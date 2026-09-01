# frozen_string_literal: true

require "pathname"
require "yaml"

class ConformanceRunner
  ROOT = Pathname(__dir__).join("../../../..").expand_path

  def initialize(test_case)
    @test_case = test_case
  end

  def run(path)
    scenario = load_yaml(ROOT.join(path))
    fixture = load_yaml(ROOT.join(
      "conformance/fixtures/#{scenario.dig('configuration', 'fixture')}.yaml"
    ))
    engine = RBBB::Engine.new(RBBB::Configuration.from_h(fixture))
    state = engine.initial_state
    public_events = []
    privileged_events = []
    rejections = []

    scenario.fetch("commands").each do |command|
      decision = engine.decide(state, command)
      if decision.accepted?
        public_events.concat(decision.events.select(&:public?).map(&:to_h))
        privileged_events.concat(decision.events.select(&:privileged?).map(&:to_h))
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
  end

  private

  attr_reader :test_case

  def load_yaml(path)
    YAML.safe_load_file(path, aliases: false)
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
