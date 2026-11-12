## Tests of the Erlang source builder (`src/gleam_in_nim/erlang_generation.nim`).
##
## Upstream has no tests in the crate `erlang-generation`: the builder is
## tested through the snapshot tests of the Erlang backend, which the port
## cannot run yet. So the tests here are of three kinds:
##
## - golden: 400 random scripts of builder calls, with the output recorded from
##   the reference builder at the pinned commit (`tools/erlcheck.sh golden`
##   regenerates them; `tools/erlcheck.sh fuzz COUNT SEED` runs the same
##   comparison live on as many scripts as you like);
## - a real module: `shapes.erl`, written by the reference `gleam` 1.19.2 for
##   the BEAM post, rebuilt here call by call and compared byte for byte;
## - the small functions: floats, atoms, escapes.
import std/[options, os, strutils, unittest]
import pkg/bigints
import ../tools/erldump
import gleam_in_nim/src_span
import gleam_in_nim/erlang_generation {.all.}

const here = currentSourcePath().parentDir
const golden = here / "golden" / "erlang_builder"

suite "erlang source builder: golden files from the reference builder":
  test "random scripts of calls":
    var expected: seq[string]
    for line in readFile(golden / "fuzz.expected").splitLines:
      if line.startsWith("== "): expected.add ""
      elif line.len > 0: expected[^1].add line & "\n"
    let scripts = parseScripts(readFile(golden / "fuzz.txt"))
    check scripts.len == 400
    check expected.len == scripts.len
    var failures = 0
    var errors = 0
    for i, script in scripts:
      let output = dump(script.calls)
      if output.startsWith("! "): inc errors
      if output != expected[i]:
        inc failures
        if failures <= 5: checkpoint "script " & script.name
    check failures == 0
    # the scripts with a line deleted, repeated or swapped reach the internal errors
    check errors > 30

suite "erlang source builder: a real module, call by call":
  test "shapes.erl as the reference compiler wrote it":
    var b = default(ErlangSourceBuilder)
    let at = initSrcSpan(0, 0)

    proc atom(name: string) = b.atomExpression(at, name)
    proc v(name: string) = b.variable(at, name)
    proc str(content: string) = b.stringExpression(at, content)
    proc int(value: int) = b.intExpression(at, initBigInt(value))
    template tup(body: untyped) =
      block:
        let t = b.startTuple(at)
        body
        b.endTuple(t)
    template builtIn(kind: ErlangBuiltInType, body: untyped) =
      block:
        let t = b.startBuiltInNamedType(kind)
        body
        b.endNamedType(t)
    proc builtIn(kind: ErlangBuiltInType) =
      builtIn(kind): discard
    proc custom(name: string) =
        let t = b.startCustomNamedType(name)
        b.endNamedType(t)
    template union(body: untyped) =
      block:
        let t = b.startUnionType()
        body
        b.endUnionType(t)
    template tupleType(body: untyped) =
      block:
        let t = b.startTupleType()
        body
        b.endTupleType(t)
    template functionType(arguments, returns: untyped) =
      block:
        let a = b.startFunctionType()
        arguments
        let f = b.endFunctionTypeArguments(a)
        returns
        b.endFunctionType(f)
    template spec(name: string, arity: int, arguments, returns: untyped) =
      block:
        let s = b.startFunctionSpec(name, arity)
        functionType(arguments, returns)
        b.endFunctionSpec(s)
    template function(name: string, arguments: openArray[string], body: untyped) =
      block:
        var names: seq[(SrcSpan, string)]
        for argument in arguments: names.add (at, argument)
        let f = b.startFunction(at, name, names.len, names)
        body
        b.endFunction(f)
    template caseOf(subject, clauses: untyped) =
      block:
        let s = b.startCase(at)
        subject
        let c = b.endCaseSubject(s)
        clauses
        b.endCase(c)
    template clauseWhen(pattern, guard, body: untyped) =
      block:
        let p = b.startCaseClause(at)
        pattern
        let g = b.endClausePattern(p)
        guard
        let bd = b.endClauseGuards(g)
        body
        b.endClauseBody(bd)
    template clause(pattern, body: untyped) =
      block:
        clauseWhen(pattern, (discard), body)
    template remote(module, name: string, arguments: untyped) =
      block:
        let c = b.startRemoteCall(at, newErlangModuleName(module), name)
        arguments
        b.endCall(c)
    template local(name: string, arguments: untyped) =
      block:
        let called = b.startCall(at)
        atom(name)
        let c = b.endCalledExpression(called)
        arguments
        b.endCall(c)
    template tuplePattern(body: untyped) =
      block:
        let t = b.startTuplePattern(at)
        body
        b.endTuplePattern(t)
    proc field(name: string) =
      b.mapField(at)
      atom(name)
    proc shapeCase(pattern: string) = b.atomPattern(at, pattern)

    b.moduleDeclaration(newErlangModuleName("shapes"))
    b.compileAttribute(["no_auto_import", "nowarn_ignored", "nowarn_unused_vars",
      "nowarn_unused_function", "nowarn_nomatch", "inline"])
    b.exportAttribute({"area": 1, "describe": 1, "widen": 2, "parse": 2, "total_area": 1,
      "greeting": 1, "make_adder": 1, "safe_divide": 2, "header": 1, "not_yet": 0})
    b.exportTypeAttribute({"shape": 0, "parse_error": 0})
    b.moduledocAttribute(docString(
      " A tiny module that touches most of what the code generator has to handle."))

    block:
      let t = b.startTypeSpec(false, "shape", newSeq[string]())
      union:
        tupleType:
          b.literalAtomType("circle")
          builtIn(ErlangBuiltInType.Float)
        tupleType:
          b.literalAtomType("rectangle")
          builtIn(ErlangBuiltInType.Float)
          builtIn(ErlangBuiltInType.Float)
        b.literalAtomType("dot")
      b.endTypeSpec(t)
    block:
      let t = b.startTypeSpec(false, "parse_error", newSeq[string]())
      union:
        tupleType:
          b.literalAtomType("unknown_shape")
          builtIn(ErlangBuiltInType.Binary)
        b.literalAtomType("bad_number")
      b.endTypeSpec(t)

    spec("area", 1, custom("shape"), builtIn(ErlangBuiltInType.Float))
    b.docAttribute(docString(" Area of a shape. Pattern matching on a custom type."))
    function("area", ["Shape"]):
      caseOf(v("Shape")):
        clause((tuplePattern do: (shapeCase("circle"); b.variablePattern(at, "R")))):
          b.binaryOperator(at, "*")
          b.binaryOperator(at, "*")
          b.floatExpression(at, 3.14159)
          v("R")
          v("R")
        clause((tuplePattern do:
            shapeCase("rectangle")
            b.variablePattern(at, "W")
            b.variablePattern(at, "H"))):
          b.binaryOperator(at, "*")
          v("W")
          v("H")
        clause(shapeCase("dot")):
          b.floatExpression(at, 0.0)

    spec("describe", 1, custom("shape"), builtIn(ErlangBuiltInType.Binary))
    function("describe", ["Shape"]):
      caseOf(v("Shape")):
        clause((tuplePattern do: (shapeCase("circle"); b.discardPattern(at)))):
          str("circle")
        clauseWhen(
          (tuplePattern do:
            shapeCase("rectangle")
            b.variablePattern(at, "W")
            b.variablePattern(at, "H")),
          (block:
            let g = b.startClauseGuard()
            b.binaryOperator(at, "=:=")
            v("W")
            v("H")
            b.endClauseGuard(g))):
          str("square")
        clause((tuplePattern do:
            shapeCase("rectangle")
            b.discardPattern(at)
            b.discardPattern(at))):
          str("rectangle")
        clause(shapeCase("dot")):
          str("dot")

    spec("widen", 2, (custom("shape"); builtIn(ErlangBuiltInType.Float)), custom("shape"))
    function("widen", ["Shape", "By"]):
      caseOf(v("Shape")):
        clause((block:
            b.matchPattern(at)
            tuplePattern:
              shapeCase("rectangle")
              b.discardPattern(at)
              b.discardPattern(at)
            b.variablePattern(at, "R"))):
          tup:
            atom("rectangle")
            b.binaryOperator(at, "+")
            remote("erlang", "element"):
              int(2)
              v("R")
            v("By")
            remote("erlang", "element"):
              int(3)
              v("R")
        clause(b.variablePattern(at, "Other")):
          v("Other")

    spec("parse", 2, (builtIn(ErlangBuiltInType.Binary); builtIn(ErlangBuiltInType.Binary))):
      union:
        tupleType:
          b.literalAtomType("ok")
          custom("shape")
        tupleType:
          b.literalAtomType("error")
          custom("parse_error")
    function("parse", ["Name", "Size"]):
      remote("gleam/result", "try"):
        block:
          let blck = b.startBlock(at)
          b.matchOperator(at)
          b.variablePattern(at, "_pipe")
          remote("gleam_stdlib", "parse_int"): v("Size")
          remote("gleam/result", "replace_error"):
            v("_pipe")
            atom("bad_number")
          b.endBlock(blck)
        block:
          let f = b.startAnonymousFunction(at, [(at, "N")])
          b.matchOperator(at)
          b.variablePattern(at, "Size@1")
          remote("erlang", "float"): v("N")
          caseOf(v("Name")):
            clause(b.stringPattern(at, "circle")):
              tup:
                atom("ok")
                tup:
                  atom("circle")
                  v("Size@1")
            clause(b.stringPattern(at, "square")):
              tup:
                atom("ok")
                tup:
                  atom("rectangle")
                  v("Size@1")
                  v("Size@1")
            clause(b.stringPattern(at, "dot")):
              tup:
                atom("ok")
                atom("dot")
            clause(b.discardPattern(at)):
              tup:
                atom("error")
                tup:
                  atom("unknown_shape")
                  v("Name")
          b.endFunction(f)

    spec("sum", 2,
        ((builtIn(ErlangBuiltInType.List) do: builtIn(ErlangBuiltInType.Float));
         builtIn(ErlangBuiltInType.Float)),
        builtIn(ErlangBuiltInType.Float))
    function("sum", ["Numbers", "Acc"]):
      caseOf(v("Numbers")):
        clause(b.emptyListPattern(at)):
          v("Acc")
        clause((block:
            b.consListPattern(at)
            b.variablePattern(at, "First")
            b.variablePattern(at, "Rest"))):
          local("sum"):
            v("Rest")
            b.binaryOperator(at, "+")
            v("Acc")
            v("First")

    spec("total_area", 1, (builtIn(ErlangBuiltInType.List) do: custom("shape")),
         builtIn(ErlangBuiltInType.Float))
    function("total_area", ["Shapes"]):
      b.matchOperator(at)
      b.variablePattern(at, "_pipe")
      v("Shapes")
      b.matchOperator(at)
      b.variablePattern(at, "_pipe@1")
      remote("gleam/list", "map"):
        v("_pipe")
        b.functionReference(at, none(ErlangModuleName), "area", 1)
      local("sum"):
        v("_pipe@1")
        b.floatExpression(at, 0.0)

    spec("greeting", 1, builtIn(ErlangBuiltInType.Binary), builtIn(ErlangBuiltInType.Binary))
    function("greeting", ["Name"]):
      caseOf((block:
          b.consList(at)
          block:
            let bits = b.startBitArray(at)
            b.bitArraySegment(at)
            v("Name")
            b.bitArraySegmentDefaultSize()
            b.bitArraySegmentSpecifiers([specifier(BitArraySegmentSpecifierKind.Binary)])
            b.bitArraySegment(at)
            str("!")
            b.bitArraySegmentDefaultSize()
            b.bitArraySegmentSpecifiers([specifier(BitArraySegmentSpecifierKind.Utf8)])
            b.endBitArray(bits)
          b.consList(at)
          str("unused")
          b.emptyList(at))):
        clause((block:
            b.consListPattern(at)
            b.variablePattern(at, "First")
            b.discardPattern(at))):
          let bits = b.startBitArray(at)
          b.bitArraySegment(at)
          str("Hello, ")
          b.bitArraySegmentDefaultSize()
          b.bitArraySegmentSpecifiers([specifier(BitArraySegmentSpecifierKind.Utf8)])
          b.bitArraySegment(at)
          v("First")
          b.bitArraySegmentDefaultSize()
          b.bitArraySegmentSpecifiers([specifier(BitArraySegmentSpecifierKind.Binary)])
          b.endBitArray(bits)
        clause(b.variablePattern(at, "_value")):
          remote("erlang", "error"):
            let m = b.startMap(at)
            field("gleam_error"); atom("let_assert")
            field("message"); str("Pattern match failed, no pattern matched the value.")
            field("file"); str("src/shapes.gleam")
            field("module"); str("shapes")
            field("function"); str("greeting")
            field("line"); int(70)
            field("value"); v("_value")
            field("start"); int(1485)
            field("end"); int(1533)
            field("pattern_start"); int(1496)
            field("pattern_end"); int(1507)
            b.endMap(m)

    spec("make_adder", 1, builtIn(ErlangBuiltInType.Integer)):
      functionType(builtIn(ErlangBuiltInType.Integer), builtIn(ErlangBuiltInType.Integer))
    function("make_adder", ["N"]):
      let f = b.startAnonymousFunction(at, [(at, "X")])
      b.binaryOperator(at, "+")
      v("X")
      v("N")
      b.endFunction(f)

    spec("safe_divide", 2,
         (builtIn(ErlangBuiltInType.Integer); builtIn(ErlangBuiltInType.Integer)),
         builtIn(ErlangBuiltInType.Integer))
    function("safe_divide", ["A", "B"]):
      caseOf(v("B")):
        clause(b.intPattern(at, initBigInt(0))):
          int(0)
        clause(b.variablePattern(at, "_value")):
          b.binaryOperator(at, "div")
          v("A")
          v("_value")

    spec("header", 1, builtIn(ErlangBuiltInType.Bitstring)):
      union:
        tupleType:
          b.literalAtomType("ok")
          tupleType:
            builtIn(ErlangBuiltInType.Integer)
            builtIn(ErlangBuiltInType.Bitstring)
        tupleType:
          b.literalAtomType("error")
          b.literalAtomType("nil")
    function("header", ["Bytes"]):
      caseOf(v("Bytes")):
        clause((block:
            let bits = b.startBitArrayPattern(at)
            b.bitArraySegment(at)
            b.variablePattern(at, "Version")
            int(8)
            b.bitArraySegmentSpecifiers(newSeq[BitArraySegmentSpecifier]())
            b.bitArraySegment(at)
            b.variablePattern(at, "Rest")
            b.bitArraySegmentDefaultSize()
            b.bitArraySegmentSpecifiers([specifier(BitArraySegmentSpecifierKind.Binary)])
            b.endBitArrayPattern(bits))):
          tup:
            atom("ok")
            tup:
              v("Version")
              v("Rest")
        clause(b.discardPattern(at)):
          tup:
            atom("error")
            atom("nil")

    spec("not_yet", 0, (discard), builtIn(ErlangBuiltInType.Integer))
    function("not_yet", newSeq[string]()):
      remote("erlang", "error"):
        let m = b.startMap(at)
        field("gleam_error"); atom("todo")
        field("message"); str("write me")
        field("file"); str("src/shapes.gleam")
        field("module"); str("shapes")
        field("function"); str("not_yet")
        field("line"); int(90)
        b.endMap(m)

    let expected = readFile(
      here.parentDir / "docs" / "devlog" / "data" / "the_beam" / "generated" / "erlang" / "shapes.erl")
    let output = b.intoOutput()
    if output != expected:
      let ours = output.splitLines
      let theirs = expected.splitLines
      for i in 0 ..< min(ours.len, theirs.len):
        if ours[i] != theirs[i]:
          checkpoint "line " & $(i + 1) & "\n  ours:   " & ours[i] & "\n  theirs: " & theirs[i]
          break
    check output == expected

suite "erlang source builder: the small functions":
  test "floats are printed as Rust prints them":
    check erlang_generation.formatFloat(0.0) == "+0.0"
    check erlang_generation.formatFloat(-0.0) == "-0.0"
    check erlang_generation.formatFloat(1.0) == "1.0"
    check erlang_generation.formatFloat(-2.5) == "-2.5"
    check erlang_generation.formatFloat(0.1) == "0.1"
    check erlang_generation.formatFloat(1.5e-7) == "0.00000015"
    check erlang_generation.formatFloat(1e21) == "1000000000000000000000.0"
    # the exact value of the float, not the shortest digits
    check erlang_generation.formatFloat(1e23) == "99999999999999991611392.0"
    check erlang_generation.formatFloat(5e-324) == "0." & "0".repeat(323) & "5"
    check erlang_generation.formatFloat(123456.789) == "123456.789"
    # Nim's `$` prints ...1562 here: of the two decimals with 17 digits that
    # read back as this float it is not the closest one
    check erlang_generation.formatFloat(-1391943062256.1563) == "-1391943062256.1563"
    check erlang_generation.formatFloat(1710397705243249.3) == "1710397705243249.3"

  test "atoms are quoted when they must be":
    check quoteAtomName("ok") == "ok"
    check quoteAtomName("gleam@list") == "gleam@list"
    check quoteAtomName("wobble_2") == "wobble_2"
    check quoteAtomName("Wibble") == "'Wibble'"
    check quoteAtomName("receive") == "'receive'"
    check quoteAtomName("maybe") == "'maybe'"
    check quoteAtomName("") == "''"
    check quoteAtomName("a.b") == "'a.b'"
    check quoteAtomName("ok\n") == "'ok\n'"

  test "unicode escapes become Erlang's, unless the backslash is escaped":
    check escapeLiteralStringContent("\\u{1F600}") == "\\x{1F600}"
    check escapeLiteralStringContent("\\\\u{1F600}") == "\\\\u{1F600}"
    check escapeLiteralStringContent("\\\\\\u{41}") == "\\\\\\x{41}"
    check escapeLiteralStringContent("u\\n\\") == "u\\n\\"

  test "an internal error says what was tried and where":
    var b = default(ErlangSourceBuilder)
    discard b.startFunction(initSrcSpan(0, 0), "main", 0, newSeq[(SrcSpan, string)]())
    discard b.startTuple(initSrcSpan(0, 0))
    expect AssertionDefect:
      b.typeVariable("A")
    try:
      b.typeVariable("A")
    except AssertionDefect as error:
      check error.msg ==
        "internal error: entered unreachable code: tried type, position: Some(Tuple { first: true })"
