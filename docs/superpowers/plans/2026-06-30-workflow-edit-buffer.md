# Workflow Edit Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix repeating-group keystroke loss (#34) by replacing the flat scalar-only edit buffer with one raw working document per step, and aligning undo/redo to the per-step document the server persists.

**Architecture:** A new pure module `client/src/client/workflow/edit.gleam` holds the in-progress raw edit state — `EditValue { Scalar(String) | Rows(List(Dict(String, String))) }` — and all transitions over it (seed, read, keystroke, row add/remove). `wizard.gleam` keeps that document in its Model (retyping the existing `edits` field), reads it in the view, and on commit parses it into the typed `value.FieldValue` document it already saves; undo/redo snapshot the whole parsed step document. `render.gleam` gains a per-keystroke `on_input` on group inputs.

**Tech Stack:** Gleam (JS target), Lustre 5, gleeunit (new client dev-dep).

## Global Constraints

- Gleam style: `let assert Ok(...)` for Result unwrapping; SLAP; descriptive names (no type-tagged abbreviations).
- Exhaustive `case` with NO `_` wildcard over `EditValue` and `value.FieldValue`.
- NO inline comments inside function bodies; only terse one-line `///` doc comments on public functions/modules.
- Tests use `assert expr == expected` (NOT gleeunit/should); deterministic explicit values; describe behaviour from the user's perspective.
- Add dependencies only via `gleam add` (never edit `gleam.toml` by hand).
- The Postgres container is on host port **5435** this session — prefix DB/e2e commands with `TEMPO_DB_PORT=5435`.
- No `shared` or server change. The wire contract, `value.FieldValue`, `RowsValue`, and the per-step storage are untouched. `value.parse`/`value.to_input` are reused as-is.
- Reuse the existing Model field name `edits` (retyped) — do NOT rename it to `working`; a helper function named `working` already exists and the names would collide.

---

### Task 1: Stand up the client test harness

**Files:**
- Modify: `client/gleam.toml` (via `gleam add`)
- Create: `client/test/client_test.gleam`
- Modify: `bin/test:18`

**Interfaces:**
- Produces: a runnable `cd client && gleam test` that discovers `*_test` functions via `gleeunit.main()`.

- [ ] **Step 1: Add gleeunit as a client dev-dependency**

Run: `cd client && gleam add --dev gleeunit`
Expected: `gleam.toml` gains `gleeunit` under `[dev_dependencies]`.

- [ ] **Step 2: Write the test runner with one trivial passing test**

Create `client/test/client_test.gleam`:

```gleam
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn harness_runs_test() {
  assert 1 + 1 == 2
}
```

- [ ] **Step 3: Run the client suite**

Run: `cd client && gleam test`
Expected: PASS — 1 test, no failures.

- [ ] **Step 4: Wire the client suite into bin/test**

In `bin/test`, change line 18 from:

```bash
( cd server && gleam test && gleam format --check src test )
```

to:

```bash
( cd server && gleam test && gleam format --check src test )
( cd client && gleam test && gleam format --check src test )
```

- [ ] **Step 5: Run the full suite**

Run: `TEMPO_DB_PORT=5435 bin/test`
Expected: server `325 passed`, client `1 passed`; format checks pass; css lint OK.

- [ ] **Step 6: Commit**

```bash
git add client/gleam.toml client/manifest.toml client/test/client_test.gleam bin/test
git commit -m "Stand up a client gleeunit test harness wired into bin/test"
```

---

### Task 2: The pure `edit` module — EditValue + transitions

**Files:**
- Create: `client/src/client/workflow/edit.gleam`
- Test: `client/test/edit_test.gleam`

**Interfaces:**
- Consumes: `shared/workflow/value.{type FieldValue, RowsValue, to_input}`.
- Produces:
  - `pub type EditValue { Scalar(String) Rows(List(Dict(String, String))) }`
  - `pub fn seed(step_values: Dict(String, FieldValue)) -> Dict(String, EditValue)`
  - `pub fn scalar(edits: Dict(String, EditValue), field: String) -> String`
  - `pub fn set_scalar(edits: Dict(String, EditValue), field: String, raw: String) -> Dict(String, EditValue)`
  - `pub fn rows(edits: Dict(String, EditValue), field: String) -> List(Dict(String, String))`
  - `pub fn set_cell(edits, field: String, index: Int, item_key: String, raw: String) -> Dict(String, EditValue)`
  - `pub fn add_row(edits, field: String) -> Dict(String, EditValue)`
  - `pub fn remove_row(edits, field: String, index: Int) -> Dict(String, EditValue)`

- [ ] **Step 1: Write the failing tests**

Create `client/test/edit_test.gleam`:

```gleam
import client/workflow/edit
import gleam/dict
import shared/money
import shared/workflow/value.{IntValue, RowsValue, TextValue}

pub fn seed_renders_scalars_as_input_strings_test() {
  let saved = dict.from_list([#("full_name", TextValue("Ada")), #("level", IntValue(5))])
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
    edit.seed(dict.from_list([
      #("team", RowsValue([dict.from_list([#("role", TextValue("Eng"))])])),
    ]))
  let edits = edit.set_cell(edits, "team", 0, "role", "Engineering")
  assert edit.rows(edits, "team") == [dict.from_list([#("role", "Engineering")])]
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
```

(The `shared/money` import keeps the test module's dependency graph identical to the source; remove it if unused once written.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd client && gleam test`
Expected: FAIL — `edit` module does not exist.

- [ ] **Step 3: Write the module**

Create `client/src/client/workflow/edit.gleam`:

```gleam
//// The wizard's in-progress raw edit state for the current step: one entry per
//// field, holding the text the user is typing (a scalar) or the per-row cells of
//// a repeating group. Raw `String` leaves mirror what an input control shows,
//// including not-yet-valid entries; `value.parse` lifts them to typed values on
//// commit and `value.to_input` seeds them back from saved values.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd client && gleam test`
Expected: PASS — the harness test plus the 6 edit tests; remove the unused `shared/money` import if the compiler warns.

- [ ] **Step 5: Commit**

```bash
git add client/src/client/workflow/edit.gleam client/test/edit_test.gleam
git commit -m "Add the workflow edit-buffer module: EditValue + pure transitions"
```

---

### Task 3: Retype the Model `edits` field and read it in the view

**Files:**
- Modify: `client/src/client/workflow/wizard.gleam` (Model `:47`, `enter_step` `:203-205`, `Edited` arm `:127-128`, `field_value` `:309-316`, `display_map` `:626-640`, `groups_map` `:642-662`, the `RowFieldChanged` arm, imports)
- Modify: `client/src/client/workflow/render.gleam` (FieldEvent `:25-37`, `group_text_input` `:377-404`)

**Interfaces:**
- Consumes: `client/workflow/edit` from Task 2; the new `RowFieldChanged` event below.
- Produces: `edits: Dict(String, edit.EditValue)` on the Model; the view reads scalars via `edit.scalar` and group rows via `edit.rows`.

This task wires the keystroke path only (display + buffering). Commit/undo stay on their current per-field shape until Task 4, so the build stays green throughout.

- [ ] **Step 1: Add the new keystroke event to render.gleam**

In `render.gleam`, add a variant to `FieldEvent` (after `RowFieldEdited`, `:36`):

```gleam
  RowFieldChanged(
    step: String,
    field: String,
    index: Int,
    item_key: String,
    raw: String,
  )
```

- [ ] **Step 2: Fire it per keystroke from the group text input**

In `render.gleam` `group_text_input` (`:386-403`), add an `on_input` handler beside the existing blur handler:

```gleam
  html.input([
    attribute.type_(input_type),
    attribute.attribute("aria-label", item_field.label),
    attribute.value(current),
    event.on_input(fn(raw) {
      on_event(RowFieldChanged(step_id, field_key, index, item_field.key, raw))
    }),
    event.on(
      "blur",
      decode.at(["target", "value"], decode.string)
        |> decode.map(fn(raw) {
          on_event(RowFieldEdited(step_id, field_key, index, item_field.key, raw))
        }),
    ),
  ])
```

- [ ] **Step 3: Retype the Model field and seed it**

In `wizard.gleam`, add the import near the other workflow imports:

```gleam
import client/workflow/edit
```

Change the Model field (`:47`) from `edits: Dict(String, String),` to:

```gleam
    edits: Dict(String, edit.EditValue),
```

In `init` (`:92`) `edits: dict.new()` stays. In `enter_step` (`:203-205`) seed `edits` from the step's saved values instead of clearing it:

```gleam
fn enter_step(model: Model, step: String) -> Model {
  Model(
    ..model,
    step:,
    edits: edit.seed(step_values_for(model, step)),
    undo: [],
    redo: [],
  )
}
```

- [ ] **Step 4: Buffer keystrokes through `edit`**

Replace the `Edited` arm (`:127-128`) with:

```gleam
    FieldChanged(Edited(field:, raw:, ..)) ->
      working(Model(..model, edits: edit.set_scalar(model.edits, field, raw)))
```

Add a new arm beside the other `FieldChanged` arms (after `:135`):

```gleam
    FieldChanged(RowFieldChanged(field:, index:, item_key:, raw:, ..)) ->
      working(Model(
        ..model,
        edits: edit.set_cell(model.edits, field, index, item_key, raw),
      ))
```

- [ ] **Step 5: Read the buffer in the view helpers**

Replace `field_value` (`:309-316`):

```gleam
/// The displayed value for a scalar field — the raw working text.
pub fn field_value(model: Model, _step: String, key: String) -> String {
  edit.scalar(model.edits, key)
}
```

Replace the `display_map` body (`:632-636`) so the scalar branch reads the buffer:

```gleam
      _ -> dict.insert(acc, field.key, edit.scalar(model.edits, field.key))
```

Replace `groups_map` (`:642-662`) so group rows come from the buffer:

```gleam
fn groups_map(
  model: Model,
  step: Step,
) -> Dict(String, List(Dict(String, String))) {
  let fields = list.flat_map(step.sections, fn(section) { section.fields })
  list.fold(fields, dict.new(), fn(acc, field) {
    case field.kind {
      GroupField(..) -> dict.insert(acc, field.key, edit.rows(model.edits, field.key))
      _ -> acc
    }
  })
}
```

- [ ] **Step 6: Build the client**

Run: `cd client && gleam build`
Expected: compiles. Fix any now-unused functions (`current_rows`/`saved_value` may still be used by Task 4 — leave them; if the compiler flags one as unused, it is consumed in Task 4, so keep it and ignore the warning until then).

- [ ] **Step 7: Commit**

```bash
git add client/src/client/workflow/wizard.gleam client/src/client/workflow/render.gleam
git commit -m "Read the per-step raw edit buffer in the wizard view; buffer group keystrokes"
```

---

### Task 4: Commit + undo/redo as step-document snapshots

**Files:**
- Modify: `client/src/client/workflow/wizard.gleam` (Model `undo`/`redo` `:48-49`, `commit_field` `:207-248`, `step_undo`/`step_redo`/`apply_restore` `:250-303`, `save_group` `:675-691`, `add_group_row` `:693-700`, `remove_group_row` `:702-714`, `edit_group_row` `:716-742`)

**Interfaces:**
- Consumes: `edit` (set_scalar/set_cell/add_row/remove_row), `step_values_for`, `set_value`, `wapi.save_step`, `value.RowsValue`.
- Produces: `undo: List(Dict(String, value.FieldValue))`, `redo: List(...)`; every commit pushes the pre-commit step document.

- [ ] **Step 1: Retype the undo/redo stacks**

In `wizard.gleam` Model (`:48-49`) change:

```gleam
    undo: List(Dict(String, value.FieldValue)),
    redo: List(Dict(String, value.FieldValue)),
```

- [ ] **Step 2: Rewrite `commit_field` to snapshot the document**

Replace `commit_field` (`:207-248`):

```gleam
fn commit_field(
  model: Model,
  step: String,
  field: String,
  raw: String,
) -> #(Model, Effect(Msg), Outcome) {
  case field_type(model, step, field) {
    Some(kind) ->
      case value.parse(kind, raw), saved_field_value(model, step, field) {
        Ok(field_value), saved if Some(field_value) == saved -> working(model)
        Ok(field_value), _ -> {
          let prev_doc = step_values_for(model, step)
          let new_doc = dict.insert(prev_doc, field, field_value)
          let model =
            Model(
              ..model,
              draft: set_value(model.draft, step, new_doc),
              edits: edit.set_scalar(model.edits, field, raw),
              undo: [prev_doc, ..model.undo],
              redo: [],
              error: "",
            )
          #(model, wapi.save_step(model.instance_id, step, new_doc, Saved), Working)
        }
        Error(_), _ ->
          working(
            Model(
              ..model,
              edits: edit.set_scalar(model.edits, field, raw),
              error: "That value isn't valid for this field.",
            ),
          )
      }
    None -> working(model)
  }
}
```

- [ ] **Step 3: Rewrite undo/redo to swap whole documents**

Replace `step_undo`, `step_redo`, and `apply_restore` (`:250-303`) with:

```gleam
fn step_undo(model: Model) -> #(Model, Effect(Msg), Outcome) {
  case model.undo {
    [prev_doc, ..rest] -> {
      let current_doc = step_values_for(model, model.step)
      restore_doc(model, prev_doc, undo: rest, redo: [current_doc, ..model.redo])
    }
    [] -> working(model)
  }
}

fn step_redo(model: Model) -> #(Model, Effect(Msg), Outcome) {
  case model.redo {
    [next_doc, ..rest] -> {
      let current_doc = step_values_for(model, model.step)
      restore_doc(model, next_doc, undo: [current_doc, ..model.undo], redo: rest)
    }
    [] -> working(model)
  }
}

fn restore_doc(
  model: Model,
  doc: Dict(String, value.FieldValue),
  undo undo: List(Dict(String, value.FieldValue)),
  redo redo: List(Dict(String, value.FieldValue)),
) -> #(Model, Effect(Msg), Outcome) {
  let model =
    Model(
      ..model,
      draft: set_value(model.draft, model.step, doc),
      edits: edit.seed(doc),
      undo:,
      redo:,
      error: "",
    )
  #(model, wapi.save_step(model.instance_id, model.step, doc, Saved), Working)
}
```

- [ ] **Step 4: Make group saves snapshot the document and keep the buffer aligned**

Replace `save_group` (`:675-691`) so it pushes undo and takes the already-updated `edits`:

```gleam
fn save_group(
  model: Model,
  step_id: String,
  field_key: String,
  new_rows: List(Dict(String, value.FieldValue)),
  edits: Dict(String, edit.EditValue),
) -> #(Model, Effect(Msg), Outcome) {
  let prev_doc = step_values_for(model, step_id)
  let new_doc = dict.insert(prev_doc, field_key, value.RowsValue(new_rows))
  let model =
    Model(
      ..model,
      draft: set_value(model.draft, step_id, new_doc),
      edits:,
      undo: [prev_doc, ..model.undo],
      redo: [],
    )
  #(model, wapi.save_step(model.instance_id, step_id, new_doc, Saved), Working)
}
```

Update its three callers to pass the buffer-aligned `edits`:

`add_group_row` (`:693-700`):

```gleam
fn add_group_row(
  model: Model,
  step_id: String,
  field_key: String,
) -> #(Model, Effect(Msg), Outcome) {
  let rows = current_rows(model, step_id, field_key)
  save_group(
    model,
    step_id,
    field_key,
    list.append(rows, [dict.new()]),
    edit.add_row(model.edits, field_key),
  )
}
```

`remove_group_row` (`:702-714`):

```gleam
fn remove_group_row(
  model: Model,
  step_id: String,
  field_key: String,
  index: Int,
) -> #(Model, Effect(Msg), Outcome) {
  let rows = current_rows(model, step_id, field_key)
  let new_rows =
    list.index_map(rows, fn(row, i) { #(i, row) })
    |> list.filter(fn(pair) { pair.0 != index })
    |> list.map(fn(pair) { pair.1 })
  save_group(
    model,
    step_id,
    field_key,
    new_rows,
    edit.remove_row(model.edits, field_key, index),
  )
}
```

`edit_group_row` (`:716-742`) — on a valid cell commit, write the typed cell into the draft rows and the raw cell into the buffer:

```gleam
fn edit_group_row(
  model: Model,
  step_id: String,
  field_key: String,
  index: Int,
  item_key: String,
  raw: String,
) -> #(Model, Effect(Msg), Outcome) {
  case group_item_field_type(model, step_id, field_key, item_key) {
    Some(kind) ->
      case value.parse(kind, raw) {
        Ok(field_value) -> {
          let rows = current_rows(model, step_id, field_key)
          let new_rows =
            list.index_map(rows, fn(row, i) {
              case i == index {
                True -> dict.insert(row, item_key, field_value)
                False -> row
              }
            })
          save_group(
            model,
            step_id,
            field_key,
            new_rows,
            edit.set_cell(model.edits, field_key, index, item_key, raw),
          )
        }
        Error(_) -> working(model)
      }
    None -> working(model)
  }
}
```

- [ ] **Step 5: Build the client**

Run: `cd client && gleam build`
Expected: compiles with no unused-function warnings (`saved_value`/`current_rows` are now consumed).

- [ ] **Step 6: Commit**

```bash
git add client/src/client/workflow/wizard.gleam
git commit -m "Snapshot the whole step document on commit; undo/redo and group edits aligned"
```

---

### Task 5: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit + format + lint suite**

Run: `TEMPO_DB_PORT=5435 bin/test`
Expected: server `325 passed`, client `7 passed` (harness + 6 edit tests), format checks pass, css lint OK.

- [ ] **Step 2: Exercise both wizard hosts in a real browser**

Run: `TEMPO_DB_PORT=5435 bin/e2e onboarding.spec.js project-creation.spec.js --workers=1`
Expected: PASS — the onboarding manager→Finance flow and the project-creation "Team requirements" group step still drive correctly against the fresh bundle (`bin/e2e` rebuilds it).

- [ ] **Step 3: Manual confirmation of the fix (optional but recommended)**

Start the app (`TEMPO_DB_PORT=5435 TEMPO_DB_NAME=tempo_e2e bin/serve`), open project-creation, add two Team-requirements rows, type in a row cell, and confirm keystrokes are retained while an autosave of a sibling field completes. Stop the server.

- [ ] **Step 4: Commit any doc touch-ups**

If `docs/2026-06-30-workflow-edit-buffer-design.md` needs a note that the Model field stayed named `edits` (not `working`) to avoid the helper-name collision, add it and commit:

```bash
git add docs/2026-06-30-workflow-edit-buffer-design.md
git commit -m "Note the edits field kept its name to avoid the working() helper collision"
```

---

## Self-Review

**Spec coverage:** EditValue + raw/typed split (Task 2); `working` document seeded per step and read in the view (Task 3); `RowFieldChanged` keystroke + `on_input` (Tasks 1/3); commit parses per field and saves the whole step doc (Task 4); undo/redo as whole-step parsed-document snapshots covering groups (Task 4); row add/remove keep buffer aligned (Tasks 2/4); client-only, no shared/server change (all tasks); tests for keystroke-survives-render, add/remove alignment, undo round-trip (Task 2 covers the pure logic; Task 5 covers the wired behaviour via e2e). Design note: the Model field is named `edits` (retyped), not `working`, to avoid colliding with the existing `working` helper.

**Placeholder scan:** none — every code step shows complete code; commands show expected output.

**Type consistency:** `edits: Dict(String, edit.EditValue)` used in Model and every arm; `undo`/`redo: List(Dict(String, value.FieldValue))` used in commit/undo/save_group; `save_group/5` signature (new `edits` param) matches all three callers; `RowFieldChanged` fields (`step/field/index/item_key/raw`) match between `render.gleam` and the `wizard.gleam` arm.
