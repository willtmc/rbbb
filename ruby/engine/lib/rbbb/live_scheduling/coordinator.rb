# frozen_string_literal: true

module RBBB
  module LiveScheduling
    # Pure auction-scoped decision maker. The host must serialize ALL mutation
    # entry points and atomically commit this result with receipt/outbox records.
    class Coordinator
      Result = Struct.new(:state, :records, :rejection_reason, :retired_group_ids, :configurations, keyword_init: true)
      attr_reader :auction_id, :configurations, :policy, :profile, :snapshot

      def initialize(auction_id:, configurations:, snapshot:, policy:, profile: PROFILE, retired_group_ids: [])
        Intent.identifier(auction_id)
        Intent.object(policy, %w[minimum_shortening_lead_seconds])
        Intent.revision(policy["minimum_shortening_lead_seconds"])
        raise InvalidConfiguration, "minimum lead must be positive" unless policy["minimum_shortening_lead_seconds"].positive?
        @auction_id = auction_id
        @configurations = LiveScheduling.copy(configurations)
        @policy = LiveScheduling.copy(policy)
        @profile = LiveScheduling.copy(profile)
        Intent.object(@profile, PROFILE.keys)
        Intent.identifier(@profile['id'])
        (PROFILE.keys - ['id']).each do |key|
          raise InvalidConfiguration, "invalid resource bound" unless @profile[key].is_a?(Integer) && @profile[key].between?(1, PROFILE[key])
        end
        @snapshot = LiveScheduling.copy(snapshot)
        @original_closing_sets = LiveScheduling.copy(snapshot.fetch("closing_sets"))
        @retired_group_ids = retired_group_ids.dup
        @retired_group_set = @retired_group_ids.to_h { |id| [id, true] }
        configurations.each_value { |config| Configuration.from_h(config) }
        snapshot.fetch("units").each_value { |unit| State.from_h(unit) }
        @snapshot["closing_sets"] = LiveScheduling.sort_sets(snapshot.fetch("closing_sets").map { |set| Intent.normalize_set(set) })
        validate_snapshot!
        @unit_to_set = {}
        @group_to_set = {}
        @snapshot["closing_sets"].each do |set|
          @group_to_set[set["group_id"]] = set if set["group_id"]
          set["member_unit_ids"].each { |id| @unit_to_set[id] = set }
        end
      end

      def register_unit(intent:, principal_id:, permissions:, effective_at:, commit_id:)
        intent = Intent.normalize_registration(intent)
        Intent.identifier(principal_id)
        Intent.identifier(commit_id)
        return reject("invalid_request") unless intent["auction_id"] == auction_id
        return reject("not_authorized") unless permissions.include?("register")
        return reject("resource_limit_exceeded") if profile["affected_units"] < 1 || profile["closing_sets"] < 1
        return reject("stale_revision") unless intent["expected_schedule_revision"] == snapshot["schedule_revision"]
        id = intent["unit_id"]
        return reject("unit_id_conflict") if configurations.key?(id) || snapshot["units"].key?(id)
        config = intent["configuration"]
        at = LiveScheduling.time(effective_at)
        return reject("invalid_schedule") unless LiveScheduling.time(config["closes_at"]) > at
        return reject("version_exhausted") if snapshot["schedule_revision"] >= MAX_SAFE_INTEGER
        state = LiveScheduling.copy(snapshot)
        empty = State.empty(Configuration.from_h(config)).to_h
        state["units"][id] = empty
        state["schedule_revision"] += 1
        set_extension = config["extension"]&.slice("trigger_window_seconds", "duration_seconds")
        set = {"group_id" => nil, "member_unit_ids" => [id], "closes_at" => config["closes_at"], "extension" => set_extension}
        state["closing_sets"] = LiveScheduling.sort_sets(state["closing_sets"] + [set])
        creation = {"capability" => CAPABILITY, "type" => "bidding_unit_registered", "visibility" => "privileged",
          "command_id" => intent["command_id"], "commit_id" => commit_id, "auction_id" => auction_id,
          "unit_id" => id, "effective_at" => LiveScheduling.dump_time(at), "operator_id" => principal_id,
          "reason" => intent["reason"], "configuration" => LiveScheduling.copy(config), "state" => empty}
        decision = result(state, [creation, change_record(intent["command_id"], commit_id, at, state, [id], [set], [])], commit_id: commit_id)
        decision.configurations = configurations.merge(id => LiveScheduling.copy(config)) unless decision.rejection_reason
        decision
      end

      def edit(intent:, principal_id:, permissions:, effective_at:, commit_id:)
        intent = Intent.normalize(intent)
        return reject("invalid_request") unless intent["auction_id"] == auction_id
        return reject("not_authorized") unless permissions.include?("schedule")
        sets = intent.fetch("resulting_closing_sets")
        requested = sets.flat_map { |set| set.fetch("member_unit_ids") }
        affected = discover(requested, sets.map { |set| set["group_id"] }.compact + intent["retired_group_ids"])
        return reject("resource_limit_exceeded") if affected.size > profile.fetch("affected_units") || sets.size > profile.fetch("closing_sets") || intent["retired_group_ids"].size > profile.fetch("retired_groups")
        return reject("stale_revision") unless intent["expected_schedule_revision"] == snapshot["schedule_revision"]
        versions = intent["expected_units"].to_h { |unit| unit.values_at("unit_id", "version") }
        return reject("stale_revision") if versions.any? { |id, version| snapshot["units"].key?(id) && snapshot["units"][id]["version"] != version }
        return reject("duplicate_membership") unless requested.uniq.size == requested.size
        return reject("conflicting_group_definition") if sets.any? { |set| set["group_id"] && @retired_group_set.key?(set["group_id"]) }
        return reject("incomplete_affected_set") unless requested.sort == affected.sort && versions.keys.sort == affected.sort && affected.all? { |id| snapshot["units"].key?(id) }
        previous = affected_sets(affected)
        old_groups = previous.map { |set| set["group_id"] }.compact
        new_groups = sets.map { |set| set["group_id"] }.compact
        return reject("conflicting_group_definition") unless (old_groups - new_groups).sort == intent["retired_group_ids"].sort
        if intent["type"] == "revise_closing_schedule" && membership(previous) != membership(sets)
          return reject("conflicting_group_definition")
        end
        at = LiveScheduling.time(effective_at)
        units = affected.map { |id| snapshot["units"].fetch(id) }
        return reject("elapsed_or_closed_unit") if units.any? { |unit| unit["status"] != "open" || LiveScheduling.time(unit["closes_at"]) <= at }
        return reject("effective_at_out_of_order") if units.any? { |unit| unit["last_effective_at"] && LiveScheduling.time(unit["last_effective_at"]) > at }
        return reject("invalid_schedule") if sets.any? { |set| LiveScheduling.time(set["closes_at"]) <= at || set["member_unit_ids"].any? { |id| LiveScheduling.time(set["closes_at"]) <= LiveScheduling.time(snapshot["units"][id]["opens_at"]) } }
        shortened = sets.select { |set| set["member_unit_ids"].any? { |id| LiveScheduling.time(set["closes_at"]) < LiveScheduling.time(snapshot["units"][id]["closes_at"]) } }
        unless shortened.empty?
          return reject("shortening_not_allowed") unless intent["allow_shortening"] && permissions.include?("shorten")
          return reject("shortening_lead_too_short") if shortened.any? { |set| LiveScheduling.time(set["closes_at"]) < at + policy["minimum_shortening_lead_seconds"] }
        end
        return reject("no_change") if previous == sets
        return reject("version_exhausted") if exhausted?(affected)

        state = LiveScheduling.copy(snapshot)
        dumped_at = LiveScheduling.dump_time(at)
        sets.each do |set|
          dumped_close = LiveScheduling.dump_time(set["closes_at"])
          set["member_unit_ids"].each do |id|
            state["units"][id].merge!("version" => state["units"][id]["version"] + 1,
              "closes_at" => dumped_close, "last_effective_at" => dumped_at)
          end
        end
        state["schedule_revision"] += 1
        previous_set_ids = previous.to_h { |set| [set.object_id, true] }
        remaining = snapshot["closing_sets"].reject { |set| previous_set_ids.key?(set.object_id) }
        state["closing_sets"] = LiveScheduling.sort_sets(remaining + sets)
        public_record = change_record(intent["command_id"], commit_id, at, state, affected, sets, intent["retired_group_ids"])
        audit = public_record.merge("type" => "closing_configuration_committed", "visibility" => "privileged",
          "operator_id" => principal_id, "reason" => intent["reason"], "allow_shortening" => intent["allow_shortening"],
          "previous_schedule_revision" => snapshot["schedule_revision"], "previous_unit_versions" => unit_versions(snapshot, affected),
          "previous_closing_sets" => wire_sets(previous))
        kinds = change_kinds(previous, sets)
        notice = public_record.slice("capability", "command_id", "commit_id", "auction_id", "effective_at").merge(
          "type" => "closing_change_notice", "visibility" => "privileged", "affected_unit_ids" => affected.sort,
          "change_kinds" => kinds, "audience" => "affected_participants")
        result(state, [audit, public_record, notice], @retired_group_ids + intent["retired_group_ids"], commit_id: commit_id)
      rescue Intent::Invalid, ArgumentError, KeyError
        reject("invalid_request")
      end

      def bid(unit_id:, command:, effective_at:, commit_id:)
        return reject("invalid_request") unless %w[place_bid reduce_maximum].include?(command["type"])
        return reject("invalid_request") unless snapshot["units"].key?(unit_id)
        set = @unit_to_set.fetch(unit_id)
        engine = unit_engine(unit_id, set, extension: nil)
        before = State.from_h(snapshot["units"].fetch(unit_id))
        command = command.merge("effective_at" => LiveScheduling.dump_time(effective_at))
        decision = engine.decide(before, command)
        return reject(decision.rejection.fetch("reason")) if decision.rejected?
        after = engine.apply(before, decision.events)
        standing = decision.events.find { |event| event.public? && event.type == "standing_bid_changed" }
        own_adjustment = before.leader_id == command["bidder_id"] && before.position_for(command["bidder_id"]) && after.leader_id == before.leader_id
        qualifying = standing && !own_adjustment
        at = LiveScheduling.time(effective_at)
        return reject("effective_at_out_of_order") if set["member_unit_ids"].any? { |id| snapshot['units'][id]['last_effective_at'] && LiveScheduling.time(snapshot['units'][id]['last_effective_at']) > at }
        original_closing = LiveScheduling.time(set["closes_at"])
        closing = original_closing
        if qualifying && set["extension"] && at >= original_closing - set["extension"]["trigger_window_seconds"]
          begin
            candidate = [original_closing, at + set["extension"]["duration_seconds"]].max
            closing = Timestamp.parse(candidate)
          rescue ArgumentError, RangeError
            return reject("invalid_closing_time")
          end
        end
        extended = closing > original_closing
        affected = extended ? set["member_unit_ids"] : [unit_id]
        return reject("resource_limit_exceeded") if affected.size > profile.fetch('affected_units')
        return reject("version_exhausted") if affected.any? { |id| snapshot["units"][id]["version"] >= MAX_SAFE_INTEGER } || (extended && snapshot["schedule_revision"] >= MAX_SAFE_INTEGER)
        state = LiveScheduling.copy(snapshot)
        state["units"][unit_id] = after.to_h
        events = decision.events.map(&:to_h)
        records = []
        if extended
          dumped_closing = LiveScheduling.dump_time(closing)
          dumped_at = LiveScheduling.dump_time(at)
          state["schedule_revision"] += 1
          new_set = set.merge("closes_at" => dumped_closing)
          remaining = snapshot["closing_sets"].reject { |item| item.equal?(set) }
          state["closing_sets"] = LiveScheduling.sort_sets(remaining + [new_set])
          affected.each do |id|
            unit = state["units"][id]
            unit["version"] += 1 unless id == unit_id
            unit.merge!("closes_at" => dumped_closing, "last_effective_at" => dumped_at)
          end
          events.each { |event| event["closes_at"] = dumped_closing if event.key?("closes_at") }
          events << {"type" => "closing_time_changed", "command_id" => command["command_id"],
            "aggregate_version" => after.version, "closes_at" => dumped_closing}
          records << change_record(command["command_id"], commit_id, at, state, affected, [new_set], [])
        end
        result(state, events.map { |event| {"unit_id" => unit_id, "event" => event} } + records, commit_id: commit_id)
      rescue ArgumentError, RangeError
        reject("invalid_request")
      end

      def void_bid(unit_id:, command:, effective_at:, commit_id:)
        return reject("invalid_request") unless command["type"] == "void_bid"
        operator_unit_change(unit_id: unit_id, command: command, effective_at: effective_at, commit_id: commit_id)
      end

      def change_reserve(unit_id:, command:, effective_at:, commit_id:)
        return reject("invalid_request") unless command["type"] == "change_reserve"
        operator_unit_change(unit_id: unit_id, command: command, effective_at: effective_at, commit_id: commit_id)
      end

      def operator_unit_change(unit_id:, command:, effective_at:, commit_id:)
        return reject("invalid_request") unless snapshot["units"].key?(unit_id)
        set = @unit_to_set.fetch(unit_id)
        at = LiveScheduling.time(effective_at)
        return reject("effective_at_out_of_order") if set["member_unit_ids"].any? { |id| snapshot["units"][id]["last_effective_at"] && LiveScheduling.time(snapshot["units"][id]["last_effective_at"]) > at }
        return reject("version_exhausted") if snapshot["units"][unit_id]["version"] >= MAX_SAFE_INTEGER
        engine = unit_engine(unit_id, set, extension: nil)
        before = State.from_h(snapshot["units"].fetch(unit_id))
        decision = engine.decide(before, command.merge("effective_at" => LiveScheduling.dump_time(at)))
        return reject(decision.rejection.fetch("reason")) if decision.rejected?
        state = LiveScheduling.copy(snapshot)
        state["units"][unit_id] = engine.apply(before, decision.events).to_h
        records = decision.events.map { |event| {"unit_id" => unit_id, "event" => event.to_h} }
        result(state, records, commit_id: commit_id)
      rescue ArgumentError, RangeError
        reject("invalid_request")
      end

      private :operator_unit_change

      def close(group_id: nil, unit_id: nil, command:, effective_at:, commit_id:)
        return reject("invalid_request") unless command["type"] == "close_bidding" && (!!group_id != !!unit_id)
        set = if group_id
          @group_to_set[group_id]
        else
          candidate = @unit_to_set[unit_id]
          candidate if candidate && candidate["group_id"].nil?
        end
        return reject("invalid_request") unless set
        at = LiveScheduling.time(effective_at)
        dumped_at = LiveScheduling.dump_time(at)
        ids = set["member_unit_ids"].sort
        return reject("resource_limit_exceeded") if ids.size > profile["affected_units"]
        return reject("version_exhausted") if exhausted?(ids)
        state = LiveScheduling.copy(snapshot)
        records = []
        ids.each do |id|
          engine = unit_engine(id, set, extension: set["extension"])
          before = State.from_h(snapshot["units"][id])
          decision = engine.decide(before, command.merge("effective_at" => dumped_at))
          return reject(decision.rejection.fetch("reason")) if decision.rejected?
          state["units"][id] = engine.apply(before, decision.events).to_h
          records.concat(decision.events.map { |event| {"unit_id" => id, "event" => event.to_h} })
        end
        state["schedule_revision"] += 1
        records << change_record(command["command_id"], commit_id, at, state, ids, [set], [])
        result(state, records, commit_id: commit_id)
      rescue ArgumentError, RangeError
        reject("invalid_request")
      end

      private

      def validate_snapshot!
        Intent.revision(snapshot.fetch("schedule_revision"))
        members = snapshot["closing_sets"].flat_map { |set| set["member_unit_ids"] }
        raise InvalidState, "invalid partition" unless members.sort == snapshot["units"].keys.sort && members.uniq.size == members.size && configurations.keys.sort == members.sort
        snapshot["closing_sets"].each do |set|
          set_close = LiveScheduling.time(set["closes_at"])
          set["member_unit_ids"].each do |id|
            raise InvalidState, "deadline mismatch" unless LiveScheduling.time(snapshot["units"][id]["closes_at"]) == set_close
          end
        end
      end

      def discover(ids, group_ids)
        found = {}
        ids.each do |id|
          found[id] = true
          set = @unit_to_set[id]
          set["member_unit_ids"].each { |member| found[member] = true } if set
        end
        group_ids.each do |group_id|
          set = @group_to_set[group_id]
          set["member_unit_ids"].each { |member| found[member] = true } if set
        end
        found.keys.sort
      end

      def affected_sets(ids)
        seen = {}
        ids.each do |id|
          set = @unit_to_set[id]
          seen[set.object_id] = set if set
        end
        LiveScheduling.sort_sets(seen.values)
      end

      def membership(sets)
        sets.map { |set| [set["group_id"], set["member_unit_ids"]] }
      end

      def unit_engine(id, set, extension:)
        config = configurations.fetch(id).merge("closes_at" => set["closes_at"], "extension" => extension)
        Engine.new(Configuration.from_h(config))
      end

      def exhausted?(ids)
        snapshot["schedule_revision"] >= MAX_SAFE_INTEGER || ids.any? { |id| snapshot["units"][id]["version"] >= MAX_SAFE_INTEGER }
      end

      def unit_versions(state, ids)
        ids.sort.map { |id| {"unit_id" => id, "version" => state["units"][id]["version"]} }
      end

      def wire_sets(sets)
        LiveScheduling.sort_sets(sets).map { |set| set.merge("closes_at" => LiveScheduling.dump_time(set["closes_at"])) }
      end

      def change_record(command_id, commit_id, at, state, ids, sets, retired)
        {"capability" => CAPABILITY, "type" => "closing_configuration_changed", "command_id" => command_id,
          "commit_id" => commit_id, "auction_id" => auction_id, "effective_at" => LiveScheduling.dump_time(at),
          "visibility" => "public", "schedule_revision" => state["schedule_revision"],
          "unit_versions" => unit_versions(state, ids), "resulting_closing_sets" => wire_sets(sets), "retired_group_ids" => retired.sort}
      end

      def change_kinds(previous, sets)
        kinds = []
        kinds << "membership" unless membership(previous) == membership(sets)
        old_by_unit = {}
        old_times = {}
        previous.each do |item|
          old_times[item.object_id] = LiveScheduling.time(item["closes_at"])
          item["member_unit_ids"].each { |id| old_by_unit[id] = item }
        end
        sets.each do |set|
          new_time = LiveScheduling.time(set["closes_at"])
          set["member_unit_ids"].each do |id|
            old = old_by_unit.fetch(id)
            old_time = old_times.fetch(old.object_id)
            kinds << "extended" if new_time > old_time
            kinds << "shortened" if new_time < old_time
            kinds << "policy" unless set["extension"] == old["extension"]
          end
        end
        kinds.uniq.sort
      end

      def reject(reason)
        Result.new(state: LiveScheduling.copy(snapshot), records: [], rejection_reason: reason, retired_group_ids: @retired_group_ids.dup)
      end

      def result(state, records, retired = @retired_group_ids, commit_id:)
        return reject("resource_limit_exceeded") if LiveScheduling.encoded_batch_size(records, commit_id) > profile["batch_bytes"]
        # Only the scheduling delta's affected sets change in whole-commit
        # replay. Preserve all other sets exactly, including timestamp spelling.
        changed_set = {}
        records.each do |record|
          next unless record["type"] == "closing_configuration_changed"
          record.fetch("unit_versions").each { |unit| changed_set[unit.fetch("unit_id")] = true }
        end
        if changed_set.empty?
          state["closing_sets"] = LiveScheduling.sort_sets(LiveScheduling.copy(@original_closing_sets))
        else
          untouched = @original_closing_sets.reject { |set| set["member_unit_ids"].any? { |id| changed_set.key?(id) } }
          affected = state["closing_sets"].select { |set| set["member_unit_ids"].any? { |id| changed_set.key?(id) } }
          state["closing_sets"] = LiveScheduling.sort_sets(LiveScheduling.copy(untouched) + wire_sets(affected))
        end
        Result.new(state: state, records: records, rejection_reason: nil, retired_group_ids: retired.uniq.sort)
      end
    end
  end
end
