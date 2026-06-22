# Project Capacity Requirements + Requirement-Based Forecasting

**Status:** Approved (design). Implementation to follow; an ADR will be added to
`docs/DECISIONS.md` during the build.

## Problem

Revenue can only be derived from **allocations** (supply — a specific engineer
assigned to a project). So a project that is *planned* but not yet staffed — or that
will need new hires — forecasts **nothing**, even though its revenue is knowable from
what the client has engaged it to deliver. We want to forecast a forward P&L from
**demand**: a project's capacity requirements over time, independent of who (if
anyone) is allocated yet.

## Concepts

- **Capacity requirement** (NEW — demand): a project needs `quantity` FTE at a given
  `level` over a period (e.g. *2× L3 + 1× L4 + 0.5× L5*, Aug 2026 – Jan 2027).
  Independent of which engineers fill it; the roles may need to be hired.
- **Allocation** (existing — supply): a specific engineer on a project at a fraction
  over a period.
- **Forecast**: forward revenue / cost / profit / margin per month from **committed
  demand**. Per project per month, the demand is the project's **requirements if it
  has any covering that month, otherwise its current allocations** (decision (b)) —
  never both, so no double-count.

## Data model

New table (add to `server/priv/migrations/001_schema.sql`; the dev DB reseeds from
scratch via `bin/reseed`):

```sql
CREATE TABLE project_requirement (
  project_id      int  NOT NULL REFERENCES project(id),
  level           int  NOT NULL CONSTRAINT project_requirement_level_check CHECK (level BETWEEN 1 AND 7),
  quantity        numeric(4,2) NOT NULL CONSTRAINT project_requirement_quantity_check CHECK (quantity > 0),
  required_during daterange NOT NULL,
  audit_id        bigint,
  CONSTRAINT project_requirement_no_overlap
    PRIMARY KEY (project_id, level, required_during WITHOUT OVERLAPS),
  CONSTRAINT requirement_within_project
    FOREIGN KEY (project_id, PERIOD required_during)
    REFERENCES project_run (project_id, PERIOD active_during)
);
```

`quantity` is fractional FTE (`2.00`, `1.00`, `0.50`). One line per `(project, level)`
over non-overlapping periods; the PERIOD-FK contains the demand within the project's
run — mirrors how `allocation` is contained, so a requirement can only exist where the
project actually runs.

## Operation

`SetProjectRequirement(project_id, level, quantity, valid_from, valid_to)` — a
FOR-PORTION-OF write on `(project_id, level)`, following the existing **ReviseRateCard**
pattern end-to-end: shared `Command` variant + codecs → `command.dispatch` → a
`project_requirement` operation module → records a `ProjectRequirement` fact →
`repository` → a `sql/project_requirement_*.sql` FOR-PORTION-OF write. Validation:
`quantity > 0` and `level ∈ 1..7` (CHECKs → `InvalidValue` 422); the period must fall
within the project's run (the PERIOD-FK → `ContainmentViolated` 409). **v1 has no
explicit remove** — shrink the period to retire a need.

## Forecast query & endpoint

`GET /api/forecast?as_of=` → `Forecast(months: [ForecastMonth{month, revenue, cost,
profit, margin}])`.

- **Window:** from the first of the as-of month to the **cliff** =
  `max(upper(required_during) over all requirements, upper(allocated_during) over all
  allocations)`. Bucket by calendar month (`generate_series`).
- **Effective demand** per `(project, month)`: if the project has **any** requirement
  covering the month → its requirement lines `(level, quantity)`; **else** its
  allocations mapped to `(level, fraction)` via `engineer_role`. (decision (b))
- **revenue(month)** = `Σ demand.quantity × rate_card[level].day_rate × days` over each
  `demand ∩ rate_card-version ∩ month` sub-period (same rate/version splitting as the
  capacity-based `pnl_rows.rev` CTE).
- **cost(month)** = `Σ demand.quantity × monthly_salary[level] × days/days-in-month`
  over each `demand ∩ salary-version ∩ month` sub-period — the expected cost to fulfil,
  including roles that would be hired.
- **profit** = revenue − cost; **margin** = profit / revenue (0 when revenue is 0).

This is the demand-side mirror of ADR-043's capacity-based P&L: the P&L recognises work
**performed** (allocations), the forecast projects work **committed** (requirements, or
allocations as the implicit plan).

## Shared types / codecs

- `ProjectRequirement(project_id, level, quantity, valid_from, valid_to)` — for the
  project detail.
- `Forecast(months)` + `ForecastMonth(month, revenue, cost, profit, margin)` + codecs.
- `ProjectDetail` gains `requirements: List(ProjectRequirement)`.

## UI

- **Project detail** — a **"Capacity requirements"** panel: each line as a level chip
  (`ui.chip`) + quantity (`×N`) + period; empty-state when none. A **"Set requirement"**
  contextual op (canonical `ui.modal`): a level `<select>` (1–7), a quantity number, and
  valid-from/to dates. Follows the page's existing op pattern.
- **Finance "Forecast" tab** — a new tab beside Invoices / Payroll / P&L. A table
  **Month | Revenue | Cost | Profit | Margin** from the as-of month to the cliff, plus a
  total/summary row; recomputes from the rail (`fetch_forecast(as_of)`). Reuses the
  finance table/stat idioms; token-only CSS.

## Seed (`server/priv/migrations/002_seed.sql`)

Add a **prospective project**: a client + a `contract_terms` over a forward window + a
`project_run` over that window (e.g. starts 2026-08-01), with requirements **2× L3 +
1× L4 + 0.5× L5** and **no allocations**. Result: it appears in the **Forecast**
(requirement-based) *and* the **Unstaffed-projects board lane** (the hiring signal),
while existing projects forecast via the allocation fallback.

**Collision note:** the `slider-board` unstaffed-lane e2e asserts the lane lists
"Platform Telemetry" (count 1). A second never-staffed project changes the lane's
contents — the implementation **must** reconcile that beat (assert the new project
appears too, or scope the existing assertion so a second card doesn't break it).

## Testing

- **Server:** forecast query — requirements override allocations per project-month;
  cost/profit/margin; the cliff; a requirement-only (unstaffed) project contributes
  revenue with no allocations; rate/salary version splitting.
- **e2e:** set a requirement on the project detail → it lists; the Finance Forecast tab
  shows the prospective project's requirement-based revenue (non-zero despite zero
  allocations) and existing projects via the fallback, with the series ending at the
  cliff. Re-run safe (FOR-PORTION-OF set is idempotent; ensure-then-assert).
- **ADR** added to `docs/DECISIONS.md`: the demand/requirement concept + requirement-
  based forecast (the (b) rule, capacity basis, the cliff).

## Limitations / out of scope

- No explicit requirement removal (shrink the period instead).
- Cost for to-hire roles uses the standard `salary[level]` (no hiring ramp/recruiting
  cost).
- Sales pipeline for *un-contracted* prospects is out of scope — a requirement attaches
  to a project that runs under a contract.
