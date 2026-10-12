# frozen_string_literal: true

module RBBB
  module LiveScheduling
    # Privileged whole-commit replay. A public consumer instead refetches a
    # consistent snapshot; it cannot synthesize private baseline bid history.
    module Projector
      module_function

      def apply(snapshot:, configurations:, records:)
        state = LiveScheduling.copy(snapshot)
        baseline, deltas = records.partition { |record| record.key?("unit_id") }
        changes = deltas.select { |record| record["type"] == "closing_configuration_changed" }
        raise InvalidState, "multiple scheduling deltas" if changes.size > 1
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
        return state if changes.empty?
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
