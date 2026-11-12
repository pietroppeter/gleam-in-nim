## golden: what the reference compiler makes of the corpus, kept as expected results.
##
##   nim r tools/golden.nim run                 every package of every corpus source
##   nim r tools/golden.nim run stdlib lustre   only sources whose repo contains a word
##   nim r tools/golden.nim list                JSON lines for other tools: package, lib, goldens
##   nim r tools/golden.nim summary             totals from corpus/golden.json
##   options: --jobs:N (default: the number of processors), --keep (do not rebuild a package
##            whose goldens are already in the cache)
##
## For each package of corpus/corpus.json (fetch them first: `nim r tools/corpus.nim fetch`) the
## reference `gleam` builds it three ways, and the outputs are copied to
## .corpus-cache/golden/<owner>__<repo>/<package path>/ :
##
##   abstr/           Erlang abstract forms, binary: what `gleam build --target erlang` writes
##   erlang/          `gleam compile-package --target erlang --no-beam`: out/ (Erlang source),
##                    stdout, stderr, code
##   javascript/      `gleam compile-package --target javascript`: out/, stdout, stderr, code
##   interface.json   `gleam export package-interface`: the public types, the type checker's oracle
##   build-erlang.txt, build-javascript.txt   what `gleam build` printed, normalised
##   format.txt       the files `gleam format --check` would change
##
## The compiled dependencies stay in <package>/build/dev/<target>, the `--lib` of that package.
##
## Nothing there is committed. corpus/golden.json is: per package the status of each target, the
## counts, and a sha256 over each golden folder, so a later run can tell whether it got the same
## bytes. Comparing a candidate compiler against these is the job of tools/difftest.nim.
##
## No Erlang is needed. The build tool wants `escript` to turn its abstract forms into BEAM
## files; we put a stand-in on the PATH that answers every request with "ok", so the build
## resolves the Hex dependencies, compiles them in order, and stops before the BEAM.
##
## The reference binary is $GLEAM_BIN, or reference/bin/gleam, or `gleam` on the PATH.
## Output is for an agent: one line per package that fails, starting with ERROR, and a last
## line with the totals.
import std/[algorithm, json, os, osproc, sequtils, strformat, strutils, tables, times]

const
  root = currentSourcePath().parentDir.parentDir
  lockPath = root / "corpus" / "corpus.json"
  goldenPath = root / "corpus" / "golden.json"
  cacheDir = root / ".corpus-cache"
  goldenDir = cacheDir / "golden"
  stubDir = cacheDir / "stubs"
  skipKinds = ["tests", "reference"]
    ## `tests` is the compiler's own repository: its test projects are run by upstream's test
    ## suite, many fail on purpose, and tools/difftest.nim already covers its snapshots.
  timeoutSeconds = 600
  escriptStub = """#!/bin/sh
# Stand-in for escript, written by tools/golden.nim. The Gleam build tool starts one escript
# and sends it a line per package to compile to BEAM; answering "ok" lets the build go on
# without Erlang. The abstract forms it wrote stay in build/dev/erlang/*/_gleam_artefacts.
while read -r line; do echo gleam-compile-result-ok; done
"""
  refuseStub = """#!/bin/sh
# Stand-in written by tools/golden.nim: this sandbox builds no Erlang or Elixir dependency.
exit 0
"""

type
  Job = object
    repo, slug, path, name, dir, gold: string

proc slug(repo: string): string = repo.replace("/", "__")

proc referenceBin(): string =
  result = getEnv("GLEAM_BIN")
  if result.len == 0 and fileExists(root / "reference" / "bin" / "gleam"):
    result = root / "reference" / "bin" / "gleam"
  if result.len == 0: result = findExe("gleam")
  if result.len == 0 or not fileExists(result):
    quit "ERROR no reference gleam (set GLEAM_BIN, or run reference/fetch.sh binary)", 2

proc writeStubs() =
  createDir stubDir
  for (name, text) in {"escript": escriptStub, "erl": refuseStub, "erlc": refuseStub,
      "rebar3": refuseStub, "mix": refuseStub, "elixir": refuseStub}:
    writeFile stubDir / name, text
    setFilePermissions stubDir / name, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
      fpGroupExec, fpOthersRead, fpOthersExec}

proc jobs(words: seq[string]): seq[Job] =
  for s in parseFile(lockPath)["sources"]:
    let repo = s["repo"].getStr
    if s["kind"].getStr in skipKinds: continue
    if words.len > 0 and not words.anyIt(it in repo): continue
    for p in s["packages"]:
      let path = p["path"].getStr
      let dir = (cacheDir / slug(repo) / path).normalizedPath
      if p["name"].getStr.len == 0 or not dirExists(dir / "src"): continue
      result.add Job(repo: repo, slug: slug(repo), path: path, name: p["name"].getStr, dir: dir,
        gold: goldenDir / slug(repo) / (if path == ".": "_root" else: path))

# ---- the script one package runs: everything a worker does is in one shell command ----

proc script(job: Job, gleam: string): string =
  ## Builds the package three ways and copies the outputs to the golden folder. Each step
  ## leaves its exit code in a file, so a failure of one target does not hide the others.
  let
    g = job.gold.quoteShell
    name = job.name
    bin = gleam.quoteShell
    limit = &"timeout {timeoutSeconds}"
  result = &"""
set -u
export PATH={stubDir.quoteShell}:"$PATH"
cd {job.dir.quoteShell} || exit 1
had_manifest=no; [ -f manifest.toml ] && had_manifest=yes
rm -rf {g} build/dev build/prod
mkdir -p {g}
echo $had_manifest > {g}/had_manifest

{limit} {bin} build --target erlang > {g}/erlang.raw 2>&1; echo $? > {g}/erlang.code
if [ -d build/dev/erlang/{name}/_gleam_artefacts ]; then
  mkdir -p {g}/abstr
  (cd build/dev/erlang/{name}/_gleam_artefacts && find . -name '*.abstr' -exec cp --parents {{}} {g}/abstr \;)
fi
if [ "$(cat {g}/erlang.code)" = 0 ]; then
  mkdir -p {g}/erlang
  {limit} {bin} compile-package --target erlang --no-beam --package . --out {g}/erlang/out \
    --lib build/dev/erlang > {g}/erlang/stdout 2> {g}/erlang/stderr; echo $? > {g}/erlang/code
  {limit} {bin} export package-interface --out {g}/interface.json > /dev/null 2>&1
fi

{limit} {bin} build --target javascript > {g}/javascript.raw 2>&1; echo $? > {g}/javascript.code
if [ "$(cat {g}/javascript.code)" = 0 ]; then
  mkdir -p {g}/javascript
  {limit} {bin} compile-package --target javascript --javascript-prelude ../prelude.mjs --package . \
    --out {g}/javascript/out --lib build/dev/javascript > {g}/javascript/stdout 2> {g}/javascript/stderr
  echo $? > {g}/javascript/code
fi
find {g} \( -name '*.cache' -o -name '*.cache_meta' -o -name '*.cache_inline' -o -name '*.cache_warnings' \) -delete

dirs=""; for d in src test dev; do [ -d $d ] && dirs="$dirs $d"; done
{limit} {bin} format --check $dirs > {g}/format.raw 2>&1; echo $? > {g}/format.code
[ -f manifest.toml ] && cp manifest.toml {g}/manifest.toml
exit 0
"""

# ---- reading what a package left ----

proc normalise(text, dir: string): string =
  ## Build output without what changes from run to run: the folder the package happens to be
  ## in, timings, and the progress lines about downloads and dependencies.
  for raw in text.replace(dir & "/", "").replace(dir, ".").splitLines:
    let line = raw.strip(leading = false)
    let t = line.strip
    if t.startsWith("Compiled in") or t.startsWith("Downloading packages") or
        t.startsWith("Downloaded ") or t.startsWith("Resolving versions") or
        t.startsWith("Compiling ") or t.startsWith("Added ") or t.startsWith("Checked in"): continue
    result.add line & "\n"
  result = result.strip & "\n"

proc treeHash(dir: string): tuple[files: int, bytes: int, sha: string] =
  ## A sha256 over the sorted list of `sha256  path` lines of every file in a folder.
  if not dirExists(dir): return (0, 0, "")
  var paths: seq[string]
  for path in walkDirRec(dir, relative = true): paths.add path
  if paths.len == 0: return (0, 0, "")
  paths.sort
  for path in paths: result.bytes += getFileSize(dir / path).int
  result.files = paths.len
  let listing = execCmdEx("find . -type f | LC_ALL=C sort | xargs -d '\\n' sha256sum | sha256sum",
    workingDir = dir).output
  result.sha = listing.splitWhitespace[0]

proc firstError(text: string): string =
  ## The headline of the first error, and the line after it when that says more.
  let ls = text.splitLines
  for i, line in ls:
    if line.startsWith("error:"):
      result = line["error:".len .. ^1].strip
      for j in i + 1 ..< min(i + 12, ls.len):
        let t = ls[j].strip
        if t.len > 0 and t[0] notin {'|', '+', '-'} and not t.startsWith("┌") and
            not t.startsWith("│") and t[0] notin Digits:
          return result & ": " & t[0 ..< min(t.len, 120)]
      return

proc count(text, prefix: string): int = text.splitLines.countIt(it.startsWith(prefix))

proc code(gold, name: string): int =
  let path = gold / name & ".code"
  if fileExists(path): parseInt(readFile(path).strip) else: -1

proc status(exitCode: int): string =
  case exitCode
  of 0: "ok"
  of 124: "timeout"
  of -1: "not run"
  else: "failed"

proc collect(job: Job): JsonNode =
  ## Turns the raw files a package left into the tidy goldens and its row of golden.json.
  var texts: Table[string, string]
  for name in ["erlang", "javascript", "format"]:
    let raw = job.gold / name & ".raw"
    texts[name] = if fileExists(raw): normalise(readFile(raw), job.dir) else: ""
    if fileExists(raw): removeFile raw
  writeFile job.gold / "build-erlang.txt", texts["erlang"]
  writeFile job.gold / "build-javascript.txt", texts["javascript"]
  writeFile job.gold / "format.txt", texts["format"]
  let
    erlangCode = code(job.gold, "erlang")
    jsCode = code(job.gold, "javascript")
    formatCode = code(job.gold, "format")
    hadManifest = readFile(job.gold / "had_manifest").strip == "yes"
  for name in ["erlang", "javascript", "format"]: removeFile job.gold / name & ".code"
  removeFile job.gold / "had_manifest"
  result = %*{"name": job.name, "path": job.path, "manifest_committed": hadManifest}
  if fileExists(job.gold / "manifest.toml"):
    result["manifest_sha256"] = %execCmdEx("sha256sum manifest.toml", workingDir = job.gold).output.splitWhitespace[0]

  proc tree(dir: string): JsonNode =
    let t = treeHash(dir)
    %*{"files": t.files, "bytes": t.bytes, "sha256": t.sha}

  proc compiled(target: string): JsonNode =
    ## The `compile-package` run of a target: the folder difftest compares a candidate with.
    let dir = job.gold / target
    if not dirExists(dir): return %*{"status": "not run"}
    let c = if fileExists(dir / "code"): parseInt(readFile(dir / "code").strip) else: -1
    result = %*{"status": status(c)}
    if c != 0: result["error"] = %firstError(readFile(dir / "stderr"))
    for key, val in tree(dir): result[key] = val

  for (target, buildCode) in [("erlang", erlangCode), ("javascript", jsCode)]:
    var t = %*{"build": status(buildCode), "warnings": count(texts[target], "warning:")}
    if buildCode != 0: t["error"] = %firstError(texts[target])
    t["compile_package"] = compiled(target)
    if target == "erlang": t["abstr"] = tree(job.gold / "abstr")
    result[target] = t
  if fileExists(job.gold / "interface.json"):
    result["interface"] = %*{"bytes": getFileSize(job.gold / "interface.json").int,
      "sha256": execCmdEx("sha256sum interface.json", workingDir = job.gold).output.splitWhitespace[0]}
  result["format"] = %*{"status": (if formatCode == 0: "formatted" elif formatCode == 1: "would change" else: status(formatCode)),
    "files_to_change": texts["format"].splitLines.countIt(it.strip.endsWith(".gleam"))}

# ---- commands ----

proc run(words: seq[string], nJobs: int, keep: bool) =
  let gleam = referenceBin()
  let version = execCmdEx(gleam.quoteShell & " --version").output.strip
  writeStubs()
  let all = jobs(words)
  if all.len == 0: quit "ERROR no package to build (fetch the corpus first: nim r tools/corpus.nim fetch)", 2
  var todo: seq[Job]
  for job in all:
    if keep and fileExists(job.gold / "build-erlang.txt"): continue
    todo.add job
  let started = epochTime()
  echo &"golden: {todo.len} packages to build with {version}, {nJobs} at a time"
  var commands: seq[string]
  for job in todo:
    createDir job.gold.parentDir
    let file = stubDir / ("job_" & job.slug & "_" & job.path.replace("/", "_") & ".sh")
    writeFile file, script(job, gleam)
    commands.add "sh " & file.quoteShell
  # Packages of one repository can share a build folder through path dependencies, so the
  # jobs of a repository run one after the other; different repositories run side by side.
  var byRepo: OrderedTable[string, seq[string]]
  for i, job in todo: byRepo.mgetOrPut(job.slug, @[]).add commands[i]
  var chains: seq[string]
  for repo, cmds in byRepo: chains.add cmds.join(" ; ")
  discard execProcesses(chains, {poEvalCommand}, n = nJobs)

  # Merge with what golden.json already has, so a partial run updates only its packages.
  var doc = if fileExists(goldenPath): parseFile(goldenPath) else: %*{"sources": {}}
  var rows = doc["sources"]
  for job in todo:
    let row = collect(job)
    if not rows.hasKey(job.repo): rows[job.repo] = newJArray()
    var kept = newJArray()
    for old in rows[job.repo]:
      if old["path"].getStr != job.path: kept.add old
    kept.add row
    rows[job.repo] = kept
    for target in ["erlang", "javascript"]:
      let st = row[target]["build"].getStr
      if st != "ok":
        let why = row[target]{"error"}.getStr
        echo &"ERROR {target} {job.repo} {job.path}: {st}: {why}"
  # Stable order: sources as in corpus.json, packages by path.
  var ordered = newJObject()
  for s in parseFile(lockPath)["sources"]:
    let repo = s["repo"].getStr
    if rows.hasKey(repo):
      var ps = rows[repo].getElems
      ps.sort(proc(a, b: JsonNode): int = cmp(a["path"].getStr, b["path"].getStr))
      ordered[repo] = %ps
  let golden = %*{
    "about": "Generated by tools/golden.nim: what the reference compiler made of each corpus package. Do not edit by hand.",
    "reference": version,
    "generated": now().utc.format("yyyy-MM-dd"),
    "sources": ordered}
  writeFile goldenPath, golden.pretty & "\n"
  echo &"golden: {todo.len} packages in {epochTime() - started:.0f}s, wrote corpus/golden.json"

proc summary() =
  let doc = parseFile(goldenPath)
  var n, erlOk, jsOk, bothOk, textOk, iface = 0
  for repo, packages in doc["sources"]:
    for p in packages:
      inc n
      let e = p["erlang"]["build"].getStr == "ok"
      let j = p["javascript"]["build"].getStr == "ok"
      if e: inc erlOk
      if j: inc jsOk
      if e and j: inc bothOk
      if p["erlang"]["compile_package"]["status"].getStr == "ok": inc textOk
      if p.hasKey("interface"): inc iface
  let version = doc["reference"].getStr
  echo &"golden: {n} packages with {version}: erlang ok {erlOk} (text {textOk}, interface {iface}), javascript ok {jsOk}, both {bothOk}"

proc list(words: seq[string]) =
  ## One JSON object per line, per package and target that has goldens: what a differential
  ## tool needs to run a candidate on the same input and compare with the reference outputs.
  for job in jobs(words):
    for (target, extra) in {"erlang": @["--no-beam"], "javascript": @["--javascript-prelude", "../prelude.mjs"]}:
      if not fileExists(job.gold / target / "code"): continue
      echo $(%*{"id": job.slug & "__" & (if job.path == ".": job.name else: job.path.replace("/", "_")),
        "target": target, "package": job.dir, "lib": job.dir / "build" / "dev" / target,
        "expected": job.gold / target, "args": extra})

when isMainModule:
  var words: seq[string]
  var nJobs = countProcessors()
  var keep = false
  let args = commandLineParams()
  for a in args[min(1, args.len) .. ^1]:
    if a.startsWith("--jobs:"): nJobs = parseInt(a["--jobs:".len .. ^1])
    elif a == "--keep": keep = true
    else: words.add a
  case (if args.len > 0: args[0] else: "")
  of "run": run(words, max(1, nJobs), keep)
  of "summary": summary()
  of "list": list(words)
  else: echo "usage: nim r tools/golden.nim run [words] [--jobs:N] [--keep] | summary | list [words]"
