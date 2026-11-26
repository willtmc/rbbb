# frozen_string_literal: true

require "json"
require "pathname"
require_relative "test_helper"

class DecisionTest < Minitest::Test
  REJECTION_SCHEMA = Pathname(__dir__).join(
    "../../../specification/rejections/rejection.schema.json"
  ).expand_path

  def test_rejection_carries_only_command_id_status_and_reason_by_default
    decision = RBBB::Decision.rejected(command_id: "command-1", reason: "invalid_maximum")

    assert decision.rejected?
    assert_equal(
      {"command_id" => "command-1", "status" => "rejected", "reason" => "invalid_maximum"},
      decision.rejection
    )
    assert decision.rejection.frozen?
  end

  def test_rejection_satisfies_the_schema_required_fields_and_status_constant
    schema = JSON.parse(REJECTION_SCHEMA.read)
    decision = RBBB::Decision.rejected(command_id: "command-1", reason: "invalid_maximum")

    assert_empty schema.fetch("required") - decision.rejection.keys
    assert_equal schema.dig("properties", "status", "const"), decision.rejection.fetch("status")
    assert_equal RBBB::Decision::REJECTED_STATUS, decision.rejection.fetch("status")
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

  def test_event_accessors_and_value_equality
    engine = RBBB::Engine.new(RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 10_000,
      increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z"
    ))
    command = {
      command_id: "command-1",
      type: "place_bid",
      bidder_id: "bidder-a",
      maximum_minor_units: 50_000,
      effective_at: "2026-09-01T12:30:00Z"
    }
    first = engine.decide(engine.initial_state, command)
    second = engine.decide(engine.initial_state, command)

    assert_equal "maximum_accepted", first.transition_event.type
    assert_equal ["standing_bid_changed"], first.public_events.map(&:type)
    assert_equal ["maximum_accepted"], first.privileged_events.map(&:type)
    assert_equal first, second
    assert first.eql?(second)
    assert_equal first.hash, second.hash
    assert_equal first.events.first, second.events.first
    assert_equal first.events.first.hash, second.events.first.hash

    public_event = RBBB::Event.new(type: "closing_time_changed", visibility: :public, data: {a: 1})
    privileged_event = RBBB::Event.new(type: "closing_time_changed", visibility: :privileged, data: {a: 1})
    refute_equal public_event, privileged_event

    rejected_a = RBBB::Decision.rejected(command_id: "command-1", reason: "invalid_command")
    rejected_b = RBBB::Decision.rejected(command_id: "command-1", reason: "invalid_command")
    assert_nil rejected_a.transition_event
    assert_empty rejected_a.public_events
    assert_empty rejected_a.privileged_events
    assert_equal rejected_a, rejected_b
    assert_equal rejected_a.hash, rejected_b.hash
    refute_equal first, rejected_a
  end
end
