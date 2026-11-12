## Seeds (and refreshes) the coverage map's data, docs/data/coverage.json, from a checkout of
## the Gleam compiler at the pinned commit:
##
##   nim r tools/coverage_seed.nim path/to/gleam
##
## One row per top-level module of every crate (`compiler-core/src/parse.rs` and
## `compiler-core/src/parse/` are the module `compiler-core/parse`), with its lines of Rust,
## split in code and tests (files named `tests.rs` or under a `tests/` folder). What people
## write (status, nim, post, notes, stage) is kept from the existing file: only the counts and
## new modules change. The stage of a new module is guessed from its name; fix it by hand.
import std/[os, json, strutils, tables, algorithm, osproc]

const stages = [   # id, name, what it is, and the modules that belong to it by default
  ("lex", "Lexer", "source text to tokens", @["compiler-core/parse/lexer", "compiler-core/parse/token"]),
  ("parse", "Parser", "tokens to the untyped tree", @["compiler-core/parse", "compiler-core/ast", "compiler-core/ast_folder", "compiler-core/bit_array", "src-span"]),
  ("format", "Formatter", "the tree back to source text", @["format", "pretty-arena"]),
  ("analyse", "Type checker", "the untyped tree to the typed tree", @["compiler-core/analyse", "compiler-core/type_", "compiler-core/exhaustiveness", "compiler-core/call_graph", "compiler-core/reference", "compiler-core/uid", "compiler-core/dep_tree"]),
  ("errors", "Diagnostics", "errors and warnings, as text a person can act on", @["compiler-core/error", "compiler-core/warning", "compiler-core/diagnostic", "compiler-core/strings"]),
  ("erlang", "Erlang backend", "the typed tree to Erlang source", @["compiler-core/erlang", "erlang-generation", "erlang-term-format"]),
  ("javascript", "JavaScript backend", "the typed tree to JavaScript and TypeScript declarations", @["compiler-core/javascript"]),
  ("build", "Build tool", "packages, modules, caches, dependencies", @["compiler-core/build", "compiler-core/codegen", "compiler-core/config", "compiler-core/metadata", "compiler-core/manifest", "compiler-core/package_interface", "compiler-core/dependency", "compiler-core/derivation_tree", "compiler-core/requirement", "compiler-core/version", "compiler-core/paths", "compiler-core/io", "compiler-core/hex", "compiler-core/encryption", "compiler-core/docs", "hexpm"]),
  ("cli", "Command line", "gleam build, run, test, format, add...", @["compiler-cli", "gleam-bin", "compiler-wasm"]),
  ("lsp", "Language server", "the compiler as an editor service", @["language-server"]),
]

proc isTest(rel: string): bool =
  let parts = rel.replace('\\', '/').split('/')
  "tests" in parts or parts[^1] == "tests.rs" or parts[^1].endsWith("_tests.rs") or parts[^1] == "test.rs"

proc linesOf(file: string): int = strutils.countLines(readFile(file))

if paramCount() < 1: quit "usage: nim r tools/coverage_seed.nim path/to/gleam"
let gleam = paramStr(1).absolutePath
let root = currentSourcePath().parentDir.parentDir
let outFile = root / "docs" / "data" / "coverage.json"
let old = if fileExists(outFile): parseFile(outFile) else: %*{"modules": []}
var kept: Table[string, JsonNode]
for m in old{"modules"}.getElems: kept[m["module"].getStr] = m

var rows: OrderedTable[string, tuple[code, tests: int]]
for kind, crateDir in walkDir(gleam):
  let crate = crateDir.lastPathPart
  if kind != pcDir or not dirExists(crateDir / "src") or crate.startsWith("test-") or crate == "compiler-benches": continue
  let split = crate == "compiler-core"   # only the big crate is listed module by module
  for file in walkDirRec(crateDir / "src"):
    if not file.endsWith(".rs"): continue
    let rel = file.relativePath(crateDir / "src").replace('\\', '/')
    var module = crate
    if split:
      let top = rel.split('/')[0].replace(".rs", "")
      module = crate & "/" & top
      # the lexer lives inside parse/: listed apart, since it is the first step of the port
      if rel in ["parse/lexer.rs", "parse/token.rs"]: module = crate & "/" & rel.replace(".rs", "")
      if top in ["lib", "tests"]: module = crate & "/(lib)"
    let n = linesOf(file)
    var cur = rows.getOrDefault(module)
    if isTest(rel): cur.tests += n else: cur.code += n
    rows[module] = cur

proc stageOf(module: string): string =
  for (id, name, what, mods) in stages:
    if module in mods: return id
  "build"

var modules = newJArray()
var names: seq[string]
for k in rows.keys: names.add k
names.sort()
for module in names:
  let (code, tests) = rows[module]
  var row = %*{"module": module, "stage": stageOf(module), "rust_code": code, "rust_tests": tests,
               "status": "planned", "nim": "", "post": "", "notes": ""}
  if module in kept:
    for key in ["stage", "status", "nim", "post", "notes"]:
      if kept[module].hasKey(key): row[key] = kept[module][key]
  modules.add row

var stageList = newJArray()
for (id, name, what, mods) in stages:
  stageList.add %*{"id": id, "name": name, "what": what}
let (commit, _) = execCmdEx("git rev-parse HEAD", workingDir = gleam)
let (tag, _) = execCmdEx("git describe --tags --always", workingDir = gleam)
let result = %*{
  "pin": {"repo": "https://github.com/gleam-lang/gleam", "tag": tag.strip, "commit": commit.strip},
  "stages": stageList,
  "modules": modules,
}
writeFile(outFile, result.pretty & "\n")
echo "wrote ", outFile.relativePath(root), ": ", modules.len, " modules"
