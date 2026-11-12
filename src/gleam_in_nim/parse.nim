## port-part-of: compiler-core/src/parse.rs
## (the rest of that file, the values of number literals, is in parse/literals.nim)
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse.rs.

## The parser: from the tokens of the lexer to the untyped syntax tree.
##
## Gleam's parser is written by hand. It is a recursive descent parser (one
## procedure per piece of grammar, calling each other) with two tokens of
## lookahead (`token0` and `token1`), and a small operator precedence parser
## for binary operators.
##
## How to read this file next to the Rust one:
##
## - Procedures are in upstream order, with upstream names in camelCase.
## - `Result<T, ParseError>`: the procedure returns `T` and raises
##   `ParseFailure` for the error. Rust's `?` is then nothing at all, and where
##   Rust looks at a `Result` there is a `try`. Only the three public entry
##   points turn the exception into a value (`ParseResult`).
## - `Result<Option<T>, ParseError>`: the procedure returns `Option[T]`. `None`
##   means "this is not here, and nothing was consumed": the caller decides
##   whether that is an error.
## - `match self.token0.take() { ... }`: Rust takes the token out of the parser
##   and leaves `None` there; the arms that do not want it put it back. This is
##   kept to the letter (`take`, and `p.token0 = t0` in the `else`), because
##   what is left in `token0` after an error is visible: some errors are
##   swallowed and parsing goes on.
## - A Rust `match` on the token is a `case` on its kind. `tkNone` stands for
##   "no token" (`None`).

import std/[deques, options, sets, strutils]
import ./[ast, warning]
import ./error as core_error
import ./parse/[error, extra, lexer, token]

export error, extra, warning

type
  Parsed* = object
    module*: Module[Unit, seq[TargetedDefinition]] ## `UntypedModule`, spelled out for `debugRepr`
    extra*: ModuleExtra

  InternalAttributeKind = enum
    iaMissing
    iaPresent

  InternalAttribute = object
    ## We use this to keep track of the `@internal` annotation for top level
    ## definitions. Instead of using just a boolean we want to keep track of the
    ## source position of the annotation in case it is present. This way we can
    ## report a better error message highlighting the annotation in case it is
    ## used on a private definition (it doesn't make sense to mark something
    ## private as internal):
    ##
    ## ```txt
    ## @internal
    ## ^^^^^^^^^ we first get to the annotation
    ## fn wibble() {}
    ## ^^ and only later discover it's applied on a private definition
    ##    so we have to keep track of the attribute's position to highlight it
    ##    in the resulting error message.
    ## ```
    case kind: InternalAttributeKind
    of iaMissing: discard
    of iaPresent: vPresent: SrcSpan

  Attributes = object
    target: Option[Target]
    deprecated: Deprecation
    externalErlang: Option[(string, string, SrcSpan)]
    externalJavascript: Option[(string, string, SrcSpan)]
    internal: InternalAttribute

  ParseFailure* = object of CatchableError
    ## How a `ParseError` travels inside the parser: see the top of this file.
    error*: ParseError

  ParseResult*[T] = object
    ## Upstream `Result<T, ParseError>`, at the public entry points.
    case isOk*: bool
    of true: value*: T
    of false: error*: ParseError

  ParserWarnings* = object
    ## What the parser has to say about a module that parses. Upstream these
    ## go to a `WarningEmitter`, wrapped with the path and the source.
    deprecatedSyntax*: seq[DeprecatedSyntaxWarning]
    detachedDocComments*: seq[SrcSpan]

  Parser = object
    tokens: Lexer
    lexErrors: seq[LexicalError]
    warnings: seq[DeprecatedSyntaxWarning]
    token0: Option[Spanned]
    token1: Option[Spanned]
    extra: ModuleExtra
    docComments: Deque[(int, string)]
    detachedDocComments: seq[SrcSpan]

  ParserArgKind* = enum
    pgArg
    pgHole

  ParserArgHole* = object of StructVariant
    name*: string
    argLocation*: SrcSpan ## The whole span of the argument.
    discardLocation*: SrcSpan ## Just the span of the ignore name.
    label*: Option[string]

  ParserArg* = object
    ## Parsing a function call into the appropriate structure
    case kind*: ParserArgKind
    of pgArg: vArg*: ref CallArg[UntypedExpr]
    of pgHole: vHole*: ParserArgHole

  ExpressionUnitContext = enum
    FollowingPipe
    Other

  PatternPosition* = enum
    ppLetAssignment
    ppCaseClause
    ppUsePattern

  Operator = (Spanned, uint8) ## an operator token and its precedence

const tkNone = tkEndOfFile
  ## "No token": the kind given for `None`. The lexer never hands out
  ## `EndOfFile` (its iterator ends instead), so the value is free.

# ---------------------------------------------------------------------------
# Small helpers that Rust has built in
# ---------------------------------------------------------------------------

func take[T](option: var Option[T]): Option[T] =
  ## Rust's `Option::take`: the value, leaving `None` behind.
  result = move(option)
  option = none(T)

func kind(token: Option[Spanned]): TokenKind =
  if token.isSome: token.get.token.kind else: tkNone

func sp(start, stop: int): SrcSpan =
  initSrcSpan(start, stop)

func parseU64(text: string): Option[uint64] =
  ## Rust's `u64::from_str`: decimal digits, an optional `+`, no overflow.
  var i = 0
  if text.len > 0 and text[0] == '+':
    i = 1
  if i >= text.len:
    return none(uint64)
  var value = 0'u64
  while i < text.len:
    if text[i] notin {'0' .. '9'}:
      return none(uint64)
    let digit = uint64(ord(text[i]) - ord('0'))
    if value > (high(uint64) - digit) div 10:
      return none(uint64)
    value = value * 10 + digit
    inc i
  some(value)

func hasFunctionOnly(self: Attributes): bool =
  self.externalErlang.isSome or self.externalJavascript.isSome

func hasExternalFor(self: Attributes, target: Target): bool =
  case target
  of tgErlang: self.externalErlang.isSome
  of tgJavaScript: self.externalJavascript.isSome

func setExternalFor(self: var Attributes, target: Target, ext: Option[(string, string, SrcSpan)]) =
  case target
  of tgErlang: self.externalErlang = ext
  of tgJavaScript: self.externalJavascript = ext

func toDeclaration*(self: PatternPosition): VariableDeclaration =
  case self
  of ppLetAssignment: VariableDeclaration(kind: vdLetPattern)
  of ppCaseClause: VariableDeclaration(kind: vdClausePattern)
  of ppUsePattern: VariableDeclaration(kind: vdUsePattern)

#
# Error Helpers
#

func pe(kind: ParseErrorTypeKind): ParseErrorType =
  ## An error type that carries no data.
  ParseErrorType(kind: kind)

func unexpectedToken(token: Token, expected: seq[string], hint = none(string)): ParseErrorType =
  ParseErrorType(
    kind: peUnexpectedToken,
    vUnexpectedToken: ParseErrorTypeUnexpectedToken(token: token, expected: expected, hint: hint),
  )

func incorrectName(kind: IncorrectNamePosition): ParseErrorType =
  ParseErrorType(kind: peIncorrectName, vIncorrectName: ParseErrorTypeIncorrectName(kind: kind))

proc raiseParseError(error: ParseError) {.noreturn.} =
  var failure = newException(ParseFailure, "parse error")
  failure.error = error
  raise failure

proc parseError(error: ParseErrorType, location: SrcSpan) {.noreturn.} =
  raiseParseError(ParseError(error: error, location: location))

proc parseError(kind: ParseErrorTypeKind, location: SrcSpan) {.noreturn.} =
  parseError(pe(kind), location)

proc concatPatternVariableLeftHandSideError(start, stop: int) {.noreturn.} =
  parseError(peConcatPatternVariableLeftHandSide, sp(start, stop))

proc concatPatternVariableWithSuffix(start: int, name: string, stop: int) {.noreturn.} =
  parseError(
    ParseErrorType(
      kind: peConcatPatternVariableWithSuffix,
      vConcatPatternVariableWithSuffix: ParseErrorTypeConcatPatternVariableWithSuffix(name: name),
    ),
    sp(start, stop),
  )

# ---------------------------------------------------------------------------
# The procedures that call each other
# ---------------------------------------------------------------------------

proc parseExpression(p: var Parser): Option[UntypedExpr]
proc parseExpressionInner(p: var Parser, isLetBinding: bool): Option[UntypedExpr]
proc parseExpressionUnit(p: var Parser, context: ExpressionUnitContext): Option[UntypedExpr]
proc expectExpression(p: var Parser): UntypedExpr
proc expectExpressionUnit(p: var Parser, context: ExpressionUnitContext): UntypedExpr
proc parseStatementSequence(p: var Parser): Option[(seq[UntypedStatement], int)]
proc parseBlock(p: var Parser, start: int): UntypedExpr
proc parsePattern(p: var Parser, position: PatternPosition): Option[UntypedPattern]
proc parseCaseClause(p: var Parser): Option[UntypedClause]
proc parseFunction(
  p: var Parser, start: int, public: bool, isAnon: bool, attributes: var Attributes
): Option[UntypedDefinition]
proc parseFnArguments(p: var Parser): seq[ParserArg]
proc parseRecordUpdateArgument(p: var Parser): Option[UntypedRecordUpdateArg]
proc parseTypeAnnotation(p: var Parser, startTok: TokenKind): Option[TypeAst]
proc parseType(p: var Parser): Option[TypeAst]
proc parseConstValue(p: var Parser): Option[UntypedConstant]
proc parseConstValueUnit(p: var Parser): Option[UntypedConstant]
proc parseConstRecordFinish(
  p: var Parser, start: int, module: Option[(string, SrcSpan)], name: string, stop: int
): Option[UntypedConstant]
proc expectBitArraySize(p: var Parser): BitArraySize[Unit]
proc parseAttributes(p: var Parser, attributes: var Attributes): Option[SrcSpan]
proc makeCall*(
  fun: UntypedExpr, arguments: seq[ParserArg], start, stop, openParenthesis: int
): UntypedExpr

# ---------------------------------------------------------------------------
# Parse Helpers (upstream they are at the end of the `impl`; Nim wants them
# before their first use)
# ---------------------------------------------------------------------------

proc nextToken(p: var Parser): Option[Spanned] =
  ## Moving the token stream forward
  ## returns old token0
  let t = take(p.token0)
  var previousNewline = none(int)
  var nxt = none(Spanned)
  while true:
    let item = p.tokens.next()
    if item.isNone:
      nxt = none(Spanned)
      break
    let lexed = item.get
    if not lexed.isOk:
      # die on lex error
      nxt = none(Spanned)
      p.lexErrors.add lexed.error
      break
    let (start, token, stop) = lexed.spanned
    case token.kind
    # gather and skip extra
    of tkCommentNormal:
      p.extra.comments.add sp(start, stop)
      previousNewline = none(int)
    of tkCommentDoc:
      p.extra.docComments.add sp(start, stop)
      p.docComments.addLast (start, token.content)
      previousNewline = none(int)
    of tkCommentModule:
      p.extra.moduleComments.add sp(start, stop)
      previousNewline = none(int)
    of tkNewLine:
      p.extra.newLines.add start
      # If the previous token is a newline as well that means we
      # have run into an empty line.
      if previousNewline.isSome:
        # We increase the byte position so that newline's start
        # doesn't overlap with the previous token's end.
        p.extra.emptyLines.add previousNewline.get + 1
      previousNewline = some(start)
    else:
      nxt = some(lexed.spanned)
      break
  p.token0 = take(p.token1)
  p.token1 = take(nxt)
  t

proc advance(p: var Parser) =
  ## Moves the token stream forward
  discard p.nextToken()

proc initParser(source: string): Parser =
  result = Parser(tokens: makeTokenizer(source), extra: initModuleExtra())
  result.advance()
  result.advance()

proc nextTokenUnexpected(p: var Parser, expected: seq[string]) {.noreturn.} =
  ## Unexpected token error on the next token or EOF
  let next = p.nextToken()
  if next.isNone:
    parseError(peUnexpectedEof, sp(0, 0))
  let (start, token, stop) = next.get
  parseError(unexpectedToken(token, expected), sp(start, stop))

proc peekToken1(p: var Parser): TokenKind =
  p.token1.kind

proc maybeOne(p: var Parser, token: TokenKind): Option[(int, int)] =
  ## If the next token matches the requested, consume it and return (start, end)
  let t0 = take(p.token0)
  if t0.isSome and t0.get.token.kind == token:
    p.advance()
    some((t0.get.start, t0.get.stop))
  else:
    p.token0 = t0
    none((int, int))

proc expectOne(p: var Parser, wanted: TokenKind): (int, int) =
  ## Expect a particular token, advances the token stream
  let found = p.maybeOne(wanted)
  if found.isSome:
    return found.get
  p.nextTokenUnexpected(@[$tok(wanted)])

proc expectOneFollowingSeries(p: var Parser, wanted: TokenKind, series: string): (int, int) =
  ## Expect a particular token after having parsed a series, advances the token stream
  ## Used for giving a clearer error message in cases where the series item is what failed to parse
  let found = p.maybeOne(wanted)
  if found.isSome:
    return found.get
  p.nextTokenUnexpected(@[$tok(wanted), series])

proc seriesOfHasTrailingSeparator[A](
  p: var Parser, parser: proc(p: var Parser): Option[A], sep: TokenKind
): (seq[A], bool) =
  ## Parse a series by repeating a parser, and a separator. Returns true if
  ## the series ends with the trailing separator. `tkNone` is "no separator".
  var results: seq[A]
  var finalSeparator = none((int, int))
  while true:
    let item = parser(p)
    if item.isNone:
      break
    results.add item.get
    if sep != tkNone:
      let separator = p.maybeOne(sep)
      if separator.isSome:
        finalSeparator = separator
      else:
        finalSeparator = none((int, int))
        break

      # Helpful error if extra separator
      let extra = p.maybeOne(sep)
      if extra.isSome:
        parseError(peExtraSeparator, sp(extra.get[0], extra.get[1]))

  # If the sequence ends with a trailing comma we want to keep track of
  # its position.
  if sep == tkComma and finalSeparator.isSome:
    p.extra.trailingCommas.add finalSeparator.get[1]

  (results, finalSeparator.isSome)

proc seriesOf[A](
  p: var Parser, parser: proc(p: var Parser): Option[A], sep: TokenKind
): seq[A] =
  ## Parse a series by repeating a parser, and possibly a separator
  p.seriesOfHasTrailingSeparator(parser, sep)[0]

proc maybeName(p: var Parser): Option[(int, string, int)] =
  ## If next token is a Name, consume it and return relevant info, otherwise, return none
  let t0 = take(p.token0)
  if t0.kind == tkName:
    p.advance()
    some((t0.get.start, t0.get.token.name, t0.get.stop))
  else:
    p.token0 = t0
    none((int, string, int))

proc maybeUpname(p: var Parser): Option[(int, string, int)] =
  ## if next token is an UpName, consume it and return relevant info, otherwise, return none
  let t0 = take(p.token0)
  if t0.kind == tkUpName:
    p.advance()
    some((t0.get.start, t0.get.token.name, t0.get.stop))
  else:
    p.token0 = t0
    none((int, string, int))

proc maybeDiscardName(p: var Parser): Option[(int, string, int)] =
  ## if next token is a DiscardName, consume it and return relevant info, otherwise, return none
  let t0 = take(p.token0)
  if t0.kind == tkDiscardName:
    p.advance()
    some((t0.get.start, t0.get.token.name, t0.get.stop))
  else:
    p.token0 = t0
    none((int, string, int))

proc expectAssignName(p: var Parser): (int, AssignName, int) =
  let t = p.nextToken()
  if t.isNone:
    parseError(peUnexpectedEof, sp(0, 0))
  let (start, token, stop) = t.get
  case token.kind
  of tkName:
    (start, AssignName(kind: anVariable, vVariable: token.name), stop)
  of tkDiscardName:
    (start, AssignName(kind: anDiscard, vDiscard: token.name), stop)
  of tkUpName:
    parseError(incorrectName(inpVariable), sp(start, stop))
  else:
    if token.isReservedWord:
      parseError(peUnexpectedReservedWord, sp(start, stop))
    parseError(peExpectedName, sp(start, stop))

proc expectName(p: var Parser, kind: IncorrectNamePosition): (int, string, int) =
  ## Expect a Name else a token dependent helpful error
  let (start, token, stop) = p.expectAssignName()
  case token.kind
  of anVariable:
    (start, token.vVariable, stop)
  of anDiscard:
    parseError(incorrectName(kind), sp(start, stop))

proc expectUpname(p: var Parser): (int, string, int) =
  ## Expect an UpName else a token dependent helpful error
  let t = p.nextToken()
  if t.isNone:
    parseError(peUnexpectedEof, sp(0, 0))
  let (start, token, stop) = t.get
  case token.kind
  of tkName, tkDiscardName:
    parseError(peIncorrectUpName, sp(start, stop))
  of tkUpName:
    (start, token.name, stop)
  else:
    parseError(peExpectedUpName, sp(start, stop))

proc expectTarget(p: var Parser, parenLocation: SrcSpan): Target =
  ## Expect a target name. e.g. `javascript` or `erlang`.
  ## The location of the preceding left parenthesis is required
  ## to give the correct error span in case the target name is missing.
  let t = p.nextToken()
  if t.isNone:
    parseError(peUnexpectedEof, sp(0, 0))
  let (start, token, stop) = t.get
  if token.kind == tkName:
    template shorthand(which: Target): Target =
      p.warnings.add DeprecatedSyntaxWarning(
        kind: dsDeprecatedTargetShorthand,
        vDeprecatedTargetShorthand: DeprecatedSyntaxWarningDeprecatedTargetShorthand(
          location: sp(start, stop), target: which
        ),
      )
      which

    case token.name
    of "javascript": tgJavaScript
    of "erlang": tgErlang
    of "js": shorthand(tgJavaScript)
    of "erl": shorthand(tgErlang)
    else: parseError(peUnknownTarget, sp(start, stop))
  else:
    parseError(peExpectedTargetName, parenLocation)

proc expectString(p: var Parser): (int, string, int) =
  ## Expect a String else error
  let t0 = take(p.token0)
  if t0.kind == tkString:
    p.advance()
    (t0.get.start, t0.get.token.value, t0.get.stop)
  else:
    p.token0 = t0
    p.nextTokenUnexpected(@["a string"])

proc takeDocumentation(p: var Parser, until: int): Option[(int, string)] =
  var content = ""
  var docStart = high(uint32).int
  while p.docComments.len > 0:
    let (start, line) = p.docComments.peekFirst
    if start < docStart:
      docStart = start
    if start >= until:
      break

    if p.extra.hasCommentBetween(start, until):
      # We ignore doc comments that come before a regular comment.
      let location = sp(start, start + line.len)
      discard p.docComments.popFirst
      p.detachedDocComments.add location
      continue

    content.add line
    content.add '\n'
    discard p.docComments.popFirst
  if content.len == 0:
    none((int, string))
  else:
    some((docStart, content))

proc functionCallInConstant(p: var Parser, start: int, startParen: int) {.noreturn.} =
  ## This function is to be called after seeing a `name(` in a constant
  ## or guard clause expression. It returns an error, as functions
  ## cannot be called in this context.
  var depth = 1

  # Scan ahead through the token stream to find the matching closing paren.
  # This can skip over invalid Gleam code as it doens't check anything but (),
  # but it is good enough for the error message.
  var stop: int
  while true:
    let t = p.nextToken()
    if t.isNone:
      stop = startParen
      break
    case t.get.token.kind
    of tkLeftParen:
      depth += 1
    of tkRightParen:
      if depth == 1:
        stop = t.get.stop
        break
      depth -= 1
    else:
      discard

  parseError(peUnexpectedFunction, sp(start, stop))

# Operator Precedence Parsing
#
# Higher number means higher precedence.
# All operators are left associative.

proc handleOperator[A](
  nextOperator: Option[Operator],
  operatorStack: var seq[Operator],
  expressionStack: var seq[A],
  doReduce: proc(operator: Spanned, expressionStack: var seq[A]),
): Option[A] =
  ## Simple-Precedence-Parser, handle seeing an operator or end
  var nextOperator = nextOperator
  while true:
    let left = if operatorStack.len > 0: some(operatorStack.pop()) else: none(Operator)
    let right = take(nextOperator)
    if left.isNone and right.isNone:
      if expressionStack.len > 0:
        let fin = expressionStack.pop()
        if expressionStack.len == 0:
          return some(fin)
        else:
          raiseAssert "Expression not fully reduced."
      else:
        return none(A)
    elif left.isNone:
      operatorStack.add right.get
      break
    elif right.isNone:
      doReduce(left.get[0], expressionStack)
    else:
      # all operators are left associative
      if left.get[1] >= right.get[1]:
        doReduce(left.get[0], expressionStack)
        nextOperator = right
      else:
        operatorStack.add left.get
        operatorStack.add right.get
        break
  none(A)

func tokenToBinop(t: Token): Option[BinOp] =
  case t.kind
  of tkVbarVbar: some(boOr)
  of tkAmperAmper: some(boAnd)
  of tkEqualEqual: some(boEq)
  of tkNotEqual: some(boNotEq)
  of tkLess: some(boLtInt)
  of tkLessEqual: some(boLtEqInt)
  of tkGreater: some(boGtInt)
  of tkGreaterEqual: some(boGtEqInt)
  of tkLessDot: some(boLtFloat)
  of tkLessEqualDot: some(boLtEqFloat)
  of tkGreaterDot: some(boGtFloat)
  of tkGreaterEqualDot: some(boGtEqFloat)
  of tkPlus: some(boAddInt)
  of tkMinus: some(boSubInt)
  of tkPlusDot: some(boAddFloat)
  of tkMinusDot: some(boSubFloat)
  of tkPercent: some(boRemainderInt)
  of tkStar: some(boMultInt)
  of tkStarDot: some(boMultFloat)
  of tkSlash: some(boDivInt)
  of tkSlashDot: some(boDivFloat)
  of tkConcatenate: some(boConcatenate)
  else: none(BinOp)

func precedence(t: Token): Option[uint8] =
  if t.kind == tkPipe:
    return some(6'u8)
  let op = tokenToBinop(t)
  if op.isSome: some(op.get.precedence) else: none(uint8)

func tokenToBitArraySizeOperator(t: Token): Option[IntOperator] =
  case t.kind
  of tkPlus: some(ioAdd)
  of tkMinus: some(ioSubtract)
  of tkStar: some(ioMultiply)
  of tkSlash: some(ioDivide)
  of tkPercent: some(ioRemainder)
  else: none(IntOperator)

func expressionOperatorReduction(operator: Spanned, left, right: UntypedExpr): UntypedExpr =
  let (tokenStart, token, _) = operator
  if token.kind == tkPipe:
    var expressions: seq[UntypedExpr]
    if left.kind == uePipeline:
      expressions = left.vPipeline.expressions
      expressions.add right
    else:
      expressions = @[left, right]
    UntypedExpr(kind: uePipeline, vPipeline: UntypedExprPipeline(expressions: expressions))
  else:
    let binop = tokenToBinop(token)
    doAssert binop.isSome, "Token could not be converted to binop."
    UntypedExpr(
      kind: ueBinOp,
      vBinOp: UntypedExprBinOp(
        location: sp(left.location.start, right.location.stop),
        operator: binop.get,
        operatorStart: tokenStart,
        left: box(left),
        right: box(right),
      ),
    )

proc doReduceExpression(operator: Spanned, estack: var seq[UntypedExpr]) =
  ## Simple-Precedence-Parser, perform reduction for expression
  doAssert estack.len >= 2, "Tried to reduce without 2 expressions"
  let right = estack.pop()
  let left = estack.pop()
  estack.add expressionOperatorReduction(operator, left, right)

func clauseGuardReduction(operator: Spanned, left, right: UntypedClauseGuard): UntypedClauseGuard =
  let (start, token, _) = operator
  let binop = tokenToBinop(token)
  doAssert binop.isSome, "Token could not be converted to binop."
  UntypedClauseGuard(
    kind: cgBinaryOperator,
    vBinaryOperator: ClauseGuardBinaryOperator[Unit](
      location: sp(left.location.start, right.location.stop),
      operator: binop.get,
      operatorStart: start,
      left: box(left),
      right: box(right),
    ),
  )

proc doReduceClauseGuard(operator: Spanned, estack: var seq[UntypedClauseGuard]) =
  ## Simple-Precedence-Parser, perform reduction for clause guard
  doAssert estack.len >= 2, "Tried to reduce without 2 guards"
  let right = estack.pop()
  let left = estack.pop()
  estack.add clauseGuardReduction(operator, left, right)

func constantBinopReduction(operator: Spanned, left, right: UntypedConstant): UntypedConstant =
  let (operatorStart, operatorToken, _) = operator
  let binop = tokenToBinop(operatorToken)
  doAssert binop.isSome, "Token could not be converted to binop."
  UntypedConstant(
    kind: coBinaryOperator,
    vBinaryOperator: ConstantBinaryOperator[Unit](
      location: sp(left.location.start, right.location.stop),
      operatorStart: operatorStart,
      operator: binop.get,
      left: box(left),
      right: box(right),
    ),
  )

proc doReduceConstant(operator: Spanned, estack: var seq[UntypedConstant]) =
  ## Simple-Precedence-Parser, perform reduction for clause guard
  doAssert estack.len >= 2, "Tried to reduce without 2 guards"
  # Upstream names the two popped values the other way round and swaps them
  # again in the call: the result is the same as for expressions.
  let right = estack.pop()
  let left = estack.pop()
  estack.add constantBinopReduction(operator, left, right)

proc reduceBitArraySize(operator: Spanned, expressionStack: var seq[BitArraySize[Unit]]) =
  ## Simple-Precedence-Parser, perform reduction for bit array size expressions
  let intOperator = tokenToBitArraySizeOperator(operator.token)
  doAssert intOperator.isSome, "only operator tokens are pushed onto the bit array size opstack"
  doAssert expressionStack.len >= 2, "Tried to reduce bit array size without 2 operands"
  let right = expressionStack.pop()
  let left = expressionStack.pop()
  expressionStack.add BitArraySize[Unit](
    kind: bsBinaryOperator,
    vBinaryOperator: BitArraySizeBinaryOperator[Unit](
      left: box(left),
      right: box(right),
      operator: intOperator.get,
      location: sp(left.location.start, right.location.stop),
    ),
  )

# BitArray Parse Helpers
#
# BitArrays in patterns, guards, and expressions have a very similar structure
# but need specific types. These are helpers for that. There is probably a
# rustier way to do this :)
proc bitArraySizeInt(value: string, intValue: BigInt, start, stop: int): UntypedPattern =
  UntypedPattern(
    kind: paBitArraySize,
    vBitArraySize: BitArraySize[Unit](
      kind: bsInt,
      vInt: BitArraySizeInt(location: sp(start, stop), value: value, intValue: intValue),
    ),
  )

proc bitArrayExpressionInt(value: string, intValue: BigInt, start, stop: int): UntypedExpr =
  UntypedExpr(
    kind: ueInt, vInt: UntypedExprInt(location: sp(start, stop), value: value, intValue: intValue)
  )

proc bitArrayConstInt(value: string, intValue: BigInt, start, stop: int): UntypedConstant =
  UntypedConstant(
    kind: coInt, vInt: ConstantInt(location: sp(start, stop), value: value, intValue: intValue)
  )

func strToBitArrayOption[A](lit: string, location: SrcSpan): Option[BitArrayOption[A]] =
  let fields = BitArrayOptionLocation(location: location)
  case lit
  of "bytes": some(BitArrayOption[A](kind: baBytes, vBytes: fields))
  of "int": some(BitArrayOption[A](kind: baInt, vInt: fields))
  of "float": some(BitArrayOption[A](kind: baFloat, vFloat: fields))
  of "bits": some(BitArrayOption[A](kind: baBits, vBits: fields))
  of "utf8": some(BitArrayOption[A](kind: baUtf8, vUtf8: fields))
  of "utf16": some(BitArrayOption[A](kind: baUtf16, vUtf16: fields))
  of "utf32": some(BitArrayOption[A](kind: baUtf32, vUtf32: fields))
  of "utf8_codepoint": some(BitArrayOption[A](kind: baUtf8Codepoint, vUtf8Codepoint: fields))
  of "utf16_codepoint": some(BitArrayOption[A](kind: baUtf16Codepoint, vUtf16Codepoint: fields))
  of "utf32_codepoint": some(BitArrayOption[A](kind: baUtf32Codepoint, vUtf32Codepoint: fields))
  of "signed": some(BitArrayOption[A](kind: baSigned, vSigned: fields))
  of "unsigned": some(BitArrayOption[A](kind: baUnsigned, vUnsigned: fields))
  of "big": some(BitArrayOption[A](kind: baBig, vBig: fields))
  of "little": some(BitArrayOption[A](kind: baLittle, vLittle: fields))
  of "native": some(BitArrayOption[A](kind: baNative, vNative: fields))
  else: none(BitArrayOption[A])

#
# Bit String parsing
#

proc parseBitArrayOption[A](
  p: var Parser,
  argParser: proc(p: var Parser): A,
  toIntSegment: proc(value: string, intValue: BigInt, start, stop: int): A,
): Option[BitArrayOption[A]] =
  ## examples:
  ##   1
  ##   size(1)
  ##   size(five)
  ##   utf8
  let t0 = take(p.token0)
  case t0.kind
  # named segment
  of tkName:
    let (start, token, stop) = t0.get
    let name = token.name
    p.advance()
    if p.maybeOne(tkLeftParen).isSome:
      # named function segment
      case name
      of "unit":
        let unitToken = take(p.token0)
        if unitToken.kind == tkInt:
          let (intS, intToken, intE) = unitToken.get
          p.advance()
          let (_, stop) = p.expectOne(tkRightParen)
          let units = parseU64(intToken.intText.replace("_", ""))
          if units.isSome and units.get > 0 and units.get <= 255:
            some(
              BitArrayOption[A](
                kind: baUnit,
                vUnit: BitArrayOptionUnit(location: sp(start, stop), value: uint8(units.get)),
              )
            )
          else:
            parseError(peInvalidBitArrayUnit, sp(intS, intE))
        else:
          p.token0 = unitToken
          p.nextTokenUnexpected(@["A positive int"])
      of "size":
        let value = argParser(p)
        let (_, stop) = p.expectOne(tkRightParen)
        some(
          BitArrayOption[A](
            kind: baSize,
            vSize: BitArrayOptionSize[A](location: sp(start, stop), value: box(value), shortForm: false),
          )
        )
      else:
        parseError(peInvalidBitArraySegment, sp(start, stop))
    else:
      let option = strToBitArrayOption[A](name, sp(start, stop))
      if option.isNone:
        parseError(peInvalidBitArraySegment, sp(start, stop))
      option
  # int segment
  of tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    some(
      BitArrayOption[A](
        kind: baSize,
        vSize: BitArrayOptionSize[A](
          location: sp(start, stop),
          value: box(toIntSegment(token.intText, token.intValue, start, stop)),
          shortForm: true,
        ),
      )
    )
  # invalid
  else:
    p.token0 = t0
    p.nextTokenUnexpected(
      @["A valid bit array segment type", "See: https://tour.gleam.run/data-types/bit-arrays/"]
    )

proc parseBitArraySegment[A](
  p: var Parser,
  valueParser: proc(p: var Parser): Option[A],
  argParser: proc(p: var Parser): A,
  toIntSegment: proc(value: string, intValue: BigInt, start, stop: int): A,
): Option[BitArraySegment[A, Unit]] =
  ## The structure is roughly the same for pattern, const, and expr
  ## that's why these functions take functions
  ##
  ## pattern (: option)?
  let parsed = valueParser(p)
  if parsed.isNone:
    return none(BitArraySegment[A, Unit])
  let value = parsed.get
  var options: seq[BitArrayOption[A]]
  if p.maybeOne(tkColon).isSome:
    options = p.seriesOf(
      proc(this: var Parser): Option[BitArrayOption[A]] =
        this.parseBitArrayOption(argParser, toIntSegment),
      tkMinus,
    )
  let stop = if options.len > 0: options[^1].location.stop else: value.location.stop
  some(
    BitArraySegment[A, Unit](
      location: sp(value.location.start, stop), value: box(value), options: options
    )
  )

proc parseBitArraySizeUnit(p: var Parser): BitArraySize[Unit] =
  let t0 = take(p.token0)
  case t0.kind
  of tkName:
    let (start, token, stop) = t0.get
    p.advance()
    BitArraySize[Unit](
      kind: bsVariable,
      vVariable: BitArraySizeVariable[Unit](
        location: sp(start, stop), name: token.name, constructor: none(ref ValueConstructor)
      ),
    )
  of tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    BitArraySize[Unit](
      kind: bsInt,
      vInt: BitArraySizeInt(location: sp(start, stop), value: token.intText, intValue: token.intValue),
    )
  of tkLeftBrace:
    let start = t0.get.start
    p.advance()
    let inner = p.expectBitArraySize()
    let (_, stop) = p.expectOne(tkRightBrace)
    BitArraySize[Unit](
      kind: bsBlock, vBlock: BitArraySizeBlock[Unit](location: sp(start, stop), inner: box(inner))
    )
  else:
    p.token0 = t0
    p.nextTokenUnexpected(@["A variable name or an int"])

proc expectBitArraySize(p: var Parser): BitArraySize[Unit] =
  var opstack: seq[Operator]
  var estack: seq[BitArraySize[Unit]]

  estack.add p.parseBitArraySizeUnit()

  while true:
    let t0 = take(p.token0)
    if t0.isNone:
      break
    let operator = tokenToBitArraySizeOperator(t0.get.token)
    if operator.isNone:
      p.token0 = t0
      break

    p.advance()
    discard handleOperator(some((t0.get, operator.get.precedence)), opstack, estack, reduceBitArraySize)

    estack.add p.parseBitArraySizeUnit()

  let size = handleOperator(none(Operator), opstack, estack, reduceBitArraySize)
  doAssert size.isSome, "bit array size expression stack should not be empty"
  size.get

proc expectBitArrayPatternSegmentArgument(p: var Parser): UntypedPattern =
  UntypedPattern(kind: paBitArraySize, vBitArraySize: p.expectBitArraySize())

proc expectConstInt(p: var Parser): UntypedConstant =
  let t0 = take(p.token0)
  if t0.kind == tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    UntypedConstant(
      kind: coInt,
      vInt: ConstantInt(location: sp(start, stop), value: token.intText, intValue: token.intValue),
    )
  else:
    p.token0 = t0
    p.nextTokenUnexpected(@["An int"])

# ---------------------------------------------------------------------------
# The parser, in upstream order
# ---------------------------------------------------------------------------

proc ensureNoErrors(p: var Parser, failure: Option[ParseError]) =
  ## The way the parser is currently implemented, it cannot exit immediately
  ## while advancing the token stream upon seeing a LexError. That is to avoid
  ## having to put `?` all over the place and instead we collect LexErrors in
  ## `self.lex_errors` and attempt to continue parsing.
  ## Once parsing has returned we want to surface an error in the order:
  ## 1) LexError, 2) ParseError
  if p.lexErrors.len > 0:
    # Lex errors first
    let error = p.lexErrors[0]
    parseError(
      ParseErrorType(kind: peLexError, vLexError: ParseErrorTypeLexError(error: error)),
      error.location,
    )
  elif failure.isSome:
    # Return any existing parse error
    raiseParseError(failure.get)

proc ensureNoErrorsOrRemainingInput(p: var Parser, failure: Option[ParseError]) =
  ## The way the parser is currently implemented, it cannot exit immediately while advancing
  ## the token stream upon seeing a LexError. That is to avoid having to put `?` all over the
  ## place and instead we collect LexErrors in `self.lex_errors` and attempt to continue parsing.
  ## Once parsing has returned we want to surface an error in the order:
  ## 1) LexError, 2) ParseError, 3) More Tokens Left
  ##
  ## Upstream this takes the `Result` of the parse and gives it back: here the
  ## caller keeps the value and passes the error, if there was one.
  p.ensureNoErrors(failure)
  let next = p.nextToken()
  if next.isSome:
    # there are still more tokens
    let (start, token, stop) = next.get
    parseError(unexpectedToken(token, @["An import, const, type, or function."]), sp(start, stop))
  # no errors

proc publicity(p: Parser, public: bool, internal: InternalAttribute): Publicity =
  case internal.kind
  of iaMissing:
    if public: Publicity(kind: pbPublic) else: Publicity(kind: pbPrivate)
  of iaPresent:
    if public:
      Publicity(
        kind: pbInternal,
        vInternal: PublicityInternal(attributeLocation: some(internal.vPresent)),
      )
    else:
      parseError(peRedundantInternalAttribute, internal.vPresent)

#
# Parse Expressions
#

proc parseExpression(p: var Parser): Option[UntypedExpr] =
  ## examples:
  ##   unit
  ##   unit op unit
  ##   unit op unit pipe unit(call)
  ##   unit op unit pipe unit(call) pipe unit(call)
  p.parseExpressionInner(false)

proc postProcessExpressionUnit(p: var Parser, unit: UntypedExpr, isLetBinding: bool) =
  # Produce better error message for `[x] = [1]` outside
  # of `let` statement.
  if not isLetBinding and unit.kind == ueList and p.token0.kind == tkEqual:
    parseError(peNoLetBinding, sp(p.token0.get.start, p.token0.get.stop))

proc parseExpressionInner(p: var Parser, isLetBinding: bool): Option[UntypedExpr] =
  # uses the simple operator parser algorithm
  var opstack: seq[Operator]
  var estack: seq[UntypedExpr]
  var lastOpStart = 0
  var lastOpEnd = 0

  # This is used to keep track if we've just ran into a `|>` operator in
  # order to properly parse an echo based on its position: if it is in a
  # pipeline then it isn't expected to be followed by an expression.
  # Otherwise, it's expected to be followed by an expression.
  var expressionUnitContext = Other

  while true:
    let unit = p.parseExpressionUnit(expressionUnitContext)
    if unit.isSome:
      p.postProcessExpressionUnit(unit.get, isLetBinding)
      estack.add unit.get
    elif estack.len == 0:
      return none(UntypedExpr)
    else:
      parseError(peOpNakedRight, sp(lastOpStart, lastOpEnd))

    let t0 = take(p.token0)
    if t0.isNone:
      break
    let (opS, t, opE) = t0.get

    let prec = precedence(t)
    if prec.isNone:
      p.token0 = t0
      break

    expressionUnitContext = if t.kind == tkPipe: FollowingPipe else: Other

    # Is Op
    p.advance()
    lastOpStart = opS
    lastOpEnd = opE
    discard handleOperator(some((t0.get, prec.get)), opstack, estack, doReduceExpression)

  handleOperator(none(Operator), opstack, estack, doReduceExpression)

proc addCommentStyleHint(error: var ParseError) =
  if error.error.kind == peUnexpectedToken:
    error.error.vUnexpectedToken.hint = some(
      "Maybe you meant to create a comment?\nComments in Gleam start with `//`, not `#`"
    )

proc maybeParseAsMessage(p: var Parser): Option[ref UntypedExpr] =
  if p.maybeOne(tkAs).isSome:
    some(box(p.expectExpressionUnit(Other)))
  else:
    none(ref UntypedExpr)

proc parseExpressionUnit(p: var Parser, context: ExpressionUnitContext): Option[UntypedExpr] =
  ## examples:
  ##   1
  ##   "one"
  ##   True
  ##   fn() { "hi" }
  ##   unit().unit().unit()
  ##   A(a.., label: tuple(1))
  ##   { expression_sequence }
  var expr: UntypedExpr
  let t0 = take(p.token0)
  case t0.kind
  of tkString:
    let (start, token, stop) = t0.get
    p.advance()
    expr = UntypedExpr(
      kind: ueString, vString: UntypedExprString(location: sp(start, stop), value: token.value)
    )
  of tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    expr = UntypedExpr(
      kind: ueInt,
      vInt: UntypedExprInt(location: sp(start, stop), value: token.intText, intValue: token.intValue),
    )
  of tkFloat:
    let (start, token, stop) = t0.get
    p.advance()
    expr = UntypedExpr(
      kind: ueFloat,
      vFloat: UntypedExprFloat(
        location: sp(start, stop),
        value: token.floatText,
        floatValue: LiteralFloatValue(token.floatValue),
      ),
    )

  # var lower_name and UpName
  of tkName, tkUpName:
    let (start, token, stop) = t0.get
    p.advance()
    expr = UntypedExpr(kind: ueVar, vVar: UntypedExprVar(location: sp(start, stop), name: token.name))
  of tkTodo:
    let (start, _, tokenEnd) = t0.get
    p.advance()
    let message = p.maybeParseAsMessage()
    let stop = if message.isSome: message.get[].location.stop else: tokenEnd
    expr = UntypedExpr(
      kind: ueTodo,
      vTodo: UntypedExprTodo(
        location: sp(start, stop), kind: TodoKind(kind: tdKeyword), message: message
      ),
    )
  of tkPanic:
    let (start, _, tokenEnd) = t0.get
    p.advance()
    let message = p.maybeParseAsMessage()
    let stop = if message.isSome: message.get[].location.stop else: tokenEnd
    expr = UntypedExpr(
      kind: uePanic, vPanic: UntypedExprPanic(location: sp(start, stop), message: message)
    )
  of tkEcho:
    let (start, _, echoEnd) = t0.get
    p.advance()
    if context == FollowingPipe:
      # If an echo is used as a step in a pipeline (`|> echo`)
      # then it cannot be followed by an expression.
      let message = p.maybeParseAsMessage()
      let stop = if message.isSome: message.get[].location.stop else: echoEnd
      expr = UntypedExpr(
        kind: ueEcho,
        vEcho: UntypedExprEcho(
          location: sp(start, stop),
          keywordEnd: echoEnd,
          expression: none(ref UntypedExpr),
          message: message,
        ),
      )
    else:
      # Otherwise it must be followed by an expression.
      # However, you might have noticed we're not erroring if the
      # expression is not there. Instead we move this error to
      # the analysis phase so that a wrong usage of echo won't
      # stop analysis from happening everywhere and be fault
      # tolerant like everything else.
      let expression = p.parseExpression()
      var stop = if expression.isSome: expression.get.location.stop else: echoEnd

      let message = p.maybeParseAsMessage()
      if message.isSome:
        stop = message.get[].location.stop

      expr = UntypedExpr(
        kind: ueEcho,
        vEcho: UntypedExprEcho(
          location: sp(start, stop),
          keywordEnd: echoEnd,
          expression: (if expression.isSome: some(box(expression.get)) else: none(ref UntypedExpr)),
          message: message,
        ),
      )
  of tkHash:
    let start = t0.get.start
    p.advance()
    try:
      discard p.expectOne(tkLeftParen)
    except ParseFailure as failure:
      addCommentStyleHint(failure.error)
      raise
    let elements = p.seriesOf(parseExpression, tkComma)
    let (_, stop) = p.expectOneFollowingSeries(tkRightParen, "an expression")
    expr = UntypedExpr(
      kind: ueTuple, vTuple: UntypedExprTuple(location: sp(start, stop), elements: elements)
    )

  # list
  of tkLeftSquare:
    let start = t0.get.start
    p.advance()
    let (elements, elementsEndWithComma) = p.seriesOfHasTrailingSeparator(parseExpression, tkComma)

    # Parse an optional tail
    var tail = none(ref UntypedExpr)
    var elementsAfterTail = none(seq[UntypedExpr])
    var dotDotLocation = none((int, int))

    let dotDot = p.maybeOne(tkDotDot)
    if dotDot.isSome:
      dotDotLocation = dotDot
      let tailExpression = p.parseExpression()
      if tailExpression.isSome:
        tail = some(box(tailExpression.get))
      if p.maybeOne(tkComma).isSome:
        # See if there's a list of items after the tail,
        # like `[..wibble, wobble, wabble]`
        try:
          elementsAfterTail = some(p.seriesOf(parseExpression, tkComma))
        except ParseFailure:
          discard

      if tail.isSome:
        if not elementsEndWithComma:
          p.warnings.add DeprecatedSyntaxWarning(
            kind: dsDeprecatedListPrepend,
            vDeprecatedListPrepend:
              DeprecatedSyntaxWarningLocation(location: sp(dotDot.get[0], dotDot.get[1])),
          )

        # Give a better error when there is two consecutive spreads
        # like `[..wibble, ..wabble, woo]`. However, if there's other
        # elements after the tail of the list
        let second = p.maybeOne(tkDotDot)
        if second.isSome:
          try:
            discard p.parseExpression()
          except ParseFailure:
            discard

          if elementsAfterTail.isNone or elementsAfterTail.get.len == 0:
            parseError(
              ParseErrorType(
                kind: peListSpreadWithAnotherSpread,
                vListSpreadWithAnotherSpread: ParseErrorTypeListSpreadWithAnotherSpread(
                  firstSpreadLocation: sp(dotDot.get[0], dotDot.get[1])
                ),
              ),
              sp(second.get[0], second.get[1]),
            )

    let (_, stop) = p.expectOne(tkRightSquare)

    # Return errors for malformed lists
    if dotDotLocation.isSome and tail.isNone:
      parseError(peListSpreadWithoutTail, sp(dotDotLocation.get[0], dotDotLocation.get[1]))
    if tail.isSome and elements.len == 0 and
        (elementsAfterTail.isNone or elementsAfterTail.get.len == 0):
      parseError(peListSpreadWithoutElements, sp(start, stop))

    if elementsAfterTail.isSome and elementsAfterTail.get.len > 0:
      if dotDotLocation.isSome and tail.isSome:
        parseError(
          peListSpreadFollowedByElements, sp(dotDotLocation.get[0], tail.get[].location.stop)
        )
      else:
        parseError(peListSpreadFollowedByElements, sp(start, stop))

    expr = UntypedExpr(
      kind: ueList,
      vList: UntypedExprList(location: sp(start, stop), elements: elements, tail: tail),
    )

  # BitArray
  of tkLtLt:
    let start = t0.get.start
    p.advance()
    let segments = p.seriesOf(
      proc(this: var Parser): Option[UntypedExprBitArraySegment] =
        this.parseBitArraySegment(
          proc(this: var Parser): Option[UntypedExpr] = this.parseExpressionUnit(Other),
          expectExpression,
          bitArrayExpressionInt,
        ),
      tkComma,
    )
    let (_, stop) = p.expectOneFollowingSeries(tkGtGt, "a bit array segment")
    expr = UntypedExpr(
      kind: ueBitArray, vBitArray: UntypedExprBitArray(location: sp(start, stop), segments: segments)
    )
  of tkFn:
    let start = t0.get.start
    p.advance()
    var attributes = Attributes()
    let definition = p.parseFunction(start, false, true, attributes)
    if definition.isSome and definition.get.kind == dfFunction:
      let function = definition.get.vFunction
      if function.body.len == 0:
        parseError(peExpectedFunctionBody, function.location)

      expr = UntypedExpr(
        kind: ueFn,
        vFn: UntypedExprFn(
          location: sp(function.location.start, function.endPosition),
          endOfHeadByteIndex: function.location.stop,
          kind: FunctionLiteralKind(
            kind: flAnonymous, vAnonymous: FunctionLiteralKindAnonymous(head: function.location)
          ),
          arguments: function.arguments,
          body: function.body,
          returnAnnotation: function.returnAnnotation,
        ),
      )
    else:
      # this isn't just none, it could also be Some(UntypedExpr::..)
      p.nextTokenUnexpected(@["An opening parenthesis."])

  # expression block  "{" "}"
  of tkLeftBrace:
    let start = t0.get.start
    p.advance()
    expr = p.parseBlock(start)

  # case
  of tkCase:
    let (start, _, caseE) = t0.get
    p.advance()
    let subjects = p.seriesOf(parseExpression, tkComma)
    if p.maybeOne(tkLeftBrace).isSome:
      let clauses = p.seriesOf(parseCaseClause, tkNone)
      let (_, stop) = p.expectOneFollowingSeries(tkRightBrace, "a case clause")
      if subjects.len == 0:
        parseError(peExpectedExpr, sp(start, caseE))
      else:
        expr = UntypedExpr(
          kind: ueCase,
          vCase: UntypedExprCase(location: sp(start, stop), subjects: subjects, clauses: some(clauses)),
        )
    else:
      expr = UntypedExpr(
        kind: ueCase,
        vCase: UntypedExprCase(
          location: sp(start, (if subjects.len > 0: subjects[^1].location.stop else: caseE)),
          subjects: subjects,
          clauses: none(seq[UntypedClause]),
        ),
      )

  # Helpful error if trying to write an if expression instead of a
  # case.
  of tkIf:
    parseError(peIfExpression, sp(t0.get.start, t0.get.stop))

  # Helpful error on possibly trying to group with "(".
  of tkLeftParen:
    parseError(peExprLparStart, sp(t0.get.start, t0.get.start))

  # Boolean negation
  of tkBang:
    let start = t0.get.start
    p.advance()
    let value = p.parseExpressionUnit(Other)
    if value.isNone:
      parseError(peExpectedExpr, sp(start, start))
    expr = UntypedExpr(
      kind: ueNegateBool,
      vNegateBool: UntypedExprNegateBool(
        location: sp(start, value.get.location.stop), value: box(value.get)
      ),
    )

  # Int negation
  of tkMinus:
    let start = t0.get.start
    p.advance()
    let value = p.parseExpressionUnit(Other)
    if value.isNone:
      parseError(peExpectedExpr, sp(start, start))
    expr = UntypedExpr(
      kind: ueNegateInt,
      vNegateInt: UntypedExprNegateInt(
        location: sp(start, value.get.location.stop), value: box(value.get)
      ),
    )
  else:
    p.token0 = t0
    return none(UntypedExpr)

  # field access and call can stack up
  while true:
    let dot = p.maybeOne(tkDot)
    if dot.isSome:
      let dotStart = dot.get[0]
      let start = expr.location.start
      # field access
      let field = take(p.token0)
      case field.kind
      # tuple access
      of tkInt:
        let (_, token, stop) = field.get
        p.advance()
        let index = parseU64(token.intText.replace("_", ""))
        if index.isNone:
          parseError(peInvalidTupleAccess, sp(start, stop))
        expr = UntypedExpr(
          kind: ueTupleIndex,
          vTupleIndex: UntypedExprTupleIndex(location: sp(start, stop), index: index.get, tupl: box(expr)),
        )
      of tkName, tkUpName:
        let (labelStart, token, stop) = field.get
        p.advance()
        expr = UntypedExpr(
          kind: ueFieldAccess,
          vFieldAccess: UntypedExprFieldAccess(
            location: sp(start, stop),
            labelLocation: sp(labelStart, stop),
            label: token.name,
            container: box(expr),
          ),
        )
      else:
        # parse a field access with no label
        p.token0 = field
        let stop = dotStart + 1
        expr = UntypedExpr(
          kind: ueFieldAccess,
          vFieldAccess: UntypedExprFieldAccess(
            location: sp(start, stop),
            labelLocation: sp(dotStart, stop),
            label: "",
            container: box(expr),
          ),
        )
        return some(expr)
    else:
      let paren = p.maybeOne(tkLeftParen)
      if paren.isSome:
        let leftParen = paren.get[0]
        let start = expr.location.start
        let spread = p.maybeOne(tkDotDot)
        if spread.isSome:
          # Record update
          let dotS = spread.get[0]
          let base = p.expectExpression()
          let baseE = base.location.stop
          let record = RecordBeingUpdated[UntypedExpr](base: box(base), location: sp(dotS, baseE))
          var arguments: seq[UntypedRecordUpdateArg]
          if p.maybeOne(tkComma).isSome:
            arguments = p.seriesOf(parseRecordUpdateArgument, tkComma)
          let (_, stop) = p.expectOne(tkRightParen)

          expr = UntypedExpr(
            kind: ueRecordUpdate,
            vRecordUpdate: UntypedExprRecordUpdate(
              location: sp(start, stop),
              spreadStart: dotS,
              constructor: box(expr),
              record: record,
              arguments: arguments,
            ),
          )
        else:
          # Call
          let arguments = p.parseFnArguments()

          let dotDot = p.maybeOne(tkDotDot)
          if dotDot.isSome:
            var value = none(UntypedConstant)
            try:
              value = p.parseConstValue()
            except ParseFailure:
              discard
            if value.isNone:
              parseError(
                unexpectedToken(tok(tkDotDot), @[$tok(tkRightParen)]),
                sp(dotDot.get[0], dotDot.get[1]),
              )
            let updateLocation = sp(dotDot.get[0], value.get.location.stop)

            discard p.expectOne(tkRightParen)

            parseError(peRecordUpdateAfterFields, updateLocation)

          let (_, stop) = p.expectOne(tkRightParen)
          expr = makeCall(expr, arguments, start, stop, leftParen)
      else:
        # done
        break

  some(expr)

proc parseUseAssignment(p: var Parser): Option[UntypedUseAssignment] =
  let start = if p.token0.isSome: p.token0.get.start else: 0

  let pattern = p.parsePattern(ppUsePattern)
  if pattern.isNone:
    parseError(peExpectedPattern, sp(start, start))

  let annotation = p.parseTypeAnnotation(tkColon)
  let stop = if annotation.isSome: annotation.get.location.stop else: pattern.get.location.stop

  some(UntypedUseAssignment(location: sp(start, stop), pattern: pattern.get, annotation: annotation))

proc parseUse(p: var Parser, start, stop: int): UntypedStatement =
  ## A `use` expression
  ## use <- function
  ## use <- function()
  ## use <- function(a, b)
  ## use <- module.function(a, b)
  ## use a, b, c <- function(a, b)
  ## use a, b, c, <- function(a, b)
  var assignments: seq[UntypedUseAssignment]
  if p.token0.kind != tkLArrow:
    assignments = p.seriesOf(parseUseAssignment, tkComma)

  discard p.expectOneFollowingSeries(tkLArrow, "a use variable assignment")
  let call = p.expectExpression()

  let assignmentsLocation =
    if assignments.len > 0:
      sp(assignments[0].location.start, assignments[^1].location.stop)
    else:
      sp(start, stop)

  UntypedStatement(
    kind: stUse,
    vUse: UntypedUse(
      location: sp(start, call.location.stop),
      assignmentsLocation: assignmentsLocation,
      rightHandSideLocation: call.location,
      assignments: assignments,
      call: box(call),
    ),
  )

proc maybeParseConstantAsMessage(p: var Parser): Option[ref UntypedConstant] =
  let asToken = p.maybeOne(tkAs)
  if asToken.isSome:
    let constant = p.parseConstValueUnit()
    if constant.isNone:
      parseError(peMissingConstantAsMessage, sp(asToken.get[0], asToken.get[1]))
    some(box(constant.get))
  else:
    none(ref UntypedConstant)

proc parseAssignment(p: var Parser, start: int): UntypedStatement =
  ## An assignment, with `Let` already consumed
  var kind = AssignmentKind[UntypedExpr](kind: akLet)
  if p.token0.kind == tkAssert:
    let (assertKeywordStart, _, assertEnd) = p.token0.get
    discard p.nextToken()
    kind = AssignmentKind[UntypedExpr](
      kind: akAssert,
      vAssert: AssignmentKindAssert[UntypedExpr](
        location: sp(start, assertEnd),
        assertKeywordStart: assertKeywordStart,
        message: none(UntypedExpr),
      ),
    )
  let pattern = p.parsePattern(ppLetAssignment)
  if pattern.isNone:
    # DUPE: 62884
    p.nextTokenUnexpected(@["A pattern"])
  let annotation = p.parseTypeAnnotation(tkColon)
  let equal = p.maybeOne(tkEqual)
  if equal.isNone:
    parseError(peExpectedEqual, sp(pattern.get.location.start, pattern.get.location.stop))
  let (eqS, eqE) = equal.get
  let value = p.parseExpressionInner(true)
  if value.isNone:
    if p.token0.kind == tkDiscardName:
      parseError(incorrectName(inpVariable), sp(p.token0.get.start, p.token0.get.stop))
    else:
      parseError(peExpectedValue, sp(eqS, eqE))

  var stop = value.get.location.stop

  case kind.kind
  of akLet, akGenerated:
    discard
  of akAssert:
    if p.maybeOne(tkAs).isSome:
      let messageExpression = p.expectExpressionUnit(Other)
      stop = messageExpression.location.stop
      kind.vAssert.message = some(messageExpression)

  UntypedStatement(
    kind: stAssignment,
    vAssignment: box(
      UntypedAssignment(
        location: sp(start, stop),
        value: value.get,
        compiledCase: CompiledCase.failure,
        pattern: pattern.get,
        annotation: annotation,
        kind: kind,
      )
    ),
  )

proc parseAssert(p: var Parser, start: int): UntypedStatement =
  ## An assert statement, with `Assert` already consumed
  let value = p.expectExpression()
  var stop = value.location.stop

  var message = none(UntypedExpr)
  if p.maybeOne(tkAs).isSome:
    let messageExpression = p.expectExpressionUnit(Other)
    stop = messageExpression.location.stop
    message = some(messageExpression)

  UntypedStatement(
    kind: stAssert, vAssert: UntypedAssert(location: sp(start, stop), value: value, message: message)
  )

proc parseStatementErrors(p: var Parser) =
  # Better error: name definitions must start with `let`
  if p.token0.kind == tkName and p.token1.kind in {tkEqual, tkColon}:
    parseError(peNoLetBinding, sp(p.token1.get.start, p.token1.get.stop))

proc parseStatement(p: var Parser): Option[UntypedStatement] =
  let t0 = take(p.token0)
  case t0.kind
  of tkUse:
    p.advance()
    some(p.parseUse(t0.get.start, t0.get.stop))
  of tkLet:
    p.advance()
    some(p.parseAssignment(t0.get.start))
  of tkAssert:
    p.advance()
    some(p.parseAssert(t0.get.start))

  # Helpful error when trying to define a constant inside a function.
  of tkConst:
    parseError(peConstantInsideFunction, sp(t0.get.start, t0.get.stop))
  else:
    p.token0 = t0
    p.parseStatementErrors()
    let expression = p.parseExpression()
    if expression.isSome:
      some(UntypedStatement(kind: stExpression, vExpression: expression.get))
    else:
      none(UntypedStatement)

proc parseStatementSequence(p: var Parser): Option[(seq[UntypedStatement], int)] =
  ## examples:
  ##   expr
  ##   expr expr..
  ##   expr assignment..
  ##   assignment
  ##   assignment expr..
  ##   assignment assignment..
  var statements: seq[UntypedStatement]
  var stop = 0

  # Try and parse as many expressions as possible
  while true:
    let statement = p.parseStatement()
    if statement.isNone:
      break
    stop = statement.get.location.stop
    statements.add statement.get

  if statements.len > 0:
    some((statements, stop))
  else:
    none((seq[UntypedStatement], int))

proc parseBlock(p: var Parser, start: int): UntypedExpr =
  let body = p.parseStatementSequence()
  let (_, stop) = p.expectOne(tkRightBrace)
  let location = sp(start, stop)
  let statements =
    if body.isSome:
      body.get[0]
    else:
      @[
        UntypedStatement(
          kind: stExpression,
          vExpression: UntypedExpr(
            kind: ueTodo,
            vTodo: UntypedExprTodo(
              kind: TodoKind(kind: tdEmptyBlock), location: location, message: none(ref UntypedExpr)
            ),
          ),
        )
      ]

  UntypedExpr(kind: ueBlock, vBlock: UntypedExprBlock(location: location, statements: statements))

proc parseConstructorPatternArgument(
  p: var Parser, position: PatternPosition
): Option[CallArg[UntypedPattern]] =
  ## examples:
  ##   a: <pattern>
  ##   a:
  ##   <pattern>
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkColon:
    # named arg
    let start = t0.get.start
    let name = t0.get.token.name
    let stop = t1.get.stop
    p.advance()
    p.advance()
    let value = p.parsePattern(position)
    if value.isSome:
      some(
        CallArg[UntypedPattern](
          implicit: none(ImplicitCallArgOrigin),
          location: sp(start, value.get.location.stop),
          label: some(name),
          value: value.get,
        )
      )
    else:
      # Argument supplied with a label shorthand.
      some(
        CallArg[UntypedPattern](
          implicit: none(ImplicitCallArgOrigin),
          location: sp(start, stop),
          label: some(name),
          value: UntypedPattern(
            kind: paVariable,
            vVariable: PatternVariable[Unit](
              origin: VariableOrigin(
                syntax: VariableSyntax(kind: vsLabelShorthand, vLabelShorthand: name),
                declaration: position.toDeclaration,
              ),
              name: name,
              location: sp(start, stop),
            ),
          ),
        )
      )
  else:
    # unnamed arg
    p.token0 = t0
    p.token1 = t1
    let value = p.parsePattern(position)
    if value.isSome:
      some(
        CallArg[UntypedPattern](
          implicit: none(ImplicitCallArgOrigin),
          location: value.get.location,
          label: none(string),
          value: value.get,
        )
      )
    else:
      none(CallArg[UntypedPattern])

proc parseConstructorPatternArguments(
  p: var Parser, upnameEnd: int, position: PatternPosition
): (seq[CallArg[UntypedPattern]], Option[SrcSpan], int) =
  ## examples:
  ##   ( args )
  if p.maybeOne(tkLeftParen).isSome:
    let (arguments, argumentsEndWithComma) = p.seriesOfHasTrailingSeparator(
      proc(this: var Parser): Option[CallArg[UntypedPattern]] =
        this.parseConstructorPatternArgument(position),
      tkComma,
    )

    let dotDot = p.maybeOne(tkDotDot)
    var spread = none(SrcSpan)
    if dotDot.isSome:
      spread = some(sp(dotDot.get[0], dotDot.get[1]))
      discard p.maybeOne(tkComma)
      if arguments.len > 0 and not argumentsEndWithComma:
        p.warnings.add DeprecatedSyntaxWarning(
          kind: dsDeprecatedRecordSpreadPattern,
          vDeprecatedRecordSpreadPattern: DeprecatedSyntaxWarningLocation(location: spread.get),
        )
    let (_, stop) = p.expectOne(tkRightParen)
    (arguments, spread, stop)
  else:
    (@[], none(SrcSpan), upnameEnd)

proc expectConstructorPattern(
  p: var Parser, module: Option[(int, string, int)], position: PatternPosition
): UntypedPattern =
  ## examples:
  ##   UpName( args )
  let (nameStart, name, nameEnd) = p.expectUpname()
  var start = nameStart
  let (arguments, spread, stop) = p.parseConstructorPatternArguments(nameEnd, position)
  if module.isSome:
    start = module.get[0]
  UntypedPattern(
    kind: paConstructor,
    vConstructor: PatternConstructorFields[Unit](
      location: sp(start, stop),
      nameLocation: sp(nameStart, nameEnd),
      arguments: arguments,
      module: (
        if module.isSome: some((module.get[1], sp(module.get[0], module.get[2])))
        else: none((string, SrcSpan))
      ),
      name: name,
      spread: spread,
      constructor: unknown[PatternConstructor](),
    ),
  )

proc discardPattern(name: string, location: SrcSpan): UntypedPattern =
  UntypedPattern(kind: paDiscard, vDiscard: PatternDiscard[Unit](location: location, name: name))

proc parsePattern(p: var Parser, position: PatternPosition): Option[UntypedPattern] =
  ## The left side of an "=" or a "->"
  var pattern: UntypedPattern
  let t0 = take(p.token0)
  case t0.kind
  # Pattern::Var or Pattern::Constructor start
  of tkName:
    let (start, token, stop) = t0.get
    let name = token.name
    p.advance()

    # A variable is not permitted on the left hand side of a `<>`
    if p.token0.kind == tkConcatenate:
      concatPatternVariableLeftHandSideError(start, stop)

    if p.maybeOne(tkDot).isSome:
      # We're doing this to get a better error message instead of a generic
      # `I was expecting a type`, you can have a look at this issue to get
      # a better idea: https://github.com/gleam-lang/gleam/issues/2841.
      try:
        pattern = p.expectConstructorPattern(some((start, name, stop)), position)
      except ParseFailure as failure:
        parseError(peInvalidModuleTypePattern, sp(start, failure.error.location.stop))
    else:
      pattern = UntypedPattern(
        kind: paVariable,
        vVariable: PatternVariable[Unit](
          origin: VariableOrigin(
            syntax: VariableSyntax(kind: vsVariable, vVariable: name),
            declaration: position.toDeclaration,
          ),
          location: sp(start, stop),
          name: name,
        ),
      )
  # Constructor
  of tkUpName:
    p.token0 = t0
    pattern = p.expectConstructorPattern(none((int, string, int)), position)
  of tkDiscardName:
    let (start, token, stop) = t0.get
    p.advance()

    # A discard is not permitted on the left hand side of a `<>`
    if p.token0.kind == tkConcatenate:
      concatPatternVariableLeftHandSideError(start, stop)

    pattern = discardPattern(token.name, sp(start, stop))
  of tkString:
    let (start, token, stop) = t0.get
    let value = token.value
    p.advance()

    case p.token0.kind
    # String matching with assignment, it could either be a
    # String prefix matching: "Hello, " as greeting <> name -> ...
    # or a full string matching: "Hello, World!" as greeting -> ...
    of tkAs:
      p.advance()
      let (nameStart, name, nameEnd) = p.expectName(inpAsPattern)
      let nameSpan = sp(nameStart, nameEnd)

      if p.token0.kind == tkConcatenate:
        # String prefix matching with assignment
        # "Hello, " as greeting <> name -> ...
        p.advance()
        let (rStart, right, rEnd) = p.expectAssignName()

        # Can't match on suffix literal
        if p.token0.kind == tkConcatenate:
          let (secondConcatStart, _, secondConcatEnd) = p.token0.get
          let suffixEnd = if p.token1.kind == tkString: p.token1.get.stop else: secondConcatEnd
          concatPatternVariableWithSuffix(secondConcatStart, right.name, suffixEnd)

        pattern = UntypedPattern(
          kind: paStringPrefix,
          vStringPrefix: PatternStringPrefix(
            location: sp(start, rEnd),
            leftLocation: sp(start, nameEnd),
            rightLocation: sp(rStart, rEnd),
            leftSideString: value,
            leftSideAssignment: some(
              StringPrefixLeftSideAssignment(
                name: name, nameStartPosition: nameSpan.start, location: sp(stop, nameEnd)
              )
            ),
            rightSideAssignment: right,
          ),
        )
      else:
        # Full string matching with assignment
        return some(
          UntypedPattern(
            kind: paAssign,
            vAssign: PatternAssign[Unit](
              name: name,
              location: nameSpan,
              pattern: box(
                UntypedPattern(
                  kind: paString, vString: PatternString(location: sp(start, stop), value: value)
                )
              ),
            ),
          )
        )

    # String prefix matching with no left side assignment
    # "Hello, " <> name -> ...
    of tkConcatenate:
      p.advance()
      let (rStart, right, rEnd) = p.expectAssignName()

      # Can't match on suffix literal
      if p.token0.kind == tkConcatenate:
        let (secondConcatStart, _, secondConcatEnd) = p.token0.get
        let suffixEnd = if p.token1.kind == tkString: p.token1.get.stop else: secondConcatEnd
        concatPatternVariableWithSuffix(secondConcatStart, right.name, suffixEnd)

      pattern = UntypedPattern(
        kind: paStringPrefix,
        vStringPrefix: PatternStringPrefix(
          location: sp(start, rEnd),
          leftLocation: sp(start, stop),
          rightLocation: sp(rStart, rEnd),
          leftSideString: value,
          leftSideAssignment: none(StringPrefixLeftSideAssignment),
          rightSideAssignment: right,
        ),
      )

    # Full string matching
    # "Hello, World!" -> ...
    else:
      pattern = UntypedPattern(
        kind: paString, vString: PatternString(location: sp(start, stop), value: value)
      )
  of tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    pattern = UntypedPattern(
      kind: paInt,
      vInt: PatternInt(location: sp(start, stop), value: token.intText, intValue: token.intValue),
    )
  of tkFloat:
    let (start, token, stop) = t0.get
    p.advance()
    pattern = UntypedPattern(
      kind: paFloat,
      vFloat: PatternFloat(
        location: sp(start, stop),
        value: token.floatText,
        floatValue: LiteralFloatValue(token.floatValue),
      ),
    )
  of tkHash:
    let start = t0.get.start
    p.advance()
    discard p.expectOne(tkLeftParen)
    let elements = p.seriesOf(
      proc(this: var Parser): Option[UntypedPattern] = this.parsePattern(position), tkComma
    )
    let (_, stop) = p.expectOneFollowingSeries(tkRightParen, "a pattern")
    pattern = UntypedPattern(
      kind: paTuple, vTuple: PatternTuple[Unit](location: sp(start, stop), elements: elements)
    )
  # BitArray
  of tkLtLt:
    let start = t0.get.start
    p.advance()
    let segments = p.seriesOf(
      proc(this: var Parser): Option[UntypedPatternBitArraySegment] =
        this.parseBitArraySegment(
          proc(this: var Parser): Option[UntypedPattern] =
            let inner = this.parsePattern(position)
            if inner.isSome and inner.get.kind == paBitArray:
              parseError(peNestedBitArrayPattern, inner.get.vBitArray.location)
            inner,
          expectBitArrayPatternSegmentArgument,
          bitArraySizeInt,
        ),
      tkComma,
    )
    let (_, stop) = p.expectOneFollowingSeries(tkGtGt, "a bit array segment pattern")
    pattern = UntypedPattern(
      kind: paBitArray, vBitArray: PatternBitArray[Unit](location: sp(start, stop), segments: segments)
    )

  # List
  of tkLeftSquare:
    let start = t0.get.start
    p.advance()
    let (elements, elementsEndWithComma) = p.seriesOfHasTrailingSeparator(
      proc(this: var Parser): Option[UntypedPattern] = this.parsePattern(position), tkComma
    )

    var elementsAfterTail = none(seq[UntypedPattern])
    var dotDotLocation = none((int, int))
    # Upstream `tail` is an `Option<Option<Pattern>>`: whether there is a
    # `..`, and whether a pattern follows it.
    var hasTail = false
    var tailPattern = none(UntypedPattern)
    if p.token0.kind == tkDotDot:
      let (dotDotStart, _, dotDotEnd) = p.token0.get
      dotDotLocation = some((dotDotStart, dotDotEnd))
      if elements.len > 0 and not elementsEndWithComma:
        p.warnings.add DeprecatedSyntaxWarning(
          kind: dsDeprecatedListPattern,
          vDeprecatedListPattern: DeprecatedSyntaxWarningLocation(location: sp(dotDotStart, dotDotEnd)),
        )

      p.advance()
      tailPattern = p.parsePattern(position)
      if p.maybeOne(tkComma).isSome:
        # See if there's a list of items after the tail,
        # like `[..wibble, wobble, wabble]`
        try:
          elementsAfterTail = some(
            p.seriesOf(
              proc(this: var Parser): Option[UntypedPattern] = this.parsePattern(position), tkComma
            )
          )
        except ParseFailure:
          discard
      hasTail = true

    let (stop, closingSquareBracketEnd) = p.expectOneFollowingSeries(tkRightSquare, "a pattern")

    # If there are elements after the tail, return an error
    if elementsAfterTail.isSome and elementsAfterTail.get.len > 0:
      if dotDotLocation.isSome and hasTail and tailPattern.isSome:
        parseError(
          peListPatternSpreadFollowedByElements,
          sp(dotDotLocation.get[0], tailPattern.get.location.stop),
        )
      elif dotDotLocation.isSome and hasTail:
        parseError(
          peListPatternSpreadFollowedByElements, sp(dotDotLocation.get[0], dotDotLocation.get[1])
        )
      else:
        parseError(peListPatternSpreadFollowedByElements, sp(start, stop))

    var tail = none(UntypedPattern)
    if hasTail:
      if tailPattern.isSome:
        if tailPattern.get.kind in {paVariable, paDiscard}:
          # There is a tail and it has a Pattern::Var or Pattern::Discard
          tail = tailPattern
        else:
          # There is a tail and but it has no content, implicit discard
          parseError(peInvalidTailPattern, tailPattern.get.location)
      else:
        tail = some(discardPattern("_", sp(closingSquareBracketEnd - 1, closingSquareBracketEnd)))
    # else: No tail specified

    if elements.len == 0 and tail.isSome:
      let location = sp(start, closingSquareBracketEnd)

      case tail.get.kind
      of paDiscard:
        p.warnings.add DeprecatedSyntaxWarning(
          kind: dsDeprecatedListCatchAllPattern,
          vDeprecatedListCatchAllPattern: DeprecatedSyntaxWarningLocation(location: location),
        )
      of paVariable:
        p.warnings.add DeprecatedSyntaxWarning(
          kind: dsDeprecatedListSpreadAsVariablePattern,
          vDeprecatedListSpreadAsVariablePattern:
            DeprecatedSyntaxWarningDeprecatedListSpreadAsVariablePattern(
              location: location, name: tail.get.vVariable.name
            ),
        )
      else:
        discard

    var boxedTail = none(ref UntypedTailPattern)
    if tail.isSome:
      doAssert dotDotLocation.isSome, "parsed tail with no preceding `..`"
      boxedTail = some(
        box(
          UntypedTailPattern(
            location: sp(dotDotLocation.get[0], tail.get.location.stop), pattern: tail.get
          )
        )
      )
    pattern = UntypedPattern(
      kind: paList,
      vList: PatternList[Unit](
        location: sp(start, closingSquareBracketEnd), elements: elements, tail: boxedTail
      ),
    )

  # No pattern
  else:
    p.token0 = t0
    return none(UntypedPattern)

  if p.token0.kind == tkAs:
    p.advance()
    let (start, name, stop) = p.expectName(inpAsPattern)
    some(
      UntypedPattern(
        kind: paAssign,
        vAssign: PatternAssign[Unit](name: name, location: sp(start, stop), pattern: box(pattern)),
      )
    )
  else:
    some(pattern)

proc addMultiLineClauseHint(error: var ParseError) =
  if error.error.kind == peUnexpectedToken:
    error.error.vUnexpectedToken.hint =
      some("Did you mean to wrap a multi line clause in curly braces?")

proc parsePatterns(p: var Parser, position: PatternPosition): seq[UntypedPattern] =
  p.seriesOf(
    proc(this: var Parser): Option[UntypedPattern] = this.parsePattern(position), tkComma
  )

proc parseFunctionCallInClauseGuard(p: var Parser, start: int) =
  ## Checks if we have an unexpected left parenthesis and returns appropriate
  ## error if it is a function call.
  let paren = p.maybeOne(tkLeftParen)
  if paren.isSome:
    # Upstream: `self.parse_fn_arguments().and(self.expect_one(&Token::RightParen))`.
    # Both are evaluated, whatever the first gives.
    var argumentsOk = true
    try:
      discard p.parseFnArguments()
    except ParseFailure:
      argumentsOk = false
    var closing = none((int, int))
    try:
      closing = some(p.expectOne(tkRightParen))
    except ParseFailure:
      discard
    if argumentsOk and closing.isSome:
      parseError(peCallInClauseGuard, sp(start, closing.get[1]))

    var error = ParseError(
      error: unexpectedToken(tok(tkLeftParen), @[$tok(tkRArrow)]),
      location: sp(paren.get[0], paren.get[1]),
    )
    addMultiLineClauseHint(error)
    raiseParseError(error)

proc parseRecordInClauseGuard(
  p: var Parser, module: string, moduleLocation: SrcSpan
): Option[UntypedClauseGuard] =
  let t0 = take(p.token0)
  if not (t0.kind == tkDot and p.peekToken1() == tkUpName):
    p.token0 = t0
    return none(UntypedClauseGuard)
  p.advance() # dot
  let upname = p.nextToken()
  if upname.kind != tkUpName:
    return none(UntypedClauseGuard)

  let record = p.parseConstRecordFinish(
    moduleLocation.start, some((module, moduleLocation)), upname.get.token.name, upname.get.stop
  )
  if record.isSome:
    some(UntypedClauseGuard(kind: cgConstant, vConstant: record.get))
  else:
    none(UntypedClauseGuard)

proc parseClauseGuardInner(p: var Parser): Option[UntypedClauseGuard]

proc parseCaseClauseGuardBlock(p: var Parser, start: int): UntypedClauseGuard =
  let body = p.parseClauseGuardInner()

  if body.isNone:
    let next = p.nextToken()
    let location = if next.kind == tkRightBrace: sp(start, next.get.stop) else: sp(start, start + 1)

    parseError(peEmptyGuardBlock, location)

  let (_, stop) = p.expectOne(tkRightBrace)
  UntypedClauseGuard(
    kind: cgBlock, vBlock: ClauseGuardBlock[Unit](location: sp(start, stop), value: box(body.get))
  )

proc parseCaseClauseGuardUnit(p: var Parser): Option[UntypedClauseGuard] =
  ## examples
  ## a
  ## 1
  ## a.1
  ## { a }
  ## a || b
  ## a < b || b < c
  let t0 = take(p.token0)
  case t0.kind
  of tkBang:
    let start = t0.get.start
    p.advance()
    let unit = p.parseCaseClauseGuardUnit()
    if unit.isNone:
      parseError(peExpectedValue, sp(start, start))
    return some(
      UntypedClauseGuard(
        kind: cgNot,
        vNot: ClauseGuardNot[Unit](
          location: sp(start, unit.get.location.stop), expression: box(unit.get)
        ),
      )
    )
  of tkName:
    let (start, token, stop) = t0.get
    let name = token.name
    p.advance()

    p.parseFunctionCallInClauseGuard(start)

    let record = p.parseRecordInClauseGuard(name, sp(start, stop))
    var unit =
      if record.isSome:
        record.get
      else:
        UntypedClauseGuard(
          kind: cgVar,
          vVar: ClauseGuardVar[Unit](
            location: sp(start, stop),
            name: name,
            definitionLocation: SrcSpan(),
            # We don't know the origin until type analysis, so
            # we just put `Generated` here as a placeholder.
            origin: VariableOrigin.generated,
          ),
        )

    while true:
      let dot = p.maybeOne(tkDot)
      if dot.isNone:
        return some(unit)
      let dotS = dot.get[0]

      let next = p.nextToken()
      case next.kind
      of tkInt:
        let (_, intToken, intE) = next.get
        let index = parseU64(intToken.intText.replace("_", ""))
        if index.isNone:
          parseError(peInvalidTupleAccess, sp(start, stop))
        unit = UntypedClauseGuard(
          kind: cgTupleIndex,
          vTupleIndex: ClauseGuardTupleIndex[Unit](
            location: sp(dotS, intE), index: index.get, tupl: box(unit)
          ),
        )
      of tkName:
        let (nameStart, labelToken, nameEnd) = next.get
        p.parseFunctionCallInClauseGuard(start)

        unit = UntypedClauseGuard(
          kind: cgFieldAccess,
          vFieldAccess: ClauseGuardFieldAccess[Unit](
            labelLocation: sp(nameStart, nameEnd),
            index: none(uint64),
            label: labelToken.name,
            container: box(unit),
          ),
        )
      of tkNone:
        p.nextTokenUnexpected(@["A positive integer"])
      else:
        parseError(incorrectName(inpVariable), sp(next.get.start, next.get.stop))
  of tkLeftBrace:
    let start = t0.get.start
    p.advance()
    return some(p.parseCaseClauseGuardBlock(start))
  else:
    p.token0 = t0
    let constVal = p.parseConstValueUnit()
    if constVal.isSome:
      # Constant
      return some(UntypedClauseGuard(kind: cgConstant, vConstant: constVal.get))
    else:
      return none(UntypedClauseGuard)

proc parseClauseGuardInner(p: var Parser): Option[UntypedClauseGuard] =
  var opstack: seq[Operator]
  var estack: seq[UntypedClauseGuard]
  var lastOpStart = 0
  var lastOpEnd = 0
  while true:
    let unit = p.parseCaseClauseGuardUnit()
    if unit.isSome:
      estack.add unit.get
    elif estack.len == 0:
      return none(UntypedClauseGuard)
    else:
      parseError(peOpNakedRight, sp(lastOpStart, lastOpEnd))

    let t0 = take(p.token0)
    if t0.isNone:
      break
    let (opS, t, opE) = t0.get

    let prec = t.guardPrecedence
    if prec.isNone:
      # Is not Op
      p.token0 = t0
      break

    # Is Op
    p.advance()
    lastOpStart = opS
    lastOpEnd = opE
    discard handleOperator(some((t0.get, prec.get)), opstack, estack, doReduceClauseGuard)

  handleOperator(none(Operator), opstack, estack, doReduceClauseGuard)

proc parseCaseClauseGuard(p: var Parser): Option[UntypedClauseGuard] =
  ## examples:
  ##   if a
  ##   if a < b
  ##   if a < b || b < c
  let ifToken = p.maybeOne(tkIf)
  if ifToken.isNone:
    return none(UntypedClauseGuard)
  let guard = p.parseClauseGuardInner()
  # If inner clause is none, a warning should be shown to let the user
  # know that empty clauses in guards are deprecated.
  if guard.isNone:
    p.warnings.add DeprecatedSyntaxWarning(
      kind: dsDeprecatedEmptyClauseGuard,
      vDeprecatedEmptyClauseGuard:
        DeprecatedSyntaxWarningLocation(location: sp(ifToken.get[0], ifToken.get[1])),
    )
  guard

proc parseCaseClause(p: var Parser): Option[UntypedClause] =
  ## examples:
  ##   pattern -> expr
  ##   pattern, pattern if -> expr
  ##   pattern, pattern | pattern, pattern if -> expr
  let patterns = p.parsePatterns(ppCaseClause)
  if patterns.len == 0:
    return none(UntypedClause)
  let lead = patterns[0]
  var alternativePatterns: seq[UntypedMultiPattern]
  while true:
    let vbar = p.maybeOne(tkVbar)
    if vbar.isNone:
      break
    let alternative = p.parsePatterns(ppCaseClause)
    if alternative.len == 0:
      parseError(peExpectedPattern, sp(vbar.get[0], vbar.get[1]))
    alternativePatterns.add alternative
  let guard = p.parseCaseClauseGuard()
  var arrow: (int, int)
  try:
    arrow = p.expectOne(tkRArrow)
  except ParseFailure as failure:
    addMultiLineClauseHint(failure.error)
    raise
  let then = p.parseExpression()
  if then.isSome:
    some(
      UntypedClause(
        location: sp(lead.location.start, then.get.location.stop),
        pattern: patterns,
        alternativePatterns: alternativePatterns,
        guard: guard,
        then: then.get,
      )
    )
  elif p.token0.kind == tkDiscardName:
    parseError(incorrectName(inpVariable), sp(p.token0.get.start, p.token0.get.stop))
  else:
    parseError(peExpectedExpr, sp(arrow[0], arrow[1]))

proc parseRecordUpdateArgument(p: var Parser): Option[UntypedRecordUpdateArg] =
  ## examples:
  ##   a: expr
  ##   a:
  let name = p.maybeName()
  if name.isNone:
    return none(UntypedRecordUpdateArg)
  let (start, label, _) = name.get
  let (_, stop) = p.expectOne(tkColon)
  let value = p.parseExpression()
  if value.isSome:
    some(
      UntypedRecordUpdateArg(
        label: label, location: sp(start, value.get.location.stop), value: value.get
      )
    )
  else:
    # Argument supplied with a label shorthand.
    some(
      UntypedRecordUpdateArg(
        label: label,
        location: sp(start, stop),
        value: UntypedExpr(kind: ueVar, vVar: UntypedExprVar(name: label, location: sp(start, stop))),
      )
    )

#
# Parse Functions
#

proc addAnonymousFnHint(error: var ParseError) =
  if error.error.kind == peUnexpectedToken and error.error.vUnexpectedToken.token.kind == tkName:
    error.error.vUnexpectedToken.hint = some("Only module-level functions can be named.")

proc parseFnParam(p: var Parser, isAnon: bool): Option[UntypedArg] =
  ## Parse a single function definition param
  ##
  ## examples:
  ##   _
  ##   a
  ##   a a
  ##   a _
  ##   a _:A
  ##   a a:A
  var start: int
  var names: ArgNames
  var stop: int
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkDiscardName:
    # labeled discard
    let (labelStart, labelToken, tokenEnd) = t0.get
    let (nameStart, nameToken, nameEnd) = t1.get
    if isAnon:
      parseError(peUnexpectedLabel, sp(labelStart, tokenEnd))

    p.advance()
    p.advance()
    start = labelStart
    names = ArgNames(
      kind: agLabelledDiscard,
      vLabelledDiscard: ArgNamesLabelledDiscard(
        name: nameToken.name,
        nameLocation: sp(nameStart, nameEnd),
        label: labelToken.name,
        labelLocation: sp(labelStart, tokenEnd),
      ),
    )
    stop = nameEnd
  elif t0.kind == tkDiscardName:
    # discard
    p.token1 = t1
    p.advance()
    start = t0.get.start
    stop = t0.get.stop
    names = ArgNames(
      kind: agDiscard, vDiscard: ArgNamesDiscard(name: t0.get.token.name, location: sp(start, stop))
    )
  elif t0.kind == tkName and t1.kind == tkName:
    # labeled name
    let (labelStart, labelToken, tokenEnd) = t0.get
    let (nameStart, nameToken, nameEnd) = t1.get
    if isAnon:
      parseError(peUnexpectedLabel, sp(labelStart, tokenEnd))

    p.advance()
    p.advance()
    start = labelStart
    names = ArgNames(
      kind: agNamedLabelled,
      vNamedLabelled: ArgNamesNamedLabelled(
        name: nameToken.name,
        nameLocation: sp(nameStart, nameEnd),
        label: labelToken.name,
        labelLocation: sp(labelStart, tokenEnd),
      ),
    )
    stop = nameEnd
  elif t0.kind == tkName:
    # name
    p.token1 = t1
    p.advance()
    start = t0.get.start
    stop = t0.get.stop
    names = ArgNames(
      kind: agNamed, vNamed: ArgNamesNamed(name: t0.get.token.name, location: sp(start, stop))
    )
  else:
    p.token0 = t0
    p.token1 = t1
    return none(UntypedArg)
  let annotation = p.parseTypeAnnotation(tkColon)
  if annotation.isSome:
    stop = annotation.get.location.stop
  some(UntypedArg(location: sp(start, stop), names: names, annotation: annotation))

proc parseFunction(
  p: var Parser, start: int, public: bool, isAnon: bool, attributes: var Attributes
): Option[UntypedDefinition] =
  ## Starts after "fn"
  ##
  ## examples:
  ##   fn a(name: String) -> String { .. }
  ##   pub fn a(name name: String) -> String { .. }
  let documentation = if isAnon: none((int, string)) else: p.takeDocumentation(start)
  var name = none(SpannedString)
  if not isAnon:
    let (nameStart, n, nameEnd) = p.expectName(inpFunction)
    name = some((sp(nameStart, nameEnd), n))
  let less = p.maybeOne(tkLess)
  if less.isSome:
    parseError(peFunctionDefinitionAngleGenerics, sp(less.get[0], less.get[1]))
  try:
    discard p.expectOne(tkLeftParen)
  except ParseFailure as failure:
    addAnonymousFnHint(failure.error)
    raise
  let arguments = p.seriesOf(
    proc(this: var Parser): Option[UntypedArg] = this.parseFnParam(isAnon), tkComma
  )
  let (_, rparE) = p.expectOneFollowingSeries(tkRightParen, "a function parameter")

  # Check for TypeScript-style return type annotation (:) instead of arrow (->)
  let colon = p.maybeOne(tkColon)
  if colon.isSome:
    parseError(
      unexpectedToken(
        tok(tkColon),
        @[$tok(tkRArrow)],
        some("Return type annotations are written using `->`, not `:`"),
      ),
      sp(colon.get[0], colon.get[1]),
    )

  let returnAnnotation = p.parseTypeAnnotation(tkRArrow)

  var bodyStart = none(int)
  var body: seq[UntypedStatement]
  var stop = rparE
  var endPosition = rparE
  let leftBrace = p.maybeOne(tkLeftBrace)
  if leftBrace.isSome:
    let leftBraceStart = leftBrace.get[0]
    let someBody = p.parseStatementSequence()
    let (_, rightBraceEnd) = p.expectOne(tkRightBrace)
    stop = if returnAnnotation.isSome: returnAnnotation.get.location.stop else: rparE
    if someBody.isNone:
      body = @[
        UntypedStatement(
          kind: stExpression,
          vExpression: UntypedExpr(
            kind: ueTodo,
            vTodo: UntypedExprTodo(
              kind: TodoKind(
                kind: tdEmptyFunction,
                vEmptyFunction: TodoKindEmptyFunction(functionLocation: sp(start, stop)),
              ),
              location: sp(leftBraceStart + 1, rightBraceEnd),
              message: none(ref UntypedExpr),
            ),
          ),
        )
      ]
    else:
      body = someBody.get[0]

    bodyStart = some(leftBraceStart)
    endPosition = rightBraceEnd

  let publicity = p.publicity(public, attributes.internal)
  let deprecation = attributes.deprecated
  attributes.deprecated = Deprecation(kind: dpNotDeprecated)
  some(
    UntypedDefinition(
      kind: dfFunction,
      vFunction: UntypedFunction(
        documentation: documentation,
        location: sp(start, stop),
        endPosition: endPosition,
        bodyStart: bodyStart,
        publicity: publicity,
        name: name,
        arguments: arguments,
        body: body,
        returnAnnotation: returnAnnotation,
        deprecation: deprecation,
        externalErlang: take(attributes.externalErlang),
        externalJavascript: take(attributes.externalJavascript),
        implementations: Implementations.supportingAll,
        purity: puPure,
      ),
    )
  )

proc parseFnArgument(p: var Parser): Option[ParserArg] =
  ## Parse a single function call arg
  ##
  ## examples:
  ##   _
  ##   expr
  ##   a: _
  ##   a: expr
  var label = none((int, string, int))
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkColon:
    p.advance()
    p.advance()
    label = some((t0.get.start, t0.get.token.name, t1.get.stop))
  else:
    p.token0 = t0
    p.token1 = t1

  let value = p.parseExpression()
  if value.isSome:
    let arg =
      if label.isSome:
        CallArg[UntypedExpr](
          implicit: none(ImplicitCallArgOrigin),
          label: some(label.get[1]),
          location: sp(label.get[0], value.get.location.stop),
          value: value.get,
        )
      else:
        CallArg[UntypedExpr](
          implicit: none(ImplicitCallArgOrigin),
          label: none(string),
          location: value.get.location,
          value: value.get,
        )
    return some(ParserArg(kind: pgArg, vArg: box(arg)))

  let discardName = p.maybeDiscardName()
  if discardName.isSome:
    let (nameStart, name, nameEnd) = discardName.get
    if label.isSome:
      some(
        ParserArg(
          kind: pgHole,
          vHole: ParserArgHole(
            label: some(label.get[1]),
            argLocation: sp(label.get[0], nameEnd),
            discardLocation: sp(nameStart, nameEnd),
            name: name,
          ),
        )
      )
    else:
      some(
        ParserArg(
          kind: pgHole,
          vHole: ParserArgHole(
            label: none(string),
            argLocation: sp(nameStart, nameEnd),
            discardLocation: sp(nameStart, nameEnd),
            name: name,
          ),
        )
      )
  elif label.isSome:
    # Argument supplied with a label shorthand.
    let (start, labelName, stop) = label.get
    some(
      ParserArg(
        kind: pgArg,
        vArg: box(
          CallArg[UntypedExpr](
            implicit: none(ImplicitCallArgOrigin),
            label: some(labelName),
            location: sp(start, stop),
            value: UntypedExpr(
              kind: ueVar, vVar: UntypedExprVar(name: labelName, location: sp(start, stop))
            ),
          )
        ),
      )
    )
  else:
    none(ParserArg)

proc parseFnArguments(p: var Parser): seq[ParserArg] =
  ## Parse function call arguments, no parens
  ##
  ## examples:
  ##   _
  ##   expr, expr
  ##   a: _, expr
  ##   a: expr, _, b: _
  p.seriesOf(parseFnArgument, tkComma)

#
# Parse Custom Types
#

proc parseRecordConstructorField(p: var Parser): Option[RecordConstructorArg[Unit]] =
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkColon:
    let (start, nameToken, nameEnd) = t0.get
    let stop = t1.get.stop
    discard p.nextToken()
    discard p.nextToken()
    let doc = p.takeDocumentation(start)
    let typeAst = p.parseType()
    if typeAst.isNone:
      parseError(peExpectedType, sp(start, stop))
    some(
      RecordConstructorArg[Unit](
        label: some((sp(start, nameEnd), nameToken.name)),
        ast: typeAst.get,
        location: sp(start, typeAst.get.location.stop),
        doc: doc,
      )
    )
  else:
    p.token0 = t0
    p.token1 = t1
    let typeAst = p.parseType()
    if typeAst.isNone:
      return none(RecordConstructorArg[Unit])
    let doc =
      if p.token0.isSome: p.takeDocumentation(p.token0.get.start) else: none((int, string))
    some(
      RecordConstructorArg[Unit](
        label: none(SpannedString), ast: typeAst.get, location: typeAst.get.location, doc: doc
      )
    )

proc parseRecordConstructorArguments(p: var Parser): (seq[RecordConstructorArg[Unit]], int) =
  ## examples:
  ##   *no args*
  ##   ()
  ##   (a, b)
  if p.maybeOne(tkLeftParen).isSome:
    let arguments = p.seriesOf(parseRecordConstructorField, tkComma)
    let (_, stop) = p.expectOneFollowingSeries(tkRightParen, "a constructor argument name")
    (arguments, stop)
  else:
    (@[], 0)

proc parseRecordConstructor(p: var Parser): Option[RecordConstructor[Unit]] =
  # The only attribute supported on constructors is @deprecated
  var attributes = Attributes()
  let attrLoc = p.parseAttributes(attributes)

  if attrLoc.isSome:
    # Expecting all but the deprecated atterbutes to be default
    if attributes.externalErlang.isSome or attributes.externalJavascript.isSome or
        attributes.target.isSome or attributes.internal.kind != iaMissing:
      parseError(peUnknownAttributeRecordVariant, attrLoc.get)

  let upname = p.maybeUpname()
  if upname.isNone:
    return none(RecordConstructor[Unit])
  let (nameStart, constructorName, nameEnd) = upname.get
  let documentation = p.takeDocumentation(nameStart)
  let (arguments, argumentsEnd) = p.parseRecordConstructorArguments()

  some(
    RecordConstructor[Unit](
      location: sp(nameStart, max(argumentsEnd, nameEnd)),
      nameLocation: sp(nameStart, nameEnd),
      name: constructorName,
      arguments: arguments,
      documentation: documentation,
      deprecation: attributes.deprecated,
    )
  )

proc invalidRecordConstructorError(
  p: var Parser, typeName: string, public: bool, opaque: bool, nameStart: int, nameEnd: int
): ParseError =
  ## This takes place when we find a lowercase name as a record constructor
  ## variant (that name is passed as an argument here).
  ## We want to look at the following tokens to produce a nice error message:
  ##
  ## ```gleam
  ## pub type Wibble {
  ##   wibble
  ## //^^^^^^ Error, this should be uppercase!
  ## }
  ## ```
  ##
  ## But if the thing looks like a record definition, we want a specialised
  ## error message:
  ##
  ## ```gleam
  ## pub type Wibble {
  ##   wibble: Int,
  ##   wobble: String
  ## }
  ## // Suggest wrapping this in a constructor.
  ## ```
  var fields: seq[RecordConstructorArg[Unit]]
  var fieldsOk = true
  try:
    fields = p.seriesOf(parseRecordConstructorField, tkComma)
  except ParseFailure:
    fieldsOk = false

  if fieldsOk and p.token0.kind == tkRightBrace:
    # If there's a list of fields right inside the type that means the
    # developer might have forgotten to wrap the thing in a constructor.
    # Basically writing something like this:
    #
    # ```gleam
    # pub type Wibble {
    #   String,
    #   wibble: Int,
    # }
    # ```
    #
    # So we want to produce a specialised error message pointing them
    # in the right direction.
    ParseError(
      location: sp(
        (if fields.len > 0: fields[0].location.start else: nameStart),
        (if fields.len > 0: fields[^1].location.stop else: nameEnd),
      ),
      error: ParseErrorType(
        kind: peExpectedRecordConstructor,
        vExpectedRecordConstructor: ParseErrorTypeExpectedRecordConstructor(
          typeName: typeName, public: public, opaque: opaque, fields: fields
        ),
      ),
    )
  else:
    # Otherwise we fall back to telling them the lowercase name should
    # be uppercased!
    ParseError(error: pe(peIncorrectUpName), location: sp(nameStart, nameEnd))

proc expectCustomTypeClose(p: var Parser): int =
  ## Expect the end to a custom type definiton or handle an incorrect
  ## record constructor definition.
  let close = p.maybeOne(tkRightBrace)
  if close.isSome:
    return close.get[1]
  let next = p.nextToken()
  if next.isNone:
    parseError(peUnexpectedEof, sp(0, 0))
  let (start, token, stop) = next.get
  let following = take(p.token0)
  var hint = none(string)
  if token.kind == tkFn or (token.kind == tkPub and following.kind == tkFn):
    let text =
      "Gleam is not an object oriented programming language so\n" &
      "functions are declared separately from types."
    hint = some(core_error.wrap(text))

  parseError(
    unexpectedToken(token, @[$tok(tkRightBrace), "a record constructor"], hint), sp(start, stop)
  )

proc expectTypeName(p: var Parser): (int, string, seq[SpannedString], int, int) =
  ## examples:
  ##   A
  ##   A(one, two)
  let (start, upname, stop) = p.expectUpname()
  let paren = p.maybeOne(tkLeftParen)
  if paren.isSome:
    let arguments = p.seriesOf(
      proc(this: var Parser): Option[(int, string, int)] = this.maybeName(), tkComma
    )
    let (_, parE) = p.expectOneFollowingSeries(tkRightParen, "a name")
    if arguments.len == 0:
      parseError(peTypeDefinitionNoArguments, sp(paren.get[0], parE))
    var arguments2: seq[SpannedString]
    for (argStart, name, argEnd) in arguments.items:
      arguments2.add (sp(argStart, argEnd), name)
    return (start, upname, arguments2, parE, stop)

  let less = p.maybeOne(tkLess)
  if less.isSome:
    var arguments = p.seriesOf(
      proc(this: var Parser): Option[string] =
        # Permit either names (`a`) or upnames (`A`) in this error-handling mode,
        # as upnames are common in other languages. Convert to lowercase so the
        # example is correct whichever was used.
        var name = this.maybeName()
        if name.isNone:
          name = this.maybeUpname()
        if name.isSome: some(name.get[1].toLowerAscii) else: none(string),
      tkComma,
    )

    # If no type arguments were parsed, fall back to a dummy type argument as an example,
    # because `Type()` would be invalid
    if arguments.len == 0:
      arguments = @["value"]

    parseError(
      ParseErrorType(
        kind: peTypeDefinitionAngleGenerics,
        vTypeDefinitionAngleGenerics:
          ParseErrorTypeTypeDefinitionAngleGenerics(name: upname, arguments: arguments),
      ),
      sp(less.get[0], less.get[1]),
    )

  (start, upname, @[], stop, stop)

proc parseCustomType(
  p: var Parser, start: int, public: bool, opaque: bool, attributes: var Attributes
): Option[UntypedDefinition] =
  ## examples:
  ##   type A { A }
  ##   type A { A(String) }
  ##   type Box(inner_type) { Box(inner: inner_type) }
  ##   type NamedBox(inner_type) { Box(String, inner: inner_type) }
  let documentation = p.takeDocumentation(start)
  let (nameStart, name, parameters, stop, nameEnd) = p.expectTypeName()
  let nameLocation = sp(nameStart, nameEnd)

  var constructors: seq[RecordConstructor[Unit]]
  var endPosition = stop
  let t0 = take(p.token0)
  case t0.kind
  # If we see `type Wibble {`, then we know we're parsing a custom type.
  of tkLeftBrace:
    p.advance()

    # If we see a lowercase name, rather than an uppercase one. We
    # know there's a syntax error! So now we can try and provide a
    # nice error message, based on what that wrong code looks like.
    if p.token0.kind == tkName:
      let (wrongStart, _, wrongEnd) = p.token0.get
      raiseParseError(p.invalidRecordConstructorError(name, public, opaque, wrongStart, wrongEnd))

    constructors = p.seriesOf(
      parseRecordConstructor,
      # No separator
      tkNone,
    )
    endPosition = p.expectCustomTypeClose()

  # If we see `type Wibble =` then we know we're parsing a type alias.
  of tkEqual:
    let (equalStart, _, equalEnd) = t0.get
    p.advance()

    if opaque:
      parseError(peOpaqueTypeAlias, sp(start, stop))

    let aliased = p.parseType()
    if aliased.isNone:
      parseError(peExpectedType, sp(equalStart, equalEnd))
    let publicity = p.publicity(public, attributes.internal)
    let deprecation = attributes.deprecated
    attributes.deprecated = Deprecation(kind: dpNotDeprecated)
    return some(
      UntypedDefinition(
        kind: dfTypeAlias,
        vTypeAlias: UntypedTypeAlias(
          documentation: documentation,
          location: sp(start, aliased.get.location.stop),
          publicity: publicity,
          alias: name,
          nameLocation: nameLocation,
          parameters: parameters,
          typeAst: aliased.get,
          deprecation: deprecation,
        ),
      )
    )
  else:
    p.token0 = t0

  let publicity = p.publicity(public, attributes.internal)
  let deprecation = attributes.deprecated
  attributes.deprecated = Deprecation(kind: dpNotDeprecated)
  some(
    UntypedDefinition(
      kind: dfCustomType,
      vCustomType: UntypedCustomType(
        documentation: documentation,
        location: sp(start, stop),
        endPosition: endPosition,
        publicity: publicity,
        opaque: opaque,
        name: name,
        nameLocation: nameLocation,
        parameters: parameters,
        constructors: constructors,
        typedParameters: @[],
        deprecation: deprecation,
        externalErlang: take(attributes.externalErlang),
        externalJavascript: take(attributes.externalJavascript),
      ),
    )
  )

#
# Parse Type Annotations
#

proc parseTypes(p: var Parser): seq[TypeAst] =
  ## For parsing a comma separated "list" of types, for tuple, constructor, and function
  p.seriesOf(parseType, tkComma)

proc parseTypeAnnotation(p: var Parser, startTok: TokenKind): Option[TypeAst] =
  ## examples:
  ##   :a
  ##   :Int
  ##   :Result(a, _)
  ##   :Result(Result(a, e), #(_, String))
  let found = p.maybeOne(startTok)
  if found.isSome:
    let annotation = p.parseType()
    if annotation.isNone:
      parseError(peExpectedType, sp(found.get[0], found.get[1]))
    annotation
  else:
    none(TypeAst)

proc parseTypeNameFinish(
  p: var Parser, start: int, stop: int, name: TypeAstConstructorName
): Option[TypeAst] =
  ## Parse the '( ... )' of a type name
  let paren = p.maybeOne(tkLeftParen)
  if paren.isSome:
    let (leftParenStart, leftParenEnd) = paren.get
    # In case the type is qualified and is missing a name, it doesn't
    # make sense to parse a types list: we don't want to accept
    # something like `wibble.(a, b)`.
    # Instead we want to say that `(` is unexpected and we were
    # expecting a type name instead:
    if name.name.isNone:
      parseError(peExpectedUpName, sp(leftParenStart, leftParenEnd))

    let arguments = p.parseTypes()
    let (_, rightParenEnd) = p.expectOne(tkRightParen)
    return some(
      TypeAst(
        kind: tyConstructor,
        vConstructor: TypeAstConstructor(
          location: sp(start, rightParenEnd),
          name: name,
          arguments: arguments,
          startParentheses: some(leftParenStart),
        ),
      )
    )

  let less = p.maybeOne(tkLess)
  if less.isSome:
    let location = sp(less.get[0], less.get[1])
    var module = none(string)
    var typeName: string
    case name.kind
    of tnQualified:
      # If we're here it means someone has typed something truly
      # wrong that looks like this: `wibble.<`.
      # In this case the hint about angle brackets wouldn't make much
      # sense, so we fallback to just reporting an invalid token
      # error saying we were expecting an uppercase name
      if name.vQualified.name.isNone:
        parseError(peExpectedUpName, location)
      module = some(name.vQualified.module)
      typeName = name.vQualified.name.get[0]
    of tnUnqualified:
      typeName = name.vUnqualified.name

    # Otherwise we try and report a nicer error, suggesting one should
    # use `(a, b)` instead of `<a, b>`.
    let arguments = p.parseTypes()
    parseError(
      ParseErrorType(
        kind: peTypeUsageAngleGenerics,
        vTypeUsageAngleGenerics: ParseErrorTypeTypeUsageAngleGenerics(
          name: typeName, module: module, arguments: arguments
        ),
      ),
      location,
    )

  some(
    TypeAst(
      kind: tyConstructor,
      vConstructor: TypeAstConstructor(
        location: sp(start, stop), name: name, arguments: @[], startParentheses: none(int)
      ),
    )
  )

proc parseType(p: var Parser): Option[TypeAst] =
  ## Parse the type part of a type annotation, same as `parse_type_annotation` minus the ":"
  let t0 = take(p.token0)
  case t0.kind
  # Type hole
  of tkDiscardName:
    let (start, token, stop) = t0.get
    p.advance()
    some(TypeAst(kind: tyHole, vHole: TypeAstHole(location: sp(start, stop), name: token.name)))

  # Tuple
  of tkHash:
    let start = t0.get.start
    p.advance()
    discard p.expectOne(tkLeftParen)
    let elements = p.parseTypes()
    let (_, stop) = p.expectOne(tkRightParen)
    some(TypeAst(kind: tyTuple, vTuple: TypeAstTuple(location: sp(start, stop), elements: elements)))

  # Function
  of tkFn:
    let start = t0.get.start
    p.advance()
    discard p.expectOne(tkLeftParen)
    let arguments = p.seriesOf(parseType, tkComma)
    discard p.expectOneFollowingSeries(tkRightParen, "a type")
    let (arrS, arrE) = p.expectOne(tkRArrow)
    let returns = p.parseType()
    if returns.isNone:
      parseError(peExpectedType, sp(arrS, arrE))
    some(
      TypeAst(
        kind: tyFn,
        vFn: TypeAstFn(
          location: sp(start, returns.get.location.stop),
          returns: box(returns.get),
          arguments: arguments,
        ),
      )
    )

  # Constructor function
  of tkUpName:
    let (start, token, stop) = t0.get
    p.advance()
    let name = TypeAstConstructorName(
      kind: tnUnqualified,
      vUnqualified: TypeAstConstructorNameUnqualified(name: token.name, location: sp(start, stop)),
    )
    p.parseTypeNameFinish(start, stop, name)

  # Constructor Module or type Variable
  of tkName:
    let (start, token, stop) = t0.get
    let module = token.name
    p.advance()

    let dot = p.maybeOne(tkDot)
    if dot.isSome:
      let dotEnd = dot.get[1]
      let moduleLocation = sp(start, stop)
      let upname = p.maybeUpname()
      if upname.isSome:
        let (nameStart, name, nameEnd) = upname.get
        let constructorName = TypeAstConstructorName(
          kind: tnQualified,
          vQualified: TypeAstConstructorNameQualified(
            module: module,
            moduleLocation: moduleLocation,
            dotLocation: dotEnd,
            name: some((name, sp(nameStart, nameEnd))),
          ),
        )
        p.parseTypeNameFinish(start, nameEnd, constructorName)
      else:
        let constructorName = TypeAstConstructorName(
          kind: tnQualified,
          vQualified: TypeAstConstructorNameQualified(
            module: module,
            moduleLocation: moduleLocation,
            dotLocation: dotEnd,
            name: none((string, SrcSpan)),
          ),
        )
        p.parseTypeNameFinish(start, dotEnd, constructorName)
    else:
      some(TypeAst(kind: tyVar, vVar: TypeAstVar(location: sp(start, stop), name: module)))
  else:
    p.token0 = t0
    none(TypeAst)

#
# Parse Imports
#

type ParsedUnqualifiedImports = object
  types: seq[UnqualifiedImport]
  values: seq[UnqualifiedImport]

proc parseUnqualifiedImports(p: var Parser): ParsedUnqualifiedImports =
  ## [Name (as Name)? | UpName (as Name)? ](, [Name (as Name)? | UpName (as Name)?])*,?
  var imports = ParsedUnqualifiedImports()
  while true:
    # parse imports
    let t0 = take(p.token0)
    case t0.kind
    of tkName:
      let (start, token, stop) = t0.get
      p.advance()
      var imported = UnqualifiedImport(
        name: token.name, location: sp(start, stop), namePosition: start, asName: none(string)
      )
      if p.maybeOne(tkAs).isSome:
        let (_, asName, asEnd) = p.expectName(inpAsPattern)
        imported.asName = some(asName)
        imported.location.stop = asEnd
      imports.values.add imported
    of tkUpName:
      let (start, token, stop) = t0.get
      p.advance()
      var imported = UnqualifiedImport(
        name: token.name, location: sp(start, stop), namePosition: start, asName: none(string)
      )
      if p.maybeOne(tkAs).isSome:
        let (_, asName, asEnd) = p.expectUpname()
        imported.asName = some(asName)
        imported.location.stop = asEnd
      imports.values.add imported
    of tkType:
      let start = t0.get.start
      p.advance()
      let (nameStart, name, stop) = p.expectUpname()
      var imported = UnqualifiedImport(
        name: name, location: sp(start, stop), namePosition: nameStart, asName: none(string)
      )
      if p.maybeOne(tkAs).isSome:
        let (_, asName, asEnd) = p.expectUpname()
        imported.asName = some(asName)
        imported.location.stop = asEnd
      imports.types.add imported
    else:
      p.token0 = t0
      break
    # parse comma
    if p.token0.kind == tkComma:
      p.advance()
    else:
      break
  imports

proc parseImport(p: var Parser, importStart: int): Option[UntypedDefinition] =
  ## examples:
  ##   import a
  ##   import a/b
  ##   import a/b.{c}
  ##   import a/b.{c as d} as e
  var start = 0
  var stop: int
  var module = ""
  var lastSegmentEnd: int

  # Gather module names
  while true:
    let (s, name, e) = p.expectName(inpModule)
    if module.len == 0:
      start = s
    else:
      module.add '/'
    module.add name
    stop = e
    lastSegmentEnd = e

    # Useful error for : import a/.{b}
    let slashDot = p.maybeOne(tkSlashDot)
    if slashDot.isSome:
      parseError(peExpectedName, sp(slashDot.get[0] + 1, slashDot.get[0] + 1))

    # break if there's no trailing slash
    if p.maybeOne(tkSlash).isNone:
      break

  let taken = p.takeDocumentation(start)
  let documentation = if taken.isSome: some(taken.get[1]) else: none(string)

  # Gather imports
  var unqualifiedValues: seq[UnqualifiedImport]
  var unqualifiedTypes: seq[UnqualifiedImport]

  let dot = p.maybeOne(tkDot)
  if dot.isSome:
    try:
      discard p.expectOne(tkLeftBrace)
    except ParseFailure as failure:
      # If the module does contain a '/', then it's unlikely that the user
      # intended for the import to be pythonic, so skip this.
      if '/' in module:
        raise

      # Catch `import gleam.io` and provide a more helpful error...
      let e = failure.error
      if not (e.error.kind == peUnexpectedToken and
          e.error.vUnexpectedToken.token.kind in {tkName, tkUpName}):
        raise

      parseError(
        ParseErrorType(
          kind: peIncorrectImportModuleSeparator,
          vIncorrectImportModuleSeparator: ParseErrorTypeIncorrectImportModuleSeparator(
            module: module, item: e.error.vUnexpectedToken.token.name
          ),
        ),
        sp(dot.get[0], dot.get[1]),
      )

    let parsed = p.parseUnqualifiedImports()
    unqualifiedTypes = parsed.types
    unqualifiedValues = parsed.values
    let (_, e) = p.expectOne(tkRightBrace)
    stop = e

  # Parse as_name
  var asName = none((AssignName, SrcSpan))
  let asToken = p.maybeOne(tkAs)
  if asToken.isSome:
    let (_, name, e) = p.expectAssignName()

    stop = e
    asName = some((name, sp(asToken.get[0], stop)))

  some(
    UntypedDefinition(
      kind: dfImport,
      vImport: UntypedImport(
        documentation: documentation,
        location: sp(importStart, stop),
        moduleLocation: sp(start, lastSegmentEnd),
        unqualifiedValues: unqualifiedValues,
        unqualifiedTypes: unqualifiedTypes,
        module: module,
        asName: asName,
      ),
    )
  )

#
# Parse Constants
#

proc parseModuleConst(
  p: var Parser, start: int, public: bool, attributes: Attributes
): Option[UntypedDefinition] =
  ## examples:
  ##   const a = 1
  ##   const a:Int = 1
  ##   pub const a:Int = 1
  let (nameStart, name, nameEnd) = p.expectName(inpConstant)
  let documentation = p.takeDocumentation(nameStart)

  let annotation = p.parseTypeAnnotation(tkColon)

  let (eqS, eqE) = p.expectOne(tkEqual)
  let value = p.parseConstValue()
  if value.isNone:
    parseError(peNoValueAfterEqual, sp(eqS, eqE))
  some(
    UntypedDefinition(
      kind: dfModuleConstant,
      vModuleConstant: UntypedModuleConstant(
        documentation: documentation,
        location: sp(
          start,
          # End after the type annotation if it's there, otherwise after the name
          max((if annotation.isSome: annotation.get.location.stop else: 0), nameEnd),
        ),
        publicity: p.publicity(public, attributes.internal),
        name: name,
        nameLocation: sp(nameStart, nameEnd),
        annotation: annotation,
        value: box(value.get),
        deprecation: attributes.deprecated,
        implementations: Implementations.supportingAll,
      ),
    )
  )

proc parseConstValue(p: var Parser): Option[UntypedConstant] =
  ## examples:
  ##   1
  ##   "hi"
  ##   True
  ##   [1,2,3]
  ##   wibble <> "wobble"
  # uses the simple operator parser algorithm
  var opstack: seq[Operator]
  var estack: seq[UntypedConstant]
  var lastOpStart = 0
  var lastOpEnd = 0

  while true:
    let unit = p.parseConstValueUnit()
    if unit.isSome:
      estack.add unit.get
    elif estack.len == 0:
      return none(UntypedConstant)
    else:
      parseError(peOpNakedRight, sp(lastOpStart, lastOpEnd))

    let t0 = take(p.token0)
    if t0.isNone:
      break
    let (operatorStart, operator, operatorEnd) = t0.get

    let prec = precedence(operator)
    if prec.isNone:
      p.token0 = t0
      break

    if operator.kind == tkPipe:
      parseError(
        unexpectedToken(
          operator, @["<>", "A new definition"], some("Pipelines are not allowed in constants")
        ),
        sp(operatorStart, operatorEnd),
      )

    # Is Op
    p.advance()
    lastOpStart = operatorStart
    lastOpEnd = operatorEnd
    discard handleOperator(some((t0.get, prec.get)), opstack, estack, doReduceConstant)

  handleOperator(none(Operator), opstack, estack, doReduceConstant)

proc constVar(
  location: SrcSpan, module: Option[(string, SrcSpan)], name: string
): UntypedConstant =
  UntypedConstant(
    kind: coVar,
    vVar: ConstantVar[Unit](
      location: location, module: module, name: name, constructor: none(ref ValueConstructor)
    ),
  )

proc parseConstValueUnit(p: var Parser): Option[UntypedConstant] =
  let t0 = take(p.token0)
  case t0.kind
  of tkTodo:
    let (start, _, tokenEnd) = t0.get
    p.advance()
    let message = p.maybeParseConstantAsMessage()
    let stop = if message.isSome: message.get[].location.stop else: tokenEnd
    some(
      UntypedConstant(
        kind: coTodo, vTodo: ConstantTodo[Unit](location: sp(start, stop), message: message)
      )
    )
  of tkString:
    let (start, token, stop) = t0.get
    p.advance()
    some(
      UntypedConstant(
        kind: coString, vString: ConstantString(value: token.value, location: sp(start, stop))
      )
    )
  of tkFloat:
    let (start, token, stop) = t0.get
    p.advance()
    some(
      UntypedConstant(
        kind: coFloat,
        vFloat: ConstantFloat(
          value: token.floatText,
          location: sp(start, stop),
          floatValue: LiteralFloatValue(token.floatValue),
        ),
      )
    )
  of tkInt:
    let (start, token, stop) = t0.get
    p.advance()
    some(
      UntypedConstant(
        kind: coInt,
        vInt: ConstantInt(value: token.intText, intValue: token.intValue, location: sp(start, stop)),
      )
    )
  of tkHash:
    let start = t0.get.start
    p.advance()
    discard p.expectOne(tkLeftParen)
    let elements = p.seriesOf(parseConstValue, tkComma)
    let (_, stop) = p.expectOneFollowingSeries(tkRightParen, "a constant value")
    some(
      UntypedConstant(
        kind: coTuple, vTuple: ConstantTuple[Unit](elements: elements, location: sp(start, stop))
      )
    )
  of tkLeftSquare:
    let start = t0.get.start
    p.advance()

    let (elements, elementsEndWithComma) = p.seriesOfHasTrailingSeparator(parseConstValue, tkComma)

    # Parse an optional tail
    var tail = none(ref UntypedConstant)
    var elementsAfterTail = none(seq[UntypedConstant])
    var dotDotLocation = none((int, int))

    # If there are no elements, we still want to parse a tail so
    # that we can report a better error message.
    if elementsEndWithComma or elements.len == 0:
      let dotDot = p.maybeOne(tkDotDot)
      if dotDot.isSome:
        dotDotLocation = dotDot
        let tailValue = p.parseConstValue()
        if tailValue.isSome:
          tail = some(box(tailValue.get))
        if p.maybeOne(tkComma).isSome:
          # See if there's a list of items after the tail,
          # like `[..wibble, wobble, wabble]`
          try:
            elementsAfterTail = some(p.seriesOf(parseConstValue, tkComma))
          except ParseFailure:
            discard

        if tail.isSome:
          # Give a better error when there are two lists being
          # concatenated like `[..wibble, ..wabble, woo]`, or if
          # there are elements after the tail.
          let second = p.maybeOne(tkDotDot)
          if second.isSome:
            try:
              discard p.parseConstValue()
            except ParseFailure:
              discard

            if elementsAfterTail.isNone or elementsAfterTail.get.len == 0:
              parseError(
                ParseErrorType(
                  kind: peListSpreadWithAnotherSpread,
                  vListSpreadWithAnotherSpread: ParseErrorTypeListSpreadWithAnotherSpread(
                    firstSpreadLocation: sp(dotDot.get[0], dotDot.get[1])
                  ),
                ),
                sp(second.get[0], second.get[1]),
              )

    let (_, stop) = p.expectOneFollowingSeries(tkRightSquare, "a constant value")

    # Return errors for malformed lists
    if dotDotLocation.isSome and tail.isNone:
      parseError(peListSpreadWithoutTail, sp(dotDotLocation.get[0], dotDotLocation.get[1]))
    if tail.isSome and elements.len == 0 and
        (elementsAfterTail.isNone or elementsAfterTail.get.len == 0):
      parseError(peListSpreadWithoutElements, sp(start, stop))

    if elementsAfterTail.isSome and elementsAfterTail.get.len > 0:
      if dotDotLocation.isSome and tail.isSome:
        parseError(
          peListSpreadFollowedByElements, sp(dotDotLocation.get[0], tail.get[].location.stop)
        )
      else:
        parseError(peListSpreadFollowedByElements, sp(start, stop))

    some(
      UntypedConstant(
        kind: coList,
        vList: ConstantList[Unit](elements: elements, location: sp(start, stop), tail: tail),
      )
    )
  # BitArray
  of tkLtLt:
    let start = t0.get.start
    p.advance()
    let segments = p.seriesOf(
      proc(this: var Parser): Option[UntypedConstantBitArraySegment] =
        this.parseBitArraySegment(parseConstValue, expectConstInt, bitArrayConstInt),
      tkComma,
    )
    let (_, stop) = p.expectOneFollowingSeries(tkGtGt, "a bit array segment")
    some(
      UntypedConstant(
        kind: coBitArray,
        vBitArray: ConstantBitArray[Unit](location: sp(start, stop), segments: segments),
      )
    )
  of tkUpName:
    let (start, token, stop) = t0.get
    p.advance()
    p.parseConstRecordFinish(start, none((string, SrcSpan)), token.name, stop)
  of tkName:
    let (start, token, nameEnd) = t0.get
    let name = token.name
    if p.peekToken1() == tkDot:
      let moduleEnd = nameEnd
      p.advance() # name
      p.advance() # dot

      let next = take(p.token0)
      case next.kind
      of tkUpName:
        p.advance() # upname
        p.parseConstRecordFinish(
          start, some((name, sp(start, moduleEnd))), next.get.token.name, next.get.stop
        )
      of tkName:
        p.advance() # name

        if p.token0.kind == tkLeftParen:
          let parenEnd = p.token0.get.stop
          p.advance()
          p.functionCallInConstant(start, parenEnd)
        else:
          some(
            constVar(
              sp(start, next.get.stop), some((name, sp(start, moduleEnd))), next.get.token.name
            )
          )
      of tkNone:
        parseError(peUnexpectedEof, sp(0, 0))
      else:
        parseError(
          unexpectedToken(next.get.token, @["A lowercase name", "An uppercase name"]),
          sp(next.get.start, next.get.stop),
        )
    else:
      p.advance() # name

      if p.token0.kind == tkLeftParen:
        let parenEnd = p.token0.get.stop
        p.advance()
        p.functionCallInConstant(start, parenEnd)
      else:
        some(constVar(sp(start, nameEnd), none((string, SrcSpan)), name))

  # Helpful error for fn
  of tkFn:
    parseError(peNotConstType, sp(t0.get.start, t0.get.stop))
  else:
    p.token0 = t0
    none(UntypedConstant)

proc parseConstRecordArgument(p: var Parser): Option[CallArg[UntypedConstant]] =
  ## examples:
  ##  name: const
  ##  const
  ##  name:
  var label = none((int, string, int))
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkColon:
    # Named arg
    p.advance()
    p.advance()
    label = some((t0.get.start, t0.get.token.name, t1.get.stop))
  else:
    # Unnamed arg
    p.token0 = t0
    p.token1 = t1

  let value = p.parseConstValue()
  if value.isSome:
    if label.isSome:
      some(
        CallArg[UntypedConstant](
          implicit: none(ImplicitCallArgOrigin),
          location: sp(label.get[0], value.get.location.stop),
          value: value.get,
          label: some(label.get[1]),
        )
      )
    else:
      some(
        CallArg[UntypedConstant](
          implicit: none(ImplicitCallArgOrigin),
          location: value.get.location,
          value: value.get,
          label: none(string),
        )
      )
  elif label.isSome:
    # Argument supplied with a label shorthand.
    let (start, labelName, stop) = label.get
    some(
      CallArg[UntypedConstant](
        implicit: none(ImplicitCallArgOrigin),
        location: sp(start, stop),
        label: some(labelName),
        value: constVar(sp(start, stop), none((string, SrcSpan)), labelName),
      )
    )
  else:
    none(CallArg[UntypedConstant])

proc parseConstRecordUpdateArgument(p: var Parser): Option[RecordUpdateArg[UntypedConstant]] =
  var start: int
  var label: string
  var labelEnd: int
  let t0 = take(p.token0)
  let t1 = take(p.token1)
  if t0.kind == tkName and t1.kind == tkColon:
    # Named arg - required for record updates
    p.advance()
    p.advance()
    start = t0.get.start
    label = t0.get.token.name
    labelEnd = t1.get.stop
  elif t0.kind == tkName:
    # Unnamed arg or other - return error since record updates require labels
    let (nameStart, nameToken, nameEnd) = t0.get
    p.token0 = t0
    p.token1 = t1

    # Check if this is label shorthand (name without colon)
    # In this case, use the name as both label and value
    let value = p.parseConstValue()
    if value.isSome and value.get.location == sp(nameStart, nameEnd):
      return some(
        RecordUpdateArg[UntypedConstant](
          label: nameToken.name, location: sp(nameStart, nameEnd), value: value.get
        )
      )
    else:
      p.token0 = t0
      parseError(peExpectedName, sp(nameStart, nameEnd))
  else:
    p.token0 = t0
    p.token1 = t1
    return none(RecordUpdateArg[UntypedConstant])

  let value = p.parseConstValue()
  if value.isSome:
    some(
      RecordUpdateArg[UntypedConstant](
        label: label, location: sp(start, value.get.location.stop), value: value.get
      )
    )
  else:
    # Label shorthand: field without value means field: field
    some(
      RecordUpdateArg[UntypedConstant](
        label: label,
        location: sp(start, labelEnd),
        value: constVar(sp(start, labelEnd), none((string, SrcSpan)), label),
      )
    )

proc parseConstRecordFinish(
  p: var Parser, start: int, module: Option[(string, SrcSpan)], name: string, stop: int
): Option[UntypedConstant] =
  ## Parse the '( .. )' of a const type constructor
  let paren = p.maybeOne(tkLeftParen)
  if paren.isNone:
    return some(
      UntypedConstant(
        kind: coRecord,
        vRecord: ConstantRecord[Unit](
          location: sp(start, stop),
          argumentsStartPosition: stop,
          module: module,
          name: name,
          arguments: none(seq[CallArg[UntypedConstant]]),
          fieldMap: unknown[FieldMap](),
          recordConstructor: none(ref ValueConstructor),
        ),
      )
    )
  let parS = paren.get[0]
  let spread = p.maybeOne(tkDotDot)
  if spread.isSome:
    let dotDotStart = spread.get[0]
    let value = p.parseConstValue()
    if value.isNone:
      parseError(peUnexpectedEof, sp(parS, parS + 2))
    let record = RecordBeingUpdated[UntypedConstant](
      location: sp(dotDotStart, value.get.location.stop), base: box(value.get)
    )

    var updateArguments: seq[RecordUpdateArg[UntypedConstant]]
    if p.maybeOne(tkComma).isSome:
      updateArguments = p.seriesOf(parseConstRecordUpdateArgument, tkComma)

    let (_, parE) =
      p.expectOneFollowingSeries(tkRightParen, "a constant record update argument")

    let constructorLocation = sp(start, stop)

    some(
      UntypedConstant(
        kind: coRecordUpdate,
        vRecordUpdate: ConstantRecordUpdate[Unit](
          location: sp(start, parE),
          constructorLocation: constructorLocation,
          module: module,
          name: name,
          record: record,
          arguments: updateArguments,
          fieldMap: unknown[FieldMap](),
        ),
      )
    )
  else:
    let arguments = p.seriesOf(parseConstRecordArgument, tkComma)

    let dotDot = p.maybeOne(tkDotDot)
    if dotDot.isSome:
      var value = none(UntypedConstant)
      try:
        value = p.parseConstValue()
      except ParseFailure:
        discard
      if value.isNone:
        parseError(
          unexpectedToken(tok(tkDotDot), @[$tok(tkRightParen)]), sp(dotDot.get[0], dotDot.get[1])
        )
      let updateLocation = sp(dotDot.get[0], value.get.location.stop)

      discard p.expectOneFollowingSeries(tkRightParen, "a constant record argument")

      parseError(peRecordUpdateAfterFields, updateLocation)

    let (_, parE) = p.expectOneFollowingSeries(tkRightParen, "a constant record argument")

    some(
      UntypedConstant(
        kind: coRecord,
        vRecord: ConstantRecord[Unit](
          location: sp(start, parE),
          argumentsStartPosition: stop,
          module: module,
          name: name,
          arguments: some(arguments),
          fieldMap: unknown[FieldMap](),
          recordConstructor: none(ref ValueConstructor),
        ),
      )
    )

proc expectExpression(p: var Parser): UntypedExpr =
  let expression = p.parseExpression()
  if expression.isSome:
    return expression.get
  p.nextTokenUnexpected(@["An expression"])

proc expectExpressionUnit(p: var Parser, context: ExpressionUnitContext): UntypedExpr =
  let expression = p.parseExpressionUnit(context)
  if expression.isSome:
    return expression.get
  p.nextTokenUnexpected(@["An expression"])

#
# Attributes
#

proc parseTargetAttribute(p: var Parser, start, stop: int, attributes: var Attributes): int =
  let (parenStart, parenEnd) = p.expectOne(tkLeftParen)
  let target = p.expectTarget(sp(parenStart, parenEnd))
  if attributes.target.isSome:
    parseError(peDuplicateAttribute, sp(start, stop))
  let (_, closeEnd) = p.expectOne(tkRightParen)
  if attributes.target.isSome:
    parseError(peDuplicateAttribute, sp(start, closeEnd))
  attributes.target = some(target)
  closeEnd

proc parseExternalAttribute(p: var Parser, start, stop: int, attributes: var Attributes): int =
  let (_, targetName, _) = p.expectName(inpTarget)

  var target: Target
  case targetName
  of "erlang": target = tgErlang
  of "javascript": target = tgJavaScript
  else: parseError(peUnknownTarget, sp(start, stop))

  discard p.expectOne(tkComma)
  let (_, module, _) = p.expectString()
  discard p.expectOne(tkComma)
  let (_, function, _) = p.expectString()
  discard p.maybeOne(tkComma)
  let (_, closeEnd) = p.expectOne(tkRightParen)

  if attributes.hasExternalFor(target):
    parseError(peDuplicateAttribute, sp(start, closeEnd))

  attributes.setExternalFor(target, some((module, function, sp(start, closeEnd))))
  closeEnd

proc parseDeprecatedAttribute(p: var Parser, start, stop: int, attributes: var Attributes): int =
  try:
    discard p.expectOne(tkLeftParen)
  except ParseFailure:
    parseError(peExpectedDeprecationMessage, sp(start, stop))
  if attributes.deprecated.isDeprecated:
    parseError(peDuplicateAttribute, sp(start, stop))
  var message: string
  try:
    message = p.expectString()[1]
  except ParseFailure:
    parseError(peExpectedDeprecationMessage, sp(start, stop))
  let (_, closeEnd) = p.expectOne(tkRightParen)
  attributes.deprecated =
    Deprecation(kind: dpDeprecated, vDeprecated: DeprecationDeprecated(message: message))
  closeEnd

proc parseInternalAttribute(p: var Parser, start, stop: int, attributes: var Attributes): int =
  case attributes.internal.kind
  # If `internal` is present that means that we have already run into
  # another `@internal` annotation, so it results in a `DuplicateAttribute`
  # error.
  of iaPresent:
    parseError(peDuplicateAttribute, sp(start, stop))
  of iaMissing:
    attributes.internal = InternalAttribute(kind: iaPresent, vPresent: sp(start, stop))
    stop

proc parseAttribute(p: var Parser, start: int, attributes: var Attributes): int =
  # Parse the name of the attribute.

  let (_, name, stop) = p.expectName(inpAttribute)

  case name
  of "external":
    if p.maybeOne(tkLeftParen).isNone:
      parseError(peExpectedExternalArguments, sp(start, stop))
    p.parseExternalAttribute(start, stop, attributes)
  of "target":
    p.parseTargetAttribute(start, stop, attributes)
  of "deprecated":
    p.parseDeprecatedAttribute(start, stop, attributes)
  of "internal":
    p.parseInternalAttribute(start, stop, attributes)
  else:
    parseError(peUnknownAttribute, sp(start, stop))

proc parseAttributes(p: var Parser, attributes: var Attributes): Option[SrcSpan] =
  var attributesSpan = none(SrcSpan)

  while true:
    let at = p.maybeOne(tkAt)
    if at.isNone:
      break
    let (start, stop) = at.get
    if attributesSpan.isNone:
      attributesSpan = some(sp(start, stop))

    let attributeEnd = p.parseAttribute(start, attributes)
    attributesSpan = some(sp(attributesSpan.get.start, attributeEnd))

  attributesSpan

#
# Definitions and the module (upstream these come first)
#

proc parseDefinition(p: var Parser): Option[TargetedDefinition] =
  var attributes = Attributes()
  let location = p.parseAttributes(attributes)

  var def = none(UntypedDefinition)
  let t0 = take(p.token0)
  let k0 = t0.kind
  let k1 = p.token1.kind
  let start = if t0.isSome: t0.get.start else: 0
  # Imports
  if k0 == tkImport:
    p.advance()
    def = p.parseImport(start)
  # Module Constants
  elif k0 == tkConst:
    p.advance()
    def = p.parseModuleConst(start, false, attributes)
  elif k0 == tkPub and k1 == tkConst:
    p.advance()
    p.advance()
    def = p.parseModuleConst(start, true, attributes)

  # Function
  elif k0 == tkFn:
    p.advance()
    def = p.parseFunction(start, false, false, attributes)
  elif k0 == tkPub and k1 == tkFn:
    p.advance()
    p.advance()
    def = p.parseFunction(start, true, false, attributes)

  # Custom Types, and Type Aliases
  elif k0 == tkType:
    p.advance()
    def = p.parseCustomType(start, false, false, attributes)
  elif k0 == tkPub and k1 == tkOpaque:
    p.advance()
    p.advance()
    discard p.expectOne(tkType)
    def = p.parseCustomType(start, true, true, attributes)
  elif k0 == tkPub and k1 == tkType:
    p.advance()
    p.advance()
    def = p.parseCustomType(start, true, false, attributes)
  elif k0 == tkOpaque and k1 == tkType:
    # A private opaque type makes no sense! We still want to parse it
    # and return an error later during the analysis phase.
    p.advance()
    p.advance()
    def = p.parseCustomType(start, false, true, attributes)
  else:
    p.token0 = t0

  if def.isSome and (def.get.isFunction or def.get.isCustomType):
    some(TargetedDefinition(definition: def.get, target: attributes.target))
  elif def.isSome and location.isNone:
    some(TargetedDefinition(definition: def.get, target: attributes.target))
  elif location.isSome and attributes.hasFunctionOnly:
    parseError(peExpectedFunctionDefinition, location.get)
  elif def.isSome:
    some(TargetedDefinition(definition: def.get, target: attributes.target))
  elif location.isSome:
    parseError(peExpectedDefinition, location.get)
  else:
    none(TargetedDefinition)

#
# Misc Helpers
#

proc makeCall*(
  fun: UntypedExpr, arguments: seq[ParserArg], start, stop, openParenthesis: int
): UntypedExpr =
  ## Parsing a function call into the appropriate structure
  var holeLocation = none(SrcSpan)

  var callArguments: seq[CallArg[UntypedExpr]]
  for argument in arguments:
    case argument.kind
    of pgArg:
      callArguments.add argument.vArg[]
    of pgHole:
      let hole = argument.vHole
      if holeLocation.isSome:
        parseError(peTooManyArgHoles, sp(start, stop))

      holeLocation = some(hole.discardLocation)
      if hole.name != "_":
        parseError(
          unexpectedToken(
            Token(kind: tkName, name: hole.name), @["An expression", "An underscore"]
          ),
          hole.argLocation,
        )

      callArguments.add CallArg[UntypedExpr](
        implicit: none(ImplicitCallArgOrigin),
        label: hole.label,
        location: hole.argLocation,
        value: UntypedExpr(
          kind: ueVar, vVar: UntypedExprVar(location: hole.discardLocation, name: CAPTURE_VARIABLE)
        ),
      )

  let call = UntypedExpr(
    kind: ueCall,
    vCall: UntypedExprCall(
      location: sp(start, stop),
      fun: box(fun),
      arguments: callArguments,
      openParenthesis: openParenthesis,
    ),
  )

  if holeLocation.isNone:
    # A normal call
    call
  else:
    # An anon function using the capture syntax run(_, 1, 2)
    UntypedExpr(
      kind: ueFn,
      vFn: UntypedExprFn(
        location: call.location,
        endOfHeadByteIndex: call.location.stop,
        kind: FunctionLiteralKind(
          kind: flCapture, vCapture: FunctionLiteralKindCapture(hole: holeLocation.get)
        ),
        arguments: @[
          UntypedArg(
            location: holeLocation.get,
            annotation: none(TypeAst),
            names: ArgNames(
              kind: agNamed,
              vNamed: ArgNamesNamed(name: CAPTURE_VARIABLE, location: holeLocation.get),
            ),
          )
        ],
        body: @[UntypedStatement(kind: stExpression, vExpression: call)],
        returnAnnotation: none(TypeAst),
      ),
    )

#
# Public Interface
#

func ok[T](value: T): ParseResult[T] =
  ParseResult[T](isOk: true, value: value)

func err[T](error: ParseError): ParseResult[T] =
  ParseResult[T](isOk: false, error: error)

proc parseModule*(src: string, warnings: var ParserWarnings): ParseResult[Parsed] =
  ## Parses a module. `src` must be valid UTF-8.
  ##
  ## Upstream this also takes the path of the module, only to put it in the
  ## warnings it emits: here the caller gets the warnings and knows the path.
  var parser = initParser(src)
  try:
    var failure = none(ParseError)
    var definitions: seq[TargetedDefinition]
    try:
      definitions = parser.seriesOf(parseDefinition, tkNone)
    except ParseFailure as e:
      failure = some(e.error)
    parser.ensureNoErrorsOrRemainingInput(failure)
    let module = UntypedModule(
      name: "",
      documentation: @[],
      definitions: definitions,
      names: initNames(),
      unusedDefinitionPositions: initHashSet[int](),
    )
    warnings.deprecatedSyntax.add parser.warnings
    warnings.detachedDocComments.add parser.detachedDocComments
    ok(Parsed(module: module, extra: parser.extra))
  except ParseFailure as e:
    err[Parsed](e.error)

#
# Test Interface
#

proc parseStatementSequence*(src: string): ParseResult[seq[UntypedStatement]] =
  ## Upstream this exists only for the tests (`#[cfg(test)]`).
  var parser = initParser(src)
  try:
    var failure = none(ParseError)
    var expr = none((seq[UntypedStatement], int))
    try:
      expr = parser.parseStatementSequence()
    except ParseFailure as e:
      failure = some(e.error)
    parser.ensureNoErrorsOrRemainingInput(failure)
    if expr.isSome:
      ok(expr.get[0])
    else:
      err[seq[UntypedStatement]](ParseError(error: pe(peExpectedExpr), location: sp(0, 0)))
  except ParseFailure as e:
    err[seq[UntypedStatement]](e.error)

proc parseConstValue*(src: string): ParseResult[UntypedConstant] =
  ## Upstream this exists only for the tests (`#[cfg(test)]`).
  var parser = initParser(src)
  try:
    var failure = none(ParseError)
    var expr = none(UntypedConstant)
    try:
      expr = parser.parseConstValue()
    except ParseFailure as e:
      failure = some(e.error)
    parser.ensureNoErrorsOrRemainingInput(failure)
    if expr.isSome:
      ok(expr.get)
    else:
      err[UntypedConstant](ParseError(error: pe(peExpectedExpr), location: sp(0, 0)))
  except ParseFailure as e:
    err[UntypedConstant](e.error)
