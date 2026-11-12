## port-of: hexpm/src/version/lexer.rs
## port-status: draft
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version/lexer.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/lexer.rs

## Lexer for semver ranges.
##
## Breaks a string of input into an iterator of tokens that can be used with a parser.
##
## Based off https://github.com/steveklabnik/semver-parser/blob/bee9de80aaa9653c5eb46a83658606cb21151e65/src/lexer.rs

import std/[options, unicode]
import ../../rust_debug

type
  TokenKind* = enum
    ## Semver tokens.
    vtEq ## `==`
    vtNotEq ## `!=`
    vtGt ## `>`
    vtLt ## `<`
    vtLtEq ## `<=`
    vtGtEq ## `>=`
    vtPessimistic ## '~>`
    vtDot ## `.`
    vtHyphen ## `-`
    vtPlus ## `+`
    vtOr ## 'or'
    vtAnd ## 'and'
    vtWhitespace ## Any number of whitespace (`\t\r\n `) and its span.
    vtNumeric ## Numeric component, like `0` or `42`.
    vtAlphaNumeric ## Alphanumeric component, like `alpha1` or `79deadbe`.
    vtLeadingZero ## An alphanumeric component with a leading zero, like `0alpha1` or `079deadbe`.

  Token* = object
    case kind*: TokenKind
    of vtEq, vtNotEq, vtGt, vtLt, vtLtEq, vtGtEq, vtPessimistic, vtDot, vtHyphen, vtPlus, vtOr, vtAnd:
      discard
    of vtWhitespace:
      vWhitespace*: (int, int)
    of vtNumeric:
      vNumeric*: uint32
    of vtAlphaNumeric:
      vAlphaNumeric*: string
    of vtLeadingZero:
      vLeadingZero*: string

  ErrorKind* = enum
    leUnexpectedCharacter

  Error* = object
    case kind*: ErrorKind
    of leUnexpectedCharacter:
      vUnexpectedCharacter*: Rune

  LexerException* = object of CatchableError
    ## How an error travels inside the port, where the Rust has `?`.
    error*: Error

  Lexer* = object
    ## Lexer for semver tokens belonging to a range.
    input: string
    chars: int ## the byte offset of the next character to read
    # Lookahead
    char0: Option[(int, Rune)]
    char1: Option[(int, Rune)]

func tok*(kind: TokenKind): Token =
  ## A token that carries nothing.
  case kind
  of vtEq: Token(kind: vtEq)
  of vtNotEq: Token(kind: vtNotEq)
  of vtGt: Token(kind: vtGt)
  of vtLt: Token(kind: vtLt)
  of vtLtEq: Token(kind: vtLtEq)
  of vtGtEq: Token(kind: vtGtEq)
  of vtPessimistic: Token(kind: vtPessimistic)
  of vtDot: Token(kind: vtDot)
  of vtHyphen: Token(kind: vtHyphen)
  of vtPlus: Token(kind: vtPlus)
  of vtOr: Token(kind: vtOr)
  of vtAnd: Token(kind: vtAnd)
  of vtWhitespace, vtNumeric, vtAlphaNumeric, vtLeadingZero:
    raiseAssert "this token carries a value"

func `==`*(left, right: Token): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of vtEq, vtNotEq, vtGt, vtLt, vtLtEq, vtGtEq, vtPessimistic, vtDot, vtHyphen, vtPlus, vtOr, vtAnd:
    true
  of vtWhitespace: left.vWhitespace == right.vWhitespace
  of vtNumeric: left.vNumeric == right.vNumeric
  of vtAlphaNumeric: left.vAlphaNumeric == right.vAlphaNumeric
  of vtLeadingZero: left.vLeadingZero == right.vLeadingZero

func isWhitespace*(self: Token): bool =
  ## Check if the current token is a whitespace token.
  self.kind == vtWhitespace

func `$`*(self: Token): string =
  case self.kind
  of vtEq: "=="
  of vtNotEq: "!="
  of vtGt: ">"
  of vtLt: "<"
  of vtLtEq: "<="
  of vtGtEq: ">="
  of vtPessimistic: "~>"
  of vtDot: "."
  of vtHyphen: "-"
  of vtPlus: "+"
  of vtOr: "or"
  of vtAnd: "and"
  of vtWhitespace: " "
  of vtNumeric: $self.vNumeric
  of vtAlphaNumeric: self.vAlphaNumeric
  of vtLeadingZero: self.vLeadingZero

func `==`*(left, right: Error): bool =
  left.vUnexpectedCharacter == right.vUnexpectedCharacter

func `$`*(self: Error): string =
  "Unexpected character " & $self.vUnexpectedCharacter

func debug*(self: Error): string =
  ## Rust's `{:?}` of the error, which is what the parser's message shows.
  "UnexpectedCharacter(" & debugChar(self.vUnexpectedCharacter) & ")"

func nextChar(self: var Lexer): Option[(int, Rune)] =
  ## Rust's `chars.next()` on a `CharIndices`.
  if self.chars >= self.input.len:
    return none((int, Rune))
  let start = self.chars
  var character: Rune
  fastRuneAt(self.input, self.chars, character)
  some((start, character))

func initLexer*(input: string): Lexer =
  ## Construct a new lexer for the given input.
  result = Lexer(input: input, chars: 0)
  result.char0 = result.nextChar()
  result.char1 = result.nextChar()

func step(self: var Lexer) =
  ## Shift all lookahead storage by one.
  self.char0 = self.char1
  self.char1 = self.nextChar()

func stepN(self: var Lexer, n: int) =
  for _ in 0 ..< n:
    self.step()

func one(self: Lexer): Option[(int, Rune)] =
  ## Access the one character, or set it if it is not set.
  self.char0

func two(self: Lexer): Option[(int, Rune, Rune)] =
  ## Access two characters.
  if self.char0.isSome and self.char1.isSome:
    some((self.char0.get[0], self.char0.get[1], self.char1.get[1]))
  else:
    none((int, Rune, Rune))

func isAsciiAlphanumeric(character: Rune): bool =
  let c = character.int32
  (c >= ord('0') and c <= ord('9')) or (c >= ord('A') and c <= ord('Z')) or
    (c >= ord('a') and c <= ord('z'))

func isSpace(character: Rune): bool =
  let c = character.int32
  c == ord(' ') or c == ord('\t') or c == ord('\n') or c == ord('\r')

template scanWhile(self: var Lexer, start: int, matches: untyped): int =
  ## Steps while the next character matches; the byte offset where it stopped.
  var stop = start
  while true:
    let next = self.one()
    if next.isSome:
      stop = next.get[0]
      if matches(next.get[1]):
        self.step()
        continue
    else:
      stop = self.input.len
    break
  stop

func parseU32(input: string): Option[uint32] =
  ## Rust's `input.parse::<u32>()`, for a string of ASCII letters and digits:
  ## none when there is a letter, or when the number does not fit.
  var value = 0'u64
  if input.len == 0:
    return none(uint32)
  for c in input:
    if c notin {'0' .. '9'}:
      return none(uint32)
    value = value * 10 + uint64(ord(c) - ord('0'))
    if value > uint64(high(uint32)):
      return none(uint32)
  some(uint32(value))

func component(self: var Lexer, start: int): Token =
  ## Consume a component.
  ##
  ## A component can either be an alphanumeric or numeric.
  ## Does not permit leading zeroes.
  let stop = scanWhile(self, start, isAsciiAlphanumeric)
  let input = self.input[start ..< stop]

  # Exactly zero
  if input == "0":
    return Token(kind: vtNumeric, vNumeric: 0)

  let number = parseU32(input)
  if number.isSome:
    # Only parse as a number if there is no leading zero
    if input[0] != '0':
      return Token(kind: vtNumeric, vNumeric: number.get)
    else:
      return Token(kind: vtLeadingZero, vLeadingZero: input)

  Token(kind: vtAlphaNumeric, vAlphaNumeric: input)

func andToken(self: var Lexer, start: int): Token =
  let next = self.one()
  if next.isSome and next.get[1] == Rune('d'):
    self.step()
    tok(vtAnd)
  else:
    self.component(start)

func whitespace(self: var Lexer, start: int): Token =
  ## Consume whitespace.
  let stop = scanWhile(self, start, isSpace)
  Token(kind: vtWhitespace, vWhitespace: (start, stop))

proc next*(self: var Lexer): Option[Token] =
  ## The next token, or none at the end of the input. Raises a
  ## `LexerException` at a character that starts no token; as upstream, the
  ## lexer does not move past it, so asking again raises again.
  # Two subsequent char tokens.
  let pair = self.two()
  if pair.isSome:
    let (start, char0, char1) = pair.get
    var doubleCharacterToken = none(Token)
    if char0.int32 < 128 and char1.int32 < 128:
      let both = (char(char0.int32), char(char1.int32))
      if both == ('~', '>'): doubleCharacterToken = some(tok(vtPessimistic))
      elif both == ('!', '='): doubleCharacterToken = some(tok(vtNotEq))
      elif both == ('<', '='): doubleCharacterToken = some(tok(vtLtEq))
      elif both == ('>', '='): doubleCharacterToken = some(tok(vtGtEq))
      elif both == ('=', '='): doubleCharacterToken = some(tok(vtEq))
      elif both == ('o', 'r'): doubleCharacterToken = some(tok(vtOr))
      elif both == ('a', 'n'):
        self.stepN(2)
        return some(self.andToken(start))

    if doubleCharacterToken.isSome:
      self.stepN(2)
      return doubleCharacterToken

  # Single char and start of numeric tokens.
  let single = self.one()
  if single.isSome:
    let (start, char2) = single.get
    var token: Token
    if isSpace(char2):
      self.step()
      return some(self.whitespace(start))
    elif char2 == Rune('>'): token = tok(vtGt)
    elif char2 == Rune('<'): token = tok(vtLt)
    elif char2 == Rune('.'): token = tok(vtDot)
    elif char2 == Rune('-'): token = tok(vtHyphen)
    elif char2 == Rune('+'): token = tok(vtPlus)
    elif isAsciiAlphanumeric(char2):
      self.step()
      return some(self.component(start))
    else:
      var exception = newException(LexerException, "Unexpected character " & $char2)
      exception.error = Error(kind: leUnexpectedCharacter, vUnexpectedCharacter: char2)
      raise exception

    self.step()
    return some(token)

  none(Token)
