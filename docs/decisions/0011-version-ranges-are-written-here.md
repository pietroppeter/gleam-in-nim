---
title: Version ranges are written here, not ported from version-ranges
status: accepted
date: 2026-11-12
---

## Context

Hex version requirements (`~> 1.2 and < 1.5.0`) are parsed by Gleam's own `hexpm` crate into a
`pubgrub::Range<Version>`: a set of versions kept as a sorted list of intervals. That type is
not Gleam's. It comes from the crate `version-ranges`, part of the `pubgrub` project, and both
are under the Mozilla Public License 2.0. This repository is Apache-2.0 and its rule is to never
copy from a source whose licence does not allow it; a translation of an MPL file would be a
file under the MPL. The same will be true, on a larger scale, of the `pubgrub` solver that
Gleam uses to resolve dependencies.

## Decision

`src/gleam_in_nim/version_ranges.nim` is written here, from what the crate documents and from
how it behaves, not from its source. It has no `port-of` header. It is held to the crate's
behaviour from outside: the Rust half of `tests/differential/hexpm_version` links the real
crate and prints its answers, and the Nim must print the same, including the corner where two
versions are equal in order and different in value (build metadata).

It holds only what the port uses, and grows the same way when a later file needs more.

## Consequences

- No MPL code in the repository, and one licence for everything in `src/`.
- The module is not covered by "the Rust is the specification" through reading: only through
  the differential test. A behaviour the test does not exercise is not known to match.
- The dependency solver is an open question for the step that reaches it (roadmap phase 5):
  write a PubGrub solver here from the published algorithm, or decide otherwise in a new
  record. Until then nothing in this repository resolves versions.
