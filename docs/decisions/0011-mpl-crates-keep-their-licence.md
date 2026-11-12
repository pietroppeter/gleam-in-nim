---
title: A port of an MPL-2.0 crate keeps the MPL-2.0, file by file
status: accepted
date: 2026-11-12
---

## Context

The repository is Apache-2.0, like Gleam ([decision 0007](#0007-ported-files-name-their-origin-and-the-port-is-apache-2-0)).
The compiler also needs code that Gleam does not contain but depends on: Rust crates, which the
porting guide says to replace with "a small module of ours that is itself a port".

Dependency resolution is the first place where such a crate is not under a permissive licence.
Gleam resolves versions with [pubgrub](https://github.com/pubgrub-rs/pubgrub) 0.3.0, and a
version requirement such as `>= 1.0.0 and < 2.0.0` *is* a value of that crate's
`version-ranges` 0.1.3. Both are under the Mozilla Public License 2.0. The MPL is a copyleft
licence per file: a file that derives from an MPL file stays MPL, and may be shipped inside a
larger work under other terms. A translation into Nim derives from the file it translates.

The options were: translate the crate and keep its licence on the translated files; write a
set of ranges of our own from the documentation alone; or stop at the parser and leave the
resolver out. The second gives up the reference for the one part where output must match byte for
byte (the text of a range is printed in `manifest.toml` and in error messages), and the third
gives up `gleam deps` and `gleam add`.

## Decision

- A crate under the MPL-2.0 may be ported. Each Nim file that translates one of its files is
  itself under the MPL-2.0: it starts with `SPDX-License-Identifier: MPL-2.0`, the notice the
  licence asks for, and the crate, version and file it comes from.
- Such a file holds nothing else. Code of ours and code ported from Gleam does not go into it,
  and code from it is not copied into Apache-2.0 files: the boundary between the two licences
  is the boundary of the file.
- The text of the licence is in `LICENSES/MPL-2.0.txt`, and `NOTICE` lists the files.
- Today that is one file, `src/gleam_in_nim/version_ranges.nim`. The solver of pubgrub will
  follow the same rule when the resolver is ported.
- Crates under licences that do not allow this (or that are unclear) are still not copied.

## Consequences

- The repository is "Apache-2.0, except the files that say MPL-2.0". Whoever reuses the
  compiler as a whole can do so under both licences' terms, which are compatible in this
  direction; whoever changes an MPL file publishes that file's changes under the MPL.
- Pietro can reverse this cheaply: the MPL files are few, small and behind a narrow interface
  (ranges of versions; later, a solver), so they can be replaced by code written from scratch
  without touching the rest.
- A reader checking licences has one command: search for `SPDX-License-Identifier`.
