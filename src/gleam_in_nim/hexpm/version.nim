## port-of: hexpm/src/version.rs
## port-status: draft
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version.rs
#
# Not ported yet: the serde parts (a version or a range read from, and written
# to, TOML and JSON). They come with the manifest.

## Functions for parsing and matching versions against requirements, based off
## and compatible with the Elixir Version module, which is used by Hex
## internally as well as be the Elixir build tool Hex client.

import std/[options, hashes]
import version/lexer
import ../version_ranges
import ../rust_debug

export options, version_ranges
export lexer.Token, lexer.TokenKind, lexer.LexerException

type
  IdentifierKind* = enum
    ikNumeric
    ikAlphaNumeric

  Identifier* = object
    case kind*: IdentifierKind
    of ikNumeric:
      vNumeric*: uint32
    of ikAlphaNumeric:
      vAlphaNumeric*: string

  Version* = object
    ## In a nutshell, a version is represented by three numbers:
    ##
    ## MAJOR.MINOR.PATCH
    ##
    ## Pre-releases are supported by optionally appending a hyphen and a series of
    ## period-separated identifiers immediately following the patch version.
    ## Identifiers consist of only ASCII alphanumeric characters and hyphens (`[0-9A-Za-z-]`):
    ##
    ## "1.0.0-alpha.3"
    ##
    ## Build information can be added by appending a plus sign and a series of
    ## dot-separated identifiers immediately following the patch or pre-release version.
    ## Identifiers consist of only ASCII alphanumeric characters and hyphens (`[0-9A-Za-z-]`):
    ##
    ## "1.0.0-alpha.3+20130417140000.amd64"
    major*: uint32
    minor*: uint32
    patch*: uint32
    pre*: seq[Identifier]
    build*: Option[string]

  PubgrubRange* = Ranges[Version]

func numeric*(number: uint32): Identifier = Identifier(kind: ikNumeric, vNumeric: number)
func alphaNumeric*(text: string): Identifier = Identifier(kind: ikAlphaNumeric, vAlphaNumeric: text)

func `==`*(left, right: Identifier): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of ikNumeric: left.vNumeric == right.vNumeric
  of ikAlphaNumeric: left.vAlphaNumeric == right.vAlphaNumeric

func cmp*(left, right: Identifier): int =
  ## Rust's derived order: every number is before every word, numbers go by
  ## value and words byte by byte.
  if left.kind != right.kind:
    return cmp(ord(left.kind), ord(right.kind))
  case left.kind
  of ikNumeric: cmp(left.vNumeric, right.vNumeric)
  of ikAlphaNumeric: cmp(left.vAlphaNumeric, right.vAlphaNumeric)

func hash*(identifier: Identifier): Hash =
  case identifier.kind
  of ikNumeric: !$(hash(0) !& hash(identifier.vNumeric))
  of ikAlphaNumeric: !$(hash(1) !& hash(identifier.vAlphaNumeric))

func `$`*(self: Identifier): string =
  case self.kind
  of ikNumeric: $self.vNumeric
  of ikAlphaNumeric: self.vAlphaNumeric

func concat*(self: Identifier, addString: string): Identifier =
  case self.kind
  of ikNumeric: alphaNumeric($self.vNumeric & addString)
  of ikAlphaNumeric: alphaNumeric(self.vAlphaNumeric & addString)

func initVersion*(major, minor, patch: uint32): Version =
  ## Upstream's `Version::new`.
  Version(major: major, minor: minor, patch: patch, pre: @[], build: none(string))

# The three bumps add one to a `u32`. Upstream is built in release mode, where
# that wraps around at 4294967295, and so does a Nim `uint32`.

func bumpMajor(self: Version): Version =
  Version(major: self.major + 1, minor: 0, patch: 0, pre: @[], build: none(string))

func bumpMinor(self: Version): Version =
  Version(major: self.major, minor: self.minor + 1, patch: 0, pre: @[], build: none(string))

func bumpPatch(self: Version): Version =
  Version(major: self.major, minor: self.minor, patch: self.patch + 1, pre: @[], build: none(string))

func lowest*(): Version =
  initVersion(0, 0, 0)

func isPre*(self: Version): bool =
  self.pre.len != 0

func `==`*(left, right: Version): bool =
  ## Rust's derived equality: every field, the build metadata too. The order
  ## (`cmp`, `<`) does not look at the build, so two versions can be neither
  ## smaller nor greater and still not equal.
  left.major == right.major and left.minor == right.minor and left.patch == right.patch and
    left.pre == right.pre and left.build == right.build

func hash*(version: Version): Hash =
  !$(hash(version.major) !& hash(version.minor) !& hash(version.patch) !& hash(version.pre) !&
    hash(version.build))

func cmpPreOrder(left, right: openArray[Identifier]): int =
  ## Upstream's `PreOrder`: a wrapper around Vec where an empty vector is
  ## greater than a non-empty one. This is desires as if there is a
  ## pre-segment in a version (1.0.0-rc1) it is lower than the same version
  ## with no pre-segments (1.0.0).
  if left.len == 0 and right.len == 0:
    0
  elif left.len == 0:
    1
  elif right.len == 0:
    -1
  else:
    # The order of two slices: the first pair that differs, then the length.
    for i in 0 ..< min(left.len, right.len):
      let ordering = cmp(left[i], right[i])
      if ordering != 0:
        return ordering
    cmp(left.len, right.len)

func cmp*(self, other: Version): int =
  result = cmp(self.major, other.major)
  if result != 0: return
  result = cmp(self.minor, other.minor)
  if result != 0: return
  result = cmp(self.patch, other.patch)
  if result != 0: return
  result = cmpPreOrder(self.pre, other.pre)

func `<`*(left, right: Version): bool = cmp(left, right) < 0
func `<=`*(left, right: Version): bool = cmp(left, right) <= 0

func `$`*(self: Version): string =
  result = $self.major & "." & $self.minor & "." & $self.patch
  if self.pre.len != 0:
    result.add "-"
    for index, identifier in self.pre:
      if index != 0:
        result.add "."
      result.add $identifier
  if self.build.isSome:
    result.add "+" & self.build.get

include version/parser

type
  ParseResult*[T] = object
    ## Rust's `Result<T, parser::Error>`.
    case isOk*: bool
    of true:
      value*: T
    of false:
      error*: Error

  Range* = object
    spec: string
    range: PubgrubRange

proc parse*(input: string): ParseResult[Version] =
  ## Parse a version. Upstream's `Version::parse`.
  try:
    var parser = initParser(input)
    let version = parser.version()
    if not parser.isEof():
      var tokens = ""
      for token in parser.tail():
        tokens.add $token
      return ParseResult[Version](isOk: false, error: Error(kind: ekMoreInput, vMoreInput: tokens))
    ParseResult[Version](isOk: true, value: version)
  except ParserException as exception:
    ParseResult[Version](isOk: false, error: exception.error)

proc parseRange(input: string): ParseResult[PubgrubRange] =
  ## Parse a Hex compatible version range. i.e. `> 1 and < 2 or == 4.5.2`.
  try:
    var parser = initParser(input)
    let version = parser.range()
    if not parser.isEof():
      var tokens = ""
      for token in parser.tail():
        tokens.add $token
      return ParseResult[PubgrubRange](isOk: false, error: Error(kind: ekMoreInput, vMoreInput: tokens))
    ParseResult[PubgrubRange](isOk: true, value: version)
  except ParserException as exception:
    ParseResult[PubgrubRange](isOk: false, error: exception.error)

func lowestVersion*(self: PubgrubRange): Option[Version] =
  ## Upstream's trait `LowestVersion`, which only a range implements.
  for (lower, higher) in self.items:
    let candidate =
      case lower.kind
      of bkIncluded: some(lower.value)
      of bkExcluded: none(Version)
      of bkUnbounded: some(lowest())
    # The minimum, and the first one of those that compare equal.
    if candidate.isSome and (result.isNone or candidate.get < result.get):
      result = candidate

proc newRange*(spec: string): ParseResult[Range] =
  ## Upstream's `Range::new`.
  let range = parseRange(spec)
  if range.isOk:
    ParseResult[Range](isOk: true, value: Range(spec: spec, range: range.value))
  else:
    ParseResult[Range](isOk: false, error: range.error)

func toPubgrub*(self: Range): PubgrubRange =
  self.range

func asStr*(self: Range): string =
  self.spec

func toRange*(range: PubgrubRange): Range =
  ## Upstream's `From<pubgrub::Range<Version>> for Range`.
  Range(spec: $range, range: range)

func toRange*(version: Version): Range =
  ## Upstream's `From<Version> for Range`.
  toRange(singleton(version))

func `==`*(left, right: Range): bool =
  left.spec == right.spec and left.range == right.range

func debug*(self: Range): string =
  ## Rust's `{:?}` of a range.
  "Range(" & debugStr(self.spec) & ")"

func `$`*(self: Range): string =
  self.spec
