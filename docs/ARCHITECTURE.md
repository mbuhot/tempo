# Tempo — Architecture

Technical design for the temporal-staffing demo. Product context is in `PRD.md`; rationale for the
choices below is in `DECISIONS.md`.

---

## 1. Stack

| Concern | Tech |
|---|---|
| Database | PostgreSQL 19 (application-time temporal tables) |
| Typed SQL | Squirrel (generates typed Gleam from `.sql` files by introspecting the live DB) |
| DB driver | pog |
| Web server / API | Wisp (Erlang target) |
| Frontend | Lustre SPA (JavaScript target) |
| Contract | a `shared` Gleam module compiled to **both** targets |

## 2. End-to-end type flow

```
PG temporal schema
   │  (Squirrel introspects + codegen)
   ▼
typed query rows (sql.gleam)        ── server only (Erlang)
   │  (map to API types)
   ▼
shared types + JSON codecs          ── BOTH targets
   │  (JSON over HTTP)
   ▼
Lustre model / view                 ── client only (JavaScript)
```

A schema change that breaks a query is caught at **codegen/compile time**; a contract change in
`shared` breaks **both** server and client builds until reconciled.

## 3. Project structure

The repo is a **four-package layout** (ADR-014): three sibling Gleam packages — `server/`, `shared/`,
and `client/` — wired by path dependencies (no symlinks — portable on any clone and in CI), plus the
`e2e/` Playwright (Node) harness. The repo root holds only orchestration: `bin/` task wrappers,
`docker-compose.yml` (the PG19 container), `plan/` (the build plan), `README.md`, and the design and
run docs under `docs/`.

```
bin/                          # thin task wrappers run from the repo root; each cd's
                              #   into the right package: db, migrate, serve, test,
                              #   build, e2e, erd, squirrel, up (one-shot stack),
                              #   seed-invoices (on-demand demo financials seed)
docker-compose.yml            # PG19 (tempo-db) on host port 5434
plan/                         # phased build plan
README.md                     # repo intro (the only doc kept at the root)
docs/                         # design docs: PRD.md, PRD-financials.md,
                              #   PRD-frontend*.md, ARCHITECTURE.md, DECISIONS.md,
                              #   SCHEMA.md; archive/ holds superseded docs

server/                       # package `tempo` — the Wisp server (Erlang target)
  gleam.toml                  #   depends on shared = { path = "../shared" }
  src/
    tempo.gleam               #   server entrypoint (gleam run, Erlang target)
    tempo/
      server/
        web/                  #   web layer (HTTP) — never imports sql
          router.gleam        #     routing + static serving; dispatches to handlers
          board.gleam         #     GET /api/board handler
          timesheet.gleam     #     GET /api/timesheet form handler
          operations.gleam    #     POST /api/operations handler (decode Command → dispatch)
          events.gleam        #     GET /api/events handler (the provenance journal)
          invoices.gleam      #     GET /api/invoices (+/:id) handler
          payroll.gleam       #     GET /api/payroll?from=&to= handler
          pnl.gleam           #     GET /api/pnl?as_of= handler
          roster.gleam        #     GET /api/roster?as_of= handler (console directory)
          request.gleam       #     parse query params into a calendar.Date
          response.gleam      #     json/error response helpers (leaf; shared by router + handlers)
        command.gleam         #   domain — Command dispatch seam: txn + route → record_facts
        operation.gleam       #   domain leaf — Event/OperationError, classify, try/run, date render
        fact.gleam            #   domain leaf — the Fact union: the typed information schema (states over periods)
        repository.gleam      #   domain — persistence seam: next_id + record_facts (the one place a fact's write semantic lives)
        engineer.gleam        #   domain — onboard_engineer (mint anchor + open founding facts) / promote / terminate_employment (cascade)
        engineer_details.gleam #  domain — UpdateContactDetails / UpdateBankingDetails / UpdateEmergencyContact (latest-read facts)
        client_details.gleam  #   domain — UpdateClientProfile (latest-read fact)
        project_details.gleam #   domain — UpdateProjectProfile / UpdateProjectPlan (latest-read facts)
        allocation.gleam      #   domain — assign_to_project / change_allocation_fraction / roll_off
        rate_card.gleam       #   domain — revise_rate_card / adjust_rate_for_portion (FOR PORTION OF)
        engagement.gleam      #   domain — sign_contract / start_project (each mints the anchor + opens its founding fact rows)
        leave.gleam           #   domain — take_leave
        salary.gleam          #   domain — set_salary (FOR PORTION OF, like rate_card)
        invoice.gleam         #   domain — draft_invoice / issue_invoice / pay_invoice
        payroll.gleam         #   domain — run_payroll (prorated lines)
        finance_query.gleam   #   domain — invoices / payroll / pnl reads (shared types, no wisp)
        roster.gleam          #   domain — console directory (employed engineers, active projects, clients)
        event.gleam           #   domain — append (used by repository) + list (journal read)
        board.gleam           #   domain — board.snapshot (no wisp)
        timesheet.gleam       #   domain — form_week, log_timesheet/log_week → EngineerWorkedHours facts (no wisp)
        context.gleam         #   pog connection pool
        sql/                  #   Squirrel .sql sources → generated sql.gleam; incl. the
                              #     *_open/*_close edit-fact writers, the *_current view
                              #     reads (engineer/client/project), and the anchor *_create
        migrate.gleam         #   numbered-migration runner (gleam run -m tempo/migrate)
      seed_financials.gleam   #   on-demand demo financials seed (gleam run -m tempo/seed_financials)
  test/                       #   constraint, operation, as-of, codec, financials, pnl, api, sql
  priv/
    migrations/               #   001_schema.sql (whole schema; each fact has an
                              #     audit_id FK to event_log), 002_seed.sql (the
                              #     deterministic demo seed + its event_log history)
    static/                   #   compiled client bundle (app.js) + index.html + styles/ (copied; gitignored)

shared/                       # package `shared` — BOTH targets, target-agnostic
  gleam.toml                  #   deps: gleam_stdlib, gleam_json only
  src/shared/
    types.gleam               #   domain/API types: BoardRow, BoardSnapshot, Command, Event, …
    codecs.gleam              #   gleam/json encoders + decoders (incl. Command, Event)

client/                       # package `client` — JavaScript target only
  gleam.toml                  #   deps: lustre, rsvp, gleam_json, gleam_time,
                              #     shared = { path = "../shared" }; dev: lustre_dev_tools
                              #   [tools.lustre.build] outdir = "../server/priv/static", no_html
  src/client/
    app.gleam                 #   Lustre model/update/view; the time slider; board + timesheet
                              #     views, the operations console, and the event-log panel
  styles/                     #   plain-CSS source: theme.css (design tokens) + per-area
                              #     component files (base, slider, board, timesheet, console,
                              #     event-log, financials) wired in page order by main.css.
                              #     bin/build copies this to ../server/priv/static/styles
                              #     (a gitignored build artifact, like app.js); ADR-029

e2e/                          # Playwright harness (Node) — drives the real app
  package.json                #   @playwright/test
  playwright.config.js        #   testDir "." → the *.spec.js below
  slider-board.spec.js        #   org board / slider beats
  timesheet.spec.js           #   my-timesheet beats (incl. the negative beat)
  operations.spec.js          #   operations-console beats (promote; a refused operation)
  financials.spec.js          #   financials beats (draft → issue → revenue; scrub back → draft)
```

**Why three Gleam packages (per-package, per-target compilation).** Gleam 1.17 compiles a *whole
package* per target, with **no per-module target exclusion** (`@target`, `internal_modules`, etc. do
not gate the JS compile). A single package therefore cannot build the JS client: `lustre/dev build`
runs `gleam build --target javascript`, which type-checks **every** module in the package for JS —
including the Erlang-only server subtree (`pog`, `wisp`, `mist`, `gleam_otp`, plus the
Squirrel-generated `sql.gleam` with its bare `@external(erlang, …)` calls) — and fails with
"Unsupported target" errors. (This disproved the P0/ADR-005 assumption that import discipline alone
would keep the client JS build clean; see P4-T01 and ADR-014.) Splitting the packages fixes it:

- The **`shared`** package depends only on target-agnostic hex packages (gleam_stdlib, gleam_json),
  so it compiles for **both** Erlang and JS and is the single source of the API contract.
- The **`client`** package (JS) path-depends on `shared` and **never** on the server package, so its
  JS dependency graph contains no Erlang-only code. Built with
  `cd client && gleam run -m lustre/dev build client/app`; the bundle is emitted to
  `../server/priv/static`.
- The **`server`** package (`tempo`) builds for Erlang (`cd server && gleam run`), path-depends on
  `shared`, and never depends on `client`. `sql.gleam` stays Squirrel-generated and untouched.
- The **`e2e`** Playwright harness is target-agnostic Node and drives the running app over HTTP
  (`cd e2e && npx playwright test`), so it depends on no Gleam package at all.

## 4. Data model (anchors + facts)

**`SCHEMA.md` is the authoritative table/relationship map** — it is regenerated from the live database
by `bin/erd` (it reads `pg_catalog`), so the ER diagram there always reflects what the migrations
actually built, including the temporal foreign keys. This section is the *why*; consult `SCHEMA.md`
for the current column-level shape.

Every entity is an **ID-ONLY anchor** — a durable referent with nothing but a primary key — and all of
its attributes live in **edit-grouped fact tables** that reference the anchor's PK. There is no
`updated_at` and no in-place mutation anywhere: a change is a new row (or a `FOR PORTION OF` split).
Each fact is valid over a `daterange` period **named for the predicate it asserts** (ADR-018) rather
than a uniform `valid_at`. A single append-only `event_log` table records system-time provenance
*beside* the facts (§5a, ADR-021). The `PERIOD` foreign keys and `WITHOUT OVERLAPS` / `EXCLUDE`
constraints carry **explicit names** so a violation classifies to a typed domain error (ADR-022).

The anchors are `engineer`, `client`, `contract`, `project`, `invoice`, and `payroll_run` — all
id-only. Their facts split into **two temporal flavours**, and the application chooses the read per
query:

- **Valid-time facts, read AS-OF a date.** The period is named for the world-predicate it asserts —
  `employed_during`, `held_during`, `on_leave_during`, `allocated_during`, `term`, `active_during`,
  `effective_during`, `status_during`, `work_day`, `planned_during` — and a query selects the version
  *in force* on the as-of date with `<period> @> $when::date`. The slider reads the version in force.
  These are the existence/containment facts and the versioned rates: `employment`, `engineer_role`,
  `leave`, `allocation`, `rate_card`, `timesheet`, `salary`, `invoice_status`, plus the renamed
  `contract_terms(contract_id, client_id, term)` and `project_run(project_id, contract_id,
  active_during)` and the new `project_plan(budget, target_completion, planned_during)`.
- **Latest-read facts** (transaction-time character), with the period named **`recorded_during`**. A
  new edit is a new row covering `[effective, NULL)`; the **most-recently-effective** row is current
  truth and the older rows are the history. The current value is exposed through `*_current` views
  (`engineer_current`, `client_current`, `project_current`) — `DISTINCT ON (anchor_id) ORDER BY
  lower(recorded_during) DESC`. These carry the descriptive / contact detail:
  `engineer_contact(name, email, phone, postal_address)`, `engineer_banking`, `engineer_emergency`,
  `client_profile(name)`, and `project_profile(title, summary)`.

A third, degenerate flavour: `invoice_subject(invoice_id, project_id, billing_period)` and
`payroll_period(run_id, period)` are **immutable 1:1 facts** — a subject set once at draft / run, one
row per anchor (keyed by the anchor PK, not a period PK), with no `*_current` view. Reads `INNER JOIN`
the fact directly. `payroll_period` carries the no-overlap `EXCLUDE` that rejects overlapping runs.

`event_log` is the append-only journal, one row per applied command. Every fact table additionally
carries a nullable **`audit_id`** FK to it — the entry of the command that recorded that row-version
(ADR-032). This is a provenance pointer only: the as-of reads never consult `audit_id`, so the model
stays valid-time-only (ADR-021, as amended) — the journal is read FROM (provenance) but does not
constrain the temporal reads.

The whole schema and the deterministic seed are built by two consolidated migrations — `001_schema.sql`
and `002_seed.sql` (ADR-033) — rather than the original incremental chain (see git history for the
01-through-18 evolution: the allocation split, the anchor/fact refactors, the financial layer, and the
id sequences).

### PERIOD-FK containment chain

```
leave  ──┐
         ├─▶ employment
allocation ─┘        └─▶ project_run ─▶ contract_terms
engineer_role ─▶ employment
timesheet ─▶ allocation
invoice_subject ─▶ project_run
```

The temporal containment chain is now `contract_terms → project_run → allocation → timesheet`, and
`employment → {engineer_role, leave, allocation}`, with `invoice_subject ⊂ project_run` (migration
`013`/`017`). End an engineer's `employment` and the database blocks any `allocation`/`leave`/`role`
that would dangle past it (PRD FR-5). The latest-read facts (`engineer_contact`, `client_profile`, …)
are plain (non-PERIOD) FKs to the anchor and are deliberately **not** in this chain — an ex-employee
still has a name and a bank account on file.

### `WITHOUT OVERLAPS` scoping

| table | uniqueness | meaning |
|---|---|---|
| employment, engineer_role, leave | per `engineer_id` | one employment/level/leave at a time |
| rate_card | per `level` | one rate per level at a time |
| contract_terms, project_run | per `contract_id` / `project_id` | one row per entity per instant |
| allocation | per `(engineer_id, project_id)` | concurrent projects allowed; no double-row for the same project |
| timesheet | per `(engineer_id, project_id)` | one entry per project per day |

## 5. Key queries

All valid-time columns are `daterange`; the as-of predicate is `<period> @> $when::date`, where
`<period>` is the table's semantically-named period column (§4). Any read that surfaces an entity
**name** joins the latest-read `*_current` view (`engineer_current`, `client_current`,
`project_current`) instead of the old anchor column, `coalesce`-d so the `String` contract holds
(Squirrel infers view columns nullable) — the projected JSON is byte-identical to the pre-refactor
output. The query files are named `board_engaged.sql` / `board_unassigned.sql` / `board_leave.sql`.

**Org board, as of a date.** The board is **three** as-of queries, one per `Engagement`
variant of the shared `BoardRow`, merged and re-sorted by engineer name in
`board.snapshot` (`server/src/tempo/server/board.gleam`). Every employed engineer is represented
**exactly once** as of any date: allocated (one row per project), unassigned, or on leave.
The split is forced by Squirrel typing — a `LEFT JOIN`ed column comes back as non-null, so
a single `LEFT JOIN` board query cannot represent the employed-but-unallocated row and
500s on those dates; see ADR-015. Each query therefore uses **`INNER JOIN`s only**, so
every selected column is non-null and decodes without `Option` plumbing.

1. `board_engaged` — the **engaged** slice: engineers `INNER JOIN`ed all the way through
   `allocation → project_run → contract_terms` and `engineer_role → rate_card`, so they are
   employed *and* allocated as of the date. The engineer/project/client **names** come from the
   `*_current` views (the anchors are id-only), `coalesce`-d to satisfy the non-null `String`
   contract. One row per (engineer × project). Engineers with a covering `leave` fact are suppressed
   here (`NOT EXISTS`). Charge rate is the two-hop `engineer_role × rate_card` join (ADR-009), exposed
   as a plain `day_rate` value (ADR-013). → `OnProject`.

   ```sql
   SELECT coalesce(engineer.name, '') AS engineer, engineer_role.level,
          coalesce(project.title, '') AS project, coalesce(client.name, '') AS client,
          allocation.fraction, rate_card.day_rate,
          lower(allocation.allocated_during) AS valid_from,
          upper(allocation.allocated_during) AS valid_to
   FROM employment
   JOIN engineer_current engineer ON engineer.id = employment.engineer_id
   JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
   JOIN rate_card      ON rate_card.level = engineer_role.level   AND rate_card.effective_during @> $1::date
   JOIN allocation     ON allocation.engineer_id = engineer.id    AND allocation.allocated_during @> $1::date
   JOIN project_run    ON project_run.project_id = allocation.project_id AND project_run.active_during @> $1::date
   JOIN project_current project ON project.id = project_run.project_id
   JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id AND contract_terms.term @> $1::date
   JOIN client_current client ON client.id = contract_terms.client_id
   WHERE employment.employed_during @> $1::date
     AND NOT EXISTS (SELECT 1 FROM leave
                     WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date)
   ORDER BY engineer.name, project.title;
   ```

2. `board_unassigned` — employed, **not** allocated and **not** on leave as of the
   date. `INNER JOIN engineer_role` keeps `level` non-null (an employed engineer always has
   a role in the seed). Name from `engineer_current`. Returns just `(engineer, level)`. → `Unassigned`.

   ```sql
   SELECT coalesce(engineer.name, '') AS engineer, engineer_role.level
   FROM employment
   JOIN engineer_current engineer ON engineer.id = employment.engineer_id
   JOIN engineer_role ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
   WHERE employment.employed_during @> $1::date
     AND NOT EXISTS (SELECT 1 FROM allocation
                     WHERE allocation.engineer_id = engineer.id AND allocation.allocated_during @> $1::date)
     AND NOT EXISTS (SELECT 1 FROM leave
                     WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date)
   ORDER BY engineer.name;
   ```

3. `board_leave` — exactly the engineers a covering `leave` fact hides from
   `board_engaged`. Leave overrides the engagement: the underlying allocation is deliberately
   not joined. The level is still resolved (for the charge story). Returns
   `(engineer, level, kind, valid_from, valid_to)`. → `OnLeave`.

   ```sql
   SELECT coalesce(engineer.name, '') AS engineer, engineer_role.level, leave.kind,
          lower(leave.on_leave_during) AS valid_from, upper(leave.on_leave_during) AS valid_to
   FROM leave
   JOIN engineer_current engineer ON engineer.id = leave.engineer_id
   LEFT JOIN engineer_role ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
   WHERE leave.on_leave_during @> $1::date
   ORDER BY engineer.name;
   ```

Range columns are decomposed to plain `date`s at the boundary (ADR-011):
`lower(<period>)`/`upper(<period>)` AS `valid_from`/`valid_to`.

**Timesheet form — my allocations as of a day** (only projects I'm on; blank when on leave):

```sql
SELECT al.project_id, coalesce(pc.title, '') AS project, al.fraction,
       COALESCE(ts.hours, 0) AS hours
FROM allocation al
JOIN project_run pr  ON pr.project_id = al.project_id AND pr.active_during @> $2::date
JOIN project_current pc ON pc.id = al.project_id
LEFT JOIN timesheet ts ON ts.engineer_id = al.engineer_id
                      AND ts.project_id  = al.project_id
                      AND ts.work_day @> $2::date
WHERE al.engineer_id = $1 AND al.allocated_during @> $2::date
  AND NOT EXISTS (SELECT 1 FROM leave lv
                  WHERE lv.engineer_id = $1 AND lv.on_leave_during @> $2::date);
```

The implemented timesheet read (`timesheet_week.sql`) is the Mon–Sun week grid — one row per
(project, day), with each day's allocation coverage and any hours logged — built over the same
joins; the single-day shape above is the illustrative core.

**Timesheet write** — the `PERIOD` FK rejects a day not covered by an allocation:

```sql
INSERT INTO timesheet (engineer_id, project_id, work_day, hours)
VALUES ($1, $2, daterange($3::date, ($3::date + 1), '[)'), $4);
```

> **Impl note (upsert):** `ON CONFLICT` does **not** apply to `WITHOUT OVERLAPS` keys (they are
> exclusion-constraint / GiST backed, not plain unique indexes). For re-entry, delete-then-insert
> within a transaction (`DELETE … WHERE work_day @> $3; INSERT …`), or add a supplemental unique
> index for the upsert path. Flag during the planning spike.

## 5a. The write model — domain operations

Every business change is a typed **`Command`** (defined in `shared`, so the client encodes it and the
server decodes the same value), applied through one seam. Reading (§5) is a trivial as-of predicate;
the modeling lives here.

**`command.dispatch(context, actor, command)`** opens one `pog.transaction` and does *only* two
things: **route** the command to its aggregate's `handle` for the **facts it records** (`engineer`,
`engineer_details`, `client_details`, `project_details`, `allocation`, `rate_card`, `engagement`,
`leave`, `timesheet`, `salary`, `invoice`, `payroll` — variants grouped per aggregate by alternative
patterns) for the `fact.Recorded(entry, facts)` it produces, then hand both to
**`repository.record_facts(conn, actor, entry, facts)`**. Facts and journal commit together or not at
all. `dispatch` **returns the persisted journal event** (`List(Event)`, with its minted
id/occurred_at), so the web layer echoes exactly what was written — no fetch-newest round-trip.
`dispatch_in` is the transaction-free core (route + record on an already-open connection) so a test can
drive it inside its own rolled-back transaction.

**Each aggregate's `handle(conn, command)` is a *pure dispatch*** (ADR-027): a `case` that routes each
variant it owns to a **named per-operation function** (`onboard_engineer`, `promote`,
`terminate_employment`; `assign_to_project`, `change_allocation_fraction`, `roll_off`;
`revise_rate_card`, `adjust_rate_for_portion`; `sign_contract`, `start_project`; `take_leave`;
`set_salary`; `log_timesheet`, `log_week`; `draft_invoice`, `issue_invoice`, `pay_invoice`;
`run_payroll`; `update_contact_details`, `update_banking_details`, `update_emergency_contact`,
`update_client_profile`, `update_project_profile`, `update_project_plan`) and
**panics** on any other variant (`panic as "<aggregate>.handle: … (dispatch bug)"`) — an unrouted
command is a routing bug, never a silent `Ok`.

**Each named op returns `Result(fact.Recorded, OperationError)`** (ADR-032) — `Recorded(entry, facts)`,
the command's audit `entry` (the journal row: operation tag, human summary, command re-encoded as
payload) plus the **`facts`** it records, in write order (identity anchors first, then the facts
contained by them). A handler builds no SQL and persists nothing. The five **create-ops**
(`onboard_engineer`, `sign_contract`, `start_project`, `draft_invoice`, `run_payroll`) **reserve the
anchor id up-front** with `repository.next_id` (a `nextval`) and thread it into every fact they emit,
so nothing is read back. The two **compute-ops** (`draft_invoice`, `run_payroll`) still read their
lines on the connection (`invoice_billing_lines`, `payroll_amounts`) and map each row to a line fact;
`issue_invoice`/`pay_invoice` read the current status to guard the transition.

**`repository.record_facts(conn, actor, entry, facts)` is the single persistence seam** — the one place
a fact's write SEMANTIC lives (ADR-032). It appends the `entry` to `event_log` (stamped with the actor;
the DB mints id/occurred_at), then writes each fact in order, passing the appended id as the **`audit_id`**
every fact carries (its FK back to the command that recorded it). It maps each fact to the SQL that
records it, classifies any rejection into a typed `OperationError`, and short-circuits on the first
failure (so the caller's transaction rolls them all back). It returns the one persisted journal `Event`.
Its companion **`next_id(conn, sequence)`** reserves an anchor id (a `nextval`) before its facts are
recorded.

To break the `command` ↔ aggregate import cycle, the journal `Event` type, the `OperationError` type,
the SQLSTATE/constraint `classify` helpers, and the ISO/period date helpers live in a leaf module
**`operation.gleam`** (it imports only `pog`/`json`/`shared`, so it sits below the aggregates). It also
exports two helpers the repository uses so a write reads as a flat sequence: **`try`** chains a write
into the next step (`use _ <- operation.try(sql.…)`, mapping `pog.QueryError → OperationError`), and
**`run`** runs a single terminal write. The fold and the line-mapping use `list.try_map`/`list.map` —
no hand-rolled recursion.

The temporal writes fall into the same four patterns as before — now selected by the **repository**
from each fact's shape, not hand-coded in a handler. PG19's `FOR PORTION OF` produces the before/after
"temporal leftovers" and drops a fully-covered row itself, so there is **no** hand-rolled
cap-and-insert and no empty-period bookkeeping.

**1. Assert** — plain `INSERT`, open-ended where the fact is ongoing
(`employed_during = daterange($start, NULL, '[)')`). The identity anchors
(`Engineer`/`Contract`/`Project`/`Invoice`/`PayrollRun`) and the bounded facts (`EngineerEmployed`,
`EngineerAllocatedToProject` with `Some(to)`, `EngineerOnLeave`, `ContractTerms`, `ProjectRun`,
`InvoiceSubject`, `InvoiceLine`, `PayrollPeriod`, `PayrollLine`) insert directly. A create-op emits the
anchor then the founding facts contained by it, each contained in the last by its `PERIOD` FK:
`onboard_engineer` → `Engineer` → `EngineerEmployed` → `EngineerAtLevel` → `EngineerContactDetails`;
`sign_contract` → `Contract` → `ContractTerms`; `start_project` → `Project` → `ProjectRun` →
`ProjectProfile` → `ProjectPlan`.

**1b. Edit (versioned-attribute change-or-open)** — `EngineerAtLevel`, the contact/banking/emergency
details, `ProjectProfile`/`Plan`, `ClientProfile`. The repository runs the `FOR PORTION OF … TO NULL`
change re-setting the `[from, NULL)` portion of the covering row; if it touches **no** row (no version
yet exists — the founding write at onboard/start_project) it falls back to the open `INSERT`, keyed off
the live row count. So the founding write and a later edit are the **same fact** — the repository, not
the handler, picks insert vs change. The `*_current` view's most-recently-effective pick advances on
each edit.

**2. Change** (`EngineerAtLevel` from `promote`, `EngineerAllocatedToProject` with `None` from
`change_allocation_fraction`, `RateCard`/`Salary` with open `to` from `revise_rate_card`/`set_salary`)
— one statement, no read:

```sql
UPDATE engineer_role
  FOR PORTION OF held_during FROM $effective TO NULL   -- "from here to the end of time"
  SET level = $new_level
  WHERE engineer_id = $eng AND held_during @> $effective::date;
```

`WHERE … @> $effective` matches only the version in effect at `effective`; `FOR PORTION OF` then
intersects `[effective, ∞)` with that row's own period, so the change lands on `[effective,
row.upper)` and Postgres re-inserts the `[row.lower, effective)` leftover at the old value. A
separately **scheduled future** version doesn't contain `effective`, so `WHERE` excludes it and `TO
NULL` cannot clobber it.

**3. Surgical** (`RateCard` with `Some(to)`, from `adjust_rate_for_portion`) — the same statement shape
with a concrete upper bound, splitting one `rate_card` row into before/during/after (PRD FR-6):

```sql
UPDATE rate_card
  FOR PORTION OF effective_during FROM $from TO $to
  SET day_rate = $new_rate
  WHERE level = $level;
```

The only difference between "publish a new version from a date" (`revise_rate_card`, `TO NULL`) and
"bump just this window" (`adjust_rate_for_portion`, concrete `TO`) is one argument.

**4. Close / cascade** (the retraction facts `EngineerOffProject` from `roll_off`, `EngineerDeparted`
from `terminate_employment`) — these read as positive facts ("off project from X", "departed from X");
the repository implements them as `DELETE … FOR PORTION OF`:

```sql
DELETE FROM allocation
  FOR PORTION OF allocated_during FROM $end TO NULL
  WHERE engineer_id = $eng;   -- no @> filter: intentionally broad
```

`EngineerOffProject` caps one allocation. `EngineerDeparted` runs this against `allocation`, then
`leave`, then `engineer_role`, then `employment` — children first (the repository's `record_departure`
sequence). The omitted `@>` filter is deliberate: departure wipes *all* future child facts (capping the
spanning rows to `[lo, end)` and deleting the fully-future ones). The `PERIOD` FKs both force the
child-first order and verify completeness — cap `employment` last and a missed child rejects the whole
transaction (PRD FR-5). Invoice status (`InvoiceInStatus`) is a cap-then-open: the repository caps the
prior status at `from` and opens the next where it begins, guarded by the handler's status read.

**Correction** needs no special handling: a change whose range covers a fact's whole span yields zero
leftovers, so Postgres deletes the prior assertion — a correction *is* a retroactive change
(ADR-021).

**Error handling — constraints, not code.** Each named op issues the writes and lets the database
reject violations; `operation.try`/`run` then *classify* the rejection by SQLSTATE + the explicit
constraint name (§4) into a typed `OperationError` (via `operation.classify`), generalizing the
existing `timesheet`/`NotAllocated` path (ADR-022):

| violation | SQLSTATE | `OperationError` | HTTP |
|---|---|---|---|
| containment `PERIOD` FK | 23503 | `ContainmentViolated(which)` | 409 |
| `WITHOUT OVERLAPS` exclusion | 23P01 | `OverlappingFact` | 409 |
| `CHECK` (fraction, level, hours) | 23514 | `InvalidValue` | 422 |
| body won't decode | — | (web layer) | 400 |
| anything else | — | `DatabaseError` | 500 |

**HTTP surface — write = command, read = query.** *Every* write goes through one endpoint:
`POST /api/operations` decodes an `{actor, command}` envelope, calls `dispatch`, and returns the
created events as a JSON array (`json.array(events, codecs.encode_event)`). There is no separate
timesheet write path — logging hours is the `LogTimesheet` command on this same endpoint. Reads are
plain queries: `GET /api/board` (the as-of board), `GET /api/timesheet` (the timesheet *form*), and
`GET /api/roster?as_of=` (the console directory — engineers EMPLOYED and projects ACTIVE on the date,
plus all clients — refetched as the slider moves so the console's name `<select>`s only ever offer a
subject valid then); `GET /api/events` lists the journal; the financial reads are §12.5. The client
builds a `Command` (operations console or timesheet), posts it, decodes the returned events, and on
success refetches the relevant reads (board / timesheet form / roster / events) — reads being trivial.

## 6. Squirrel integration

- `.sql` query sources live in `server/src/tempo/server/sql/`; `cd server && gleam run -m squirrel`
  generates `sql.gleam` with one typed function per file (`bin/squirrel`).
- **Range boundary.** Squirrel maps the standard scalar types cleanly; to avoid relying on
  `daterange`/`datemultirange` mapping, queries **return** `lower(<period>) AS valid_from` /
  `upper(<period>) AS valid_to` (plain `date`) and **accept** ranges constructed in SQL
  (`daterange($from, $to, '[)')`). Shared types carry `valid_from` / `valid_to` as `date`s.
- **`FOR PORTION OF` is load-bearing** (§5a). Almost the entire write layer routes through it, so the
  planning spike that confirms Squirrel can introspect/prepare these statements is on the critical
  path; the fallback is hand-written `pog` queries for the write functions (reads stay
  Squirrel-typed). De-risked first in the implementation plan.
- After any migration, regenerate `sql.gleam`; broken queries fail to compile (PRD §1 thesis).

## 7. Schema evolution (the anchor/fact refactor)

The schema's current shape is the **anchor + fact** model of §4 — see `SCHEMA.md` for the live
table/relationship map. It was reached by an ordered chain of in-tree migrations, the last four of
which (`014`–`017`) performed the **anchor/fact split**: every entity became an id-only anchor and its
attributes moved into edit-grouped fact tables. The constraints are what make each step safe.

**The constraints validate the migration.** Each migration runs in one transaction; the `WITHOUT
OVERLAPS` PKs and the `PERIOD` FKs reject a bad transform *inside* it — the database is the migration's
own test harness. Two mechanics carry the 014–017 split with minimal risk:

- **Rename carries the PERIOD FKs.** `016` does not drop and re-add the temporal foreign keys into
  `contract`/`project`; it **renames** the live fact tables (`contract → contract_terms`, `project →
  project_run`) and their id columns, so the dependent `PERIOD` FKs (`project_within_contract`,
  `allocation_within_project`, `invoice_within_project`) re-point by rename. A fresh id-only anchor is
  then minted above each from the distinct ids, with a plain FK back.
- **Seed flows the founding fact.** Where an anchor sheds a column (`014`/`015`/`016`), the old column
  and the new fact table coexist in the same migration (the `DROP COLUMN` is last), so the founding
  `name`/`title` flows straight from the anchor into the fact — guaranteeing the post-refactor reads
  expose the **same** name strings the board/financials JSON exposed before. **External JSON
  (board/financials) is byte-identical** across the refactor.

`017` is the one step where columns **move tables** rather than rename in place (the invoice subject
and the payroll period become immutable 1:1 facts), so the constraints that keyed against the moved
columns are dropped from the anchor and re-added on the fact — including the payroll no-overlap
`EXCLUDE`, which now lives on `payroll_period`.

`010_split_allocation` remains in the chain: it removed an earlier denormalized `day_rate` cache from
`allocation` and `range_agg`-coalesced the fragmented rows, with charge rate thereafter derived from
the two-hop `engineer_role × rate_card` join (§5). The slider scrubbing across any of these boundaries
is the on-stage correctness demonstration.

## 8. Migrations mechanism

- Numbered, hand-written SQL in `server/priv/migrations/` (`NNN_description.sql`), applied in order —
  currently `001`–`017` (`SCHEMA.md` is regenerated from the resulting live DB by `bin/erd`).
- `server/src/tempo/server/migrate.gleam` runs pending files in a transaction and records them in a
  `schema_migrations(version text primary key, applied_at timestamptz)` table.
- **Periods are named for the predicate they assert** (ADR-018) directly in `001_schema.sql`, so `main`
  uses one consistent naming throughout.
- **Seed.** `002_seed.sql` is the canonical seed, run as the second migration: the demo facts plus the
  realistic `event_log` history each fact's `audit_id` links to (ADR-032). `bin/seed-invoices` is the
  separate on-demand financial seed (§9, §12.5).

## 9. Build & run

```sh
# one-shot: db (up + healthy) → migrate → build client → serve on :8000
bin/up
```

The individual steps `bin/up` chains, for running a single piece:

```sh
# database (PG19): start the tempo-db container (from the repo root)
docker compose up -d                                # bin/db

# create + migrate + seed (Gleam server lives in server/, path-deps ../shared)
cd server && gleam run -m tempo/migrate             # bin/migrate

# regenerate typed SQL after schema changes
cd server && gleam run -m squirrel                  # bin/squirrel

# client bundle → ../server/priv/static; also copies client/styles → priv/static/styles
cd client && gleam run -m lustre/dev build client/app   # bin/build

# server (serves JSON API + static assets; from the server/ package)
cd server && gleam run                              # bin/serve
```

On-demand demo financials seed (issued + draft invoices + a payroll run, via the real
`command.dispatch`; idempotent). Deliberately **not** run by `bin/up`, so a freshly-migrated DB stays
test-clean — run it only when you want demo financial data on the dev DB:

```sh
cd server && gleam run -m tempo/seed_financials     # bin/seed-invoices
```

## 10. Testing

Layered — each guarantee verified at the cheapest level that can prove it. The Gleam layers (129
tests) follow strict TDD (`todo` stubs first, `assert expr == expected`, deterministic seed values);
14 Playwright specs sit on top.

**1. Temporal-constraint tests** (Gleam + pog against an ephemeral PG19). Prove the database, not the
app, enforces the rules. Each asserts the expected rejection or split, **and** that the rejection
classifies to the right typed `OperationError` (ADR-022):
  - `WITHOUT OVERLAPS` rejects an overlapping `allocation` for the same `(engineer, project)`.
  - PERIOD FKs reject: an `allocation`/`leave`/`engineer_role` extending past `employment`; an
    `allocation` outside its `project_run`; a `project_run` outside its `contract_terms`; a
    `timesheet` against a project not allocated that day.
  - `FOR PORTION OF` splits a `rate_card` row into the expected before/during/after sub-periods.
  - `range_agg` coalescing produces the expected merged ranges (and preserves real gaps).

**2. Operation tests** (the new core, §5a). Apply each operation to a known state, then assert the
resulting facts *and* exactly one `event_log` row (operation/summary/payload). Cover the hard cases
explicitly:
  - `promote` splits the version covering the effective date but preserves a separately scheduled
    future version; the leftover keeps the old level.
  - `terminate_employment` cascade-caps `allocation`/`leave`/`engineer_role` then `employment`, and is
    *rejected* when a `timesheet` outlives the end date.
  - a retroactive `revise_rate_card` whose range covers a whole fact erases the prior value (zero
    temporal leftovers).
  - `adjust_rate_for_portion` produces the expected before/during/after split.

**3. As-of query tests.** Crafted seed + fixed dates → exact expected board / timesheet-form rows.

**4. Codec round-trip tests.** `encode |> decode == value` for every shared API type — including
`Command` and `Event` — pure Gleam, runs on both targets.

**5. End-to-end (Playwright, 14 specs across four files).** Drives the real app — Wisp serving the
Lustre SPA against a migrated+seeded PG19. **Behaviour-driven**: assert what the user sees, never CSS
classes / ids / DOM structure. Each panel is a named region (`role=region`, e.g. "My timesheet",
"Operations console") so a query scoped to it is unambiguous even where two panels share a control
label — the timesheet's and the console's same-named "Engineer" `<select>` resolve only because each
lookup is scoped to its region. One test per read beat *and* per operation beat (PRD §7, §9):
  - `slider-board.spec.js` — scrub to a date → expected engineers/projects/clients shown; scrub across
    a seeded future promotion → level and charge rate increase; scrub onto a leave period → "On leave";
    an employed-but-unallocated engineer shows as Unassigned; the selected date round-trips through the
    URL;
  - `timesheet.spec.js` — scrub to a day → only allocated projects offered; enter hours → reload →
    persisted; a rolled-off project is not offered; on leave → nothing to log; an empty hours field
    shows a friendly message, not a crash;
  - `operations.spec.js` — promote in the console → the board re-renders with the new level/rate and the
    event-log panel shows the new entry; an operation the database refuses shows the user why and leaves
    the board unchanged;
  - `financials.spec.js` — draft then issue an invoice → its total appears in the P&L revenue; scrub the
    slider before the issue date → the invoice shows as `draft` again.

**Behavioural contract.** The Playwright suite asserts only what the user sees — never a table shape,
the rate source, or any internal that the anchor/fact refactor (§7) moved. Because the migrations
thread the founding facts so the board/financials JSON is byte-identical across the refactor, the
suite holds by construction over the migrated+seeded schema. Playwright is written and maintained
continuously through development, not added at the end.

**Determinism.** Valid-time "now" is a fixed seed date, not the system clock; the seed uses explicit
names/dates/rates (no factory sequences in assertions), so every layer is reproducible.
`event_log.occurred_at` is the one real-clock column, so tests assert on operation/summary/payload,
never on the timestamp.

**Provisioning / CI.** Ephemeral PG19 per run (container / CI service). `.github/workflows/test.yml`
runs each step in its package's working directory: provision PG19 → `gleam test` (layers 1–4) in
`server/` → build the client in `client/` (bundle → `../server/priv/static`) → migrate + seed and run
`npx playwright test` (layer 5) in `e2e/`.

## 11. Open spikes (resolve during planning)

1. **PG19 availability** on the talk machine (beta/RC or temporal-patched build).
2. **Squirrel ↔ `daterange` / `datemultirange`** mapping — confirm the `lower()/upper()`
   decomposition strategy compiles and round-trips.
3. **Squirrel ↔ `FOR PORTION OF`** — confirm PG can prepare the statement and Squirrel accepts it;
   fall back to a hand-written `pog` query for that one statement if not.
4. **Temporal upsert** — confirm the delete-then-insert (or supplemental unique index) approach for
   timesheet re-entry.

## 12. Financials (invoicing, payroll, P&L)

Money layered on the temporal staffing model (`PRD-financials.md`): same stack, same discipline —
writes through the command bus (§5a), reads as as-of queries (§5). Migration **`012_financials.sql`
is additive** over the staffing schema; `013_financial_fks.sql` then closed the financial layer's
cross-references, and `017` reshaped invoice/payroll_run into anchors + facts (§4, §7). See `SCHEMA.md`
for the resulting financial tables.

### 12.1 Schema (the new tables)

Same naming discipline as §4: periods named for the predicate they assert (ADR-018), `WITHOUT
OVERLAPS` and `CHECK` constraints carry explicit names so a violation classifies to a typed
`OperationError` (ADR-022). One **cost fact** (`salary`); an invoice **anchor** (`invoice`) with its
immutable subject (`invoice_subject`), temporal status (`invoice_status`), and snapshot lines
(`invoice_line`); and a payroll **anchor** (`payroll_run`) with its immutable period
(`payroll_period`) and lines (`payroll_line`). The DDL below shows the original `012` shape for
illustration; in the consolidated `001_schema.sql` the command-minted anchors are `int GENERATED BY
DEFAULT AS IDENTITY` (so the app supplies an id reserved from the same `<anchor>_id_seq` via
`repository.next_id`, and the seed can pin explicit ids), and every fact carries an `audit_id` FK to
`event_log` — see `SCHEMA.md` for the current shape.

```sql
-- Cost rate (the analogue of rate_card: what we PAY a level, vs what we CHARGE) --
CREATE TABLE salary (                            -- "we pay level L this monthly salary"
  level          int NOT NULL CHECK (level BETWEEN 1 AND 7),
  monthly_salary numeric(10,2) NOT NULL,
  effective_during daterange NOT NULL,
  CONSTRAINT salary_no_overlap
    PRIMARY KEY (level, effective_during WITHOUT OVERLAPS)  -- FOR PORTION OF target, like rate_card
);

-- Invoice: identity + immutable subject (which project, which month) -----------
CREATE TABLE invoice (
  id             int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id     int NOT NULL,                   -- project ENTITY id (no identity table; see below)
  billing_period daterange NOT NULL              -- the daterange covering the billed month
);

CREATE TABLE invoice_status (                    -- "invoice N is in status S" — the temporal lifecycle
  invoice_id int NOT NULL REFERENCES invoice(id),
  status     text NOT NULL CHECK (status IN ('draft', 'issued', 'paid')),
  status_during daterange NOT NULL,
  CONSTRAINT invoice_status_no_overlap
    PRIMARY KEY (invoice_id, status_during WITHOUT OVERLAPS)
);

CREATE TABLE invoice_line (                       -- the lines snapshotted at draft (plain rows)
  invoice_id  int NOT NULL REFERENCES invoice(id),
  engineer_id int NOT NULL,
  level       int NOT NULL,
  day_rate    numeric(10,2) NOT NULL,             -- the contract-AGREED rate (§12.2)
  days        numeric(8,2) NOT NULL,
  amount      numeric(12,2) NOT NULL
);

-- Payroll: a run per month, a prorated payment instruction per engineer --------
CREATE TABLE payroll_run  (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, period daterange NOT NULL);
CREATE TABLE payroll_line (
  run_id      int NOT NULL REFERENCES payroll_run(id),
  engineer_id int NOT NULL,
  amount      numeric(12,2) NOT NULL,
  days        numeric(8,2) NOT NULL
);
```

**Cross-entity containment is now enforced.** As shipped in `012` the financial rows held no
cross-entity PERIOD FKs — an invoice referenced a project *entity* id with no single-row table to key
against, so containment lived only in the computing queries (§12.2–12.4). `013_financial_fks.sql` then
closed those gaps, and `017` carried the constraint to its current home: `invoice_subject.project_id`
is a **PERIOD FK** into `project_run` (keyed against the project's temporal PK), so an invoice's
billing month must fall within the project's active period, and the snapshot lines' `engineer_id`s are
plain FKs. So `SCHEMA.md` has no dashed `logical (no FK)` edges. Also enforced: the `invoice_status`
`WITHOUT OVERLAPS` exclusion, the `salary` exclusion, the status `CHECK`, the `payroll_period`
no-overlap `EXCLUDE`, and the plain `REFERENCES` on the status/line children. `salary` is revised
exactly like `rate_card` — `salary_revise.sql` is a `FOR PORTION OF effective_during FROM $effective
TO NULL` Change (§5a pattern 2), and `SetSalary` is its command.

### 12.2 Agreed-rate billing (`invoice_billing_lines.sql`, FR-F1/F2 — the centerpiece)

`DraftInvoice(project_id, month)` mints the invoice anchor, opens its `draft` status and immutable
`invoice_subject`, and computes its lines once (snapshotted). The temporal point is **which `rate_card`
version to read**: the `day_rate` is `rate_card[level] @> lower(contract_terms.term)` — the rate as of
the **contract's signing date** — **not** `rate_card @> month`. If the rate card was revised after the
contract was signed, the invoice still bills the older *agreed* rate, so the board's as-of-today charge
rate and an invoice's billed rate visibly diverge once a `ReviseRateCard` has landed.

The query pins `agreed_date = lower(contract_terms.term)` for the one contract active over the month
(`project_run ⊂ contract_terms`, both `&&` the month), then per line:

- the billable sub-period is the **three-way intersection** (`*`) of `allocation`, the
  `engineer_role` (level) version, and the month — so a **mid-month promotion splits** the work into
  one sub-period per level, each billed at *that level's* agreed rate;
- `days = Σ fraction × (upper − lower)` and `amount = Σ fraction × (upper − lower) × day_rate`, day
  counted as the integer width of the range, aggregated per `(engineer, level)`;
- the rate is joined `rate_card.effective_during @> agreed_date` (not the month). **Leave does not
  reduce billing** — billing is allocation-fraction-weighted working days; leave is a payroll concern
  (§12.3), paid in full.

`IssueInvoice` / `PayInvoice` are temporal **status Changes** (§5a, the Change pattern) with a guard:
read the status covering `at`, assert it equals the expected predecessor (`draft` for issue, `issued`
for pay) — an out-of-order transition is rejected as `InvalidValue`, not silently applied — then
`invoice_status_close` caps it (`DELETE … FOR PORTION OF status_during FROM $at TO NULL`) and
`invoice_status_open` asserts the next from `at`; the `invoice_status_no_overlap` exclusion is the
database backstop. The initial `draft` opens at `lower(billing_period)`, so scrubbing the slider back
to before an invoice's issue date shows it as `draft` again (FR-F4).

### 12.3 Payroll proration (`payroll_amounts.sql`, FR-F5/F6)

`RunPayroll(month)` mints a `payroll_run` and one `payroll_line` per engineer employed in the month.
The paid period is the intersection (`*`) of **`employment ∩ engineer_role(level) ∩ salary-version ∩
month`**; splitting on both the role and the salary version means a **mid-month promotion** is paid
partly at each level's salary and a mid-month salary revision is honoured day-accurate:

```
amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod / days_in_month
days   = Σ over sub-periods of  days_in_subperiod                      (employed days in month)
```

`days_in_month` is the actual calendar width (`upper(month) − lower(month)`, 28..31). A hire or
termination mid-month **clips** the paid period to the employed days; a promotion **splits** it;
**leave is paid in full** — the `leave` table is deliberately **not consulted**, so payroll prorates
over `employment`, not `employment − leave` (FR-F6).

### 12.4 P&L (`pnl_rows.sql` + `finance_query.pnl`, FR-F7/F8 — a read query)

`GET /api/pnl?as_of=` is a pure read. `pnl_rows.sql` returns, per engineer employed in the window, the
raw components; `finance_query.pnl` runs it over **two windows** — the month containing `as_of`, and
year-to-date (Jan 1 of that year to the end of that month) — and derives the rest in Gleam:

- **revenue** = Σ `invoice_line.amount` over invoices whose `billing_period` overlaps the window
  **and** whose status **as of the window's exclusive upper bound** is `issued`/`paid`. Revenue is
  recognized **on issue** (PRD §8); the as-of predicate carries FR-F4 into the P&L — scrub the period
  end back before an issue date and that revenue drops out.
- **cost** = Σ `payroll_line.amount` over runs whose period overlaps the window.
- **profit** = revenue − cost; **margin %** = profit / revenue (0 at zero revenue).
- **utilization %** = `Σ fraction × days in (allocation ∩ employment ∩ window)` / `employed_days` —
  capacity-share, **not** hours-based (the timesheet is not consulted; leave does not reduce it; PRD §8).

The driving set is engineers **employed** in the window (so the utilization denominator is non-zero);
revenue/cost/utilization attach by `LEFT JOIN` and coalesce to 0, so an employed engineer with no
invoices/payroll/allocation still appears with zeros and the per-engineer rows **reconcile to the
statement totals** (the totals are the sum of the breakdown). Revenue and cost are summed from the
**snapshot** lines (`invoice_line`, `payroll_line`), not a recomputation — an issued invoice does not
retro-change when underlying facts move (PRD §8).

### 12.5 Layering & tests

Commands route through the same bus as everything else: `invoice.handle` and `payroll.handle` (and
`salary` via `SetSalary`) each do their writes and emit one `Event` (§5a, ADR-025). The web layer adds
read-only `GET /api/invoices` (+`/:id`), `GET /api/payroll?from=&to=`, and `GET /api/pnl?as_of=`,
each delegating to `finance_query` (which speaks shared types and never imports `wisp` or `sql`
directly — it is the domain seam, §10). Tests: `financials_test.gleam` (operation layer — the agreed
rate after a later `ReviseRateCard`, the mid-month hire/termination/promotion proration, leave at full
pay, and the rejected out-of-order transition), `pnl_test.gleam` (the read layer — exact
month/YTD/per-engineer figures), codec round-trips for the new `Command`/read types, and the
behaviour-driven `e2e/financials.spec.js` (draft → issue → revenue appears; scrub back → `draft`).

## 13. Leave balances (`leave_policy` + `leave_balance.sql`, a read calculation)

Leave entitlement is a temporal, per-`(kind, level)` **`leave_policy`** (`days_per_year` versioned over
`effective_during`, like `rate_card`/`salary`). A balance is never stored — it is a pure as-of query
(ADR-034), the same temporal integration the payroll layer does:

- **accrued** = Σ over each `employment ∩ engineer_role ∩ leave_policy[kind, level] ∩ (−∞, as_of)`
  sub-period of `days_per_year × (year_fraction(hi) − year_fraction(lo))`. `year_fraction(d)` is a
  **leap-aware** year coordinate — `year + day-of-year / that-year's-length` — so a day in a 366-day
  year is worth `1/366` of the grant and a full year is exactly `1.0`, with no drift across leap
  boundaries. Because the integration splits on the `engineer_role` version, a **promotion blends the
  accrual rate** across its date exactly as it blends salary in `payroll_amounts` (L6+ accrue more).
- **taken** = Σ calendar days of the engineer's `leave` of that kind up to `as_of`.
- **balance** = accrued − taken. `leave_balance(engineer, kind, as_of)` returns it for any past or
  future date; a future policy change (e.g. "25 days from 2027-01-01") is a `FOR PORTION OF` revise and
  the calculation is unchanged — it simply integrates whichever version covers each slice.

`take_leave` guards on this: `leave_check` returns the balance on return (accrued − taken as of
`valid_to`) and the days requested (`valid_to − valid_from`); the handler rejects when the kind is
policied and the balance is short, as `InsufficientLeaveBalance` (→ 422). A kind with **no** policy
(e.g. unpaid) is unlimited — no guard fires. `accrued_leave`/`taken_leave` are `STABLE` SQL functions so
both the balance query and the guard share one definition. Tests: `leave_test.gleam` (per-level
accrual, leap-exactness, taken subtraction, promotion blend, automatic policy-change pickup, and the
guard's allow/reject/unlimited paths).

## 14. Frontend application (the overhaul — PRD-frontend.md)

The client becomes a real application: a login gate, a persistent shell, client-side routing, and one
global as-of date every page resolves against. ADR-014's single JS `client` package is unchanged; this
is internal structure plus a few new read endpoints. The write path (`POST /api/operations`, the
`Command` vocabulary) is untouched.

**Module split (ADR-039).** `app.gleam` shrinks from one ~2400-line module to a shell that owns the
top-level model, the global as-of date, the login gate, the sidebar, and the `modem` router. Routing
dispatches to one module per page; shared view atoms and the time rail are their own modules.

```
client/src/client/
  app.gleam            # shell: model/update/view, login gate, sidebar, modem router, global as-of
  route.gleam          # Route type + parse/to_uri (path + ?date=); modem on_url_change → Msg
  time.gleam           # the time rail: slider/date-input/step/Today over the seed range
  ui.gleam             # shared view helpers: avatar, pill, stat, panel, table, kv (no page logic)
  page/
    board.gleam        # GET /api/board
    people.gleam       # GET /api/people, /api/engineers/:id, /api/timesheet
    clients.gleam      # GET /api/clients/:id (+ roster)
    projects.gleam     # GET /api/projects/:id (+ roster)
    finance.gleam      # invoices(+:id) / payroll / pnl (three tabs)
    activity.gleam     # GET /api/events
    settings.gleam     # rate card / salary / leave_policy reads
```

Pages import `shared/*` (the contract types + codecs) and the fetch helpers (`rsvp`), never each
other's internals — the same one-purpose-per-module discipline as the server's web handlers (§3).

**Global as-of (ADR-036).** The shell model holds one `as_of: calendar.Date`. The time rail emits a
`AsOfChanged(Date)` message; the shell updates the date, writes it to the URL (`?date=`, via `modem`),
and re-issues the active page's fetch. As-of is **application (valid) time** — the axis board, finance,
balances, and detail pages resolve against. The **Activity** journal is **system time** and is *not*
filtered by the rail (PRD §5; the Activity PRD documents this). The seed-range bounds and the
`seed_now` anchor that the current slider uses carry over unchanged.

**Routing (ADR-036/039).** `route.gleam` defines the `Route` union (`Board`, `People(Option(Int))`,
`Clients(Option(Int))`, `Projects(Option(Int))`, `Finance(Tab)`, `Activity`, `Settings`) and maps it
to/from a URL, with the as-of date as a query param carried across navigation. `lustre/modem` (already
a `client` dependency) drives `init` (parse the initial URL) and `on_url_change`; the sidebar links and
in-page drill-ins are plain `<a href>`s modem intercepts. Routes are deep-linkable and honour
back/forward.

**Login gate (ADR-035).** Identity is client view-state: an `actor: Option(String)` in the model. The
gate lists the seeded engineers (from the roster) and the Admin/Ops roles; selecting one sets `actor`
and reveals the shell, "sign out" clears it. `actor` is sent in each `OperationRequest` (the existing
field). No backend, no session.

**New read endpoints (PRD-frontend §5).** All are as-of queries over the existing `*_current` views and
fact tables — no schema change — added as thin web handlers beside the current ones (§3), each calling
the domain and encoding a shared type:

| Route | Returns | Built from |
|---|---|---|
| `GET /api/people?as_of=` | roster list (level, status, allocation, leave balance per engineer) | board snapshot + `leave_balance` (superset of today's board) |
| `GET /api/engineers/:id?as_of=` | detail bundle: contact/banking/emergency, employment + role history, allocations, leave balance + history | `engineer_*_current` views + `engineer_role`/`employment`/`allocation`/`leave` |
| `GET /api/clients/:id` | profile, contracts, projects | `client_profile_current` + contracts/projects |
| `GET /api/projects/:id?as_of=` | profile, plan, team as-of, invoices | `project_profile_current`/`project_plan_current` + allocation + invoices |
| settings reads | current rate card / salary / leave policy rows | `rate_card`/`salary`/`leave_policy` |

New shared types back these bundles (e.g. an engineer-detail record aggregating the existing
`EngineerContact`/`EngineerBanking`/`EngineerEmergency` with history lists); contextual-action writes
reuse the existing `Command` variants unchanged.

**CSS (ADR-038).** `client/styles/theme.css` grows into the full token system (spacing/type/weight/
radius scales, semantic colours, layout sizes, the `--cat-*` categorical palette); new per-area files
(`app-shell`, `sidebar`, `time-rail`, `login`, plus one per page) join the `main.css` `@import`
manifest in page order and are copied to `priv/static/styles` by `bin/build` (ADR-029). Every rule
references `var(--token)`; no rule carries a literal colour or size.

**Testing.** The existing Playwright beats (board/slider, timesheet, operations, financials) move
behind the shell — selectors updated to the new layout and navigation, behaviour-driven assertions
(text/ARIA) unchanged. New beats cover sign-in → land on board, navigating between pages with the as-of
date preserved, and a contextual action appearing in the Activity journal.
