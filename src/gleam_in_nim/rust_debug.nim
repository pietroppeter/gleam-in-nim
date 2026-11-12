# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The gleam-in-nim contributors
#
# Not a port of a Gleam file: upstream gets this from Rust's standard library
# (`format!("{:?}", text)`). The table of escaped characters is asked of Rust
# itself (tools/gen/rust_debug_tables.rs).

## Rust's debug form of a string and of a character: what `{:?}` prints.
##
## Some of the compiler's messages contain one (`encountered unexpected token:
## "and"`), so the port has to quote and escape exactly as Rust does: `\0`,
## `\t`, `\r`, `\n`, the backslash and the quote take a backslash; a character
## that is not printable, or that extends the grapheme before it, is written as
## `\u{hex}`; everything else is itself.

import std/[unicode, strutils]
import rust_debug_tables
export rustDebugUnicodeVersion

func isEscaped(codePoint: int32): bool =
  ## Whether Rust writes this character as `\u{..}`.
  if codePoint < 0x80:
    return codePoint < 0x20 or codePoint == 0x7F
  var
    low = 0
    high: int = rustDebugEscaped.high
  while low <= high:
    let middle = (low + high) div 2
    if codePoint < rustDebugEscaped[middle].lo: high = middle - 1
    elif codePoint > rustDebugEscaped[middle].hi: low = middle + 1
    else: return true
  false

func addEscaped(output: var string, character: Rune, quote: char) =
  let codePoint = character.int32
  case codePoint
  of 0: output.add "\\0"
  of 9: output.add "\\t"
  of 13: output.add "\\r"
  of 10: output.add "\\n"
  of ord('\\'): output.add "\\\\"
  else:
    if codePoint == ord(quote):
      output.add '\\'
      output.add quote
    elif isEscaped(codePoint):
      output.add "\\u{"
      output.add toLowerAscii(toHex(codePoint.int64).strip(leading = true, trailing = false, chars = {'0'}))
      output.add '}'
    else:
      output.add $character

func debugStr*(text: string): string =
  ## `format!("{:?}", text)` for a string: in double quotes.
  result = "\""
  for character in text.runes:
    result.addEscaped(character, '"')
  result.add '"'

func debugChar*(character: Rune): string =
  ## `format!("{:?}", character)` for a char: in single quotes.
  result = "'"
  result.addEscaped(character, '\'')
  result.add '\''
