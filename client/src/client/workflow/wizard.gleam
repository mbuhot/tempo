//// The onboarding wizard as an embeddable component (not a page): a host opens it
//// for an instance id, renders `view` inside a modal, forwards `Msg`s, and reacts to
//// the `Outcome` (`Working` keep open, `Dismissed` close, `Committed` close + the
//// engineer was created). Step navigation is modal-local — Back/Next move
//// `model.step` (Next also persists the open step) — so there is no URL per step;
//// the draft is durable in the DB and reopened by resuming from the People list.
//// The schema drives rendering generically; field values autosave on blur with a
//// no-op guard; undo/redo is a per-step buffer that re-saves.

import client/api
import client/workflow/api as wapi
import client/workflow/render.{
  type FieldEvent, Committed as FieldCommitted, Edited,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/workflow/schema.{type FieldType, type Step, type WorkflowSchema}
import shared/workflow/value
import shared/workflow/view.{
  type DraftView, type StepStatus, Active, Done, DraftView, Locked, Pending,
}

const kind = "onboard_engineer"

pub type Model {
  Model(
    instance_id: String,
    schema: Option(WorkflowSchema),
    draft: Option(DraftView),
    step: String,
    edits: Dict(String, String),
    undo: List(#(String, String)),
    redo: List(#(String, String)),
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
pub fn init(instance_id: String) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      instance_id:,
      schema: None,
      draft: None,
      step: "",
      edits: dict.new(),
      undo: [],
      redo: [],
      error: "",
    )
  #(
    model,
    effect.batch([
      wapi.fetch_schema(kind, SchemaFetched),
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
      working(Model(..model, draft: Some(draft), step:))
    }
    DraftFetched(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    FieldChanged(Edited(field:, raw:, ..)) ->
      working(Model(..model, edits: dict.insert(model.edits, field, raw)))
    FieldChanged(FieldCommitted(step:, field:, raw:)) ->
      commit_field(model, step, field, raw)

    Saved(Ok(_)) -> working(model)
    Saved(Error(error)) ->
      working(Model(..model, error: api.describe_error(error)))

    UndoClicked -> step_undo(model)
    RedoClicked -> step_redo(model)

    BackClicked ->
      case prev_step_id(model) {
        Some(prev) -> working(enter_step(model, prev))
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
    StepAdvanced(next, Ok(_)) -> working(enter_step(model, next))
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
      wapi.commit(model.instance_id, CommitReturned),
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

/// Move to `step`, clearing the per-step edit buffer and undo/redo stacks.
fn enter_step(model: Model, step: String) -> Model {
  Model(..model, step:, edits: dict.new(), undo: [], redo: [])
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
        // A blur that doesn't change the value is a no-op: no save, no undo entry.
        Ok(field_value), saved if Some(field_value) == saved -> working(model)
        Ok(field_value), _ -> {
          let prev = saved_value(model, step, field)
          let model =
            Model(
              ..model,
              draft: set_value(model.draft, step, field, field_value),
              edits: dict.insert(model.edits, field, raw),
              undo: [#(field, prev), ..model.undo],
              redo: [],
              error: "",
            )
          #(
            model,
            wapi.save_field(model.instance_id, step, field, field_value, Saved),
            Working,
          )
        }
        Error(_), _ ->
          working(
            Model(
              ..model,
              edits: dict.insert(model.edits, field, raw),
              error: "That value isn't valid for this field.",
            ),
          )
      }
    None -> working(model)
  }
}

fn step_undo(model: Model) -> #(Model, Effect(Msg), Outcome) {
  case model.undo {
    [#(field, prev), ..rest] ->
      apply_restore(model, field, prev, fn(current) {
        Model(..model, undo: rest, redo: [#(field, current), ..model.redo])
      })
    [] -> working(model)
  }
}

fn step_redo(model: Model) -> #(Model, Effect(Msg), Outcome) {
  case model.redo {
    [#(field, next), ..rest] ->
      apply_restore(model, field, next, fn(current) {
        Model(..model, redo: rest, undo: [#(field, current), ..model.undo])
      })
    [] -> working(model)
  }
}

fn apply_restore(
  model: Model,
  field: String,
  raw: String,
  bookkeep: fn(String) -> Model,
) -> #(Model, Effect(Msg), Outcome) {
  let step = model.step
  case field_type(model, step, field) {
    Some(kind) ->
      case value.parse(kind, raw) {
        Ok(field_value) -> {
          let current = saved_value(model, step, field)
          let model = bookkeep(current)
          let model =
            Model(
              ..model,
              draft: set_value(model.draft, step, field, field_value),
              edits: dict.insert(model.edits, field, raw),
            )
          #(
            model,
            wapi.save_field(model.instance_id, step, field, field_value, Saved),
            Working,
          )
        }
        Error(_) -> working(model)
      }
    None -> working(model)
  }
}

// --- view -------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  case model.schema, model.draft {
    Some(schema), Some(draft) ->
      case find_step(schema, model.step) {
        Some(step) ->
          html.div([attribute.class("wizard wizard--modal")], [
            view_rail(schema, draft),
            html.div([attribute.class("wizard__panel")], [
              html.h2([], [html.text(step.title)]),
              render.step_view(step, display_map(model, step), FieldChanged),
              view_error(model.error),
              view_footer(model, schema, step, draft),
            ]),
          ])
        None -> html.p([], [html.text("Loading…")])
      }
    _, _ -> html.p([], [html.text("Loading…")])
  }
}

fn view_rail(schema: WorkflowSchema, draft: DraftView) -> Element(Msg) {
  html.ol(
    [attribute.class("wizard__rail")],
    list.map(schema.steps, fn(step) {
      let status = case dict.get(draft.step_status, step.id) {
        Ok(status) -> status
        Error(_) -> Pending
      }
      html.li([attribute.class("wizard__rail-step " <> status_class(status))], [
        html.text(step.title),
      ])
    }),
  )
}

fn status_class(status: StepStatus) -> String {
  case status {
    Done -> "is-done"
    Active -> "is-active"
    Pending -> "is-pending"
    Locked -> "is-locked"
  }
}

fn view_footer(
  model: Model,
  schema: WorkflowSchema,
  step: Step,
  draft: DraftView,
) -> Element(Msg) {
  let back = case prev_step_id(model) {
    Some(_) ->
      html.button(
        [attribute.class("btn btn--ghost"), event.on_click(BackClicked)],
        [
          html.text("← Back"),
        ],
      )
    None -> element.none()
  }
  let undo =
    html.button(
      [attribute.class("btn btn--ghost"), event.on_click(UndoClicked)],
      [
        html.text("Undo"),
      ],
    )
  let redo =
    html.button(
      [attribute.class("btn btn--ghost"), event.on_click(RedoClicked)],
      [
        html.text("Redo"),
      ],
    )
  let advance = case is_gated(step), next_gated(schema, step) {
    True, _ ->
      case draft.can_act {
        True ->
          html.button([attribute.class("btn"), event.on_click(CommitClicked)], [
            html.text("Confirm & commit"),
          ])
        False -> html.p([], [html.text("Awaiting Finance confirmation.")])
      }
    False, True ->
      html.button([attribute.class("btn"), event.on_click(HandOffClicked)], [
        html.text("Hand off to Finance →"),
      ])
    False, False ->
      html.button([attribute.class("btn"), event.on_click(NextClicked)], [
        html.text("Continue →"),
      ])
  }
  html.div([attribute.class("wizard__footer")], [back, undo, redo, advance])
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

fn is_gated(step: Step) -> Bool {
  case step.requires_permission {
    Some(_) -> True
    None -> False
  }
}

fn next_gated(schema: WorkflowSchema, step: Step) -> Bool {
  case neighbour(schema, step.id, 1) {
    Some(next) ->
      case find_step(schema, next) {
        Some(found) -> is_gated(found)
        None -> False
      }
    None -> False
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

fn saved_field_value(
  model: Model,
  step_id: String,
  field_key: String,
) -> Option(value.FieldValue) {
  case model.draft {
    Some(draft) ->
      option.from_result(dict.get(draft.values, step_id <> "." <> field_key))
    None -> None
  }
}

fn saved_value(model: Model, step_id: String, field_key: String) -> String {
  case model.draft {
    Some(draft) ->
      case dict.get(draft.values, step_id <> "." <> field_key) {
        Ok(field_value) -> value.to_input(field_value)
        Error(_) -> ""
      }
    None -> ""
  }
}

fn display_map(model: Model, step: Step) -> Dict(String, String) {
  let fields = list.flat_map(step.sections, fn(section) { section.fields })
  list.fold(fields, dict.new(), fn(acc, field) {
    let shown = case dict.get(model.edits, field.key) {
      Ok(value) -> value
      Error(_) -> saved_value(model, step.id, field.key)
    }
    dict.insert(acc, field.key, shown)
  })
}

fn set_value(
  draft: Option(DraftView),
  step_id: String,
  field_key: String,
  field_value: value.FieldValue,
) -> Option(DraftView) {
  case draft {
    Some(current) ->
      Some(
        DraftView(
          ..current,
          values: dict.insert(
            current.values,
            step_id <> "." <> field_key,
            field_value,
          ),
        ),
      )
    None -> None
  }
}
