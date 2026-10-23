# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_admission"

class RevocationBoundaryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @at = "2034-02-10T12:30:00Z"
    config = {"currency" => "USD", "opening_minor_units" => 10_000,
      "reserve_minor_units" => nil, "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 1_000}],
      "opens_at" => "2034-02-10T12:00:00Z", "closes_at" => "2034-02-10T13:00:00Z"}
    state = RBBB::State.empty(RBBB::Configuration.from_h(config)).to_h
    @host = RBBBExamples::LiveSchedulingHost.new(path: File.join(@directory, "auction.sqlite3"),
      tenant_id: "tenant-demo", auction_id: "auction-demo", configurations: {"unit-demo" => config},
      snapshot: {"schedule_revision" => 0, "units" => {"unit-demo" => state},
        "closing_sets" => [{"group_id" => nil, "member_unit_ids" => ["unit-demo"],
          "closes_at" => config.fetch("closes_at"), "extension" => nil}]},
      policy: {"minimum_shortening_lead_seconds" => 60}, clock: -> { @at })
    @admission = RBBBExamples::LiveSchedulingAdmission.new(host: @host,
      authenticate: ->(credential) { %w[bidder-a bidder-b operator-demo].include?(credential) ? credential : nil },
      authorize: ->(**scope) { scope[:action] == "bid" || scope[:principal_id] == "operator-demo" },
      permissions: ->(**scope) { scope[:principal_id] == "operator-demo" ? %w[void close] : ["bid"] })
    bid("bidder-a", "maximum-a", 16_000)
    bid("bidder-b", "challenge-b", 14_200)
    assert_equal 15_000, unit.fetch("standing_minor_units")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def unit = @host.snapshot.fetch("units").fetch("unit-demo")

  def bid(who, id, amount, type: "place_bid")
    @admission.bid(credential: who, unit_id: "unit-demo",
      command: {"type" => type, "command_id" => id, "maximum_minor_units" => amount})
  end

  def correction(id: "operator-correction", reason: "Duplicate authorization confirmed by operator")
    {"type" => "void_bid", "command_id" => id, "bid_id" => "maximum-a",
      "reason" => reason, "notification_policy" => "affected"}
  end

  def test_bidder_cancels_unused_authority_but_cannot_revoke_executed_competition
    before = @host.snapshot
    [0, 14_200, 14_999].each_with_index do |amount, index|
      result = bid("bidder-a", "invalid-cancel-#{index}", amount, type: "reduce_maximum")
      assert_equal "maximum_below_executed_amount", result.fetch("rejection_reason")
      assert_empty result.fetch("records")
      assert_equal before, @host.snapshot
    end
    result = bid("bidder-a", "cancel-unused", 15_000, type: "reduce_maximum")
    assert_nil result.fetch("rejection_reason")
    assert_equal 15_000, unit.fetch("positions").fetch("bidder-a").fetch("maximum_minor_units")
    assert_equal 15_000, unit.fetch("positions").fetch("bidder-a").fetch("executed_minor_units")
    assert_equal 15_000, unit.fetch("standing_minor_units")
    assert_equal "bidder-a", unit.fetch("leader_id")
    assert_equal 16_000, unit.fetch("next_required_minor_units")
    refute result.fetch("records").any? { |record| record.dig("event", "type") == "standing_bid_changed" }
  end

  def test_bidder_cannot_use_operator_route_or_spoof_operator_identity
    before = @host.snapshot
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) do
      @admission.void_bid(credential: "bidder-a", unit_id: "unit-demo", command: correction)
    end
    assert_raises(ArgumentError) do
      @admission.bid(credential: "bidder-a", unit_id: "unit-demo", command: correction)
    end
    assert_raises(ArgumentError) do
      @admission.void_bid(credential: "bidder-a", principal_id: "operator-demo",
        permissions: ["void"], unit_id: "unit-demo", command: correction)
    end
    assert_equal before, @host.snapshot
  end

  def test_operator_correction_requires_reason_and_retains_an_audited_event
    before = @host.snapshot
    invalid = @admission.void_bid(credential: "operator-demo", unit_id: "unit-demo", command: correction(reason: ""))
    assert_equal "invalid_command", invalid.fetch("rejection_reason")
    assert_empty invalid.fetch("records")
    assert_equal before, @host.snapshot
    result = @admission.void_bid(credential: "operator-demo", unit_id: "unit-demo",
      command: correction(id: "valid-correction"))
    assert_nil result.fetch("rejection_reason")
    event = result.fetch("records").find { |record| record.dig("event", "type") == "bid_voided" }.fetch("event")
    assert_equal "operator-demo", event.fetch("operator_id")
    assert_equal "maximum-a", event.fetch("bid_id")
    assert_equal correction.fetch("reason"), event.fetch("reason")
    assert_equal @at, event.fetch("effective_at")
    assert_equal "bidder-b", unit.fetch("leader_id")
    assert_equal "maximum-a", unit.fetch("authorization_history").first.fetch("bid_id")
    assert_includes unit.fetch("voided_bid_ids"), "maximum-a"
    retry_result = @admission.void_bid(credential: "operator-demo", unit_id: "unit-demo",
      command: correction(id: "valid-correction"))
    assert_equal result.merge("replayed" => true), retry_result
  end

  def test_operator_cannot_correct_after_closing
    @at = "2034-02-10T13:01:00Z"
    before = @host.snapshot
    result = @admission.void_bid(credential: "operator-demo", unit_id: "unit-demo", command: correction)
    assert_equal "bidding_closed", result.fetch("rejection_reason")
    assert_empty result.fetch("records")
    assert_equal before, @host.snapshot
  end
end
