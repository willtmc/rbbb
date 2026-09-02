# frozen_string_literal: true

module RBBB
  # Exact monetary value represented without floating point.
  class Money
    include Comparable

    # Largest amount any RFC 0001 field may carry. Every conforming
    # implementation must produce identical results, so amounts share the
    # interoperable integer bound in RBBB::MAX_SAFE_INTEGER.
    MAX_MINOR_UNITS = MAX_SAFE_INTEGER

    attr_reader :currency, :minor_units

    # True when value is a non-negative integer inside the interoperable range.
    def self.amount?(value)
      value.is_a?(Integer) && value >= 0 && value <= MAX_MINOR_UNITS
    end

    def initialize(currency:, minor_units:)
      unless currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
        raise InvalidMoney, "currency must be a three-letter uppercase code"
      end
      raise InvalidMoney, "minor_units must be an integer" unless minor_units.is_a?(Integer)
      if minor_units.abs > MAX_MINOR_UNITS
        raise InvalidMoney, "minor_units must not exceed #{MAX_MINOR_UNITS}"
      end

      @currency = currency.freeze
      @minor_units = minor_units
      freeze
    end

    def <=>(other)
      ensure_same_currency!(other)
      minor_units <=> other.minor_units
    end

    def +(other)
      ensure_same_currency!(other)
      self.class.new(currency: currency, minor_units: minor_units + other.minor_units)
    end

    def -(other)
      ensure_same_currency!(other)
      self.class.new(currency: currency, minor_units: minor_units - other.minor_units)
    end

    def ==(other)
      other.is_a?(Money) && currency == other.currency && minor_units == other.minor_units
    end
    alias eql? ==

    def hash
      [currency, minor_units].hash
    end

    def to_h
      {"currency" => currency, "minor_units" => minor_units}
    end

    private

    def ensure_same_currency!(other)
      unless other.is_a?(Money) && other.currency == currency
        raise InvalidMoney, "money operations require matching currencies"
      end
    end
  end
end
