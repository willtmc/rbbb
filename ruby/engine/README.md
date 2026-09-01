# RBBB Ruby reference engine

This directory will contain the pure-Ruby reference implementation of the RBBB
specification.

> [!WARNING]
> The gem is an early RFC 0001 implementation. It is not production ready and
> must not be used in a live auction.

The engine will remain independent of Rails, databases, HTTP, jobs, and
authentication. Its public decision boundary is:

```ruby
decision = engine.decide(current_state, command)
new_state = engine.apply(current_state, decision.events)
```

The current implementation covers exact minor-unit money, configurable
increment tiers, opening bids, proxy competition, earlier-equal priority,
proxy clipping, challenger minimums, private leader maximum increases, and
confidential reserve pricing and status. It also enforces authoritative closing
times, configurable per-unit soft-close extensions, and bidder withdrawal of
unexecuted proxy authority. Authorized operator bid voiding preserves the
original bid, deterministically recomputes standing and executed amounts, and
emits host-facing notification intent. Audited operator commands may also
change closing time and reserve under the RFC's pre-bid and post-bid
constraints without unwinding already executed amounts. Explicit ordered
closing produces `sold`, `no_sale`, or `no_bid` terminal state. Persistence,
networking, service-level idempotency, and authentication are not implemented.

The pure engine records `operator_id`; it does not authenticate or authorize
that identity. A host must authorize the operator before submitting any
operator command and must deliver or retry any requested notifications.

```ruby
configuration = RBBB::Configuration.new(
  currency: "USD",
  opening_minor_units: 10_000,
  increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
  opens_at: "2026-09-01T12:00:00Z",
  closes_at: "2026-09-01T13:00:00Z",
  extension: {trigger_window_seconds: 300, duration_seconds: 300}
)
engine = RBBB::Engine.new(configuration)
state = engine.initial_state

decision = engine.decide(state, {
  command_id: "command-1",
  type: "place_bid",
  bidder_id: "bidder-a",
  maximum_minor_units: 50_000,
  effective_at: "2026-09-01T12:10:00Z"
})
state = engine.apply(state, decision.events) if decision.accepted?
```

## Development

```sh
bundle install
bundle exec rake
```
