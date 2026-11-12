## port-part-of: compiler-core/src/type_.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2018 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/type_.rs.

## The types of the type checker.
##
## Upstream `type_.rs` and `ast.rs` use each other's types. Here this module
## imports `ast` and exports it, and the types that both need are defined on
## the tree's side (decision 0011): `Type`, `TypeVar`, `PatternConstructor`
## and `Deprecation` in `typ/in_tree.nim`, `ValueConstructor` and
## `ValueConstructorVariant` in `ast/constant.nim`, `ModuleValueConstructor`
## in `ast/typed.nim`. So `import typ` gives everything `type_.rs` has.
##
## Ported so far: what upstream implements for `Deprecation`. The few
## functions of `type_.rs` that the tree's own functions call are in
## `typ/in_tree_functions.nim`; the rest of the file comes with the `types`
## step.

import std/hashes
import ./ast

export ast

func isDeprecated*(self: Deprecation): bool =
  ## Returns `true` if the deprecation is `Deprecated`.
  self.kind == dpDeprecated

func `==`*(a, b: Deprecation): bool =
  a.kind == b.kind and (a.kind == dpNotDeprecated or a.vDeprecated == b.vDeprecated)

func hash*(self: Deprecation): Hash =
  case self.kind
  of dpNotDeprecated: hash(0)
  of dpDeprecated: hash(self.vDeprecated.message)
