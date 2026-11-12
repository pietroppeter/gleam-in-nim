## port-part-of: compiler-core/src/type_/fields.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/type_/fields.rs.

## Only the `FieldMap` type is ported so far: the syntax tree needs it.

import std/tables

type FieldMap* = object
  arity*: int ## Number of accepted arguments, including unlabelled fields.
  fields*: Table[string, int] ## Map of labels to argument indices
