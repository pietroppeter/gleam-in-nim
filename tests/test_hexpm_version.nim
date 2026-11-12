# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2: the tests at the end of
# hexpm/src/version/lexer.rs, and hexpm/src/version/tests.rs.
#
# The tests of tests.rs are made by macros, one test per input. Their inputs are replayed
# from tests/golden/hexpm_version/cases.txt (the cases named `upstream:<test name>`), with
# the answers of the Rust crate itself as expected results, next to the versions and
# requirements of the corpus and a few thousand random strings. See
# tests/differential/hexpm_version/run.sh.
import std/[importutils, options, os, sequtils, unittest]
import ../src/gleam_in_nim/hexpm/version {.all.}
import differential/hexpm_version/driver

privateAccess(Token)

proc lex(input: string): seq[Token] =
  var lexer = newLexer(input)
  while true:
    let token = lexer.next()
    if token.isNone: break
    result.add token.get

proc numeric(n: uint32): Token = Token(kind: tkNumeric, number: n)
proc alphaNumeric(s: string): Token = Token(kind: tkAlphaNumeric, text: s)
proc simple(kind: TokenKind): Token = Token(kind: kind)

suite "hexpm version lexer: upstream's tests":
  test "simple_tokens":
    check lex("!===><<=>=~>.-+orand") == [tkNotEq, tkEq, tkGt, tkLt, tkLtEq, tkGtEq,
      tkPessimistic, tkDot, tkHyphen, tkPlus, tkOr, tkAnd].map(simple)

  test "whitespace":
    check lex("  wibble \t\n\rwobble") == @[
      Token(kind: tkWhitespace, start: 0, stop: 2),
      alphaNumeric("wibble"),
      Token(kind: tkWhitespace, start: 8, stop: 12),
      alphaNumeric("wobble")]

  test "components":
    check lex("42") == @[numeric(42)]
    check lex("0") == @[numeric(0)]
    check lex("5885644aa") == @[alphaNumeric("5885644aa")]
    check lex("beta2") == @[alphaNumeric("beta2")]
    check lex("beta.2") == @[alphaNumeric("beta"), simple(tkDot), numeric(2)]

  test "empty":
    check lex("").len == 0

  test "numeric_all_numbers":
    let expected = toSeq(0'u32 .. 9'u32).map(numeric)
    let actual = lex("0 1 2 3 4 5 6 7 8 9").filterIt(not it.isWhitespace)
    check actual == expected

  test "token_display":
    check $simple(tkEq) == "=="
    check $simple(tkNotEq) == "!="
    check $simple(tkGt) == ">"
    check $simple(tkLt) == "<"
    check $simple(tkLtEq) == "<="
    check $simple(tkGtEq) == ">="
    check $simple(tkPessimistic) == "~>"
    check $simple(tkDot) == "."
    check $simple(tkHyphen) == "-"
    check $simple(tkPlus) == "+"
    check $simple(tkOr) == "or"
    check $simple(tkAnd) == "and"
    check $Token(kind: tkWhitespace, start: 0, stop: 1) == " "
    check $numeric(42) == "42"
    check $alphaNumeric("abc") == "abc"
    check $Token(kind: tkLeadingZero, text: "012") == "012"

suite "hexpm version: upstream's tests":
  # `manifest_toml` serialises versions to TOML: it comes with the manifest.

  test "missing_minor_has_correct_error_type":
    check Version.parse("1") == ParseResult[Version](isOk: false,
      error: ParserError(kind: peMinorVersionMissing, major: 1))

  test "missing_patch_has_correct_error_type":
    check Version.parse("1.2") == ParseResult[Version](isOk: false,
      error: ParserError(kind: pePatchVersionMissing, major: 1, minor: 2))

  test "the inputs of upstream's tests, the corpus and random strings, answered as the Rust crate answers":
    let golden = currentSourcePath.parentDir / "golden" / "hexpm_version"
    let r = compare(golden / "cases.txt", golden / "expected.txt")
    checkpoint r.first
    check r.cases > 4000
    check r.different == 0

suite "hexpm version: what the cases cannot reach":
  test "a range made from a version or from a set prints the set":
    check $toRange(Version.new(1, 2, 3)) == "1.2.3"
    check toRange(higherThan(Version.new(1, 0, 0))).asStr == ">=1.0.0"
    check Range.new("~> 1.0").value.asStr == "~> 1.0"

  test "lowest_version":
    check lowestVersion(Range.new("~> 1.2 or == 0.3.0").value.toPubgrub) == some(Version.new(0, 3, 0))
    check lowestVersion(Range.new("< 2.0.0").value.toPubgrub) == some(Version.lowest)
    check lowestVersion(PubgrubRange.empty) == none(Version)

  test "build metadata is part of equality, not of the order":
    let a = Version.parse("1.0.0+a").value
    let b = Version.parse("1.0.0+b").value
    check a != b
    check cmp(a, b) == 0
    check Version.parse("1.0.0-rc1").value < Version.parse("1.0.0").value
    check Version.parse("1.0.0").value.isPre == false
