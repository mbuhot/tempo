//// The Meetings page's state machine: the loadable-list model, the messages,
//// init/refetch, the update fold (granular op-form launches plus the bespoke
//// `ScheduleMeeting` create form), the fetches, and the pure command-building
//// and local-time helpers the view and tests draw from.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/time
import client/ui/ops
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp
import lustre/effect.{type Effect}
import rsvp
import shared/command as gateway
import shared/location/view.{type EngineerLocation, engineer_location_decoder}
import shared/meeting/command.{Required}
import shared/meeting/view.{type MeetingRecord, meeting_record_decoder} as meeting_view

pub type State {
  MeetingsLoading
  MeetingsLoaded(records: List(MeetingRecord))
  MeetingsFailed(detail: String)
}

/// One row of the create form's attendee list: an engineer plus the
/// `Attendance` they are invited with.
pub type Attendee {
  Attendee(engineer_id: Int, attendance: command.Attendance)
}

/// Names a slot of the bespoke `CreateForm` — the create form's own field
/// enum, distinct from `ops.OpField` since `ScheduleMeeting` is built directly
/// rather than through the scalar op-form engine.
pub type CreateField {
  CreateTitle
  CreateTimezone
  CreateDate
  CreateStartsAt
  CreateDurationMinutes
  CreateLocation
  CreateClientId
  CreateProjectId
}

/// The "Schedule meeting" create form: scalar fields plus a repeated
/// attendee list built by searching the engineer roster.
pub type CreateForm {
  CreateForm(
    title: String,
    timezone: String,
    date: String,
    starts_at: String,
    duration_minutes: String,
    location: String,
    client_id: String,
    project_id: String,
    attendees: List(Attendee),
    query: String,
    error: Option(String),
  )
}

pub type Model {
  Model(
    as_of: Date,
    actor: String,
    state: State,
    op: Option(ops.OpState),
    roster: List(EngineerLocation),
    create: Option(CreateForm),
  )
}

pub type Msg {
  Fetched(as_of: Date, result: Result(List(MeetingRecord), rsvp.Error(String)))
  RosterFetched(result: Result(List(EngineerLocation), rsvp.Error(String)))
  RescheduleOpened(permit: ops.Permit, record: MeetingRecord)
  CancelOpened(permit: ops.Permit, meeting_id: Int)
  AddAttendeeOpened(permit: ops.Permit, meeting_id: Int)
  RemoveAttendeeOpened(permit: ops.Permit, meeting_id: Int, engineer_id: Int)
  OpCancelled
  OpFieldEdited(field: ops.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
  CreateOpened
  CreateCancelled
  CreateFieldEdited(field: CreateField, value: String)
  AttendeeQueryChanged(query: String)
  AttendeeAdded(engineer_id: Int)
  AttendeeRemoved(engineer_id: Int)
  AttendanceSet(engineer_id: Int, attendance: command.Attendance)
  CreateSubmitted
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: MeetingsLoading,
      op: None,
      roster: [],
      create: None,
    ),
    effect.batch([fetch(as_of), fetch_roster(as_of)]),
  )
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, actor:),
    effect.batch([fetch(as_of), fetch_roster(as_of)]),
  )
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/meetings?as_of=" <> time.iso_date(as_of),
    decode.list(meeting_record_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}

/// The engineer roster (every engineer plus their location as-of `as_of`) the
/// create form's attendee search filters over.
fn fetch_roster(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/locations?as_of=" <> time.iso_date(as_of),
    decode.list(engineer_location_decoder()),
    RosterFetched,
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Fetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(records) -> MeetingsLoaded(records:)
            Error(error) -> MeetingsFailed(detail: api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }

    RosterFetched(result:) -> {
      let roster = result |> result.unwrap([])
      #(Model(..model, roster:), effect.none(), [])
    }

    RescheduleOpened(permit:, record:) -> {
      let kind = ops.permit_kind(permit)
      let meeting_view.MeetingRecord(
        meeting_id:,
        meeting_tz:,
        starts_at:,
        ends_at:,
        canonical_offset_minutes:,
        ..,
      ) = record
      let form =
        ops.blank_op_form(kind, model.as_of)
        |> ops.update_op_form(ops.FMeetingId, int.to_string(meeting_id))
        |> ops.update_op_form(
          ops.FEffective,
          time.iso_date(local_date(starts_at, canonical_offset_minutes)),
        )
        |> ops.update_op_form(
          ops.FStartsAt,
          local_time(starts_at, canonical_offset_minutes),
        )
        |> ops.update_op_form(
          ops.FDurationMinutes,
          int.to_string(minutes_between(starts_at, ends_at)),
        )
        |> ops.update_op_form(ops.FTimezone, meeting_tz)
      #(
        Model(..model, op: Some(ops.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    CancelOpened(permit:, meeting_id:) -> #(
      open_op(model, permit, meeting_id),
      effect.none(),
      [],
    )

    AddAttendeeOpened(permit:, meeting_id:) -> #(
      open_op(model, permit, meeting_id),
      effect.none(),
      [],
    )

    RemoveAttendeeOpened(permit:, meeting_id:, engineer_id:) -> {
      let kind = ops.permit_kind(permit)
      let form =
        ops.blank_op_form(kind, model.as_of)
        |> ops.update_op_form(ops.FMeetingId, int.to_string(meeting_id))
        |> ops.update_op_form(ops.FEngineerId, int.to_string(engineer_id))
      #(
        Model(..model, op: Some(ops.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(ops.OpState(kind:, form:, ..)) -> #(
          Model(
            ..model,
            op: Some(ops.OpState(
              kind:,
              form: ops.update_op_form(form, field, value),
              error: None,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(ops.OpState(kind:, form:, ..)) ->
          case ops.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ops.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch_effect) =
            refetch(
              Model(..model, op: None, create: None),
              model.as_of,
              model.actor,
            )
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) -> #(
          set_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }

    CreateOpened -> #(
      Model(..model, create: Some(blank_create_form())),
      effect.none(),
      [],
    )

    CreateCancelled -> #(Model(..model, create: None), effect.none(), [])

    CreateFieldEdited(field:, value:) ->
      case model.create {
        Some(form) -> #(
          Model(
            ..model,
            create: Some(
              CreateForm(..update_create_field(form, field, value), error: None),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeQueryChanged(query:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(CreateForm(..form, query:))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeAdded(engineer_id:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(add_attendee(form, engineer_id))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeRemoved(engineer_id:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(remove_attendee(form, engineer_id))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendanceSet(engineer_id:, attendance:) ->
      case model.create {
        Some(form) -> #(
          Model(
            ..model,
            create: Some(set_attendance(form, engineer_id, attendance)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    CreateSubmitted ->
      case model.create {
        Some(form) ->
          case build_schedule_command(form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                create: Some(CreateForm(..form, error: Some(message))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }
  }
}

/// Open `permit`'s op with a form pre-filled with `meeting_id` only — the shape
/// shared by cancel and add-attendee, which need no other prefill.
fn open_op(model: Model, permit: ops.Permit, meeting_id: Int) -> Model {
  let kind = ops.permit_kind(permit)
  let form =
    ops.blank_op_form(kind, model.as_of)
    |> ops.update_op_form(ops.FMeetingId, int.to_string(meeting_id))
  Model(..model, op: Some(ops.OpState(kind:, form:, error: None)))
}

/// Surface a rejection on whichever modal is open — the bespoke create form
/// takes priority since it and the granular op-form modal are never open
/// together.
fn set_error(model: Model, message: String) -> Model {
  case model.create {
    Some(form) ->
      Model(..model, create: Some(CreateForm(..form, error: Some(message))))
    None -> set_op_error(model, message)
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ops.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ops.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

// --- Create form --------------------------------------------------------

/// A blank "Schedule meeting" form, opened by the "New meeting" launcher.
fn blank_create_form() -> CreateForm {
  CreateForm(
    title: "",
    timezone: "",
    date: "",
    starts_at: "",
    duration_minutes: "",
    location: "",
    client_id: "",
    project_id: "",
    attendees: [],
    query: "",
    error: None,
  )
}

/// Fold a `CreateFieldEdited` edit into the matching `CreateForm` slot.
fn update_create_field(
  form: CreateForm,
  field: CreateField,
  value: String,
) -> CreateForm {
  case field {
    CreateTitle -> CreateForm(..form, title: value)
    CreateTimezone -> CreateForm(..form, timezone: value)
    CreateDate -> CreateForm(..form, date: value)
    CreateStartsAt -> CreateForm(..form, starts_at: value)
    CreateDurationMinutes -> CreateForm(..form, duration_minutes: value)
    CreateLocation -> CreateForm(..form, location: value)
    CreateClientId -> CreateForm(..form, client_id: value)
    CreateProjectId -> CreateForm(..form, project_id: value)
  }
}

/// Append `engineer_id` as a `Required` attendee, unless already present.
fn add_attendee(form: CreateForm, engineer_id: Int) -> CreateForm {
  case
    list.any(form.attendees, fn(attendee) {
      attendee.engineer_id == engineer_id
    })
  {
    True -> form
    False ->
      CreateForm(
        ..form,
        attendees: list.append(form.attendees, [
          Attendee(engineer_id:, attendance: Required),
        ]),
        query: "",
      )
  }
}

/// Drop `engineer_id` from the attendee list.
fn remove_attendee(form: CreateForm, engineer_id: Int) -> CreateForm {
  CreateForm(
    ..form,
    attendees: list.filter(form.attendees, fn(attendee) {
      attendee.engineer_id != engineer_id
    }),
  )
}

/// Set `engineer_id`'s `Attendance`, leaving every other row untouched.
fn set_attendance(
  form: CreateForm,
  engineer_id: Int,
  attendance: command.Attendance,
) -> CreateForm {
  CreateForm(
    ..form,
    attendees: list.map(form.attendees, fn(attendee) {
      case attendee.engineer_id == engineer_id {
        True -> Attendee(..attendee, attendance:)
        False -> attendee
      }
    }),
  )
}

/// The pure, testable heart of the create form: validate + assemble a
/// `ScheduleMeeting` command, or report the first thing missing.
pub fn build_schedule_command(
  form: CreateForm,
) -> Result(gateway.Command, String) {
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  use date <- result.try(parse_date(form.date))
  use client_id <- result.try(optional_int("client id", form.client_id))
  use project_id <- result.try(optional_int("project id", form.project_id))
  case form.title, form.timezone, form.attendees {
    "", _, _ -> Error("title is required")
    _, "", _ -> Error("timezone is required")
    _, _, [] -> Error("add at least one attendee")
    title, timezone, attendees ->
      Ok(
        gateway.MeetingCommand(command.ScheduleMeeting(
          title:,
          timezone:,
          date:,
          starts_at: form.starts_at,
          duration_minutes: duration,
          location: optional_text(form.location),
          client_id:,
          project_id:,
          attendees: list.map(attendees, fn(attendee) {
            #(attendee.engineer_id, attendee.attendance)
          }),
        )),
      )
  }
}

/// `""` (after trimming) becomes `None`; anything else is `Some(trimmed)`.
fn optional_text(raw: String) -> Option(String) {
  case string.trim(raw) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// `""` (after trimming) becomes `Ok(None)`; a non-numeric value becomes an
/// `Error` naming `field`.
fn optional_int(field: String, raw: String) -> Result(Option(Int), String) {
  case string.trim(raw) {
    "" -> Ok(None)
    trimmed ->
      int.parse(trimmed)
      |> result.map(Some)
      |> result.replace_error(field <> " must be a number")
  }
}

/// Parse a `YYYY-MM-DD` field into a `calendar.Date`, or a message naming the
/// expected shape.
fn parse_date(raw: String) -> Result(Date, String) {
  time.parse_iso_date(string.trim(raw))
  |> result.replace_error("date must be YYYY-MM-DD")
}

// --- Time formatting ---------------------------------------------------------

/// An ISO-8601 UTC instant shifted by `offset_minutes` (minutes east of UTC)
/// and split into its local calendar date and wall-clock time — the shared
/// arithmetic behind `local_time`, `local_date`, and the reschedule prefill.
fn shift_local(
  starts_at_iso: String,
  offset_minutes: Int,
) -> #(Date, calendar.TimeOfDay) {
  let assert Ok(instant) = timestamp.parse_rfc3339(starts_at_iso)
  let shifted = timestamp.add(instant, duration.minutes(offset_minutes))
  timestamp.to_calendar(shifted, calendar.utc_offset)
}

/// The wall-clock "HH:MM" for `starts_at` (an ISO-8601 UTC instant) shifted by
/// `offset_minutes` (minutes east of UTC), so the caller can render a meeting's
/// canonical time or any attendee's local time from the same wire instant.
pub fn local_time(starts_at_iso: String, offset_minutes: Int) -> String {
  let #(_date, time_of_day) = shift_local(starts_at_iso, offset_minutes)
  pad2(time_of_day.hours) <> ":" <> pad2(time_of_day.minutes)
}

/// The local calendar date for `starts_at` shifted by `offset_minutes` — used to
/// pre-fill the reschedule form's date field from a meeting's own timezone.
fn local_date(starts_at_iso: String, offset_minutes: Int) -> Date {
  let #(date, _time_of_day) = shift_local(starts_at_iso, offset_minutes)
  date
}

/// The whole-minute span between two ISO-8601 UTC instants — used to pre-fill
/// the reschedule form's duration field from a meeting's `starts_at`/`ends_at`.
fn minutes_between(starts_at_iso: String, ends_at_iso: String) -> Int {
  let assert Ok(starts_at) = timestamp.parse_rfc3339(starts_at_iso)
  let assert Ok(ends_at) = timestamp.parse_rfc3339(ends_at_iso)
  float.round(
    duration.to_seconds(timestamp.difference(starts_at, ends_at)) /. 60.0,
  )
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}
