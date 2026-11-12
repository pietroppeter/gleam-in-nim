## Barlume's parser: tokens in, a syntax tree out. Recursive descent, one procedure per rule
## of the grammar, and two stacks for the operators, as in Gleam's parser. It is ours, not a
## port. The `#--- name` lines mark the parts the posts show.
import lexer, ast

#--- parser
type
  Parser = object
    source: string
    tokens: seq[Token]
    # the next token to read
    pos: int

  ParseError* = object of CatchableError
    # where in the source
    at*: int

func peek(p: Parser): TokenKind =
  p.tokens[p.pos].kind

proc advance(p: var Parser): Token =
  result = p.tokens[p.pos]
  if result.kind != tkEndOfFile: inc p.pos

func text(p: Parser, token: Token): string =
  p.source.text(token)

proc fail(p: Parser, wanted: string) =
  let token = p.tokens[p.pos]
  let found =
    if token.kind == tkEndOfFile: "the end of the file"
    else: "`" & p.text(token) & "`"
  raise (ref ParseError)(at: token.start,
    msg: "I was expecting " & wanted &
         " and found " & found)

proc expect(p: var Parser, kind: TokenKind,
            wanted: string): Token =
  if p.peek != kind: p.fail wanted
  p.advance
#--- end

func stop(p: Parser): int =
  ## Where the last token read stopped.
  p.tokens[p.pos - 1].stop

proc parseExpr(p: var Parser): Expr
proc parseBlock(p: var Parser): Expr

#--- pattern
proc parsePattern(p: var Parser): Pattern =
  let token = p.advance
  result = Pattern(start: token.start,
                   text: p.text(token))
  case token.kind
  of tkInt: result.kind = pkInt
  of tkString: result.kind = pkString
  of tkName:
    result.kind =
      if result.text[0] == '_': pkDiscard
      else: pkVar
  of tkUpName:
    result.kind = pkConstructor
    if p.peek == tkLeftParen:
      discard p.advance
      result.args.add p.parsePattern
      while p.peek == tkComma:
        discard p.advance
        result.args.add p.parsePattern
      discard p.expect(tkRightParen, "a `)`")
  else:
    dec p.pos
    p.fail "a pattern"
  result.stop = p.stop
#--- end

#--- case
proc parseCase(p: var Parser): Expr =
  let start = p.expect(tkCase, "`case`").start
  result = Expr(kind: ekCase, start: start)
  result.subject = p.parseExpr
  discard p.expect(tkLeftBrace, "a `{`")
  while p.peek != tkRightBrace:
    let pattern = p.parsePattern
    discard p.expect(tkArrow, "a `->`")
    result.clauses.add Clause(
      pattern: pattern, then: p.parseExpr)
  discard p.advance
  result.stop = p.stop
#--- end

#--- unit
proc parseUnit(p: var Parser): Expr =
  ## What goes between operators.
  case p.peek
  of tkInt, tkString, tkName, tkUpName:
    let token = p.advance
    result =
      case token.kind
      of tkInt: Expr(kind: ekInt)
      of tkString: Expr(kind: ekString)
      else: Expr(kind: ekVar)
    result.text = p.text(token)
    result.start = token.start
    result.stop = token.stop
  of tkLeftBrace: result = p.parseBlock
  of tkCase: result = p.parseCase
  else: p.fail "a value"
  # a unit followed by ( is a call, and
  # the result can be called again: f(1)(2)
  while p.peek == tkLeftParen:
    discard p.advance
    var call = Expr(kind: ekCall, callee: result,
                    start: result.start)
    while p.peek != tkRightParen:
      call.args.add p.parseExpr
      if p.peek != tkRightParen:
        discard p.expect(tkComma, "a `,` or a `)`")
    discard p.advance
    call.stop = p.stop
    result = call
#--- end

#--- precedence
func precedence(kind: TokenKind): int =
  ## How tightly an operator holds what is
  ## around it. Gleam's numbers; 0: no operator.
  case kind
  of tkEqualEqual: 3
  of tkLess, tkGreater: 4
  of tkPlus, tkMinus: 7
  of tkStar, tkSlash: 8
  else: 0
#--- end

#--- expr
proc parseExpr(p: var Parser): Expr =
  # waiting values
  var units: seq[Expr]
  var operators: seq[TokenKind] # waiting operators

  proc reduce() =
    # the top operator takes the top two values
    let right = units.pop
    let left = units.pop
    units.add Expr(kind: ekBinary,
      op: operators.pop, left: left, right: right,
      start: left.start, stop: right.stop)

  units.add p.parseUnit
  while precedence(p.peek) > 0:
    let operator = p.advance.kind
    # whatever waits and holds at least as
    # tightly goes first
    while operators.len > 0 and
        precedence(operators[^1]) >=
        precedence(operator):
      reduce()
    operators.add operator
    units.add p.parseUnit
  while operators.len > 0: reduce()
  units[0]
#--- end

#--- block
proc parseStatement(p: var Parser): Statement =
  if p.peek == tkLet:
    discard p.advance
    let name = p.expect(tkName, "a name")
    discard p.expect(tkEqual, "an `=`")
    Statement(name: p.text(name), value: p.parseExpr)
  else:
    Statement(value: p.parseExpr)

proc parseBlock(p: var Parser): Expr =
  let start = p.expect(tkLeftBrace, "a `{`").start
  result = Expr(kind: ekBlock, start: start)
  result.statements.add p.parseStatement
  while p.peek != tkRightBrace:
    result.statements.add p.parseStatement
  discard p.advance
  result.stop = p.stop
#--- end

#--- definitions
proc parseFunction(p: var Parser,
                   public: bool): Function =
  result.start = p.expect(tkFn, "`fn`").start
  result.public = public
  let name = p.expect(tkName, "a function name")
  result.name = p.text(name)
  discard p.expect(tkLeftParen, "a `(`")
  while p.peek != tkRightParen:
    let param = p.expect(tkName, "a parameter")
    result.params.add p.text(param)
    if p.peek != tkRightParen:
      discard p.expect(tkComma, "a `,` or a `)`")
  discard p.advance
  result.body = p.parseBlock
  result.stop = p.stop

proc parseType(p: var Parser): CustomType =
  result.start = p.expect(tkType, "`type`").start
  let name = p.expect(tkUpName, "a type name")
  result.name = p.text(name)
  discard p.expect(tkLeftBrace, "a `{`")
  while p.peek != tkRightBrace:
    let token = p.expect(tkUpName, "a constructor")
    var constructor = Constructor(
      name: p.text(token), start: token.start)
    if p.peek == tkLeftParen:
      discard p.advance
      while p.peek != tkRightParen:
        let field = p.expect(tkUpName, "a type")
        constructor.fields.add p.text(field)
        if p.peek != tkRightParen:
          discard p.expect(tkComma, "a `,` or a `)`")
      discard p.advance
    constructor.stop = p.stop
    result.constructors.add constructor
  discard p.advance
  result.stop = p.stop

proc parseModule(p: var Parser): Module =
  while p.peek != tkEndOfFile:
    case p.peek
    of tkType: result.types.add p.parseType
    of tkFn:
      result.functions.add p.parseFunction(false)
    of tkPub:
      discard p.advance
      result.functions.add p.parseFunction(true)
    else: p.fail "`fn`, `pub` or `type`"
#--- end

#--- entry
proc parse*(source: string): Module =
  ## A whole program.
  var p = Parser(source: source, tokens: lex(source))
  p.parseModule

proc parseExpression*(source: string): Expr =
  ## One expression, for trying things out.
  var p = Parser(source: source, tokens: lex(source))
  result = p.parseExpr
  if p.peek != tkEndOfFile: p.fail "the end"
#--- end
