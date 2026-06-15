# Tempo — Product Requirements

A live-demo application that showcases **PostgreSQL 19 native temporal tables** (SQL:2011
application-time periods) through a software-consultancy staffing model, built with **Gleam,
Squirrel, Wisp, and Lustre**.

---

## 1. Context & motivation

PostgreSQL 19 adds native **application-time period** support: `WITHOUT OVERLAPS` primary keys,
`PERIOD` foreign keys, and `FOR PORTION OF` updates. For the first time, *time becomes a
first-class, queryable axis* in plain SQL — no audit tables, no trigger-maintained history, no
"effective date" columns filtered by hand.

These features are **unreachable through any ORM or query builder** — they have no vocabulary for
periods, range-overlap predicates, `FOR PORTION OF`, or `PERIOD` foreign keys. Tempo exists to make
that concrete: when you own your SQL (via Squirrel's typed codegen), you reach capabilities the
abstraction layer cannot express *at all*, while keeping type-safety from the database column to the
rendered pixel.

## 2. Audience & purpose

A **conference talk / live demo**. Every decision optimizes for:

- **Legibility from the back of the room** — large, obvious state changes.
- **A visual spine** — a *time slider* the presenter scrubs; the whole view re-renders "as of" that
  instant, past, present, or future.
- **An intellectual climax** — a schema redesign whose correctness is *proven on stage*.

## 3. The thesis (two threads)

1. **Time is queryable.** Record *facts with validity periods*, then ask the database what was true
   (or will be true) at any instant — directly, in SQL.
2. **You own your SQL.** Cutting-edge SQL the ORM can't express, *plus* end-to-end type-safety:
   `PG schema → Squirrel (typed rows) → shared types → JSON ⇄ → Lustre view`.

### The deeper frame: facts, not state

The CRUD/ORM worldview treats a row as the *current state* of an entity; `UPDATE` destroys the
prior state. Tempo treats a row as a **fact asserted true over a period**. You never destroy a
fact — when the world changes you **cap its validity** and **assert a new fact**. The database
accumulates truth instead of overwriting it.

This corresponds philosophically to Event Sourcing (both record facts rather than mutate state) but
differs crucially: Event Sourcing stores an append-only event log and requires *projections* to
query relationships; temporal tables store the facts in **normalized, directly-queryable relational
form** and let you query *any point in time* with a period predicate. The database *is* the read
model. Lineage: 6th Normal Form / anchor modeling / Datomic's datoms.

## 4. Domain — Alembic consultancy staffing

Software engineers are allocated (fractionally) to projects; each project runs under a contract for
a client; engineers hold a level (L1–L7) that changes on promotion and drives a charge rate; they
take leave; and they log timesheets against the projects they are allocated to.

Every time-varying thing is a **narrow fact** with its own validity period (see `ARCHITECTURE.md`
for the schema).

## 5. Perspectives (the two views)

| View | Audience | Mode |
|---|---|---|
| **Org board** | staffing / PM | read-only — the whole company as-of a date |
| **My timesheet** | an engineer | read + write — scrub to a day, log hours |

Both share the single time slider.

## 6. Functional requirements

- **FR-1 — As-of org board.** For any date the slider selects, show every employed engineer with
  their level, current project(s) and client(s), allocation fraction, and charge rate, computed
  *as of that date*.
- **FR-2 — Time travel.** The slider spans past → present → future; the board re-renders for any
  instant. Past dates show history; future dates show scheduled facts.
- **FR-3 — Future-dated changes.** A promotion (and any allocation/leave) seeded with a future
  start activates on its own when the slider crosses its start date — no job, no flag flip. The
  engineer's level *and* charge rate step up.
- **FR-4 — Leave precedence.** An engineer with a leave fact covering the selected date is shown as
  "On leave"; their underlying allocation persists but is suppressed in the view. (Overlapping facts
  resolved at read time.)
- **FR-5 — Temporal integrity (enforced, not coded).** The database *rejects*:
  - an allocation or leave that outlives the engineer's employment (employment ends ⇒ associations
    end);
  - an allocation outside its project's run, or a project outside its contract's term;
  - a timesheet logged against a project the engineer is not allocated to on that day.
- **FR-6 — Surgical rate edits.** Bump a level's charge rate for *part* of a year via
  `FOR PORTION OF`; the rate-card row splits automatically; only the affected sub-period changes.
- **FR-7 — Interactive timesheet.** Scrub to a day, see *my* allocations as of that day (only
  projects I'm actually on, with fractions), enter hours per project, and submit. The write is typed
  end-to-end and backstopped by the timesheet `PERIOD` foreign key.
- **FR-8 — Schema-evolution centerpiece.** A versioned schema redesign (git tag `v1-wide` →
  `v2-split`) decomposes a denormalized table into narrow facts via temporal **coalescing**
  (`range_agg`). The migration is validated by the new constraints *inside its transaction*, and the
  slider proves the board is **identical for every date** before and after. (See "slider as oracle"
  in `ARCHITECTURE.md`.)

## 7. Demo script (the beats)

1. **Scrub the clock** — the org board morphs across hires, project moves, fractional splits.
   *(FR-1, FR-2 — as-of + temporal join)*
2. **Scrub into the future** — a promotion seeded for next quarter snaps in; level and charge rate
   step up unaided. *(FR-3 — future-dating, role × rate-card)*
3. **Scrub the past** — full history, no audit tables. *(FR-2)*
4. **`FOR PORTION OF`** — bump the L5 rate for H2-2026; scrub across the boundary and watch only that
   window change. *(FR-6)*
5. **My timesheet** — "I'm Priya"; scrub to last Tuesday; her two half-time projects appear; log
   hours; note the DB would refuse a project she has rolled off. *(FR-7, FR-5)*
6. **The redesign** — `git checkout v2-split`, run the migration, rebuild; re-scrub the same dates →
   identical. "I restructured the schema and history is *provably* intact." *(FR-8)*
7. **The thesis** — show one Squirrel query and the shared type it feeds; none of
   `WITHOUT OVERLAPS` / `PERIOD` / `FOR PORTION OF` / `range_agg` is ORM-reachable, yet types hold
   from column to pixel. *(§3)*

## 8. Honest limitations (stated on stage)

These are deliberately *not* engineered around — naming them keeps the talk credible:

- **No system-time / bitemporality.** PG19 provides valid-time only. Tempo cannot answer "what did
  the database *believe* on date X" after a correction. A structural redesign re-interprets all of
  history at deploy time and is lossy about modeling history (mitigation: archive old tables; full
  fix needs system-time, e.g. `pg_bitemporal`). This is also where Event Sourcing is *more* rigorous
  — it never loses original events — at the cost of projection machinery.
- **"Fractions sum to ≤ 1.0 per day" is not expressible** via `WITHOUT OVERLAPS` (it is a sum over
  overlapping periods, not a pairwise overlap). That invariant still needs a trigger or application
  logic.

## 9. Testing & verification

Layered, so each guarantee is checked at the cheapest level that can prove it (full detail in
`ARCHITECTURE.md` §10):

1. **Temporal-constraint tests** (Gleam + pog vs ephemeral PG19) — the DB *rejects* overlaps and
   every PERIOD-FK violation, and `FOR PORTION OF` / `range_agg` behave as specified.
2. **Migration oracle** — an automated property test of the on-stage claim: board snapshots are
   equal for a dense set of dates before and after the `v1-wide → v2-split` migration.
3. **As-of query tests** — crafted seed + fixed dates → exact expected rows.
4. **Codec round-trip tests** — encode→decode identity for the shared API types.
5. **End-to-end (Playwright)** — one behaviour-driven browser test per demo beat (§7): scrub the
   slider and assert what the user *sees*, never DOM internals. The **same suite runs unchanged
   against both `v1-wide` and `v2-split`** (v2 derived by migrating the v1 seed) and must stay green
   — the suite is itself the UI-level proof that the migration preserves observable behaviour.
   Playwright is maintained continuously through development, not bolted on at the end.

"Now" is anchored to a fixed seed date (not the system clock) so the slider and all assertions are
deterministic.

## 10. Success criteria

- All seven demo beats run reliably from a clean checkout on the talk machine.
- Every demo beat (§7) is covered by a Playwright test, and the **same suite passes unmodified
  against both `v1-wide` and `v2-split`**; the migration oracle (§9.2) also passes in CI.
- The `v1-wide → v2-split` migration applies cleanly and the board is byte-identical across the
  boundary for every sampled date.
- Changing a field in the `shared` types module breaks **both** server and client builds until
  reconciled (demonstrating the contract).
- The whole stack — schema, queries, API, UI — is typed with no `dynamic` escapes outside the
  decode boundary.

## 11. Non-goals

- No authentication, authorization, or multi-tenant concerns.
- No general migration framework — just enough runner for the demo.
- No timesheet approval workflow, reporting, or exports.
- No system-time/bitemporality (it is the honest-limit talking point).
- Minimal styling — legibility over polish.

## 12. Dependencies & risks

- **PostgreSQL 19** (beta/RC or a build with the temporal patches) on the talk machine. Squirrel
  introspects this instance at codegen time.
- **Squirrel ↔ range types / `FOR PORTION OF`** — must verify mapping; mitigation is to decompose
  ranges to `lower()/upper()` dates at the query boundary (see `ARCHITECTURE.md`). Resolve via a
  small spike during planning.
