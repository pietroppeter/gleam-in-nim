## The port map: every Rust file of the reference compiler, how big it is, how it is tested
## upstream, and which Nim file ports it. Written to docs/data/portmap.json.
##
##   nim r tools/portmap.nim            write the map, print the totals
##   nim r tools/portmap.nim todo       the Rust files nobody ported yet, smallest first
##   nim r tools/portmap.nim check      fail when a Nim file names a Rust file that does not exist
##   options: --ref:PATH
##
## A Nim file says what it ports in its first lines, and that is the only bookkeeping:
##
##   ## port-of: compiler-core/src/parse/lexer.rs
##   ## port-status: draft
##
## `port-of` may be repeated (a Nim file that ports two Rust files). The status is `draft`
## (translated), `verified` (read against the Rust by a second pass) or `conformant` (the
## upstream tests of that file pass on the Nim code). A Rust file ported by several Nim files
## takes the lowest of their statuses. Files that will not be ported are listed, with the
## reason, in docs/data/portmap_skip.txt (`path-prefix<TAB>reason`).
import std/[os, strutils, json, tables, algorithm, parseopt]
import common, snapshots, harvest

type
  Status = enum sTodo = "todo", sDraft = "draft", sVerified = "verified", sConformant = "conformant",
                sSkip = "skip"
  RustFile = object
    path, crate, component: string
    lines, code, fns, snaps, cases: int
    isTest: bool
    nim: seq[string]
    status: Status
    reason: string

proc measure(src: string): tuple[lines, code, fns: int] =
  var inBlock = false
  for raw in src.splitLines:
    inc result.lines
    let line = raw.strip
    if inBlock:
      if "*/" in line: inBlock = false
      continue
    if line.len == 0 or line.startsWith("//"): continue
    if line.startsWith("/*"):
      if "*/" notin line: inBlock = true
      continue
    inc result.code
    if line.startsWith("fn ") or " fn " in line: inc result.fns

proc isTestPath(path: string): bool =
  let parts = path.split('/')
  parts[0].startsWith("test-") or "tests" in parts or parts[^1] in ["tests.rs", "test.rs"] or
    parts[^1].endsWith("_tests.rs")

proc componentOf(path: string): string =
  ## `compiler-core/src/type_/expression.rs` is the component `type_`.
  let parts = path.split('/')
  if parts.len > 2 and parts[1] == "src": parts[2].changeFileExt("") else: "(root)"

proc nimHeaders(): Table[string, seq[tuple[nim: string, status: Status]]] =
  ## What the Nim files of this repository say they port.
  for folder in ["src", "tests"]:
    if not dirExists(repoDir / folder): continue
    for path in walkDirRec(repoDir / folder, relative = true):
      if not path.endsWith(".nim"): continue
      var origins: seq[string]
      var status = sDraft
      var n = 0
      for line in lines(repoDir / folder / path):
        inc n
        if n > 30: break
        let text = line.strip(chars = {'#', ' '})
        if text.startsWith("port-of:"):
          origins.add text[8 .. ^1].strip.split(' ')[0]
        elif text.startsWith("port-status:"):
          try: status = parseEnum[Status](text[12 .. ^1].strip.split(' ')[0])
          except ValueError: quit "ERROR " & folder / path & ": unknown port-status in `" & line & "`", 1
      for origin in origins:
        result.mgetOrPut(origin, @[]).add (nim: (folder / path).unixPath, status: status)

proc skips(): seq[tuple[prefix, reason: string]] =
  let path = dataDir / "portmap_skip.txt"
  if fileExists(path):
    for line in lines(path):
      if line.strip.len > 0 and not line.startsWith("#"):
        let parts = line.split('\t', maxsplit = 1)
        result.add (parts[0].strip, if parts.len > 1: parts[1].strip else: "")

proc build(refDir: string): tuple[files: seq[RustFile], unknown: seq[string]] =
  var snapCount, caseCount: CountTable[string]
  for snap in snaps(refDir): snapCount.inc snap.source.unixPath
  let headers = nimHeaders()
  let skipList = skips()
  var known: seq[string]
  for path in rustFiles(refDir):
    known.add path
    let src = readFile(refDir / path)
    let m = measure(src)
    var file = RustFile(path: path, crate: path.split('/')[0], component: componentOf(path),
                        lines: m.lines, code: m.code, fns: m.fns, isTest: isTestPath(path),
                        snaps: snapCount.getOrDefault(path), cases: harvestSource(src, path).len)
    for (prefix, reason) in skipList:
      if path.startsWith(prefix):
        file.status = sSkip
        file.reason = reason
    if path in headers:
      file.status = sConformant
      for (nim, status) in headers[path]:
        file.nim.add nim
        if status < file.status: file.status = status
    result.files.add file
  for origin in headers.keys:
    if origin notin known: result.unknown.add origin

proc main() =
  var refArg: string
  var args: seq[string]
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if key == "ref": refArg = val
      else: quit "ERROR unknown option --" & key, 2
    of cmdArgument: args.add key
    of cmdEnd: discard
  let refDir = refDirFrom(refArg)
  let (files, unknown) = build(refDir)
  for origin in unknown:
    echo "ERROR a Nim file has `port-of: ", origin, "` but the reference has no such file"
  if args.len > 0 and args[0] == "check":
    quit(if unknown.len > 0: 1 else: 0)
  if args.len > 0 and args[0] == "todo":
    var todo: seq[RustFile]
    for f in files:
      if f.status == sTodo and not f.isTest: todo.add f
    todo.sort(proc (a, b: RustFile): int = cmp(a.code, b.code))
    for f in todo: echo align($f.code, 6), "  ", f.path
    echo todo.len, " Rust files to port (tests not counted), smallest first"
    return
  var total: array[Status, tuple[files, code: int]]
  var tests: tuple[files, code: int]
  var crates: OrderedTable[string, array[Status, int]]
  var list = newJArray()
  for f in files:
    if f.isTest:
      inc tests.files
      tests.code += f.code
    else:
      inc total[f.status].files
      total[f.status].code += f.code
      if f.crate notin crates: crates[f.crate] = default(array[Status, int])
      crates[f.crate][f.status] += f.code
    var row = %*{"path": f.path, "crate": f.crate, "component": f.component, "lines": f.lines,
                 "code": f.code, "fns": f.fns, "test": f.isTest, "snaps": f.snaps, "cases": f.cases,
                 "status": $f.status, "nim": f.nim}
    if f.reason.len > 0: row["reason"] = %f.reason
    list.add row
  var totals = newJObject()
  var all = 0
  for s in Status:
    totals[$s] = %*{"files": total[s].files, "code": total[s].code}
    all += total[s].code
  var crateRows = newJArray()
  for name, by in crates:
    var row = %*{"crate": name}
    for s in Status: row[$s] = %by[s]
    crateRows.add row
  createDir dataDir
  writeFile dataDir / "portmap.json", (%*{"pin": pinOf(refDir), "code": all, "totals": totals,
    "tests": {"files": tests.files, "code": tests.code}, "crates": crateRows, "files": list}).pretty & "\n"
  let started = all - total[sTodo].code - total[sSkip].code
  echo "portmap: gleam ", pinOf(refDir), ", ", files.len, " Rust files, ", all, " lines of code to port and ",
    tests.code, " lines of tests"
  for s in Status:
    if total[s].files > 0:
      echo "  ", ($s).alignLeft(11), align($total[s].files, 4), " files", align($total[s].code, 8), " lines  ",
        formatFloat(100 * total[s].code / max(all, 1), ffDecimal, 1), "%"
  echo "  ported so far (draft or better): ", started, " lines"
  echo "wrote docs/data/portmap.json"
  if unknown.len > 0: quit 1

main()
