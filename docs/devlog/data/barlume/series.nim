## What the posts of the series on the stages of a compiler share: the list of its parts
## (series.json) and a way to show a part of Barlume's source.
import std/[json, os, strutils]

const here = currentSourcePath.parentDir

proc seriesTable*(current: string): string =
  ## The parts of the series as a Markdown table, for a post in `docs/devlog/<slug>/`:
  ## a published part is a link, the `current` one is in bold, the others are planned.
  result = "| | Stage | The question | It turns |\n|---:|---|---|---|\n"
  var number = 0
  for part in parseFile(here / "series.json")["parts"]:
    inc number
    let slug = part["post"].getStr
    let stage = part["stage"].getStr
    let name =
      if slug == current: "**" & stage & "** (this post)"
      elif slug.len > 0: "[" & stage & "](../" & slug & "/)"
      else: stage & " (planned)"
    result.add "| " & $number & " | " & name & " | " & part["question"].getStr & " | " &
      part["takes"].getStr & " into " & part["gives"].getStr & " |\n"

proc barlume*(file, part: string): string =
  ## A part of a Barlume source file as a Nim code fence: the lines between `#--- part` and
  ## the next `#--- end`.
  var lines: seq[string]
  var inside = false
  for line in readFile(here / file).splitLines:
    if line.strip == "#--- " & part: inside = true
    elif line.strip == "#--- end": inside = false
    elif inside: lines.add line
  doAssert lines.len > 0, file & " has no part " & part
  "```nim\n" & lines.join("\n") & "\n```"

proc barlumeLines*(file: string): int =
  ## The lines of code of a Barlume source file: not blank, not only a comment.
  for line in readFile(here / file).splitLines:
    if line.strip.len > 0 and not line.strip.startsWith("#"): inc result
