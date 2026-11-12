pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
}

pub fn width(shape: Shape) -> Float {
  shape.width
}
