# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
#
# Ported to Nim from the Gleam compiler: compiler-core/src/pretty/tests.rs as
# it was in commit bc1d344c3 (9 June 2026), the last one before upstream moved
# the pretty printer to its own crate and dropped this file. The pinned
# snapshot (v1.19.2) has no tests of its own for the pretty printer: there it
# is tested through the formatter and the JavaScript backend.
import std/unittest
import ../src/gleam_in_nim/pretty

proc frame(mode: Mode, document: Document, next: Frame = nil): Frame =
  Frame(indent: 0, mode: mode, document: document, next: next)

suite "pretty printer: upstream's tests":
  test "fits_test":
    # Negative limits never fit
    check not fits(-1, 0, nil)

    # If no more documents it always fits
    check fits(0, 0, nil)

    # ForceBreak never fits
    check not fits(100, 0, frame(Unbroken, emptyDocument.forceBreak))
    check not fits(100, 0, frame(Broken, emptyDocument.forceBreak))

    # Break in Broken fits always
    check fits(1, 0, frame(Broken, breakDoc("12", "")))

    # Break in Unbroken mode fits if `unbroken` fits
    check fits(3, 0, frame(Unbroken, breakDoc("", "123")))
    check not fits(2, 0, frame(Unbroken, breakDoc("", "123")))

    # Line always fits
    check fits(0, 0, frame(Broken, lines(100)))
    check fits(0, 0, frame(Unbroken, lines(100)))

    # String fits if smaller than limit
    check fits(5, 0, frame(Broken, "Hello".toDoc))
    check fits(5, 0, frame(Unbroken, "Hello".toDoc))
    check not fits(4, 0, frame(Broken, "Hello".toDoc))
    check not fits(4, 0, frame(Unbroken, "Hello".toDoc))

    # Cons fits if combined smaller than limit
    let cons = "1".toDoc.append("2")
    check fits(2, 0, frame(Broken, cons))
    check fits(2, 0, frame(Unbroken, cons))
    check not fits(1, 0, frame(Broken, cons))
    check not fits(1, 0, frame(Unbroken, cons))

    # Nest fits if combined smaller than limit
    for indent in [1, 0]:
      let nested = "12".toDoc.nest(indent)
      check fits(2, 0, frame(Broken, nested))
      check fits(2, 0, frame(Unbroken, nested))
      check not fits(1, 0, frame(Broken, nested))
      check not fits(1, 0, frame(Unbroken, nested))

    let zeroWidth = zeroWidthStr("this is a very long string that doesn't count towards line width")
    check fits(10, 0, frame(Unbroken, zeroWidth))
    check fits(10, 9, frame(Unbroken, zeroWidth))
    check fits(10, 0, frame(Unbroken, "hello!".toDoc, frame(Unbroken, zeroWidth)))

  test "format_test":
    check "Hi".toDoc.toPrettyString(10) == "Hi"
    check "Hi".toDoc.append(", world!").toPrettyString(10) == "Hi, world!"

    check breakDoc("broken", "unbroken").group.toPrettyString(10) == "unbroken"
    check breakDoc("broken", "unbroken").group.toPrettyString(5) == "broken\n"

    check "1".toDoc.append(lines(1).append("2")).nest(2).toPrettyString(1) == "1\n  2"

    check breakDoc("broken", "unbroken").forceBreak.group.toPrettyString(100) == "broken\n"
    check flexBreak("broken", "unbroken").forceBreak.toPrettyString(100) == "unbroken"

    let document = concat([
      breakDoc("broken", "unbroken"),
      zeroWidthStr("<This will not cause a line break>"),
      breakDoc("broken", "unbroken"),
    ])
    check document.toPrettyString(20) == "unbroken<This will not cause a line break>unbroken"

  test "forcing_test":
    let docs = join(["hello".toDoc, "a".toDoc, "b".toDoc, "c".toDoc, "d".toDoc], breakDoc("", " "))
    check docs.forceBreak.group.toPrettyString(80) == "hello\na\nb\nc\nd"
    check docs.forceBreak.nextBreakFits(Enabled).group.toPrettyString(80) == "hello a b c d"
    check docs.forceBreak.nextBreakFits(Enabled).nextBreakFits(Disabled).group.toPrettyString(80) ==
      "hello\na\nb\nc\nd"

  test "nest_if_broken_test":
    check concat(["hello".toDoc, breakDoc("", " "), "world".toDoc]).nestIfBroken(2).group
      .toPrettyString(10) == "hello\n  world"

    let listDoc = concat([
      concat([breakDoc("[", "["), "a,".toDoc, breakDoc("", " "), "b".toDoc]).nest(2),
      breakDoc(",", ""),
      "]".toDoc,
    ]).group

    let argumentsDoc = concat([
      breakDoc("", ""),
      "one".toDoc,
      ",".toDoc,
      breakDoc("", " "),
      listDoc.group.nextBreakFits(Enabled),
    ]).nestIfBroken(2).group

    let functionCallDoc = concat([
      "some_function_call(".toDoc, argumentsDoc, breakDoc("", ""), ")".toDoc,
    ]).group

    check functionCallDoc.toPrettyString(2) ==
      "some_function_call(\n  one,\n  [\n    a,\n    b,\n  ]\n)"
    check functionCallDoc.toPrettyString(20) == "some_function_call(\n  one,\n  [a, b]\n)"
    check functionCallDoc.toPrettyString(25) == "some_function_call(one, [\n  a,\n  b,\n])"
    check functionCallDoc.toPrettyString(80) == "some_function_call(one, [a, b])"

  test "let_left_side_fits_test":
    let elements = breakDoc("", "").append("1").nest(2).append(breakDoc("", ""))
    let list = "[".toDoc.append(elements).append("]").group
    let document = list.append(" = ").append(list)

    check document.toPrettyString(7) == "[1] = [\n  1\n]"
    check document.toPrettyString(2) == "[\n  1\n] = [\n  1\n]"
    check document.toPrettyString(16) == "[1] = [1]"

  test "empty_documents":
    # nil
    check emptyDocument.isEmpty

    # lines
    check lines(0).isEmpty
    check not line().isEmpty

    # force break
    check emptyDocument.forceBreak.isEmpty
    check not "ok".toDoc.forceBreak.isEmpty

    # strings
    check "".toDoc.isEmpty
    check not "wibble".toDoc.isEmpty
    check not " ".toDoc.isEmpty
    check not "\n".toDoc.isEmpty

    # containers
    check "".toDoc.nest(2).isEmpty
    check not "wibble".toDoc.nest(2).isEmpty
    check "".toDoc.group.isEmpty
    check not "wibble".toDoc.group.isEmpty
    check breakDoc("", "").isEmpty
    check not breakDoc("wibble", "wibble").isEmpty
    check not breakDoc("wibble\nwobble", "wibble wobble").isEmpty
    check "".toDoc.append("".toDoc).isEmpty
    check not "wibble".toDoc.append("".toDoc).isEmpty
    check not "".toDoc.append("wibble".toDoc).isEmpty
    check not zeroWidthStr("wibble").isEmpty

  test "set_nesting":
    let document = docvec("wibble", breakDoc("", " "), "wobble").group
    check document.setNesting(0).nest(2).toPrettyString(1) == "wibble\nwobble"

type Recorder = ref object of CursorPositionObserver
  seen: seq[(int, int)]

method observeCursorPosition(recorder: Recorder, line, width: int) =
  recorder.seen.add (line, width)

suite "pretty printer: the examples of upstream's doc comments, and what the port adds":
  test "break_ example":
    let document = docvec("Hello", breakDoc("", ", "), "world!").group
    check document.toPrettyString(20) == "Hello, world!"
    check document.toPrettyString(10) == "Hello\nworld!"

  test "flex_break example":
    let withBreaks = docvec("Hello", breakDoc("", ", "), "pretty", breakDoc("", ", "), "printed!").group
    check withBreaks.toPrettyString(20) == "Hello\npretty\nprinted!"
    let withFlexBreaks = docvec("Hello", flexBreak("", ", "), "pretty", flexBreak("", ", "), "printed!").group
    check withFlexBreaks.toPrettyString(20) == "Hello, pretty\nprinted!"

  test "zero_width_string example":
    let document = docvec("Hello", zeroWidthStr("This is a very long string"), breakDoc("", ""), "world")
    check document.toPrettyString(20) == "HelloThis is a very long stringworld"

  test "a string is as wide as its grapheme clusters, a break as its bytes":
    check "abc".toDoc.graphemes == 3
    check "è".toDoc.graphemes == 1 # two bytes
    check "é".toDoc.graphemes == 1 # e and a combining accent
    check "👩‍👩‍👧‍👦".toDoc.graphemes == 1 # four people joined into one family
    check "\r\n".toDoc.graphemes == 1
    # Upstream measures the text of a break in bytes, not in graphemes, so a
    # string and a break with the same text can fit differently.
    check fits(1, 0, frame(Unbroken, "è".toDoc))
    check not fits(1, 0, frame(Unbroken, breakDoc("", "è")))

  test "docvec, concat and join print their documents in order":
    for count in 0 .. 9:
      var documents: seq[Document]
      var expected = ""
      for index in 0 ..< count:
        documents.add toDoc($index)
        expected.add $index
      check concat(documents).toPrettyString(80) == expected
      check docvec(documents).toPrettyString(80) == expected
    check join(["a".toDoc, "b".toDoc, "c".toDoc], ", ".toDoc).toPrettyString(80) == "a, b, c"
    check join([], ", ".toDoc).isEmpty
    check "x".toDoc.surround("(", ")").toPrettyString(80) == "(x)"

  test "the cursor position observer sees lines and columns":
    let recorder = Recorder()
    let document = docvec("ab", positionObserver(recorder), line(), "cde", positionObserver(recorder)).nest(2)
    check document.toPrettyString(80) == "ab\n  cde"
    check recorder.seen == @[(0, 2), (1, 5)]

  test "the constants keep upstream's widths, the odd ones included":
    check spaceDocument.string == " "
    check constSpaceDocument.string == "const " and constSpaceDocument.graphemes == 5
    check ifSpaceDocument.string == "if " and ifSpaceDocument.graphemes == 2
    check commaBreakDocument.broken == "," and commaBreakDocument.unbroken == ", "
    check flexCommaDocument.breakKind == Flex
