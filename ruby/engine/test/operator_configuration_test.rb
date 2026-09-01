# frozen_string_literal: true

require_relative "test_helper"

class OperatorConfigurationTest < Minitest::Test
  def test_operator_may_set_raise_lower_and_remove_reserve_before_first_bid
    engine = build_engine(reserve: nil)
    state = engine.initial_state

    state = apply(engine, state, change_reserve(engine, state, 120_000, "command-set"))
    assert_equal 120_000, state.reserve_minor_units
    assert_equal "reserve_not_met", state.reserve_status

    state = apply(engine, state, change_reserve(engine, state, 150_000, "command-raise"))
    state = apply(engine, state, change_reserve(engine, state, 90_000, "command-lower"))
    state = apply(engine, state, change_reserve(engine, state, nil, "command-remove"))

    assert_nil state.reserve_minor_units
    assert_nil state.reserve_status
    assert_equal 4, state.reserve_history.length
    refute state.bidding_started?
  end

  def test_reserve_change_is_privately_audited_without_disclosing_amount
    engine = build_engine(reserve: 100_000)
    state = place(engine, engine.initial_state, "command-bid", "bidder-a", 80_000)

    decision = change_reserve(engine, state, 70_000, "command-reserve")
    audit = event(decision, "reserve_changed", :privileged)
    public_event = event(decision, "reserve_status_changed", :public)

    assert_equal 100_000, audit.fetch("old_reserve_minor_units")
    assert_equal 70_000, audit.fetch("new_reserve_minor_units")
    assert_equal "operator-1", audit.fetch("operator_id")
    assert_equal "seller_authorized_change", audit.fetch("reason")
    assert_equal "reserve_met", public_event.fetch("reserve_status")
    refute public_event.key?("operator_id")
    refute public_event.key?("reason")
    refute public_event.keys.any? { |key| key.include?("minor_units") }
  end

  def test_later_bids_use_current_reserve_instead_of_initial_configuration
    set_engine = build_engine(reserve: nil)
    set_state = apply(
      set_engine,
      set_engine.initial_state,
      change_reserve(set_engine, set_engine.initial_state, 100_000, "command-set")
    )
    set_state = place(set_engine, set_state, "command-bid-set", "bidder-a", 150_000)

    remove_engine = build_engine(reserve: 100_000)
    remove_state = apply(
      remove_engine,
      remove_engine.initial_state,
      change_reserve(remove_engine, remove_engine.initial_state, nil, "command-remove")
    )
    remove_state = place(
      remove_engine,
      remove_state,
      "command-bid-remove",
      "bidder-a",
      150_000
    )

    assert_equal 100_000, set_state.standing_minor_units
    assert_equal "reserve_met", set_state.reserve_status
    assert_equal 10_000, remove_state.standing_minor_units
    assert_nil remove_state.reserve_status
  end

  def test_operator_may_remove_but_not_set_or_raise_reserve_after_bidding_starts
    no_reserve_engine = build_engine(reserve: nil)
    no_reserve_state = place(
      no_reserve_engine,
      no_reserve_engine.initial_state,
      "command-bid-a",
      "bidder-a",
      50_000
    )
    set = change_reserve(no_reserve_engine, no_reserve_state, 40_000, "command-set")

    reserve_engine = build_engine(reserve: 100_000)
    reserve_state = place(
      reserve_engine,
      reserve_engine.initial_state,
      "command-bid-b",
      "bidder-b",
      150_000
    )
    raise_reserve = change_reserve(reserve_engine, reserve_state, 120_000, "command-raise")
    remove = change_reserve(reserve_engine, reserve_state, nil, "command-remove")
    removed = apply(reserve_engine, reserve_state, remove)

    assert_equal "reserve_may_not_increase_after_first_bid", set.rejection.fetch("reason")
    assert_equal "reserve_may_not_increase_after_first_bid",
      raise_reserve.rejection.fetch("reason")
    assert remove.accepted?
    assert_nil removed.reserve_minor_units
    assert_nil removed.reserve_status
  end

  def test_reserve_history_preserves_executed_floor_during_later_void_replay
    engine = build_engine(reserve: 100_000)
    state = place(engine, engine.initial_state, "command-a", "bidder-a", 150_000,
      bid_id: "bid-a")
    state = apply(engine, state, change_reserve(engine, state, 80_000, "command-reserve"))
    state = place(engine, state, "command-b", "bidder-b", 110_000, bid_id: "bid-b")

    void = engine.decide(state, {
      command_id: "command-void",
      type: "void_bid",
      bid_id: "bid-b",
      operator_id: "operator-1",
      reason: "bidder_entry_error",
      notification_policy: "affected",
      effective_at: "2026-09-01T12:30:00Z"
    })
    recomputed = apply(engine, state, void)

    assert_equal 80_000, recomputed.reserve_minor_units
    assert_equal 100_000, recomputed.standing_minor_units
    assert_equal 100_000, recomputed.position_for("bidder-a").executed_minor_units

    reduction = engine.decide(recomputed, {
      command_id: "command-reduce",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      maximum_minor_units: 99_000,
      effective_at: "2026-09-01T12:31:00Z"
    })
    assert_equal "maximum_below_executed_amount", reduction.rejection.fetch("reason")
  end

  def test_voiding_every_bid_does_not_restore_pre_bid_operator_permissions
    engine = build_engine(reserve: nil)
    state = place(engine, engine.initial_state, "command-bid", "bidder-a", 50_000,
      bid_id: "bid-a")
    void = engine.decide(state, {
      command_id: "command-void",
      type: "void_bid",
      bid_id: "bid-a",
      operator_id: "operator-1",
      reason: "bidder_entry_error",
      notification_policy: "affected",
      effective_at: "2026-09-01T12:20:00Z"
    })
    state = apply(engine, state, void)

    reserve = change_reserve(engine, state, 40_000, "command-reserve")
    shorten = change_close(
      engine,
      state,
      "2026-09-01T12:30:00Z",
      "command-shorten",
      effective_at: "2026-09-01T12:21:00Z"
    )

    assert_empty state.positions
    assert state.bidding_started?
    assert_equal "reserve_may_not_increase_after_first_bid", reserve.rejection.fetch("reason")
    assert_equal "closing_time_may_not_shorten_after_first_bid",
      shorten.rejection.fetch("reason")
  end

  def test_operator_may_move_close_earlier_or_later_before_first_bid
    engine = build_engine
    state = engine.initial_state

    earlier = change_close(engine, state, "2026-09-01T12:30:00Z", "command-earlier")
    state = apply(engine, state, earlier)
    later = change_close(engine, state, "2026-09-01T14:00:00Z", "command-later",
      effective_at: "2026-09-01T12:11:00Z")
    state = apply(engine, state, later)

    assert_equal "2026-09-01T14:00:00Z", state.to_h.fetch("closes_at")
    assert_equal "2026-09-01T12:30:00Z",
      event(later, "closing_time_changed", :privileged).fetch("old_closes_at")
  end

  def test_operator_schedule_audit_is_private_and_public_event_is_safe
    engine = build_engine
    state = engine.initial_state
    decision = change_close(engine, state, "2026-09-01T14:00:00Z", "command-close")
    audit = event(decision, "closing_time_changed", :privileged)
    public_event = event(decision, "closing_time_changed", :public)

    assert_equal "operator-1", audit.fetch("operator_id")
    assert_equal "seller_authorized_change", audit.fetch("reason")
    assert_equal "2026-09-01T13:00:00Z", public_event.fetch("old_closes_at")
    assert_equal "2026-09-01T14:00:00Z", public_event.fetch("closes_at")
    refute public_event.key?("operator_id")
    refute public_event.key?("reason")
  end

  def test_closed_bidding_unit_cannot_be_reopened
    engine = build_engine
    state = engine.initial_state

    decision = change_close(
      engine,
      state,
      "2026-09-01T14:00:00Z",
      "command-reopen",
      effective_at: "2026-09-01T13:00:00Z"
    )

    assert_equal "bidding_closed", decision.rejection.fetch("reason")
  end

  def test_closing_time_must_be_after_authoritative_time_and_opening
    engine = build_engine
    state = engine.initial_state

    at_effective_time = change_close(
      engine,
      state,
      "2026-09-01T12:10:00Z",
      "command-now"
    )
    before_open = change_close(
      engine,
      state,
      "2026-09-01T11:59:00Z",
      "command-before-open"
    )
    invalid = change_close(engine, state, "not-a-time", "command-invalid")

    assert_equal "invalid_closing_time", at_effective_time.rejection.fetch("reason")
    assert_equal "invalid_closing_time", before_open.rejection.fetch("reason")
    assert_equal "invalid_closing_time", invalid.rejection.fetch("reason")
  end

  def test_operator_identity_reason_and_reserve_value_are_validated
    engine = build_engine
    state = engine.initial_state
    missing_reason = engine.decide(state, {
      command_id: "command-reserve",
      type: "change_reserve",
      operator_id: "operator-1",
      reserve_minor_units: 80_000,
      effective_at: "2026-09-01T12:10:00Z"
    })
    missing_operator = engine.decide(state, {
      command_id: "command-close",
      type: "change_closing_time",
      closes_at: "2026-09-01T14:00:00Z",
      reason: "seller_authorized_change",
      effective_at: "2026-09-01T12:10:00Z"
    })
    invalid_reserve = change_reserve(engine, state, -1, "command-negative")

    assert_equal "invalid_command", missing_reason.rejection.fetch("reason")
    assert_equal "invalid_command", missing_operator.rejection.fetch("reason")
    assert_equal "invalid_reserve", invalid_reserve.rejection.fetch("reason")
  end

  def test_apply_rejects_reserve_audit_that_does_not_match_current_state
    engine = build_engine(reserve: 100_000)
    state = engine.initial_state
    decision = change_reserve(engine, state, 80_000, "command-reserve")
    transition = decision.events.find(&:privileged?)
    tampered = RBBB::Event.new(
      type: transition.type,
      visibility: transition.visibility,
      data: transition.data.merge("old_reserve_minor_units" => 90_000)
    )

    assert_raises(RBBB::InvalidState) { engine.apply(state, [tampered]) }
  end

  private

  def build_engine(reserve: nil)
    RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: reserve,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z"
    ))
  end

  def place(engine, state, command_id, bidder_id, maximum, bid_id: command_id)
    decision = engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bid_id: bid_id,
      bidder_id: bidder_id,
      maximum_minor_units: maximum,
      effective_at: "2026-09-01T12:10:00Z"
    })
    apply(engine, state, decision)
  end

  def change_reserve(engine, state, reserve, command_id)
    engine.decide(state, {
      command_id: command_id,
      type: "change_reserve",
      operator_id: "operator-1",
      reserve_minor_units: reserve,
      reason: "seller_authorized_change",
      effective_at: "2026-09-01T12:20:00Z"
    })
  end

  def change_close(engine, state, closes_at, command_id, effective_at: "2026-09-01T12:10:00Z")
    engine.decide(state, {
      command_id: command_id,
      type: "change_closing_time",
      operator_id: "operator-1",
      closes_at: closes_at,
      reason: "seller_authorized_change",
      effective_at: effective_at
    })
  end

  def apply(engine, state, decision)
    assert decision.accepted?, decision.rejection.inspect
    engine.apply(state, decision.events)
  end

  def event(decision, type, visibility)
    decision.events.find do |candidate|
      candidate.type == type && candidate.visibility == visibility
    end.to_h
  end
end
