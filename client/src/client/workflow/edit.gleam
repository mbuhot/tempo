//// The wizard's in-progress raw edit state for the current step: one entry per
//// field, holding the text the user is typing (a scalar) or the per-row cells of
//// a repeating group. Raw `String` leaves mirror what an input control shows,
//// including not-yet-valid entries; `value.parse` lifts them to typed values on
//// commit and `value.to_input` seeds them back from saved values.

import gleam/dict.{type Dict}
import gleam/list
import shared/workflow/value.{type FieldValue, RowsValue}

/// A field's raw working state: a scalar's text, or a group's per-row raw cells
/// (positionally aligned with the saved `RowsValue`).
pub type EditValue {
  Scalar(String)
  Rows(List(Dict(String, String)))
}

/// Build the current step's raw working document from its saved typed values.
pub fn seed(step_values: Dict(String, FieldValue)) -> Dict(String, EditValue) {
  dict.map_values(step_values, fn(_field, field_value) {
    case field_value {
      RowsValue(saved_rows) ->
        Rows(
          list.map(saved_rows, fn(row) {
            dict.map_values(row, fn(_key, cell) { value.to_input(cell) })
          }),
        )
      scalar_value -> Scalar(value.to_input(scalar_value))
    }
  })
}

/// The raw text shown for a scalar field, or "" when untouched or unset.
pub fn scalar(edits: Dict(String, EditValue), field: String) -> String {
  case dict.get(edits, field) {
    Ok(Scalar(raw)) -> raw
    Ok(Rows(_)) -> ""
    Error(_) -> ""
  }
}

/// Buffer a scalar keystroke.
pub fn set_scalar(
  edits: Dict(String, EditValue),
  field: String,
  raw: String,
) -> Dict(String, EditValue) {
  dict.insert(edits, field, Scalar(raw))
}

/// The raw rows shown for a group field, or [] when none.
pub fn rows(
  edits: Dict(String, EditValue),
  field: String,
) -> List(Dict(String, String)) {
  case dict.get(edits, field) {
    Ok(Rows(group_rows)) -> group_rows
    Ok(Scalar(_)) -> []
    Error(_) -> []
  }
}

/// Buffer a group-cell keystroke at `index`.
pub fn set_cell(
  edits: Dict(String, EditValue),
  field: String,
  index: Int,
  item_key: String,
  raw: String,
) -> Dict(String, EditValue) {
  let updated =
    list.index_map(rows(edits, field), fn(row, row_index) {
      case row_index == index {
        True -> dict.insert(row, item_key, raw)
        False -> row
      }
    })
  dict.insert(edits, field, Rows(updated))
}

/// Append an empty row to a group field.
pub fn add_row(
  edits: Dict(String, EditValue),
  field: String,
) -> Dict(String, EditValue) {
  dict.insert(edits, field, Rows(list.append(rows(edits, field), [dict.new()])))
}

/// Drop the row at `index`, shifting later rows down.
pub fn remove_row(
  edits: Dict(String, EditValue),
  field: String,
  index: Int,
) -> Dict(String, EditValue) {
  let kept =
    rows(edits, field)
    |> list.index_map(fn(row, row_index) { #(row_index, row) })
    |> list.filter(fn(pair) { pair.0 != index })
    |> list.map(fn(pair) { pair.1 })
  dict.insert(edits, field, Rows(kept))
}
