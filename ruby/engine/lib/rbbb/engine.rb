# frozen_string_literal: true

module RBBB
  # Deterministic RFC 0001 state transitions implemented to a claimed subset.
  class Engine
    SUPPORTED_COMMANDS = %w[place_bid].freeze

    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
      unless configuration.is_a?(Configuration)
        raise InvalidConfiguration, "engine requires an RBBB::Configuration"
      end
      if configuration.extension
        raise UnsupportedFeature, "extension behavior is not implemented in this engine version"
      end
    end

    def initial_state
      State.empty(configuration)
    end

    def decide(state, command)
      raise InvalidState, "engine requires an RBBB::State" unless state.is_a?(State)
      return reject(nil, "invalid_command") unless command.respond_to?(:transform_keys)

      values = command.transform_keys(&:to_s)
      command_id = values["command_id"]
      return reject(command_id, "unsupported_command") unless SUPPORTED_COMMANDS.include?(values["type"])
      unless present_string?(command_id) && present_string?(values["bidder_id"])
        return reject(command_id, "invalid_command")
      end
      if values.key?("expected_version") && values["expected_version"] != state.version
        return reject(command_id, "stale_aggregate_version")
      end

      decide_place_bid(state, values)
    end

    def apply(state, events)
      transition = events.find do |event|
        event.privileged? && %w[maximum_accepted maximum_increased].include?(event.type)
      end
      return state unless transition

      aggregate_version = transition.data.fetch("aggregate_version")
      unless aggregate_version == state.version + 1
        raise InvalidState, "event aggregate version is not the next version"
      end

      State.new(
        version: aggregate_version,
        positions: transition.data.fetch("positions"),
        leader_id: transition.data.fetch("leader_id"),
        standing_minor_units: transition.data.fetch("standing_minor_units"),
        next_required_minor_units: transition.data.fetch("next_required_minor_units"),
        reserve_status: transition.data["reserve_status"]
      )
    end

    private

    def decide_place_bid(state, command)
      bidder_id = command.fetch("bidder_id").to_s
      maximum = command["maximum_minor_units"]
      command_id = command["command_id"]
      unless maximum.is_a?(Integer) && maximum >= 0
        return reject(command_id, "invalid_maximum")
      end

      existing = state.position_for(bidder_id)
      if state.positions.empty? && maximum < configuration.opening_minor_units
        return reject(command_id, "maximum_below_opening")
      end
      if existing && maximum <= existing.maximum_minor_units
        return reject(command_id, "maximum_not_increased")
      end
      if state.leader_id && bidder_id != state.leader_id &&
          maximum < state.next_required_minor_units
        return reject(command_id, "maximum_below_next_required")
      end

      build_bid_decision(state, command, bidder_id, maximum, existing)
    end

    def build_bid_decision(state, command, bidder_id, maximum, existing)
      aggregate_version = state.version + 1
      positions = state.positions.transform_values(&:to_h)
      positions[bidder_id] = {
        "maximum_minor_units" => maximum,
        "priority" => aggregate_version,
        "executed_minor_units" => existing&.executed_minor_units || 0
      }

      ranked = positions.sort_by do |id, position|
        [-position.fetch("maximum_minor_units"), position.fetch("priority"), id]
      end
      leader_id = ranked.fetch(0).first
      standing = standing_amount(ranked)
      reserve_status = reserve_status_for(ranked.fetch(0).last)
      next_required = standing + configuration.increment_for(standing)

      positions.each do |id, position|
        executed = id == leader_id ? standing : position.fetch("maximum_minor_units")
        position["executed_minor_units"] = [
          position.fetch("executed_minor_units"),
          executed
        ].max
      end

      event_type = existing ? "maximum_increased" : "maximum_accepted"
      privileged = Event.new(
        type: event_type,
        visibility: :privileged,
        data: {
          "command_id" => command.fetch("command_id"),
          "aggregate_version" => aggregate_version,
          "bidder_id" => bidder_id,
          "maximum_minor_units" => maximum,
          "executed_minor_units" => positions.fetch(bidder_id).fetch("executed_minor_units"),
          "leader_id" => leader_id,
          "standing_minor_units" => standing,
          "next_required_minor_units" => next_required,
          "reserve_status" => reserve_status,
          "positions" => positions
        }
      )

      events = [privileged]
      if standing != state.standing_minor_units || leader_id != state.leader_id ||
          reserve_status != state.reserve_status
        public_data = {
          "command_id" => command.fetch("command_id"),
          "aggregate_version" => aggregate_version,
          "standing_minor_units" => standing,
          "next_required_minor_units" => next_required,
          "leader_changed" => leader_id != state.leader_id
        }
        public_data["reserve_status"] = reserve_status if reserve_status
        events << Event.new(
          type: "standing_bid_changed",
          visibility: :public,
          data: public_data
        )
      end

      Decision.accepted(events)
    end

    def standing_amount(ranked)
      leader = ranked.fetch(0).last
      competitive = if ranked.one?
        configuration.opening_minor_units
      else
        runner_up = ranked.fetch(1).last
        runner_up.fetch("maximum_minor_units") +
          configuration.increment_for(runner_up.fetch("maximum_minor_units"))
      end
      reserve_pressure = if configuration.reserve_minor_units
        [leader.fetch("maximum_minor_units"), configuration.reserve_minor_units].min
      else
        configuration.opening_minor_units
      end
      [
        leader.fetch("maximum_minor_units"),
        [configuration.opening_minor_units, competitive, reserve_pressure].max
      ].min
    end

    def reserve_status_for(leader)
      return nil unless configuration.reserve_minor_units

      if leader.fetch("maximum_minor_units") >= configuration.reserve_minor_units
        "reserve_met"
      else
        "reserve_not_met"
      end
    end

    def reject(command_id, reason)
      Decision.rejected(command_id: command_id, reason: reason)
    end

    def present_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
