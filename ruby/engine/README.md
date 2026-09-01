# RBBB Ruby reference engine

This directory will contain the pure-Ruby reference implementation of the RBBB
specification.

> [!WARNING]
> The gem implements only an early subset of RFC 0001. It is not production
> ready and must not be used in a live auction.

The engine will remain independent of Rails, databases, HTTP, jobs, and
authentication. Its public decision boundary is:

```ruby
decision = engine.decide(current_state, command)
new_state = engine.apply(current_state, decision.events)
```

The current implementation covers exact minor-unit money, configurable
increment tiers, opening bids, proxy competition, earlier-equal priority,
proxy clipping, challenger minimums, and private leader maximum increases. It
fails closed when reserve behavior is configured. Extensions, reductions,
operator commands, closing, persistence, and networking are not implemented.

```ruby
configuration = RBBB::Configuration.new(
  currency: "USD",
  opening_minor_units: 10_000,
  increments: [{from_minor_units: 0, amount_minor_units: 1_000}]
)
engine = RBBB::Engine.new(configuration)
state = engine.initial_state

decision = engine.decide(state, {
  command_id: "command-1",
  type: "place_bid",
  bidder_id: "bidder-a",
  maximum_minor_units: 50_000
})
state = engine.apply(state, decision.events) if decision.accepted?
```

## Development

```sh
bundle install
bundle exec rake
```
