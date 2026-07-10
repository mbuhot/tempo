//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/invoice/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `invoice_billing_lines` query
/// defined in `./src/tempo/server/invoice/sql/invoice_billing_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceBillingLinesRow {
  InvoiceBillingLinesRow(
    engineer_id: Int,
    engineer: String,
    level: Int,
    day_rate: Option(String),
    days: Float,
    amount: Option(String),
  )
}

/// invoice_billing_lines.sql — the contract-agreed billable lines for a project
/// over a month (FR-F1, FR-F2: the temporal centerpiece). One row per (engineer,
/// level) who worked the project during the month, at the rate the CONTRACT agreed.
///
/// Params: $1 = project_id (entity id), $2 = month start (date), $3 = month end
/// (date, exclusive). The month range is built in SQL as daterange($2, $3, '[)'),
/// so only scalar dates cross the Squirrel boundary.
///
/// The agreed rate (FR-F2, issue #31). The day_rate is the contract's own
/// negotiated `contract_rate[level]` AS OF lower(contract.term) — the contract's
/// signing date — when a row covers it, otherwise the firm-wide `rate_card[level]`
/// at that same date. Either way it is NOT as-of the billing month: if either rate
/// source has been revised since the contract was signed, the invoice still bills
/// the older agreed rate. `agreed_date`/`contract_id` are computed once from the
/// contract active over the month (project ⊂ contract, both overlapping the
/// month) and pinned for every line.
///
/// Both rate sources are LEFT JOINed: a negotiated contract_rate stands alone at
/// the agreed date, and bills correctly even when the firm-wide rate_card has no
/// covering version there. day_rate/amount come back NULL for a level neither
/// source covers, so the caller can name exactly which level is missing its
/// agreed rate rather than the line silently vanishing. The `?` alias suffix
/// forces Squirrel to generate Option(String) rather than inferring non-null off
/// the seed (every seed level has a covering rate_card row).
///
/// Day counting. A daterange's day count is upper - lower (integer days; PG returns
/// e.g. 30 for a June [1st, next-1st) range). The billable sub-period for a line is
/// the THREE-way intersection (the * operator) of the allocation, the engineer_role
/// (level) version, and the month — so a mid-month promotion splits the work into
/// one sub-period per level, each billed at that level's agreed rate. Empty
/// intersections (a role version that does not actually overlap the allocation
/// within the month) are dropped via NOT isempty.
///
/// days   = Σ over sub-periods of  fraction × (upper - lower)
/// amount = Σ over sub-periods of  fraction × (upper - lower) × day_rate
///
/// Aggregated per (engineer, level): a single allocation under one level yields one
/// row; a promotion mid-month yields two rows (one per level) for that engineer.
///
/// Assumptions:
/// * Exactly one contract is active over the month for the project (project ⊂
/// contract by construction); ORDER BY the contract's own signing date then
/// LIMIT 1 pins the agreed date deterministically if the schema ever admits
/// more than one covering row.
/// * Leave does NOT reduce billing (billing is allocation-fraction-weighted
/// working days; leave is a payroll concern, paid in full — FR-F6).
/// * Calendar days, not business days: "working days in the month" is the day
/// width of the intersection, matching the day-count convention used elsewhere.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_billing_lines(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(InvoiceBillingLinesRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    use day_rate <- decode.field(3, decode.optional(decode.string))
    use days <- decode.field(4, pog.numeric_decoder())
    use amount <- decode.field(5, decode.optional(decode.string))
    decode.success(InvoiceBillingLinesRow(
      engineer_id:,
      engineer:,
      level:,
      day_rate:,
      days:,
      amount:,
    ))
  }

  "-- invoice_billing_lines.sql — the contract-agreed billable lines for a project
-- over a month (FR-F1, FR-F2: the temporal centerpiece). One row per (engineer,
-- level) who worked the project during the month, at the rate the CONTRACT agreed.
--
-- Params: $1 = project_id (entity id), $2 = month start (date), $3 = month end
-- (date, exclusive). The month range is built in SQL as daterange($2, $3, '[)'),
-- so only scalar dates cross the Squirrel boundary.
--
-- The agreed rate (FR-F2, issue #31). The day_rate is the contract's own
-- negotiated `contract_rate[level]` AS OF lower(contract.term) — the contract's
-- signing date — when a row covers it, otherwise the firm-wide `rate_card[level]`
-- at that same date. Either way it is NOT as-of the billing month: if either rate
-- source has been revised since the contract was signed, the invoice still bills
-- the older agreed rate. `agreed_date`/`contract_id` are computed once from the
-- contract active over the month (project ⊂ contract, both overlapping the
-- month) and pinned for every line.
--
-- Both rate sources are LEFT JOINed: a negotiated contract_rate stands alone at
-- the agreed date, and bills correctly even when the firm-wide rate_card has no
-- covering version there. day_rate/amount come back NULL for a level neither
-- source covers, so the caller can name exactly which level is missing its
-- agreed rate rather than the line silently vanishing. The `?` alias suffix
-- forces Squirrel to generate Option(String) rather than inferring non-null off
-- the seed (every seed level has a covering rate_card row).
--
-- Day counting. A daterange's day count is upper - lower (integer days; PG returns
-- e.g. 30 for a June [1st, next-1st) range). The billable sub-period for a line is
-- the THREE-way intersection (the * operator) of the allocation, the engineer_role
-- (level) version, and the month — so a mid-month promotion splits the work into
-- one sub-period per level, each billed at that level's agreed rate. Empty
-- intersections (a role version that does not actually overlap the allocation
-- within the month) are dropped via NOT isempty.
--
--   days   = Σ over sub-periods of  fraction × (upper - lower)
--   amount = Σ over sub-periods of  fraction × (upper - lower) × day_rate
--
-- Aggregated per (engineer, level): a single allocation under one level yields one
-- row; a promotion mid-month yields two rows (one per level) for that engineer.
--
-- Assumptions:
--   * Exactly one contract is active over the month for the project (project ⊂
--     contract by construction); ORDER BY the contract's own signing date then
--     LIMIT 1 pins the agreed date deterministically if the schema ever admits
--     more than one covering row.
--   * Leave does NOT reduce billing (billing is allocation-fraction-weighted
--     working days; leave is a payroll concern, paid in full — FR-F6).
--   * Calendar days, not business days: \"working days in the month\" is the day
--     width of the intersection, matching the day-count convention used elsewhere.
WITH params AS (
  SELECT
    $1::int AS project_id,
    daterange($2::date, $3::date, '[)') AS month
),
agreed AS (
  -- the contract active over the month, its id, and its agreed date = lower(term)
  SELECT lower(contract_terms.term) AS agreed_date,
         project_run.contract_id   AS contract_id
  FROM params
  JOIN project_run    ON project_run.project_id = params.project_id
                     AND project_run.active_during && params.month
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
                     AND contract_terms.term && params.month
  ORDER BY lower(contract_terms.term) ASC
  LIMIT 1
),
sub AS (
  -- each allocation ∩ engineer_role(level) ∩ month sub-period for the project
  SELECT
    allocation.engineer_id,
    engineer_role.level,
    allocation.fraction,
    allocation.allocated_during * engineer_role.held_during * params.month
      AS sub_period
  FROM params
  JOIN allocation    ON allocation.project_id = params.project_id
                    AND allocation.allocated_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                    AND engineer_role.held_during && allocation.allocated_during
                    AND engineer_role.held_during && params.month
)
SELECT
  sub.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  sub.level,
  coalesce(contract_rate.day_rate, rate_card.day_rate)::text AS \"day_rate?\",
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period)))::numeric
    AS days,
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period))
      * coalesce(contract_rate.day_rate, rate_card.day_rate))::text AS \"amount?\"
FROM sub
CROSS JOIN agreed
JOIN engineer_current engineer ON engineer.id = sub.engineer_id
LEFT JOIN rate_card ON rate_card.level = sub.level
                   AND rate_card.effective_during @> agreed.agreed_date
LEFT JOIN contract_rate ON contract_rate.contract_id = agreed.contract_id
                       AND contract_rate.level = sub.level
                       AND contract_rate.effective_during @> agreed.agreed_date
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name, sub.level, rate_card.day_rate,
         contract_rate.day_rate
ORDER BY engineer.name, sub.level;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_create.sql — insert the invoice identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of draft_invoice. The id is reserved up-front from invoice_id_seq
/// (invoice_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The subject/status/lines are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_create.sql — insert the invoice identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of draft_invoice. The id is reserved up-front from invoice_id_seq
-- (invoice_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The subject/status/lines are separate facts recorded alongside.
INSERT INTO invoice (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_header` query
/// defined in `./src/tempo/server/invoice/sql/invoice_header.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceHeaderRow {
  InvoiceHeaderRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: String,
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// invoice_header.sql — one invoice's header for the detail read model
/// (GET /api/invoices/:id). Same projection as invoice_list (project + client
/// name, billing month, status AS OF $2, line total, issue/pay transition dates)
/// for a single invoice.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $2. The `?` alias suffix forces Squirrel to generate
/// Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
///
/// Params: $1 = invoice_id, $2 = as-of date. The status shown is the row covering
/// $2 (FR-F4). Unlike the list, the status JOIN is LEFT so the header still
/// returns for an as-of date with no covering status (status NULL), letting the
/// detail endpoint distinguish "no such invoice" (no row) from "exists but no
/// status as of this date" (a row with NULL status). The caller coalesces a NULL
/// status to "" before mapping to the shared read type.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_header(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(InvoiceHeaderRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, decode.string)
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(InvoiceHeaderRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- invoice_header.sql — one invoice's header for the detail read model
-- (GET /api/invoices/:id). Same projection as invoice_list (project + client
-- name, billing month, status AS OF $2, line total, issue/pay transition dates)
-- for a single invoice.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $2. The `?` alias suffix forces Squirrel to generate
-- Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
--
-- Params: $1 = invoice_id, $2 = as-of date. The status shown is the row covering
-- $2 (FR-F4). Unlike the list, the status JOIN is LEFT so the header still
-- returns for an as-of date with no covering status (status NULL), letting the
-- detail endpoint distinguish \"no such invoice\" (no row) from \"exists but no
-- status as of this date\" (a row with NULL status). The caller coalesces a NULL
-- status to \"\" before mapping to the shared read type.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  coalesce((
    SELECT invoice_status.status FROM invoice_status
     WHERE invoice_status.invoice_id = invoice.id
       AND invoice_status.status_during @> $2::date
  ), '') AS status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::text AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $2::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $2::date
     LIMIT 1
  ) AS \"paid_at?\"
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
WHERE invoice.id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_line_insert.sql — one snapshotted billing line. Last param is the
/// audit_id. $1 = invoice_id, $2 = engineer_id, $3 = level, $4 = day_rate (exact
/// decimal text), $5 = days, $6 = amount (exact decimal text).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_line_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Int,
  arg_4: String,
  arg_5: Float,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_line_insert.sql — one snapshotted billing line. Last param is the
-- audit_id. $1 = invoice_id, $2 = engineer_id, $3 = level, $4 = day_rate (exact
-- decimal text), $5 = days, $6 = amount (exact decimal text).
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount, audit_id)
VALUES ($1, $2, $3, $4::text::numeric, $5, $6::text::numeric, $7);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.float(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_lines` query
/// defined in `./src/tempo/server/invoice/sql/invoice_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceLinesRow {
  InvoiceLinesRow(
    engineer: String,
    level: Int,
    day_rate: String,
    days: Float,
    amount: String,
  )
}

/// invoice_lines.sql — an invoice's snapshot lines for the detail read model
/// (GET /api/invoices/:id). The plain rows computed when the invoice was drafted
/// (invoice_line), joined to the engineer name; not a recomputation (PRD §8: an
/// issued invoice's lines do not change).
///
/// Param: $1 = invoice_id. Ordered as the billing query emitted them (engineer,
/// level) so a promotion's two lines stay adjacent and the wire order is
/// deterministic for the client and tests.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_lines(
  db: pog.Connection,
  invoice_line_invoice_id: Int,
) -> Result(pog.Returned(InvoiceLinesRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use day_rate <- decode.field(2, decode.string)
    use days <- decode.field(3, pog.numeric_decoder())
    use amount <- decode.field(4, decode.string)
    decode.success(InvoiceLinesRow(engineer:, level:, day_rate:, days:, amount:))
  }

  "-- invoice_lines.sql — an invoice's snapshot lines for the detail read model
-- (GET /api/invoices/:id). The plain rows computed when the invoice was drafted
-- (invoice_line), joined to the engineer name; not a recomputation (PRD §8: an
-- issued invoice's lines do not change).
--
-- Param: $1 = invoice_id. Ordered as the billing query emitted them (engineer,
-- level) so a promotion's two lines stay adjacent and the wire order is
-- deterministic for the client and tests.
SELECT
  coalesce(engineer.name, '') AS engineer,
  invoice_line.level,
  invoice_line.day_rate::text AS day_rate,
  invoice_line.days::numeric AS days,
  invoice_line.amount::text AS amount
FROM invoice_line
JOIN engineer_current engineer ON engineer.id = invoice_line.engineer_id
WHERE invoice_line.invoice_id = $1
ORDER BY engineer.name, invoice_line.level;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_line_invoice_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_list` query
/// defined in `./src/tempo/server/invoice/sql/invoice_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceListRow {
  InvoiceListRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: String,
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
/// invoice: the durable subject (project + client name, billing month) plus its
/// status AS OF $1, its line total (Σ invoice_line.amount), and the issue/pay
/// transition dates.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $1 (the transition day is after the rail date, or never).
/// The `?` alias suffix forces Squirrel to generate Option(Date) (the seed has no
/// unissued/unpaid invoice, so it would otherwise infer non-null and decode-fail).
/// The as-of status above still resolves independently via @>.
///
/// Param: $1 = as-of date. The status shown is the row covering $1 via `@>`, so
/// scrubbing the slider back shows a `draft` before its issue date (FR-F4). An
/// invoice with no status covering $1 (e.g. as-of before the billing month) is
/// dropped — the status JOIN is not a LEFT JOIN, so only invoices that "exist as
/// of $1" are listed.
///
/// Name resolution. The durable subject (project_id, billing_period) lives in the
/// 1:1 immutable invoice_subject fact, INNER JOINed here. `project_id` is a project
/// ENTITY id whose names are stable across its period-rows in the seed, so a
/// correlated LIMIT-1 subquery picks one name without multiplying the row by every
/// period version. An invoice whose project entity has no project row at all yields
/// NULL names (coalesced to '').
///
/// Total. coalesce(Σ amount, 0) over the snapshot lines — an invoice drafted with
/// no billable lines totals 0 rather than vanishing.
///
/// Keyset pagination (#12). Stable total order is (lower(billing_period), id) —
/// the existing display order plus the unique id tiebreaker. The cursor names the
/// last row already returned: $2 = its billing_from, $3 = its id; a row is on the
/// NEXT page when (billing_from, id) sorts strictly after (row > cursor). The first
/// page passes the sentinel ('0001-01-01', 0), which precedes every real row so
/// nothing is skipped. $4 = limit; the caller fetches limit+1 to detect a further
/// page. lower(billing_period) is bound to a real `b` first so the keyset compares
/// the same expression the ORDER BY sorts on.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_list(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
  arg_3: Int,
  arg_4: Int,
) -> Result(pog.Returned(InvoiceListRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, decode.string)
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(InvoiceListRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
-- invoice: the durable subject (project + client name, billing month) plus its
-- status AS OF $1, its line total (Σ invoice_line.amount), and the issue/pay
-- transition dates.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $1 (the transition day is after the rail date, or never).
-- The `?` alias suffix forces Squirrel to generate Option(Date) (the seed has no
-- unissued/unpaid invoice, so it would otherwise infer non-null and decode-fail).
-- The as-of status above still resolves independently via @>.
--
-- Param: $1 = as-of date. The status shown is the row covering $1 via `@>`, so
-- scrubbing the slider back shows a `draft` before its issue date (FR-F4). An
-- invoice with no status covering $1 (e.g. as-of before the billing month) is
-- dropped — the status JOIN is not a LEFT JOIN, so only invoices that \"exist as
-- of $1\" are listed.
--
-- Name resolution. The durable subject (project_id, billing_period) lives in the
-- 1:1 immutable invoice_subject fact, INNER JOINed here. `project_id` is a project
-- ENTITY id whose names are stable across its period-rows in the seed, so a
-- correlated LIMIT-1 subquery picks one name without multiplying the row by every
-- period version. An invoice whose project entity has no project row at all yields
-- NULL names (coalesced to '').
--
-- Total. coalesce(Σ amount, 0) over the snapshot lines — an invoice drafted with
-- no billable lines totals 0 rather than vanishing.
--
-- Keyset pagination (#12). Stable total order is (lower(billing_period), id) —
-- the existing display order plus the unique id tiebreaker. The cursor names the
-- last row already returned: $2 = its billing_from, $3 = its id; a row is on the
-- NEXT page when (billing_from, id) sorts strictly after (row > cursor). The first
-- page passes the sentinel ('0001-01-01', 0), which precedes every real row so
-- nothing is skipped. $4 = limit; the caller fetches limit+1 to detect a further
-- page. lower(billing_period) is bound to a real `b` first so the keyset compares
-- the same expression the ORDER BY sorts on.
SELECT * FROM (
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  invoice_status.status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::text AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $1::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $1::date
     LIMIT 1
  ) AS \"paid_at?\"
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $1::date
) page
WHERE (page.billing_from, page.id) > ($2::date, $3::int)
ORDER BY page.billing_from, page.id
LIMIT $4::int;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_lock` query
/// defined in `./src/tempo/server/invoice/sql/invoice_lock.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceLockRow {
  InvoiceLockRow(id: Int)
}

/// invoice_lock.sql — take a row lock on the invoice anchor before reading its
/// status, so a status transition's read-modify-write is serialized per invoice.
///
/// Under READ COMMITTED two concurrent transitions can otherwise both read the same
/// pre-status and both commit (issue #2: double-pay). Locking the anchor with
/// `FOR UPDATE` makes the second transaction block until the first commits, then
/// re-read the now-changed status and fail the transition guard. $1 = invoice_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_lock(
  db: pog.Connection,
  id: Int,
) -> Result(pog.Returned(InvoiceLockRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InvoiceLockRow(id:))
  }

  "-- invoice_lock.sql — take a row lock on the invoice anchor before reading its
-- status, so a status transition's read-modify-write is serialized per invoice.
--
-- Under READ COMMITTED two concurrent transitions can otherwise both read the same
-- pre-status and both commit (issue #2: double-pay). Locking the anchor with
-- `FOR UPDATE` makes the second transaction block until the first commits, then
-- re-read the now-changed status and fail the transition guard. $1 = invoice_id.
SELECT id FROM invoice WHERE id = $1 FOR UPDATE;
"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_next_id` query
/// defined in `./src/tempo/server/invoice/sql/invoice_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceNextIdRow {
  InvoiceNextIdRow(id: Int)
}

/// invoice_next_id.sql — reserve the next invoice id from its sequence.
///
/// Called before draft_invoice records any invoice fact: the handler threads this id
/// into the Invoice anchor, its subject, status, and lines in one transaction, so
/// nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(InvoiceNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InvoiceNextIdRow(id:))
  }

  "-- invoice_next_id.sql — reserve the next invoice id from its sequence.
--
-- Called before draft_invoice records any invoice fact: the handler threads this id
-- into the Invoice anchor, its subject, status, and lines in one transaction, so
-- nothing is read back.
SELECT nextval('invoice_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_status_close.sql — cap an invoice's current status at $2.
///
/// Close half of a status transition: `DELETE … FOR PORTION OF status_during
/// FROM $2 TO NULL` removes the [$2, ∞) tail of the open status, capping the
/// spanning row to [row.lower, $2) (Postgres re-inserts the before-leftover).
/// The caller then runs invoice_status_open to start the new status at $2.
/// Keyed to the invoice — the open span is the only one covering $2.
///
/// $1 = invoice_id, $2 = transition day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_close(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_status_close.sql — cap an invoice's current status at $2.
--
-- Close half of a status transition: `DELETE … FOR PORTION OF status_during
-- FROM $2 TO NULL` removes the [$2, ∞) tail of the open status, capping the
-- spanning row to [row.lower, $2) (Postgres re-inserts the before-leftover).
-- The caller then runs invoice_status_open to start the new status at $2.
-- Keyed to the invoice — the open span is the only one covering $2.
--
-- $1 = invoice_id, $2 = transition day (scalar date, cast in SQL).
DELETE FROM invoice_status
   FOR PORTION OF status_during FROM $2::date TO NULL
 WHERE invoice_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_status_current` query
/// defined in `./src/tempo/server/invoice/sql/invoice_status_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceStatusCurrentRow {
  InvoiceStatusCurrentRow(status: String)
}

/// invoice_status_current.sql — the status of an invoice AS OF $2.
///
/// The transition guard: reads the single status row covering $2 via `@>` so the
/// command can validate the from-state before opening a new status. $1 is the
/// invoice_id, $2 the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_current(
  db: pog.Connection,
  invoice_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(InvoiceStatusCurrentRow), pog.QueryError) {
  let decoder = {
    use status <- decode.field(0, decode.string)
    decode.success(InvoiceStatusCurrentRow(status:))
  }

  "-- invoice_status_current.sql — the status of an invoice AS OF $2.
--
-- The transition guard: reads the single status row covering $2 via `@>` so the
-- command can validate the from-state before opening a new status. $1 is the
-- invoice_id, $2 the as-of date.
SELECT status
  FROM invoice_status
 WHERE invoice_id = $1
   AND status_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_status_open.sql — open a status span for an invoice from $3 onward. Last
/// param is the audit_id. $1 = invoice_id, $2 = status, $3 = from.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_status_open.sql — open a status span for an invoice from $3 onward. Last
-- param is the audit_id. $1 = invoice_id, $2 = status, $3 = from.
INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_subject_insert.sql — the immutable 1:1 invoice subject (project + billing
/// month), contained by the project run. Last param is the audit_id. $1 = invoice_id,
/// $2 = project_id, $3 = billing_from, $4 = billing_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_subject_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_subject_insert.sql — the immutable 1:1 invoice subject (project + billing
-- month), contained by the project run. Last param is the audit_id. $1 = invoice_id,
-- $2 = project_id, $3 = billing_from, $4 = billing_to.
INSERT INTO invoice_subject (invoice_id, project_id, billing_period, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
