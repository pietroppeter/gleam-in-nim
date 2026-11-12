## port-part-of: compiler-core/src/type_/printer.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/type_/printer.rs.

## Only the fields of `Names` are ported so far: every module of the syntax
## tree carries one, empty until the type checker fills it. The two `BiMap`s
## of upstream are plain tables here until the printer is ported.

import std/tables
import ../src_span

type Names* = object
  ## This class keeps track of what names are used for modules in the current
  ## scope, so they can be printed in errors, etc.
  localTypes*: Table[(string, string), string]
    ## key: (Defining module name, type name), value: Alias name
  importedModules*: Table[string, (string, SrcSpan)]
  typeVariables*: Table[uint64, string]
  localValueConstructors*: Table[(string, string), string]
    ## key: (Defining module name, type name), value: Alias name
  reexportAliases*: Table[(string, string), (string, string)]

func initNames*(): Names =
  ## Upstream `Names::new`.
  Names()
