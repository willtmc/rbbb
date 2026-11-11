# frozen_string_literal: true

require_relative "test_helper"

# A void re-prices the unit by replaying the remaining authorizations in
# order. An authorization that was valid in the history that happened can sit
# below its bidder's executed amount in the replayed one. Replay gives such an
# entry no effect, whether it was recorded as a reduction or as a later bid,
# so `decide` never returns a void that `apply` refuses.
class VoidReplayFloorTest < Minitest::Test
  BASE = Time.utc(2026, 9, 1, 12, 0, 0)
  SEEDS = [11, 12, 14, 20, 24, 20_261_110].freeze
  CASES_PER_SEED = Integer(ENV.fetch("RBBB_VOID_REPLAY_CASES_PER_SEED", "150"))
  PROJECTION = %w[leader_id standing_minor_units next_required_minor_units reserve_status].freeze
  FLOOR_REJECTIONS = %w[maximum_below_executed_amount maximum_not_reduced maximum_not_found].freeze

  def test_void_after_raise_reduction_and_lower_rebid_is_applied
    engine = RBBB::Engine.new(configuration(opening: 1_000, increments: [[0, 1_000]]))
    state = run_commands(engine, six_commands.take(5))
    assert_equal ["y", 13_000], [state.leader_id, state.standing_minor_units]

    decision = engine.decide(state, stamp(six_commands.last, 6))
    assert decision.accepted?, decision.rejection.inspect
    voided = engine.apply(state, decision.events)

    # Without x-1, y leads from the second command, so x's 14,000 takes the
    # lead at 14,000. Neither the reduction to 13,400 nor the later 13,500 can
    # take x below that executed amount.
    assert_equal ["x", 14_000, 15_000],
      [voided.leader_id, voided.standing_minor_units, voided.next_required_minor_units]
    assert_equal({"maximum_minor_units" => 14_000, "executable_maximum_minor_units" => 14_000,
                  "priority" => 3, "executed_minor_units" => 14_000}, voided.position_for("x").to_h)
    assert_equal 13_000, voided.position_for("y").executed_minor_units
    assert_equal %w[x-1], voided.voided_bid_ids
    assert_equal 5, voided.authorization_history.length
    change = decision.events.find { |event| event.type == "executed_amount_changed" }
    assert_equal({"bidder_id" => "x", "old_minor_units" => 13_000, "new_minor_units" => 14_000},
      change.data.slice("bidder_id", "old_minor_units", "new_minor_units"))
  end

  def test_lower_rebid_gets_the_same_result_as_the_skipped_reduction_alone
    engine = RBBB::Engine.new(configuration(opening: 1_000, increments: [[0, 1_000]]))
    with_rebid = run_commands(engine, six_commands)
    without_rebid = run_commands(engine, six_commands.take(4) + [six_commands.last])

    assert_equal public_and_positions(without_rebid), public_and_positions(with_rebid)
  end

  def test_lower_rebid_at_or_above_the_executed_amount_still_lowers_the_maximum
    engine = RBBB::Engine.new(configuration(opening: 1_000, increments: [[0, 1_000]]))
    commands = six_commands
    commands[2] = commands[2].merge("maximum_minor_units" => 20_000)
    commands[4] = commands[4].merge("maximum_minor_units" => 15_000)
    before = run_commands(engine, commands.take(5))
    assert_equal ["x", 14_000, 15_000],
      [before.leader_id, before.standing_minor_units, before.position_for("x").maximum_minor_units]

    voided = run_commands(engine, commands)

    assert_equal ["x", 14_000], [voided.leader_id, voided.standing_minor_units]
    assert_equal 15_000, voided.position_for("x").maximum_minor_units
    assert_equal 14_000, voided.position_for("x").executed_minor_units
  end

  def test_fully_revoking_the_bidder_after_the_sequence_leaves_the_other_bidder_at_opening
    engine = RBBB::Engine.new(configuration(opening: 1_000, increments: [[0, 1_000]]))
    state = run_commands(engine, six_commands)
    %w[x-2 x-3].each_with_index do |bid_id, index|
      state = accept(engine, state, stamp(six_commands.last.merge("bid_id" => bid_id), 7 + index))
    end

    assert_equal ["y", 1_000], [state.leader_id, state.standing_minor_units]
    assert_nil state.position_for("x")
    assert_equal 1_000, state.position_for("y").executed_minor_units
  end

  # For random histories with voids: every event `decide` returns is accepted
  # by `apply`, executed amounts stay inside what each position can execute,
  # and the state after a void equals a fresh unit that received the remaining
  # entries in order through the ordinary command path, minus the entries that
  # would cross an executed amount there.
  def test_random_histories_with_voids_are_applied_and_match_a_fresh_replay
    voids = 0
    compared = 0
    SEEDS.each do |seed|
      rng = Random.new(seed)
      CASES_PER_SEED.times do |index|
        case_voids, case_compared = exercise(rng, "seed #{seed} case #{index}")
        voids += case_voids
        compared += case_compared
      end
    end

    assert_operator voids, :>=, SEEDS.length * CASES_PER_SEED, "too few voids exercised"
    assert_operator compared * 2, :>, voids, "fresh replay compared too few voids (#{compared}/#{voids})"
  end

  private

  def six_commands
    [
      {"type" => "place_bid", "bid_id" => "x-1", "bidder_id" => "x", "maximum_minor_units" => 13_000},
      {"type" => "place_bid", "bid_id" => "y-1", "bidder_id" => "y", "maximum_minor_units" => 13_000},
      {"type" => "place_bid", "bid_id" => "x-2", "bidder_id" => "x", "maximum_minor_units" => 14_000},
      {"type" => "reduce_maximum", "bidder_id" => "x", "maximum_minor_units" => 13_400},
      {"type" => "place_bid", "bid_id" => "x-3", "bidder_id" => "x", "maximum_minor_units" => 13_500},
      {"type" => "void_bid", "bid_id" => "x-1", "operator_id" => "operator-1",
       "reason" => "synthetic correction", "notification_policy" => "none"}
    ]
  end

  def configuration(opening:, increments:, reserve: nil)
    RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: opening,
      reserve_minor_units: reserve,
      increments: increments.map { |from, amount| {from_minor_units: from, amount_minor_units: amount} },
      opens_at: BASE,
      closes_at: BASE + 1_000_000
    )
  end

  def stamp(command, sequence)
    command.merge("command_id" => "command-#{sequence}",
      "effective_at" => RBBB::Timestamp.dump(BASE + sequence))
  end

  def accept(engine, state, command)
    decision = engine.decide(state, command)
    assert decision.accepted?, "#{command.inspect} rejected: #{decision.rejection.inspect}"
    engine.apply(state, decision.events)
  end

  def run_commands(engine, commands)
    commands.each_with_index.reduce(engine.initial_state) do |state, (command, index)|
      accept(engine, state, stamp(command, index + 1))
    end
  end

  def public_and_positions(state)
    PROJECTION.to_h { |key| [key, state.public_send(key)] }
      .merge("positions" => state.positions.transform_values(&:to_h))
  end

  def random_configuration(rng)
    increments = [
      [[0, 1_000]],
      [[0, 100], [1_000, 200], [2_600, 500], [10_000, 1_000]],
      [[0, 300], [1_000, 700], [1_300, 50]],
      [[0, rng.rand(1..700)]]
    ].sample(random: rng)
    configuration(
      opening: [0, 1, 100, 1_000, rng.rand(0..3_000)].sample(random: rng),
      reserve: rng.rand(3).zero? ? rng.rand(0..15_000) : nil,
      increments: increments
    )
  end

  def exercise(rng, label)
    engine = RBBB::Engine.new(random_configuration(rng))
    state = engine.initial_state
    bidders = Array.new(rng.rand(2..3)) { |index| "bidder-#{index}" }
    bid_ids = []
    voids = 0
    compared = 0

    rng.rand(4..28).times do |index|
      command = stamp(random_command(rng, state, bidders, bid_ids, index), index + 1)
      decision = engine.decide(state, command)
      next unless decision.accepted?

      trace = "#{label} #{command.slice('type', 'bidder_id', 'bid_id', 'maximum_minor_units').inspect}"
      begin
        state = engine.apply(state, decision.events)
      rescue RBBB::InvalidState => error
        flunk "#{trace}: apply refused an accepted decision (#{error.message}); " \
          "history #{state.authorization_history.inspect} voided #{state.voided_bid_ids.inspect}"
      end
      bid_ids << command.fetch("bid_id") if command.fetch("type") == "place_bid"
      assert_executed_amounts(state, trace)
      next unless command.fetch("type") == "void_bid"

      voids += 1
      fresh = fresh_replay(engine.configuration, state)
      next unless fresh

      compared += 1
      assert_equal comparable(fresh), comparable(state), "#{trace}: void diverged from a fresh replay"
    end
    [voids, compared]
  end

  def random_command(rng, state, bidders, bid_ids, index)
    roll = rng.rand(100)
    bidder = bidders.sample(random: rng)
    position = state.position_for(bidder)
    required = state.next_required_minor_units
    if roll < 56 || bid_ids.empty?
      rival = state.positions.values.sample(random: rng)&.maximum_minor_units || required
      own = position&.maximum_minor_units || required
      maximum = [
        required, required + rng.rand(1..99), required + rng.rand(0..4_000),
        own + rng.rand(1..150), own + rng.rand(1..1_200), rival, rival + rng.rand(0..1_200)
      ].sample(random: rng)
      {"type" => "place_bid", "bid_id" => "bid-#{index}", "bidder_id" => bidder,
       "maximum_minor_units" => maximum}
    elsif roll < 72
      maximum = position ? [position.executed_minor_units + rng.rand(0..600), position.maximum_minor_units - 1].min : 0
      {"type" => "reduce_maximum", "bidder_id" => bidder, "maximum_minor_units" => [maximum, 0].max}
    elsif roll < 77
      {"type" => "change_reserve", "operator_id" => "operator-1", "reason" => "synthetic review",
       "reserve_minor_units" => [nil, rng.rand(0..15_000), (state.reserve_minor_units || 0) / 2].sample(random: rng)}
    else
      {"type" => "void_bid", "bid_id" => bid_ids.sample(random: rng), "operator_id" => "operator-1",
       "reason" => "synthetic correction", "notification_policy" => "none"}
    end
  end

  def assert_executed_amounts(state, trace)
    state.positions.each do |bidder_id, position|
      assert_operator position.executed_minor_units, :<=, position.executable_maximum_minor_units,
        "#{trace}: #{bidder_id} is executed above its executable maximum"
      expected = bidder_id == state.leader_id ? state.standing_minor_units : position.executable_maximum_minor_units
      assert_equal expected, position.executed_minor_units, "#{trace}: #{bidder_id} executed amount"
    end
  end

  # Feeds the remaining entries to a new unit through decide/apply. Returns
  # nil when the ordinary command path cannot express the replayed order (a
  # challenger now under the next required amount, or a later lower bid that
  # stays at or above the executed amount), so those voids are checked by the
  # invariants above only.
  def fresh_replay(configuration, state)
    engine = RBBB::Engine.new(configuration)
    fresh = engine.initial_state
    actions = [
      *state.authorization_history,
      *state.reserve_history.map { |entry| entry.merge("type" => "reserve_changed") }
    ].sort_by { |entry| entry.fetch("priority") }

    actions.each_with_index do |entry, index|
      command = fresh_command(entry, state.voided_bid_ids)
      next unless command

      decision = engine.decide(fresh, stamp(command, index + 1))
      if decision.accepted?
        fresh = engine.apply(fresh, decision.events)
        next
      end
      next if crosses_executed_amount?(fresh, entry, decision.rejection.fetch("reason"))

      return nil
    end
    fresh
  end

  def fresh_command(entry, voided_bid_ids)
    case entry.fetch("type")
    when "reserve_changed"
      {"type" => "change_reserve", "operator_id" => "operator-1", "reason" => "synthetic review",
       "reserve_minor_units" => entry.fetch("new_reserve_minor_units")}
    when "place_bid"
      return nil if voided_bid_ids.include?(entry.fetch("bid_id"))

      entry.slice("type", "bid_id", "bidder_id", "maximum_minor_units")
    else
      entry.slice("bidder_id", "maximum_minor_units").merge("type" => "reduce_maximum")
    end
  end

  def crosses_executed_amount?(fresh, entry, reason)
    return FLOOR_REJECTIONS.include?(reason) unless entry.fetch("type") == "place_bid"

    position = fresh.position_for(entry.fetch("bidder_id"))
    reason == "maximum_not_increased" &&
      entry.fetch("maximum_minor_units") < position.executed_minor_units
  end

  # Priorities are command sequence numbers, which a fresh unit numbers
  # differently, so compare the order they produce instead.
  def comparable(state)
    PROJECTION.to_h { |key| [key, state.public_send(key)] }.merge(
      "positions" => state.positions.transform_values { |position| position.to_h.except("priority") },
      "priority_order" => state.positions.sort_by { |_, position| position.priority }.map(&:first)
    )
  end
end
