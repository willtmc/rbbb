# frozen_string_literal: true

require "json"
require "pathname"
require_relative "test_helper"

class DecisionTest < Minitest::Test
  REJECTION_SCHEMA = Pathname(__dir__).join(
    "../../../specification/rejections/rejection.schema.json"
  ).expand_path

  def test_rejection_carries_only_command_id_and_reason_by_default
    decision = RBBB::Decision.rejected(command_id: "command-1", reason: "invalid_maximum")

    assert decision.rejected?
    assert_equal({"command_id" => "command-1", "reason" => "invalid_maximum"}, decision.rejection)
    assert decision.rejection.frozen?
  end

  def test_executed_floor_is_reported_only_for_maximum_below_executed_amount
    decision = RBBB::Decision.rejected(
      command_id: "command-1",
      reason: "maximum_below_executed_amount",
      executed_floor_minor_units: 31_000
    )

    assert_equal 31_000, decision.rejection.fetch("executed_floor_minor_units")
    assert_raises(ArgumentError) do
      RBBB::Decision.rejected(
        command_id: "command-1",
        reason: "maximum_not_reduced",
        executed_floor_minor_units: 31_000
      )
    end
  end

  def test_maximum_below_executed_amount_requires_an_integer_floor
    assert_raises(ArgumentError) do
      RBBB::Decision.rejected(command_id: "command-1", reason: "maximum_below_executed_amount")
    end
    assert_raises(ArgumentError) do
      RBBB::Decision.rejected(
        command_id: "command-1",
        reason: "maximum_below_executed_amount",
        executed_floor_minor_units: -1
      )
    end
  end

  def test_reason_specific_fields_match_the_rejection_schema
    schema = JSON.parse(REJECTION_SCHEMA.read)
    declared = schema.fetch("properties").keys - %w[command_id status reason]
    scoped = Array(schema["allOf"]).to_h do |clause|
      [clause.dig("if", "properties", "reason", "const"), Array(clause.dig("then", "required"))]
    end

    assert_equal false, schema.fetch("additionalProperties")
    assert_equal RBBB::Decision::REASON_SPECIFIC_FIELDS, scoped
    assert_equal declared.sort, RBBB::Decision::REASON_SPECIFIC_FIELDS.values.flatten.sort
  end
end
