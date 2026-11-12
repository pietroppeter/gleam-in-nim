## The Nim half of the diagnostics' differential test.
##
##   driver generate SEED COUNT   random diagnostics, one per line, on stdout
##   driver print                 reads those lines, prints each diagnostic as hex
##
## A line is words separated by spaces. Text is hex (`.` for the empty string, `-` for none):
##   COLOUR(0|1) LEVEL(E|W) TITLE TEXT HINT (N | L SRC PATH LABEL COUNT EXTRA*)
##   LABEL = TEXT START END        EXTRA = (M | S SRC PATH) LABEL
import std/[options, os, random, strutils]
import ../../../src/gleam_in_nim/[diagnostic, src_span, termcolor]

func hex(text: string): string =
  if text.len == 0: "." else: text.toHex.toLowerAscii

func unhex(text: string): string =
  if text == ".": "" else: parseHexStr(text)

const pieces = ["let", "x", "wibble", "wobble", "=", "+", "1", "\"a\"", "fn", "(", ")", "{", "}",
                " ", " ", " ", "  ", "\t", "\t", "é", "日本", "👩‍👩‍👧‍👦", "e\u0301", "🇮🇹", "\u200B", "ﷺ", "\u17D8", "\0"]
const words = ["this", "is", "a", "String", "expected", "Int", "here", "`wibble`", "naïve", "日本語", "-",
               "averyveryverylongwordthatneedsbreakingbecauseitislongerthanalinecanbe_averyveryverylongword"]

proc source(rng: var Rand): string =
  let lines = rng.rand(0 .. 14)
  for index in 0 ..< lines:
    for _ in 0 ..< rng.rand(0 .. 8): result.add rng.sample(pieces)
    if index < lines - 1 or rng.rand(1.0) < 0.7:
      result.add (if rng.rand(1.0) < 0.15: "\r\n" else: "\n")

proc sentence(rng: var Rand, most: int): string =
  for index in 0 ..< rng.rand(0 .. most):
    if index > 0: result.add (if rng.rand(1.0) < 0.05: "\n" else: " ")
    result.add rng.sample(words)

proc position(rng: var Rand, src: string): int =
  result = rng.rand(0 .. src.len)
  # mostly on a character boundary
  if rng.rand(1.0) < 0.95:
    while result > 0 and result < src.len and (src[result].ord and 0xC0) == 0x80: dec result

proc label(rng: var Rand, src: string): string =
  var start = rng.position(src)
  var stop = rng.position(src)
  if start > stop: swap start, stop
  if rng.rand(1.0) < 0.6: stop = min(src.len, start + rng.rand(0 .. 6))
  if rng.rand(1.0) < 0.9:
    while stop < src.len and (src[stop].ord and 0xC0) == 0x80: inc stop
  let text = if rng.rand(1.0) < 0.25: "-" else: hex(rng.sentence(4))
  text & " " & $start & " " & $stop

proc generate(seed, count: int) =
  var rng = initRand(seed)
  for _ in 0 ..< count:
    var line = @[$rng.rand(0 .. 1), rng.sample(["E", "W"]), hex(rng.sentence(5)), hex(rng.sentence(30)),
                 (if rng.rand(1.0) < 0.4: "-" else: hex(rng.sentence(40)))]
    if rng.rand(1.0) < 0.1:
      line.add "N"
    else:
      let src = rng.source()
      line.add ["L", hex(src), hex("src/app.gleam"), rng.label(src)]
      let extras = if rng.rand(1.0) < 0.5: 0 else: rng.rand(1 .. 4)
      line.add $extras
      for _ in 0 ..< extras:
        if rng.rand(1.0) < 0.3:
          let other = rng.source()
          line.add ["S", hex(other), hex(rng.sample(["src/other.gleam", "src/app.gleam", "test/日本.gleam"])),
                    rng.label(other)]
        else:
          line.add ["M", rng.label(src)]
    echo line.join(" ")

proc print() =
  for line in stdin.lines:
    let words = line.split(' ')
    var next = 0
    proc word(): string =
      result = words[next]
      inc next
    proc optional(): Option[string] =
      let text = word()
      if text == "-": none(string) else: some(unhex(text))
    proc label(): Label =
      result.text = optional()
      result.span = SrcSpan(start: parseInt(word()), stop: parseInt(word()))
    let colour = word() == "1"
    var diagnostic = Diagnostic(level: (if word() == "E": Level.Error else: Level.Warning))
    diagnostic.title = unhex(word())
    diagnostic.text = unhex(word())
    diagnostic.hint = optional()
    if word() == "L":
      var location = Location(src: unhex(word()), path: unhex(word()))
      location.label = label()
      for _ in 0 ..< parseInt(word()):
        var extra: ExtraLabel
        if word() == "S": extra.srcInfo = some((unhex(word()), unhex(word())))
        extra.label = label()
        location.extraLabels.add extra
      diagnostic.location = some(location)
    try:
      let buffer = if colour: Buffer.ansi else: Buffer.noColor
      diagnostic.write(buffer)
      echo hex(buffer.asString)
    except CatchableError, Defect:
      echo "PANIC"

case paramStr(1)
of "generate": generate(parseInt(paramStr(2)), parseInt(paramStr(3)))
of "print": print()
else: quit "usage: driver generate SEED COUNT | driver print"
