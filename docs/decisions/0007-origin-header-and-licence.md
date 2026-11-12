---
title: Ported files name their origin, and the port is Apache-2.0
status: proposed
date: 2026-11-12
---

## Context

Gleam is licensed under Apache-2.0. A translation of its source into Nim is a derivative work,
and the licence asks four things of whoever distributes one: give a copy of the licence, say that
the files were changed, keep the copyright and attribution notices, and carry the NOTICE file if
there is one. The repository was created with an MIT licence, which is fine for what we write
ourselves but cannot replace Apache-2.0 on what we translate.

## Decision

- Every Nim file that ports upstream code starts by naming the file it ports, relative to the
  Gleam repository at the pin, and its state:

  ```nim
  ## port-of: compiler-core/src/parse/lexer.rs
  ## port-status: draft
  ```

  The same two lines feed the port map, so the legal notice and the progress bar cannot drift
  apart.
- The repository carries the Apache-2.0 text and a `NOTICE` that credits the Gleam authors and
  says the Nim files are translations of Gleam at the pinned version.
- Proposed, for Pietro to confirm: license the whole repository under Apache-2.0, like upstream,
  instead of keeping two licences side by side.

## Consequences

- One licence, the same as Gleam, keeps the question "may I copy this?" trivial in both
  directions.
- If Pietro prefers to keep MIT for the original parts (tools, pages), the header already tells
  the two kinds of files apart, and only the wording of `NOTICE` changes.
