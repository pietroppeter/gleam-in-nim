pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
}

pub fn area(shape: Shape) -> Float {
  case shape {
    Circle(radius:) -> 3.14 *. radius *. radius
    Rectangle(width:, height:) -> width *. height
  }
}
