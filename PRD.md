# Tempo — Product Requirements

An exploration of **temporal database design applied to web systems**, built on **PostgreSQL 19
native application-time tables** (SQL:2011 periods) through a software-consultancy staffing model,
with **Gleam, Squirrel, Wisp, and Lustre**.

> Re-baselined 2026-06-17. The original talk-first requirements are archived at
> `docs/archive/PRD-v1-conference-talk.md`. Rationale for the shift: `DECISIONS.md` ADR-017.

---

## 1. Context & motivation

PostgreSQL 19 makes **application time** a first-class, queryable axis in plain SQL: `WITHOUT
OVERLAPS` primary keys, `PERIOD` foreign keys, and `FOR PORTION OF` updates/deletes. Most temporal
demos stop at the *read* side — "scrub a slider, watch the board re-render as-of a date." That part
is genuinely valuable, but it is also the *easy* part: an as-of read is one predicate (`valid_at @>
$when`) threaded through a join.

The substance is on the **write** side. A temporal system does not `UPDATE` state; it records *facts
asserted true over a period*, and every business change is a careful temporal mutation — cap a fact,
assert a new one, split a period, cascade a closure. PG19's `FOR PORTION OF` expresses these
natively, and they are **unreachable through any ORM or query builder** — no vocabulary for periods,
range-overlap predicates, `FOR PORTION OF`, period-keyed splits, or `PERIOD` foreign keys. Tempo
exists to make that concrete: when you own your SQL (via Squirrel's typed codegen) you reach
capabilities the abstraction layer cannot express *at all*, while keeping type-safety from the
database column to the rendered pixel.

## 2. Audience & purpose

A study in temporal domain modeling that **doubles as a conference talk / live demo**. The priority
order changed (ADR-017): **model fidelity leads, the demo follows.** Where a modeling decision and a
talk-legibility decision conflict, modeling wins and the demo shifts to match. Legibility still
matters for the live views (large, obvious state changes; a slider scrubbed on stage).

## 3. The thesis (three threads)

1. **Time is queryable — and that part is trivial.** Record facts with validity periods, then ask
   the database what was true (or will be true) at any instant with a single period predicate. The
   org board "as of a date" is just a temporal join.
2. **The write cycle is where the modeling lives.** Business events — onboarding, promotion,
   allocation, roll-off, a rate-card revision, going on leave, offboarding — are modeled as
   **discrete operations**, each performing the correct native temporal mutation (`FOR PORTION OF`,
   period-keyed split, cascade) plus one provenance record, in a transaction. *Reading is trivial
   compared to the sophistication of the insert/update cycle.*
3. **You own your SQL.** Cutting-edge SQL the ORM can't express — `WITHOUT OVERLAPS`, `PERIOD` FKs,
   `FOR PORTION OF`, `range_agg` — *plus* end-to-end type-safety: `PG schema → Squirrel (typed rows)
   → shared types → JSON ⇄ → Lustre view`.

### The deeper frame: facts, not state

The CRUD/ORM worldview treats a row as the *current state* of an entity; `UPDATE` destroys the prior
state. Tempo treats a row as a **fact asserted true over a period**. You never destroy a fact — when
the world changes you **cap its validity** and **assert a new fact**. Three consequences shape the
whole design:

- **Decomposition is by rate-of-change, not functional dependency.** Two attributes of the same
  entity that change for different reasons at different times (an engineer's *name* vs. their
  *level*) must be separate fact tables, because a single validity period cannot honestly describe
  when each changed. This is effectively 6NF / anchor modeling / Datomic's datoms.
- **Identity shrinks to a durable referent.** Each entity is a surrogate key; everything that varies
  over time is a fact *about* it.
- **A correction is a retroactive change (§5).** In an application-time-only model there is no
  separate "correction" primitive — correcting a value is a change whose effective date reaches back
  over the fact's life. Covering the fact's whole span replaces it; the prior assertion is erased.

This corresponds philosophically to Event Sourcing (both record facts rather than mutate state) but
differs crucially: Event Sourcing stores an append-only event log and requires *projections* to
query relationships; temporal tables store the facts in **normalized, directly-queryable relational
form** and let you query *any point in time* with a period predicate. The database *is* the read
model.

## 4. Domain — Alembic consultancy staffing

Software engineers are allocated (fractionally) to projects; each project runs under a contract for a
client; engineers hold a level (L1–L7) that changes on promotion and drives a charge rate; they take
leave; and they log timesheets against the projects they are allocated to.

Every time-varying thing is a **narrow fact** with its own validity period, and each period is
**named for the predicate it asserts** (ADR-018) rather than a generic `valid_at`:

| fact | period column | the period means |
|---|---|---|
| `employment` | `employed_during` | the engineer is employed |
| `engineer_role` | `held_during` | the engineer holds a level |
| `rate_card` | `effective_during` | a level's day-rate is in effect |
| `contract` | `term` | the engagement's term |
| `project` | `active_during` | the project is active |
| `allocation` | `allocated_during` | the engineer is assigned to a project |
| `leave` | `on_leave_during` | the engineer is away |
| `timesheet` | `work_day` | the day worked |

(See `ARCHITECTURE.md` for the full schema.)

## 5. The two axes — application time vs. system time

Tempo is **application-time only** (valid time): the facts answer *"what is/was/will be true?"* It
deliberately does **not** add system-time/bitemporality, with one pragmatic addition:

- **Back-dating a fact erases the previously-held belief**, and that is accepted (ADR-021). A
  correction ≡ a retroactive change; the application-time tables cannot distinguish "the world
  changed" from "we recorded it wrong," and do not try to.
- **A single append-only `event_log` records system-time provenance *beside* the data** — who applied
  which operation, when (real clock), with what parameters. It answers *"what did we do, and when?"*
  but **not** *"what did we believe was true on date X?"* (that would require versioning every fact
  by system time — the bitemporal cost we are not paying). It is a provenance journal, not a
  reconstruction source, and it never constrains or contaminates the fact tables.

## 6. Perspectives (the views)

| View | Audience | Mode |
|---|---|---|
| **Org board** | staffing / PM | read-only — the whole company as-of a date |
| **My timesheet** | an engineer | read + write — scrub to a day, log hours |
| **Operations console** | admin / presenter | write — perform business operations live |
| **Event log** | admin / presenter | read-only — the system-time provenance journal |

The org board and timesheet share the single valid-time slider; the operations console drives the
write model; the event-log panel shows the provenance of every change.

## 7. Functional requirements

**Reads (the trivial side):**

- **FR-1 — As-of org board.** For any date the slider selects, show every employed engineer with
  their level, current project(s)/client(s), allocation fraction, and charge rate, computed *as of
  that date*.
- **FR-2 — Time travel.** The slider spans past → present → future; the board re-renders for any
  instant. Past dates show history; future dates show scheduled facts.
- **FR-4 — Leave precedence.** An engineer with a covering leave fact is shown "On leave"; their
  allocation persists but is suppressed in the view (overlapping facts resolved at read time).
- **FR-7 — Interactive timesheet.** Scrub to a day, see *my* allocations as of that day, enter hours
  per project, submit; the write is typed end-to-end and backstopped by the timesheet `PERIOD` FK.

**Writes (the substantial side):**

- **FR-9 — Domain operations.** A typed command vocabulary, exposed over HTTP and the operations
  console, each translating a business intent into the correct native temporal writes plus one
  `event_log` row, in a single transaction:
  - **Assert:** `onboard_engineer`, `sign_contract`, `start_project`, `assign_to_project`,
    `take_leave`, `log_timesheet`.
  - **Change** (cap-and-split via `FOR PORTION OF … FROM effective TO NULL`): `promote`,
    `change_allocation_fraction`, `revise_rate_card` — "publish a new version effective from a date."
  - **Surgical** (`FOR PORTION OF … FROM a TO b`): `adjust_rate_for_portion` — bump a level's rate for
    a bounded window, splitting the row into before/during/after.
  - **Close / cascade** (`DELETE … FOR PORTION OF`): `roll_off`; `terminate_employment`, which caps
    every contained fact (allocation → leave → role → employment, children first) — the PERIOD FKs
    both force the cascade and verify it is complete.
- **FR-3 — Future-dating.** A `promote` (or allocation/leave) with a future effective date activates
  on its own when the slider crosses that date — no job, no flag flip; level *and* charge rate step
  up.
- **FR-6 — Surgical rate edits.** `adjust_rate_for_portion` changes a level's rate for *part* of a
  period via `FOR PORTION OF`; only the affected sub-period changes.
- **FR-10 — Corrections as retroactive changes.** Any change accepts an arbitrary effective date,
  including retroactive. A change covering a fact's whole span replaces it (Postgres yields zero
  temporal leftovers and drops the prior row); no separate correction primitive exists.

**Integrity & provenance:**

- **FR-5 — Temporal integrity (enforced, not coded).** The database *rejects*: an allocation/leave/
  role that outlives employment; an allocation outside its project, or a project outside its
  contract's term; a timesheet against a project not allocated that day. Violations are *classified*
  into typed domain errors (ADR-022), never opaque 500s.
- **FR-11 — Event log / provenance.** Every operation appends exactly one append-only `event_log`
  row (`actor`, system-time `occurred_at`, `operation`, human `summary`, JSON `payload`), in the same
  transaction as its temporal writes, and is visible in the event-log panel. The granularity is one
  row per *operation*, not per fact-row touched.
- **FR-12 — Semantically-named validity periods.** Each fact's period is named for the predicate it
  asserts (§4), not a uniform `valid_at`.
- **FR-13 — Seed as operations.** The seed dataset is a replayed *sequence of operations*, so it
  exercises every operation and populates the event log with the founding history.

**Retained as a historical artifact:**

- **FR-8 — Schema-evolution example.** The versioned `v1-wide → v2-split` redesign (a denormalized
  `day_rate` cache coalesced away via `range_agg`, validated by the migration oracle) is **kept as
  is** but is no longer the sole centerpiece (ADR-024). New operations target the clean (v2)
  normalized schema where charge rate is derived from `engineer_role × rate_card`.

## 8. Honest limitations (stated plainly)

- **Application-time only.** Back-dating erases the previously-held belief; the `event_log` records
  *that* a change happened, not the world it replaced. Tempo cannot answer "what did the database
  *believe* on date X." A full fix is system-time/bitemporality (e.g. `pg_bitemporal`) — deliberately
  out of scope.
- **Change semantics are confined to the covering version.** An operation's `effective` date must
  fall within the fact currently in effect; corrections that *extend a fact earlier than its start*
  or rewrite across multiple fragmented rows are out of scope for the first cut of the operations
  layer.
- **"Fractions sum to ≤ 1.0 per day" is not expressible** via `WITHOUT OVERLAPS` (a sum over
  overlapping periods, not pairwise overlap); it still needs a trigger or application logic.
- **`FOR PORTION OF` through Squirrel is a load-bearing assumption.** Essentially the whole write
  layer routes through it; if Squirrel cannot introspect/prepare these statements, the fallback is
  hand-written `pog` queries for the write functions (reads stay Squirrel-typed). De-risked first in
  the implementation plan.

## 9. Testing & verification

Layered, each guarantee checked at the cheapest level that can prove it (detail in `ARCHITECTURE.md`):

1. **Temporal-constraint tests** — the DB rejects overlaps and every `PERIOD`-FK violation, and each
   rejection *classifies* to the right typed domain error (ADR-022).
2. **Operation tests** (the new core) — each operation applied to a known state, asserting the
   resulting facts *and* exactly one `event_log` row. Hard cases covered explicitly: `promote` splits
   the covering version yet preserves a scheduled future one; `terminate_employment` cascade-caps and
   is *rejected* when a timesheet outlives the end date; a retroactive `revise_rate_card` covering a
   whole fact erases the prior value; `adjust_rate_for_portion` three-way split.
3. **Seed-equivalence test** — the operation-built seed produces the expected board across a dense
   date range (a mini-oracle that "seed-as-operations ≡ the intended data").
4. **As-of query tests** — crafted seed + fixed dates → exact expected rows.
5. **Codec round-trip tests** — `encode |> decode == value` for every shared API type, including
   `Command` and `Event`.
6. **Migration oracle** — the retained `v1-wide → v2-split` property test (board equal for every
   date) stays green through the rename.
7. **End-to-end (Playwright)** — behaviour-driven: scrub the slider and assert what the user sees;
   *and* perform an operation in the UI and assert the board re-renders and the event-log panel shows
   the entry.

"Now" for **valid time** is a fixed seed date (not the system clock), so the slider and assertions
are deterministic. `event_log.occurred_at` is the one real-clock column and is therefore never
asserted on (tests assert operation/summary/payload).

## 10. Success criteria

- Every operation performs the correct native temporal writes, proven by the operation tests, and
  the board re-renders to reflect it; each operation leaves exactly one event-log row.
- A retroactive change replaces the prior assertion (zero leftovers); a cascade closure is rejected
  by the PERIOD FKs when incomplete.
- Changing a field in the `shared` types module (including `Command`/`Event`) breaks **both** server
  and client builds until reconciled.
- The migration oracle and the Playwright suite (slider beats *and* operation beats) pass in CI.
- The whole stack — schema, write/read queries, API, UI — is typed with no `dynamic` escapes outside
  the decode boundary.

## 11. Non-goals

- No authentication/authorization (the event-log `actor` is nominal).
- No system-time/bitemporal reconstruction (the honest limit; the event log is provenance only).
- No general migration framework — just enough runner for the demo.
- No timesheet approval workflow, reporting, or exports.
- No extend-earlier / multi-row corrections in the first cut of the operations layer (§8).

## 12. Dependencies & risks

- **PostgreSQL 19** (beta/RC or a build with the temporal patches) on the dev/talk machine. Squirrel
  introspects this instance at codegen time.
- **Squirrel ↔ `FOR PORTION OF`** — now load-bearing (§8); confirm PG can prepare the statements and
  Squirrel accepts them, with a hand-written `pog` fallback for the write layer. De-risked first.
- **Squirrel ↔ range types** — queries decompose ranges to `lower()/upper()` dates at the boundary
  (ADR-011); inputs are ranges built in SQL.
