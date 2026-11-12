## Barlume's syntax tree: what the parser builds and the later stages read.
## See lexer.nim for what Barlume is. The `#--- name` lines mark the parts the posts show.
import std/strutils
import lexer

#--- expr
type
  ExprKind* = enum
    ekInt, ekString, ekVar,
    ekBinary, ekCall, ekCase, ekBlock

  Expr* = ref object
    # its span in the source
    start*, stop*: int
    case kind*: ExprKind
    of ekInt, ekString, ekVar:
      # 42, "hi", total, Circle
      text*: string
    of ekBinary:
      # tkPlus, tkStar, ...
      op*: TokenKind
      left*, right*: Expr
    of ekCall:
      callee*: Expr
      args*: seq[Expr]
    of ekCase:
      subject*: Expr
      clauses*: seq[Clause]
    of ekBlock:
      statements*: seq[Statement]

  Statement* = object
    # `let name = value`, or just `value`
    # (then the name is "")
    name*: string
    value*: Expr

  Clause* = object
    # pattern -> then
    pattern*: Pattern
    then*: Expr
#--- end

#--- pattern
  PatternKind* = enum
    pkInt, pkString, pkVar, pkDiscard,
    pkConstructor

  Pattern* = ref object
    start*, stop*: int
    kind*: PatternKind
    # 0, "hi", r, _, Circle
    text*: string
    # for a constructor
    args*: seq[Pattern]
#--- end

#--- module
  Function* = object
    name*: string
    public*: bool
    params*: seq[string]
    # always an ekBlock
    body*: Expr
    start*, stop*: int

  Constructor* = object
    name*: string
    fields*: seq[string] # the names of their types
    start*, stop*: int

  CustomType* = object
    name*: string
    constructors*: seq[Constructor]
    start*, stop*: int

  Module* = object
    types*: seq[CustomType]
    functions*: seq[Function]
#--- end

# ------------------------------------------------------------------ showing a tree

const opNames*: array[TokenKind, string] = block:
  var names: array[TokenKind, string]
  names[tkPlus] = "+"; names[tkMinus] = "-"; names[tkStar] = "*"; names[tkSlash] = "/"
  names[tkLess] = "<"; names[tkGreater] = ">"; names[tkEqualEqual] = "=="
  names

func sexp*(pattern: Pattern): string =
  if pattern.kind != pkConstructor or pattern.args.len == 0: return pattern.text
  result = "(" & pattern.text
  for arg in pattern.args: result.add " " & sexp(arg)
  result.add ")"

func parts(expr: Expr): seq[string]

func sexp*(expr: Expr, width = 40, indent = 0): string =
  ## A tree as nested brackets: `(+ 1 (* 2 3))`. The first word says what the node is, the
  ## rest are its children. A node that does not fit in `width` puts each child on a line.
  if expr.kind in {ekInt, ekString, ekVar}: return expr.text
  let ps = parts(expr)
  let flat = "(" & ps.join(" ") & ")"
  if indent + flat.len <= width and '\n' notin flat: return flat
  # too long: the children again, each on its own line and knowing how far in it is
  var children: seq[string]
  case expr.kind
  of ekBinary:
    children = @[sexp(expr.left, width, indent + 2), sexp(expr.right, width, indent + 2)]
  of ekCall:
    children.add sexp(expr.callee, width, indent + 2)
    for arg in expr.args: children.add sexp(arg, width, indent + 2)
  of ekCase:
    children.add sexp(expr.subject, width, indent + 2)
    for clause in expr.clauses:
      children.add "(-> " & sexp(clause.pattern) & " " & sexp(clause.then, width, indent + 6) & ")"
  of ekBlock:
    for statement in expr.statements:
      if statement.name.len > 0:
        children.add "(let " & statement.name & " " & sexp(statement.value, width, indent + 4) & ")"
      else: children.add sexp(statement.value, width, indent + 2)
  else: discard
  result = "(" & ps[0]
  for child in children: result.add "\n" & repeat(' ', indent + 2) & child
  result.add ")"

func parts(expr: Expr): seq[string] =
  ## The head of a node and its children, each on one line.
  const wide = 10_000
  case expr.kind
  of ekInt, ekString, ekVar: @[expr.text]
  of ekBinary: @[opNames[expr.op], sexp(expr.left, wide), sexp(expr.right, wide)]
  of ekCall:
    var ps = @["call", sexp(expr.callee, wide)]
    for arg in expr.args: ps.add sexp(arg, wide)
    ps
  of ekCase:
    var ps = @["case", sexp(expr.subject, wide)]
    for clause in expr.clauses:
      ps.add "(-> " & sexp(clause.pattern) & " " & sexp(clause.then, wide) & ")"
    ps
  of ekBlock:
    var ps = @["block"]
    for statement in expr.statements:
      if statement.name.len > 0: ps.add "(let " & statement.name & " " & sexp(statement.value, wide) & ")"
      else: ps.add sexp(statement.value, wide)
    ps

func sexp*(module: Module, width = 40): string =
  ## A whole module as nested brackets.
  for t in module.types:
    result.add "(type " & t.name
    for c in t.constructors:
      result.add "\n  (" & c.name
      for field in c.fields: result.add " " & field
      result.add ")"
    result.add ")\n"
  for f in module.functions:
    result.add "(" & (if f.public: "pub-fn " else: "fn ") & f.name & " (" & f.params.join(" ") & ")\n  " &
      sexp(f.body, width, 2) & ")\n"
