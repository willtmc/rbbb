# frozen_string_literal: true

require_relative "test_helper"

class ProxyReductionTest < Minitest::Test
  def setup
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
    )
    @engine = RBBB::Engine.new(configuration)
  end

  def test_leader_may_reduce_maximum_to_executed_floor
    state = competed_state(@engine)
    original = state

    decision = reduce(@engine, state, maximum: 31_000)
    state = @engine.apply(state, decision.events)

    assert decision.accepted?
    assert_empty decision.events.select(&:public?)
    assert_equal 50_000, original.position_for("bidder-a").maximum_minor_units
    assert_equal 31_000, state.position_for("bidder-a").maximum_minor_units
    assert_equal 31_000, state.position_for("bidder-a").executed_minor_units
    assert_equal 31_000, state.standing_minor_units
  end

  def test_reduction_audit_records_old_new_and_executed_floor
    state = competed_state(@engine)
    decision = reduce(@engine, state, maximum: 35_000)
    audit = decision.events.fetch(0).to_h

    assert_equal "maximum_reduced", audit.fetch("type")
    assert_equal 50_000, audit.fetch("old_maximum_minor_units")
    assert_equal 35_000, audit.fetch("new_maximum_minor_units")
    assert_equal 31_000, audit.fetch("executed_floor_minor_units")
  end

  def test_reduction_does_not_emit_public_event_or_extend_close
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    )
    engine = RBBB::Engine.new(configuration)
    state = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bidder-b", 30_000,
      "2026-09-01T12:58:00Z")

    decision = reduce(engine, state, maximum: 35_000, effective_at: "2026-09-01T12:59:00Z")
    reduced = engine.apply(state, decision.events)

    assert_empty decision.events.select(&:public?)
    assert_equal "2026-09-01T13:03:00Z", reduced.to_h.fetch("closes_at")
  end

  def test_missing_position_and_non_reduction_are_rejected
    missing = reduce(@engine, @engine.initial_state, maximum: 20_000)
    state = place(@engine, @engine.initial_state, "command-1", "bidder-a", 50_000)
    unchanged = reduce(@engine, state, maximum: 50_000)

    assert_equal "maximum_not_found", missing.rejection.fetch("reason")
    assert_equal "maximum_not_reduced", unchanged.rejection.fetch("reason")
    assert_equal %w[command_id status reason], missing.rejection.keys
    assert_equal %w[command_id status reason], unchanged.rejection.keys
  end

  def test_reduction_below_executed_floor_reports_only_the_bidder_own_floor
    state = competed_state(@engine)
    decision = reduce(@engine, state, maximum: 20_000)

    assert decision.rejected?
    assert_equal "maximum_below_executed_amount", decision.rejection.fetch("reason")
    assert_equal 31_000, decision.rejection.fetch("executed_floor_minor_units")
    assert_equal state.position_for("bidder-a").executed_minor_units,
      decision.rejection.fetch("executed_floor_minor_units")
    assert_equal %w[command_id status reason executed_floor_minor_units], decision.rejection.keys
  end

  def test_sole_bidder_floor_under_reserve_pressure_equals_public_standing_amount
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      reserve_minor_units: 40_000
    )
    engine = RBBB::Engine.new(configuration)
    state = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000)
    decision = reduce(engine, state, maximum: 20_000)

    assert_equal 40_000, state.standing_minor_units
    assert_equal state.standing_minor_units, decision.rejection.fetch("executed_floor_minor_units")
    refute decision.rejection.key?("reserve_minor_units")
  end

  private

  def competed_state(engine)
    state = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000)
    place(engine, state, "command-2", "bidder-b", 30_000)
  end

  def place(engine, state, command_id, bidder_id, maximum, effective_at = nil)
    decision = engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bidder_id: bidder_id,
      maximum_minor_units: maximum,
      effective_at: effective_at
    })
    assert decision.accepted?, decision.rejection.inspect
    engine.apply(state, decision.events)
  end

  def reduce(engine, state, maximum:, effective_at: nil)
    engine.decide(state, {
      command_id: "command-reduce",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: maximum,
      effective_at: effective_at
    })
  end
end
