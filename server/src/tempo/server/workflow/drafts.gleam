//// Shared draft-prepend read for list tables that surface in-progress workflow
//// drafts as rows. Each table supplies its workflow kind, the commit permission that
//// gates the shared awaiting-Finance queue, and where the draft's display label lives
//// (its step id and value path). The viewer scope — an owner sees their own drafts; a
//// committer also sees the awaiting-Finance queue — is enforced here as bound params.

import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/result
import pog
import tempo/server/auth
import tempo/server/context.{type Context}

/// One in-progress draft surfaced as a table row: the instance id (the row id), the
/// display label (the open value at the configured path, or ""), and lifecycle status.
pub type DraftRow {
  DraftRow(instance_id: String, label: String, status: String)
}

/// Where a kind's draft rows come from: the `kind` string, the `commit_permission`
/// gating the shared awaiting-Finance queue, and the `step_id` + `value_path` of the
/// step value used as the row's display label.
pub type DraftSource {
  DraftSource(
    kind: String,
    commit_permission: String,
    step_id: String,
    value_path: String,
  )
}

/// The in-progress drafts visible to the context's viewer for `source`'s kind: drafts
/// they own, plus — when they hold the commit permission — the shared awaiting-Finance
/// queue. Ordered by creation time, oldest first.
pub fn rows(
  context: Context,
  source: DraftSource,
) -> Result(List(DraftRow), pog.QueryError) {
  let #(account_id, can_commit) = scope(context, source.commit_permission)
  let row_decoder = {
    use instance_id <- decode.field(0, decode.string)
    use label <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    decode.success(DraftRow(instance_id:, label:, status:))
  }
  use returned <- result.map(
    pog.query(sql(source))
    |> pog.parameter(pog.int(account_id))
    |> pog.parameter(pog.bool(can_commit))
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  returned.rows
}

/// The draft scope for the viewer: their account id and whether they hold the kind's
/// commit permission. No principal sees no drafts (the route guard makes this
/// unreachable in production).
fn scope(context: Context, commit_permission: String) -> #(Int, Bool) {
  case context.principal {
    Some(principal) -> #(
      principal.account_id,
      auth.can(principal, commit_permission),
    )
    None -> #(-1, False)
  }
}

/// The draft list query for `source`. The owner-or-committer scope binds the viewer's
/// account id ($1) and commit flag ($2) as params; the kind, step id, and value path
/// are trusted per-kind constants composed into the text.
fn sql(source: DraftSource) -> String {
  "
SELECT i.id,
       coalesce(v.value #>> '" <> source.value_path <> "', ''),
       i.status
  FROM workflow_instance i
  LEFT JOIN workflow_step_value v
    ON v.instance_id = i.id AND v.step_id = '" <> source.step_id <> "'
       AND upper_inf(v.recorded_during)
 WHERE i.kind = '" <> source.kind <> "'
   AND i.status IN ('draft', 'awaiting_finance')
   AND (i.owner_id = $1 OR ($2 AND i.status = 'awaiting_finance'))
 ORDER BY i.created_at
"
}
