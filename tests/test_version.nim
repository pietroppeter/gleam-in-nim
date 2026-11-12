## port-of: hexpm/src/version/tests.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version/tests.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/tests.rs
#
# Upstream writes these tests with macros of its own, one test per line. Here
# each macro is a template and each test keeps its name. Also here: the tests
# at the end of hexpm/src/version/lexer.rs. Not ported: `manifest_toml`, which
# tests the TOML writer (it comes with the manifest).

import std/unittest
import gleam_in_nim/hexpm/version
import gleam_in_nim/hexpm/version/lexer

# Tests adapted from the tests for Elixir's version module

template versionParseTest(name: string, input: string, expected: Version) =
  test name:
    let parsed = parse(input)
    check parsed.isOk
    check parsed.value == expected

template versionParseFailTest(name: string, input: string) =
  test name:
    check not parse(input).isOk

template versionParsePrint(name: string, input: string) =
  test name:
    check input == $parse(input).value

template parseRangeTest(name: string, input: string, expected: PubgrubRange) =
  test name:
    let parsed = newRange(input)
    check parsed.isOk
    check parsed.value.toPubgrub == expected

template parseRangeFailTest(name: string, input: string) =
  test name:
    check not newRange(input).isOk

template assertOrder(name: string, left: string, ordering: int, right: string) =
  test name:
    check cmp(parse(left).value, parse(right).value) == ordering

func v(a, b, c: uint32): Version =
  initVersion(a, b, c)

func v(major, minor, patch: uint32, pre: seq[Identifier], build: Option[string]): Version =
  Version(major: major, minor: minor, patch: patch, pre: pre, build: build)

const
  Less = -1
  Equal = 0
  Greater = 1

suite "hexpm version: upstream's tests":
  versionParseTest("triplet", "1.2.3", v(1, 2, 3))

  versionParseTest("build", "1.4.5+ignore", v(1, 4, 5, @[], some("ignore")))

  versionParseTest("two_part_build", "0.0.1+sha.0702245", v(0, 0, 1, @[], some("sha.0702245")))

  versionParseTest("pre", "1.4.5-6-g3318bd5", v(1, 4, 5, @[alphaNumeric("6-g3318bd5")], none(string)))

  versionParseTest(
    "multi_part_pre", "1.4.5-6.7.eight",
    v(1, 4, 5, @[numeric(6), numeric(7), alphaNumeric("eight")], none(string)))

  versionParseTest(
    "pre_and_build", "1.4.5-6-g3318bd5+ignore",
    v(1, 4, 5, @[alphaNumeric("6-g3318bd5")], some("ignore")))

  versionParseFailTest("just_a_word", "wibble")
  versionParseFailTest("just_major", "2")
  versionParseFailTest("major_dor", "2.")
  versionParseFailTest("major_minor", "2.3")
  versionParseFailTest("major_minor_dot", "2.3.")
  versionParseFailTest("triplet_dash", "2.3.0-")
  versionParseFailTest("triplet_plus", "2.3.0+")
  versionParseFailTest("triplet_dot", "2.3.0.")
  versionParseFailTest("quad", "2.3.0.4")
  versionParseFailTest("missing_minor", "2.3.-rc.1")
  versionParseFailTest("missing_minor_with_dot", "2.3.+rc.1")
  versionParseFailTest("zero_pre", "2.3.0-01")
  versionParseFailTest("double_zero_pre", "2.3.00-1")
  versionParseFailTest("double_zero", "2.3.00")
  versionParseFailTest("leading_zero_minor", "2.03.0")
  versionParseFailTest("leading_zero_major", "02.3.0")
  versionParseFailTest("extra_whitespace", "0. 0.0")
  versionParseFailTest("and_in_version", "0.1.0-andpre")

  versionParsePrint("print_triplet", "1.100.1000")
  versionParsePrint("print_pre", "1.100.4-dev")
  versionParsePrint("print_pre_dot", "1.100.4-dev.1.r.t")
  versionParsePrint("print_build", "1.100.4+dev.1.r.t")
  versionParsePrint("print_pre_build", "1.100.4-ewfjhwefj.wefw.w.1.ff+dev.1.r.t")

  parseRangeTest("leading_space", " 1.2.3", singleton(v(1, 2, 3)))
  parseRangeTest("trailing_space", "1.2.3 ", singleton(v(1, 2, 3)))

  parseRangeTest("eq_triplet", "== 1.2.3 ", singleton(v(1, 2, 3)))

  parseRangeTest("eq_triplet_nospace", "==1.2.3 ", singleton(v(1, 2, 3)))

  parseRangeTest(
    "neq_triplet", "!= 1.2.3",
    strictlyLowerThan(v(1, 2, 3)).union(higherThan(v(1, 2, 4))))

  parseRangeTest("implicit_eq", "2.2.3", singleton(v(2, 2, 3)))

  parseRangeTest(
    "range_pre_build", "1.2.3-thing+oop",
    singleton(v(1, 2, 3, @[alphaNumeric("thing")], some("oop"))))

  parseRangeTest(
    "and", "< 1.2.3 and > 1.0.1",
    strictlyLowerThan(v(1, 2, 3)).intersection(higherThan(v(1, 0, 2))))

  parseRangeTest(
    "or", "< 1.2.3 or > 1.0.1",
    strictlyLowerThan(v(1, 2, 3)).union(higherThan(v(1, 0, 2))))

  parseRangeTest("gt", "> 1.0.0", higherThan(v(1, 0, 1)))
  parseRangeTest("gt_eq", ">= 1.0.0", higherThan(v(1, 0, 0)))
  parseRangeTest("lt", "< 1.0.0", strictlyLowerThan(v(1, 0, 0)))
  parseRangeTest("lt_eq", "<= 1.0.0", strictlyLowerThan(v(1, 0, 1)))

  parseRangeTest(
    "pessimistic_pair", "~> 2.2",
    higherThan(v(2, 2, 0)).intersection(strictlyLowerThan(v(3, 0, 0))))

  parseRangeTest(
    "pessimistic_triplet", "~> 4.6.5",
    higherThan(v(4, 6, 5)).intersection(strictlyLowerThan(v(4, 7, 0))))

  parseRangeTest(
    "pessimistic_triplet_pre", "~> 4.6.5-eee",
    higherThan(v(4, 6, 5, @[alphaNumeric("eee")], none(string)))
      .intersection(strictlyLowerThan(v(4, 7, 0))))

  parseRangeTest(
    "pessimistic_triplet_build", "~> 4.6.5+eee",
    higherThan(v(4, 6, 5, @[], some("eee"))).intersection(strictlyLowerThan(v(4, 7, 0))))

  parseRangeTest(
    "greater_or_pessimistic", "> 10.0.0 or ~> 3.0.0",
    higherThan(v(10, 0, 1)).union(
      higherThan(v(3, 0, 0)).intersection(strictlyLowerThan(v(3, 1, 0)))))

  parseRangeTest(
    "pessimistic_or_pessimistic", "~> 1.0.0 or ~> 3.0.0",
    higherThan(v(1, 0, 0)).intersection(strictlyLowerThan(v(1, 1, 0))).union(
      higherThan(v(3, 0, 0)).intersection(strictlyLowerThan(v(3, 1, 0)))))

  parseRangeTest(
    "pessimistic_and_gt", "~> 0.6 and >= 0.6.16",
    higherThan(v(0, 6, 0)).intersection(strictlyLowerThan(v(1, 0, 0)))
      .intersection(higherThan(v(0, 6, 16))))

  parseRangeTest(
    "pessimistic_and_gt_pre", "~> 1.0-pre and >= 1.0.0-pre.5",
    higherThan(v(1, 0, 0, @[alphaNumeric("pre")], none(string)))
      .intersection(strictlyLowerThan(v(2, 0, 0)))
      .intersection(higherThan(v(1, 0, 0, @[alphaNumeric("pre"), numeric(5)], none(string)))))

  parseRangeFailTest("range_quad", "1.1.1.1")
  parseRangeFailTest("range_just_major", "1")
  parseRangeFailTest("range_just_major_minor", "1.1")
  parseRangeFailTest("alpha_component", "1.1.a")
  parseRangeFailTest("range_word", "wibble")
  parseRangeFailTest("range_major_dot", "2.")
  parseRangeFailTest("range_major_minor_dot", "2.3.")
  parseRangeFailTest("range_triplet_dash", "2.3.0-")
  parseRangeFailTest("range_triplet_plus", "2.3.0+")
  parseRangeFailTest("range_triplet_dot", "2.3.0.")
  parseRangeFailTest("range_dot_dash", "2.3.-rc.1")
  parseRangeFailTest("range_dot_plus", "2.3.+rc.1")
  parseRangeFailTest("range_zero_pre", "2.3.0-01")
  parseRangeFailTest("patch_zerozero_dash", "2.3.00-1")
  parseRangeFailTest("patch_zerozero", "2.3.00")
  parseRangeFailTest("minor_leading_zero", "2.03.0")
  parseRangeFailTest("major_leading_zero", "02.3.0")
  parseRangeFailTest("triplet_containing_whitespace", "0. 0.0")
  parseRangeFailTest("dash_amp", "0.1.0-&&pre")
  parseRangeFailTest("or_whitespace_before", "!= 1.2.3or == 1.0.1")
  parseRangeFailTest("or_whitespace_after", "!= 1.2.3 or== 1.0.1")
  parseRangeFailTest("and_whitespace_before", "!= 1.2.3and == 1.0.1")
  parseRangeFailTest("and_whitespace_after", "!= 1.2.3 and== 1.0.1")
  parseRangeFailTest("trailing_and", "1.1.1 and")
  parseRangeFailTest("trailing_or", "1.1.1 or")
  parseRangeFailTest("leading_and", "and 1.1.1")
  parseRangeFailTest("leading_or", "and 1.1.1")
  parseRangeFailTest("just_and", "and")
  parseRangeFailTest("just_or", "and")
  parseRangeFailTest("duplicate_eq", "== ==")
  parseRangeFailTest("just_eq", "==")
  parseRangeFailTest("empty", "")
  parseRangeFailTest("pessimistic_major", "~> 1")

  assertOrder("ord_same", "1.0.0", Equal, "1.0.0")
  assertOrder("ord_same_build_right", "1.0.0", Equal, "1.0.0+1")
  assertOrder("ord_same_build_left", "1.0.0+1", Equal, "1.0.0")
  assertOrder("ord_same_diff_build", "1.0.0+1", Equal, "1.0.0+2")
  assertOrder("ord_diff_build", "1.0.0+2", Equal, "1.0.0+1")
  assertOrder("ord_major_greater", "3.0.0", Greater, "2.0.0")
  assertOrder("ord_major_lesser", "1.0.0", Less, "2.0.0")
  assertOrder("ord_minor_greater", "1.1.0", Greater, "1.0.0")
  assertOrder("ord_minor_lesser", "1.0.0", Less, "1.1.0")
  assertOrder("ord_patch_greater", "1.0.1", Greater, "1.0.0")
  assertOrder("ord_patch_lesser", "1.0.0", Less, "1.0.1")
  assertOrder("ord_pre_smaller_than_zero", "1.0.0", Greater, "1.0.0-rc1")
  assertOrder("ord_pre_smaller_than_zero_flip", "1.0.0-rc1", Less, "1.0.0")
  assertOrder("ord_pre_rc1_2", "1.0.0-rc1", Less, "1.0.0-rc2")

  test "missing_minor_has_correct_error_type":
    check parse("1").error == version.Error(kind: ekMinorVersionMissing, vMinorVersionMissing: 1)

  test "missing_patch_has_correct_error_type":
    check parse("1.2").error == version.Error(kind: ekPatchVersionMissing, vPatchVersionMissing: (1'u32, 2'u32))

proc lex(input: string): seq[Token] =
  var lexer = initLexer(input)
  while true:
    let token = lexer.next()
    if token.isNone:
      break
    result.add token.get

func numericToken(number: uint32): Token = Token(kind: vtNumeric, vNumeric: number)
func alphaNumericToken(text: string): Token = Token(kind: vtAlphaNumeric, vAlphaNumeric: text)
func whitespace(start, stop: int): Token = Token(kind: vtWhitespace, vWhitespace: (start, stop))

suite "hexpm version lexer: upstream's tests":
  test "simple_tokens":
    check lex("!===><<=>=~>.-+orand") == @[
      tok(vtNotEq), tok(vtEq), tok(vtGt), tok(vtLt), tok(vtLtEq), tok(vtGtEq), tok(vtPessimistic),
      tok(vtDot), tok(vtHyphen), tok(vtPlus), tok(vtOr), tok(vtAnd)]

  test "whitespace":
    check lex("  wibble \t\n\rwobble") == @[
      whitespace(0, 2), alphaNumericToken("wibble"), whitespace(8, 12), alphaNumericToken("wobble")]

  test "components":
    check lex("42") == @[numericToken(42)]
    check lex("0") == @[numericToken(0)]
    check lex("5885644aa") == @[alphaNumericToken("5885644aa")]
    check lex("beta2") == @[alphaNumericToken("beta2")]
    check lex("beta.2") == @[alphaNumericToken("beta"), tok(vtDot), numericToken(2)]

  test "empty":
    check lex("").len == 0

  test "numeric_all_numbers":
    var expected: seq[Token]
    for number in 0'u32 .. 9'u32: expected.add numericToken(number)

    var actual: seq[Token]
    for token in lex("0 1 2 3 4 5 6 7 8 9"):
      if not token.isWhitespace: actual.add token

    check actual == expected

  test "token_display":
    check $tok(vtEq) == "=="
    check $tok(vtNotEq) == "!="
    check $tok(vtGt) == ">"
    check $tok(vtLt) == "<"
    check $tok(vtLtEq) == "<="
    check $tok(vtGtEq) == ">="
    check $tok(vtPessimistic) == "~>"
    check $tok(vtDot) == "."
    check $tok(vtHyphen) == "-"
    check $tok(vtPlus) == "+"
    check $tok(vtOr) == "or"
    check $tok(vtAnd) == "and"
    check $whitespace(0, 1) == " "
    check $numericToken(42) == "42"
    check $alphaNumericToken("abc") == "abc"
    check $Token(kind: vtLeadingZero, vLeadingZero: "012") == "012"
