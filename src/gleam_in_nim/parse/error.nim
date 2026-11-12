## port-of: compiler-core/src/parse/error.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/error.rs.

## Errors of the lexer. The parser's errors (`ParseError`) are not ported yet.

import std/[strformat, unicode]
import ../src_span
import ../error as core_error

type
  InvalidUnicodeEscapeError* = enum
    MissingOpeningBrace ## Expected '{'
    ExpectedHexDigitOrCloseBrace ## Expected hex digit or '}'
    InvalidNumberOfHexDigits ## Expected between 1 and 6 hex digits
    InvalidCodepoint ## Invalid Unicode codepoint

  LexicalErrorKind* = enum
    ## Upstream `LexicalErrorType`.
    BadStringEscape ## String contains an unescaped slash
    InvalidUnicodeEscape ## \u{...} escape sequence is invalid
    DigitOutOfRadix ## 0x012 , 2 is out of radix
    NumTrailingUnderscore ## 1_000_ is not allowed
    RadixIntNoValue ## 0x, 0b, 0o without a value
    MissingExponent ## 1.0e, for example, where there is no exponent
    UnexpectedStringEnd ## Unterminated string literal
    UnrecognizedToken
    InvalidTripleEqual
    MergeConflictIndicator
    UnsupportedProceduralOperator
      ## Operators that commonly exist in procedural language, but do
      ## not exist in Gleam. e.g. `++`, `-=`, `/=`, `%=`, `+=`, `*=`
    VisuallySimilarInvalidCharacter
      ## A character was encountered that visually looks like a correct
      ## character, but in reality it's some other unicode characters.
      ## For example, a non-breaking-space instead of a regular space.

  LexicalErrorType* = object
    case kind*: LexicalErrorKind
    of InvalidUnicodeEscape:
      escape*: InvalidUnicodeEscapeError
    of UnrecognizedToken:
      token*: Rune
    of VisuallySimilarInvalidCharacter:
      name*: string
      correct*: string
    else:
      discard

  LexicalError* = object
    error*: LexicalErrorType
    location*: SrcSpan

func `==`*(a, b: LexicalErrorType): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of InvalidUnicodeEscape:
    a.escape == b.escape
  of UnrecognizedToken:
    a.token == b.token
  of VisuallySimilarInvalidCharacter:
    a.name == b.name and a.correct == b.correct
  else:
    true

func `==`*(a, b: LexicalError): bool =
  a.error == b.error and a.location == b.location

func toParseErrorInfo*(error: LexicalError): tuple[title: string, extra: seq[string]] =
  ## The message shown for a lexical error, and its extra lines.
  let e = error.error
  case e.kind
  of BadStringEscape:
    ("I don't understand this escape code", @[
      "Hint: Add another backslash before it.",
      "See: https://tour.gleam.run/basics/strings",
    ])
  of DigitOutOfRadix:
    ("This digit is too big for the specified radix", @[])
  of NumTrailingUnderscore:
    ("Numbers cannot have a trailing underscore", @["Hint: remove it."])
  of RadixIntNoValue:
    ("This integer has no value", @[])
  of MissingExponent:
    ("This float is missing an exponent",
      @["Hint: Add an exponent or remove the trailing `e`"])
  of UnexpectedStringEnd:
    ("The string starting here was left open", @[])
  of UnrecognizedToken:
    if e.token == Rune(';'):
      ("Remove this semicolon", @[
        "Hint: Semicolons used to be whitespace and did nothing.",
        "You can safely remove them without your program changing.",
      ])
    elif e.token == Rune('\''):
      ("Unexpected single quote", @["Hint: Strings are written with double quotes."])
    else:
      ("I can't figure out what to do with this character", @["Hint: Is it a typo?"])
  of InvalidUnicodeEscape:
    case e.escape
    of MissingOpeningBrace:
      ("Expected '{' in Unicode escape sequence", @["Hint: Add it."])
    of ExpectedHexDigitOrCloseBrace:
      ("Expected hex digit or '}' in Unicode escape sequence", @[
        "Hint: Hex digits are digits from 0 to 9 and letters from a to f or A to F."
      ])
    of InvalidNumberOfHexDigits:
      ("Expected between 1 and 6 hex digits in Unicode escape sequence", @[])
    of InvalidCodepoint:
      ("Invalid Unicode codepoint", @[])
  of InvalidTripleEqual:
    ("Did you mean `==`?", @[
      "Gleam uses `==` to check for equality between two values.",
      "See: https://tour.gleam.run/basics/equality",
    ])
  of MergeConflictIndicator:
    ("Merge conflict marker found", @[
      """Your code appears to have a merge conflict. Resolve it by removing
the code you do not want to keep.

If you are in a merge, the top chunk is the checked-out code, and the
bottom chunk is the new code being merged.

If you are in a rebase, the top chunk is the code being rebased onto,
and the chunk section is the checked-out code which is being rebased.

More information can be found in the official git documentation:
https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging#_checking_out_conflicts"""
    ])
  of UnsupportedProceduralOperator:
    ("Unknown operator", @[
      """Gleam is an immutable language and does not have any operators that
change the value of an existing variable. You might want to create a
new variable with the same name as the previous one:

    let wibble = 10
    let blobby = wibble
    let wibble = wibble + 20
    assert wibble == 30
    assert blobby == 10
"""
    ])
  of VisuallySimilarInvalidCharacter:
    ("Unexpected character", @[
      wrap(&"This looks like ascii {e.correct}, but it is actually the unicode {e.name}.")
    ])
