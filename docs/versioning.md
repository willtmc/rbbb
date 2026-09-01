# Versioning and compatibility

RBBB versions three related artifacts independently:

1. the language-neutral specification;
2. the conformance suite; and
3. each implementation or client package.

An implementation compatibility claim names all three relevant versions. A gem
version alone does not identify the auction rules it implements.

Ruby evaluation packages use prerelease versions such as `0.1.0.pre.1`. They
expose `RBBB::SPECIFICATION_VERSION` and `RBBB::RELEASE_STATUS`, and repeat
those values in gem metadata. Prerelease packages may change incompatibly and
must not be treated as production-ready merely because they can be installed.

Before specification 1.0, incompatible changes may occur between minor
versions and will be called out in the changelog. After 1.0, the specification
and public contracts follow Semantic Versioning:

- patch: clarification or correction that does not change conforming outcomes;
- minor: backward-compatible capability or optional rule vocabulary; and
- major: incompatible command, event, state, configuration, or outcome change.

A bug fix that changes an auction outcome is not automatically a patch. The
governing RFC must explain whether the earlier outcome was outside the existing
specification or whether a compatibility break is necessary.
