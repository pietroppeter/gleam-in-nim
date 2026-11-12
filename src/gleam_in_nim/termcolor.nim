# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The gleam-in-nim contributors
#
# Not a port of a Gleam file: upstream gets this from the Rust crate termcolor
# 1.4.1 (Andrew Gallant, Unlicense or MIT). Only what the compiler uses is
# here: a buffer that either drops colours or writes ANSI escape codes, with
# the bytes termcolor writes.

## Coloured text for a terminal, written to a buffer in memory.
import std/options

type
  Color* {.pure.} = enum
    Black, Blue, Green, Red, Cyan, Magenta, Yellow, White

  ColorSpec* = object
    fgColor*: Option[Color]
    bgColor*: Option[Color]
    bold*: bool
    intense*: bool
    underline*: bool
    dimmed*: bool
    italic*: bool
    reset*: bool
    strikethrough*: bool

  BufferKind = enum
    bkNoColor, bkAnsi

  Buffer* = ref object
    ## `termcolor::Buffer`. A ref, because upstream always passes it as `&mut`.
    kind: BufferKind
    bytes: string

func newColorSpec*(): ColorSpec =
  ## A spec with nothing set, that resets what came before (`ColorSpec::new()`).
  ColorSpec(reset: true)

func setFg*(spec: ColorSpec, color: Option[Color]): ColorSpec =
  result = spec
  result.fgColor = color

func setBold*(spec: ColorSpec, yes: bool): ColorSpec =
  result = spec
  result.bold = yes

func setIntense*(spec: ColorSpec, yes: bool): ColorSpec =
  result = spec
  result.intense = yes

func noColor*(_: typedesc[Buffer]): Buffer = Buffer(kind: bkNoColor)
func ansi*(_: typedesc[Buffer]): Buffer = Buffer(kind: bkAnsi)

func write*(buffer: Buffer, text: string) = buffer.bytes.add text
func asString*(buffer: Buffer): string = buffer.bytes
  ## What was written so far (`as_slice`).
func supportsColor*(buffer: Buffer): bool = buffer.kind == bkAnsi

func reset*(buffer: Buffer) =
  if buffer.kind == bkAnsi: buffer.bytes.add "\x1B[0m"

func writeColor(buffer: Buffer, fg: bool, color: Color, intense: bool) =
  if intense:
    let code = case color
      of Color.Black: "8"
      of Color.Blue: "12"
      of Color.Green: "10"
      of Color.Red: "9"
      of Color.Cyan: "14"
      of Color.Magenta: "13"
      of Color.Yellow: "11"
      of Color.White: "15"
    buffer.bytes.add (if fg: "\x1B[38;5;" else: "\x1B[48;5;") & code & "m"
  else:
    let code = case color
      of Color.Black: "0"
      of Color.Blue: "4"
      of Color.Green: "2"
      of Color.Red: "1"
      of Color.Cyan: "6"
      of Color.Magenta: "5"
      of Color.Yellow: "3"
      of Color.White: "7"
    buffer.bytes.add (if fg: "\x1B[3" else: "\x1B[4") & code & "m"

func setColor*(buffer: Buffer, spec: ColorSpec) =
  if buffer.kind == bkNoColor: return
  if spec.reset: buffer.reset()
  if spec.bold: buffer.bytes.add "\x1B[1m"
  if spec.dimmed: buffer.bytes.add "\x1B[2m"
  if spec.italic: buffer.bytes.add "\x1B[3m"
  if spec.underline: buffer.bytes.add "\x1B[4m"
  if spec.strikethrough: buffer.bytes.add "\x1B[9m"
  if spec.fgColor.isSome: buffer.writeColor(true, spec.fgColor.get, spec.intense)
  if spec.bgColor.isSome: buffer.writeColor(false, spec.bgColor.get, spec.intense)
