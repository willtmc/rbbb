# frozen_string_literal: true

module RBBB
  # Immutable fact emitted by an accepted engine command.
  class Event
    VISIBILITIES = %i[public privileged].freeze

    attr_reader :type, :visibility, :data

    def initialize(type:, visibility:, data: {})
      raise ArgumentError, "unknown event visibility" unless VISIBILITIES.include?(visibility)

      @type = type.is_a?(String) ? -type : type.to_s.freeze
      @visibility = visibility
      normalized = string_keyed_hash?(data) ? data : data.transform_keys(&:to_s)
      @data = deep_freeze(normalized)
      freeze
    end

    def public?
      visibility == :public
    end

    def privileged?
      visibility == :privileged
    end

    def to_h
      {"type" => type}.merge(data)
    end

    def ==(other)
      other.is_a?(Event) && type == other.type && visibility == other.visibility && data == other.data
    end
    alias eql? ==

    def hash
      [self.class, type, visibility, data].hash
    end

    private

    def string_keyed_hash?(value)
      return false unless value.instance_of?(Hash)

      value.each_key { |key| return false unless key.is_a?(String) }
      true
    end

    def deeply_frozen?(value)
      return false unless value.frozen?

      case value
      when Hash
        value.each_value { |nested| return false unless deeply_frozen?(nested) }
        true
      when Array
        value.each { |nested| return false unless deeply_frozen?(nested) }
        true
      else
        true
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        return value if deeply_frozen?(value)

        value.transform_values { |nested| deep_freeze(nested) }.freeze
      when Array
        return value if deeply_frozen?(value)

        value.map { |nested| deep_freeze(nested) }.freeze
      when String
        value.frozen? ? value : -value
      else
        value.freeze
      end
    end
  end
end
