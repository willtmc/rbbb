# Examples

Examples are informative unless they are also represented in the conformance suite.
Use synthetic inputs only; never copy production data or vendor payloads.

## Multi-unit auction walkthrough

Run from the repository root:

```sh
ruby examples/multi_unit_auction.rb
```

This deterministic, single-process simulation uses the accepted RFC 0001 engine.
It interleaves bids on two independent units, registers a third after bidding
starts, extends only the unit receiving a late bid, restores state from
JSON-serialized command event batches, and closes with sold, no-sale, and no-bid
outcomes. Output contains public projections and bounded rejection reasons;
privileged event payloads remain inside the process.

The premature close and post-close bid are rejected. The post-bid deadline
shortening request is rejected by current policy, and regrouping is unsupported.
These are explicit capability boundaries, not a workaround for linked groups.
No engine semantics are changed by this example.

The example is **not** a database-backed host, concurrent transaction test,
authorization service, notification delivery test, or production-readiness claim.
Recovering serialized events preserves each accepted command's event batch;
flattening multiple commands into one `apply` call is invalid.

## Scheduling decision needed

The [flexible live scheduling proposal](https://github.com/willtmc/rbbb/pull/34)
would add group coordination and separately authorized shortening to a strictly
future deadline, while preserving accepted bids and private proxy positions.
The present engine cannot satisfy those requirements. RFC acceptance is separate
from implementing its coordinator and passing transaction/race/crash tests.
The simulation above establishes a baseline for that later work; it does not
execute the proposal's scheduling vectors or claim group support.
