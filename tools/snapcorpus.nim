## Indexes the snapshot tests of the reference compiler into docs/data/snapshots.json.
##
##   nim r tools/snapcorpus.nim                         write the index, print a summary
##   nim r tools/snapcorpus.nim list compiler-core/src/erlang      the snapshots under a folder
##   nim r tools/snapcorpus.nim show <path.snap>        one snapshot, section by section
##   options: --ref:PATH (default reference/gleam or $GLEAM_REF)
import std/[os, strutils, json, tables, algorithm, parseopt]
import common, snapshots

type Row = object
  source: string        # the Rust test file
  crate, area: string
  snaps, withSource: int
  kinds: CountTable[string]

proc areaOf(source: string): tuple[crate, area: string] =
  ## `compiler-core/src/javascript/tests/assert.rs` is crate `compiler-core`, area `javascript`.
  let parts = source.unixPath.split('/')
  result.crate = parts[0]
  if parts.len > 2 and parts[1] == "src":
    result.area = parts[2].changeFileExt("")
  else:
    result.area = "(root)"

proc index(refDir: string) =
  var rows: OrderedTable[string, Row]
  var kinds: CountTable[string]
  var total, withSource: int
  for snap in snaps(refDir):
    inc total
    let key = snap.source.unixPath
    if key notin rows:
      let (crate, area) = areaOf(key)
      rows[key] = Row(source: key, crate: crate, area: area)
    inc rows[key].snaps
    if snap.has("SOURCE CODE"):
      inc withSource
      inc rows[key].withSource
    for sec in snap.sections:
      let title = if sec.title.len == 0: "(plain)" else: sec.title
      rows[key].kinds.inc title
      kinds.inc title
  var byArea: OrderedTable[string, tuple[snaps, withSource: int]]
  var list: seq[Row]
  for row in rows.values: list.add row
  list.sort(proc (a, b: Row): int = cmp(a.source, b.source))
  for row in list:
    let key = row.crate & ": " & row.area
    var entry = byArea.getOrDefault(key)
    entry.snaps += row.snaps
    entry.withSource += row.withSource
    byArea[key] = entry
  var j = %*{"pin": pinOf(refDir), "total": total, "with_source": withSource,
             "sections": newJObject(), "areas": newJArray(), "files": newJArray()}
  kinds.sort
  for title, n in kinds: j["sections"][title] = %n
  for key, entry in byArea:
    let parts = key.split(": ")
    j["areas"].add %*{"crate": parts[0], "area": parts[1], "snaps": entry.snaps,
                       "with_source": entry.withSource}
  for row in list:
    var ks = newJObject()
    var k = row.kinds
    k.sort
    for title, n in k: ks[title] = %n
    j["files"].add %*{"source": row.source, "crate": row.crate, "area": row.area,
                       "snaps": row.snaps, "with_source": row.withSource, "sections": ks}
  createDir dataDir
  writeFile dataDir / "snapshots.json", j.pretty & "\n"
  echo "snapshots: ", total, " at gleam ", pinOf(refDir), ", ", withSource, " embed their Gleam source, from ",
    list.len, " Rust test files"
  for key, entry in byArea:
    if entry.snaps >= 30: echo "  ", key.alignLeft(34), align($entry.snaps, 5), " (", entry.withSource, " with source)"
  echo "wrote docs/data/snapshots.json"

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
  if args.len == 0:
    index refDir
  elif args[0] == "list":
    let under = if args.len > 1: args[1] else: ""
    var n = 0
    for snap in snaps(refDir, under):
      inc n
      var titles: seq[string]
      for sec in snap.sections: titles.add(if sec.title.len == 0: "(plain)" else: sec.title)
      echo snap.path, "\t", titles.join(", ")
    echo n, " snapshots under ", (if under.len > 0: under else: ".")
  elif args[0] == "show" and args.len > 1:
    let snap = loadSnap(refDir, args[1])
    echo "source: ", snap.source, "\nname: ", snap.name
    for sec in snap.sections:
      echo "=== ", (if sec.title.len == 0: "(plain)" else: sec.title), " ==="
      echo sec.text
  else:
    quit "ERROR usage: snapcorpus [list [folder] | show <path.snap>] [--ref:PATH]", 2

main()
