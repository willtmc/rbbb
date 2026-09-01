# frozen_string_literal: true

require_relative "test_helper"

class TimedClosingTest < Minitest::Test
  def setup
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    )
    @engine = RBBB::Engine.new(configuration)
  end

  def test_bid_inside_trigger_window_resets_close_from_authoritative_time
    decision = place_bid(effective_at: "2026-09-01T12:55:00.001Z")
    state = @engine.apply(@engine.initial_state, decision.events)

    assert decision.accepted?
    assert_equal "2026-09-01T13:00:00.001Z", state.to_h.fetch("closes_at")
    closing_event = decision.events.find { |event| event.type == "closing_time_changed" }
    refute_nil closing_event
  end

  def test_bid_before_trigger_window_does_not_change_close
    decision = place_bid(effective_at: "2026-09-01T12:54:59Z")
    state = @engine.apply(@engine.initial_state, decision.events)

    assert decision.accepted?
    assert_equal "2026-09-01T13:00:00Z", state.to_h.fetch("closes_at")
    refute decision.events.any? { |event| event.type == "closing_time_changed" }
  end

  def test_scheduled_engine_rejects_missing_or_invalid_authoritative_time
    missing = place_bid(effective_at: nil)
    invalid = place_bid(effective_at: "not-a-time")

    assert_equal "invalid_command", missing.rejection.fetch("reason")
    assert_equal "invalid_command", invalid.rejection.fetch("reason")
  end

  def test_timestamp_round_trips_fractional_authoritative_time
    timestamp = RBBB::Timestamp.parse("2026-09-01T12:59:59.999000Z")

    assert_equal "2026-09-01T12:59:59.999Z", RBBB::Timestamp.dump(timestamp)
  end

  private

  def place_bid(effective_at:)
    @engine.decide(@engine.initial_state, {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000,
      effective_at: effective_at
    })
  end
end
