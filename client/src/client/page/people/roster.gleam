//// The People roster list (FR-PE*), a self-contained sub-component MVU split out of
//// `client/page/people`. This is the page's LIST mode: it owns its as-of, the roster
//// table host, and the open onboarding wizard (or `None`).
////
//// The roster renders via the generic data table, embedded through `table_host`
//// (which owns load state, infinite scroll, debounce, and column-layout persistence):
//// `GET /api/people/table?as_of=&filter.*=&sort=&page_size=&cursor=`. The list also
//// carries in-progress onboarding drafts as rows (their id is the instance uuid, not
//// an engineer id). A row's `Activated` outcome: a numeric id navigates to the
//// engineer's detail; a non-numeric id opens the onboarding wizard for that draft.
//// The `+ Onboard` action starts a fresh draft and opens the wizard. Closing the
//// wizard refetches the list; a commit also raises `OperationCommitted`.

import client/focus
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui
import client/workflow/api as wapi
import client/workflow/wizard
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

const onboard_kind = "onboard_engineer"

/// The roster list's state: the as-of its data answers, the roster table host, and
/// the open onboarding wizard (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    host: table_host.Host,
    wizard: Option(wizard.Model),
  )
}

pub type Msg {
  TableHostMsg(sub: table_host.Msg)
  OnboardClicked(permit: ui.Permit)
  OnboardStarted(result: Result(String, rsvp.Error(String)))
  WizardMsg(sub: wizard.Msg)
}

/// Start the list mode at `as_of`, fetching the roster table.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.init("/api/people/table", as_of)
  #(Model(as_of:, host:, wizard: None), effect.map(host_effect, TableHostMsg))
}

/// Re-fetch the list for a new `as_of` (stale-while-revalidate), keeping any open
/// wizard and the active filters/sort/layout.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  #(Model(..model, as_of:, host:), effect.map(host_effect, TableHostMsg))
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id:) ->
          case int.parse(id) {
            // A numeric row id is an engineer → open their detail.
            Ok(engineer_id) -> #(model, effect, [
              Navigate(route.People(id: Some(engineer_id))),
            ])
            // A non-numeric id is an onboarding draft (instance uuid) → resume it.
            Error(Nil) -> open_wizard(model, effect, id)
          }
        table_host.ActionInvoked(..) -> #(model, effect, [])
      }
    }

    OnboardClicked(..) -> #(model, wapi.start(onboard_kind, OnboardStarted), [])

    OnboardStarted(result:) ->
      case result {
        Ok(id) -> open_wizard(model, effect.none(), id)
        Error(_) -> #(model, effect.none(), [])
      }

    WizardMsg(sub:) ->
      case model.wizard {
        None -> #(model, effect.none(), [])
        Some(current) -> {
          let #(next, wizard_effect, outcome) = wizard.update(current, sub)
          case outcome {
            wizard.Working -> #(
              Model(..model, wizard: Some(next)),
              effect.map(wizard_effect, WizardMsg),
              [],
            )
            wizard.Dismissed -> {
              let #(model, fetch) =
                refetch(Model(..model, wizard: None), model.as_of)
              #(model, effect.batch([fetch, focus.release()]), [])
            }
            wizard.Committed -> {
              let #(model, fetch) =
                refetch(Model(..model, wizard: None), model.as_of)
              #(model, effect.batch([fetch, focus.release()]), [
                OperationCommitted,
              ])
            }
          }
        }
      }
  }
}

/// Open the wizard for an instance, batching its init effect with any pending host
/// effect.
fn open_wizard(
  model: Model,
  pending: Effect(Msg),
  instance_id: String,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  let #(wizard_model, wizard_effect) = wizard.init(instance_id)
  #(
    Model(..model, wizard: Some(wizard_model)),
    effect.batch([
      pending,
      effect.map(wizard_effect, WizardMsg),
      focus.trap(".modal--wide"),
    ]),
    [],
  )
}

// --- View -------------------------------------------------------------------

/// Render the list mode: the page head with the Onboard action, the onboarding
/// wizard modal (when open), and the roster table.
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let list_page =
    ui.list_page(
      title: "People",
      blurb: "Everyone employed as of "
        <> time.iso_date(model.as_of)
        <> ". Open a person for their full record and history.",
      actions: [
        ui.page_action(
          ui.permit(permissions, own: False, kind: ui.OpOnboardEngineer),
          OnboardClicked,
          "+ Onboard",
        ),
      ],
      body: element.map(
        table_host.view(model.host, "Loading roster…"),
        TableHostMsg,
      ),
    )
  html.div([], [view_wizard(model.wizard, permissions), list_page])
}

fn view_wizard(
  open: Option(wizard.Model),
  permissions: Set(String),
) -> Element(Msg) {
  case open {
    None -> element.none()
    Some(wizard_model) ->
      ui.dialog(
        title: "Onboard an engineer",
        on_dismiss: WizardMsg(wizard.DismissClicked),
        body: element.map(wizard.view(wizard_model, permissions), WizardMsg),
      )
  }
}
