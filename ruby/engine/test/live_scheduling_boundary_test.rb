# frozen_string_literal: true
require_relative "test_helper"
require "rbbb/live_scheduling"

class LiveSchedulingBoundaryTest < Minitest::Test
  def setup
    config = {"currency" => "USD", "opening_minor_units" => 100,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 25}],
      "opens_at" => "2031-04-05T11:00:00Z", "closes_at" => "2031-04-05T13:00:00Z",
      "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}
    @configs = %w[unit-a unit-c].to_h { |id| [id, config] }
    @snapshot = {"schedule_revision" => 0,
      "units" => @configs.transform_values { |item| RBBB::State.empty(RBBB::Configuration.from_h(item)).to_h },
      "closing_sets" => [{"group_id" => "group-ac", "member_unit_ids" => @configs.keys,
        "closes_at" => config["closes_at"], "extension" => config["extension"]}]}
    @core = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo", configurations: @configs,
      snapshot: @snapshot, policy: {"minimum_shortening_lead_seconds" => 60})
  end

  def project(records)
    RBBB::LiveScheduling::Projector.apply(snapshot: @snapshot, configurations: @configs, records: records)
  end

  def assert_refused(records)
    before = Marshal.dump([@snapshot, @configs, records])
    assert_raises(RBBB::InvalidState) { project(records) }
    assert_equal before, Marshal.dump([@snapshot, @configs, records])
  end

  def test_pure_entrypoints_cannot_bypass_group_scheduling_or_operation_scope
    wrong = {"type" => "change_closing_time", "command_id" => "wrong-route",
      "operator_id" => "operator-a", "reason" => "Synthetic boundary",
      "closes_at" => "2031-04-05T14:00:00Z"}
    [wrong, wrong.merge("type" => "close_bidding"), wrong.merge("type" => "change_reserve", "reserve_minor_units" => 200)].each do |command|
      result = @core.bid(unit_id: "unit-a", command: command,
        effective_at: "2031-04-05T13:00:00Z", commit_id: "bad-bid")
      assert_equal "invalid_request", result.rejection_reason
      assert_equal @core.snapshot, result.state
      assert_empty result.records
    end
    [{group_id: "group-ac", command: wrong},
      {group_id: "group-ac", unit_id: "unit-a", command: {"type" => "close_bidding", "command_id" => "ambiguous"}}].each do |arguments|
      result = @core.close(**arguments, effective_at: "2031-04-05T13:00:00Z", commit_id: "bad-close")
      assert_equal "invalid_request", result.rejection_reason
      assert_equal @core.snapshot, result.state
      assert_empty result.records
    end
  end

  def test_linked_bid_replay_refuses_missing_reordered_and_conflicting_companions
    result = @core.bid(unit_id: "unit-a", command: {"type" => "place_bid", "command_id" => "late-bid",
      "bidder_id" => "bidder-a", "maximum_minor_units" => 500},
      effective_at: "2031-04-05T12:59:50Z", commit_id: "bid-commit")
    assert_nil result.rejection_reason
    assert_equal result.state, project(result.records)
    # A private state snapshot alone cannot prove the complete commit survived.
    result.records.each_index { |index| assert_refused(result.records.reject.with_index { |_, i| i == index }) }
    assert_refused(result.records.rotate(-1))
    reordered = RBBB::LiveScheduling.copy(result.records)
    reordered[1], reordered[2] = reordered[2], reordered[1]
    assert_refused(reordered)
    changed = RBBB::LiveScheduling.copy(result.records)
    changed[1]["event"]["command_id"] = "different-command"
    assert_refused(changed)
    changed = RBBB::LiveScheduling.copy(result.records)
    changed[1]["event"]["standing_minor_units"] += 25
    assert_refused(changed)
  end

  def test_group_close_replay_requires_every_member_and_canonical_record_order
    result = @core.close(group_id: "group-ac", command: {"type" => "close_bidding", "command_id" => "close-group"},
      effective_at: "2031-04-05T13:00:00Z", commit_id: "close-commit")
    assert_nil result.rejection_reason
    assert_equal result.state, project(result.records)
    result.records.each_index { |index| assert_refused(result.records.reject.with_index { |_, i| i == index }) }
    assert_refused(result.records.reject { |record| record["unit_id"] == "unit-a" })
    assert_refused(result.records[2, 2] + result.records[0, 2] + [result.records.last])
    changed = RBBB::LiveScheduling.copy(result.records)
    changed[1]["event"]["result"] = "sold"
    assert_refused(changed)
  end
end
