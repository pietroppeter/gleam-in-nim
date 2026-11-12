## The roadmap, docs/roadmap/index.html: the phases of the port and their steps, with their
## status. Kept up to date: the data is docs/data/roadmap.json, changed in the pull request
## that starts, ships or replans a step.
import std/[strformat]
import nimib
import tabelline, tabelline/nimib
import blocks, site

let phases = loadRoadmap()
let milestones = loadMilestones()
let posts = devlogPosts()

proc hasPost(slug: string): bool =
  for p in posts:
    if p.slug == slug: return true

nbInit
nb.doc.filename = docsDir / "roadmap" / "index.html"
nb.usePage(section = "Roadmap", cadence = "kept up to date", title = "Roadmap · gleam in nim", homeHref = "../",
           description = "The phases of porting the Gleam compiler to Nim, their steps and where each stands.")

nbTitle "Roadmap · kept up to date", "The roadmap", """
The port goes in phases, each a list of steps. A step is a well defined task, small enough to
verify, and it ships with a [devlog](../devlog/) post. The plan is revised after every step.
"""

nbToc

proc phaseStatus(id: string): Status =
  for p in phases:
    if p.id == id:
      return (if p.steps.len > 0 and p.done == p.steps.len: stDone elif p.done > 0: stStarted else: stPlanned)

if milestones.len > 0:
  nbText: """
## Milestones

A milestone is a point where the port can prove something about itself against the reference.
Each is reached at the end of a phase.
"""
  block:
    type Row = object
      milestone, phase, status: string
    var rows: seq[Row]
    for m in milestones:
      rows.add Row(milestone: &"**{m.id} · {m.title}**<br>{m.proof}", phase: m.after, status: status(phaseStatus(m.after)))
    let t = tabella(rows):
      colsLabel {"milestone": "milestone, and its proof", "phase": "after phase"}
      fmtMarkdown "milestone"
      fmtPassthrough "status", escape = false
      colsWidth {"phase": "4.5em", "status": "5.5em"}
      optCssTheme()
    nbTable t

for phase in phases:
  nbText: &"## Phase {phase.id}: {phase.title}\n\n{phase.goal}\n\n{phase.done} of {phase.steps.len} steps done.\n"
  block:
    type Row = object
      step, kind, status: string
    var rows: seq[Row]
    for s in phase.steps:
      let title = if s.post.len > 0 and hasPost(s.post): &"[**{s.title}**](../devlog/{s.post}/)" else: &"**{s.title}**"
      let pr = if s.pr.len > 0: &" ([#{s.pr}]({repoUrl}/pull/{s.pr}))" else: ""
      let doneWhen = if s.doneWhen.len > 0: &"<br>*Done when:* {s.doneWhen}" else: ""
      let owner = if s.owner.len > 0: &"<br>*Thread:* {s.owner}" else: ""
      rows.add Row(step: &"{title}{pr}<br>{s.what}{doneWhen}{owner}", kind: s.kind, status: status(s.status))
    let t = tabella(rows):
      colsLabel {"step": "step, and what it does"}
      fmtMarkdown "step"
      fmtPassthrough "status", escape = false
      colsWidth {"kind": "5.5em", "status": "5.5em"}
      optCssTheme()
    nbTable t

nbText: """
## How the roadmap changes

- A step starts: its status becomes `started` in `docs/data/roadmap.json`, in the first pull
  request of the step.
- A step ships: `done`, with the slug of its post and the number of its pull request.
- A thread claims a step by writing its title as the step's `owner`, in a pull request,
  before it starts. *Done when* is the test the step must pass.
- The plan changes: steps are added, split or dropped here, and the post of the step that
  caused the change says why.
"""

nbSave
