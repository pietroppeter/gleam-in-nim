## The coverage map, docs/coverage/index.html: the Rust compiler module by module, and how much
## of it is ported. Kept up to date: the data is docs/data/coverage.json; the lines of Rust come
## from `tools/coverage_seed.nim`, the rest (status, the Nim module, the post) from the pull
## request that ports a module.
import std/[strformat]
import nimib
import tabelline, tabelline/nimib
import blocks, site

let cov = loadCoverage()

nbInit
nb.doc.filename = docsDir / "coverage" / "index.html"
nb.usePage(section = "Coverage map", cadence = "kept up to date", title = "Coverage map · gleam in nim", homeHref = "../",
           description = "The Gleam compiler module by module, and how much of it is ported to Nim.")

nbTitle "Coverage map · kept up to date", "The coverage map", &"""
What there is to port, and what is ported. The reference is Gleam
[{cov.pin.tag}]({cov.pin.repo}/tree/{cov.pin.tag}), commit `{cov.pin.shortCommit}`.
"""

nbPipeline cov.pipeline

nbToc

nbText: "## By stage"

block:
  type Row = object
    stage: string
    rust, tests: int
    status: string
  var rows: seq[Row]
  for s in cov.stages:
    rows.add Row(stage: &"**{s.name}**<br>{s.what}", rust: s.rustCode, tests: s.rustTests, status: status(s.status))
  let t = tabella(rows):
    tabHeader "The stages of the compiler", "lines of Rust in the reference"
    colsLabel {"stage": "stage", "rust": "Rust", "tests": "its tests"}
    fmtInteger ["rust", "tests"]
    fmtMarkdown "stage"
    fmtPassthrough "status", escape = false
    grandSummaryRows {"total": agg.sum}, columns = ["rust", "tests"]
    tabSourceNote md("Lines counted by `tools/coverage_seed.nim`: every line of every `.rs` file, comments and blanks included; tests are files named `tests.rs` or under a `tests/` folder.")
    optCssTheme()
  nbTable t

nbText: &"Ported so far: **{cov.portedCode.thousands}** of {cov.rustCode.thousands} lines of Rust (the lines of the modules that are done).\n"

nbText: """
## By module

One row per top-level module of each crate. `compiler-core` is listed module by module, the
other crates whole. The lexer is listed apart from the parser it lives in, because it is the
first step.
"""

block:
  type Row = object
    stage, module: string
    rust, tests: int
    status: string
  var rows: seq[Row]
  for s in cov.stages:
    for m in s.modules:
      let post = if m.post.len > 0: &" · [post](../devlog/{m.post}/)" else: ""
      let nim = if m.nim.len > 0: &"<br>in Nim: `{m.nim}`{post}" else: ""
      let notes = if m.notes.len > 0: "<br>" & m.notes else: ""
      rows.add Row(stage: &"{s.name}: {s.what}", module: &"`{m.module}`{nim}{notes}", rust: m.rustCode, tests: m.rustTests,
                   status: status(m.status))
  let t = tabella(rows, groupnameCol = "stage"):
    colsLabel {"rust": "Rust", "tests": "its tests"}
    fmtInteger ["rust", "tests"]
    fmtMarkdown "module"
    fmtPassthrough "status", escape = false
    optCssTheme()
  nbTable t

nbText: """
## How the map changes

- The pull request that ports a module sets its row in `docs/data/coverage.json`: `status`
  (`started`, then `done`), `nim` (the module in `src/`), `post` (the slug of its devlog post)
  and `notes` (what differs from the Rust, in a few words).
- `done` means: the Nim module does what the Rust one does, and its tests say so against the
  reference. Half done is `started`.
- When the pinned snapshot moves, `nim r tools/coverage_seed.nim path/to/gleam` recounts the
  Rust and keeps what people wrote.
"""

nbSave
