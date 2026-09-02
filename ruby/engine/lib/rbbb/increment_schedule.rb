# frozen_string_literal: true

module RBBB
  # Lower-bound tiers used to select the increment for an exact amount.
  class IncrementSchedule
    Tier = Struct.new(:from_minor_units, :amount_minor_units, keyword_init: true) do
      def to_h
        {
          "from_minor_units" => from_minor_units,
          "amount_minor_units" => amount_minor_units
        }
      end
    end

    attr_reader :tiers

    def initialize(tiers)
      @tiers = Array(tiers).map do |tier|
        unless tier.respond_to?(:transform_keys)
          raise InvalidConfiguration, "increment tier must be an object"
        end

        values = tier.transform_keys(&:to_s)
        Tier.new(
          from_minor_units: values.fetch("from_minor_units"),
          amount_minor_units: values.fetch("amount_minor_units")
        ).freeze
      end
      validate_tier_types!
      @tiers = @tiers.sort_by(&:from_minor_units)

      validate!
      @tiers.freeze
      freeze
    rescue KeyError => e
      raise InvalidConfiguration, "increment tier is missing #{e.key}"
    end

    def increment_for(minor_units)
      unless minor_units.is_a?(Integer) && minor_units >= 0
        raise InvalidConfiguration, "increment lookup amount must be a non-negative integer"
      end

      tiers.reverse_each.find { |tier| tier.from_minor_units <= minor_units }.amount_minor_units
    end

    def to_a
      tiers.map(&:to_h)
    end

    private

    def validate_tier_types!
      tiers.each do |tier|
        unless tier.from_minor_units.is_a?(Integer) && tier.from_minor_units >= 0
          raise InvalidConfiguration, "increment lower bounds must be non-negative integers"
        end
        unless tier.amount_minor_units.is_a?(Integer) && tier.amount_minor_units.positive?
          raise InvalidConfiguration, "increments must be positive integers"
        end
      end
    end

    def validate!
      raise InvalidConfiguration, "increment schedule must contain at least one tier" if tiers.empty?
      unless tiers.first.from_minor_units == 0
        raise InvalidConfiguration, "increment schedule must begin at zero"
      end

      duplicate = tiers.each_cons(2).find do |left, right|
        left.from_minor_units == right.from_minor_units
      end
      raise InvalidConfiguration, "increment lower bounds must be unique" if duplicate
    end
  end
end
