# frozen_string_literal: true

require "pathname"
require "yaml"
require_relative "schema_assertions"

class ConformanceRunner
  ROOT = Pathname(__dir__).join("../../../..").expand_path
  AGGREGATE_SCHEMA = "specification/state/aggregate.schema.json"
  PUBLIC_STATE_SCHEMA = "specification/state/bidding-unit.schema.json"
  PUBLIC_EVENT_SCHEMA = "specification/events/public-event.schema.json"
  PRIVILEGED_EVENT_SCHEMA = "specification/events/privileged-event.schema.json"
  REJECTION_SCHEMA = "specification/rejections/rejection.schema.json"

  def initialize(test_case)
    @test_case = test_case
    test_case.extend(SchemaAssertions) unless test_case.is_a?(SchemaAssertions)
  end

  def run(path)
    scenario = load_yaml(ROOT.join(path))
    fixture = load_yaml(ROOT.join(
      "conformance/fixtures/#{scenario.dig('configuration', 'fixture')}.yaml"
    ))
    identity = {
      "auction_id" => "auction-conformance",
      "bidding_unit_id" => File.basename(path, ".yaml"),
      "currency" => fixture.fetch("currency")
    }
    engine = RBBB::Engine.new(RBBB::Configuration.from_h(fixture))
    state = engine.initial_state
    public_events = []
    public_envelopes = []
    privileged_events = []
    privileged_envelopes = []
    rejections = []

    scenario.fetch("commands").each do |command|
      decision = engine.decide(state, command)
      if decision.accepted?
        public_events.concat(decision.events.select(&:public?).map(&:to_h))
        privileged_events.concat(decision.events.select(&:privileged?).map(&:to_h))
        public_envelopes.concat(event_envelopes(identity, command, decision.events, visibility: :public))
        privileged_envelopes.concat(event_envelopes(identity, command, decision.events, visibility: :privileged))
        state = engine.apply(state, decision.events)
      else
        rejections << decision.rejection
      end
    end

    expected = scenario.fetch("expected")
    assert_collection(expected.fetch("public_events"), public_events, "public events")
    if expected.key?("privileged_events")
      expected_privileged = expected.fetch("privileged_events")
      expected_types = expected_privileged.map { |event| event.fetch("type") }.uniq
      relevant_privileged = privileged_events.select do |event|
        expected_types.include?(event.fetch("type"))
      end
      assert_collection(expected_privileged, relevant_privileged, "privileged events")
    end
    assert_collection(expected.fetch("rejections", []), rejections, "rejections")
    assert_subset(expected.fetch("final_state"), state.to_h, "final state")

    assert_schema(AGGREGATE_SCHEMA, identity.merge(state.to_h), "aggregate state")
    assert_schema(PUBLIC_STATE_SCHEMA, identity.merge(state.public_view), "public state")
    public_envelopes.each_with_index do |envelope, index|
      assert_schema(PUBLIC_EVENT_SCHEMA, envelope, "public event[#{index}]")
    end
    privileged_envelopes.each_with_index do |envelope, index|
      assert_schema(PRIVILEGED_EVENT_SCHEMA, envelope, "privileged event[#{index}]")
    end
    rejections.each_with_index do |rejection, index|
      assert_schema(REJECTION_SCHEMA, rejection, "rejection[#{index}]")
    end
  end

  private

  attr_reader :test_case

  def load_yaml(path)
    YAML.safe_load_file(path, aliases: false)
  end

  # Wraps each engine event of the given visibility in the transport envelope
  # described by specification/events/base.schema.json. The engine emits
  # command_id, aggregate_version, and (on transitions) effective_at inline;
  # the host lifts those into the envelope and supplies identity, ordering, and
  # recording fields.
  def event_envelopes(identity, command, events, visibility:)
    events.each_with_index.filter_map do |event, event_index|
      next unless event.visibility == visibility

      data = event.data.dup
      command_id = data.delete("command_id")
      aggregate_version = data.delete("aggregate_version")
      effective_at = data.delete("effective_at") || command.fetch("effective_at")
      {
        "event_id" => "#{command_id}-#{event_index}",
        "type" => event.type,
        "visibility" => visibility.to_s,
        "auction_id" => identity.fetch("auction_id"),
        "bidding_unit_id" => identity.fetch("bidding_unit_id"),
        "aggregate_version" => aggregate_version,
        "event_index" => event_index,
        "command_id" => command_id,
        "effective_at" => effective_at,
        "recorded_at" => effective_at,
        "data" => data
      }
    end
  end

  def assert_schema(schema_path, document, label)
    test_case.assert_matches_schema(test_case.load_schema(schema_path), document, path: label)
  end

  def assert_collection(expected, actual, label)
    test_case.assert_equal expected.length, actual.length, "#{label} count"
    expected.zip(actual).each_with_index do |(expected_item, actual_item), index|
      assert_subset(expected_item, actual_item, "#{label}[#{index}]")
    end
  end

  def assert_subset(expected, actual, label)
    expected.each do |key, expected_value|
      test_case.assert actual.key?(key), "#{label} is missing #{key}"
      actual_value = actual.fetch(key)
      if expected_value.is_a?(Hash)
        assert_subset(expected_value, actual_value, "#{label}.#{key}")
      elsif expected_value.nil?
        test_case.assert_nil actual_value, "#{label}.#{key}"
      else
        test_case.assert_equal expected_value, actual_value, "#{label}.#{key}"
      end
    end
  end
end
