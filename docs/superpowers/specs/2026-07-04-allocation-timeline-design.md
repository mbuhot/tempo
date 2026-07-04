# Project Allocation Timeline — Design

**Problem.** A client names an ideal start date for their project. We need to see, quickly, whether the required capabilities and levels are staffed at that time — and preview the reassignments (or a start-date shift) that would close the gaps before committing to them.

**Solution.** A new top-level **Schedule** page: every active project as a block of engineer rows over 12 weekly columns, with a gap row per requirement line. A scenario builder holds draft operations; each edit previews them through the real write seam inside a rolled-back transaction, so the timeline shows the hypothetical world with full database validation.

```
Project A            |Jun 15|Jun 22|Jun 29|Jul 06| …
  James (L5)         |  50% |  50% |  50% |   0  |
  Jill  (L4)         |   0  | 100% | 100% | 100% |
  Gap: Backend ×2@L4 |  1.5 |  0.5 |  0.5 |  1.0 |
  Gap: L5 ×1         |  0.5 |  0.5 |  0.5 |  1.0 |
```

## Read model

New server concept `schedule` (`view.gleam` + `sql/` + `http.gleam`), shared types in `shared/schedule/view.gleam`.

- **Window**: 12 week-start dates, beginning the Monday of the global as-of date.
- **Projects**: every project whose `project_run.active_during` overlaps the window.
- **Engineer rows**: engineers with an allocation to the project inside the window. Cell = fraction in force at that week's start (`allocated_during @> week_start`). A week whose start falls in a `leave` range shows a leave marker and contributes 0 to coverage.
- **Requirement lines** (both kinds, quantities sampled per week):
  | Kind | Source | An engineer qualifies when |
  |------|--------|---------------------------|
  | Capability | `project_capability` (capability, target_level, quantity) | capability rollup proficiency ≥ target_level (as-of week start) |
  | Level | `project_requirement` (level, quantity) | `engineer_role.level` ≥ required level (as-of week start) |
- **Gap rule — independent sums**: per line per week, `gap = max(0, quantity − Σ qualifying allocated fractions)`. An engineer may count toward several lines in the same week.
- **Over-allocation flag**: an engineer whose fractions across all projects sum past 1.0 in a week is flagged on every affected cell.

The capability qualifying test reuses the Phase 2 rollup definition: `Σ(skill level × weight) / Σ(weight)` over the capability's mapped skills, unassessed skills counting 0.

**Candidates read**: for one requirement line, every engineer who qualifies under the same rule — including the fully committed — each with level, rollup proficiency, free fraction (`1 − Σ allocations` over the line's window, floored at 0), and a short commitment summary (current projects, leave). Served as `GET /api/schedule/candidates?project=…&line=…&as_of=…`; feeds the inspector's nomination picker. Nominating a committed engineer over-allocates them: the preview surfaces it through the over-allocation flag, and the operator either resolves it with further re-assignments or applies it as accepted overtime.

## Endpoints

| Endpoint | Body | Transaction outcome |
|----------|------|---------------------|
| `GET /api/schedule?as_of=` | — | plain read |
| `POST /api/schedule/preview` | `{as_of, operations: [Command…]}` | rolled back |
| `POST /api/schedule/apply` | same | committed |

Preview and apply share one executor:

1. Authorize every operation up front via the shared `access/policy` (any refusal → 403 naming the operation index; the transaction never opens).
2. Open one `pog.transaction`; `dispatch_in` each operation in order. Each gets its own `event_log` entry, so an applied scenario keeps per-command provenance.
3. Evaluate the timeline read on the same connection.
4. Preview returns the payload through the `Error` channel so pog rolls back (`TransactionRolledBack(Evaluated(timeline))` unwraps to `Ok`); apply returns it through `Ok` so pog commits.

Preview wraps each operation in a savepoint: a rejected operation rolls back to its savepoint and evaluation continues, so one bad draft never hides the rest of the scenario. The response pairs the timeline with per-operation outcomes (ok, or the typed `OperationError` — containment violations, overlaps, the reschedule guards below), and a project-scoped rejection also annotates that project in the timeline payload — the client renders it as a warning pill on the project's header (e.g. "Outside contract term Jun 01 → Dec 31") beside the pinned inspector error. Apply is all-or-nothing: any rejection rolls back the whole batch. Preview burns `event_log` sequence ids on rollback; harmless. The timeline read runs on the in-transaction connection, so it stays serial (the pnl precedent) — the async fan-out helper is for pool reads only.

## New command: RescheduleProject

`EngagementCommand.RescheduleProject(project_id, valid_from, valid_to)` → fact `ProjectRescheduled`. Semantics: move the whole plan in time by `delta = new_from − old_from`.

Write sequence (PERIOD FKs are immediate, so children move via delete + re-insert):

1. Guards: exactly one `project_run` row for the project (else typed error); zero `timesheet` rows for the project (else typed error — logged time pins a schedule).
2. Delete the project's `allocation`, `project_requirement`, `project_capability` rows, capturing them with `RETURNING`.
3. Delete + re-insert the `project_run` at the new window.
4. Re-insert the captured children shifted by `delta`, clamped to the new window; a child whose shifted range collapses to empty is dropped.

A run landing outside its contract term rejects via the existing `run_within_contract` containment, surfacing as feedback in the preview. Engineer double-booking at the new dates is deliberately unconstrained — it shows up as the over-allocation flag, which is the signal the scrub exists to reveal.

Wiring follows the standard exhaustive sites: shared `Command`/codec, `CommandKey` + policy requirement, `auth.command_tag`, `command.dispatch_in` route, `fact.Fact`, `repository.write`. Clean-build after the union changes.

## Client

- New route `/schedule`, sidebar entry, page module `client/src/client/page/schedule.gleam` with the frozen MVU interface; `refetch` takes the shell's global as-of date. UI reference: `docs/prototypes/2026-07-05-allocation-timeline.html`.
- The timeline grid is read-only; edits flow through the aside **inspector**. Selecting a project block focuses it: run-window date controls (a change drafts `RescheduleProject`), a **Team** list with one seat row per required engineer (a level requirement of quantity N expands to ⌈N⌉ seats, the last carrying any fractional demand; each seat shows the engineer filling it and their fraction, and all unfilled demand — a wholly open seat or a partially filled seat's remainder — renders as an open slot with its required fraction and a **Nominate** picker backed by the candidates read; picking a candidate drafts an allocation assign, with a companion re-fraction draft on the candidate's other projects when needed), and a **Capabilities** chart (one bar per required capability: team proficiency against a target-level tick).
- Scenario = the draft operations those controls produce, held in page state and permission-gated per op via `shared/access/policy`. The scenario chrome is a single top-bar **Preview** toggle plus an **Apply changes** button; the timeline and inspector re-render with the previewed outcome, drafted seats and dates carry an accent mark, and a preview error pins to the inspector control that produced it.
- Empty scenario → `GET /api/schedule`. Non-empty → debounced `POST /preview` on every edit (token/timer debounce, the rail-scrub pattern). **Apply changes** posts the list to `/apply` and clears the scenario.
- Gap cells > 0 and over-allocation flags are visually highlighted. A requirement line renders a gap row only when it has a positive gap in some week of the window; covered state lives in the inspector's requirement card, and header chips flag gaps only.
- Scenarios live in page state only; navigation or refresh discards them.

## Permissions

- Timeline read: gated like the existing board/roster reads.
- Preview and apply authorize per-operation with the existing policy — previewing a change requires the same permission as making it.

## Seed & testing

- Extend the base seed with one deterministic gap: a project carrying a capability requirement no allocated engineer covers, and a level requirement partially covered (base-seed "now" is 2026-06-15).
- gleeunit (base seed): timeline shape and week bucketing; gap arithmetic for both line kinds; leave zeroing a cell; over-allocation flag; preview leaves the database unchanged (preview, then plain read, assert identical); reschedule cascade (run + children shifted, clamp, drop-empty); reschedule guards (multiple runs, logged time); contract-term containment rejection surfacing the op index; per-op authorization refusal.
- e2e (demo seed): open Schedule → gap visible → add draft reallocation → preview closes the gap → Apply → gap stays closed on plain reload.

## Out of scope (v1)

- Saved/shared scenarios (page state only).
- Exclusive assignment coverage (independent sums may overstate when one engineer is the sole qualifier for two lines — revisit if it misleads in practice).
- Zoom levels (fixed 12 weekly columns).
- What-if creation of a brand-new project (the project-creation workflow already covers real creation; scrub its dates afterwards).
