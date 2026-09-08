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

  def test_proxy_adjustment_examples_preserve_deadline_even_when_public_view_changes
    cases = @example.fetch("independent_cases")
    adjustments = cases.reject { |row| row.fetch("operation") == "new_qualifying_bid" }
    assert_equal %w[increase_existing_proxy reduce_existing_proxy], adjustments.map { |row| row.fetch("operation") }.uniq.sort
    assert adjustments.any? { |row| row.fetch("public_projection_changed") }
    adjustments.each { |row| assert_equal "15:02", row.fetch("expected_group_close") }
    bid = cases.find { |row| row.fetch("operation") == "new_qualifying_bid" }
    assert_equal "15:04", bid.fetch("expected_group_close")
  end
end
