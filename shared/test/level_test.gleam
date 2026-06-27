//// The shared level pill: the band label, the swatch colour token, and the
//// data-table cell — the single source the People roster and Settings render from.

import gleam/option.{None}
import shared/level
import shared/table/cell.{EntityCell}

pub fn band_names_each_level_test() {
  assert level.band(1) == "L1 · Associate"
  assert level.band(5) == "L5 · Principal"
  assert level.band(7) == "L7 · Fellow"
}

pub fn cell_is_a_gradient_entity_pill_test() {
  assert level.cell(5)
    == EntityCell(label: "L5 · Principal", sub: None, color: "var(--lvl-5)")
}
