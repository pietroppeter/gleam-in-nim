## The Nim half of the pretty printer's differential test (see run.sh).
##
##   driver generate SEED COUNT   prints COUNT random documents, one per line
##   driver print                 reads documents, prints each at several widths
##
## A document is written in a small prefix language that the Rust driver
## (src/main.rs) reads too: `s` string, `z` zero width string, `b` and `f`
## strict and flex breaks, `l` lines, `e` empty, `o` cursor observer, `g`
## group, `n` nest, `i` nest if broken, `t` set nesting, `F` force break, `x`
## and `y` next break fits enabled and disabled, `a` append, `c` concat, `j`
## join. Text is in hexadecimal, `-` for the empty string.
import std/[os, random, strutils]
import ../../../src/gleam_in_nim/pretty

type Recorder = ref object of CursorPositionObserver
  seen: seq[string]

method observeCursorPosition(recorder: Recorder, line, width: int) =
  recorder.seen.add $line & ":" & $width

proc hex(text: string): string =
  for character in text: result.add toHex(ord(character), 2).toLowerAscii

proc unhex(token: string): string =
  if token == "-": "" else: parseHexStr(token)

proc build(tokens: seq[string], position: var int, recorder: Recorder): Document =
  template next(): string =
    inc position
    tokens[position - 1]
  case next()
  of "s": result = unhex(next()).toDoc
  of "z": result = zeroWidthStr(unhex(next()))
  of "b":
    let broken = unhex(next())
    result = breakDoc(broken, unhex(next()))
  of "f":
    let broken = unhex(next())
    result = flexBreak(broken, unhex(next()))
  of "l": result = lines(parseInt(next()))
  of "e": result = emptyDocument
  of "o": result = positionObserver(recorder)
  of "g": result = build(tokens, position, recorder).group
  of "n":
    let indent = parseInt(next())
    result = build(tokens, position, recorder).nest(indent)
  of "i":
    let indent = parseInt(next())
    result = build(tokens, position, recorder).nestIfBroken(indent)
  of "t":
    let indent = parseInt(next())
    result = build(tokens, position, recorder).setNesting(indent)
  of "F": result = build(tokens, position, recorder).forceBreak
  of "x": result = build(tokens, position, recorder).nextBreakFits(Enabled)
  of "y": result = build(tokens, position, recorder).nextBreakFits(Disabled)
  of "a":
    let first = build(tokens, position, recorder)
    result = first.append(build(tokens, position, recorder))
  of "c":
    var documents: seq[Document]
    for _ in 0 ..< parseInt(next()): documents.add build(tokens, position, recorder)
    result = concat(documents)
  of "j":
    let count = parseInt(next())
    let separator = build(tokens, position, recorder)
    var documents: seq[Document]
    for _ in 0 ..< count: documents.add build(tokens, position, recorder)
    result = join(documents, separator)
  else: quit("unknown token " & tokens[position - 1])

proc print() =
  for line in stdin.lines:
    for width in [0, 1, 2, 3, 5, 8, 13, 20, 40, 80]:
      let recorder = Recorder()
      var position = 0
      let document = build(line.splitWhitespace, position, recorder)
      echo width, " ", document.isEmpty, " ", hex(document.toPrettyString(width)), " ", recorder.seen.join(",")

const texts = ["", " ", "a", "wibble", "wobble_wubble", ",", "(", ")", "è", "é", "日本語",
  "👩‍👩‍👧‍👦", "🇮🇹", "\r\n", "a\nb", "क्षि", "the quick brown fox"]

proc text(rng: var Rand): string =
  let chosen = rng.sample(texts)
  if chosen.len == 0: "-" else: hex(chosen)

proc generate(rng: var Rand, depth: int): string =
  let leaf = depth <= 0 or rng.rand(1.0) < 0.25
  if leaf:
    case rng.rand(9)
    of 0 .. 3: "s " & rng.text
    of 4: "z " & rng.text
    of 5, 6: "b " & rng.text & " " & rng.text
    of 7: "f " & rng.text & " " & rng.text
    of 8: (if rng.rand(3) == 0: "o" else: "l " & $rng.rand(2))
    else: "e"
  else:
    template child(): string = generate(rng, depth - 1)
    case rng.rand(13)
    of 0, 1, 2: "g " & child()
    of 3: "n " & $rng.rand(-2 .. 6) & " " & child()
    of 4: "i " & $rng.rand(-2 .. 6) & " " & child()
    of 5: "t " & $rng.rand(0 .. 4) & " " & child()
    of 6: "F " & child()
    of 7: "x " & child()
    of 8: "y " & child()
    of 9: "a " & child() & " " & child()
    of 10, 11:
      let count = rng.rand(0 .. 6)
      var parts = "c " & $count
      for _ in 0 ..< count: parts.add " " & child()
      parts
    else:
      let count = rng.rand(0 .. 5)
      var parts = "j " & $count & " " & child()
      for _ in 0 ..< count: parts.add " " & child()
      parts

when isMainModule:
  case paramStr(1)
  of "print": print()
  of "generate":
    var rng = initRand(parseInt(paramStr(2)))
    for _ in 0 ..< parseInt(paramStr(3)): echo generate(rng, rng.rand(1 .. 7))
  else: quit("usage: driver generate SEED COUNT | driver print")
