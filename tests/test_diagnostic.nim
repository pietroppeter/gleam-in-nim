# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The gleam-in-nim contributors
#
# Upstream has no unit tests for compiler-core/src/diagnostic.rs: it is tested
# through the 1,233 snapshots of errors and warnings. Until the port can raise
# those errors, the renderer is tested on cases recorded from upstream's own
# code by tests/differential/diagnostic (see tests/data/diagnostics.txt).
import std/[options, os, strutils, unittest]
import ../src/gleam_in_nim/[diagnostic, src_span, termcolor, unicode_width]
import std/unicode except strip, split

func unhex(text: string): string =
  if text == ".": "" else: parseHexStr(text)

proc render(line: string): string =
  ## Builds the diagnostic of a line of the data file (the format is in
  ## tests/differential/diagnostic/driver.nim) and writes it.
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
  var problem = Diagnostic(level: (if word() == "E": Level.Error else: Level.Warning))
  problem.title = unhex(word())
  problem.text = unhex(word())
  problem.hint = optional()
  if word() == "L":
    var location = Location(src: unhex(word()), path: unhex(word()))
    location.label = label()
    for _ in 0 ..< parseInt(word()):
      var extra: ExtraLabel
      if word() == "S": extra.srcInfo = some((unhex(word()), unhex(word())))
      extra.label = label()
      location.extraLabels.add extra
    problem.location = some(location)
  let buffer = if colour: Buffer.ansi else: Buffer.noColor
  problem.write(buffer)
  buffer.asString

suite "diagnostics":
  test "an error with a span, as Gleam prints it":
    let src = "pub fn main() {\n  1 + \"a\"\n}\n"
    let error = Diagnostic(
      title: "Type mismatch",
      text: "Expected type:\n\n    Int\n\nFound type:\n\n    String",
      level: Level.Error,
      location: some(Location(
        src: src, path: "/src/one/two.gleam",
        label: Label(text: none(string), span: SrcSpan(start: 22, stop: 25)))),
    )
    let buffer = Buffer.noColor
    error.write(buffer)
    check buffer.asString == """
error: Type mismatch
  ┌─ /src/one/two.gleam:2:7
  │
2 │   1 + "a"
  │       ^^^

Expected type:

    Int

Found type:

    String
"""

  test "a diagnostic without a location is a title, in colour or not":
    let warning = Diagnostic(title: "Something", text: "Text", level: Level.Warning,
                                        hint: some("Do this"))
    let plain = Buffer.noColor
    warning.write(plain)
    check plain.asString == "warning: Something\n\nText\n\nHint: Do this\n"
    let coloured = Buffer.ansi
    warning.write(coloured)
    check coloured.asString ==
      "\e[0m\e[1m\e[33mwarning\e[0m\e[1m: Something\n\n\e[0mText\n\nHint: Do this\n"

  test "character widths are those of unicode-width":
    check Rune('a').width == 1
    check "日".runeAt(0).width == 2
    check Rune(0x0301).width == 0   # a combining accent
    check Rune(0).width == 0        # a control character
    check Rune(0x17D8).width == 3   # the one character three columns wide (a Khmer sign)

  test "the cases recorded from upstream's Diagnostic::write":
    let path = currentSourcePath.parentDir / "data" / "diagnostics.txt"
    var cases = 0
    var input = ""
    for line in lines(path):
      if line.startsWith("#") or line.len == 0: continue
      if input.len == 0:
        input = line
      else:
        let expected = if line == "PANIC": "PANIC" else: unhex(line)
        var got: string
        try: got = render(input)
        except CatchableError, Defect: got = "PANIC"
        if got != expected:
          checkpoint "case " & $(cases + 1) & ": " & input
        check got == expected
        input = ""
        inc cases
    check cases == 60
