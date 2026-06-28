//// The onboarding wizard page. `/onboard` is the landing — start a new flow or
//// resume one from the queue; `/onboard/<id>/<step>` is the wizard open at a step.
//// The schema drives the rendering generically; field values autosave on blur and
//// mirror to localStorage; undo/redo is a per-step buffer that re-saves; the footer
//// advances steps (browser back/forward via the URL), hands off to Finance, or
//// commits. Implements the frozen page contract (init/update/view/refetch + OutMsg).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/workflow/api as wapi
import client/workflow/draft_cache
import client/workflow/render.{
  type FieldEvent, Committed as FieldCommitted, Edited,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/workflow/schema.{type FieldType, type Step, type WorkflowSchema}
import shared/workflow/value
import shared/workflow/view.{
  type DraftSummary, type DraftView, type StepStatus, Active, Done, DraftView,
  Locked, Pending,
}

const kind = "onboard_engineer"

const first_step = "identity"

pub type Model {
  Model(
    as_of: calendar.Date,
    actor: String,
    instance_id: Option(String),
    route_step: Option(String),
    schema: Option(WorkflowSchema),
    draft: Option(DraftView),
    drafts: Option(Result(List(DraftSummary), String)),
    edits: Dict(String, String),
    undo: List(#(String, String)),
    redo: List(#(String, String)),
    error: String,
  )
}

pub type Msg {
  SchemaFetched(Result(WorkflowSchema, rsvp.Error(String)))
  DraftFetched(Result(DraftView, rsvp.Error(String)))
  DraftsFetched(Result(List(DraftSummary), rsvp.Error(String)))
  StartClicked
  Started(Result(String, rsvp.Error(String)))
  ResumeClicked(String)
  FieldChanged(FieldEvent)
  Saved(Result(Nil, rsvp.Error(String)))
  BackClicked
  NextClicked
  StepAdvanced(String, Result(Nil, rsvp.Error(String)))
  UndoClicked
  RedoClicked
  HandOffClicked
  HandedOff(Result(Nil, rsvp.Error(String)))
  CancelClicked
  Cancelled(Result(Nil, rsvp.Error(String)))
  CommitClicked
  CommitReturned(Result(Nil, rsvp.Error(String)))
}

pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(instance_id, route_step) = case route {
    route.Onboard(instance_id:, step_id:) -> #(instance_id, step_id)
    _ -> #(None, None)
  }
  let model =
    Model(
      as_of:,
      actor:,
      instance_id:,
      route_step:,
      schema: None,
      draft: None,
      drafts: None,
      edits: dict.new(),
      undo: [],
      redo: [],
      error: "",
    )
  let load = case instance_id {
    Some(id) -> wapi.fetch_draft(id, DraftFetched)
    None -> wapi.fetch_drafts(DraftsFetched)
  }
  #(model, effect.batch([wapi.fetch_schema(kind, SchemaFetched), load]))
}

pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let next = Model(..model, as_of:, actor:)
  case model.instance_id {
    Some(id) -> #(next, wapi.fetch_draft(id, DraftFetched))
    None -> #(next, wapi.fetch_drafts(DraftsFetched))
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    SchemaFetched(Ok(schema)) -> #(
      Model(..model, schema: Some(schema)),
      effect.none(),
      [],
    )
    SchemaFetched(Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )

    DraftFetched(Ok(draft)) -> #(
      Model(..model, draft: Some(draft)),
      draft_cache.save(draft),
      [],
    )
    DraftFetched(Error(error)) ->
      case model.instance_id {
        Some(id) ->
          case draft_cache.load(id) {
            Some(cached) -> #(
              Model(..model, draft: Some(cached)),
              effect.none(),
              [],
            )
            None -> #(
              Model(..model, error: api.describe_error(error)),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    DraftsFetched(result) -> #(
      Model(
        ..model,
        drafts: Some(case result {
          Ok(drafts) -> Ok(drafts)
          Error(error) -> Error(api.describe_error(error))
        }),
      ),
      effect.none(),
      [],
    )

    StartClicked -> #(model, wapi.start(kind, Started), [])
    Started(Ok(id)) -> #(model, effect.none(), [
      Navigate(route.Onboard(Some(id), Some(first_step))),
    ])
    Started(Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )

    ResumeClicked(id) -> #(model, effect.none(), [
      Navigate(route.Onboard(Some(id), None)),
    ])

    FieldChanged(Edited(field:, raw:, ..)) -> #(
      Model(..model, edits: dict.insert(model.edits, field, raw)),
      effect.none(),
      [],
    )
    FieldChanged(FieldCommitted(step:, field:, raw:)) ->
      commit_field(model, step, field, raw)

    Saved(Ok(_)) -> #(model, effect.none(), [])
    Saved(Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )

    UndoClicked -> step_undo(model)
    RedoClicked -> step_redo(model)

    BackClicked ->
      case model.instance_id, prev_step_id(model) {
        Some(id), Some(prev) -> #(model, effect.none(), [
          Navigate(route.Onboard(Some(id), Some(prev))),
        ])
        _, _ -> #(model, effect.none(), [])
      }

    NextClicked ->
      case model.instance_id, next_step_id(model) {
        Some(id), Some(next) -> #(
          model,
          wapi.complete_step(id, next, StepAdvanced(next, _)),
          [],
        )
        _, _ -> #(model, effect.none(), [])
      }
    StepAdvanced(next, Ok(_)) ->
      case model.instance_id {
        Some(id) -> #(model, effect.none(), [
          Navigate(route.Onboard(Some(id), Some(next))),
        ])
        None -> #(model, effect.none(), [])
      }
    StepAdvanced(_, Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )

    HandOffClicked ->
      case model.instance_id {
        Some(id) -> #(model, wapi.hand_off(id, HandedOff), [])
        None -> #(model, effect.none(), [])
      }
    HandedOff(Ok(_)) -> #(model, effect.none(), [
      Navigate(route.Onboard(None, None)),
    ])
    HandedOff(Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )

    CancelClicked ->
      case model.instance_id {
        Some(id) -> #(model, wapi.cancel(id, Cancelled), [])
        None -> #(model, effect.none(), [])
      }
    Cancelled(_) -> #(model, effect.none(), [
      Navigate(route.Onboard(None, None)),
    ])

    CommitClicked ->
      case model.instance_id {
        Some(id) -> #(model, wapi.commit(id, CommitReturned), [])
        None -> #(model, effect.none(), [])
      }
    CommitReturned(Ok(_)) -> #(model, effect.none(), [
      OperationCommitted,
      Navigate(route.Board),
    ])
    CommitReturned(Error(error)) -> #(
      Model(..model, error: api.describe_error(error)),
      effect.none(),
      [],
    )
  }
}

/// Optimistically apply a committed field value, record undo, and save to the server.
fn commit_field(
  model: Model,
  step: String,
  field: String,
  raw: String,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model.instance_id, field_type(model, step, field) {
    Some(id), Some(kind) ->
      case value.parse(kind, raw), saved_field_value(model, step, field) {
        // A blur that doesn't change the value (tabbing through) is a no-op: no
        // save, no undo entry, and the redo stack is left intact.
        Ok(field_value), saved if Some(field_value) == saved -> #(
          model,
          effect.none(),
          [],
        )
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
          #(model, wapi.save_field(id, step, field, field_value, Saved), [])
        }
        Error(_), _ -> #(
          Model(
            ..model,
            edits: dict.insert(model.edits, field, raw),
            error: "That value isn't valid for this field.",
          ),
          effect.none(),
          [],
        )
      }
    _, _ -> #(model, effect.none(), [])
  }
}

fn step_undo(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  let step = current_step_id(model)
  case model.instance_id, model.undo {
    Some(id), [#(field, prev), ..rest] ->
      apply_restore(model, id, step, field, prev, fn(current) {
        Model(..model, undo: rest, redo: [#(field, current), ..model.redo])
      })
    _, _ -> #(model, effect.none(), [])
  }
}

fn step_redo(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  let step = current_step_id(model)
  case model.instance_id, model.redo {
    Some(id), [#(field, next), ..rest] ->
      apply_restore(model, id, step, field, next, fn(current) {
        Model(..model, redo: rest, undo: [#(field, current), ..model.undo])
      })
    _, _ -> #(model, effect.none(), [])
  }
}

/// Restore `field` to `raw` (undo/redo), moving the value it replaces onto the other
/// stack via `bookkeep`, and re-save.
fn apply_restore(
  model: Model,
  id: String,
  step: String,
  field: String,
  raw: String,
  bookkeep: fn(String) -> Model,
) -> #(Model, Effect(Msg), List(OutMsg)) {
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
          #(model, wapi.save_field(id, step, field, field_value, Saved), [])
        }
        Error(_) -> #(model, effect.none(), [])
      }
    None -> #(model, effect.none(), [])
  }
}

// --- view -------------------------------------------------------------------

pub fn view(
  model: Model,
  _as_of: calendar.Date,
  _permissions: a,
) -> Element(Msg) {
  case model.instance_id {
    None -> view_landing(model)
    Some(_) -> view_wizard(model)
  }
}

fn view_landing(model: Model) -> Element(Msg) {
  html.div([attribute.class("wizard wizard--landing")], [
    html.h1([], [html.text("Onboard an engineer")]),
    html.p([], [
      html.text("Start a new onboarding, or continue one in progress."),
    ]),
    html.button(
      [attribute.class("login__submit"), event.on_click(StartClicked)],
      [html.text("Start onboarding")],
    ),
    view_error(model.error),
    view_drafts(model.drafts),
  ])
}

fn view_drafts(
  drafts: Option(Result(List(DraftSummary), String)),
) -> Element(Msg) {
  case drafts {
    None -> html.p([], [html.text("Loading…")])
    Some(Error(message)) -> view_error(message)
    Some(Ok([])) -> element.none()
    Some(Ok(summaries)) ->
      html.div([attribute.class("wizard__resume")], [
        html.h3([], [html.text("In progress")]),
        html.ul(
          [],
          list.map(summaries, fn(summary) {
            html.li([], [
              html.button([event.on_click(ResumeClicked(summary.instance_id))], [
                html.text(resume_label(summary)),
              ]),
            ])
          }),
        ),
      ])
  }
}

fn resume_label(summary: DraftSummary) -> String {
  let suffix = case summary.awaiting_me {
    True -> " — awaiting you"
    False -> " — " <> summary.current_step
  }
  summary.title <> suffix
}

fn view_wizard(model: Model) -> Element(Msg) {
  case model.schema, model.draft {
    Some(schema), Some(draft) -> {
      let step_id = current_step_id(model)
      case find_step(schema, step_id) {
        Some(step) ->
          html.div([attribute.class("wizard")], [
            view_rail(schema, draft),
            html.div([attribute.class("wizard__panel")], [
              html.h2([], [html.text(step.title)]),
              render.step_view(step, display_map(model, step), FieldChanged),
              view_error(model.error),
              view_footer(model, schema, step, draft),
            ]),
          ])
        None -> html.p([], [html.text("Unknown step.")])
      }
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
    Some(_) -> html.button([event.on_click(BackClicked)], [html.text("← Back")])
    None -> element.none()
  }
  let undo = html.button([event.on_click(UndoClicked)], [html.text("Undo")])
  let redo = html.button([event.on_click(RedoClicked)], [html.text("Redo")])
  let advance = case is_gated(step), next_gated(schema, step) {
    True, _ ->
      case draft.can_act {
        True ->
          html.button(
            [attribute.class("login__submit"), event.on_click(CommitClicked)],
            [html.text("Confirm & commit")],
          )
        False -> html.p([], [html.text("Awaiting Finance confirmation.")])
      }
    False, True ->
      html.button(
        [attribute.class("login__submit"), event.on_click(HandOffClicked)],
        [html.text("Hand off to Finance →")],
      )
    False, False ->
      html.button(
        [attribute.class("login__submit"), event.on_click(NextClicked)],
        [html.text("Continue →")],
      )
  }
  html.div([attribute.class("wizard__footer")], [
    back,
    undo,
    redo,
    advance,
    html.button([event.on_click(CancelClicked)], [html.text("Cancel")]),
  ])
}

fn view_error(error: String) -> Element(Msg) {
  case error {
    "" -> element.none()
    message ->
      html.p([attribute.class("login__error"), attribute.role("alert")], [
        html.text(message),
      ])
  }
}

// --- helpers ----------------------------------------------------------------

fn current_step_id(model: Model) -> String {
  case model.route_step, model.draft {
    Some(step), _ -> step
    None, Some(draft) -> draft.current_step
    None, None -> first_step
  }
}

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

/// Whether the step AFTER `step` is permission-gated (so this is the last step a
/// non-Finance owner fills, and the footer should hand off rather than advance).
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
    Some(schema) -> neighbour(schema, current_step_id(model), 1)
    None -> None
  }
}

fn prev_step_id(model: Model) -> Option(String) {
  case model.schema {
    Some(schema) -> neighbour(schema, current_step_id(model), -1)
    None -> None
  }
}

/// The id of the step `offset` positions from `step_id` in schema order, or `None`
/// if out of range.
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

/// The last-saved value of a field as its typed `FieldValue`, or `None` if unset.
/// Used to skip a no-op blur (the value the user tabbed past is unchanged).
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

/// The last-saved value for a field, read from the draft (the server-confirmed,
/// optimistically-updated source of truth).
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

/// The string shown in a field's control: the live edit buffer if present, else the
/// last-saved value.
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

/// Optimistically set a field's value in the draft view.
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
