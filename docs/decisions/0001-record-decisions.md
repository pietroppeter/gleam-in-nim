---
title: Record decisions as short dated notes
status: accepted
date: 2026-11-12
---

## Context

This port is built by many short sessions, most of them by coding agents that start with an empty
memory, and reviewed by one person on a phone. A choice that lives only in a chat is lost at the
next session, and then made again, differently.

## Decision

Every choice that a later session could reasonably make another way gets a decision record: one
Markdown file in `docs/decisions/`, named `NNNN-slug.md`, with a title, a status (`proposed`,
`accepted`, `superseded by NNNN`) and a date, then three short sections: Context, Decision,
Consequences. The page [Decisions](../decisions/) lists them all.

A record is not edited once accepted, except for typos and links. To change a decision, write a
new record and mark the old one superseded.

## Consequences

- A session that is about to choose something reads the list first; it is short on purpose.
- The explainers (the devlog) tell the story; the records hold the rule. A post may link a
  record, never the other way round for the reasoning.
- Records are cheap. If writing one takes more than ten minutes, the choice is not ready.
