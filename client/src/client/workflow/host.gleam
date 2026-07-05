//// Shared hosting for a workflow wizard embedded in a list page. The People
//// onboarding host and the Projects create-project host differ only in their
//// `WorkflowKind`, dialog title, and the optional per-step aside. Starting a draft,
//// opening the wizard with a focus trap, delegating `wizard.Msg`s, and rendering the
//// dialog are shared here, so a third workflow host becomes configuration.

import client/focus
import client/ui/atoms
import client/workflow/api as wapi
import client/workflow/wizard
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import rsvp
import shared/workflow/kind.{type WorkflowKind}

/// A host's configuration: the workflow kind it runs and the dialog title it shows.
/// Constructed inline at each call site; the open wizard model lives in the page model
/// as `Option(wizard.Model)`.
pub type Config {
  Config(kind: WorkflowKind, title: String)
}

/// What the host resolved a `wizard.Msg` to: keep `Working` with the updated wizard and
/// its mapped effect, or the wizard closed (`Dismissed`/`Committed`) carrying its focus
/// release. On a close the caller drops the wizard and runs its own refetch.
pub type Resolved(msg) {
  Working(wizard: wizard.Model, effect: Effect(msg))
  Dismissed(effect: Effect(msg))
  Committed(effect: Effect(msg))
}

/// POST a fresh draft of the host's kind; the result is the new instance id.
pub fn start(
  config: Config,
  to_msg: fn(Result(String, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  wapi.start(kind.to_string(config.kind), to_msg)
}

/// Open the wizard for `instance_id`: its init effect (mapped through `wrap`) batched
/// with the modal focus trap.
pub fn open(
  config: Config,
  instance_id: String,
  wrap: fn(wizard.Msg) -> msg,
) -> #(wizard.Model, Effect(msg)) {
  let #(wizard_model, wizard_effect) = wizard.init(instance_id, config.kind)
  #(
    wizard_model,
    effect.batch([effect.map(wizard_effect, wrap), focus.trap(".modal--wide")]),
  )
}

/// Delegate a `wizard.Msg` to the open wizard, classifying its outcome for the host.
pub fn update(
  current: wizard.Model,
  sub: wizard.Msg,
  wrap: fn(wizard.Msg) -> msg,
) -> Resolved(msg) {
  let #(next, wizard_effect, outcome) = wizard.update(current, sub)
  case outcome {
    wizard.Working ->
      Working(wizard: next, effect: effect.map(wizard_effect, wrap))
    wizard.Dismissed -> Dismissed(effect: focus.release())
    wizard.Committed -> Committed(effect: focus.release())
  }
}

/// Render the wizard dialog when open, with the host's title and per-step `aside`.
pub fn view(
  open: Option(wizard.Model),
  config: Config,
  permissions: Set(String),
  aside: fn(String) -> Element(wizard.Msg),
  wrap: fn(wizard.Msg) -> msg,
) -> Element(msg) {
  case open {
    None -> element.none()
    Some(wizard_model) ->
      atoms.dialog(
        title: config.title,
        on_dismiss: wrap(wizard.DismissClicked),
        body: element.map(wizard.view(wizard_model, permissions, aside), wrap),
      )
  }
}
