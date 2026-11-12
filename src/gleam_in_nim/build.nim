## port-part-of: compiler-core/src/build.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/build.rs.

## Only `Target` is ported so far: the syntax tree needs it.

type Target* = enum
  tgErlang
  tgJavaScript

func asPresentableStr*(self: Target): string =
  case self
  of tgErlang: "Erlang"
  of tgJavaScript: "JavaScript"

func isJavascript*(self: Target): bool =
  ## Returns `true` if the target is `JavaScript`.
  self == tgJavaScript

func isErlang*(self: Target): bool =
  ## Returns `true` if the target is `Erlang`.
  self == tgErlang

func moduleErlangName*(gleamName: string): string =
  result = newStringOfCap(gleamName.len)
  for c in gleamName:
    result.add (if c == '/': '@' else: c)
