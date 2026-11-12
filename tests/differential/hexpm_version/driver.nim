## The Nim half of the differential test of Hex versions and ranges: answers the cases of
## cases.py the way the Rust driver (src/main.rs) does, so the two can be compared line by
## line. `tests/test_hexpm_version.nim` uses `answer` on the committed cases; run.sh fuzz
## runs this file on fresh ones:  driver CASES EXPECTED
import std/[options, os, sequtils, strutils]
import ../../../src/gleam_in_nim/hexpm/version

proc unhex(text: string): string = parseHexStr(text)

proc answer*(line: string): string =
  ## One case (kind, name, inputs in hex, separated by tabs) to the line the oracle prints.
  let f = line.split('\t')
  case f[0]
  of "V":
    let r = Version.parse(unhex(f[2]))
    if r.isOk:
      let v = r.value
      let pre = v.pre.mapIt((if it.kind == ikNumeric: "N:" else: "A:") & $it).join(",")
      ["ok", $v.major, $v.minor, $v.patch, pre, (if v.build.isSome: "+" & v.build.get else: "-"), $v].join("\t")
    else: "err\t" & $r.error
  of "R":
    let r = Range.new(unhex(f[2]))
    if r.isOk: "ok\t" & $r.value.toPubgrub
    else: "err\t" & $r.error
  of "C":
    let a = Version.parse(unhex(f[2]))
    let b = Version.parse(unhex(f[3]))
    if a.isOk and b.isOk:
      let c = cmp(a.value, b.value)
      (if c < 0: "Less" elif c > 0: "Greater" else: "Equal") & "\t" & $(a.value == b.value)
    else: "invalid"
  of "T":
    let r = Range.new(unhex(f[2]))
    let v = Version.parse(unhex(f[3]))
    if r.isOk and v.isOk: $r.value.toPubgrub.contains(v.value)
    else: "invalid"
  else: raiseAssert "unknown case"

proc compare*(casesFile, expectedFile: string): tuple[cases, different: int, first: string] =
  ## How many cases there are, how many the port answers differently, and the first of those.
  let cases = readFile(casesFile).splitLines
  let expected = readFile(expectedFile).splitLines
  for i, line in cases:
    if line.len == 0: continue
    inc result.cases
    let got = answer(line)
    if got != expected[i]:
      inc result.different
      if result.first.len == 0:
        let f = line.split('\t')
        result.first = f[1] & " " & f[2 .. ^1].mapIt(escape(unhex(it))).join(" ") &
          "\n  rust: " & expected[i] & "\n  nim:  " & got

when isMainModule:
  let r = compare(paramStr(1), paramStr(2))
  if r.different == 0:
    echo "hexpm version: ", r.cases, " cases, identical"
  else:
    echo "ERROR hexpm version: ", r.different, " of ", r.cases, " cases differ; the first is ", r.first
    quit 1
