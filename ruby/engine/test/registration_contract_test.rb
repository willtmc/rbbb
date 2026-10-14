# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"

# Contract/schema checks only: no registration coordinator/host is exercised.
class RegistrationContractTest < Minitest::Test
  include SchemaAssertions

  DIRECTORY = "rfcs/proposals/flexible-live-scheduling"

  def setup
    @schema = load_schema("#{DIRECTORY}/registration.schema.json")
    @intent = {
      "type" => "register_unit", "command_id" => "registration-one",
      "auction_id" => "auction-synthetic", "unit_id" => "unit-new",
      "expected_schedule_revision" => 7, "reason" => "Synthetic inventory arrival",
      "configuration" => {
        "currency" => "USD", "opening_minor_units" => 100, "reserve_minor_units" => 500,
        "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 25}],
        "opens_at" => "2031-04-05T11:00:00Z", "closes_at" => "2031-04-05T13:30:00Z",
        "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}
      }
    }
    configuration = RBBB::Configuration.new(**@intent.fetch("configuration").transform_keys(&:to_sym))
    @state = RBBB::Engine.new(configuration).initial_state.to_h
    @creation = {
      "capability" => "flexible_live_scheduling_draft_1", "type" => "bidding_unit_registered",
      "visibility" => "privileged", "command_id" => "registration-one",
      "commit_id" => "commit-synthetic", "auction_id" => "auction-synthetic", "unit_id" => "unit-new",
      "effective_at" => "2031-04-05T12:00:00Z", "operator_id" => "operator-synthetic",
      "reason" => @intent.fetch("reason"), "configuration" => @intent.fetch("configuration"), "state" => @state
    }
  end

  def assert_registration(kind, value)
    assert_matches_schema({"$ref" => "#/$defs/#{kind}"}, value, root: @schema)
  end

  def test_accepted_shapes_are_not_execution_certification
    assert_equal "accepted-contract", @schema.fetch("x-rbbb-status")
    assert_registration("intent", @intent)
    assert_registration("creation", @creation)
    assert_matches_schema(@schema, @intent)
    assert_matches_schema(@schema, @creation)
  end

  def test_intent_is_closed_and_rejects_server_fields
    %w[operator_id effective_at state version group_id capability authorized].each do |field|
      assert_raises(Minitest::Assertion) { assert_registration("intent", @intent.merge(field => true)) }
    end
    @intent.keys.each do |field|
      assert_raises(Minitest::Assertion) { assert_registration("intent", @intent.reject { |key, _| key == field }) }
    end
    @intent.fetch("configuration")["unknown"] = true
    assert_raises(Minitest::Assertion) { assert_registration("intent", @intent) }
  end

  def test_identifier_reason_and_revision_boundaries
    ["", "unit extra", "x" * 129].each do |value|
      assert_raises(Minitest::Assertion) { assert_registration("intent", @intent.merge("unit_id" => value)) }
    end
    ["", " \n", "x" * 2049].each do |value|
      assert_raises(Minitest::Assertion) { assert_registration("intent", @intent.merge("reason" => value)) }
    end
    [-1, 1.5, 9_007_199_254_740_992].each do |value|
      assert_raises(Minitest::Assertion) { assert_registration("intent", @intent.merge("expected_schedule_revision" => value)) }
    end
    assert_registration("intent", @intent.merge("expected_schedule_revision" => 9_007_199_254_740_991))
  end

  def test_creation_has_exact_baseline_empty_state_and_null_unit_clock
    expected = {
      "version" => 0, "status" => "open", "opens_at" => "2031-04-05T11:00:00Z",
      "closes_at" => "2031-04-05T13:30:00Z", "last_effective_at" => nil,
      "reserve_minor_units" => 500, "reserve_status" => "reserve_not_met",
      "leader_id" => nil, "standing_minor_units" => nil, "next_required_minor_units" => 100,
      "positions" => {}, "authorization_history" => [], "reserve_history" => [],
      "voided_bid_ids" => [], "result" => nil, "winner_id" => nil, "winning_minor_units" => nil
    }
    assert_equal expected, @state
    assert_registration("creation", @creation)
    [{"version" => 1}, {"last_effective_at" => @creation.fetch("effective_at")},
      {"positions" => {"bidder-synthetic" => {}}}, {"authorization_history" => [{}]}].each do |change|
      assert_raises(Minitest::Assertion) do
        assert_registration("creation", @creation.merge("state" => @state.merge(change)))
      end
    end
  end

  def test_identity_conflict_rejection_is_finite_and_private_diagnostics_are_absent
    schema = load_schema("#{DIRECTORY}/contract.schema.json")
    rejection = {"capability" => "flexible_live_scheduling_draft_1",
      "type" => "closing_change_rejected", "command_id" => "registration-one", "reason" => "unit_id_conflict"}
    assert_matches_schema({"$ref" => "#/$defs/rejection"}, rejection, root: schema)
    [rejection.merge("reason" => "arbitrary"), rejection.merge("configuration" => @intent.fetch("configuration"))].each do |invalid|
      assert_raises(Minitest::Assertion) do
        assert_matches_schema({"$ref" => "#/$defs/rejection"}, invalid, root: schema)
      end
    end
  end

  def test_public_delta_cannot_contain_creation_or_private_fields
    public_schema = load_schema("#{DIRECTORY}/contract.schema.json")
    delta = {
      "capability" => "flexible_live_scheduling_draft_1", "type" => "closing_configuration_changed",
      "visibility" => "public", "command_id" => "registration-one", "commit_id" => "commit-synthetic",
      "auction_id" => "auction-synthetic", "effective_at" => "2031-04-05T12:00:00Z",
      "schedule_revision" => 8, "unit_versions" => [{"unit_id" => "unit-new", "version" => 0}],
      "resulting_closing_sets" => [{"group_id" => nil, "member_unit_ids" => ["unit-new"],
        "closes_at" => "2031-04-05T13:30:00Z", "extension" => @intent.fetch("configuration").fetch("extension")}],
      "retired_group_ids" => []
    }
    assert_matches_schema({"$ref" => "#/$defs/public_change"}, delta, root: public_schema)
    %w[configuration state reserve_minor_units reason operator_id].each do |field|
      assert_raises(Minitest::Assertion) do
        assert_matches_schema({"$ref" => "#/$defs/public_change"}, delta.merge(field => "private"), root: public_schema)
      end
    end
    assert_raises(Minitest::Assertion) { assert_registration("creation", @creation.merge("visibility" => "public")) }
  end
end
