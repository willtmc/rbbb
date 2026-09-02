# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"

# A host must be able to checkpoint an aggregate from its latest transition
# event (or a stored snapshot) and continue with decisions identical to a
# full replay, and must be able to publish a query projection that cannot
# leak identities, maxima, or the reserve amount.
class StateSnapshotTest < Minitest::Test
  include SchemaAssertions

  IDENTITY = {"auction_id" => "auction-1", "bidding_unit_id" => "unit-1", "currency" => "USD"}.freeze
  # Mirrors the privileged-key guard in scripts/validate_documents.rb.
  FORBIDDEN_PUBLIC_KEYS = /maximum|reserve_minor_units|operator_id|reason|bidder_id|leader_id|winner_id/
  PREFIX_COMMANDS = [
    {command_id: "command-1", type: "place_bid", bid_id: "bid-1", bidder_id: "bidder-a",
     maximum_minor_units: 50_000, effective_at: "2026-09-01T12:10:00Z"},
    {command_id: "command-2", type: "place_bid", bid_id: "bid-2", bidder_id: "bidder-b",
     maximum_minor_units: 43_000, effective_at: "2026-09-01T12:11:00Z"},
    {command_id: "command-3", type: "reduce_maximum", bidder_id: "bidder-a",
     maximum_minor_units: 45_000, effective_at: "2026-09-01T12:12:00Z"},
    {command_id: "command-4", type: "change_reserve", operator_id: "operator-1",
     reason: "seller_lowered_reserve", reserve_minor_units: 35_000,
     effective_at: "2026-09-01T12:13:00Z"},
    {command_id: "command-5", type: "void_bid", bid_id: "bid-2", operator_id: "operator-1",
     reason: "review", notification_policy: "affected", effective_at: "2026-09-01T12:14:00Z"},
    {command_id: "command-6", type: "change_closing_time", operator_id: "operator-1",
     reason: "seller_request", closes_at: "2026-09-01T13:30:00Z",
     effective_at: "2026-09-01T12:15:00Z"}
  ].freeze
  SUFFIX_COMMANDS = [
    {command_id: "command-7", type: "place_bid", bid_id: "bid-7", bidder_id: "bidder-c",
     maximum_minor_units: 47_000, effective_at: "2026-09-01T12:20:00Z"},
    {command_id: "command-8", type: "place_bid", bid_id: "bid-8", bidder_id: "bidder-b",
     maximum_minor_units: 20_000, effective_at: "2026-09-01T12:21:00Z"},
    {command_id: "command-9", type: "place_bid", bid_id: "bid-9", bidder_id: "bidder-c",
     maximum_minor_units: 60_000, effective_at: "2026-09-01T13:00:00Z"},
    {command_id: "command-10", type: "close_bidding", effective_at: "2026-09-01T13:20:00Z"},
    {command_id: "command-11", type: "close_bidding", effective_at: "2026-09-01T13:30:00Z"}
  ].freeze

  def setup
    @engine = RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: 40_000,
      increments: [
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: 100_000, amount_minor_units: 2_500}
      ],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300}
    ))
  end

  def test_checkpoint_from_last_transition_continues_identically_to_full_replay
    replayed, transitions = run_commands(@engine.initial_state, PREFIX_COMMANDS)
    assert_equal PREFIX_COMMANDS.length, transitions.length
    assert_equal 6, replayed.version

    checkpoint = @engine.restore(transitions.last)
    from_snapshot = RBBB::State.from_h(replayed.to_h)

    assert_equal replayed.to_h, checkpoint.to_h
    assert_equal replayed.to_h, from_snapshot.to_h
    assert_equal replayed.public_view, checkpoint.public_view

    rejections = 0
    SUFFIX_COMMANDS.each do |command|
      decisions = [replayed, checkpoint, from_snapshot].map { |state| @engine.decide(state, command) }
      expected = decisions.first
      decisions.drop(1).each do |decision|
        assert_equal expected.events.map(&:to_h), decision.events.map(&:to_h), command.inspect
        if expected.rejection.nil?
          assert_nil decision.rejection, command.inspect
        else
          assert_equal expected.rejection, decision.rejection, command.inspect
        end
      end
      if expected.rejected?
        rejections += 1
        next
      end

      replayed, checkpoint, from_snapshot = decisions.zip([replayed, checkpoint, from_snapshot])
        .map { |decision, state| @engine.apply(state, decision.events) }
      assert_equal replayed.to_h, checkpoint.to_h, command.inspect
      assert_equal replayed.to_h, from_snapshot.to_h, command.inspect
    end

    assert_equal 2, rejections
    assert_equal "sold", replayed.result
    assert_equal "bidder-c", replayed.winner_id
    assert_equal 46_000, replayed.winning_minor_units
    assert_equal 9, replayed.version
  end

  def test_snapshot_round_trips_for_initial_and_closed_states
    initial = @engine.initial_state
    assert_equal initial.to_h, RBBB::State.from_h(initial.to_h).to_h

    closed, transitions = run_commands(initial, PREFIX_COMMANDS + SUFFIX_COMMANDS)
    assert closed.closed?
    assert_equal closed.to_h, RBBB::State.from_h(closed.to_h).to_h
    assert_equal closed.to_h, @engine.restore(transitions.last).to_h
    assert_equal closed.to_h, RBBB::State.from_transition(@engine.configuration, transitions.last.data).to_h
  end

  def test_snapshot_ignores_host_identity_keys_and_accepts_symbol_keys
    state, = run_commands(@engine.initial_state, PREFIX_COMMANDS)
    snapshot = IDENTITY.merge(state.to_h).transform_keys(&:to_sym)

    assert_equal state.to_h, RBBB::State.from_h(snapshot).to_h
  end

def test_restore_rejects_events_that_are_not_state_transitions
  decision = @engine.decide(@engine.initial_state, PREFIX_COMMANDS.first)
  public_event = decision.events.find(&:public?)
  refute_nil public_event

  assert_raises(RBBB::InvalidState) { @engine.restore(public_event) }
  assert_raises(RBBB::InvalidState) { @engine.restore(public_event.to_h) }

  before_void, = run_commands(@engine.initial_state, PREFIX_COMMANDS.take(4))
  void = @engine.decide(before_void, PREFIX_COMMANDS.fetch(4))
  notification = void.events.find { |event| event.type == "notification_requested" }
  refute_nil notification

  assert_raises(RBBB::InvalidState) { @engine.restore(notification) }
  assert_raises(RBBB::InvalidState) do
    RBBB::State.from_transition(@engine.configuration, notification)
  end
end

  def test_restore_validates_the_snapshot_it_is_handed
    _, transitions = run_commands(@engine.initial_state, PREFIX_COMMANDS)
    data = transitions.last.data

    tampered = data.merge("leader_id" => "bidder-z")
    error = assert_raises(RBBB::InvalidState) do
      RBBB::State.from_transition(@engine.configuration, tampered)
    end
    assert_match(/leader must have a position/, error.message)

    missing = data.reject { |key, _| key == "positions" }
    error = assert_raises(RBBB::InvalidState) do
      RBBB::State.from_transition(@engine.configuration, missing)
    end
    assert_match(/positions/, error.message)

    assert_raises(RBBB::InvalidState) { RBBB::State.from_h(data.reject { |key, _| key == "version" }) }
    assert_raises(RBBB::InvalidState) { RBBB::State.from_h("not a snapshot") }
    assert_raises(RBBB::InvalidState) { RBBB::State.from_transition(@engine.configuration, nil) }
  end

  def test_to_h_is_a_complete_aggregate_snapshot
    schema = load_schema("specification/state/aggregate.schema.json")
    state_owned = schema.fetch("required") - IDENTITY.keys
    assert_equal state_owned.sort, RBBB::State::SNAPSHOT_KEYS.sort

    open_state, = run_commands(@engine.initial_state, PREFIX_COMMANDS)
    closed_state, = run_commands(open_state, SUFFIX_COMMANDS)
    [@engine.initial_state, open_state, closed_state].each do |state|
      snapshot = state.to_h
      assert_equal state_owned.sort, snapshot.keys.sort
      assert_matches_schema(schema, IDENTITY.merge(snapshot))
    end

    assert_equal({"bidder-a" => {"maximum_minor_units" => 45_000, "priority" => 3,
      "executed_minor_units" => 40_000}}, open_state.to_h.fetch("positions"))
    assert_equal 3, open_state.to_h.fetch("authorization_history").length
    assert_equal 1, open_state.to_h.fetch("reserve_history").length
    assert_equal ["bid-2"], open_state.to_h.fetch("voided_bid_ids")
  end

  def test_public_view_matches_the_public_schema_and_discloses_nothing_private
    schema = load_schema("specification/state/bidding-unit.schema.json")
    public_owned = schema.fetch("required") - IDENTITY.keys
    assert_equal public_owned.sort, RBBB::State::PUBLIC_VIEW_KEYS.sort

    open_state, = run_commands(@engine.initial_state, PREFIX_COMMANDS)
    closed_state, = run_commands(open_state, SUFFIX_COMMANDS)
    [@engine.initial_state, open_state, closed_state].each do |state|
      view = state.public_view
      assert_equal public_owned.sort, view.keys.sort
      assert_empty view.keys - schema.fetch("properties").keys
      assert_empty deep_keys(view).grep(FORBIDDEN_PUBLIC_KEYS)
      assert_matches_schema(schema, IDENTITY.merge(view))
      %w[positions authorization_history reserve_history voided_bid_ids last_effective_at].each do |key|
        refute view.key?(key), "public view must not carry #{key}"
      end
    end

    assert_equal 40_000, open_state.public_view.fetch("standing_minor_units")
    assert_equal "reserve_met", open_state.public_view.fetch("reserve_status")
    assert_equal "sold", closed_state.public_view.fetch("result")
    assert_equal 46_000, closed_state.public_view.fetch("winning_minor_units")
    refute_includes closed_state.public_view.values, "bidder-c"
  end

  private

  def run_commands(state, commands)
    transitions = []
    commands.each do |command|
      decision = @engine.decide(state, command)
      next unless decision.accepted?

      transitions << decision.events.find do |event|
        event.privileged? && RBBB::Engine::STATE_TRANSITION_EVENTS.include?(event.type)
      end
      state = @engine.apply(state, decision.events)
    end
    [state, transitions]
  end

  def deep_keys(value)
    case value
    when Hash then value.flat_map { |key, nested| [key, *deep_keys(nested)] }
    when Array then value.flat_map { |nested| deep_keys(nested) }
    else []
    end
  end
end
