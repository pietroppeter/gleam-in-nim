## port-part-of: compiler-core/src/type_/expression.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/type_/expression.rs.

## Only `Implementations` and `Purity` are ported so far: the syntax tree
## needs them. The typing of expressions comes with the type checker.

type
  Implementations* = object
    gleam*: bool
      ## Whether the function has a pure-gleam implementation.
      ##
      ## It's important to notice that, even if all individual targets are
      ## supported, it would not be the same as being pure Gleam.
      ## Imagine this scenario:
      ##
      ## ```gleam
      ## @external(javascript, "wibble", "wobble")
      ## @external(erlang, "wibble", "wobble")
      ## pub fn func() -> Int
      ## ```
      ##
      ## `func` supports all _current_ Gleam targets; however, if a new target
      ## is added - say a WASM target - `func` wouldn't support it! On the other
      ## hand, a pure Gleam function will support all future targets.
    canRunOnErlang*: bool
    canRunOnJavascript*: bool
    usesErlangExternals*: bool
      ## Whether the function has an implementation that uses external Erlang
      ## code.
    usesJavascriptExternals*: bool
      ## Whether the function has an implementation that uses external javascript
      ## code.

  Purity* = enum
    ## The purity of a function.
    ##
    ## This is not actually proper purity tracking, rather an approximation, which
    ## is good enough for the purpose it is currently used for: warning for unused
    ## pure functions. See the upstream file for the whole discussion.
    puPure
      ## The function is in pure Gleam, and does not reference any language
      ## feature that can cause side effects, such as `panic`, `assert` or `echo`.
      ## It also does not call any impure functions.
    puTrustedPure
      ## This function is part of the standard library, or an otherwise trusted
      ## source, and though it might use FFI, we can trust that the FFI function
      ## will not cause any side effects.
    puImpure
      ## This function is impure because it either uses FFI, panics, uses `echo`,
      ## or calls another impure function.
    puUnknown
      ## We don't know the purity of this function.

func supportingAll*(_: typedesc[Implementations]): Implementations =
  Implementations(
    gleam: true,
    canRunOnErlang: true,
    canRunOnJavascript: true,
    usesJavascriptExternals: false,
    usesErlangExternals: false,
  )

func isPure*(self: Purity): bool =
  case self
  of puPure, puTrustedPure: true
  of puImpure, puUnknown: false

func merge*(self, other: Purity): Purity =
  case self
  of puPure:
    # If we call a trusted pure function, the current function remains pure
    if other == puTrustedPure: puPure else: other
  of puTrustedPure:
    # If we call a pure function, the current function remains trusted pure
    if other == puPure: puTrustedPure else: other
  of puImpure:
    # Nothing can make an already impure function pure again
    puImpure
  of puUnknown:
    # If we call an impure function from a function we don't know the
    # purity of, we are now certain that it is impure.
    puImpure
