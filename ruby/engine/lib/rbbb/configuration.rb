# frozen_string_literal: true

module RBBB
  # Immutable bidding-unit configuration consumed by the pure engine.
  class Configuration
    attr_reader :currency, :opening_minor_units, :reserve_minor_units,
      :increment_schedule, :extension

    def self.from_h(attributes)
      values = attributes.transform_keys(&:to_s)
      new(
        currency: values.fetch("currency"),
        opening_minor_units: values.fetch("opening_minor_units"),
        reserve_minor_units: values["reserve_minor_units"],
        increments: values.fetch("increments"),
        extension: values["extension"]
      )
    rescue KeyError => e
      raise InvalidConfiguration, "configuration is missing #{e.key}"
    end

    def initialize(currency:, opening_minor_units:, increments:, reserve_minor_units: nil,
      extension: nil)
      Money.new(currency: currency, minor_units: opening_minor_units)
      unless opening_minor_units >= 0
        raise InvalidConfiguration, "opening amount must be non-negative"
      end
      if !reserve_minor_units.nil? &&
          (!reserve_minor_units.is_a?(Integer) || reserve_minor_units.negative?)
        raise InvalidConfiguration, "reserve must be a non-negative integer"
      end

      @currency = currency.freeze
      @opening_minor_units = opening_minor_units
      @reserve_minor_units = reserve_minor_units
      @increment_schedule = IncrementSchedule.new(increments)
      @extension = extension&.transform_keys(&:to_s)&.freeze
      freeze
    rescue InvalidMoney => e
      raise InvalidConfiguration, e.message
    end

    def increment_for(minor_units)
      increment_schedule.increment_for(minor_units)
    end
  end
end
