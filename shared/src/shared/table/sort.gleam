//// A table's active (or default) sort: the column key and direction.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type SortDir {
  Asc
  Desc
}

pub type Sort {
  Sort(key: String, dir: SortDir)
}

pub fn dir_to_string(dir: SortDir) -> String {
  case dir {
    Asc -> "asc"
    Desc -> "desc"
  }
}

pub fn dir_from_string(text: String) -> Result(SortDir, Nil) {
  case text {
    "asc" -> Ok(Asc)
    "desc" -> Ok(Desc)
    _ -> Error(Nil)
  }
}

pub fn encode_sort(value: Sort) -> Json {
  json.object([
    #("key", json.string(value.key)),
    #("dir", json.string(dir_to_string(value.dir))),
  ])
}

pub fn sort_decoder() -> Decoder(Sort) {
  use key <- decode.field("key", decode.string)
  use dir_text <- decode.field("dir", decode.string)
  let dir = case dir_from_string(dir_text) {
    Ok(value) -> value
    Error(Nil) -> Asc
  }
  decode.success(Sort(key:, dir:))
}
