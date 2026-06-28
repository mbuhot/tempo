# Project-creation Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second fixed-structure workflow — *Create a project* — reusing the onboarding-era workflow engine, introducing a `kind → schema` registry seam and a repeating-group schema feature.

**Architecture:** The DB tables, SQL, instance lifecycle, wire types, and client wizard are already generic. A new `workflow/registry` module maps `kind → WorkflowSchema` and derives first/finance/title/step-ids/commit-gate from the schema, so `http`/`instance` stop naming a specific workflow. The project schema is built server-side (it needs DB-sourced client choices). Commit routing stays per-kind. Repeating groups are added to the schema/value/render/wizard layer last, since they don't fit the scalar edit model.

**Tech Stack:** Gleam (Erlang server, JS Lustre client, shared wire package), Postgres temporal model, squirrel codegen, Playwright e2e.

## Global Constraints

- Gleam style: `let assert Ok(..)` unwrapping; `int.modulo` for positive wrap; no inline comments (doc comments only, terse); descriptive names (no type-tag suffixes); model status as a type, not booleans.
- Tests: `assert expr == expected` (no gleeunit/should); deterministic values; behaviour-driven; never assert absence of a non-feature.
- TDD: stub with `todo`, one failing test, confirm it fails on assertion/`todo` (not compile error), minimal code, refactor.
- Clean-build after adding a union variant (incremental builds mask inexhaustive matches): `cd server && gleam clean && gleam build`.
- Server tests run on the **base** seed (`bin/seed`); reseed to base before `gleam test`. e2e runs on the **demo** seed; use a unique name per run.
- Preserve full test output (no `head`/`tail`/`grep` on the runner in the same command).
- Doc/copy: state the positive, no counterfactuals, no inline issue citations.
- New permission value: `project.create.confirm`. New workflow kind: `create_project`.

---

## File Structure

**New files:**
- `server/src/tempo/server/workflow/registry.gleam` — `kind → WorkflowSchema` + derived helpers (first_step, finance_step, step_ids, title, commit_permission). The seam.
- `server/src/tempo/server/workflow/project_schema.gleam` — `create_project_schema(ctx) -> Result(WorkflowSchema, _)`, building client choices from a DB read.
- `server/src/tempo/server/project/sql/clients_for_choice.sql` — list `(id, name)` of current clients for the picker.
- `server/src/tempo/server/project/sql/rate_card_asof.sql` — `(level, day_rate)` effective at a date, for the read-only display.
- `client/src/client/page/projects/roster.gleam` *(only if projects.gleam isn't already a list/detail split — otherwise fold the host into projects.gleam)*.

**Modified files:**
- `shared/src/shared/access.gleam` — add `project_create_confirm`.
- `shared/src/shared/workflow/command.gleam` — add `CreateProject(instance_id)`.
- `shared/src/shared/workflow/schema.gleam` — add `GroupField` (Phase C).
- `shared/src/shared/workflow/value.gleam` — add `RowsValue` (Phase C).
- `shared/src/shared/access/policy.gleam` — add `ConfirmProjectCreate` key.
- `server/src/tempo/server/workflow/http.gleam` — dispatch via registry, generalise `can_commit`.
- `server/src/tempo/server/workflow/instance.gleam` — `compute_step_status`/`title_for` via registry.
- `server/src/tempo/server/workflow/commit.gleam` — add `CreateProject` route arm.
- `server/src/tempo/server/auth.gleam` — add `command_tag` arm for `CreateProject`.
- `server/src/tempo/server/repository.gleam` — add `create_client`.
- `server/src/tempo/server/fact.gleam` — already has all needed facts; no change.
- `server/priv/seed/rbac_seed.sql` — grant `project.create.confirm` to owner + admin.
- `client/src/client/page/projects.gleam` — host the wizard (trigger + draft rows + resume).
- `server/src/tempo/server/project/table.gleam` — prepend project draft rows.
- `client/src/client/ui.gleam` — add `OpCreateProject` `OpKind`.
- `client/src/client/workflow/render.gleam` + `wizard.gleam` — group rendering (Phase C).
- `client/styles/wizard.scss` — repeating-group styles (Phase C).
- `e2e/project-creation.spec.js` — new spec.

---

# Phase A — The registry seam

Goal: onboarding keeps working, but `http`/`instance` no longer name it. Proves the plumbing seam.

### Task A1: Registry module derives config from a schema

**Files:**
- Create: `server/src/tempo/server/workflow/registry.gleam`
- Create: `server/test/workflow_registry_test.gleam`
- Reference (template): `server/src/tempo/server/workflow/schema.gleam` (onboarding `step_ids`/`finance_step`/`field_type`)

**Interfaces:**
- Consumes: `tempo/server/workflow/schema.onboard_schema/0`, `shared/workflow/schema.{WorkflowSchema, Step}`, `tempo/server/context.{Context}`.
- Produces:
  - `schema_for(kind: String, ctx: Context) -> Result(WorkflowSchema, Nil)`
  - `first_step(schema: WorkflowSchema) -> String`
  - `step_ids(schema: WorkflowSchema) -> List(String)`
  - `gated_step(schema: WorkflowSchema) -> Option(Step)` (first step with `requires_permission: Some`)
  - `finance_step(schema: WorkflowSchema) -> String` (the gated step's id, or `first_step`)
  - `commit_permission(schema: WorkflowSchema) -> Option(String)` (the gated step's permission)
  - `title(schema: WorkflowSchema) -> String`

- [ ] **Step 1: Write the failing test** in `server/test/workflow_registry_test.gleam`

```gleam
import gleam/option.{Some}
import tempo/server/workflow/registry
import tempo/server/workflow/schema as onboard

pub fn step_ids_come_from_schema_test() {
  let schema = onboard.onboard_schema()
  assert registry.step_ids(schema) == onboard.step_ids()
}

pub fn first_step_is_first_test() {
  let schema = onboard.onboard_schema()
  assert registry.first_step(schema) == "identity"
}

pub fn finance_step_is_the_gated_step_test() {
  let schema = onboard.onboard_schema()
  assert registry.finance_step(schema) == "payroll"
}

pub fn commit_permission_is_the_gated_steps_permission_test() {
  let schema = onboard.onboard_schema()
  assert registry.commit_permission(schema)
    == Some("engineer.onboard.commit")
}
```

- [ ] **Step 2: Run, confirm it fails** (`cd server && gleam test 2>&1 | tee /tmp/a1.log`) — fails to compile (module missing) → write the stub first, then it fails on `todo`.

- [ ] **Step 3: Implement** `registry.gleam`. `schema_for` initially handles only onboarding; project added in Phase B.

```gleam
//// The workflow registry: maps a workflow `kind` to its schema, and derives every
//// per-workflow datum the HTTP and instance layers need (first step, the gated
//// "finance" step, the commit permission, the title) FROM the schema — so those
//// layers never name a specific workflow. `schema_for` takes `Context` because some
//// schemas (project creation) source choices from the database.

import gleam/list
import gleam/option.{type Option, None, Some}
import shared/workflow/schema.{type Step, type WorkflowSchema}
import tempo/server/context.{type Context}
import tempo/server/workflow/schema as onboard

pub fn schema_for(kind: String, _ctx: Context) -> Result(WorkflowSchema, Nil) {
  case kind {
    "onboard_engineer" -> Ok(onboard.onboard_schema())
    _ -> Error(Nil)
  }
}

pub fn step_ids(schema: WorkflowSchema) -> List(String) {
  list.map(schema.steps, fn(step) { step.id })
}

pub fn first_step(schema: WorkflowSchema) -> String {
  case schema.steps {
    [step, ..] -> step.id
    [] -> ""
  }
}

pub fn gated_step(schema: WorkflowSchema) -> Option(Step) {
  list.find(schema.steps, fn(step) {
    case step.requires_permission {
      Some(_) -> True
      None -> False
    }
  })
  |> fn(result) {
    case result {
      Ok(step) -> Some(step)
      Error(_) -> None
    }
  }
}

pub fn finance_step(schema: WorkflowSchema) -> String {
  case gated_step(schema) {
    Some(step) -> step.id
    None -> first_step(schema)
  }
}

pub fn commit_permission(schema: WorkflowSchema) -> Option(String) {
  case gated_step(schema) {
    Some(step) -> step.requires_permission
    None -> None
  }
}

pub fn title(schema: WorkflowSchema) -> String {
  schema.title
}
```

- [ ] **Step 4: Run tests, confirm pass.** `cd server && gleam test 2>&1 | tee /tmp/a1.log`
- [ ] **Step 5: Commit.** `git add server/src/tempo/server/workflow/registry.gleam server/test/workflow_registry_test.gleam && git commit -m "Add workflow registry deriving per-kind config from the schema"`

### Task A2: `http.gleam` dispatches via the registry

**Files:**
- Modify: `server/src/tempo/server/workflow/http.gleam`
- Reference: the current hardcoded sites at `handle_schema:52`, `start_response:151`, `handle_action:89`, `can_commit:142`.

**Interfaces:**
- Consumes: `registry.{schema_for, first_step, finance_step, commit_permission, title}`.
- Produces: unchanged HTTP behaviour for onboarding; now kind-agnostic.

- [ ] **Step 1:** Replace `handle_schema` body:

```gleam
pub fn handle_schema(req: wisp.Request, ctx: Context, kind: String) -> wisp.Response {
  use _ <- guard.authenticated(ctx)
  use <- wisp.require_method(req, http.Get)
  case registry.schema_for(kind, ctx) {
    Ok(schema) -> response.json_response(wschema.encode_schema(schema))
    Error(_) -> wisp.not_found()
  }
}
```

- [ ] **Step 2:** Replace `start_response`:

```gleam
fn start_response(ctx: Context, principal: Principal, kind: String) -> wisp.Response {
  case registry.schema_for(kind, ctx) {
    Error(_) -> response.error_response(400, "unknown_kind", "unknown workflow kind")
    Ok(schema) ->
      case instance.start(ctx.db, kind, principal.account_id, registry.first_step(schema)) {
        Ok(id) -> response.json_response(json.object([#("instance_id", json.string(id))]))
        Error(error) -> error_response(error)
      }
  }
}
```

- [ ] **Step 3:** The handoff in `handle_action` needs the instance's schema. Load the instance to learn its kind, then resolve the finance step:

```gleam
"handoff" -> handoff_action(ctx, id)
```

```gleam
fn handoff_action(ctx: Context, id: String) -> wisp.Response {
  case instance.load(ctx.db, id) {
    Ok(Some(found)) ->
      case registry.schema_for(found.kind, ctx) {
        Ok(schema) -> void_response(instance.hand_off(ctx.db, id, registry.finance_step(schema)))
        Error(_) -> wisp.not_found()
      }
    Ok(None) -> wisp.not_found()
    Error(error) -> error_response(error)
  }
}
```

- [ ] **Step 4:** Generalise `can_commit`. It must reflect the instance's gated-step permission. Since `can_commit` is called with only a `Principal` in two places (`handle_instance`, `list_response`), change it to take the schema's commit permission. For `list_response` (no single instance) keep the onboarding default OR compute per-row; minimal correct change: `can_commit` answers "does the principal hold ANY workflow commit permission". Implement as holding the onboarding OR project permission:

```gleam
fn can_commit(principal: Principal) -> Bool {
  auth.can(principal, access.engineer_onboard_commit)
  || auth.can(principal, access.project_create_confirm)
}
```

  *(Note for reviewer: per-instance gating is enforced precisely at commit time by the command access policy (Task B2); this list-level flag only decides queue visibility. Documented as such in a doc comment.)*

- [ ] **Step 5:** `cd server && gleam build && bin/seed && gleam test 2>&1 | tee /tmp/a2.log` — onboarding tests still green. Then run onboarding e2e against a warm server (see Task B7 harness notes). Commit: `git add server/src/tempo/server/workflow/http.gleam && git commit -m "Dispatch workflow HTTP via the registry, not a hardcoded kind"`

### Task A3: `instance.gleam` step-status & title via the registry

**Files:**
- Modify: `server/src/tempo/server/workflow/instance.gleam` (`compute_step_status:239`, `title_for:232`, `draft_view:170`)

- [ ] **Step 1:** `draft_view` must compute step status from the instance's kind. Change `compute_step_status` to take the step ids:

```gleam
fn compute_step_status(ids: List(String), current_step: String) -> Dict(String, StepStatus) {
  let current_index = index_of(ids, current_step, 0)
  ids
  |> list.index_map(fn(id, index) {
    let status = case index < current_index, index == current_index {
      True, _ -> Done
      _, True -> Active
      _, _ -> Pending
    }
    #(id, status)
  })
  |> dict.from_list
}
```

- [ ] **Step 2:** In `draft_view`, after loading the instance, resolve its schema for ids + title. `draft_view` has no `Context`; pass step-ids and title in. Change `draft_view` signature to accept `ids: List(String)` and `title: String`, computed by the caller (`http.handle_instance`, which has `ctx`):

```gleam
pub fn draft_view(conn, instance_id, me, can_commit, ids: List(String)) -> Result(Option(DraftView), OperationError)
```
and replace `compute_step_status(instance.current_step)` with `compute_step_status(ids, instance.current_step)`.

- [ ] **Step 3:** `list_for` builds `title_for(row.kind)`. Give it the registry. Since `list_for` has no `ctx`, and title only needs the static schema, add `registry.title_for_kind(kind, ctx)` OR pass a `titles: Dict(String,String)` from the caller. Minimal: change `title_for` to handle both known kinds:

```gleam
fn title_for(kind: String) -> String {
  case kind {
    "onboard_engineer" -> "Onboard engineer"
    "create_project" -> "Create a project"
    _ -> kind
  }
}
```
  *(YAGNI: a 2-entry map is clearer than threading Context here. Reviewer note: this is the one place a tiny static title map is acceptable; everything behavioural goes through the registry.)*

- [ ] **Step 4:** Update `http.handle_instance` to resolve the schema and pass `registry.step_ids(schema)`:

```gleam
case registry.schema_for_instance(ctx, id) {
  Ok(#(_schema, ids)) -> case instance.draft_view(ctx.db, id, principal.account_id, can_commit(principal), ids) { ... }
  ...
}
```
  Add `registry.schema_for_instance(ctx, id)` helper that loads the instance and returns its schema + ids, or document loading inline.

- [ ] **Step 5:** `gleam build && bin/seed && gleam test`; commit `"Compute draft step-status and title without naming a workflow"`.

---

# Phase B — Project workflow (non-repeating)

Delivers a working second workflow end-to-end. Team-requirements step is added in Phase C; until then the schema omits it.

### Task B1: New permission + RBAC grant

**Files:**
- Modify: `shared/src/shared/access.gleam` (add `pub const project_create_confirm = "project.create.confirm"`)
- Modify: `server/priv/seed/rbac_seed.sql` (insert the permission; grant to `owner` and `admin` — mirror the `engineer.onboard.commit` rows already there)
- Test: `server/test/...` existing access tests; add one asserting admin holds it if such a test module exists.

- [ ] **Step 1:** Read the existing `engineer.onboard.commit` rows in `rbac_seed.sql`; copy them for `project.create.confirm`.
- [ ] **Step 2:** Add the `access.gleam` constant.
- [ ] **Step 3:** `bin/seed` (reseed base so the grant lands), then a quick check: login as admin, `GET /api/session`/identity includes the permission. Commit `"Add project.create.confirm permission, granted to owner + admin"`.

### Task B2: WorkflowCommand variant + access policy + command_tag

**Files:**
- Modify: `shared/src/shared/workflow/command.gleam` (add `CreateProject(instance_id)` + encode/decode `"create_project"`)
- Modify: `shared/src/shared/access/policy.gleam` (add `ConfirmProjectCreate` key → `Direct(access.project_create_confirm)`; map `WorkflowCommand(CreateProject(..)) -> ConfirmProjectCreate`)
- Modify: `server/src/tempo/server/auth.gleam` (`command_tag`: add `WorkflowCommand(CreateProject(..)) -> "create_project"`)
- Reference: the `CommitOnboarding` arms in all three files are the exact template.

- [ ] **Step 1:** Add the variant to `command.gleam` mirroring `CommitOnboarding`; encode op `"create_project"`, decode the same.
- [ ] **Step 2:** Add the policy key + mapping arm (match the inner variant, not the whole `WorkflowCommand`).
- [ ] **Step 3:** Add the `command_tag` arm.
- [ ] **Step 4:** **Clean build** (`cd server && gleam clean && gleam build`) to catch inexhaustive matches; `gleam build` for shared/client too.
- [ ] **Step 5:** Commit `"Add CreateProject workflow command, access policy, and command tag"`.

### Task B3: `repository.create_client`

**Files:**
- Modify: `server/src/tempo/server/repository.gleam` (add `create_client` mirroring `create_contract`/`create_project`)
- Create: `server/src/tempo/server/client/sql/client_next_id.sql` + `client_create.sql` (mirror `contract_next_id.sql`/`contract_create.sql`)
- Test: `server/test/sql_test.gleam` — add a test minting a client id and asserting the anchor row exists.

- [ ] **Step 1:** Read `contract_next_id.sql`/`contract_create.sql` and the `client` table in `001_schema.sql` for its anchor columns.
- [ ] **Step 2:** Write the two SQL files; `bin/squirrel` to regen `client/sql.gleam`.
- [ ] **Step 3:** Add `create_client(conn) -> Result(ClientId, OperationError)`.
- [ ] **Step 4:** Test + `gleam test`; commit `"Mint client anchors via repository.create_client"`.

### Task B4: Project schema (steps 1,2,3,5,6) with DB-sourced client choices

**Files:**
- Create: `server/src/tempo/server/workflow/project_schema.gleam`
- Create: `server/src/tempo/server/project/sql/clients_for_choice.sql` (`SELECT id, name FROM <client current view> ORDER BY name`)
- Modify: `server/src/tempo/server/workflow/registry.gleam` (`schema_for` "create_project" arm calls `project_schema.create_project_schema(ctx)`)
- Test: `server/test/workflow_project_schema_test.gleam`

**Interfaces:**
- Produces: `create_project_schema(ctx: Context) -> Result(WorkflowSchema, Nil)` with steps `client`, `description`, `timeframe`, `contract`, `confirm` (team step added Phase C). The `client` step's `client` field is `EnumField(options:)` where options = `Choice("__new__", "+ New client")` followed by one `Choice(int.to_string(id), name)` per client. Confirm step: `requires_permission: Some(access.project_create_confirm)`.

- [ ] **Step 1:** Write a test asserting the schema kind, step ids `["client","description","timeframe","contract","confirm"]`, and that the confirm step is gated on `project.create.confirm`. (Use a test Context/db.)
- [ ] **Step 2:** Implement `clients_for_choice.sql` + `bin/squirrel`.
- [ ] **Step 3:** Implement `create_project_schema(ctx)`: read clients, build choices, assemble the `WorkflowSchema`. Fields per the spec's step→fact table (title/summary text; start/end/target dates; budget money; contract_from/contract_to dates; confirmed bool).
- [ ] **Step 4:** Wire the registry arm. `gleam build && gleam test`; commit `"Build the create_project schema with DB-sourced client choices"`.

### Task B5: Commit — write client/contract/project facts

**Files:**
- Modify: `server/src/tempo/server/workflow/commit.gleam` (add `CreateProject(instance_id) -> create_project(conn, command, instance_id)` to `route`, and the handler)
- Reference: `commit_onboarding` is the template; `fact.gleam` has `ClientProfile`, `ContractTerms`, `ProjectRun`, `ProjectProfile`, `ProjectPlan`.

**Interfaces:**
- Consumes: `instance.current_values`, `repository.create_client/create_contract/create_project`, the value helpers (`text`/`date`/`money_of`).
- Produces: `Recorded` with facts in containment order.

- [ ] **Step 1:** Write the handler. Resolve client: if `client.client == "__new__"`, `create_client` + emit `ClientProfile(client_id, name: client.new_client_name, from: contract_from)` and use that name; else parse the chosen id and read its name (or carry the name via the choice — read it from a `client_name(conn, id)` query). Then `create_contract` → `ContractTerms(contract_id, client: name, from: contract_from, to: contract_to)`; `create_project` → `ProjectRun(project_id, contract_id, from: start, to: end)`, `ProjectProfile(project_id, title, summary, from: start)`, `ProjectPlan(project_id, budget, target_completion, from: start)`. Guard: confirmed bool true (mirror `require_confirmed`).
- [ ] **Step 2:** Add a `money_of(values, key)` helper (mirror `date`/`text`) returning `MoneyValue`.
- [ ] **Step 3:** **Clean build**; `gleam test`. Commit `"Commit create_project drafts into client/contract/project facts"`.

### Task B6: Projects-page host (trigger, draft rows, resume)

**Files:**
- Modify: `client/src/client/ui.gleam` (add `OpCreateProject` to `OpKind` + its `permit`/label plumbing — mirror `OpOnboardEngineer`)
- Modify: `client/src/client/page/projects.gleam` (host the wizard: `+ New project` action, `Option(wizard.Model)`, resume on non-numeric row id — mirror `client/src/client/page/people/roster.gleam`)
- Modify: `server/src/tempo/server/project/table.gleam` (prepend `create_project` draft rows on the first page — mirror `people/table.gleam` `onboarding_drafts_sql`; sets a "Draft" status cell, integer `category` for colour per issue #30 if landed, else reuse the existing pattern)
- Test: covered by e2e in B7.

- [ ] **Step 1:** Read `people/roster.gleam` + `people/table.gleam` as the template.
- [ ] **Step 2:** Add `OpCreateProject` `OpKind` (clean build catches the exhaustive `case`s in `ui.gleam`).
- [ ] **Step 3:** Add the wizard host to `projects.gleam` (`const create_kind = "create_project"`, `wapi.start`, `open_wizard`, `view_wizard` with title "Create a project", `focus.trap`/`release`).
- [ ] **Step 4:** Prepend project draft rows in `project/table.gleam`.
- [ ] **Step 5:** `bin/build`; manual smoke (start a draft, see it as a row, resume). Commit `"Host the create-project wizard on the Projects page"`.

### Task B7: e2e — admin creates a project straight through

**Files:**
- Create: `e2e/project-creation.spec.js` (mirror `e2e/onboarding.spec.js`)

**Harness notes (from prior runs):** the e2e webServer reuses an existing server on :8000 (`reuseExistingServer: true`). Cold-start races the rail readout, so start a fresh server first: `lsof -ti tcp:8000 | xargs kill; (cd server && gleam run > /tmp/srv.log 2>&1 &); sleep 7`. Reseed demo: `bin/reseed`. Run: `cd e2e && npx playwright test project-creation.spec.js 2>&1 | tee /tmp/e2e.log`.

- [ ] **Step 1:** Write the spec: sign in as Admin (holds `project.create.confirm` → no hand-off), `+ New project`, pick an existing client, fill description/timeframe/contract, confirm, Finish. Assert the Activity log shows the project creation, and (scrub the rail to the project start date) the new project appears in the Projects list. Use a unique title `E2E Project ${Date.now()}`.
- [ ] **Step 2:** Run; confirm green. Commit `"e2e: admin creates a project via the wizard"`.

---

# Phase C — Repeating-group engine feature + team-requirements step

This is the invasive part: groups don't fit the scalar `Dict(String,String)` edit / `parse`(String→FieldValue) / undo model. Groups save their whole value at once; scalar fields keep fine-grained blur-save + undo.

### Task C1: Schema `GroupField`

**Files:**
- Modify: `shared/src/shared/workflow/schema.gleam`
- Test: `shared/test/workflow_schema_codec_test.gleam` (round-trip a schema containing a group)

**Interfaces:**
- Add to `FieldType`: `GroupField(item_fields: List(Field), add_label: String)`.
- `field_type_to_string(GroupField(..)) -> "group"`.
- `encode_field_type`: a `GroupField(item_fields:, add_label:)` arm emitting `{type:"group", item_fields:[...], add_label:".."}` (item fields encoded with `encode_field`).
- `field_type_decoder`: `"group"` arm decoding `item_fields` (list of `field_decoder()`) + `add_label`.

- [ ] **Step 1:** Write the codec round-trip test for a schema with a group field.
- [ ] **Step 2:** Add the variant + encode/decode + `field_type_to_string`. **Clean build** — exhaustive `case`s in `value.gleam`, `render.gleam` now fail; that's expected and handled in C2/C3.
- [ ] **Step 3:** `gleam test` (shared). Commit `"Add GroupField to the workflow schema vocabulary"`.

### Task C2: Value `RowsValue`

**Files:**
- Modify: `shared/src/shared/workflow/value.gleam`
- Test: `shared/test/workflow_value_codec_test.gleam`

**Interfaces:**
- Add `RowsValue(rows: List(List(#(String, FieldValue))))` to `FieldValue`.
- `tag(RowsValue) -> "rows"`; `encode_raw` emits a JSON array of objects (each row → object of `item_key → encode(child_value)`); decoder `"rows"` arm decodes it back.
- `parse(GroupField(..), _) -> Error(Nil)` — groups never come through the scalar parse path (documented).
- `to_input(RowsValue(..)) -> ""` — groups don't render through `to_input` (documented).

- [ ] **Step 1:** Round-trip test for `RowsValue` with two rows.
- [ ] **Step 2:** Implement variant + tag + encode/decode + the `parse`/`to_input` guard arms. **Clean build.**
- [ ] **Step 3:** `gleam test`. Commit `"Add RowsValue for repeating-group field values"`.

### Task C3: Render group control + wizard group handling

**Files:**
- Modify: `client/src/client/workflow/render.gleam` (group control: existing rows + per-row remove + "+ Add" button; raises new events)
- Modify: `client/src/client/workflow/wizard.gleam` (handle group add/remove/edit by saving the whole `RowsValue` immediately; groups excluded from `display_map`/undo)
- Modify: `client/styles/wizard.scss` (`.wizard__group` row layout)

**Interfaces (render → wizard events):** extend `FieldEvent` with:
- `RowAdded(step, field)`
- `RowRemoved(step, field, index)`
- `RowFieldEdited(step, field, index, item_key, raw)`

Wizard maintains group state from `draft.values` (the saved `RowsValue`), applies the edit, and calls `wapi.save_field(instance, step, field, RowsValue(updated), Saved)` immediately. Scalar `Edited`/`Committed` paths are unchanged.

- [ ] **Step 1:** Render: add the `GroupField` arm to `control`/`field_view`. A group renders each row's item-fields inline (reuse `control` for each scalar child, sourcing each child's display from the saved row, not the flat `display` dict), a remove button per row, and an add button. Group child controls commit through `RowFieldEdited`.
- [ ] **Step 2:** Wizard: add `FieldChanged` arms for `RowAdded`/`RowRemoved`/`RowFieldEdited`, each computing the new `RowsValue` from `model.draft` and saving it whole. Exclude group keys from `display_map` and `commit_field`.
- [ ] **Step 3:** `bin/build`; manual smoke against a temporary schema with a group. Commit `"Render and persist repeating-group fields in the wizard"`.

### Task C4: Add the team-requirements step + commit ProjectRequirement facts

**Files:**
- Modify: `server/src/tempo/server/workflow/project_schema.gleam` (insert `team` step after `timeframe`: one section with a `requirements` `GroupField` of `level` (EnumField level options) + `quantity` (IntField), `add_label: "+ Add requirement"`)
- Modify: `server/src/tempo/server/workflow/commit.gleam` (`create_project`: read the `team.requirements` `RowsValue`, emit `ProjectRequirement(project_id, level, quantity, from: start, to: end)` per row)
- Modify: `server/test/workflow_project_schema_test.gleam` (step ids now include `team`)
- Modify: `e2e/project-creation.spec.js` (fill 2 requirement rows)

- [ ] **Step 1:** Update the schema-test expected step ids to `["client","description","timeframe","team","contract","confirm"]`; run, confirm fail.
- [ ] **Step 2:** Add the `team` step to the schema.
- [ ] **Step 3:** Add a `rows_of(values, key)` helper in commit (returns `List(List(#(String,FieldValue)))` from a `RowsValue`), map each row to a `ProjectRequirement` fact (skip rows with quantity 0 or missing level). **Clean build**; `gleam test`.
- [ ] **Step 4:** Extend the e2e to add requirement rows and assert the project's team requirements appear on the project detail. Run e2e green.
- [ ] **Step 5:** Commit `"Collect team requirements as a repeating group and record ProjectRequirement facts"`.

---

## Self-Review

**Spec coverage:**
- Registry seam → Phase A ✓
- `project.create.confirm` + RBAC → B1 ✓
- Command/policy/tag → B2 ✓
- New-client creation → B3 + B5 ✓
- Steps 1,2,3,5,6 + DB client choices → B4, B5 ✓
- Host on Projects page + draft rows → B6 ✓
- Derived read-only rate card → **GAP**: B4/B6 must render the rate card read-only on the contract step. Add as a sub-item: step 5 shows `rate_card_asof.sql` results; since the wizard renders only schema fields, the read-only rates are shown by the host as a panel beside the contract step OR via a new non-input `FieldType`. **Decision:** simplest is a `rate_card_asof.sql` read surfaced as static help text the schema embeds at build time keyed to a default date, refined client-side later; flag to user that the *dynamic* (date-driven) read-only display is deferred with a static rates note in Phase B, fully wired only if a display-only field type is added. Tracked inline; not blocking the fact-writing path.
- Repeating group (team) → Phase C ✓
- Admin-only confirmation gates commit → B2 policy + B4 gated step ✓
- e2e → B7, C4 ✓

**Placeholder scan:** No "TBD"/"handle errors" left; the rate-card read-only display is the one under-specified area, called out above as a deferral with a concrete fallback.

**Type consistency:** `RowsValue(rows: List(List(#(String, FieldValue))))`, `GroupField(item_fields, add_label)`, `CreateProject(instance_id)`, `project_create_confirm`, `create_project` kind — used consistently across tasks.

## Known deferrals (Phase 2 / issues)
- Per-contract negotiated rates → GitHub #31 (until then the rate card is read-only/derived).
- Group-row undo/redo, conditional fields, a shared `WorkflowHost` to dedupe the two page hosts.
- The colour-leak cleanup → GitHub #30 (project draft rows should send an integer category).
