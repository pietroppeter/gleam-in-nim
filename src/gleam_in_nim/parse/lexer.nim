## port-of: compiler-core/src/parse/lexer.rs
## port-status: conformant
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/lexer.rs.

## The Gleam lexer: source text in, tokens with their byte spans out.
##
## This is a line by line port, so that it can be read next to the original.
## The differences worth knowing:
##
## - A character is an `int32` code point, and `noChar` stands for Rust's
##   `None`. The source must be valid UTF-8, as a Rust `&str` always is: check
##   with `std/unicode.validateUtf8` before lexing bytes of unknown origin.
## - Rust's `Result` and `?` become a private exception, caught in `next`.
## - Positions are `int`, not `u32`.

import std/[options, strutils, unicode]
import pkg/bigints
import ../src_span
import ./token
import ./error
import ./literals

export token, error, src_span, options

type
  Spanned* = tuple[start: int, token: Token, stop: int]

  LexResult* = object
    case isOk*: bool
    of true:
      spanned*: Spanned
    of false:
      error*: LexicalError

  Lexer* = object
    source: string
    cursor: int
    pending: seq[Spanned]
    char0: int32
    char1: int32
    location0: int
    location1: int
    hasCarriageReturn: bool

  LexicalException = object of CatchableError
    error: LexicalError

const noChar = -1'i32

template ch(c: char): int32 =
  int32(ord(c))

func `==`*(a, b: LexResult): bool =
  if a.isOk != b.isOk:
    return false
  if a.isOk:
    a.spanned == b.spanned
  else:
    a.error == b.error

func ok*(start: int, token: Token, stop: int): LexResult =
  LexResult(isOk: true, spanned: (start, token, stop))

func err*(error: LexicalErrorType, start, stop: int): LexResult =
  LexResult(
    isOk: false,
    error: LexicalError(error: error, location: initSrcSpan(start, stop)),
  )

func stringToKeyword*(word: string): Option[Token] =
  # Alphabetical keywords:
  case word
  of "as": some(tok(tkAs))
  of "assert": some(tok(tkAssert))
  of "auto": some(tok(tkAuto))
  of "case": some(tok(tkCase))
  of "const": some(tok(tkConst))
  of "delegate": some(tok(tkDelegate))
  of "derive": some(tok(tkDerive))
  of "echo": some(tok(tkEcho))
  of "else": some(tok(tkElse))
  of "fn": some(tok(tkFn))
  of "if": some(tok(tkIf))
  of "implement": some(tok(tkImplement))
  of "import": some(tok(tkImport))
  of "let": some(tok(tkLet))
  of "macro": some(tok(tkMacro))
  of "opaque": some(tok(tkOpaque))
  of "panic": some(tok(tkPanic))
  of "pub": some(tok(tkPub))
  of "test": some(tok(tkTest))
  of "todo": some(tok(tkTodo))
  of "type": some(tok(tkType))
  of "use": some(tok(tkUse))
  else: none(Token)

# Characters that look like valid Gleam source but are not.
const visuallySimilar: array[29, tuple[code: int32, name, correct: string]] = [
  (0x201A'i32, "low single comma quotation mark", "comma"),
  (0xFF3B'i32, "fullwidth left square bracket", "left square bracket"),
  (0xFF3D'i32, "fullwidth right square bracket", "right square bracket"),
  (0xFF08'i32, "fullwidth left parenthesis", "left parenthesis"),
  (0xFF09'i32, "fullwidth right parenthesis", "right parenthesis"),
  (0xFF0E'i32, "fullwidth full stop", "dot"),
  (0x3002'i32, "ideographic full stop", "dot"),
  (0xFF1C'i32, "fullwidth less-than sign", "less-than sign"),
  (0xFF1E'i32, "fullwidth greater-than sign", "greater-than sign"),
  (0xFF5C'i32, "fullwidth vertical line", "pipe"),
  (0xFF20'i32, "fullwidth commercial at", "at sign"),
  (0xFF3E'i32, "fullwidth circumflex accent", "caret"),
  (0xFF1A'i32, "fullwidth colon", "colon"),
  (0x201C'i32, "double quotation mark", "double quote"),
  (0x201D'i32, "double quotation mark", "double quote"),
  (0x2018'i32, "single quotation mark", "single quote"),
  (0x2019'i32, "single quotation mark", "single quote"),
  (0x2013'i32, "en dash", "minus sign"),
  (0x2014'i32, "em dash", "minus sign"),
  (0x2217'i32, "asterisk operator", "asterisk"),
  (0x2215'i32, "division slash", "forward slash"),
  (0x00A0'i32, "non-breaking space", "space"),
  (0x200B'i32, "zero-width space", "space"),
  (0x0430'i32, "Cyrillic letter а", "latin letter a"),
  (0x0435'i32, "Cyrillic letter е", "latin letter e"),
  (0x043E'i32, "Cyrillic letter о", "latin letter o"),
  (0x0440'i32, "Cyrillic letter р", "latin letter p"),
  (0x1D35'i32, "modifier letter capital I", "latin letter I"),
  (0xFF0C'i32, "fullwidth comma", "comma"),
]
const ideographicComma = (0x3001'i32, "ideographic comma", "comma")

proc fail(error: LexicalErrorType, start, stop: int) {.noreturn.} =
  var exception = newException(LexicalException, "lexical error")
  exception.error = LexicalError(error: error, location: initSrcSpan(start, stop))
  raise exception

proc fail(kind: LexicalErrorKind, start, stop: int) {.noreturn.} =
  fail(LexicalErrorType(kind: kind), start, stop)

# Helper function to go to the next character coming up.
# `\r\n` and lone `\r` become `\n`, reported at the `\r`'s index.
proc nextChar(lexer: var Lexer): int32 {.discardable.} =
  result = lexer.char0
  var next = noChar
  if lexer.cursor < lexer.source.len:
    let start = lexer.cursor
    let byte = lexer.source[lexer.cursor]
    if byte == '\r':
      lexer.hasCarriageReturn = true
      if lexer.cursor + 1 < lexer.source.len and lexer.source[lexer.cursor + 1] == '\n':
        lexer.cursor += 2
      else:
        lexer.cursor += 1
      next = ch('\n')
    elif ord(byte) < 0x80:
      lexer.cursor += 1
      next = ch(byte)
    else:
      var rune: Rune
      fastRuneAt(lexer.source, lexer.cursor, rune, true)
      next = int32(rune)
    lexer.location0 = lexer.location1
    lexer.location1 = start
  else:
    # No more characters to read, but the final ones may still be
    # in char0/char1. The first time we get here location1 is the start
    # of the final character, so stepping past it means jumping
    # to the end of the source, more than one byte away if that
    # character is multi-byte. After that we step one at a time.
    lexer.location0 = lexer.location1
    lexer.location1 = max(lexer.location1 + 1, lexer.cursor)
  lexer.char0 = lexer.char1
  lexer.char1 = next

proc makeTokenizer*(source: sink string): Lexer =
  result = Lexer(source: source, char0: noChar, char1: noChar)
  result.nextChar()
  result.nextChar()

  # Check whether the first character is a UTF-8 byte order mark, and if so, consume it.
  if result.char0 == 0xFEFF:
    result.nextChar()

# Helper function to retrieve the current position.
func getPosition(lexer: Lexer): int =
  lexer.location0

# The byte index just past everything consumed so far.
func consumedBytePos(lexer: Lexer): int =
  if lexer.char0 != noChar: lexer.location0 else: lexer.source.len

# Helper function to emit a lexed token to the queue of tokens.
proc emit(lexer: var Lexer, spanned: Spanned) =
  lexer.pending.add spanned

proc emit(lexer: var Lexer, start: int, kind: TokenKind, stop: int) =
  lexer.pending.add (start, tok(kind), stop)

# advance the stream and emit a token
proc eatSingleChar(lexer: var Lexer, kind: TokenKind) =
  let tokenStart = lexer.getPosition()
  lexer.nextChar()
  let tokenEnd = lexer.getPosition()
  lexer.emit(tokenStart, kind, tokenEnd)

func isNameStart(character: int32): bool =
  character == ch('_') or (character >= ch('a') and character <= ch('z'))

func isUpnameStart(character: int32): bool =
  character >= ch('A') and character <= ch('Z')

func isAsciiDigit(character: int32): bool =
  character >= ch('0') and character <= ch('9')

func isNumberStart(character, character1: int32): bool =
  if isAsciiDigit(character):
    true
  elif character == ch('-'):
    isAsciiDigit(character1)
  else:
    false

func isNameContinuation(lexer: Lexer): bool =
  let c = lexer.char0
  c == ch('_') or isAsciiDigit(c) or (c >= ch('a') and c <= ch('z')) or
    (c >= ch('A') and c <= ch('Z'))

# Test if a digit is of a certain radix.
func isDigitOfRadix(c: int32, radix: int): bool =
  let digit =
    if isAsciiDigit(c):
      c - ch('0')
    elif c >= ch('a') and c <= ch('z'):
      c - ch('a') + 10
    elif c >= ch('A') and c <= ch('Z'):
      c - ch('A') + 10
    else:
      return false
  case radix
  of 2, 8, 10, 16:
    digit < radix
  else:
    raiseAssert "Radix not implemented: " & $radix

# Consume a sequence of numbers with the given radix,
# the digits can be decorated with underscores
# like this: '1_2_3_4' == '1234'
proc radixRun(lexer: var Lexer, radix: int): string =
  let start = lexer.getPosition()
  while true:
    if isDigitOfRadix(lexer.char0, radix):
      lexer.nextChar()
    elif lexer.char0 == ch('_') and isDigitOfRadix(lexer.char1, radix):
      lexer.nextChar()
    else:
      break
  lexer.source[start ..< lexer.getPosition()]

# this can be either a reserved word, or a name
proc lexName(lexer: var Lexer): Spanned =
  let startPosition = lexer.getPosition()

  while lexer.isNameContinuation():
    lexer.nextChar()

  let endPosition = lexer.getPosition()
  let name = lexer.source[startPosition ..< endPosition]

  let keyword = stringToKeyword(name)
  if keyword.isSome:
    (startPosition, keyword.get, endPosition)
  elif name.startsWith('_'):
    (startPosition, Token(kind: tkDiscardName, name: name), endPosition)
  else:
    (startPosition, Token(kind: tkName, name: name), endPosition)

# A type name or constructor
proc lexUpname(lexer: var Lexer): Spanned =
  let startPosition = lexer.getPosition()

  while lexer.isNameContinuation():
    lexer.nextChar()

  let endPosition = lexer.getPosition()
  let name = lexer.source[startPosition ..< endPosition]

  let keyword = stringToKeyword(name)
  if keyword.isSome:
    (startPosition, keyword.get, endPosition)
  else:
    (startPosition, Token(kind: tkUpName, name: name), endPosition)

# Lex a hex/octal/decimal/binary number without a decimal point.
proc lexNumberRadix(
    lexer: var Lexer, startPos: int, radix: int, isNegative: bool, prefix: string
): Spanned =
  let num = lexer.radixRun(radix)
  if num.len == 0:
    let location = lexer.getPosition() - 1
    fail(RadixIntNoValue, location, location)
  elif radix < 16 and isDigitOfRadix(lexer.char0, 16):
    let location = lexer.getPosition()
    fail(DigitOutOfRadix, location, location)
  else:
    var value = prefix & num
    var intValue = parseIntValue(value).get
    let endPos = lexer.getPosition()

    if isNegative:
      value = "-" & value
      intValue = -intValue

    (startPos, Token(kind: tkInt, intText: value, intValue: intValue), endPos)

proc lexDecimalOrIntNumber(
    lexer: var Lexer, startPos: int, isNegative: bool, canLexDecimal: bool
): Spanned =
  let valueStart = if isNegative: startPos else: lexer.getPosition()
  # consume first run of digits
  discard lexer.radixRun(10)

  # If float:
  if canLexDecimal and lexer.char0 == ch('.'):
    lexer.nextChar()
    discard lexer.radixRun(10)

    # If scientific:
    if lexer.char0 == ch('e'):
      lexer.nextChar()
      if lexer.char0 == ch('-'):
        lexer.nextChar()
      if lexer.radixRun(10).len == 0:
        fail(MissingExponent, startPos, lexer.getPosition())
    let endPos = lexer.getPosition()
    let value = lexer.source[valueStart ..< endPos]
    let floatValue = parseLiteralFloat(value).get
    (startPos, Token(kind: tkFloat, floatText: value, floatValue: floatValue), endPos)
  else:
    let endPos = lexer.getPosition()
    let value = lexer.source[valueStart ..< endPos]
    let intValue = parseIntValue(value).get
    (startPos, Token(kind: tkInt, intText: value, intValue: intValue), endPos)

# Lex a normal number, that is, no octal, hex or binary number.
# This function cannot be reached without the head of the stream being either 0-9 or '-', 0-9
proc lexDecimalNumber(lexer: var Lexer, startPos: int, isNegative: bool): Spanned =
  lexer.lexDecimalOrIntNumber(startPos, isNegative, true)

proc lexIntNumber(lexer: var Lexer, startPos: int, isNegative: bool): Spanned =
  lexer.lexDecimalOrIntNumber(startPos, isNegative, false)

proc lexNumber(lexer: var Lexer): Spanned =
  let startPosition = lexer.getPosition()

  # We call this function after making sure that what comes next starts
  # with what seems to be a valid number. If we see that it starts with
  # `-` we consume the token and record that the number is negative.
  let isNegative = lexer.char0 == ch('-')
  if isNegative:
    lexer.nextChar()

  let number =
    if lexer.char0 == ch('0'):
      if lexer.char1 == ch('x') or lexer.char1 == ch('X'):
        # Hex!
        lexer.nextChar()
        lexer.nextChar()
        lexer.lexNumberRadix(startPosition, 16, isNegative, "0x")
      elif lexer.char1 == ch('o') or lexer.char1 == ch('O'):
        # Octal!
        lexer.nextChar()
        lexer.nextChar()
        lexer.lexNumberRadix(startPosition, 8, isNegative, "0o")
      elif lexer.char1 == ch('b') or lexer.char1 == ch('B'):
        # Binary!
        lexer.nextChar()
        lexer.nextChar()
        lexer.lexNumberRadix(startPosition, 2, isNegative, "0b")
      else:
        lexer.lexDecimalNumber(startPosition, isNegative)
    else:
      lexer.lexDecimalNumber(startPosition, isNegative)

  if lexer.char0 == ch('_'):
    let location = lexer.getPosition()
    fail(NumTrailingUnderscore, location, location)
  number

# Maybe lex dot access that comes after name token.
proc maybeLexDotAccess(lexer: var Lexer) =
  # It can be nested like: `tuple.1.2.3.4`
  while isAsciiDigit(lexer.char0):
    let number = lexer.lexIntNumber(lexer.getPosition(), false)
    lexer.emit(number)

# There are 3 kinds of comments
# 2 slash, normal
# 3 slash, document
# 4 slash, module
# this function is entered after 2 slashes
proc lexComment(lexer: var Lexer): Spanned =
  type Kind = enum
    Comment
    Doc
    ModuleDoc

  let kind =
    if lexer.char0 == ch('/') and lexer.char1 == ch('/'):
      lexer.nextChar()
      lexer.nextChar()
      ModuleDoc
    elif lexer.char0 == ch('/'):
      lexer.nextChar()
      Doc
    else:
      Comment
  let startPosition = lexer.getPosition()
  let contentStart = lexer.consumedBytePos()
  while lexer.char0 != ch('\n'):
    if lexer.char0 == noChar:
      break
    lexer.nextChar()
  let endPosition = lexer.getPosition()
  let token =
    case kind
    of Comment:
      tok(tkCommentNormal)
    of Doc:
      let contentEnd = lexer.consumedBytePos()
      Token(kind: tkCommentDoc, content: lexer.source[contentStart ..< contentEnd])
    of ModuleDoc:
      tok(tkCommentModule)
  (startPosition, token, endPosition)

func isAsciiHexDigit(c: int32): bool =
  isAsciiDigit(c) or (c >= ch('a') and c <= ch('f')) or (c >= ch('A') and c <= ch('F'))

proc lexString(lexer: var Lexer): Spanned =
  let startPosition = lexer.getPosition()
  # advance past the first quote
  lexer.nextChar()
  let contentStart = lexer.consumedBytePos()

  var contentEnd = 0
  while true:
    let charByte = lexer.consumedBytePos()
    let character = lexer.nextChar()
    if character == ch('\\'):
      let slashPosition = lexer.getPosition() - 1
      let escaped = lexer.char0
      if escaped == noChar:
        fail(BadStringEscape, slashPosition, slashPosition)
      if escaped < 128 and char(escaped) in {'f', 'n', 'r', 't', '"', '\\'}:
        lexer.nextChar()
      elif escaped == ch('u'):
        lexer.nextChar()

        if lexer.char0 != ch('{'):
          fail(
            LexicalErrorType(kind: InvalidUnicodeEscape, escape: MissingOpeningBrace),
            lexer.getPosition() - 1,
            lexer.getPosition(),
          )

        # All digits inside \u{...}.
        var hexDigits = 0
        var codepoint = 0

        while true:
          lexer.nextChar()

          let chr = lexer.char0
          if chr == noChar:
            break

          # Don't break early when we've reached 6 digits to ensure a
          # useful error message
          if chr == ch('}'):
            break

          if not isAsciiHexDigit(chr):
            fail(
              LexicalErrorType(
                kind: InvalidUnicodeEscape, escape: ExpectedHexDigitOrCloseBrace
              ),
              lexer.getPosition(),
              lexer.getPosition() + 1,
            )

          hexDigits += 1
          if hexDigits <= 6:
            codepoint = codepoint * 16 + parseHexInt($char(chr))

        if lexer.char0 != ch('}'):
          fail(
            LexicalErrorType(
              kind: InvalidUnicodeEscape, escape: ExpectedHexDigitOrCloseBrace
            ),
            lexer.getPosition() - 1,
            lexer.getPosition(),
          )

        lexer.nextChar()

        if hexDigits notin 1 .. 6:
          fail(
            LexicalErrorType(kind: InvalidUnicodeEscape, escape: InvalidNumberOfHexDigits),
            slashPosition,
            lexer.getPosition(),
          )

        # Checks for i >= 0x110000 || (i >= 0xD800 && i < 0xE000),
        # where i is the unicode codepoint.
        if codepoint >= 0x110000 or (codepoint >= 0xD800 and codepoint < 0xE000):
          fail(
            LexicalErrorType(kind: InvalidUnicodeEscape, escape: InvalidCodepoint),
            slashPosition,
            lexer.getPosition(),
          )
      else:
        fail(BadStringEscape, slashPosition, slashPosition + 1)
    elif character == ch('"'):
      contentEnd = charByte
      break
    elif character == noChar:
      fail(UnexpectedStringEnd, startPosition, startPosition)
  let endPosition = lexer.getPosition()

  # The lexer reports `\r\n` and lone `\r` as `\n`, but this value is a
  # slice of the source, where they are still carriage returns.
  var value = lexer.source[contentStart ..< contentEnd]
  if lexer.hasCarriageReturn and '\r' in value:
    value = value.replace("\r\n", "\n").replace('\r', '\n')

  (startPosition, Token(kind: tkString, value: value), endPosition)

# Once we've found a `<`, proceed from there
proc lexLt(lexer: var Lexer, tokenStart: int) =
  var tokenStart = tokenStart
  if lexer.char0 == ch('>'):
    lexer.nextChar()
    lexer.emit(tokenStart, tkConcatenate, lexer.getPosition())
  elif lexer.char0 == ch('<'):
    lexer.nextChar()

    if lexer.char0 != ch('<'):
      lexer.emit(tokenStart, tkLtLt, lexer.getPosition())
      return

    lexer.nextChar()
    var seenLt = 3

    while true:
      if seenLt >= 7:
        fail(MergeConflictIndicator, tokenStart, lexer.getPosition())

      if lexer.char0 == ch('<'):
        lexer.nextChar()
        seenLt += 1
      else:
        while seenLt > 1:
          lexer.emit(tokenStart, tkLtLt, tokenStart + 2)
          tokenStart += 2
          seenLt -= 2
        if seenLt > 0:
          lexer.lexLt(tokenStart)
        return
  elif lexer.char0 == ch('.'):
    lexer.nextChar()
    lexer.emit(tokenStart, tkLessDot, lexer.getPosition())
  elif lexer.char0 == ch('-'):
    lexer.nextChar()
    lexer.emit(tokenStart, tkLArrow, lexer.getPosition())
  elif lexer.char0 == ch('='):
    lexer.nextChar()
    if lexer.char0 == ch('.'):
      lexer.nextChar()
      lexer.emit(tokenStart, tkLessEqualDot, lexer.getPosition())
    else:
      lexer.emit(tokenStart, tkLessEqual, lexer.getPosition())
  else:
    lexer.emit(tokenStart, tkLess, lexer.getPosition())

# Once we've found a `>`
proc lexGt(lexer: var Lexer, tokenStart: int) =
  var tokenStart = tokenStart
  if lexer.char0 == ch('>'):
    lexer.nextChar()
    let tokenEnd = lexer.getPosition()

    if lexer.char0 != ch('>'):
      lexer.emit(tokenStart, tkGtGt, tokenEnd)
      return

    lexer.nextChar()
    var seenGt = 3

    while true:
      if seenGt >= 7:
        fail(MergeConflictIndicator, tokenStart, lexer.getPosition())

      if lexer.char0 == ch('>'):
        lexer.nextChar()
        seenGt += 1
      else:
        while seenGt > 1:
          lexer.emit(tokenStart, tkGtGt, tokenStart + 2)
          tokenStart += 2
          seenGt -= 2
        if seenGt > 0:
          lexer.lexGt(tokenStart)
        return
  elif lexer.char0 == ch('.'):
    lexer.nextChar()
    lexer.emit(tokenStart, tkGreaterDot, lexer.getPosition())
  elif lexer.char0 == ch('='):
    lexer.nextChar()
    if lexer.char0 == ch('.'):
      lexer.nextChar()
      lexer.emit(tokenStart, tkGreaterEqualDot, lexer.getPosition())
    else:
      lexer.emit(tokenStart, tkGreaterEqual, lexer.getPosition())
  else:
    lexer.emit(tokenStart, tkGreater, lexer.getPosition())

proc consumeEqual(lexer: var Lexer) =
  var tokenStart = lexer.getPosition()
  lexer.nextChar()

  if lexer.char0 != ch('='):
    let tokenEnd = lexer.getPosition()
    lexer.emit(tokenStart, tkEqual, tokenEnd)
    return

  lexer.nextChar()

  if lexer.char0 != ch('='):
    lexer.emit(tokenStart, tkEqualEqual, lexer.getPosition())
    return

  lexer.nextChar()
  var seenEquals = 3

  if lexer.char0 != ch('='):
    fail(InvalidTripleEqual, tokenStart, lexer.getPosition())

  while true:
    if seenEquals >= 7:
      fail(MergeConflictIndicator, tokenStart, lexer.getPosition())

    if lexer.char0 == ch('='):
      lexer.nextChar()
      seenEquals += 1
    else:
      while seenEquals > 1:
        lexer.emit(tokenStart, tkEqualEqual, tokenStart + 2)
        tokenStart += 2
        seenEquals -= 2
      if seenEquals > 0:
        lexer.emit(tokenStart, tkEqual, lexer.getPosition())
      break

# An arithmetic operator: `dotKind` if followed by a `.`, an error if followed
# by one of `procedural` (as in `+=`), else `plainKind`.
template arithmeticOperator(
    lexer: var Lexer, plainKind, dotKind: TokenKind, procedural: set[char]
) =
  let tokenStart = lexer.getPosition()
  lexer.nextChar()
  let next = lexer.char0
  if next == ch('.'):
    lexer.nextChar()
    lexer.emit(tokenStart, dotKind, lexer.getPosition())
  elif next >= 0 and next < 128 and char(next) in procedural:
    lexer.nextChar()
    fail(UnsupportedProceduralOperator, tokenStart, lexer.getPosition())
  else:
    lexer.emit(tokenStart, plainKind, lexer.getPosition())

proc consumeCharacter(lexer: var Lexer, character: int32) =
  if character < 128:
    case char(character)
    of '@':
      lexer.eatSingleChar(tkAt)
    of '"':
      let str = lexer.lexString()
      lexer.emit(str)
    of '=':
      lexer.consumeEqual()
    of '+':
      lexer.arithmeticOperator(tkPlus, tkPlusDot, {'=', '+'})
    of '*':
      lexer.arithmeticOperator(tkStar, tkStarDot, {'='})
    of '/':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('.'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkSlashDot, lexer.getPosition())
      elif lexer.char0 == ch('/'):
        lexer.nextChar()
        let comment = lexer.lexComment()
        lexer.emit(comment)
      elif lexer.char0 == ch('='):
        lexer.nextChar()
        fail(UnsupportedProceduralOperator, tokenStart, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkSlash, lexer.getPosition())
    of '%':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('='):
        lexer.nextChar()
        fail(UnsupportedProceduralOperator, tokenStart, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkPercent, lexer.getPosition())
    of '|':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('|'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkVbarVbar, lexer.getPosition())
      elif lexer.char0 == ch('>'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkPipe, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkVbar, lexer.getPosition())
    of '&':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('&'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkAmperAmper, lexer.getPosition())
      else:
        fail(
          LexicalErrorType(kind: UnrecognizedToken, token: Rune('&')),
          tokenStart,
          tokenStart,
        )
    of '-':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('.'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkMinusDot, lexer.getPosition())
      elif lexer.char0 == ch('>'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkRArrow, lexer.getPosition())
      # Not including `-` here because repeated int negation is
      # valid gleam
      elif lexer.char0 == ch('='):
        lexer.nextChar()
        fail(UnsupportedProceduralOperator, tokenStart, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkMinus, lexer.getPosition())
    of '!':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('='):
        lexer.nextChar()
        lexer.emit(tokenStart, tkNotEqual, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkBang, lexer.getPosition())
    of '(':
      lexer.eatSingleChar(tkLeftParen)
    of ')':
      lexer.eatSingleChar(tkRightParen)
    of '[':
      lexer.eatSingleChar(tkLeftSquare)
    of ']':
      lexer.eatSingleChar(tkRightSquare)
    of '{':
      lexer.eatSingleChar(tkLeftBrace)
    of '}':
      lexer.eatSingleChar(tkRightBrace)
    of ':':
      lexer.eatSingleChar(tkColon)
    of '<':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      lexer.lexLt(tokenStart)
    of '>':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      lexer.lexGt(tokenStart)
    of ',':
      lexer.eatSingleChar(tkComma)
    of '.':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      if lexer.char0 == ch('.'):
        lexer.nextChar()
        lexer.emit(tokenStart, tkDotDot, lexer.getPosition())
      else:
        lexer.emit(tokenStart, tkDot, lexer.getPosition())
        lexer.maybeLexDotAccess()
    of '#':
      lexer.eatSingleChar(tkHash)
    of '\n', ' ', '\t', '\x0C':
      let tokenStart = lexer.getPosition()
      lexer.nextChar()
      let tokenEnd = lexer.getPosition()
      if character == ch('\n'):
        lexer.emit(tokenStart, tkNewLine, tokenEnd)
    else:
      let location = lexer.getPosition()
      fail(
        LexicalErrorType(kind: UnrecognizedToken, token: Rune(character)),
        location,
        location,
      )
  else:
    let location = lexer.getPosition()
    # Visually similar characters that are not valid Gleam source.
    for (code, name, correct) in visuallySimilar:
      if code == character:
        fail(
          LexicalErrorType(
            kind: VisuallySimilarInvalidCharacter, name: name, correct: correct
          ),
          location,
          location,
        )
    if character == ideographicComma[0]:
      fail(
        LexicalErrorType(
          kind: VisuallySimilarInvalidCharacter,
          name: ideographicComma[1],
          correct: ideographicComma[2],
        ),
        location,
        location,
      )
    fail(
      LexicalErrorType(kind: UnrecognizedToken, token: Rune(character)),
      location,
      location,
    )

# Take a look at the next character, if any, and decide upon the next steps.
proc consumeNormal(lexer: var Lexer) =
  # Check if we have some character:
  let character = lexer.char0
  if character != noChar:
    var checkForMinus = false
    if isUpnameStart(character):
      let name = lexer.lexUpname()
      lexer.emit(name)
    elif isNameStart(character):
      checkForMinus = true
      let name = lexer.lexName()
      lexer.emit(name)
    elif isNumberStart(character, lexer.char1):
      checkForMinus = true
      let num = lexer.lexNumber()
      lexer.emit(num)
    else:
      lexer.consumeCharacter(character)
    if checkForMinus:
      # We want to lex `1-1` and `x-1` as `1 - 1` and `x - 1`
      if lexer.char0 == ch('-') and isNumberStart(ch('-'), lexer.char1):
        lexer.eatSingleChar(tkMinus)
  else:
    # We reached end of file.
    let tokenPos = lexer.getPosition()
    lexer.emit(tokenPos, tkEndOfFile, tokenPos)

# This is the main entry point. Call this function to retrieve the next token.
# This function is used by the iterator implementation.
proc innerNext(lexer: var Lexer): LexResult =
  try:
    # top loop, keep on processing, until we have something pending.
    while lexer.pending.len == 0:
      lexer.consumeNormal()
  except LexicalException as exception:
    return LexResult(isOk: false, error: exception.error)

  result = LexResult(isOk: true, spanned: lexer.pending[0])
  lexer.pending.delete(0)

proc next*(lexer: var Lexer): Option[LexResult] =
  ## The next token or error, or none at the end of the source.
  ##
  ## As upstream, the lexer can be asked for more after an error, but some
  ## errors do not consume the offending character and will repeat forever:
  ## the parser stops at the first one.
  let item = lexer.innerNext()
  if item.isOk and item.spanned.token.kind == tkEndOfFile:
    none(LexResult)
  else:
    some(item)

iterator items*(lexer: var Lexer): LexResult =
  var item = lexer.next()
  while item.isSome:
    yield item.get
    item = lexer.next()

proc lex*(source: sink string): seq[LexResult] =
  ## All the tokens of `source`, up to and including the first error if any.
  var lexer = makeTokenizer(source)
  for item in lexer:
    result.add item
    if not item.isOk:
      break
