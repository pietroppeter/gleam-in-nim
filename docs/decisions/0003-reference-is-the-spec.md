---
title: The pinned compiler and its tests are the specification
status: accepted
date: 2026-11-12
---

## Context

Other projects of Pietro's (tabelline, for one) write the behaviour down first, as requirements
with examples, and build from that. It works well when the thing does not exist yet. Here it
exists: the Gleam compiler at the pin, about 105,000 lines of Rust with about 87,000 lines of
tests, 4,377 snapshot files and 7,078 `assert_*!` test calls. Writing a second description of the
same behaviour would be slower than the port and would be wrong in places.

## Decision

- The specification is the reference compiler at the pinned version, the tests in its repository,
  and what its binary does. When they disagree with anything we wrote, they win.
- We do not keep a separate behaviour specification (no OpenSpec, no requirement documents).
- Upstream tests are replayed, not retyped: `tools/snapshots.nim` reads the snapshot files and
  `tools/harvest.nim` reads the test macros out of the Rust sources.
- Every place where the Nim port knowingly behaves differently from the reference is one entry in
  `docs/divergences.md`, with the reason. Nothing else is allowed to differ.

## Consequences

- "Is this right?" always has an answer that does not need a person: run the reference.
- The pin does not move during the port. Following upstream is a later project, with its own
  decision.
- Specifications still have a place for what upstream does not define: our tools, our pages and
  our process. Those are specified by their own tests and by these records.
