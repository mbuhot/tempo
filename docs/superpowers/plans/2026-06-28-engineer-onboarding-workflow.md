# Engineer Onboarding Workflow (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A multi-step wizard to onboard an engineer, with draft state persisted server-side (durable across tab sleep, refresh, and devices), a Manager→Finance hand-off, and an atomic commit into the existing `engineer.*` domain facts.

**Architecture:** Server-driven, like the data-table system — a `WorkflowSchema` (steps → sections → typed fields) is a pure Gleam value the client renders generically. Draft values are stored append-only as transaction-time versions in `workflow_step_value`; the instance lifecycle (`Draft → AwaitingFinance → Committed/Cancelled`) lives in `workflow_instance`. Draft mutations go through a dedicated, un-journaled `/api/workflows` API; the final commit goes through the existing `/api/operations` command pipeline so it is journaled and writes facts atomically.

**Tech Stack:** Gleam (Erlang target server, Lustre client), Postgres (pog + squirrel codegen), wisp router, gleeunit (`assert x == expected`).

GitHub: Phase 1 = #28, Phase 2 = #29. Design artifact linked in #28.

## Global Constraints

- Gleam style: `let assert Ok(..)` for unwrapping; no inline comments inside functions; doc comments terse, one line. Boolean-flag smell → status unions.
- Tests: `assert expr == expected` (no gleeunit `should`); deterministic data; behaviour-driven. DB-backed server tests wrap mutations in a rolling-back transaction via `test_pool`.
- SQL: author `.sql` under `src/tempo/server/<domain>/sql/`, regenerate the typed `sql.gleam` with `bin/squirrel`. Never hand-edit `sql.gleam`.
- Migrations: additive file `server/priv/migrations/20260628HHMMSS_<name>.sql`; never edit `001_schema.sql`.
- Draft autosave must NOT write to `event_log`. Only commit journals.
- Commands/codecs: per-aggregate `encode`/`decoder(op)`; new aggregate wired into `shared/command.gleam`.
- Run server tests + format: `bin/test`. Regen SQL: `bin/squirrel`. Apply migrations: `bin/migrate`.

---

## File Structure

**Shared (wire contract)**
- `shared/src/shared/workflow/schema.gleam` — `WorkflowSchema`, `Step`, `Section`, `Field`, `FieldType`, `Layout`, `Choice` + JSON codecs.
- `shared/src/shared/workflow/value.gleam` — `FieldValue` (the typed value a field holds) + codecs; the wire form of a saved/loaded value.
- `shared/src/shared/workflow/view.gleam` — `DraftView` (instance status, current step, per-field values, step completion), `DraftSummary` (resume list row) + codecs.
- `shared/src/shared/workflow/command.gleam` — `WorkflowCommand` (commit only, Phase 1) + codecs; wired into `shared/command.gleam`.

**Server**
- `server/priv/migrations/20260628120000_workflow_onboarding.sql` — `workflow_instance`, `workflow_step_value`.
- `server/src/tempo/server/workflow/schema.gleam` — `onboard_schema() -> WorkflowSchema` (the Phase-1 fixed flow as a pure value); `field_type_of(step, key)` lookups.
- `server/src/tempo/server/workflow/instance.gleam` — instance lifecycle: `start`, `load`, `save_field`, `complete_step`, `hand_off`, `cancel`, `list_for`, `draft_view`; the `Status` union + transitions.
- `server/src/tempo/server/workflow/commit.gleam` — `route(conn, WorkflowCommand)`: load draft, mint engineer, build facts, mark instance committed; returns `Recorded`.
- `server/src/tempo/server/workflow/sql/*.sql` + generated `sql.gleam`.
- `server/src/tempo/server/workflow/http.gleam` — `/api/workflows` handlers (start/save/complete/handoff/cancel + GET draft + GET drafts list).
- Modify `server/src/tempo/server/web/router.gleam` — register `/api/workflows*`.
- Modify `server/src/tempo/server/command.gleam` — route `WorkflowCommand`.

**Client**
- `client/src/client/workflow/render.gleam` — generic renderer: step → section cards → typed field widgets (exhaustive on `FieldType`).
- `client/src/client/workflow/draft_cache.gleam` — localStorage mirror + reconciliation.
- `client/src/client/workflow/api.gleam` — fetch schema/draft/list, save field, complete step, handoff, cancel; commit via `api.submit_operation`.
- `client/src/client/page/onboard.gleam` — the page (Model/Msg/init/update/view/refetch) per the frozen page contract.
- Modify `client/src/client/route.gleam` — `Onboard(instance_id, step_id)` route.
- Modify `client/src/client/app.gleam` — `OnboardPage`, `OnboardMsg`, init/refetch/update wiring; Resume dropdown entry.
- Modify `client/src/client/page/board.gleam` (or shell) — "+ Add ▸ Onboard engineer" launcher + Resume dropdown.

**Tests**
- `shared/test/workflow_schema_test.gleam` — codec round-trips.
- `server/test/workflow_instance_test.gleam` — lifecycle + draft persistence + transitions (rolling-back).
- `server/test/workflow_commit_test.gleam` — commit creates the engineer facts.
- `e2e/tests/onboarding.spec.ts` — manager fills 1–5, hands off, finance confirms + commits.

---

## Data model decisions (Phase 1)

- `workflow_step_value` is **append-only**, stamped `recorded_at timestamptz default clock_timestamp()`. Current value per field = latest `recorded_at`. Durable history is retained for Phase 2 as-of reads. (`clock_timestamp()` advances within a transaction, so tests and same-request double-saves stay ordered.)
- **Undo/redo in Phase 1 is a client-side per-step stack** that re-issues `save_field`. True server as-of-read undo is deferred (Phase 2). The durable history makes this a non-breaking refinement.
- Instance id: `gen_random_uuid()` text.
- Draft mutations are not authorized as journaled commands; the `/api/workflows` handlers gate on the authenticated principal (owner/assignee). Commit is a journaled command gated on a finance permission.

---

## Task 1: Migration — workflow tables

**Files:**
- Create: `server/priv/migrations/20260628120000_workflow_onboarding.sql`
- Test: `server/test/workflow_migration_test.gleam`

**Produces:** tables `workflow_instance(id text pk, kind text, status text, owner_id int, assignee_id int null, current_step text, created_at, updated_at)` and `workflow_step_value(instance_id text, step_id text, field_key text, value jsonb, recorded_at timestamptz default clock_timestamp(), id bigint identity pk)`.

DDL:
```sql
CREATE TABLE workflow_instance (
  id           text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  kind         text NOT NULL,
  status       text NOT NULL DEFAULT 'draft'
                 CONSTRAINT workflow_instance_status_check
                 CHECK (status IN ('draft','awaiting_finance','committed','cancelled')),
  owner_id     int  NOT NULL REFERENCES account(id),
  assignee_id  int  REFERENCES account(id),
  current_step text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workflow_step_value (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id text NOT NULL REFERENCES workflow_instance(id) ON DELETE CASCADE,
  step_id     text NOT NULL,
  field_key   text NOT NULL,
  value       jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX workflow_step_value_current_idx
  ON workflow_step_value (instance_id, field_key, recorded_at DESC, id DESC);
```

- [ ] Step 1: Write the migration file with the DDL above.
- [ ] Step 2: Write failing test: after `migrate.run`, `workflow_instance` and `workflow_step_value` exist (query `information_schema.tables`). Run, expect FAIL.
- [ ] Step 3: `bin/migrate`. Run test, expect PASS.
- [ ] Step 4: Commit (`feat: workflow draft tables (#28)`).

## Task 2: shared schema types + codecs

**Files:** Create `shared/src/shared/workflow/schema.gleam`; Test `shared/test/workflow_schema_test.gleam`.

**Produces (exact types):**
```gleam
pub type FieldType {
  TextField  EmailField  IntField  MoneyField  DateField
  EnumField(options: List(Choice))  PersonField  BoolField
}
pub type Choice { Choice(value: String, label: String) }
pub type Layout { OneColumn  TwoColumn }
pub type Field {
  Field(key: String, label: String, kind: FieldType, required: Bool,
        help: Option(String))
}
pub type Section { Section(title: String, layout: Layout, fields: List(Field)) }
pub type Step { Step(id: String, title: String, sections: List(Section),
                     requires_permission: Option(String)) }
pub type WorkflowSchema {
  WorkflowSchema(kind: String, title: String, steps: List(Step))
}
```
Codecs: `encode_schema`, `schema_decoder` (mirror `table/column.gleam` style; `FieldType` encoded with a `"type"` tag + options for enum).

- [ ] Step 1: failing round-trip test (`schema_round_trips_test`) with a 2-step schema incl. an `EnumField`.
- [ ] Step 2: run, expect FAIL (module missing).
- [ ] Step 3: implement types + codecs.
- [ ] Step 4: run, expect PASS. Commit.

## Task 3: shared FieldValue + DraftView + DraftSummary

**Files:** Create `shared/src/shared/workflow/value.gleam`, `shared/src/shared/workflow/view.gleam`; Test `shared/test/workflow_view_test.gleam`.

**Produces:**
```gleam
// value.gleam
pub type FieldValue { TextValue(String) IntValue(Int) MoneyValue(Money)
  DateValue(Date) BoolValue(Bool) PersonValue(Int) }
pub fn encode(FieldValue) -> Json
pub fn decoder(of: FieldType) -> Decoder(FieldValue)   // type-directed, like cell_decoder

// view.gleam
pub type StepStatus { Pending Active Done Locked }
pub type DraftView {
  DraftView(instance_id: String, kind: String, status: String,
            current_step: String, assignee_is_me: Bool,
            values: Dict(String, FieldValue),          // key = "step.field"
            step_status: Dict(String, StepStatus))
}
pub type DraftSummary {
  DraftSummary(instance_id: String, kind: String, status: String,
               title: String, current_step: String, awaiting_me: Bool)
}
+ codecs for DraftView, DraftSummary, and a list of summaries.
```

- [ ] round-trip tests for `FieldValue` (per variant via `decoder(of:)`), `DraftView`, `DraftSummary`. Red → implement → green → commit.

## Task 4: shared WorkflowCommand + wire into Command

**Files:** Create `shared/src/shared/workflow/command.gleam`; Modify `shared/src/shared/command.gleam`; Test extend `shared/test/...` (command round-trip).

**Produces:**
```gleam
pub type WorkflowCommand { CommitOnboarding(instance_id: String) }
pub fn encode(WorkflowCommand) -> Json   // op:"commit_onboarding"
pub fn decoder(op: String) -> Result(Decoder(WorkflowCommand), Nil)
```
Modify `Command` union: add `WorkflowCommand(workflow_command.WorkflowCommand)`; extend `encode_command` and `grouped_command_decoder`.

- [ ] command round-trip test red → implement → green → commit.

## Task 5: server onboard schema value

**Files:** Create `server/src/tempo/server/workflow/schema.gleam`; Test `server/test/workflow_schema_test.gleam`.

`onboard_schema() -> WorkflowSchema` — the 6 steps from #28 (identity, level_role, employment, contact, banking, payroll). `payroll` step has `requires_permission: Some("confirm_onboarding_payroll")`. Helper `field_type(schema, step_id, field_key) -> Result(FieldType, Nil)`.

- [ ] test: schema has 6 steps in order, payroll step gated, `field_type` resolves `employment`/`base_salary` to `MoneyField`. Red → implement → green → commit.

## Task 6: server SQL + instance persistence

**Files:** Create `server/src/tempo/server/workflow/sql/*.sql` then `bin/squirrel`; Create `server/src/tempo/server/workflow/instance.gleam`; Test `server/test/workflow_instance_test.gleam`.

SQL files:
- `instance_start.sql` — INSERT instance (kind, owner_id, current_step) RETURNING id.
- `instance_by_id.sql` — SELECT instance row.
- `instance_set_step.sql`, `instance_set_status.sql`, `instance_set_assignee.sql` — UPDATE + `updated_at = now()`.
- `instance_list_for.sql` — drafts where owner_id=$1 OR assignee_id=$1 AND status IN ('draft','awaiting_finance').
- `step_value_insert.sql` — INSERT append-only value.
- `step_values_current.sql` — `SELECT DISTINCT ON (field_key) step_id, field_key, value FROM workflow_step_value WHERE instance_id=$1 ORDER BY field_key, recorded_at DESC, id DESC`.

`instance.gleam` API:
```gleam
pub type Status { Draft AwaitingFinance Committed Cancelled }
pub fn start(conn, kind: String, owner_id: Int, first_step: String) -> Result(String, OperationError)
pub fn save_field(conn, instance_id, step_id, field_key, value_json: Json) -> Result(Nil, OperationError)
pub fn complete_step(conn, instance_id, next_step: String) -> Result(Nil, OperationError)
pub fn hand_off(conn, instance_id, assignee_id: Int) -> Result(Nil, OperationError)  // status->awaiting_finance
pub fn cancel(conn, instance_id) -> Result(Nil, OperationError)
pub fn draft_view(conn, instance_id, me_account_id) -> Result(Option(DraftView), OperationError)
pub fn list_for(conn, account_id) -> Result(List(DraftSummary), OperationError)
```
`draft_view` assembles current values (decoded per schema field type) + computes `step_status` from `current_step` ordering.

- [ ] tests (rolling-back): start→returns id; save_field then draft_view shows the value; latest save wins; complete_step advances current_step; hand_off sets awaiting_finance + assignee; list_for returns the draft. Red (stub with `todo`) → squirrel + implement → green → commit.

## Task 7: server commit handler + dispatch wiring

**Files:** Create `server/src/tempo/server/workflow/commit.gleam`; Modify `server/src/tempo/server/command.gleam`; Test `server/test/workflow_commit_test.gleam`.

`commit.route(conn, CommitOnboarding(instance_id))`:
1. load instance (must be `awaiting_finance`, else `OperationError`),
2. read current values, decode against `onboard_schema`,
3. `repository.create_engineer(conn)` → id,
4. build facts: `EngineerEmployed`, `EngineerAtLevel`, `EngineerContactDetails`, `EngineerBankingDetails`, `Salary` (level salary), from `start_date`,
5. mark instance `committed` (conn write),
6. return `Recorded(entry: Event(operation:"onboard_engineer", summary:..., payload:..), facts:)`.

Modify `command.route`: `WorkflowCommand(cmd) -> workflow_commit.route(conn, cmd)`. Authorize commit on permission `confirm_onboarding_payroll` (add to access policy + a role grant in a small migration or reuse an existing finance permission — confirm during impl).

- [ ] test (rolling-back): seed an awaiting_finance instance with all fields, dispatch commit, assert an engineer exists with employment/level/contact/banking/salary at the start date; instance status committed; second commit rejected. Red → implement → green → commit.

## Task 8: server HTTP + router

**Files:** Create `server/src/tempo/server/workflow/http.gleam`; Modify `server/src/tempo/server/web/router.gleam`. Test via existing router/integration patterns (light).

Endpoints (all `guard.authenticated`; owner/assignee checks):
- `GET  /api/workflows/schema/onboard_engineer` → `encode_schema(onboard_schema())`.
- `POST /api/workflows` `{kind}` → start; returns `{instance_id}`.
- `GET  /api/workflows/:id` → `DraftView`.
- `POST /api/workflows/:id/field` `{step, field, value}` → save_field.
- `POST /api/workflows/:id/step` `{next_step}` → complete_step.
- `POST /api/workflows/:id/handoff` `{assignee_id}` → hand_off.
- `POST /api/workflows/:id/cancel` → cancel.
- `GET  /api/workflows` → `list_for(principal)` → `[DraftSummary]`.

- [ ] add route arm; manual/integration check the schema + start + draft round-trip. Commit.

## Task 9: client route + api

**Files:** Modify `client/src/client/route.gleam`; Create `client/src/client/workflow/api.gleam`.

Route: add `Onboard(instance_id: String, step_id: String)` → `/onboard/<id>/<step>`; parse + `to_path`.
`workflow/api.gleam`: `fetch_schema`, `fetch_draft(id)`, `fetch_drafts()`, `start(kind, to_msg)`, `save_field(id, step, field, value)`, `complete_step(id, next)`, `handoff(id, assignee)`, `cancel(id)`; commit via `api.submit_operation(WorkflowCommand(CommitOnboarding(id)), ..)`.

- [ ] route parse/serialize test (client tests if present, else shared-style) red → implement → green → commit.

## Task 10: client renderer

**Files:** Create `client/src/client/workflow/render.gleam`.

`render_step(step: Step, values: Dict(String, FieldValue), on_edit: fn(field_key, String) -> msg, on_blur: fn(field_key) -> msg) -> Element(msg)` — section cards (CSS grid by `Layout`), each field a widget chosen exhaustively on `FieldType` (text/email/number/date/money inputs, enum select, bool toggle, person select). Reuse `ui.*` atoms where they fit.

- [ ] No logic test; verified via the page + e2e. Implement, ensure it compiles, commit.

## Task 11: client onboard page + draft_cache

**Files:** Create `client/src/client/page/onboard.gleam`, `client/src/client/workflow/draft_cache.gleam`.

`draft_cache`: `key(id) -> String`; `save(id, DraftView) -> Effect`; `load(id) -> Option(DraftView)`; reconcile prefers server on fetch, falls back to cache offline.

`onboard.gleam` Model: `Model(as_of, actor, instance_id, schema: Option(WorkflowSchema), draft: Option(DraftView), undo: Dict(step_id, History), saving: Bool, error: String)`. Msg: fetch results, `FieldEdited`, `FieldBlurred`, `NextClicked`, `BackClicked`, `UndoClicked`, `RedoClicked`, `HandOffClicked`, `CommitClicked`, save/commit results. `update` returns `OutMsg` (`Navigate` for step changes via URL, `OperationCommitted` on commit). On blur → save_field + cache. On next/back → `Navigate(Onboard(id, step))`. Undo/redo manipulate the per-step history stack and re-save.

- [ ] page compiles; behaviour covered by e2e. Implement, commit.

## Task 12: shell wiring + launcher + Resume

**Files:** Modify `client/src/client/app.gleam`, `client/src/client/page/board.gleam`.

Add `OnboardPage(onboard.Model)` to `Page`, `OnboardMsg(onboard.Msg)` to `Msg`; `init_page`/`refetch_page`/`update` arms; on `Onboard` route with empty id, start an instance then `modem.replace` to its url. Board gets "+ Add ▸ Onboard engineer" (gated on onboarding permission) and a "Resume" dropdown populated from `GET /api/workflows`.

- [ ] compiles; nav works. Commit.

## Task 13: e2e happy path

**Files:** Create `e2e/tests/onboarding.spec.ts`.

Manager signs in, starts onboarding, fills steps 1–5 (assert values persist across a reload mid-flow), hands off to Finance; Finance signs in, sees the awaiting count, opens the draft, confirms payroll, commits; assert the new engineer appears in People with the entered details.

- [ ] write spec; run against seeded app; green. Commit.

---

## Self-Review notes

- Spec coverage: durability (Task 1,6,11 + e2e reload), back/forward (Task 9,11 URL steps), hand-off (Task 6,7,12), commit→facts (Task 7), resume (Task 8,12), validation (render format Task 10; semantic at complete_step/commit Task 6,7). Undo/redo: client-stack (Task 11) — intentional P1 simplification, history retained server-side.
- Authorization for commit permission resolved in Task 7 against the access policy.
- `clock_timestamp()` chosen so rolling-back single-transaction tests still order saves.
