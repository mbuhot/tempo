//// The Meetings page's granular contextual-operation form: the centred op
//// modal and the per-kind field sets (Reschedule/Cancel/Add attendee/Remove
//// attendee) built on the shared `ui/ops` op-form engine, plus the op
//// titles/verbs.

import client/page/meetings/update.{
  type Msg, OpCancelled, OpFieldEdited, OpSubmitted,
}
import client/ui/atoms
import client/ui/ops
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn view_op_modal(op: Option(ops.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ops.OpState(kind:, form:, error:)) ->
      atoms.modal(
        title: op_title(kind),
        error: option.unwrap(error, ""),
        body: op_fields(kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

fn op_title(kind: ops.OpKind) -> String {
  case kind {
    ops.OpRescheduleMeeting -> "Reschedule meeting"
    ops.OpCancelMeeting -> "Cancel meeting"
    ops.OpAddAttendee -> "Add attendee"
    ops.OpRemoveAttendee -> "Remove attendee"
    _ -> ""
  }
}

/// The confirm-button verb for an operation kind — the action the presenter is
/// committing, not a generic "Confirm".
fn op_verb(kind: ops.OpKind) -> String {
  case kind {
    ops.OpRescheduleMeeting -> "Reschedule"
    ops.OpCancelMeeting -> "Cancel meeting"
    ops.OpAddAttendee -> "Add"
    ops.OpRemoveAttendee -> "Remove"
    _ -> "Confirm"
  }
}

fn op_fields(kind: ops.OpKind, form: ops.OpForm) -> List(Element(Msg)) {
  case kind {
    ops.OpRescheduleMeeting -> [
      date_field("Date", ops.FEffective, form.effective),
      text_field("Start (HH:MM)", ops.FStartsAt, form.starts_at),
      text_field(
        "Duration (minutes)",
        ops.FDurationMinutes,
        form.duration_minutes,
      ),
      text_field("Timezone (IANA TZID)", ops.FTimezone, form.timezone),
    ]
    ops.OpCancelMeeting -> [
      html.p([], [html.text("Cancel meeting #" <> form.meeting_id <> "?")]),
    ]
    ops.OpAddAttendee -> [
      text_field("Engineer id", ops.FEngineerId, form.engineer_id),
      attendance_select(form.attendance),
    ]
    ops.OpRemoveAttendee -> [
      html.p([], [
        html.text(
          "Remove engineer #"
          <> form.engineer_id
          <> " from meeting #"
          <> form.meeting_id
          <> "?",
        ),
      ]),
    ]
    _ -> []
  }
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

/// A labelled `<select>` over the two `Attendance` values, bound to the
/// `FAttendance` slot.
fn attendance_select(selected: String) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Attendance")]),
    html.select(
      [
        attribute.attribute("aria-label", "Attendance"),
        event.on_change(fn(value) { OpFieldEdited(ops.FAttendance, value) }),
      ],
      [
        html.option(
          [
            attribute.value("required"),
            attribute.selected(selected == "required"),
          ],
          "Required",
        ),
        html.option(
          [
            attribute.value("optional"),
            attribute.selected(selected == "optional"),
          ],
          "Optional",
        ),
      ],
    ),
  ])
}
