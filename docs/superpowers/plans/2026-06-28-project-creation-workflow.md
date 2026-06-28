# Project-creation Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second fixed-structure workflow — *Create a project* — reusing the onboarding-era workflow engine, introducing a `kind → schema` registry seam and a repeating-group schema feature.

**Architecture:** The DB tables, SQL, instance lifecycle, wire types, and client wizard are already generic. A new `workflow/registry` module maps `kind → WorkflowSchema` and derives first/finance/title/step-ids/commit-gate from the schema, so `http`/`instance` stop naming a specific workflow. The project schema is built server-side (it needs DB-sourced client choices). Commit routing stays per-kind. Phase B.5 then moves draft persistence from per-field to **per-step** (one JSON document per step), aligning storage with the wizard's step navigation; on that base a repeating group is simply a field whose value is a list of rows nested in the step document (Phase C).

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
- `shared/src/shared/rate/view.gleam` *(or reuse an existing rates read model if one exists)* — `RateRow(level: Int, day_rate: Money)` + codec, for the rate-card panel response.
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
- `client/src/client/workflow/wizard.gleam` — `current_step/1` + `field_value/3` accessors; optional `aside` slot in `view` (Task B6b).
- `client/src/client/workflow/render.gleam` + `wizard.gleam` — group rendering (Phase C).
- `server/src/tempo/server/router` (wherever routes are dispatched) — `GET /api/projects/rate-card?as_of=` (Task B6b).
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
- Modify: `server/priv/seed/rbac_seed.sql` (insert the permission `('project.create.confirm', 'Confirm and create a project')`; grant to `owner` ONLY — there is no `admin` role; the Admin user holds `owner`. "Admin-only confirmation" = owner-only. Mirror the placement of the `engineer.onboard.commit` rows.)
- Test: existing access tests; add one asserting the owner role holds it if such a test module exists.

- [ ] **Step 1:** Read the existing `engineer.onboard.commit` rows in `rbac_seed.sql`; add a `('project.create.confirm', ...)` permission row and one `('owner', 'project.create.confirm')` grant row. Do NOT grant to manager or finance.
- [ ] **Step 2:** Add the `access.gleam` constant `pub const project_create_confirm = "project.create.confirm"`.
- [ ] **Step 3:** `bin/seed` (reseed base so the grant lands), then a quick check: login as the Admin user, identity includes the permission. Commit `"Add project.create.confirm permission, granted to owner"`.

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

### Task B6b: Date-driven read-only rate-card panel beside the contract step

The contract step shows the firm-wide rates the chosen `contract_from` resolves to. The
wizard stays generic; the **host** fetches and renders the panel into a generic `aside` slot.

**Files:**
- Create: `server/src/tempo/server/project/sql/rate_card_asof.sql` (`SELECT level, day_rate::text FROM rate_card WHERE effective_during @> $1::date ORDER BY level`)
- Create/modify: a rates read model `shared/src/shared/rate/view.gleam` (`RateRow(level: Int, day_rate: Money)` + list codec) unless one exists.
- Modify: the server router — add `GET /api/projects/rate-card?as_of=` → `rate_card_asof` rows as JSON.
- Modify: `client/src/client/workflow/wizard.gleam`:
  - `pub fn current_step(model: Model) -> String { model.step }`
  - `pub fn field_value(model: Model, step: String, key: String) -> String` (reuse `saved_value`, merged over `edits`)
  - `pub fn view(model, permissions, aside: fn(String) -> Element(Msg))` — render `aside(model.step)` as a third column / panel inside `wizard__content` (or a new `wizard__aside`). The aside element carries no event handlers, so the host builds it as a generic `Element(a)`.
- Modify: `client/src/client/page/projects.gleam` host:
  - state: `rates: Option(List(RateRow))`, `rates_for: String` (the date the rates answer)
  - in `WizardMsg`, after `wizard.update`, read `wizard.field_value(next, "contract", "contract_from")`; if `wizard.current_step(next) == "contract"` and the date changed from `rates_for`, fire `fetch_rates(date)`.
  - `RatesFetched(date, result)` stores the rows when `date == current contract_from`.
  - `view_wizard` passes `aside: fn(step) { case step { "contract" -> rates_panel(model.rates); _ -> element.none() } }`.

**Interfaces:**
- Consumes: `wizard.current_step/1`, `wizard.field_value/3`, `api.get`.
- Produces: a read-only rates panel; **no** facts, **no** schema field.

- [ ] **Step 1:** `rate_card_asof.sql` + `bin/squirrel`; the read model + codec.
- [ ] **Step 2:** The `GET /api/projects/rate-card?as_of=` route returning the rows.
- [ ] **Step 3:** Wizard accessors + `aside` slot param; update the onboarding host call site (`people/roster.gleam`) to pass `aside: fn(_) { element.none() }`. **Clean build** (the `view` arity change ripples to all callers).
- [ ] **Step 4:** Projects host: rates state + fetch-on-date-change + `rates_panel` + wire the aside.
- [ ] **Step 5:** `bin/build`; manual smoke — on the contract step, changing the date refetches and re-renders the rates. Commit `"Show date-driven read-only rate card beside the contract step"`.

### Task B7: e2e — admin creates a project straight through

**Files:**
- Create: `e2e/project-creation.spec.js` (mirror `e2e/onboarding.spec.js`)

**Harness notes (from prior runs):** the e2e webServer reuses an existing server on :8000 (`reuseExistingServer: true`). Cold-start races the rail readout, so start a fresh server first: `lsof -ti tcp:8000 | xargs kill; (cd server && gleam run > /tmp/srv.log 2>&1 &); sleep 7`. Reseed demo: `bin/reseed`. Run: `cd e2e && npx playwright test project-creation.spec.js 2>&1 | tee /tmp/e2e.log`.

- [ ] **Step 1:** Write the spec: sign in as Admin (holds `project.create.confirm` → no hand-off), `+ New project`, pick an existing client, fill description/timeframe/contract, confirm, Finish. Assert the Activity log shows the project creation, and (scrub the rail to the project start date) the new project appears in the Projects list. Use a unique title `E2E Project ${Date.now()}`.
- [ ] **Step 2:** Run; confirm green. Commit `"e2e: admin creates a project via the wizard"`.

---

# Phase B.5 — Per-step persistence (refactor; both workflows)

**Why:** the per-field storage/edit model is what made repeating groups invasive — a list cannot be a scalar `(step, field)` row, and `parse: String → FieldValue` / a flat `Dict(field, String)` edit buffer cannot express rows. Moving the unit of persistence to the **step** (one JSON document per step, holding all its fields) matches the wizard's step-based navigation and lets a group be a nested array in that document. After this, a group is "a field whose value is a list", not an exception to the storage model.

**No migration burden:** draft data is seed-driven and wipeable, so the table is recreated, not migrated. **Safety net:** onboarding and project-creation e2e (both green today) must both pass after this refactor — that is the gate proving no regression.

### Task P1: Convert persistence from per-field to per-step (atomic refactor, scalars only)

This is a connected change across the persistence stack; it lands as one task, green at the end, with NO new field types (groups come in Phase C). If it proves too large, report BLOCKED and it will be split (server-half behind a temporary wire shim, then client-half).

**Files:**
- Create: `server/priv/migrations/<ts>_workflow_step_per_step.sql` — DROP the existing `workflow_step_value`, recreate WITHOUT `field_key`: columns `(instance_id uuid, step_id text, value jsonb, recorded_during tstzrange)`, PK `(instance_id, step_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE`, FK + `btree_gist` exactly as the original `20260628120000_workflow_onboarding.sql` (read it for exact types/FK/index).
- Modify: `server/src/tempo/server/workflow/sql/step_value_set.sql` — upsert keyed by `(instance_id, step_id)` only; `value` is the whole step document; keep the FOR PORTION OF + `changed` no-op-when-unchanged CTE (now comparing the step document).
- Modify: `server/src/tempo/server/workflow/sql/step_values_current.sql` — `SELECT step_id, value FROM ... WHERE instance_id = $1 AND upper_inf(recorded_during)` (one row per step). `bin/squirrel` to regen.
- Modify: `shared/src/shared/workflow/value.gleam` — add step-document codec helpers: `encode_step(values: Dict(String, FieldValue)) -> Json` (a JSON object `{field_key: encode(FieldValue)}`) and `step_decoder() -> Decoder(Dict(String, FieldValue))` (`decode.dict(decode.string, decoder())`). The `FieldValue` union is UNCHANGED in P1.
- Modify: `shared/src/shared/workflow/view.gleam` — `DraftView.values` changes from `Dict(String, FieldValue)` (flat "step.field") to `Dict(String, Dict(String, FieldValue))` (step_id → field_key → value); update `encode_draft`/`draft decoder` to nest (object of step → step-document).
- Modify: `server/src/tempo/server/workflow/instance.gleam`:
  - replace `save_field(conn, instance, step, field, value: Json)` with `save_step(conn, instance, step, values: Dict(String, FieldValue))` — encode via `value.encode_step` and upsert the step row.
  - `current_values(conn, instance) -> Dict(String, Dict(String, FieldValue))` — parse each step row's `value` via `value.step_decoder()` into a `Dict(field, FieldValue)`, keyed by step_id.
  - `draft_view` carries the nested values.
- Modify: `server/src/tempo/server/workflow/http.gleam` — replace the `"field"` action with a `"values"` action: body `{step: String, values: <object of field → FieldValue>}` decoded with `value.step_decoder()`, calling `instance.save_step`. Keep `"step"` (advance), `"handoff"`, `"cancel"`.
- Modify: `client/src/client/workflow/api.gleam` (`wapi`) — replace `save_field` with `save_step(instance, step, values: Dict(String, FieldValue), msg)` POSTing to `/values`.
- Modify: `client/src/client/workflow/wizard.gleam`:
  - `Model.draft.values` is now nested. `display_map(step)` reads `draft.values[step][field] |> to_input`, merged over the `edits` buffer (unchanged buffer type `Dict(field, String)`).
  - on a scalar `Committed(step, field, raw)`: parse to a `FieldValue`, set it in the step's working `Dict(field, FieldValue)` (saved values for the step, overlaid with the new field), and `wapi.save_step(instance, step, updated_step_values, Saved)` (replaces the per-field save). The no-op-when-unchanged guard stays (compare against the saved value).
  - undo/redo: operate on the step's working values dict (restore a field's prior `FieldValue`) then `save_step`.
- Modify: `server/src/tempo/server/workflow/commit.gleam` — `current_values` is now nested. Add `field_at(values, step, field) -> Option(FieldValue)`; rewrite the helpers `text`/`optional`/`date`/`money_of`/`level_of`/`require_confirmed`/`require_project_confirmed` to take `(values, step, field)` (look up `values[step][field]`) instead of a flat `"step.field"` key. Both `commit_onboarding` and `create_project` call sites update mechanically.
- Re-verify: `server/test/*` (the workflow commit/instance tests reshape to the nested values); BOTH e2e specs.

- [ ] **Step 1:** Migration + the two SQL files + `bin/squirrel`; `bin/migrate` + `bin/seed` clean.
- [ ] **Step 2:** Shared: step-document codec helpers + `DraftView.values` nesting + codec. Clean build shared.
- [ ] **Step 3:** Server: `instance.save_step`/`current_values`, `http` `"values"` action, `commit.gleam` nested helpers. Update server tests to the nested shape. `cd server && gleam build && gleam test`.
- [ ] **Step 4:** Client: `wapi.save_step`, wizard edit/save/undo on the step working dict, nested `display_map`. `cd client && gleam clean && gleam build && cd .. && ./bin/build`.
- [ ] **Step 5:** Warm-server harness (see Task B7): reseed demo, restart server, run BOTH `onboarding.spec.js` and `project-creation.spec.js` — both GREEN.
- [ ] **Step 6:** Commit `"Persist workflow drafts per step (one JSON document per step) instead of per field"`.

---

# Phase C — Repeating groups + team-requirements step

On the per-step base, a group is just a field whose value is a list of rows, stored inside the step's document. No flat-key gymnastics.

### Task C1: Group field type, value, render, and wizard handling

**Files:**
- Modify: `shared/src/shared/workflow/schema.gleam` — add `GroupField(item_fields: List(Field), add_label: String)` to `FieldType`; `field_type_to_string(GroupField(..)) -> "group"`; `encode_field_type` arm `{type:"group", item_fields:[…encode_field…], add_label:"…"}`; `field_type_decoder` `"group"` arm.
- Modify: `shared/src/shared/workflow/value.gleam` — add `RowsValue(List(Dict(String, FieldValue)))` to `FieldValue`; `tag -> "rows"`; `encode_raw` emits a JSON array of row objects (each row encoded via `encode_step`); decoder `"rows"` arm (list of `step_decoder()`); `parse(of: GroupField(..), _) -> Error(Nil)` (a group is never parsed from one input string — documented); `to_input(RowsValue(..)) -> ""` (documented).
- Modify: `client/src/client/workflow/render.gleam` — `GroupField` arm: render each existing row's `item_fields` (reuse the scalar `control` per child, sourcing each child's display from that row's values), a per-row remove button, and an "+ Add" button (`add_label`). Group child interactions raise new `FieldEvent`s: `RowAdded(step, field)`, `RowRemoved(step, field, index)`, `RowFieldEdited(step, field, index, item_key, raw)`.
- Modify: `client/src/client/workflow/wizard.gleam` — handle the three group events by computing the group's new `RowsValue` from the step's working values, then `save_step` the whole step (the per-step model makes this one path — no special save). Groups are excluded from the scalar `display_map`/`commit_field` (the render reads group rows directly from `draft.values[step][field]`).
- Modify: `client/styles/wizard.scss` — `.wizard__group` row layout (rows + remove + add button).
- Test: `shared/test/workflow_value_codec_test.gleam` + `workflow_schema_codec_test.gleam` — round-trip a `GroupField` schema and a `RowsValue` (two rows) inside a step document.

- [ ] **Step 1:** Round-trip tests (schema with a group; a step document whose value contains a `RowsValue` of two rows). Confirm RED.
- [ ] **Step 2:** Add `GroupField` + `RowsValue` + codecs + `parse`/`to_input` guards. **Clean build** (shared, then server, then client — exhaustive `case`s over `FieldType`/`FieldValue` must all gain arms).
- [ ] **Step 3:** Render the group control + wizard event handling (`save_step` on add/remove/row-edit). `./bin/build`.
- [ ] **Step 4:** `gleam test` (shared) GREEN; clean build all packages. Commit `"Add repeating-group fields (GroupField + RowsValue) rendered and persisted per step"`.

### Task C2: Team-requirements step + ProjectRequirement facts + e2e

**Files:**
- Modify: `server/src/tempo/server/workflow/project_schema.gleam` — insert a `team` step (title "Team requirements") AFTER `timeframe`, one section with a single `GroupField` field `requirements` whose `item_fields` are `level` (`EnumField` over the level options — reuse the level-band choices, mirror onboarding's `level_options()`) and `quantity` (`IntField`), `add_label: "+ Add requirement"`.
- Modify: `server/src/tempo/server/workflow/commit.gleam` — in `create_project`, read the `team`/`requirements` `RowsValue` via a `rows_of(values, step, field) -> List(Dict(String, FieldValue))` helper; per row emit `ProjectRequirement(project_id, level, quantity, from: start, to: end)`; skip rows missing a level or with quantity 0.
- Modify: `server/test/workflow_project_schema_test.gleam` — step ids become `["client","description","timeframe","team","contract","confirm"]`.
- Modify: `server/test/workflow_project_commit_test.gleam` — add requirement rows to the draft; assert `ProjectRequirement` facts are emitted with the right level/quantity.
- Modify: `e2e/project-creation.spec.js` — on the new Team step, add two requirement rows (level + quantity) before continuing.

- [ ] **Step 1:** Update the schema-test expected step ids (now includes `team`); confirm RED.
- [ ] **Step 2:** Add the `team` step to the schema.
- [ ] **Step 3:** `rows_of` helper + per-row `ProjectRequirement` emission; add the commit-test assertions. **Clean build**; `gleam test` GREEN.
- [ ] **Step 4:** Extend the e2e to fill two requirement rows; warm-server run BOTH e2e GREEN.
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
- Derived read-only rate card → Task B6b: host-rendered, date-driven panel in a generic wizard `aside` slot. The wizard stays workflow-agnostic; the Projects host fetches `GET /api/projects/rate-card?as_of=<contract_from>` and renders the panel. ✓
- Per-step persistence refactor → Phase B.5 / Task P1 (gated by both e2e) ✓
- Repeating group (team) → Phase C (C1 engine on per-step base, C2 team step) ✓
- Admin-only confirmation gates commit → B2 policy + B4 gated step ✓
- e2e → B7, C2 ✓

**Placeholder scan:** No "TBD"/"handle errors" left. The one place needing a codebase check during execution is whether a rates read model/endpoint already exists to reuse (Task B6b) — noted inline.

**Type consistency:** `RowsValue(List(Dict(String, FieldValue)))`, `GroupField(item_fields, add_label)`, step document = `Dict(String, FieldValue)`, `DraftView.values: Dict(String, Dict(String, FieldValue))`, `CreateProject(instance_id)`, `project_create_confirm`, `create_project` kind — used consistently across tasks.

## Known deferrals (Phase 2 / issues)
- Per-contract negotiated rates → GitHub #31 (until then the rate card is read-only/derived).
- Group-row undo/redo, conditional fields, a shared `WorkflowHost` to dedupe the two page hosts.
- The colour-leak cleanup → GitHub #30 (project draft rows should send an integer category).
