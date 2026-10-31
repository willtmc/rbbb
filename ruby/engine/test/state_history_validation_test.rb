# frozen_string_literal: true

require_relative "test_helper"

class StateHistoryValidationTest < Minitest::Test
  def setup
    engine = RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD", opening_minor_units: 100, reserve_minor_units: 1_000,
      increments: [{from_minor_units: 0, amount_minor_units: 100}],
      opens_at: "2026-01-01T00:00:00Z", closes_at: "2026-01-02T00:00:00Z"
    ))
    state = engine.initial_state
    [
      {type: "place_bid", bidder_id: "bidder-a", bid_id: "bid-a", maximum_minor_units: 2_000},
      {type: "place_bid", bidder_id: "bidder-b", bid_id: "bid-b", maximum_minor_units: 1_500},
      {type: "change_reserve", operator_id: "operator", reason: "synthetic", reserve_minor_units: 900},
      {type: "change_reserve", operator_id: "operator", reason: "synthetic", reserve_minor_units: 800}
    ].each_with_index do |command, index|
      decision = engine.decide(state, command.merge(command_id: "command-#{index}",
        effective_at: "2026-01-01T12:00:00Z"))
      raise "invalid synthetic fixture" if decision.rejected?

      state = engine.apply(state, decision.events)
    end
    @snapshot = state.to_h
  end

  def test_valid_history_with_and_without_reserve_changes_round_trips
    assert_equal @snapshot, RBBB::State.from_h(@snapshot).to_h
    @snapshot["reserve_history"] = []
    assert_equal @snapshot, RBBB::State.from_h(@snapshot).to_h
  end

  def test_authorization_types_remain_an_exact_allowlist
    entry = @snapshot.fetch("authorization_history").last
    entry["type"] = "maximum_reduced"
    entry.delete("bid_id")
    assert_equal @snapshot, RBBB::State.from_h(@snapshot).to_h

    ["", "PLACE_BID", "place_bid ", "reduce_maximum", nil].each do |type|
      entry["type"] = type
      assert_invalid("authorization type is invalid")
    end
  end

  def test_empty_reserve_history_does_not_bypass_authorization_validation
    @snapshot["reserve_history"] = []
    assert_authorization_errors
  end

  def test_nonempty_reserve_history_preserves_authorization_validation
    assert_authorization_errors
  end

  def test_reserve_order_range_and_cross_history_collisions_are_validated
    history = @snapshot.fetch("reserve_history")
    [[0, 4], [3, 5], ["3", 4]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("reserve change priority must belong to the event stream")
    end
    [[4, 3], [3, 3]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("reserve change priorities must be unique and ordered")
    end
    [[1, 4], [2, 4]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("state history priorities must be unique")
    end
    set_priorities(history, [3, 4])
    assert_equal @snapshot, RBBB::State.from_h(@snapshot).to_h
  end

  def test_reserve_values_continuity_and_current_value_remain_validated
    history = @snapshot.fetch("reserve_history")
    history.first["old_reserve_minor_units"] = -1
    assert_invalid("reserve change values must be non-negative integers or nil")
    history.first["old_reserve_minor_units"] = 1_000
    history.last["old_reserve_minor_units"] = 700
    assert_invalid("reserve change history must be continuous")
    history.last["old_reserve_minor_units"] = 900
    history.last["new_reserve_minor_units"] = 700
    assert_invalid("current reserve must match reserve change history")
  end

  private

  def assert_authorization_errors
    history = @snapshot.fetch("authorization_history")
    [["1", 2], [1, nil]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("authorization priority must belong to the event stream")
    end
    [[2, 1], [1, 1]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("authorization priorities must be unique and ordered")
    end
    [[0, 2], [1, 5]].each do |priorities|
      set_priorities(history, priorities)
      assert_invalid("authorization priority must belong to the event stream")
    end
    set_priorities(history, [1, 2])
    history.last["bid_id"] = "bid-a"
    assert_invalid("bid IDs must be unique")
    history.last["bid_id"] = "bid-b"
    history.last["maximum_minor_units"] = -1
    assert_invalid("authorization maximum must be a non-negative integer")
    history.last["maximum_minor_units"] = 1_500
    @snapshot["voided_bid_ids"] = ["missing-bid"]
    assert_invalid("voided bid IDs must refer to accepted bids")
    @snapshot["voided_bid_ids"] = ["bid-b", "bid-b"]
    assert_invalid("voided bid IDs must be unique")
  end

  def set_priorities(history, priorities)
    history.zip(priorities).each { |entry, priority| entry["priority"] = priority }
  end

  def assert_invalid(message)
    error = assert_raises(RBBB::InvalidState) { RBBB::State.from_h(@snapshot) }
    assert_equal message, error.message
  end
end
