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
      :next_required_minor_units, :reserve_status, :opens_at, :closes_at,
      :last_effective_at, :reserve_minor_units, :authorization_history,
      :reserve_history, :voided_bid_ids, :status, :result, :winner_id,
      :winning_minor_units

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

    def initialize(version:, positions:, leader_id:, standing_minor_units:,
      next_required_minor_units:, reserve_status: nil, opens_at: nil, closes_at: nil,
      last_effective_at: nil, reserve_minor_units: nil,
      authorization_history: [], reserve_history: [],
      voided_bid_ids: [], status: "open", result: nil, winner_id: nil,
      winning_minor_units: nil)
      @version = version
      @positions = positions.each_with_object({}) do |(bidder_id, position), copy|
        copy[bidder_id.to_s.freeze] = coerce_position(position)
      end.freeze
      @leader_id = leader_id&.to_s&.freeze
      @standing_minor_units = standing_minor_units
      @next_required_minor_units = next_required_minor_units
      @reserve_status = reserve_status&.to_s&.freeze
      @reserve_minor_units = reserve_minor_units
      @opens_at = coerce_timestamp(opens_at, "opens_at")
      @closes_at = coerce_timestamp(closes_at, "closes_at")
      @last_effective_at = coerce_timestamp(last_effective_at, "last_effective_at")
      @authorization_history = authorization_history.map do |entry|
        coerce_authorization(entry)
      end.freeze
      @reserve_history = reserve_history.map do |entry|
        coerce_reserve_change(entry)
      end.freeze
      @voided_bid_ids = voided_bid_ids.map { |bid_id| bid_id.to_s.freeze }.freeze
      @status = status.to_s.freeze
      @result = result&.to_s&.freeze
      @winner_id = winner_id&.to_s&.freeze
      @winning_minor_units = winning_minor_units
      validate!
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

    def to_h
      result = {
        "version" => version,
        "leader_id" => leader_id,
        "standing_minor_units" => standing_minor_units,
        "next_required_minor_units" => next_required_minor_units,
        "status" => status
      }
      result["opens_at"] = Timestamp.dump(opens_at) if opens_at
      result["closes_at"] = Timestamp.dump(closes_at) if closes_at
      result["last_effective_at"] = Timestamp.dump(last_effective_at) if last_effective_at
      if leader_id
        result["leader_maximum_minor_units"] = positions.fetch(leader_id).maximum_minor_units
        result["leader_executed_minor_units"] = positions.fetch(leader_id).executed_minor_units
      end
      result["reserve_status"] = reserve_status if reserve_status
      result["reserve_minor_units"] = reserve_minor_units unless reserve_minor_units.nil?
      result["voided_bid_ids"] = voided_bid_ids if voided_bid_ids.any?
      result["result"] = self.result if self.result
      result["winner_id"] = winner_id if winner_id
      result["winning_minor_units"] = winning_minor_units unless winning_minor_units.nil?
      result
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

      values = position.respond_to?(:to_h) ? position.to_h.transform_keys(&:to_s) : {}
      Position.new(
        maximum_minor_units: values.fetch("maximum_minor_units"),
        priority: values.fetch("priority"),
        executed_minor_units: values.fetch("executed_minor_units")
      ).freeze
    rescue KeyError => e
      raise InvalidState, "position is missing #{e.key}"
    end

    def coerce_authorization(entry)
      values = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s) : {}
      normalized = {
        "type" => values.fetch("type").to_s.freeze,
        "bidder_id" => values.fetch("bidder_id").to_s.freeze,
        "maximum_minor_units" => values.fetch("maximum_minor_units"),
        "priority" => values.fetch("priority")
      }
      if normalized.fetch("type") == "place_bid"
        normalized["bid_id"] = values.fetch("bid_id").to_s.freeze
      end
      normalized.freeze
    rescue KeyError => e
      raise InvalidState, "authorization is missing #{e.key}"
    end

    def coerce_reserve_change(entry)
      values = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s) : {}
      {
        "old_reserve_minor_units" => values.fetch("old_reserve_minor_units"),
        "new_reserve_minor_units" => values.fetch("new_reserve_minor_units"),
        "priority" => values.fetch("priority")
      }.freeze
    rescue KeyError => e
      raise InvalidState, "reserve change is missing #{e.key}"
    end

    def validate!
      raise InvalidState, "version must be a non-negative integer" unless version.is_a?(Integer) && version >= 0
      unless next_required_minor_units.is_a?(Integer) && next_required_minor_units >= 0
        raise InvalidState, "next required amount must be a non-negative integer"
      end
      unless [nil, "reserve_not_met", "reserve_met"].include?(reserve_status)
        raise InvalidState, "reserve status is invalid"
      end
      unless valid_optional_minor_units?(reserve_minor_units)
        raise InvalidState, "reserve must be a non-negative integer or nil"
      end
      if reserve_minor_units.nil? != reserve_status.nil?
        raise InvalidState, "reserve and reserve status must be present together"
      end
      if opens_at && closes_at && opens_at >= closes_at
        raise InvalidState, "opens_at must be earlier than closes_at"
      end
      validate_authorization_history!
      validate_reserve_history!
      validate_lifecycle!
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

    def validate_authorization_history!
      priorities = authorization_history.map { |entry| entry.fetch("priority") }
      unless priorities.all? { |priority| priority.is_a?(Integer) }
        raise InvalidState, "authorization priority must belong to the event stream"
      end
      unless priorities == priorities.sort && priorities.uniq == priorities
        raise InvalidState, "authorization priorities must be unique and ordered"
      end

      bid_ids = []
      authorization_history.each do |entry|
        unless %w[place_bid maximum_reduced].include?(entry.fetch("type"))
          raise InvalidState, "authorization type is invalid"
        end
        unless entry.fetch("maximum_minor_units").is_a?(Integer) &&
            entry.fetch("maximum_minor_units") >= 0
          raise InvalidState, "authorization maximum must be a non-negative integer"
        end
        if entry.fetch("bidder_id").empty?
          raise InvalidState, "authorization bidder ID must be present"
        end
        unless entry.fetch("priority").positive? && entry.fetch("priority") <= version
          raise InvalidState, "authorization priority must belong to the event stream"
        end
        next unless entry.fetch("type") == "place_bid"

        bid_id = entry.fetch("bid_id")
        raise InvalidState, "authorization bid ID must be present" if bid_id.empty?

        bid_ids << bid_id
      end
      raise InvalidState, "bid IDs must be unique" unless bid_ids.uniq == bid_ids
      unless voided_bid_ids.uniq == voided_bid_ids
        raise InvalidState, "voided bid IDs must be unique"
      end
      unless voided_bid_ids.all? { |bid_id| bid_ids.include?(bid_id) }
        raise InvalidState, "voided bid IDs must refer to accepted bids"
      end
    end

    def validate_reserve_history!
      priorities = reserve_history.map { |entry| entry.fetch("priority") }
      valid_priorities = priorities.all? do |priority|
        priority.is_a?(Integer) && priority.positive? && priority <= version
      end
      unless valid_priorities
        raise InvalidState, "reserve change priority must belong to the event stream"
      end
      unless priorities == priorities.sort && priorities.uniq == priorities
        raise InvalidState, "reserve change priorities must be unique and ordered"
      end
      unless (priorities & authorization_history.map { |entry| entry.fetch("priority") }).empty?
        raise InvalidState, "state history priorities must be unique"
      end

      reserve_history.each do |entry|
        unless valid_optional_minor_units?(entry.fetch("old_reserve_minor_units")) &&
            valid_optional_minor_units?(entry.fetch("new_reserve_minor_units"))
          raise InvalidState, "reserve change values must be non-negative integers or nil"
        end
      end
      reserve_history.each_cons(2) do |previous, current|
        unless previous.fetch("new_reserve_minor_units") ==
            current.fetch("old_reserve_minor_units")
          raise InvalidState, "reserve change history must be continuous"
        end
      end
      if reserve_history.any? &&
          reserve_history.last.fetch("new_reserve_minor_units") != reserve_minor_units
        raise InvalidState, "current reserve must match reserve change history"
      end
    end

    def valid_optional_minor_units?(value)
      value.nil? || (value.is_a?(Integer) && value >= 0)
    end

    def validate_lifecycle!
      unless %w[open closed].include?(status)
        raise InvalidState, "bidding status is invalid"
      end
      if status == "open"
        unless result.nil? && winner_id.nil? && winning_minor_units.nil?
          raise InvalidState, "open bidding cannot have a closing result"
        end
        return
      end

      unless %w[sold no_sale no_bid].include?(result)
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
