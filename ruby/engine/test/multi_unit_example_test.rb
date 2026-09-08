# frozen_string_literal: true

require_relative "test_helper"
require_relative "../../../examples/multi_unit_auction"

class MultiUnitExampleTest < Minitest::Test
  def setup
    @report = RBBBExamples::MultiUnitAuction.new.run
  end

  def test_interleaved_bidding_recovery_and_all_three_outcomes
    units = @report.fetch("public_units")
    assert_equal "sold", units.fetch("unit-a").fetch("result")
    assert_equal 5_100, units.fetch("unit-a").fetch("winning_minor_units")
    assert_equal "no_sale", units.fetch("unit-b").fetch("result")
    assert_equal "no_bid", units.fetch("unit-c").fetch("result")
    assert @report.fetch("event_replay_matches")
    assert @report.fetch("trace").any? { |row| row["operation"] == "recover_from_serialized_events" }
    assert_equal @report, RBBBExamples::MultiUnitAuction.new.run
  end

  def test_late_registration_and_soft_close_do_not_mutate_other_units
    trace = @report.fetch("trace")
    registration = trace.find { |row| row["operation"] == "register_independent_unit" && row["unit_id"] == "unit-c" }
    assert_operator registration.fetch("public_units").fetch("unit-a").fetch("version"), :>, 0
    assert_equal 0, registration.fetch("public_units").fetch("unit-c").fetch("version")
    extended = step("challenger").fetch("public_units")
    assert_equal "2030-01-01T13:03:00Z", extended.fetch("unit-a").fetch("closes_at")
    assert_equal "2030-01-01T13:00:00Z", extended.fetch("unit-b").fetch("closes_at")
    assert_equal registration.fetch("public_units").fetch("unit-b"), extended.fetch("unit-b")
  end

  def test_rejected_schedule_and_close_operations_leave_state_unchanged
    {"shorten" => "closing_time_may_not_shorten_after_first_bid", "regroup" => "unsupported_command",
     "early-close" => "closing_time_not_reached", "late-bid" => "bidding_closed"}.each do |id, reason|
      trace = @report.fetch("trace")
      index = trace.index { |row| row["command_id"] == id }
      refute trace[index].fetch("accepted")
      assert_equal reason, trace[index].fetch("rejection_reason")
      assert_equal trace[index - 1].fetch("public_units"), trace[index].fetch("public_units")
    end
  end

  def test_public_report_does_not_contain_privileged_state_or_input
    text = JSON.generate(@report)
    %w[bidder-a bidder-b bidder-c bidder-d operator-a maximum_minor_units positions winner_id leader_id reserve_minor_units authorization_history].each do |private_value|
      refute_includes text, private_value
    end
  end

  private

  def step(command_id)
    @report.fetch("trace").find { |row| row["command_id"] == command_id }
  end
end
