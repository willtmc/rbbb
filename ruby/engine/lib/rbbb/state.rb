# frozen_string_literal: true

module RBBB
  # Replayable aggregate state for one independent bidding unit.
  class State
    Position = Struct.new(
      :maximum_minor_units,
      :executable_maximum_minor_units,
      :priority,
      :executed_minor_units,
      keyword_init: true
    ) do
      def to_h
        {
          "maximum_minor_units" => maximum_minor_units,
          "executable_maximum_minor_units" => executable_maximum_minor_units,
          "priority" => priority,
          "executed_minor_units" => executed_minor_units
        }
      end
    end

    attr_reader :version, :positions, :leader_id, :standing_minor_units,
      :next_required_minor_units, :reserve_status, :opens_at, :closes_at,
      :last_effective_at, :reserve_minor_units, :authorization_history,
      :reserve_history, :voided_bid_ids, :status, :result, :winner_id,
      :winning_minor_units

    # Aggregate snapshot keys owned by the bidding unit. A host adds
    # auction_id, bidding_unit_id, and currency to complete
    # specification/state/aggregate.schema.json.
    SNAPSHOT_KEYS = %w[
      version status opens_at closes_at last_effective_at reserve_minor_units
      reserve_status leader_id standing_minor_units next_required_minor_units
      positions authorization_history reserve_history voided_bid_ids result
      winner_id winning_minor_units
    ].freeze

    # Public projection keys owned by the bidding unit, per
    # specification/state/bidding-unit.schema.json. Never add an identity,
    # a maximum, a reserve amount, or audit history here.
    PUBLIC_VIEW_KEYS = %w[
      version status opens_at closes_at standing_minor_units
      next_required_minor_units reserve_status result winning_minor_units
    ].freeze

    # Keys every privileged state-transition event carries. Closing adds
    # status, result, winner_id, and winning_minor_units.
    TRANSITION_KEYS = %w[
      aggregate_version closes_at reserve_minor_units reserve_status leader_id
      standing_minor_units next_required_minor_units positions
      authorization_history reserve_history voided_bid_ids
    ].freeze

    EMPTY_ARRAY = [].freeze

    def self.empty(configuration)
      new(
        version: 0,
        positions: {},
        leader_id: nil,
        standing_minor_units: nil,
        next_required_minor_units: configuration.opening_minor_units,
        reserve_status: configuration.reserve_minor_units.nil? ? nil : "reserve_not_met",
        reserve_minor_units: configuration.reserve_minor_units,
        opens_at: configuration.opens_at,
        closes_at: configuration.closes_at,
        last_effective_at: nil,
        authorization_history: [],
        reserve_history: [],
        voided_bid_ids: [],
        status: "open"
      )
    end

    # Rebuild a validated state from a `State#to_h` snapshot. Identity keys
    # added by the host are ignored; every snapshot key must be present.
    def self.from_h(snapshot, bid_ladder: nil)
      raise InvalidState, "snapshot must be an object" unless snapshot.respond_to?(:transform_keys)

      values = string_keyed_hash?(snapshot) ? snapshot : snapshot.transform_keys(&:to_s)
      unless SNAPSHOT_KEYS.all? { |key| values.key?(key) }
        missing = SNAPSHOT_KEYS.reject { |key| values.key?(key) }
        raise InvalidState, "snapshot is missing #{missing.join(', ')}"
      end

      new(
        version: values.fetch("version"),
        positions: values.fetch("positions"),
        leader_id: values.fetch("leader_id"),
        standing_minor_units: values.fetch("standing_minor_units"),
        next_required_minor_units: values.fetch("next_required_minor_units"),
        reserve_status: values.fetch("reserve_status"),
        reserve_minor_units: values.fetch("reserve_minor_units"),
        opens_at: values.fetch("opens_at"),
        closes_at: values.fetch("closes_at"),
        last_effective_at: values.fetch("last_effective_at"),
        authorization_history: values.fetch("authorization_history"),
        reserve_history: values.fetch("reserve_history"),
        voided_bid_ids: values.fetch("voided_bid_ids"),
        status: values.fetch("status"),
        result: values.fetch("result"),
        winner_id: values.fetch("winner_id"),
        winning_minor_units: values.fetch("winning_minor_units"),
        bid_ladder: bid_ladder
      )
    rescue NoMethodError, TypeError
      raise InvalidState, "snapshot is malformed"
    end

    # Rebuild a validated state from one privileged state-transition event
    # (or its data hash). Every transition carries the full aggregate
    # snapshot, so a host can checkpoint from the latest transition instead
    # of replaying the stream from version 0. `opens_at` is fixed by
    # configuration and is not repeated in events.
    def self.from_transition(configuration, event_or_data)
      data = event_or_data.respond_to?(:data) ? event_or_data.data : event_or_data
      raise InvalidState, "transition data must be an object" unless data.respond_to?(:transform_keys)

      values = string_keyed_hash?(data) ? data : data.transform_keys(&:to_s)
      unless TRANSITION_KEYS.all? { |key| values.key?(key) }
        missing = TRANSITION_KEYS.reject { |key| values.key?(key) }
        raise InvalidState, "transition is missing #{missing.join(', ')}"
      end

      from_h(
        {
          "version" => values.fetch("aggregate_version"),
          "status" => values.fetch("status", "open"),
          "opens_at" => configuration.opens_at,
          "closes_at" => values["closes_at"],
          "last_effective_at" => values["effective_at"],
          "reserve_minor_units" => values["reserve_minor_units"],
          "reserve_status" => values["reserve_status"],
          "leader_id" => values["leader_id"],
          "standing_minor_units" => values["standing_minor_units"],
          "next_required_minor_units" => values["next_required_minor_units"],
          "positions" => values["positions"],
          "authorization_history" => values["authorization_history"],
          "reserve_history" => values["reserve_history"],
          "voided_bid_ids" => values["voided_bid_ids"],
          "result" => values["result"],
          "winner_id" => values["winner_id"],
          "winning_minor_units" => values["winning_minor_units"]
        },
        bid_ladder: configuration.bid_ladder
      )
    end

    def self.string_keyed_hash?(value)
      return false unless value.instance_of?(Hash)

      value.each_key { |key| return false unless key.is_a?(String) }
      true
    end
    private_class_method :string_keyed_hash?

    def initialize(version:, positions:, leader_id:, standing_minor_units:,
      next_required_minor_units:, reserve_status: nil, opens_at: nil, closes_at: nil,
      last_effective_at: nil, reserve_minor_units: nil,
      authorization_history: [], reserve_history: [],
      voided_bid_ids: [], status: "open", result: nil, winner_id: nil,
      winning_minor_units: nil, bid_ladder: nil)
      @version = version
      @positions = positions.each_with_object({}) do |(bidder_id, position), copy|
        copy[freeze_string(bidder_id)] = coerce_position(position)
      end.freeze
      @leader_id = leader_id.nil? ? nil : freeze_string(leader_id)
      @standing_minor_units = standing_minor_units
      @next_required_minor_units = next_required_minor_units
      @reserve_status = reserve_status.nil? ? nil : freeze_string(reserve_status)
      @reserve_minor_units = reserve_minor_units
      @opens_at = coerce_timestamp(opens_at, "opens_at")
      @closes_at = coerce_timestamp(closes_at, "closes_at")
      @last_effective_at = coerce_timestamp(last_effective_at, "last_effective_at")
      @authorization_history = if authorization_history.empty?
        EMPTY_ARRAY
      else
        authorization_history.map { |entry| coerce_authorization(entry) }.freeze
      end
      @reserve_history = if reserve_history.empty?
        EMPTY_ARRAY
      else
        reserve_history.map { |entry| coerce_reserve_change(entry) }.freeze
      end
      @voided_bid_ids = if voided_bid_ids.empty?
        EMPTY_ARRAY
      else
        voided_bid_ids.map { |bid_id| freeze_string(bid_id) }.freeze
      end
      @status = freeze_string(status)
      @result = result.nil? ? nil : freeze_string(result)
      @winner_id = winner_id.nil? ? nil : freeze_string(winner_id)
      @winning_minor_units = winning_minor_units
      validate!(bid_ladder: bid_ladder)
      freeze
    end

    def position_for(bidder_id)
      positions[bidder_id.to_s]
    end

    def bid_record_for(bid_id)
      authorization_history.find do |entry|
        entry.fetch("type") == "place_bid" && entry.fetch("bid_id") == bid_id.to_s
      end
    end

    def bidding_started?
      authorization_history.any? { |entry| entry.fetch("type") == "place_bid" }
    end

    def closed?
      status == "closed"
    end

    # Full privileged aggregate snapshot. Together with the host's
    # auction_id, bidding_unit_id, and currency it satisfies
    # specification/state/aggregate.schema.json and round-trips through
    # `State.from_h`. It contains identities, maxima, the reserve amount, and
    # audit history; never publish it.
    def to_h
      {
        "version" => version,
        "status" => status,
        "opens_at" => Timestamp.dump(opens_at),
        "closes_at" => Timestamp.dump(closes_at),
        "last_effective_at" => Timestamp.dump(last_effective_at),
        "reserve_minor_units" => reserve_minor_units,
        "reserve_status" => reserve_status,
        "leader_id" => leader_id,
        "standing_minor_units" => standing_minor_units,
        "next_required_minor_units" => next_required_minor_units,
        "positions" => positions.transform_values(&:to_h),
        "authorization_history" => authorization_history.map(&:dup),
        "reserve_history" => reserve_history.map(&:dup),
        "voided_bid_ids" => voided_bid_ids.dup,
        "result" => result,
        "winner_id" => winner_id,
        "winning_minor_units" => winning_minor_units
      }
    end

    # Public query projection. Together with the host's auction_id,
    # bidding_unit_id, and currency it satisfies
    # specification/state/bidding-unit.schema.json. It never carries a
    # bidder, leader, or winner identity, a maximum, the reserve amount, or
    # audit history.
    def public_view
      {
        "version" => version,
        "status" => status,
        "opens_at" => Timestamp.dump(opens_at),
        "closes_at" => Timestamp.dump(closes_at),
        "standing_minor_units" => standing_minor_units,
        "next_required_minor_units" => next_required_minor_units,
        "reserve_status" => reserve_status,
        "result" => result,
        "winning_minor_units" => winning_minor_units
      }
    end

    def ==(other)
      other.is_a?(State) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    private

    def coerce_timestamp(value, field)
      return nil if value.nil?

      Timestamp.parse(value)
    rescue ArgumentError
      raise InvalidState, "#{field} must be a valid ISO 8601 timestamp"
    end

    def coerce_position(position)
      return position if position.is_a?(Position) && position.frozen?

      values = if self.class.send(:string_keyed_hash?, position)
        position
      elsif position.respond_to?(:to_h)
        position.to_h.transform_keys(&:to_s)
      else
        {}
      end
      Position.new(
        maximum_minor_units: values.fetch("maximum_minor_units"),
        executable_maximum_minor_units: values.fetch("executable_maximum_minor_units"),
        priority: values.fetch("priority"),
        executed_minor_units: values.fetch("executed_minor_units")
      ).freeze
    rescue KeyError => e
      raise InvalidState, "position is missing #{e.key}"
    end

    def coerce_authorization(entry)
      if entry.instance_of?(Hash) && entry.frozen?
        type = entry["type"]
        bidder_id = entry["bidder_id"]
        if type.is_a?(String) && type.frozen? && bidder_id.is_a?(String) && bidder_id.frozen? &&
            entry.key?("maximum_minor_units") && entry.key?("priority")
          if type == "place_bid" && entry.size == 5 &&
              (bid_id = entry["bid_id"]).is_a?(String) && bid_id.frozen?
            return entry
          elsif type == "maximum_reduced" && entry.size == 4
            return entry
          end
        end
      end

      values = if self.class.send(:string_keyed_hash?, entry)
        entry
      elsif entry.respond_to?(:to_h)
        entry.to_h.transform_keys(&:to_s)
      else
        {}
      end
      type = freeze_string(values.fetch("type"))
      normalized = {
        "type" => type,
        "bidder_id" => freeze_string(values.fetch("bidder_id")),
        "maximum_minor_units" => values.fetch("maximum_minor_units"),
        "priority" => values.fetch("priority")
      }
      if type == "place_bid"
        normalized["bid_id"] = freeze_string(values.fetch("bid_id"))
      end
      normalized.freeze
    rescue KeyError => e
      raise InvalidState, "authorization is missing #{e.key}"
    end

    def coerce_reserve_change(entry)
      if entry.instance_of?(Hash) && entry.frozen? && entry.size == 3 &&
          entry.key?("old_reserve_minor_units") &&
          entry.key?("new_reserve_minor_units") &&
          entry.key?("priority")
        return entry
      end

      values = if self.class.send(:string_keyed_hash?, entry)
        entry
      elsif entry.respond_to?(:to_h)
        entry.to_h.transform_keys(&:to_s)
      else
        {}
      end
      {
        "old_reserve_minor_units" => values.fetch("old_reserve_minor_units"),
        "new_reserve_minor_units" => values.fetch("new_reserve_minor_units"),
        "priority" => values.fetch("priority")
      }.freeze
    rescue KeyError => e
      raise InvalidState, "reserve change is missing #{e.key}"
    end

    def freeze_string(value)
      value.is_a?(String) ? -value : value.to_s.freeze
    end

    def validate!(bid_ladder: nil)
      unless version.is_a?(Integer) && version.between?(0, MAX_SAFE_INTEGER)
        raise InvalidState, "version must be a non-negative integer no greater than #{MAX_SAFE_INTEGER}"
      end
      unless Money.amount?(next_required_minor_units)
        raise InvalidState, "next required amount must be a non-negative integer no greater than #{Money::MAX_MINOR_UNITS}"
      end
      unless reserve_status.nil? || reserve_status == "reserve_not_met" || reserve_status == "reserve_met"
        raise InvalidState, "reserve status is invalid"
      end
      unless valid_optional_minor_units?(reserve_minor_units)
        raise InvalidState, "reserve must be a non-negative integer or nil"
      end
      if reserve_minor_units.nil? != reserve_status.nil?
        raise InvalidState, "reserve and reserve status must be present together"
      end
      raise InvalidState, "state is missing opens_at" if opens_at.nil?
      raise InvalidState, "state is missing closes_at" if closes_at.nil?
      if opens_at >= closes_at
        raise InvalidState, "opens_at must be earlier than closes_at"
      end
      auth_priorities = validate_authorization_history!
      validate_reserve_history!(auth_priorities)
      validate_lifecycle!
      if leader_id && !positions.key?(leader_id)
        raise InvalidState, "leader must have a position"
      end
      if leader_id.nil? != standing_minor_units.nil?
        raise InvalidState, "leader and standing amount must be present together"
      end

      positions.each_value do |position|
        unless Money.amount?(position.maximum_minor_units)
          raise InvalidState, "maximums must be non-negative integers no greater than #{Money::MAX_MINOR_UNITS}"
        end
        unless Money.amount?(position.executable_maximum_minor_units) &&
            position.executable_maximum_minor_units <= position.maximum_minor_units
          raise InvalidState, "executable maximum must be within entered maximum"
        end
        unless position.priority.is_a?(Integer) && position.priority.positive? && position.priority <= version
          raise InvalidState, "position priority must belong to the applied event stream"
        end
        unless position.executed_minor_units.is_a?(Integer) &&
            position.executed_minor_units.between?(0, position.executable_maximum_minor_units)
          raise InvalidState, "executed amount must be between zero and maximum"
        end
      end

      return unless leader_id

      leader = positions.fetch(leader_id)
      unless Money.amount?(standing_minor_units) &&
          standing_minor_units <= leader.executable_maximum_minor_units
        raise InvalidState, "standing amount must be within the leader maximum"
      end
      # The next required amount saturates only at the final rung of the bid
      # ladder, where no higher rung fits within Money::MAX_MINOR_UNITS.
      saturated = standing_minor_units == next_required_minor_units &&
        if bid_ladder
          bid_ladder.above(standing_minor_units).nil?
        else
          standing_minor_units == leader.executable_maximum_minor_units &&
            standing_minor_units > Money::MAX_MINOR_UNITS / 2
        end
      unless saturated || next_required_minor_units > standing_minor_units
        raise InvalidState, "next required amount must exceed standing amount"
      end

      ranked_leader = if positions.size == 1
        positions.each_key.first
      else
        positions.min_by do |bidder_id, position|
          [-position.executable_maximum_minor_units, position.priority, bidder_id]
        end.first
      end
      raise InvalidState, "leader does not match maximum priority" unless ranked_leader == leader_id
    end

    def validate_authorization_history!
      prev_priority = nil
      bid_ids = {}
      auth_priorities = reserve_history.empty? ? nil : {}

      authorization_history.each do |entry|
        priority = entry.fetch("priority")
        unless priority.is_a?(Integer)
          raise InvalidState, "authorization priority must belong to the event stream"
        end
        if prev_priority && priority <= prev_priority
          raise InvalidState, "authorization priorities must be unique and ordered"
        end
        prev_priority = priority

        type = entry.fetch("type")
        unless type == "place_bid" || type == "maximum_reduced"
          raise InvalidState, "authorization type is invalid"
        end
        unless Money.amount?(entry.fetch("maximum_minor_units"))
          raise InvalidState, "authorization maximum must be a non-negative integer no greater than #{Money::MAX_MINOR_UNITS}"
        end
        if entry.fetch("bidder_id").empty?
          raise InvalidState, "authorization bidder ID must be present"
        end
        unless priority.positive? && priority <= version
          raise InvalidState, "authorization priority must belong to the event stream"
        end
        auth_priorities[priority] = true if auth_priorities

        next unless type == "place_bid"

        bid_id = entry.fetch("bid_id")
        raise InvalidState, "authorization bid ID must be present" if bid_id.empty?
        raise InvalidState, "bid IDs must be unique" if bid_ids.key?(bid_id)

        bid_ids[bid_id] = true
      end

      unless voided_bid_ids.empty?
        seen_voided = {}
        missing_voided = false
        voided_bid_ids.each do |bid_id|
          raise InvalidState, "voided bid IDs must be unique" if seen_voided.key?(bid_id)
          seen_voided[bid_id] = true
          missing_voided = true unless bid_ids.key?(bid_id)
        end
        raise InvalidState, "voided bid IDs must refer to accepted bids" if missing_voided
      end

      auth_priorities
    end

    def validate_reserve_history!(auth_priorities)
      return if reserve_history.empty?

      prev_priority = nil
      prev_new_reserve = nil
      has_prev = false
      reserve_history.each do |entry|
        priority = entry.fetch("priority")
        unless priority.is_a?(Integer) && priority.positive? && priority <= version
          raise InvalidState, "reserve change priority must belong to the event stream"
        end
        if prev_priority && priority <= prev_priority
          raise InvalidState, "reserve change priorities must be unique and ordered"
        end
        if auth_priorities&.key?(priority)
          raise InvalidState, "state history priorities must be unique"
        end
        prev_priority = priority

        old_reserve = entry.fetch("old_reserve_minor_units")
        new_reserve = entry.fetch("new_reserve_minor_units")
        unless valid_optional_minor_units?(old_reserve) && valid_optional_minor_units?(new_reserve)
          raise InvalidState, "reserve change values must be non-negative integers or nil"
        end
        if has_prev && prev_new_reserve != old_reserve
          raise InvalidState, "reserve change history must be continuous"
        end
        prev_new_reserve = new_reserve
        has_prev = true
      end
      if prev_new_reserve != reserve_minor_units
        raise InvalidState, "current reserve must match reserve change history"
      end
    end

    def valid_optional_minor_units?(value)
      value.nil? || Money.amount?(value)
    end

    def validate_lifecycle!
      unless status == "open" || status == "closed"
        raise InvalidState, "bidding status is invalid"
      end
      if status == "open"
        unless result.nil? && winner_id.nil? && winning_minor_units.nil?
          raise InvalidState, "open bidding cannot have a closing result"
        end
        return
      end

      unless result == "sold" || result == "no_sale" || result == "no_bid"
        raise InvalidState, "closed bidding result is invalid"
      end
      case result
      when "sold"
        unless leader_id && winner_id == leader_id && winning_minor_units == standing_minor_units
          raise InvalidState, "sold result must match the standing leader and amount"
        end
        if reserve_status == "reserve_not_met"
          raise InvalidState, "sold result requires reserve to be met"
        end
      when "no_sale"
        unless leader_id && standing_minor_units && reserve_status == "reserve_not_met"
          raise InvalidState, "no-sale result requires a leader below reserve"
        end
        unless winner_id.nil? && winning_minor_units.nil?
          raise InvalidState, "no-sale result cannot have a winner"
        end
      when "no_bid"
        unless leader_id.nil? && standing_minor_units.nil? &&
            winner_id.nil? && winning_minor_units.nil?
          raise InvalidState, "no-bid result cannot have a standing bid or winner"
        end
      end
    end
  end
end
