## port-of: hexpm/src/version/parser.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version/parser.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/parser.rs
#
# This file is included by ../version.nim, not imported: upstream `parser` is a private
# submodule of `version`, and the two refer to each other.

# Based off of https://github.com/steveklabnik/semver-parser/blob/bee9de80aaa9653c5eb46a83658606cb21151e65/src/parser.rs

type
  PubgrubRange* = Ranges[Version]

  ParserErrorKind* = enum
    peUnexpectedEnd          ## Needed more tokens for parsing, but none are available.
    peUnexpectedToken        ## Unexpected token.
    peLexer                  ## An error occurred in the lexer.
    peMoreInput              ## More input available.
    peEmptyPredicate         ## Encountered empty predicate in a set of predicates.
    peEmptyRange             ## Encountered an empty range.
    peMinorVersionMissing    ## Encountered a semver that's missing the minor and patch version.
    pePatchVersionMissing    ## Encountered a semver that's missing the patch version.

  ParserError* = object
    ## upstream: `parser::Error`
    case kind*: ParserErrorKind
    of peUnexpectedToken:
      token*: string
    of peLexer:
      lexer*: LexerError
    of peMoreInput:
      tokens*: string
    of peMinorVersionMissing, pePatchVersionMissing:
      major*: uint32
      minor*: uint32   ## only for `pePatchVersionMissing`
    of peUnexpectedEnd, peEmptyPredicate, peEmptyRange:
      discard

  ParserFailure = object of CatchableError
    ## How a `parser::Error` travels inside this module. Nothing outside sees it: the public
    ## procs of ../version.nim catch it and return a `ParseResult`.
    error: ParserError

  Parser = object
    ## A recursive-descent parser for parsing version requirements.
    lexer: Lexer            ## Source of token.
    token0: Option[Token]   ## Lookaehead.

proc `==`*(a, b: ParserError): bool =
  if a.kind != b.kind: return false
  case a.kind
  of peUnexpectedToken: a.token == b.token
  of peLexer: a.lexer == b.lexer
  of peMoreInput: a.tokens == b.tokens
  of peMinorVersionMissing: a.major == b.major
  of pePatchVersionMissing: a.major == b.major and a.minor == b.minor
  of peUnexpectedEnd, peEmptyPredicate, peEmptyRange: true

template fail(e: ParserError) =
  raise (ref ParserFailure)(msg: "version parser error", error: e)

proc unexpectedToken(token: Token): ParserError =
  ParserError(kind: peUnexpectedToken, token: $token)

proc debugEscape(character: Rune, quote: char): string =
  ## One character as Rust's `{:?}` writes it inside a string (`quote` is `"`) or a char
  ## (`quote` is `'`). Rust also escapes characters Unicode calls non-printable; here only
  ## the control characters are, which is exact for everything the lexer lets through
  ## except exotic characters in an `UnexpectedCharacter` error.
  let c = character.int32
  if c == ord('\t'): "\\t"
  elif c == ord('\r'): "\\r"
  elif c == ord('\n'): "\\n"
  elif c == ord('\\'): "\\\\"
  elif c == 0: "\\0"
  elif c == ord(quote): "\\" & $quote
  elif c < 0x20 or (c >= 0x7f and c <= 0x9f): "\\u{" & toHex(c).strip(chars = {'0'}, trailing = false).toLowerAscii & "}"
  else: $character

proc debugString(text: string): string =
  ## `format!("{text:?}")`
  result = "\""
  for character in text.runes: result.add debugEscape(character, '"')
  result.add "\""

proc debugChar(character: Rune): string =
  ## `format!("{character:?}")`
  "'" & debugEscape(character, '\'') & "'"

proc `$`*(self: ParserError): string =
  case self.kind
  of peUnexpectedEnd: "expected more input"
  of peUnexpectedToken: "encountered unexpected token: " & debugString(self.token)
  of peLexer:
    case self.lexer.kind
    of leUnexpectedCharacter: "lexer error: UnexpectedCharacter(" & debugChar(self.lexer.character) & ")"
  of peMoreInput: "expected end of input, but got: " & debugString(self.tokens)
  of peEmptyPredicate: "encountered empty predicate"
  of peEmptyRange: "encountered empty range"
  of peMinorVersionMissing: "missing minor and patch versions: " & $self.major
  of pePatchVersionMissing: "missing patch version: " & $self.major & "." & $self.minor

proc lexNext(self: var Parser): Option[Token] =
  ## `self.lexer.next()` followed by `?`: a lexer error becomes a parser error.
  try:
    self.lexer.next()
  except LexerFailure as failure:
    fail ParserError(kind: peLexer, lexer: failure.error)

proc newParser(input: string): Parser =
  ## Construct a new parser for the given input.
  result = Parser(lexer: newLexer(input))
  result.token0 = result.lexNext()

proc pop(self: var Parser): Token =
  ## Pop one token.
  let token0 = self.lexNext()
  let previous = self.token0
  self.token0 = token0
  if previous.isNone: fail ParserError(kind: peUnexpectedEnd)
  previous.get

proc peek(self: var Parser): Option[Token] =
  ## Peek one token.
  self.token0

proc peekIs(self: var Parser, kind: TokenKind): bool =
  ## `self.peek() == Some(&Token::X)` for a token without data
  self.token0.isSome and self.token0.get.kind == kind

proc skipWhitespace(self: var Parser) =
  ## Skip whitespace if present.
  if self.peekIs(tkWhitespace): discard self.pop()

proc expectWhitespace(self: var Parser) =
  ## Check that some whitespace is next and then discard it
  let token = self.pop()
  if token.kind != tkWhitespace: fail unexpectedToken(token)

proc numeric(self: var Parser): uint32 =
  ## Parse a single numeric.
  let token = self.pop()
  if token.kind == tkNumeric: token.number
  else: fail unexpectedToken(token)

proc dot(self: var Parser) =
  let token = self.pop()
  if token.kind != tkDot: fail unexpectedToken(token)

proc dotNumeric(self: var Parser): uint32 =
  ## Parse a dot, then a numeric.
  self.dot()
  self.numeric()

proc identifier(self: var Parser): Identifier =
  ## Parse an string identifier.
  ##
  ## Like, `wibble`, or `wobble`, or `beta-1`.
  let token = self.pop()
  let identifier =
    case token.kind
    of tkAlphaNumeric: Identifier(kind: ikAlphaNumeric, text: token.text)
    of tkNumeric: Identifier(kind: ikNumeric, number: token.number)
    else: fail unexpectedToken(token)

  if self.peekIs(tkHyphen):
    # Pop the peeked hyphen
    discard self.pop()
    # Concat with any following identifiers
    identifier.concat("-").concat($self.identifier())
  else:
    identifier

proc parts(self: var Parser): seq[Identifier] =
  ## Parse a dot-separated set of identifiers.
  result.add self.identifier()

  while self.peekIs(tkDot):
    discard self.pop()

    result.add self.identifier()

proc pre(self: var Parser): seq[Identifier] =
  ## Parse all pre-release identifiers, separated by dots.
  ##
  ## Like, `abcdef.1234`.
  if not self.peekIs(tkHyphen): return @[]

  # Pop the peeked hyphen.
  discard self.pop()
  self.parts()

proc plusBuildMetadata(self: var Parser): Option[string] =
  ## Parse optional build metadata.
  ##
  ## Like, `` (empty), or `+abcdef`.
  if self.peekIs(tkPlus): discard self.pop()
  else: return none(string)

  var buffer = ""

  while true:
    var token: Token
    try:
      token = self.pop()
    except ParserFailure as failure:
      if failure.error.kind == peUnexpectedEnd: break
      raise
    case token.kind
    of tkLeadingZero: buffer.add token.text
    of tkAlphaNumeric: buffer.add token.text
    of tkNumeric: buffer.add $token.number
    of tkDot: buffer.add '.'
    else: fail unexpectedToken(token)

  if buffer.len == 0:
    fail ParserError(kind: peUnexpectedEnd)
  else:
    some(buffer)

proc version(self: var Parser): Version =
  ## Parse a version.
  ##
  ## Like, `1.0.0` or `3.0.0-beta.1`.
  self.skipWhitespace()

  let major = self.numeric()
  let minor =
    try: self.dotNumeric()
    except ParserFailure: fail ParserError(kind: peMinorVersionMissing, major: major)
  let patch =
    try: self.dotNumeric()
    except ParserFailure: fail ParserError(kind: pePatchVersionMissing, major: major, minor: minor)
  let pre = self.pre()
  let build = self.plusBuildMetadata()

  self.skipWhitespace()

  Version(major: major, minor: minor, patch: patch, pre: pre, build: build)

proc pessimisticVersionConstraint(self: var Parser): PubgrubRange =
  var includedPatch = false
  let major = self.numeric()
  let minor = self.dotNumeric()
  let patch =
    if self.peekIs(tkDot):
      includedPatch = true
      discard self.pop()
      self.numeric()
    else:
      0'u32
  let pre = self.pre()
  let build = self.plusBuildMetadata()

  let lower = Version(major: major, minor: minor, patch: patch, pre: pre, build: build)
  let upper =
    if includedPatch: lower.bumpMinor()
    else: lower.bumpMajor()
  higherThan(lower).intersection(strictlyLowerThan(upper))

proc rangeAndsSection(self: var Parser): PubgrubRange =
  var range = none(PubgrubRange)
  proc andRange(range: Option[PubgrubRange], constraint: PubgrubRange): Option[PubgrubRange] =
    ## upstream: the closure `and`
    if range.isNone: some(constraint)
    else: some(range.get.intersection(constraint))
  while true:
    self.skipWhitespace()
    let peeked = self.peek()
    if peeked.isNone: break
    case peeked.get.kind
    of tkNumeric: range = andRange(range, singleton(self.version()))

    of tkEq:
      discard self.pop()
      range = andRange(range, singleton(self.version()))

    of tkNotEq:
      discard self.pop()
      let version = self.version()
      let bumped = version.bumpPatch()
      let below = strictlyLowerThan(version)
      let above = higherThan(bumped)
      range = andRange(range, below.union(above))

    of tkGt:
      discard self.pop()
      range = andRange(range, higherThan(self.version().bumpPatch()))

    of tkGtEq:
      discard self.pop()
      range = andRange(range, higherThan(self.version()))

    of tkLt:
      discard self.pop()
      range = andRange(range, strictlyLowerThan(self.version()))

    of tkLtEq:
      discard self.pop()
      range = andRange(range, strictlyLowerThan(self.version().bumpPatch()))

    of tkPessimistic:
      discard self.pop()
      self.skipWhitespace()
      range = andRange(range, self.pessimisticVersionConstraint())

    of tkDot, tkHyphen, tkPlus, tkOr, tkAnd, tkWhitespace, tkAlphaNumeric, tkLeadingZero:
      fail unexpectedToken(self.pop())

    self.skipWhitespace()
    if self.peekIs(tkAnd):
      discard self.pop()
      self.expectWhitespace()
    else:
      break
  self.skipWhitespace()
  if range.isNone: fail ParserError(kind: peUnexpectedEnd)
  range.get

proc range(self: var Parser): PubgrubRange =
  ## Parse a version range requirement.
  ##
  ## Like, `~> 1.0.0` or `3.0.0-beta.1 or < 1.0 and > 0.2.3`.
  var range = none(PubgrubRange)

  while true:
    let constraint = self.rangeAndsSection()
    range = some(if range.isNone: constraint else: range.get.union(constraint))
    if self.peekIs(tkOr):
      discard self.pop()
      self.expectWhitespace()
    else:
      break

  self.skipWhitespace()
  if range.isNone: fail ParserError(kind: peUnexpectedEnd)
  range.get

proc isEof(self: var Parser): bool =
  ## Check if we have reached the end of input.
  self.token0.isNone

proc tail(self: var Parser): seq[Token] =
  ## Get the rest of the tokens in the parser.
  ##
  ## Useful for debugging.
  if self.token0.isSome:
    result.add self.token0.get
    self.token0 = none(Token)

  while true:
    let token = self.lexNext()
    if token.isNone: break
    result.add token.get
