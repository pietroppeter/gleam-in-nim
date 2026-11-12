## port-part-of: compiler-core/src/analyse.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2018 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/analyse.rs.

## Only `Inferred` is ported so far: the syntax tree needs it. The analysis
## itself comes with the type checker.

type
  InferredKind* = enum
    inKnown
    inUnknown

  Inferred*[T] = object
    ## Upstream `Inferred<T>`. `inUnknown` is the default, as upstream.
    case kind*: InferredKind
    of inKnown:
      vKnown*: T
    of inUnknown:
      discard

func known*[T](value: T): Inferred[T] =
  Inferred[T](kind: inKnown, vKnown: value)

func unknown*[T](): Inferred[T] =
  Inferred[T](kind: inUnknown)

func expect*[T](self: Inferred[T], message: string): T =
  case self.kind
  of inKnown:
    self.vKnown
  of inUnknown:
    raiseAssert message
