## port-of: src-span/src/tests.rs
## port-status: conformant
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), src-span/src/tests.rs.

## The upstream tests of `LineNumbers`, and a few of ours for `SrcSpan` and
## the functions upstream does not test.

import gleam_in_nim/src_span

block byteIndexTest:
  let src = """import gleam/io

pub fn main() {
  io.println("Hello, world!")
}
"""
  let lineNumbers = initLineNumbers(src)

  doAssert lineNumbers.byteIndex(Position(line: 0, character: 0)) == 0
  doAssert lineNumbers.byteIndex(Position(line: 0, character: 4)) == 4
  doAssert lineNumbers.byteIndex(Position(line: 100, character: 0)) == src.len
  doAssert lineNumbers.byteIndex(Position(line: 2, character: 1)) == 18

const multibyteSrc = """fn wibble(_a, _b, _c) {
  todo
}

pub fn main() {
  wibble("क्षि", 10, <<"abc">>)
}
"""

# https://github.com/gleam-lang/gleam/issues/3628
block byteIndexWithMultibyteCharacters:
  let lineNumbers = initLineNumbers(multibyteSrc)

  doAssert lineNumbers.byteIndex(Position(line: 1, character: 6)) == 30
  doAssert lineNumbers.byteIndex(Position(line: 5, character: 2)) == 52
  doAssert lineNumbers.byteIndex(Position(line: 5, character: 17)) == 75
  doAssert lineNumbers.byteIndex(Position(line: 6, character: 1)) == 91

# https://github.com/gleam-lang/gleam/issues/3628
block lineAndColumnWithMultibyteCharacters:
  let lineNumbers = initLineNumbers(multibyteSrc)

  doAssert lineNumbers.lineAndUtf16ColumnNumber(30) == LineColumn(line: 2, column: 7)
  doAssert lineNumbers.lineAndUtf16ColumnNumber(52) == LineColumn(line: 6, column: 3)
  doAssert lineNumbers.lineAndUtf16ColumnNumber(75) == LineColumn(line: 6, column: 18)
  doAssert lineNumbers.lineAndUtf16ColumnNumber(91) == LineColumn(line: 7, column: 2)

# Not upstream: the functions the upstream tests do not reach.
block ours:
  let lineNumbers = initLineNumbers("one\ntwo\n\nfour")
  doAssert lineNumbers.lineStarts == @[0, 4, 8, 9]
  doAssert lineNumbers.length == 13
  doAssert lineNumbers.lineNumber(0) == 1
  doAssert lineNumbers.lineNumber(3) == 1
  doAssert lineNumbers.lineNumber(4) == 2
  doAssert lineNumbers.lineNumber(8) == 3
  doAssert lineNumbers.lineNumber(12) == 4
  doAssert lineNumbers.lineNumber(1000) == 4
  doAssert lineNumbers.lineAndUtf8ColumnNumber(5) == LineColumn(line: 2, column: 1)
  doAssert lineNumbers.spansEntireLine(initSrcSpan(4, 7))
  doAssert not lineNumbers.spansEntireLine(initSrcSpan(4, 6))
  doAssert not lineNumbers.spansEntireLine(initSrcSpan(5, 7))

  let span = initSrcSpan(2, 5)
  doAssert span.contains(2) and span.contains(5) and not span.contains(6)
  doAssert span.containsSpan(initSrcSpan(3, 4))
  doAssert span.merge(initSrcSpan(4, 9)) == initSrcSpan(2, 9)
  doAssert span.len == 3 and not span.isEmpty

echo "ok: src_span"
