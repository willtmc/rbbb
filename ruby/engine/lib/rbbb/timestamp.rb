# frozen_string_literal: true

require "time"

module RBBB
  # Strict parsing and canonical serialization for authoritative UTC times.
  module Timestamp
    # Date, "T", time, optional fraction, and a mandatory zone designator.
    # Ruby's Time.iso8601 silently treats a zone-less string as host-local
    # time, which would let the host's TZ setting change auction outcomes.
    FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/

    module_function

    def parse(value)
      time = case value
      when Time
        value
      when String
        raise ArgumentError, "timestamp must carry an explicit UTC offset" unless value.match?(FORMAT)

        Time.iso8601(value)
      else
        raise ArgumentError, "timestamp must be an ISO 8601 string or Time"
      end

      time.getutc.freeze
    end

    def dump(time)
      return nil unless time

      formatted = time.getutc.iso8601(9)
      formatted.sub!(/0+Z\z/, "Z")
      formatted.sub!(/\.Z\z/, "Z")
      formatted
    end
  end
end
