## port-of: src-span/src/lib.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), src-span/src/lib.rs.

## A span of source code, as a pair of byte offsets, and the table that turns
## byte offsets into lines and columns.
##
## Naming: upstream calls the fields `start` and `end`. `end` is a Nim keyword,
## so here it is `stop`. Upstream offsets are `u32`; here they are `int`
## (see the porting guide). `Position` is the one type this file takes from
## the `lsp_types` crate: a zero-based line and a UTF-16 column.

import std/[algorithm, tables, unicode]

type SrcSpan* = object
  start*: int
  stop*: int

func initSrcSpan*(start, stop: int): SrcSpan =
  SrcSpan(start: start, stop: stop)

func contains*(span: SrcSpan, byteIndex: int): bool =
  byteIndex >= span.start and byteIndex <= span.stop

func containsSpan*(span, other: SrcSpan): bool =
  span.contains(other.start) and span.contains(other.stop)

func merge*(span, other: SrcSpan): SrcSpan =
  ## The span that starts at the start of the smaller one and ends at the end
  ## of the bigger one.
  SrcSpan(start: min(span.start, other.start), stop: max(span.stop, other.stop))

func len*(span: SrcSpan): int =
  span.stop - span.start

func isEmpty*(span: SrcSpan): bool =
  span.len == 0

type
  LineColumn* = object ## A 1-index line and column position
    line*: int
    column*: int

  Character* = object
    ## Information about how a character is encoded in UTF-8 and UTF-16.
    lengthUtf8*: uint8 ## The number of bytes needed to encode this in UTF-8.
    lengthUtf16*: uint8
      ## The number of 16-bit segments needed to encode this in UTF-16.

  Position* = object
    ## `lsp_types::Position`: a zero-based line and a UTF-16 column.
    line*: int
    character*: int

  LineNumbers* = object
    ## A struct which contains information about line numbers of a source file,
    ## and can convert between byte offsets that are used in the compiler and
    ## line-column pairs used in LSP.
    lineStarts*: seq[int]
      ## The byte offsets of the start of each line of the source file
    length*: int ## The total length of the source file
    mapping*: Table[int, Character]
      ## A mapping of byte offsets to character length information. This is used
      ## when converting between byte indices and line-column numbers, because
      ## LSP uses UTF-16, while Rust encodes strings as UTF-8.
      ##
      ## This only contains characters which are more than one byte in UTF-8,
      ## because one byte UTF-8 characters are one UTF-16 segment also, so no
      ## translation is needed.
      ##
      ## We could store the whole source file here instead, however that would
      ## be quite wasteful. Most Gleam programs use only ASCII characters, meaning
      ## UTF-8 offsets are the same as UTF-16 ones. With this representation, we
      ## only need to store a few characters.
      ##
      ## In most programs this will be empty because they will only be using
      ## ASCII characters.

func mapping(src: string): Table[int, Character] =
  var i = 0
  while i < src.len:
    let length = runeLenAt(src, i)
    if length != 1:
      let rune = runeAt(src, i)
      result[i] = Character(
        lengthUtf8: uint8(length),
        lengthUtf16: (if int32(rune) > 0xFFFF: 2'u8 else: 1'u8),
      )
    i += length

func initLineNumbers*(src: string): LineNumbers =
  ## Upstream `LineNumbers::new`.
  result.length = src.len
  result.lineStarts = @[0]
  for i, c in src:
    if c == '\n':
      result.lineStarts.add i + 1
  result.mapping = mapping(src)

func lineNumber*(self: LineNumbers, byteIndex: int): int =
  ## Returns the 1-indexed line number of a given byte index
  let next = self.lineStarts.lowerBound(byteIndex)
  if next < self.lineStarts.len and self.lineStarts[next] == byteIndex:
    next + 1
  else:
    next - 1 + 1

func lineStartOf(self: LineNumbers, line: int): int =
  if line - 1 >= 0 and line - 1 < self.lineStarts.len:
    self.lineStarts[line - 1]
  else:
    0

func lineAndUtf8ColumnNumber*(self: LineNumbers, byteIndex: int): LineColumn =
  ## Returns the 1-indexed line and column number of a given byte index,
  ## using a UTF-8 character offset.
  let line = self.lineNumber(byteIndex)
  let lineStart = self.lineStartOf(line)
  LineColumn(line: line, column: byteIndex - lineStart)

func lineAndUtf16ColumnNumber*(self: LineNumbers, byteIndex: int): LineColumn =
  ## Returns the 1-indexed line and column number of a given byte index,
  ## using a UTF-16 character offset.
  let line = self.lineNumber(byteIndex)
  let lineStart = self.lineStartOf(line)

  var u8Offset = lineStart
  var u16Offset = 0

  while true:
    if u8Offset >= byteIndex:
      break

    if u8Offset in self.mapping:
      let length = self.mapping[u8Offset]
      u8Offset += int(length.lengthUtf8)
      u16Offset += int(length.lengthUtf16)
    else:
      u16Offset += 1
      u8Offset += 1

  LineColumn(line: line, column: u16Offset + 1)

func byteIndex*(self: LineNumbers, position: Position): int =
  ## Returns the byte index of the corresponding LSP line-column `Position`,
  ## translating from a UTF-16 character index to a UTF-8 byte index.
  if position.line >= self.lineStarts.len:
    return self.length
  let lineStart = self.lineStarts[position.line]

  var u8Offset = lineStart
  var u16Offset = 0

  while true:
    if u16Offset >= position.character:
      break

    if u8Offset in self.mapping:
      let length = self.mapping[u8Offset]
      u8Offset += int(length.lengthUtf8)
      u16Offset += int(length.lengthUtf16)
    else:
      u16Offset += 1
      u8Offset += 1

  u8Offset

func spansEntireLine*(self: LineNumbers, span: SrcSpan): bool =
  ## Checks if the given span spans an entire line (excluding the newline
  ## character itself).
  for lineStart in self.lineStarts:
    if lineStart == span.start and (span.stop + 1) in self.lineStarts:
      return true
  false
