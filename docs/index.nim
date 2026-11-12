## The home page, docs/index.html.
import std/[strformat]
import nimib
import blocks, site

let cov = loadCoverage()
let posts = devlogPosts()

nbInit
nb.doc.filename = docsDir / "index.html"
nb.usePage(title = "gleam in nim", cadence = "kept up to date",
           description = "The Gleam compiler, ported to Nim one explained step at a time.")

nbTitle "A port, built in public", "The Gleam compiler, in Nim", """
[Gleam](https://gleam.run) is a friendly, statically typed language for the BEAM and for
JavaScript, with a compiler written in Rust. This project ports a snapshot of that compiler to
[Nim](https://nim-lang.org), one well defined step at a time, and explains every step.
"""

nbText: &"""
The snapshot is Gleam [{cov.pin.tag}]({cov.pin.repo}/tree/{cov.pin.tag}) (commit `{cov.pin.shortCommit}`):
{cov.rustCode.thousands} lines of Rust, tests not counted. Ported so far: {cov.portedCode.thousands}.
Each lamp is a stage of the compiler; it turns yellow when its port starts and pink when it is done.
"""

nbPipeline cov.pipeline

nbText: """
## Why

To learn how a real compiler is made by making one again, in a language its author knows well;
to see how far an AI model can carry a long port when each step is small, verified against the
original, and explained to a person who reviews it; and for the fun of it. It is not a
replacement for Gleam's compiler, and it is not affiliated with the Gleam project.

## Where to go
"""

nbCards "the pages of the site":
  nbCard("Devlog", "devlog/", "dated posts", nkInfo):
    nbText "Every step, explained: research, plans and the port itself."
  nbCard("Roadmap", "roadmap/", "kept up to date", nkInfo):
    nbText "The phases and their steps, and where each one stands."
  nbCard("Coverage map", "coverage/", "kept up to date", nkInfo):
    nbText "The Rust compiler module by module, and how much of it is in Nim."
  nbCard("Decisions", "decisions/", "kept up to date", nkInfo):
    nbText "The choices of the port, each a short dated record: context, decision, consequences."
  nbCard("Porting guide", "porting/", "kept up to date", nkInfo):
    nbText "How the Rust of the Gleam compiler is written in Nim here: rules, idiom map, traps."
  nbCard("For coding agents", "agents/", "kept up to date", nkInfo):
    nbText "The working rules of the repository: how a step, a post and a pull request are made."

nbText: "## Latest posts"

nbCards "the latest posts":
  for i, p in posts:
    if i >= 6: break
    nbCard(p.title, "devlog/" & p.slug & "/", &"{p.date} · {p.kind}", (if p.kind == "port": nkGleam elif p.kind == "research": nkNim else: nkInfo)):
      nbText p.lede
nbSave
