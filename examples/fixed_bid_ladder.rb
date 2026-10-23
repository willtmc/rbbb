# frozen_string_literal: true

# Run: ruby -I ruby/engine/lib examples/fixed_bid_ladder.rb
require "rbbb"
configuration = RBBB::Configuration.new(currency: "USD", opening_minor_units: 1000,
  increments: [{from_minor_units: 0, amount_minor_units: 1000},
    {from_minor_units: 25000, amount_minor_units: 2500}],
  opens_at: "2032-01-01T12:00:00Z", closes_at: "2032-01-01T13:00:00Z")
engine = RBBB::Engine.new(configuration)
decision = engine.decide(engine.initial_state,
  {type: "place_bid", command_id: "synthetic-odd", bidder_id: "synthetic-bidder",
   maximum_minor_units: 24900, effective_at: "2032-01-01T12:30:00Z"})
abort(decision.rejection.inspect) if decision.rejected?
# The bid has already been accepted. Display privately; do not ask again or round up.
puts decision.bidder_notice.fetch("message")
