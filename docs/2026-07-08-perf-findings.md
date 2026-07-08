# Perf gate findings — scaled dataset + EXPLAIN ANALYZE

**Date:** 2026-07-08
**Status:** Done
**Issue:** #20

## Summary

A deterministic scaled dataset (`bin/seed-scale`, `server/priv/seed/scale_seed.sql`)
and an `EXPLAIN (ANALYZE, FORMAT JSON)` perf gate (`bin/perf`) now answer the issue's
three questions with real measured numbers. The board and pnl fan-outs earn their
keep; the deferred candidates (client detail, roster, settings) are fast enough
sequential; `pnl_rows` (YTD window) and `forecast` are the clear single-query
hotspots and the strongest #13 projection-table candidates.

## Dataset volumes

500 engineers, 150 clients/contracts, 200 projects, staggered employment/contract
starts, rolling allocations re-shuffled every 4 months, annual/sick leave, 30 monthly
payroll runs, and one invoice per (project, month) with any allocation over
2025-01..2026-06:

| Table | Rows |
|---|---:|
| engineer | 500 |
| employment | 500 |
| engineer_role | 895 |
| client | 150 |
| contract | 150 |
| project | 200 |
| project_requirement | 801 |
| allocation | 19,497 |
| leave | 1,976 |
| payroll_run / payroll_period | 30 / 30 |
| payroll_line / payroll_line_segment | 9,506 / 9,756 |
| invoice / invoice_subject | 3,600 / 3,600 |
| invoice_status | 7,200 |
| invoice_line | 55,680 |
| event_log | 45 |

`bin/seed-scale` wall time: ~5.2s (well under the ~60s tuning budget). Allocation
volume sits above the issue's "≈12-15k" guide (6 concurrent slots per 4-month period)
so the downstream `invoice_line` table is large enough for the planted-regression
check below to produce a measurable result.

## Question 1 — fan-outs confirmed or reverted?

Sum of a fanned endpoint's queries vs. its slowest query (the max) is the saving a
concurrent fan-out buys over running them one after another.

| Endpoint | Queries | Sum (ms) | Max (ms) | Saving (ms) | Verdict |
|---|---|---:|---:|---:|---|
| Board | board_engaged, board_unassigned, board_leave, board_unstaffed, leave_balances | 48.44 | 24.81 | 23.63 | **Keep.** A live-scrubbing UI ticks on every rail drag; halving a ~48ms tick to ~25ms is felt. |
| Engineer detail | engineer_employment_asof, engineer_allocations, leave_history, leave_balance | 1.86 | 1.67 | 0.19 | **Keep, low stakes.** Sub-millisecond saving — harmless to fan out, would not be missed if reverted. |
| Project detail | project_team, project_requirements, project_invoices | 2.84 | 1.40 | 1.44 | **Keep, low stakes.** Same shape as engineer detail — a small, free win. |
| P&L (month + YTD) | pnl_rows × 2 windows | 3,286.09 | 2,079.48 | 1,206.61 | **Keep, decisively.** Sequential would cost the YTD query's time *twice*; the fan-out is the difference between a ~2.1s and a ~3.3s page. |

## Question 2 — deferred fan-out candidates?

| Endpoint | Queries | Sum (ms) | Max (ms) | Saving (ms) | Verdict |
|---|---|---:|---:|---:|---|
| Client detail | client_contracts, client_projects | 0.13 | 0.11 | 0.02 | Sequential is fine. |
| Roster | roster_engineers, roster_projects, roster_clients | 0.71 | 0.40 | 0.30 | Sequential is fine. |
| Settings | rate_card_list, salary_list, leave_policy_list | 0.04 | 0.01 | 0.02 | Sequential is fine. |

Every deferred candidate's saving is sub-millisecond — a fan-out would spend more on
process/task overhead than it recovers. None need it.

## Question 3 — single-query hotspots (#13 projection-table candidates)

Two queries dominate their endpoint regardless of fan-out, both well over 100x every
other measured query:

| Query | Measured (ms) | Share of its endpoint |
|---|---:|---|
| `pnl_rows` (YTD window) | 2,079 | 63% of the P&L endpoint's 3,286ms sum |
| `forecast` | 306 | 100% (no fan-out partner) |

**`pnl_rows` (YTD).** `EXPLAIN ANALYZE` shows the planner inlines the `rev` and
`util` CTEs into a correlated nested loop, so each one runs once **per employed
engineer** (395 loops):

| Plan node | Actual time × loops | Share of total |
|---|---:|---|
| `rev` CTE Aggregate (allocation × engineer_role × rate_card) | 2.996ms × 395 ≈ 1,183ms | 56% |
| `util` CTE Aggregate (allocation × employment) | 2.218ms × 395 ≈ 876ms | 42% |

Together, ~98% of the YTD query's 2,105ms. This is the textbook #13 case: a
`pnl_engineer_month` projection, maintained incrementally as allocation/role/rate-card
facts change, would turn this per-engineer correlated join into a single indexed
lookup per window.

**`forecast`.** The `allocation_demand` fallback branch (projects with no
`project_requirement` covering the month) dominates:

| Plan node | Actual time | Share of total |
|---|---:|---|
| `allocation_demand` nested loop (engineer_role × allocation × NOT EXISTS project_requirement, 69,744 intermediate rows) | 263ms | 85% |
| `demand` CTE re-scanned once for revenue, once for cost | included above (2×) | — |

The `demand` CTE is inlined and evaluated twice (once per downstream consumer), so the
263ms anti-join effectively runs twice. A materialized `demand` CTE (or splitting
`forecast` into two single-purpose queries) is a cheaper first step than a full
projection table here.

## Planted-regression check

**As specified (`allocation_allocated_during_gist`).** Dropping the exact index named
in the issue produces **no measurable regression** — `bin/perf` stays green (exit 0)
with the index missing.

| Run | Exit code | Note |
|---|---:|---|
| Index dropped | 0 | every ratio within normal run-to-run noise (0.5x-1.3x) |
| Index recreated | 0 | baseline restored |

Root cause: `allocation`'s own primary key is `(engineer_id, project_id,
allocated_during WITHOUT OVERLAPS)`, a GiST index. Unlike a Btree, a GiST index does
not require its leading columns to be constrained — Postgres serves a bare
`allocated_during && ...` predicate straight from the composite PK's index just as
well as from a dedicated single-column one. Confirmed at both this dataset's scale and
a synthetic 50k-row benchmark: same plan, same cost, with or without the dedicated
index. Every other range-GiST index the performance-indexes migration adds
(`employment_employed_during_gist`, `engineer_role_held_during_gist`, ...) is
redundant the same way, for the same reason, at any table size — none of them cover a
genuinely uncovered access path.

**Substitute demonstration (`invoice_line_invoice_id_idx`).** `invoice_line`'s only
other index is a surrogate `id` primary key that doesn't include `invoice_id` — the
one index in this migration that is *not* redundant with a composite PK. Dropping it
forces `project_invoices`' three correlated per-invoice subqueries into a sequential
scan of all 55,680 `invoice_line` rows:

| Run | Exit code | `project_invoices` ratio |
|---|---:|---:|
| Baseline | 0 | 1.0x |
| Index dropped | **1** | **7.68x** (1.33ms → 10.22ms) |
| Index recreated | 0 | 0.71x (normal noise) |

`bin/perf` named `project_invoices` and exited non-zero; recreating the index brought
it straight back to green. This is the mechanism the gate is built to catch — the
literally-named index just happens to be one Postgres already covers another way.

## Re-running this

```sh
export TEMPO_DB_PORT=5435
bin/seed-scale               # once — no-ops if tempo_perf is already scaled
bin/perf                     # measure + gate against the committed baseline
bin/perf --update-baseline   # after an intentional query/index change
```
