## Barlume's exhaustiveness checker: every `case` of a typed tree in, a decision tree out,
## with the patterns it forgot and the clauses it can never reach. The algorithm is the one
## of Jules Jacobs' note "How to compile pattern matching", which Gleam's follows.
## It is ours, not a port. The `#--- name` lines mark the parts the posts show.
import std/[tables, sets, strutils, sequtils]
import ast, types

#--- rows
type
  Test = object
    # "this variable is of this shape"
    variable: string
    pattern: Pattern

  Row = object
    # one clause: what is still to be tested,
    tests: seq[Test]
    # the names its pattern gave to variables,
    bindings: seq[(string, string)]
    # and which clause it was
    clause: int
#--- end

#--- decision
  DecisionKind* = enum dkLeaf, dkFail, dkSwitch

  Decision* = ref object
    case kind*: DecisionKind
    of dkLeaf:
      # run this clause, with these names
      clause*: int
      bindings*: seq[(string, string)]
    of dkFail:
      # nothing matches
      discard
    of dkSwitch:
      # look at this variable
      variable*: string
      branches*: seq[Branch]
      # for numbers and strings: anything else
      otherwise*: Decision

  Branch* = object
    # if it was made by this constructor,
    constructor*: string
    # call its fields this,
    fields*: seq[string]
    # and go on from here
    then*: Decision
#--- end

  CaseReport* = object
    ## What was found out about one `case`.
    at*: int
    tree*: Decision
    missing*: seq[string]
    unreachable*: seq[int]

  Compiler = object
    constructorsOf: Table[string, seq[Constructor]]
    typeOf: Table[string, string]   # variable -> type
    made: int
    reached: HashSet[int]

#--- helpers
proc fresh(c: var Compiler, typeName: string): string =
  ## A new variable, for a field.
  inc c.made
  result = "$" & $c.made
  c.typeOf[result] = typeName

func testOn(row: Row, variable: string): int =
  ## Which test of the row is on this variable?
  for i, test in row.tests:
    if test.variable == variable: return i
  -1

proc moveVariables(row: var Row) =
  ## `x is name` always matches: it is not a
  ## test, it is a name for x.
  var tests: seq[Test]
  for test in row.tests:
    case test.pattern.kind
    of pkDiscard: discard
    of pkVar:
      row.bindings.add (test.pattern.text, test.variable)
    else: tests.add test
  row.tests = tests
#--- end

#--- compile
proc compile(c: var Compiler, rows: seq[Row]): Decision =
  var rows = rows
  for row in rows.mitems: moveVariables(row)

  # no clause left: this value matches nothing
  if rows.len == 0:
    return Decision(kind: dkFail)

  # the first clause has nothing left to test:
  # it matches, and the ones after it lose
  if rows[0].tests.len == 0:
    c.reached.incl rows[0].clause
    return Decision(kind: dkLeaf,
      clause: rows[0].clause, bindings: rows[0].bindings)

  # otherwise: pick a variable the first clause
  # tests, and split on what it can be
  let variable = rows[0].tests[0].variable
  result = Decision(kind: dkSwitch, variable: variable)
  let typeName = c.typeOf.getOrDefault(variable)

  if typeName in c.constructorsOf:
    # a custom type: one branch per constructor
    for constructor in c.constructorsOf[typeName]:
      var fields: seq[string]
      for field in constructor.fields:
        fields.add c.fresh(field)
      var rest: seq[Row]
      for row in rows:
        let i = row.testOn(variable)
        if i < 0:
          # does not care: stays in every branch
          rest.add row
        elif row.tests[i].pattern.text == constructor.name:
          # wants this constructor: stays, and
          # now tests the fields instead
          var row = row
          let pattern = row.tests[i].pattern
          row.tests.delete i
          for j, arg in pattern.args:
            row.tests.add Test(variable: fields[j],
                               pattern: arg)
          rest.add row
        # wants another constructor: gone
      result.branches.add Branch(
        constructor: constructor.name, fields: fields,
        then: c.compile(rest))
  else:
    # a number or a string: one branch per
    # literal that appears, and one for the rest
    var literals: seq[string]
    for row in rows:
      let i = row.testOn(variable)
      if i >= 0 and row.tests[i].pattern.text notin literals:
        literals.add row.tests[i].pattern.text
    for literal in literals:
      var rest: seq[Row]
      for row in rows:
        let i = row.testOn(variable)
        if i < 0: rest.add row
        elif row.tests[i].pattern.text == literal:
          var row = row
          row.tests.delete i
          rest.add row
      result.branches.add Branch(
        constructor: literal, then: c.compile(rest))
    result.otherwise = c.compile(
      rows.filterIt(it.testOn(variable) < 0))
#--- end

#--- missing
func show(variable: string,
          known: Table[string, Branch]): string =
  ## What we know about a variable, as a pattern.
  if variable notin known: return "_"
  let branch = known[variable]
  result = branch.constructor
  if branch.fields.len > 0:
    result.add "(" & branch.fields.mapIt(
      show(it, known)).join(", ") & ")"

proc missing(d: Decision, subject: string,
             known: var Table[string, Branch],
             found: var seq[string]) =
  ## Walk to every dkFail, remembering the
  ## choices made on the way down.
  case d.kind
  of dkLeaf: discard
  of dkFail: found.add show(subject, known)
  of dkSwitch:
    for branch in d.branches:
      known[d.variable] = branch
      missing(branch.then, subject, known, found)
      known.del d.variable
    if d.otherwise != nil:
      missing(d.otherwise, subject, known, found)
#--- end

#--- render
func render*(d: Decision, indent = 0): string =
  ## A decision tree as indented text.
  let pad = repeat(' ', indent)
  case d.kind
  of dkFail: result = pad & "no clause matches!\n"
  of dkLeaf:
    result = pad & "clause " & $(d.clause + 1)
    if d.bindings.len > 0:
      result.add " with " & d.bindings.mapIt(
        it[0] & " = " & it[1]).join(", ")
    result.add "\n"
  of dkSwitch:
    result = pad & "look at " & d.variable & "\n"
    for branch in d.branches:
      result.add pad & "  is it " & branch.constructor
      if branch.fields.len > 0:
        result.add "(" & branch.fields.join(", ") & ")"
      result.add "?\n" & render(branch.then, indent + 4)
    if d.otherwise != nil:
      result.add pad & "  anything else?\n" &
        render(d.otherwise, indent + 4)
#--- end

#--- check
proc checkCase(c: var Compiler, e: Expr, typed: Typed): CaseReport =
  # the thing examined gets a name and a type
  let subject =
    if e.subject.kind == ekVar: e.subject.text
    else: "$subject"
  let subjectType = prune(typed.of_expr[e.subject])
  if subjectType.kind == tyNamed:
    c.typeOf[subject] = subjectType.name
  # each clause starts as one test
  var rows: seq[Row]
  for i, clause in e.clauses:
    rows.add Row(clause: i, tests: @[
      Test(variable: subject, pattern: clause.pattern)])
  c.reached.clear
  result.at = e.start
  result.tree = c.compile(rows)
  var known: Table[string, Branch]
  result.tree.missing(subject, known, result.missing)
  result.missing = result.missing.deduplicate
  for i in 0 ..< e.clauses.len:
    if i notin c.reached: result.unreachable.add i
#--- end

proc walk(c: var Compiler, e: Expr, typed: Typed, reports: var seq[CaseReport]) =
  case e.kind
  of ekInt, ekString, ekVar: discard
  of ekBinary: (c.walk(e.left, typed, reports); c.walk(e.right, typed, reports))
  of ekCall:
    c.walk(e.callee, typed, reports)
    for arg in e.args: c.walk(arg, typed, reports)
  of ekBlock:
    for s in e.statements: c.walk(s.value, typed, reports)
  of ekCase:
    c.walk(e.subject, typed, reports)
    reports.add c.checkCase(e, typed)
    for clause in e.clauses: c.walk(clause.then, typed, reports)

proc checkCases*(module: Module, typed: Typed): seq[CaseReport] =
  ## Every `case` of a module that passed the type checker (see types.check).
  var c = Compiler()
  for t in module.types: c.constructorsOf[t.name] = t.constructors
  for f in module.functions: c.walk(f.body, typed, result)
