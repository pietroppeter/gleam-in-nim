## port-of: src-span/src/lib.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), src-span/src/lib.rs.

## A span of source code, as a pair of byte offsets.
##
## Only `SrcSpan` is ported so far: `LineNumbers` comes when something needs it.
##
## Naming: upstream calls the fields `start` and `end`. `end` is a Nim keyword,
## so here it is `stop`.

type SrcSpan* = object
  start*: int
  stop*: int

func initSrcSpan*(start, stop: int): SrcSpan =
  SrcSpan(start: start, stop: stop)

func contains*(span: SrcSpan, byteIndex: int): bool =
  byteIndex >= span.start and byteIndex <= span.stop

func containsSpan*(span, other: SrcSpan): bool =
  span.contains(other.start) and span.contains(other.stop)

func merge*(span, other: SrcSpan): SrcSpan =
  ## The span that starts at the start of the smaller one and ends at the end
  ## of the bigger one.
  SrcSpan(start: min(span.start, other.start), stop: max(span.stop, other.stop))

func len*(span: SrcSpan): int =
  span.stop - span.start

func isEmpty*(span: SrcSpan): bool =
  span.len == 0
