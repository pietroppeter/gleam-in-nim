# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The gleam-in-nim contributors
#
# Not a port of a Gleam file: upstream gets this from the Rust crate
# unicode-segmentation (`str.graphemes(true).count()`). The tables are that
# crate's (see graphemes_tables.nim); the rules are those of Unicode Standard
# Annex #29, "Unicode Text Segmentation", written as one pass over the string.

## Counting extended grapheme clusters: what a person would call the
## characters of a string. `"é"` is two code points and one grapheme;
## a family emoji is seven code points and one grapheme.
##
## The pretty printer uses this count as the width of a string when it
## decides where to break a line, so it has to agree with upstream's count
## for every string, which is why the tables come from the very crate (and
## Unicode version) that upstream uses.

import std/unicode
import graphemes_tables
export unicodeVersion

proc graphemeCategory*(codePoint: int32): GraphemeCat =
  ## The category of a code point, by binary search in the table of ranges.
  var
    low = 0
    high: int = graphemeCatTable.high
  while low <= high:
    let middle = (low + high) div 2
    if codePoint < graphemeCatTable[middle].lo: high = middle - 1
    elif codePoint > graphemeCatTable[middle].hi: low = middle + 1
    else: return graphemeCatTable[middle].cat
  gcAny

proc isIncbExtend(codePoint: int32): bool =
  ## Indic_Conjunct_Break=Extend.
  var
    low = 0
    high: int = incbExtendTable.high
  while low <= high:
    let middle = (low + high) div 2
    if codePoint < incbExtendTable[middle].lo: high = middle - 1
    elif codePoint > incbExtendTable[middle].hi: low = middle + 1
    else: return true
  false

proc isIncbLinker(codePoint: int32): bool {.inline.} =
  ## Indic_Conjunct_Break=Linker: the viramas that join two consonants.
  codePoint in incbLinkers

type
  Emoji = enum
    ## Where we are in `Extended_Pictographic Extend* ZWJ` (rule GB11).
    emNone, emPictographic, emJoiner
  Segmenter* = object
    ## What the rules need to remember about the text before a boundary.
    started: bool
    previous: GraphemeCat
    regionalIndicators: int ## how many in a row, up to and including `previous`
    emoji: Emoji
    conjunct: bool ## after a consonant, with only linkers and extends since
    linkers: int   ## how many of those were linkers

proc isBoundary*(segmenter: var Segmenter, codePoint: int32): bool =
  ## Feeds the next code point of a text; true when a grapheme cluster ends
  ## before it. Never true for the first code point.
  let category = graphemeCategory(codePoint)
  let previous = segmenter.previous
  result =
    if not segmenter.started: false
    # GB3: a carriage return and its line feed stay together.
    elif previous == gcCR and category == gcLF: false
    # GB4, GB5: otherwise break around controls and line ends.
    elif previous in {gcControl, gcCR, gcLF} or category in {gcControl, gcCR, gcLF}: true
    # GB6, GB7, GB8: Hangul syllables are made of jamo that stay together.
    elif previous == gcL and category in {gcL, gcV, gcLV, gcLVT}: false
    elif previous in {gcLV, gcV} and category in {gcV, gcT}: false
    elif previous in {gcLVT, gcT} and category == gcT: false
    # GB9, GB9a: never break before a combining mark or a joiner.
    elif category in {gcExtend, gcZWJ, gcSpacingMark}: false
    # GB9b: nor after a prepending character.
    elif previous == gcPrepend: false
    # GB9c: Indic conjuncts, a consonant joined to the next by a linker.
    elif category == gcInCBConsonant and segmenter.conjunct and segmenter.linkers > 0: false
    # GB11: emoji joined by a zero width joiner.
    elif category == gcExtendedPictographic and segmenter.emoji == emJoiner: false
    # GB12, GB13: flags are pairs of regional indicators.
    elif category == gcRegionalIndicator and previous == gcRegionalIndicator and
        segmenter.regionalIndicators mod 2 == 1: false
    # GB999: break everywhere else.
    else: true

  # Remember what the next decision needs.
  segmenter.started = true
  segmenter.previous = category
  if category == gcRegionalIndicator: inc segmenter.regionalIndicators
  else: segmenter.regionalIndicators = 0
  segmenter.emoji =
    if category == gcExtendedPictographic: emPictographic
    elif segmenter.emoji == emPictographic and category == gcExtend: emPictographic
    elif segmenter.emoji == emPictographic and category == gcZWJ: emJoiner
    else: emNone
  if category == gcInCBConsonant:
    segmenter.conjunct = true
    segmenter.linkers = 0
  elif segmenter.conjunct and isIncbLinker(codePoint):
    inc segmenter.linkers
  elif segmenter.conjunct and isIncbExtend(codePoint):
    discard
  else:
    segmenter.conjunct = false

proc graphemesCount*(text: string): int =
  ## The number of extended grapheme clusters in `text`.
  runnableExamples:
    assert graphemesCount("") == 0
    assert graphemesCount("wibble") == 6
    assert graphemesCount("é") == 1
  var segmenter: Segmenter
  for rune in text.runes:
    if segmenter.isBoundary(rune.int32): inc result
  if segmenter.started: inc result

iterator graphemes*(text: string): string =
  ## The extended grapheme clusters of `text`, in order.
  var
    segmenter: Segmenter
    start, index = 0
  while index < text.len:
    let length = text.runeLenAt(index)
    if segmenter.isBoundary(text.runeAt(index).int32):
      yield text[start ..< index]
      start = index
    index += length
  if start < text.len: yield text[start ..< text.len]
