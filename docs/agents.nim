## For coding agents, docs/agents/index.html: AGENTS.md as a page, read when the page is built,
## so the rules Pietro reviews on his phone are the rules the agents follow.
import std/[os, strutils]
import nimib
import blocks

let text = readFile(repoDir / "AGENTS.md")
let cut = text.find("\n## ")   # the page has its own title: skip the file's `# ` heading and intro
let (intro, body) = if cut >= 0: (text[0 ..< cut], text[cut .. ^1]) else: ("", text)
var lede: seq[string]
for line in intro.splitLines:
  if not line.startsWith("# "): lede.add line

nbInit
nb.doc.filename = docsDir / "agents" / "index.html"
nb.usePage(section = "For coding agents", cadence = "kept up to date", title = "For coding agents · gleam in nim", homeHref = "../",
           description = "The working rules of the gleam-in-nim repository.")
nbTitle "For coding agents · kept up to date", "The working rules", lede.join("\n").strip
nbToc
nbText body
nbSave
