# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

ROOT = Pathname(__dir__).join("..").expand_path

def relative(path)
  Pathname(path).relative_path_from(ROOT)
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

if errors.any?
  warn errors.join("\n")
  exit 1
end

puts "Validated #{schemas.length} JSON Schemas and the OpenAPI/AsyncAPI documents."
