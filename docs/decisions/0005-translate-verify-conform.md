---
title: Every file goes through translate, verify, conform
status: accepted
date: 2026-11-12
---

## Context

A translation that compiles is not a translation that is right. Bun's port ran each file through
three roles (one writes, one hunts for deviations from the source and the guide, one fixes) and
then through the test suite; the regressions that still escaped were places where the two
languages look alike and mean different things.

## Decision

Each Rust file moves through three states, written in the header of its Nim file
(`## port-status:`) and shown on the port map:

1. **draft**: translated following the porting guide. It may not compile alone yet.
2. **verified**: a second pass, with fresh context and no memory of the first, has read the Nim
   against the Rust, function by function, looking only for differences in behaviour, and its
   findings are fixed. The second pass is asked to find problems, not to approve.
3. **conformant**: the upstream tests of that file (snapshots and harvested cases) pass on the
   Nim code, and the differential harness agrees wherever the stage can be reached from the
   command line.

The tests of a file are ported with the file. A step of the port is a pull request that moves
some files forward, with its explainer.

## Consequences

- The port map always says how much is translated, how much is checked, and how much is proven.
- A file can be `draft` for a while when its tests need a later stage (the parser needs the
  formatter to be compared from the command line). That is visible, not hidden.
- Traps found in verification are added to the porting guide, so the next translation avoids
  them.
