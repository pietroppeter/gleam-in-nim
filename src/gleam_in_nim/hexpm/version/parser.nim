## port-of: hexpm/src/version/parser.rs
## port-status: draft
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version/parser.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/parser.rs
#
# Based off of https://github.com/steveklabnik/semver-parser/blob/bee9de80aaa9653c5eb46a83658606cb21151e65/src/parser.rs
#
# In the port: this file is not a module. Upstream's parser and its parent
# module use each other (the parser builds a `Version`, `Version::parse` runs
# the parser), which Nim modules cannot do, so `../version.nim` includes this
# file after it has declared `Version` and `Identifier`. Import that one.

type
  ErrorKind* = enum
    ekUnexpectedEnd ## Needed more tokens for parsing, but none are available.
    ekUnexpectedToken ## Unexpected token.
    ekLexer ## An error occurred in the lexer.
    ekMoreInput ## More input available.
    ekEmptyPredicate ## Encountered empty predicate in a set of predicates.
    ekEmptyRange ## Encountered an empty range.
    ekMinorVersionMissing ## Encountered a semver that's missing the minor and patch version.
    ekPatchVersionMissing ## Encountered a semver that's missing the patch version.

  Error* = object
    case kind*: ErrorKind
    of ekUnexpectedEnd, ekEmptyPredicate, ekEmptyRange:
      discard
    of ekUnexpectedToken:
      vUnexpectedToken*: string
    of ekLexer:
      vLexer*: lexer.Error
    of ekMoreInput:
      vMoreInput*: string
    of ekMinorVersionMissing:
      vMinorVersionMissing*: uint32
    of ekPatchVersionMissing:
      vPatchVersionMissing*: (uint32, uint32)

  ParserException* = object of CatchableError
    ## How an error travels inside the port, where the Rust has `?`. Nothing
    ## outside this module sees one: `parse` and `newRange` return the error.
    error*: Error

  Parser* = object
    ## A recursive-descent parser for parsing version requirements.
    lexer: Lexer ## Source of token.
    token0: Option[Token] ## Lookaehead.

func `==`*(left, right: Error): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of ekUnexpectedEnd, ekEmptyPredicate, ekEmptyRange: true
  of ekUnexpectedToken: left.vUnexpectedToken == right.vUnexpectedToken
  of ekLexer: left.vLexer == right.vLexer
  of ekMoreInput: left.vMoreInput == right.vMoreInput
  of ekMinorVersionMissing: left.vMinorVersionMissing == right.vMinorVersionMissing
  of ekPatchVersionMissing: left.vPatchVersionMissing == right.vPatchVersionMissing

func `$`*(self: Error): string =
  case self.kind
  of ekUnexpectedEnd: "expected more input"
  of ekUnexpectedToken: "encountered unexpected token: " & debugStr(self.vUnexpectedToken)
  of ekLexer: "lexer error: " & debug(self.vLexer)
  of ekMoreInput: "expected end of input, but got: " & debugStr(self.vMoreInput)
  of ekEmptyPredicate: "encountered empty predicate"
  of ekEmptyRange: "encountered empty range"
  of ekMinorVersionMissing: "missing minor and patch versions: " & $self.vMinorVersionMissing
  of ekPatchVersionMissing: "missing patch version: " & $self.vPatchVersionMissing[0] & "." & $self.vPatchVersionMissing[1]

proc fail(error: Error) {.noreturn.} =
  var exception = newException(ParserException, $error)
  exception.error = error
  raise exception

func unexpectedToken(token: Token): Error =
  Error(kind: ekUnexpectedToken, vUnexpectedToken: $token)

proc nextToken(lexer: var Lexer): Option[Token] =
  ## `lexer.next()` followed by `?`: a lexer error becomes a parser error.
  try:
    result = lexer.next()
  except LexerException as exception:
    fail Error(kind: ekLexer, vLexer: exception.error)

proc initParser*(input: string): Parser =
  ## Construct a new parser for the given input.
  var lexer = initLexer(input)

  let token0 = lexer.nextToken()

  Parser(lexer: lexer, token0: token0)

proc pop(self: var Parser): Token =
  ## Pop one token.
  let token0 = self.lexer.nextToken()

  let popped = self.token0
  self.token0 = token0
  if popped.isNone:
    fail Error(kind: ekUnexpectedEnd)
  popped.get

func peek(self: Parser): Option[Token] =
  ## Peek one token.
  self.token0

func peekIs(self: Parser, kind: TokenKind): bool =
  self.token0.isSome and self.token0.get.kind == kind

proc skipWhitespace(self: var Parser) =
  ## Skip whitespace if present.
  if self.peekIs(vtWhitespace):
    discard self.pop()

proc expectWhitespace(self: var Parser) =
  ## Check that some whitespace is next and then discard it
  let token = self.pop()
  if token.kind != vtWhitespace:
    fail unexpectedToken(token)

proc numeric*(self: var Parser): uint32 =
  ## Parse a single numeric.
  let token = self.pop()
  if token.kind == vtNumeric:
    token.vNumeric
  else:
    fail unexpectedToken(token)

proc dot(self: var Parser) =
  let token = self.pop()
  if token.kind != vtDot:
    fail unexpectedToken(token)

proc dotNumeric(self: var Parser): uint32 =
  ## Parse a dot, then a numeric.
  self.dot()
  self.numeric()

proc identifier*(self: var Parser): Identifier =
  ## Parse an string identifier.
  ##
  ## Like, `wibble`, or `wobble`, or `beta-1`.
  let token = self.pop()
  let identifier =
    case token.kind
    of vtAlphaNumeric: alphaNumeric(token.vAlphaNumeric)
    of vtNumeric: numeric(token.vNumeric)
    of vtEq, vtNotEq, vtGt, vtLt, vtLtEq, vtGtEq, vtPessimistic, vtDot, vtHyphen, vtPlus, vtOr,
        vtAnd, vtWhitespace, vtLeadingZero:
      fail unexpectedToken(token)

  if self.peekIs(vtHyphen):
    # Pop the peeked hyphen
    discard self.pop()
    # Concat with any following identifiers
    identifier.concat("-").concat($self.identifier())
  else:
    identifier

proc parts(self: var Parser): seq[Identifier] =
  ## Parse a dot-separated set of identifiers.
  var parts: seq[Identifier] = @[]

  parts.add self.identifier()

  while self.peekIs(vtDot):
    discard self.pop()

    parts.add self.identifier()

  parts

proc pre(self: var Parser): seq[Identifier] =
  ## Parse all pre-release identifiers, separated by dots.
  ##
  ## Like, `abcdef.1234`.
  if not self.peekIs(vtHyphen):
    return @[]

  # Pop the peeked hyphen.
  discard self.pop()
  self.parts()

proc plusBuildMetadata(self: var Parser): Option[string] =
  ## Parse optional build metadata.
  ##
  ## Like, `` (empty), or `+abcdef`.
  if self.peekIs(vtPlus):
    discard self.pop()
  else:
    return none(string)

  var buffer = ""

  while true:
    var token: Token
    try:
      token = self.pop()
    except ParserException as exception:
      if exception.error.kind == ekUnexpectedEnd:
        break
      raise
    case token.kind
    of vtLeadingZero: buffer.add token.vLeadingZero
    of vtAlphaNumeric: buffer.add token.vAlphaNumeric
    of vtNumeric: buffer.add $token.vNumeric
    of vtDot: buffer.add '.'
    of vtEq, vtNotEq, vtGt, vtLt, vtLtEq, vtGtEq, vtPessimistic, vtHyphen, vtPlus, vtOr, vtAnd,
        vtWhitespace:
      fail unexpectedToken(token)

  if buffer.len == 0:
    fail Error(kind: ekUnexpectedEnd)
  else:
    some(buffer)

proc version*(self: var Parser): Version =
  ## Parse a version.
  ##
  ## Like, `1.0.0` or `3.0.0-beta.1`.
  self.skipWhitespace()

  let major = self.numeric()
  var minor: uint32
  try:
    minor = self.dotNumeric()
  except ParserException:
    fail Error(kind: ekMinorVersionMissing, vMinorVersionMissing: major)
  var patch: uint32
  try:
    patch = self.dotNumeric()
  except ParserException:
    fail Error(kind: ekPatchVersionMissing, vPatchVersionMissing: (major, minor))
  let pre = self.pre()
  let build = self.plusBuildMetadata()

  self.skipWhitespace()

  Version(major: major, minor: minor, patch: patch, pre: pre, build: build)

proc pessimisticVersionConstraint(self: var Parser): PubgrubRange =
  var includedPatch = false
  let major = self.numeric()
  let minor = self.dotNumeric()
  let patch =
    if self.peekIs(vtDot):
      includedPatch = true
      discard self.pop()
      self.numeric()
    else:
      0'u32
  let pre = self.pre()
  let build = self.plusBuildMetadata()

  let lower = Version(major: major, minor: minor, patch: patch, pre: pre, build: build)
  let upper =
    if includedPatch:
      lower.bumpMinor()
    else:
      lower.bumpMajor()
  higherThan(lower).intersection(strictlyLowerThan(upper))

proc rangeAndsSection(self: var Parser): PubgrubRange =
  var range = none(PubgrubRange)
  proc `and`(range: Option[PubgrubRange], constraint: PubgrubRange): Option[PubgrubRange] =
    some(
      if range.isNone: constraint
      else: range.get.intersection(constraint)
    )
  while true:
    self.skipWhitespace()
    let peeked = self.peek()
    if peeked.isNone:
      break
    case peeked.get.kind
    of vtNumeric:
      range = `and`(range, singleton(self.version()))

    of vtEq:
      discard self.pop()
      range = `and`(range, singleton(self.version()))

    of vtNotEq:
      discard self.pop()
      let version = self.version()
      let bumped = version.bumpPatch()
      let below = strictlyLowerThan(version)
      let above = higherThan(bumped)
      range = `and`(range, below.union(above))

    of vtGt:
      discard self.pop()
      range = `and`(range, higherThan(self.version().bumpPatch()))

    of vtGtEq:
      discard self.pop()
      range = `and`(range, higherThan(self.version()))

    of vtLt:
      discard self.pop()
      range = `and`(range, strictlyLowerThan(self.version()))

    of vtLtEq:
      discard self.pop()
      range = `and`(range, strictlyLowerThan(self.version().bumpPatch()))

    of vtPessimistic:
      discard self.pop()
      self.skipWhitespace()
      range = `and`(range, self.pessimisticVersionConstraint())

    of vtDot, vtHyphen, vtPlus, vtOr, vtAnd, vtWhitespace, vtAlphaNumeric, vtLeadingZero:
      fail unexpectedToken(self.pop())

    self.skipWhitespace()
    if self.peekIs(vtAnd):
      discard self.pop()
      self.expectWhitespace()
    else:
      break
  self.skipWhitespace()
  if range.isNone:
    fail Error(kind: ekUnexpectedEnd)
  range.get

proc range*(self: var Parser): PubgrubRange =
  ## Parse a version range requirement.
  ##
  ## Like, `~> 1.0.0` or `3.0.0-beta.1 or < 1.0 and > 0.2.3`.
  var range = none(PubgrubRange)

  while true:
    let constraint = self.rangeAndsSection()
    range = some(
      if range.isNone: constraint
      else: range.get.union(constraint)
    )
    if self.peekIs(vtOr):
      discard self.pop()
      self.expectWhitespace()
    else:
      break

  self.skipWhitespace()
  if range.isNone:
    fail Error(kind: ekUnexpectedEnd)
  range.get

func isEof*(self: Parser): bool =
  ## Check if we have reached the end of input.
  self.token0.isNone

proc tail*(self: var Parser): seq[Token] =
  ## Get the rest of the tokens in the parser.
  ##
  ## Useful for debugging.
  var output: seq[Token] = @[]

  if self.token0.isSome:
    output.add self.token0.get
    self.token0 = none(Token)

  while true:
    let token = self.lexer.nextToken()
    if token.isNone:
      break
    output.add token.get

  output
