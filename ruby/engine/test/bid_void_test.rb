# frozen_string_literal: true

require_relative "test_helper"

class BidVoidTest < Minitest::Test
  OPENS_AT = "2026-09-01T12:00:00Z"
  CLOSES_AT = "2026-09-01T13:00:00Z"
  BID_AT = "2026-09-01T12:30:00Z"

  def setup
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT
    )
    @engine = RBBB::Engine.new(configuration)
  end

  def test_void_preserves_bid_history_and_recomputes_executed_floor
    state = competed_state
    decision = void(@engine, state, bid_id: "bid-b")
    recomputed = @engine.apply(state, decision.events)

    assert decision.accepted?
    assert_equal 2, recomputed.authorization_history.length
    assert_equal "bid-b", recomputed.bid_record_for("bid-b").fetch("bid_id")
    assert_equal ["bid-b"], recomputed.voided_bid_ids
    assert_equal 10_000, recomputed.standing_minor_units
    assert_equal 10_000, recomputed.position_for("bidder-a").executed_minor_units
    assert_nil recomputed.position_for("bidder-b")
  end

  def test_voided_competitor_no_longer_binds_reduction_floor
    state = competed_state
    decision = void(@engine, state, bid_id: "bid-b")
    state = @engine.apply(state, decision.events)

    reduction = @engine.decide(state, {
      command_id: "command-reduce",
      type: "reduce_maximum",
      bidder_id: "bidder-a",
      effective_at: BID_AT,
      maximum_minor_units: 10_000
    })

    assert reduction.accepted?, reduction.rejection.inspect
  end

  def test_voiding_only_bid_returns_to_empty_pricing_state
    state = place(@engine, @engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000)
    decision = void(@engine, state, bid_id: "bid-a")
    recomputed = @engine.apply(state, decision.events)

    assert_nil recomputed.leader_id
    assert_nil recomputed.standing_minor_units
    assert_equal 10_000, recomputed.next_required_minor_units
    assert_empty recomputed.positions
  end

  def test_voiding_later_maximum_restores_same_bidders_prior_authority
    state = place(@engine, @engine.initial_state, "command-1", "bid-a-1", "bidder-a", 20_000)
    state = place(@engine, state, "command-2", "bid-a-2", "bidder-a", 50_000)
    state = place(@engine, state, "command-3", "bid-b", "bidder-b", 15_000)

    decision = void(@engine, state, bid_id: "bid-a-2")
    recomputed = @engine.apply(state, decision.events)

    assert_equal "bidder-a", recomputed.leader_id
    assert_equal 20_000, recomputed.position_for("bidder-a").maximum_minor_units
    assert_equal 16_000, recomputed.standing_minor_units
  end

  def test_public_void_event_does_not_disclose_private_details
    decision = void(@engine, competed_state, bid_id: "bid-b")
    public_event = decision.events.find(&:public?).to_h

    assert_equal "standing_bid_changed", public_event.fetch("type")
    refute public_event.key?("bidder_id")
    refute public_event.key?("leader_id")
    refute public_event.key?("operator_id")
    refute public_event.key?("reason")
    refute public_event.keys.any? { |key| key.include?("maximum") }
  end

  def test_affected_policy_notifies_removed_bidder_when_leader_is_unchanged
    decision = void(@engine, competed_state, bid_id: "bid-b", policy: "affected")
    notification = event(decision, "notification_requested")

    assert_equal "bid-b", notification.fetch("bid_id")
    assert_equal "bidder_entry_error", notification.fetch("reason")
    assert_equal ["bidder-b"], notification.fetch("bidder_ids")
  end

  def test_affected_policy_notifies_both_bidders_when_leader_changes
    state = place(@engine, @engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000)
    state = place(@engine, state, "command-2", "bid-b", "bidder-b", 50_000)

    decision = void(@engine, state, bid_id: "bid-b", policy: "affected")
    public_event = decision.events.find(&:public?).to_h
    notification = event(decision, "notification_requested")

    assert_equal true, public_event.fetch("leader_changed")
    assert_equal ["bidder-a", "bidder-b"], notification.fetch("bidder_ids")
  end

  def test_notification_policies_have_deterministic_recipients
    state = competed_state

    assert_equal ["bidder-b"], notification_ids(state, "removed_bidder")
    assert_equal ["bidder-a", "bidder-b"], notification_ids(state, "all_bidders")
    assert_empty notification_ids(state, "none")
  end

  def test_missing_unknown_and_already_voided_bids_are_rejected
    state = competed_state
    missing = @engine.decide(state, {
      command_id: "command-void-missing",
      type: "void_bid",
      operator_id: "operator-1",
      reason: "bidder_entry_error",
      notification_policy: "affected",
      effective_at: BID_AT
    })
    unknown = void(@engine, state, bid_id: "bid-unknown")
    first = void(@engine, state, bid_id: "bid-b")
    state = @engine.apply(state, first.events)
    duplicate = void(@engine, state, bid_id: "bid-b")

    assert_equal "invalid_command", missing.rejection.fetch("reason")
    assert_equal "bid_not_found", unknown.rejection.fetch("reason")
    assert_equal "bid_already_voided", duplicate.rejection.fetch("reason")
  end

  def test_invalid_notification_policy_is_rejected
    decision = void(@engine, competed_state, bid_id: "bid-b", policy: "email_everyone")

    assert_equal "invalid_notification_policy", decision.rejection.fetch("reason")
  end

  def test_void_does_not_reverse_a_prior_soft_close_extension
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    )
    engine = RBBB::Engine.new(configuration)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 30_000,
      "2026-09-01T12:58:00Z")

    decision = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:59:00Z")
    recomputed = engine.apply(state, decision.events)

    assert_equal "2026-09-01T13:03:00Z", recomputed.to_h.fetch("closes_at")
    refute decision.events.any? { |candidate| candidate.type == "closing_time_changed" }
  end

  def test_bid_cannot_be_voided_at_or_after_close
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z"
    )
    engine = RBBB::Engine.new(configuration)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")

    decision = void(engine, state, bid_id: "bid-a", effective_at: "2026-09-01T13:00:00Z")

    assert_equal "bidding_closed", decision.rejection.fetch("reason")
  end

  private

  def competed_state
    state = place(@engine, @engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000)
    place(@engine, state, "command-2", "bid-b", "bidder-b", 30_000)
  end

  def place(engine, state, command_id, bid_id, bidder_id, maximum, effective_at = BID_AT)
    decision = engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bid_id: bid_id,
      bidder_id: bidder_id,
      maximum_minor_units: maximum,
      effective_at: effective_at
    })
    assert decision.accepted?, decision.rejection.inspect
    engine.apply(state, decision.events)
  end

  def void(engine, state, bid_id:, policy: "affected", effective_at: BID_AT)
    engine.decide(state, {
      command_id: "command-void-#{bid_id}",
      type: "void_bid",
      bid_id: bid_id,
      operator_id: "operator-1",
      reason: "bidder_entry_error",
      notification_policy: policy,
      effective_at: effective_at
    })
  end

  def event(decision, type)
    decision.events.find { |candidate| candidate.type == type }.to_h
  end

  def notification_ids(state, policy)
    event(void(@engine, state, bid_id: "bid-b", policy: policy),
      "notification_requested").fetch("bidder_ids")
  end
end
