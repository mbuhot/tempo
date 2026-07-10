//// The Meetings page's state machine: the loadable-list model, the messages,
//// init/refetch, the update fold (granular op-form launches, the bespoke
//// `ScheduleMeeting` create form, and the find-a-time wizard's message
//// handling), the fetches, and the pure create-form command-building this
//// module keeps for itself — the find-a-time wizard's own form/validation/
//// command-building lives in `meetings/finder`, and the display-mode/local-time
//// arithmetic in `meetings/time_display`.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/page/meetings/finder.{
  type Attendee, type FinderField, type FinderForm, Attendee, FinderForm, Found,
  Searching, SlotTaken,
}
import client/page/meetings/time_display.{type TimeDisplay, OriginTime}
import client/time
import client/ui/op_commands
import client/ui/ops
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import lustre/effect.{type Effect}
import rsvp
import shared/command as gateway
import shared/location/view.{type EngineerLocation, engineer_location_decoder}
import shared/meeting/command.{Required}
import shared/meeting/view.{
  type CandidateSlot, type MeetingRecord, candidate_slot_decoder,
  meeting_record_decoder,
} as meeting_view
import shared/roster/view.{type Ref, roster_decoder} as _

pub type State {
  MeetingsLoading
  MeetingsLoaded(records: List(MeetingRecord))
  MeetingsFailed(detail: String)
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
    projects: List(Ref),
    create: Option(CreateForm),
    finder: Option(FinderForm),
    notice: Option(String),
    time_display: TimeDisplay,
  )
}

pub type Msg {
  Fetched(as_of: Date, result: Result(List(MeetingRecord), rsvp.Error(String)))
  RosterFetched(result: Result(List(EngineerLocation), rsvp.Error(String)))
  ProjectsFetched(result: Result(List(Ref), rsvp.Error(String)))
  RescheduleOpened(permit: ops.Permit, record: MeetingRecord)
  CancelOpened(permit: ops.Permit, meeting_id: Int)
  AddAttendeeOpened(permit: ops.Permit, meeting_id: Int)
  RemoveAttendeeOpened(permit: ops.Permit, meeting_id: Int, engineer_id: Int)
  AttendanceToggled(
    permit: ops.Permit,
    meeting_id: Int,
    engineer_id: Int,
    attendance: command.Attendance,
  )
  NoticeDismissed
  TimeDisplaySet(display: TimeDisplay)
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
  FinderOpened
  FinderCancelled
  FinderFieldEdited(field: FinderField, value: String)
  FinderAttendeeQueryChanged(query: String)
  FinderAttendeeAdded(engineer_id: Int)
  FinderAllAdded
  FinderAttendeeRemoved(engineer_id: Int)
  FinderAttendanceSet(engineer_id: Int, attendance: command.Attendance)
  FinderFillFromProjectRequested
  FinderProjectTeamFetched(
    project_id: Int,
    result: Result(List(Int), rsvp.Error(String)),
  )
  FinderSearchRequested
  FinderSlotsFetched(result: Result(List(CandidateSlot), rsvp.Error(String)))
  FinderSlotsRefetchedAfterTaken(
    result: Result(List(CandidateSlot), rsvp.Error(String)),
  )
  FinderSlotBooked(slot: CandidateSlot)
  FinderBookingReturned(result: Result(Nil, rsvp.Error(String)))
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: MeetingsLoading,
      op: None,
      roster: [],
      projects: [],
      create: None,
      finder: None,
      notice: None,
      time_display: OriginTime,
    ),
    effect.batch([fetch(as_of), fetch_roster(as_of), fetch_projects(as_of)]),
  )
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, actor:),
    effect.batch([fetch(as_of), fetch_roster(as_of), fetch_projects(as_of)]),
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

/// The as-of project directory the find-a-time wizard's "Fill from project"
/// dropdown picks from.
fn fetch_projects(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_decoder(),
    fn(outcome) {
      ProjectsFetched(
        result: result.map(outcome, fn(roster) { roster.projects }),
      )
    },
  )
}

/// Fetch every candidate slot `url` (a fully-built find-a-time query string)
/// names, handing the outcome to `to_msg` — shared by the wizard's initial
/// search and its automatic re-search after a slot-taken rejection.
fn fetch_slots(
  url: String,
  to_msg: fn(Result(List(CandidateSlot), rsvp.Error(String))) -> Msg,
) -> Effect(Msg) {
  api.get(url, decode.list(candidate_slot_decoder()), to_msg)
}

/// The engineers allocated to `project_id` as-of `as_of` — "Fill from project".
fn fetch_project_team(project_id: Int, as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/meetings/find-a-time/project-team?project_id="
      <> int.to_string(project_id)
      <> "&as_of="
      <> time.iso_date(as_of),
    decode.list(decode.int),
    fn(result) { FinderProjectTeamFetched(project_id:, result:) },
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

    ProjectsFetched(result:) -> {
      let projects = result |> result.unwrap([])
      #(Model(..model, projects:), effect.none(), [])
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
          time.iso_date(time_display.local_date(
            starts_at,
            canonical_offset_minutes,
          )),
        )
        |> ops.update_op_form(
          ops.FStartsAt,
          time_display.local_time(starts_at, canonical_offset_minutes),
        )
        |> ops.update_op_form(
          ops.FDurationMinutes,
          int.to_string(time_display.minutes_between(starts_at, ends_at)),
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

    AttendanceToggled(permit:, meeting_id:, engineer_id:, attendance:) -> {
      let _ = permit
      #(
        model,
        api.submit_operation(
          gateway.MeetingCommand(command.AddAttendee(
            meeting_id:,
            engineer_id:,
            attendance:,
          )),
          OperationReturned,
        ),
        [],
      )
    }

    NoticeDismissed -> #(Model(..model, notice: None), effect.none(), [])

    TimeDisplaySet(display:) -> #(
      Model(..model, time_display: display),
      effect.none(),
      [],
    )

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
          case op_commands.build_command(kind, form) {
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
              Model(..model, op: None, create: None, notice: None),
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

    FinderOpened -> #(
      Model(
        ..model,
        finder: Some(finder.finder_reconcile_timezone(
          finder.blank_finder_form(model.as_of),
          model.roster,
        )),
      ),
      effect.none(),
      [],
    )

    FinderCancelled -> #(Model(..model, finder: None), effect.none(), [])

    FinderFieldEdited(field:, value:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(
              FinderForm(
                ..finder.update_finder_field(form, field, value),
                error: None,
              ),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderAttendeeQueryChanged(query:) ->
      case model.finder {
        Some(form) -> #(
          Model(..model, finder: Some(FinderForm(..form, query:))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderAttendeeAdded(engineer_id:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(finder.finder_reconcile_timezone(
              FinderForm(
                ..finder.finder_add_ids(form, [engineer_id]),
                query: "",
              ),
              model.roster,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderAllAdded ->
      case model.finder {
        Some(form) -> {
          let located_ids =
            finder.located_roster(model.roster)
            |> list.map(fn(entry) { entry.engineer_id })
          #(
            Model(
              ..model,
              finder: Some(finder.finder_reconcile_timezone(
                finder.finder_add_ids(form, located_ids),
                model.roster,
              )),
            ),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    FinderAttendeeRemoved(engineer_id:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(finder.finder_reconcile_timezone(
              FinderForm(
                ..form,
                attendees: list.filter(form.attendees, fn(attendee) {
                  attendee.engineer_id != engineer_id
                }),
              ),
              model.roster,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderAttendanceSet(engineer_id:, attendance:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(
              FinderForm(
                ..form,
                attendees: list.map(form.attendees, fn(attendee) {
                  case attendee.engineer_id == engineer_id {
                    True -> Attendee(..attendee, attendance:)
                    False -> attendee
                  }
                }),
              ),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderFillFromProjectRequested ->
      case model.finder {
        Some(form) ->
          case int.parse(string.trim(form.project_choice)) {
            Ok(project_id) -> #(
              model,
              fetch_project_team(project_id, model.as_of),
              [],
            )
            Error(Nil) -> #(
              Model(
                ..model,
                finder: Some(
                  FinderForm(..form, error: Some("choose a project")),
                ),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    FinderProjectTeamFetched(project_id:, result:) ->
      case model.finder {
        Some(form) ->
          case result {
            Ok(engineer_ids) -> {
              let located_ids =
                finder.located_roster(model.roster)
                |> list.map(fn(entry) { entry.engineer_id })
              let offerable =
                list.filter(engineer_ids, fn(id) {
                  list.contains(located_ids, id)
                })
              #(
                Model(
                  ..model,
                  finder: Some(finder.finder_reconcile_timezone(
                    finder.finder_add_ids(
                      FinderForm(..form, booking_project_id: Some(project_id)),
                      offerable,
                    ),
                    model.roster,
                  )),
                ),
                effect.none(),
                [],
              )
            }
            Error(error) -> #(
              Model(
                ..model,
                finder: Some(
                  FinderForm(..form, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    FinderSearchRequested ->
      case model.finder {
        Some(form) ->
          case finder.build_search_url(form) {
            Ok(url) -> #(
              Model(
                ..model,
                finder: Some(
                  FinderForm(..form, results: Searching, error: None),
                ),
              ),
              fetch_slots(url, FinderSlotsFetched),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                finder: Some(FinderForm(..form, error: Some(message))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    FinderSlotsFetched(result:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(finder.apply_slots_fetched(form, Found, result)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderSlotsRefetchedAfterTaken(result:) ->
      case model.finder {
        Some(form) -> #(
          Model(
            ..model,
            finder: Some(finder.apply_slots_fetched(form, SlotTaken, result)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderSlotBooked(slot:) ->
      case model.finder {
        Some(form) ->
          case finder.build_finder_schedule_command(form, slot) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, FinderBookingReturned),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                finder: Some(FinderForm(..form, error: Some(message))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    FinderBookingReturned(result:) ->
      case result {
        Ok(_events) -> {
          let notice = case model.finder {
            Some(form) -> Some("Booked \"" <> form.title <> "\"")
            None -> None
          }
          let #(refreshed, fetch_effect) =
            refetch(
              Model(..model, finder: None, notice:),
              model.as_of,
              model.actor,
            )
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) ->
          case finder.is_slot_taken(error), model.finder {
            True, Some(form) ->
              case finder.build_search_url(form) {
                Ok(url) -> #(
                  Model(
                    ..model,
                    finder: Some(
                      FinderForm(..form, results: Searching, error: None),
                    ),
                  ),
                  fetch_slots(url, FinderSlotsRefetchedAfterTaken),
                  [],
                )
                Error(message) -> #(
                  Model(
                    ..model,
                    finder: Some(FinderForm(..form, error: Some(message))),
                  ),
                  effect.none(),
                  [],
                )
              }
            False, Some(form) -> #(
              Model(
                ..model,
                finder: Some(
                  FinderForm(..form, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
            _, None -> #(model, effect.none(), [])
          }
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
          check: command.AllowOverlap,
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
