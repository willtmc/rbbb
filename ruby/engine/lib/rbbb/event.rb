# frozen_string_literal: true

module RBBB
  # Immutable fact emitted by an accepted engine command.
  class Event
    VISIBILITIES = %i[public privileged].freeze

    attr_reader :type, :visibility, :data

    def initialize(type:, visibility:, data: {})
      raise ArgumentError, "unknown event visibility" unless VISIBILITIES.include?(visibility)

      @type = type.to_s.freeze
      @visibility = visibility
      @data = deep_freeze(data.transform_keys(&:to_s))
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

    private

    def deep_freeze(value)
      case value
      when Hash
        value.transform_values { |nested| deep_freeze(nested) }.freeze
      when Array
        value.map { |nested| deep_freeze(nested) }.freeze
      else
        value.freeze
      end
    end
  end
end
