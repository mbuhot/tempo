//// The People detail's state machine: the model (the engineer bundle, timesheet,
//// skills, location, availability, and directory load states, the active tab, the
//// open op form, and the open weekly-hours editor), the messages, init/refetch,
//// and update — including the op-form seeding/prefills, the timesheet cell edits,
//// the LogWeek assembly, and the weekly-hours editor's `SetWorkSchedule` assembly.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/time
import client/ui/ops
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import lustre/effect.{type Effect}
import rsvp
import shared/allocation/view.{AllocationRow} as allocation_view
import shared/availability/command as availability_command
import shared/availability/view.{type AvailabilityRecord, type DaySlot} as availability_view
import shared/command as gateway
import shared/engineer/view.{
  type EngineerDetail, EngineerBanking, EngineerContact, EngineerEmergency,
} as engineer_view
import shared/leave/kind as leave_kind
import shared/location/view.{type LocationRecord, LocationRecord} as location_view
import shared/roster/view.{type Ref, type Roster} as roster_view
import shared/skill/view.{type EngineerSkills, EngineerSkills} as skill_view

import shared/timesheet/command.{type TimesheetEntry, LogWeek, TimesheetEntry}
import shared/timesheet/view.{
  type TimesheetWeek, TimesheetCell, TimesheetWeekRow,
} as timesheet_view

// --- Model ------------------------------------------------------------------

/// The detail mode's state: the as-of its data answers, the shown engineer id, the
/// bundle / timesheet / skills / directory load states (fetched in parallel as
/// sibling fields so whichever arrives first never discards the others), the
/// active tab, and the open contextual op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    engineer_id: Int,
    detail: DetailData,
    timesheet: TimesheetData,
    skills: SkillsData,
    location: LocationData,
    availability: AvailabilityData,
    roster: Directory,
    tab: Tab,
    op: Option(ops.OpState),
    week_form: Option(WeekForm),
  )
}

/// The detail mode's tabs: `Overview` holds the existing panels/timesheet grid,
/// `Skills` the engineer's skill matrix, capability rollup, and recent
/// assessments.
pub type Tab {
  Overview
  Skills
}

/// The engineer bundle's load state.
pub type DetailData {
  DetailLoading
  DetailLoaded(detail: EngineerDetail)
  DetailFailed(message: String)
}

/// The weekly timesheet grid's load state. When loaded it carries the fetched week
/// plus the presenter's in-progress edits keyed by `#(project_id, day_index)`, so
/// typed hours survive a re-render and feed the `LogWeek` submit.
pub type TimesheetData {
  TimesheetLoading
  TimesheetLoaded(week: TimesheetWeek, edits: Dict(#(Int, Int), String))
  TimesheetFailed(message: String)
}

/// The as-of operations directory's load state.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(roster: Roster)
  DirectoryFailed(message: String)
}

/// The engineer's skill matrix load state (the Skills tab's read model).
pub type SkillsData {
  SkillsLoading
  SkillsLoaded(skills: EngineerSkills)
  SkillsFailed(message: String)
}

/// The engineer's location history load state (the Overview tab's "Location &
/// timezone" card + timeline).
pub type LocationData {
  LocationLoading
  LocationLoaded(records: List(LocationRecord))
  LocationFailed(message: String)
}

/// The engineer's availability load state (the Overview tab's "Availability"
/// panel: weekly working hours, upcoming focus blocks, upcoming holidays).
pub type AvailabilityData {
  AvailabilityLoading
  AvailabilityLoaded(record: AvailabilityRecord)
  AvailabilityFailed(message: String)
}

/// One editable row of the bespoke weekly-hours editor: whether the engineer
/// works that weekday, and the typed start/end times (blank when not working).
pub type DayEdit {
  DayEdit(working: Bool, starts: String, ends: String)
}

/// The bespoke weekly-hours editor's state: the typed effective date, the 7
/// editable day rows (index = weekday, 0 = Monday), and a rejection prompt.
pub type WeekForm {
  WeekForm(effective: String, days: List(DayEdit), error: Option(String))
}

// --- Messages ---------------------------------------------------------------

/// The detail mode's messages: the bundle / timesheet / skills / directory fetch
/// results (each carrying the `as_of` they answer, and the timesheet/skills their
/// engineer id), the back-link navigation, the tab switch, the contextual op
/// lifecycle, the grid's cell edit + submit, and the operation reply.
pub type Msg {
  DetailFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(EngineerDetail, rsvp.Error(String)),
  )
  TimesheetFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(TimesheetWeek, rsvp.Error(String)),
  )
  SkillsFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(EngineerSkills, rsvp.Error(String)),
  )
  LocationFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(List(LocationRecord), rsvp.Error(String)),
  )
  AvailabilityFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(AvailabilityRecord, rsvp.Error(String)),
  )
  DirectoryFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  BackClicked
  TabClicked(tab: Tab)
  OpOpened(permit: ops.Permit)
  OpCancelled
  OpFieldEdited(field: ops.OpField, value: String)
  OpSubmitted
  CellEdited(project_id: Int, day: calendar.Date, value: String)
  TimesheetSubmitted(permit: ops.Permit)
  WeekOpened
  WeekCancelled
  WeekEffectiveEdited(value: String)
  WeekDayToggled(weekday: Int)
  WeekStartsEdited(weekday: Int, value: String)
  WeekEndsEdited(weekday: Int, value: String)
  WeekSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Start the detail mode for `engineer_id` at `as_of`, fetching the bundle, the
/// timesheet, and the directory in parallel.
pub fn init(as_of: calendar.Date, engineer_id: Int) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      as_of:,
      engineer_id:,
      detail: DetailLoading,
      timesheet: TimesheetLoading,
      skills: SkillsLoading,
      location: LocationLoading,
      availability: AvailabilityLoading,
      roster: DirectoryLoading,
      tab: Overview,
      op: None,
      week_form: None,
    )
  #(
    model,
    effect.batch([fetch_detail(as_of, engineer_id), fetch_directory(as_of)]),
  )
}

/// Re-fetch the detail mode for a new `as_of` (stale-while-revalidate), keeping any
/// open op form and the active tab: refetch the bundle, the timesheet, and the
/// skill matrix for the new instant.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      as_of:,
      detail: DetailLoading,
      timesheet: TimesheetLoading,
      skills: SkillsLoading,
      location: LocationLoading,
      availability: AvailabilityLoading,
      roster: DirectoryLoading,
    ),
    effect.batch([
      fetch_detail(as_of, model.engineer_id),
      fetch_directory(as_of),
    ]),
  )
}

fn fetch_detail(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  effect.batch([
    api.get(
      "/api/engineers/"
        <> int.to_string(engineer_id)
        <> "?as_of="
        <> time.iso_date(as_of),
      engineer_view.engineer_detail_decoder(),
      fn(result) { DetailFetched(as_of:, engineer_id:, result:) },
    ),
    fetch_timesheet(as_of, engineer_id),
    fetch_skills(as_of, engineer_id),
    fetch_location(as_of, engineer_id),
    fetch_availability(as_of, engineer_id),
  ])
}

fn fetch_skills(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  api.get(
    "/api/engineers/"
      <> int.to_string(engineer_id)
      <> "/skills?as_of="
      <> time.iso_date(as_of),
    skill_view.engineer_skills_decoder(),
    fn(result) { SkillsFetched(as_of:, engineer_id:, result:) },
  )
}

fn fetch_location(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  api.get(
    "/api/engineers/"
      <> int.to_string(engineer_id)
      <> "/location?as_of="
      <> time.iso_date(as_of),
    decode.list(location_view.location_record_decoder()),
    fn(result) { LocationFetched(as_of:, engineer_id:, result:) },
  )
}

fn fetch_availability(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  api.get(
    "/api/engineers/"
      <> int.to_string(engineer_id)
      <> "/availability?as_of="
      <> time.iso_date(as_of),
    availability_view.availability_record_decoder(),
    fn(result) { AvailabilityFetched(as_of:, engineer_id:, result:) },
  )
}

fn fetch_directory(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { DirectoryFetched(as_of:, result:) },
  )
}

fn fetch_timesheet(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  let week = time.week_start_of(as_of)
  api.get(
    "/api/timesheet?engineer="
      <> int.to_string(engineer_id)
      <> "&week="
      <> time.iso_date(week),
    timesheet_view.timesheet_week_decoder(),
    fn(result) { TimesheetFetched(as_of:, engineer_id:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    DetailFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let detail = case result {
            Ok(detail) -> DetailLoaded(detail:)
            Error(error) -> DetailFailed(api.describe_error(error))
          }
          #(Model(..model, detail:), effect.none(), [])
        }
      }

    TimesheetFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let timesheet = case result {
            Ok(week) -> TimesheetLoaded(week:, edits: dict.new())
            Error(error) -> TimesheetFailed(api.describe_error(error))
          }
          #(Model(..model, timesheet:), effect.none(), [])
        }
      }

    SkillsFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let skills = case result {
            Ok(skills) -> SkillsLoaded(skills:)
            Error(error) -> SkillsFailed(api.describe_error(error))
          }
          let op = reprefill_skill_id(model.op, skills)
          #(Model(..model, skills:, op:), effect.none(), [])
        }
      }

    LocationFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let location = case result {
            Ok(records) -> LocationLoaded(records:)
            Error(error) -> LocationFailed(api.describe_error(error))
          }
          #(Model(..model, location:), effect.none(), [])
        }
      }

    AvailabilityFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let availability = case result {
            Ok(record) -> AvailabilityLoaded(record:)
            Error(error) -> AvailabilityFailed(api.describe_error(error))
          }
          #(Model(..model, availability:), effect.none(), [])
        }
      }

    DirectoryFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> DirectoryLoaded(roster:)
            Error(error) -> DirectoryFailed(api.describe_error(error))
          }
          #(Model(..model, roster:), effect.none(), [])
        }
      }

    BackClicked -> #(model, effect.none(), [Navigate(route.People(id: None))])

    TabClicked(tab:) -> #(Model(..model, tab:), effect.none(), [])

    OpOpened(permit:) -> {
      let kind = ops.permit_kind(permit)
      #(
        Model(
          ..model,
          op: Some(ops.OpState(
            kind:,
            form: blank_form(model, kind),
            error: None,
          )),
        ),
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

    CellEdited(project_id:, day:, value:) -> #(
      edit_cell(model, project_id, day, value),
      effect.none(),
      [],
    )

    TimesheetSubmitted(..) ->
      case model.timesheet {
        TimesheetLoaded(week:, edits:) -> #(
          model,
          api.submit_operation(
            gateway.TimesheetCommand(LogWeek(
              engineer_id: model.engineer_id,
              entries: week_entries(week, edits),
            )),
            OperationReturned,
          ),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    WeekOpened -> #(
      Model(..model, week_form: Some(seed_week_form(model))),
      effect.none(),
      [],
    )

    WeekCancelled -> #(Model(..model, week_form: None), effect.none(), [])

    WeekEffectiveEdited(value:) ->
      case model.week_form {
        Some(form) -> #(
          Model(
            ..model,
            week_form: Some(WeekForm(..form, effective: value, error: None)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    WeekDayToggled(weekday:) ->
      case model.week_form {
        Some(form) -> #(
          Model(
            ..model,
            week_form: Some(
              WeekForm(
                ..form,
                days: edit_day(form.days, weekday, fn(day) {
                  DayEdit(..day, working: !day.working)
                }),
                error: None,
              ),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    WeekStartsEdited(weekday:, value:) ->
      case model.week_form {
        Some(form) -> #(
          Model(
            ..model,
            week_form: Some(
              WeekForm(
                ..form,
                days: edit_day(form.days, weekday, fn(day) {
                  DayEdit(..day, starts: value)
                }),
                error: None,
              ),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    WeekEndsEdited(weekday:, value:) ->
      case model.week_form {
        Some(form) -> #(
          Model(
            ..model,
            week_form: Some(
              WeekForm(
                ..form,
                days: edit_day(form.days, weekday, fn(day) {
                  DayEdit(..day, ends: value)
                }),
                error: None,
              ),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    WeekSubmitted ->
      case model.week_form {
        Some(form) ->
          case build_week_command(model.engineer_id, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                week_form: Some(WeekForm(..form, error: Some(message))),
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
          let #(refreshed, fetch) =
            refetch(Model(..model, op: None, week_form: None), model.as_of)
          #(refreshed, fetch, [OperationCommitted])
        }
        Error(error) -> #(
          set_week_or_op_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }
  }
}

// --- Update helpers ---------------------------------------------------------

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ops.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ops.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

/// Surface a rejection on whichever form is open — the op-form modal or the
/// bespoke weekly-hours editor — leaving its typed fields intact.
fn set_week_or_op_error(model: Model, message: String) -> Model {
  case model.week_form {
    Some(form) ->
      Model(..model, week_form: Some(WeekForm(..form, error: Some(message))))
    None -> set_op_error(model, message)
  }
}

const weekday_names = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
]

/// Seed the weekly-hours editor from the loaded week (or blank rows while it is
/// still loading) at the current as-of.
fn seed_week_form(model: Model) -> WeekForm {
  let days = case model.availability {
    AvailabilityLoaded(record:) -> list.map(record.week, day_edit_from_slot)
    _ -> list.repeat(DayEdit(False, "", ""), 7)
  }
  WeekForm(effective: time.iso_date(model.as_of), days:, error: None)
}

fn day_edit_from_slot(slot: DaySlot) -> DayEdit {
  case slot.starts, slot.ends {
    Some(starts), Some(ends) -> DayEdit(True, starts, ends)
    _, _ -> DayEdit(False, "", "")
  }
}

/// Rewrite the day row at `weekday` with `edit`, leaving every other row
/// untouched.
fn edit_day(
  days: List(DayEdit),
  weekday: Int,
  edit: fn(DayEdit) -> DayEdit,
) -> List(DayEdit) {
  list.index_map(days, fn(day, index) {
    case index == weekday {
      True -> edit(day)
      False -> day
    }
  })
}

/// Build `SetWorkSchedule` from the weekly editor; the days list is always 7
/// long, index = weekday (0 = Monday).
pub fn build_week_command(
  engineer_id: Int,
  form: WeekForm,
) -> Result(gateway.Command, String) {
  use effective <- result.try(
    time.parse_iso_date(form.effective)
    |> result.replace_error("effective date must be YYYY-MM-DD"),
  )
  use days <- result.try(
    form.days
    |> list.index_map(fn(day, weekday) { day_hours(day, weekday) })
    |> result.all,
  )
  Ok(
    gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
      engineer_id:,
      effective:,
      days:,
    )),
  )
}

fn day_hours(
  day: DayEdit,
  weekday: Int,
) -> Result(availability_command.DayHours, String) {
  let name = weekday_name(weekday)
  case day.working, string.trim(day.starts), string.trim(day.ends) {
    False, _, _ -> Ok(availability_command.DayHours(weekday, None))
    True, "", _ -> Error(name <> " needs start and end times")
    True, _, "" -> Error(name <> " needs start and end times")
    True, starts, ends ->
      Ok(availability_command.DayHours(weekday, Some(#(starts, ends))))
  }
}

/// The English weekday name for a 0-indexed weekday (0 = Monday), shared by the
/// weekly-hours editor's validation prompts and the Availability panel's grid.
pub fn weekday_name(weekday: Int) -> String {
  case list.drop(weekday_names, weekday) {
    [name, ..] -> name
    [] -> "Day"
  }
}

/// The active project `Ref`s from the loaded directory, for the op-form
/// `<select>`s. Empty until the directory loads.
pub fn project_refs(model: Model) -> List(Ref) {
  case model.roster {
    DirectoryLoaded(roster:) -> roster.projects
    _ -> []
  }
}

/// A fresh op form seeded for `kind`: the visible engineer's id (every detail op
/// acts on the shown engineer), the loaded contact/banking/emergency facts
/// pre-filled into the matching edit form, the roll-off project pre-selected from
/// the engineer's active allocation, and every entity slot snapped to a valid
/// directory option. Dates default to the as-of.
fn blank_form(model: Model, kind: ops.OpKind) -> ops.OpForm {
  let form = ops.blank_op_form(kind, model.as_of)
  let form = case kind {
    ops.OpTakeLeave ->
      ops.update_op_form(
        form,
        ops.FKind,
        leave_kind.to_string(leave_kind.Annual),
      )
    _ -> form
  }
  let form =
    ops.update_op_form(form, ops.FEngineerId, int.to_string(model.engineer_id))
  let form = prefill_from_detail(form, kind, model.detail)
  let form = prefill_skill_id(form, kind, model.skills)
  let form = prefill_location(form, kind, model.location, model.as_of)
  ops.reconcile_form(form, [], project_refs(model))
}

/// Pre-select the first assessed skill for `OpAssessSkill` so the `<select>` opens
/// on a valid skill id rather than blank. Other kinds (and an unloaded matrix)
/// leave the form untouched.
fn prefill_skill_id(
  form: ops.OpForm,
  kind: ops.OpKind,
  skills: SkillsData,
) -> ops.OpForm {
  case kind, skills {
    ops.OpAssessSkill, SkillsLoaded(EngineerSkills(matrix: [first, ..], ..)) ->
      ops.update_op_form(form, ops.FSkillId, int.to_string(first.skill_id))
    _, _ -> form
  }
}

/// Re-run the skill prefill on an already-open op modal once the skill matrix
/// finishes loading after the modal opened: an `OpAssessSkill` form whose
/// `skill_id` is still unset (the matrix was `SkillsLoading` at open time) gets
/// seeded with the newly-loaded first skill, matching the `<select>` the browser
/// auto-selects once real options render. Any other modal (or an already-seeded
/// one) is left untouched.
fn reprefill_skill_id(
  op: Option(ops.OpState),
  skills: SkillsData,
) -> Option(ops.OpState) {
  case op {
    Some(ops.OpState(kind: ops.OpAssessSkill, form:, error:))
      if form.skill_id == ""
    ->
      Some(ops.OpState(
        kind: ops.OpAssessSkill,
        form: prefill_skill_id(form, ops.OpAssessSkill, skills),
        error:,
      ))
    _ -> op
  }
}

/// Pre-fill the form's slots from the loaded engineer bundle for the kinds that
/// edit existing facts: the contact/banking/emergency edit forms open showing the
/// current values, and roll-off pre-selects the engineer's active allocation. Other
/// kinds (and an unloaded bundle) leave the form untouched.
fn prefill_from_detail(
  form: ops.OpForm,
  kind: ops.OpKind,
  detail: DetailData,
) -> ops.OpForm {
  case detail {
    DetailLoaded(detail:) ->
      case kind {
        ops.OpUpdateContact -> {
          let EngineerContact(name:, email:, phone:, postal_address:, ..) =
            detail.contact
          form
          |> ops.update_op_form(ops.FName, name)
          |> ops.update_op_form(ops.FEmail, email)
          |> ops.update_op_form(ops.FPhone, phone)
          |> ops.update_op_form(ops.FPostalAddress, postal_address)
        }
        ops.OpUpdateBanking -> {
          let EngineerBanking(bank:, branch:, account_no:, account_name:, ..) =
            detail.banking
          form
          |> ops.update_op_form(ops.FBank, bank)
          |> ops.update_op_form(ops.FBranch, branch)
          |> ops.update_op_form(ops.FAccountNo, account_no)
          |> ops.update_op_form(ops.FAccountName, account_name)
        }
        ops.OpUpdateEmergency ->
          case detail.emergency {
            Some(EngineerEmergency(relation:, name:, phone:, email:, ..)) ->
              form
              |> ops.update_op_form(ops.FRelation, relation)
              |> ops.update_op_form(ops.FEmergencyName, name)
              |> ops.update_op_form(ops.FEmergencyPhone, phone)
              |> ops.update_op_form(ops.FEmergencyEmail, email)
            None -> form
          }
        ops.OpRollOff ->
          case active_allocation(detail.allocations) {
            Some(project_id) ->
              ops.update_op_form(
                form,
                ops.FProjectId,
                int.to_string(project_id),
              )
            None -> form
          }
        _ -> form
      }
    _ -> form
  }
}

/// Pre-fill `OpSetLocation`'s country/region/timezone from the location record
/// covering `as_of`, so relocating opens showing the current location rather
/// than blank. Other kinds (and no covering record) leave the form untouched.
fn prefill_location(
  form: ops.OpForm,
  kind: ops.OpKind,
  location: LocationData,
  as_of: calendar.Date,
) -> ops.OpForm {
  case kind, location {
    ops.OpSetLocation, LocationLoaded(records:) ->
      case covering_location(records, as_of) {
        Some(LocationRecord(country:, region:, timezone:, ..)) ->
          form
          |> ops.update_op_form(ops.FCountry, country)
          |> ops.update_op_form(ops.FRegion, option.unwrap(region, ""))
          |> ops.update_op_form(ops.FTimezone, timezone)
        None -> form
      }
    _, _ -> form
  }
}

/// The location record whose span contains `as_of`, if any.
pub fn covering_location(
  records: List(LocationRecord),
  as_of: calendar.Date,
) -> Option(LocationRecord) {
  list.find(records, fn(record) {
    let LocationRecord(valid_from:, valid_to:, ..) = record
    covers_as_of(valid_from, valid_to, as_of)
  })
  |> option.from_result
}

/// Whether a `[valid_from, valid_to)` span (an open-ended span when `valid_to`
/// is `None`) contains `as_of`.
pub fn covers_as_of(
  valid_from: calendar.Date,
  valid_to: Option(calendar.Date),
  as_of: calendar.Date,
) -> Bool {
  time.date_to_day_index(valid_from) <= time.date_to_day_index(as_of)
  && case valid_to {
    None -> True
    Some(to) -> time.date_to_day_index(as_of) < time.date_to_day_index(to)
  }
}

/// The project id of the engineer's first active allocation, if any — the natural
/// roll-off target so the form opens pre-selected.
fn active_allocation(
  allocations: List(allocation_view.AllocationRow),
) -> Option(Int) {
  list.find_map(allocations, fn(allocation) {
    case allocation {
      AllocationRow(project_id:, active: True, ..) -> Ok(project_id)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Record a typed timesheet cell value, keyed by `#(project_id, day_index)`, so the
/// grid re-renders the typed value and the submit reads it back.
fn edit_cell(
  model: Model,
  project_id: Int,
  day: calendar.Date,
  value: String,
) -> Model {
  case model.timesheet {
    TimesheetLoaded(week:, edits:) -> {
      let key = #(project_id, time.date_to_day_index(day))
      let edits = dict.insert(edits, key, value)
      Model(..model, timesheet: TimesheetLoaded(week:, edits:))
    }
    _ -> model
  }
}

/// Assemble the `LogWeek` entries from the fetched grid and the presenter's edits:
/// one entry per editable (project, day) cell, taking the typed value when present
/// (an unparseable or blank typed value clears the cell at 0.0) and otherwise the
/// cell's already-logged hours. Disabled cells are never logged.
fn week_entries(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> List(TimesheetEntry) {
  list.flat_map(week.rows, fn(row) {
    let TimesheetWeekRow(project_id:, cells:, ..) = row
    list.filter_map(cells, fn(cell) {
      let TimesheetCell(date:, allocated:, hours:) = cell
      case allocated {
        False -> Error(Nil)
        True -> {
          let key = #(project_id, time.date_to_day_index(date))
          let value = case dict.get(edits, key) {
            Ok(typed) -> parse_hours(typed)
            Error(Nil) -> hours
          }
          Ok(TimesheetEntry(project_id:, day: date, hours: value))
        }
      }
    })
  })
}

/// Parse a typed hours cell; a blank or unparseable value clears the cell (0.0).
/// Accepts both decimals ("7.5") and bare integers ("8").
fn parse_hours(raw: String) -> Float {
  let trimmed = string.trim(raw)
  case float.parse(trimmed) {
    Ok(value) -> value
    Error(Nil) ->
      case int.parse(trimmed) {
        Ok(value) -> int.to_float(value)
        Error(Nil) -> 0.0
      }
  }
}
