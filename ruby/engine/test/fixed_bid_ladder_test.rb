# frozen_string_literal: true

require_relative "test_helper"

class FixedBidLadderTest < Minitest::Test
  def setup
    @config = RBBB::Configuration.new(currency: "USD", opening_minor_units: 1000,
      increments: [{from_minor_units: 0, amount_minor_units: 100},
        {from_minor_units: 1000, amount_minor_units: 200},
        {from_minor_units: 2500, amount_minor_units: 500},
        {from_minor_units: 10000, amount_minor_units: 1000},
        {from_minor_units: 25000, amount_minor_units: 2500}],
      opens_at: "2032-01-01T12:00:00Z", closes_at: "2032-01-01T13:00:00Z",
      extension: {trigger_window_seconds: 300, duration_seconds: 300})
    @engine = RBBB::Engine.new(@config)
    @state = @engine.initial_state
    @sequence = 0
  end

  def command(type = "place_bid", **fields)
    @sequence += 1
    {type: type, command_id: "synthetic-#{@sequence}", effective_at: "2032-01-01T12:59:00Z"}.merge(fields)
  end

  def accept(value)
    decision = @engine.decide(@state, value)
    assert decision.accepted?, decision.rejection.inspect
    assert_equal decision.events.map(&:to_h), @engine.decide(@state, value).events.map(&:to_h)
    @state = @engine.apply(@state, decision.events)
    assert_equal @state.to_h, @engine.restore(decision.events.first).to_h
    decision
  end

  def bid(who, maximum)
    accept(command(bidder_id: who, maximum_minor_units: maximum))
  end

  def test_published_breakpoints_cannot_be_shifted_by_odd_maxima
    ladder = @config.bid_ladder
    [[2499, 2400, 2500], [2500, 2500, 3000], [9999, 9500, 10000],
      [10001, 10000, 11000], [24999, 24000, 25000], [25001, 25000, 27500]].each do |amount, floor, following|
      assert_equal floor, ladder.floor(amount)
      assert_equal following, ladder.above(amount)
    end
  end

  def test_ladder_lookup_matches_an_independently_enumerated_small_grid
    # Explicit allowed amounts, including the short fixed transition 24 -> 25.
    rungs = [1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400,
      2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500, 7000,
      7500, 8000, 8500, 9000, 9500, 10000, 11000]
    (0..10500).each do |amount|
      assert_equal rungs.select { |r| r <= amount }.last || 0, @config.bid_ladder.floor(amount)
      assert_equal rungs.find { |r| r > amount }, @config.bid_ladder.above(amount)
    end
  end

  def test_odd_maximum_is_retained_and_notice_is_private_and_nonblocking
    decision = bid("a", 24900)
    notice = decision.events.first.data.fetch("bidder_notice")
    assert_equal 24900, @state.position_for("a").maximum_minor_units
    assert_equal 24000, @state.position_for("a").executable_maximum_minor_units
    assert_equal 1000, @state.standing_minor_units
    assert_equal 25000, notice.fetch("next_ladder_minor_units")
    assert_equal "Your maximum of USD 249.00 is accepted. Under this item's bid increments, we can bid up to USD 240.00 for you. The next available amount is USD 250.00.", notice.fetch("message")
    refute @state.public_view.keys.any? { |key| key.include?("maximum") || key.include?("notice") }
    decision.events.select(&:public?).each { |event| refute event.data.key?("bidder_notice") }
  end

  def test_unused_remainder_does_not_win_tie_or_raise_price
    bid("a", 24100)
    bid("b", 24900)
    assert_equal "a", @state.leader_id
    assert_equal 24000, @state.standing_minor_units
    assert_equal 24000, @state.position_for("b").executed_minor_units
    assert_equal 25000, @state.next_required_minor_units
  end

  def test_same_rung_increases_and_reductions_keep_original_priority_and_clock
    bid("a", 24100)
    bid("b", 24900)
    close = @state.closes_at
    decision = bid("a", 24999)
    assert_equal 1, @state.position_for("a").priority
    assert_empty decision.events.select(&:public?)
    accept(command("reduce_maximum", bidder_id: "a", maximum_minor_units: 24000))
    assert_equal "a", @state.leader_id
    assert_equal 1, @state.position_for("a").priority
    assert_equal close, @state.closes_at
    bid("b", 24999)
    assert_equal 2, @state.position_for("b").priority
    assert_equal "a", @state.leader_id
  end

  def test_losing_bidder_remainder_edit_cannot_reprice_an_earlier_tie
    bid("a", 24100)
    bid("b", 24900)
    bid("a", 30000)
    assert_equal 24000, @state.standing_minor_units
    decision = bid("b", 24999)
    assert_equal 24000, @state.standing_minor_units
    assert_empty decision.events.select(&:public?)
    replay = @engine.send(:replay_authorizations, @state.authorization_history, [], [])
    assert_equal 24000, replay.fetch("standing_minor_units")
    assert_equal @state.positions.transform_values(&:to_h), replay.fetch("positions")
  end

  def test_arbitrary_opening_is_fixed_and_does_not_offset_later_rungs
    ladder = RBBB::BidLadder.new(@config.increment_schedule, 2300)
    assert_equal 2300, ladder.floor(2399)
    assert_equal 2400, ladder.above(2300)
    assert_equal 2500, ladder.above(2400)
    assert_equal 3000, ladder.above(2500)
  end

  def test_exact_maximum_needs_no_notice
    assert_nil bid("a", 24000).bidder_notice
  end

  def test_new_rung_assigns_new_priority_without_self_repricing
    bid("a", 24900)
    bid("b", 23000)
    assert_equal 24000, @state.standing_minor_units
    bid("a", 27900)
    assert_equal 3, @state.position_for("a").priority
    assert_equal 24000, @state.standing_minor_units
    bid("c", 27500)
    assert_equal "a", @state.leader_id
    assert_equal 27500, @state.standing_minor_units
  end

  def test_cut_bid_cannot_meet_next_required_amount
    bid("a", 25000)
    bid("b", 24000)
    rejected = @engine.decide(@state, command(bidder_id: "c", maximum_minor_units: 27499))
    assert_equal "maximum_below_next_required", rejected.rejection.fetch("reason")
  end

  def test_off_ladder_reserve_does_not_consume_remainder
    accept(command("change_reserve", operator_id: "operator", reason: "Synthetic reserve", reserve_minor_units: 24900))
    bid("a", 24999)
    assert_equal 24000, @state.standing_minor_units
    assert_equal "reserve_not_met", @state.reserve_status
    bid("a", 25001)
    assert_equal 25000, @state.standing_minor_units
    assert_equal "reserve_met", @state.reserve_status
  end

  def test_reduction_can_remove_remainder_but_not_executed_bid
    bid("a", 24900)
    bid("b", 25000)
    accept(command("reduce_maximum", bidder_id: "a", maximum_minor_units: 24000))
    rejected = @engine.decide(@state, command("reduce_maximum", bidder_id: "a", maximum_minor_units: 23999))
    assert_equal 24000, rejected.rejection.fetch("executed_floor_minor_units")
  end

  def test_operator_void_replays_retained_priority_not_raw_maximum
    bid("a", 24100)
    bid("b", 24900)
    bid("a", 24999)
    bid("c", 35000)
    accept(command("void_bid", bid_id: "synthetic-4", operator_id: "operator", reason: "Synthetic correction", notification_policy: "affected"))
    assert_equal "a", @state.leader_id
    assert_equal 24000, @state.standing_minor_units
    assert_equal 1, @state.position_for("a").priority
  end

  def test_old_or_tampered_snapshot_cannot_enter_new_engine
    bid("a", 24900)
    snapshot = @state.to_h
    snapshot["positions"]["a"].delete("executable_maximum_minor_units")
    assert_raises(RBBB::InvalidState) { RBBB::State.from_h(snapshot) }
    snapshot = @state.to_h
    snapshot["positions"]["a"]["executable_maximum_minor_units"] = 24900
    state = RBBB::State.from_h(snapshot)
    assert_raises(RBBB::InvalidState) { @engine.decide(state, command(bidder_id: "b", maximum_minor_units: 30000)) }
  end

  def test_numeric_ceiling_does_not_create_a_cut_bid
    bid("a", RBBB::MAX_SAFE_INTEGER)
    bid("b", RBBB::MAX_SAFE_INTEGER)
    top = @config.bid_ladder.floor(RBBB::MAX_SAFE_INTEGER)
    assert_equal top, @state.standing_minor_units
    assert_equal top, @state.next_required_minor_units
    assert_nil @config.bid_ladder.above(top)
    rejection = @engine.decide(@state, command(bidder_id: "c", maximum_minor_units: RBBB::MAX_SAFE_INTEGER))
    assert_equal "maximum_below_next_required", rejection.rejection.fetch("reason")
  end
end
