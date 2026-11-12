## devlog: 12 Nov 2026 J | A corpus of real Gleam | Seventy five projects, pinned at exact commits with their licences, for the Nim compiler to grow up on.
## kind: tooling
import std/[algorithm, json, os, strformat, strutils, sequtils, tables]
import nimib
import tabelline, tabelline/nimib
import ../blocks, ../site

nbInit
nb.usePost()

nbText: """
## The short version

A compiler is tested by compiling things. The Rust compiler's own tests are the first oracle,
and the plan post covers them. This post is about the second one: programs that people
actually wrote, from thirty lines to hundreds of thousands, that the Nim port will have to
lex, parse, type check and eventually compile to the same output as the original.

- The corpus is a **manifest, not a copy**. `corpus/sources.json` is a hand written list of
  repositories. `corpus/corpus.json` is generated from it and records, for each one, the exact
  commit, the licence, and what is inside.
- A small Nim tool, `tools/corpus.nim`, pins, fetches and measures. Nothing from the corpus is
  committed to this repository.
- The sources are chosen to form a **ladder**: tiny teaching programs, small libraries, the
  standard library, frameworks, whole applications, and a few compilers written in Gleam.
- Counting constructs across the corpus gives a first **ranking of language features** by how
  much real code depends on them.

Everything below is computed on this page from `corpus/corpus.json`.
"""

nbCode:
  let corpus = parseFile(docsDir.parentDir / "corpus" / "corpus.json")
  let sources = corpus["sources"].getElems
  let totalFiles = sources.mapIt(it["gleam_files"].getInt).foldl(a + b)
  let totalLines = sources.mapIt(it["gleam_lines"].getInt).foldl(a + b)
  echo sources.len, " sources pinned on ", corpus["generated"].getStr
  echo totalFiles.thousands, " Gleam files, ", totalLines.thousands, " lines"

nbText: """
## What is in it

Each source has a kind, chosen by hand, that says what it is good for.
"""

block:
  type Row = object
    kind, forWhat: string
    sources, files, lines: int
  let kinds = parseFile(docsDir.parentDir / "corpus" / "sources.json")["kinds"]
  var rows: seq[Row]
  for kind, what in kinds:
    let these = sources.filterIt(it["kind"].getStr == kind)
    rows.add Row(kind: kind, forWhat: what.getStr, sources: these.len,
      files: these.mapIt(it["gleam_files"].getInt).foldl(a + b, 0),
      lines: these.mapIt(it["gleam_lines"].getInt).foldl(a + b, 0))
  let t = tabella(rows, rownameCol = "kind"):
    tabHeader "The corpus by kind", "sources, Gleam files and lines of Gleam"
    colsHide "forWhat"
    fmtInteger()
    tabSourceNote "Lines include tests, comments and blank lines. One source, arc, accounts for more than a third of all lines."
    optCssTheme()
  nbTable t
  var legend = ""
  for row in rows: legend.add &"- **{row.kind}**: {row.forWhat}.\n"
  nbText legend

nbText: """
A few choices deserve a word.

**Snippets first.** The language tour is one small program per feature, written by the Gleam
team to teach the language. Exercism adds more than a hundred exercises, each with a solution
and tests. These are the programs a brand new lexer and parser should meet first.

**The standard library is the first real milestone.** Every Gleam program imports it, so
nothing else compiles until it does. It also has both Erlang and JavaScript helper files, so it
exercises `@external` from day one.

**Compilers in Gleam are both test input and second opinion.** `glexer` (a lexer), `glance`
(a parser) and `glimpse` (a type checker) are Gleam programs that understand Gleam. We can
compile them, and we can compare their idea of the language with ours.

**Two entries are not Gleam at all.** `tree-sitter-gleam` is an independent grammar with its
own parse tests. `glistix` is a fork of the Rust compiler with a third backend, which shows
where a new code generator plugs in.
"""

type SourceRow = object
  project, kind, licence, commit: string
  files, lines: int

proc toRow(s: JsonNode): SourceRow =
  let repo = s["repo"].getStr
  SourceRow(project: &"[{repo}]({s[\"url\"].getStr}/tree/{s[\"commit\"].getStr})",
    kind: s["kind"].getStr, licence: s["licence"].getStr, commit: s["commit"].getStr[0 ..< 10],
    files: s["gleam_files"].getInt, lines: s["gleam_lines"].getInt)

nbText: """
## The ladder

Sorted by size, the corpus is a staircase. These are the first rungs: the smallest sources
that are complete packages.
"""

block:
  var small = sources.filterIt(it["kind"].getStr in ["library", "core", "app"])
  small.sort(proc(a, b: JsonNode): int = cmp(a["gleam_lines"].getInt, b["gleam_lines"].getInt))
  let t = tabella(small[0 ..< 12].map(toRow), rownameCol = "project"):
    tabHeader "The twelve smallest packages", "where a young compiler can start"
    fmtMarkdown "project"
    fmtInteger()
    colsHide "commit"
    colsHide "files"
    colsHide "kind"
    optCssTheme()
  nbTable t

nbText: """
And this is the whole staircase, with the commit each source is pinned at.
"""

nbFold "All the sources, smallest first":
  block:
    var all = sources
    all.sort(proc(a, b: JsonNode): int = cmp(a["gleam_lines"].getInt, b["gleam_lines"].getInt))
    let t = tabella(all.map(toRow), rownameCol = "project"):
      fmtMarkdown "project"
      fmtInteger()
      optCssTheme()
    nbTable t

nbText: """
## Which features does real code use?

The tool counts, line by line, where some constructs appear. It is a rough count on purpose:
it skips comment lines and looks for keywords, no parser involved, because we do not have one
yet. It is good enough to rank features. One source is left out here: `arc` is so large that
it would drown the others.
"""

nbCode:
  var features = initCountTable[string]()
  var counted = 0
  for s in sources:
    if s["repo"].getStr == "alii/arc": continue
    counted += s["gleam_lines"].getInt
    for name, n in s["features"]: features.inc(name, n.getInt)
  features.sort()
  for name, n in features:
    echo name.alignLeft(12), align(n.thousands, 8), "   one line in ",
      (if n > 0: $(counted div n) else: "-")

nbText: """
What this says about the order of work:

- **Pipes and `case` are everywhere.** No surprise, and both are needed for the very first
  programs.
- **`use` is not a niche feature.** It shows up about once every eighty lines. It has to be in
  the first version of the parser and type checker, not left for later.
- **`let assert` and `assert` are the test suite.** Almost every test in the corpus is written
  with them, so running anybody's tests depends on both.
- **Bit arrays are common**, more than constants. Servers and parsers lean on them heavily.
- **`@external` appears about 1,600 times.** Real Gleam is glued to Erlang and JavaScript.
  We can type check that code without a runtime, but to run it we need the real BEAM and Node.
- **`echo`, `todo` and `panic` are rare** but cheap, and the language tour uses all three.
"""

nbText: """
## Two targets, and code that is not Gleam
"""

nbCode:
  var targets = initCountTable[string]()
  var ffi = initCountTable[string]()
  var packages = 0
  for s in sources:
    for p in s["packages"]:
      inc packages
      targets.inc p["target"].getStr
    for ext, n in s["ffi_files"]: ffi.inc(ext, n.getInt)
  echo packages, " packages (a repository can hold several)"
  for target, n in targets: echo "  target ", target.alignLeft(11), n
  echo "helper files in other languages:"
  ffi.sort()
  for ext, n in ffi: echo "  ", ext.alignLeft(6), n

nbText: """
A package declares one default target and most choose Erlang, but many libraries are written
to run on both. The helper files are the other half of every `@external` function. They are
not ours to compile, they only have to be carried along to the output unchanged.

## What depends on what

Counting the dependencies declared across all packages tells us what to make work first.
"""

nbCode:
  var deps = initCountTable[string]()
  for s in sources:
    if s["kind"].getStr in ["snippets", "tests", "reference"]: continue
    for p in s["packages"]:
      for d in p["dependencies"]: deps.inc d.getStr
  deps.sort()
  var shown = 0
  for name, n in deps:
    echo name.alignLeft(22), n
    inc shown
    if shown == 12: break

nbText: """
## Licences

Every source keeps its own licence, and the manifest records it twice: what the licence file
at the root of the repository says, and what `gleam.toml` declares.
"""

nbCode:
  var licences = initCountTable[string]()
  for s in sources: licences.inc s["licence"].getStr
  licences.sort()
  for name, n in licences: echo name.alignLeft(12), n
  echo "without a licence: ", sources.filterIt(it["licence"].getStr == "none").mapIt(it["repo"].getStr).join(", ")

nbNote """
Nothing in the corpus is copied into this repository, whatever its licence. The tool fetches
each source into `.corpus-cache/`, which git ignores. Sources with no licence are used only as
local test input. If a test ever needs a fixture committed here, it must come from a source
whose licence allows it, with its notice.
""", nkWarning, "The rule"

nbText: """
## The tool

`tools/corpus.nim` is about three hundred lines of Nim with no dependency beyond the standard
library, `git` and `curl`.

```sh
nim r tools/corpus.nim lock      # pin sources that are new in corpus/sources.json
nim r tools/corpus.nim update    # move every pin to the current head (or the given ref)
nim r tools/corpus.nim fetch     # check out every pinned commit into .corpus-cache/
nim r tools/corpus.nim fetch stdlib lustre   # only some
nim r tools/corpus.nim list      # a quick table in the terminal
```

To add a project, add one line to `corpus/sources.json` and run `lock`. Existing pins do not
move unless you ask with `update`, so a test that passed yesterday is run against the same
code today. The compiler itself is pinned by tag, `v1.19.2`, the snapshot we port. For each
package published on Hex the tool also records all time downloads, after checking that the
Hex package was really built with Gleam, since names like `arc` are taken by older packages.
"""

nbNote """
What was verified: every one of the sources resolved and was fetched at its pinned commit from
this sandbox on 12 November 2026, and `fetch` restores a source from the manifest alone.
What was not: none of this code has been compiled yet, by the original compiler or by ours.
The sandbox has no Gleam, Erlang or Node installed. That is a job for the plan and the first
port steps.
""", nkDone, "Checked, and not"

nbText: """
## What this changes for the port

1. **Each stage gets a corpus test.** Lexer: every `.gleam` file lexes without an error token
   and round trips. Parser: every file parses. Type checker: every package checks. Code
   generation: output equal to the reference compiler's. The same manifest serves all four.
2. **The order of sources is the order of difficulty.** Language tour, then the tiny
   libraries, then the standard library, then everything else.
3. **`use`, `let assert`, bit arrays and `@external` are core**, not extras. The feature
   counts say they must be in the first complete front end.
4. **Running tests needs the BEAM and Node.** Type checking the corpus does not. Comparing
   generated code needs the reference `gleam` binary. The sandbox setup should say which of
   these it installs.
5. **The pins move on purpose only.** `update` is a deliberate step, recorded in a commit.

## Sources

- `corpus/sources.json` and `corpus/corpus.json` in this repository, and `tools/corpus.nim`.
- [awesome-gleam](https://github.com/gleam-lang/awesome-gleam) and the GitHub search API, to
  find candidates.
- [`test-community-packages`](https://github.com/gleam-lang/gleam/tree/v1.19.2/test-community-packages)
  in the Gleam repository: the list of community packages the Gleam team itself compiles as a
  regression test, which confirmed many of the choices here.
- [hex.pm](https://hex.pm) API for download counts.
- The companion post [Gleam, its people and its programs](../gleam-and-its-people/).
"""

nbSave
