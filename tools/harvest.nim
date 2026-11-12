## Harvests test cases from the Rust test sources of the reference compiler.
##
## Not every upstream test is a snapshot: the formatter has `assert_format!("...")`, inference has
## `assert_infer!("1", "Int")`, and so on, with the Gleam source and the expected result written
## as string literals in the Rust file. This tool finds every `assert_*!(...)` macro call and
## returns its arguments, so a Nim test can replay the same cases without retyping them.
##
##   nim r tools/harvest.nim                       summary into docs/data/harvest.json
##   nim r tools/harvest.nim cases format/src      the cases under a folder, as JSON on stdout
##   options: --ref:PATH, --macro:NAME (only this macro)
##
## As a library: `for c in harvestFile(refDir, "compiler-core/src/format/tests.rs")`.
import std/[os, strutils, json, tables, algorithm, parseopt, unicode]
import common

type
  ArgKind* = enum akString, akCode
  Arg* = object
    kind*: ArgKind
    text*: string       ## the decoded string literal, or the Rust code as written
  Case* = object
    file*: string       ## Rust file, relative to the reference checkout
    line*: int          ## line of the macro call
    test*: string       ## the enclosing `fn`
    macroName*: string  ## `assert_format`, `assert_infer`, ...
    args*: seq[Arg]

proc decodeString(src: string, i: var int): string =
  ## Reads a Rust string literal whose opening quote is at `src[i]`; leaves `i` after it.
  inc i
  while i < src.len and src[i] != '"':
    if src[i] == '\\' and i + 1 < src.len:
      inc i
      case src[i]
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of '0': result.add '\0'
      of '\\': result.add '\\'
      of '"': result.add '"'
      of '\'': result.add '\''
      of 'x':
        result.add chr(parseHexInt(src[i + 1 .. i + 2]))
        i += 2
      of 'u':
        let close = src.find('}', i)
        result.add Rune(parseHexInt(src[i + 2 ..< close])).toUTF8
        i = close
      of '\n', '\r':
        # A backslash at the end of a line: skip the newline and the indentation after it.
        while i + 1 < src.len and src[i + 1] in {' ', '\t', '\n', '\r'}: inc i
      else: result.add src[i]
      inc i
    else:
      result.add src[i]
      inc i
  inc i

proc rawStringAt(src: string, i: int): int =
  ## The number of `#` of a raw string starting at `src[i]` (`r"`, `r#"`, `br"`), or -1.
  var j = i
  if j < src.len and src[j] == 'b': inc j
  if j >= src.len or src[j] != 'r': return -1
  inc j
  var hashes = 0
  while j < src.len and src[j] == '#':
    inc hashes
    inc j
  if j < src.len and src[j] == '"': hashes else: -1

proc decodeRaw(src: string, i: var int, hashes: int): string =
  i = src.find('"', i) + 1
  let close = '"' & repeat('#', hashes)
  let stop = src.find(close, i)
  result = src[i ..< stop]
  i = stop + close.len

proc skipTrivia(src: string, i: var int): bool =
  ## Skips a comment or a char literal at `i`; true when it skipped something.
  if src.continuesWith("//", i):
    while i < src.len and src[i] != '\n': inc i
    return true
  if src.continuesWith("/*", i):
    var depth = 0
    while i < src.len:
      if src.continuesWith("/*", i): (inc depth; i += 2)
      elif src.continuesWith("*/", i):
        dec depth
        i += 2
        if depth == 0: break
      else: inc i
    return true
  if src[i] == '\'':
    # 'x', '\n', '\u{1F600}' are char literals; 'a without a closing quote is a lifetime.
    if i + 2 < src.len and src[i + 1] == '\\':
      let close = src.find('\'', i + 2)
      if close > 0 and close - i <= 12:
        i = close + 1
        return true
    else:
      let width = if i + 1 < src.len: src.runeLenAt(i + 1) else: 1
      if i + 1 + width < src.len and src[i + 1 + width] == '\'':
        i = i + 2 + width
        return true
    inc i
    return true

proc isIdent(c: char): bool = c in IdentChars

proc harvestSource*(src: string, file = ""): seq[Case] =
  ## Every `assert_*!( ... )` call of a Rust source, with its arguments.
  var i = 0
  var line = 1
  var lastCounted = 0
  var currentFn = ""
  template countLines(upTo: int) =
    for k in lastCounted ..< min(upTo, src.len):
      if src[k] == '\n': inc line
    lastCounted = upTo
  while i < src.len:
    if skipTrivia(src, i): continue
    let c = src[i]
    if c == '"':
      discard decodeString(src, i)
      continue
    if c in {'r', 'b'} and (i == 0 or not isIdent(src[i - 1])):
      let hashes = rawStringAt(src, i)
      if hashes >= 0:
        discard decodeRaw(src, i, hashes)
        continue
      if c == 'b' and i + 1 < src.len and src[i + 1] == '"':
        inc i
        discard decodeString(src, i)
        continue
    if isIdent(c) and (i == 0 or not isIdent(src[i - 1])):
      var j = i
      while j < src.len and isIdent(src[j]): inc j
      let word = src[i ..< j]
      if word == "fn":
        var k = j
        while k < src.len and src[k] in Whitespace: inc k
        var e = k
        while e < src.len and isIdent(src[e]): inc e
        if e > k: currentFn = src[k ..< e]
        i = e
        continue
      if word.startsWith("assert_") and j + 1 < src.len and src[j] == '!' and src[j + 1] in {'(', '[', '{'}:
        countLines(i)
        var item = Case(file: file, line: line, test: currentFn, macroName: word)
        # Read the arguments: split at the commas that are not inside brackets.
        var k = j + 2
        var depth = 1
        var argStart = k
        var only: seq[Arg]      # the string literals met in the current argument
        var other = false       # the current argument has something else than one literal
        template closeArg(stop: int) =
          let raw = src[argStart ..< stop].strip
          if raw.len > 0:
            if only.len == 1 and not other: item.args.add only[0]
            else: item.args.add Arg(kind: akCode, text: raw)
          only = @[]
          other = false
        while k < src.len and depth > 0:
          if skipTrivia(src, k): continue
          let d = src[k]
          if d == '"':
            only.add Arg(kind: akString, text: decodeString(src, k))
            continue
          if d in {'r', 'b'} and not isIdent(src[k - 1]):
            let hashes = rawStringAt(src, k)
            if hashes >= 0:
              only.add Arg(kind: akString, text: decodeRaw(src, k, hashes))
              continue
          case d
          of '(', '[', '{': (inc depth; other = true)
          of ')', ']', '}':
            dec depth
            if depth == 0:
              closeArg(k)
              break
            other = true
          of ',':
            if depth == 1:
              closeArg(k)
              argStart = k + 1
            else: other = true
          of ' ', '\t', '\n', '\r': discard
          else: other = true
          inc k
        result.add item
        i = k + 1
        continue
      i = j
      continue
    inc i

proc harvestFile*(refDir, relPath: string): seq[Case] =
  harvestSource(readFile(refDir / relPath), relPath.unixPath)

proc rustFiles*(refDir: string, under = ""): seq[string] =
  for path in walkDirRec(refDir / under, relative = true):
    let parts = path.unixPath.split('/')
    if path.endsWith(".rs") and "target" notin parts:
      result.add(if under.len > 0: (under / path).unixPath else: path.unixPath)
  result.sort

proc toJson*(c: Case): JsonNode =
  result = %*{"file": c.file, "line": c.line, "test": c.test, "macro": c.macroName, "args": newJArray()}
  for a in c.args:
    result["args"].add(if a.kind == akString: %*{"string": a.text} else: %*{"code": a.text})

proc selfTest*() =
  let src = """
// assert_nope!("in a comment")
#[test]
fn first<'a>(x: &'a str) {
    let c = '"'; let d = '\n';
    assert_format!("pub fn main() {\n  1\n}\n");
    assert_infer!("[1, 2]", "List(Int)");
}
/* assert_nope!("x") */
#[test]
fn second() {
    assert_format_rewrite!(
        r#"let "a" = b"#,
        "let \"a\" =
            b",
    );
    assert_eq!(lex("a"), vec![Token::Name { name: "a".into() }]);
    assert_module_error!(("dep", "x"), "y");
}
"""
  let cases = harvestSource(src, "t.rs")
  doAssert cases.len == 5, $cases.len
  doAssert cases[0].macroName == "assert_format" and cases[0].test == "first" and cases[0].line == 5
  doAssert cases[0].args.len == 1 and cases[0].args[0].text == "pub fn main() {\n  1\n}\n"
  doAssert cases[1].args.len == 2 and cases[1].args[1].text == "List(Int)"
  doAssert cases[2].test == "second" and cases[2].args[0].text == "let \"a\" = b"
  doAssert cases[2].args[1].text == "let \"a\" =\n            b"
  doAssert cases[3].macroName == "assert_eq" and cases[3].args[0].kind == akCode
  doAssert cases[4].args[0].kind == akCode and cases[4].args[1].text == "y"
  echo "ok: harvest"

proc main() =
  var refArg, only: string
  var args: seq[string]
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "ref": refArg = val
      of "macro": only = val
      else: quit "ERROR unknown option --" & key, 2
    of cmdArgument: args.add key
    of cmdEnd: discard
  if args.len > 0 and args[0] == "selftest":
    selfTest()
    return
  let refDir = refDirFrom(refArg)
  if args.len > 0 and args[0] == "cases":
    var list = newJArray()
    for file in rustFiles(refDir, if args.len > 1: args[1] else: ""):
      for c in harvestFile(refDir, file):
        if only.len == 0 or c.macroName == only: list.add c.toJson
    echo list.pretty
    return
  var macros: CountTable[string]
  var literal: CountTable[string]   # calls whose arguments are all string literals: replayable as they are
  var files = newJArray()
  var total = 0
  for file in rustFiles(refDir):
    var perFile: CountTable[string]
    for c in harvestFile(refDir, file):
      inc total
      macros.inc c.macroName
      perFile.inc c.macroName
      var allStrings = c.args.len > 0
      for a in c.args:
        if a.kind != akString: allStrings = false
      if allStrings: literal.inc c.macroName
    if perFile.len > 0:
      perFile.sort
      var m = newJObject()
      for name, n in perFile: m[name] = %n
      files.add %*{"file": file, "macros": m}
  macros.sort
  var m = newJArray()
  for name, n in macros:
    m.add %*{"macro": name, "calls": n, "all_literal": literal.getOrDefault(name)}
  createDir dataDir
  writeFile dataDir / "harvest.json",
    (%*{"pin": pinOf(refDir), "total": total, "macros": m, "files": files}).pretty & "\n"
  echo "harvest: ", total, " assert_* macro calls at gleam ", pinOf(refDir), ", ", macros.len, " different macros"
  var shown = 0
  for name, n in macros:
    if shown < 12: echo "  ", name.alignLeft(36), align($n, 6), "  (", literal.getOrDefault(name), " with only string arguments)"
    inc shown
  echo "wrote docs/data/harvest.json"

when isMainModule: main()
