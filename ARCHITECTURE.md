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
      server/                 #   Erlang target only
        router.gleam          #     Wisp routes
        context.gleam         #     pog connection pool
        board.gleam           #     as-of board handler
        timesheet.gleam       #     timesheet read + write handlers
        sql/                  #     Squirrel .sql sources → generated sql.gleam
        migrate.gleam         #     numbered-migration runner (gleam run -m tempo/migrate)
  test/                       #   layers 1–4 (constraint, oracle helpers, as-of, codec)
  priv/
    migrations/               #   001_init.sql, 002_facts.sql, 003_seed.sql, 010_split_allocation.sql
    static/                   #   compiled client bundle (app.js) + index.html + styles.css

shared/                       # package `shared` — BOTH targets, target-agnostic
  gleam.toml                  #   deps: gleam_stdlib, gleam_json only
  src/shared/
    types.gleam               #   domain/API types: BoardRow, BoardSnapshot, AsOf, …
    codecs.gleam              #   gleam/json encoders + gleam/dynamic/decode decoders

client/                       # package `client` — JavaScript target only
  gleam.toml                  #   deps: lustre, rsvp, gleam_json, gleam_time,
                              #     shared = { path = "../shared" }; dev: lustre_dev_tools
                              #   [tools.lustre.build] outdir = "../server/priv/static", no_html
  src/client/
    app.gleam                 #   Lustre model/update/view; the time slider; both views

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

Two **identity** tables (durable referents) and eight **fact** tables (each valid over a
`daterange valid_at`). This is effectively 6NF: one fact per relation.

```sql
-- Identity ------------------------------------------------------------------
CREATE TABLE engineer (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL);
CREATE TABLE client   (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL);

-- Facts ---------------------------------------------------------------------
CREATE TABLE employment (                       -- "engineer is employed"
  engineer_id int NOT NULL REFERENCES engineer(id),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS)
);

CREATE TABLE engineer_role (                    -- "engineer is at level L"; promotion = new row
  engineer_id int NOT NULL,
  level       int NOT NULL CHECK (level BETWEEN 1 AND 7),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at)
);

CREATE TABLE rate_card (                        -- L1–L7 charge rates, versioned over time
  level    int NOT NULL CHECK (level BETWEEN 1 AND 7),
  day_rate numeric(10,2) NOT NULL,
  valid_at daterange NOT NULL,
  PRIMARY KEY (level, valid_at WITHOUT OVERLAPS)  -- FOR PORTION OF target
);

CREATE TABLE contract (                         -- "client engagement", a term
  id        int NOT NULL,
  client_id int NOT NULL REFERENCES client(id),
  valid_at  daterange NOT NULL,
  PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
);

CREATE TABLE project (                          -- "project runs under a contract"  (project ⊂ contract)
  id          int NOT NULL,
  contract_id int NOT NULL,
  name        text NOT NULL,
  valid_at    daterange NOT NULL,
  PRIMARY KEY (id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (contract_id, PERIOD valid_at) REFERENCES contract (id, PERIOD valid_at)
);

CREATE TABLE allocation (                        -- "engineer on project" (fractional; ⊂ employment AND ⊂ project)
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  fraction    numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, project_id, valid_at WITHOUT OVERLAPS),  -- no overlap per engineer+project
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at),
  FOREIGN KEY (project_id,  PERIOD valid_at) REFERENCES project    (id,          PERIOD valid_at)
);

CREATE TABLE leave (                            -- "engineer on leave" (⊂ employment; overrides allocation)
  engineer_id int NOT NULL,
  kind        text NOT NULL,                    -- annual | sick | parental | …
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at)
);

CREATE TABLE timesheet (                        -- "hours logged"; a logged day must be covered by an allocation
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  work_day    daterange NOT NULL,               -- a single day [d, d+1)
  hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  PRIMARY KEY (engineer_id, project_id, work_day WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
    REFERENCES allocation (engineer_id, project_id, PERIOD valid_at)
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

All temporal columns are `daterange`; the as-of predicate is `valid_at @> $when::date`.

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
          lower(al.valid_at) AS valid_from, upper(al.valid_at) AS valid_to
   FROM employment emp
   JOIN engineer e       ON e.id = emp.engineer_id
   JOIN engineer_role rl ON rl.engineer_id = e.id  AND rl.valid_at @> $1::date
   JOIN rate_card rc     ON rc.level = rl.level     AND rc.valid_at @> $1::date
   JOIN allocation al    ON al.engineer_id = e.id   AND al.valid_at @> $1::date
   JOIN project pr       ON pr.id = al.project_id   AND pr.valid_at @> $1::date
   JOIN contract ct      ON ct.id = pr.contract_id  AND ct.valid_at @> $1::date
   JOIN client cl        ON cl.id = ct.client_id
   WHERE emp.valid_at @> $1::date
     AND NOT EXISTS (SELECT 1 FROM leave lv
                     WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date)
   ORDER BY e.name, pr.name;
   ```

2. `board_unassigned_as_of` — employed, **not** allocated and **not** on leave as of the
   date. `INNER JOIN engineer_role` keeps `level` non-null (an employed engineer always has
   a role in the seed). Returns just `(engineer, level)`. → `Unassigned`.

   ```sql
   SELECT e.name AS engineer, rl.level
   FROM employment emp
   JOIN engineer e       ON e.id = emp.engineer_id
   JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
   WHERE emp.valid_at @> $1::date
     AND NOT EXISTS (SELECT 1 FROM allocation al
                     WHERE al.engineer_id = e.id AND al.valid_at @> $1::date)
     AND NOT EXISTS (SELECT 1 FROM leave lv
                     WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date)
   ORDER BY e.name;
   ```

3. `board_leave_as_of` — exactly the engineers a covering `leave` fact hides from
   `board_as_of`. Leave overrides the engagement: the underlying allocation is deliberately
   not joined. The level is still resolved (for the charge story). Returns
   `(engineer, level, kind, valid_from, valid_to)`. → `OnLeave`.

   ```sql
   SELECT e.name AS engineer, rl.level, lv.kind,
          lower(lv.valid_at) AS valid_from, upper(lv.valid_at) AS valid_to
   FROM leave lv
   JOIN engineer e            ON e.id = lv.engineer_id
   LEFT JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
   WHERE lv.valid_at @> $1::date
   ORDER BY e.name;
   ```

Range columns are decomposed to plain `date`s at the boundary (ADR-011):
`lower(valid_at)`/`upper(valid_at)` AS `valid_from`/`valid_to`.

**Timesheet form — my allocations as of a day** (only projects I'm on; blank when on leave):

```sql
SELECT pr.id AS project_id, pr.name AS project, al.fraction,
       COALESCE(ts.hours, 0) AS hours
FROM allocation al
JOIN project pr ON pr.id = al.project_id AND pr.valid_at @> $2::date
LEFT JOIN timesheet ts ON ts.engineer_id = al.engineer_id
                      AND ts.project_id  = al.project_id
                      AND ts.work_day @> $2::date
WHERE al.engineer_id = $1 AND al.valid_at @> $2::date
  AND NOT EXISTS (SELECT 1 FROM leave lv
                  WHERE lv.engineer_id = $1 AND lv.valid_at @> $2::date);
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

## 6. Squirrel integration

- `.sql` query sources live in `server/src/tempo/server/sql/`; `cd server && gleam run -m squirrel`
  generates `sql.gleam` with one typed function per file (`bin/squirrel`).
- **Range boundary.** Squirrel maps the standard scalar types cleanly; to avoid relying on
  `daterange`/`datemultirange` mapping, queries **return** `lower(valid_at) AS valid_from` /
  `upper(valid_at) AS valid_to` (plain `date`) and **accept** ranges constructed in SQL
  (`daterange($from, $to, '[)')`). Shared types carry `valid_from` / `valid_to` as `date`s.
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
INSERT INTO allocation_v2 (engineer_id, project_id, fraction, valid_at)
SELECT engineer_id, project_id, fraction, unnest(range_agg(valid_at))
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

Layered — each guarantee verified at the cheapest level that can prove it. Layers 1–4 are Gleam and
follow strict TDD (`todo` stubs first, `assert expr == expected`, deterministic seed values).

**1. Temporal-constraint tests** (Gleam + pog against an ephemeral PG19). Prove the database, not the
app, enforces the rules. Each asserts the expected rejection or split:
  - `WITHOUT OVERLAPS` rejects an overlapping `allocation` for the same `(engineer, project)`.
  - PERIOD FKs reject: an `allocation`/`leave`/`engineer_role` extending past `employment`; an
    `allocation` outside its `project`; a `project` outside its `contract`; a `timesheet` against a
    project not allocated that day.
  - `FOR PORTION OF` splits a `rate_card` row into the expected before/during/after sub-periods.
  - `range_agg` coalescing produces the expected merged ranges (and preserves real gaps).

**2. Migration oracle** (the standout test). Automates the on-stage claim:

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

**3. As-of query tests.** Crafted seed + fixed dates → exact expected board / timesheet-form rows.

**4. Codec round-trip tests.** `encode |> decode == value` for every shared API type (pure Gleam,
runs on both targets).

**5. End-to-end (Playwright).** Drives the real app — Wisp serving the Lustre SPA against a
migrated+seeded PG19. **Behaviour-driven**: assert what the user sees, never CSS classes / ids / DOM
structure. One test per demo beat (PRD §7):
  - scrub to a date → expected engineers/projects/clients shown;
  - scrub across a seeded future promotion → level and charge rate increase;
  - scrub onto a leave period → engineer shows "On leave";
  - my timesheet: scrub to a day → only allocated projects offered; enter hours → reload → persisted;
  - negative: a rolled-off project is not offered.

**Schema-version-agnostic suite.** The Playwright suite is a behavioural contract that must be green
on **both** `v1-wide` and `v2-split`, *unmodified*. The v1 seed is the single source of truth; the
v2 state is produced by **running the migration on the v1 seed**, so "same suite, both tags" also
exercises the migration end-to-end and proves at the UI layer that observable behaviour is
unchanged. Because the tests assert only what the user sees, this holds by construction — never
assert on the denormalized rate source or any table shape that differs between versions. Playwright
is written and maintained continuously through development, not added at the end.

**Determinism.** "Now" is a fixed seed date, not the system clock; the seed uses explicit
names/dates/rates (no factory sequences in assertions), so every layer is reproducible.

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
