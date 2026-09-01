# frozen_string_literal: true

require "time"

module RBBB
  # Strict parsing and canonical serialization for authoritative UTC times.
  module Timestamp
    module_function

    def parse(value)
      time = case value
      when Time
        value
      when String
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
