# frozen_string_literal: true

module RBBB
  # Replayable aggregate state for one independent bidding unit.
  class State
    Position = Struct.new(
      :maximum_minor_units,
      :priority,
      :executed_minor_units,
      keyword_init: true
    ) do
      def to_h
        {
          "maximum_minor_units" => maximum_minor_units,
          "priority" => priority,
          "executed_minor_units" => executed_minor_units
        }
      end
    end

    attr_reader :version, :positions, :leader_id, :standing_minor_units,
      :next_required_minor_units, :reserve_status

    def self.empty(configuration)
      new(
        version: 0,
        positions: {},
        leader_id: nil,
        standing_minor_units: nil,
        next_required_minor_units: configuration.opening_minor_units,
        reserve_status: configuration.reserve_minor_units.nil? ? nil : "reserve_not_met"
      )
    end

    def initialize(version:, positions:, leader_id:, standing_minor_units:,
      next_required_minor_units:, reserve_status: nil)
      @version = version
      @positions = positions.each_with_object({}) do |(bidder_id, position), copy|
        copy[bidder_id.to_s.freeze] = coerce_position(position)
      end.freeze
      @leader_id = leader_id&.to_s&.freeze
      @standing_minor_units = standing_minor_units
      @next_required_minor_units = next_required_minor_units
      @reserve_status = reserve_status&.to_s&.freeze
      validate!
      freeze
    end

    def position_for(bidder_id)
      positions[bidder_id.to_s]
    end

    def to_h
      result = {
        "version" => version,
        "leader_id" => leader_id,
        "standing_minor_units" => standing_minor_units,
        "next_required_minor_units" => next_required_minor_units
      }
      if leader_id
        result["leader_maximum_minor_units"] = positions.fetch(leader_id).maximum_minor_units
        result["leader_executed_minor_units"] = positions.fetch(leader_id).executed_minor_units
      end
      result["reserve_status"] = reserve_status if reserve_status
      result
    end

    private

    def coerce_position(position)
      return position if position.is_a?(Position) && position.frozen?

      values = position.respond_to?(:to_h) ? position.to_h.transform_keys(&:to_s) : {}
      Position.new(
        maximum_minor_units: values.fetch("maximum_minor_units"),
        priority: values.fetch("priority"),
        executed_minor_units: values.fetch("executed_minor_units")
      ).freeze
    rescue KeyError => e
      raise InvalidState, "position is missing #{e.key}"
    end

    def validate!
      raise InvalidState, "version must be a non-negative integer" unless version.is_a?(Integer) && version >= 0
      unless next_required_minor_units.is_a?(Integer) && next_required_minor_units >= 0
        raise InvalidState, "next required amount must be a non-negative integer"
      end
      unless [nil, "reserve_not_met", "reserve_met"].include?(reserve_status)
        raise InvalidState, "reserve status is invalid"
      end
      if leader_id && !positions.key?(leader_id)
        raise InvalidState, "leader must have a position"
      end
      if leader_id.nil? != standing_minor_units.nil?
        raise InvalidState, "leader and standing amount must be present together"
      end

      positions.each_value do |position|
        unless position.maximum_minor_units.is_a?(Integer) && position.maximum_minor_units >= 0
          raise InvalidState, "maximums must be non-negative integers"
        end
        unless position.priority.is_a?(Integer) && position.priority.positive? && position.priority <= version
          raise InvalidState, "position priority must belong to the applied event stream"
        end
        unless position.executed_minor_units.is_a?(Integer) &&
            position.executed_minor_units.between?(0, position.maximum_minor_units)
          raise InvalidState, "executed amount must be between zero and maximum"
        end
      end

      return unless leader_id

      leader = positions.fetch(leader_id)
      unless standing_minor_units.is_a?(Integer) &&
          standing_minor_units.between?(0, leader.maximum_minor_units)
        raise InvalidState, "standing amount must be within the leader maximum"
      end
      unless next_required_minor_units > standing_minor_units
        raise InvalidState, "next required amount must exceed standing amount"
      end

      ranked_leader = positions.min_by do |bidder_id, position|
        [-position.maximum_minor_units, position.priority, bidder_id]
      end.first
      raise InvalidState, "leader does not match maximum priority" unless ranked_leader == leader_id
    end
  end
end
