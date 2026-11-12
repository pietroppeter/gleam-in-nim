## Replay scripts of Erlang builder calls on the Nim port, in the same format
## as the reference oracle (reference/erldump, which links the real
## `erlang-generation` crate).
##
## Usage:
##   erldump source FILE     replay with `ErlangSourceBuilder`
##
## A file holds scripts. A script starts with a line `== NAME` and has one
## builder call per line: the name of the function upstream (snake_case), then
## its arguments, tab separated. Bytes outside printable ASCII, and the
## backslash, are written `\xHH`.
##
## - a location is `START:END`;
## - a list (exports, argument names, type parameters, specifiers) is the rest
##   of the line, pairs being two fields;
## - a float is the 16 hex digits of its bits; an int is decimal;
## - `doc_attribute` and `moduledoc_attribute` take `false`, or `string` and
##   the content;
## - the module of `function_reference` is `-` when there is none;
## - a module name is a Gleam module name (`ErlangModuleName::new`).
##
## The `end_*` calls take no argument: the value their `start_*` returned is
## kept on a stack, one stack per associated type of the trait upstream.
## `into_output` is called when the script ends.
##
## Output: `== NAME`, then each line of the output as `| LINE`, or
## `! MESSAGE` when the builder failed (a panic upstream, an `AssertionDefect`
## here).
import std/[options, strutils]
import pkg/bigints
import gleam_in_nim/[erlang_generation, src_span]

func escapeBytes*(s: string): string =
  for c in s:
    if ord(c) >= 0x20 and ord(c) < 0x7f and c != '\\':
      result.add c
    else:
      result.add "\\x" & toHex(ord(c), 2)

func unescapeBytes*(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 3 < s.len and s[i + 1] == 'x':
      result.add char(parseHexInt(s[i + 2 .. i + 3]))
      i += 4
    else:
      result.add s[i]
      i += 1

func location(s: string): SrcSpan =
  let parts = s.split(':')
  initSrcSpan(parseInt(parts[0]), parseInt(parts[1]))

func doc(f: seq[string]): DocContent =
  case f[1]
  of "false": docFalse()
  of "string": docString(f[2])
  else: raiseAssert "doc content " & f[1]

func builtIn(s: string): ErlangBuiltInType =
  case s
  of "any": ErlangBuiltInType.Any
  of "integer": ErlangBuiltInType.Integer
  of "binary": ErlangBuiltInType.Binary
  of "boolean": ErlangBuiltInType.Boolean
  of "float": ErlangBuiltInType.Float
  of "bitstring": ErlangBuiltInType.Bitstring
  of "list": ErlangBuiltInType.List
  else: raiseAssert "built in type " & s

func segmentSpecifier(s: string): BitArraySegmentSpecifier =
  case s
  of "utf8": specifier(spUtf8)
  of "utf16": specifier(spUtf16)
  of "utf32": specifier(spUtf32)
  of "integer": specifier(spInteger)
  of "float": specifier(spFloat)
  of "binary": specifier(spBinary)
  of "bitstring": specifier(spBitstring)
  of "signed": specifier(spSigned)
  of "unsigned": specifier(spUnsigned)
  of "little": specifier(spLittle)
  of "big": specifier(spBig)
  of "native": specifier(spNative)
  else:
    doAssert s.startsWith("unit:"), "specifier"
    unitSpecifier(uint8(parseInt(s[5 .. ^1])))

func float(s: string): float64 = cast[float64](fromHex[uint64](s))

func pairs(f: seq[string]): seq[(string, int)] =
  for i in countup(0, f.len - 2, 2): result.add (f[i], parseInt(f[i + 1]))

func arguments(f: seq[string]): seq[(SrcSpan, string)] =
  for i in countup(0, f.len - 2, 2): result.add (location(f[i]), f[i + 1])

proc take[T](stack: var seq[T]): T =
  if stack.len == 0: raiseAssert "stack"
  stack.pop()

proc replaySource*(script: seq[seq[string]]): string =
  ## The output of `ErlangSourceBuilder` for one script.
  var b = default(ErlangSourceBuilder)
  # One stack per associated type of the trait upstream.
  var functions, calls, calledExpressions, cases, caseSubjects, clausePatterns, clauseGuards,
    guards, clauseBodies, tuples, maps, bitArrays, bitArrayPatterns, tupleTypes, tuplePatterns,
    recordAttributes, functionTypes, namedTypes, remoteNamedTypes, unionTypes, functionSpecs,
    blocks, functionTypeArguments, typeSpecs: seq[Unit]

  for f in script:
    case f[0]
    of "module_declaration": b.moduleDeclaration(newErlangModuleName(f[1]))
    of "export_attribute": b.exportAttribute(pairs(f[1 .. ^1]))
    of "export_type_attribute": b.exportTypeAttribute(pairs(f[1 .. ^1]))
    of "doc_attribute": b.docAttribute(doc(f))
    of "moduledoc_attribute": b.moduledocAttribute(doc(f))
    of "compile_attribute": b.compileAttribute(f[1 .. ^1])
    of "module_file_attribute": b.moduleFileAttribute(f[1])
    of "start_record_attribute": recordAttributes.add b.startRecordAttribute(f[1])
    of "end_record_attribute": b.endRecordAttribute(recordAttributes.take)
    of "record_field": b.recordField()
    of "start_function_spec": functionSpecs.add b.startFunctionSpec(f[1], parseInt(f[2]))
    of "end_function_spec": b.endFunctionSpec(functionSpecs.take)
    of "start_type_spec": typeSpecs.add b.startTypeSpec(f[1] == "1", f[2], f[3 .. ^1])
    of "end_type_spec": b.endTypeSpec(typeSpecs.take)
    of "start_function_type": functionTypeArguments.add b.startFunctionType()
    of "end_function_type_arguments":
      functionTypes.add b.endFunctionTypeArguments(functionTypeArguments.take)
    of "end_function_type": b.endFunctionType(functionTypes.take)
    of "start_built_in_named_type": namedTypes.add b.startBuiltInNamedType(builtIn(f[1]))
    of "start_custom_named_type": namedTypes.add b.startCustomNamedType(f[1])
    of "end_named_type": b.endNamedType(namedTypes.take)
    of "start_remote_named_type":
      remoteNamedTypes.add b.startRemoteNamedType(newErlangModuleName(f[1]), f[2])
    of "end_remote_named_type": b.endRemoteNamedType(remoteNamedTypes.take)
    of "start_tuple_type": tupleTypes.add b.startTupleType()
    of "end_tuple_type": b.endTupleType(tupleTypes.take)
    of "start_union_type": unionTypes.add b.startUnionType()
    of "end_union_type": b.endUnionType(unionTypes.take)
    of "type_variable": b.typeVariable(f[1])
    of "literal_atom_type": b.literalAtomType(f[1])
    of "start_function":
      functions.add b.startFunction(location(f[1]), f[2], parseInt(f[3]), arguments(f[4 .. ^1]))
    of "start_anonymous_function":
      functions.add b.startAnonymousFunction(location(f[1]), arguments(f[2 .. ^1]))
    of "end_function": b.endFunction(functions.take)
    of "start_block": blocks.add b.startBlock(location(f[1]))
    of "end_block": b.endBlock(blocks.take)
    of "start_remote_call":
      calls.add b.startRemoteCall(location(f[1]), newErlangModuleName(f[2]), f[3])
    of "start_call": calledExpressions.add b.startCall(location(f[1]))
    of "end_called_expression": calls.add b.endCalledExpression(calledExpressions.take)
    of "end_call": b.endCall(calls.take)
    of "start_tuple": tuples.add b.startTuple(location(f[1]))
    of "end_tuple": b.endTuple(tuples.take)
    of "start_map": maps.add b.startMap(location(f[1]))
    of "end_map": b.endMap(maps.take)
    of "map_field": b.mapField(location(f[1]))
    of "start_bit_array": bitArrays.add b.startBitArray(location(f[1]))
    of "end_bit_array": b.endBitArray(bitArrays.take)
    of "bit_array_segment": b.bitArraySegment(location(f[1]))
    of "bit_array_segment_default_size": b.bitArraySegmentDefaultSize()
    of "bit_array_segment_specifiers":
      var specifiers: seq[BitArraySegmentSpecifier]
      for s in f[1 .. ^1]: specifiers.add segmentSpecifier(s)
      b.bitArraySegmentSpecifiers(specifiers)
    of "cons_list": b.consList(location(f[1]))
    of "empty_list": b.emptyList(location(f[1]))
    of "start_case": caseSubjects.add b.startCase(location(f[1]))
    of "end_case_subject": cases.add b.endCaseSubject(caseSubjects.take)
    of "end_case": b.endCase(cases.take)
    of "start_case_clause": clausePatterns.add b.startCaseClause(location(f[1]))
    of "end_clause_pattern": clauseGuards.add b.endClausePattern(clausePatterns.take)
    of "start_clause_guard": guards.add b.startClauseGuard()
    of "end_clause_guard": b.endClauseGuard(guards.take)
    of "end_clause_guards": clauseBodies.add b.endClauseGuards(clauseGuards.take)
    of "end_clause_body": b.endClauseBody(clauseBodies.take)
    of "variable": b.variable(location(f[1]), f[2])
    of "unary_operator": b.unaryOperator(location(f[1]), f[2])
    of "binary_operator": b.binaryOperator(location(f[1]), f[2])
    of "function_reference":
      b.functionReference(
        location(f[1]),
        (if f[2] == "-": none(ErlangModuleName) else: some(newErlangModuleName(f[2]))),
        f[3], parseInt(f[4]))
    of "match_operator": b.matchOperator(location(f[1]))
    of "match_pattern": b.matchPattern(location(f[1]))
    of "variable_pattern": b.variablePattern(location(f[1]), f[2])
    of "discard_pattern": b.discardPattern(location(f[1]))
    of "int_pattern": b.intPattern(location(f[1]), initBigInt(f[2]))
    of "float_pattern": b.floatPattern(location(f[1]), float(f[2]))
    of "string_pattern": b.stringPattern(location(f[1]), f[2])
    of "atom_pattern": b.atomPattern(location(f[1]), f[2])
    of "start_tuple_pattern": tuplePatterns.add b.startTuplePattern(location(f[1]))
    of "end_tuple_pattern": b.endTuplePattern(tuplePatterns.take)
    of "start_bit_array_pattern": bitArrayPatterns.add b.startBitArrayPattern(location(f[1]))
    of "end_bit_array_pattern": b.endBitArrayPattern(bitArrayPatterns.take)
    of "cons_list_pattern": b.consListPattern(location(f[1]))
    of "empty_list_pattern": b.emptyListPattern(location(f[1]))
    of "string": b.stringExpression(location(f[1]), f[2])
    of "int_expression": b.intExpression(location(f[1]), initBigInt(f[2]))
    of "float_expression": b.floatExpression(location(f[1]), float(f[2]))
    of "atom_expression": b.atomExpression(location(f[1]), f[2])
    else: raiseAssert "unknown call " & f[0]
  b.intoOutput()

proc dump*(script: seq[seq[string]]): string =
  ## What the oracle prints for one script, after its `== NAME` line.
  try:
    for line in replaySource(script).split('\n'):
      result.add "| " & line & "\n"
  except AssertionDefect as error:
    result = "! " & error.msg.replace("\n", "\\n") & "\n"

proc parseScripts*(text: string): seq[tuple[name: string, calls: seq[seq[string]]]] =
  for line in text.splitLines:
    if line.startsWith("== "):
      result.add (line[3 .. ^1], newSeq[seq[string]]())
    elif line.len > 0 and result.len > 0:
      var fields = line.split('\t')
      for field in fields.mitems: field = unescapeBytes(field)
      result[^1].calls.add fields

when isMainModule:
  import std/os

  let args = commandLineParams()
  if args.len != 2 or args[0] != "source":
    quit "usage: erldump source FILE", 2
  var output = ""
  for (name, calls) in parseScripts(readFile(args[1])):
    output.add "== " & name & "\n"
    output.add dump(calls)
  stdout.write output
