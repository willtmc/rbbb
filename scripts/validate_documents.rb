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

def walk(value, &block)
  yield value
  case value
  when Hash
    value.each_value { |nested| walk(nested, &block) }
  when Array
    value.each { |nested| walk(nested, &block) }
  end
end

def load_document(path)
  if path.extname == ".json"
    JSON.parse(path.read)
  else
    YAML.safe_load_file(path, aliases: false)
  end
end

def resolve_pointer(document, fragment)
  return document if fragment.nil? || fragment.empty?
  raise "fragment must be a JSON Pointer" unless fragment.start_with?("/")

  fragment.delete_prefix("/").split("/").reduce(document) do |value, token|
    decoded = token.gsub("~1", "/").gsub("~0", "~")
    if value.is_a?(Hash)
      value.fetch(decoded)
    elsif value.is_a?(Array)
      value.fetch(Integer(decoded, 10))
    else
      raise "pointer traverses a scalar"
    end
  end
end

def discriminator_values(document)
  values = []
  walk(document) do |node|
    next unless node.is_a?(Hash) && node["properties"].is_a?(Hash)

    discriminator = node.dig("properties", "type")
    next unless discriminator.is_a?(Hash)

    values << discriminator["const"] if discriminator.key?("const")
    values.concat(discriminator["enum"]) if discriminator["enum"].is_a?(Array)
  end
  values.compact.uniq
end

def property_names(document)
  names = []
  walk(document) do |node|
    names.concat(node["properties"].keys) if node.is_a?(Hash) && node["properties"].is_a?(Hash)
  end
  names.uniq
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

schemas = Dir[ROOT.join("{specification,conformance}/**/*.schema.json")].sort
schema_documents = {}
schema_ids = {}
schemas.each do |path_string|
  path = Pathname(path_string)
  schema = JSON.parse(path.read)
  schema_documents[path] = schema
  errors << "#{relative(path)}: missing $schema" unless schema.key?("$schema")
  errors << "#{relative(path)}: missing $id" unless schema.key?("$id")
  if path.to_s.start_with?(ROOT.join("specification").to_s + "/") &&
      !%w[draft experimental stable].include?(schema["x-rbbb-status"])
    errors << "#{relative(path)}: missing or invalid x-rbbb-status"
  end
  if schema["$id"]
    if schema_ids.key?(schema["$id"])
      errors << "#{relative(path)}: duplicate $id also used by #{relative(schema_ids[schema['$id']])}"
    else
      schema_ids[schema["$id"]] = path
    end
  end

  walk(schema) do |node|
    next unless node.is_a?(Hash)

    if node["required"].is_a?(Array) && node["properties"].is_a?(Hash)
      missing_properties = node["required"] - node["properties"].keys
      if missing_properties.any?
        errors << "#{relative(path)}: required fields lack properties: #{missing_properties.join(', ')}"
      end
    end
  end
end

document_cache = schema_documents.dup
documents_with_refs = {
  Pathname(ROOT.join("specification/openapi.yaml")) => openapi,
  Pathname(ROOT.join("specification/asyncapi.yaml")) => asyncapi
}.merge(schema_documents)

documents_with_refs.each do |path, document|
  walk(document) do |node|
    next unless node.is_a?(Hash) && node["$ref"].is_a?(String)

    file_part, fragment = node.fetch("$ref").split("#", 2)
    target_path = if file_part.empty?
      path
    else
      path.dirname.join(file_part).cleanpath
    end
    unless target_path.to_s.start_with?(ROOT.to_s + "/") && target_path.file?
      errors << "#{relative(path)}: unresolved $ref #{node.fetch('$ref')}"
      next
    end

    begin
      target = document_cache[target_path] ||= load_document(target_path)
      resolve_pointer(target, fragment)
    rescue KeyError, IndexError, ArgumentError, RuntimeError => e
      errors << "#{relative(path)}: invalid $ref #{node.fetch('$ref')}: #{e.message}"
    end
  end
end

scenario_paths = Dir[ROOT.join("conformance/scenarios/**/*.yaml")].sort
scenario_names = {}
scenario_command_types = []
scenario_public_event_types = []
scenario_privileged_event_types = []
scenario_rejection_reasons = []
scenario_rejections = []

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

  scenario_command_types.concat(Array(scenario["commands"]).filter_map { |command| command["type"] })
  scenario_public_event_types.concat(Array(expected["public_events"]).filter_map { |event| event["type"] })
  scenario_privileged_event_types.concat(Array(expected["privileged_events"]).filter_map { |event| event["type"] })
  scenario_rejection_reasons.concat(Array(expected["rejections"]).filter_map { |rejection| rejection["reason"] })
  Array(expected["rejections"]).each_with_index do |rejection, index|
    scenario_rejections << [relative(path), index, rejection] if rejection.is_a?(Hash)
  end
end

command_base = schema_documents.fetch(ROOT.join("specification/commands/base.schema.json"))
schema_command_types = command_base.dig("properties", "type", "enum") || []
missing_commands = scenario_command_types.uniq - schema_command_types
errors << "command schemas omit conformance types: #{missing_commands.join(', ')}" if missing_commands.any?

command_union = schema_documents.fetch(ROOT.join("specification/commands/command.schema.json"))
union_command_types = Array(command_union["oneOf"]).flat_map do |entry|
  ref = entry["$ref"]
  next [] unless ref

  target = ROOT.join("specification/commands").join(ref).cleanpath
  discriminator_values(schema_documents.fetch(target))
end.uniq
unless union_command_types.sort == schema_command_types.sort
  errors << "command union types do not match the command envelope enum"
end

public_event_schema = schema_documents.fetch(ROOT.join("specification/events/public-event.schema.json"))
missing_public_events = scenario_public_event_types.uniq - discriminator_values(public_event_schema)
if missing_public_events.any?
  errors << "public event schema omits conformance types: #{missing_public_events.join(', ')}"
end

privileged_event_schema = schema_documents.fetch(ROOT.join("specification/events/privileged-event.schema.json"))
missing_privileged_events = scenario_privileged_event_types.uniq - discriminator_values(privileged_event_schema)
if missing_privileged_events.any?
  errors << "privileged event schema omits conformance types: #{missing_privileged_events.join(', ')}"
end

rejection_schema = schema_documents.fetch(ROOT.join("specification/rejections/rejection.schema.json"))
schema_rejections = rejection_schema.dig("properties", "reason", "enum") || []
missing_rejections = scenario_rejection_reasons.uniq - schema_rejections
errors << "rejection schema omits conformance reasons: #{missing_rejections.join(', ')}" if missing_rejections.any?
if rejection_schema.fetch("properties").key?("details")
  errors << "specification/rejections/rejection.schema.json: open-ended details risk privileged disclosure"
end

# Rejections may carry only finite, reason-specific fields. Each extra
# property must be required by exactly one reason's conditional clause and
# forbidden for every other reason, and scenarios may assert only declared
# keys for the reason they name.
rejection_base_fields = %w[command_id status reason]
rejection_fields_by_reason = Hash.new { |hash, reason| hash[reason] = [] }
Array(rejection_schema["allOf"]).each do |clause|
  reason = clause.dig("if", "properties", "reason", "const")
  fields = Array(clause.dig("then", "required"))
  next if reason.nil? || fields.empty?

  unless schema_rejections.include?(reason)
    errors << "specification/rejections/rejection.schema.json: reason-specific clause names unknown reason #{reason}"
  end
  unless Array(clause.dig("else", "not", "required")).sort == fields.sort
    errors << "specification/rejections/rejection.schema.json: #{fields.join(', ')} must be forbidden for reasons other than #{reason}"
  end
  rejection_fields_by_reason[reason].concat(fields)
end
scoped_rejection_fields = rejection_fields_by_reason.values.flatten
duplicated_rejection_fields = scoped_rejection_fields.tally.select { |_, count| count > 1 }.keys
if duplicated_rejection_fields.any?
  errors << "specification/rejections/rejection.schema.json: rejection fields must belong to exactly one reason: #{duplicated_rejection_fields.join(', ')}"
end
unscoped_rejection_fields = rejection_schema.fetch("properties").keys - rejection_base_fields - scoped_rejection_fields
if unscoped_rejection_fields.any?
  errors << "specification/rejections/rejection.schema.json: rejection fields must be reason-specific: #{unscoped_rejection_fields.join(', ')}"
end
undeclared_rejection_fields = scoped_rejection_fields - rejection_schema.fetch("properties").keys
if undeclared_rejection_fields.any?
  errors << "specification/rejections/rejection.schema.json: reason-specific fields lack properties: #{undeclared_rejection_fields.join(', ')}"
end
unless rejection_schema["additionalProperties"] == false
  errors << "specification/rejections/rejection.schema.json: additionalProperties must be false"
end

scenario_rejections.each do |label, index, rejection|
  allowed_keys = rejection_base_fields + rejection_fields_by_reason.fetch(rejection["reason"], [])
  undeclared_keys = rejection.keys - allowed_keys
  next if undeclared_keys.empty?

  errors << "#{label}: rejections[#{index}] contains keys the rejection schema does not declare for #{rejection['reason']}: #{undeclared_keys.join(', ')}"
end

forbidden_contract_keys = /maximum|reserve_minor_units|operator_id|reason|bidder_id|leader_id|winner_id/
{
  "specification/events/public-event.schema.json" => public_event_schema,
  "specification/state/bidding-unit.schema.json" => schema_documents.fetch(
    ROOT.join("specification/state/bidding-unit.schema.json")
  )
}.each do |label, document|
  leaked = property_names(document).grep(forbidden_contract_keys)
  errors << "#{label}: public schema contains privileged properties: #{leaked.join(', ')}" if leaked.any?
end

unless openapi.dig("paths", "/v1/commands", "post", "requestBody", "content",
    "application/json", "schema", "$ref") == "./commands/command.schema.json"
  errors << "specification/openapi.yaml: command endpoint must use the command union"
end
command_result = openapi.dig("components", "schemas", "CommandResult") || {}
unless command_result.dig("properties", "public_events", "items", "$ref") ==
    "./events/public-event.schema.json"
  errors << "specification/openapi.yaml: command results must expose only public events"
end
if command_result.dig("properties", "events")
  errors << "specification/openapi.yaml: unscoped command result events risk privileged disclosure"
end
unless asyncapi.dig("components", "messages", "PublicEvent", "payload", "$ref") ==
    "./events/public-event.schema.json"
  errors << "specification/asyncapi.yaml: subscription must use the public event schema"
end

# Cross-language determinism: every amount and timestamp must go through the
# shared bounded definitions so no implementation can accept a value that
# another cannot represent exactly.
money_schema = schema_documents.fetch(ROOT.join("specification/common/money.schema.json"))
money_bound = money_schema.dig("$defs", "minorUnits", "maximum")
errors << "specification/common/money.schema.json: minorUnits must declare maximum" unless money_bound
money_schema.fetch("$defs").each do |name, definition|
  next if definition["maximum"] == money_bound

  errors << "specification/common/money.schema.json: $defs/#{name} must use the shared maximum"
end
schema_documents.each do |path, document|
  next unless path.to_s.start_with?(ROOT.join("specification").to_s + "/")
  next if path.dirname == ROOT.join("specification/common")

  walk(document) do |node|
    next unless node.is_a?(Hash) && node["properties"].is_a?(Hash)

    node["properties"].each do |name, property|
      next unless property.is_a?(Hash)

      if name.end_with?("minor_units") && !property.key?("const") &&
          !property["$ref"].to_s.start_with?("../common/money.schema.json#/$defs/")
        errors << "#{relative(path)}: #{name} must reference a bounded money.schema.json definition"
      end
      timestamp_ref = "../common/timestamp.schema.json"
      uses_timestamp = property["$ref"] == timestamp_ref ||
        Array(property["oneOf"]).any? { |entry| entry["$ref"] == timestamp_ref }
      if property["format"] == "date-time" ||
          (name.end_with?("_at") && !uses_timestamp)
        errors << "#{relative(path)}: #{name} must reference timestamp.schema.json"
      end
    end
  end
end

event_base = schema_documents.fetch(ROOT.join("specification/events/base.schema.json"))
unless event_base.fetch("required").include?("event_index")
  errors << "specification/events/base.schema.json: event_index is required for deterministic order"
end
event_union = schema_documents.fetch(ROOT.join("specification/events/event.schema.json"))
event_union_refs = Array(event_union["oneOf"]).filter_map { |entry| entry["$ref"] }.sort
unless event_union_refs == ["./privileged-event.schema.json", "./public-event.schema.json"]
  errors << "specification/events/event.schema.json: event union must separate public and privileged events"
end

if errors.any?
  warn errors.join("\n")
  exit 1
end

puts "Validated #{schemas.length} JSON Schemas, #{scenario_paths.length} conformance scenarios, and the OpenAPI/AsyncAPI documents."
