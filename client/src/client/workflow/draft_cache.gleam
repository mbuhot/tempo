//// A localStorage mirror of a draft view, so a tab that sleeps and restores (or a
//// reload) repaints instantly from the cache while the server refetch confirms the
//// source of truth. The server view always wins once it arrives; the cache only
//// bridges the gap before it does.

import client/storage
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}
import shared/workflow/view.{type DraftView}

fn key(instance_id: String) -> String {
  "tempo.onboard." <> instance_id
}

/// Mirror a draft view into localStorage.
pub fn save(draft: DraftView) -> Effect(msg) {
  storage.set(key(draft.instance_id), json.to_string(view.encode_draft(draft)))
}

/// Read a mirrored draft view, or `None` if absent or unparseable.
pub fn load(instance_id: String) -> Option(DraftView) {
  case storage.get(key(instance_id)) {
    Some(text) ->
      case json.parse(text, view.draft_decoder()) {
        Ok(draft) -> Some(draft)
        Error(_) -> None
      }
    None -> None
  }
}
