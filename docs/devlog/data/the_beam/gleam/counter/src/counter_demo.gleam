import counter
import gleam/erlang/process
import gleam/int
import gleam/io

pub fn main() -> Nil {
  let assert Ok(c) = counter.start()
  process.send(c, counter.Increment(by: 2))
  process.send(c, counter.Increment(by: 40))
  let n = process.call(c, waiting: 100, sending: counter.Get)
  io.println("counter says: " <> int.to_string(n))
  process.send(c, counter.Stop)
}
