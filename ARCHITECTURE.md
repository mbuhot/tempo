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
`docker-compose.yml` (the PG19 container), `plan/` (the build plan), and the design docs.

```
bin/                          # thin task wrappers run from the repo root; each cd's
                              #   into the right package: db, migrate, serve, test,
                              #   build, e2e, oracle, squirrel
docker-compose.yml            # PG19 (tempo-db) on host port 5434
plan/                         # phased build plan
PRD.md ARCHITECTURE.md DECISIONS.md README.md RUNBOOK.md   # design + run docs

server/                       # package `tempo` — the Wisp server (Erlang target)
  gleam.toml                  #   depends on shared = { path = "../shared" }
  src/
    tempo.gleam               #   server entrypoint (gleam run, Erlang target)
    tempo/
      oracle.gleam            #   migration-oracle entrypoint (gleam run -m tempo/oracle)
      server/
        web/                  #   web layer (HTTP) — never imports sql
          router.gleam        #     routing + static serving; dispatches to handlers
          board.gleam         #     GET /api/board handler
          timesheet.gleam     #     GET/POST /api/timesheet handlers
          operations.gleam    #     POST /api/operations handler (decode Command → dispatch)
          events.gleam        #     GET /api/events handler (the provenance journal)
          request.gleam       #     parse query params into a calendar.Date
          response.gleam      #     json/error response helpers (leaf; shared by router + handlers)
        command.gleam         #   domain — Command dispatch seam: txn + route + event_log row
        engineer.gleam        #   domain — onboard / promote / terminate_employment (cascade)
        allocation.gleam      #   domain — assign / change_fraction / roll_off
        rate_card.gleam       #   domain — revise / adjust_for_portion (FOR PORTION OF)
        engagement.gleam      #   domain — sign_contract / start_project
        leave.gleam           #   domain — take_leave
        event.gleam           #   domain — append (used by dispatch) + list (journal read)
        board.gleam           #   domain — board.snapshot (no wisp)
        timesheet.gleam       #   domain — form, log, WriteError (no wisp)
        context.gleam         #   pog connection pool
        sql/                  #   Squirrel .sql sources → generated sql.gleam
        migrate.gleam         #   numbered-migration runner (gleam run -m tempo/migrate)
        seed.gleam            #   the seed as an ordered List(Command) replayed through dispatch
  test/                       #   layers 1–6 (constraint, operation, seed-equivalence, as-of, codec, oracle helpers)
  priv/
    migrations/               #   001_init.sql, 002_facts.sql, 003_seed.sql, 010_split_allocation.sql
    static/                   #   compiled client bundle (app.js) + index.html + styles.css

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

e2e/                          # Playwright harness (Node) — drives the real app
  package.json                #   @playwright/test
  playwright.config.js        #   testDir "." → the *.spec.js below
  slider-board.spec.js        #   org board / slider beats
  timesheet.spec.js           #   my-timesheet beats (incl. the negative beat)
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

## 4. Data model (v2 — the target schema)

Two **identity** tables (durable referents) and eight **fact** tables, each valid over a `daterange`
period **named for the predicate it asserts** (ADR-018) rather than a uniform `valid_at`. This is
effectively 6NF: one fact per relation. A single append-only `event_log` table records system-time
provenance *beside* the facts (§5a, ADR-021). The `PERIOD` foreign keys and `WITHOUT OVERLAPS`
exclusion constraints carry **explicit names** so a violation classifies to a typed domain error
(ADR-022).

```sql
-- Identity ------------------------------------------------------------------
CREATE TABLE engineer (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL);
CREATE TABLE client   (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL);

-- Facts ---------------------------------------------------------------------
CREATE TABLE employment (                       -- "engineer is employed"
  engineer_id    int NOT NULL REFERENCES engineer(id),
  employed_during daterange NOT NULL,
  CONSTRAINT employment_no_overlap
    PRIMARY KEY (engineer_id, employed_during WITHOUT OVERLAPS)
);

CREATE TABLE engineer_role (                    -- "engineer holds level L"; promotion = new row
  engineer_id int NOT NULL,
  level       int NOT NULL CHECK (level BETWEEN 1 AND 7),
  held_during daterange NOT NULL,
  CONSTRAINT engineer_role_no_overlap
    PRIMARY KEY (engineer_id, held_during WITHOUT OVERLAPS),
  CONSTRAINT engineer_role_within_employment
    FOREIGN KEY (engineer_id, PERIOD held_during)
    REFERENCES employment (engineer_id, PERIOD employed_during)
);

CREATE TABLE rate_card (                         -- L1–L7 charge rates, versioned over time
  level           int NOT NULL CHECK (level BETWEEN 1 AND 7),
  day_rate        numeric(10,2) NOT NULL,
  effective_during daterange NOT NULL,
  CONSTRAINT rate_card_no_overlap
    PRIMARY KEY (level, effective_during WITHOUT OVERLAPS)  -- FOR PORTION OF target
);

CREATE TABLE contract (                         -- "client engagement", a term
  id        int NOT NULL,
  client_id int NOT NULL REFERENCES client(id),
  term      daterange NOT NULL,
  CONSTRAINT contract_no_overlap
    PRIMARY KEY (id, term WITHOUT OVERLAPS)
);

CREATE TABLE project (                          -- "project runs under a contract"  (project ⊂ contract)
  id           int NOT NULL,
  contract_id  int NOT NULL,
  name         text NOT NULL,
  active_during daterange NOT NULL,
  CONSTRAINT project_no_overlap
    PRIMARY KEY (id, active_during WITHOUT OVERLAPS),
  CONSTRAINT project_within_contract
    FOREIGN KEY (contract_id, PERIOD active_during)
    REFERENCES contract (id, PERIOD term)
);

CREATE TABLE allocation (                        -- "engineer on project" (fractional; ⊂ employment AND ⊂ project)
  engineer_id     int NOT NULL,
  project_id      int NOT NULL,
  fraction        numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  allocated_during daterange NOT NULL,
  CONSTRAINT allocation_no_overlap            -- no overlap per engineer+project
    PRIMARY KEY (engineer_id, project_id, allocated_during WITHOUT OVERLAPS),
  CONSTRAINT allocation_within_employment
    FOREIGN KEY (engineer_id, PERIOD allocated_during)
    REFERENCES employment (engineer_id, PERIOD employed_during),
  CONSTRAINT allocation_within_project
    FOREIGN KEY (project_id, PERIOD allocated_during)
    REFERENCES project (id, PERIOD active_during)
);

CREATE TABLE leave (                            -- "engineer on leave" (⊂ employment; overrides allocation)
  engineer_id   int NOT NULL,
  kind          text NOT NULL,                  -- annual | sick | parental | …
  on_leave_during daterange NOT NULL,
  CONSTRAINT leave_no_overlap
    PRIMARY KEY (engineer_id, on_leave_during WITHOUT OVERLAPS),
  CONSTRAINT leave_within_employment
    FOREIGN KEY (engineer_id, PERIOD on_leave_during)
    REFERENCES employment (engineer_id, PERIOD employed_during)
);

CREATE TABLE timesheet (                         -- "hours logged"; a logged day must be covered by an allocation
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  work_day    daterange NOT NULL,                -- a single day [d, d+1)
  hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  CONSTRAINT timesheet_no_overlap
    PRIMARY KEY (engineer_id, project_id, work_day WITHOUT OVERLAPS),
  CONSTRAINT timesheet_within_allocation
    FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
    REFERENCES allocation (engineer_id, project_id, PERIOD allocated_during)
);

-- Provenance (system time, beside the facts) --------------------------------
-- Append-only journal: one row per applied operation. Never referenced by the
-- fact tables (no FKs in or out), so it constrains and contaminates nothing.
CREATE TABLE event_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- also the order applied
  occurred_at timestamptz NOT NULL DEFAULT now(),  -- SYSTEM time: the real wall clock
  actor       text  NOT NULL,                      -- who applied it (nominal; no auth)
  operation   text  NOT NULL,                      -- command tag: 'promote', 'revise_rate_card', …
  summary     text  NOT NULL,                      -- human-readable description
  payload     jsonb NOT NULL                       -- the command's parameters (shared codecs)
);
```

### PERIOD-FK containment chain

```
leave  ──┐
         ├─▶ employment
allocation ─┘        └─▶ project ─▶ contract
engineer_role ─▶ employment
timesheet ─▶ allocation
```

End an engineer's `employment` and the database blocks any `allocation`/`leave`/`role` that would
dangle past it (PRD FR-5).

### `WITHOUT OVERLAPS` scoping

| table | uniqueness | meaning |
|---|---|---|
| employment, engineer_role, leave | per `engineer_id` | one employment/level/leave at a time |
| rate_card | per `level` | one rate per level at a time |
| contract, project | per `id` | one row per entity per instant |
| allocation | per `(engineer_id, project_id)` | concurrent projects allowed; no double-row for the same project |
| timesheet | per `(engineer_id, project_id)` | one entry per project per day |

## 5. Key queries

All temporal columns are `daterange`; the as-of predicate is `<period> @> $when::date`, where
`<period>` is the table's semantically-named period column (§4).

**Org board, as of a date.** The board is **three** as-of queries, one per `Engagement`
variant of the shared `BoardRow`, merged and re-sorted by engineer name in
`board.snapshot` (`server/src/tempo/server/board.gleam`). Every employed engineer is represented
**exactly once** as of any date: allocated (one row per project), unassigned, or on leave.
The split is forced by Squirrel typing — a `LEFT JOIN`ed column comes back as non-null, so
a single `LEFT JOIN` board query cannot represent the employed-but-unallocated row and
500s on those dates; see ADR-015. Each query therefore uses **`INNER JOIN`s only**, so
every selected column is non-null and decodes without `Option` plumbing.

1. `board_as_of` — the **engaged** slice: engineers `INNER JOIN`ed all the way through
   `allocation → project → contract → client` and `engineer_role → rate_card`, so they are
   employed *and* allocated as of the date. One row per (engineer × project). Engineers
   with a covering `leave` fact are suppressed here (`NOT EXISTS`). Charge rate is the
   two-hop `engineer_role × rate_card` join (ADR-009), exposed as a plain `day_rate` value
   (ADR-013). → `OnProject`.

   ```sql
   SELECT e.name AS engineer, rl.level, pr.name AS project, cl.name AS client,
          al.fraction, rc.day_rate,
          lower(al.allocated_during) AS valid_from, upper(al.allocated_during) AS valid_to
   FROM employment emp
   JOIN engineer e       ON e.id = emp.engineer_id
   JOIN engineer_role rl ON rl.engineer_id = e.id  AND rl.held_during      @> $1::date
   JOIN rate_card rc     ON rc.level = rl.level     AND rc.effective_during @> $1::date
   JOIN allocation al    ON al.engineer_id = e.id   AND al.allocated_during @> $1::date
   JOIN project pr       ON pr.id = al.project_id   AND pr.active_during    @> $1::date
   JOIN contract ct      ON ct.id = pr.contract_id  AND ct.term            @> $1::date
   JOIN client cl        ON cl.id = ct.client_id
   WHERE emp.employed_during @> $1::date
     AND NOT EXISTS (SELECT 1 FROM leave lv
                     WHERE lv.engineer_id = e.id AND lv.on_leave_during @> $1::date)
   ORDER BY e.name, pr.name;
   ```

2. `board_unassigned_as_of` — employed, **not** allocated and **not** on leave as of the
   date. `INNER JOIN engineer_role` keeps `level` non-null (an employed engineer always has
   a role in the seed). Returns just `(engineer, level)`. → `Unassigned`.

   ```sql
   SELECT e.name AS engineer, rl.level
   FROM employment emp
   JOIN engineer e       ON e.id = emp.engineer_id
   JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.held_during @> $1::date
   WHERE emp.employed_during @> $1::date
     AND NOT EXISTS (SELECT 1 FROM allocation al
                     WHERE al.engineer_id = e.id AND al.allocated_during @> $1::date)
     AND NOT EXISTS (SELECT 1 FROM leave lv
                     WHERE lv.engineer_id = e.id AND lv.on_leave_during @> $1::date)
   ORDER BY e.name;
   ```

3. `board_leave_as_of` — exactly the engineers a covering `leave` fact hides from
   `board_as_of`. Leave overrides the engagement: the underlying allocation is deliberately
   not joined. The level is still resolved (for the charge story). Returns
   `(engineer, level, kind, valid_from, valid_to)`. → `OnLeave`.

   ```sql
   SELECT e.name AS engineer, rl.level, lv.kind,
          lower(lv.on_leave_during) AS valid_from, upper(lv.on_leave_during) AS valid_to
   FROM leave lv
   JOIN engineer e            ON e.id = lv.engineer_id
   LEFT JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.held_during @> $1::date
   WHERE lv.on_leave_during @> $1::date
   ORDER BY e.name;
   ```

Range columns are decomposed to plain `date`s at the boundary (ADR-011):
`lower(<period>)`/`upper(<period>)` AS `valid_from`/`valid_to`.

**Timesheet form — my allocations as of a day** (only projects I'm on; blank when on leave):

```sql
SELECT pr.id AS project_id, pr.name AS project, al.fraction,
       COALESCE(ts.hours, 0) AS hours
FROM allocation al
JOIN project pr ON pr.id = al.project_id AND pr.active_during @> $2::date
LEFT JOIN timesheet ts ON ts.engineer_id = al.engineer_id
                      AND ts.project_id  = al.project_id
                      AND ts.work_day @> $2::date
WHERE al.engineer_id = $1 AND al.allocated_during @> $2::date
  AND NOT EXISTS (SELECT 1 FROM leave lv
                  WHERE lv.engineer_id = $1 AND lv.on_leave_during @> $2::date);
```

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

**`command.dispatch(context, actor, command)`** opens one `pog.transaction`, routes the command to its
aggregate function (`engineer`, `allocation`, `rate_card`, `engagement`, `leave`, `timesheet`), then
appends exactly one `event_log` row (`operation` tag, `summarize(command)`, and the command
re-encoded as `payload`) — facts and journal commit together or not at all. The aggregate functions
take the in-transaction connection and do *only* their temporal writes; event-writing lives solely in
`dispatch`.

The temporal writes fall into four patterns. PG19's `FOR PORTION OF` produces the before/after
"temporal leftovers" and drops a fully-covered row itself, so there is **no** hand-rolled
cap-and-insert and no empty-period bookkeeping.

**1. Assert** (`onboard_engineer`, `sign_contract`, `start_project`, `assign_to_project`,
`take_leave`, `log_timesheet`) — plain `INSERT`, open-ended where the fact is ongoing
(`employed_during = daterange($start, NULL, '[)')`). `onboard_engineer` is three inserts in one txn
(identity → employment → role), each contained in the last by its `PERIOD` FK.

**2. Change** (`promote`, `change_allocation_fraction`, `revise_rate_card`) — one statement, no read:

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

**3. Surgical** (`adjust_rate_for_portion`) — the same statement shape with a concrete upper bound,
splitting one `rate_card` row into before/during/after (PRD FR-6):

```sql
UPDATE rate_card
  FOR PORTION OF effective_during FROM $from TO $to
  SET day_rate = $new_rate
  WHERE level = $level;
```

The only difference between "publish a new version from a date" (`revise_rate_card`, `TO NULL`) and
"bump just this window" (`adjust_rate_for_portion`, concrete `TO`) is one argument.

**4. Close / cascade** (`roll_off`, `terminate_employment`) — `DELETE … FOR PORTION OF`:

```sql
DELETE FROM allocation
  FOR PORTION OF allocated_during FROM $end TO NULL
  WHERE engineer_id = $eng;   -- no @> filter: intentionally broad
```

`roll_off` caps one allocation. `terminate_employment` runs this against `allocation`, then `leave`,
then `engineer_role`, then `employment` — children first. The omitted `@>` filter is deliberate:
terminate wipes *all* future child facts (capping the spanning rows to `[lo, end)` and deleting the
fully-future ones). The `PERIOD` FKs both force the child-first order and verify completeness — cap
`employment` last and a missed child rejects the whole transaction (PRD FR-5).

**Correction** needs no special handling: a change whose range covers a fact's whole span yields zero
leftovers, so Postgres deletes the prior assertion — a correction *is* a retroactive change
(ADR-021).

**Error handling — constraints, not code.** The domain issues the writes and lets the database reject
violations, then *classifies* the rejection by SQLSTATE + the explicit constraint name (§4) into a
typed `OperationError`, generalizing the existing `timesheet`/`NotAllocated` path (ADR-022):

| violation | SQLSTATE | `OperationError` | HTTP |
|---|---|---|---|
| containment `PERIOD` FK | 23503 | `ContainmentViolated(which)` | 409 |
| `WITHOUT OVERLAPS` exclusion | 23P01 | `OverlappingFact` | 409 |
| `CHECK` (fraction, level, hours) | 23514 | `InvalidValue` | 422 |
| body won't decode | — | (web layer) | 400 |
| anything else | — | `DatabaseError` | 500 |

**HTTP surface.** `POST /api/operations` decodes an `{actor, command}` envelope and calls `dispatch`;
`GET /api/events` lists the journal. The client builds a `Command` in the operations console, posts
it, and on success refetches `GET /api/board` (+ `/api/events`) — reads being trivial.

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

## 7. Schema evolution (the centerpiece)

**v1 (`v1-wide`)** caches a `day_rate` on `allocation` — "so billing didn't have to join
`engineer_role × rate_card`." Every rate change or promotion therefore *fragments* allocation
history into adjacent rows that differ only by the cached rate.

**v2 (`v2-split`)** removes the cache (rate is derived from `engineer_role × rate_card`) and
**coalesces** the fragmented allocations back into whole engagements:

```sql
BEGIN;
CREATE TABLE allocation_v2 (LIKE allocation INCLUDING ALL);  -- without the day_rate column
ALTER TABLE allocation_v2 DROP COLUMN day_rate;

-- range_agg merges adjacent+overlapping periods, preserving genuine gaps;
-- grouping by fraction keeps a fraction change a real boundary, while a
-- rate-only change (not in the group key) is coalesced away.
INSERT INTO allocation_v2 (engineer_id, project_id, fraction, allocated_during)
SELECT engineer_id, project_id, fraction, unnest(range_agg(allocated_during))
FROM allocation
GROUP BY engineer_id, project_id, fraction;

DROP TABLE allocation;
ALTER TABLE allocation_v2 RENAME TO allocation;
COMMIT;
```

**The constraints validate the migration.** The new `WITHOUT OVERLAPS` PK and the PERIOD FKs reject
a bad transform *inside the transaction* — the database is the migration's test harness.

**The slider is the correctness oracle.** Charge rate in v1 is `allocation.day_rate`; in v2 it is
`engineer_role × rate_card`. The seed data is constructed so the cached rate always equalled the
rate card (it was a redundant cache), so for **every** date the board's project/client/fraction/rate
are identical before and after. Proven on stage by scrubbing across the migration boundary.

> Seed invariant: for every allocation row, `day_rate` == `rate_card[engineer_role.level]` for the
> overlapping period. The seed generator must guarantee this.

## 8. Migrations mechanism

- Numbered, hand-written SQL in `server/priv/migrations/` (`NNN_description.sql`), applied in order.
- `server/src/tempo/server/migrate.gleam` runs pending files in a transaction and records them in a
  `schema_migrations(version text primary key, applied_at timestamptz)` table.
- Git tags mark schema generations: `v1-wide`, `v2-split`. The presenter does
  `git checkout v2-split && gleam run -m tempo/migrate && <rebuild client>`. Squirrel-generated code
  and shared types are committed at each tag, so the checked-out tree is internally consistent.
- **Semantic period rename is done in place** in the existing migration files (`002`, `010`), *not*
  as a new migration layered on top (ADR-018). The oracle replays the migrations and runs the
  production board SQL, so a rename-on-top would run pre-rename generations against post-rename query
  text. The `v1-wide`/`v2-split` *git tags* are historical commits and stay untouched; `main` uses
  one consistent naming throughout.
- **Two seed paths.** The running app's clean-schema data is produced by replaying the operations
  seed (`seed.gleam`, ADR-023), which also populates the `event_log` with the founding history. The
  hand-written `003_seed.sql` is retained as the **v1 fixture for the migration oracle** (it seeds
  the wide schema that `010` coalesces), per ADR-024.

## 9. Build & run

```sh
# database (PG19): start the tempo-db container (from the repo root)
docker compose up -d                                # bin/db

# create + migrate + seed (Gleam server lives in server/, path-deps ../shared)
cd server && gleam run -m tempo/migrate             # bin/migrate

# regenerate typed SQL after schema changes
cd server && gleam run -m squirrel                  # bin/squirrel

# client bundle → ../server/priv/static (from the JS `client` package, ADR-014)
cd client && gleam run -m lustre/dev build client/app   # bin/build

# server (serves JSON API + static assets; from the server/ package)
cd server && gleam run                              # bin/serve
```

## 10. Testing

Layered — each guarantee verified at the cheapest level that can prove it. Layers 1–6 are Gleam and
follow strict TDD (`todo` stubs first, `assert expr == expected`, deterministic seed values).

**1. Temporal-constraint tests** (Gleam + pog against an ephemeral PG19). Prove the database, not the
app, enforces the rules. Each asserts the expected rejection or split, **and** that the rejection
classifies to the right typed `OperationError` (ADR-022):
  - `WITHOUT OVERLAPS` rejects an overlapping `allocation` for the same `(engineer, project)`.
  - PERIOD FKs reject: an `allocation`/`leave`/`engineer_role` extending past `employment`; an
    `allocation` outside its `project`; a `project` outside its `contract`; a `timesheet` against a
    project not allocated that day.
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

**3. Seed-equivalence test.** Replay the operations seed (`seed.gleam`) and assert the board matches a
reference snapshot across a dense date range — a mini-oracle that "seed-as-operations ≡ the intended
data," and incidentally exercises every operation end to end.

**4. As-of query tests.** Crafted seed + fixed dates → exact expected board / timesheet-form rows.

**5. Codec round-trip tests.** `encode |> decode == value` for every shared API type — including
`Command` and `Event` — pure Gleam, runs on both targets.

**6. Migration oracle** (retained, §7). Automates the on-stage claim:

```
seed v1  →  snapshot board for every date in a dense range  →  apply 010_split_allocation
         →  re-snapshot  →  assert equal for every date
```

Makes "history is provably intact" a CI gate, not a hope. Implemented as
`tempo/oracle` and run **in isolation** — `gleam run -m tempo/oracle` — because it
drops and rebuilds the `public` schema (a fresh v1 seed) and so cannot share the
`gleam test` DB. It samples every day of the seed span (2024-01-01 .. 2026-12-31)
and compares the *user-visible* board only (engineer/level/project/client/
fraction/rate); the engagement window `valid_from`/`valid_to` is deliberately
excluded because the coalesce is supposed to merge it (§7) and the client never
shows it. To stay faithful, the snapshot runs the production `board_as_of.sql`
text (no re-typed query) and renders each date's board NULL-tolerantly, handling
the employed-but-unallocated row. It exits non-zero (panics) on the first
differing date and leaves the DB at v2-split (same end state as
`gleam run -m tempo/migrate`).

**7. End-to-end (Playwright).** Drives the real app — Wisp serving the Lustre SPA against a
migrated+seeded PG19. **Behaviour-driven**: assert what the user sees, never CSS classes / ids / DOM
structure. One test per read beat *and* per operation beat (PRD §7, §9):
  - scrub to a date → expected engineers/projects/clients shown;
  - scrub across a seeded future promotion → level and charge rate increase;
  - scrub onto a leave period → engineer shows "On leave";
  - my timesheet: scrub to a day → only allocated projects offered; enter hours → reload → persisted;
  - negative: a rolled-off project is not offered;
  - perform an operation in the console (e.g. promote, revise the rate card, terminate) → the board
    re-renders to reflect it and the event-log panel shows the new entry.

**Schema-version-agnostic suite.** The Playwright suite is a behavioural contract that must be green
on **both** `v1-wide` and `v2-split`, *unmodified*. The v1 seed is the single source of truth; the
v2 state is produced by **running the migration on the v1 seed**, so "same suite, both tags" also
exercises the migration end-to-end and proves at the UI layer that observable behaviour is
unchanged. Because the tests assert only what the user sees, this holds by construction — never
assert on the denormalized rate source or any table shape that differs between versions. Playwright
is written and maintained continuously through development, not added at the end.

**Determinism.** Valid-time "now" is a fixed seed date, not the system clock; the seed uses explicit
names/dates/rates (no factory sequences in assertions), so every layer is reproducible.
`event_log.occurred_at` is the one real-clock column, so tests assert on operation/summary/payload,
never on the timestamp.

**Provisioning / CI.** Ephemeral PG19 per run (container / CI service). `.github/workflows/test.yml`
runs each step in its package's working directory: provision PG19 → `gleam test` (layers 1–4) in
`server/` → build the client in `client/` (bundle → `../server/priv/static`) → run the oracle in
`server/` → seed `v1-wide` and run `npx playwright test` in `e2e/` → apply the migration to that data
(`v2-split`) and run the **same** suite again. Both Playwright passes must be green.

## 11. Open spikes (resolve during planning)

1. **PG19 availability** on the talk machine (beta/RC or temporal-patched build).
2. **Squirrel ↔ `daterange` / `datemultirange`** mapping — confirm the `lower()/upper()`
   decomposition strategy compiles and round-trips.
3. **Squirrel ↔ `FOR PORTION OF`** — confirm PG can prepare the statement and Squirrel accepts it;
   fall back to a hand-written `pog` query for that one statement if not.
4. **Temporal upsert** — confirm the delete-then-insert (or supplemental unique index) approach for
   timesheet re-entry.
