# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"

# Executable contract checks, NOT coordinator behavior/conformance tests.
# The proposed capability remains unimplemented and outside the release API.
class FlexibleSchedulingProposalTest < Minitest::Test
  include SchemaAssertions

  DIRECTORY = "rfcs/proposals/flexible-live-scheduling"
  MAX_INTEGER = 9_007_199_254_740_991

  def setup
    @schema = load_schema("#{DIRECTORY}/contract.schema.json")
    @example = JSON.parse(ROOT.join("#{DIRECTORY}/merge-example.json").read)
  end

  def assert_document(kind, document)
    assert_matches_schema({"$ref" => "#/$defs/#{kind}"}, document, root: @schema)
  end

  def command
    @example.fetch("command")
  end

  def test_documents_remain_explicitly_proposed
    assert_equal "proposed", @schema.fetch("x-rbbb-status")
    assert_equal "proposed_shape_example_not_engine_execution", @example.fetch("status")
    %w[command public_change audit_event notification_intent].each do |kind|
      assert_document(kind, @example.fetch(kind))
      assert_matches_schema(@schema, @example.fetch(kind))
    end
    assert_document("rejection", @example.fetch("rejection_example"))
    assert_matches_schema(@schema, @example.fetch("rejection_example"))
  end

  def test_current_engine_does_not_accept_the_proposed_commands
    configuration = RBBB::Configuration.new(currency: "USD", opening_minor_units: 1000,
      increments: [{from_minor_units: 0, amount_minor_units: 100}],
      opens_at: "2031-04-17T10:00:00Z", closes_at: "2031-04-17T15:00:00Z")
    engine = RBBB::Engine.new(configuration)
    %w[revise_closing_schedule reconfigure_closing_groups].each do |type|
      decision = engine.decide(engine.initial_state, command.merge("type" => type))
      assert decision.rejected?
      assert_empty decision.events
    end
  end

  def test_example_receipt_links_one_commit_and_exactly_the_requested_result
    public_change = @example.fetch("public_change")
    audit = @example.fetch("audit_event")
    notice = @example.fetch("notification_intent")
    [public_change, audit, notice].each do |document|
      assert_equal command.fetch("command_id"), document.fetch("command_id")
      assert_equal command.fetch("auction_id"), document.fetch("auction_id")
      assert_equal command.fetch("effective_at"), document.fetch("effective_at")
      assert_equal public_change.fetch("commit_id"), document.fetch("commit_id")
    end
    assert_equal command.fetch("resulting_closing_sets"), public_change.fetch("resulting_closing_sets")
    assert_equal command.fetch("resulting_closing_sets"), audit.fetch("resulting_closing_sets")
    assert_equal command.fetch("expected_units"), audit.fetch("previous_unit_versions")
    assert_equal command.fetch("expected_schedule_revision"), audit.fetch("previous_schedule_revision")
    assert_equal audit.fetch("previous_schedule_revision") + 1, audit.fetch("schedule_revision")
    assert_equal audit.fetch("schedule_revision"), public_change.fetch("schedule_revision")
    assert_equal audit.fetch("unit_versions"), public_change.fetch("unit_versions")
    expected_versions = command.fetch("expected_units").map do |entry|
      entry.merge("version" => entry.fetch("version") + 1)
    end
    assert_equal expected_versions, audit.fetch("unit_versions")
    assert_equal command.fetch("retired_group_ids"), audit.fetch("retired_group_ids")
    assert_equal command.fetch("retired_group_ids"), public_change.fetch("retired_group_ids")
    assert_equal command.fetch("expected_units").map { |entry| entry.fetch("unit_id") }.sort,
      notice.fetch("affected_unit_ids").sort
  end

  def test_public_projection_refuses_private_values_and_unknown_fields
    %w[reason operator_id bidder_id maximum_minor_units reserve_minor_units positions].each do |field|
      leaked = @example.fetch("public_change").merge(field => "private")
      assert_raises(Minitest::Assertion) { assert_document("public_change", leaked) }
    end
    leaked = @example.fetch("public_change")
    leaked.fetch("resulting_closing_sets").first["maximum_minor_units"] = 5000
    assert_raises(Minitest::Assertion) { assert_document("public_change", leaked) }
  end

  def test_command_rejects_self_asserted_authorization_and_missing_shortening_intent
    assert_raises(Minitest::Assertion) { assert_document("command", command.merge("authorized" => true)) }
    assert_raises(Minitest::Assertion) { assert_document("command", command.except("allow_shortening")) }
    command["allow_shortening"] = false
    # Shape-valid does not mean authorized or semantically accepted.
    assert_document("command", command)
  end

  def test_numeric_limits_are_enforced_through_chained_external_references
    command["expected_schedule_revision"] = MAX_INTEGER
    assert_document("command", command)
    command["expected_schedule_revision"] += 1
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
    command["expected_schedule_revision"] = -1
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
  end

  def test_extension_duration_is_positive_bounded_and_exact
    extension = command.fetch("resulting_closing_sets").first.fetch("extension")
    [0, -1, MAX_INTEGER + 1, 1.5].each do |invalid|
      extension["duration_seconds"] = invalid
      assert_raises(Minitest::Assertion) { assert_document("command", command) }
    end
    extension["duration_seconds"] = MAX_INTEGER
    assert_document("command", command)
  end

  def test_timestamp_requires_offset_and_at_most_milliseconds
    ["2031-04-17T12:00:00", "2031-04-17T12:00:00.0001Z"].each do |invalid|
      command["effective_at"] = invalid
      assert_raises(Minitest::Assertion) { assert_document("command", command) }
    end
    command["effective_at"] = "2031-04-17T12:00:00.001Z"
    assert_document("command", command)
  end

  def test_membership_and_ungrouped_cardinality_are_closed_shapes
    closing_set = command.fetch("resulting_closing_sets").first
    closing_set["member_unit_ids"] = []
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
    closing_set["member_unit_ids"] = ["unit-a", "unit-a"]
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
    closing_set["member_unit_ids"] = ["unit-a", "unit-b"]
    closing_set["group_id"] = nil
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
    closing_set["member_unit_ids"] = ["unit-a"]
    assert_document("command", command)
  end

  def test_schedule_only_operation_cannot_retire_groups
    command["type"] = "revise_closing_schedule"
    assert_raises(Minitest::Assertion) { assert_document("command", command) }
    command["retired_group_ids"] = []
    assert_document("command", command)
  end

  def test_reason_is_nonblank_bounded_and_never_echoed_in_rejection
    ["", " \n ", "x" * 2049].each do |invalid|
      command["reason"] = invalid
      assert_raises(Minitest::Assertion) { assert_document("command", command) }
    end
    rejection = @example.fetch("rejection_example").merge("operator_reason" => "private")
    assert_raises(Minitest::Assertion) { assert_document("rejection", rejection) }
  end

  def test_identifiers_are_bounded_single_tokens
    ["x" * 129, "\nunit-a", "unit-a\n", "unit-a extra"].each do |invalid|
      command["command_id"] = invalid
      assert_raises(Minitest::Assertion) { assert_document("command", command) }
    end
  end
end
