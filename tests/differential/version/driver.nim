## The Nim half of the differential test of versions and ranges (see run.sh).
##
##   driver generate SEED COUNT   prints COUNT random cases, one per line
##   driver answer                reads cases, prints what the port says of each
##
## The cases are those of the Rust driver (src/main.rs), which answers them
## with upstream's code. Strings are in hexadecimal, `-` for the empty string.
import std/[os, random, strutils, algorithm, unicode]
import ../../../src/gleam_in_nim/hexpm/version

proc hex(text: string): string =
  if text.len == 0: return "-"
  for character in text: result.add toHex(ord(character), 2).toLowerAscii

proc hexOut(text: string): string =
  for character in text: result.add toHex(ord(character), 2).toLowerAscii

proc unhex(token: string): string =
  if token == "-": "" else: parseHexStr(token)

# ---------------------------------------------------------------- generate

const
  numbers = ["0", "0", "1", "1", "1", "2", "2", "3", "4", "10", "17", "4294967295"]
  oddNumbers = ["01", "00", "4294967296", "99999999999999999999", "", "x", "1a"]
  identifiers = ["rc1", "rc2", "alpha", "beta", "1", "2", "0", "10", "pre", "beta-1", "a-b-3", "6-g3318bd5", "dev", "RC", "4294967296"]
  oddIdentifiers = ["01", "", "-", "é", "and", "or", "a_b"]
  builds = ["sha.0702245", "1", "ignore", "001", "dev.1.r.t", "20130417140000.amd64", "0"]
  oddBuilds = ["a-b", "", ".", "+", "é"]
  operators = ["", "", "==", "!=", ">", ">=", "<", "<=", "~>", "~>"]
  noise = [" ", " ", "\t", "\n", "\r", ".", "-", "+", "0", "1", "9", "a", "n", "d", "o", "r", "z", "A",
           "~", ">", "<", "=", "!", "&", "|", "é", "∅", "*", ",", "\"", "'", "\\", "́", "​", "😀", "\0", "\x7F", "\u00AD", "\u0378", "\uFEFF", "\u2028", "\uE000", "Z"]

var tight = false
  ## A case in a small space (numbers up to 2, three identifiers, two builds),
  ## where versions meet often: equal ones, bounds that touch, the same
  ## version with another build.

proc number(rng: var Rand, clean: bool): string =
  if tight: $rng.rand(2)
  elif not clean and rng.rand(40) == 0: rng.sample(oddNumbers)
  else: rng.sample(numbers)

proc identifier(rng: var Rand, clean: bool): string =
  if tight: rng.sample(["1", "rc1", "2"])
  elif not clean and rng.rand(30) == 0: rng.sample(oddIdentifiers)
  else: rng.sample(identifiers)

proc randomVersion(rng: var Rand, clean: bool): string =
  result = rng.number(clean) & "." & rng.number(clean) & "." & rng.number(clean)
  if rng.rand(3) == 0:
    result.add "-"
    for i in 0 .. rng.rand(2):
      if i > 0: result.add "."
      result.add rng.identifier(clean)
  if rng.rand(5) == 0:
    result.add "+"
    result.add (if tight: rng.sample(["a", "b"])
                elif not clean and rng.rand(20) == 0: rng.sample(oddBuilds)
                else: rng.sample(builds))

proc spaces(rng: var Rand, clean: bool): string =
  case rng.rand(if clean: 3 else: 12)
  of 0 .. 3: " "
  of 4 .. 6: ""
  of 7: "  "
  of 8: "\t"
  of 9: " \n"
  else: " "

proc randomRange(rng: var Rand, clean: bool): string =
  for section in 0 .. (if rng.rand(2) == 0: rng.rand(2) else: 0):
    if section > 0: result.add rng.spaces(clean) & "or" & rng.spaces(clean)
    for constraint in 0 .. (if rng.rand(1) == 0: rng.rand(2) else: 0):
      if constraint > 0: result.add rng.spaces(clean) & "and" & rng.spaces(clean)
      let operator = rng.sample(operators)
      result.add operator
      if operator.len > 0: result.add rng.spaces(clean)
      if operator == "~>" and rng.rand(1) == 0:
        result.add rng.number(clean) & "." & rng.number(clean)
        if rng.rand(6) == 0: result.add "-" & rng.identifier(clean = true)
      else:
        result.add rng.randomVersion(clean)
  if not clean and rng.rand(10) == 0: result = rng.spaces(clean) & result
  if not clean and rng.rand(10) == 0: result.add rng.spaces(clean)

proc mutate(rng: var Rand, text: string): string =
  ## Sometimes, a character more, a character less or another character.
  var characters = text.toRunes
  for _ in 1 .. (if rng.rand(4) == 0: 1 + rng.rand(2) else: 0):
    let at = rng.rand(characters.len)
    case rng.rand(2)
    of 0: characters.insert(rng.sample(noise).toRunes[0], at)
    of 1:
      if at < characters.len: characters.delete(at)
    else:
      if at < characters.len:
        characters.delete(at)
        characters.insert(rng.sample(noise).toRunes[0], at)
  $characters

proc validVersion(rng: var Rand): string =
  while true:
    result = rng.randomVersion(clean = true)
    if parse(result).isOk: return

proc validRange(rng: var Rand): string =
  while true:
    result = rng.randomRange(clean = true)
    if newRange(result).isOk: return

proc randomBound(rng: var Rand): string =
  case rng.rand(4)
  of 0: "u"
  of 1, 2: "i" & hex(rng.validVersion())
  else: "e" & hex(rng.validVersion())

proc randomSegments(rng: var Rand): string =
  ## Any segments, in any order: empty ones, overlapping ones, touching ones.
  let count = rng.rand(4)
  result = $count
  for _ in 0 ..< count:
    result.add " " & rng.randomBound() & " " & rng.randomBound()

proc generate(seed: int64, count: int) =
  var rng = initRand(seed)
  for _ in 1 .. count:
    tight = rng.rand(1) == 0
    case rng.rand(11)
    of 0, 1: echo "V ", hex(rng.mutate(rng.randomVersion(clean = false)))
    of 2: echo "C ", hex(rng.validVersion()), " ", hex(rng.validVersion())
    of 3, 4, 5: echo "R ", hex(rng.mutate(rng.randomRange(clean = false)))
    of 6, 7: echo "O ", hex(rng.validRange()), " ", hex(rng.validRange()), " ", hex(rng.validVersion())
    of 10, 11:
      tight = rng.rand(4) != 0
      echo "B ", rng.randomSegments(), " ", rng.randomSegments(), " ", hex(rng.validVersion())
    of 8:
      var line = "S " & hex(rng.validRange())
      for _ in 0 .. rng.rand(6): line.add " " & hex(rng.validVersion())
      echo line
    else:
      var line = "I"
      for _ in 0 .. rng.rand(4): line.add " " & hex(rng.validRange())
      echo line

# ------------------------------------------------------------------ answer

proc fields(version: Version): string =
  var pre: seq[string]
  for identifier in version.pre:
    case identifier.kind
    of ikNumeric: pre.add "n" & $identifier.vNumeric
    of ikAlphaNumeric: pre.add "a" & identifier.vAlphaNumeric
  $version.major & " " & $version.minor & " " & $version.patch & " [" & pre.join(",") & "] " &
    (if version.build.isSome: "+" & version.build.get else: "-")

proc ordering(ordering: int): string =
  if ordering < 0: "less" elif ordering == 0: "equal" else: "greater"

proc version(token: string): Version =
  let parsed = parse(unhex(token))
  doAssert parsed.isOk, "not a version: " & unhex(token)
  parsed.value

proc range(token: string): PubgrubRange =
  let parsed = newRange(unhex(token))
  doAssert parsed.isOk, "not a range: " & unhex(token)
  parsed.value.toPubgrub

proc orNone(version: Option[Version]): string =
  if version.isSome: $version.get else: "none"

proc bound(token: string): Bound[Version] =
  case token[0]
  of 'u': unbounded[Version]()
  of 'i': included(version(token[1 .. ^1]))
  of 'e': excluded(version(token[1 .. ^1]))
  else: raiseAssert "unknown bound " & token

proc built(tokens: seq[string], position: var int): PubgrubRange =
  let count = parseInt(tokens[position])
  inc position
  var segments: seq[Interval[Version]]
  for _ in 0 ..< count:
    segments.add (bound(tokens[position]), bound(tokens[position + 1]))
    position += 2
  fromIntervals(segments)

proc operations(left, right: PubgrubRange, version: Version): string =
  "union:" & $left.union(right) & " | intersection:" & $left.intersection(right) &
    " | complement:" & $left.complement() & " | contains:" & $left.contains(version) &
    " | disjoint:" & $left.isDisjoint(right) & " | subset:" & $left.subsetOf(right) &
    " | equal:" & $(left == right) & " | " & ordering(cmp(left, right)) &
    " | singleton:" & orNone(left.asSingleton()) &
    " | empty:" & $left.intersection(right.complement()).isEmpty &
    " | double:" & $(left.complement().complement() == left)

proc answer(line: string): string =
  let tokens = line.split(' ')
  case tokens[0]
  of "V":
    let parsed = parse(unhex(tokens[1]))
    if parsed.isOk:
      "ok " & hexOut($parsed.value) & " | " & fields(parsed.value) & " | pre:" & $parsed.value.isPre
    else:
      "error " & hexOut($parsed.error)
  of "C":
    let (left, right) = (version(tokens[1]), version(tokens[2]))
    ordering(cmp(left, right)) & " " & $(left == right)
  of "R":
    let parsed = newRange(unhex(tokens[1]))
    if parsed.isOk:
      let range = parsed.value
      "ok " & hexOut($range.toPubgrub) & " | " & hexOut(range.asStr) & " | " &
        hexOut($toRange(range.toPubgrub)) & " | " & debug(range) & " | lowest:" &
        orNone(range.toPubgrub.lowestVersion)
    else:
      "error " & hexOut($parsed.error)
  of "O":
    let (left, right, version) = (range(tokens[1]), range(tokens[2]), version(tokens[3]))
    operations(left, right, version)
  of "B":
    var position = 1
    let left = built(tokens, position)
    let right = built(tokens, position)
    let version = version(tokens[position])
    $left & " | " & $right & " | " & operations(left, right, version)
  of "S":
    let range = range(tokens[1])
    var versions: seq[Version]
    for token in tokens[2 .. ^1]: versions.add version(token)
    versions.sort(proc (a, b: Version): int = cmp(a, b))
    var contained: seq[string]
    for found in range.containsMany(versions): contained.add $found
    $range.simplify(versions) & " | " & contained.join(",")
  of "I":
    var segments: seq[Interval[Version]]
    for token in tokens[1 .. ^1]:
      for segment in range(token).items: segments.add segment
    $fromIntervals(segments)
  else:
    raiseAssert "unknown case " & tokens[0]

when isMainModule:
  case paramStr(1)
  of "generate": generate(parseInt(paramStr(2)), parseInt(paramStr(3)))
  of "answer":
    for line in stdin.lines: echo answer(line)
  else: quit "usage: driver generate SEED COUNT | driver answer"
