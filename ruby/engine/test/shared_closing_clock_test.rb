# frozen_string_literal: true

require_relative "test_helper"
require "json"

class SharedClosingClockTest < Minitest::Test
  def clock(**extra)
    RBBB::SharedClosingClock.new(group_id: "group-a", unit_ids: %w[lot-12 lot-47 lot-103],
      closes_at: "2030-01-01T13:00:00Z", quiet_period_seconds: 180, **extra)
  end

  def engine(deadline, **extra)
    RBBB::Engine.new(RBBB::Configuration.new(currency: "USD", opening_minor_units: 1000,
      increments: [{from_minor_units: 0, amount_minor_units: 100}],
      opens_at: "2030-01-01T12:00:00Z", closes_at: RBBB::Timestamp.dump(deadline), **extra))
  end

  def bid(core, state, id: "bid", bidder: "bidder-a", maximum: 5000, at: "2030-01-01T12:59:00Z", type: "place_bid")
    core.decide(state, command_id: id, type: type, bidder_id: bidder,
      maximum_minor_units: maximum, effective_at: at)
  end

  def test_portable_quiet_period_vector_uses_real_engine_decisions
    vector = JSON.parse(File.read(File.expand_path("../../../conformance/shared-closing-clock/quiet-period.json", __dir__)))
    current = RBBB::SharedClosingClock.new(**vector.reject { |key, _| %w[id steps].include?(key) }.transform_keys(&:to_sym))
    vector.fetch("steps").each do |step|
      core = engine(current.closes_at)
      decision = bid(core, core.initial_state, at: step.fetch("effective_at"))
      assert decision.accepted?
      previous = current
      current = current.after_decision(unit_id: step.fetch("unit_id"), decision: decision, expected_revision: current.revision)
      vector.fetch("unit_ids").each { |id| assert_equal step.fetch("expected_closes_at"), RBBB::Timestamp.dump(current.deadline_for(id)) }
      assert_equal step.fetch("expected_revision"), current.revision
      assert_operator current.closes_at, :>, previous.closes_at
    end
    refute current.due?(at: "2030-01-01T13:05:59.999Z")
    assert current.due?(at: "2030-01-01T13:06:00Z")
  end

  def test_outbid_bidder_raising_to_retake_the_lead_extends_the_group
    current = clock
    core = engine(current.closes_at)
    state = core.initial_state
    first = bid(core, state, id: "a", maximum: 2000, at: "2030-01-01T12:30:00Z")
    state = core.apply(state, first.events)
    challenger = bid(core, state, id: "b", bidder: "bidder-b", maximum: 3000, at: "2030-01-01T12:31:00Z")
    state = core.apply(state, challenger.events)
    raise_decision = bid(core, state, id: "raise", maximum: 4000)
    assert_equal "maximum_increased", raise_decision.events.find(&:privileged?).type
    assert raise_decision.events.find { |event| event.type == "standing_bid_changed" }.data.fetch("leader_changed")
    result = current.after_decision(unit_id: "lot-12", decision: raise_decision, expected_revision: 0)
    assert_equal "2030-01-01T13:02:00Z", result.public_view.fetch("closes_at")
    assert_equal 1, result.revision
  end

  def test_outbid_bidder_raising_the_price_without_retaking_the_lead_extends
    current = clock
    core = engine(current.closes_at)
    state = core.apply(core.initial_state, bid(core, core.initial_state, id: "a", bidder: "bidder-a", maximum: 5000, at: "2030-01-01T12:30:00Z").events)
    state = core.apply(state, bid(core, state, id: "b", bidder: "bidder-b", maximum: 1500, at: "2030-01-01T12:31:00Z").events)
    raise_decision = bid(core, state, id: "raise", bidder: "bidder-b", maximum: 2500)
    standing = raise_decision.events.find { |event| event.type == "standing_bid_changed" }
    refute standing.data.fetch("leader_changed")
    result = current.after_decision(unit_id: "lot-12", decision: raise_decision, expected_revision: 0)
    assert_equal "2030-01-01T13:02:00Z", result.public_view.fetch("closes_at")
  end

  def test_leader_own_increase_does_not_extend_even_when_it_crosses_reserve
    current = clock
    core = engine(current.closes_at, reserve_minor_units: 3000)
    state = core.apply(core.initial_state, bid(core, core.initial_state, id: "a", maximum: 2000, at: "2030-01-01T12:30:00Z").events)
    adjustment = bid(core, state, id: "raise", maximum: 4000)
    assert adjustment.events.any? { |event| event.type == "standing_bid_changed" }
    result = current.after_decision(unit_id: "lot-12", decision: adjustment, expected_revision: 0)
    assert_equal current.public_view, result.public_view
    assert_equal "2030-01-01T12:59:00Z", result.to_h.fetch("last_effective_at")
    refute result.public_view.key?("last_effective_at")
  end

  def test_proxy_reduction_and_rejected_bid_leave_deadline_unchanged
    current = clock
    core = engine(current.closes_at)
    state = core.apply(core.initial_state, bid(core, core.initial_state, at: "2030-01-01T12:30:00Z").events)
    reduction = bid(core, state, id: "reduce", type: "reduce_maximum", maximum: 3000)
    assert reduction.accepted?
    assert_equal current.public_view, current.after_decision(unit_id: "lot-47", decision: reduction, expected_revision: 0).public_view
    rejected = bid(core, core.initial_state, maximum: 1)
    assert_same current, current.after_decision(unit_id: "lot-47", decision: rejected, expected_revision: 0)
  end

  def test_trigger_boundary_and_before_window_never_shorten
    ["2030-01-01T12:56:59.999Z", "2030-01-01T12:57:00Z"].each do |at|
      current = clock
      core = engine(current.closes_at)
      result = current.after_decision(unit_id: "lot-12", decision: bid(core, core.initial_state, at: at), expected_revision: 0)
      assert_equal current.public_view, result.public_view
    end
  end

  def test_refuses_stale_revision_wrong_member_unsynchronized_deadline_and_time_regression
    current = clock(last_effective_at: "2030-01-01T12:59:30Z")
    core = engine(current.closes_at)
    decision = bid(core, core.initial_state)
    assert_raises(RBBB::InvalidState) { current.after_decision(unit_id: "lot-12", decision: decision, expected_revision: 1) }
    assert_raises(RBBB::InvalidState) { clock.after_decision(unit_id: "lot-12", decision: decision, expected_revision: 0.0) }
    assert_raises(RBBB::InvalidState) { current.after_decision(unit_id: "unknown", decision: decision, expected_revision: 0) }
    assert_raises(RBBB::InvalidState) { current.after_decision(unit_id: "lot-12", decision: decision, expected_revision: 0) }
    different = engine(RBBB::Timestamp.parse("2030-01-01T14:00:00Z"))
    assert_raises(RBBB::InvalidState) { clock.after_decision(unit_id: "lot-12", decision: bid(different, different.initial_state), expected_revision: 0) }
  end

  def test_public_clock_does_not_copy_private_bid_data
    current = clock
    core = engine(current.closes_at)
    result = current.after_decision(unit_id: "lot-12", decision: bid(core, core.initial_state), expected_revision: 0)
    %w[bidder-a maximum_minor_units standing_minor_units positions reserve_minor_units].each { |value| refute_includes JSON.generate(result.to_h), value }
    assert current.frozen?
    assert result.frozen?
    assert_equal 0, current.revision
  end

  def test_invalid_configuration_and_timestamp_overflow_are_refused
    [0, -1, 1.5, RBBB::MAX_SAFE_INTEGER + 1].each do |seconds|
      assert_raises(RBBB::InvalidConfiguration) { clock(quiet_period_seconds: seconds) }
    end
    assert_raises(RBBB::InvalidConfiguration) { clock(unit_ids: ["a", "a"]) }
    current = clock(quiet_period_seconds: RBBB::MAX_SAFE_INTEGER)
    core = engine(current.closes_at)
    assert_raises(RBBB::InvalidConfiguration) { current.after_decision(unit_id: "lot-12", decision: bid(core, core.initial_state), expected_revision: 0) }
  end

  def test_revision_overflow_is_refused
    current = clock(revision: RBBB::MAX_SAFE_INTEGER)
    core = engine(current.closes_at)
    assert_raises(RBBB::InvalidState) { current.after_decision(unit_id: "lot-12", decision: bid(core, core.initial_state), expected_revision: current.revision) }
  end
end
