# frozen_string_literal: true

module RBBB
  # Accepted events or one stable rejection from evaluating a command.
  class Decision
    # The constant status every rejection carries. The pure engine emits the
    # complete rejection document defined by
    # specification/rejections/rejection.schema.json; a service adapter must
    # transmit it without adding or removing fields.
    REJECTED_STATUS = "rejected"

    # Rejection fields beyond command_id, status, and reason, keyed by the only
    # reason that may carry them. Mirrors the rejection schema; there is
    # deliberately no open-ended details object.
    REASON_SPECIFIC_FIELDS = {
      "maximum_below_executed_amount" => %w[executed_floor_minor_units].freeze
    }.freeze

    attr_reader :events, :rejection

    def self.accepted(events)
      new(events: events, rejection: nil)
    end

    def self.rejected(command_id:, reason:, executed_floor_minor_units: nil)
      rejection = {"command_id" => command_id, "status" => REJECTED_STATUS, "reason" => reason}
      allowed = REASON_SPECIFIC_FIELDS.fetch(reason, [])

      if allowed.include?("executed_floor_minor_units")
        unless executed_floor_minor_units.is_a?(Integer) && executed_floor_minor_units >= 0
          raise ArgumentError, "#{reason} requires a non-negative integer executed_floor_minor_units"
        end

        rejection["executed_floor_minor_units"] = executed_floor_minor_units
      elsif !executed_floor_minor_units.nil?
        raise ArgumentError, "executed_floor_minor_units is only reported for maximum_below_executed_amount"
      end

      new(events: [], rejection: rejection.freeze)
    end

    def initialize(events:, rejection:)
      @events = events.freeze
      @rejection = rejection
      freeze
    end

    def accepted?
      rejection.nil?
    end

    def rejected?
      !accepted?
    end
  end
end
