# Tempo — Demo Run-book

The on-stage script for the PostgreSQL 19 temporal-tables talk. Maps each of the
seven PRD §7 beats to **concrete actions** with the **exact seeded dates and
engineers**, so a fresh clone can reproduce the whole demo by following this file.

The live demo runs on **`v2-split`** (the final schema). `v1-wide` is shown only
briefly — the "before" picture and the migration reveal in **beat 6**. Everything
else is identical on both tags by construction (the board asserts only what the
user sees), so you do **not** switch tags except where beat 6 says to.

> Background: `PRD.md` (§7 beats, §9 success criteria), `ARCHITECTURE.md` (§5
> queries, §7 migration, §10 testing), `DECISIONS.md` (ADR-006/007/013).
> Operational detail (env vars, oracle, Playwright) lives in `README.md`.

---

## The fixed clock and the cast

Nothing here uses the wall clock. The seed pins **"now" = 2026-06-15**
(`server/priv/migrations/003_seed.sql`); the slider, the board, and every test anchor to
it. The slider spans **2024-01-01 → 2026-12-31** (the seed range; the open upper
bound 2027-01-01 makes 2026-12-31 the last selectable day).

| Engineer | Level | Notes used on stage |
|---|---|---|
| **Priya Sharma** (id 1) | L5 throughout | The fractional split: **50% Ledger Migration + 50% Inventory Sync**. Logged 4h on each on Tue **2026-06-09**. |
| **Marcus Chen** (id 2) | L4 → **L5 on 2026-07-01** | The future-dated **promotion**. Employed from 2024-06-01 but **Unassigned until 2025-01-01** (joins Data Platform). |
| **Aisha Okafor** (id 3) | L6 throughout | On **annual leave 2026-06-08 .. 2026-06-22** (covers "now"), full-time on Data Platform otherwise. |

| Client | Projects | Runs |
|---|---|---|
| Northwind Trading | Ledger Migration (id 100), Inventory Sync (id 200) | Ledger 2024-01-01+; Inventory **from 2025-06-01** |
| Globex Corporation | Data Platform (id 300) | from 2025-01-01 |

Key dated facts:
- **Marcus promotion** L4→L5 at **2026-07-01** (his own role row flips unaided).
- **L5 rate card** steps **$1,200 → $1,400 at 2026-07-01**; L5 is also the
  **`FOR PORTION OF`** home for beat 4.
- **Aisha leave** annual **2026-06-08 .. 2026-06-22**.
- **Unassigned example**: scrub to **2024-06-01** → **Marcus is Unassigned**
  (employed, not yet on any project, not on leave); Priya is already on Ledger.

---

## Prerequisites

- **Docker** running (PG19 comes from the container; a local PG ≤ 18 will not work).
- **Gleam** (server is Erlang target; client is JS target) and **Node.js**
  (Playwright, only if you rehearse the e2e suite).
- **`psql`** on PATH — beat 4 and the migration reveal run raw SQL by hand.

```sh
docker compose up -d        # PostgreSQL 19beta1 on host port 5434 (db/user/pass: tempo)
```

The pool reads `TEMPO_DB_*` env vars (defaults match the compose file:
host 127.0.0.1, port 5434, db/user/password `tempo`). For a hand-run `psql`:

```sh
export PGPASSWORD=tempo
alias tempodb='psql -h 127.0.0.1 -p 5434 -U tempo -d tempo'
```

---

## One-time setup (talk-machine, clean checkout)

Run from the repo root, on `main` (= the `v2-split` state). The Gleam server lives
in `server/` (path-depends on `../shared`); the client is built from `client/`; the
Playwright harness lives in `e2e/`. Thin `bin/` wrappers at the repo root `cd` into
the right package for each step. **For a clean dry run start from an empty database**
— the migration runner is forward-only and will not re-seed an already-migrated DB:

```sh
docker compose down -v && docker compose up -d   # wipe + fresh PG19 (skip the -v on the live machine if already seeded clean)

cd server && gleam run -m tempo/migrate           # schema 001-003 (+ 010 on main) + the v1 seed   (bin/migrate)
cd client && gleam run -m lustre/dev build client/app   # build the SPA bundle → ../server/priv/static   (bin/build)
cd server && gleam run                            # serve API + static assets on http://127.0.0.1:8000   (bin/serve)
```

Open **http://127.0.0.1:8000**. The page boots **"As of 2026-06-15"** with the
org board and the "My timesheet" panel below it.

Smoke-check before going live (each must be green — actually observed, never assumed):

```sh
cd server && gleam test          # 52 unit tests (DB constraint + as-of + codec layers)   (bin/test)
cd server && gleam run -m tempo/oracle   # migration oracle: board identical for every date v1→v2 (leaves DB at v2-split)   (bin/oracle)
cd e2e && npx playwright test    # 10 e2e specs, one per beat (needs the server running; see README)   (bin/e2e)
```

> The oracle **rebuilds the public schema to a fresh v1 seed and ends at
> v2-split**. If you run it during prep, you are back at the demo state
> afterwards. If you run it and then want a pristine board, re-do the
> one-time-setup `migrate` is unnecessary (it already ends seeded at v2).

---

## The seven beats

The slider is the spine. Its `aria-label` is **"Board date"**; the heading
**"As of YYYY-MM-DD"** is your visible confirmation a scrub landed. Each board
line reads `‹Engineer› L‹n› — ‹engagement sentence›`, e.g.
`Marcus Chen L4 — Data Platform for Globex Corporation (100%, $1000/day)`.

### Beat 1 — Scrub the clock *(FR-1, FR-2; as-of + temporal join)*

Land on (or scrub to) **2026-06-15**. Read the board out loud — the whole company
as of one instant:

- **Priya Sharma — L5** — *Ledger Migration for Northwind Trading (50%, $1200/day)*
  **and** *Inventory Sync for Northwind Trading (50%, $1200/day)* (the fractional split).
- **Marcus Chen — L4** — *Data Platform for Globex Corporation (100%, $1000/day)*.
- **Aisha Okafor — L6** — *On leave: annual* (her Data Platform allocation is
  **suppressed** by the covering leave fact; FR-4).

Then drag the slider left/right a little: the whole board re-renders per date —
hires appear, projects start, fractions split. One join, every date, no audit
tables.

### Beat 2 — Scrub into the future *(FR-3; future-dating, role × rate-card)*

Watch **Marcus** as you cross **2026-07-01**:

- At **2026-06-15** he reads **L4** and **$1000/day**.
- Scrub to **2026-07-15** → he reads **L5** and **$1400/day**.

His `engineer_role` row (L4→L5) and the L5 `rate_card` row (1200→1400) both start
2026-07-01; crossing that date activates **both unaided** — no job, no flag flip.
The two-hop temporal join (`engineer_role × rate_card`, ADR-009) does the work.
(Aisha is also back from leave by 2026-07-15.)

### Beat 3 — Scrub the past *(FR-2; history for free)*

Scrub **back to 2026-06-01** — *before* Aisha's leave window (2026-06-08..06-22):

- **Aisha Okafor — L6** now reads *Data Platform for Globex Corporation (100%, …)* —
  **not** "On leave". Her allocation was there all along; leave only overrode it
  during the window.

This is real history queried directly: same row, different truth at a different
instant, with no history tables.

### Beat 4 — `FOR PORTION OF` *(FR-6; surgical rate edit)*

There is **no UI button** for this — it is a raw SQL edit you run at the `psql`
prompt while the audience watches the slider react. Bump the **L5** rate to
**$1,600 for a window inside H2-2026** so PG **splits the rate-card row** into
before / during / after (more dramatic than aligning to the existing boundary):

```sh
tempodb -c "UPDATE rate_card
              FOR PORTION OF valid_at FROM '2026-09-01'::date TO '2026-11-01'::date
              SET day_rate = 1600
            WHERE level = 5;"
```

Show the split:

```sh
tempodb -c "SELECT level, day_rate, lower(valid_at) AS from, upper(valid_at) AS to
            FROM rate_card WHERE level = 5 ORDER BY valid_at;"
-- L5 was [2026-07-01,2027-01-01)=1400; now: …07-01..09-01=1400, 09-01..11-01=1600, 11-01..2027=1400
```

Back in the browser, scrub across the boundaries (refresh so the board re-fetches):

- **2026-10-01** (inside the window) → Priya's rate reads **$1600/day**.
- **2026-08-01** or **2026-12-01** (outside) → back to **$1400/day**.

Only that sub-period changed; the row split itself. **Undo afterward** so the seed
is pristine for a re-run:

```sh
tempodb -c "UPDATE rate_card
              FOR PORTION OF valid_at FROM '2026-09-01'::date TO '2026-11-01'::date
              SET day_rate = 1400
            WHERE level = 5;"
-- (the adjacent 1400 rows re-merge on the next FOR PORTION OF / coalesce; or just
--  re-run one-time setup against a fresh DB if you prefer a guaranteed-clean board)
```

> If you prefer a no-residue demo, wrap the edit in a transaction and `ROLLBACK`:
> `tempodb` then `BEGIN; UPDATE … FOR PORTION OF …; \echo show; ROLLBACK;`.

### Beat 5 — My timesheet *(FR-7, FR-5; interactive write + integrity)*

In the **My timesheet** panel: set the **Engineer** dropdown to **Priya Sharma**
and scrub to **last Tuesday, 2026-06-09** ("Logging for 2026-06-09" confirms it):

- Exactly her **two half-time projects** appear: **Ledger Migration (50%)** and
  **Inventory Sync (50%)**, each pre-filled with the **4** hours already on record.
- **Data Platform is not offered** — she is not allocated to it.

Now the negative beat (the DB would refuse a project she has rolled off). Scrub
Priya back to **2025-01-15** — *before* Inventory Sync begins (2025-06-01):

- Only **Ledger Migration (50%)** is offered; **Inventory Sync is gone**. The form
  only surfaces projects the day's allocations cover.

Optionally show a live write: select **Marcus Chen**, scrub to **2026-06-10**
(0 logged), type **6.5** into Data Platform, **Save Data Platform** → "Saved.";
reload → the value persists (committed, not client-held). The write is backstopped
by the timesheet `PERIOD` FK to `allocation` — logging a day with no covering
allocation is rejected at the database. *(Restore the seed afterward if you ran
the write:* `tempodb -c "DELETE FROM timesheet WHERE engineer_id=2 AND project_id=300 AND work_day @> '2026-06-10'::date;"`*.)*

### Beat 6 — The redesign *(FR-8; schema evolution, proven)*

This is the climax. The live app is already on **`v2-split`**; you reveal the
*before* on `v1-wide`, then re-apply forward and show parity.

> **Do the git checkouts yourself at the podium** — this run-book intentionally
> does not perform them (the rest of the working tree must stay on `main`).

1. **Show the "before".** From a clean checkout, on a **fresh DB**:
   ```sh
   git checkout v1-wide
   docker compose down -v && docker compose up -d
   cd server && gleam run -m tempo/migrate                     # 001-003 only → v1-wide schema + seed
   cd client && gleam run -m lustre/dev build client/app
   cd server && gleam run                                      # serve v1-wide
   ```
   Show `allocation` carries the denormalized **`day_rate`** cache and history is
   **fragmented** (adjacent rows differ only by the cached rate):
   ```sh
   tempodb -c "SELECT engineer_id, project_id, fraction, day_rate,
                      lower(valid_at) AS from, upper(valid_at) AS to
               FROM allocation ORDER BY engineer_id, project_id, valid_at;"
   ```
   Note the board still reads identically to beat 1 (rate is the same number,
   just sourced from the cache).

2. **Apply the migration → the "after".**
   ```sh
   git checkout v2-split
   cd server && gleam run -m tempo/migrate                     # applies 010_split_allocation forward
   cd client && gleam run -m lustre/dev build client/app
   cd server && gleam run
   ```
   `010_split_allocation.sql` **drops the `day_rate` cache** and **coalesces** the
   fragmented allocations into whole engagements with `range_agg` (rate is now
   derived from `engineer_role × rate_card`). The new `WITHOUT OVERLAPS` PK and
   the `PERIOD` FKs **validate the transform inside the transaction** — a bad
   coalesce would roll the whole file back. Show the slimmer, coalesced table:
   ```sh
   tempodb -c "SELECT engineer_id, project_id, fraction,
                      lower(valid_at) AS from, upper(valid_at) AS to
               FROM allocation ORDER BY engineer_id, project_id, valid_at;"
   -- no day_rate column; Marcus's two fragments merged into one 2025-01-01..2027-01-01 row
   ```

3. **Re-scrub the same dates** (2026-06-15, 2026-07-15, 2026-06-01, 2024-06-01) →
   **the board is identical**. "I restructured the schema and history is
   *provably* intact."

4. **The proof, not the hope.** Note that the **migration oracle** asserts this
   board parity for **every day** of the seed span (2024-01-01..2026-12-31) in CI,
   and the **same Playwright suite** passes unmodified on both tags:
   ```sh
   cd server && gleam run -m tempo/oracle   # exits 0; board equal for every date v1→v2 (ends at v2-split)
   ```

> **Return to `main` after the talk:** `git checkout main` (= the `v2-split`
> state). The git tags and history are never modified by this demo.

### Beat 7 — The thesis *(§3; type-safe column → pixel)*

Show the one chain that no ORM can express *and* keep typed end to end:

1. **The Squirrel query** — `server/src/tempo/server/sql/board_as_of.sql` — the engaged
   as-of board: `INNER JOIN`s through `allocation → project → contract → client`
   and `engineer_role × rate_card`, with `valid_at @> $1::date` as the as-of
   predicate. None of `WITHOUT OVERLAPS`, `PERIOD` FK, `FOR PORTION OF`, or
   `range_agg` (beats 1–6) is reachable from any ORM/query builder.
2. **The shared type it feeds** — `shared/src/shared/types.gleam`: `BoardRow` and
   the `Engagement` sum (`OnProject` / `Unassigned` / `OnLeave`), with the JSON
   codecs in `shared/src/shared/codecs.gleam`. This module compiles to **both**
   targets and is the single API contract.
3. **The pixel** — `client/src/client/app.gleam` renders that exact type into the
   board line you have been reading all demo.

Make the point concrete: change a field in `shared/src/shared/types.gleam` and
**both** the server (Erlang) and client (JS) builds fail until reconciled — the
contract is enforced by the compiler. Types hold from the database column to the
rendered pixel; the SQL is cutting-edge and **you own it**.

---

## Dry-run checklist (run this before the talk)

Observed-green on the talk machine — do not assume:

- [ ] `docker compose up -d` (or `bin/db`) → `tempo-db` healthy on 5434.
- [ ] `cd server && gleam run -m tempo/migrate` (`bin/migrate`) → applies cleanly (fresh DB).
- [ ] `cd client && gleam run -m lustre/dev build client/app` (`bin/build`) → "Bundle successfully built."
- [ ] `cd server && gleam run` (`bin/serve`) → page loads "As of 2026-06-15" with all three engineers.
- [ ] Beats 1–5 read as written above (scrub the dates, eyeball the sentences).
- [ ] Beat 4 SQL runs and the slider shows $1600 inside / $1400 outside the window; undo restores it.
- [ ] Beat 6 checkout/migrate/rebuild sequence rehearsed end to end on a fresh DB; boards match.
- [ ] `cd server && gleam test` (`bin/test`, 52 pass), `cd server && gleam run -m tempo/oracle` (`bin/oracle`, PASS), `cd e2e && npx playwright test` (`bin/e2e`, 10 pass).
- [ ] Back on `main`, DB at v2-split, page re-loaded clean.
