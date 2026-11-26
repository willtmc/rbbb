# frozen_string_literal: true

# Synthetic diagnostic only; no timing threshold is an engine contract.
require "json"
require_relative "../lib/rbbb"

engine = RBBB::Engine.new(RBBB::Configuration.new(
  currency: "USD", opening_minor_units: 100,
  increments: [{from_minor_units: 0, amount_minor_units: 100}],
  opens_at: "2026-01-01T00:00:00Z", closes_at: "2026-01-02T00:00:00Z"
))
state = engine.initial_state
1_000.times do |index|
  decision = engine.decide(state, {
    command_id: "synthetic-#{index}", type: "place_bid",
    bid_id: "synthetic-#{index}", bidder_id: "synthetic-bidder",
    maximum_minor_units: 100 * (index + 1), effective_at: "2026-01-01T12:00:00Z"
  })
  raise "synthetic setup rejected" if decision.rejected?

  state = engine.apply(state, decision.events)
end
snapshot = state.to_h
command = {
  command_id: "synthetic-next", type: "place_bid", bid_id: "synthetic-next",
  bidder_id: "synthetic-bidder", maximum_minor_units: 100_100,
  effective_at: "2026-01-01T12:00:01Z"
}
measurements = {}
{
  restore: -> { RBBB::State.from_h(snapshot) },
  decide_and_apply: -> { engine.apply(state, engine.decide(state, command).events) }
}.each do |name, operation|
  10.times { operation.call }
  measurements[name] = 3.times.map do
    GC.start
    allocated_before = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    300.times { operation.call }
    {
      seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
      allocated_objects: GC.stat(:total_allocated_objects) - allocated_before
    }
  end
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, history_entries: 1_000,
  iterations_per_measurement: 300, measurements: measurements)
