---
title: Everything needed to resume is in the repository
status: accepted
date: 2026-11-12
---

## Context

Sessions end without warning: a token budget runs out, a container is reclaimed. The next session
knows nothing. The agent-built C compiler handled this with progress files that every agent had to
keep current; Bun's port kept a guide, a scoreboard and one script per phase in the repository.

## Decision

A fresh session must be able to continue from a clone of the repository alone.

- **What to do next** is the roadmap (`docs/data/roadmap.json`, the Roadmap page).
- **Where the port stands** is computed, not written: `tools/portmap.nim` reads the headers of
  the Nim files, and the tests say what passes.
- **How to do it** is `AGENTS.md`, the porting guide and these records.
- **What happened and why** is the devlog, one dated post per step.
- Project memory outside the repository holds only pointers to these and the few facts that
  cannot be public.

A step is not finished until its pull request has updated whichever of these it changed.

## Consequences

- Work in progress is pushed to its branch often; a draft pull request is a save point.
- A session's first command is `sh tools/setup.sh`, then the port map and the roadmap.
