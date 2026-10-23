# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbbb/live_scheduling"

class LeaderMaximumTest < Minitest::Test
  def engine(reserve: nil, extension: nil)
    RBBB::Engine.new(RBBB::Configuration.new(currency: "USD", opening_minor_units: 10_000,
      reserve_minor_units: reserve, extension: extension, increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2034-02-10T12:00:00Z", closes_at: "2034-02-10T13:00:00Z"))
  end

  def apply(engine, state, type, **fields)
    command = {type: type, command_id: "command-#{state.version + 1}",
      effective_at: "2034-02-10T12:30:00Z"}.merge(fields)
    decision = engine.decide(state, command)
    assert decision.accepted?, decision.rejection.inspect
    [engine.apply(state, decision.events), decision]
  end

  def test_void_reconstruction_preserves_the_ladder_price
    e = engine
    s = e.initial_state
    [["a", 13_200], ["b", 12_500], ["a", 18_000], ["a", 20_000]].each do |who, amount|
      s, = apply(e, s, "place_bid", bidder_id: who, maximum_minor_units: amount)
    end
    s, = apply(e, s, "void_bid", bid_id: "command-3", operator_id: "operator-demo",
      reason: "duplicate authorization", notification_policy: "none")
    assert_equal 13_000, s.standing_minor_units
    assert_equal 13_000, s.position_for("a").executed_minor_units
    assert_equal 14_000, s.next_required_minor_units
    s, = apply(e, s, "reduce_maximum", bidder_id: "a", maximum_minor_units: 13_200)
    assert_equal 13_200, s.position_for("a").maximum_minor_units
  end

  def test_reduction_back_to_a_tie_follows_executable_maximum_priority_and_replays
    e = engine(extension: {trigger_window_seconds: 300, duration_seconds: 300})
    s = e.initial_state
    [["a", 24_000], ["b", 24_000], ["a", 29_000]].each do |who, amount|
      s, = apply(e, s, "place_bid", bidder_id: who, maximum_minor_units: amount)
    end
    s, decision = apply(e, s, "reduce_maximum", bidder_id: "a", maximum_minor_units: 24_000,
      effective_at: "2034-02-10T12:59:00Z")
    assert_equal "b", s.leader_id
    assert_equal 24_000, s.standing_minor_units
    assert_equal 24_000, s.position_for("a").executed_minor_units
    assert_equal "2034-02-10T13:04:00Z", RBBB::Timestamp.dump(s.closes_at)
    assert_equal %w[standing_bid_changed closing_time_changed], decision.events.select(&:public?).map(&:type)
    replay = e.send(:replay_authorizations, s.authorization_history, s.voided_bid_ids, s.reserve_history)
    assert_equal "b", replay.fetch("leader_id")
    assert_equal s.positions.transform_values(&:to_h), replay.fetch("positions")
    assert_equal s.to_h, e.restore(decision.events.first).to_h
  end

  def test_reserve_pressure_still_advances_and_stops_at_reserve
    e = engine(reserve: 13_400)
    s = e.initial_state
    s, = apply(e, s, "place_bid", bidder_id: "a", maximum_minor_units: 13_200)
    s, decision = apply(e, s, "place_bid", bidder_id: "a", maximum_minor_units: 18_000)
    assert_equal 14_000, s.standing_minor_units
    assert_equal "reserve_met", s.reserve_status
    assert_equal 14_000, s.position_for("a").executed_minor_units
    assert decision.events.any?(&:public?)
    s, decision = apply(e, s, "place_bid", bidder_id: "a", maximum_minor_units: 20_000)
    assert_equal 14_000, s.standing_minor_units
    assert_empty decision.events.select(&:public?)
  end

  def test_postclose_void_boundary_is_unchanged
    e = engine
    s, = apply(e, e.initial_state, "place_bid", bidder_id: "a", maximum_minor_units: 13_200)
    decision = e.decide(s, {type: "void_bid", command_id: "late-void", bid_id: "command-1",
      operator_id: "operator-demo", reason: "later review", notification_policy: "none",
      effective_at: "2034-02-11T12:00:00Z"})
    assert decision.rejected?
    assert_equal "bidding_closed", decision.rejection.fetch("reason")
    assert_empty decision.events
  end

  def test_leader_increase_preserves_extensions_across_linked_members
    vector = JSON.parse(File.read(File.expand_path("../../../conformance/shared-closing-clock/leader-maximum.json", __dir__)))
    ids = vector.fetch("member_unit_ids")
    config = vector.fetch("configuration")
    configurations = ids.to_h { |id| [id, config] }
    snapshot = {"schedule_revision" => 0,
      "units" => ids.to_h { |id| [id, RBBB::State.empty(RBBB::Configuration.from_h(config)).to_h] },
      "closing_sets" => [{"group_id" => "group-demo", "member_unit_ids" => ids,
        "closes_at" => config.fetch("closes_at"), "extension" => vector.fetch("extension")}]}
    policy = {"minimum_shortening_lead_seconds" => 60}
    vector.fetch("steps").each_with_index do |step, index|
      coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo",
        configurations: configurations, snapshot: snapshot, policy: policy)
      result = coordinator.bid(unit_id: step.fetch("unit_id"), command: step.fetch("command"),
        effective_at: step.fetch("effective_at"), commit_id: "commit-#{index}")
      assert_nil result.rejection_reason
      projected = RBBB::LiveScheduling::Projector.apply_commit(snapshot: snapshot,
        configurations: configurations, records: result.records, policy: policy, auction_id: "auction-demo")
      assert_equal result.state, projected.fetch("snapshot")
      snapshot = result.state
      assert_equal step.fetch("standing_minor_units"), snapshot["units"][step.fetch("unit_id")]["standing_minor_units"]
      ids.each { |id| assert_equal step.fetch("shared_closes_at"), snapshot["units"][id]["closes_at"] }
    end
    coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo",
      configurations: configurations, snapshot: snapshot, policy: policy)
    result = coordinator.close(group_id: "group-demo",
      command: {"type" => "close_bidding", "command_id" => "close-demo"},
      effective_at: "2034-02-10T13:13:00Z", commit_id: "commit-close")
    assert_nil result.rejection_reason
    projected = RBBB::LiveScheduling::Projector.apply_commit(snapshot: snapshot,
      configurations: configurations, records: result.records, policy: policy, auction_id: "auction-demo")
    assert_equal result.state, projected.fetch("snapshot")
    %w[unit-amber unit-coral].each do |id|
      assert_equal "bidder-b", result.state["units"][id]["winner_id"]
    end
  end
end
