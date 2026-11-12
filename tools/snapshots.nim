## Reads the snapshot tests of the reference Gleam compiler (insta `.snap` files).
##
## Upstream keeps thousands of expected outputs as snapshots. Many embed the Gleam source they
## were made from, so they work as a conformance suite for the port: feed `SOURCE CODE` to the
## Nim code, compare with the other section, byte for byte.
##
## A snapshot is a small front matter (`source:`, `expression:`) and a body. The body is either
## plain text or a list of sections, each opened by a line `----- TITLE`.
import std/[os, strutils, algorithm]

type
  Section* = object
    title*: string   ## "SOURCE CODE", "COMPILED ERLANG", "ERROR", ... or "" for a plain body
    text*: string    ## the text of the section, without the blank line insta puts at the end
  Snap* = object
    path*: string         ## path of the .snap file, relative to the reference checkout
    source*: string       ## the Rust file whose test wrote it (front matter `source:`)
    expression*: string   ## front matter `expression:`, raw
    name*: string         ## test name: the last `__` part of the file name
    sections*: seq[Section]

const sectionMark = "----- "

proc parseSnap*(content: string, path = ""): Snap =
  ## Parses the content of a `.snap` file.
  result.path = path
  result.name = path.extractFilename.changeFileExt("").rsplit("__", maxsplit = 1)[^1]
  let lines = content.splitLines
  var i = 0
  if lines.len > 0 and lines[0] == "---":
    i = 1
    while i < lines.len and lines[i] != "---":
      let line = lines[i]
      if line.startsWith("source: "): result.source = line[8 .. ^1].strip(chars = {'"'})
      elif line.startsWith("expression: "): result.expression = line[12 .. ^1]
      inc i
    inc i # the closing ---
  var current = Section()
  var body: seq[string]
  var started = false
  template flush() =
    if started or body.len > 0:
      while body.len > 0 and body[^1] == "": discard body.pop
      current.text = body.join("\n")
      result.sections.add current
  while i < lines.len:
    let line = lines[i]
    if line.startsWith(sectionMark):
      flush()
      current = Section(title: line[sectionMark.len .. ^1].strip)
      body = @[]
      started = true
    else:
      body.add line
    inc i
  flush()

proc loadSnap*(refDir, relPath: string): Snap =
  parseSnap(readFile(refDir / relPath), relPath)

proc section*(s: Snap, title: string): string =
  ## The text of the first section with this title, or "" when there is none.
  for sec in s.sections:
    if sec.title == title: return sec.text

proc has*(s: Snap, title: string): bool =
  for sec in s.sections:
    if sec.title == title: return true

proc snapPaths*(refDir: string, under = ""): seq[string] =
  ## Every `.snap` file of the reference checkout (relative paths, sorted), optionally only
  ## those under a directory such as `compiler-core/src/erlang`.
  for path in walkDirRec(refDir / under, relative = true):
    if path.endsWith(".snap") and "target" notin path.split({'/', '\\'}):
      result.add(if under.len > 0: under / path else: path)
  result.sort

iterator snaps*(refDir: string, under = ""): Snap =
  for path in snapPaths(refDir, under):
    yield loadSnap(refDir, path)

proc selfTest*() =
  ## Proves the parser; `nim r tools/snapshots.nim` and tests/test_tools.nim run it.
  let s = parseSnap("---\nsource: a/b.rs\nexpression: \"x\"\n---\n----- SOURCE CODE\nlet x\n\n----- ERROR\nboom\n  here\n",
                    "a/snapshots/gleam_core__parse__tests__my_test.snap")
  doAssert s.source == "a/b.rs"
  doAssert s.name == "my_test"
  doAssert s.sections.len == 2
  doAssert s.section("SOURCE CODE") == "let x"
  doAssert s.section("ERROR") == "boom\n  here"
  let plain = parseSnap("---\nsource: a.rs\n---\nhello\nworld\n")
  doAssert plain.sections.len == 1 and plain.sections[0].title == "" and plain.sections[0].text == "hello\nworld"
  echo "ok: snapshots"

when isMainModule: selfTest()
