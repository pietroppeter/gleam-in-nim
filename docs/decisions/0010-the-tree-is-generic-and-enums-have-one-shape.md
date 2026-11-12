---
title: The syntax tree is generic like upstream's, and every enum with data has one shape
status: accepted
date: 2026-11-12
---

## Context

Upstream has one syntax tree in two states. The parser builds `Pattern<()>`,
`Statement<(), UntypedExpr>`, `Definition<(), UntypedExpr, ()>`; the type checker rebuilds it as
`Pattern<Arc<Type>>`, `Statement<Arc<Type>, TypedExpr>`. Only the expressions are two separate
enums (`UntypedExpr`, `TypedExpr`). The untyped tree therefore carries fields that only the type
checker fills (`type_: ()`, `constructor: Unknown`, `compiled_case`), and upstream's parser tests
are snapshots of that tree printed with Rust's `{:#?}`, those fields included.

The port could have kept this, or written one non-generic tree with optional types, or two
separate trees. And however the tree is cut, it is made of Rust enums with data, about twenty of
them, which Nim writes as objects with a `case`. Nim forbids the same field name in two branches
of a `case`, and almost every variant upstream has a `location`.

## Decision

- **Generic, as upstream.** `Pattern[T]`, `Statement[T, Expr]`, `Definition[T, Expr,
  PackageName]`, `Constant[T]`, with the upstream aliases (`UntypedPattern = Pattern[Unit]`).
  `Unit` is an empty object and stands for `()`. A prototype showed that Nim accepts the
  mutually recursive generic variants this needs.
- **One file per upstream file, one module for the three of the tree.** `ast.nim` includes
  `ast/constant.nim` and `ast/untyped.nim` at the point where the types they need exist.
  Upstream's submodules start with `use super::*` and are re-exported by `ast.rs`: the three
  files are one namespace there too. In `ast.nim` the types come first and the functions after,
  each in upstream order, because Nim wants types that mention each other in one section.
- **Every enum with data has one shape**, described in `src/gleam_in_nim/rust_enum.nim`: an
  object with `kind` (an enum whose values are a short prefix plus the Rust variant name) and
  exactly one field per variant that has data, named `v` plus the variant name. A tuple variant
  holds its value. A struct variant holds an object with its fields in upstream order, named
  after the enum and the variant, which inherits from the marker `StructVariant`.
  `UntypedExpr::Int { location, value, int_value }` is `kind: ueInt`, `vInt: UntypedExprInt`.
- **Field names are upstream's in camelCase.** The exceptions are in one table, `fieldRenames`
  in `ast.nim` (`typ`, `returns`, `stop`, `tupl`).
- **`Box<T>` in the tree is `ref T`**, built with `box(x)`; the nodes themselves are values.
  `u32` and `usize` positions are `int`, as `SrcSpan` already was.
- **No `==` on the tree for now.** Nim does not derive it for objects with a `case`. Trees are
  compared by their Rust-style debug text, which is also what the snapshots hold.
- **Types of modules not ported yet** that the tree mentions get a file at their upstream path
  with a `port-part-of` header: real when small (`Inferred`, `Target`, `Deprecation`,
  `VariableOrigin`, `Implementations`, `Purity`, `FieldMap`, `LabelSyntax`), a placeholder with
  no fields when they belong to the type checker and the parser never fills them
  (`ValueConstructor`, `PatternConstructor`, `Variable`, and `Decision` beyond `Fail`).

## Consequences

- The Nim reads next to the Rust, type by type and field by field, and a generic printer can
  write any tree the way `{:#?}` does without code per type. That is what lets the parser be
  checked against upstream's snapshots and against the reference parser.
- Access is one step longer than a flat object: `expr.vInt.value`, `definition.vFunction.body`.
  In exchange no field was renamed to dodge a clash, and a `case expr.kind` reads like a `match`.
- The typed tree can reuse every generic type. Two problems wait for that step. Upstream's
  `ast` and `type_` modules use each other's types (`Constant` holds a `ValueConstructor`, which
  holds a `TypedConstant`), and Nim modules cannot import in a cycle: the placeholders in
  `typ.nim` will have to become real types in a place both can see. And the tree is made of
  values, so assigning a subtree copies it: where upstream moves or shares (`Arc`), the port must
  take care not to copy in a loop.
- Three payload names are not enum plus variant: `PatternConstructorFields` (the plain name is a
  type of `type_.rs`), and `BitArrayOptionLocation`, shared by the fifteen options that are only
  a location. Code that needs to know a payload is a struct variant asks `is StructVariant`.
