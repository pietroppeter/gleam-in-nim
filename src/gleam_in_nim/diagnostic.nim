## port-of: compiler-core/src/diagnostic.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/diagnostic.rs.

import std/[options, tables]
import codespan_reporting, error, src_span, termcolor

export LabelStyle, Severity

type
  Level* {.pure.} = enum
    Error
    Warning

  Label* = object
    text*: Option[string]
    span*: SrcSpan

  ExtraLabel* = object
    srcInfo*: Option[tuple[src: string, path: string]]
    label*: Label

  Location* = object
    src*: string
    path*: string
    label*: Label
    extraLabels*: seq[ExtraLabel]

  # TODO: split this into locationed diagnostics and locationless diagnostics
  Diagnostic* = object
    title*: string
    text*: string
    level*: Level
    location*: Option[Location]
    hint*: Option[string]

func toCodespanLabel(label: Label, fileid: int, style: LabelStyle): codespan_reporting.Label =
  let codespanLabel = newLabel(style, fileid, (label.span.start, label.span.stop))
  if label.text.isNone: codespanLabel
  else: codespanLabel.withMessage(label.text.get)

proc writeSpan(diagnostic: Diagnostic, location: Location, buffer: Buffer) =
  var fileMap: Table[string, int]
  var files: SimpleFiles

  let mainLocationPath = location.path
  let mainLocationSrc = location.src
  let mainFileId = files.add(mainLocationPath, mainLocationSrc)
  fileMap[mainLocationPath] = mainFileId

  var labels = @[location.label.toCodespanLabel(mainFileId, LabelStyle.Primary)]

  for label in location.extraLabels:
    let (locationSrc, locationPath) =
      if label.srcInfo.isSome: (label.srcInfo.get.src, label.srcInfo.get.path)
      else: (mainLocationSrc, mainLocationPath)
    if locationPath notin fileMap:
      let fileId = files.add(locationPath, locationSrc)
      fileMap[locationPath] = fileId
      labels.add label.label.toCodespanLabel(fileId, LabelStyle.Secondary)
    else:
      labels.add label.label.toCodespanLabel(fileMap[locationPath], LabelStyle.Secondary)

  let severity = case diagnostic.level
    of Level.Error: Severity.Error
    of Level.Warning: Severity.Warning

  let codespanDiagnostic = newDiagnostic(severity)
    .withMessage(diagnostic.title)
    .withLabels(labels)
  let config = defaultConfig()
  emitToWriteStyle(buffer, config, files, codespanDiagnostic)

proc writeTitle(diagnostic: Diagnostic, buffer: Buffer) =
  let (kind, colour) = case diagnostic.level
    of Level.Error: ("error", Color.Red)
    of Level.Warning: ("warning", Color.Yellow)
  buffer.setColor(newColorSpec().setBold(true).setFg(some(colour)))
  buffer.write kind
  buffer.setColor(newColorSpec().setBold(true))
  buffer.write ": " & diagnostic.title & "\n\n"
  buffer.setColor(newColorSpec())

proc write*(diagnostic: Diagnostic, buffer: Buffer) =
  if diagnostic.location.isSome: diagnostic.writeSpan(diagnostic.location.get, buffer)
  else: diagnostic.writeTitle(buffer)

  if diagnostic.text.len > 0:
    buffer.write diagnostic.text & "\n"

  if diagnostic.hint.isSome:
    # If there's some text before the hint we want to leave an empty
    # line separating the two.
    if diagnostic.text.len > 0:
      buffer.write "\n"
    let message = wrap("Hint: " & diagnostic.hint.get)
    buffer.write message & "\n"
