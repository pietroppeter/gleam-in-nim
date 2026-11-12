## Golden tests: the Nim lexer against outputs recorded from the reference
## Gleam lexer at the pinned commit.
##
## `tools/lexcheck.sh golden` regenerates the files under `golden/lexer`, and
## `tools/lexcheck.sh fuzz` runs the same comparison live on as many random
## sources as you like. Formats are described in `tools/lexdump.nim`.

import std/[unittest, strutils, os, options]
import ../tools/lexdump
import gleam_in_nim/parse/[lexer, literals]

const golden = currentSourcePath().parentDir / "golden" / "lexer"

proc readLines(name: string): seq[string] =
  result = readFile(golden / name).split('\n')
  if result.len > 0 and result[^1] == "":
    result.setLen(result.len - 1)

suite "lexer: golden files from the reference lexer":
  test "token streams":
    let sources = readLines("sources.txt")
    # The expected file has a `== N` header before the dump of source N.
    var expected = newSeq[string](sources.len)
    var current = -1
    for line in readLines("sources.expected"):
      if line.startsWith("== "):
        current = parseInt(line[3 .. ^1]) - 1
      else:
        expected[current].add line & "\n"
    check sources.len == 2500
    var failures = 0
    for i, source in sources:
      if dump(unescapeBytes(source)) != expected[i]:
        failures += 1
        if failures <= 5:
          checkpoint "source " & $(i + 1) & ": " & source
    check failures == 0

  test "float literal values":
    let literals = readLines("floats.txt")
    let expected = readLines("floats.expected")
    check literals.len == expected.len
    var failures = 0
    for i, literal in literals:
      let value = parseLiteralFloat(literal)
      let got = if value.isSome: toHex(cast[uint64](value.get), 16) else: "none"
      if got != expected[i]:
        failures += 1
        if failures <= 5:
          checkpoint literal & ": expected " & expected[i] & ", got " & got
    check failures == 0

  test "int literal values":
    let literals = readLines("ints.txt")
    let expected = readLines("ints.expected")
    check literals.len == expected.len
    var failures = 0
    for i, literal in literals:
      let value = parseIntValue(literal)
      let got = if value.isSome: $value.get else: "none"
      if got != expected[i]:
        failures += 1
        if failures <= 5:
          checkpoint literal & ": expected " & expected[i] & ", got " & got
    check failures == 0
