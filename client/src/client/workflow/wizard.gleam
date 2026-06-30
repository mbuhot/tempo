//// The onboarding wizard as an embeddable component (not a page): a host opens it
//// for an instance id, renders `view` inside a modal, forwards `Msg`s, and reacts to
//// the `Outcome` (`Working` keep open, `Dismissed` close, `Committed` close + the
//// engineer was created). Step navigation is modal-local — Back/Next move
//// `model.step` (Next also persists the open step) — so there is no URL per step;
//// the draft is durable in the DB and reopened by resuming from the People list.
//// The schema drives rendering generically; field values autosave on blur with a
//// no-op guard; undo/redo is a per-step buffer that re-saves.

import client/api
import client/focus
import client/icons
import client/workflow/api as wapi
import client/workflow/edit
import client/workflow/render.{
  type FieldEvent, Committed as FieldCommitted, Edited, RowAdded,
  RowFieldChanged, RowFieldEdited, RowRemoved,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/workflow/kind as wkind
import shared/workflow/schema.{
  type FieldType, type Step, type WorkflowSchema, GroupField,
}
import shared/workflow/value
import shared/workflow/view.{type DraftView, DraftView}

pub type Model {
  Model(
    instance_id: String,
    kind: wkind.WorkflowKind,
    schema: Option(WorkflowSchema),
    draft: Option(DraftView),
    step: String,
    // The furthest step reached, so the rail can mark earlier steps done +
    // clickable even after stepping Back.
    furthest: String,
    edits: Dict(String, edit.EditValue),
    undo: List(Dict(String, value.FieldValue)),
    redo: List(Dict(String, value.FieldValue)),
    error: String,
  )
}

pub type Msg {
  SchemaFetched(Result(WorkflowSchema, rsvp.Error(String)))
  DraftFetched(Result(DraftView, rsvp.Error(String)))
  FieldChanged(FieldEvent)
  Saved(Result(Nil, rsvp.Error(String)))
  BackClicked
  NextClicked
  GoToStep(step: String)
  StepAdvanced(String, Result(Nil, rsvp.Error(String)))
  UndoClicked
  RedoClicked
  HandOffClicked
  HandedOff(Result(Nil, rsvp.Error(String)))
  CommitClicked
  CommitReturned(Result(Nil, rsvp.Error(String)))
  DismissClicked
}

/// What the host should do after an update.
pub type Outcome {
  Working
  Dismissed
  Committed
}

/// Open the wizard for an existing instance, fetching its schema and draft.
pub fn init(
  instance_id: String,
  kind: wkind.WorkflowKind,
) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      instance_id:,
      kind:,
      schema: None,
      draft: None,
      step: "",
      furthest: "",
      edits: dict.new(),
      undo: [],
      redo: [],
      error: "",
    )
  #(
    model,
    effect.batch([
      wapi.fetch_schema(wkind.to_string(kind), SchemaFetched),
      wapi.fetch_draft(instance_id, DraftFetched),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), Outcome) {
  case msg {
    SchemaFetched(Ok(schema)) -> working(Model(..model, schema: Some(schema)))
    SchemaFetched(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    DraftFetched(Ok(draft)) -> {
      let step = case model.step {
        "" -> draft.current_step
        step -> step
      }
      let furthest = case model.furthest {
        "" -> draft.current_step
        furthest -> furthest
      }
      // The fields render now — focus the first one.
      entered(Model(..model, draft: Some(draft), step:, furthest:))
    }
    DraftFetched(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    FieldChanged(Edited(field:, raw:, ..)) ->
      working(Model(..model, edits: edit.set_scalar(model.edits, field, raw)))
    FieldChanged(FieldCommitted(step:, field:, raw:)) ->
      commit_field(model, step, field, raw)
    FieldChanged(RowAdded(step:, field:)) -> add_group_row(model, step, field)
    FieldChanged(RowRemoved(step:, field:, index:)) ->
      remove_group_row(model, step, field, index)
    FieldChanged(RowFieldEdited(step:, field:, index:, item_key:, raw:)) ->
      edit_group_row(model, step, field, index, item_key, raw)
    FieldChanged(RowFieldChanged(field:, index:, item_key:, raw:, ..)) ->
      working(
        Model(
          ..model,
          edits: edit.set_cell(model.edits, field, index, item_key, raw),
        ),
      )

    Saved(Ok(_)) -> working(model)
    Saved(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    UndoClicked -> step_undo(model)
    RedoClicked -> step_redo(model)

    BackClicked ->
      case prev_step_id(model) {
        Some(prev) -> entered(enter_step(model, prev))
        None -> working(model)
      }

    NextClicked ->
      case next_step_id(model) {
        Some(next) -> #(
          model,
          wapi.complete_step(model.instance_id, next, StepAdvanced(next, _)),
          Working,
        )
        None -> working(model)
      }
    GoToStep(step:) -> entered(enter_step(model, step))
    StepAdvanced(next, Ok(_)) -> {
      let furthest = extend_furthest(model, next)
      entered(Model(..enter_step(model, next), furthest:))
    }
    StepAdvanced(_, Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    HandOffClicked -> #(
      model,
      wapi.hand_off(model.instance_id, HandedOff),
      Working,
    )
    HandedOff(Ok(_)) -> #(model, effect.none(), Dismissed)
    HandedOff(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    CommitClicked -> #(
      model,
      case model.kind {
        wkind.CreateProject ->
          wapi.commit_project(model.instance_id, CommitReturned)
        wkind.OnboardEngineer -> wapi.commit(model.instance_id, CommitReturned)
      },
      Working,
    )
    CommitReturned(Ok(_)) -> #(model, effect.none(), Committed)
    CommitReturned(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    DismissClicked -> #(model, effect.none(), Dismissed)
  }
}

fn working(model: Model) -> #(Model, Effect(Msg), Outcome) {
  #(model, effect.none(), Working)
}

/// Like `working`, but also focuses the first field of the (now-rendered) step.
fn entered(model: Model) -> #(Model, Effect(Msg), Outcome) {
  #(model, focus.first_field(".wizard__content"), Working)
}

/// Move to `step`, seeding the edit buffer from saved values and clearing undo/redo.
fn enter_step(model: Model, step: String) -> Model {
  Model(
    ..model,
    step:,
    edits: edit.seed(step_values_for(model, step)),
    undo: [],
    redo: [],
  )
}

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
          #(
            model,
            wapi.save_step(model.instance_id, step, new_doc, Saved),
            Working,
          )
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
      restore_doc(
        model,
        next_doc,
        undo: [current_doc, ..model.undo],
        redo: rest,
      )
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

/// The current step id.
pub fn current_step(model: Model) -> String {
  model.step
}

/// The displayed value for a scalar field — the raw working text.
pub fn field_value(model: Model, _step: String, key: String) -> String {
  edit.scalar(model.edits, key)
}

// --- view -------------------------------------------------------------------

pub fn view(
  model: Model,
  permissions: Set(String),
  aside: fn(String) -> Element(Msg),
) -> Element(Msg) {
  case model.schema, model.draft {
    Some(schema), Some(_draft) ->
      case find_step(schema, model.step) {
        Some(step) ->
          html.div([attribute.class("wizard wizard--modal")], [
            html.div([attribute.class("wizard__body")], [
              view_rail(model, schema, permissions),
              html.div([attribute.class("wizard__divider")], []),
              html.div([attribute.class("wizard__content")], [
                html.h2([], [html.text(step.title)]),
                render.step_view(
                  step,
                  display_map(model, step),
                  groups_map(model, step),
                  FieldChanged,
                ),
                view_error(model.error),
                aside(model.step),
              ]),
            ]),
            view_footer(model, schema, step, permissions),
          ])
        None -> html.p([], [html.text("Loading…")])
      }
    _, _ -> html.p([], [html.text("Loading…")])
  }
}

/// The rail, driven by the LIVE client step (panel and rail must agree; the server
/// `step_status` lags until a refetch). Each step shows a numbered circle: a check
/// once reached, the number while pending, a lock when it is permission-gated and the
/// current user can't complete it (they'll hand it off). Reached steps are buttons
/// that jump back to them.
fn view_rail(
  model: Model,
  schema: WorkflowSchema,
  permissions: Set(String),
) -> Element(Msg) {
  let ids = list.map(schema.steps, fn(step) { step.id })
  let current = index_of(ids, model.step, 0)
  let furthest = index_of(ids, model.furthest, 0)
  html.ol(
    [attribute.class("wizard__rail")],
    list.index_map(schema.steps, fn(step, index) {
      rail_step(step, index, current, furthest, permissions)
    }),
  )
}

fn rail_step(
  step: Step,
  index: Int,
  current: Int,
  furthest: Int,
  permissions: Set(String),
) -> Element(Msg) {
  let active = index == current
  // Done (✓) means BEHIND the current step — completed and moved past. A step that
  // is ahead (even if previously reached) is not done; it shows its number, or a
  // lock when it is gated and the current user can't complete it.
  let done = index < current
  let reached = index <= furthest
  let #(state, marker) = case active, done, can_complete(step, permissions) {
    True, _, _ -> #("is-active", html.text(int.to_string(index + 1)))
    False, True, _ -> #("is-done", html.text("✓"))
    False, False, True -> #("is-pending", html.text(int.to_string(index + 1)))
    False, False, False -> #("is-handoff", icons.lock())
  }
  let inner = [
    html.span([attribute.class("wizard__rail-num")], [marker]),
    html.span([attribute.class("wizard__rail-label")], [html.text(step.title)]),
  ]
  // Only a reached, non-current step jumps back; the rest are inert.
  let row = case reached && !active {
    True ->
      html.button(
        [
          attribute.class("wizard__rail-link"),
          event.on_click(GoToStep(step.id)),
        ],
        inner,
      )
    False -> html.span([attribute.class("wizard__rail-row")], inner)
  }
  html.li([attribute.class("wizard__rail-step " <> state)], [row])
}

/// Whether the current user could complete this step themselves (an ungated step, or
/// a gated one they hold the permission for).
fn can_complete(step: Step, permissions: Set(String)) -> Bool {
  case step.requires_permission {
    None -> True
    Some(permission) -> set.contains(permissions, permission)
  }
}

/// The furthest step reached so far, by schema order (Next never regresses it).
fn extend_furthest(model: Model, step: String) -> String {
  case model.schema {
    Some(schema) -> {
      let ids = list.map(schema.steps, fn(step) { step.id })
      case index_of(ids, step, 0) > index_of(ids, model.furthest, 0) {
        True -> step
        False -> model.furthest
      }
    }
    None -> step
  }
}

/// The footer is permission-driven, not a rigid hand-off. The advance action depends
/// on whether the current user can complete the NEXT step: if they can, Continue into
/// it; if it is gated beyond their permission, Hand off to Finance. On the last step,
/// Finish (commit) when they hold the permission, else they are awaiting Finance. So
/// an Admin who can do every step never hands off; a Manager hands off at payroll.
fn view_footer(
  model: Model,
  schema: WorkflowSchema,
  step: Step,
  permissions: Set(String),
) -> Element(Msg) {
  let back = case prev_step_id(model) {
    Some(_) ->
      html.button(
        [attribute.class("btn btn--ghost"), event.on_click(BackClicked)],
        [html.text("← Back")],
      )
    None -> element.none()
  }
  let undo =
    html.button(
      [
        attribute.class("btn btn--ghost"),
        attribute.disabled(list.is_empty(model.undo)),
        event.on_click(UndoClicked),
      ],
      [html.text("Undo")],
    )
  let redo =
    html.button(
      [
        attribute.class("btn btn--ghost"),
        attribute.disabled(list.is_empty(model.redo)),
        event.on_click(RedoClicked),
      ],
      [html.text("Redo")],
    )
  let advance = case next_step_obj(schema, step) {
    Some(next) ->
      case can_complete(next, permissions) {
        True ->
          html.button([attribute.class("btn"), event.on_click(NextClicked)], [
            html.text("Continue →"),
          ])
        False ->
          html.button([attribute.class("btn"), event.on_click(HandOffClicked)], [
            html.text("Hand off for approval →"),
          ])
      }
    None ->
      case can_complete(step, permissions) {
        True ->
          html.button([attribute.class("btn"), event.on_click(CommitClicked)], [
            html.text("Finish"),
          ])
        False -> html.p([], [html.text("Awaiting Finance confirmation.")])
      }
  }
  html.div([attribute.class("wizard__footer")], [
    html.div([attribute.class("wizard__footer-group")], [undo, redo]),
    html.div([attribute.class("wizard__footer-group wizard__footer-nav")], [
      back,
      advance,
    ]),
  ])
}

/// The step after `step`, or `None` if it is the last.
fn next_step_obj(schema: WorkflowSchema, step: Step) -> Option(Step) {
  case neighbour(schema, step.id, 1) {
    Some(id) -> find_step(schema, id)
    None -> None
  }
}

fn view_error(error: String) -> Element(Msg) {
  case error {
    "" -> element.none()
    message ->
      html.p([attribute.class("op-form__error"), attribute.role("alert")], [
        html.text(message),
      ])
  }
}

// --- helpers ----------------------------------------------------------------

fn find_step(schema: WorkflowSchema, step_id: String) -> Option(Step) {
  case list.find(schema.steps, fn(step) { step.id == step_id }) {
    Ok(step) -> Some(step)
    Error(_) -> None
  }
}

fn next_step_id(model: Model) -> Option(String) {
  case model.schema {
    Some(schema) -> neighbour(schema, model.step, 1)
    None -> None
  }
}

fn prev_step_id(model: Model) -> Option(String) {
  case model.schema {
    Some(schema) -> neighbour(schema, model.step, -1)
    None -> None
  }
}

fn neighbour(
  schema: WorkflowSchema,
  step_id: String,
  offset: Int,
) -> Option(String) {
  let ids = list.map(schema.steps, fn(step) { step.id })
  let target = index_of(ids, step_id, 0) + offset
  case target < 0 {
    True -> None
    False -> at(ids, target)
  }
}

fn index_of(items: List(String), target: String, at: Int) -> Int {
  case items {
    [] -> -1
    [head, ..rest] ->
      case head == target {
        True -> at
        False -> index_of(rest, target, at + 1)
      }
  }
}

fn at(items: List(String), index: Int) -> Option(String) {
  case items, index {
    [head, ..], 0 -> Some(head)
    [_, ..rest], _ -> at(rest, index - 1)
    [], _ -> None
  }
}

fn field_type(
  model: Model,
  step_id: String,
  field_key: String,
) -> Option(FieldType) {
  case model.schema {
    Some(schema) ->
      case find_step(schema, step_id) {
        Some(step) -> {
          let fields =
            list.flat_map(step.sections, fn(section) { section.fields })
          case list.find(fields, fn(field) { field.key == field_key }) {
            Ok(field) -> Some(field.kind)
            Error(_) -> None
          }
        }
        None -> None
      }
    None -> None
  }
}

fn step_values_for(
  model: Model,
  step_id: String,
) -> Dict(String, value.FieldValue) {
  case model.draft {
    Some(draft) ->
      case dict.get(draft.values, step_id) {
        Ok(step_values) -> step_values
        Error(_) -> dict.new()
      }
    None -> dict.new()
  }
}

fn saved_field_value(
  model: Model,
  step_id: String,
  field_key: String,
) -> Option(value.FieldValue) {
  option.from_result(dict.get(step_values_for(model, step_id), field_key))
}

fn display_map(model: Model, step: Step) -> Dict(String, String) {
  let fields = list.flat_map(step.sections, fn(section) { section.fields })
  list.fold(fields, dict.new(), fn(acc, field) {
    case field.kind {
      GroupField(..) -> acc
      _ -> dict.insert(acc, field.key, edit.scalar(model.edits, field.key))
    }
  })
}

fn groups_map(
  model: Model,
  step: Step,
) -> Dict(String, List(Dict(String, String))) {
  let fields = list.flat_map(step.sections, fn(section) { section.fields })
  list.fold(fields, dict.new(), fn(acc, field) {
    case field.kind {
      GroupField(..) ->
        dict.insert(acc, field.key, edit.rows(model.edits, field.key))
      _ -> acc
    }
  })
}

fn current_rows(
  model: Model,
  step_id: String,
  field_key: String,
) -> List(Dict(String, value.FieldValue)) {
  case dict.get(step_values_for(model, step_id), field_key) {
    Ok(value.RowsValue(rows)) -> rows
    _ -> []
  }
}

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

fn group_item_field_type(
  model: Model,
  step_id: String,
  field_key: String,
  item_key: String,
) -> Option(FieldType) {
  case model.schema {
    Some(schema) ->
      case find_step(schema, step_id) {
        Some(step) -> {
          let fields =
            list.flat_map(step.sections, fn(section) { section.fields })
          list.find(fields, fn(field) { field.key == field_key })
          |> result.map(fn(group_field) {
            case group_field.kind {
              GroupField(item_fields:, ..) ->
                list.find(item_fields, fn(f) { f.key == item_key })
                |> result.map(fn(item_field) { item_field.kind })
                |> option.from_result
              _ -> None
            }
          })
          |> result.unwrap(None)
        }
        None -> None
      }
    None -> None
  }
}

fn set_value(
  draft: Option(DraftView),
  step_id: String,
  step_values: Dict(String, value.FieldValue),
) -> Option(DraftView) {
  case draft {
    Some(current) ->
      Some(
        DraftView(
          ..current,
          values: dict.insert(current.values, step_id, step_values),
        ),
      )
    None -> None
  }
}
