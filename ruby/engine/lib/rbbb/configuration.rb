# frozen_string_literal: true

module RBBB
  # Immutable bidding-unit configuration consumed by the pure engine.
  class Configuration
    attr_reader :currency, :opening_minor_units, :reserve_minor_units,
      :increment_schedule, :opens_at, :closes_at, :extension

    def self.from_h(attributes)
      values = attributes.transform_keys(&:to_s)
      new(
        currency: values.fetch("currency"),
        opening_minor_units: values.fetch("opening_minor_units"),
        reserve_minor_units: values["reserve_minor_units"],
        increments: values.fetch("increments"),
        opens_at: values["opens_at"],
        closes_at: values["closes_at"],
        extension: values["extension"]
      )
    rescue KeyError => e
      raise InvalidConfiguration, "configuration is missing #{e.key}"
    end

    def initialize(currency:, opening_minor_units:, increments:, reserve_minor_units: nil,
      opens_at: nil, closes_at: nil, extension: nil)
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
      @opens_at = parse_timestamp(opens_at, "opens_at")
      @closes_at = parse_timestamp(closes_at, "closes_at")
      if @opens_at && @closes_at && @opens_at >= @closes_at
        raise InvalidConfiguration, "opens_at must be earlier than closes_at"
      end
      @extension = normalize_extension(extension)
      freeze
    rescue InvalidMoney => e
      raise InvalidConfiguration, e.message
    end

    def increment_for(minor_units)
      increment_schedule.increment_for(minor_units)
    end

    private

    def parse_timestamp(value, field)
      return nil if value.nil?

      Timestamp.parse(value)
    rescue ArgumentError
      raise InvalidConfiguration, "#{field} must be a valid ISO 8601 timestamp"
    end

    def normalize_extension(extension)
      return nil if extension.nil?
      unless extension.respond_to?(:transform_keys)
        raise InvalidConfiguration, "extension must be an object"
      end
      raise InvalidConfiguration, "extension requires closes_at" unless closes_at

      values = extension.transform_keys(&:to_s)
      trigger = values["trigger_window_seconds"]
      duration = values["duration_seconds"]
      unless trigger.is_a?(Integer) && trigger >= 0
        raise InvalidConfiguration, "extension trigger window must be a non-negative integer"
      end
      unless duration.is_a?(Integer) && duration.positive?
        raise InvalidConfiguration, "extension duration must be a positive integer"
      end

      {
        "trigger_window_seconds" => trigger,
        "duration_seconds" => duration
      }.freeze
    end
  end
end
