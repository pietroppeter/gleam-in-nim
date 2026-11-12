## The data the living pages share: the coverage map (`docs/data/coverage.json`, seeded by
## `tools/coverage_seed.nim`) and the roadmap (`docs/data/roadmap.json`). Pages read them here,
## so the home page, the roadmap and the coverage map always agree.
import std/[json, os, strutils]
import blocks

type
  Module* = object
    ## A top-level module of the Rust compiler and where its port stands.
    module*, stage*, nim*, post*, notes*: string
    rustCode*, rustTests*: int
    status*: Status
  Stage* = object
    ## A stage of the compiler: a group of modules, with the status they add up to.
    id*, name*, what*: string
    modules*: seq[Module]
    rustCode*, rustTests*, portedCode*: int
    status*: Status
  Pin* = object
    ## The snapshot of the Gleam compiler being ported.
    repo*, tag*, commit*: string
  Coverage* = object
    pin*: Pin
    stages*: seq[Stage]
  Step* = object
    ## A step of the roadmap: a well defined task that ships with an explainer.
    id*, kind*, title*, what*, post*, pr*: string
    doneWhen*: string   ## the test the step must pass, or ""
    owner*: string      ## the thread that claimed the step, or ""
    status*: Status
  Phase* = object
    id*, title*, goal*: string
    steps*: seq[Step]
  Milestone* = object
    ## A point where the port can prove something about itself: reached `after` a phase, by `proof`.
    id*, title*, after*, proof*: string

const dataDir = docsDir / "data"

proc loadCoverage*(): Coverage =
  let j = parseFile(dataDir / "coverage.json")
  result.pin = Pin(repo: j["pin"]["repo"].getStr, tag: j["pin"]["tag"].getStr, commit: j["pin"]["commit"].getStr)
  for s in j["stages"]:
    var stage = Stage(id: s["id"].getStr, name: s["name"].getStr, what: s["what"].getStr)
    var done, begun = 0
    for m in j["modules"]:
      if m["stage"].getStr != stage.id: continue
      let module = Module(module: m["module"].getStr, stage: stage.id, nim: m{"nim"}.getStr, post: m{"post"}.getStr,
                          notes: m{"notes"}.getStr, rustCode: m["rust_code"].getInt, rustTests: m["rust_tests"].getInt,
                          status: toStatus(m{"status"}.getStr))
      stage.modules.add module
      stage.rustCode += module.rustCode
      stage.rustTests += module.rustTests
      if module.status == stDone: (inc done; stage.portedCode += module.rustCode)
      if module.status in {stStarted, stBlocked}: inc begun
    stage.status = if stage.modules.len > 0 and done == stage.modules.len: stDone
                   elif done + begun > 0: stStarted else: stPlanned
    result.stages.add stage
  for m in j["modules"]:
    var known = false
    for s in result.stages:
      if s.id == m["stage"].getStr: known = true
    doAssert known, "coverage.json: module " & m["module"].getStr & " has an unknown stage " & m["stage"].getStr

func rustCode*(c: Coverage): int =
  for s in c.stages: result += s.rustCode
func portedCode*(c: Coverage): int =
  for s in c.stages: result += s.portedCode
func shortCommit*(p: Pin): string = p.commit[0 ..< min(7, p.commit.len)]

func pipeline*(c: Coverage): seq[(string, Status)] =
  ## The stages and their status, for `nbPipeline`.
  for s in c.stages: result.add (s.name, s.status)

proc loadRoadmap*(): seq[Phase] =
  let j = parseFile(dataDir / "roadmap.json")
  for p in j["phases"]:
    var phase = Phase(id: p["id"].getStr, title: p["title"].getStr, goal: p{"goal"}.getStr)
    for s in p["steps"]:
      let kind = s{"kind"}.getStr("port")
      doAssert kind in postKinds, "roadmap.json: step " & s["id"].getStr & ": kind must be one of " & postKinds.join(", ")
      phase.steps.add Step(id: s["id"].getStr, kind: kind, title: s["title"].getStr, what: s{"what"}.getStr,
                           post: s{"post"}.getStr, pr: s{"pr"}.getStr, status: toStatus(s{"status"}.getStr),
                           doneWhen: s{"done_when"}.getStr, owner: s{"owner"}.getStr)
    result.add phase

proc loadMilestones*(): seq[Milestone] =
  ## The milestones of the roadmap (`milestones` in roadmap.json), or none.
  let j = parseFile(dataDir / "roadmap.json")
  for m in j{"milestones"}.getElems:
    result.add Milestone(id: m["id"].getStr, title: m["title"].getStr, after: m{"after"}.getStr, proof: m{"proof"}.getStr)

func done*(p: Phase): int =
  ## How many steps of the phase are done.
  for s in p.steps:
    if s.status == stDone: inc result

func thousands*(n: int): string =
  ## 137715 as `137,715`.
  let s = $n
  for i, c in s:
    if i > 0 and (s.len - i) mod 3 == 0: result.add ','
    result.add c
