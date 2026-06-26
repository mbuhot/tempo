//// Web: the signed-in identity JSON the client stores for UI gating — the journal
//// actor, the linked engineer (for own-resource UI), and the effective permission keys.
//// ONE encoder shared by POST /api/login (the convenience snapshot at sign-in) and
//// GET /api/me (the canonical, re-fetchable resolution), so the two never drift.

import gleam/json.{type Json}
import gleam/set
import tempo/server/auth.{type Principal}

/// Encode a resolved `Principal` as `{actor, engineer_id, permissions}`.
pub fn encode(principal: Principal) -> Json {
  json.object([
    #("actor", json.string(principal.actor)),
    #("engineer_id", json.nullable(principal.engineer_id, json.int)),
    #(
      "permissions",
      json.array(set.to_list(principal.permissions), json.string),
    ),
  ])
}
