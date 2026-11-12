# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The gleam-in-nim contributors
#
# Not a port of a Gleam file: upstream gets this from the Rust crate
# unicode-width (`UnicodeWidthChar::width`), through codespan-reporting. The
# table is that crate's (see unicode_width_tables.nim).

## How many terminal columns a character takes: 0 for control and combining
## characters, 2 for wide ones (CJK, most emoji), 1 for the rest.
import std/unicode
import unicode_width_tables

func width*(ch: Rune): int =
  ## What `ch.width().unwrap_or(0)` is in Rust.
  let codePoint = ch.int32
  var low = 0
  var high: int = widthRanges.high
  while low <= high:
    let mid = (low + high) div 2
    if codePoint < widthRanges[mid].first: high = mid - 1
    elif codePoint > widthRanges[mid].last: low = mid + 1
    else: return widthRanges[mid].width.int
  1
