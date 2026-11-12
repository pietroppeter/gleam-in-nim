//// A counter as an actor: one process, one mailbox, one piece of state.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type Message {
  Increment(by: Int)
  Get(reply_to: Subject(Int))
  Stop
}

fn handle(count: Int, message: Message) -> actor.Next(Int, Message) {
  case message {
    Increment(by:) -> actor.continue(count + by)
    Get(reply_to:) -> {
      process.send(reply_to, count)
      actor.continue(count)
    }
    Stop -> actor.stop()
  }
}

pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new(0)
  |> actor.on_message(handle)
  |> actor.start
  |> result_map_data
}

fn result_map_data(
  r: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Subject(Message), actor.StartError) {
  case r {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}
