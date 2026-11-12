## devlog: 12 Nov 2026 O | What the real compiler says | The reference Gleam compiler was run over every package of the corpus, three ways, and its answers are now the expected results the Nim port is compared with.
## kind: tooling
import std/[algorithm, json, os, strutils, sequtils, tables]
import nimib
import tabelline, tabelline/nimib
import ../blocks, ../site

nbInit
nb.usePost()

nbText: """
## The short version

The [corpus](../a-corpus-of-real-gleam/) gave us real Gleam programs. A program is only a
test when you know the right answer, and for a port the right answer is whatever the original
compiler says. So this step asked it: the reference `gleam` binary, the exact release we
port, was run over every package of the corpus, and what it produced is kept as **goldens**.

- A new tool, `tools/golden.nim`, builds each package for Erlang and for JavaScript with the
  reference compiler and keeps five things: the binary abstract forms, the Erlang source, the
  JavaScript, the package interface as JSON, and everything the compiler printed.
- It needs **no Erlang**. A four line stand-in for `escript` lets the real build tool resolve
  and compile every Hex dependency in order, and stop just before the BEAM.
- The goldens are not committed: they are derived from other people's code and they are big.
  `corpus/golden.json` is committed instead, with the status of every package and a sha256 of
  each golden, so anybody can regenerate them and know they got the same bytes.
- Not everything builds, and that is a finding too. The failures are listed below with their
  reasons, because a port must fail in the same way on the same input.

The numbers on this page are computed from `corpus/golden.json`.
"""

nbCode:
  let golden = parseFile(docsDir.parentDir / "corpus" / "golden.json")
  var packages: seq[tuple[repo: string, p: JsonNode]]
  for repo, ps in golden["sources"]:
    for p in ps: packages.add (repo, p)
  proc ok(p: JsonNode, target: string): bool = p[target]["build"].getStr == "ok"
  let
    erlangOk = packages.countIt(it.p.ok("erlang"))
    jsOk = packages.countIt(it.p.ok("javascript"))
    bothOk = packages.countIt(it.p.ok("erlang") and it.p.ok("javascript"))
    neither = packages.countIt(not it.p.ok("erlang") and not it.p.ok("javascript"))
  echo golden["reference"].getStr, ", ", golden["sources"].len, " sources, ", packages.len, " packages"
  echo "built for Erlang:      ", erlangOk
  echo "built for JavaScript:  ", jsOk
  echo "built for both:        ", bothOk
  echo "built for neither:     ", neither

nbText: """
## Five goldens

For each package the tool leaves a folder in `.corpus-cache/golden/`, next to the checkout of
the source.

| Golden | What it is | Made by |
|---|---|---|
| `abstr/` | Erlang abstract forms, one binary file per module | `gleam build --target erlang` |
| `erlang/` | Erlang source, with what the compiler printed and its exit code | `gleam compile-package --target erlang --no-beam` |
| `javascript/` | JavaScript modules, same extras | `gleam compile-package --target javascript` |
| `interface.json` | every public type, function and constant with its type | `gleam export package-interface` |
| `build-*.txt`, `format.txt` | warnings and errors of the builds, and the files the formatter would change | `gleam build`, `gleam format --check` |

Each golden answers a different stage of the port. The interface is the oracle of the type
checker: it can be compared long before any code generator exists. The Erlang source and the
JavaScript are the oracles of the two back ends. The abstract forms are the output the build
tool really uses since v1.19. The printed warnings are the oracle of the diagnostics, which in
Gleam are a feature in their own right.
"""

nbCode:
  var bytes = initCountTable[string]()
  var files = initCountTable[string]()
  var interfaces = 0
  for (repo, p) in packages:
    for (name, node) in {"abstr": p["erlang"]["abstr"], "erlang": p["erlang"]["compile_package"],
        "javascript": p["javascript"]["compile_package"]}:
      bytes.inc(name, node{"bytes"}.getInt)
      files.inc(name, node{"files"}.getInt)
    if p.hasKey("interface"):
      inc interfaces
      bytes.inc("interface", p["interface"]["bytes"].getInt)
  for name in ["abstr", "erlang", "javascript"]:
    echo name.alignLeft(11), align(files[name].thousands, 8), " files ",
      align((bytes[name] div 1_000_000).thousands, 6), " MB"
  echo "interface".alignLeft(11), align(interfaces.thousands, 8), " files ",
    align((bytes["interface"] div 1_000_000).thousands, 6), " MB"

nbText: """
## Building for Erlang without Erlang

The sandboxes this port is written in have no Erlang, and installing the right version takes
a while. The low level `gleam compile-package` command does not need it, but it compiles one
package at a time and expects its dependencies to be compiled already, in the right order,
which is the build tool's job.

The build tool, on the other hand, insists on Erlang: after writing the abstract forms of a
package it hands them to a long running `escript` process that turns them into BEAM files,
and waits for an answer on a pipe. The protocol is one line each way. So the tool puts this on
the `PATH`:

```sh
#!/bin/sh
# Stand-in for escript: answer every compile request with "ok".
while read -r line; do echo gleam-compile-result-ok; done
```

With that, `gleam build --target erlang` runs to the end. It downloads the dependencies from
Hex at the versions of the package's manifest, compiles them in dependency order, and leaves
the abstract forms of every module on disk. No BEAM file is produced and nothing can be run,
but everything the Gleam compiler itself does has happened. The folder it leaves is then
exactly the `--lib` that `compile-package` wants, which gives the Erlang source too.
"""

nbNote """
The stand-in only replaces the last step, the one done by Erlang's own compiler. Dependencies
written in Erlang or Elixir are not compiled at all, which is fine for our purpose: Gleam only
needs the Gleam dependencies to type check and generate code.
""", nkGleam, "What is skipped"

nbText: """
## What built

By source, largest first.
"""

block:
  type Row = object
    source: string
    packages, erlang, javascript, warnings: int
  var rows: seq[Row]
  for repo, ps in golden["sources"]:
    var r = Row(source: repo, packages: ps.len)
    for p in ps:
      if p.ok("erlang"): inc r.erlang
      if p.ok("javascript"): inc r.javascript
      r.warnings += p["erlang"]["warnings"].getInt
    rows.add r
  rows.sort(proc(a, b: Row): int = cmp(b.packages, a.packages))
  nbFold "Every source: packages, how many built for each target, warnings":
    let t = tabella(rows, rownameCol = "source"):
      colsLabel {"erlang": "Erlang", "javascript": "JS"}
      fmtInteger()
      optCssTheme()
    nbTable t

nbText: """
## What did not build, and why

A failure is not noise. If the reference refuses a package, a faithful port must refuse it
too, with the same message. These are the reasons, most common first.
"""

nbCode:
  proc reason(text: string): string =
    ## The headline of an error, without the part that names a particular module or package.
    result = text.split(": ")[0]
    if result.len == 0: result = "(no error message captured)"
  for target in ["erlang", "javascript"]:
    var reasons = initCountTable[string]()
    for (repo, p) in packages:
      if not p.ok(target): reasons.inc reason(p[target]{"error"}.getStr)
    reasons.sort()
    echo target, ": ", packages.len - packages.countIt(it.p.ok(target)), " packages did not build"
    for why, n in reasons: echo "  ", align($n, 4), "  ", why

nbFold "Every package that did not build":
  nbCode:
    for (repo, p) in packages:
      for target in ["erlang", "javascript"]:
        if not p.ok(target):
          echo target.alignLeft(10), " ", repo, " ", p["path"].getStr, "\n    ", p[target]{"error"}.getStr

nbText: """
## Formatting and warnings

Two cheap signals come with every build.
"""

nbCode:
  let formatted = packages.countIt(it.p["format"]["status"].getStr == "formatted")
  let wouldChange = packages.countIt(it.p["format"]["status"].getStr == "would change")
  let filesToChange = packages.mapIt(it.p["format"]["files_to_change"].getInt).foldl(a + b)
  echo "packages already formatted as `gleam format` wants: ", formatted
  echo "packages it would change:                           ", wouldChange, " (", filesToChange, " files)"
  let withManifest = packages.countIt(it.p["manifest_committed"].getBool)
  echo "packages that commit a manifest (pinned dependencies): ", withManifest, " of ", packages.len

nbText: """
A package that is already formatted is a free test for our formatter: the output must equal
the input. A package without a committed manifest gets the newest dependencies that satisfy
its `gleam.toml` on the day the goldens are made, so its goldens can change when a dependency
publishes a release. The manifest the reference resolved is kept with the goldens and its
hash is in `corpus/golden.json`, so that kind of drift is visible and not mistaken for a bug.
"""

nbText: """
## Is it reproducible?

A golden that changes from run to run is worthless. After the full run, a sample of sources
was built a second time from scratch and every status, count and hash compared.

The first attempt at this check failed, and usefully. Most rows differed in one field: the
tool decided whether a package commits a manifest by looking for the file, and the first run
had left one behind. It now asks git, and deletes a manifest the project does not commit, so
each run resolves dependencies afresh. One package had also lost its interface in the first
run for a reason the tool had thrown away; the error of that command is now kept. With both
fixed, the whole corpus was run again, and then the sample:
"""

nbCode:
  let check = parseFile(docsDir / "devlog" / "data" / "what_the_reference_says" / "rerun.json")
  echo "sources picked by:        ", check["words"].mapIt(it.getStr).join(" ")
  echo "packages built twice:     ", check["packages"].getInt
  echo "identical in every field: ", check["identical"].getInt
  for d in check["different"]: echo "  differs: ", d.getStr

nbText: """
The missing interface did not come back in either later run, so its cause is not known: the
honest label is "seen once, not reproduced".
"""

nbText: """
## Using the goldens

```sh
reference/fetch.sh binary               # the pinned gleam, once
nim r tools/corpus.nim fetch            # the corpus, once
nim r tools/golden.nim run              # every package; add words to pick sources
nim r tools/golden.nim run stdlib --keep   # skip what is already there
nim r tools/golden.nim summary
nim r tools/golden.nim list             # JSON lines, one per package and target
```

`list` is the bridge to `tools/difftest.nim`, the harness that compares a candidate compiler
with the reference. Each line names a package, the folder of its compiled dependencies, the
folder of expected outputs and the extra flags, so the candidate can be run on real packages
with their dependencies and compared without running the reference again.
"""

nbNote """
What was verified: the tool ran over the whole corpus in this sandbox with the pinned
`gleam 1.19.2`; the counts above are from that run; the second run of a sample is reported as
it came out. What was not: no generated code was executed, since there is no BEAM here, so
"built" means the Gleam compiler was satisfied, not that tests pass. The compiled dependency
folders contain the reference's own `.cache` files, which a candidate compiler may not be able
to read until it writes the same format.
""", nkDone, "Checked, and not"

nbText: """
## What this changes for the port

1. **Every stage has an oracle on real code.** Formatter: packages already formatted. Type
   checker: `interface.json` and the printed warnings. Back ends: `erlang/` and
   `javascript/`. Build tool: `abstr/` and the resolved manifests.
2. **The type checker can be tested before any back end**, by comparing package interfaces.
3. **Erlang is not needed to make goldens**, only to run code. Installing it becomes a
   separate step, needed first for the milestone where compiled code must run.
4. **Failures are expectations too.** The packages the reference rejects stay in the corpus,
   with their error, as negative tests.
5. **Dependencies come with the package.** The port has to read `gleam.toml` and
   `manifest.toml` and find modules of other packages well before it resolves versions
   itself. That part of the build tool is the next thing this thread ports.

## Sources

- `tools/golden.nim` and `corpus/golden.json` in this repository.
- [`compiler-cli/src/beam_compiler.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-cli/src/beam_compiler.rs)
  in the Gleam repository, for the protocol between the build tool and `escript`.
- `gleam help compile-package` and `gleam help export` of the reference binary.
- [A corpus of real Gleam](../a-corpus-of-real-gleam/), the post about the inputs, and
  [How this port is developed](../how-we-work/), where the differential harness is described.
"""

nbSave
