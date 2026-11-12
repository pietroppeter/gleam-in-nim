## port-part-of: compiler-core/src/type_.rs
## (the types of `type_.rs` that the syntax tree is made of; data only, no functions)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2018 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/type_.rs.

## The types of the type checker that the syntax tree holds: `Type`,
## `TypeVar`, `PatternConstructor`, `Deprecation`.
##
## Upstream, `ast.rs` uses the types of `type_.rs` and `type_.rs` uses the
## types of `ast.rs`. Nim modules cannot import each other, so these types are
## in this file, which `ast.nim` includes (it is not a module of its own):
## import `ast`, or `typ`, to use them (decision 0011).
##
## Three more types of `type_.rs` are in the tree's own files, because they
## hold a piece of the tree: `ValueConstructor` and `ValueConstructorVariant`
## in `ast/constant.nim`, `ModuleValueConstructor` in `ast/typed.nim`.
##
## How this differs from the Rust:
##
## - `Arc<Type>` is `Type`: a `ref object`. A type is shared, never copied.
## - `Arc<RefCell<TypeVar>>` is `TypeVar`: a `ref` too, and the one thing in
##   the tree that changes after it is built. Unification links a variable by
##   assigning the whole object: `v[] = TypeVarObj(kind: tvLink, ...)`.
## - There is no `==` here. On a `ref`, Nim's `==` asks whether two values are
##   the same object, which is not upstream's derived `PartialEq`. The
##   comparisons upstream uses (`same_as` and friends) come with `typ.nim`.
## - `u16` is `int`.
## - The fields of `Type::Var` are `TypeVarFields`, because `TypeVar` is taken.

type
  DeprecationKind* = enum
    dpNotDeprecated
    dpDeprecated

  DeprecationDeprecated* = object of StructVariant
    message*: string

  Deprecation* = object
    ## `dpNotDeprecated` is the default, as upstream.
    case kind*: DeprecationKind
    of dpNotDeprecated:
      discard
    of dpDeprecated:
      vDeprecated*: DeprecationDeprecated

  TypeKind* = enum
    tpNamed
      ## A nominal (named) type such as `Int`, `Float`, or a programmer defined
      ## custom type such as `Person`. The type can take other types as
      ## arguments (aka "generics" or "parametric polymorphism").
      ##
      ## If the type is defined in the Gleam prelude the `module` field will be
      ## the string "gleam", otherwise it will contain the name of the module
      ## that defines the type.
    tpFn ## The type of a function. It takes arguments and returns a value.
    tpVar
      ## A type variable. See the contained `TypeVar` enum for more information.
    tpTuple
      ## A tuple is an ordered collection of 0 or more values, each of which
      ## can have a different type, so the `tuple` type is the sum of all the
      ## contained types.

  TypeNamed* = object of StructVariant
    publicity*: Publicity
    package*: string
    module*: string
    name*: string
    arguments*: seq[Type]
    inferredVariant*: Option[int]
      ## Which variant of the types this value is, if it is known from variant inference.
      ## This allows us to permit certain operations when we know this,
      ## such as record updates for multi-constructor types, or field access
      ## for fields not shared between type variants. For example:
      ##
      ## ```gleam
      ## type Wibble {
      ##   Wibble(wibble: Int, other, Int)
      ##   Wobble(wobble: Int, something: Int)
      ## }
      ##
      ## fn add_one(some_wibble: Wibble) -> Wibble {
      ##   case some_wibble {
      ##     Wibble(..) as wibble -> Wibble(..wibble, other: wibble.other + 1)
      ##     Wobble(..) as wobble -> Wobble(..wobble, something: wobble.something + 1)
      ##   }
      ## }
      ## ```
      ##
      ## Here, the `wibble` variable has an inferred variant of `0`, since we know it's
      ## of the `Wibble` variant. This means we can safely update it using the `Wibble`
      ## constructor, and access the `other` field, which is only present in that variant.
      ##
      ## However, the parameter `some_wibble` has no known variant; it could be either of the variants,
      ## so we can't allow any of that until we pattern match on it.

  TypeFn* = object of StructVariant
    arguments*: seq[Type]
    returns*: Type

  TypeVarFields* = object of StructVariant
    ## The fields of `Type::Var`. Not `TypeVar`: that is the variable itself.
    typ*: TypeVar

  TypeTuple* = object of StructVariant
    elements*: seq[Type]

  TypeObj* = object
    case kind*: TypeKind
    of tpNamed: vNamed*: TypeNamed
    of tpFn: vFn*: TypeFn
    of tpVar: vVar*: TypeVarFields
    of tpTuple: vTuple*: TypeTuple

  Type* = ref TypeObj ## Upstream's `Arc<Type>`.

  TypeVarKind* = enum
    tvUnbound
      ## Unbound is an unbound variable. It is one specific type but we don't
      ## know what yet in the inference process. It has a unique id which can be used to
      ## identify if two unbound variable Rust values are the same Gleam type variable
      ## instance or not.
    tvLink
      ## Link is type variable where it was an unbound variable but we worked out
      ## that it is some other type and now we point to that one.
    tvGeneric
      ## A Generic variable stands in for any possible type and cannot be
      ## specialised to any one type
      ##
      ## # Example
      ##
      ## ```gleam
      ## type Cat(a) {
      ##   Cat(name: a)
      ## }
      ## // a is TypeVar::Generic
      ## ```

  TypeVarUnbound* = object of StructVariant
    id*: uint64

  TypeVarLink* = object of StructVariant
    typ*: Type

  TypeVarGeneric* = object of StructVariant
    id*: uint64

  TypeVarObj* = object
    case kind*: TypeVarKind
    of tvUnbound: vUnbound*: TypeVarUnbound
    of tvLink: vLink*: TypeVarLink
    of tvGeneric: vGeneric*: TypeVarGeneric

  TypeVar* = ref TypeVarObj ## Upstream's `Arc<RefCell<TypeVar>>`.

  PatternConstructor* = object
    name*: string
    fieldMap*: Option[FieldMap]
    documentation*: Option[string]
    module*: string
    location*: SrcSpan
    constructorIndex*: int
