## port-of: compiler-core/src/parse/tests.rs
## port-status: draft
##
## The upstream tests that exercise the lexer. Tests that upstream runs
## through the parser (`assert_error!` with a `LexError`) are checked here at
## the lexer: the error and its location are the same thing one level down.

import std/[unittest, unicode]
import gleam_in_nim/parse/lexer

func name(start: int, name: string, stop: int): LexResult =
  ok(start, Token(kind: tkName, name: name), stop)

func int(start: int, text: string, value: int, stop: int): LexResult =
  ok(start, Token(kind: tkInt, intText: text, intValue: initBigInt(value)), stop)

func str(start: int, value: string, stop: int): LexResult =
  ok(start, Token(kind: tkString, value: value), stop)

func t(start: int, kind: TokenKind, stop: int): LexResult =
  ok(start, tok(kind), stop)

proc lexError(source: string): LexicalError =
  ## The error that stops the lexing of `source`.
  let items = lex(source)
  doAssert items.len > 0 and not items[^1].isOk, "expected a lexical error"
  items[^1].error

func error(kind: LexicalErrorKind, start, stop: int): LexicalError =
  LexicalError(error: LexicalErrorType(kind: kind), location: initSrcSpan(start, stop))

func unicodeError(escape: InvalidUnicodeEscapeError, start, stop: int): LexicalError =
  LexicalError(
    error: LexicalErrorType(kind: InvalidUnicodeEscape, escape: escape),
    location: initSrcSpan(start, stop),
  )

suite "lexer: upstream tests":
  test "int_tests":
    # bad binary digit
    check lexError("0b012") == error(DigitOutOfRadix, 4, 4)
    # bad octal digit
    check lexError("0o12345678") == error(DigitOutOfRadix, 9, 9)
    # no int value
    check lexError("0x") == error(RadixIntNoValue, 1, 1)
    # trailing underscore
    check lexError("1_000_") == error(NumTrailingUnderscore, 5, 5)

  test "string_bad_character_escape":
    check lexError("\"\\g\"") == error(BadStringEscape, 1, 2)

  test "string_bad_character_escape_leading_backslash":
    check lexError("\"\\\\\\g\"") == error(BadStringEscape, 3, 4)

  test "string_freestanding_unicode_escape_sequence":
    check lexError("\"\\u\"") == unicodeError(MissingOpeningBrace, 2, 3)

  test "string_unicode_escape_sequence_no_braces":
    check lexError("\"\\u65\"") == unicodeError(MissingOpeningBrace, 2, 3)

  test "string_unicode_escape_sequence_invalid_hex":
    check lexError("\"\\u{z}\"") == unicodeError(ExpectedHexDigitOrCloseBrace, 4, 5)

  test "string_unclosed_unicode_escape_sequence":
    check lexError("\"\\u{039a\"") == unicodeError(ExpectedHexDigitOrCloseBrace, 8, 9)

  test "string_empty_unicode_escape_sequence":
    check lexError("\"\\u{}\"") == unicodeError(InvalidNumberOfHexDigits, 1, 5)

  test "string_overlong_unicode_escape_sequence":
    check lexError("\"\\u{0011f601}\"") == unicodeError(InvalidNumberOfHexDigits, 1, 13)

  test "string_invalid_unicode_escape_sequence":
    check lexError("\"\\u{110000}\"") == unicodeError(InvalidCodepoint, 1, 11)

  test "triple_equals":
    # https://github.com/gleam-lang/gleam/issues/3125
    check lexError("let wobble:Int = 32\n        wobble === 42") ==
      error(InvalidTripleEqual, 35, 38)

  test "newline_tokens":
    check lex("1\n\n2\n") ==
      @[
        int(0, "1", 1, 1),
        t(1, tkNewLine, 2),
        t(2, tkNewLine, 3),
        int(3, "2", 2, 4),
        t(4, tkNewLine, 5),
      ]

  test "crlf_source_exact_tokens":
    check lex("pub fn add(_x) {\r\n  Wibble\r\n}\r\n") ==
      @[
        t(0, tkPub, 3),
        t(4, tkFn, 6),
        name(7, "add", 10),
        t(10, tkLeftParen, 11),
        ok(11, Token(kind: tkDiscardName, name: "_x"), 13),
        t(13, tkRightParen, 14),
        t(15, tkLeftBrace, 16),
        t(16, tkNewLine, 18),
        ok(20, Token(kind: tkUpName, name: "Wibble"), 26),
        t(26, tkNewLine, 28),
        t(28, tkRightBrace, 29),
        t(29, tkNewLine, 31),
      ]

  test "lone_carriage_return_exact_tokens":
    check lex("a\rb") == @[name(0, "a", 1), t(1, tkNewLine, 2), name(2, "b", 3)]
    check lex("a\r") == @[name(0, "a", 1), t(1, tkNewLine, 2)]

  test "unrecognized_non_ascii_char_error":
    # Upstream takes the first two items; `lex` stops at the first error.
    check lex("let é = 1") ==
      @[
        t(0, tkLet, 3),
        err(LexicalErrorType(kind: UnrecognizedToken, token: "é".runeAt(0)), 4, 4),
      ]

  test "doc_comment_with_multibyte_char_at_eof":
    check lex("/// café") == @[ok(3, Token(kind: tkCommentDoc, content: " café"), 9)]

  test "string_containing_crlf_collapses_to_newline":
    check lex("\"a\r\nb\"") == @[str(0, "a\nb", 6)]

  test "string_containing_lone_carriage_return_collapses_to_newline":
    check lex("\"a\rb\"") == @[str(0, "a\nb", 5)]

  test "string_starting_with_crlf_collapses_to_newline":
    check lex("\"\r\nfoo\"") == @[str(0, "\nfoo", 7)]

  test "non_ascii_source_exact_tokens":
    check lex("let x = \"héllo\"") ==
      @[t(0, tkLet, 3), name(4, "x", 5), t(6, tkEqual, 7), str(8, "héllo", 16)]

suite "lexer: beyond upstream":
  test "the lexer can be driven one token at a time":
    var lexer = makeTokenizer("a b")
    check lexer.next() == some(name(0, "a", 1))
    check lexer.next() == some(name(2, "b", 3))
    check lexer.next().isNone
    check lexer.next().isNone

  test "tokens print as in error messages":
    check $tok(tkPipe) == "`|>`"
    check $Token(kind: tkName, name: "wibble") == "`wibble`"
    check $tok(tkNewLine) == "`NEWLINE`"

  test "reserved words and guard precedence":
    check tok(tkEcho).isReservedWord
    check not tok(tkPlus).isReservedWord
    check tok(tkStar).guardPrecedence == some(7'u8)
    check tok(tkPipe).guardPrecedence.isNone

  test "every keyword lexes to its own token":
    for kind in firstKeyword .. lastKeyword:
      let word = ($tok(kind))[1 .. ^2]
      check lex(word) == @[t(0, kind, word.len)]

  test "error messages":
    check lexError("a ; b").toParseErrorInfo.title == "Remove this semicolon"
    check lexError("x = ［1］").toParseErrorInfo.extra ==
      @[
        "This looks like ascii left square bracket, but it is actually the unicode\nfullwidth left square bracket."
      ]
