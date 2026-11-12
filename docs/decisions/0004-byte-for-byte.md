---
title: Outputs are compared byte for byte with the reference
status: accepted
date: 2026-11-12
---

## Context

"Looks the same" and "passes our tests" are weak: tests written by the same hand as the code share
its blind spots. Ladybird asked for identical bytecode from its two pipelines and got a port with
zero regressions; the C compiler built by parallel agents only became debuggable at scale when GCC
was used as an oracle. We have the same luxury: a released `gleam` binary for the pin.

## Decision

A stage of the port is done when its output is identical, byte for byte, to the reference on the
upstream inputs: formatted source, generated Erlang, generated JavaScript, and the text of errors
and warnings, exit codes included.

- `tools/difftest.nim` runs the reference and the candidate on the same inputs and compares
  everything they write. The candidate takes the same command line as `gleam`.
- No fuzzy matching, no normalising of whitespace. The only files not compared are the private
  caches of an implementation.
- Where identical output is impossible or pointless, the difference is recorded as a divergence
  (decision 0003) and the comparison excludes exactly that.

## Consequences

- The Nim code must reproduce details that look arbitrary, such as the order of generated
  variables and the wrapping of long lines. The porting guide says to keep the Rust iteration
  order for that reason.
- Any difference is a bug with a small reproduction, found by a machine.
- The harness is part of the product: it has a self test, and a change to it is reviewed like
  compiler code.
