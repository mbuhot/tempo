# Tempo — Demo Run-book

The on-stage script for the PostgreSQL 19 temporal-tables talk. Maps the demo
beats below to **concrete actions** with the **exact seeded dates and engineers**,
so a fresh clone can reproduce the whole demo by following this file. The reads
(the org board and "My timesheet") show history-as-of a date; the writes run live
through the **operations console**, the **event-log panel**, and the **financials
view** in the UI, not only as raw SQL.

The live demo runs on the **final schema**. The earlier wide-allocation schema is
shown only briefly — the "before" picture and the migration reveal in **beat 6**.
Everything else is identical on both versions by construction (the board asserts
only what the user sees), so you do **not** switch versions except where beat 6
says to.

> Operational detail (env vars, the Playwright harness, the package layout) lives
> in `../README.md`.

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
  **`FOR PORTION OF`** home for beat 4. **L6** charges **$1,800/day**.
- **Aisha leave** annual **2026-06-08 .. 2026-06-22**.
- **Unassigned example**: scrub to **2024-06-01** → **Marcus is Unassigned**
  (employed, not yet on any project, not on leave); Priya is already on Ledger.

---

## Prerequisites

- **Docker** running (PG19 comes from the container; a local PG ≤ 18 will not work).
- **Gleam** (server is Erlang target; client is JS target) and **Node.js**
  (Playwright, only if you rehearse the e2e suite).
- **`psql`** on PATH — beat 4 and the migration reveal run raw SQL by hand.

The pool reads `TEMPO_DB_*` env vars (defaults match the compose file:
host 127.0.0.1, port 5434, db/user/password `tempo`). For a hand-run `psql`:

```sh
export PGPASSWORD=tempo
alias tempodb='psql -h 127.0.0.1 -p 5434 -U tempo -d tempo'
```

---

## One-time setup (talk-machine, clean checkout)

One command brings the whole stack up: it starts PG19 and waits for it, applies
any pending migrations (schema + seed), builds the Lustre client bundle, and
serves on **http://localhost:8000** (Ctrl-C stops the server; the DB container
keeps running). It is idempotent — safe to re-run.

```sh
bin/up
```

**For a clean dry run start from an empty database** — the migration runner is
forward-only and will not re-seed an already-migrated DB. Wipe and re-run:

```sh
docker compose down -v        # wipe the data volume (skip on the live machine if already clean)
bin/up                        # fresh PG19 → migrate → build → serve on :8000
```

Open **http://localhost:8000**. The page boots **"As of 2026-06-15"** with the
org board, the "My timesheet" panel, the operations console, the event log, and
the financials view below it.

On a freshly-migrated DB the financial screens are empty. To populate a demo set —
an issued Data Platform invoice (issued 2026-06-20), a draft Ledger invoice, and a
June payroll run — run on demand:

```sh
bin/seed-invoices             # demo financials via the real command.dispatch; idempotent, NOT run by bin/up
```

It is deliberately left out of `bin/up` so a freshly-migrated DB stays test-clean.
Because it pre-commits invoices the read tests do not expect, re-migrate
(`docker compose down -v && bin/up`) before running `gleam test`.

Smoke-check before going live (each must be green — actually observed, never assumed):

```sh
cd server && gleam test          # 129 Gleam tests (DB constraint + operations + as-of + financials + codec layers)   (bin/test)
cd e2e && npx playwright test    # 14 Playwright specs (board + timesheet + operations console + financials; needs the server running; see README)   (bin/e2e)
```

---

## The seven beats

The slider is the spine. Its `aria-label` is **"Board date"**; the heading
**"As of YYYY-MM-DD"** is your visible confirmation a scrub landed. Each board
line reads `‹Engineer› L‹n› — ‹engagement sentence›`, e.g.
`Marcus Chen L4 — Data Platform for Globex Corporation (100%, $1000/day)`.

### Beat 1 — Scrub the clock *(as-of + temporal join)*

Land on (or scrub to) **2026-06-15**. Read the board out loud — the whole company
as of one instant:

- **Priya Sharma — L5** — *Ledger Migration for Northwind Trading (50%, $1200/day)*
  **and** *Inventory Sync for Northwind Trading (50%, $1200/day)* (the fractional split).
- **Marcus Chen — L4** — *Data Platform for Globex Corporation (100%, $1000/day)*.
- **Aisha Okafor — L6** — *On leave: annual* (her Data Platform allocation is
  **suppressed** by the covering leave fact).

Then drag the slider left/right a little: the whole board re-renders per date —
hires appear, projects start, fractions split. One join, every date, no audit
tables.

### Beat 2 — Scrub into the future *(future-dating, role × rate-card)*

Watch **Marcus** as you cross **2026-07-01**:

- At **2026-06-15** he reads **L4** and **$1000/day**.
- Scrub to **2026-07-15** → he reads **L5** and **$1400/day**.

His `engineer_role` row (L4→L5) and the L5 `rate_card` row (1200→1400) both start
2026-07-01; crossing that date activates **both unaided** — no job, no flag flip.
The two-hop temporal join (`engineer_role × rate_card`) does the work. (Aisha is
also back from leave by 2026-07-15.)

### Beat 3 — Scrub the past *(history for free)*

Scrub **back to 2026-06-01** — *before* Aisha's leave window (2026-06-08..06-22):

- **Aisha Okafor — L6** now reads *Data Platform for Globex Corporation (100%, …)* —
  **not** "On leave". Her allocation was there all along; leave only overrode it
  during the window.

This is real history queried directly: same row, different truth at a different
instant, with no history tables.

### Beat 4 — `FOR PORTION OF` *(surgical rate edit)*

There is **no UI button** for an arbitrary sub-period rate edit at the `psql`
prompt — it is a raw SQL edit you run while the audience watches the slider react.
(The console's "Adjust rate for portion" operation does the same thing through a
typed command, but the hand-run SQL is the more visceral demo.) Bump the **L5**
rate to **$1,600 for a window inside H2-2026** so PG **splits the rate-card row**
into before / during / after (more dramatic than aligning to the existing
boundary):

```sh
tempodb -c "UPDATE rate_card
              FOR PORTION OF effective_during FROM '2026-09-01'::date TO '2026-11-01'::date
              SET day_rate = 1600
            WHERE level = 5;"
```

Show the split:

```sh
tempodb -c "SELECT level, day_rate, lower(effective_during) AS from, upper(effective_during) AS to
            FROM rate_card WHERE level = 5 ORDER BY effective_during;"
-- L5 was [2026-07-01,2027-01-01)=1400; now: …07-01..09-01=1400, 09-01..11-01=1600, 11-01..2027=1400
```

Back in the browser, scrub across the boundaries (refresh so the board re-fetches):

- **2026-10-01** (inside the window) → Priya's rate reads **$1600/day**.
- **2026-08-01** or **2026-12-01** (outside) → back to **$1400/day**.

Only that sub-period changed; the row split itself. **Undo afterward** so the seed
is pristine for a re-run:

```sh
tempodb -c "UPDATE rate_card
              FOR PORTION OF effective_during FROM '2026-09-01'::date TO '2026-11-01'::date
              SET day_rate = 1400
            WHERE level = 5;"
-- (the adjacent 1400 rows re-merge on the next FOR PORTION OF / coalesce; or just
--  re-run one-time setup against a fresh DB if you prefer a guaranteed-clean board)
```

> If you prefer a no-residue demo, wrap the edit in a transaction and `ROLLBACK`:
> `tempodb` then `BEGIN; UPDATE … FOR PORTION OF …; \echo show; ROLLBACK;`.

### Beat 5 — My timesheet *(interactive write + integrity)*

In the **My timesheet** panel: set the **Engineer** select to **Priya Sharma** and
scrub to **last Tuesday, 2026-06-09** ("Logging for 2026-06-09" confirms it):

- Exactly her **two half-time projects** appear: **Ledger Migration (50%)** and
  **Inventory Sync (50%)**, each pre-filled in its **Hours for …** input with the
  **4** hours already on record.
- **Data Platform is not offered** — she is not allocated to it.

Now the negative beat (the DB would refuse a project she has rolled off). Scrub
Priya back to **2025-01-15** — *before* Inventory Sync begins (2025-06-01):

- Only **Ledger Migration (50%)** is offered; **Inventory Sync is gone**. The form
  only surfaces projects the day's allocations cover.

Optionally show a live write: select **Marcus Chen**, scrub to **2026-06-10**
(0 logged), type **6** into **Hours for Data Platform**, click **Save Data
Platform** → "Saved."; reload → the value persists (committed, not client-held).
The write is backstopped by the timesheet `PERIOD` FK to `allocation` — logging a
day with no covering allocation is rejected at the database. *(Restore the seed
afterward if you ran the write:* `tempodb -c "DELETE FROM timesheet WHERE engineer_id=2 AND project_id=300 AND work_day @> '2026-06-10'::date;"`*.)*

### Beat 6 — The redesign *(schema evolution, proven)*

This is the climax. The live app is already on the **final (split-allocation)
schema**; you reveal the *before* on the wide-allocation version, then re-apply
forward and show parity.

> **Do the git checkouts yourself at the podium** — this run-book intentionally
> does not perform them (the rest of the working tree must stay on `main`).

1. **Show the "before".** From a clean checkout, on a **fresh DB**, check out the
   wide-allocation tag, then:
   ```sh
   docker compose down -v && docker compose up -d   # wipe + fresh PG19
   cd server && gleam run -m tempo/migrate                     # schema + seed → wide-allocation
   cd client && gleam run -m lustre/dev build client/app
   cd server && gleam run                                      # serve the "before"
   ```
   Show `allocation` carries the denormalized **`day_rate`** cache and history is
   **fragmented** (adjacent rows differ only by the cached rate):
   ```sh
   tempodb -c "SELECT engineer_id, project_id, fraction, day_rate,
                      lower(allocated_during) AS from, upper(allocated_during) AS to
               FROM allocation ORDER BY engineer_id, project_id, allocated_during;"
   ```
   Note the board still reads identically to beat 1 (rate is the same number,
   just sourced from the cache).

2. **Apply the migration → the "after".** Check out the split-allocation version,
   then:
   ```sh
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
                      lower(allocated_during) AS from, upper(allocated_during) AS to
               FROM allocation ORDER BY engineer_id, project_id, allocated_during;"
   -- no day_rate column; Marcus's two fragments merged into one 2025-01-01..2027-01-01 row
   ```

3. **Re-scrub the same dates** (2026-06-15, 2026-07-15, 2026-06-01, 2024-06-01) →
   **the board is identical**. "I restructured the schema and history is
   *provably* intact."

4. **The proof, not the hope.** The migration validates itself **inside the
   transaction**: the new `WITHOUT OVERLAPS` PK and the `PERIOD` FKs reject a bad
   coalesce and roll the whole file back, so a migration that commits is one whose
   history is intact. And the **read-model Playwright specs** (slider/board +
   timesheet) pass unmodified on both versions — the same `2026-06-15 / 2026-07-15
   / 2026-06-01 / 2024-06-01` assertions hold before and after (the operations-
   console and financials specs target the final schema only). "I restructured the
   schema and history is *provably* intact."

> **Return to `main` after the talk:** `git checkout main`. The git tags and
> history are never modified by this demo.

### Beat 7 — Operations console + financials *(live writes, integrity, money)*

Everything so far has been reads (plus one timesheet write). The operations
console and the financials view drive **business writes** through the same typed
command path, and you watch the board, event log, and P&L react.

#### 7a — The operations console

The **Operations console** is a named region. Pick an operation in the
**Operation** select, fill the fields it reveals, and click **Apply operation**.
Entity-reference fields are **name `<select>`s** sourced from `GET
/api/roster?as_of=<slider date>` — you pick the **Engineer**, **Project**, and
**Level** by name (the roster offers only engineers employed and projects active
on the slider date, refetched as the slider moves), never by typing ids. The
console offers eight operations: Onboard engineer, Promote, Assign to project,
Roll off project, Revise rate card, Adjust rate for portion, Take leave, and
Terminate employment.

Show a **promote** that the board reflects immediately:

- Scrub to **2026-06-15**. Priya reads **L5 … $1200/day** on her Ledger line.
- In the console: **Operation = Promote**, **Engineer = Priya Sharma**, **Level =
  L6**, **Effective = 2026-06-01**, then **Apply operation**.
- The board refetches for the current date and now reads **Priya Sharma — L6 …
  $1800/day** (the L6 rate). The **Event log** panel gains the entry *"Promote
  engineer 1 to L6 from 2026-06-01"* (newest-first).

Then show **integrity surfaced to the user** — a write the database refuses:

- **Operation = Assign to project**, **Engineer = Aisha Okafor** (employed only
  from 2025-01-01), **Project = Ledger Migration**, **Fraction = 0.5**, **Valid
  from = 2024-01-01**, **Valid to = 2024-06-01**, then **Apply operation**.
- The allocation would dangle outside Aisha's employment, so the containment
  `PERIOD` FK fires. The console shows a clear **"Rejected: …"** line naming the
  containment rule that fired; the board is **unchanged** and the event log stays
  empty. Not a crash, not a silent success.

*(Restore the seed after the promote: delete engineer 1's role rows, re-insert the
single seeded L5 span, and clear the journal — see `e2e/operations.spec.js`'s
cleanup for the exact SQL, or just `docker compose down -v && bin/up`.)*

#### 7b — The financials view

Run **`bin/seed-invoices`** first if you want pre-populated data, or draft live in
the UI. The **Financials** panel reads everything **as of the slider date**.

- **Invoices** — the **Project** select + **Draft invoice** button drafts an
  invoice for the slider's month at the contract-agreed rates. The drafted row
  shows the client, the billed **total**, a **status**, and the action for that
  status. An invoice walks **draft → issued → paid**: the **Issue** button on a
  `draft` row transitions it to `issued` at the slider date, then **Pay** moves it
  to `paid`. Because status is a temporal fact, scrubbing the slider *before* the
  issue date shows the same invoice as `draft` again.
- **Payroll** — **Run payroll for ‹month›** runs the slider month's payroll.
- **Profit & loss** — the P&L table breaks out **Revenue / Cost / Profit** for the
  slider's month (revenue is recognized on **issue**: an issued invoice's total
  lands in the month's Revenue; a draft does not).

The standout chain: draft Data Platform's June invoice, watch **$84,000** appear
in `draft` with **$0** P&L revenue, click **Issue**, and watch that **$84,000**
move into the month's **Revenue** — money flowing through the same as-of join.

---

## Dry-run checklist (run this before the talk)

Observed-green on the talk machine — do not assume:

- [ ] `docker compose down -v` then `bin/up` → DB healthy on 5434, migrations applied, client built, server on :8000.
- [ ] Page loads **"As of 2026-06-15"** with all three engineers, the timesheet, the console, the event log, and the financials view.
- [ ] Beats 1–3 read as written above (scrub the dates, eyeball the sentences).
- [ ] Beat 4 SQL runs and the slider shows $1600 inside / $1400 outside the window; undo restores it.
- [ ] Beat 5: Priya's two projects + 4h on 2026-06-09; Inventory gone at 2025-01-15; optional Marcus write persists across reload.
- [ ] Beat 6 checkout/migrate/rebuild sequence rehearsed end to end on a fresh DB; boards match across versions.
- [ ] Beat 7a console: a **Promote** re-renders the board to the new level/rate and the event log gains the entry; a containment-violating **Assign to project** shows a clear "Rejected: …" reason and leaves the board unchanged.
- [ ] Beat 7b financials (`bin/seed-invoices` or live): an invoice walks draft → issued → paid; an issued invoice's total appears in the month's P&L **Revenue**; payroll runs.
- [ ] `cd server && gleam test` (`bin/test`, 129 pass), `cd e2e && npx playwright test` (`bin/e2e`, 14 pass).
- [ ] Back on `main`, DB freshly seeded, page re-loaded clean.
