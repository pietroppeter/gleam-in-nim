## Barlume's type checker: a resolved tree in (see names.nim), the type of every expression
## and every function out, and a list of the places where types do not fit. Inference in the
## style of Gleam's: type variables that are unbound, linked or generic, and unification.
## It is ours, not a port. The `#--- name` lines mark the parts the posts show.
import std/[tables, hashes, strutils, sets]
import lexer, ast

#--- type
type
  TypeKind* = enum tyNamed, tyFn, tyVar

  Type* = ref object
    case kind*: TypeKind
    of tyNamed:
      # Int, String, Bool, Shape
      name*: string
    of tyFn:
      # fn(params) -> ret
      params*: seq[Type]
      ret*: Type
    of tyVar:
      # a type not known yet: a number, and,
      # once we find out, a link to what it is
      id*: int
      link*: Type
      # or a type that may be anything, for good
      generic*: bool
#--- end

  TypeError* = object
    at*: int
    message*: string

  Typed* = object
    ## What the checker found out.
    functions*: OrderedTable[string, Type]
    constructors*: Table[string, Type]
    of_expr*: Table[Expr, Type]
    errors*: seq[TypeError]

  Checker = object
    env: Table[string, Type]   # symbol -> type
    nextId: int
    typed: Typed

func hash*(e: Expr): Hash = hash(cast[pointer](e))

func named(name: string): Type = Type(kind: tyNamed, name: name)
let
  tInt = named("Int")
  tString = named("String")
  tBool = named("Bool")

#--- prune
func prune*(t: Type): Type =
  ## Follow the links: what this type is,
  ## as far as we know now.
  result = t
  while result.kind == tyVar and result.link != nil:
    result = result.link
#--- end

#--- show
func show(t: Type, names: var Table[int, string]): string =
  let t = prune(t)
  case t.kind
  of tyNamed: t.name
  of tyVar:
    # variables are shown as a, b, c
    if t.id notin names:
      names[t.id] = $chr(ord('a') + names.len)
    names[t.id]
  of tyFn:
    var params: seq[string]
    for p in t.params: params.add show(p, names)
    "fn(" & params.join(", ") & ") -> " &
      show(t.ret, names)

func `$`*(t: Type): string =
  var names: Table[int, string]
  show(t, names)
#--- end

#--- fresh
proc fresh(c: var Checker): Type =
  ## A new unknown.
  inc c.nextId
  Type(kind: tyVar, id: c.nextId)
#--- end

#--- unify
func occursIn(v, t: Type): bool =
  ## Is the variable v somewhere inside t?
  let t = prune(t)
  case t.kind
  of tyVar: t == v
  of tyNamed: false
  of tyFn:
    for p in t.params:
      if v.occursIn(p): return true
    v.occursIn(t.ret)

proc unify(a, b: Type): bool =
  ## Make two types the same, by filling in
  ## unknowns. False if they cannot be.
  let (a, b) = (prune(a), prune(b))
  if a == b: return true
  if a.kind == tyVar and not a.generic:
    if a.occursIn(b): return false
    # now we know what a is
    a.link = b
    return true
  if b.kind == tyVar and not b.generic:
    return unify(b, a)
  if a.kind == tyNamed and b.kind == tyNamed:
    return a.name == b.name
  if a.kind == tyFn and b.kind == tyFn:
    if a.params.len != b.params.len: return false
    for i in 0 ..< a.params.len:
      if not unify(a.params[i], b.params[i]):
        return false
    return unify(a.ret, b.ret)
  false
#--- end

#--- expect
proc expect(c: var Checker, found, wanted: Type,
            at: int) =
  # show both with the same letters
  var names: Table[int, string]
  let f = show(found, names)
  let w = show(wanted, names)
  if not unify(found, wanted):
    c.typed.errors.add TypeError(at: at,
      message: "I expected " & w & " and found " & f)
#--- end

#--- generalise
proc generalise(t: Type) =
  ## Whatever is still unknown when a function
  ## is finished may be anything, for ever.
  let t = prune(t)
  case t.kind
  of tyVar: t.generic = true
  of tyNamed: discard
  of tyFn:
    for p in t.params: generalise(p)
    generalise(t.ret)

proc instantiate(c: var Checker, t: Type,
                 copies: var Table[int, Type]): Type =
  ## A copy for one use: each generic variable
  ## becomes a new unknown.
  let t = prune(t)
  case t.kind
  of tyNamed: t
  of tyVar:
    if not t.generic: return t
    if t.id notin copies: copies[t.id] = c.fresh
    copies[t.id]
  of tyFn:
    var copy = Type(kind: tyFn)
    for p in t.params:
      copy.params.add c.instantiate(p, copies)
    copy.ret = c.instantiate(t.ret, copies)
    copy
#--- end

#--- pattern
proc check(c: var Checker, p: Pattern, wanted: Type) =
  ## A pattern must fit the type of what it
  ## is matched against.
  case p.kind
  of pkDiscard: discard
  of pkVar: c.env[p.text] = wanted
  of pkInt: c.expect(tInt, wanted, p.start)
  of pkString: c.expect(tString, wanted, p.start)
  of pkConstructor:
    if p.text notin c.typed.constructors: return
    let constructor = c.typed.constructors[p.text]
    var fields: seq[Type]
    var made = constructor
    if constructor.kind == tyFn:
      fields = constructor.params
      made = constructor.ret
    c.expect(made, wanted, p.start)
    if p.args.len != fields.len:
      c.typed.errors.add TypeError(at: p.start,
        message: p.text & " has " & $fields.len &
          " fields and this pattern has " & $p.args.len)
    else:
      for i, arg in p.args: c.check(arg, fields[i])
#--- end

#--- infer
proc infer(c: var Checker, e: Expr): Type =
  case e.kind
  of ekInt: result = tInt
  of ekString: result = tString
  of ekVar:
    if e.text in c.env:
      # each use of a generic function
      # gets its own copy of its type
      var copies: Table[int, Type]
      result = c.instantiate(c.env[e.text], copies)
    else:
      # an unknown name: carry on
      result = c.fresh
  of ekBinary:
    let left = c.infer(e.left)
    let right = c.infer(e.right)
    if e.op == tkEqualEqual:
      # == compares two of the same type
      c.expect(right, left, e.right.start)
      result = tBool
    else:
      # + - * / < > want numbers
      c.expect(left, tInt, e.left.start)
      c.expect(right, tInt, e.right.start)
      result =
        if e.op in {tkLess, tkGreater}: tBool
        else: tInt
  of ekCall:
    # whatever is called must be a function from
    # these arguments to something: call it ret
    let callee = c.infer(e.callee)
    var wanted = Type(kind: tyFn, ret: c.fresh)
    for arg in e.args:
      wanted.params.add c.infer(arg)
    c.expect(callee, wanted, e.start)
    result = wanted.ret
  of ekBlock:
    for s in e.statements:
      result = c.infer(s.value)
      if s.name.len > 0: c.env[s.name] = result
  of ekCase:
    let subject = c.infer(e.subject)
    result = c.fresh
    for clause in e.clauses:
      c.check(clause.pattern, subject)
      # every clause gives the same type
      c.expect(c.infer(clause.then), result,
               clause.then.start)
  c.typed.of_expr[e] = result
#--- end

func calls(e: Expr, found: var seq[string]) =
  ## The names an expression uses.
  case e.kind
  of ekInt, ekString: discard
  of ekVar: found.add e.text
  of ekBinary: (calls(e.left, found); calls(e.right, found))
  of ekCall:
    calls(e.callee, found)
    for arg in e.args: calls(arg, found)
  of ekBlock:
    for s in e.statements: calls(s.value, found)
  of ekCase:
    calls(e.subject, found)
    for clause in e.clauses: calls(clause.then, found)

#--- module
proc check*(module: Module): Typed =
  ## Give it the tree that names.resolve made.
  var c = Checker()

  # constructors: their types are written
  # in the type definition
  for t in module.types:
    for constructor in t.constructors:
      var made = named(t.name)
      if constructor.fields.len > 0:
        made = Type(kind: tyFn, ret: made)
        for field in constructor.fields:
          made.params.add named(field)
      c.env[constructor.name] = made
      c.typed.constructors[constructor.name] = made

  # functions: unknown for now
  var functions: Table[string, Function]
  for f in module.functions:
    functions[f.name] = f
    c.env[f.name] = c.fresh

  # a function is inferred after the ones it uses
  var done: HashSet[string]
  proc inferFunction(c: var Checker, f: Function) =
    if f.name in done: return
    done.incl f.name
    var used: seq[string]
    calls(f.body, used)
    for name in used:
      if name in functions:
        c.inferFunction(functions[name])
    var signature = Type(kind: tyFn)
    for param in f.params:
      c.env[param] = c.fresh
      signature.params.add c.env[param]
    signature.ret = c.infer(f.body)
    c.expect(signature, c.env[f.name], f.start)
    generalise(c.env[f.name])

  for f in module.functions: c.inferFunction(f)
  for f in module.functions:
    c.typed.functions[f.name] = c.env[f.name]
  c.typed
#--- end
