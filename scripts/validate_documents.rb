# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

ROOT = Pathname(__dir__).join("..").expand_path
FORBIDDEN_PUBLIC_KEYS = /maximum|reserve_minor_units|operator_id|reason|bidder_id|leader_id|winner_id|bid_id|bidder_notice|positions|executed_minor_units|authorization_history|reserve_history|voided_bid_ids/

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

# Like walk, but also yields the JSON Pointer of each node for error messages.
def walk_with_pointer(value, pointer = "", &block)
  yield value, pointer
  case value
  when Hash
    value.each { |key, nested| walk_with_pointer(nested, "#{pointer}/#{key}", &block) }
  when Array
    value.each_with_index { |nested, index| walk_with_pointer(nested, "#{pointer}/#{index}", &block) }
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

def non_negative_integer?(value, max)
  value.is_a?(Integer) && value >= 0 && value <= max
end

def positive_integer?(value, max)
  value.is_a?(Integer) && value >= 1 && value <= max
end

def validate_fixture(path, fixture, timed_proxy_schema, timestamp_regex, money_bound, errors)
  label = relative(path)
  unless fixture.is_a?(Hash)
    errors << "#{label}: fixture must be an object"
    return
  end

  required = timed_proxy_schema.fetch("required")
  allowed = timed_proxy_schema.fetch("properties").keys
  missing = required.reject { |key| fixture.key?(key) }
  errors << "#{label}: missing required keys: #{missing.join(', ')}" if missing.any?
  extra = fixture.keys - allowed
  errors << "#{label}: unexpected keys: #{extra.join(', ')}" if extra.any?

  currency = fixture["currency"]
  unless currency.is_a?(String) && /\A[A-Z]{3}\z/.match?(currency)
    errors << "#{label}: currency must be a 3-letter ISO 4217 code"
  end
  unless non_negative_integer?(fixture["opening_minor_units"], money_bound)
    errors << "#{label}: opening_minor_units must be an integer in 0..#{money_bound}"
  end
  reserve = fixture["reserve_minor_units"]
  unless reserve.nil? || non_negative_integer?(reserve, money_bound)
    errors << "#{label}: reserve_minor_units must be null or an integer in 0..#{money_bound}"
  end

  increments = fixture["increments"]
  if !increments.is_a?(Array) || increments.empty?
    errors << "#{label}: increments must be a non-empty array"
  else
    increments.each_with_index do |tier, index|
      unless tier.is_a?(Hash)
        errors << "#{label}: increments[#{index}] must be an object"
        next
      end
      tier_missing = %w[from_minor_units amount_minor_units].reject { |key| tier.key?(key) }
      errors << "#{label}: increments[#{index}] missing #{tier_missing.join(', ')}" if tier_missing.any?
      tier_extra = tier.keys - %w[from_minor_units amount_minor_units]
      errors << "#{label}: increments[#{index}] unexpected keys: #{tier_extra.join(', ')}" if tier_extra.any?
      unless non_negative_integer?(tier["from_minor_units"], money_bound)
        errors << "#{label}: increments[#{index}].from_minor_units must be an integer in 0..#{money_bound}"
      end
      unless positive_integer?(tier["amount_minor_units"], money_bound)
        errors << "#{label}: increments[#{index}].amount_minor_units must be an integer in 1..#{money_bound}"
      end
    end
  end

  %w[opens_at closes_at].each do |field|
    value = fixture[field]
    unless value.is_a?(String) && timestamp_regex.match?(value)
      errors << "#{label}: #{field} must be a valid RFC 3339 timestamp with UTC offset"
    end
  end

  return unless fixture.key?("extension")

  extension = fixture["extension"]
  return if extension.nil?

  unless extension.is_a?(Hash)
    errors << "#{label}: extension must be null or an object"
    return
  end

  ext_schema = timed_proxy_schema.dig("$defs", "extension")
  ext_missing = ext_schema.fetch("required").reject { |key| extension.key?(key) }
  errors << "#{label}: extension missing #{ext_missing.join(', ')}" if ext_missing.any?
  ext_extra = extension.keys - ext_schema.fetch("properties").keys
  errors << "#{label}: extension unexpected keys: #{ext_extra.join(', ')}" if ext_extra.any?
  unless non_negative_integer?(extension["trigger_window_seconds"], money_bound)
    errors << "#{label}: extension.trigger_window_seconds must be an integer in 0..#{money_bound}"
  end
  unless positive_integer?(extension["duration_seconds"], money_bound)
    errors << "#{label}: extension.duration_seconds must be an integer in 1..#{money_bound}"
  end
  if extension.key?("extend_on_void") && ![true, false].include?(extension["extend_on_void"])
    errors << "#{label}: extension.extend_on_void must be a boolean"
  end
end

errors = []

json_paths = (
  Dir[ROOT.join("{specification,conformance}/**/*.json")] +
  Dir[ROOT.join("rfcs/proposals/flexible-live-scheduling/*.schema.json")]
).uniq.sort
json_paths.each do |path|
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

# Version consistency across specification/VERSION, OpenAPI, AsyncAPI, and Ruby engine.
version_file = ROOT.join("specification/VERSION")
spec_version = version_file.file? ? version_file.read.strip : nil
if spec_version.nil? || spec_version.empty?
  errors << "specification/VERSION: missing or empty specification version"
else
  if openapi.dig("info", "version") != spec_version
    errors << "specification/openapi.yaml: info.version (#{openapi.dig('info', 'version').inspect}) does not match specification/VERSION (#{spec_version.inspect})"
  end
  if asyncapi.dig("info", "version") != spec_version
    errors << "specification/asyncapi.yaml: info.version (#{asyncapi.dig('info', 'version').inspect}) does not match specification/VERSION (#{spec_version.inspect})"
  end
  ruby_version_path = ROOT.join("ruby/engine/lib/rbbb/version.rb")
  if !ruby_version_path.file?
    errors << "ruby/engine/lib/rbbb/version.rb: missing engine version file"
  else
    ruby_spec_match = ruby_version_path.read.match(/SPECIFICATION_VERSION\s*=\s*"([^"]+)"/)
    ruby_spec_version = ruby_spec_match && ruby_spec_match[1]
    if ruby_spec_version != spec_version
      errors << "ruby/engine/lib/rbbb/version.rb: SPECIFICATION_VERSION (#{ruby_spec_version.inspect}) does not match specification/VERSION (#{spec_version.inspect})"
    end
  end
end

schemas = (
  Dir[ROOT.join("{specification,conformance}/**/*.schema.json")] +
  Dir[ROOT.join("rfcs/proposals/flexible-live-scheduling/*.schema.json")]
).uniq.sort
schema_documents = {}
schema_ids = {}
schemas.each do |path_string|
  path = Pathname(path_string)
  begin
    schema = JSON.parse(path.read)
  rescue JSON::ParserError
    next
  end
  unless schema.is_a?(Hash)
    errors << "#{relative(path)}: JSON Schema root must be an object"
    next
  end
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

money_schema = schema_documents.fetch(ROOT.join("specification/common/money.schema.json"))
money_bound = money_schema.dig("$defs", "minorUnits", "maximum")
timestamp_schema = schema_documents.fetch(ROOT.join("specification/common/timestamp.schema.json"))
timestamp_regex = Regexp.new(timestamp_schema.fetch("pattern").sub(/\A\^/) { "\\A" }.sub(/\$\z/) { "\\z" })
timed_proxy_schema = schema_documents.fetch(ROOT.join("specification/configuration/timed-proxy.schema.json"))

fixture_paths = Dir[ROOT.join("conformance/fixtures/*.yaml")].sort
fixture_paths.each do |path|
  fixture = YAML.safe_load_file(path, aliases: false)
  validate_fixture(path, fixture, timed_proxy_schema, timestamp_regex, money_bound, errors)
end

scenario_schema = schema_documents.fetch(ROOT.join("conformance/schemas/scenario.schema.json"))
scenario_required = scenario_schema.fetch("required")
scenario_allowed = scenario_schema.fetch("properties").keys
expected_required = scenario_schema.dig("properties", "expected", "required")
expected_allowed = scenario_schema.dig("properties", "expected", "properties").keys
rfc_pattern = Regexp.new(
  scenario_schema.dig("properties", "rfcs", "items", "pattern").sub(/\A\^/) { "\\A" }.sub(/\$\z/) { "\\z" }
)

scenario_paths = Dir[ROOT.join("conformance/scenarios/**/*.yaml")].sort
scenario_names = {}
scenario_command_types = []
scenario_public_event_types = []
scenario_privileged_event_types = []
scenario_rejection_reasons = []
scenario_rejections = []

scenario_paths.each do |path|
  scenario = YAML.safe_load_file(path, aliases: false)
  unless scenario.is_a?(Hash)
    errors << "#{relative(path)}: scenario must be an object"
    next
  end

  missing = scenario_required.reject { |key| scenario.key?(key) }
  errors << "#{relative(path)}: missing #{missing.join(', ')}" if missing.any?
  extra = scenario.keys - scenario_allowed
  errors << "#{relative(path)}: unexpected top-level keys: #{extra.join(', ')}" if extra.any?

  name = scenario["name"]
  errors << "#{relative(path)}: name must be a non-empty string" unless name.is_a?(String) && !name.empty?
  if scenario_names.key?(name)
    errors << "#{relative(path)}: duplicate name also used by #{scenario_names[name]}"
  else
    scenario_names[name] = relative(path)
  end

  sv = scenario["specification_version"]
  unless sv.is_a?(String) && !sv.empty?
    errors << "#{relative(path)}: specification_version must be a non-empty string"
  end

  unless scenario["configuration"].is_a?(Hash)
    errors << "#{relative(path)}: configuration must be an object"
  end
  unless scenario["starting_state"].is_a?(Hash)
    errors << "#{relative(path)}: starting_state must be an object"
  end
  commands = scenario["commands"]
  if !commands.is_a?(Array) || commands.empty? || !commands.all? { |cmd| cmd.is_a?(Hash) }
    errors << "#{relative(path)}: commands must be a non-empty array of objects"
  end

  fixture = scenario.dig("configuration", "fixture") if scenario["configuration"].is_a?(Hash)
  fixture_path = ROOT.join("conformance/fixtures/#{fixture}.yaml") if fixture
  errors << "#{relative(path)}: unknown fixture #{fixture}" if fixture && !fixture_path.file?

  rfcs = scenario["rfcs"]
  if !rfcs.is_a?(Array) || rfcs.empty?
    errors << "#{relative(path)}: rfcs must be a non-empty array"
  else
    rfcs.each do |rfc|
      unless rfc.is_a?(String) && rfc_pattern.match?(rfc)
        errors << "#{relative(path)}: invalid RFC identifier #{rfc.inspect} (expected 4-digit string)"
        next
      end
      matches = Dir[ROOT.join("rfcs/#{rfc}-*.md")]
      errors << "#{relative(path)}: unknown RFC #{rfc}" if matches.empty?
    end
  end

  expected = scenario["expected"]
  unless expected.is_a?(Hash)
    errors << "#{relative(path)}: expected must be an object"
    next
  end
  expected_missing = expected_required.reject { |key| expected.key?(key) }
  errors << "#{relative(path)}: expected missing #{expected_missing.join(', ')}" if expected_missing.any?
  expected_extra = expected.keys - expected_allowed
  errors << "#{relative(path)}: expected has unexpected keys: #{expected_extra.join(', ')}" if expected_extra.any?

  if !expected["public_events"].is_a?(Array) || !expected["public_events"].all? { |item| item.is_a?(Hash) }
    errors << "#{relative(path)}: expected.public_events must be an array of objects"
  end
  if expected.key?("privileged_events") &&
      (!expected["privileged_events"].is_a?(Array) || !expected["privileged_events"].all? { |item| item.is_a?(Hash) })
    errors << "#{relative(path)}: expected.privileged_events must be an array of objects"
  end
  if expected.key?("rejections") &&
      (!expected["rejections"].is_a?(Array) || !expected["rejections"].all? { |item| item.is_a?(Hash) })
    errors << "#{relative(path)}: expected.rejections must be an array of objects"
  end
  errors << "#{relative(path)}: expected.final_state must be an object" unless expected["final_state"].is_a?(Hash)

  Array(expected["public_events"]).each_with_index do |event, index|
    leaked = deep_keys(event).grep(FORBIDDEN_PUBLIC_KEYS).uniq
    next if leaked.empty?

    errors << "#{relative(path)}: public_events[#{index}] contains privileged keys: #{leaked.join(', ')}"
  end

  scenario_command_types.concat(Array(commands).filter_map { |command| command["type"] if command.is_a?(Hash) })
  scenario_public_event_types.concat(Array(expected["public_events"]).filter_map { |event| event["type"] if event.is_a?(Hash) })
  scenario_privileged_event_types.concat(Array(expected["privileged_events"]).filter_map { |event| event["type"] if event.is_a?(Hash) })
  scenario_rejection_reasons.concat(Array(expected["rejections"]).filter_map { |rejection| rejection["reason"] if rejection.is_a?(Hash) })
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

{
  "specification/events/public-event.schema.json" => public_event_schema,
  "specification/state/bidding-unit.schema.json" => schema_documents.fetch(
    ROOT.join("specification/state/bidding-unit.schema.json")
  )
}.each do |label, document|
  leaked = property_names(document).grep(FORBIDDEN_PUBLIC_KEYS)
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

# Every other integer (versions, priorities, counters, extension seconds) must
# carry the same 2^53 - 1 bound. A bare "type": "integer" without a maximum, or
# a maximum above the shared bound, fails; properties should reference
# common/integer.schema.json instead of declaring their own range.
integer_schema = schema_documents.fetch(ROOT.join("specification/common/integer.schema.json"))
unless integer_schema["type"] == "integer" && integer_schema["maximum"] == money_bound
  errors << "specification/common/integer.schema.json: root must be an integer with the shared maximum"
end
integer_schema.fetch("$defs").each do |name, definition|
  next if definition["type"] == "integer" && definition["maximum"] == money_bound

  errors << "specification/common/integer.schema.json: $defs/#{name} must use the shared maximum"
end
bounded_integer_documents = schema_documents.select do |path, _document|
  path.to_s.start_with?(ROOT.join("specification").to_s + "/") &&
    path.dirname != ROOT.join("specification/common")
end.merge(
  Pathname(ROOT.join("specification/openapi.yaml")) => openapi,
  Pathname(ROOT.join("specification/asyncapi.yaml")) => asyncapi
)
bounded_integer_documents.each do |path, document|
  walk_with_pointer(document) do |node, pointer|
    next unless node.is_a?(Hash) && Array(node["type"]).include?("integer")
    next if node["maximum"].is_a?(Integer) && node["maximum"] <= money_bound

    errors << "#{relative(path)}: #{pointer} is an integer without a maximum of at most #{money_bound}; " \
      "reference common/integer.schema.json or common/money.schema.json"
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

puts "Validated #{schemas.length} JSON Schemas, #{fixture_paths.length} conformance fixtures, #{scenario_paths.length} conformance scenarios, and the OpenAPI/AsyncAPI documents."
