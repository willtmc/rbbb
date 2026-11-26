# frozen_string_literal: true

module RBBB
  # RFC 0002 initial planning only. Never applies a schedule to live state.
  module InitialClosingSchedule
    ALLOWED_GROUP_KEYS = {"group_id" => true, "unit_ids" => true, "closes_at" => true}.freeze

    module_function

    def plan(unit_ids:, opens_at:, first_closes_at:, lots_per_minute:, groups: [])
      units = identities(unit_ids)
      opening = timestamp(opens_at)
      first = timestamp(first_closes_at)
      raise InvalidConfiguration, "first closing must follow opening" unless first > opening
      unless lots_per_minute.is_a?(Integer) && lots_per_minute.between?(1, MAX_SAFE_INTEGER)
        raise InvalidConfiguration, "lots_per_minute must be a positive interoperable integer"
      end
      raise InvalidConfiguration, "groups must be an array" unless groups.is_a?(Array)

      original = units.each_with_index.to_h do |id, index|
        [id, timestamp(first + (index / lots_per_minute) * 60)]
      end
      resolved = original.dup
      assigned = {}
      group_ids = {}
      planned_groups = groups.map do |group|
        unless group.is_a?(Hash) && group.each_key.all? { |key| ALLOWED_GROUP_KEYS.key?(key) }
          raise InvalidConfiguration, "invalid group shape"
        end
        id = identity(group["group_id"])
        raise InvalidConfiguration, "duplicate group identity" if group_ids.key?(id)
        group_ids[id] = true
        members = identities(group["unit_ids"]).sort
        members.each do |member|
          if !original.key?(member) || assigned.key?(member)
            raise InvalidConfiguration, "unknown or overlapping group member"
          end
          assigned[member] = true
        end
        close = group.key?("closes_at") ? timestamp(group["closes_at"]) : members.map { |member| original.fetch(member) }.max
        raise InvalidConfiguration, "group closing must follow opening" unless close > opening
        members.each { |member| resolved[member] = close }
        {"group_id" => id, "unit_ids" => members, "closes_at" => Timestamp.dump(close)}
      end
      {"version" => 1, "scope" => "initial_schedule_plan_only",
       "initial_closes_at" => original.transform_values { |time| Timestamp.dump(time) },
       "unit_closes_at" => resolved.transform_values { |time| Timestamp.dump(time) },
       "groups" => planned_groups.sort_by { |group| group.fetch("group_id") }}
    end

    def identity(value)
      raise InvalidConfiguration, "identity must be a nonempty string" unless value.is_a?(String) && !value.empty?
      value.dup
    end
    private_class_method :identity

    def identities(values)
      raise InvalidConfiguration, "identities must be a nonempty array" unless values.is_a?(Array) && !values.empty?
      seen = {}
      values.map do |value|
        id = identity(value)
        raise InvalidConfiguration, "duplicate identity" if seen.key?(id)
        seen[id] = true
        id
      end
    end
    private_class_method :identities

    def timestamp(value)
      Timestamp.parse(value)
    rescue ArgumentError, RangeError
      raise InvalidConfiguration, "invalid scheduling timestamp"
    end
    private_class_method :timestamp
  end
end
