# frozen_string_literal: true

require_relative "test_helper"

class ProxyPropertiesTest < Minitest::Test
  MAXIMA = [10_000, 11_000, 11_001, 19_999, 20_000, 50_000].freeze

  def setup
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
    )
    @engine = RBBB::Engine.new(configuration)
  end

  def test_two_bidder_outcomes_preserve_proxy_invariants
    MAXIMA.product(MAXIMA).each do |first_maximum, second_maximum|
      next if second_maximum < 11_000

      state = accept(@engine.initial_state, "command-1", "bidder-a", first_maximum)
      state = accept(state, "command-2", "bidder-b", second_maximum)

      expected_leader = second_maximum > first_maximum ? "bidder-b" : "bidder-a"
      leader_maximum, runner_up_maximum = [first_maximum, second_maximum].sort.reverse
      expected_standing = [leader_maximum, runner_up_maximum + 1_000].min

      assert_equal expected_leader, state.leader_id,
        "leader for maxima #{first_maximum} and #{second_maximum}"
      assert_equal expected_standing, state.standing_minor_units,
        "standing amount for maxima #{first_maximum} and #{second_maximum}"
      assert_operator state.next_required_minor_units, :>, state.standing_minor_units
      state.positions.each_value do |position|
        assert_operator position.executed_minor_units, :<=, position.maximum_minor_units
      end
    end
  end

  def test_single_bidder_reserve_boundaries_preserve_price_and_privacy
    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      reserve_minor_units: 100_000,
      increments: [
        {from_minor_units: 0, amount_minor_units: 1_000},
        {from_minor_units: 100_000, amount_minor_units: 2_500}
      ]
    )
    engine = RBBB::Engine.new(configuration)

    [99_999, 100_000, 100_001, 150_000].each_with_index do |maximum, index|
      decision = decide(engine, engine.initial_state, "reserve-#{index}", "bidder-a", maximum)
      state = engine.apply(engine.initial_state, decision.events)
      expected_status = maximum >= 100_000 ? "reserve_met" : "reserve_not_met"
      expected_standing = [maximum, 100_000].min
      public_event = decision.events.find(&:public?).to_h

      assert_equal expected_standing, state.standing_minor_units, "maximum #{maximum}"
      assert_equal expected_status, state.reserve_status, "maximum #{maximum}"
      assert_equal "bidder-a", state.leader_id, "maximum #{maximum}"
      assert_equal expected_status, public_event.fetch("reserve_status"), "maximum #{maximum}"
      refute public_event.key?("reserve_minor_units"), "maximum #{maximum}"
    end
  end

  private

  def accept(state, command_id, bidder_id, maximum_minor_units)
    decision = decide(@engine, state, command_id, bidder_id, maximum_minor_units)
    @engine.apply(state, decision.events)
  end

  def decide(engine, state, command_id, bidder_id, maximum_minor_units)
    decision = engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bidder_id: bidder_id,
      maximum_minor_units: maximum_minor_units
    })
    assert decision.accepted?, decision.rejection.inspect
    decision
  end
end
