# frozen_string_literal: true

module RBBB
  module LiveScheduling
    # Privileged whole-commit replay. A public consumer instead refetches a
    # consistent snapshot; it cannot synthesize private baseline bid history.
    module Projector
      module_function

      # Returns both detached registries. Callers must install them atomically.
      # Recompute creation from the accepted pure contract rather than trusting
      # submitted private state, version vectors or a partial public delta.
      def apply_commit(snapshot:, configurations:, records:, policy:, auction_id:, profile: PROFILE)
        unless records.any? { |record| record["type"] == "bidding_unit_registered" }
          return {"snapshot" => apply(snapshot: snapshot, configurations: configurations, records: records),
            "configurations" => LiveScheduling.copy(configurations)}
        end
        raise InvalidState, "incomplete registration commit" unless records.size == 2 && records[0]["type"] == "bidding_unit_registered" && records[1]["type"] == "closing_configuration_changed"
        creation = records[0]
        raise InvalidState, "wrong auction" unless creation.fetch("auction_id") == auction_id
        intent = {"type" => "register_unit", "command_id" => creation.fetch("command_id"),
          "auction_id" => auction_id, "unit_id" => creation.fetch("unit_id"),
          "expected_schedule_revision" => snapshot.fetch("schedule_revision"),
          "configuration" => creation.fetch("configuration"), "reason" => creation.fetch("reason")}
        coordinator = Coordinator.new(auction_id: auction_id, configurations: configurations,
          snapshot: snapshot, policy: policy, profile: profile)
        decision = coordinator.register_unit(intent: intent, principal_id: creation.fetch("operator_id"),
          permissions: ["register"], effective_at: creation.fetch("effective_at"), commit_id: creation.fetch("commit_id"))
        raise InvalidState, "incoherent registration commit" if decision.rejection_reason || decision.records != records
        {"snapshot" => decision.state, "configurations" => decision.configurations}
      rescue KeyError, TypeError, ArgumentError => e
        raise InvalidState, "incoherent registration commit: #{e.message}"
      end

      def apply(snapshot:, configurations:, records:)
        raise InvalidState, "registration requires apply_commit and atomic registry installation" if records.any? { |record| record["type"] == "bidding_unit_registered" }
        state = LiveScheduling.copy(snapshot)
        baseline, deltas = records.partition { |record| record.key?("unit_id") }
        changes = deltas.select { |record| record["type"] == "closing_configuration_changed" }
        raise InvalidState, "multiple scheduling deltas" if changes.size > 1
        unless deltas.empty?
          types = deltas.map { |record| record['type'] }
          manual = types == %w[closing_configuration_committed closing_configuration_changed closing_change_notice] && baseline.empty?
          automatic = types == ['closing_configuration_changed'] && !baseline.empty?
          raise InvalidState, "incomplete commit projection" unless manual || automatic
          if manual
            audit, change, notice = deltas
            shared = %w[capability command_id commit_id auction_id effective_at]
            raise InvalidState, "commit identity conflict" unless shared.all? { |key| audit[key] == change[key] && notice[key] == change[key] }
            raise InvalidState, "audit revision conflict" unless audit['previous_schedule_revision'] == snapshot['schedule_revision']
            raise InvalidState, "audit delta conflict" unless %w[schedule_revision unit_versions resulting_closing_sets retired_group_ids].all? { |key| audit[key] == change[key] }
          end
        end
        baseline.group_by { |record| record.fetch("unit_id") }.sort.each do |id, entries|
          before = State.from_h(state.fetch("units").fetch(id))
          engine = Engine.new(Configuration.from_h(configurations.fetch(id).merge("closes_at" => before.to_h["closes_at"])))
          events = entries.map do |entry|
            data = entry.fetch("event")
            Event.new(type: data.fetch("type"), visibility: data.key?("positions") ? :privileged : :public,
              data: data.reject { |key, _| key == "type" })
          end
          state["units"][id] = engine.apply(before, events).to_h
        end
        if changes.empty?
          changed_schedule = baseline.any? do |record|
            id = record.fetch('unit_id')
            before, after = snapshot['units'].fetch(id), state['units'].fetch(id)
            LiveScheduling.time(before['closes_at']) != LiveScheduling.time(after['closes_at']) || before['status'] != after['status']
          end
          raise InvalidState, "missing scheduling delta" if changed_schedule
          return state
        end
        change = changes.first
        raise InvalidState, "scheduling revision gap" unless change.fetch("schedule_revision") == snapshot.fetch("schedule_revision") + 1
        versions = change.fetch("unit_versions")
        ids = versions.map { |entry| entry.fetch("unit_id") }
        raise InvalidState, "duplicate version vector" unless ids.uniq.size == ids.size
        sets = change.fetch("resulting_closing_sets")
        members = sets.flat_map { |set| set.fetch("member_unit_ids") }
        raise InvalidState, "incomplete scheduling delta" unless members.sort == ids.sort
        previous = state["closing_sets"].select { |set| (set["member_unit_ids"] & ids).any? }
        raise InvalidState, "partial closing set" unless previous.flat_map { |set| set["member_unit_ids"] }.sort == ids.sort
        retired = change.fetch("retired_group_ids")
        raise InvalidState, "incorrect retired groups" unless (previous.map { |set| set["group_id"] }.compact - sets.map { |set| set["group_id"] }.compact).sort == retired.sort
        versions.each do |entry|
          id, version = entry.values_at("unit_id", "version")
          raise InvalidState, "unit version gap" unless version == snapshot["units"].fetch(id).fetch("version") + 1
          unit = state["units"].fetch(id)
          native = baseline.any? { |record| record["unit_id"] == id }
          raise InvalidState, "baseline version conflict" if native && unit["version"] != version
          set = sets.find { |item| item["member_unit_ids"].include?(id) }
          unit.merge!("version" => version, "closes_at" => set.fetch("closes_at"), "last_effective_at" => change.fetch("effective_at"))
          State.from_h(unit)
        end
        state["closing_sets"] = LiveScheduling.sort_sets(state["closing_sets"] - previous + sets)
        state["schedule_revision"] = change["schedule_revision"]
        state
      rescue KeyError, TypeError, ArgumentError => e
        raise InvalidState, "incoherent scheduling commit: #{e.message}"
      end
    end
  end
end
