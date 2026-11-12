## corpus: pin, fetch and measure the real Gleam code we test gleam-in-nim against.
##
##   nim r tools/corpus.nim lock      pin sources that are not in corpus/corpus.json yet
##   nim r tools/corpus.nim update    re-pin every source to its current head (or `ref`)
##   nim r tools/corpus.nim fetch     check out every pinned commit into .corpus-cache/
##   nim r tools/corpus.nim fetch stdlib lustre    only sources whose repo contains a word
##   nim r tools/corpus.nim list      print the manifest as a table
##
## corpus/sources.json is the hand-edited list; corpus/corpus.json is generated from it.
## Nothing is vendored: the cache is git-ignored and every licence is recorded, not assumed.
import std/[algorithm, json, os, osproc, sequtils, strformat, strutils, tables, times]

const
  root = currentSourcePath().parentDir.parentDir
  sourcesPath = root / "corpus" / "sources.json"
  lockPath = root / "corpus" / "corpus.json"
  cacheDir = root / ".corpus-cache"
  skipDirs = ["build", "node_modules", ".git", "deps", "_build", "target"]
  ffiExts = [".erl", ".hrl", ".ex", ".mjs", ".js", ".ts", ".cjs"]

type
  Package = object
    name, version, path, target, gleam: string
    licences, deps, devDeps: seq[string]
    files, lines: Table[string, int] # per top-level dir: src, test, dev
    ffi: Table[string, int]          # per extension, anywhere in the package

proc run(cmd: string, dir = ""): tuple[output: string, ok: bool] =
  let (o, code) = execCmdEx(cmd, workingDir = dir)
  (o.strip, code == 0)

proc slug(repo: string): string = repo.replace("/", "__")

# ---- a tiny reader for the subset of TOML that gleam.toml files use ----

proc unquote(s: string): string = s.strip.strip(chars = {'"', '\''})

proc readGleamToml(path: string): Package =
  var section = ""
  for raw in lines(path):
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("["):
      section = line.strip(chars = {'[', ']', ' '})
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip.unquote
    let val = line[eq + 1 .. ^1].strip
    case section
    of "":
      case key
      of "name": result.name = val.unquote
      of "version": result.version = val.unquote
      of "target": result.target = val.unquote
      of "gleam": result.gleam = val.unquote
      of "licences":
        result.licences = val.strip(chars = {'[', ']', ' '}).split(',')
          .mapIt(it.unquote).filterIt(it.len > 0)
      else: discard
    of "dependencies": result.deps.add key
    of "dev-dependencies", "dev_dependencies": result.devDeps.add key
    else: discard
  if result.target.len == 0: result.target = "erlang"

# ---- licences ----

proc detectLicenceFile(dir: string): string =
  ## Recognise the common licence texts by their opening lines. Returns "" when
  ## there is no licence file and "other" when there is one we do not recognise.
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename.toUpperAscii
    if not (name.startsWith("LICENSE") or name.startsWith("LICENCE") or
        name.startsWith("COPYING")): continue
    let text = readFile(path)
    let head = text[0 ..< min(text.len, 1500)].toLowerAscii
    if "apache license" in head: return "Apache-2.0"
    if "mozilla public license" in head: return "MPL-2.0"
    if "gnu affero general public license" in head: return "AGPL-3.0"
    if "gnu lesser general public license" in head: return "LGPL-3.0"
    if "gnu general public license" in head: return "GPL-3.0"
    if "permission is hereby granted, free of charge" in head: return "MIT"
    if "redistribution and use in source and binary forms" in head: return "BSD"
    if "this is free and unencumbered software" in head: return "Unlicense"
    if "european union public licence" in head: return "EUPL-1.2"
    return "other"
  ""

# ---- measuring Gleam code ----

const featureNames = [
  "pipe", "case", "use", "external", "target", "bit_array", "let_assert",
  "assert", "echo", "todo", "panic", "opaque", "const", "deprecated", "internal"]

proc hasWord(line, word: string): bool =
  ## `word` appears in `line` delimited by non-identifier characters.
  var at = line.find(word)
  while at >= 0:
    let before = at == 0 or line[at - 1] notin IdentChars
    let after = at + word.len >= line.len or line[at + word.len] notin IdentChars
    if before and after: return true
    at = line.find(word, at + 1)

proc scanFeatures(path: string, counts: var CountTable[string]): int =
  ## Line based and approximate on purpose: it counts lines where a construct
  ## shows up, skipping comment lines. Good enough to rank features by how common
  ## they are; the real numbers will come from our own parser later.
  for raw in lines(path):
    inc result
    let line = raw.strip
    if line.len == 0 or line.startsWith("//"): continue
    if "|>" in line: counts.inc "pipe"
    if line.hasWord("case"): counts.inc "case"
    if line.startsWith("use ") or " <- " in line and line.hasWord("use"): counts.inc "use"
    if line.startsWith("@external"): counts.inc "external"
    if line.startsWith("@target"): counts.inc "target"
    if line.startsWith("@deprecated"): counts.inc "deprecated"
    if line.startsWith("@internal"): counts.inc "internal"
    if "<<" in line: counts.inc "bit_array"
    if "let assert" in line: counts.inc "let_assert"
    elif line.startsWith("assert "): counts.inc "assert"
    if line.hasWord("echo"): counts.inc "echo"
    if line.hasWord("todo"): counts.inc "todo"
    if line.hasWord("panic"): counts.inc "panic"
    if "opaque type" in line: counts.inc "opaque"
    if line.startsWith("const ") or line.startsWith("pub const "): counts.inc "const"

iterator walkCode(dir: string): string =
  ## Every file under dir, skipping build output and dependency folders.
  var stack = @[dir]
  while stack.len > 0:
    let d = stack.pop
    for kind, path in walkDir(d):
      case kind
      of pcDir:
        if path.extractFilename notin skipDirs: stack.add path
      of pcFile: yield path
      else: discard

proc measure(dir: string): JsonNode =
  var packages: seq[Package]
  var tomlDirs: seq[string]
  for path in walkCode(dir):
    if path.extractFilename == "gleam.toml": tomlDirs.add path.parentDir
  tomlDirs.sort
  var features = initCountTable[string]()
  var totalFiles, totalLines: int
  var ffiTotal = initCountTable[string]()
  for path in walkCode(dir):
    let ext = path.splitFile.ext
    if ext == ".gleam":
      inc totalFiles
      totalLines += scanFeatures(path, features)
    elif ext in ffiExts: ffiTotal.inc ext
  for pdir in tomlDirs:
    var p = readGleamToml(pdir / "gleam.toml")
    p.path = if pdir == dir: "." else: pdir.relativePath(dir)
    for sub in ["src", "test", "dev"]:
      if not dirExists(pdir / sub): continue
      var dummy = initCountTable[string]()
      for path in walkCode(pdir / sub):
        let ext = path.splitFile.ext
        if ext == ".gleam":
          p.files.mgetOrPut(sub, 0).inc
          p.lines.mgetOrPut(sub, 0) += scanFeatures(path, dummy)
        elif ext in ffiExts: p.ffi.mgetOrPut(ext, 0).inc
    packages.add p
  result = %*{"gleam_files": totalFiles, "gleam_lines": totalLines}
  var f = newJObject()
  for name in featureNames: f[name] = %features.getOrDefault(name)
  result["features"] = f
  var ffi = newJObject()
  for ext in ffiExts:
    if ffiTotal.getOrDefault(ext) > 0: ffi[ext] = %ffiTotal[ext]
  result["ffi_files"] = ffi
  var ps = newJArray()
  for p in packages:
    var j = %*{"name": p.name, "version": p.version, "path": p.path, "target": p.target}
    if p.gleam.len > 0: j["gleam"] = %p.gleam
    j["licences"] = %p.licences
    j["dependencies"] = %p.deps
    j["dev_dependencies"] = %p.devDeps
    var files = newJObject()
    var lines = newJObject()
    for sub in ["src", "test", "dev"]:
      if sub in p.files:
        files[sub] = %p.files[sub]
        lines[sub] = %p.lines[sub]
    j["gleam_files"] = files
    j["gleam_lines"] = lines
    var pf = newJObject()
    for ext in ffiExts:
      if ext in p.ffi: pf[ext] = %p.ffi[ext]
    j["ffi_files"] = pf
    ps.add j
  result["packages"] = ps

proc sizeClass(lines: int): string =
  if lines < 500: "tiny"
  elif lines < 2_000: "small"
  elif lines < 10_000: "medium"
  else: "large"

# ---- git ----

proc checkout(repo, commit, dir: string): bool =
  ## Shallow fetch of exactly one commit. Works for any commit GitHub still has.
  if dirExists(dir / ".git") and run("git rev-parse HEAD", dir).output == commit:
    return true
  removeDir dir
  createDir dir
  let url = "https://github.com/" & repo
  for cmd in ["git init -q", "git remote add origin " & url,
      "git fetch -q --depth 1 origin " & commit, "git checkout -q FETCH_HEAD"]:
    let r = run(cmd, dir)
    if not r.ok:
      echo "  failed: ", cmd, "\n  ", r.output
      return false
  true

proc resolve(repo, gitRef: string): string =
  ## The commit a branch, tag or HEAD points at right now.
  let url = "https://github.com/" & repo
  let wanted = if gitRef.len == 0: "HEAD" else: gitRef
  let r = run(&"git ls-remote {url} {wanted} refs/tags/{wanted}^{{}}")
  if not r.ok or r.output.len == 0: return ""
  # A peeled tag (the ^{} line) is the commit an annotated tag points to.
  let rows = r.output.splitLines
  for row in rows:
    if row.endsWith("^{}"): return row.splitWhitespace[0]
  rows[0].splitWhitespace[0]

proc hexDownloads(name: string): int =
  ## All-time downloads from hex.pm, or -1. Hex names are global, so an app called
  ## `arc` must not pick up the numbers of an unrelated Elixir package: we only
  ## accept a Hex package whose latest release was built with the Gleam build tool.
  let r = run(&"curl -sS -m 20 https://hex.pm/api/packages/{name}")
  if not r.ok: return -1
  try:
    let j = parseJson(r.output)
    let releases = j{"releases"}
    if releases.isNil or releases.kind != JArray or releases.len == 0: return -1
    let rel = run("curl -sS -m 20 " & releases[0]["url"].getStr)
    if not rel.ok: return -1
    let tools = parseJson(rel.output){"meta", "build_tools"}
    if tools.isNil or tools.kind != JArray: return -1
    if tools.anyIt(it.getStr == "gleam"): return j{"downloads", "all"}.getInt(-1)
  except CatchableError: discard
  -1

# ---- commands ----

proc loadLock(): OrderedTable[string, JsonNode] =
  if fileExists(lockPath):
    for s in parseFile(lockPath)["sources"]: result[s["repo"].getStr] = s

proc lock(repin: bool) =
  let sources = parseFile(sourcesPath)["sources"]
  let old = loadLock()
  var entries = newJArray()
  createDir cacheDir
  for s in sources:
    let repo = s["repo"].getStr
    let gitRef = s{"ref"}.getStr
    if repo in old and not repin:
      var kept = old[repo]
      kept["kind"] = s["kind"]
      if s.hasKey("note"): kept["note"] = s["note"]
      entries.add kept
      continue
    stdout.write repo, " ... "
    stdout.flushFile
    let commit = resolve(repo, gitRef)
    let dir = cacheDir / slug(repo)
    if commit.len == 0 or not checkout(repo, commit, dir):
      echo "SKIPPED (not reachable)"
      if repo in old: entries.add old[repo]
      continue
    var e = %*{"repo": repo, "url": "https://github.com/" & repo, "kind": s["kind"]}
    if gitRef.len > 0: e["ref"] = %gitRef
    e["commit"] = %commit
    e["commit_date"] = %run("git log -1 --format=%cI", dir).output
    if s.hasKey("note"): e["note"] = s["note"]
    let m = measure(dir)
    let fileLicence = detectLicenceFile(dir)
    var declared: seq[string]
    for p in m["packages"]:
      if p["path"].getStr == ".":
        declared = p["licences"].to(seq[string])
    e["licence_file"] = %fileLicence
    e["licence_declared"] = %declared
    e["licence"] = %(if fileLicence.len > 0 and fileLicence != "other": fileLicence
                     elif declared.len > 0: declared.join(" OR ")
                     elif fileLicence == "other": "other"
                     else: "none")
    e["size"] = %sizeClass(m["gleam_lines"].getInt)
    for key in ["gleam_files", "gleam_lines", "features", "ffi_files"]: e[key] = m[key]
    var hex = newJObject()
    for p in m["packages"]:
      if p["path"].getStr == "." and p["name"].getStr.len > 0:
        let d = hexDownloads(p["name"].getStr)
        if d >= 0: hex = %*{"package": p["name"], "downloads_all_time": d}
    if hex.len > 0: e["hex"] = hex
    e["packages"] = m["packages"]
    entries.add e
    echo commit[0 ..< 10], "  ", e["licence"].getStr, "  ", e["gleam_lines"].getInt, " lines"
  let doc = %*{
    "about": "Generated by tools/corpus.nim from corpus/sources.json. Do not edit by hand.",
    "generated": now().utc.format("yyyy-MM-dd"),
    "sources": entries}
  writeFile(lockPath, doc.pretty & "\n")
  echo "wrote ", lockPath.relativePath(root), " with ", entries.len, " sources"

proc fetch(words: seq[string]) =
  createDir cacheDir
  for repo, e in loadLock():
    if words.len > 0 and not words.anyIt(it in repo): continue
    let ok = checkout(repo, e["commit"].getStr, cacheDir / slug(repo))
    echo (if ok: "ok      " else: "FAILED  "), repo, " @ ", e["commit"].getStr[0 ..< 10]

proc list() =
  echo "kind       size    lines   licence      repo"
  for repo, e in loadLock():
    echo e["kind"].getStr.alignLeft(10), " ", e["size"].getStr.alignLeft(7), " ",
      ($e["gleam_lines"].getInt).align(6), "  ", e["licence"].getStr.alignLeft(12), " ", repo

when isMainModule:
  let args = commandLineParams()
  case (if args.len > 0: args[0] else: "")
  of "lock": lock(repin = false)
  of "update": lock(repin = true)
  of "fetch": fetch(args[1 .. ^1])
  of "list": list()
  else: echo "usage: nim r tools/corpus.nim lock | update | fetch [words] | list"
