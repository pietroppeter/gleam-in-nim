import * as $int from "../gleam_stdlib/gleam/int.mjs";
import * as $list from "../gleam_stdlib/gleam/list.mjs";
import * as $result from "../gleam_stdlib/gleam/result.mjs";
import {
  Ok,
  Error,
  Empty as $Empty,
  List$Empty$const as $List$Empty$const,
  prepend as listPrepend,
  CustomType as $CustomType,
  makeError,
  divideInt,
  bitArraySlice,
} from "./gleam.mjs";

const FILEPATH = "src/shapes.gleam";

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

export class Dot extends $CustomType {}
export const Shape$Dot$const = new Dot();
export const Shape$Dot = () => Shape$Dot$const;
export const Shape$isDot = (value) => value instanceof Dot;

export class UnknownShape extends $CustomType {
  constructor(name) {
    super();
    this.name = name;
  }
}
export const ParseError$UnknownShape = (name) => new UnknownShape(name);
export const ParseError$isUnknownShape = (value) =>
  value instanceof UnknownShape;
export const ParseError$UnknownShape$name = (value) => value.name;
export const ParseError$UnknownShape$0 = (value) => value.name;

export class BadNumber extends $CustomType {}
export const ParseError$BadNumber$const = new BadNumber();
export const ParseError$BadNumber = () => ParseError$BadNumber$const;
export const ParseError$isBadNumber = (value) => value instanceof BadNumber;

export const pi = 3.14159;

/**
 * Area of a shape. Pattern matching on a custom type.
 */
export function area(shape) {
  if (shape instanceof Circle) {
    let r = shape.radius;
    return (pi * r) * r;
  } else if (shape instanceof Rectangle) {
    let w = shape.width;
    let h = shape.height;
    return w * h;
  } else {
    return 0.0;
  }
}

export function describe(shape) {
  if (shape instanceof Circle) {
    return "circle";
  } else if (shape instanceof Rectangle) {
    let w = shape.width;
    let h = shape.height;
    if (w === h) {
      return "square";
    } else {
      return "rectangle";
    }
  } else {
    return "dot";
  }
}

export function widen(shape, by) {
  if (shape instanceof Rectangle) {
    let r = shape;
    return new Rectangle(r.width + by, r.height);
  } else {
    return shape;
  }
}

export function parse(name, size) {
  return $result.try$(
    (() => {
      let _pipe = $int.parse(size);
      return $result.replace_error(_pipe, ParseError$BadNumber$const);
    })(),
    (n) => {
      let size$1 = $int.to_float(n);
      if (name === "circle") {
        return new Ok(new Circle(size$1));
      } else if (name === "square") {
        return new Ok(new Rectangle(size$1, size$1));
      } else if (name === "dot") {
        return new Ok(Shape$Dot$const);
      } else {
        return new Error(new UnknownShape(name));
      }
    },
  );
}

function sum(loop$numbers, loop$acc) {
  while (true) {
    let numbers = loop$numbers;
    let acc = loop$acc;
    if (numbers instanceof $Empty) {
      return acc;
    } else {
      let first = numbers.head;
      let rest = numbers.tail;
      loop$numbers = rest;
      loop$acc = acc + first;
    }
  }
}

export function total_area(shapes) {
  let _pipe = shapes;
  let _pipe$1 = $list.map(_pipe, area);
  return sum(_pipe$1, 0.0);
}

export function greeting(name) {
  let $ = listPrepend(name + "!", listPrepend("unused", $List$Empty$const));
  let first;
  if ($ instanceof $Empty) {
    throw makeError(
      "let_assert",
      FILEPATH,
      "shapes",
      70,
      "greeting",
      "Pattern match failed, no pattern matched the value.",
      {
        value: $,
        start: 1485,
        end: 1533,
        pattern_start: 1496,
        pattern_end: 1507
      }
    )
  } else {
    first = $.head;
  }
  return "Hello, " + first;
}

export function make_adder(n) {
  return (x) => { return x + n; };
}

export function safe_divide(a, b) {
  return divideInt(a, b);
}

export function header(bytes) {
  if (bytes.bitSize >= 8 && bytes.bitSize % 8 === 0) {
    let version = bytes.byteAt(0);
    let rest = bitArraySlice(bytes, 8);
    return new Ok([version, rest]);
  } else {
    return new Error(undefined);
  }
}

export function not_yet() {
  throw makeError("todo", FILEPATH, "shapes", 90, "not_yet", "write me", {})
}
