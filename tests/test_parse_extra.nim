## port-part-of: compiler-core/src/parse/extra.rs
## port-part-of-note: the tests at the end of that file
##
## The upstream tests of `ModuleExtra`, and a check of our binary search
## against Rust's: `tests/data/parse_extra/binary_search.txt` is the output of
## `binary_search.rs` beside it (2,000 random lists of spans, with the index
## `binary_search_by` returns, or -1).

import std/[options, strutils]
import gleam_in_nim/parse/extra
import gleam_in_nim/src_span

func setUpExtra(): ModuleExtra =
  result = initModuleExtra()
  result.comments = @[
    initSrcSpan(0, 10),
    initSrcSpan(20, 30),
    initSrcSpan(40, 50),
    initSrcSpan(60, 70),
    initSrcSpan(80, 90),
    initSrcSpan(90, 100),
  ]

block firstCommentBetween:
  doAssert setUpExtra().firstCommentBetween(15, 85) == some(initSrcSpan(20, 30))

block firstCommentBetweenEqualToRange:
  doAssert setUpExtra().firstCommentBetween(40, 50) == some(initSrcSpan(40, 50))

block firstCommentBetweenOverlappingStartOfRange:
  doAssert setUpExtra().firstCommentBetween(45, 80) == some(initSrcSpan(40, 50))

block firstCommentBetweenOverlappingEndOfRange:
  doAssert setUpExtra().firstCommentBetween(35, 45) == some(initSrcSpan(40, 50))

block firstCommentBetweenAtEndOfRange:
  doAssert setUpExtra().firstCommentBetween(55, 60) == some(initSrcSpan(60, 70))

# Not upstream.
block ours:
  let extra = setUpExtra()
  doAssert extra.firstCommentBetween(11, 19).isNone
  doAssert extra.lastCommentBetween(15, 75) == some(initSrcSpan(60, 70))
  doAssert extra.lastCommentBetween(11, 19).isNone
  doAssert extra.hasCommentBetween(0, 0) and not extra.hasCommentBetween(101, 200)
  doAssert extra.isWithinComment(25) and extra.isWithinComment(30)
  doAssert not extra.isWithinComment(31)
  doAssert initComment(initSrcSpan(3, 8), "// hello") == Comment(start: 3, content: "hello")

proc binarySearchLikeRust() =
  var cases = 0
  for line in lines("tests/data/parse_extra/binary_search.txt"):
    let parts = line.split(' ')
    doAssert parts.len == 4, line
    var spans: seq[SrcSpan]
    if parts[0].len > 0:
      for item in parts[0].split(','):
        let ends = item.split('-')
        spans.add initSrcSpan(parseInt(ends[0]), parseInt(ends[1]))
    let start = parseInt(parts[1])
    let stop = parseInt(parts[2])
    let found = spans.binarySearchBy(
      proc(comment: SrcSpan): int =
        if comment.stop < start:
          -1
        elif comment.start > stop:
          1
        else:
          0
    )
    doAssert found.get(-1) == parseInt(parts[3]), line
    inc cases
  doAssert cases == 2000

binarySearchLikeRust()

echo "ok: parse/extra"
