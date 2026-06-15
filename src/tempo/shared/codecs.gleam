//// Target: both (Erlang + JS) — gleam/json encoders and gleam/dynamic/decode decoders for the shared API types.

import gleam/json
import tempo/shared/types.{type BoardSnapshot}

/// Encode a board snapshot to JSON for the HTTP API.
pub fn encode_board_snapshot(_snapshot: BoardSnapshot) -> json.Json {
  todo as "P1: encode BoardSnapshot to json"
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Nil {
  todo as "P1: gleam/dynamic/decode decoder for BoardSnapshot"
}
