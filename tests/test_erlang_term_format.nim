## port-of: erlang-term-format/src/tests.rs
## port-status: conformant
##
## SPDX-License-Identifier: Apache-2.0
## SPDX-FileCopyrightText: 2026 The Gleam contributors
## Translated to Nim from Gleam v1.19.2 for the gleam-in-nim project.
##
## We want to test all of these functions against the actual values produced by
## Erlang when turning some data into a binary.
##
## All the bytes you see in the assertions here were produced using the
## following bit of Erlang:
##
## ```erl
## Binary = term_to_binary(SomeErlangData),
## io:format("~w~n", [Binary]).
## ```
##
## Upstream writes the expected bytes in each test. Here they are not retyped: they were
## extracted from the Rust file into `tests/data/erlang_term_format/expected.txt`, one line per
## test, and each test below builds the same term as its upstream namesake. Three more checks
## follow the upstream tests: the data file against the reference checkout (when there is one),
## `toBytesLe`, and a round trip through real Erlang (when `escript` is installed).
import std/[os, strutils, tables, options, random, osproc, sequtils, re]
import pkg/bigints
import gleam_in_nim/erlang_term_format {.all.}

const dataDir = currentSourcePath().parentDir / "data" / "erlang_term_format"

proc readExpected(text: string): OrderedTable[string, seq[uint8]] =
  for line in text.splitLines:
    if line.len == 0 or line.startsWith("#"): continue
    let parts = line.split(": ", 1)
    result[parts[0]] = parts[1].splitWhitespace.mapIt(uint8(parseInt(it)))

let expected = readExpected(readFile(dataDir / "expected.txt"))
var ran: seq[string]

template test(name: string, body: untyped) =
  block:
    var etf {.inject.} = newTermBuilder()
    body
    doAssert name in expected, "no expected bytes for " & name
    doAssert etf.intoVec == expected[name], name & ": got " & $etf.intoVec
    ran.add name

test "small_atom":
  etf.atom("atom")

test "small_atom_utf8":
  etf.atom("ksiąskę")

test "atom":
  etf.atom("ą".repeat(128))

test "small_integer":
  etf.smallInteger(1)

test "integer":
  etf.integer(-2)

test "integer_2":
  etf.integer(1048576)

test "float":
  etf.newFloat(1.2)

test "small_big":
  etf.smallBig(initBigInt(123123123123123123'i64))

test "negative_small_big":
  etf.smallBig(initBigInt(-123123123123123123'i64))

test "empty_list":
  etf.emptyList()

test "proper_list_with_a_single_item":
  let list = etf.startList()
  etf.smallInteger(1)
  etf.endList(list, 1)

test "proper_list":
  let list = etf.startList()
  etf.smallInteger(1)
  etf.smallTuple(0)
  etf.smallInteger(2)
  etf.endList(list, 3)

test "empty_binary":
  etf.binary(0, [])

test "binary":
  etf.binary(3, [1'u8, 2, 3])

test "small_empty_tuple":
  etf.smallTuple(0)

test "small_single_item_tuple":
  etf.smallTuple(1)
  etf.smallInteger(1)

test "small_tuple":
  etf.smallTuple(3)
  etf.newFloat(1.1)
  etf.integer(-1)
  etf.smallInteger(11)

test "small_nested_tuple":
  etf.smallTuple(2)

  etf.smallTuple(2)
  etf.smallInteger(1)
  etf.smallInteger(11)

  etf.smallTuple(1)
  etf.newFloat(1.1)

test "large_tuple":
  etf.largeTuple(500)
  for _ in 1 .. 500:
    etf.smallInteger(1)

test "large_big":
  etf.largeBig(initBigInt("1".repeat(1500)))

test "negative_large_big":
  etf.largeBig(-initBigInt("1".repeat(1500)))

doAssert ran == toSeq(expected.keys), "an upstream test was not replayed"
echo "erlang_term_format: ", ran.len, " upstream tests replayed"

# --- the data file is what upstream says -------------------------------------------------------

block:
  let reference = getEnv("GLEAM_REF", currentSourcePath().parentDir.parentDir / "reference" / "gleam")
  let rust = reference / "erlang-term-format" / "src" / "tests.rs"
  if fileExists(rust):
    var upstream: OrderedTable[string, seq[uint8]]
    let source = readFile(rust)
    for chunk in source.split("#[test]")[1 .. ^1]:
      let name = chunk.findAll(re"fn (\w+)\(\)")[0][3 ..^ 3]
      let start = chunk.find('[', chunk.find("into_vec()"))
      upstream[name] = chunk[start + 1 ..< chunk.find(']', start)].split(',').mapIt(it.strip)
        .filterIt(it.len > 0).mapIt(uint8(parseInt(it)))
    doAssert upstream == expected, "tests/data/erlang_term_format/expected.txt differs from " & rust
    echo "erlang_term_format: expected bytes identical to the reference checkout"
  else:
    echo "erlang_term_format: no reference checkout, expected bytes not compared with upstream"

# --- toBytesLe (num-bigint's, written here because `bigints` has none) ----------------------------

block:
  doAssert initBigInt(0).toBytesLe == (NoSign, @[0'u8])
  doAssert initBigInt(258).toBytesLe == (Plus, @[2'u8, 1])
  doAssert initBigInt(-258).toBytesLe == (Minus, @[2'u8, 1])
  doAssert initBigInt(255).toBytesLe == (Plus, @[255'u8])
  doAssert initBigInt(low(int64)).toBytesLe == (Minus, @[0'u8, 0, 0, 0, 0, 0, 0, 128])
  doAssert initBigInt("1" & "0".repeat(30)).toBytesLe.bytes.len == 13
  echo "toBytesLe: ok"

# --- a quirk kept ------------------------------------------------------------------------------
# `bigint` never chooses LARGE_BIG_EXT: past 255 bytes of magnitude the length byte of
# SMALL_BIG_EXT wraps around (`bytes.len() as u8` upstream) and Erlang cannot read the term.
# The reference compiler does the same (docs/devlog/data/the_erlang_term_format/big_literal.sh),
# so the port must too. If upstream fixes it, this is the test that will need to change.

block:
  let number = initBigInt("1".repeat(700))
  doAssert number.toBytesLe.bytes.len == 291
  var etf = newTermBuilder()
  etf.bigint(number)
  doAssert etf.intoVec[0 .. 3] == @[131'u8, 110, uint8(291 - 256), 0]
  doAssert etf.intoVec.len == 4 + 291
  echo "erlang_term_format: the length byte of a 291 byte integer wraps, as upstream"

# --- the first form of a real .abstr file ------------------------------------------------------
# docs/devlog/data/the_beam/generated/erlang/shapes.abstr was written by the reference gleam.
# It is a list of forms, and the first is `{attribute, 0, module, shapes}`.

block:
  let file = currentSourcePath().parentDir.parentDir / "docs" / "devlog" / "data" / "the_beam" / "generated" / "erlang" / "shapes.abstr"
  let reference = cast[seq[uint8]](readFile(file))
  var etf = newTermBuilder()
  let forms = etf.startList()
  etf.smallTuple(4)
  etf.atom("attribute")
  etf.usize(0)
  etf.atom("module")
  etf.atom("shapes")
  let ours = etf.intoVec   # the list is left open on purpose: only its start is compared
  forms.consume()
  doAssert ours[0 .. 1] == reference[0 .. 1] and ours[6 .. ^1] == reference[6 ..< ours.len]
  echo "erlang_term_format: the first form of shapes.abstr, byte for byte (", ours.len - 6, " bytes)"

# --- a round trip through real Erlang -----------------------------------------------------------
# Random terms are encoded with the builder and also written as Erlang source. Erlang decodes
# the bytes with binary_to_term and compares with what it parses from the source.

type
  TermKind = enum tAtom, tInt, tFloat, tBinary, tTuple, tList
  Term = ref object
    case kind: TermKind
    of tAtom: name: string
    of tInt: number: BigInt
    of tFloat: value: float64
    of tBinary: bytes: seq[uint8]
    of tTuple, tList: items: seq[Term]

proc randomTerm(rng: var Rand, depth: int): Term =
  let kinds = if depth <= 0: @[tAtom, tInt, tFloat, tBinary] else: toSeq(TermKind)
  case rng.sample(kinds)
  of tAtom:
    let alphabet = ["a", "b", "k", "n", "_", "@", "ą", "ę", "λ", "日", "Z", "0", " "]
    # An atom has at most 255 characters. With characters of two or three bytes the name
    # goes past 255 bytes, which is where ATOM_UTF8_EXT takes over from SMALL_ATOM_UTF8_EXT.
    let length = rng.sample([1, 2, 5, 40, 100, 255])
    var name = ""
    for _ in 1 .. length: name.add rng.sample(alphabet)
    Term(kind: tAtom, name: name)
  of tInt:
    let digits = rng.sample([1, 2, 3, 5, 9, 10, 11, 19, 20, 40, 300, 700])
    var text = if rng.rand(1) == 0: "-" else: ""
    text.add rng.sample("123456789")
    for _ in 2 .. digits: text.add rng.sample("0123456789")
    Term(kind: tInt, number: initBigInt(text))
  of tFloat:
    Term(kind: tFloat, value: rng.sample([0.0, -0.0, 1.2, -1.1, 1e300, 5e-324, 123456.789, rng.rand(1.0), rng.rand(1e15) - 5e14]))
  of tBinary:
    Term(kind: tBinary, bytes: newSeqWith(rng.sample([0, 1, 3, 70, 300]), uint8(rng.rand(255))))
  of tTuple:
    Term(kind: tTuple, items: newSeqWith(rng.sample([0, 1, 2, 3, 5, 260]), rng.randomTerm(0)))   # leaves only: 260 of them is enough
  of tList:
    Term(kind: tList, items: newSeqWith(rng.sample([0, 1, 2, 4, 12]), rng.randomTerm(depth - 1)))

proc encode(etf: var TermBuilder, term: Term) =
  case term.kind
  of tAtom: etf.atom(term.name)
  of tInt:
    # as the binary backend will have to: the small form holds up to 255 bytes of magnitude
    if term.number.toBytesLe.bytes.len > 255: etf.largeBig(term.number) else: etf.bigint(term.number)
  of tFloat: etf.newFloat(term.value)
  of tBinary: etf.binary(uint32(term.bytes.len), term.bytes)
  of tTuple:
    if term.items.len <= 255: etf.smallTuple(uint8(term.items.len)) else: etf.largeTuple(uint32(term.items.len))
    for item in term.items: etf.encode(item)
  of tList:
    if term.items.len == 0: etf.emptyList()
    else:
      let list = etf.startList()
      for item in term.items: etf.encode(item)
      etf.endList(list, uint32(term.items.len))

proc erlangSource(term: Term): string =
  case term.kind
  of tAtom: "'" & term.name & "'"
  of tInt: $term.number
  of tFloat: term.value.formatFloat(ffScientific, 17)
  of tBinary: "<<" & term.bytes.mapIt($it).join(",") & ">>"
  of tTuple: "{" & term.items.mapIt(erlangSource(it)).join(",") & "}"
  of tList: "[" & term.items.mapIt(erlangSource(it)).join(",") & "]"

block:
  let escript = findExe("escript")
  if escript.len == 0:
    echo "erlang_term_format: escript not installed, the round trip through Erlang was skipped"
  else:
    var rng = initRand(20261112)
    var lines: seq[string]
    for _ in 1 .. 500:
      let term = rng.randomTerm(2)
      var etf = newTermBuilder()
      etf.encode(term)
      lines.add etf.intoVec.mapIt(it.toHex(2)).join("") & "\t" & erlangSource(term)
    let file = getTempDir() / "gleam_in_nim_etf_terms.txt"
    writeFile(file, lines.join("\n") & "\n")
    let (output, code) = execCmdEx(escript & " " & quoteShell(currentSourcePath().parentDir / "erlang_term_format_oracle.escript") & " " & quoteShell(file))
    doAssert code == 0 and output.strip == "ok 500", "Erlang disagrees:\n" & output[0 ..< min(output.len, 2000)]
    echo "erlang_term_format: 500 random terms decoded by Erlang to the same terms"
    if existsEnv("RECORD_RESULTS"):
      # for the devlog post: what was run, where it can read it
      let erlang = execCmdEx("erl -noshell -eval 'io:format(\"~s\",[erlang:system_info(otp_release)]), halt().'").output.strip
      var bytes = 0
      for line in lines: bytes += line.find('\t') div 2
      writeFile(currentSourcePath().parentDir.parentDir / "docs" / "devlog" / "data" / "the_erlang_term_format" / "roundtrip.json",
        "{\"terms\": 500, \"bytes\": " & $bytes & ", \"mismatches\": 0, \"otp\": \"" & erlang & "\", \"upstream_tests\": " & $ran.len & "}\n")
