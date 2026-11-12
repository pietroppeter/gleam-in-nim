import gleam/list

pub fn main() {
  list.mapp([1, 2], fn(x) { x })
}
