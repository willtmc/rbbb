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

  def test_extend_on_void_defaults_to_false_and_matches_explicit_false_byte_for_byte
    default_engine = soft_close_engine
    explicit_false_engine = soft_close_engine(extend_on_void: false)

    assert_equal false, default_engine.configuration.extension.fetch("extend_on_void")
    assert_equal false, explicit_false_engine.configuration.extension.fetch("extend_on_void")

    default_state = place(default_engine, default_engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000,
      "2026-09-01T12:10:00Z")
    default_state = place(default_engine, default_state, "command-2", "bid-b", "bidder-b", 50_000,
      "2026-09-01T12:11:00Z")
    default_decision = void(default_engine, default_state, bid_id: "bid-b", effective_at: "2026-09-01T12:58:00Z")
    default_after = default_engine.apply(default_state, default_decision.events)

    false_state = place(explicit_false_engine, explicit_false_engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000,
      "2026-09-01T12:10:00Z")
    false_state = place(explicit_false_engine, false_state, "command-2", "bid-b", "bidder-b", 50_000,
      "2026-09-01T12:11:00Z")
    false_decision = void(explicit_false_engine, false_state, bid_id: "bid-b", effective_at: "2026-09-01T12:58:00Z")
    false_after = explicit_false_engine.apply(false_state, false_decision.events)

    assert_equal CLOSES_AT, default_after.to_h.fetch("closes_at")
    refute default_decision.events.any? { |candidate| candidate.type == "closing_time_changed" }
    assert_equal default_decision.events.map(&:to_h), false_decision.events.map(&:to_h)
    assert_equal default_after.to_h, false_after.to_h
  end

  def test_extend_on_void_rejects_non_boolean_values
    ["true", 1, nil, []].each do |invalid|
      error = assert_raises(RBBB::InvalidConfiguration) do
        RBBB::Configuration.new(
          currency: "USD",
          opening_minor_units: 10_000,
          increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
          opens_at: OPENS_AT,
          closes_at: CLOSES_AT,
          extension: {trigger_window_seconds: 300, duration_seconds: 300, extend_on_void: invalid}
        )
      end
      assert_match(/extend_on_void must be a boolean/, error.message)
    end
  end

  def test_extend_on_void_extends_when_void_changes_leader_and_price_inside_window
    engine = soft_close_engine(extend_on_void: true)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 50_000,
      "2026-09-01T12:11:00Z")

    decision = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:58:00.25Z")
    recomputed = engine.apply(state, decision.events)

    assert_equal "bidder-a", recomputed.leader_id
    assert_equal 10_000, recomputed.standing_minor_units
    assert_equal "2026-09-01T13:03:00.25Z", recomputed.to_h.fetch("closes_at")

    closing_event = decision.events.find { |candidate| candidate.type == "closing_time_changed" }
    refute_nil closing_event
    assert closing_event.public?
    assert_equal "2026-09-01T13:03:00.25Z", closing_event.data.fetch("closes_at")
    assert_equal recomputed.version, closing_event.data.fetch("aggregate_version")
    assert_equal "2026-09-01T13:03:00.25Z", event(decision, "bid_voided").fetch("closes_at")
  end

  def test_extend_on_void_extends_when_void_changes_only_price_inside_window
    engine = soft_close_engine(extend_on_void: true)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 30_000,
      "2026-09-01T12:11:00Z")

    decision = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:58:00Z")
    recomputed = engine.apply(state, decision.events)

    assert_equal "bidder-a", recomputed.leader_id
    assert_equal 10_000, recomputed.standing_minor_units
    assert_equal "2026-09-01T13:03:00Z", recomputed.to_h.fetch("closes_at")
    assert decision.events.any? { |candidate| candidate.public? && candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_extends_when_void_changes_only_leader_inside_window
    engine = RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 1_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT,
      extension: {trigger_window_seconds: 300, duration_seconds: 300, extend_on_void: true}
    ))
    state = place(engine, engine.initial_state, "command-1", "x-1", "bidder-x", 2_000, "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "y-1", "bidder-y", 2_000, "2026-09-01T12:11:00Z")
    state = place(engine, state, "command-3", "x-2", "bidder-x", 3_000, "2026-09-01T12:12:00Z")
    reduce_x = engine.decide(state, {command_id: "command-4", type: "reduce_maximum", bidder_id: "bidder-x",
                                     maximum_minor_units: 2_000, effective_at: "2026-09-01T12:13:00Z"})
    state = engine.apply(state, reduce_x.events)
    state = place(engine, state, "command-5", "y-2", "bidder-y", 4_500, "2026-09-01T12:14:00Z")
    reduce_y = engine.decide(state, {command_id: "command-6", type: "reduce_maximum", bidder_id: "bidder-y",
                                     maximum_minor_units: 2_600, effective_at: "2026-09-01T12:15:00Z"})
    state = engine.apply(state, reduce_y.events)
    state = place(engine, state, "command-7", "y-3", "bidder-y", 2_700, "2026-09-01T12:16:00Z")
    state = place(engine, state, "command-8", "w-1", "bidder-w", 4_500, "2026-09-01T12:17:00Z")
    state = place(engine, state, "command-9", "y-4", "bidder-y", 4_000, "2026-09-01T12:18:00Z")

    assert_equal "bidder-w", state.leader_id
    assert_equal 4_000, state.standing_minor_units

    decision = void(engine, state, bid_id: "x-2", effective_at: "2026-09-01T12:58:00Z")
    recomputed = engine.apply(state, decision.events)

    assert_equal "bidder-y", recomputed.leader_id
    assert_equal 4_000, recomputed.standing_minor_units
    assert_equal "2026-09-01T13:03:00Z", recomputed.to_h.fetch("closes_at")
    assert decision.events.any? { |candidate| candidate.public? && candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_extends_when_voiding_only_bid_inside_window
    engine = soft_close_engine(extend_on_void: true)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")

    decision = void(engine, state, bid_id: "bid-a", effective_at: "2026-09-01T12:58:00Z")
    recomputed = engine.apply(state, decision.events)

    assert_nil recomputed.leader_id
    assert_nil recomputed.standing_minor_units
    assert_equal "2026-09-01T13:03:00Z", recomputed.to_h.fetch("closes_at")
    assert decision.events.any? { |candidate| candidate.public? && candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_does_not_extend_when_neither_leader_nor_price_changes
    engine = soft_close_engine(extend_on_void: true)

    # Case 1: voiding a losing bid that did not set the standing price.
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 50_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 20_000,
      "2026-09-01T12:11:00Z")
    state = place(engine, state, "command-3", "bid-c", "bidder-c", 30_000,
      "2026-09-01T12:12:00Z")

    losing_void = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:58:00Z")
    after_losing = engine.apply(state, losing_void.events)

    assert_equal "bidder-a", after_losing.leader_id
    assert_equal 31_000, after_losing.standing_minor_units
    assert_equal CLOSES_AT, after_losing.to_h.fetch("closes_at")
    refute losing_void.events.any? { |candidate| candidate.type == "closing_time_changed" }

    # Case 2: voiding the leader's unexecuted maximum increase.
    raised = place(engine, after_losing, "command-4", "bid-a-2", "bidder-a", 80_000,
      "2026-09-01T12:58:30Z")
    raise_void = void(engine, raised, bid_id: "bid-a-2", effective_at: "2026-09-01T12:59:00Z")
    after_raise_void = engine.apply(raised, raise_void.events)

    assert_equal "bidder-a", after_raise_void.leader_id
    assert_equal 31_000, after_raise_void.standing_minor_units
    assert_equal CLOSES_AT, after_raise_void.to_h.fetch("closes_at")
    refute raise_void.events.any? { |candidate| candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_does_not_extend_outside_soft_close_window
    engine = soft_close_engine(extend_on_void: true)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 50_000,
      "2026-09-01T12:11:00Z")

    decision = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:54:59.999Z")
    recomputed = engine.apply(state, decision.events)

    assert_equal "bidder-a", recomputed.leader_id
    assert_equal 10_000, recomputed.standing_minor_units
    assert_equal CLOSES_AT, recomputed.to_h.fetch("closes_at")
    refute decision.events.any? { |candidate| candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_never_shortens_closing_time
    engine = soft_close_engine(trigger_window_seconds: 300, duration_seconds: 60, extend_on_void: true)
    state = place(engine, engine.initial_state, "command-1", "bid-a", "bidder-a", 30_000,
      "2026-09-01T12:10:00Z")
    state = place(engine, state, "command-2", "bid-b", "bidder-b", 50_000,
      "2026-09-01T12:11:00Z")

    early_in_window = void(engine, state, bid_id: "bid-b", effective_at: "2026-09-01T12:56:00Z")
    after_early = engine.apply(state, early_in_window.events)

    assert_equal CLOSES_AT, after_early.to_h.fetch("closes_at")
    refute early_in_window.events.any? { |candidate| candidate.type == "closing_time_changed" }

    late_in_window = void(engine, after_early, bid_id: "bid-a", effective_at: "2026-09-01T12:59:30Z")
    after_late = engine.apply(after_early, late_in_window.events)

    assert_equal "2026-09-01T13:00:30Z", after_late.to_h.fetch("closes_at")
    assert late_in_window.events.any? { |candidate| candidate.public? && candidate.type == "closing_time_changed" }
  end

  def test_extend_on_void_replay_and_checkpoint_reproduce_exact_closing_time
    config = RBBB::Configuration.from_h(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT,
      extension: {trigger_window_seconds: 300, duration_seconds: 300, extend_on_void: true}
    )
    engine = RBBB::Engine.new(config)
    commands = [
      {command_id: "command-1", type: "place_bid", bid_id: "bid-a", bidder_id: "bidder-a",
       maximum_minor_units: 30_000, effective_at: "2026-09-01T12:10:00Z"},
      {command_id: "command-2", type: "place_bid", bid_id: "bid-b", bidder_id: "bidder-b",
       maximum_minor_units: 50_000, effective_at: "2026-09-01T12:11:00Z"},
      {command_id: "command-3", type: "void_bid", bid_id: "bid-b", operator_id: "operator-1",
       reason: "bidder_entry_error", notification_policy: "affected", effective_at: "2026-09-01T12:58:00Z"},
      {command_id: "command-4", type: "place_bid", bid_id: "bid-c", bidder_id: "bidder-c",
       maximum_minor_units: 40_000, effective_at: "2026-09-01T13:01:00Z"}
    ]

    state = engine.initial_state
    recorded_event_batches = []
    commands.each do |command|
      decision = engine.decide(state, command)
      assert decision.accepted?, decision.rejection.inspect
      recorded_event_batches << decision.events
      state = engine.apply(state, decision.events)
    end

    assert_equal "2026-09-01T13:06:00Z", state.to_h.fetch("closes_at")
    assert_equal "bidder-c", state.leader_id
    assert_equal 31_000, state.standing_minor_units

    # Event-stream replay reproduces the exact same state and closing time.
    replayed_from_events = recorded_event_batches.reduce(engine.initial_state) do |acc, batch|
      engine.apply(acc, batch)
    end
    assert_equal state.to_h, replayed_from_events.to_h

    # Command-stream replay on a fresh engine reproduces the exact same closing time.
    fresh_engine = RBBB::Engine.new(config)
    replayed_from_commands = commands.reduce(fresh_engine.initial_state) do |acc, command|
      decision = fresh_engine.decide(acc, command)
      assert decision.accepted?, decision.rejection.inspect
      fresh_engine.apply(acc, decision.events)
    end
    assert_equal state.to_h, replayed_from_commands.to_h

    # Checkpoint restore from the bid_voided transition event carries the void-extended close.
    void_transition = recorded_event_batches.fetch(2).find { |candidate| candidate.type == "bid_voided" }
    restored = fresh_engine.restore(void_transition)
    assert_equal "2026-09-01T13:03:00Z", restored.to_h.fetch("closes_at")

    continued_decision = fresh_engine.decide(restored, commands.last)
    assert continued_decision.accepted?, continued_decision.rejection.inspect
    continued_state = fresh_engine.apply(restored, continued_decision.events)
    assert_equal state.to_h, continued_state.to_h
  end

  private

  def soft_close_engine(trigger_window_seconds: 300, duration_seconds: 300, reserve_minor_units: nil,
    extend_on_void: :omit)
    extension = {
      trigger_window_seconds: trigger_window_seconds,
      duration_seconds: duration_seconds
    }
    extension[:extend_on_void] = extend_on_void unless extend_on_void == :omit
    RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: reserve_minor_units,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: OPENS_AT,
      closes_at: CLOSES_AT,
      extension: extension
    ))
  end

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
