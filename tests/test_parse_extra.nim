## port-part-of: compiler-core/src/parse/extra.rs
## (the tests at the end of that file)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/extra.rs.

import std/[options, unittest]
import ../src/gleam_in_nim/src_span
import ../src/gleam_in_nim/parse/extra

func setUpExtra(): ModuleExtra =
  result = initModuleExtra()
  result.comments = @[
    initSrcSpan(0, 10), initSrcSpan(20, 30), initSrcSpan(40, 50),
    initSrcSpan(60, 70), initSrcSpan(80, 90), initSrcSpan(90, 100)]

suite "parse/extra":
  let extra = setUpExtra()

  test "first_comment_between":
    check extra.firstCommentBetween(15, 85) == some(initSrcSpan(20, 30))

  test "first_comment_between_equal_to_range":
    check extra.firstCommentBetween(40, 50) == some(initSrcSpan(40, 50))

  test "first_comment_between_overlapping_start_of_range":
    check extra.firstCommentBetween(45, 80) == some(initSrcSpan(40, 50))

  test "first_comment_between_overlapping_end_of_range":
    check extra.firstCommentBetween(35, 45) == some(initSrcSpan(40, 50))

  test "first_comment_between_at_end_of_range":
    check extra.firstCommentBetween(55, 60) == some(initSrcSpan(60, 70))

  test "not in upstream: last comment, within comment, none":
    check extra.lastCommentBetween(15, 85) == some(initSrcSpan(60, 70))
    check extra.firstCommentBetween(11, 19).isNone
    check extra.isWithinComment(25)
    check not extra.isWithinComment(15)
    check initComment(initSrcSpan(3, 8), "// hello there").content == "hello"
