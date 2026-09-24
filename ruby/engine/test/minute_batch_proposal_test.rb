# frozen_string_literal: true

require_relative "test_helper"
require "time"

# Checks proposed example arithmetic only, not scheduler behavior.
class MinuteBatchProposalTest < Minitest::Test
  def setup
    @example = JSON.parse(File.read(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/minute-batch-examples.json", __dir__)))
  end

  def test_explicit_order_maps_to_minute_batches_without_subminute_staggering
    assert_equal "proposed_examples_not_coordinator_execution", @example.fetch("status")
    start = Time.iso8601(@example.fetch("first_close"))
    count = @example.fetch("lots_per_minute")
    @example.fetch("ordered_units").each_with_index do |unit, index|
      expected = (start + (index / count) * 60).utc.strftime("%H:%M")
      assert_equal expected, @example.fetch("initial_slots").fetch(unit.fetch("unit_id"))
    end
  end

  def test_nonconsecutive_members_share_latest_slot_and_leave_other_slots_intact
    members = @example.fetch("group_members")
    labels = @example.fetch("ordered_units").select { |unit| members.include?(unit.fetch("unit_id")) }.map { |unit| unit.fetch("lot_number") }
    assert_equal %w[12 47 103], labels
    latest = members.map { |id| @example.fetch("initial_slots").fetch(id) }.max
    @example.fetch("resolved_closes").each do |id, close|
      assert_equal(members.include?(id) ? latest : @example.fetch("initial_slots").fetch(id), close)
    end
  end

  def test_only_the_current_leaders_own_adjustment_preserves_the_deadline
    cases = @example.fetch("independent_cases")
    leader_adjustments = cases.select { |row| row.fetch("bidder_role") == "current_leader" }
    assert_equal %w[increase_existing_proxy reduce_existing_proxy], leader_adjustments.map { |row| row.fetch("operation") }.uniq.sort
    assert leader_adjustments.any? { |row| row.fetch("public_projection_changed") }
    leader_adjustments.each do |row|
      refute row.fetch("leader_changed")
      assert_equal "15:02", row.fetch("expected_group_close")
    end
    qualifying = cases.reject { |row| row.fetch("bidder_role") == "current_leader" }
    assert_equal %w[new_bidder non_leader], qualifying.map { |row| row.fetch("bidder_role") }.sort
    assert qualifying.any? { |row| row.fetch("operation") == "increase_existing_proxy" }
    qualifying.each do |row|
      assert row.fetch("leader_changed")
      assert_equal "15:04", row.fetch("expected_group_close")
    end
  end

  def test_leader_reduction_examples_cannot_change_the_public_result
    reductions = @example.fetch("independent_cases").select { |row| row.fetch("operation") == "reduce_existing_proxy" }
    refute_empty reductions
    reductions.each { |row| refute row.fetch("public_projection_changed") }
  end
end
