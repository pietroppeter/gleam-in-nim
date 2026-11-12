## port-part-of: compiler-core/src/error.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/error.rs.

## The compiler's error module. Only the text wrapping helpers are ported so
## far, because lexical error messages need them.

func floorCharBoundary(s: string, index: int): int =
  ## The closest UTF-8 character boundary at or before `index`.
  if index >= s.len:
    return s.len
  result = index
  while result > 0 and (s[result].ord and 0xC0) == 0x80:
    dec result

func breakWord(word: string, width: int): tuple[lines: seq[string], remainder: string] =
  ## Breaks a word into lines of at most `width` bytes.
  var cut = word.floorCharBoundary(width)
  result.lines.add word[0 ..< cut]
  var remainder = word[cut .. ^1]
  while remainder.len > width:
    cut = remainder.floorCharBoundary(width)
    result.lines.add remainder[0 ..< cut]
    remainder = remainder[cut .. ^1]
  result.remainder = remainder

func split1(s: string, sep: char): seq[string] =
  ## Like Rust's `str::split` with a char: always at least one piece.
  result = @[""]
  for c in s:
    if c == sep:
      result.add ""
    else:
      result[^1].add c

func breakLine(line: string, width: int): seq[string] =
  var newline = ""
  var i = 0
  for word in line.split1(' '):
    let isNewLine = i < 1 or newline.len == 0
    inc i
    let canAddWord =
      if isNewLine:
        newline.len + word.len <= width
      else:
        # +1 accounts for space added before word
        newline.len + (word.len + 1) <= width
    if canAddWord:
      if not isNewLine:
        newline.add ' '
      newline.add word
    else:
      # word too big, save existing line if present
      if newline.len > 0:
        result.add newline
        newline = ""
      # then save word to a new line or break it
      if word.len > width:
        let (lines, remainder) = breakWord(word, width)
        result.add lines
        newline.add remainder
      else:
        newline.add word
  if newline.len > 0:
    result.add newline

func wrapText(text: string, width: int): seq[string] =
  for line in text.split1('\n'):
    if line.len > width:
      result.add breakLine(line, width)
    else:
      result.add line

func wrap*(text: string): string =
  ## Wraps text at 75 columns, the width of Gleam's diagnostics.
  let lines = wrapText(text, 75)
  for i, line in lines:
    if i > 0:
      result.add '\n'
    result.add line
