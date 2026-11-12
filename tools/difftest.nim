## Differential testing: the same input through the reference `gleam` and through a candidate,
## and the outputs compared byte for byte.
##
##   nim r tools/difftest.nim format     --candidate:CMD   `gleam format --stdin` on every source
##   nim r tools/difftest.nim erlang     --candidate:CMD   `gleam compile-package --target erlang --no-beam`
##   nim r tools/difftest.nim javascript --candidate:CMD   `gleam compile-package --target javascript`
##   nim r tools/difftest.nim selftest                     proves the harness: same, then different
##
##   --reference:CMD   the reference compiler (default: $GLEAM_BIN, or `gleam` on the PATH)
##   --candidate:CMD   the compiler under test; it must take the same command line as gleam
##   --corpus:DIR      also take inputs from a folder (.gleam files, or packages with src/)
##   --only:TEXT       only the cases whose id contains TEXT
##   --fast:N          a sample of N percent of the cases, the same every time for a given --seed
##   --seed:S          another sample (default 0)
##   --max-errors:N    print at most N ERROR lines (default 20); all are counted and logged
##   --record          add the result to docs/data/difftest.json, for the dashboard
##   --ref:PATH        the reference checkout the inputs come from
##
## The inputs are the Gleam sources embedded in the upstream snapshots, and for `format` the
## sources of the `assert_format!` tests too. No Erlang and no network are needed: both backends
## are run through the low-level `compile-package`, which writes text.
##
## Output is for an agent: one line per difference, starting with ERROR, the detail in
## build/difftest/<mode>/<case>/, and a last line with the totals. Exit code 1 on a difference.
import std/[os, osproc, strutils, json, hashes, parseopt, times, algorithm, tables, sets]
import common, snapshots, harvest

type
  Mode = enum mFormat = "format", mErlang = "erlang", mJavascript = "javascript"
  Input = object
    id: string          ## unique name of the case, also the name of its folder
    source: string      ## Gleam source
    origin: string      ## where it comes from (a .snap, a Rust file and line, a corpus file)
    package: string     ## for the backends: a package folder to copy instead of one source
  Options = object
    mode: Mode
    reference, candidate, corpus, only, refArg: string
    fast, seed, maxErrors: int
    record: bool

const ignoredOutputs = [".cache", ".cache_meta", ".cache_inline", ".cache_warnings"]
  ## Files of `_gleam_artefacts` that are private to an implementation: not compared.

proc safeId(text: string): string =
  for c in text:
    result.add(if c in Letters + Digits + {'_', '-', '.'}: c else: '_')
  if result.len > 120: result = result[0 ..< 100] & "_" & $(hash(text) and 0xffffff)

proc collect(opts: Options, refDir: string): seq[Input] =
  var seen: HashSet[string]
  template add(input: Input) =
    if input.id notin seen:
      seen.incl input.id
      result.add input
  let under = case opts.mode
    of mFormat: ""
    of mErlang: "compiler-core/src/erlang"
    of mJavascript: "compiler-core/src/javascript"
  if refDir.len > 0:
    for snap in snaps(refDir, under):
      if snap.has("SOURCE CODE"):
        add Input(id: safeId(snap.path.extractFilename.changeFileExt("")),
                  source: snap.section("SOURCE CODE") & "\n", origin: snap.path)
    if opts.mode == mFormat:
      for file in rustFiles(refDir, "format/src"):
        for c in harvestFile(refDir, file):
          if c.macroName.startsWith("assert_format") and c.args.len > 0 and c.args[0].kind == akString:
            add Input(id: safeId(file.changeFileExt("").replace("/src/", "_") & "_" & $c.line),
                      source: c.args[0].text, origin: file & ":" & $c.line)
  if opts.corpus.len > 0:
    if opts.mode == mFormat:
      for path in walkDirRec(opts.corpus, relative = true):
        if path.endsWith(".gleam") and "build" notin path.unixPath.split('/'):
          add Input(id: safeId("corpus_" & path), source: readFile(opts.corpus / path), origin: path)
    else:
      for kind, dir in walkDir(opts.corpus):
        if kind == pcDir and dirExists(dir / "src"):
          add Input(id: safeId("corpus_" & dir.extractFilename), package: dir, origin: dir)
  result.sort(proc (a, b: Input): int = cmp(a.id, b.id))

proc sampled(id: string, opts: Options): bool =
  if opts.only.len > 0 and opts.only notin id: return false
  if opts.fast <= 0 or opts.fast >= 100: return true
  (hash(id & "#" & $opts.seed) and 0x7fffffff) mod 100 < opts.fast

proc commandFor(mode: Mode, bin: string): string =
  ## The shell command a case runs in its own folder; it leaves `stdout`, `stderr`, `code`.
  let call = case mode
    of mFormat: bin.quoteShell & " format --stdin < ../input.gleam"
    of mErlang: bin.quoteShell & " compile-package --target erlang --no-beam --package pkg --out out --lib lib"
    of mJavascript: bin.quoteShell & " compile-package --target javascript --javascript-prelude prelude.mjs" &
      " --package pkg --out out --lib lib"
  call & " > stdout 2> stderr; echo $? > code"

proc prepare(mode: Mode, input: Input, caseDir: string) =
  removeDir caseDir
  for side in ["reference", "candidate"]:
    createDir caseDir / side
    if mode != mFormat:
      createDir caseDir / side / "lib"
      createDir caseDir / side / "out"
      if input.package.len > 0:
        copyDir input.package, caseDir / side / "pkg"
        removeDir caseDir / side / "pkg" / "build"
      else:
        createDir caseDir / side / "pkg" / "src" / "my"
        writeFile caseDir / side / "pkg" / "gleam.toml", "name = \"thepackage\"\nversion = \"1.0.0\"\n"
        writeFile caseDir / side / "pkg" / "src" / "my" / "mod.gleam", input.source
  if mode == mFormat: writeFile caseDir / "input.gleam", input.source

proc outputs(dir: string): OrderedTable[string, string] =
  ## What a run left: stdout, stderr, exit code, and every file it wrote (but the private caches).
  for name in ["code", "stdout", "stderr"]:
    result[name] = if fileExists(dir / name): readFile(dir / name) else: "(missing)"
  var files: seq[string]
  if dirExists(dir / "out"):
    for path in walkDirRec(dir / "out", relative = true):
      if path.splitFile.ext notin ignoredOutputs: files.add path.unixPath
  files.sort
  for path in files: result["out/" & path] = readFile(dir / "out" / path)

proc firstDifference(a, b: string): string =
  let la = a.splitLines
  let lb = b.splitLines
  for i in 0 ..< max(la.len, lb.len):
    let x = if i < la.len: la[i] else: "(end)"
    let y = if i < lb.len: lb[i] else: "(end)"
    if x != y:
      return "line " & $(i + 1) & ": reference `" & x.strip[0 ..< min(60, x.strip.len)] &
        "` candidate `" & y.strip[0 ..< min(60, y.strip.len)] & "`"
  "same lines, different bytes"

proc compare(caseDir: string): string =
  ## "" when the two runs agree, else one line saying where they first differ.
  let r = outputs(caseDir / "reference")
  let c = outputs(caseDir / "candidate")
  for name, text in r:
    if name notin c: return name & ": written by the reference only"
    if c[name] != text:
      if name == "code": return "exit code: reference " & text.strip & " candidate " & c[name].strip
      return name & " " & firstDifference(text, c[name])
  for name in c.keys:
    if name notin r: return name & ": written by the candidate only"

proc run(opts: Options): int =
  let started = epochTime()
  let refDir = if opts.refArg == "none": "" else: refDirFrom(opts.refArg)
  let work = repoDir / "build" / "difftest" / $opts.mode
  var inputs: seq[Input]
  let all = collect(opts, refDir)
  for input in all:
    if sampled(input.id, opts): inputs.add input
  if inputs.len == 0: quit "ERROR no cases (" & $all.len & " before --only and --fast)", 2
  var commands: seq[string]
  for input in inputs:
    let caseDir = work / input.id
    prepare(opts.mode, input, caseDir)
    writeFile caseDir / "origin", input.origin & "\n"
    for (side, bin) in [("reference", opts.reference), ("candidate", opts.candidate)]:
      commands.add "cd " & quoteShell(caseDir / side) & " && " & commandFor(opts.mode, bin)
  discard execProcesses(commands, {poEvalCommand}, n = max(1, countProcessors()))
  var same, different, crashed = 0
  var log: seq[string]
  for input in inputs:
    let verdict = compare(work / input.id)
    if verdict.len == 0:
      inc same
      removeDir work / input.id   # keep only what needs a look
    else:
      inc different
      if "candidate 101" in verdict or "candidate 134" in verdict or "candidate 139" in verdict: inc crashed
      let line = "ERROR " & $opts.mode & " " & input.id & ": " & verdict
      log.add line & "   (from " & input.origin & ")"
      if different <= opts.maxErrors: echo line
  if different > opts.maxErrors:
    echo "... and ", different - opts.maxErrors, " more, all in build/difftest/", opts.mode, "/errors.log"
  writeFile work / "errors.log", log.join("\n") & (if log.len > 0: "\n" else: "")
  let seconds = epochTime() - started
  if opts.record:
    let path = dataDir / "difftest.json"
    var j = if fileExists(path): parseFile(path) else: newJObject()
    j[$opts.mode] = %*{"cases": inputs.len, "of": all.len, "same": same, "different": different,
                        "pin": (if refDir.len > 0: pinOf(refDir) else: "")}
    writeFile path, j.pretty & "\n"
  echo "difftest ", opts.mode, ": ", inputs.len, " cases",
    (if inputs.len < all.len: " (of " & $all.len & ")" else: ""), ", ", same, " same, ", different,
    " different", (if crashed > 0: " (" & $crashed & " crashes)" else: ""), ", ",
    seconds.formatFloat(ffDecimal, 1), "s",
    (if different > 0: ". Look at build/difftest/" & $opts.mode & "/<case>/ and errors.log" else: "")
  if different > 0: 1 else: 0

proc selfTest(opts: Options): int =
  ## The harness against itself: the reference as candidate must agree everywhere, and a
  ## candidate that changes one keyword must be caught.
  var o = opts
  o.fast = 5
  o.maxErrors = 3
  o.candidate = o.reference
  let liar = repoDir / "build" / "difftest" / "liar.sh"
  createDir liar.parentDir
  writeFile liar, "#!/bin/sh\n# A candidate that is wrong on purpose: `pub fn` becomes `pub  fn`.\n" &
    quoteShell(opts.reference) & " \"$@\" | sed 's/^pub fn/pub  fn/'\n"
  setFilePermissions liar, {fpUserExec, fpUserRead, fpUserWrite}
  for mode in Mode:
    o.mode = mode
    if run(o) != 0: quit "ERROR selftest: the reference disagrees with itself in " & $mode, 1
  o.mode = mFormat
  o.candidate = liar
  if run(o) == 0: quit "ERROR selftest: a wrong candidate was not caught", 1
  echo "ok: difftest selftest (the reference agrees with itself; a wrong candidate is caught)"

proc main() =
  var opts = Options(maxErrors: 20, reference: getEnv("GLEAM_BIN", "gleam"))
  var modeArg: string
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "reference": opts.reference = val
      of "candidate": opts.candidate = val
      of "corpus": opts.corpus = val
      of "only": opts.only = val
      of "fast": opts.fast = parseInt(val)
      of "seed": opts.seed = parseInt(val)
      of "max-errors": opts.maxErrors = parseInt(val)
      of "record": opts.record = true
      of "ref": opts.refArg = val
      else: quit "ERROR unknown option --" & key, 2
    of cmdArgument: modeArg = key
    of cmdEnd: discard
  if findExe(opts.reference).len == 0 and not fileExists(opts.reference):
    quit "ERROR no reference compiler `" & opts.reference & "` (pass --reference:PATH or set GLEAM_BIN)", 2
  if fileExists(opts.reference): opts.reference = opts.reference.absolutePath
  if modeArg == "selftest": quit selfTest(opts)
  case modeArg
  of "format": opts.mode = mFormat
  of "erlang": opts.mode = mErlang
  of "javascript": opts.mode = mJavascript
  else: quit "ERROR usage: difftest format|erlang|javascript|selftest --candidate:CMD (see the top of tools/difftest.nim)", 2
  if opts.candidate.len == 0: quit "ERROR --candidate:CMD is required", 2
  if fileExists(opts.candidate): opts.candidate = opts.candidate.absolutePath
  quit run(opts)

main()
