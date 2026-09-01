# frozen_string_literal: true

require_relative "test_helper"

class EngineTest < Minitest::Test
  def setup
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
    )
    @engine = RBBB::Engine.new(configuration)
  end

  def test_decision_is_deterministic_and_does_not_mutate_state
    state = @engine.initial_state
    command = {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000
    }

    first = @engine.decide(state, command)
    second = @engine.decide(state, command)

    assert_equal first.events.map(&:to_h), second.events.map(&:to_h)
    assert_equal 0, state.version
    assert_nil state.leader_id
  end

  def test_apply_rebuilds_state_from_events
    state = @engine.initial_state
    decision = @engine.decide(state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000
    })

    applied = @engine.apply(state, decision.events)

    assert_equal 1, applied.version
    assert_equal "bidder-a", applied.leader_id
    assert_equal 10_000, applied.standing_minor_units
  end

  def test_public_events_do_not_disclose_bidder_or_maximum
    decision = @engine.decide(@engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000
    })

    public_event = decision.events.find(&:public?).to_h

    refute public_event.key?("bidder_id")
    refute public_event.key?("leader_id")
    refute public_event.keys.any? { |key| key.include?("maximum") }
  end

  def test_apply_rejects_out_of_order_event_version
    state = @engine.initial_state
    event = RBBB::Event.new(
      type: "maximum_accepted",
      visibility: :privileged,
      data: {
        aggregate_version: 2,
        positions: {},
        leader_id: nil,
        standing_minor_units: nil,
        next_required_minor_units: 10_000
      }
    )

    assert_raises(RBBB::InvalidState) { @engine.apply(state, [event]) }
  end

  def test_rejects_stale_expected_version
    decision = @engine.decide(@engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000,
      expected_version: 2
    })

    assert decision.rejected?
    assert_equal "stale_aggregate_version", decision.rejection.fetch("reason")
  end

  def test_confidential_reserve_affects_price_without_becoming_leader
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: 100_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
    )
    engine = RBBB::Engine.new(configuration)

    decision = engine.decide(engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 150_000
    })
    state = engine.apply(engine.initial_state, decision.events)

    assert_equal "bidder-a", state.leader_id
    assert_equal 100_000, state.standing_minor_units
    assert_equal "reserve_met", state.reserve_status
  end

  def test_public_reserve_event_discloses_status_but_not_amount_or_maximum
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: 100_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
    )
    engine = RBBB::Engine.new(configuration)

    decision = engine.decide(engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 150_000
    })
    public_event = decision.events.find(&:public?).to_h

    assert_equal "reserve_met", public_event.fetch("reserve_status")
    refute public_event.keys.any? { |key| key.include?("reserve") && key != "reserve_status" }
    refute public_event.keys.any? { |key| key.include?("maximum") }
  end

  def test_competition_can_push_standing_amount_above_reserve
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: 100_000,
      increments: [
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: 100_000, amount_minor_units: 2_500}
      ]
    )
    engine = RBBB::Engine.new(configuration)
    state = engine.initial_state

    first = engine.decide(state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 150_000
    })
    state = engine.apply(state, first.events)
    second = engine.decide(state, {
      command_id: "command-2",
      type: "place_bid",
      bidder_id: "bidder-b",
      maximum_minor_units: 110_000
    })
    state = engine.apply(state, second.events)

    assert_equal "bidder-a", state.leader_id
    assert_equal 112_500, state.standing_minor_units
    assert_equal 115_000, state.next_required_minor_units
    assert_equal "reserve_met", state.reserve_status
  end

  def test_parses_timed_configuration_and_exposes_initial_schedule
    configuration = RBBB::Configuration.from_h({
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    })
    engine = RBBB::Engine.new(configuration)

    assert_equal "2026-09-01T12:00:00Z", RBBB::Timestamp.dump(configuration.opens_at)
    assert_equal "2026-09-01T13:00:00Z", RBBB::Timestamp.dump(configuration.closes_at)
    assert_equal 300, configuration.extension.fetch("duration_seconds")
    assert_equal "2026-09-01T13:00:00Z", engine.initial_state.to_h.fetch("closes_at")
  end
end
