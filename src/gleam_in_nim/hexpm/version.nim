## port-of: hexpm/src/version.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   hexpm/src/version.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version.rs

## Functions for parsing and matching versions against requirements, based off
## and compatible with the Elixir Version module, which is used by Hex
## internally as well as be the Elixir build tool Hex client.
##
## Notes on the port:
## - `mod lexer; mod parser;` are private submodules upstream and refer back to this file, so
##   they are included here (`version/lexer.nim`, `version/parser.nim`), not imported.
## - Errors: inside the module a private exception is raised where upstream has `?` or
##   `Err(...)`; the public procs catch it and return a `ParseResult`, upstream's `Result`.
## - `pubgrub::Range<Version>` is `Ranges[Version]` of `../version_ranges`.
## - The serde implementations (a version or a range is a string in TOML and JSON) come with
##   the modules that read and write those files.

import std/[hashes, options, strutils, unicode]
import ../version_ranges
export version_ranges

type
  IdentifierKind* = enum
    ikNumeric, ikAlphaNumeric
  Identifier* = object
    case kind*: IdentifierKind
    of ikNumeric: number*: uint32
    of ikAlphaNumeric: text*: string

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
    ##
    major*: uint32
    minor*: uint32
    patch*: uint32
    pre*: seq[Identifier]
    build*: Option[string]

proc `==`*(a, b: Identifier): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ikNumeric: a.number == b.number
  of ikAlphaNumeric: a.text == b.text

proc cmp*(a, b: Identifier): int =
  ## The derived `Ord`: every `Numeric` is below every `AlphaNumeric`.
  if a.kind != b.kind: return cmp(ord(a.kind), ord(b.kind))
  case a.kind
  of ikNumeric: cmp(a.number, b.number)
  of ikAlphaNumeric: cmp(a.text, b.text)

proc hash*(self: Identifier): Hash =
  case self.kind
  of ikNumeric: !$(hash(0) !& hash(self.number))
  of ikAlphaNumeric: !$(hash(1) !& hash(self.text))

proc hash*(self: Version): Hash =
  !$(hash(self.major) !& hash(self.minor) !& hash(self.patch) !& hash(self.pre) !& hash(self.build))

proc `$`*(self: Identifier): string =
  case self.kind
  of ikNumeric: $self.number
  of ikAlphaNumeric: self.text

proc concat*(self: Identifier, addString: string): Identifier =
  case self.kind
  of ikNumeric: Identifier(kind: ikAlphaNumeric, text: $self.number & addString)
  of ikAlphaNumeric: Identifier(kind: ikAlphaNumeric, text: self.text & addString)

proc new*(T: typedesc[Version], major, minor, patch: uint32): Version =
  Version(major: major, minor: minor, patch: patch, pre: @[], build: none(string))

proc bumpMajor(self: Version): Version =
  Version(major: self.major + 1, minor: 0, patch: 0, pre: @[], build: none(string))

proc bumpMinor(self: Version): Version =
  Version(major: self.major, minor: self.minor + 1, patch: 0, pre: @[], build: none(string))

proc bumpPatch(self: Version): Version =
  Version(major: self.major, minor: self.minor, patch: self.patch + 1, pre: @[], build: none(string))

proc lowest*(T: typedesc[Version]): Version =
  Version.new(0, 0, 0)

proc isPre*(self: Version): bool =
  self.pre.len != 0

proc cmpPreOrder(a, b: seq[Identifier]): int =
  ## upstream: `PreOrder`.
  # A wrapper around Vec where an empty vector is greater than a non-empty one.
  # This is desires as if there is a pre-segment in a version (1.0.0-rc1) it is
  # lower than the same version with no pre-segments (1.0.0).
  if a.len == 0 and b.len == 0:
    0
  elif a.len == 0:
    1
  elif b.len == 0:
    -1
  else:
    # the order of slices: element by element, then the shorter one first
    for i in 0 ..< min(a.len, b.len):
      let c = cmp(a[i], b[i])
      if c != 0: return c
    cmp(a.len, b.len)

proc cmp*(self, other: Version): int =
  ## upstream: `Ord for Version`, through `tuple()`. Build metadata is not part of the order,
  ## while it is part of `==`.
  result = cmp(self.major, other.major)
  if result != 0: return
  result = cmp(self.minor, other.minor)
  if result != 0: return
  result = cmp(self.patch, other.patch)
  if result != 0: return
  result = cmpPreOrder(self.pre, other.pre)

proc `<`*(a, b: Version): bool = cmp(a, b) < 0
proc `<=`*(a, b: Version): bool = cmp(a, b) <= 0

proc `$`*(self: Version): string =
  result = $self.major & "." & $self.minor & "." & $self.patch
  if self.pre.len != 0:
    result.add "-"
    for index, identifier in self.pre:
      if index != 0:
        result.add "."
      result.add $identifier
  if self.build.isSome:
    result.add "+" & self.build.get

include version/lexer
include version/parser

type
  ParseResult*[T] = object
    ## upstream: `Result<T, parser::Error>`
    case isOk*: bool
    of true: value*: T
    of false: error*: ParserError

proc ok[T](value: T): ParseResult[T] = ParseResult[T](isOk: true, value: value)
proc err[T](error: ParserError): ParseResult[T] = ParseResult[T](isOk: false, error: error)

proc `==`*[T](a, b: ParseResult[T]): bool =
  if a.isOk != b.isOk: false
  elif a.isOk: a.value == b.value
  else: a.error == b.error

proc moreInput(parser: var Parser): ParserError =
  var tokens = ""
  for token in parser.tail(): tokens.add $token
  ParserError(kind: peMoreInput, tokens: tokens)

proc parse*(T: typedesc[Version], input: string): ParseResult[Version] =
  ## Parse a version.
  try:
    var parser = newParser(input)
    let version = parser.version()
    if not parser.isEof():
      return err[Version](moreInput(parser))
    ok(version)
  except ParserFailure as failure:
    err[Version](failure.error)

proc parseRange(input: string): ParseResult[PubgrubRange] =
  ## Parse a Hex compatible version range. i.e. `> 1 and < 2 or == 4.5.2`.
  ## upstream: `Version::parse_range`
  try:
    var parser = newParser(input)
    let version = parser.range()
    if not parser.isEof():
      return err[PubgrubRange](moreInput(parser))
    ok(version)
  except ParserFailure as failure:
    err[PubgrubRange](failure.error)

proc lowestVersion*(self: PubgrubRange): Option[Version] =
  ## upstream: the trait `LowestVersion`, implemented for `pubgrub::Range<Version>`
  for (lower, _) in self.segments:
    let candidate =
      case lower.kind
      of bkIncluded: some(lower.value)
      of bkExcluded: none(Version)
      of bkUnbounded: some(Version.lowest)
    if candidate.isSome and (result.isNone or cmp(candidate.get, result.get) < 0):
      result = candidate

type
  Range* = object
    spec: string
    range: PubgrubRange

proc new*(T: typedesc[Range], spec: string): ParseResult[Range] =
  let range = parseRange(spec)
  if range.isOk: ok(Range(spec: spec, range: range.value))
  else: err[Range](range.error)

proc toPubgrub*(self: Range): PubgrubRange =
  self.range

proc asStr*(self: Range): string =
  self.spec

proc toRange*(range: PubgrubRange): Range =
  ## upstream: `From<pubgrub::Range<Version>> for Range`
  Range(spec: $range, range: range)

proc toRange*(version: Version): Range =
  ## upstream: `From<Version> for Range`
  toRange(singleton(version))

proc `==`*(a, b: Range): bool =
  a.spec == b.spec and a.range == b.range

proc `$`*(self: Range): string =
  self.spec
