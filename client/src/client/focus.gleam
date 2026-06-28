//// Modal focus management (FFI over the DOM): trap keyboard focus inside the open
//// modal so Tab can't reach the page behind it, and restore focus when it closes. A
//// host raises `trap` when it opens a modal and `release` when it closes.

import lustre/effect.{type Effect}

/// Trap focus within the element matched by `selector` (the open modal). Focuses it
/// so the first Tab moves into its fields, and cycles Tab at the ends.
pub fn trap(selector: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { do_trap(selector) })
}

/// Release the active trap and return focus to where it was before the modal opened.
pub fn release() -> Effect(msg) {
  effect.from(fn(_dispatch) { do_release() })
}

@external(javascript, "./focus_ffi.mjs", "trapFocus")
fn do_trap(_selector: String) -> Nil {
  panic as "JavaScript only"
}

@external(javascript, "./focus_ffi.mjs", "releaseFocus")
fn do_release() -> Nil {
  panic as "JavaScript only"
}
