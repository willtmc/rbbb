# frozen_string_literal: true

require "time"

module RBBB
  # Strict parsing and canonical serialization for authoritative UTC times.
  module Timestamp
    # Normative precision is one millisecond. Finer input is rejected rather
    # than truncated so that a millisecond-native implementation replays the
    # same command stream to the same closing times.
    PRECISION_DIGITS = 3
    NANOSECONDS_PER_UNIT = 10**(9 - PRECISION_DIGITS)

    # Date, "T", time, optional fraction of at most PRECISION_DIGITS digits,
    # and a mandatory zone designator. Ruby's Time.iso8601 silently treats a
    # zone-less string as host-local time, which would let the host's TZ
    # setting change auction outcomes.
    FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,#{PRECISION_DIGITS}})?(?:Z|[+-]\d{2}:\d{2})\z/

    module_function

    def parse(value)
      time = case value
      when Time
        value
      when String
        unless value.match?(FORMAT)
          raise ArgumentError,
            "timestamp must carry an explicit UTC offset and at most #{PRECISION_DIGITS} fractional digits"
        end

        Time.iso8601(value)
      else
        raise ArgumentError, "timestamp must be an ISO 8601 string or Time"
      end

      unless (time.nsec % NANOSECONDS_PER_UNIT).zero?
        raise ArgumentError, "timestamp precision must not exceed #{PRECISION_DIGITS} fractional digits"
      end

      time.getutc.freeze
    end

    # Canonical form: UTC with "Z", the fraction omitted when zero and
    # otherwise trimmed of trailing zeros, never more than PRECISION_DIGITS.
    def dump(time)
      return nil unless time

      formatted = time.getutc.iso8601(PRECISION_DIGITS)
      formatted.sub!(/0+Z\z/, "Z")
      formatted.sub!(/\.Z\z/, "Z")
      formatted
    end
  end
end
