# Project-creation workflow — design

**Goal:** Add a second fixed-structure workflow — *Create a project* — to test how well
the onboarding-era workflow seams generalise, and extend the schema engine with the two
constructs a richer flow needs (repeating groups, server-populated choices).

## Why this workflow

It deliberately stresses the engine where onboarding never did:

| Step | New demand on the engine |
|---|---|
| Client: choose existing **or** enter new | Choices populated from the DB (not static); commit branches on picked-vs-new |
| Team requirements: N engineers at levels | **Repeating group** — variable-length rows |
| Admin-only confirmation | A *different* gated permission than onboarding's |

## Seam findings (onboarding → today)

**Reused unchanged — well factored:**
- `workflow_instance` / `workflow_step_value` tables + all SQL (already keyed by `kind`)
- `instance.gleam` lifecycle (start / save_field / complete_step / hand_off / cancel / commit / load / current_values / list_for)
- shared wire types (`schema`, `value`, `view`)
- client `wizard.gleam` + `render.gleam` (render any schema)

**Onboard-hardcoded — the coupling to remove:**
- `http.handle_schema` / `start_response` hardcode `flow.onboard_schema()`, `flow.kind`, `flow.first_step`
- `http.handle_action` handoff hardcodes `flow.finance_step()`
- `http.can_commit` fixes the gate to `engineer_onboard_commit`
- `instance.compute_step_status` / `title_for` hardcode `flow.step_ids()` / `flow.title`
- `wizard.gleam:32` `const kind = "onboard_engineer"`

## The seam: a workflow registry

Introduce `tempo/server/workflow/registry` mapping `kind -> WorkflowSchema`:

```
pub fn schema_for(kind: String, ctx: Context) -> Result(WorkflowSchema, Nil)
```

It takes `Context` because the project schema's client choices come from the DB.
Everything else derives generically from the returned schema:

- `first_step` = first step's id
- `step_ids` = the steps' ids in order
- `finance_step` / gated step = the first step with `requires_permission: Some(_)`
- `title` = `schema.title`
- the **commit gate** = that gated step's `requires_permission` (replaces the hardcoded
  `engineer_onboard_commit`; now `can_commit` works for any workflow)

After this, `http.gleam` and `instance.gleam` mention no specific workflow. `commit.route`
stays per-kind — commit logic is legitimately domain-specific, not duplication.

## Engine feature 1 — repeating groups

A step section may hold a repeating group: a labelled sub-form (a list of fields) that the
user adds/removes rows of.

- **Schema** (`shared/workflow/schema`): add `RepeatingField(key, label, item_fields: List(Field), add_label: String)` as a `FieldType`, or a `Group` field. One group = one `field_key`.
- **Value** (`shared/workflow/value`): add `ListValue(List(List(#(String, FieldValue))))` —
  the group's value is an ordered list of rows, each row a list of `(item_key, FieldValue)`.
  Stored as one JSON array under the group's `(step, field_key)` in `workflow_step_value`
  (no schema change to the table).
- **Client** (`render` + `wizard`): render existing rows + an "+ Add" control + per-row
  remove. The wizard's flat `edits: Dict(String,String)` and per-field undo/redo do not
  model list edits — a group row-edit/add/remove saves the **whole group value** at once
  (a coarser autosave granularity for groups; scalar fields keep their fine-grained
  blur-save + undo). Undo/redo applies to scalar fields only in Phase 1; group edits are
  immediate saves.

## Engine feature 2 — server-populated choices

`EnumField(options)` already carries `List(Choice)`. Onboarding builds them statically
(`level_options()`). The project schema builds the client picker's choices from a DB read,
which is why `schema_for` takes `Context`. A sentinel choice `("__new__", "+ New client")`
plus a `new_client_name` text field models "choose existing **or** enter new" without
schema branching.

## Steps and fact mapping

| # | Step | Fields | Facts on commit |
|---|---|---|---|
| 1 | Client | `client` (enum: existing + "+ New client"), `new_client_name` (text) | If new: `create_client` + `ClientProfile`. Resolve to a client id/name. |
| 2 | Description | `title` (text), `summary` (text) | `ProjectProfile(project_id, title, summary, from)` |
| 3 | Timeframe & budget | `start` (date), `end` (date), `budget` (money), `target_completion` (date) | `ProjectPlan(project_id, budget, target_completion, from)`; dates feed contract/run |
| 4 | Team requirements | repeating group: `level` (enum), `quantity` (int) | `ProjectRequirement(project_id, level, quantity, from, to)` per row |
| 5 | Contract & rate card | `contract_from` (date), `contract_to` (date), repeating rate-card group: `level` (enum), `day_rate` (money) | `ContractTerms(contract_id, client, from, to)`, `ProjectRun(project_id, contract_id, from, to)`, `RateCard(level, day_rate, contract_from, None)` per row |
| 6 | Confirmation | `confirmed` (bool) — gated `project.create.confirm` | gates the commit |

Commit order honours containment: create client (if new) → `ClientProfile`; create contract
→ `ContractTerms`; create project → `ProjectRun`, `ProjectProfile`, `ProjectPlan`,
`ProjectRequirement`×, `RateCard`×.

**Open question for review:** `RateCard` is a *global* per-level fact, so writing it here
revises firm-wide day rates from the contract start. Acceptable for the exercise; flag if
the rate card should instead be project-scoped (no such fact today) or dropped from the flow.

## Permission

New permission `project.create.confirm` (`shared/access`), granted to `owner` + `admin` in
`rbac_seed.sql`. The confirmation step sets `requires_permission: Some(it)`; the registry's
generalised `can_commit` enforces it. Non-admins fill steps 1–5 and hand off; admins commit
straight through — identical mechanics to onboarding, now driven by the schema rather than a
constant.

## Host

The **Projects** page gains a `+ New project` action (permitted by a new `ui.OpKind`) that
starts a draft and opens the shared `wizard` in a `ui.dialog`. In-progress project drafts
appear as rows in the Projects table (id = instance uuid); a row click resumes the wizard.
Mirrors onboarding on People — `roster.gleam` and `people/table.gleam` are the templates,
and the duplication between the two hosts is itself a finding (a `WorkflowHost` helper could
fold it, deferred).

## Out of scope (Phase 2)
- Undo/redo for repeating-group rows
- True conditional/branching fields
- A shared `WorkflowHost` component to dedupe the two page hosts
- Project-scoped rate cards
