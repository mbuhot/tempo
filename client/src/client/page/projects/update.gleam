//// The Projects page's state machine: the list-vs-detail model (each arm with
//// its read-model and roster load states), the messages, init/refetch, the
//// update fold with its as-of staleness guards, the create-project wizard
//// wiring, and the op-form launch seeding (locked project, detail prefills,
//// capability prefill).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/ui/ops
import client/workflow/host
import client/workflow/wizard
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/effect.{type Effect}
import rsvp
import shared/invoice/view as _
import shared/money
import shared/project/view.{type ProjectDetail} as project_view
import shared/project_capability/view.{type CoverageSnapshot, CoverageSnapshot} as coverage_view

import shared/roster/view.{type Ref, type Roster} as roster_view
import shared/settings/view.{type RateCardRow} as settings_view
import shared/workflow/kind as wkind

// --- Model ------------------------------------------------------------------

/// The page renders one of two sub-views: the project list or a single project's
/// detail. Each is independently loadable, so the model is a sum over the two with
/// each arm carrying its own load state plus the as-of `Roster` the op selects
/// draw from. The signed-in `actor` is threaded in (the frozen `update` signature
/// omits it) so contextual writes can post on the presenter's behalf; the current
/// `as_of` is held so a committed write can refetch the same instant.
pub type Model {
  ListView(
    actor: String,
    as_of: calendar.Date,
    host: table_host.Host,
    roster: Load(Roster),
    op: Option(ops.OpState),
    wizard: Option(wizard.Model),
    rates: Option(List(RateCardRow)),
    rates_for: String,
  )
  DetailView(
    actor: String,
    as_of: calendar.Date,
    project_id: Int,
    detail: Load(ProjectDetail),
    roster: Load(Roster),
    op: Option(ops.OpState),
    tab: Tab,
    coverage: Load(CoverageSnapshot),
  )
}

/// The project-detail mode's tabs: `Overview` holds the existing team / capacity /
/// invoices panels, `Coverage` the capability-coverage read (demand vs. the
/// current team, per requirement).
pub type Tab {
  Overview
  Coverage
}

/// A loadable region: still fetching, loaded with the data and the as_of it
/// answers, or failed with a message. The as_of on `Loaded` is what the staleness
/// guard compares against the model's current as_of.
pub type Load(a) {
  Loading
  Loaded(value: a)
  Failed(message: String)
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `ProjectsMsg(projects.Msg)`. Each
/// fetch result tags the `as_of` it answers for the staleness guard.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
  CreateProjectClicked
  CreateProjectStarted(result: Result(String, rsvp.Error(String)))
  WizardMsg(sub: wizard.Msg)
  DetailFetched(
    project_id: Int,
    result: Result(ProjectDetail, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  CoverageFetched(
    project_id: Int,
    result: Result(CoverageSnapshot, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  RosterFetched(
    result: Result(Roster, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  RatesFetched(
    date: String,
    result: Result(List(RateCardRow), rsvp.Error(String)),
  )
  BackToListClicked
  TabClicked(tab: Tab)
  TeamCardClicked(engineer_id: Int)
  InvoiceRowClicked(invoice_id: Int)
  OpStarted(permit: ops.Permit)
  OpStartedFor(permit: ops.Permit, engineer_id: Int)
  OpFieldEdited(field: ops.OpField, value: String)
  OpCancelled
  OpSubmitted
  OpResponded(result: Result(Nil, rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `route` at `as_of` on the signed-in
/// `actor`'s behalf. `Projects(Some(id))` opens that project's detail (so a cold
/// deep link to `/projects/:id` lands on the detail); any other route opens the
/// project list. Both arms kick off their read-model fetch AND the roster fetch.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case route {
    route.Projects(id: Some(project_id)) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op: None,
        tab: Overview,
        coverage: Loading,
      ),
      effect.batch([
        fetch_detail(project_id, as_of),
        fetch_roster(as_of),
        fetch_coverage(project_id, as_of),
      ]),
    )
    _ -> {
      let #(host, host_effect) = table_host.init("/api/projects/table", as_of)
      #(
        ListView(
          actor:,
          as_of:,
          host:,
          roster: Loading,
          op: None,
          wizard: None,
          rates: None,
          rates_for: "",
        ),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
  }
}

/// Re-fetch the active view for a new `as_of` without dropping in-flight op-form
/// state (stale-while-revalidate). The open form, if any, is preserved. Advancing
/// `as_of` makes the staleness guard in `update` drop any in-flight responses for
/// the previous date.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case model {
    ListView(host:, op:, ..) -> {
      let #(host, host_effect) = table_host.refetch(host, as_of)
      #(
        ListView(
          actor:,
          as_of:,
          host:,
          roster: Loading,
          op:,
          wizard: None,
          rates: None,
          rates_for: "",
        ),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
    DetailView(project_id:, op:, tab:, ..) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op:,
        tab:,
        coverage: Loading,
      ),
      effect.batch([
        fetch_detail(project_id, as_of),
        fetch_roster(as_of),
        fetch_coverage(project_id, as_of),
      ]),
    )
  }
}

fn fetch_detail(project_id: Int, as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/projects/"
      <> int.to_string(project_id)
      <> "?as_of="
      <> iso_date(as_of),
    project_view.project_detail_decoder(),
    fn(result) { DetailFetched(project_id:, result:, as_of:) },
  )
}

fn fetch_coverage(project_id: Int, as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/projects/"
      <> int.to_string(project_id)
      <> "/coverage?as_of="
      <> iso_date(as_of),
    coverage_view.coverage_snapshot_decoder(),
    fn(result) { CoverageFetched(project_id:, result:, as_of:) },
  )
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { RosterFetched(result:, as_of:) },
  )
}

fn fetch_rate_card(date: String) -> Effect(Msg) {
  api.get(
    "/api/projects/rate-card?as_of=" <> date,
    decode.list(settings_view.rate_card_row_decoder()),
    fn(result) { RatesFetched(date:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s for
/// the shell to act on.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TableHostMsg(sub:) ->
      case model {
        ListView(as_of:, host:, ..) -> {
          let #(host, host_effect, out) = table_host.update(host, sub, as_of)
          let model = ListView(..model, host:)
          let effect = effect.map(host_effect, TableHostMsg)
          case out {
            table_host.Stay -> #(model, effect, [])
            table_host.Activated(id:) ->
              case int.parse(id) {
                Ok(project_id) -> #(model, effect, [
                  Navigate(route.Projects(id: Some(project_id))),
                ])
                Error(Nil) -> open_wizard(model, effect, id)
              }
            table_host.ActionInvoked(..) -> #(model, effect, [])
          }
        }
        _ -> #(model, effect.none(), [])
      }

    CreateProjectClicked -> #(
      model,
      host.start(config(), CreateProjectStarted),
      [],
    )

    CreateProjectStarted(result:) ->
      case result {
        Ok(id) -> open_wizard(model, effect.none(), id)
        Error(_) -> #(model, effect.none(), [])
      }

    WizardMsg(sub:) ->
      case model {
        ListView(wizard: Some(current), rates_for:, ..) ->
          case host.update(current, sub, WizardMsg) {
            host.Working(wizard: next, effect:) -> {
              let rates_effect = case wizard.current_step(next) == "contract" {
                False -> effect.none()
                True -> {
                  let contract_from =
                    wizard.field_value(next, "contract", "contract_from")
                  case contract_from != "" && contract_from != rates_for {
                    False -> effect.none()
                    True -> fetch_rate_card(contract_from)
                  }
                }
              }
              #(
                ListView(..model, wizard: Some(next)),
                effect.batch([effect, rates_effect]),
                [],
              )
            }
            host.Dismissed(effect:) -> {
              let #(reloaded, fetch) = reload(ListView(..model, wizard: None))
              #(reloaded, effect.batch([fetch, effect]), [])
            }
            host.Committed(effect:) -> {
              let #(reloaded, fetch) = reload(ListView(..model, wizard: None))
              #(reloaded, effect.batch([fetch, effect]), [OperationCommitted])
            }
          }
        _ -> #(model, effect.none(), [])
      }

    RatesFetched(date:, result:) ->
      case model {
        ListView(wizard: Some(current_wizard), ..) -> {
          let current_date =
            wizard.field_value(current_wizard, "contract", "contract_from")
          case date == current_date {
            False -> #(model, effect.none(), [])
            True ->
              case result {
                Ok(rows) -> #(
                  ListView(..model, rates: Some(rows), rates_for: date),
                  effect.none(),
                  [],
                )
                Error(_) -> #(
                  ListView(..model, rates: Some([]), rates_for: date),
                  effect.none(),
                  [],
                )
              }
          }
        }
        _ -> #(model, effect.none(), [])
      }

    DetailFetched(project_id:, result:, as_of:) ->
      case model {
        DetailView(project_id: current, as_of: current_as_of, ..)
          if current == project_id && current_as_of == as_of
        -> #(set_detail(model, load_result(result)), effect.none(), [])
        _ -> #(model, effect.none(), [])
      }

    CoverageFetched(project_id:, result:, as_of:) ->
      case model {
        DetailView(project_id: current, as_of: current_as_of, ..)
          if current == project_id && current_as_of == as_of
        -> {
          let coverage = load_result(result)
          let updated = set_coverage(model, coverage)
          let op = reprefill_capability_id(current_op(updated), coverage)
          #(set_op(updated, op), effect.none(), [])
        }
        _ -> #(model, effect.none(), [])
      }

    RosterFetched(result:, as_of:) ->
      case as_of == view_as_of(model) {
        True -> #(set_roster(model, load_result(result)), effect.none(), [])
        False -> #(model, effect.none(), [])
      }

    BackToListClicked -> #(model, effect.none(), [
      Navigate(route.Projects(id: None)),
    ])

    TabClicked(tab:) ->
      case model {
        DetailView(..) -> #(DetailView(..model, tab:), effect.none(), [])
        _ -> #(model, effect.none(), [])
      }

    TeamCardClicked(engineer_id:) -> #(model, effect.none(), [
      Navigate(route.People(id: Some(engineer_id))),
    ])

    InvoiceRowClicked(invoice_id:) -> #(model, effect.none(), [
      Navigate(route.Finance(tab: route.Invoices, invoice: Some(invoice_id))),
    ])

    OpStarted(permit:) -> #(
      set_op(model, Some(open_op(model, ops.permit_kind(permit), None))),
      effect.none(),
      [],
    )

    OpStartedFor(permit:, engineer_id:) -> #(
      set_op(
        model,
        Some(open_op(model, ops.permit_kind(permit), Some(engineer_id))),
      ),
      effect.none(),
      [],
    )

    OpFieldEdited(field:, value:) ->
      case current_op(model) {
        Some(ops.OpState(kind:, form:, ..)) -> {
          let form = ops.update_op_form(form, field, value)
          #(
            set_op(model, Some(ops.OpState(kind:, form:, error: None))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpCancelled -> #(set_op(model, None), effect.none(), [])

    OpSubmitted ->
      case current_op(model) {
        Some(ops.OpState(kind:, form:, ..)) ->
          case ops.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              set_op(
                model,
                Some(ops.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case result {
        Ok(_) -> {
          let cleared = set_op(model, None)
          let #(reloaded, effect) = reload(cleared)
          #(reloaded, effect, [OperationCommitted])
        }
        Error(error) ->
          case current_op(model) {
            Some(ops.OpState(kind:, form:, ..)) -> #(
              set_op(
                model,
                Some(ops.OpState(
                  kind:,
                  form:,
                  error: Some(api.describe_error(error)),
                )),
              ),
              effect.none(),
              [],
            )
            None -> #(model, effect.none(), [])
          }
      }
  }
}

fn load_result(result: Result(a, rsvp.Error(String))) -> Load(a) {
  case result {
    Ok(value) -> Loaded(value:)
    Error(error) -> Failed(api.describe_error(error))
  }
}

/// Re-fetch the active view (read model and roster) at the as_of the current view
/// answers, so a committed write is reflected immediately.
fn reload(model: Model) -> #(Model, Effect(Msg)) {
  case model {
    ListView(actor:, as_of:, host:, op:, ..) -> {
      let #(host, host_effect) = table_host.refetch(host, as_of)
      #(
        ListView(
          actor:,
          as_of:,
          host:,
          roster: Loading,
          op:,
          wizard: None,
          rates: None,
          rates_for: "",
        ),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
    DetailView(actor:, as_of:, project_id:, op:, tab:, ..) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op:,
        tab:,
        coverage: Loading,
      ),
      effect.batch([
        fetch_detail(project_id, as_of),
        fetch_roster(as_of),
        fetch_coverage(project_id, as_of),
      ]),
    )
  }
}

fn view_as_of(model: Model) -> calendar.Date {
  case model {
    ListView(as_of:, ..) -> as_of
    DetailView(as_of:, ..) -> as_of
  }
}

fn current_op(model: Model) -> Option(ops.OpState) {
  case model {
    ListView(op:, ..) -> op
    DetailView(op:, ..) -> op
  }
}

fn set_op(model: Model, op: Option(ops.OpState)) -> Model {
  case model {
    ListView(..) -> ListView(..model, op:)
    DetailView(..) -> DetailView(..model, op:)
  }
}

fn set_detail(model: Model, detail: Load(ProjectDetail)) -> Model {
  case model {
    DetailView(..) -> DetailView(..model, detail:)
    _ -> model
  }
}

fn set_roster(model: Model, roster: Load(Roster)) -> Model {
  case model {
    ListView(..) -> ListView(..model, roster:)
    DetailView(..) -> DetailView(..model, roster:)
  }
}

fn set_coverage(model: Model, coverage: Load(CoverageSnapshot)) -> Model {
  case model {
    DetailView(..) -> DetailView(..model, coverage:)
    _ -> model
  }
}

// --- Op-form launch ----------------------------------------------------------

/// A fresh op form for `kind`. The project select is pre-filled and locked from
/// the detail view (so an op started on a project's page targets it); profile and
/// plan edits are pre-filled from the loaded detail (title/summary, budget/target
/// completion) rather than starting blank; an op launched from a team card
/// pre-fills the engineer. Entity slots are then snapped to valid roster options.
fn open_op(
  model: Model,
  kind: ops.OpKind,
  engineer_id: Option(Int),
) -> ops.OpState {
  let form = ops.blank_op_form(kind, view_as_of(model))
  let form = seed_project(model, form)
  let form = seed_detail_fields(model, kind, form)
  let form = prefill_capability_id(form, kind, coverage_of(model))
  let form = case engineer_id {
    Some(id) -> ops.update_op_form(form, ops.FEngineerId, int.to_string(id))
    None -> form
  }
  let form = reconcile(model, form)
  ops.OpState(kind:, form:, error: None)
}

/// Seed the form's project slot from the detail view, so an op composed on a
/// project's page pre-targets that project.
fn seed_project(model: Model, form: ops.OpForm) -> ops.OpForm {
  case model {
    DetailView(project_id:, ..) ->
      ops.update_op_form(form, ops.FProjectId, int.to_string(project_id))
    ListView(..) -> form
  }
}

/// Pre-fill the profile (title/summary) and plan (budget/target completion) slots
/// from the loaded detail, so an edit form opens showing the project's current
/// values rather than blank.
fn seed_detail_fields(
  model: Model,
  kind: ops.OpKind,
  form: ops.OpForm,
) -> ops.OpForm {
  case model {
    DetailView(detail: Loaded(detail), ..) ->
      case kind {
        ops.OpUpdateProjectProfile ->
          form
          |> ops.update_op_form(ops.FTitle, detail.profile.title)
          |> ops.update_op_form(ops.FSummary, detail.profile.summary)
        ops.OpUpdateProjectPlan ->
          form
          |> ops.update_op_form(
            ops.FBudget,
            float_text(money.to_float(detail.plan.budget)),
          )
          |> ops.update_op_form(
            ops.FTargetCompletion,
            iso_date(detail.plan.target_completion),
          )
        ops.OpSetProjectRequirement ->
          form
          |> ops.update_op_form(ops.FLevel, "3")
          |> ops.update_op_form(ops.FFraction, "1")
        ops.OpSetProjectCapability ->
          form
          |> ops.update_op_form(ops.FLevel, "3")
          |> ops.update_op_form(ops.FFraction, "1")
        _ -> form
      }
    _ -> form
  }
}

/// Pre-select the first cataloged capability for `OpSetProjectCapability` so the
/// `<select>` opens on a valid capability id rather than blank. Other kinds (and an
/// unloaded coverage snapshot) leave the form untouched.
fn prefill_capability_id(
  form: ops.OpForm,
  kind: ops.OpKind,
  coverage: Load(CoverageSnapshot),
) -> ops.OpForm {
  case kind, coverage {
    ops.OpSetProjectCapability,
      Loaded(value: CoverageSnapshot(catalog: [first, ..], ..))
    ->
      ops.update_op_form(
        form,
        ops.FCapabilityId,
        int.to_string(first.capability_id),
      )
    _, _ -> form
  }
}

/// Re-run the capability prefill on an already-open op modal once the coverage
/// snapshot finishes loading after the modal opened: an `OpSetProjectCapability`
/// form whose `capability_id` is still unset (the catalog was `Loading` at open
/// time) gets seeded with the newly-loaded first capability. Any other modal (or an
/// already-seeded one) is left untouched.
fn reprefill_capability_id(
  op: Option(ops.OpState),
  coverage: Load(CoverageSnapshot),
) -> Option(ops.OpState) {
  case op {
    Some(ops.OpState(kind: ops.OpSetProjectCapability, form:, error:))
      if form.capability_id == ""
    ->
      Some(ops.OpState(
        kind: ops.OpSetProjectCapability,
        form: prefill_capability_id(form, ops.OpSetProjectCapability, coverage),
        error:,
      ))
    _ -> op
  }
}

/// The coverage snapshot load state for the open model, `Loading` on the list page
/// (which never composes `OpSetProjectCapability`).
fn coverage_of(model: Model) -> Load(CoverageSnapshot) {
  case model {
    DetailView(coverage:, ..) -> coverage
    ListView(..) -> Loading
  }
}

/// Snap the form's engineer and project slots to valid options from the as-of
/// roster, so a freshly opened form names an engineer and project the directory
/// actually carries.
fn reconcile(model: Model, form: ops.OpForm) -> ops.OpForm {
  ops.reconcile_form(form, engineer_refs(model), project_refs(model))
}

/// The create-project host configuration for the Projects list.
pub fn config() -> host.Config {
  host.Config(kind: wkind.CreateProject, title: "Create a project")
}

fn open_wizard(
  model: Model,
  pending: Effect(Msg),
  instance_id: String,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    ListView(..) -> {
      let #(wizard_model, wizard_effect) =
        host.open(config(), instance_id, WizardMsg)
      #(
        ListView(..model, wizard: Some(wizard_model)),
        effect.batch([pending, wizard_effect]),
        [],
      )
    }
    _ -> #(model, pending, [])
  }
}

// --- Op-form directories -----------------------------------------------------

/// The engineer directory for op selects on the open model, from the as-of roster.
/// Empty until the roster loads.
fn engineer_refs(model: Model) -> List(Ref) {
  roster_engineers(roster_of(model))
}

/// The project directory for op selects on the open model, from the as-of roster.
/// Empty until the roster loads.
fn project_refs(model: Model) -> List(Ref) {
  roster_projects(roster_of(model))
}

fn roster_of(model: Model) -> Load(Roster) {
  case model {
    ListView(roster:, ..) -> roster
    DetailView(roster:, ..) -> roster
  }
}

pub fn roster_engineers(roster: Load(Roster)) -> List(Ref) {
  case roster {
    Loaded(value:) -> value.engineers
    _ -> []
  }
}

pub fn roster_projects(roster: Load(Roster)) -> List(Ref) {
  case roster {
    Loaded(value:) -> value.projects
    _ -> []
  }
}

// --- Date / number formatting -----------------------------------------------

/// Render a budget float for a pre-filled text input: a whole number when
/// integral ("84000"), otherwise its decimal form, so the Edit-plan form opens on
/// the project's current budget rather than blank.
fn float_text(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> float.to_string(value)
  }
}

pub fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

fn pad4(value: Int) -> String {
  case value < 10 {
    True -> "000" <> int.to_string(value)
    False ->
      case value < 100 {
        True -> "00" <> int.to_string(value)
        False ->
          case value < 1000 {
            True -> "0" <> int.to_string(value)
            False -> int.to_string(value)
          }
      }
  }
}
