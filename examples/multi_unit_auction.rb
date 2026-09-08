# frozen_string_literal: true

require "json"
require_relative "../ruby/engine/lib/rbbb"

module RBBBExamples
  # Deterministic, single-process walkthrough of accepted RFC 0001 behavior.
  # This is not a persistence service, scheduling coordinator, or live host.
  class MultiUnitAuction
    def initialize
      @engines = {}
      @states = {}
      @events = Hash.new { |hash, key| hash[key] = [] }
      @trace = []
    end

    def run
      register("unit-a")
      register("unit-b", reserve_minor_units: 10_000)
      bid("unit-a", "first", "bidder-a", 5_000, "12:10:00")
      bid("unit-b", "reserve-bid", "bidder-b", 8_000, "12:11:00")
      # Host registration of a separate unit after another unit has bids.
      register("unit-c")
      bid("unit-a", "challenger", "bidder-c", 6_000, "12:58:00")
      submit("unit-a", command_id: "shorten", type: "change_closing_time",
        operator_id: "operator-a", reason: "synthetic_schedule_request",
        closes_at: instant("13:02:00"), effective_at: instant("12:59:00"))
      submit("unit-a", command_id: "regroup", type: "reconfigure_closing_groups",
        effective_at: instant("12:59:30"))
      recover
      close("unit-a", "early-close", "13:00:00")
      close("unit-b", "close-b", "13:00:00")
      close("unit-c", "close-c", "13:00:00")
      close("unit-a", "close-a", "13:03:00")
      bid("unit-a", "late-bid", "bidder-d", 7_000, "13:04:00")
      {
        "scope" => "synthetic_single_process_simulation",
        "specification_version" => RBBB::SPECIFICATION_VERSION,
        "trace" => @trace,
        "public_units" => public_units,
        "event_replay_matches" => replay_matches?,
        "limitations" => [
          "Units close independently; no linked closing-group capability is implemented.",
          "Post-bid shortening remains rejected under accepted RFC 0001.",
          "Recovery uses serialized in-memory events, not a database or crash-safe service.",
          "No concurrent transactions, authorization service, delivery, payments, or live auction are exercised."
        ]
      }
    end

    private

    def instant(time)
      "2030-01-01T#{time}Z"
    end

    def register(id, **extra)
      config = RBBB::Configuration.new(currency: "USD", opening_minor_units: 1_000,
        increments: [{from_minor_units: 0, amount_minor_units: 100}],
        opens_at: instant("12:00:00"), closes_at: instant("13:00:00"),
        extension: {trigger_window_seconds: 300, duration_seconds: 300}, **extra)
      @engines[id] = RBBB::Engine.new(config)
      @states[id] = @engines[id].initial_state
      @trace << {"operation" => "register_independent_unit", "unit_id" => id, "public_units" => public_units}
    end

    def bid(id, command_id, bidder_id, maximum, time)
      submit(id, command_id: command_id, type: "place_bid", bidder_id: bidder_id,
        maximum_minor_units: maximum, effective_at: instant(time))
    end

    def close(id, command_id, time)
      submit(id, command_id: command_id, type: "close_bidding", effective_at: instant(time))
    end

    def submit(id, command)
      decision = @engines.fetch(id).decide(@states.fetch(id), command)
      if decision.accepted?
        @states[id] = @engines.fetch(id).apply(@states.fetch(id), decision.events)
        @events[id] << decision.events
      end
      @trace << {"operation" => command.fetch(:type), "command_id" => command.fetch(:command_id),
        "unit_id" => id, "accepted" => decision.accepted?,
        "rejection_reason" => decision.rejection&.fetch("reason"), "public_units" => public_units}
    end

    def restored_states
      @engines.to_h do |id, engine|
        # Round-trip every record including visibility, without printing its payload.
        serialized = JSON.generate(@events[id].map do |batch|
          batch.map { |event| {"type" => event.type, "visibility" => event.visibility, "data" => event.data} }
        end)
        state = JSON.parse(serialized).reduce(engine.initial_state) do |current, batch|
          events = batch.map { |record| RBBB::Event.new(type: record.fetch("type"), visibility: record.fetch("visibility").to_sym, data: record.fetch("data")) }
          engine.apply(current, events)
        end
        [id, state]
      end
    end

    def replay_matches?
      restored_states.all? { |id, state| state.to_h == @states.fetch(id).to_h }
    end

    def recover
      raise "Event replay differs from running state" unless replay_matches?

      @states = restored_states
      @trace << {"operation" => "recover_from_serialized_events", "public_units" => public_units}
    end

    def public_units
      @states.to_h { |id, state| [id, state.public_view] }
    end
  end
end

puts JSON.pretty_generate(RBBBExamples::MultiUnitAuction.new.run) if $PROGRAM_NAME == __FILE__
