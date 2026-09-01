# frozen_string_literal: true

require_relative "test_helper"

class ClosingOutcomeTest < Minitest::Test
  def test_sale_records_private_winner_without_public_identity
    engine = build_engine
    state = place(engine, engine.initial_state, maximum: 50_000)
    decision = close(engine, state)
    closed = apply(engine, state, decision)
    audit = event(decision, :privileged)
    public_event = event(decision, :public)

    assert_equal "closed", closed.status
    assert_equal "sold", closed.result
    assert_equal "bidder-a", closed.winner_id
    assert_equal 10_000, closed.winning_minor_units
    assert_equal "bidder-a", audit.fetch("winner_id")
    assert_equal 10_000, audit.fetch("winning_minor_units")
    assert_equal "sold", public_event.fetch("result")
    assert_equal 10_000, public_event.fetch("winning_minor_units")
    refute public_event.key?("winner_id")
    refute public_event.key?("leader_id")
    refute public_event.keys.any? { |key| key.include?("maximum") }
  end

  def test_reserve_met_bid_closes_as_sale
    engine = build_engine(reserve: 100_000)
    state = place(engine, engine.initial_state, maximum: 150_000)
    closed = apply(engine, state, close(engine, state))

    assert_equal "sold", closed.result
    assert_equal 100_000, closed.winning_minor_units
    assert_equal "bidder-a", closed.winner_id
  end

  def test_below_reserve_closes_without_winner
    engine = build_engine(reserve: 100_000)
    state = place(engine, engine.initial_state, maximum: 80_000)
    decision = close(engine, state)
    closed = apply(engine, state, decision)
    public_event = event(decision, :public)

    assert_equal "no_sale", closed.result
    assert_nil closed.winner_id
    assert_nil closed.winning_minor_units
    assert_equal 80_000, closed.standing_minor_units
    assert_equal "no_sale", public_event.fetch("result")
    assert_equal 80_000, public_event.fetch("standing_minor_units")
  end

  def test_empty_unit_closes_as_no_bid
    engine = build_engine
    state = engine.initial_state
    decision = close(engine, state)
    closed = apply(engine, state, decision)
    public_event = event(decision, :public)

    assert_equal "no_bid", closed.result
    assert_nil closed.leader_id
    assert_nil closed.standing_minor_units
    assert_nil closed.winner_id
    assert_equal({
      "type" => "bidding_closed",
      "command_id" => "command-close",
      "aggregate_version" => 1,
      "result" => "no_bid"
    }, public_event)
  end

  def test_close_before_current_soft_close_is_rejected
    engine = build_engine(extension: true)
    state = place(
      engine,
      engine.initial_state,
      maximum: 50_000,
      effective_at: "2026-09-01T12:58:00Z"
    )

    premature = close(engine, state, effective_at: "2026-09-01T13:00:00Z")
    on_time = close(engine, state, effective_at: "2026-09-01T13:03:00Z")

    assert_equal "2026-09-01T13:03:00Z", state.to_h.fetch("closes_at")
    assert_equal "closing_time_not_reached", premature.rejection.fetch("reason")
    assert on_time.accepted?
  end

  def test_invalid_or_missing_close_time_is_rejected
    engine = build_engine
    state = engine.initial_state
    invalid = close(engine, state, effective_at: "not-a-time")
    missing = engine.decide(state, {
      command_id: "command-close-missing",
      type: "close_bidding"
    })

    assert_equal "invalid_command", invalid.rejection.fetch("reason")
    assert_equal "invalid_command", missing.rejection.fetch("reason")
  end

  def test_every_supported_mutation_is_rejected_after_close
    engine = build_engine
    state = place(engine, engine.initial_state, maximum: 50_000, bid_id: "bid-a")
    state = apply(engine, state, close(engine, state))
    commands = [
      {
        command_id: "command-bid-late",
        type: "place_bid",
        bidder_id: "bidder-b",
        maximum_minor_units: 60_000,
        effective_at: "2026-09-01T13:01:00Z"
      },
      {
        command_id: "command-reduce-late",
        type: "reduce_maximum",
        bidder_id: "bidder-a",
        maximum_minor_units: 10_000,
        effective_at: "2026-09-01T13:01:00Z"
      },
      {
        command_id: "command-void-late",
        type: "void_bid",
        bid_id: "bid-a",
        operator_id: "operator-1",
        reason: "late_request",
        notification_policy: "affected",
        effective_at: "2026-09-01T13:01:00Z"
      },
      {
        command_id: "command-reserve-late",
        type: "change_reserve",
        operator_id: "operator-1",
        reserve_minor_units: nil,
        reason: "late_request",
        effective_at: "2026-09-01T13:01:00Z"
      },
      {
        command_id: "command-schedule-late",
        type: "change_closing_time",
        operator_id: "operator-1",
        closes_at: "2026-09-01T14:00:00Z",
        reason: "late_request",
        effective_at: "2026-09-01T13:01:00Z"
      },
      {
        command_id: "command-close-again",
        type: "close_bidding",
        effective_at: "2026-09-01T13:01:00Z"
      }
    ]

    commands.each do |command|
      decision = engine.decide(state, command)

      assert_equal "bidding_closed", decision.rejection.fetch("reason"), command.fetch(:type)
    end
  end

  def test_apply_rejects_closing_result_with_mismatched_winner
    engine = build_engine
    state = place(engine, engine.initial_state, maximum: 50_000)
    decision = close(engine, state)
    transition = decision.events.find(&:privileged?)
    malformed = RBBB::Event.new(
      type: transition.type,
      visibility: transition.visibility,
      data: transition.data.merge("winner_id" => "bidder-b")
    )

    assert_raises(RBBB::InvalidState) { engine.apply(state, [malformed]) }
  end

  def test_apply_rejects_closing_transition_before_current_close
    engine = build_engine
    state = place(engine, engine.initial_state, maximum: 50_000)
    decision = close(engine, state)
    transition = decision.events.find(&:privileged?)
    premature = RBBB::Event.new(
      type: transition.type,
      visibility: transition.visibility,
      data: transition.data.merge("effective_at" => "2026-09-01T12:59:59Z")
    )

    assert_raises(RBBB::InvalidState) { engine.apply(state, [premature]) }
  end

  private

  def build_engine(reserve: nil, extension: false)
    RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: reserve,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: extension ? {trigger_window_seconds: 300, duration_seconds: 300} : nil
    ))
  end

  def place(engine, state, maximum:, bid_id: "bid-a",
    effective_at: "2026-09-01T12:10:00Z")
    decision = engine.decide(state, {
      command_id: "command-bid",
      type: "place_bid",
      bid_id: bid_id,
      bidder_id: "bidder-a",
      maximum_minor_units: maximum,
      effective_at: effective_at
    })
    apply(engine, state, decision)
  end

  def close(engine, state, effective_at: "2026-09-01T13:00:00Z")
    engine.decide(state, {
      command_id: "command-close",
      type: "close_bidding",
      effective_at: effective_at
    })
  end

  def apply(engine, state, decision)
    assert decision.accepted?, decision.rejection.inspect
    engine.apply(state, decision.events)
  end

  def event(decision, visibility)
    decision.events.find { |candidate| candidate.visibility == visibility }.to_h
  end
end
