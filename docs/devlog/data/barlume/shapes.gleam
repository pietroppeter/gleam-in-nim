type Shape {
  Circle(Int)
  Rectangle(Int, Int)
}

fn area(shape) {
  case shape {
    Circle(r) -> 3 * r * r
    Rectangle(w, h) -> w * h
  }
}

pub fn main() {
  // two shapes, one number
  let total = area(Circle(2)) + area(Rectangle(3, 4))
  total
}
