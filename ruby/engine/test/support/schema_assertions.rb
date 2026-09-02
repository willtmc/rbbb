# frozen_string_literal: true

require "json"
require "pathname"

# A small JSON Schema 2020-12 checker covering the subset used by the RBBB
# state and event schemas: types, enum/const, minimum/minLength/pattern,
# date-time, properties/required/additionalProperties, items, $ref into
# $defs or into sibling schema files, oneOf, and allOf with if/then. It
# keeps the engine free of runtime dependencies while letting tests assert
# that produced documents satisfy the contract.
module SchemaAssertions
  ROOT = Pathname(__dir__).join("../../../..").expand_path
  TYPES = {
    "string" => String, "integer" => Integer, "number" => Numeric,
    "object" => Hash, "array" => Array, "null" => NilClass
  }.freeze

  def load_schema(relative_path)
    load_schema_file(ROOT.join(relative_path))
  end

  def assert_matches_schema(schema, document, root: schema, path: "document")
    schema, root = resolve_schema_ref(schema, root)

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
    if document.is_a?(Integer) && schema.key?("minimum")
      assert_operator document, :>=, schema["minimum"], "#{path} is below minimum"
    end
    if document.is_a?(String)
      if schema.key?("minLength")
        assert_operator document.length, :>=, schema["minLength"], "#{path} is too short"
      end
      assert_match(Regexp.new(schema["pattern"]), document, path) if schema.key?("pattern")
      if schema["format"] == "date-time"
        RBBB::Timestamp.parse(document)
      end
    end

    assert_object_matches(schema, document, root, path) if document.is_a?(Hash)
    if document.is_a?(Array) && schema["items"]
      document.each_with_index do |item, index|
        assert_matches_schema(schema["items"], item, root: root, path: "#{path}[#{index}]")
      end
    end
    if schema["oneOf"]
      matching = schema["oneOf"].count { |alternative| matches_schema?(alternative, document, root) }
      assert_equal 1, matching, "#{path} must match exactly one oneOf alternative"
    end
    Array(schema["allOf"]).each do |clause|
      if clause.key?("if")
        next unless matches_schema?(clause["if"], document, root)

        assert_matches_schema(clause["then"], document, root: root, path: path) if clause["then"]
      else
        assert_matches_schema(clause, document, root: root, path: path)
      end
    end
  rescue ArgumentError => e
    flunk "#{path}: #{e.message}"
  end

  private

  def assert_object_matches(schema, document, root, path)
    properties = schema["properties"] || {}
    Array(schema["required"]).each do |key|
      assert document.key?(key), "#{path} is missing #{key}"
    end
    document.each do |key, value|
      if properties.key?(key)
        assert_matches_schema(properties.fetch(key), value, root: root, path: "#{path}.#{key}")
      elsif schema["additionalProperties"].is_a?(Hash)
        assert_matches_schema(schema["additionalProperties"], value, root: root, path: "#{path}.#{key}")
      elsif schema["additionalProperties"] == false
        flunk "#{path} has unexpected key #{key}"
      end
    end
  end

  def matches_schema?(schema, document, root)
    assert_matches_schema(schema, document, root: root)
    true
  rescue Minitest::Assertion
    false
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

  # Returns the referenced schema node and the root document it lives in.
  # A ref with a file part switches the root so nested `#/$defs` refs inside
  # the target file resolve against that file.
  def resolve_schema_ref(schema, root)
    return [schema, root] unless schema.is_a?(Hash) && schema["$ref"]

    ref = schema.fetch("$ref")
    file_part, fragment = ref.split("#", 2)
    if file_part.empty?
      target_root = root
    else
      source = schema_sources[root]
      raise ArgumentError, "cannot resolve #{ref}: root schema was not loaded from a file" unless source

      target_path = source.dirname.join(file_part).cleanpath
      unless target_path.to_s.start_with?("#{ROOT}/") && target_path.file?
        raise ArgumentError, "unresolved $ref #{ref} from #{source.relative_path_from(ROOT)}"
      end

      target_root = load_schema_file(target_path)
    end

    [resolve_json_pointer(target_root, fragment), target_root]
  end

  def resolve_json_pointer(document, fragment)
    return document if fragment.nil? || fragment.empty?
    raise ArgumentError, "$ref fragment must be a JSON Pointer: ##{fragment}" unless fragment.start_with?("/")

    fragment.delete_prefix("/").split("/").reduce(document) do |value, token|
      decoded = token.gsub("~1", "/").gsub("~0", "~")
      case value
      when Hash then value.fetch(decoded)
      when Array then value.fetch(Integer(decoded, 10))
      else raise ArgumentError, "$ref ##{fragment} traverses a scalar"
      end
    end
  rescue KeyError, IndexError
    raise ArgumentError, "$ref ##{fragment} does not exist in the target schema"
  end
end
