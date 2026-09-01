# R Triple B

**A deterministic, auditable auction bidding engine.**

> [!WARNING]
> RBBB is in its initial design phase. It is not production ready and must not
> be used to accept or resolve live bids.

R Triple B is an open-source project for specifying and implementing auction
bidding behavior. The project separates the behavior of the standard from the
language used by any one implementation:

1. a language-neutral specification;
2. a language-neutral conformance suite; and
3. a production-quality Ruby reference implementation.

The first milestone is deliberately narrow: deterministic, timed online proxy
bidding with a complete audit trail. Future auction formats will be proposed
through RFCs rather than added as customer-specific hooks.

## Why this project exists

Auction behavior is full of deceptively important edge cases. When two systems
receive the same ordered commands under the same configuration, they should
reach the same result and explain why. RBBB aims to make those rules explicit,
portable, testable, and open to domain experts—not merely buried in one
application's code.

## Project shape

```text
specification/   Language-neutral concepts, schemas, and API contracts
conformance/     Portable behavior scenarios for every compliant engine
ruby/engine/     Pure-Ruby reference implementation
ruby/server/     Future deployable reference service
rfcs/            Proposed changes to normative auction behavior
docs/            Architecture, terminology, and design decisions
```

The reference implementation will expose a pure decision boundary:

```ruby
events = engine.decide(current_state, command)
new_state = engine.apply(current_state, events)
```

Rails, PostgreSQL, HTTP, and real-time delivery may surround that core, but
framework and persistence concerns do not belong inside the auction rules.

## Current status

The repository is being bootstrapped. Its current documents describe project
boundaries and contribution mechanics, not finalized auction semantics.
Anything marked `draft` may change before the first stable release.

See [ROADMAP.md](ROADMAP.md), [docs/architecture.md](docs/architecture.md), and
[specification/README.md](specification/README.md) for the planned path.

## Contributing

Auctioneers, software operators, designers, security researchers, and
developers are all invited to contribute. A real-world edge case expressed as
a provenance-safe conformance scenario can be as valuable as code.

Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md). Normative rule
changes use the [RFC process](rfcs/README.md). Security issues should be
reported privately as described in [SECURITY.md](SECURITY.md).
General support expectations are in [SUPPORT.md](SUPPORT.md).

## License

RBBB is available under the [MIT License](LICENSE). The specification,
conformance materials, reference implementation, examples, and associated
documentation in this repository use the same license unless a file says
otherwise.
