# frozen_string_literal: true

module RBBB
  # Immutable bidding-unit configuration consumed by the pure engine.
  #
  # RFC 0001 defines only timed bidding units, so +opens_at+ and +closes_at+
  # are required alongside currency, opening amount, and increments.
  class Configuration
    attr_reader :currency, :opening_minor_units, :reserve_minor_units,
      :increment_schedule, :bid_ladder, :opens_at, :closes_at, :extension

    def self.from_h(attributes)
      unless attributes.respond_to?(:transform_keys)
        raise InvalidConfiguration, "configuration must be an object"
      end

      values = attributes.transform_keys(&:to_s)
      new(
        currency: values.fetch("currency"),
        opening_minor_units: values.fetch("opening_minor_units"),
        reserve_minor_units: values["reserve_minor_units"],
        increments: values.fetch("increments"),
        opens_at: values.fetch("opens_at"),
        closes_at: values.fetch("closes_at"),
        extension: values["extension"]
      )
    rescue KeyError => e
      raise InvalidConfiguration, "configuration is missing #{e.key}"
    end

    def initialize(currency:, opening_minor_units:, increments:, reserve_minor_units: nil,
      opens_at: nil, closes_at: nil, extension: nil)
      Money.new(currency: currency, minor_units: opening_minor_units)
      unless Money.amount?(opening_minor_units)
        raise InvalidConfiguration, "opening amount must be a non-negative integer no greater than #{Money::MAX_MINOR_UNITS}"
      end
      if !reserve_minor_units.nil? && !Money.amount?(reserve_minor_units)
        raise InvalidConfiguration, "reserve must be a non-negative integer no greater than #{Money::MAX_MINOR_UNITS}"
      end

      @currency = currency.freeze
      @opening_minor_units = opening_minor_units
      @reserve_minor_units = reserve_minor_units
      @increment_schedule = IncrementSchedule.new(increments)
      @bid_ladder = BidLadder.new(@increment_schedule, opening_minor_units)
      @opens_at = parse_timestamp(opens_at, "opens_at")
      @closes_at = parse_timestamp(closes_at, "closes_at")
      if @opens_at >= @closes_at
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

    def ==(other)
      other.is_a?(Configuration) && equality_key == other.equality_key
    end
    alias eql? ==

    def hash
      [self.class, equality_key].hash
    end

    protected

    def equality_key
      [
        currency,
        opening_minor_units,
        reserve_minor_units,
        increment_schedule.to_a,
        Timestamp.dump(opens_at),
        Timestamp.dump(closes_at),
        extension
      ]
    end

    private

    def parse_timestamp(value, field)
      raise InvalidConfiguration, "configuration is missing #{field}" if value.nil?

      Timestamp.parse(value)
    rescue ArgumentError
      raise InvalidConfiguration, "#{field} must be a valid ISO 8601 timestamp"
    end

    def normalize_extension(extension)
      return nil if extension.nil?
      unless extension.respond_to?(:transform_keys)
        raise InvalidConfiguration, "extension must be an object"
      end

      values = extension.transform_keys(&:to_s)
      trigger = values["trigger_window_seconds"]
      duration = values["duration_seconds"]
      extend_on_void = values.fetch("extend_on_void", false)
      # Seconds share the interoperable integer bound so closing-time
      # arithmetic (command time plus duration) stays representable in every
      # implementation and inside the RFC 3339 four-digit-year range.
      unless trigger.is_a?(Integer) && trigger >= 0 && trigger <= MAX_SAFE_INTEGER
        raise InvalidConfiguration,
          "extension trigger window must be a non-negative integer no greater than #{MAX_SAFE_INTEGER}"
      end
      unless duration.is_a?(Integer) && duration.positive? && duration <= MAX_SAFE_INTEGER
        raise InvalidConfiguration,
          "extension duration must be a positive integer no greater than #{MAX_SAFE_INTEGER}"
      end
      unless extend_on_void == true || extend_on_void == false
        raise InvalidConfiguration, "extension extend_on_void must be a boolean"
      end

      {
        "trigger_window_seconds" => trigger,
        "duration_seconds" => duration,
        "extend_on_void" => extend_on_void
      }.freeze
    end
  end
end
