## port-of: compiler-core/src/parse/extra.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/extra.rs.

## What the parser keeps beside the tree: where the comments, the empty lines
## and the trailing commas are. The formatter puts them back.

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
  ## Upstream `ModuleExtra::new`.
  ModuleExtra()

func binarySearchBy*(spans: seq[SrcSpan], cmp: proc(span: SrcSpan): int {.noSideEffect.}
): Option[int] =
  ## Rust's `binary_search_by`, when it finds: the index of an element for
  ## which `cmp` is 0. `cmp` says where the element is relative to the target:
  ## negative for before (`Less`), positive for after (`Greater`).
  ##
  ## Same steps as Rust's standard library (checked against rustc 1.97 on
  ## random inputs, see tests/test_parse_extra.nim), so that among several
  ## matching elements this returns the same one.
  var size = spans.len
  if size == 0:
    return none(int)
  var base = 0
  while size > 1:
    let half = size div 2
    let mid = base + half
    if cmp(spans[mid]) <= 0:
      base = mid
    size -= half
  if cmp(spans[base]) == 0:
    some(base)
  else:
    none(int)

func isWithinComment*(self: ModuleExtra, byteIndex: int): bool =
  ## Detects if a byte index is in a comment context
  let cmp = proc(span: SrcSpan): int =
    if byteIndex < span.start:
      1
    elif byteIndex > span.stop:
      -1
    else:
      0

  self.comments.binarySearchBy(cmp).isSome or self.docComments.binarySearchBy(cmp).isSome or
    self.moduleComments.binarySearchBy(cmp).isSome

func indexOfFirstCommentBetween(self: ModuleExtra, start, stop: int): Option[int] =
  self.comments.binarySearchBy(
    proc(comment: SrcSpan): int =
      if comment.stop < start:
        -1
      elif comment.start > stop:
        1
      else:
        0
  )

func firstCommentBetween*(self: ModuleExtra, start, stop: int): Option[SrcSpan] =
  ## Returns the first comment overlapping the given source locations (inclusive)
  ## Note that the returned span covers the text of the comment, not the `//`
  # Index of a comment, but not necessarily the first one.
  let found = self.indexOfFirstCommentBetween(start, stop)
  if found.isNone:
    return none(SrcSpan)
  let index = found.get

  var i = index
  while i >= 0:
    let comment = self.comments[i]
    # comment overlaps span (inclusive of endpoints)
    if comment.stop >= start and comment.start <= stop:
      result = some(comment)
      dec i
    else:
      break

func hasCommentBetween*(self: ModuleExtra, start, stop: int): bool =
  self.firstCommentBetween(start, stop).isSome

func lastCommentBetween*(self: ModuleExtra, start, stop: int): Option[SrcSpan] =
  # We start from the first comment that we can find in between the given
  # start and end, this is really fast as we can find such index through
  # binary search.
  let found = self.indexOfFirstCommentBetween(start, stop)
  if found.isNone:
    return none(SrcSpan)
  var indexOfLastComment = found.get

  # Then we go over all the comments we can find from that one that are
  # still in between the given indices.
  while true:
    if indexOfLastComment + 1 < self.comments.len and
        start <= self.comments[indexOfLastComment + 1].start and
        self.comments[indexOfLastComment + 1].stop <= stop:
      # The next comment is still in between the two indices, we keep
      # going.
      indexOfLastComment += 1
    else:
      # The next comment is outside of the given range, that means
      # the current one is the last comment we were looking for.
      # We can return it!
      return some(self.comments[indexOfLastComment])

func initComment*(span: SrcSpan, src: string): Comment =
  ## Upstream `Comment::from((&SrcSpan, &str))`: the text of the comment at
  ## `span` in `src`.
  doAssert span.start >= 0 and span.stop <= src.len and span.start <= span.stop,
    "From span to comment"
  Comment(start: span.start, content: src[span.start ..< span.stop])
