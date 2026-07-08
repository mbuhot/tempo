//// The Meetings page's state machine: the loadable-list model, the messages,
//// init/refetch, the update fold (granular op-form launches, the bespoke
//// `ScheduleMeeting` create form, and the find-a-time wizard), the fetches, and
//// the pure command-building and local-time helpers the view and tests draw from.

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

/// The find-a-time wizard's search outcome: no search run yet, a search
/// in flight, a completed search, or a completed RE-search run automatically
/// because the presenter's booked pick was just taken by someone else — a
/// distinct state rather than a "stale" boolean flag, so the view can name it.
pub type FinderResults {
  NotSearched
  Searching
  Found(slots: List(CandidateSlot))
  SlotTaken(slots: List(CandidateSlot))
}

/// Names a slot of the `FinderForm` — the wizard's own field enum, mirroring
/// `CreateField` since `find_time`/`ScheduleMeeting` are also composed directly
/// rather than through the scalar op-form engine.
pub type FinderField {
  FinderTitle
  FinderProjectChoice
  FinderFromDate
  FinderToDate
  FinderDurationMinutes
  FinderTimezone
}

/// The "Find a time" wizard: the criteria (attendees, search window, duration,
/// timezone), the meeting title to book, and the current `results`.
/// `booking_project_id` is set only once "Fill from project" has actually run,
/// so a booked meeting attaches to that project exactly when the wizard was
/// used to staff it from one — an id, not a bare flag, doubling as both "was it
/// used" and "which project".
pub type FinderForm {
  FinderForm(
    attendees: List(Attendee),
    query: String,
    project_choice: String,
    booking_project_id: Option(Int),
    from_date: String,
    to_date: String,
    duration_minutes: String,
    timezone: String,
    title: String,
    results: FinderResults,
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
        finder: Some(finder_reconcile_timezone(
          blank_finder_form(model.as_of),
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
              FinderForm(..update_finder_field(form, field, value), error: None),
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
            finder: Some(finder_reconcile_timezone(
              FinderForm(..finder_add_ids(form, [engineer_id]), query: ""),
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
            located_roster(model.roster)
            |> list.map(fn(entry) { entry.engineer_id })
          #(
            Model(
              ..model,
              finder: Some(finder_reconcile_timezone(
                finder_add_ids(form, located_ids),
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
            finder: Some(finder_reconcile_timezone(
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
                located_roster(model.roster)
                |> list.map(fn(entry) { entry.engineer_id })
              let offerable =
                list.filter(engineer_ids, fn(id) {
                  list.contains(located_ids, id)
                })
              #(
                Model(
                  ..model,
                  finder: Some(finder_reconcile_timezone(
                    finder_add_ids(
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
          case build_search_url(form) {
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
          Model(..model, finder: Some(apply_slots_fetched(form, Found, result))),
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
            finder: Some(apply_slots_fetched(form, SlotTaken, result)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    FinderSlotBooked(slot:) ->
      case model.finder {
        Some(form) ->
          case build_finder_schedule_command(form, slot) {
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
          case is_slot_taken(error), model.finder {
            True, Some(form) ->
              case build_search_url(form) {
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

// --- Find-a-time wizard -------------------------------------------------------

/// A blank finder form, opened by the "Find a time" launcher: the search window
/// defaults to `as_of .. as_of+13 days`, duration to 60 minutes, timezone blank —
/// the caller (`FinderOpened`) runs it through `finder_reconcile_timezone` right
/// away, which snaps the blank value to `"UTC"` (no attendees yet).
fn blank_finder_form(as_of: Date) -> FinderForm {
  FinderForm(
    attendees: [],
    query: "",
    project_choice: "",
    booking_project_id: None,
    from_date: time.iso_date(as_of),
    to_date: time.iso_date(plus_days(as_of, 13)),
    duration_minutes: "60",
    timezone: "",
    title: "",
    results: NotSearched,
    error: None,
  )
}

fn plus_days(date: Date, days: Int) -> Date {
  time.day_index_to_date(time.date_to_day_index(date) + days)
}

/// Fold a `FinderFieldEdited` edit into the matching `FinderForm` slot.
fn update_finder_field(
  form: FinderForm,
  field: FinderField,
  value: String,
) -> FinderForm {
  case field {
    FinderTitle -> FinderForm(..form, title: value)
    FinderProjectChoice -> FinderForm(..form, project_choice: value)
    FinderFromDate -> FinderForm(..form, from_date: value)
    FinderToDate -> FinderForm(..form, to_date: value)
    FinderDurationMinutes -> FinderForm(..form, duration_minutes: value)
    FinderTimezone -> FinderForm(..form, timezone: value)
  }
}

/// The roster narrowed to engineers with a location as-of the date — the only
/// engineers any wizard picker (search, add everyone, fill from project) can
/// ever offer, since an unlocated engineer can never produce a free slot.
pub fn located_roster(
  roster: List(EngineerLocation),
) -> List(EngineerLocation) {
  list.filter(roster, fn(entry) { option.is_some(entry.location) })
}

/// Add every id in `ids` to `form.attendees` as `Required`, skipping any id
/// already present so an existing attendee KEEPS whichever attendance the
/// presenter already chose for them.
pub fn finder_add_ids(form: FinderForm, ids: List(Int)) -> FinderForm {
  FinderForm(..form, attendees: list.fold(ids, form.attendees, add_one))
}

fn add_one(attendees: List(Attendee), engineer_id: Int) -> List(Attendee) {
  case
    list.any(attendees, fn(attendee) { attendee.engineer_id == engineer_id })
  {
    True -> attendees
    False ->
      list.append(attendees, [Attendee(engineer_id:, attendance: Required)])
  }
}

/// The distinct timezones of `attendees`' roster locations, in attendee order,
/// with `"UTC"` always appended last (deduped against an attendee already
/// located there) — the find-a-time wizard's `Timezone` select options. An
/// attendee with no as-of location contributes no option.
pub fn finder_timezone_options(
  attendees: List(Attendee),
  roster: List(EngineerLocation),
) -> List(String) {
  let zones =
    attendees
    |> list.filter_map(fn(attendee) {
      attendee_timezone(attendee.engineer_id, roster)
    })
    |> list.unique
    |> list.filter(fn(timezone) { timezone != "UTC" })
  list.append(zones, ["UTC"])
}

fn attendee_timezone(
  engineer_id: Int,
  roster: List(EngineerLocation),
) -> Result(String, Nil) {
  use entry <- result.try(
    list.find(roster, fn(entry) { entry.engineer_id == engineer_id }),
  )
  use location <- result.try(option.to_result(entry.location, Nil))
  Ok(location.timezone)
}

/// Snap `current` to `options`: kept if still present, otherwise reset to the
/// first option (an attendee's own zone, or `"UTC"` once the attendee list is
/// empty) — mirroring `ops.reconcile_ref`'s stale-selection reset.
pub fn reconcile_finder_timezone(
  current: String,
  options: List(String),
) -> String {
  case list.contains(options, current), options {
    True, _ -> current
    False, [first, ..] -> first
    False, [] -> current
  }
}

/// Reconcile `form.timezone` against the options its CURRENT attendees now
/// offer — called everywhere the attendee list changes, so the selection never
/// points at a zone no attendee is in.
fn finder_reconcile_timezone(
  form: FinderForm,
  roster: List(EngineerLocation),
) -> FinderForm {
  let options = finder_timezone_options(form.attendees, roster)
  FinderForm(
    ..form,
    timezone: reconcile_finder_timezone(form.timezone, options),
  )
}

/// Split `attendees` into (required ids, optional ids), each deduplicated and
/// disjoint — an id present as both stays only in `required` — mirroring the
/// server's own `find_time` dedupe guard.
pub fn partition_attendee_ids(
  attendees: List(Attendee),
) -> #(List(Int), List(Int)) {
  let required =
    attendees
    |> list.filter(fn(attendee) { attendee.attendance == command.Required })
    |> list.map(fn(attendee) { attendee.engineer_id })
    |> list.unique
  let optional =
    attendees
    |> list.filter(fn(attendee) { attendee.attendance == command.Optional })
    |> list.map(fn(attendee) { attendee.engineer_id })
    |> list.unique
    |> list.filter(fn(id) { !list.contains(required, id) })
  #(required, optional)
}

/// Validate the wizard's criteria and build the `GET /api/meetings/find-a-time`
/// query string, or report the first thing missing: at least one required
/// attendee, a non-empty timezone, a positive duration, and `from` on or before
/// `to`.
pub fn build_search_url(form: FinderForm) -> Result(String, String) {
  use from <- result.try(parse_date(form.from_date))
  use to <- result.try(parse_date(form.to_date))
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  let #(required, optional) = partition_attendee_ids(form.attendees)
  let timezone = string.trim(form.timezone)
  case
    required,
    timezone,
    duration > 0,
    time.date_to_day_index(from) <= time.date_to_day_index(to)
  {
    [], _, _, _ -> Error("add at least one required attendee")
    _, "", _, _ -> Error("timezone is required")
    _, _, False, _ -> Error("duration must be a positive number of minutes")
    _, _, _, False -> Error("from date must be on or before to date")
    _, _, _, _ ->
      Ok(
        "/api/meetings/find-a-time?from="
        <> time.iso_date(from)
        <> "&to="
        <> time.iso_date(to)
        <> "&tz="
        <> timezone
        <> "&duration="
        <> int.to_string(duration)
        <> "&required="
        <> ids_to_csv(required)
        <> optional_ids_query(optional),
      )
  }
}

fn ids_to_csv(ids: List(Int)) -> String {
  ids |> list.map(int.to_string) |> string.join(",")
}

fn optional_ids_query(optional: List(Int)) -> String {
  case optional {
    [] -> ""
    ids -> "&optional=" <> ids_to_csv(ids)
  }
}

/// Fold a `FinderSlotsFetched`/`FinderSlotsRefetchedAfterTaken` outcome into
/// the form: on success wrap the slots in `wrap` (`Found` for a normal search,
/// `SlotTaken` for the automatic re-search after a booking collision); on
/// failure fall back to `NotSearched` and surface the error inline.
fn apply_slots_fetched(
  form: FinderForm,
  wrap: fn(List(CandidateSlot)) -> FinderResults,
  result: Result(List(CandidateSlot), rsvp.Error(String)),
) -> FinderForm {
  case result {
    Ok(slots) -> FinderForm(..form, results: wrap(slots), error: None)
    Error(error) ->
      FinderForm(
        ..form,
        results: NotSearched,
        error: Some(api.describe_error(error)),
      )
  }
}

/// A candidate slot's UTC `starts_at_iso`, shifted by `viewer_offset_minutes`
/// into the viewer-local calendar date and "HH:MM" wall-clock time the booking
/// command needs — the client has no timezone database, so the server ships
/// the offset and this is where it gets applied to a BOOKING (as opposed to a
/// read-only local-time render, which uses `local_time` alone).
pub fn slot_local_start(
  starts_at_iso: String,
  viewer_offset_minutes: Int,
) -> #(Date, String) {
  #(
    local_date(starts_at_iso, viewer_offset_minutes),
    local_time(starts_at_iso, viewer_offset_minutes),
  )
}

/// The pure, testable heart of booking a slot: validate + assemble a
/// `ScheduleMeeting(check: RequireFree)` command from the wizard's criteria and
/// the chosen slot, or report the first thing missing.
pub fn build_finder_schedule_command(
  form: FinderForm,
  slot: CandidateSlot,
) -> Result(gateway.Command, String) {
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  case string.trim(form.title), form.attendees {
    "", _ -> Error("title is required")
    _, [] -> Error("add at least one attendee")
    title, attendees -> {
      let #(date, starts_at) =
        slot_local_start(slot.starts_at, slot.viewer_offset_minutes)
      Ok(
        gateway.MeetingCommand(command.ScheduleMeeting(
          title:,
          timezone: string.trim(form.timezone),
          date:,
          starts_at:,
          duration_minutes: duration,
          location: None,
          client_id: None,
          project_id: form.booking_project_id,
          attendees: list.map(attendees, fn(attendee) {
            #(attendee.engineer_id, attendee.attendance)
          }),
          check: command.RequireFree,
        )),
      )
    }
  }
}

/// Whether `error` is the operations handler's `slot_taken` rejection — the
/// wizard automatically re-searches on this ONE failure and surfaces every
/// other error inline instead.
pub fn is_slot_taken(error: rsvp.Error(String)) -> Bool {
  case error {
    rsvp.HttpError(response) ->
      gateway.decode_error_tag(response.body) == Ok("slot_taken")
    _ -> False
  }
}
