//// The Projects page's contextual-operation form: the centred op modal and the
//// per-kind field sets — entity `<select>`s over the as-of roster (the project
//// locked to the project in view on the detail page), the level and capability
//// selects, and the op titles/verbs.

import client/page/projects/update.{
  type Load, type Msg, Loaded, OpCancelled, OpFieldEdited, OpSubmitted,
  roster_engineers, roster_projects,
}
import client/ui/atoms
import client/ui/format
import client/ui/ops
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/invoice/view as _
import shared/project_capability/view as coverage_view
import shared/roster/view as roster_view

// --- Op-form modal -----------------------------------------------------------

/// The contextual operation, shown as a centred modal over a dimmed backdrop when
/// an op is open. Renders the kind-specific fields (engineer/project as `<select>`s
/// from the as-of directory, the project locked to the project in view on the
/// detail page), the last rejection message, and a Cancel / verb-labelled Confirm
/// footer. `locked_project_id`, when present, pins the project select to that id.
pub fn op_modal(
  op: Option(ops.OpState),
  roster: Load(roster_view.Roster),
  coverage: Load(coverage_view.CoverageSnapshot),
  locked_project_id: Option(Int),
) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ops.OpState(kind:, form:, error:)) ->
      atoms.modal(
        title: op_title(kind),
        error: error_text(error),
        body: op_fields(kind, form, roster, coverage, locked_project_id),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

fn error_text(error: Option(String)) -> String {
  case error {
    None -> ""
    Some(message) -> message
  }
}

/// The form fields for the open op. Entity ids are `<select>`s over the as-of
/// roster; the project is locked when a `locked_project_id` is in view; the
/// engineer (AssignToProject / ChangeAllocationFraction) is a free select.
/// StartProject keeps a typed numeric Contract id — the roster carries no contract
/// directory to select over.
fn op_fields(
  kind: ops.OpKind,
  form: ops.OpForm,
  roster: Load(roster_view.Roster),
  coverage: Load(coverage_view.CoverageSnapshot),
  locked_project_id: Option(Int),
) -> List(Element(Msg)) {
  let engineers = roster_engineers(roster)
  let projects = roster_projects(roster)
  let project_select = project_field(form, projects, locked_project_id)
  let engineer_select =
    ops.ref_select(
      label: "Engineer",
      field: ops.FEngineerId,
      refs: engineers,
      selected: form.engineer_id,
      to_msg: edit,
    )
  case kind {
    ops.OpStartProject -> [
      text_field("Title", ops.FName, form.name),
      number_field("Contract id", ops.FContractId, form.contract_id),
      date_field("Valid from", ops.FValidFrom, form.valid_from),
      date_field("Valid to", ops.FValidTo, form.valid_to),
    ]
    ops.OpAssignToProject -> [
      engineer_select,
      project_select,
      number_field("Fraction", ops.FFraction, form.fraction),
      date_field("Valid from", ops.FValidFrom, form.valid_from),
      date_field("Valid to", ops.FValidTo, form.valid_to),
    ]
    ops.OpChangeAllocationFraction -> [
      engineer_select,
      project_select,
      number_field("Fraction", ops.FFraction, form.fraction),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpUpdateProjectProfile -> [
      project_select,
      text_field("Title", ops.FTitle, form.title),
      text_field("Summary", ops.FSummary, form.summary),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpUpdateProjectPlan -> [
      project_select,
      number_field("Budget", ops.FBudget, form.budget),
      date_field(
        "Target completion",
        ops.FTargetCompletion,
        form.target_completion,
      ),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpDraftInvoice -> [
      project_select,
      date_field("Billing from", ops.FValidFrom, form.valid_from),
      date_field("Billing to", ops.FValidTo, form.valid_to),
    ]
    ops.OpSetProjectRequirement -> [
      project_select,
      level_select(form.level),
      number_field("Quantity", ops.FFraction, form.fraction),
      date_field("Valid from", ops.FValidFrom, form.valid_from),
      date_field("Valid to", ops.FValidTo, form.valid_to),
    ]
    ops.OpSetProjectCapability -> [
      project_select,
      capability_select(form.capability_id, coverage),
      target_level_select(form.level),
      number_field("Quantity", ops.FFraction, form.fraction),
      date_field("Valid from", ops.FValidFrom, form.valid_from),
      date_field("Valid to", ops.FValidTo, form.valid_to),
    ]
    _ -> []
  }
}

/// A labelled `<select>` over levels 1–7, bound to the `FLevel` slot. The option
/// value is the level number as text, the label its band name; the form's current
/// level is pre-selected. Built locally so `atoms.gleam` stays frozen.
fn level_select(selected: String) -> Element(Msg) {
  let options =
    [1, 2, 3, 4, 5, 6, 7]
    |> list.map(fn(level) {
      let value = int.to_string(level)
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        format.level_band(level),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Level")]),
    html.select(
      [
        attribute.attribute("aria-label", "Level"),
        event.on_change(fn(value) { OpFieldEdited(ops.FLevel, value) }),
      ],
      options,
    ),
  ])
}

/// A labelled `<select>` over the coverage snapshot's capability catalog, bound to
/// the `FCapabilityId` slot. Sourced from the read-side catalog rather than the
/// `skills.manage`-gated taxonomy, so a `project.manage`-only presenter can still
/// set a requirement.
fn capability_select(
  selected: String,
  coverage: Load(coverage_view.CoverageSnapshot),
) -> Element(Msg) {
  ops.ref_select(
    label: "Capability",
    field: ops.FCapabilityId,
    refs: capability_refs(coverage),
    selected:,
    to_msg: edit,
  )
}

fn capability_refs(
  coverage: Load(coverage_view.CoverageSnapshot),
) -> List(roster_view.Ref) {
  case coverage {
    Loaded(value:) -> list.map(value.catalog, capability_ref)
    _ -> []
  }
}

fn capability_ref(choice: coverage_view.CapabilityChoice) -> roster_view.Ref {
  roster_view.Ref(id: choice.capability_id, name: choice.name)
}

/// A labelled `<select>` over target levels 0–4, bound to the `FLevel` slot. Built
/// locally (rather than in `atoms.gleam`) because the option labels are the
/// capability-proficiency scale, distinct from the engineer seniority `level_band`
/// levels 1–7 the requirement form's `level_select` renders.
fn target_level_select(selected: String) -> Element(Msg) {
  let options =
    [0, 1, 2, 3, 4]
    |> list.map(fn(level) {
      let value = int.to_string(level)
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        int.to_string(level) <> " · " <> capability_level_label(level),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Target level")]),
    html.select(
      [
        attribute.attribute("aria-label", "Target level"),
        event.on_change(fn(value) { OpFieldEdited(ops.FLevel, value) }),
      ],
      options,
    ),
  ])
}

fn capability_level_label(level: Int) -> String {
  case level {
    0 -> "none"
    1 -> "learning"
    2 -> "with supervision"
    3 -> "independent"
    4 -> "expert · can teach"
    _ -> ""
  }
}

/// The project select: a free `<select>` over the roster on the list page, or a
/// locked single-option select pinned to the project in view on the detail page.
fn project_field(
  form: ops.OpForm,
  projects: List(roster_view.Ref),
  locked_project_id: Option(Int),
) -> Element(Msg) {
  case locked_project_id {
    Some(project_id) -> locked_project_select(project_id, projects)
    None ->
      ops.ref_select(
        label: "Project",
        field: ops.FProjectId,
        refs: projects,
        selected: form.project_id,
        to_msg: edit,
      )
  }
}

/// A disabled project select pinned to the project in view: a single option named
/// from the roster (or the bare id while the roster loads). It is inert so the
/// presenter cannot retarget an op composed from a project's page, while the form
/// still carries the pre-filled `FProjectId` for `build_command`.
fn locked_project_select(
  project_id: Int,
  projects: List(roster_view.Ref),
) -> Element(Msg) {
  let id = int.to_string(project_id)
  let name =
    projects
    |> list.find(fn(reference) { reference.id == project_id })
    |> option.from_result
    |> option.map(fn(reference) { reference.name })
    |> option.unwrap("Project #" <> id)
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Project")]),
    html.select(
      [attribute.attribute("aria-label", "Project"), attribute.disabled(True)],
      [html.option([attribute.value(id), attribute.selected(True)], name)],
    ),
  ])
}

// --- Op-form field helpers ---------------------------------------------------

fn text_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(label:, field:, value:, input_type: "text", to_msg: edit)
}

fn number_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(label:, field:, value:, input_type: "number", to_msg: edit)
}

fn date_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(label:, field:, value:, input_type: "date", to_msg: edit)
}

fn edit(field: ops.OpField, value: String) -> Msg {
  OpFieldEdited(field:, value:)
}

fn op_title(kind: ops.OpKind) -> String {
  case kind {
    ops.OpStartProject -> "Start a project"
    ops.OpAssignToProject -> "Assign to project"
    ops.OpChangeAllocationFraction -> "Change allocation fraction"
    ops.OpUpdateProjectProfile -> "Edit project profile"
    ops.OpUpdateProjectPlan -> "Edit project plan"
    ops.OpDraftInvoice -> "Draft an invoice"
    ops.OpSetProjectRequirement -> "Set capacity requirement"
    ops.OpSetProjectCapability -> "Set capability requirement"
    _ -> "Operation"
  }
}

fn op_verb(kind: ops.OpKind) -> String {
  case kind {
    ops.OpStartProject -> "Start project"
    ops.OpAssignToProject -> "Assign"
    ops.OpChangeAllocationFraction -> "Adjust allocation"
    ops.OpUpdateProjectProfile -> "Save profile"
    ops.OpUpdateProjectPlan -> "Save plan"
    ops.OpDraftInvoice -> "Draft invoice"
    ops.OpSetProjectRequirement -> "Set requirement"
    ops.OpSetProjectCapability -> "Set requirement"
    _ -> "Confirm"
  }
}
