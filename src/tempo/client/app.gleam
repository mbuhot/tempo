//// Target: JS only — Lustre SPA: model/update/view, the time slider, and both views. Imports shared/* only (never server/*).

import lustre/element.{type Element}
import lustre/element/html
import tempo/shared/types.{type AsOf, type BoardSnapshot}

/// Lustre model: the selected instant and the board rendered as of it.
pub type Model {
  Model(as_of: AsOf, board: BoardSnapshot)
}

/// Client entrypoint: start the Lustre application.
pub fn main() -> Nil {
  todo as "P2: register and start the Lustre application"
}

/// Render the current model (org board / timesheet behind the shared time slider).
pub fn view(_model: Model) -> Element(message) {
  html.text("")
}
