## port-part-of: compiler-core/src/exhaustiveness.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/exhaustiveness.rs.

## Only the shape of `CompiledCase` is ported so far: every assignment of the
## syntax tree carries one, and the parser always puts `CompiledCase::failure()`
## there. `Decision` has only its `Fail` variant and `Variable` is a
## placeholder: the rest comes with the exhaustiveness checker.

type
  DecisionKind* = enum
    deFail

  Decision* = object
    case kind*: DecisionKind
    of deFail:
      discard

  Variable* = object ## Placeholder: see the top of this file.

  CompiledCase* = object
    tree*: Decision
    subjectVariables*: seq[Variable]

func failure*(_: typedesc[CompiledCase]): CompiledCase =
  CompiledCase(tree: Decision(kind: deFail), subjectVariables: @[])
