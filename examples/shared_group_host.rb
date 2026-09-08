# frozen_string_literal: true
require "rbbb"

module RBBBExamples
  # Process-local reference host; not durable storage or a public service API.
  class SharedGroupHost
    Receipt = Struct.new(:decision, :clock, :public_units, keyword_init: true)
    CloseReceipt = Struct.new(:decisions, :clock, :public_units, keyword_init: true)
    Snapshot = Struct.new(:states, :clock, :receipts, :event_batches, keyword_init: true)

    def initialize(configurations:, clock:)
      raise ArgumentError, "shared clock required" unless clock.is_a?(RBBB::SharedClosingClock)
      members = clock.public_view.fetch("unit_ids")
      unless configurations.is_a?(Hash) && configurations.keys.sort == members
        raise ArgumentError, "configurations must exactly match group members"
      end
      @engines = configurations.to_h do |id, config|
        unless config.is_a?(RBBB::Configuration) && config.extension.nil? && config.closes_at == clock.closes_at
          raise ArgumentError, "member configuration must use shared deadline without independent extension"
        end
        [id.dup.freeze, RBBB::Engine.new(config)]
      end.freeze
      raise ArgumentError, "initial clock required" unless clock.revision.zero? && clock.last_effective_at.nil?
      @mutex = Mutex.new
      @snapshot = Snapshot.new(states: @engines.transform_values(&:initial_state).freeze,
        clock: clock, receipts: {}.freeze, event_batches: [].freeze).freeze
    end

    # The host authenticates/authorizes callers and assigns authoritative time.
    # Exact retries return the original receipt even after the clock advances.
    def submit(unit_id:, command:, expected_revision:)
      request = normalize_request(unit_id, command, expected_revision)
      @mutex.synchronize do
        before = @snapshot
        id = request.fetch("command").fetch("command_id")
        if (saved = before.receipts[id])
          raise ArgumentError, "command ID reused for a different request" unless saved.first == request
          return saved.last
        end
        before.clock.deadline_for(unit_id)
        unless expected_revision.is_a?(Integer) && expected_revision == before.clock.revision
          raise RBBB::InvalidState, "stale clock revision"
        end
        engine = @engines.fetch(unit_id)
        state = synchronized_state(before.states.fetch(unit_id), before.clock)
        decision = engine.decide(state, request.fetch("command"))
        clock = before.clock.after_decision(unit_id: unit_id, decision: decision, expected_revision: expected_revision)
        states = before.states.merge(unit_id => engine.apply(state, decision.events)).freeze
        receipt = Receipt.new(decision: decision, clock: clock.public_view.transform_values { |v| v.freeze }.freeze,
          public_units: public_units(states, clock)).freeze
        receipts = before.receipts.merge(id => [request, receipt].freeze).freeze
        batches = before.event_batches
        if decision.accepted?
          # Original engine events and the resulting clock form one host record.
          batch = {"unit_id" => request.fetch("unit_id"), "events" => decision.events, "clock" => clock}.freeze
          batches = (batches + [batch]).freeze
        end
        publish(Snapshot.new(states: states, clock: clock, receipts: receipts, event_batches: batches).freeze)
        receipt
      end
    end

    # Compose existing close_bidding decisions; publish only when all succeed.
    def close_group(command_id:, effective_at:, expected_revision:)
      request = normalize_close_request(command_id, effective_at, expected_revision)
      @mutex.synchronize do
        before = @snapshot
        if (saved = before.receipts[command_id])
          raise ArgumentError, "command ID reused for a different request" unless saved.first == request
          return saved.last
        end
        unless expected_revision == before.clock.revision
          raise RBBB::InvalidState, "stale clock revision"
        end
        unless before.clock.due?(at: request.fetch("command").fetch("effective_at"))
          raise RBBB::InvalidState, "shared closing time not reached"
        end
        states = before.states.dup
        decisions = {}
        batches = before.event_batches.dup
        @engines.keys.sort.each do |id|
          engine = @engines.fetch(id)
          state = synchronized_state(states.fetch(id), before.clock)
          decision = engine.decide(state, request.fetch("command"))
          raise RBBB::InvalidState, "member close refused: #{decision.rejection.fetch('reason')}" if decision.rejected?
          states[id] = engine.apply(state, decision.events)
          decisions[id] = decision
          batches << {"unit_id" => id, "events" => decision.events, "clock" => before.clock}.freeze
        end
        receipt = CloseReceipt.new(decisions: decisions.freeze,
          clock: before.clock.public_view.transform_values { |v| v.freeze }.freeze,
          public_units: public_units(states, before.clock)).freeze
        receipts = before.receipts.merge(request.fetch("command").fetch("command_id") => [request, receipt].freeze).freeze
        publish(Snapshot.new(states: states.freeze, clock: before.clock,
          receipts: receipts, event_batches: batches.freeze).freeze)
        receipt
      end
    end

    def public_view
      @mutex.synchronize { public_units(@snapshot.states, @snapshot.clock) }
    end

    private

    # A durable adapter needs a database transaction, group-wide lock/CAS,
    # and atomic receipt/event outbox writes in place of this publication.
    def publish(candidate)
      @snapshot = candidate
    end

    def synchronized_state(state, clock)
      RBBB::State.from_h(state.to_h.merge("closes_at" => RBBB::Timestamp.dump(clock.closes_at)))
    end

    def public_units(states, clock)
      states.to_h do |id, state|
        [id, synchronized_state(state, clock).public_view.transform_values { |v| v.freeze }.freeze]
      end.freeze
    end

    def normalize_close_request(command_id, effective_at, revision)
      unless command_id.is_a?(String) && !command_id.empty? && revision.is_a?(Integer)
        raise ArgumentError, "invalid close request"
      end
      time = RBBB::Timestamp.dump(RBBB::Timestamp.parse(effective_at)).freeze
      {"operation" => "close_group", "expected_revision" => revision,
        "command" => {"command_id" => command_id.dup.freeze,
          "type" => "close_bidding", "effective_at" => time}.freeze}.freeze
    end

    def normalize_request(unit_id, command, revision)
      unless unit_id.is_a?(String) && revision.is_a?(Integer) && command.is_a?(Hash) &&
          command.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
        raise ArgumentError, "invalid request"
      end
      values = command.transform_keys(&:to_s)
      unless values.size == command.size && values.values.all? { |v| v.nil? || v.is_a?(String) || v.is_a?(Integer) } &&
          %w[place_bid reduce_maximum].include?(values["type"]) &&
          values["command_id"].is_a?(String) && !values["command_id"].empty?
        raise ArgumentError, "only scalar bid/maximum commands with a command ID are supported"
      end
      copied = values.to_h { |k, v| [k.dup.freeze, v.is_a?(String) ? v.dup.freeze : v] }.freeze
      {"unit_id" => unit_id.dup.freeze, "command" => copied, "expected_revision" => revision}.freeze
    end
  end
end
