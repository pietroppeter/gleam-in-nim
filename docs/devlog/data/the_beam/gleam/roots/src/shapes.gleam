//// A tiny module that touches most of what the code generator has to handle.

import gleam/int
import gleam/list
import gleam/result

pub const pi = 3.14159

pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
  Dot
}

pub type ParseError {
  UnknownShape(name: String)
  BadNumber
}

/// Area of a shape. Pattern matching on a custom type.
pub fn area(shape: Shape) -> Float {
  case shape {
    Circle(radius: r) -> pi *. r *. r
    Rectangle(width: w, height: h) -> w *. h
    Dot -> 0.0
  }
}

pub fn describe(shape: Shape) -> String {
  case shape {
    Circle(..) -> "circle"
    Rectangle(width: w, height: h) if w == h -> "square"
    Rectangle(..) -> "rectangle"
    Dot -> "dot"
  }
}

pub fn widen(shape: Shape, by: Float) -> Shape {
  case shape {
    Rectangle(..) as r -> Rectangle(..r, width: r.width +. by)
    other -> other
  }
}

pub fn parse(name: String, size: String) -> Result(Shape, ParseError) {
  use n <- result.try(int.parse(size) |> result.replace_error(BadNumber))
  let size = int.to_float(n)
  case name {
    "circle" -> Ok(Circle(size))
    "square" -> Ok(Rectangle(size, size))
    "dot" -> Ok(Dot)
    _ -> Error(UnknownShape(name))
  }
}

pub fn total_area(shapes: List(Shape)) -> Float {
  shapes
  |> list.map(area)
  |> sum(0.0)
}

fn sum(numbers: List(Float), acc: Float) -> Float {
  case numbers {
    [] -> acc
    [first, ..rest] -> sum(rest, acc +. first)
  }
}

pub fn greeting(name: String) -> String {
  let assert [first, ..] = [name <> "!", "unused"]
  "Hello, " <> first
}

pub fn make_adder(n: Int) -> fn(Int) -> Int {
  fn(x) { x + n }
}

pub fn safe_divide(a: Int, b: Int) -> Int {
  a / b
}

pub fn header(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<version:8, rest:bytes>> -> Ok(#(version, rest))
    _ -> Error(Nil)
  }
}

pub fn not_yet() -> Int {
  todo as "write me"
}
