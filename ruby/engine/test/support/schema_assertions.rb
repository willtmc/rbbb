# frozen_string_literal: true

require "json"
require "pathname"
require "set"

# A small JSON Schema 2020-12 checker covering the subset used by the RBBB
# command, state, rejection, and event schemas: types, enum/const,
# minimum/maximum, string lengths, pattern/date-time,
# properties/patternProperties/required/additionalProperties/unevaluatedProperties,
# array lengths and uniqueness, items, chained $ref into $defs or sibling schema
# files, oneOf, anyOf, allOf, if/then/else, and not. It keeps the engine free of
# runtime dependencies while letting tests assert that produced documents satisfy
# the contract.
module SchemaAssertions
  class SchemaError < StandardError; end

  ROOT = Pathname(__dir__).join("../../../..").expand_path
  TYPES = {
    "string" => String, "integer" => Integer, "number" => Numeric,
    "object" => Hash, "array" => Array, "null" => NilClass
  }.freeze

  def load_schema(relative_path)
    load_schema_file(ROOT.join(relative_path))
  end

  def assert_matches_schema(schema, document, root: schema, path: "document")
    validate_schema(schema, document, root: root, path: path, seen_refs: Set.new)
  rescue SchemaError => e
    flunk "#{path}: #{e.message}"
  end

  private

  # Validates `document` against `schema` and returns the Set of property names
  # on `document` evaluated at this instance location (used by
  # `unevaluatedProperties` per JSON Schema 2020-12).
  def validate_schema(schema, document, root:, path:, seen_refs:)
    if schema == true
      return document.is_a?(Hash) ? document.keys.to_set : Set.new
    elsif schema == false
      flunk "#{path} is disallowed by false schema"
    end

    evaluated = Set.new

    if schema.key?("$ref")
      location = [schema.object_id, root.object_id]
      raise SchemaError, "cyclic schema reference" if seen_refs.include?(location)

      ref_schema, ref_root = resolve_single_schema_ref(schema, root)
      ref_evaluated = validate_schema(
        ref_schema,
        document,
        root: ref_root,
        path: path,
        seen_refs: seen_refs | [location]
      )
      evaluated.merge(ref_evaluated)
    end

    types = Array(schema["type"])
    if types.any?
      matched = types.any? do |type|
        type == "boolean" ? [true, false].include?(document) : TYPES.fetch(type) === document
      end
      assert matched, "#{path} must be #{types.join('|')}, got #{document.inspect}"
    end
    assert_includes schema["enum"], document, "#{path} is not in enum" if schema.key?("enum")
    if schema.key?("const")
      schema["const"].nil? ? assert_nil(document, path) : assert_equal(schema["const"], document, path)
    end
    if document.is_a?(Numeric)
      assert_operator document, :>=, schema["minimum"], "#{path} is below minimum" if schema.key?("minimum")
      assert_operator document, :<=, schema["maximum"], "#{path} is above maximum" if schema.key?("maximum")
    end
    if document.is_a?(String)
      if schema.key?("minLength")
        assert_operator document.length, :>=, schema["minLength"], "#{path} is too short"
      end
      assert_operator document.length, :<=, schema["maxLength"], "#{path} is too long" if schema.key?("maxLength")
      if schema.key?("pattern")
        # JSON Schema uses ECMA's string-start ^, not Ruby's line-start ^.
        pattern = schema["pattern"].sub(/\A\^/) { "\\A" }
        assert_match(Regexp.new(pattern), document, path)
      end
      if schema["format"] == "date-time"
        begin
          RBBB::Timestamp.parse(document)
        rescue ArgumentError => e
          flunk "#{path}: #{e.message}"
        end
      end
    end

    if document.is_a?(Hash)
      evaluated.merge(validate_object_keywords(schema, document, root: root, path: path))
    end

    if document.is_a?(Array)
      assert_operator document.length, :>=, schema["minItems"], "#{path} has too few items" if schema.key?("minItems")
      assert_operator document.length, :<=, schema["maxItems"], "#{path} has too many items" if schema.key?("maxItems")
      assert_equal document.length, document.uniq.length, "#{path} has duplicate items" if schema["uniqueItems"]
      if schema["items"]
        document.each_with_index do |item, index|
          validate_schema(schema["items"], item, root: root, path: "#{path}[#{index}]", seen_refs: Set.new)
        end
      end
    end

    Array(schema["allOf"]).each do |clause|
      evaluated.merge(validate_schema(clause, document, root: root, path: path, seen_refs: seen_refs))
    end

    if schema["oneOf"]
      matching = schema["oneOf"].filter_map do |alternative|
        ok, alt_evaluated = probe_schema(alternative, document, root: root, path: path, seen_refs: seen_refs)
        alt_evaluated if ok
      end
      assert_equal 1, matching.length, "#{path} must match exactly one oneOf alternative"
      evaluated.merge(matching.first)
    end

    if schema["anyOf"]
      matching = schema["anyOf"].filter_map do |alternative|
        ok, alt_evaluated = probe_schema(alternative, document, root: root, path: path, seen_refs: seen_refs)
        alt_evaluated if ok
      end
      assert_operator matching.length, :>=, 1, "#{path} must match at least one anyOf alternative"
      matching.each { |alt_evaluated| evaluated.merge(alt_evaluated) }
    end

    if schema.key?("if")
      matched, if_evaluated = probe_schema(schema["if"], document, root: root, path: path, seen_refs: seen_refs)
      if matched
        evaluated.merge(if_evaluated)
        if schema.key?("then")
          evaluated.merge(validate_schema(schema["then"], document, root: root, path: path, seen_refs: seen_refs))
        end
      elsif schema.key?("else")
        evaluated.merge(validate_schema(schema["else"], document, root: root, path: path, seen_refs: seen_refs))
      end
    end

    if schema.key?("not")
      matched, = probe_schema(schema["not"], document, root: root, path: path, seen_refs: seen_refs)
      flunk "#{path} must not match negated schema" if matched
    end

    if document.is_a?(Hash) && schema.key?("unevaluatedProperties")
      remaining = document.keys.reject { |key| evaluated.include?(key) }
      rule = schema["unevaluatedProperties"]
      if rule == false
        flunk "#{path} has unevaluated key #{remaining.first}" if remaining.any?
      elsif rule == true
        evaluated.merge(remaining)
      elsif rule.is_a?(Hash)
        remaining.each do |key|
          validate_schema(rule, document.fetch(key), root: root, path: "#{path}.#{key}", seen_refs: Set.new)
          evaluated << key
        end
      end
    end

    evaluated
  end

  def validate_object_keywords(schema, document, root:, path:)
    evaluated = Set.new
    properties = schema["properties"] || {}
    pattern_properties = schema["patternProperties"] || {}

    Array(schema["required"]).each do |key|
      assert document.key?(key), "#{path} is missing #{key}"
    end

    document.each do |key, value|
      matched_here = false
      if properties.key?(key)
        validate_schema(properties.fetch(key), value, root: root, path: "#{path}.#{key}", seen_refs: Set.new)
        evaluated << key
        matched_here = true
      end

      pattern_properties.each do |pattern, subschema|
        next unless Regexp.new(pattern.sub(/\A\^/) { "\\A" }).match?(key)

        validate_schema(subschema, value, root: root, path: "#{path}.#{key}", seen_refs: Set.new)
        evaluated << key
        matched_here = true
      end

      next if matched_here

      if schema["additionalProperties"].is_a?(Hash)
        validate_schema(schema["additionalProperties"], value, root: root, path: "#{path}.#{key}", seen_refs: Set.new)
        evaluated << key
      elsif schema["additionalProperties"] == true
        evaluated << key
      elsif schema["additionalProperties"] == false
        flunk "#{path} has unexpected key #{key}"
      end
    end

    evaluated
  end

  def probe_schema(schema, document, root:, path:, seen_refs:)
    [true, validate_schema(schema, document, root: root, path: path, seen_refs: seen_refs)]
  rescue Minitest::Assertion
    [false, Set.new]
  end

  # Loaded schema documents keyed by absolute path, and the path each parsed
  # root came from, so `$ref`s to sibling files resolve relative to the file
  # that contains them (mirroring scripts/validate_documents.rb).
  def schema_documents
    @schema_documents ||= {}
  end

  def schema_sources
    @schema_sources ||= {}.compare_by_identity
  end

  def load_schema_file(path)
    schema_documents[path] ||= JSON.parse(path.read).tap { |schema| schema_sources[schema] = path }
  end

  def resolve_single_schema_ref(schema, root)
    ref = schema.fetch("$ref")
    file_part, fragment = ref.split("#", 2)
    if file_part.empty?
      target_root = root
    else
      source = schema_sources[root]
      raise SchemaError, "cannot resolve #{ref}: root schema was not loaded from a file" unless source

      target_path = source.dirname.join(file_part).cleanpath
      unless target_path.to_s.start_with?("#{ROOT}/") && target_path.file?
        raise SchemaError, "unresolved $ref #{ref} from #{source.relative_path_from(ROOT)}"
      end

      target_root = load_schema_file(target_path)
    end

    [resolve_json_pointer(target_root, fragment), target_root]
  end

  def resolve_json_pointer(document, fragment)
    return document if fragment.nil? || fragment.empty?
    raise SchemaError, "$ref fragment must be a JSON Pointer: ##{fragment}" unless fragment.start_with?("/")

    fragment.delete_prefix("/").split("/").reduce(document) do |value, token|
      decoded = token.gsub("~1", "/").gsub("~0", "~")
      case value
      when Hash then value.fetch(decoded)
      when Array then value.fetch(Integer(decoded, 10))
      else raise SchemaError, "$ref ##{fragment} traverses a scalar"
      end
    end
  rescue KeyError, IndexError, ArgumentError
    raise SchemaError, "$ref ##{fragment} does not exist in the target schema"
  end
end
