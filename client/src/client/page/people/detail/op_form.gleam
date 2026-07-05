//// The People detail's contextual-operation form: the permission-gated launch
//// buttons, the centred op modal, and the per-kind field sets (leave kind, skill
//// and level selects, contact/banking/emergency edits) bound to the shared
//// `ops.OpForm`.

import client/page/people/detail/update.{
  type Model, type Msg, type SkillsData, OpCancelled, OpFieldEdited, OpOpened,
  OpSubmitted, SkillsLoaded, project_refs,
}
import client/ui/atoms
import client/ui/ops
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/leave/kind as leave_kind
import shared/skill/view.{EngineerSkills, SkillAssessment}

// --- Op form ----------------------------------------------------------------

/// A permitted button that opens the contextual operation `kind`: shown only when the
/// principal may run `kind` (minting a `Permit` carried by `OpOpened`), so an ungated
/// detail launcher cannot be expressed. `ghost` renders the secondary (outlined) variant.
pub fn op_launch(
  permissions: Set(String),
  own: Bool,
  kind: ops.OpKind,
  label: String,
  ghost: Bool,
) -> Element(Msg) {
  let button_kind = case ghost {
    True -> atoms.Ghost
    False -> atoms.Primary
  }
  ops.launch(
    ops.permit(permissions, own:, kind:),
    to_msg: OpOpened,
    label:,
    kind: button_kind,
    size: atoms.Small,
  )
}

/// The contextual operation as a centred modal over a dimmed backdrop, shown only
/// while an op is open. Renders the fields the chosen kind needs, the rejection
/// prompt if any, and the Cancel / op-verb Confirm footer.
pub fn view_op_modal(model: Model, op: Option(ops.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ops.OpState(kind:, form:, error:)) ->
      atoms.modal(
        title: op_title(kind),
        error: option.unwrap(error, ""),
        body: op_fields(model, kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

/// The form fields each operation kind reads, bound to the shared `OpForm`: the
/// roll-off project is a `<select>` over the as-of directory, the leave kind a fixed
/// `<select>`, and the contact/banking/emergency edits open pre-filled with the
/// loaded values. Only the detail kinds have a populated arm; any other shows just
/// its engineer-id field (a safe fallback never triggered).
fn op_fields(
  model: Model,
  kind: ops.OpKind,
  form: ops.OpForm,
) -> List(Element(Msg)) {
  case kind {
    ops.OpPromote -> [
      number_field("New level", ops.FLevel, form.level),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpTakeLeave -> [
      leave_kind_field(form.kind),
      date_field("From", ops.FValidFrom, form.valid_from),
      date_field("To", ops.FValidTo, form.valid_to),
    ]
    ops.OpRollOff -> [
      ops.ref_select(
        label: "Project",
        field: ops.FProjectId,
        refs: project_refs(model),
        selected: form.project_id,
        to_msg: OpFieldEdited,
      ),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpTerminateEmployment -> [
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpUpdateContact -> [
      text_field("Name", ops.FName, form.name),
      text_field("Email", ops.FEmail, form.email),
      text_field("Phone", ops.FPhone, form.phone),
      text_field("Address", ops.FPostalAddress, form.postal_address),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpUpdateBanking -> [
      text_field("Bank", ops.FBank, form.bank),
      text_field("BSB", ops.FBranch, form.branch),
      text_field("Account", ops.FAccountNo, form.account_no),
      text_field("Account name", ops.FAccountName, form.account_name),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpUpdateEmergency -> [
      text_field("Relation", ops.FRelation, form.relation),
      text_field("Name", ops.FEmergencyName, form.emergency_name),
      text_field("Phone", ops.FEmergencyPhone, form.emergency_phone),
      text_field("Email", ops.FEmergencyEmail, form.emergency_email),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    ops.OpAssessSkill -> [
      skill_select_field(model.skills, form.skill_id),
      level_select_field(form.level),
      date_field("Assessed from", ops.FEffective, form.effective),
    ]
    ops.OpSetLocation -> [
      text_field("Country", ops.FCountry, form.country),
      text_field("Region", ops.FRegion, form.region),
      text_field("Timezone (IANA TZID)", ops.FTimezone, form.timezone),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    _ -> [number_field("Engineer id", ops.FEngineerId, form.engineer_id)]
  }
}

/// The leave-kind `<select>` for TakeLeave: a fixed list of leave kinds bound to the
/// form's `kind` slot, so the wire value is always one the domain accepts rather
/// than free text. Defaults to "annual" when the slot is blank.
fn leave_kind_field(selected: String) -> Element(Msg) {
  let selected = case selected {
    "" -> leave_kind.to_string(leave_kind.Annual)
    other -> other
  }
  let options =
    list.map(leave_kind.all(), fn(kind) {
      let value = leave_kind.to_string(kind)
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        string.capitalise(value),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Kind")]),
    html.select(
      [
        attribute.attribute("aria-label", "Kind"),
        event.on_change(fn(value) { OpFieldEdited(field: ops.FKind, value:) }),
      ],
      options,
    ),
  ])
}

/// The skill `<select>` for AssessSkill: options are the engineer's loaded skill
/// matrix (skill_id/name), so the wire value is always a skill the taxonomy
/// knows. Shows a disabled placeholder while the matrix is still loading.
fn skill_select_field(skills: SkillsData, selected: String) -> Element(Msg) {
  let options = case skills {
    SkillsLoaded(EngineerSkills(matrix:, ..)) ->
      list.map(matrix, fn(assessment) {
        let SkillAssessment(skill_id:, name:, ..) = assessment
        let id = int.to_string(skill_id)
        html.option(
          [attribute.value(id), attribute.selected(id == selected)],
          name,
        )
      })
    _ -> [
      html.option([attribute.value(""), attribute.disabled(True)], "Loading…"),
    ]
  }
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Skill")]),
    html.select(
      [
        attribute.attribute("aria-label", "Skill"),
        event.on_change(fn(value) { OpFieldEdited(field: ops.FSkillId, value:) }),
      ],
      options,
    ),
  ])
}

/// The fixed 0–4 experience-level `<select>` for AssessSkill, mirroring
/// `leave_kind_field`'s fixed-vocabulary pattern. Defaults to "0" when blank.
fn level_select_field(selected: String) -> Element(Msg) {
  let selected = case selected {
    "" -> "0"
    other -> other
  }
  let levels = [
    #("0", "0 — none"),
    #("1", "1 — learning"),
    #("2", "2 — with supervision"),
    #("3", "3 — independently capable"),
    #("4", "4 — expert · can teach"),
  ]
  let options =
    list.map(levels, fn(level) {
      let #(value, label) = level
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        label,
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Experience level")]),
    html.select(
      [
        attribute.attribute("aria-label", "Experience level"),
        event.on_change(fn(value) { OpFieldEdited(field: ops.FLevel, value:) }),
      ],
      options,
    ),
  ])
}

fn text_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(
    label:,
    field:,
    value:,
    input_type: "text",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn number_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(
    label:,
    field:,
    value:,
    input_type: "number",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn date_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(
    label:,
    field:,
    value:,
    input_type: "date",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn op_title(kind: ops.OpKind) -> String {
  case kind {
    ops.OpPromote -> "Promote"
    ops.OpTakeLeave -> "Take leave"
    ops.OpRollOff -> "Roll off a project"
    ops.OpTerminateEmployment -> "Terminate employment"
    ops.OpUpdateContact -> "Update contact details"
    ops.OpUpdateBanking -> "Update banking details"
    ops.OpUpdateEmergency -> "Update emergency contact"
    ops.OpAssessSkill -> "Assess skill"
    ops.OpSetLocation -> "Set location"
    _ -> "Operation"
  }
}

/// The confirm-button verb for an operation kind — the action the presenter is
/// committing, not a generic "Apply".
fn op_verb(kind: ops.OpKind) -> String {
  case kind {
    ops.OpPromote -> "Promote"
    ops.OpTakeLeave -> "Take leave"
    ops.OpRollOff -> "Roll off"
    ops.OpTerminateEmployment -> "Terminate"
    ops.OpUpdateContact -> "Save contact"
    ops.OpUpdateBanking -> "Save banking"
    ops.OpUpdateEmergency -> "Save emergency"
    ops.OpAssessSkill -> "Record assessment"
    ops.OpSetLocation -> "Set location"
    _ -> "Confirm"
  }
}
