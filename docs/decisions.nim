## The decision records, docs/decisions/index.html: every choice a later session could make
## another way, one Markdown file each in docs/decisions/ (`NNNN-slug.md`: a front matter with
## title, status and date, then Context, Decision, Consequences). The page finds them itself.
## Kept up to date: a record is added in the pull request that makes the decision.
import std/[os, strutils, algorithm]
import nimib
import blocks

type Record = object
  number, title, status, date, body: string

proc readRecord(path: string): Record =
  result.number = path.extractFilename[0 .. 3]
  let parts = readFile(path).split("---\n", maxsplit = 2)
  doAssert parts.len == 3, path & ": a record starts with a front matter between two lines of ---"
  for line in parts[1].splitLines:
    let pair = line.split(": ", maxsplit = 1)
    if pair.len == 2:
      case pair[0]
      of "title": result.title = pair[1]
      of "status": result.status = pair[1]
      of "date": result.date = pair[1]
      else: discard
  doAssert result.title.len > 0 and result.status.len > 0 and result.date.len > 0,
    path & ": the front matter needs title, status and date"
  # The sections of a record sit one level below its title on the page.
  result.body = parts[2].strip.replace("\n## ", "\n#### ")
  if result.body.startsWith("## "): result.body = "##" & result.body

proc records(): seq[Record] =
  for path in walkFiles(docsDir / "decisions" / "*.md"):
    result.add readRecord(path)
  result.sort(proc (a, b: Record): int = cmp(a.number, b.number))

func heading*(r: Record): string = r.number & " " & r.title

nbInit
nb.doc.filename = docsDir / "decisions" / "index.html"
nb.usePage(section = "Decisions", cadence = "kept up to date", title = "Decisions · gleam in nim",
           homeHref = "../", description = "The decision records of the port of the Gleam compiler to Nim.")

nbTitle "Decisions · kept up to date", "The decisions", """
Every choice that a later session could reasonably make another way is written down once, short
and dated: the context, the decision, what follows from it. A record is not rewritten: a new one
replaces it. The reasoning at length is in the [devlog](../devlog/).
"""

let all = records()

block:
  var list = "| | Decision | Status |\n| --- | --- | --- |\n"
  for r in all:
    list.add "| " & r.number & " | [" & r.title & "](#" & slugify(r.heading) & ") | " & r.status & " |\n"
  nbText: list

for r in all:
  nbText: "## " & r.heading & "\n\n*" & r.status & ", " & r.date & "*\n\n" & r.body

nbText: "## Divergences\n\n" & readFile(docsDir / "divergences.md")

nbSave
