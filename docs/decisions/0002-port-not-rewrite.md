---
title: This is a port, not a rewrite
status: accepted
date: 2026-11-12
---

## Context

The projects that changed language quickly and kept their behaviour (the Go compiler from C to Go,
TypeScript to Go, Ladybird's LibJS to Rust, Bun to Rust) all translated the program they had: same
files, same functions, same data structures, same order of operations. The ones that redesigned
on the way (Roc, by choice) took years and say so. See the post
[What other rewrites teach us](../devlog/learning-from-rewrites/).

## Decision

The Nim code mirrors the Rust code of the pinned Gleam snapshot.

- One Rust file, one Nim file, at the matching path, with the same name. Types, functions and
  fields keep their names, changed only to Nim's case (`parse_statement` is `parseStatement`).
- Same control flow and the same order of side effects, so that a difference in output points to
  a line.
- Nim that reads like translated Rust is expected in this phase and is not a defect. Making it
  idiomatic is a later, separate change, done file by file once that file is `conformant`, with
  the tests as the safety net.
- Where Nim cannot say what Rust says (ownership, traits, pattern matching on enums), the
  [porting guide](../porting/) has one agreed translation, and everyone uses it.

## Consequences

- A reviewer can put the two files side by side. So can a second agent, which is how we verify.
- We inherit upstream's architecture, including what we might have done differently. That is the
  price, and it is cheap.
- Improvements, new features and clever Nim are out of scope until the port is complete. Ideas go
  to the backlog.
