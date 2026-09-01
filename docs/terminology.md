# Terminology

This glossary is draft and will evolve through RFC review.

**Aggregate version**
: A monotonically increasing number identifying the exact bidding-unit state
  against which a command is evaluated.

**Auction**
: A host-defined event containing one or more bidding units and shared policy
  configuration.

**Bidder authorization**
: A host-platform decision permitting a bidder to issue specified commands,
  possibly under explicit constraints.

**Bidding unit**
: The smallest set of lots whose bid state must be ordered and decided
  together. Initially this is normally one lot.

**Command**
: A request to change engine state. Commands may be accepted or rejected and
  must be idempotent under a stable command identifier.

**Configuration**
: A versioned selection of specified auction rules. Configuration chooses among
  defined behavior; it does not introduce arbitrary code.

**Conformance scenario**
: A language-neutral sequence of configuration, state, commands, and expected
  observable outcomes used to test an implementation.

**Event**
: An immutable fact emitted by an accepted state transition. Applying an
  ordered event stream rebuilds state.

**Maximum bid**
: A private bidder instruction limiting how far an automatic bidding rule may
  act. A maximum is not necessarily the publicly standing amount.

**Normative**
: Required for compatibility with a specification version.

**Projection**
: Query-friendly state derived from committed events.

**Standing amount**
: The currently observable amount established by accepted bidding rules.

Terms such as “current bid,” “winning bid,” “high bid,” and “proxy bid” can be
ambiguous and should not be used normatively without a definition.
