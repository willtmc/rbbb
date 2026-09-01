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
