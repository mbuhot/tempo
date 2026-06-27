import gleam/int
import gleam/option.{None}
import shared/table/cell.{type Cell, EntityCell}

/// The level's band label, e.g. "L5 · Principal". The one definition of the band names.
pub fn band(level: Int) -> String {
  let name = case level {
    1 -> "Associate"
    2 -> "Engineer"
    3 -> "Senior"
    4 -> "Staff"
    5 -> "Principal"
    6 -> "Distinguished"
    7 -> "Fellow"
    _ -> "Engineer"
  }
  "L" <> int.to_string(level) <> " · " <> name
}

/// The level's swatch colour token (the sequential ramp lives in theme.css).
pub fn color(level: Int) -> String {
  "var(--lvl-" <> int.to_string(level) <> ")"
}

/// The level rendered as a data-table cell: a gradient swatch + the band label.
/// THE single definition of a level pill in the generic table.
pub fn cell(level: Int) -> Cell {
  EntityCell(label: band(level), sub: None, color: color(level))
}
