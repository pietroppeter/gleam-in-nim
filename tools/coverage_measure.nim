## Measures the coverage map against the pinned reference source.
##
## For every component in docs/data/coverage.json this recounts the upstream
## Rust lines (source and tests apart) and the snapshot files under the
## component's `upstream` paths, and the Nim lines under its `nim_modules`.
## Run it from the repository root after `reference/fetch.sh source`:
##
##   nim r tools/coverage_measure.nim          # rewrite the numbers in place
##   nim r tools/coverage_measure.nim --check  # fail if the file is out of date
import std/[json, os, strutils, sequtils]

const
  coveragePath = "docs/data/coverage.json"
  referenceRoot = "reference/gleam"

proc isTestFile(path: string): bool =
  ## Upstream keeps tests in `tests.rs`, `tests/` folders and `*_tests.rs`.
  let name = path.extractFilename
  "/tests/" in path or name == "tests.rs" or name.endsWith("_tests.rs") or
    name.endsWith("_test.rs")

proc countLines(path: string): int =
  for _ in lines(path): inc result

proc filesUnder(path: string): seq[string] =
  if dirExists(path): toSeq(walkDirRec(path))
  elif fileExists(path): @[path]
  else: quit("coverage_measure: missing path " & path)

proc measure(component: JsonNode) =
  var source, tests, snapshots = 0
  for upstream in component["upstream"]:
    for file in filesUnder(referenceRoot / upstream.getStr):
      if file.endsWith(".snap"): inc snapshots
      elif file.endsWith(".rs"):
        if file.isTestFile: tests += countLines(file)
        else: source += countLines(file)
  var nimLines = 0
  for module in component["nim_modules"]:
    for file in filesUnder(module.getStr):
      if file.endsWith(".nim"): nimLines += countLines(file)
  component["rust_loc"] = %source
  component["rust_test_loc"] = %tests
  component["snapshots"] = %snapshots
  component["nim_loc"] = %nimLines

when isMainModule:
  if not dirExists(referenceRoot):
    quit("coverage_measure: run reference/fetch.sh source first")
  let original = readFile(coveragePath)
  let coverage = parseJson(original)
  for component in coverage["components"]: measure(component)
  let updated = coverage.pretty & "\n"
  if "--check" in commandLineParams():
    if updated != original: quit("coverage_measure: " & coveragePath & " is out of date")
    echo "coverage map is up to date"
  else:
    writeFile(coveragePath, updated)
    var source, tests = 0
    for component in coverage["components"]:
      source += component["rust_loc"].getInt
      tests += component["rust_test_loc"].getInt
    echo "measured ", coverage["components"].len, " components: ", source,
      " lines of Rust source, ", tests, " lines of Rust tests"
