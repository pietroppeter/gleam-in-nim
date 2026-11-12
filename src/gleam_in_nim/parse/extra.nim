## port-of: compiler-core/src/parse/extra.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/extra.rs.

## What the parser finds in a module that is not part of the tree: comments,
## empty lines, line ends, trailing commas. The formatter needs them to print
## the module back.

import std/options
import ../src_span

type
  ModuleExtra* = object
    moduleComments*: seq[SrcSpan]
    docComments*: seq[SrcSpan]
    comments*: seq[SrcSpan]
    emptyLines*: seq[int]
    newLines*: seq[int]
    trailingCommas*: seq[int]

  Comment* = object
    start*: int
    content*: string

func initModuleExtra*(): ModuleExtra =
  ModuleExtra()

func binarySearchBy(spans: seq[SrcSpan], cmp: proc(span: SrcSpan): int {.noSideEffect.}): Option[int] =
  ## Rust's `binary_search_by`, `.ok()`: the index of an element for which
  ## `cmp` is 0, if there is one. `cmp` says where the element stands relative
  ## to what is searched: below (-1), above (1) or on it (0).
  var
    low = 0
    high = spans.len
  while low < high:
    let
      mid = low + (high - low) div 2
      order = cmp(spans[mid])
    if order == 0:
      return some(mid)
    elif order < 0:
      low = mid + 1
    else:
      high = mid
  none(int)

func isWithinComment*(extra: ModuleExtra, byteIndex: int): bool =
  ## Detects if a byte index is in a comment context
  let cmp = proc(span: SrcSpan): int {.noSideEffect.} =
    if byteIndex < span.start: 1
    elif byteIndex > span.stop: -1
    else: 0
  extra.comments.binarySearchBy(cmp).isSome or
    extra.docComments.binarySearchBy(cmp).isSome or
    extra.moduleComments.binarySearchBy(cmp).isSome

func indexOfFirstCommentBetween(extra: ModuleExtra, start, stop: int): Option[int] =
  extra.comments.binarySearchBy(proc(comment: SrcSpan): int {.noSideEffect.} =
    if comment.stop < start: -1
    elif comment.start > stop: 1
    else: 0)

func firstCommentBetween*(extra: ModuleExtra, start, stop: int): Option[SrcSpan] =
  ## Returns the first comment overlapping the given source locations (inclusive)
  ## Note that the returned span covers the text of the comment, not the `//`
  # Index of a comment, but not necessarily the first one.
  let index = extra.indexOfFirstCommentBetween(start, stop)
  if index.isNone:
    return none(SrcSpan)
  var i = index.get
  # Walk back while the comment overlaps the span (inclusive of endpoints).
  while i > 0 and extra.comments[i - 1].stop >= start and extra.comments[i - 1].start <= stop:
    dec i
  some(extra.comments[i])

func hasCommentBetween*(extra: ModuleExtra, start, stop: int): bool =
  extra.firstCommentBetween(start, stop).isSome

func lastCommentBetween*(extra: ModuleExtra, start, stop: int): Option[SrcSpan] =
  # We start from the first comment that we can find in between the given
  # start and end, this is really fast as we can find such index through
  # binary search.
  let index = extra.indexOfFirstCommentBetween(start, stop)
  if index.isNone:
    return none(SrcSpan)
  var indexOfLastComment = index.get
  # Then we go over all the comments we can find from that one that are
  # still in between the given indices.
  while indexOfLastComment + 1 < extra.comments.len and
      start <= extra.comments[indexOfLastComment + 1].start and
      extra.comments[indexOfLastComment + 1].stop <= stop:
    inc indexOfLastComment
  some(extra.comments[indexOfLastComment])

func initComment*(span: SrcSpan, src: string): Comment =
  ## Upstream `impl From<(&SrcSpan, &str)> for Comment`.
  Comment(start: span.start, content: src[span.start ..< span.stop])
