fn id(x) { x }

pub fn main() {
  #(id(1), id("one"))
}
