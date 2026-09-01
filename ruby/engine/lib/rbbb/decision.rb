# frozen_string_literal: true

module RBBB
  # Accepted events or one stable rejection from evaluating a command.
  class Decision
    attr_reader :events, :rejection

    def self.accepted(events)
      new(events: events, rejection: nil)
    end

    def self.rejected(command_id:, reason:, details: {})
      new(
        events: [],
        rejection: {
          "command_id" => command_id,
          "reason" => reason
        }.merge(details.transform_keys(&:to_s)).freeze
      )
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
