## Sources for comparing the Nim parser with the reference one. Prints one
## escaped source per line (see lexdump.nim), the input format of
## tests/differential/parse.
##
##   parsefuzz harvest module|statements     the inputs of upstream's parser tests
##   parsefuzz files FILE...                 each file as one source (module mode)
##   parsefuzz gen module|statements|const COUNT SEED
##                                           random sources from a small grammar,
##                                           some of them broken on purpose
##   parsefuzz mutate module|statements|const COUNT SEED FILE...
##                                           pieces of real files (definitions,
##                                           function bodies, constant values)
##                                           with a few tokens changed
##
## The reference parser stops at the first error, so a source broken in many
## places teaches little: most sources get zero, one or two faults.

import std/[os, random, strutils]
import gleam_in_nim/parse/[lexer, token]
import ./[common, harvest, lexdump]

# ---------------------------------------------------------------- harvest

proc harvested(mode: string): seq[string] =
  ## `assert_parse!` and `assert_error!` go through `parse_statement_sequence`,
  ## `assert_parse_module!` and `assert_module_error!` through `parse_module`.
  let wanted =
    if mode == "module": @["assert_parse_module", "assert_module_error"]
    else: @["assert_parse", "assert_error"]
  for item in harvestFile(refDirFrom(""), "compiler-core/src/parse/tests.rs"):
    if item.macroName in wanted and item.args.len > 0 and item.args[0].kind == akString:
      result.add item.args[0].text

# ---------------------------------------------------------------- grammar

type Gen = object
  rng: Rand
  depth: int
  calm: bool  ## this source is meant to parse: no alternative known to be an error
  anon: bool  ## inside the parameters of an anonymous function

const
  names = ["a", "b", "x", "wibble", "wobble", "acc", "list", "int", "size", "unit", "utf8"]
  upnames = ["A", "Ok", "Error", "Wibble", "Wobble", "Some", "None", "Int", "String", "List"]
  discards = ["_", "_x", "_wibble"]
  ints = ["0", "1", "42", "1_000", "0xFF", "0b101", "0o17", "256", "999999999999999999999"]
  floats = ["1.0", "0.5", "1.0e10", "2.5e-3", "1_0.0_1"]
  strings = ["\"\"", "\"hi\"", "\"a\\nb\"", "\"\\u{1F600}\"", "\"wibble wobble\""]
  binops = ["+", "-", "*", "/", "%", "+.", "-.", "*.", "/.", "<", ">", "<=", ">=", "<.",
    ">.", "<=.", ">=.", "==", "!=", "&&", "||", "<>", "|>", "|>", "|>"]
  bitOptions = ["bytes", "int", "float", "bits", "utf8", "utf16", "utf32", "utf8_codepoint",
    "utf16_codepoint", "utf32_codepoint", "signed", "unsigned", "big", "little", "native",
    "size(8)", "size(x)", "size(x + 1)", "size({ x * 2 })", "unit(8)", "8",
    "unit(0)", "unit(300)", "wibble", "unit(x)"]
  safeBitOptions = 21
  faults = [
    "(", ")", "{", "}", "[", "]", ",", ",,", ":", "=", "->", "<-", "..", ".", "|", "#", "@",
    "<", ">", "<<", ">>", "!", "-", "_", "if", "as", "let", "use", "case", "fn", "pub",
    "type", "const", "import", "opaque", "assert", "todo", "panic", "echo", "else", "auto",
    "test", "macro", "derive", "x", "Wibble", "_x", "1", "1.0", "\"s\"", "//c\n", "///d\n",
    "////m\n", "\n\n", ";", "'", "===", "+=", "$", "x.1", "x.y", "x()", "x(_)", "x(_, _)",
    "x: ", "<T>", "x =", "x:", "todo as", "1..2", "wibble.Wobble", "wibble.{", ".{",
  ]

proc pick(g: var Gen, items: openArray[string]): string = g.rng.sample(items)
proc chance(g: var Gen, p: float): bool = g.rng.rand(1.0) < p
proc deep(g: var Gen): bool = g.depth > 4

proc choose(g: var Gen, shallow, safe, all: int): int =
  ## Which alternative of a rule to take. The alternatives are ordered: the
  ## first `shallow` do not recurse, the first `safe` are valid Gleam, the
  ## rest are mistakes the parser has an error for.
  if g.deep: g.rng.rand(0 ..< shallow)
  elif g.calm: g.rng.rand(0 ..< safe)
  else: g.rng.rand(0 ..< all)

proc pickSafe(g: var Gen, items: openArray[string], safe: int): string =
  ## Like `pick`, but only among the first `safe` items when calm.
  if g.calm: items[g.rng.rand(0 ..< safe)] else: g.rng.sample(items)

proc expr(g: var Gen): string
proc pattern(g: var Gen): string
proc typ(g: var Gen): string
proc constant(g: var Gen): string
proc statements(g: var Gen): string

proc sep(g: var Gen): string =
  if g.chance(0.85): " " else: "\n"

proc series(g: var Gen, item: proc(g: var Gen): string, most = 3): string =
  let count = g.rng.rand(0 .. most)
  for i in 0 ..< count:
    if i > 0: result.add ", "
    result.add item(g)
  if count > 0 and g.chance(0.15): result.add ","

proc typ(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  case g.choose(3, 8, 9)
  of 0: g.pick(upnames)
  of 1: g.pick(names)
  of 2: g.pick(discards)
  of 3: g.pick(upnames) & "(" & g.series(typ) & ")"
  of 4: g.pick(names) & "." & g.pick(upnames)
  of 5: g.pick(names) & "." & g.pick(upnames) & "(" & g.series(typ) & ")"
  of 6: "#(" & g.series(typ) & ")"
  of 7: "fn(" & g.series(typ) & ") -> " & g.typ
  else: g.pick(upnames) & "<" & g.series(typ) & ">"

proc bitSegment(g: var Gen, value: string): string =
  result = value
  if g.chance(0.6):
    result.add ":"
    for i in 0 .. g.rng.rand(0 .. 2):
      if i > 0: result.add "-"
      result.add g.pickSafe(bitOptions, safeBitOptions)

proc patternArg(g: var Gen): string =
  case g.rng.rand(0 .. 3)
  of 0: g.pick(names) & ": " & g.pattern
  of 1: g.pick(names) & ":"
  else: g.pattern

proc pattern(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  result =
    case g.choose(6, 15, 17)
    of 0: g.pick(names)
    of 1: g.pick(discards)
    of 2: g.pick(ints)
    of 3: g.pick(floats)
    of 4: g.pick(strings)
    of 5: g.pick(upnames)
    of 6: g.pick(upnames) & "(" & g.series(patternArg) & ")"
    of 7: g.pick(upnames) & "(" & g.series(patternArg) & (if g.chance(0.5): ", .." else: " ..") & ")"
    of 8: g.pick(names) & "." & g.pick(upnames) & "(" & g.series(patternArg) & ")"
    of 9: "#(" & g.series(pattern) & ")"
    of 10: "[" & g.series(pattern) & "]"
    of 11: "[" & g.series(pattern) & (if g.chance(0.5): ", .." else: " ..") &
        g.pickSafe(["", "rest", "_", "_rest", "[]", "rest, x"], 4) & "]"
    of 12: g.pick(strings) & " <> " & g.pickSafe(["rest", "_", "_rest", "Rest", "\"x\""], 3)
    of 13: g.pick(strings) & " as " & g.pick(names) & " <> " & g.pick(["rest", "_"])
    of 14:
      var segments: seq[string]
      for _ in 0 .. g.rng.rand(0 .. 2):
        segments.add g.bitSegment(g.pattern)
      "<<" & segments.join(", ") & ">>"
    of 15: g.pick(names) & " <> " & g.pick(names)
    else: g.pick(names) & "." & g.pick(names)
  if g.chance(0.1): result.add " as " & g.pickSafe(["x", "y", "_x", "X"], 2)

proc guard(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  case g.choose(4, 10, 12)
  of 0: g.pick(names)
  of 1: g.pick(ints)
  of 2: g.pick(strings)
  of 3: g.pick(names) & "." & g.pickSafe(["0", "1", "wibble", "1_0", "Wibble"], 4)
  of 4: g.guard & " " & g.pick(binops[0 ..< 22]) & " " & g.guard
  of 5: "{ " & g.guard & " }"
  of 6: "!" & g.guard
  of 7: g.constant
  of 8: g.pick(names) & "." & g.pick(upnames) & "(" & g.series(constant) & ")"
  of 9: ""
  of 10: g.pick(names) & "(" & g.series(expr) & ")"
  else: "{}"

proc callArg(g: var Gen): string =
  case g.rng.rand(0 .. (if g.calm: 20 else: 7))
  of 0: g.pick(names) & ": " & g.expr
  of 1: g.pick(names) & ":"
  of 2: "_"
  of 3: g.pick(names) & ": _"
  else: g.expr

proc fnParam(g: var Gen): string =
  result = g.pickSafe([g.pick(names), g.pick(discards), g.pick(names) & " " & g.pick(names),
    g.pick(names) & " " & g.pick(discards)], (if g.anon: 2 else: 4))
  if g.chance(0.4): result.add ": " & g.typ

proc clause(g: var Gen): string =
  result = g.pattern
  if g.chance(0.2): result.add ", " & g.pattern
  while g.chance(0.2): result.add " | " & g.pattern
  if g.chance(0.3): result.add " if " & g.guard
  result.add " -> " & g.expr

proc exprUnit(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  result =
    case g.choose(7, 23, 28)
    of 0: g.pick(names)
    of 1: g.pick(ints)
    of 2: g.pick(floats)
    of 3: g.pick(strings)
    of 4: g.pick(upnames)
    of 5: "todo"
    of 6: "panic"
    of 7: g.pick(["todo", "panic"]) & " as " & g.exprUnit
    of 8: "echo " & g.expr
    of 9: "echo " & g.expr & " as " & g.exprUnit
    of 10: "#(" & g.series(expr) & ")"
    of 11: "[" & g.series(expr) & "]"
    of 12: "[" & g.exprUnit & g.pick([", ..", " ..", ".."]) & g.pickSafe(["rest", "[]", "", "a, b"], 2) & "]"
    of 13:
      var segments: seq[string]
      for _ in 0 .. g.rng.rand(0 .. 2):
        segments.add g.bitSegment(g.exprUnit)
      "<<" & segments.join(", ") & ">>"
    of 14:
      g.anon = true
      let params = g.series(fnParam)
      g.anon = false
      "fn(" & params & ")" & (if g.chance(0.3): " -> " & g.typ else: "") &
        " { " & g.statements & " }"
    of 15: "{ " & g.statements & " }"
    of 16:
      var clauses: seq[string]
      for _ in 0 .. g.rng.rand(0 .. 2):
        clauses.add g.clause
      "case " & g.expr & (if g.chance(0.2): ", " & g.expr else: "") & " {" & g.sep &
        clauses.join("\n") & g.sep & "}"
    of 17: "!" & g.exprUnit
    of 18: "-" & g.exprUnit
    of 19: g.exprUnit & "." & g.pick(["0", "1", "wibble", "Wibble", "1_0", ""])
    of 20: g.exprUnit & "(" & g.series(callArg) & ")"
    of 21: g.pick(upnames) & "(.." & g.expr & (if g.chance(0.7): ", " & g.series(callArg) else: "") & ")"
    of 22: g.pick(names) & "." & g.pick(names) & "(" & g.series(callArg) & ")"
    of 23: "if " & g.expr & " { " & g.expr & " }"
    of 24: "(" & g.expr & ")"
    of 25: "fn " & g.pick(names) & "() { 1 }"
    of 26: "fn(" & g.series(fnParam) & ")"
    else: g.pick(upnames) & "(" & g.series(callArg) & ", .." & g.pick(names) & ")"

proc expr(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  result = g.exprUnit
  while not g.deep and g.chance(0.3):
    result.add " " & g.pick(binops) & g.sep & g.exprUnit

proc statement(g: var Gen): string =
  case g.rng.rand(0 .. (if g.calm: 10 else: 11))
  of 0, 1:
    "let " & g.pattern & (if g.chance(0.3): ": " & g.typ else: "") & " = " & g.expr
  of 2:
    "let assert " & g.pattern & " = " & g.expr & (if g.chance(0.4): " as " & g.exprUnit else: "")
  of 3:
    var assignments: seq[string]
    for _ in 0 ..< g.rng.rand(0 .. 2):
      assignments.add g.pattern & (if g.chance(0.2): ": " & g.typ else: "")
    "use " & assignments.join(", ") & (if assignments.len > 0: " " else: "") & "<- " & g.expr
  of 4:
    "assert " & g.expr & (if g.chance(0.4): " as " & g.exprUnit else: "")
  of 11:
    g.pick(["const x = 1", "x = 1", "x: Int = 1", "let x", "let = 1", "let x = _y", "use"])
  else: g.expr

proc statements(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  let count =
    if g.depth == 1: g.rng.rand(1 .. 4)
    elif g.deep: g.rng.rand(0 .. 1)
    else: g.rng.rand(0 .. 3)
  for i in 0 ..< count:
    if i > 0: result.add "\n"
    result.add g.statement

proc constArg(g: var Gen): string =
  case g.rng.rand(0 .. 4)
  of 0: g.pick(names) & ": " & g.constant
  of 1: g.pick(names) & ":"
  else: g.constant

proc constant(g: var Gen): string =
  inc g.depth
  defer: dec g.depth
  result =
    case g.choose(6, 14, 19)
    of 0: g.pick(ints)
    of 1: g.pick(floats)
    of 2: g.pick(strings)
    of 3: g.pick(names)
    of 4: g.pick(upnames)
    of 5: g.pick(names) & "." & g.pick(names)
    of 6: g.pick(names) & "." & g.pick(upnames)
    of 7: "#(" & g.series(constant) & ")"
    of 8: "[" & g.series(constant) & "]"
    of 9: "[" & g.constant & ", .." & g.pickSafe(["rest", "", "rest, x", "a, ..b", "a, ..b, c"], 1) & "]"
    of 10: g.pick(upnames) & "(" & g.series(constArg) & ")"
    of 11: g.pick(names) & "." & g.pick(upnames) & "(" & g.series(constArg) & ")"
    of 12: g.pick(upnames) & "(.." & g.pick(names) & (if g.chance(0.7): ", " & g.series(constArg) else: "") & ")"
    of 13:
      var segments: seq[string]
      for _ in 0 .. g.rng.rand(0 .. 2):
        segments.add g.bitSegment(g.constant)
      "<<" & segments.join(", ") & ">>"
    of 14: g.pick(upnames) & "(" & g.series(constArg) & ", .." & g.pick(names) & ")"
    of 15: g.pick(names) & "(" & g.series(constant) & ")"
    of 16: "todo" & (if g.chance(0.6): " as " & g.pick(["\"m\"", "x", ""]) else: "")
    of 17: g.pick(["fn() { 1 }", "x |> y", "{ 1 }", "-1", "!x"])
    else: g.pick(names) & "." & g.pick(["1", "", "(", "x(1, (2))"])
  while not g.deep and g.chance(0.15):
    result.add " " & g.pickSafe(["<>", "<>", "+", "==", "&&", "|>"], 5) & " " & g.constant

proc attribute(g: var Gen): string =
  g.pickSafe([
    "@external(erlang, \"mod\", \"fun\")", "@external(javascript, \"./ffi.mjs\", \"fun\")",
    "@external(erlang, \"mod\", \"fun\",)", "@target(erlang)", "@target(javascript)",
    "@target(erl)", "@target(js)", "@deprecated(\"use other\")", "@internal",
    "@external(wasm, \"a\", \"b\")", "@external", "@target(wasm)",
    "@target()", "@deprecated", "@deprecated()",
    "@wibble", "@_x", "@external(erlang, \"a\")"], 9) & g.sep

proc constructor(g: var Gen): string =
  if g.chance(0.15): result.add g.pickSafe(["@deprecated(\"no\")\n", "/// doc\n", "// c\n", "@internal\n"], 3)
  result.add g.pick(upnames)
  if g.chance(0.6):
    var fields: seq[string]
    for _ in 0 ..< g.rng.rand(0 .. 3):
      fields.add (if g.chance(0.5): g.pick(names) & ": " else: "") & g.typ
    result.add "(" & fields.join(", ") & (if g.chance(0.1): "," else: "") & ")"

proc definition(g: var Gen): string =
  g.depth = 0
  while g.chance(if g.calm: 0.08 else: 0.25): result.add g.attribute
  if g.chance(0.3): result.add g.pick(["/// A doc\n", "/// Two\n/// lines\n", "// c\n", "//// module\n",
    "/// detached\n// c\n", "\n\n"])
  let public = if g.chance(0.5): "pub " else: ""
  case g.rng.rand(0 .. (if g.calm: 10 else: 11))
  of 0 .. 3:
    result.add public & "fn " & g.pick(names) & "(" & g.series(fnParam) & ")"
    if g.chance(0.4): result.add " -> " & g.typ
    if g.chance(0.9): result.add " {" & g.sep & g.statements & g.sep & "}"
  of 4, 5:
    result.add public & g.pick(["", "", "opaque "]) & "type " & g.pick(upnames)
    if g.chance(0.3):
      let parameters = g.series(proc(g: var Gen): string = g.pick(names))
      result.add "(" & (if g.calm and parameters.len == 0: "a" else: parameters) & ")"
    if g.chance(0.85):
      var constructors: seq[string]
      for _ in 0 ..< g.rng.rand(0 .. 3):
        constructors.add g.constructor
      if not g.calm and g.chance(0.05): constructors.add g.pick(["wibble", "x: Int, y: String", "fn f() {}", "pub fn f() {}"])
      result.add " {" & g.sep & constructors.join("\n") & g.sep & "}"
  of 6:
    result.add public & g.pickSafe(["", "opaque "], 1) & "type " & g.pick(upnames) &
      (if g.chance(0.3): "(a)" else: "") & " = " & g.typ
  of 7, 8:
    result.add public & "const " & g.pick(names) & (if g.chance(0.3): ": " & g.typ else: "") &
      " = " & g.constant
  of 9, 10:
    result.add "import " & g.pickSafe(["gleam/io", "gleam", "a/b/c", "gleam.io", "a/.{b}", "_x", "A"], 3)
    if g.chance(0.4):
      result.add ".{" & g.series(proc(g: var Gen): string =
        g.pickSafe(["x", "X", "type X", "x as y", "X as Y", "type X as Y", "x as _y", "type x"], 6)) & "}"
    if g.chance(0.3): result.add " as " & g.pickSafe(["x", "_", "_x", "X"], 3)
  else:
    result.add g.pick(["type A<T> { A }", "fn f<T>() {}", "pub type A() { A }", "wibble", "pub", "pub opaque",
      "@target(erlang)", "fn f(): Int { 1 }", "fn(x) { x }", "pub fn f(x) -> { x }", "# comment", "1"])

proc generated(g: var Gen, mode: string): string =
  g.depth = 0
  g.anon = false
  g.calm = g.chance(0.6)
  case mode
  of "module":
    for i in 0 ..< g.rng.rand(1 .. 3):
      if i > 0: result.add g.pick(["\n", "\n\n", "\n\n\n"])
      result.add g.definition
  of "statements": result = g.statements
  of "const": result = g.constant
  else: quit "unknown mode: " & mode

# ---------------------------------------------------------------- tokens

type Piece = tuple[start, stop: int, kind: TokenKind]

proc pieces(source: string): seq[Piece] =
  ## The tokens of a source, up to the first lexical error.
  for item in lex(source):
    if not item.isOk: break
    let (start, token, stop) = item.spanned
    if token.kind notin {tkNewLine, tkEndOfFile}:
      result.add (start, stop, token.kind)

proc withFaults(g: var Gen, source: string, most: int): string =
  ## The source with up to `most` token-level faults: a token dropped, doubled,
  ## replaced, swapped with its neighbour, or a new one put in.
  result = source
  for _ in 0 ..< g.rng.rand(0 .. most):
    let tokens = pieces(result)
    if tokens.len == 0: break
    let
      i = g.rng.rand(0 ..< tokens.len)
      (start, stop, _) = tokens[i]
      text = result[start ..< stop]
    case g.rng.rand(0 .. 5)
    of 0: result = result[0 ..< start] & result[stop .. ^1]
    of 1: result = result[0 ..< stop] & " " & text & result[stop .. ^1]
    of 2: result = result[0 ..< start] & g.pick(faults) & result[stop .. ^1]
    of 3:
      if i + 1 < tokens.len:
        let (nextStart, nextStop, _) = tokens[i + 1]
        result = result[0 ..< start] & result[nextStart ..< nextStop] & result[stop ..< nextStart] &
          text & result[nextStop .. ^1]
    of 4: result = result[0 ..< start] & g.pick(faults) & " " & result[start .. ^1]
    else: result = result[0 ..< stop] & " " & g.pick(faults) & result[stop .. ^1]

proc closing(tokens: seq[Piece], open: int): int =
  ## The index of the token closing the bracket at `open`, or -1.
  var depth = 0
  for i in open ..< tokens.len:
    case tokens[i].kind
    of tkLeftBrace, tkLeftParen, tkLeftSquare: inc depth
    of tkRightBrace, tkRightParen, tkRightSquare:
      dec depth
      if depth == 0: return i
    else: discard
  -1

proc definitionsOf(source: string): seq[string] =
  ## The top-level definitions of a module, with the comments before them.
  var current = ""
  for line in source.splitLines:
    let startsDefinition = line.len > 0 and line[0] in {'a' .. 'z', '@'}
    if startsDefinition and current.strip.len > 0 and not current.strip.endsWith(")") and
        not current.splitLines[^2].startsWith("@") and not current.splitLines[^2].startsWith("//"):
      result.add current
      current = ""
    current.add line & "\n"
  if current.strip.len > 0: result.add current

proc bodiesOf(source: string): seq[string] =
  ## The text between the braces of each function, named or anonymous.
  let tokens = pieces(source)
  for i, token in tokens:
    if token.kind != tkFn: continue
    var open = i + 1
    if open < tokens.len and tokens[open].kind == tkName: inc open
    if open >= tokens.len or tokens[open].kind != tkLeftParen: continue
    var j = closing(tokens, open) + 1
    if j == 0: continue
    while j < tokens.len and tokens[j].kind notin {tkLeftBrace, tkFn, tkRightBrace, tkEqual}: inc j
    if j >= tokens.len or tokens[j].kind != tkLeftBrace: continue
    let close = closing(tokens, j)
    if close > j + 1:
      result.add source[tokens[j].stop ..< tokens[close].start].strip

proc constantsOf(source: string): seq[string] =
  ## The values of the constants of a module.
  for definition in definitionsOf(source):
    let tokens = pieces(definition)
    for i, token in tokens:
      if token.kind == tkConst:
        for j in i + 1 ..< tokens.len:
          if tokens[j].kind == tkEqual:
            result.add definition[tokens[j].stop .. ^1].strip
            break
        break

proc partsOf(mode, source: string): seq[string] =
  case mode
  of "module": definitionsOf(source)
  of "statements": bodiesOf(source)
  of "const": constantsOf(source)
  else: quit "unknown mode: " & mode

# ---------------------------------------------------------------- main

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    quit "usage: parsefuzz harvest MODE | files FILE... | gen MODE COUNT SEED | mutate MODE COUNT SEED FILE..."
  case args[0]
  of "harvest":
    for source in harvested(args[1]):
      echo escapeBytes(source)
  of "files":
    for file in args[1 .. ^1]:
      echo escapeBytes(readFile(file))
  of "gen":
    var g = Gen(rng: initRand(parseInt(args[3])))
    for _ in 0 ..< parseInt(args[2]):
      var source = g.generated(args[1])
      if not g.calm and g.chance(0.5): source = g.withFaults(source, 2)
      echo escapeBytes(source)
  of "mutate":
    var g = Gen(rng: initRand(parseInt(args[3])))
    var parts: seq[string]
    for file in args[4 .. ^1]:
      for part in partsOf(args[1], readFile(file)):
        if part.len < 4000: parts.add part
    if parts.len == 0: quit "no parts found in the files"
    for _ in 0 ..< parseInt(args[2]):
      var source = g.rng.sample(parts)
      if args[1] == "module" and g.chance(0.3): source.add "\n" & g.rng.sample(parts)
      echo escapeBytes(g.withFaults(source, 2))
  else:
    quit "unknown command: " & args[0]

main()
