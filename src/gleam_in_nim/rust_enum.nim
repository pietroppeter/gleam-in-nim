# SPDX-License-Identifier: Apache-2.0

## How a Rust enum with data, and a `Box`, are written in this port.
## Not a port of an upstream file: it is the support for a rule of the porting
## guide (decision 0010).
##
## A Rust enum whose variants carry data is a Nim object with a `kind` and one
## field per variant:
##
## ```rust
## pub enum AssignName { Variable(EcoString), Discard(EcoString) }
## pub enum TodoKind { Keyword, EmptyFunction { function_location: SrcSpan } }
## ```
##
## ```nim
## AssignName* = object
##   case kind*: AssignNameKind
##   of anVariable: vVariable*: string
##   of anDiscard: vDiscard*: string
##
## TodoKindEmptyFunction* = object of StructVariant
##   functionLocation*: SrcSpan
## TodoKind* = object
##   case kind*: TodoKindKind
##   of tkKeyword: discard
##   of tkEmptyFunction: vEmptyFunction*: TodoKindEmptyFunction
## ```
##
## - The values of the `kind` enum are a short prefix and the Rust variant's
##   name. The field of a variant is `v` and the variant's name: never a
##   keyword, never the same name in two branches (which Nim forbids).
## - A tuple variant (`Variable(EcoString)`) holds its value directly.
## - A struct variant (`EmptyFunction { .. }`) holds an object with the fields,
##   in upstream order, named after the enum and the variant. That object
##   inherits from `StructVariant`, so generic code (the printer that writes a
##   tree the way Rust's `{:#?}` does) can tell `Int { .. }` from
##   `Function(Function { .. })`.

type
  StructVariant* {.inheritable, pure.} = object
    ## The marker of the object that holds the fields of a struct variant.

  Unit* = object
    ## Rust's `()`: the type of the `type_` fields of a tree that has no types
    ## yet.

func box*[T](value: sink T): ref T =
  ## Rust's `Box::new`. A `Box<T>` is a `ref T` here.
  new result
  result[] = value
