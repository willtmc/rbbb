# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/durable_shared_group_host"

class DurableGroupCloseTest < Minitest::Test
  IDS = %w[lot-12 lot-47 lot-103].freeze
  def setup
    @directory = Dir.mktmpdir("rbbb-close-")
    @path = File.join(@directory, "group.sqlite3")
  end
  def teardown
    FileUtils.remove_entry(@directory)
  end
  def host(klass = RBBBExamples::DurableSharedGroupHost)
    configurations = IDS.to_h do |id|
      [id, {currency: "USD", opening_minor_units: 1000,
        reserve_minor_units: id == "lot-47" ? 10000 : nil,
        increments: [{from_minor_units: 0, amount_minor_units: 100}],
        opens_at: "2030-01-01T12:00:00Z", closes_at: "2030-01-01T13:00:00Z"}]
    end
    klass.new(path: @path, configurations: configurations,
      clock: {group_id: "group-a", unit_ids: IDS, closes_at: "2030-01-01T13:00:00Z", quiet_period_seconds: 180})
  end
  def bid(unit: "lot-12", at: "2030-01-01T12:30:00Z", revision: 0)
    host.submit(unit_id: unit, expected_revision: revision, command: {
      command_id: "bid-#{unit}", type: "place_bid", bidder_id: "bidder-a",
      maximum_minor_units: 5000, effective_at: at})
  end
  def closing(id: "close-a", at: "2030-01-01T13:00:00Z", revision: 0)
    {command_id: id, effective_at: at, expected_revision: revision}
  end
  def test_mixed_outcomes_commit_together_and_replay_after_restart
    bid
    bid(unit: "lot-47")
    receipt = host.close_group(**closing)
    assert_equal ["closed"], receipt.public_units.values.map { |v| v["status"] }.uniq
    assert_equal "sold", receipt.public_units["lot-12"]["result"]
    assert_equal "no_sale", receipt.public_units["lot-47"]["result"]
    assert_equal "no_bid", receipt.public_units["lot-103"]["result"]
    assert_equal receipt.public_units, host.public_view["units"]
    retry_receipt = host.close_group(**closing)
    assert_equal receipt.decisions.transform_values { |d| d.events.map(&:to_h) }, retry_receipt.decisions.transform_values { |d| d.events.map(&:to_h) }
    assert_equal [1, 2, 2], host.public_view["units"].values.map { |v| v["version"] }.sort
  end
  def test_extended_group_cannot_close_at_original_deadline
    bid(at: "2030-01-01T12:59:00Z")
    assert_raises(RBBB::InvalidState) { host.close_group(**closing(revision: 1)) }
    assert_equal ["open"], host.public_view["units"].values.map { |v| v["status"] }.uniq
    receipt = host.close_group(**closing(at: "2030-01-01T13:02:00Z", revision: 1))
    assert_equal ["closed"], receipt.public_units.values.map { |v| v["status"] }.uniq
  end
  def test_stale_close_revision_is_refused_without_saving_receipt
    bid(at: "2030-01-01T12:59:00Z")
    assert_raises(RBBB::InvalidState) { host.close_group(**closing(at: "2030-01-01T13:02:00Z")) }
    assert_equal ["open"], host.public_view["units"].values.map { |v| v["status"] }.uniq
    assert host.close_group(**closing(at: "2030-01-01T13:02:00Z", revision: 1))
  end
  def test_crash_before_commit_leaves_every_member_open
    bid
    crashing = Class.new(RBBBExamples::DurableSharedGroupHost) do
      private
      def before_commit(_db)
        Process.exit!(76)
      end
    end
    pid = fork { host(crashing).close_group(**closing) }
    assert_equal 76, Process.wait2(pid).last.exitstatus
    assert_equal ["open"], host.public_view["units"].values.map { |v| v["status"] }.uniq
    assert_equal ["closed"], host.close_group(**closing).public_units.values.map { |v| v["status"] }.uniq
  end
  def test_crash_after_commit_retries_original_outcomes_once
    bid
    pid = fork do
      host.close_group(**closing)
      Process.exit!(77)
    end
    assert_equal 77, Process.wait2(pid).last.exitstatus
    assert_equal "sold", host.close_group(**closing).public_units["lot-12"]["result"]
    assert_equal 2, host.public_view["units"]["lot-12"]["version"]
  end
  def test_concurrent_identical_close_requests_have_one_result
    host
    pids = 3.times.map { fork { host.close_group(**closing); Process.exit!(0) } }
    pids.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal [1], host.public_view["units"].values.map { |v| v["version"] }.uniq
  end
  def test_closed_group_rejects_new_bids_and_new_close_ids
    host.close_group(**closing)
    result = bid(at: "2030-01-01T13:01:00Z")
    assert result.decision.rejected?
    assert_equal "bidding_closed", result.decision.rejection["reason"]
    assert_raises(RBBB::InvalidState) { host.close_group(**closing(id: "another")) }
    assert_equal [1], host.public_view["units"].values.map { |v| v["version"] }.uniq
  end
  def test_close_id_collision_with_bid_and_changed_retry_are_refused
    bid
    assert_raises(ArgumentError) { host.close_group(**closing(id: "bid-lot-12")) }
    host.close_group(**closing)
    assert_raises(ArgumentError) { host.close_group(**closing(at: "2030-01-01T13:01:00Z")) }
  end
  def test_public_close_projection_excludes_privileged_winner_and_maxima
    bid
    receipt = host.close_group(**closing)
    assert receipt.decisions["lot-12"].events.any? { |e| e.privileged? && e.data["winner_id"] == "bidder-a" }
    %w[bidder-a winner_id maximum_minor_units positions].each do |private_value|
      refute_includes receipt.public_units.inspect, private_value
    end
    assert_raises(FrozenError) { receipt.public_units["lot-12"]["status"].replace("open") }
  end
  def test_one_member_refusal_discards_prepared_outcomes_for_other_members
    bid
    refusing = Class.new(RBBBExamples::DurableSharedGroupHost) do
      private
      def build_host
        result = super
        engines = result.instance_variable_get(:@engines).dup
        engine = engines.fetch("lot-47")
        def engine.decide(state, command)
          return RBBB::Decision.rejected(command_id: command["command_id"], reason: "bidding_closed") if command["type"] == "close_bidding"
          super
        end
        result
      end
    end
    assert_raises(RBBB::InvalidState) { host(refusing).close_group(**closing) }
    assert_equal ["open"], host.public_view["units"].values.map { |v| v["status"] }.uniq
    assert_equal "sold", host.close_group(**closing).public_units["lot-12"]["result"]
  end

  def test_bid_and_close_race_has_no_partially_closed_group
    host
    bidder = fork do
      bid(at: "2030-01-01T12:59:00Z")
      Process.exit!(0)
    end
    closer = fork do
      host.close_group(**closing)
      Process.exit!(0)
    rescue RBBB::InvalidState
      Process.exit!(78)
    end
    assert Process.wait2(bidder).last.success?
    assert_includes [0, 78], Process.wait2(closer).last.exitstatus
    view = host.public_view
    statuses = view["units"].values.map { |v| v["status"] }.uniq
    assert_includes [["open"], ["closed"]], statuses
    assert_equal(statuses == ["open"] ? 1 : 0, view["clock"]["revision"])
  end

end
