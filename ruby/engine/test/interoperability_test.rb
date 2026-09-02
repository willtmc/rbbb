# frozen_string_literal: true

require_relative "test_helper"

# Cross-language determinism: every amount fits in 2**53 - 1 and every
# timestamp carries at most millisecond precision, so a JavaScript, Go, or Java
# implementation replays the same command stream to the same outcome.
class InteroperabilityTest < Minitest::Test
  BOUND = RBBB::Money::MAX_MINOR_UNITS

  def test_bound_is_the_largest_safe_json_integer
    assert_equal 9_007_199_254_740_991, BOUND
    assert_equal (2**53) - 1, BOUND
  end

  def test_money_accepts_the_bound_and_rejects_one_above_it
    assert_equal BOUND, RBBB::Money.new(currency: "USD", minor_units: BOUND).minor_units
    assert_raises(RBBB::InvalidMoney) { RBBB::Money.new(currency: "USD", minor_units: BOUND + 1) }
    assert_raises(RBBB::InvalidMoney) { RBBB::Money.new(currency: "USD", minor_units: 10**40) }
  end

  def test_money_arithmetic_cannot_leave_the_bound
    top = RBBB::Money.new(currency: "USD", minor_units: BOUND)
    one = RBBB::Money.new(currency: "USD", minor_units: 1)

    assert_raises(RBBB::InvalidMoney) { top + one }
  end

  def test_configuration_rejects_amounts_above_the_bound
    assert_raises(RBBB::InvalidConfiguration) { build_configuration(opening_minor_units: BOUND + 1) }
    assert_raises(RBBB::InvalidConfiguration) { build_configuration(reserve_minor_units: BOUND + 1) }
    assert_raises(RBBB::InvalidConfiguration) do
      build_configuration(increments: [{from_minor_units: 0, amount_minor_units: BOUND + 1}])
    end
    assert_raises(RBBB::InvalidConfiguration) do
      build_configuration(increments: [
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: BOUND + 1, amount_minor_units: 1_000}
      ])
    end
  end

  def test_shared_integer_bound_matches_the_money_bound
    assert_equal BOUND, RBBB::MAX_SAFE_INTEGER
  end

  def test_configuration_rejects_extension_seconds_above_the_bound
    [BOUND + 1, 10**40].each do |seconds|
      error = assert_raises(RBBB::InvalidConfiguration) do
        build_configuration(extension: {trigger_window_seconds: seconds, duration_seconds: 300})
      end
      assert_match(/trigger window.*no greater than #{BOUND}/, error.message)

      error = assert_raises(RBBB::InvalidConfiguration) do
        build_configuration(extension: {trigger_window_seconds: 300, duration_seconds: seconds})
      end
      assert_match(/duration.*no greater than #{BOUND}/, error.message)
    end
  end

  def test_configuration_accepts_extension_seconds_at_the_bound
    configuration = build_configuration(extension: {trigger_window_seconds: BOUND, duration_seconds: BOUND})

    assert_equal BOUND, configuration.extension.fetch("trigger_window_seconds")
    assert_equal BOUND, configuration.extension.fetch("duration_seconds")
  end

  def test_configuration_accepts_amounts_at_the_bound
    configuration = build_configuration(
      opening_minor_units: BOUND,
      reserve_minor_units: BOUND,
      increments: [{from_minor_units: 0, amount_minor_units: BOUND}]
    )

    assert_equal BOUND, configuration.opening_minor_units
    assert_equal BOUND, configuration.reserve_minor_units
  end

  def test_engine_rejects_maximum_and_reserve_above_the_bound
    engine = RBBB::Engine.new(build_configuration)
    state = engine.initial_state

    too_large = engine.decide(state, place_bid("command-1", "bidder-a", BOUND + 1))
    assert_equal "invalid_maximum", too_large.rejection.fetch("reason")

    accepted = engine.decide(state, place_bid("command-2", "bidder-a", 50_000))
    state = engine.apply(state, accepted.events)
    reduction = engine.decide(state, {
      command_id: "command-3",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: 10**40,
      effective_at: "2026-09-01T12:12:00Z"
    })
    assert_equal "invalid_maximum", reduction.rejection.fetch("reason")

    reserve = engine.decide(state, {
      command_id: "command-4",
      type: "change_reserve",
      operator_id: "operator-1",
      reason: "seller_authorized_change",
      reserve_minor_units: BOUND + 1,
      effective_at: "2026-09-01T12:13:00Z"
    })
    assert_equal "invalid_reserve", reserve.rejection.fetch("reason")
  end

  def test_next_required_amount_saturates_at_the_bound
    engine = RBBB::Engine.new(build_configuration)
    state = engine.initial_state
    state = engine.apply(state, engine.decide(state, place_bid("command-1", "bidder-a", BOUND - 500)).events)
    decision = engine.decide(state, place_bid("command-2", "bidder-b", BOUND, at: "2026-09-01T12:11:00Z"))
    state = engine.apply(state, decision.events)

    assert decision.accepted?, decision.rejection.inspect
    assert_equal BOUND, state.standing_minor_units
    assert_equal BOUND, state.next_required_minor_units
    public_event = decision.events.find { |event| event.type == "standing_bid_changed" }
    assert_equal BOUND, public_event.to_h.fetch("next_required_minor_units")
  end

  def test_timestamp_accepts_millisecond_precision
    assert_equal "2026-09-01T12:59:59.999Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("2026-09-01T12:59:59.999Z"))
    assert_equal "2026-09-01T12:59:59.99Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("2026-09-01T12:59:59.990Z"))
    assert_equal "2026-09-01T12:59:59Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("2026-09-01T12:59:59.000Z"))
    assert_equal "2026-09-01T12:59:59.5Z", RBBB::Timestamp.dump(RBBB::Timestamp.parse("2026-09-01T13:59:59.5+01:00"))
  end

  def test_timestamp_rejects_precision_finer_than_a_millisecond
    assert_raises(ArgumentError) { RBBB::Timestamp.parse("2026-09-01T12:59:59.9999Z") }
    assert_raises(ArgumentError) { RBBB::Timestamp.parse("2026-09-01T12:59:59.999000Z") }
    assert_raises(ArgumentError) { RBBB::Timestamp.parse("2026-09-01T12:59:59.123456789Z") }
    assert_raises(ArgumentError) { RBBB::Timestamp.parse(Time.utc(2026, 9, 1, 12, 59, 59, 999_999)) }
    assert_equal "2026-09-01T12:59:59.999Z",
      RBBB::Timestamp.dump(RBBB::Timestamp.parse(Time.utc(2026, 9, 1, 12, 59, 59, 999_000)))
  end

  def test_engine_rejects_commands_with_sub_millisecond_authoritative_time
    engine = RBBB::Engine.new(build_configuration)
    decision = engine.decide(engine.initial_state,
      place_bid("command-1", "bidder-a", 50_000, at: "2026-09-01T12:10:00.000001Z"))

    assert_equal "invalid_command", decision.rejection.fetch("reason")
  end

  def test_configuration_rejects_sub_millisecond_schedule
    assert_raises(RBBB::InvalidConfiguration) { build_configuration(closes_at: "2026-09-01T13:00:00.0001Z") }
  end

  def test_extension_arithmetic_round_trips_at_millisecond_precision
    engine = RBBB::Engine.new(build_configuration(
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    ))
    decision = engine.decide(engine.initial_state,
      place_bid("command-1", "bidder-a", 50_000, at: "2026-09-01T12:57:30.250Z"))
    state = engine.apply(engine.initial_state, decision.events)

    assert_equal "2026-09-01T13:02:30.25Z", state.to_h.fetch("closes_at")
    assert_equal state.closes_at, RBBB::Timestamp.parse(state.to_h.fetch("closes_at"))
  end

  private

  def build_configuration(**overrides)
    RBBB::Configuration.new(**{
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z"
    }.merge(overrides))
  end

  def place_bid(command_id, bidder_id, maximum, at: "2026-09-01T12:10:00Z")
    {
      command_id: command_id,
      type: "place_bid",
      bidder_id: bidder_id,
      maximum_minor_units: maximum,
      effective_at: at
    }
  end
end
