# Workflow edit buffer — one step-document model

## Problem

Repeating-group rows (e.g. project-creation's "Team requirements" step) lose
keystrokes. While a user types in a group-row input, an async `save_step`
response can land and re-render the wizard; the controlled input's `value` snaps
back to the last-committed value and the in-progress keystrokes vanish. Scalar
fields are immune; group rows are not. (GitHub #34.)

## Why this happens

The wizard's inputs are **controlled** — every render sets each input's `value`
from the model. A controlled input only survives re-renders if the model already
holds the live keystroke. Scalar fields update the model on every keystroke
(`Edited`); group-row inputs update it **only on blur**, so between keystrokes the
model lags and a mid-type re-render repaints the stale value.

Two forces make this form different from a plain input→submit form:

1. **Autosave on blur.** Each field commits to the server on blur, so the model
   carries both the live raw text *and* a typed, validated, persisted value.
2. **Strong typing.** A value is a `value.FieldValue` (`DateValue`, `MoneyValue`,
   …). Mid-typing text like `"2026-0"` is not yet any typed value, so the live
   input state must be a raw `String`.

The existing buffer holds that raw text — `edits: Dict(String, String)` — keyed
by a flat field key. A flat key cannot name a cell inside a repeating group, so
group rows had no per-keystroke slot.

## The persistence unit

Draft values are stored one JSON document per step, transaction-time versioned:

```
workflow_step_value (instance_id, step_id, value jsonb, recorded_during)
```

A save writes the whole step document. The client's edit state and undo/redo are
per-field, a layer finer than the unit the server stores and versions. Aligning
the client to the **step document** makes group editing and undo fall out
uniformly.

## Design

Two representations, by layer:

| Layer | Holds | Type | Lifetime |
|---|---|---|---|
| Raw / input | what the user is typing (may be invalid) | `String` leaves | current step |
| Typed / persisted | validated, saved, domain values | `value.FieldValue` | all steps |

Bridged by existing `value.gleam` functions: `parse(kind, raw) -> Result(FieldValue)`
on commit, `to_input(FieldValue) -> String` on seed.

### Edit value

```gleam
type EditValue {
  Scalar(String)                      // raw text for a scalar field
  Rows(List(Dict(String, String)))    // per-row raw cells, aligned 1:1 with the saved RowsValue
}
```

`Rows` is a `List` kept positionally aligned with the step's saved
`RowsValue` — row add/remove is the same list operation on both, so there is no
composite key and no index re-keying.

### Model

```gleam
Model(
  draft: Option(DraftView),                       // saved parsed values, all steps (unchanged)
  step: String,
  working: Dict(String, EditValue),               // current step's raw working document (replaces `edits`)
  undo: List(Dict(String, value.FieldValue)),     // whole-step parsed-document snapshots
  redo: List(Dict(String, value.FieldValue)),
  ...
)
```

`working` is seeded on `enter_step` from `draft.values[step]` via `to_input`, so
every input — scalar or group cell — binds to one slot in `working`, and the view
reads `working` directly. `undo`/`redo` snapshot the whole parsed step document
(the same type as `draft.values[step]`), so a single commit captures the step's
entire state, groups included.

### Update flow

| Message | Phase | Action |
|---|---|---|
| `Edited(field, raw)` | keystroke | `working[field] = Scalar(raw)` |
| `RowFieldChanged(field, i, key, raw)` *(new)* | keystroke | `working[field] = Rows` with `[i][key] = raw` |
| `FieldCommitted(field)` | blur | parse the field; if changed: push undo, overlay into `draft.values[step]`, `save_step` |
| `RowFieldEdited(field, i, key, raw)` | blur | same, for one row cell |
| `RowAdded` / `RowRemoved` | action | list-op on `working` Rows and `draft` rows in lockstep; push undo; `save_step` |
| `Undo` / `Redo` | action | pop document → set `draft.values[step]`, re-seed `working`, push the inverse, `save_step` |

Keystroke phases never save. Commit parses **per field**, so an invalid entry
raises a per-field error; the saved payload is the whole step document, which
`save_step` already is. `enter_step` seeds `working` and clears undo/redo.

## Scope

- Client only: `client/.../workflow/wizard.gleam` (the type, `working`/`undo`/`redo`,
  the seed helper, the keystroke/commit/group/undo arms, and the readers
  `field_value`/`display_map`/`groups_map` now read `working`) and
  `client/.../workflow/render.gleam` (new `RowFieldChanged` event, `on_input` on the
  group inputs).
- No `shared` or server change. The wire contract, `value.FieldValue`,
  `RowsValue`, and the per-step storage are untouched.
- Estimate ~120–180 lines, mostly `wizard.gleam`.

## Testing

Unit tests on the wizard update function:

- A keystroke survives a re-render — apply `Edited` / `RowFieldChanged`, then a
  `Saved` / `DraftFetched` re-render, assert the input still shows the typed text.
- Row add/remove keeps `working` aligned — edit rows 0 and 1, remove row 0, assert
  row 1's edit now reads at index 0.
- Undo/redo round-trips a whole step document including a group edit.
