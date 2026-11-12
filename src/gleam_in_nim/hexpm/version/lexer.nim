## port-of: hexpm/src/version/lexer.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version/lexer.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/lexer.rs
#
# This file is included by ../version.nim, not imported: upstream `lexer` is a private
# submodule of `version`, and the two refer to each other.

## Lexer for semver ranges.
##
## Breaks a string of input into an iterator of tokens that can be used with a parser.
##
## Based off https://github.com/steveklabnik/semver-parser/blob/bee9de80aaa9653c5eb46a83658606cb21151e65/src/lexer.rs

type
  TokenKind = enum
    ## Semver tokens.
    tkEq            ## `==`
    tkNotEq         ## `!=`
    tkGt            ## `>`
    tkLt            ## `<`
    tkLtEq          ## `<=`
    tkGtEq          ## `>=`
    tkPessimistic   ## `~>`
    tkDot           ## `.`
    tkHyphen        ## `-`
    tkPlus          ## `+`
    tkOr            ## 'or'
    tkAnd           ## 'and'
    tkWhitespace    ## Any number of whitespace (`\t\r\n `) and its span.
    tkNumeric       ## Numeric component, like `0` or `42`.
    tkAlphaNumeric  ## Alphanumeric component, like `alpha1` or `79deadbe`.
    tkLeadingZero   ## An alphanumeric component with a leading zero, like `0alpha1` or `079deadbe`.

  Token = object
    case kind: TokenKind
    of tkWhitespace:
      start, stop: int
    of tkNumeric:
      number: uint32
    of tkAlphaNumeric, tkLeadingZero:
      text: string
    of tkEq, tkNotEq, tkGt, tkLt, tkLtEq, tkGtEq, tkPessimistic, tkDot, tkHyphen, tkPlus, tkOr, tkAnd:
      discard

  LexerErrorKind* = enum
    leUnexpectedCharacter
  LexerError* = object
    ## upstream: `lexer::Error`
    kind*: LexerErrorKind
    character*: Rune

  IndexedChar = tuple[index: int, character: Rune]

  Lexer = object
    ## Lexer for semver tokens belonging to a range.
    input: string
    chars: int   ## the byte offset of the next character `chars.next()` would give
    # Lookahead
    char0: Option[IndexedChar]
    char1: Option[IndexedChar]

  LexerFailure = object of CatchableError
    ## How a `lexer::Error` travels inside this module: raised where upstream returns `Err`,
    ## caught by the parser, which turns it into its own error as upstream's `?` does.
    error: LexerError

template raiseLexer(e: LexerError) =
  raise (ref LexerFailure)(msg: "version lexer error", error: e)

proc `==`(a, b: Token): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tkWhitespace: a.start == b.start and a.stop == b.stop
  of tkNumeric: a.number == b.number
  of tkAlphaNumeric, tkLeadingZero: a.text == b.text
  of tkEq, tkNotEq, tkGt, tkLt, tkLtEq, tkGtEq, tkPessimistic, tkDot, tkHyphen, tkPlus, tkOr, tkAnd: true

proc isWhitespace(self: Token): bool =
  ## Check if the current token is a whitespace token.
  self.kind == tkWhitespace

proc `$`(self: Token): string =
  case self.kind
  of tkEq: "=="
  of tkNotEq: "!="
  of tkGt: ">"
  of tkLt: "<"
  of tkLtEq: "<="
  of tkGtEq: ">="
  of tkPessimistic: "~>"
  of tkDot: "."
  of tkHyphen: "-"
  of tkPlus: "+"
  of tkOr: "or"
  of tkAnd: "and"
  of tkWhitespace: " "
  of tkNumeric: $self.number
  of tkAlphaNumeric: self.text
  of tkLeadingZero: self.text

proc `$`*(self: LexerError): string =
  case self.kind
  of leUnexpectedCharacter: "Unexpected character " & $self.character

proc nextChar(self: var Lexer): Option[IndexedChar] =
  ## `self.chars.next()` of a `str::CharIndices`.
  if self.chars >= self.input.len: return none(IndexedChar)
  let index = self.chars
  var character: Rune
  fastRuneAt(self.input, self.chars, character, true)
  some((index, character))

proc newLexer(input: string): Lexer =
  ## Construct a new lexer for the given input.
  result = Lexer(input: input, chars: 0)
  result.char0 = result.nextChar()
  result.char1 = result.nextChar()

proc step(self: var Lexer) =
  ## Shift all lookahead storage by one.
  self.char0 = self.char1
  self.char1 = self.nextChar()

proc stepN(self: var Lexer, n: int) =
  for _ in 0 ..< n:
    self.step()

proc one(self: var Lexer): Option[IndexedChar] =
  ## Access the one character, or set it if it is not set.
  self.char0

proc two(self: var Lexer): Option[tuple[start: int, char0, char1: Rune]] =
  ## Access two characters.
  if self.char0.isSome and self.char1.isSome:
    return some((self.char0.get.index, self.char0.get.character, self.char1.get.character))

template scanWhile(self: var Lexer, start: int, matches: untyped): int =
  ## upstream: the macro `scan_while!`. `matches` is an expression over `character`.
  var stop = start
  while true:
    let current = self.one()
    if current.isSome:
      stop = current.get.index
      let character {.inject.} = current.get.character
      if matches:
        self.step()
        continue
    else:
      stop = self.input.len
    break
  stop

proc isAsciiAlphaNumeric(character: Rune): bool =
  let c = character.int32
  (c >= ord('0') and c <= ord('9')) or (c >= ord('A') and c <= ord('Z')) or (c >= ord('a') and c <= ord('z'))

proc isSpace(character: Rune): bool =
  character.int32 in [ord(' ').int32, ord('\t').int32, ord('\n').int32, ord('\r').int32]

proc parseU32(input: string): Option[uint32] =
  ## `input.parse::<u32>()`: digits only (a leading `+` cannot reach here), and it must fit.
  if input.len == 0: return none(uint32)
  var number = 0'u64
  for c in input:
    if c notin {'0'..'9'}: return none(uint32)
    number = number * 10 + uint64(ord(c) - ord('0'))
    if number > uint64(high(uint32)): return none(uint32)
  some(uint32(number))

proc component(self: var Lexer, start: int): Token =
  ## Consume a component.
  ##
  ## A component can either be an alphanumeric or numeric.
  ## Does not permit leading zeroes.
  let stop = scanWhile(self, start, isAsciiAlphaNumeric(character))
  let input = self.input[start ..< stop]

  # Exactly zero
  if input == "0":
    return Token(kind: tkNumeric, number: 0)

  let number = parseU32(input)
  if number.isSome:
    # Only parse as a number if there is no leading zero
    if input[0] != '0':
      return Token(kind: tkNumeric, number: number.get)
    else:
      return Token(kind: tkLeadingZero, text: input)

  Token(kind: tkAlphaNumeric, text: input)

proc andToken(self: var Lexer, start: int): Token =
  ## upstream: `and`, a Nim keyword
  let current = self.one()
  if current.isSome and current.get.character == Rune('d'):
    self.step()
    Token(kind: tkAnd)
  else:
    self.component(start)

proc whitespace(self: var Lexer, start: int): Token =
  ## Consume whitespace.
  let stop = scanWhile(self, start, isSpace(character))
  Token(kind: tkWhitespace, start: start, stop: stop)

proc next(self: var Lexer): Option[Token] =
  ## upstream: `Iterator::next`, which gives `Option<Result<Token, Error>>`. Here the error is
  ## raised as a `LexerFailure`: see the note on errors in ../version.nim.
  # Two subsequent char tokens.
  let pair = self.two()
  if pair.isSome:
    let (start, char0, char1) = pair.get
    var doubleCharacterToken = none(Token)
    if char0.int32 < 128 and char1.int32 < 128:
      case $char(char0.int32) & $char(char1.int32)
      of "~>": doubleCharacterToken = some(Token(kind: tkPessimistic))
      of "!=": doubleCharacterToken = some(Token(kind: tkNotEq))
      of "<=": doubleCharacterToken = some(Token(kind: tkLtEq))
      of ">=": doubleCharacterToken = some(Token(kind: tkGtEq))
      of "==": doubleCharacterToken = some(Token(kind: tkEq))
      of "or": doubleCharacterToken = some(Token(kind: tkOr))
      of "an":
        self.stepN(2)
        return some(self.andToken(start))
      else: discard

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
    elif char2 == Rune('>'): token = Token(kind: tkGt)
    elif char2 == Rune('<'): token = Token(kind: tkLt)
    elif char2 == Rune('.'): token = Token(kind: tkDot)
    elif char2 == Rune('-'): token = Token(kind: tkHyphen)
    elif char2 == Rune('+'): token = Token(kind: tkPlus)
    elif isAsciiAlphaNumeric(char2):
      self.step()
      return some(self.component(start))
    else:
      raiseLexer LexerError(kind: leUnexpectedCharacter, character: char2)

    self.step()
    return some(token)

  none(Token)
