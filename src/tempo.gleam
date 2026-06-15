//// Target: Erlang only — server entrypoint (`gleam run`); boots the Wisp server with the pog pool.

import gleam/io

pub fn main() -> Nil {
  io.println("Hello from tempo!")
}
