## Generate random Gleam-ish sources to compare the Nim lexer with the
## reference one. Prints one escaped source per line (see lexdump.nim).
##
## Usage: lexfuzz COUNT [SEED [FILE...]]
##
## With files, half of the sources are windows of them with random edits.
##
## Usage: lexfuzz --floats COUNT SEED, lexfuzz --ints COUNT SEED
##
## Random number literals, one per line, for the two literal parsers.
##
## Sources are built from fragments chosen to hit the lexer's corners: number
## prefixes, underscores, exponents, escapes, runs of `=` `<` `>`, comments,
## carriage returns, look-alike characters, a byte order mark.

import std/[os, random, strutils, unicode]
import pkg/bigints
import ./lexdump

const fragments = [
  "=", "=", "==", "<", "<", ">", ">", "-", "-", ".", ".", "_", "_", "0x", "0X", "0b",
  "0B", "0o", "0O", "0", "1", "2", "7", "8", "9", "a", "f", "F", "e", "E", "g", "x", "Z",
  "Wibble", "wobble", "_discard", "\"", "\"", "\\", "\\n", "\\\"", "\\u", "\\u{", "{", "}",
  "\\u{1F600}", "\\u{D800}", "\\u{110000}", "\\u{1234567}", "\\u{}", "\\q", "/", "//",
  "///", "////", "\r", "\n", "\r\n", " ", " ", "\t", "\x0C", "+", "*", "%", "|", "&", "!",
  "#", "@", ":", ",", ";", "'", "(", ")", "[", "]", "+.", "-.", "*.", "/.", "<.", ">.",
  "<=", ">=", "<=.", ">=.", "<>", "|>", "||", "&&", "->", "<-", "..", "!=", "+=", "++",
  "-=", "*=", "/=", "%=", "1.0", "1.", "1.0e", "1.0e-", "1.0e10", "1_000", "1__0", "1_",
  "0.1e-3", "123456789012345678901234567890", "1.7976931348623157e308", "1.0e400",
  "4.9e-324", "0.30000000000000004", "as", "assert", "auto", "case", "const", "delegate",
  "derive", "echo", "else", "fn", "if", "implement", "import", "let", "macro", "opaque",
  "panic", "pub", "test", "todo", "type", "use", "é", "λ", "日本", "🦀", "\u{FEFF}",
  "\u{201A}", "\u{FF3B}", "\u{FF3D}", "\u{FF08}", "\u{FF09}", "\u{FF0E}", "\u{3002}",
  "\u{FF1C}", "\u{FF1E}", "\u{FF5C}", "\u{FF20}", "\u{FF3E}", "\u{FF1A}", "\u{201C}",
  "\u{201D}", "\u{2018}", "\u{2019}", "\u{2013}", "\u{2014}", "\u{2217}", "\u{2215}",
  "\u{00A0}", "\u{200B}", "\u{0430}", "\u{0435}", "\u{043E}", "\u{0440}", "\u{1D35}",
  "\u{FF0C}", "\u{3001}", "===", "=======", "========", "<<<", "<<<<<<<", ">>>", ">>>>>>>",
  "<<", ">>", "\0", "\x7F", "$", "^", "~", "`", "?",
]

const calm = [
  " ", " ", " ", "\n", "a", "b1", "x_y", "Wibble", "_", "1", "0", "42", "1.5", "(", ")",
  "{", "}", "[", "]", ",", ":", "=", "==", "<", ">", "-", ".", "+", "*", "/", "|", "#",
  "@", "!", "\"", "\"str\"", "//", "fn", "let", "case", "->", "|>", "<>", "..", "\r\n",
]

proc randomSource(rng: var Rand): string =
  ## A source made of fragments. Most of the corner cases are errors, which
  ## end the lexing, so they are diluted to let the lexer get further.
  let spice = rng.sample([0.05, 0.3, 1.0])
  for _ in 0 ..< rng.rand(1 .. 12):
    if rng.rand(1.0) < spice:
      result.add rng.sample(fragments)
    else:
      result.add rng.sample(calm)

proc mutated(rng: var Rand, source: string): string =
  ## A window of a real source with a few random edits.
  var runes = source.toRunes
  if runes.len == 0:
    return rng.randomSource()
  let first = rng.rand(0 ..< runes.len)
  runes = runes[first ..< min(runes.len, first + rng.rand(1 .. 120))]
  for _ in 0 ..< rng.rand(1 .. 3):
    let at = rng.rand(0 .. runes.len)
    case rng.rand(0 .. 2)
    of 0:
      runes = runes[0 ..< at] & rng.sample(fragments).toRunes & runes[at .. ^1]
    of 1:
      if at < runes.len:
        runes.delete(at)
    else:
      if at < runes.len:
        runes.insert(runes[at], at)
  $runes

const specialFloats = [
  "0.", ".5", "5.", "1e5", "1E5", "1e", "e5", ".", "", "1.0e+", "inf", "-inf", "Infinity",
  "nan", "NaN", "+1.5", "-0.0", "1_0.0_1", "1..2", "1.2.3", "0x10", "1.0e-400", "4.9e-324",
  "2.4703282292062327e-324", "2.4703282292062328e-324", "1.7976931348623158e308",
  "1.7976931348623159e308", "9007199254740993.0", "9007199254740992.5", "1.0e23",
  "8.5e22", "123456789012345.0e22", "123456789012345.0e23", "1 ", " 1", "1.0f",
  "1.0e123456789012345678901234567890", "1.0e-123456789012345678901234567890",
  "0.0e123456789012345678901234567890",
]

proc randomDigits(rng: var Rand, count: int): string =
  for _ in 0 ..< count:
    result.add rng.sample("0123456789")

proc randomFloatLiteral(rng: var Rand): string =
  ## Float literals, with the hard cases over-represented: long mantissas,
  ## values exactly halfway between two floats (and one digit off), subnormals,
  ## huge exponents.
  case rng.rand(0 .. 9)
  of 0 .. 2:
    result = rng.randomDigits(rng.rand(1 .. 20)) & "." & rng.randomDigits(rng.rand(0 .. 20))
    if rng.rand(1) == 0:
      result.add "e" & rng.sample(["", "-"]) & $rng.rand(0 .. 340)
  of 3 .. 5:
    # Halfway between a random float and the next one: (2m + 1) * 2^(e - 1).
    let bits = rng.next() and 0x7FEF_FFFF_FFFF_FFFF'u64
    let biased = int(bits shr 52)
    let fraction = bits and ((1'u64 shl 52) - 1)
    let mantissa = if biased == 0: fraction else: fraction or (1'u64 shl 52)
    let exponent = (if biased == 0: -1074 else: biased - 1075) - 1
    var digits = initBigInt(mantissa) * initBigInt(2) + initBigInt(1)
    var decimalExponent = 0
    if exponent >= 0:
      digits = digits shl exponent
    else:
      digits = digits * pow(initBigInt(5), -exponent)
      decimalExponent = exponent
    case rng.rand(0 .. 2)
    of 0:
      discard
    of 1:
      digits = digits - initBigInt(1)
    else:
      digits = digits * initBigInt(10) + initBigInt(1)
      decimalExponent -= 1
    result = $digits & ".0e" & $decimalExponent
  of 6:
    result = rng.randomDigits(rng.rand(1 .. 5)) & "." & rng.randomDigits(rng.rand(0 .. 5)) &
      "e" & rng.sample(["", "-"]) & rng.randomDigits(rng.rand(1 .. 30))
  of 7 .. 8:
    result = "0." & repeat('0', rng.rand(0 .. 330)) & rng.randomDigits(rng.rand(1 .. 25))
    if rng.rand(2) == 0:
      result.add "e" & $rng.rand(0 .. 330)
  else:
    result = rng.sample(specialFloats)

proc randomIntLiteral(rng: var Rand): string =
  result = rng.sample(["", "", "0x", "0o", "0b", "-", "-0x", "0X", "+"])
  for _ in 0 ..< rng.rand(0 .. 40):
    result.add(
      if rng.rand(3) == 0: rng.sample("0123456789abcdefABCDEF_gz")
      else: rng.sample("01234567")
    )

when isMainModule:
  if paramStr(1) in ["--floats", "--ints"]:
    var rng = initRand(parseInt(paramStr(3)))
    for _ in 0 ..< parseInt(paramStr(2)):
      echo (if paramStr(1) == "--floats": rng.randomFloatLiteral() else: rng.randomIntLiteral())
    quit 0
  ## lexfuzz COUNT [SEED [FILE...]]: with files, half of the sources are
  ## mutations of them.
  let count = parseInt(paramStr(1))
  var rng = initRand(if paramCount() > 1: parseInt(paramStr(2)) else: 1)
  var corpus: seq[string]
  for i in 3 .. paramCount():
    let source = readFile(paramStr(i))
    if validateUtf8(source) == -1:
      corpus.add source
  var output = ""
  for _ in 0 ..< count:
    let source =
      if corpus.len > 0 and rng.rand(1.0) < 0.5:
        rng.mutated(rng.sample(corpus))
      else:
        rng.randomSource()
    output.add escapeBytes(source)
    output.add '\n'
  stdout.write output
