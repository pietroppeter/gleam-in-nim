## port-part-of: compiler-core/src/reference.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/reference.rs.

## Only `LabelSyntax` is ported so far: the syntax tree needs it.

type LabelSyntax* = enum
  ## The syntax used to write a record field label where it is used.
  lsLonghand
    ## The label is written out on its own, as in `Wibble(label: value)` or
    ## `record.label`, so renaming it is a simple replacement.
  lsShorthand
    ## The label shorthand syntax (`label:`), which stands for both the label
    ## and a variable with the same name. Renaming the field then has to
    ## expand it so the value keeps its name: `wibble:` becomes
    ## `wobble: wibble`.
