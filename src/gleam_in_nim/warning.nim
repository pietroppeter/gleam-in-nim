## port-part-of: compiler-core/src/warning.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/warning.rs.

## Warnings. Only the ones the parser gives are ported so far: syntax that
## still parses but is deprecated.

import ./[build, rust_enum, src_span]

type
  DeprecatedSyntaxWarningKind* = enum
    dsDeprecatedListPrepend
      ## If someone uses the deprecated syntax to append to a list:
      ## `["a"..["b", "c"]]`, notice how there's no comma!
    dsDeprecatedListPattern
      ## If someone uses the deprecated syntax to pattern match on a list:
      ## ```gleam
      ## case list {
      ##   [first..rest] -> todo
      ##   //   ^^ notice there's no comma!
      ##   _ ->
      ## }
      ## ```
    dsDeprecatedListCatchAllPattern
      ## If someone uses the deprecated syntax to match on all lists instead of
      ## a common `_`:
      ## ```gleam
      ## case list {
      ##   [..] -> todo
      ## //^^^^ this matches on all lists so a `_` should be used instead!
      ##   _ ->
      ## }
      ## ```
    dsDeprecatedListSpreadAsVariablePattern
      ## If someone uses the deprecated syntax to match on all lists and bind
      ## them to a name: `[..name]`.
    dsDeprecatedRecordSpreadPattern
      ## If a record pattern has a spread that is not preceded by a comma:
      ## ```gleam
      ## case wibble {
      ##   Wibble(arg1: name ..) -> todo
      ## //                  ^^ this should be preceded by a comma!
      ## }
      ## ```
    dsDeprecatedEmptyClauseGuard
      ## If a guard has an empty clause : `_ if -> todo`
    dsDeprecatedTargetShorthand

  DeprecatedSyntaxWarningLocation* = object of StructVariant
    ## The fields of the five warnings that are only a location.
    location*: SrcSpan

  DeprecatedSyntaxWarningDeprecatedListSpreadAsVariablePattern* = object of StructVariant
    location*: SrcSpan
    name*: string

  DeprecatedSyntaxWarningDeprecatedTargetShorthand* = object of StructVariant
    target*: Target
    location*: SrcSpan

  DeprecatedSyntaxWarning* = object
    case kind*: DeprecatedSyntaxWarningKind
    of dsDeprecatedListPrepend: vDeprecatedListPrepend*: DeprecatedSyntaxWarningLocation
    of dsDeprecatedListPattern: vDeprecatedListPattern*: DeprecatedSyntaxWarningLocation
    of dsDeprecatedListCatchAllPattern:
      vDeprecatedListCatchAllPattern*: DeprecatedSyntaxWarningLocation
    of dsDeprecatedListSpreadAsVariablePattern:
      vDeprecatedListSpreadAsVariablePattern*:
        DeprecatedSyntaxWarningDeprecatedListSpreadAsVariablePattern
    of dsDeprecatedRecordSpreadPattern:
      vDeprecatedRecordSpreadPattern*: DeprecatedSyntaxWarningLocation
    of dsDeprecatedEmptyClauseGuard: vDeprecatedEmptyClauseGuard*: DeprecatedSyntaxWarningLocation
    of dsDeprecatedTargetShorthand:
      vDeprecatedTargetShorthand*: DeprecatedSyntaxWarningDeprecatedTargetShorthand
