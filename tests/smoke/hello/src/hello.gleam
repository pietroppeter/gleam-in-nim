//// The smoke test of tools/smoke.sh: a program with no dependencies whose result
//// touches custom types, pattern matching, recursion, strings and bit arrays.

pub type Shape {
  Circle(radius: Int)
  Rectangle(width: Int, height: Int)
}

pub fn area(shape: Shape) -> Int {
  case shape {
    Circle(radius:) -> 3 * radius * radius
    Rectangle(width:, height:) -> width * height
  }
}

fn sum(shapes: List(Shape), total: Int) -> Int {
  case shapes {
    [] -> total
    [first, ..rest] -> sum(rest, total + area(first))
  }
}

pub fn main() -> #(String, Int, BitArray) {
  let shapes = [Circle(2), Rectangle(3, 4), Circle(1)]
  #("hello from " <> "gleam", sum(shapes, 0), <<"ok":utf8, 255>>)
}
