---
title: The compiler depends on one package, bigints
status: accepted
date: 2026-11-12
---

## Context

The porting guide says `src/` uses only the standard library, and that a new dependency needs a
decision record. The lexer is the first file to need big integers: a Gleam integer literal can
be of any size, and the `Int` token carries its value (`num_bigint::BigInt` upstream). Later
stages need them again, for constant folding, bit arrays and pattern matching on integers. Nim's
standard library has no big integers.

The two options were a small module of our own, or `nim-lang/bigints`: pure Nim, MIT, kept under
the Nim organisation, with tests of its own.

## Decision

- `src/` may import `pkg/bigints`. It is pinned by commit in `deps.lock` like the dependencies
  of the pages, and cloned by `tools/setup.sh`.
- It is the only package `src/` may import. The rule for everything else stands.
- Float literals do not use `parseFloat` from the standard library, which is wrong for very long
  exponents and mantissas. `parse/literals.nim` has `parseLiteralFloat`, exact, built on the
  fast path for short literals and on big integers for the rest.

## Consequences

- Arithmetic on literals is somebody else's tested code, and what it must agree with is
  num-bigint: the lexer's check compares values with the Rust lexer on random literals.
- A fresh checkout needs `sh tools/setup.sh` before the tests, which was already true for the
  pages.
- If the package ever becomes a problem (speed, a bug, an abandoned repository), the surface used
  is small (parse in a radix, negate, compare, print, multiply, shift, divide) and a module of
  ours can replace it behind the same names.
