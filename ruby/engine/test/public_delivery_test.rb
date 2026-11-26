# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/durable_shared_group_host"

class PublicDeliveryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("rbbb-delivery-")
    @path = File.join(@directory, "group.sqlite3")
  end
  def teardown
    FileUtils.remove_entry(@directory)
  end
  def host(klass = RBBBExamples::DurableSharedGroupHost)
    config = {currency: "USD", opening_minor_units: 1000,
      increments: [{from_minor_units: 0, amount_minor_units: 100}],
      opens_at: "2030-01-01T12:00:00Z", closes_at: "2030-01-01T13:00:00Z"}
    klass.new(path: @path, configurations: {"lot-12" => config, "lot-47" => config},
      clock: {group_id: "group-a", unit_ids: %w[lot-12 lot-47], closes_at: config[:closes_at], quiet_period_seconds: 180})
  end
  def bid(id: "bid-a", maximum: 5000)
    {unit_id: "lot-12", expected_revision: 0, command: {command_id: id,
      type: "place_bid", bidder_id: "private-bidder", maximum_minor_units: maximum,
      effective_at: "2030-01-01T12:30:00Z"}}
  end
  def pending(consumer = "public-feed")
    host.next_public_delivery(consumer_id: consumer)
  end
  def test_committed_bid_and_group_close_are_delivered_in_order_after_restart
    host.submit(**bid)
    host.close_group(command_id: "close", effective_at: "2030-01-01T13:00:00Z", expected_revision: 0)
    first = pending
    assert_equal ["open"], first["units"].values.map { |v| v["status"] }.uniq
    assert host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: first["delivery_id"])
    second = pending
    assert_equal ["closed"], second["units"].values.map { |v| v["status"] }.uniq
    refute_equal first["delivery_id"], second["delivery_id"]
    host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: second["delivery_id"])
    assert_nil pending
  end
  def test_failed_callback_remains_pending_with_same_identity
    host.submit(**bid)
    original = pending
    assert_raises(RuntimeError) do
      host.deliver_next_public(consumer_id: "public-feed") { raise "transport unavailable" }
    end
    assert_equal original, pending
  end
  def test_crash_after_sink_write_before_ack_retries_stable_identity
    host.submit(**bid)
    sink = File.join(@directory, "sink-id")
    pid = fork do
      host.deliver_next_public(consumer_id: "public-feed") do |payload|
        File.write(sink, payload["delivery_id"])
        Process.exit!(79)
      end
    end
    assert_equal 79, Process.wait2(pid).last.exitstatus
    assert_equal File.read(sink), pending["delivery_id"]
    applied = {File.read(sink) => true}
    host.deliver_next_public(consumer_id: "public-feed") { |p| applied[p["delivery_id"]] ||= true }
    assert_equal 1, applied.size
    assert_nil pending
  end
  def test_ack_is_idempotent_and_consumers_are_independent
    host.submit(**bid)
    id = pending["delivery_id"]
    assert host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: id)
    refute host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: id)
    assert_nil pending
    assert_equal id, pending("second-feed")["delivery_id"]
  end
  def test_ack_cannot_skip_pending_or_use_foreign_stream
    host.submit(**bid)
    host.submit(**bid(id: "increase", maximum: 6000))
    id = pending["delivery_id"]
    assert_raises(ArgumentError) { host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: id.sub(/:1$/, ":2")) }
    assert_raises(ArgumentError) { host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: "foreign:1") }
    assert_equal id, pending["delivery_id"]
  end
  def test_rejections_and_command_retries_do_not_create_extra_delivery
    host.submit(**bid(id: "low", maximum: 1))
    assert_nil pending
    host.submit(**bid)
    host.submit(**bid)
    host.deliver_next_public(consumer_id: "public-feed") { |_| }
    assert_nil pending
  end
  def test_rolled_back_commit_creates_no_delivery
    crashing = Class.new(RBBBExamples::DurableSharedGroupHost) do
      private
      def before_commit(_db)
        raise "failed save"
      end
    end
    assert_raises(RuntimeError) { host(crashing).submit(**bid) }
    assert_nil pending
  end
  def test_delivery_excludes_private_bid_records
    host.submit(**bid)
    host.close_group(command_id: "close", effective_at: "2030-01-01T13:00:00Z", expected_revision: 0)
    2.times do
      payload = pending
      %w[private-bidder maximum_minor_units winner_id leader_id positions events command_id].each do |secret|
        refute_includes JSON.generate(payload), secret
      end
      host.acknowledge_public_delivery(consumer_id: "public-feed", delivery_id: payload["delivery_id"])
    end
  end
  def test_callback_does_not_hold_writer_lock
    host.submit(**bid)
    host.deliver_next_public(consumer_id: "public-feed") do |_|
      host.submit(**bid(id: "increase", maximum: 6000))
    end
    assert pending
  end
  def test_callback_cannot_change_which_delivery_is_acknowledged
    host.submit(**bid)
    host.submit(**bid(id: "increase", maximum: 6000))
    consumer = +"public-feed"
    first_id = pending["delivery_id"]
    host.deliver_next_public(consumer_id: consumer) do |payload|
      consumer.replace("other-feed")
      payload["delivery_id"].replace(first_id.sub(/:1$/, ":2"))
    end
    assert_equal first_id.sub(/:1$/, ":2"), pending["delivery_id"]
    assert_equal first_id, pending("other-feed")["delivery_id"]
  end

end
