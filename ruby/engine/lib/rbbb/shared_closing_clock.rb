# frozen_string_literal: true

module RBBB
  # RFC 0003 clock component; the host owns atomic unit/clock persistence.
  class SharedClosingClock
    attr_reader :revision, :closes_at, :quiet_period_seconds, :last_effective_at

    def initialize(group_id:, unit_ids:, closes_at:, quiet_period_seconds:, revision: 0, last_effective_at: nil)
      unless group_id.is_a?(String) && !group_id.empty? && unit_ids.is_a?(Array) && !unit_ids.empty? &&
          unit_ids.all? { |id| id.is_a?(String) && !id.empty? } && unit_ids.uniq.size == unit_ids.size
        raise InvalidConfiguration, "invalid group identities"
      end
      unless quiet_period_seconds.is_a?(Integer) && quiet_period_seconds.between?(1, MAX_SAFE_INTEGER) &&
          revision.is_a?(Integer) && revision.between?(0, MAX_SAFE_INTEGER)
        raise InvalidConfiguration, "invalid clock bounds"
      end
      @group_id = group_id.dup.freeze
      @unit_ids = unit_ids.map { |id| id.dup.freeze }.sort.freeze
      @closes_at = parse_time(closes_at)
      @quiet_period_seconds = quiet_period_seconds
      @revision = revision
      @last_effective_at = last_effective_at && parse_time(last_effective_at)
      raise InvalidConfiguration, "clock decision time must precede closing" if @last_effective_at && @last_effective_at >= @closes_at
      freeze
    end

    def after_decision(unit_id:, decision:, expected_revision:)
      deadline_for(unit_id)
      raise InvalidState, "stale clock revision" unless expected_revision.is_a?(Integer) && expected_revision == revision
      raise InvalidState, "engine decision required" unless decision.is_a?(Decision)
      return self if decision.rejected?

      transitions = decision.events.select(&:privileged?)
      unless transitions.size == 1 && %w[maximum_accepted maximum_increased maximum_reduced].include?(transitions.first.type)
        raise InvalidState, "unsupported accepted decision"
      end
      transition = transitions.first
      data = transition.data
      unless data.key?("effective_at") && data.key?("closes_at") && parse_time(data["closes_at"]) == closes_at
        raise InvalidState, "unit decision is not synchronized with shared clock"
      end
      time = parse_time(data["effective_at"])
      raise InvalidState, "accepted decision outside clock ordering" if time >= closes_at || (last_effective_at && time < last_effective_at)
      qualifying = qualifying?(transition, decision)
      deadline = closes_at
      if qualifying && time >= closes_at - quiet_period_seconds
        deadline = parse_time([closes_at, time + quiet_period_seconds].max)
      end
      next_revision = revision + (deadline > closes_at ? 1 : 0)
      raise InvalidState, "clock revision exhausted" if next_revision > MAX_SAFE_INTEGER
      self.class.new(group_id: @group_id, unit_ids: @unit_ids, closes_at: deadline,
        quiet_period_seconds: quiet_period_seconds, revision: next_revision, last_effective_at: time)
    end

    def deadline_for(unit_id)
      raise InvalidState, "unknown group member" unless @unit_ids.include?(unit_id)
      closes_at
    end

    def due?(at:)
      parse_time(at) >= closes_at
    end

    def public_view
      {"group_id" => @group_id, "unit_ids" => @unit_ids, "closes_at" => Timestamp.dump(closes_at), "revision" => revision}
    end

    def to_h
      public_view.merge("quiet_period_seconds" => quiet_period_seconds, "last_effective_at" => Timestamp.dump(last_effective_at))
    end

    private

    # RFC 0004: any accepted change to the public standing qualifies, except the
    # current leader adjusting their own maximum. A leader change always qualifies.
    def qualifying?(transition, decision)
      standing = decision.events.find { |event| event.public? && event.type == "standing_bid_changed" }
      return false unless standing
      return true if standing.data["leader_changed"]

      transition.type == "maximum_accepted" || transition.data["leader_id"] != transition.data["bidder_id"]
    end

    def parse_time(value)
      time = Timestamp.parse(value)
      raise InvalidConfiguration, "timestamp outside supported range" unless time.year.between?(1, 9999)
      time
    rescue ArgumentError, RangeError
      raise InvalidConfiguration, "invalid clock timestamp"
    end
  end
end
