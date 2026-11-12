import clock
import gleam/float
import gleam/int
import gleam/io
import shapes.{Circle, Dot, Rectangle}

pub fn main() -> Nil {
  let shapes = [Circle(1.0), Rectangle(2.0, 3.0), Dot]
  io.println("total area: " <> float.to_string(shapes.total_area(shapes)))
  io.println(shapes.greeting("BEAM"))
  let _ = echo shapes.parse("square", "4")
  let _ = echo shapes.parse("hexagon", "4")
  let _ = echo shapes.header(<<1, 2, 3>>)
  io.println("7 / 0 = " <> int.to_string(shapes.safe_divide(7, 0)))
  io.println("add 2 to 40: " <> int.to_string(shapes.make_adder(2)(40)))
  case clock.now() > 0 {
    True -> io.println("the clock is ticking")
    False -> io.println("time stands still")
  }
}
