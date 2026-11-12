pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
  Dot
}

pub fn name(shape: Shape) -> String {
  case shape {
    Circle(..) -> "circle"
  }
}
