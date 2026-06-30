import client/workflow/edit
import gleam/dict
import shared/workflow/value.{IntValue, RowsValue, TextValue}

pub fn seed_renders_scalars_as_input_strings_test() {
  let saved =
    dict.from_list([#("full_name", TextValue("Ada")), #("level", IntValue(5))])
  let edits = edit.seed(saved)
  assert edit.scalar(edits, "full_name") == "Ada"
  assert edit.scalar(edits, "level") == "5"
}

pub fn seed_renders_group_rows_as_input_strings_test() {
  let team =
    RowsValue([
      dict.from_list([#("role", TextValue("Eng")), #("count", IntValue(2))]),
    ])
  let edits = edit.seed(dict.from_list([#("team", team)]))
  assert edit.rows(edits, "team")
    == [dict.from_list([#("role", "Eng"), #("count", "2")])]
}

pub fn set_scalar_buffers_raw_text_test() {
  let edits = edit.set_scalar(dict.new(), "level", "12a")
  assert edit.scalar(edits, "level") == "12a"
}

pub fn set_cell_updates_one_row_cell_test() {
  let edits =
    edit.seed(
      dict.from_list([
        #("team", RowsValue([dict.from_list([#("role", TextValue("Eng"))])])),
      ]),
    )
  let edits = edit.set_cell(edits, "team", 0, "role", "Engineering")
  assert edit.rows(edits, "team")
    == [dict.from_list([#("role", "Engineering")])]
}

pub fn add_row_appends_an_empty_row_test() {
  let edits = edit.add_row(dict.new(), "team")
  assert edit.rows(edits, "team") == [dict.new()]
}

pub fn remove_row_drops_and_shifts_later_rows_test() {
  let edits =
    dict.new()
    |> edit.add_row("team")
    |> edit.add_row("team")
    |> edit.set_cell("team", 0, "role", "first")
    |> edit.set_cell("team", 1, "role", "second")
  let edits = edit.remove_row(edits, "team", 0)
  assert edit.rows(edits, "team") == [dict.from_list([#("role", "second")])]
}
