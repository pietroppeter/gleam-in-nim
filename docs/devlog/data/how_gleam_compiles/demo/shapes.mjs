import { CustomType as $CustomType } from "./gleam.mjs";

export class Circle extends $CustomType {
  constructor(radius) {
    super();
    this.radius = radius;
  }
}
export const Shape$Circle = (radius) => new Circle(radius);
export const Shape$isCircle = (value) => value instanceof Circle;
export const Shape$Circle$radius = (value) => value.radius;
export const Shape$Circle$0 = (value) => value.radius;

export class Rectangle extends $CustomType {
  constructor(width, height) {
    super();
    this.width = width;
    this.height = height;
  }
}
export const Shape$Rectangle = (width, height) => new Rectangle(width, height);
export const Shape$isRectangle = (value) => value instanceof Rectangle;
export const Shape$Rectangle$width = (value) => value.width;
export const Shape$Rectangle$0 = (value) => value.width;
export const Shape$Rectangle$height = (value) => value.height;
export const Shape$Rectangle$1 = (value) => value.height;

export function area(shape) {
  if (shape instanceof Circle) {
    let radius = shape.radius;
    return (3.14 * radius) * radius;
  } else {
    let width = shape.width;
    let height = shape.height;
    return width * height;
  }
}
