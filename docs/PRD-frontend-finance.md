# Tempo — Frontend: Finance (Product Requirements)

The money pages — Invoices, Payroll, and P&L — presented as three tabs, every figure resolved as of the
global date. A page PRD under `PRD-frontend.md` (umbrella); read the cross-cutting requirements there.
The product requirements for the underlying calculations live in `PRD-financials.md`; this PRD is the
client surface for them.

> Sources: `GET /api/invoices?as_of=` (list), `GET /api/invoices/:id` (detail/lines),
> `GET /api/payroll?from=&to=`, `GET /api/pnl?as_of=`. Writes via `POST /api/operations`. No new
> endpoints required.

---

## 1. Purpose

Run the billing lifecycle and read profitability, with temporal correctness visible: an invoice's
status is what it was *as of the date*, payroll prorates the date's month, and P&L bills at the
contract-agreed rate, not today's.

## 2. Functional requirements — Invoices tab

- **FR-FN1 — Invoice list (as-of).** Only invoices that exist as of the date are shown (an invoice
  appears once its draft is recorded on or before the date); each row shows invoice id, project, client,
  billing month, total, and its **status as of the date** (draft / issued / paid). Summary stats:
  outstanding, collected (visible), and count existing.
- **FR-FN2 — Lifecycle actions.** A draft invoice offers "Issue" (`IssueInvoice`); an issued invoice
  offers "Mark paid" (`PayInvoice`); "Draft" (`DraftInvoice`) creates one — umbrella FR-U5. After an
  action, scrubbing back before its date shows the prior status (the status is a temporal fact).
- **FR-FN3 — Invoice detail.** An invoice opens to its computed lines (`InvoiceDetail`): per engineer,
  the level during the work, the contract-agreed day rate, allocation-weighted days, and amount.

## 3. Functional requirements — Payroll tab

- **FR-FN4 — Payroll run (month of the date).** One line per engineer employed in the date's month:
  engineer, level band, prorated days, and amount (salary by level, prorated for part-periods — a
  mid-month promotion blends salaries; `PRD-financials.md`). A run total, and a "Run payroll"
  (`RunPayroll`) action.

## 4. Functional requirements — P&L tab

- **FR-FN5 — P&L (month + per-employee).** Month revenue / cost / profit headline stats, and a
  per-employee table: revenue (their invoice lines), cost (their payroll line), profit, margin %, and
  utilization % (`PnlRow`). Year-to-date totals are available from the `Pnl` read.

## 5. Acceptance

- An invoice issued on date D shows "draft" when scrubbed to D−1 and "issued" at D; paid likewise.
- The Finance invoice status for a given invoice and date matches the project-detail invoice status for
  the same date.
- Payroll for a month spanning a promotion shows the prorated blend, not a single flat salary.
