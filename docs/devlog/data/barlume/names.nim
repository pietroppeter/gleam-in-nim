## Barlume's name resolution: a syntax tree in, the same tree out with every name replaced
## by the unique symbol it refers to, and a list of the names that refer to nothing.
## It is ours, not a port. The `#--- name` lines mark the parts the posts show.
import std/[tables, sets, editdistance]
import ast

#--- scope
type
  Scope = ref object
    # a name as written -> its unique symbol
    symbols: Table[string, string]
    # the scope around this one, or nil
    up: Scope

  NameError* = object
    at*: int
    message*: string

  Resolver = object
    scope: Scope             # the innermost one
    types: HashSet[string]   # the other namespace
    counts: CountTable[string]
    errors: seq[NameError]

func lookup(scope: Scope, name: string): string =
  ## The symbol a name refers to, or "".
  var s = scope
  while s != nil:
    if name in s.symbols: return s.symbols[name]
    s = s.up
  ""

proc open(r: var Resolver) =
  r.scope = Scope(up: r.scope)

proc close(r: var Resolver) =
  r.scope = r.scope.up

proc declare(r: var Resolver, name: string): string =
  ## A new local: total becomes total.0, the
  ## next total of this function total.1.
  result = name & "." & $r.counts[name]
  r.counts.inc name
  r.scope.symbols[name] = result
#--- end

#--- unknown
func closest(scope: Scope, name: string): string =
  ## The visible name most like this one.
  # how many edits away it may be
  var best = min(3, (name.len + 1) div 2)
  var s = scope
  while s != nil:
    for candidate in s.symbols.keys:
      let d = editDistance(name, candidate)
      if d < best: (best, result) = (d, candidate)
    s = s.up

proc unknown(r: var Resolver, name: string, at: int) =
  var message = "I do not know any `" & name & "`"
  let near = r.scope.closest(name)
  if near.len > 0:
    message.add ". Did you mean `" & near & "`?"
  r.errors.add NameError(at: at, message: message)
#--- end

#--- pattern
proc resolve(r: var Resolver, p: Pattern): Pattern =
  result = Pattern(kind: p.kind, text: p.text,
                   start: p.start, stop: p.stop)
  case p.kind
  of pkVar:
    # a pattern variable is a definition
    result.text = r.declare(p.text)
  of pkConstructor:
    # a constructor is a use
    if r.scope.lookup(p.text).len == 0:
      r.unknown(p.text, p.start)
    for arg in p.args:
      result.args.add r.resolve(arg)
  else: discard
#--- end

#--- expr
proc resolve(r: var Resolver, e: Expr): Expr =
  case e.kind
  of ekInt, ekString:
    result = e
  of ekVar:
    # a use: find what it refers to
    result = Expr(kind: ekVar)
    result.text = r.scope.lookup(e.text)
    if result.text.len == 0:
      r.unknown(e.text, e.start)
      result.text = e.text & ".?"
  of ekBinary:
    result = Expr(kind: ekBinary, op: e.op)
    result.left = r.resolve(e.left)
    result.right = r.resolve(e.right)
  of ekCall:
    result = Expr(kind: ekCall)
    result.callee = r.resolve(e.callee)
    for arg in e.args:
      result.args.add r.resolve(arg)
  of ekBlock:
    # a block is a scope
    result = Expr(kind: ekBlock)
    r.open
    for s in e.statements:
      # first the value, in the scope so far,
      let value = r.resolve(s.value)
      # then the name, for what follows
      let name =
        if s.name.len > 0: r.declare(s.name)
        else: ""
      result.statements.add Statement(
        name: name, value: value)
    r.close
  of ekCase:
    result = Expr(kind: ekCase)
    result.subject = r.resolve(e.subject)
    for clause in e.clauses:
      # each clause is a scope: its pattern
      # defines names for its own body only
      r.open
      let pattern = r.resolve(clause.pattern)
      result.clauses.add Clause(pattern: pattern,
        then: r.resolve(clause.then))
      r.close
  result.start = e.start
  result.stop = e.stop
#--- end

#--- module
proc resolve*(module: Module): tuple[
    module: Module, errors: seq[NameError]] =
  var r = Resolver(scope: Scope())
  r.types = ["Int", "String"].toHashSet

  proc global(r: var Resolver, name: string, at: int) =
    if name in r.scope.symbols:
      r.errors.add NameError(at: at,
        message: "`" & name & "` is defined twice")
    r.scope.symbols[name] = name

  # first pass: every top level name, so that
  # the order of definitions does not matter
  for t in module.types:
    if t.name in r.types:
      r.errors.add NameError(at: t.start, message:
        "the type `" & t.name & "` is defined twice")
    r.types.incl t.name
    for c in t.constructors: r.global(c.name, c.start)
  for f in module.functions: r.global(f.name, f.start)

  # second pass: the insides
  for t in module.types:
    for c in t.constructors:
      for field in c.fields:
        if field notin r.types:
          r.errors.add NameError(at: c.start, message:
            "I do not know any type `" & field & "`")
  result.module.types = module.types
  for f in module.functions:
    var resolved = f
    r.counts.clear
    r.open   # the parameters are a scope
    for param in resolved.params.mitems:
      param = r.declare(param)
    resolved.body = r.resolve(f.body)
    r.close
    result.module.functions.add resolved
  result.errors = r.errors
#--- end
