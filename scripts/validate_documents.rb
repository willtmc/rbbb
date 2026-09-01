# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

ROOT = Pathname(__dir__).join("..").expand_path

def relative(path)
  Pathname(path).relative_path_from(ROOT)
end

def deep_keys(value)
  case value
  when Hash
    value.flat_map { |key, nested| [key, *deep_keys(nested)] }
  when Array
    value.flat_map { |nested| deep_keys(nested) }
  else
    []
  end
end

errors = []

Dir[ROOT.join("{specification,conformance}/**/*.json")].sort.each do |path|
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  errors << "#{relative(path)}: invalid JSON: #{e.message}"
end

Dir[ROOT.join("{specification,conformance}/**/*.{yaml,yml}")].sort.each do |path|
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::Exception => e
  errors << "#{relative(path)}: invalid or unsafe YAML: #{e.message}"
end

openapi = YAML.safe_load_file(ROOT.join("specification/openapi.yaml"), aliases: false)
errors << "specification/openapi.yaml: expected OpenAPI 3.1" unless openapi["openapi"]&.start_with?("3.1.")
errors << "specification/openapi.yaml: paths must be an object" unless openapi["paths"].is_a?(Hash)

asyncapi = YAML.safe_load_file(ROOT.join("specification/asyncapi.yaml"), aliases: false)
errors << "specification/asyncapi.yaml: expected AsyncAPI 3" unless asyncapi["asyncapi"]&.start_with?("3.")
errors << "specification/asyncapi.yaml: channels must be an object" unless asyncapi["channels"].is_a?(Hash)

schemas = Dir[ROOT.join("{specification,conformance}/**/*.schema.json")]
schemas.each do |path|
  schema = JSON.parse(File.read(path))
  errors << "#{relative(path)}: missing $schema" unless schema.key?("$schema")
  errors << "#{relative(path)}: missing $id" unless schema.key?("$id")
end

scenario_paths = Dir[ROOT.join("conformance/scenarios/**/*.yaml")].sort
scenario_names = {}

scenario_paths.each do |path|
  scenario = YAML.safe_load_file(path, aliases: false)
  required = %w[name specification_version rfcs configuration starting_state commands expected]
  missing = required.reject { |key| scenario.key?(key) }
  errors << "#{relative(path)}: missing #{missing.join(', ')}" if missing.any?

  name = scenario["name"]
  if scenario_names.key?(name)
    errors << "#{relative(path)}: duplicate name also used by #{scenario_names[name]}"
  else
    scenario_names[name] = relative(path)
  end

  fixture = scenario.dig("configuration", "fixture")
  fixture_path = ROOT.join("conformance/fixtures/#{fixture}.yaml") if fixture
  errors << "#{relative(path)}: unknown fixture #{fixture}" if fixture && !fixture_path.file?

  Array(scenario["rfcs"]).each do |rfc|
    matches = Dir[ROOT.join("rfcs/#{rfc}-*.md")]
    errors << "#{relative(path)}: unknown RFC #{rfc}" if matches.empty?
  end

  expected = scenario["expected"] || {}
  errors << "#{relative(path)}: expected.public_events must be an array" unless expected["public_events"].is_a?(Array)
  errors << "#{relative(path)}: expected.final_state must be an object" unless expected["final_state"].is_a?(Hash)

  forbidden_public_keys = /maximum|reserve_minor_units|operator_id|reason|bidder_id|leader_id|winner_id/
  Array(expected["public_events"]).each_with_index do |event, index|
    leaked = deep_keys(event).grep(forbidden_public_keys).uniq
    next if leaked.empty?

    errors << "#{relative(path)}: public_events[#{index}] contains privileged keys: #{leaked.join(', ')}"
  end
end

if errors.any?
  warn errors.join("\n")
  exit 1
end

puts "Validated #{schemas.length} JSON Schemas, #{scenario_paths.length} conformance scenarios, and the OpenAPI/AsyncAPI documents."
