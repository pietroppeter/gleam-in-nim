## Random scripts of Erlang builder calls, for tools/erlcheck.sh.
##
##   erlfuzz COUNT SEED            COUNT scripts in the format of tools/erldump.nim
##   erlfuzz --floats COUNT SEED   one script: a function returning COUNT floats
##
## Three scripts in four are valid: a module with attributes, records, type
## specs and functions, every construct the builder has, nested at random.
## The fourth has one line deleted, repeated or swapped with the next one, to
## reach the internal errors of the builder and their messages.
##
## A valid script never has a `case` without clauses: upstream that
## underflows the indentation (a panic in a debug build, a very long line of
## spaces in a release build).
import std/[os, random, strutils]
import erldump

var rng: Rand
var lines: seq[string]

proc emit(fields: varargs[string]) =
  var line = ""
  for i, field in fields:
    if i > 0: line.add '\t'
    line.add escapeBytes(field)
  lines.add line

proc chance(percent: int): bool = rng.rand(99) < percent
proc pick[T](items: openArray[T]): T = items[rng.rand(items.high)]

proc loc(): string =
  let start = rng.rand(2000)
  $start & ":" & $(start + rng.rand(40))

const atoms = ["ok", "error", "nil", "true", "false", "wibble", "wobble_2", "a@b", "x",
  "Wibble", "receive", "div", "maybe", "else", "case", "!", "", "9lives", "with space",
  "it's", "caf\xC3\xA9", "a.b", "_private", "gleam@list", "erlang", "andalso", "é", "a-b",
  "aB", "query", "let", "end"]
const variables = ["X", "Y", "_", "_pipe", "Acc", "_assert_subject", "Wibble@1", "_use0", "Z1"]
const modules = ["gleam/list", "gleam/io", "erlang", "wibble", "my/deep/module", "maps",
  "Elixir.Enum", "case", "io_lib"]
const binaryOperators = ["+", "-", "*", "/", "div", "rem", "andalso", "orelse", "=:=", "=/=",
  "<", "=<", ">", ">=", "+.", "++", "bsl", "band"]
const unaryOperators = ["-", "not", "bnot", "+"]
const builtIns = ["any", "integer", "binary", "boolean", "float", "bitstring", "list"]
const plainSpecifiers = ["utf8", "utf16", "utf32", "integer", "float", "binary", "bitstring",
  "signed", "unsigned", "little", "big", "native"]
const stringPieces = ["wibble", " ", "\\u{1F600}", "\\\\u{41}", "\\\\\\u{42}", "\\n", "\\\"",
  "\"", "\\", "u", "\n", "\t", "~", "é", "日本", "\\e", "\\u", "\\\\", "{}", "'", "%", "\\x41"]
const niceFloats = [0.0, -0.0, 1.0, -1.0, 1.5, 0.1, 1e21, 1e22, 1e23, 1.5e-7, 1e-7, 123456.789,
  1e15, 1e16, 1e17, 9007199254740993.0, 5e-324, 1.7976931348623157e308, 0.3, 2.5e-5, 100.0,
  1e100, 1.0e-10, 3.141592653589793, 4.35, 0.000001, 123456789012345680000.0]

proc atom(): string = pick(atoms)

proc text(): string =
  for _ in 0 ..< rng.rand(4): result.add pick(stringPieces)

proc floatBits(): string =
  var value: float64
  let roll = rng.rand(99)
  if roll < 45:
    value = pick(niceFloats)
    if chance(30): value = -value
  elif roll < 55:
    value = float64(rng.rand(1_000_000) - 500_000)
  elif roll < 75:
    value = float64(rng.rand(1_000_000)) / pick([10.0, 100.0, 1000.0, 3.0, 7.0, 1e9])
  else:
    # any bits at all, but neither an infinity nor a NaN: Gleam has no literal for them
    while true:
      value = cast[float64](rng.next())
      if value == value and value != Inf and value != NegInf: break
  toHex(cast[uint64](value), 16)

proc intText(): string =
  let roll = rng.rand(99)
  if roll < 50: result = $rng.rand(300)
  elif roll < 70: result = $(rng.rand(int64.high))
  else:
    result = $(1 + rng.rand(8))
    for _ in 0 ..< rng.rand(60): result.add char(ord('0') + rng.rand(9))
  if chance(25) and result != "0": result = "-" & result

proc typ(depth: int)
proc expression(depth: int)
proc pattern(depth: int)

proc functionType(depth: int) =
  emit "start_function_type"
  for _ in 0 ..< rng.rand(3): typ(depth - 1)
  emit "end_function_type_arguments"
  typ(depth - 1)
  emit "end_function_type"

proc typ(depth: int) =
  let roll = if depth <= 0: rng.rand(2) else: rng.rand(9)
  case roll
  of 0: emit "type_variable", pick(["A", "B", "Value", "_"])
  of 1: emit "literal_atom_type", atom()
  of 2:
    emit "start_built_in_named_type", pick(builtIns)
    emit "end_named_type"
  of 3:
    emit "start_built_in_named_type", "list"
    typ(depth - 1)
    emit "end_named_type"
  of 4:
    emit "start_custom_named_type", atom()
    for _ in 0 ..< rng.rand(3): typ(depth - 1)
    emit "end_named_type"
  of 5:
    emit "start_remote_named_type", pick(modules), atom()
    for _ in 0 ..< rng.rand(3): typ(depth - 1)
    emit "end_remote_named_type"
  of 6:
    emit "start_tuple_type"
    for _ in 0 ..< rng.rand(4): typ(depth - 1)
    emit "end_tuple_type"
  of 7, 8:
    emit "start_union_type"
    for _ in 0 .. rng.rand(3): typ(depth - 1)
    emit "end_union_type"
  else: functionType(depth)

proc specifiers() =
  var fields = @["bit_array_segment_specifiers"]
  for _ in 0 ..< rng.rand(3): fields.add pick(plainSpecifiers)
  if chance(25): fields.insert("unit:" & $rng.rand(255), 1 + rng.rand(fields.len - 1))
  emit fields

proc segmentSize(depth: int) =
  if chance(50): emit "bit_array_segment_default_size"
  else: expression(depth - 1)

proc statements(depth: int) =
  for _ in 0 .. rng.rand(2): expression(depth - 1)

proc caseExpression(depth: int) =
  emit "start_case", loc()
  expression(depth - 1)
  emit "end_case_subject"
  for _ in 0 .. rng.rand(2):
    emit "start_case_clause", loc()
    pattern(depth - 1)
    emit "end_clause_pattern"
    if chance(35):
      emit "start_clause_guard"
      expression(depth - 1)
      emit "end_clause_guard"
    emit "end_clause_guards"
    statements(depth)
    emit "end_clause_body"
  emit "end_case"

proc arguments(fields: var seq[string]) =
  for _ in 0 ..< rng.rand(3):
    fields.add loc()
    fields.add pick(variables)

proc expression(depth: int) =
  let roll = if depth <= 0: rng.rand(6) else: rng.rand(27)
  case roll
  of 0: emit "variable", loc(), pick(variables)
  of 1: emit "int_expression", loc(), intText()
  of 2: emit "float_expression", loc(), floatBits()
  of 3: emit "string", loc(), text()
  of 4: emit "atom_expression", loc(), atom()
  of 5: emit "empty_list", loc()
  of 6:
    if chance(50): emit "function_reference", loc(), "-", atom(), $rng.rand(4)
    else: emit "function_reference", loc(), pick(modules), atom(), $rng.rand(4)
  of 7, 8:
    emit "start_tuple", loc()
    for _ in 0 ..< rng.rand(4): expression(depth - 1)
    emit "end_tuple"
  of 9, 10:
    for _ in 0 .. rng.rand(3):
      emit "cons_list", loc()
      expression(depth - 1)
    if chance(70): emit "empty_list", loc()
    else: expression(depth - 1)
  of 11:
    emit "start_map", loc()
    for _ in 0 ..< rng.rand(3):
      emit "map_field", loc()
      expression(depth - 1)
      expression(depth - 1)
    emit "end_map"
  of 12, 13:
    emit "start_bit_array", loc()
    for _ in 0 ..< rng.rand(4):
      emit "bit_array_segment", loc()
      expression(depth - 1)
      segmentSize(depth)
      specifiers()
    emit "end_bit_array"
  of 14:
    emit "start_block", loc()
    statements(depth)
    emit "end_block"
  of 15, 16:
    emit "start_call", loc()
    expression(depth - 1)
    emit "end_called_expression"
    for _ in 0 ..< rng.rand(3): expression(depth - 1)
    emit "end_call"
  of 17, 18:
    emit "start_remote_call", loc(), pick(modules), atom()
    for _ in 0 ..< rng.rand(3): expression(depth - 1)
    emit "end_call"
  of 19:
    var fields = @["start_anonymous_function", loc()]
    arguments(fields)
    emit fields
    statements(depth)
    emit "end_function"
  of 20, 21: caseExpression(depth)
  of 22:
    emit "unary_operator", loc(), pick(unaryOperators)
    expression(depth - 1)
  of 23, 24, 25:
    emit "binary_operator", loc(), pick(binaryOperators)
    expression(depth - 1)
    expression(depth - 1)
  else:
    emit "match_operator", loc()
    pattern(depth - 1)
    expression(depth - 1)

proc pattern(depth: int) =
  let roll = if depth <= 0: rng.rand(6) else: rng.rand(13)
  case roll
  of 0: emit "variable_pattern", loc(), pick(variables)
  of 1: emit "discard_pattern", loc()
  of 2: emit "int_pattern", loc(), intText()
  of 3: emit "float_pattern", loc(), floatBits()
  of 4: emit "string_pattern", loc(), text()
  of 5: emit "atom_pattern", loc(), atom()
  of 6: emit "empty_list_pattern", loc()
  of 7, 8:
    emit "start_tuple_pattern", loc()
    for _ in 0 ..< rng.rand(4): pattern(depth - 1)
    emit "end_tuple_pattern"
  of 9, 10:
    for _ in 0 .. rng.rand(3):
      emit "cons_list_pattern", loc()
      pattern(depth - 1)
    if chance(60): emit "empty_list_pattern", loc()
    else: pattern(depth - 1)
  of 11, 12:
    emit "start_bit_array_pattern", loc()
    for _ in 0 ..< rng.rand(4):
      emit "bit_array_segment", loc()
      pattern(depth - 1)
      segmentSize(depth)
      specifiers()
    emit "end_bit_array_pattern"
  else:
    emit "match_pattern", loc()
    pattern(depth - 1)
    pattern(depth - 1)

proc exports(call: string) =
  var fields = @[call]
  for _ in 0 ..< rng.rand(4):
    fields.add atom()
    fields.add $rng.rand(5)
  emit fields

proc docValue(call: string) =
  if chance(25): emit call, "false"
  else: emit call, "string", text() & pick(["", " \"quoted\" \\ and more", "\n second line"])

proc module() =
  let depth = 1 + rng.rand(3)
  if chance(90): emit "module_declaration", pick(modules)
  if chance(40): docValue("moduledoc_attribute")
  if chance(60): emit "compile_attribute", "no_auto_import", "nowarn_unused_vars"
  if chance(20): emit "compile_attribute"
  if chance(30): emit "module_file_attribute", "src/wibble.gleam"
  exports("export_attribute")
  exports("export_type_attribute")
  for _ in 0 ..< rng.rand(2):
    var fields = @["start_type_spec", $rng.rand(1), atom()]
    for _ in 0 ..< rng.rand(3): fields.add pick(["A", "B", "Value"])
    emit fields
    typ(depth)
    emit "end_type_spec"
  for _ in 0 ..< rng.rand(2):
    emit "start_record_attribute", atom()
    for _ in 0 ..< rng.rand(4):
      emit "record_field"
      emit "atom_expression", loc(), atom()
      typ(depth)
    emit "end_record_attribute"
  for _ in 0 ..< rng.rand(4):
    let name = atom()
    var fields = @["start_function", loc(), name]
    var names: seq[string]
    arguments(names)
    fields.add $(names.len div 2)
    fields.add names
    if chance(40): docValue("doc_attribute")
    if chance(60):
      emit "start_function_spec", name, $(names.len div 2)
      emit "start_function_type"
      for _ in 0 ..< names.len div 2: typ(depth - 1)
      emit "end_function_type_arguments"
      typ(depth - 1)
      emit "end_function_type"
      emit "end_function_spec"
    emit fields
    statements(depth + 1)
    emit "end_function"

proc mutate() =
  if lines.len < 2: return
  let i = rng.rand(lines.len - 2)
  case rng.rand(2)
  of 0: lines.delete(i)
  of 1: lines.insert(lines[i], i)
  else: swap(lines[i], lines[i + 1])

proc floats(count: int) =
  ## Floats of every size: any bits, powers of two and their neighbours (where
  ## the gap to the next float changes), subnormals, and decimals with few
  ## digits.
  emit "start_function", "0:0", "floats", "0"
  for n in 0 ..< count:
    var value: float64
    case n mod 5
    of 0, 1:
      while true:
        value = cast[float64](rng.next())
        if value == value and value != Inf and value != NegInf: break
    of 2:
      let power = cast[uint64](rng.rand(2045) + 1) shl 52
      value = cast[float64](power + cast[uint64](rng.rand(4) - 2))
    of 3:
      value = cast[float64](cast[uint64](rng.rand(int64(1) shl 53)))
    else:
      value = float64(rng.rand(100_000_000)) / pick([10.0, 100.0, 1e4, 1e8, 1e12, 1e-3, 1e30])
    emit "float_expression", "0:0", toHex(cast[uint64](value), 16)
  emit "end_function"

when isMainModule:
  let args = commandLineParams()
  if args.len == 3 and args[0] == "--floats":
    rng = initRand(parseInt(args[2]))
    floats(parseInt(args[1]))
    stdout.write "== floats\n" & lines.join("\n") & "\n"
    quit 0
  if args.len != 2:
    quit "usage: erlfuzz COUNT SEED", 2
  rng = initRand(parseInt(args[1]))
  var output = ""
  for n in 1 .. parseInt(args[0]):
    lines.setLen(0)
    module()
    if n mod 4 == 0: mutate()
    output.add "== " & $n & "\n"
    for line in lines: output.add line & "\n"
  stdout.write output
