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

  def test_state_requires_opens_at_and_closes_at
    error = assert_raises(RBBB::InvalidState) do
      build_state(opens_at: nil, closes_at: CLOSES_AT)
    end
    assert_match(/missing opens_at/, error.message)

    error = assert_raises(RBBB::InvalidState) do
      build_state(opens_at: OPENS_AT, closes_at: nil)
    end
    assert_match(/missing closes_at/, error.message)

    state = build_state(opens_at: OPENS_AT, closes_at: CLOSES_AT)
    assert_equal OPENS_AT, state.to_h.fetch("opens_at")
    assert_equal CLOSES_AT, state.to_h.fetch("closes_at")
  end

  def test_timestamp_rejects_years_outside_rfc3339_four_digit_range
    [
      Time.utc(0, 12, 31, 23, 59, 59),
      Time.utc(10_000, 1, 1, 0, 0, 0),
      "0000-12-31T23:59:59Z",
      "0001-01-01T00:00:00+01:00",
      "9999-12-31T23:59:59-01:00"
    ].each do |invalid|
      assert_raises(ArgumentError) { RBBB::Timestamp.parse(invalid) }
    end

    assert_raises(ArgumentError) { RBBB::Timestamp.dump(Time.utc(0, 12, 31, 23, 59, 59)) }
    assert_raises(ArgumentError) { RBBB::Timestamp.dump(Time.utc(10_000, 1, 1, 0, 0, 0)) }
    assert_equal "0001-01-01T00:00:00Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("0001-01-01T00:00:00Z"))
    assert_equal "9999-12-31T23:59:59.999Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("9999-12-31T23:59:59.999Z"))
  end

  def test_extension_overflow_past_year_9999_is_rejected_cleanly_in_decide
    engine = build_engine(extension: {
      trigger_window_seconds: 300,
      duration_seconds: RBBB::MAX_SAFE_INTEGER,
      extend_on_void: true
    })

    bid_overflow = place(engine, engine.initial_state, "cmd-bid", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:59:00Z")
    assert bid_overflow.rejected?
    assert_equal "invalid_closing_time", bid_overflow.rejection.fetch("reason")

    state = engine.apply(engine.initial_state, place(engine, engine.initial_state, "cmd-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:10:00Z").events)
    state = engine.apply(state, place(engine, state, "cmd-2", "bidder-b", 50_000,
      effective_at: "2026-09-01T12:11:00Z").events)
    state = engine.apply(state, place(engine, state, "cmd-3", "bidder-a", 60_000,
      effective_at: "2026-09-01T12:12:00Z").events)

    reduction_overflow = engine.decide(state, {
      command_id: "cmd-reduce",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000,
      effective_at: "2026-09-01T12:59:00Z"
    })
    assert reduction_overflow.rejected?
    assert_equal "invalid_closing_time", reduction_overflow.rejection.fetch("reason")

    void_overflow = engine.decide(state, {
      command_id: "cmd-void",
      type: "void_bid",
      bid_id: "cmd-2",
      operator_id: "operator-1",
      reason: "review",
      notification_policy: "none",
      effective_at: "2026-09-01T12:59:00Z"
    })
    assert void_overflow.rejected?
    assert_equal "invalid_closing_time", void_overflow.rejection.fetch("reason")
  end

  def test_apply_rejects_transitions_on_closed_state_and_backward_effective_at
    engine = build_engine
    first = place(engine, engine.initial_state, "command-1", "bidder-a", 50_000,
      effective_at: "2026-09-01T12:30:00Z")
    open_state = engine.apply(engine.initial_state, first.events)

    assert_same open_state, engine.apply(open_state, [])
    assert_raises(RBBB::InvalidState) { engine.apply(open_state, first.public_events) }

    second = place(engine, open_state, "command-2", "bidder-b", 60_000,
      effective_at: "2026-09-01T12:31:00Z")
    backward_transition = RBBB::Event.new(
      type: second.transition_event.type,
      visibility: :privileged,
      data: second.transition_event.data.merge("effective_at" => "2026-09-01T12:29:59Z")
    )
    error = assert_raises(RBBB::InvalidState) { engine.apply(open_state, [backward_transition]) }
    assert_match(/precedes state last_effective_at/, error.message)

    close_decision = engine.decide(open_state, {
      command_id: "command-close",
      type: "close_bidding",
      effective_at: CLOSES_AT
    })
    closed_state = engine.apply(open_state, close_decision.events)
    reopen_transition = RBBB::Event.new(
      type: "maximum_accepted",
      visibility: :privileged,
      data: second.transition_event.data.merge(
        "aggregate_version" => closed_state.version + 1,
        "effective_at" => "2026-09-01T13:01:00Z"
      )
    )
    error = assert_raises(RBBB::InvalidState) { engine.apply(closed_state, [reopen_transition]) }
    assert_match(/closed state/, error.message)
  end

  def test_malformed_command_id_produces_nil_in_rejection
    engine = build_engine
    ["", 123, false, "x" * 256, nil].each do |bad_id|
      invalid = engine.decide(engine.initial_state, {
        command_id: bad_id,
        type: "place_bid",
        bidder_id: "bidder-a",
        maximum_minor_units: 50_000,
        effective_at: "2026-09-01T12:10:00Z"
      })
      assert invalid.rejected?
      assert_equal "invalid_command", invalid.rejection.fetch("reason")
      assert_nil invalid.rejection.fetch("command_id")

      unsupported = engine.decide(engine.initial_state, {
        command_id: bad_id,
        type: "unknown_command"
      })
      assert unsupported.rejected?
      assert_equal "unsupported_command", unsupported.rejection.fetch("reason")
      assert_nil unsupported.rejection.fetch("command_id")
    end
  end

  def test_non_integer_expected_version_and_explicit_false_bid_id_are_rejected
    engine = build_engine

    [0.0, "0", -1, RBBB::MAX_SAFE_INTEGER + 1, nil].each do |bad_version|
      decision = engine.decide(engine.initial_state, {
        command_id: "command-1",
        type: "place_bid",
        bidder_id: "bidder-a",
        maximum_minor_units: 50_000,
        expected_version: bad_version,
        effective_at: "2026-09-01T12:10:00Z"
      })
      assert decision.rejected?
      assert_equal "invalid_command", decision.rejection.fetch("reason")
    end

    false_bid_id = engine.decide(engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bid_id: false,
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000,
      effective_at: "2026-09-01T12:10:00Z"
    })
    assert false_bid_id.rejected?
    assert_equal "invalid_command", false_bid_id.rejection.fetch("reason")
  end

  def test_version_at_max_safe_integer_is_bounded_cleanly
    engine = build_engine
    max_state = RBBB::State.new(
      version: RBBB::MAX_SAFE_INTEGER,
      positions: {},
      leader_id: nil,
      standing_minor_units: nil,
      next_required_minor_units: 10_000,
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT
    )

    assert_raises(RBBB::InvalidState) do
      place(engine, max_state, "command-overflow", "bidder-a", 50_000,
        effective_at: "2026-09-01T12:10:00Z")
    end
    assert_raises(RBBB::InvalidState) do
      RBBB::State.from_h(max_state.to_h.merge("version" => RBBB::MAX_SAFE_INTEGER + 1))
    end
  end

  def test_configuration_from_h_rejects_non_hash_as_invalid_configuration
    [nil, "not-a-hash", 42, []].each do |input|
      assert_raises(RBBB::InvalidConfiguration) { RBBB::Configuration.from_h(input) }
    end
  end

  def test_unsupported_feature_constant_is_removed
    refute defined?(RBBB::UnsupportedFeature)
  end

  private

  def build_state(opens_at:, closes_at:)
    RBBB::State.new(
      version: 0,
      positions: {},
      leader_id: nil,
      standing_minor_units: nil,
      next_required_minor_units: 10_000,
      opens_at: opens_at,
      closes_at: closes_at
    )
  end

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
