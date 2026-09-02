# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for defects found by adversarial review of the RFC 0001
# engine: schedule, time-ordering, timestamp, and apply-boundary hardening.
class HardeningTest < Minitest::Test
  OPENS_AT = "2026-09-01T12:00:00Z"
  CLOSES_AT = "2026-09-01T13:00:00Z"

  def test_extension_never_pulls_closing_time_earlier
    engine = build_engine(extension: {trigger_window_seconds: 300, duration_seconds: 60})

    decision = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:56:00Z")
    state = engine.apply(engine.initial_state, decision.events)

    assert decision.accepted?
    assert_equal CLOSES_AT, state.to_h.fetch("closes_at")
    refute decision.events.any? { |event| event.type == "closing_time_changed" }

    later = place(engine, state, "command-2", "bidder-b", 20_000,
      effective_at: "2026-09-01T12:59:30Z")
    extended = engine.apply(state, later.events)

    assert_equal "2026-09-01T13:00:30Z", extended.to_h.fetch("closes_at")
  end

  def test_bidder_commands_before_opening_time_are_rejected
    engine = build_engine
    early = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T11:59:59.999Z")
    at_open = place(engine, engine.initial_state, "command-2", "bidder-a", 50_000,
      effective_at: OPENS_AT)

    assert_equal "bidding_not_open", early.rejection.fetch("reason")
    assert at_open.accepted?, at_open.rejection.inspect

    state = engine.apply(engine.initial_state, at_open.events)
    reduction = engine.decide(state, {
      command_id: "command-3",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: 20_000,
      effective_at: "2026-09-01T11:00:00Z"
    })
    assert_equal "effective_at_out_of_order", reduction.rejection.fetch("reason")
  end

  def test_reduction_before_opening_time_is_rejected_when_no_time_has_been_recorded
    engine = build_engine
    reduction = engine.decide(engine.initial_state, {
      command_id: "command-1",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: 20_000,
      effective_at: "2026-09-01T11:00:00Z"
    })

    assert_equal "bidding_not_open", reduction.rejection.fetch("reason")
  end

  def test_operator_commands_remain_permitted_before_opening_time
    engine = build_engine(reserve: nil)
    decision = engine.decide(engine.initial_state, {
      command_id: "command-1",
      type: "change_reserve",
      operator_id: "operator-1",
      reason: "seller_set_reserve",
      reserve_minor_units: 80_000,
      effective_at: "2026-08-31T09:00:00Z"
    })

    assert decision.accepted?, decision.rejection.inspect
  end

  def test_commands_with_regressing_authoritative_time_are_rejected
    engine = build_engine
    first = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:30:00Z")
    state = engine.apply(engine.initial_state, first.events)

    assert_equal "2026-09-01T12:30:00Z", state.to_h.fetch("last_effective_at")

    regressed = place(engine, state, "command-2", "bidder-b", 60_000,
      effective_at: "2026-09-01T12:29:59Z")
    equal = place(engine, state, "command-3", "bidder-b", 60_000,
      effective_at: "2026-09-01T12:30:00Z")
    regressed_close = engine.decide(state, {
      command_id: "command-4",
      type: "close_bidding",
      effective_at: "2026-09-01T12:00:00Z"
    })

    assert_equal "effective_at_out_of_order", regressed.rejection.fetch("reason")
    assert equal.accepted?, equal.rejection.inspect
    assert_equal "effective_at_out_of_order", regressed_close.rejection.fetch("reason")
  end

  def test_zone_less_timestamps_are_rejected_rather_than_read_as_host_local_time
    assert_raises(ArgumentError) { RBBB::Timestamp.parse("2026-09-01T12:59:00") }
    assert_raises(ArgumentError) { RBBB::Timestamp.parse("2026-09-01 12:59:00Z") }
    assert_equal "2026-09-01T12:59:00Z",
      RBBB::Timestamp.dump(RBBB::Timestamp.parse("2026-09-01T07:59:00-05:00"))

    engine = build_engine
    decision = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:59:00")

    assert_equal "invalid_command", decision.rejection.fetch("reason")
  end

  def test_apply_refuses_events_from_more_than_one_command
    engine = build_engine
    first = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:10:00Z")
    state = engine.apply(engine.initial_state, first.events)
    second = place(engine, state, "command-2", "bidder-b", 60_000,
      effective_at: "2026-09-01T12:11:00Z")

    error = assert_raises(RBBB::InvalidState) do
      engine.apply(engine.initial_state, first.events + second.events)
    end
    assert_match(/exactly one accepted command/, error.message)
  end

  def test_increment_schedule_rejects_non_integer_bounds_as_configuration_errors
    error = assert_raises(RBBB::InvalidConfiguration) do
      RBBB::IncrementSchedule.new([
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: "100000", amount_minor_units: 2_500}
      ])
    end
    assert_match(/lower bounds/, error.message)

    assert_raises(RBBB::InvalidConfiguration) do
      RBBB::IncrementSchedule.new([{from_minor_units: 0, amount_minor_units: 1_000}, "bad"])
    end
  end

  private

  def build_engine(reserve: nil, extension: nil)
    RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: reserve,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT,
      extension: extension
    ))
  end

  def place(engine, state, command_id, bidder_id, maximum, effective_at:)
    engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bidder_id: bidder_id,
      maximum_minor_units: maximum,
      effective_at: effective_at
    })
  end
end
