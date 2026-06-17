# Tempo — Financials (Product Requirements)

Invoicing, payroll, and a P&L statement, layered on the temporal staffing model in `PRD.md`. Same
stack and same discipline: facts decoupled from identity, writes through the command bus
(`POST /api/operations`), reads as queries, temporal integrity enforced by the database.

> Companion to `PRD.md` (the core staffing model). See `ARCHITECTURE.md` for the schema and
> `DECISIONS.md` for the financial ADRs (ADR-026…).

---

## 1. Motivation & the temporal points it makes

The staffing model says *who did what, when, at what level and charge rate*. Financials turn that into
money, and money is where temporal correctness bites hardest:

- **Bill at the agreed rate, not the current rate.** An invoice for a project must use the charge
  rates the **contract** agreed, which may be a year stale — *not* whatever the rate card says today.
  This is an as-of query pinned to the contract's signing date, set beside the board's as-of-today
  charge rate.
- **Pay for partial periods correctly.** Payroll must prorate across mid-month hires, terminations,
  and promotions (a promotion splits the month into sub-periods paid at different salaries), while a
  leave period is paid at full salary. This is temporal integration over `employment ∩ month`, split
  by `engineer_role`.
- **A lifecycle decoupled from identity.** An invoice is one durable thing whose *state* (draft →
  issued → paid) is a temporal fact — you can ask "what was the status of invoice 7 on 2026-05-01."

## 2. Scope

- **Invoices** — per project, per billing month; draft → issued → paid; lines computed from the
  contract-agreed rate card.
- **Payroll** — per engineer, per month; salary by level, prorated for part-periods.
- **P&L** — revenue (invoices) vs cost (payroll): this month, year-to-date, and per-employee
  (revenue, cost, profit, margin %, utilization).

Non-goals: tax/GST, multi-currency, payment integration, credit notes, approval workflows beyond the
invoice status lifecycle, accrual vs cash accounting nuance (we recognize revenue on **issue**).

## 3. Data model (new facts; see ARCHITECTURE.md for DDL)

All periods are semantically named (ADR-018); identities are surrogate referents; everything that
varies over time is a narrow fact.

**Cost rates (new):**
- `salary(level, monthly_salary, effective_during)` — what we **pay** an engineer at each level over
  time (the cost analogue of `rate_card`, which is what we **charge**). `WITHOUT OVERLAPS (level,
  effective_during)`; revised via `FOR PORTION OF`, exactly like `rate_card`.

**Invoice (identity + temporal status + computed lines):**
- `invoice(id, project_id, billing_period)` — identity + immutable subject: which project, which
  month (`billing_period` is a `daterange` covering the month). `project_id` is the project entity id.
- `invoice_status(invoice_id, status, status_during)` — the **temporal lifecycle**: `status ∈ {draft,
  issued, paid}`, `WITHOUT OVERLAPS (invoice_id, status_during)`. A transition caps the current status
  and asserts the next (the Change pattern). Current status = the row covering "now"; full history is
  queryable.
- `invoice_line(invoice_id, engineer_id, level, day_rate, days, amount)` — the snapshot lines computed
  when the invoice is drafted: one per engineer who worked the project in the period, at the
  contract-agreed `day_rate`. Plain rows (an issued invoice's lines do not change).

**Payroll (identity + computed lines):**
- `payroll_run(id, period)` — a run for a month (`period` = the month `daterange`).
- `payroll_line(run_id, engineer_id, amount, days)` — the payment instruction per engineer: the
  prorated salary owed for the period.

PERIOD-FK containment is not added across the financial tables (an invoice references a project
*entity*, which—like `contract`—has no single-row identity table to key against); integrity that can
be enforced (status non-overlap, value checks, the salary `WITHOUT OVERLAPS`) is, the rest is upheld
by the computing queries.

## 4. Functional requirements

**Invoicing**
- **FR-F1 — Draft an invoice.** `DraftInvoice(project_id, month)` creates the invoice identity, sets
  status `draft`, and computes its lines: for each engineer allocated to the project during the month,
  `days` = allocation-fraction-weighted working days in the month, `day_rate` = the rate for that
  engineer's **level during the work** taken from `rate_card` **as of the contract's signing date**
  (`lower(term)` of the project's contract), `amount = days × day_rate`. Invoice total = Σ lines.
- **FR-F2 — Agreed-rate billing (the temporal centerpiece).** The `day_rate` used is `rate_card @>
  lower(contract.term)`, *not* `rate_card @> month`. If the rate card has been revised since the
  contract was signed, the invoice still bills the agreed (older) rate. The board's "current charge
  rate" (as-of today) and an invoice's billed rate visibly differ once a `ReviseRateCard` has landed.
- **FR-F3 — Issue / pay.** `IssueInvoice(invoice_id, at)` transitions `draft → issued` at a date;
  `PayInvoice(invoice_id, at)` transitions `issued → paid`. Both are temporal status changes (cap +
  assert) through the command bus; the database rejects an out-of-order transition (no overlap, and a
  transition guard that the current status is the expected predecessor).
- **FR-F4 — Status as-of.** The invoice list shows each invoice's status **as of** the selected date;
  scrubbing the slider back shows an invoice as `draft` before its issue date.

**Payroll**
- **FR-F5 — Run payroll.** `RunPayroll(month)` produces one `payroll_line` per employed engineer:
  `amount` = the engineer's salary prorated over `employment ∩ month`, **split by `engineer_role`** so
  a mid-month promotion is paid partly at each level's salary.
- **FR-F6 — Part-period correctness.** A hire or termination mid-month clips the paid period to the
  employed days; a promotion splits it; **leave is paid in full** (leave does not reduce salary).
  Proration is by day: `amount = Σ over sub-periods of monthly_salary[level] × days_in_subperiod /
  days_in_month`.

**P&L**
- **FR-F7 — P&L statement.** `GET /api/pnl?as_of=<date>` returns, for the month containing the date
  and year-to-date: total **revenue** (Σ lines of invoices that are `issued`/`paid`), total **cost**
  (Σ payroll lines), **profit** (revenue − cost), and **margin %** (profit / revenue).
- **FR-F8 — Per-employee breakdown.** Per engineer: revenue (their invoice lines), cost (their
  payroll line), profit, margin %, and **utilization** = Σ(allocation fraction × employed days) /
  employed days over the period (the share of their capacity that was billable).

## 5. Operations (commands) & reads (queries)

New commands on the existing bus (`POST /api/operations`), each a `Command` variant dispatched to a
financial aggregate and journaled in `event_log`:
`SetSalary(level, monthly_salary, effective)` (FOR PORTION OF, like `ReviseRateCard`),
`DraftInvoice`, `IssueInvoice`, `PayInvoice`, `RunPayroll`.

New read endpoints (queries, not commands): `GET /api/invoices` (+ status as-of), `GET
/api/invoices/:id` (lines), `GET /api/payroll?period=`, `GET /api/pnl?as_of=`.

## 6. UI

A **Financials** view sharing the time slider: an invoices table (project, month, total, status
as-of, with issue/pay actions that post the corresponding command), a payroll run (per-employee
amounts), and the P&L statement (month / YTD totals + the per-employee table). Legibility over polish.

## 7. Testing

Layered, matching the core model:
- **Operation tests** — each financial command applied to a known state, asserting the resulting facts
  + the `event_log` row; the hard cases get explicit tests: an invoice billed at the agreed rate after
  a later `ReviseRateCard` (FR-F2); payroll for a mid-month hire, a mid-month termination, a mid-month
  promotion (blended), and an engineer on leave (full pay) (FR-F5/F6); status transitions and the
  rejection of an out-of-order transition (FR-F3).
- **P&L query tests** — crafted seed → exact month/YTD totals and per-employee revenue/cost/profit/
  margin/utilization (FR-F7/F8).
- **Codec round-trips** for the new `Command` variants and read types.
- **Playwright** — a behaviour-driven beat: draft → issue an invoice and see it move to "issued" and
  appear in the P&L revenue; scrub the slider and see status change as-of.
- The existing suite, the migration oracle, and the board stay green (financials are additive; the
  board query is untouched).

## 8. Honest limitations (stated, not engineered around)

- **Revenue recognized on issue**, in the invoice's billing month — a simplification (no accrual
  schedules, no partial recognition).
- **Agreed rate pinned to `lower(contract.term)`** — a contract "amendment" to new rates would be a
  new contract term version; we do not model an explicit `agreed_rate_at` separate from the term start
  (it can be added later if amendments must decouple from the term).
- **Invoice lines are snapshotted at draft**; re-drafting recomputes, but editing underlying facts
  after issue does not retro-change an issued invoice (correct for billing, but it means an issued
  invoice can diverge from a recomputation — by design).
- **Utilization** is capacity-share (billable fraction of employed days), not hours-based; it does not
  consult the timesheet.
- Financial tables carry no cross-entity PERIOD FKs (the project/contract entity ids have no
  single-row identity table to reference); those invariants live in the computing queries, not the
  schema.
