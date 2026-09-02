# frozen_string_literal: true

require_relative "test_helper"

# Seeded random command streams that check structural invariants after every
# accepted command and, critically, that the incremental pricing path used by
# place_bid agrees with the from-scratch replay used by void_bid. The two
# paths are separate implementations of the same RFC 0001 rules; any drift
# between them would make a void produce a state no live sequence could reach.
class EngineDifferentialTest < Minitest::Test
  SEEDS = [1, 2, 3, 20_260_901].freeze
  RUNS_PER_SEED = 60
  COMMANDS_PER_RUN = 40
  BIDDERS = %w[bidder-a bidder-b bidder-c bidder-d].freeze
  BASE = Time.utc(2026, 9, 1, 12, 0, 0)
  PRIVATE_KEYS = %w[
    bidder_id maximum_minor_units reserve_minor_units operator_id positions
    authorization_history reserve_history executed_minor_units leader_id
    winner_id old_reserve_minor_units new_reserve_minor_units bidder_ids
    old_maximum_minor_units new_maximum_minor_units executed_floor_minor_units
  ].freeze
  PUBLIC_PROJECTION = %w[
    leader_id standing_minor_units next_required_minor_units reserve_status
  ].freeze

  def test_random_command_streams_preserve_invariants_and_replay_agreement
    SEEDS.each do |seed|
      rng = Random.new(seed)
      RUNS_PER_SEED.times do |run|
        exercise(rng, "seed #{seed} run #{run}")
      end
    end
  end

  private

  def exercise(rng, label)
    configuration = random_configuration(rng)
    engine = RBBB::Engine.new(configuration)
    state = engine.initial_state
    time = BASE + 60
    bid_ids = []
    reserve_changed = false
    accepted = 0

    COMMANDS_PER_RUN.times do |index|
      time += rng.rand(1..400)
      command = random_command(rng, state, bid_ids, "command-#{index}", time)
      decision = engine.decide(state, command)
      assert_equal decision.events.map(&:to_h), engine.decide(state, command).events.map(&:to_h),
        "#{label}: decide is not deterministic for #{command.inspect}"
      next unless decision.accepted?

      accepted += 1
      bid_ids << command[:bid_id] if command[:type] == "place_bid"
      reserve_changed = true if command[:type] == "change_reserve"
      before = state
      state = engine.apply(state, decision.events)

      assert_no_private_data_in_public_events(decision, label)
      assert_checkpoint_agreement(engine, decision, state, label)
      if command[:type] == "place_bid"
        assert_operator state.closes_at, :>=, before.closes_at,
          "#{label}: a bid moved closing time earlier: #{command.inspect}"
      end
      assert_executed_amount_rules(state, label)
      assert_executed_amounts_monotone(before, state, label) unless command[:type] == "void_bid"
      assert_fresh_pricing(configuration, state, label) if state.leader_id && !reserve_changed
      assert_replay_agreement(engine, state, label) unless state.closed?

      break if state.closed?
    end

    assert_operator accepted, :>, 0, "#{label}: no command was accepted"
  end

  def random_configuration(rng)
    RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: [nil, nil, 50_000, 100_000, 120_000].sample(random: rng),
      increments: [
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: 100_000, amount_minor_units: 2_500}
      ],
      opens_at: BASE,
      closes_at: BASE + 3600,
      extension: [
        nil,
        {trigger_window_seconds: 300, duration_seconds: 300},
        {trigger_window_seconds: 300, duration_seconds: 60}
      ].sample(random: rng)
    )
  end

  def random_command(rng, state, bid_ids, command_id, time)
    effective_at = RBBB::Timestamp.dump(time)
    roll = rng.rand
    if roll < 0.55
      bidder = BIDDERS.sample(random: rng)
      position = state.position_for(bidder)
      required = state.next_required_minor_units
      candidates = [required - 1, required, required + 1, required + rng.rand(0..150_000),
        10_000, 9_999, 100_000, 100_001]
      if position
        candidates.push(position.maximum_minor_units, position.maximum_minor_units + 1,
          position.maximum_minor_units + 500)
      end
      candidates << state.positions.fetch(state.leader_id).maximum_minor_units if state.leader_id
      {command_id: command_id, bid_id: "bid-#{command_id}", type: "place_bid",
       bidder_id: bidder, maximum_minor_units: candidates.sample(random: rng),
       effective_at: effective_at}
    elsif roll < 0.7
      bidder = BIDDERS.sample(random: rng)
      position = state.position_for(bidder)
      candidates = [10_000, 0]
      if position
        executed = position.executed_minor_units
        candidates.push(executed, executed - 1, executed + 1, position.maximum_minor_units - 1)
      end
      {command_id: command_id, type: "reduce_maximum", bidder_id: bidder,
       maximum_minor_units: candidates.sample(random: rng), effective_at: effective_at}
    elsif roll < 0.82 && bid_ids.any?
      {command_id: command_id, type: "void_bid", bid_id: bid_ids.sample(random: rng),
       operator_id: "operator-1", reason: "review",
       notification_policy: RBBB::Engine::NOTIFICATION_POLICIES.sample(random: rng),
       effective_at: effective_at}
    elsif roll < 0.9
      {command_id: command_id, type: "change_reserve", operator_id: "operator-1",
       reason: "review", reserve_minor_units: [nil, 0, 20_000, 60_000, 130_000].sample(random: rng),
       effective_at: effective_at}
    elsif roll < 0.95
      {command_id: command_id, type: "change_closing_time", operator_id: "operator-1",
       reason: "review", closes_at: RBBB::Timestamp.dump(state.closes_at + rng.rand(-600..1200)),
       effective_at: effective_at}
    else
      {command_id: command_id, type: "close_bidding", effective_at: effective_at}
    end
  end

  def assert_no_private_data_in_public_events(decision, label)
    decision.events.select(&:public?).each do |event|
      leaked = event.data.keys & PRIVATE_KEYS
      assert_empty leaked, "#{label}: public #{event.type} leaked #{leaked.inspect}"
    end
  end

  # A host that checkpoints from the latest transition event, or from a stored
  # snapshot, must land on exactly the state the incremental path produced,
  # and its public projection must never carry a private key.
  def assert_checkpoint_agreement(engine, decision, state, label)
    transition = decision.events.find do |event|
      event.privileged? && RBBB::Engine::STATE_TRANSITION_EVENTS.include?(event.type)
    end
    assert_equal state.to_h, engine.restore(transition).to_h,
      "#{label}: restore from #{transition.type} diverged from apply"
    assert_equal state.to_h, RBBB::State.from_h(state.to_h).to_h,
      "#{label}: snapshot did not round-trip"
    leaked = state.public_view.keys & PRIVATE_KEYS
    assert_empty leaked, "#{label}: public view leaked #{leaked.inspect}"
  end

  def assert_executed_amount_rules(state, label)
    state.positions.each do |bidder_id, position|
      if bidder_id == state.leader_id
        assert_equal state.standing_minor_units, position.executed_minor_units,
          "#{label}: leader executed amount must equal the standing amount"
      else
        assert_equal position.maximum_minor_units, position.executed_minor_units,
          "#{label}: an outbid proxy must be fully executed"
      end
    end
  end

  def assert_executed_amounts_monotone(before, state, label)
    state.positions.each do |bidder_id, position|
      previous = before.position_for(bidder_id)
      next unless previous

      assert_operator position.executed_minor_units, :>=, previous.executed_minor_units,
        "#{label}: executed amount decreased without a void"
    end
  end

  # Without reserve changes the ratchet is never engaged, so the standing amount
  # must equal the RFC formula computed from current positions alone.
  def assert_fresh_pricing(configuration, state, label)
    ranked = state.positions.sort_by { |id, position| [-position.maximum_minor_units, position.priority, id] }
    leader_maximum = ranked.first.last.maximum_minor_units
    competitive = if ranked.length > 1
      runner_up = ranked[1].last.maximum_minor_units
      runner_up + configuration.increment_for(runner_up)
    else
      configuration.opening_minor_units
    end
    pressure = state.reserve_minor_units ? [leader_maximum, state.reserve_minor_units].min : configuration.opening_minor_units
    expected = [leader_maximum, [configuration.opening_minor_units, competitive, pressure].max].min

    assert_equal expected, state.standing_minor_units, "#{label}: standing amount drifted from RFC formula"
  end

  def assert_replay_agreement(engine, state, label)
    replayed = engine.send(:replay_authorizations, state.authorization_history,
      state.voided_bid_ids, state.reserve_history)
    live = PUBLIC_PROJECTION.to_h { |key| [key, state.public_send(key)] }
    live["positions"] = state.positions.transform_values(&:to_h)

    assert_equal live, replayed.slice(*live.keys), "#{label}: incremental state diverged from replay"
  end
end
