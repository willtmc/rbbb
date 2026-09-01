# frozen_string_literal: true

module RBBB
  # Exact monetary value represented without floating point.
  class Money
    include Comparable

    attr_reader :currency, :minor_units

    def initialize(currency:, minor_units:)
      unless currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
        raise InvalidMoney, "currency must be a three-letter uppercase code"
      end
      raise InvalidMoney, "minor_units must be an integer" unless minor_units.is_a?(Integer)

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
