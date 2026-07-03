//// A thin wrapper over the browser `localStorage`, for per-user, per-device UI
//// preferences (the data table's column order and visibility). `get` reads
//// synchronously for a page's `init`; `set` is a fire-and-forget effect. A missing
//// key reads back as `None`.

import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}

/// Read the value stored under `key`, or `None` when absent (or when storage is
/// unavailable).
pub fn get(key: String) -> Option(String) {
  case read(key) {
    "" -> None
    value -> Some(value)
  }
}

/// Persist `value` under `key`. Best-effort: a storage failure is swallowed so a
/// preference write can never break the app.
pub fn set(key: String, value: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { write(key, value) })
}

@external(javascript, "./storage_ffi.mjs", "read")
fn read(_key: String) -> String {
  panic as "JavaScript only"
}

@external(javascript, "./storage_ffi.mjs", "write")
fn write(_key: String, _value: String) -> Nil {
  panic as "JavaScript only"
}
