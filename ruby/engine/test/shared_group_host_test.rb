# frozen_string_literal: true
require_relative "test_helper"
require_relative "../../../examples/shared_group_host"

class SharedGroupHostTest < Minitest::Test
  IDS = %w[lot-12 lot-47 lot-103].freeze
  def host(klass = RBBBExamples::SharedGroupHost)
    clock = RBBB::SharedClosingClock.new(group_id: "group-a", unit_ids: IDS,
      closes_at: "2030-01-01T13:00:00Z", quiet_period_seconds: 180)
    configs = IDS.to_h do |id|
      [id, RBBB::Configuration.new(currency: "USD", opening_minor_units: 1000,
        increments: [{from_minor_units: 0, amount_minor_units: 100}],
        opens_at: "2030-01-01T12:00:00Z", closes_at: "2030-01-01T13:00:00Z")]
    end
    klass.new(configurations: configs, clock: clock)
  end
  def command(id = "bid-a", bidder: "bidder-a", at: "2030-01-01T12:59:00Z", maximum: 5000)
    {command_id: id, type: "place_bid", bidder_id: bidder,
      maximum_minor_units: maximum, effective_at: at}
  end
  def test_real_member_bids_use_extended_deadline_and_retry_original_receipt
    current = host
    first = current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    second = current.submit(unit_id: IDS[1], command: command("bid-b", at: "2030-01-01T13:01:00Z"), expected_revision: 1)
    assert second.decision.accepted?
    assert_equal ["2030-01-01T13:04:00Z"], current.public_view.values.map { |v| v["closes_at"] }.uniq
    assert_same first, current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    assert_equal "2030-01-01T13:02:00Z", first.clock["closes_at"]
    assert_equal 1, current.public_view[IDS[0]]["version"]
  end
  def test_concurrent_identical_requests_commit_once
    current = host
    results = 12.times.map { Thread.new { current.submit(unit_id: IDS[0], command: command, expected_revision: 0) } }.map(&:value)
    assert_equal 1, results.map(&:object_id).uniq.size
    assert_equal 1, current.public_view[IDS[0]]["version"]
    assert_equal 1, results.first.clock["revision"]
  end
  def test_concurrent_different_bids_cannot_overwrite_shared_clock
    current = host
    results = IDS.first(2).map do |id|
      Thread.new do
        current.submit(unit_id: id, command: command(id), expected_revision: 0)
      rescue RBBB::InvalidState => e
        e
      end
    end.map(&:value)
    assert_equal 1, results.count { |r| r.is_a?(RBBBExamples::SharedGroupHost::Receipt) }
    assert_equal 1, results.count { |r| r.is_a?(RBBB::InvalidState) }
    assert_equal 1, current.public_view.values.sum { |v| v["version"] }
  end
  def test_failed_publication_leaves_no_bid_clock_or_receipt
    failing = Class.new(RBBBExamples::SharedGroupHost) do
      attr_accessor :fail_commit
      private
      def publish(candidate)
        raise "simulated storage failure" if fail_commit
        super
      end
    end
    current = host(failing)
    before = current.public_view
    current.fail_commit = true
    assert_raises(RuntimeError) { current.submit(unit_id: IDS[0], command: command, expected_revision: 0) }
    assert_equal before, current.public_view
    current.fail_commit = false
    receipt = current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    assert receipt.decision.accepted?
    assert_equal 1, receipt.clock["revision"]
  end
  def test_proxy_adjustment_and_rejection_do_not_extend_and_rejections_are_retryable
    current = host
    current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    increased = current.submit(unit_id: IDS[0], command: command("increase", maximum: 6000, at: "2030-01-01T13:01:00Z"), expected_revision: 1)
    assert increased.decision.accepted?
    assert_equal "2030-01-01T13:02:00Z", increased.clock["closes_at"]
    low = command("low", maximum: 1, at: "2030-01-01T13:01:30Z")
    rejected = current.submit(unit_id: IDS[1], command: low, expected_revision: 1)
    assert rejected.decision.rejected?
    assert_same rejected, current.submit(unit_id: IDS[1], command: low, expected_revision: 1)
    assert_equal 0, current.public_view[IDS[1]]["version"]
  end
  def test_conflicting_retry_or_clock_time_regression_never_changes_state
    current = host
    current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    before = current.public_view
    assert_raises(ArgumentError) { current.submit(unit_id: IDS[1], command: command, expected_revision: 0) }
    assert_raises(RBBB::InvalidState) do
      current.submit(unit_id: IDS[1], command: command("old", at: "2030-01-01T12:58:00Z"), expected_revision: 1)
    end
    assert_equal before, current.public_view
  end
  def test_public_projection_is_immutable_and_receipt_owns_request_copy
    current = host
    request = command(bidder: +"bidder-a")
    receipt = current.submit(unit_id: IDS[0], command: request, expected_revision: 0)
    request[:bidder_id].replace("mutated")
    assert_same receipt, current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    assert current.public_view.frozen?
    assert_raises(FrozenError) { current.public_view[IDS[0]]["closes_at"].replace("bad") }
    %w[bidder-a maximum_minor_units positions leader_id].each { |secret| refute_includes current.public_view.inspect, secret }
  end
  def test_committed_event_batches_rebuild_member_views_with_authoritative_clock
    current = host
    current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    current.submit(unit_id: IDS[1], command: command("second", at: "2030-01-01T13:01:00Z"), expected_revision: 1)
    snapshot = current.instance_variable_get(:@snapshot)
    engines = current.instance_variable_get(:@engines)
    restored = engines.transform_values(&:initial_state)
    snapshot.event_batches.each do |batch|
      id = batch.fetch("unit_id")
      restored[id] = engines.fetch(id).restore(batch.fetch("events").find(&:privileged?))
    end
    views = restored.transform_values do |state|
      state.public_view.merge("closes_at" => RBBB::Timestamp.dump(snapshot.clock.closes_at))
    end
    assert_equal current.public_view, views
    assert_equal 2, snapshot.receipts.size
    assert_equal 2, snapshot.event_batches.size
  end

  def test_elapsed_group_rejects_bid_and_receipt_clock_cannot_be_mutated
    current = host
    receipt = current.submit(unit_id: IDS[0], command: command, expected_revision: 0)
    assert_raises(FrozenError) { receipt.clock["closes_at"].replace("bad") }
    late = current.submit(unit_id: IDS[1], command: command("late", at: "2030-01-01T13:02:00Z"), expected_revision: 1)
    assert late.decision.rejected?
    assert_equal "bidding_closed", late.decision.rejection["reason"]
    assert_equal 0, current.public_view[IDS[1]]["version"]
  end

end
