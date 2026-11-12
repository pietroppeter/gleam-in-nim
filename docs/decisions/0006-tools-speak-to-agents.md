---
title: Tools and tests are written for a reader with a small context
status: accepted
date: 2026-11-12
---

## Context

Most runs of our tools are read by a coding agent. Pages of passing tests push the useful line
out of its context, and a test suite that takes minutes makes it run tests instead of working.
The author of the agent-built C compiler lists this first among what he learned: design the
harness for the model.

## Decision

Every tool and test runner in this repository follows the same rules.

- A passing run prints a few lines. Nothing per passing case.
- A problem is one line that starts with `ERROR` and holds the reason on that same line, so that
  `grep ERROR` is the whole story. Details go to a file under `build/`, and the line says where.
- The last line is a summary with numbers.
- Anything slow has `--fast:N`, a deterministic sample of N percent, with `--seed` to get another
  sample. The full run is for the end of a step and for CI.
- Tools write their results as JSON in `docs/data/`, and the pages read that. Numbers are never
  typed by hand into a page.
- A tool has a self test that proves it can fail.

## Consequences

- An agent can run the differential harness dozens of times in a session without drowning.
- People get the same benefit: the output fits on a phone.
