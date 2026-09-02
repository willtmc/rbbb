# Changelog

All notable changes will be documented here.

The project intends to follow Semantic Versioning once it begins publishing
versioned artifacts.

## Unreleased

- Bootstrap project governance, specification, conformance, and Ruby reference
  implementation structure.
- Implement the first pure-Ruby RFC 0001 slice: exact money, configurable
  increments, opening bids, proxy competition, equal-maximum priority, short
  increments, and challenger validation.
- Implement confidential reserve pressure, reserve-met status, and real-bidder
  priority when a maximum equals reserve.
- Implement authoritative closing-time eligibility and configurable soft-close
  resets for public bid changes.
- Implement private maximum reductions constrained by each bidder's immutable
  executed floor and authoritative command order.
- Implement audited pre-close operator bid voiding with immutable authorization
  history, deterministic state recomputation, and notification intent.
- Implement audited operator closing-time and reserve changes, including
  post-bid restrictions and preservation of previously executed reserve
  pressure.
- Implement explicit ordered closing with terminal `sold`, `no_sale`, and
  `no_bid` outcomes and post-close mutation rejection.
- Complete the experimental RFC 0001 configuration, command, rejection, event,
  public-state, and privileged aggregate-state schema contract.
- Package the Ruby reference engine as the pre-stable `0.1.0.pre.1` evaluation
  gem with compatibility metadata and isolated artifact verification.
- Harden RFC 0001 timing: an extension can no longer move closing time earlier
  when the configured duration is shorter than the remaining time; bids and
  reductions before opening time are rejected as `bidding_not_open`; commands
  whose authoritative time regresses are rejected as
  `effective_at_out_of_order` (aggregate state now records
  `last_effective_at`); zone-less timestamps are invalid instead of being read
  in host-local time. Conformance scenarios 027–029 cover these rules.
- `Engine#apply` raises when handed the events of more than one command, and
  malformed increment tiers raise `InvalidConfiguration` instead of a raw
  comparison error.
- Add a seeded differential test that checks structural invariants and
  incremental-versus-replay pricing agreement across random command streams.
- Declare `executed_floor_minor_units` as the finite, reason-specific rejection
  field for `maximum_below_executed_amount`, replace the engine's open-ended
  rejection details with that explicit field, and make document validation
  reject undeclared or unscoped rejection keys.
- `State#to_h` is now the full privileged aggregate snapshot matching
  `aggregate.schema.json` (positions, histories, voided bid IDs, and closing
  facts included; the derived `leader_maximum_minor_units` and
  `leader_executed_minor_units` keys are gone, so read the leader's position
  instead). `State.from_h` and `State.from_transition` / `Engine#restore`
  rebuild a validated state from a snapshot or from one state-transition
  event, so a host can checkpoint without replaying from version 0.
- Add `State#public_view`, the public query projection matching
  `bidding-unit.schema.json`; it can never carry an identity, a maximum, the
  reserve amount, or audit history.
- Emit the constant `status: "rejected"` from the pure engine so its rejection
  is the complete schema-valid document rather than one the service adapter
  must finish, and assert `status` in every conformance rejection.
- `Engine#apply` now builds the next state with `State.from_transition`, so it
  is guaranteed to equal `Engine#restore` of the same event. Consequence: in an
  untimed configuration, a command without `effective_at` now clears
  `last_effective_at` instead of silently carrying the previous value forward,
  which the transition event never recorded.
