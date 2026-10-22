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
        # Retained records have an authoritative order. Never sort a damaged or
        # partial batch into an apparently valid commit during recovery.
        unit_order = baseline.map { |record| record.fetch("unit_id") }
        raise InvalidState, "record order conflict" unless records == baseline + deltas && unit_order == unit_order.sort
        baseline.each do |record|
          raise InvalidState, "invalid unit record" unless record.keys.sort == %w[event unit_id]
        end
        command_ids = baseline.map { |record| record.fetch("event").fetch("command_id") }.uniq
        raise InvalidState, "mixed command batch" if command_ids.size > 1
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
          transitions = entries.select { |entry| entry.fetch("event").key?("positions") && Engine::STATE_TRANSITION_EVENTS.include?(entry["event"]["type"]) }
          raise InvalidState, "missing or reordered unit transition" unless transitions.size == 1 && entries.first == transitions.first
          identities = entries.map { |entry| entry.fetch("event").values_at("command_id", "aggregate_version") }.uniq
          raise InvalidState, "unit event identity conflict" unless identities.size == 1
          if changes.any?
            raise InvalidState, "command identity conflict" unless identities.first.first == changes.first.fetch("command_id")
          end
          before = State.from_h(state.fetch("units").fetch(id))
          engine = Engine.new(Configuration.from_h(configurations.fetch(id).merge("closes_at" => before.to_h["closes_at"], "extension" => nil)))
          validate_unit_records!(engine, before, entries.map { |entry| entry.fetch("event") }, changes.first)
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
        closing = baseline.select { |record| record.dig("event", "type") == "bidding_closed" }
        if closing.any?
          raise InvalidState, "partial group close" unless closing == baseline && closing.map { |record| record["unit_id"] }.uniq.sort == ids.sort
        end
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

      # Derive the complete native event batch from its privileged transition.
      # Engine.apply alone restores that transition even when public/audit
      # companions are missing. Whole-commit replay must refuse that damage.
      def validate_unit_records!(engine, before, records, change)
        transition = records.first
        command = transition.slice("command_id", "effective_at", "bidder_id", "bid_id", "operator_id", "reason", "notification_policy")
        command["type"] = case transition.fetch("type")
        when "maximum_accepted", "maximum_increased"
          command["maximum_minor_units"] = transition.fetch("maximum_minor_units")
          "place_bid"
        when "maximum_reduced"
          command["maximum_minor_units"] = transition.fetch("new_maximum_minor_units")
          "reduce_maximum"
        when "reserve_changed"
          command["reserve_minor_units"] = transition.fetch("new_reserve_minor_units")
          "change_reserve"
        when "bid_voided" then "void_bid"
        when "bidding_closed" then "close_bidding"
        else raise InvalidState, "unsupported unit transition"
        end
        decision = engine.decide(before, command)
        raise InvalidState, "invalid unit transition" if decision.rejected?
        expected = decision.events.map(&:to_h)
        if %w[maximum_accepted maximum_increased].include?(transition["type"]) &&
            LiveScheduling.time(transition.fetch("closes_at")) > before.closes_at
          raise InvalidState, "missing linked extension" unless change && change["effective_at"] == transition["effective_at"]
          expected.each { |event| event["closes_at"] = transition["closes_at"] if event.key?("closes_at") }
          expected << transition.slice("command_id", "aggregate_version", "closes_at").merge("type" => "closing_time_changed")
        end
        raise InvalidState, "incomplete or conflicting unit records" unless records == expected
      end
      private_class_method :validate_unit_records!
    end
  end
end
