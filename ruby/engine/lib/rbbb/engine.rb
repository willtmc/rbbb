# frozen_string_literal: true

module RBBB
  # Deterministic RFC 0001 state transitions implemented to a claimed subset.
  class Engine
    SUPPORTED_COMMANDS = %w[place_bid reduce_maximum void_bid].freeze
    NOTIFICATION_POLICIES = %w[affected removed_bidder all_bidders none].freeze
    STATE_TRANSITION_EVENTS = %w[
      maximum_accepted
      maximum_increased
      maximum_reduced
      bid_voided
    ].freeze

    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
      unless configuration.is_a?(Configuration)
        raise InvalidConfiguration, "engine requires an RBBB::Configuration"
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
      return reject(command_id, "invalid_command") unless present_string?(command_id)
      if values.key?("expected_version") && values["expected_version"] != state.version
        return reject(command_id, "stale_aggregate_version")
      end

      case values.fetch("type")
      when "place_bid"
        return reject(command_id, "invalid_command") unless present_string?(values["bidder_id"])

        decide_place_bid(state, values)
      when "reduce_maximum"
        return reject(command_id, "invalid_command") unless present_string?(values["bidder_id"])

        decide_reduce_maximum(state, values)
      when "void_bid"
        decide_void_bid(state, values)
      end
    end

    def apply(state, events)
      transition = events.find do |event|
        event.privileged? && STATE_TRANSITION_EVENTS.include?(event.type)
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
        reserve_status: transition.data["reserve_status"],
        opens_at: state.opens_at,
        closes_at: transition.data.fetch("closes_at", state.closes_at),
        authorization_history: transition.data.fetch(
          "authorization_history",
          state.authorization_history
        ),
        voided_bid_ids: transition.data.fetch("voided_bid_ids", state.voided_bid_ids)
      )
    end

    private

    def decide_place_bid(state, command)
      bidder_id = command.fetch("bidder_id").to_s
      bid_id = command["bid_id"] || command.fetch("command_id")
      maximum = command["maximum_minor_units"]
      command_id = command["command_id"]
      return reject(command_id, "invalid_command") unless present_string?(bid_id)
      return reject(command_id, "bid_id_already_exists") if state.bid_record_for(bid_id)

      effective_at = authoritative_time(command)
      timing_rejection = reject_for_timing(state, command_id, effective_at)
      return timing_rejection if timing_rejection
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

      build_bid_decision(state, command, bid_id, bidder_id, maximum, existing, effective_at)
    end

    def decide_reduce_maximum(state, command)
      bidder_id = command.fetch("bidder_id").to_s
      maximum = command["maximum_minor_units"]
      command_id = command["command_id"]
      effective_at = authoritative_time(command)
      timing_rejection = reject_for_timing(state, command_id, effective_at)
      return timing_rejection if timing_rejection
      unless maximum.is_a?(Integer) && maximum >= 0
        return reject(command_id, "invalid_maximum")
      end

      existing = state.position_for(bidder_id)
      return reject(command_id, "maximum_not_found") unless existing
      if maximum >= existing.maximum_minor_units
        return reject(command_id, "maximum_not_reduced")
      end
      if maximum < existing.executed_minor_units
        return reject(
          command_id,
          "maximum_below_executed_amount",
          "executed_floor_minor_units" => existing.executed_minor_units
        )
      end

      build_reduction_decision(state, command, bidder_id, maximum, existing, effective_at)
    end

    def decide_void_bid(state, command)
      command_id = command.fetch("command_id")
      bid_id = command["bid_id"]
      operator_id = command["operator_id"]
      reason = command["reason"]
      policy = command["notification_policy"]
      unless present_string?(bid_id) && present_string?(operator_id) && present_string?(reason)
        return reject(command_id, "invalid_command")
      end
      unless NOTIFICATION_POLICIES.include?(policy)
        return reject(command_id, "invalid_notification_policy")
      end

      effective_at = authoritative_time(command)
      timing_rejection = reject_for_timing(state, command_id, effective_at)
      return timing_rejection if timing_rejection

      target = state.bid_record_for(bid_id)
      return reject(command_id, "bid_not_found") unless target
      return reject(command_id, "bid_already_voided") if state.voided_bid_ids.include?(bid_id)

      build_void_decision(state, command, target, effective_at)
    end

    def build_bid_decision(state, command, bid_id, bidder_id, maximum, existing, effective_at)
      aggregate_version = state.version + 1
      authorization_history = state.authorization_history.map(&:dup)
      authorization_history << {
        "type" => "place_bid",
        "bid_id" => bid_id,
        "bidder_id" => bidder_id,
        "maximum_minor_units" => maximum,
        "priority" => aggregate_version
      }
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
      public_result_changed = standing != state.standing_minor_units ||
        leader_id != state.leader_id
      closes_at = extended_closing_time(state, effective_at, public_result_changed)

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
          "bid_id" => bid_id,
          "bidder_id" => bidder_id,
          "maximum_minor_units" => maximum,
          "executed_minor_units" => positions.fetch(bidder_id).fetch("executed_minor_units"),
          "leader_id" => leader_id,
          "standing_minor_units" => standing,
          "next_required_minor_units" => next_required,
          "reserve_status" => reserve_status,
          "effective_at" => Timestamp.dump(effective_at),
          "closes_at" => Timestamp.dump(closes_at),
          "positions" => positions,
          "authorization_history" => authorization_history,
          "voided_bid_ids" => state.voided_bid_ids
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
      if closes_at != state.closes_at
        events << Event.new(
          type: "closing_time_changed",
          visibility: :public,
          data: {
            "command_id" => command.fetch("command_id"),
            "aggregate_version" => aggregate_version,
            "closes_at" => Timestamp.dump(closes_at)
          }
        )
      end

      Decision.accepted(events)
    end

    def build_reduction_decision(state, command, bidder_id, maximum, existing, effective_at)
      aggregate_version = state.version + 1
      authorization_history = state.authorization_history.map(&:dup)
      authorization_history << {
        "type" => "maximum_reduced",
        "bidder_id" => bidder_id,
        "maximum_minor_units" => maximum,
        "priority" => aggregate_version
      }
      positions = state.positions.transform_values(&:to_h)
      positions[bidder_id] = {
        "maximum_minor_units" => maximum,
        "priority" => aggregate_version,
        "executed_minor_units" => existing.executed_minor_units
      }

      event = Event.new(
        type: "maximum_reduced",
        visibility: :privileged,
        data: {
          "command_id" => command.fetch("command_id"),
          "aggregate_version" => aggregate_version,
          "bidder_id" => bidder_id,
          "old_maximum_minor_units" => existing.maximum_minor_units,
          "new_maximum_minor_units" => maximum,
          "executed_floor_minor_units" => existing.executed_minor_units,
          "leader_id" => state.leader_id,
          "standing_minor_units" => state.standing_minor_units,
          "next_required_minor_units" => state.next_required_minor_units,
          "reserve_status" => state.reserve_status,
          "effective_at" => Timestamp.dump(effective_at),
          "closes_at" => Timestamp.dump(state.closes_at),
          "positions" => positions,
          "authorization_history" => authorization_history,
          "voided_bid_ids" => state.voided_bid_ids
        }
      )

      Decision.accepted([event])
    end

    def build_void_decision(state, command, target, effective_at)
      aggregate_version = state.version + 1
      voided_bid_ids = [*state.voided_bid_ids, command.fetch("bid_id")]
      recomputed = replay_authorizations(state.authorization_history, voided_bid_ids)
      common_data = {
        "command_id" => command.fetch("command_id"),
        "aggregate_version" => aggregate_version
      }

      events = [Event.new(
        type: "bid_voided",
        visibility: :privileged,
        data: common_data.merge(
          "bid_id" => command.fetch("bid_id"),
          "bidder_id" => target.fetch("bidder_id"),
          "operator_id" => command.fetch("operator_id"),
          "reason" => command.fetch("reason"),
          "notification_policy" => command.fetch("notification_policy"),
          "effective_at" => Timestamp.dump(effective_at),
          "leader_id" => recomputed.fetch("leader_id"),
          "standing_minor_units" => recomputed.fetch("standing_minor_units"),
          "next_required_minor_units" => recomputed.fetch("next_required_minor_units"),
          "reserve_status" => recomputed.fetch("reserve_status"),
          "closes_at" => Timestamp.dump(state.closes_at),
          "positions" => recomputed.fetch("positions"),
          "authorization_history" => state.authorization_history,
          "voided_bid_ids" => voided_bid_ids
        )
      )]

      executed_amount_changes(state, recomputed).each do |change|
        events << Event.new(
          type: "executed_amount_changed",
          visibility: :privileged,
          data: common_data.merge(change)
        )
      end

      if public_state_changed?(state, recomputed)
        public_data = common_data.merge(
          "standing_minor_units" => recomputed.fetch("standing_minor_units"),
          "next_required_minor_units" => recomputed.fetch("next_required_minor_units"),
          "leader_changed" => state.leader_id != recomputed.fetch("leader_id")
        )
        reserve_status = recomputed.fetch("reserve_status")
        public_data["reserve_status"] = reserve_status if reserve_status
        events << Event.new(
          type: "standing_bid_changed",
          visibility: :public,
          data: public_data
        )
      end

      events << Event.new(
        type: "notification_requested",
        visibility: :privileged,
        data: common_data.merge(
          "bid_id" => command.fetch("bid_id"),
          "reason" => command.fetch("reason"),
          "policy" => command.fetch("notification_policy"),
          "bidder_ids" => notification_recipients(
            state,
            recomputed,
            target,
            command.fetch("notification_policy")
          )
        )
      )

      Decision.accepted(events)
    end

    def replay_authorizations(history, voided_bid_ids)
      positions = {}

      history.each do |entry|
        bidder_id = entry.fetch("bidder_id")
        maximum = entry.fetch("maximum_minor_units")
        if entry.fetch("type") == "place_bid"
          next if voided_bid_ids.include?(entry.fetch("bid_id"))

          existing = positions[bidder_id]
          positions[bidder_id] = {
            "maximum_minor_units" => maximum,
            "priority" => entry.fetch("priority"),
            "executed_minor_units" => existing&.fetch("executed_minor_units") || 0
          }
          snapshot = price_positions(positions)
          apply_executions!(positions, snapshot)
        else
          existing = positions[bidder_id]
          next unless existing
          next unless maximum < existing.fetch("maximum_minor_units")
          next unless maximum >= existing.fetch("executed_minor_units")

          existing["maximum_minor_units"] = maximum
          existing["priority"] = entry.fetch("priority")
        end
      end

      return empty_pricing_snapshot.merge("positions" => {}) if positions.empty?

      price_positions(positions).merge("positions" => positions)
    end

    def price_positions(positions)
      ranked = positions.sort_by do |id, position|
        [-position.fetch("maximum_minor_units"), position.fetch("priority"), id]
      end
      leader_id = ranked.fetch(0).first
      standing = standing_amount(ranked)
      {
        "leader_id" => leader_id,
        "standing_minor_units" => standing,
        "next_required_minor_units" => standing + configuration.increment_for(standing),
        "reserve_status" => reserve_status_for(ranked.fetch(0).last)
      }
    end

    def empty_pricing_snapshot
      {
        "leader_id" => nil,
        "standing_minor_units" => nil,
        "next_required_minor_units" => configuration.opening_minor_units,
        "reserve_status" => configuration.reserve_minor_units ? "reserve_not_met" : nil
      }
    end

    def apply_executions!(positions, snapshot)
      leader_id = snapshot.fetch("leader_id")
      standing = snapshot.fetch("standing_minor_units")
      positions.each do |id, position|
        executed = id == leader_id ? standing : position.fetch("maximum_minor_units")
        position["executed_minor_units"] = [
          position.fetch("executed_minor_units"),
          executed
        ].max
      end
    end

    def executed_amount_changes(state, recomputed)
      recomputed.fetch("positions").keys.sort.filter_map do |bidder_id|
        old_position = state.position_for(bidder_id)
        new_amount = recomputed.fetch("positions").fetch(bidder_id).fetch("executed_minor_units")
        next unless old_position && old_position.executed_minor_units != new_amount

        {
          "bidder_id" => bidder_id,
          "old_minor_units" => old_position.executed_minor_units,
          "new_minor_units" => new_amount
        }
      end
    end

    def public_state_changed?(state, recomputed)
      state.standing_minor_units != recomputed.fetch("standing_minor_units") ||
        state.leader_id != recomputed.fetch("leader_id") ||
        state.reserve_status != recomputed.fetch("reserve_status")
    end

    def notification_recipients(state, recomputed, target, policy)
      case policy
      when "affected"
        bidders = [target.fetch("bidder_id")]
        if state.leader_id != recomputed.fetch("leader_id")
          bidders.concat([state.leader_id, recomputed.fetch("leader_id")])
        end
        bidders.compact.uniq.sort
      when "removed_bidder"
        [target.fetch("bidder_id")]
      when "all_bidders"
        state.authorization_history.filter_map do |entry|
          entry.fetch("bidder_id") if entry.fetch("type") == "place_bid"
        end.uniq.sort
      when "none"
        []
      end
    end

    def authoritative_time(command)
      value = command["effective_at"]
      return nil if value.nil?

      Timestamp.parse(value)
    rescue ArgumentError
      nil
    end

    def reject_for_timing(state, command_id, effective_at)
      return reject(command_id, "invalid_command") if state.closes_at && !effective_at
      return reject(command_id, "bidding_closed") if state.closes_at && effective_at >= state.closes_at

      nil
    end

    def extended_closing_time(state, effective_at, public_result_changed)
      return state.closes_at unless configuration.extension
      return state.closes_at unless public_result_changed && effective_at && state.closes_at

      trigger_window = configuration.extension.fetch("trigger_window_seconds")
      return state.closes_at if effective_at < state.closes_at - trigger_window

      effective_at + configuration.extension.fetch("duration_seconds")
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

    def reject(command_id, reason, details = {})
      Decision.rejected(command_id: command_id, reason: reason, details: details)
    end

    def present_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
