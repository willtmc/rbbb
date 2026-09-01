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

  private

  def accept(state, command_id, bidder_id, maximum_minor_units)
    decision = @engine.decide(state, {
      command_id: command_id,
      type: "place_bid",
      bidder_id: bidder_id,
      maximum_minor_units: maximum_minor_units
    })
    assert decision.accepted?, decision.rejection.inspect
    @engine.apply(state, decision.events)
  end
end
