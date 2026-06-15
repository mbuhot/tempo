# Tempo — Decision Log

Architecture/product decisions made while designing the demo, with rationale and the alternatives
considered. Newest decisions append to the end. See `PRD.md` and `ARCHITECTURE.md` for the resulting
design.

Status legend: **Accepted** · Superseded · Proposed

---

## ADR-001 — Purpose: conference talk / live demo
**Status:** Accepted

**Context.** The artifact could be a tutorial repo, a reusable template, or a talk demo.
**Decision.** Optimize for a **conference talk / live demo**.
**Rationale.** Drives every other choice toward visual legibility, a scrub-the-clock spine, and a
provable on-stage climax — rather than breadth or production hardening.
**Alternatives.** Blog-companion repo; reference template; personal exploration.

## ADR-002 — Hero capabilities: all four, time-travel as the spine
**Status:** Accepted

**Context.** Which temporal capabilities to center.
**Decision.** Build around **as-of time-travel**, **future-dating**, **history-for-free**, and
**temporal joins**, with `FOR PORTION OF` / `WITHOUT OVERLAPS` / `PERIOD` FKs as supporting cast.
**Rationale.** The user's framing: the meaningful developer value is "query the state at any point
in time, historical or future-dated," not the parlor-trick of a rejected write. A time slider that
re-renders "as of" any instant is the visual spine.

## ADR-003 — Domain: Alembic consultancy staffing
**Status:** Accepted (supersedes an earlier generic hotel/org example)

**Context.** Need a domain rich enough that scrubbing time visibly transforms the view and that
naturally hosts overlaps, period-FKs, and slice-edits.
**Decision.** Model **Alembic's own business**: engineers allocated to projects, projects under
contracts for clients, levels/promotions, leave, timesheets.
**Rationale.** Real and relatable to the presenter; every temporal feature maps onto a genuine
business rule (see ADR-008/009/010).
**Alternatives.** Hotel rates+availability; SaaS subscriptions; generic org chart.

## ADR-004 — Model facts, not state (6NF narrow fact relations)
**Status:** Accepted

**Context.** How to shape the schema.
**Decision.** Two durable identity tables; everything time-varying is a **narrow fact** with its own
`valid_at daterange`. Never `UPDATE` state — cap the old fact, assert a new one.
**Rationale.** This is the talk's philosophical payload. Narrow facts also make schema evolution
mostly additive (a new attribute is a new table), and they correspond to 6NF / anchor modeling /
Datomic. Contrast with Event Sourcing made explicit: same "record facts" spirit, but temporal tables
are directly queryable across time with no projections.
**Consequence.** ~10 small tables rather than a few wide ones — accepted as a feature, not a cost.

## ADR-005 — Architecture: Lustre SPA + Wisp JSON API + shared types
**Status:** Accepted

**Context.** How to wire Wisp and Lustre; the slider's as-of fetch is the core interaction.
**Decision.** Lustre SPA in the browser; Wisp serves a JSON API + static assets; a **`shared` Gleam
module** (compiled to both Erlang and JS) defines the API types and JSON codecs.
**Rationale.** A clean, explicit as-of query boundary (demo-able), plus end-to-end type-safety:
`PG schema → Squirrel → shared types → JSON ⇄ → Lustre`. A contract change in `shared` breaks both
ends until reconciled.
**Alternatives.** Lustre server components (hides the query boundary); Wisp SSR + htmx-style
(weaker live morph). **Constraint introduced:** `shared` must be target-agnostic; `client` must not
import `server`.

## ADR-006 — Schema evolution demonstrated via git tags, not a live in-app migration
**Status:** Accepted

**Context.** How to show a structural redesign on stage.
**Decision.** Encode each schema generation as a **git tag** (`v1-wide`, `v2-split`); the presenter
checks out a tag and runs hand-written numbered SQL migrations.
**Rationale.** Lower-risk than an in-app button, and it reinforces the thesis: this is
version-controlled SQL you own. Each tag is an internally-consistent tree (schema + generated code +
shared types + UI).
**Alternatives.** A live "migrate now" button; a sandbox side-by-side.

## ADR-007 — Migration shape: decompose + temporally coalesce (range algebra)
**Status:** Accepted

**Context.** What structural change makes the strongest "ORM can't do this" beat.
**Decision.** A **split with temporal coalescing** using `range_agg` / multiranges — the v1 cached
`day_rate` on `allocation` is removed and fragmented allocation rows are merged back into whole
engagements (see `ARCHITECTURE.md` §7).
**Rationale.** It is not about missing *syntax* but missing *range algebra* — the deepest
ORM-impossible point. The new constraints validate the transform; the slider proves the board
identical for every date (the migration's correctness oracle).
**Alternatives.** Merge (temporal join/intersection); static-column → temporal-fact extraction
(rejected as mechanically trivial and without a coalescing demo); round-trip split+merge (too much
to rehearse).

## ADR-008 — Fractional allocations + timesheet PERIOD FK
**Status:** Accepted

**Context.** Alembic allows engineers split across projects, which removes the simple "one project at
a time" invariant.
**Decision.** Allow overlapping allocations across *different* projects; scope `WITHOUT OVERLAPS` to
`(engineer_id, project_id)` and add a `fraction`. Recover integrity with a **`timesheet` table whose
single-day period must be covered by an allocation** (3-column `PERIOD` foreign key): you cannot log
time to a project you are not allocated to that day (PRD FR-5/FR-7).
**Rationale.** Keeps the model realistic while giving a fresh, day-grain PERIOD-FK integrity demo.
**Accepted limitation.** "Fractions sum ≤ 1.0 per day" is a sum over overlapping periods — **not**
expressible via `WITHOUT OVERLAPS`; left to a trigger / app logic and named on stage.

## ADR-009 — Engineer level as a temporal `engineer_role` fact + `rate_card`
**Status:** Accepted

**Context.** L1–L7 levels are charged at different rates; level changes on promotion.
**Decision.** Level is a **temporal fact** (`engineer_role`, promotion = new row), not a static
`engineer.level` column. Charge rates live in a temporal **`rate_card(level, valid_at)`**. Charge
rate as-of a date is a two-hop temporal join: level as-of D, then rate-card as-of D.
**Rationale.** A static column destroys history and breaks retroactive billing ("what was her rate
on that day in 2024?"). As a fact it gives the **future-dating climax** (a promotion seeded ahead
activates on its own; level *and* rate step up) and the natural **`FOR PORTION OF`** home (slice an
L5 rate for H2). `contract` correspondingly slims to `(id, client_id, valid_at)`.

## ADR-010 — Timesheet is an interactive write path (two views)
**Status:** Accepted (supersedes "seeded integrity demo only")

**Context.** The timesheet could be seeded data purely for the FK demo.
**Decision.** Make it **interactive**: an engineer scrubs to a day, sees their allocations as of that
day, and enters hours per project; `POST /api/timesheet` writes it. The app therefore has two views
(read-only **org board**; read+write **my timesheet**) sharing the slider.
**Rationale.** Ties a temporal *read* directly to a temporal *write*, both behind the shared types,
and makes the PERIOD-FK integrity reachable live without being a gimmick (the UI shows truth; the DB
guarantees it).

## ADR-011 — Range types decomposed at the Squirrel boundary
**Status:** Accepted

**Context.** Squirrel's mapping of `daterange`/`datemultirange` is unverified.
**Decision.** Queries **return** `lower(valid_at)`/`upper(valid_at)` as plain `date`s and **accept**
ranges built in SQL (`daterange($from,$to,'[)')`); shared types carry `valid_from`/`valid_to` dates.
**Rationale.** Keeps Squirrel on well-trodden scalar types regardless of range-type support.
**Status note.** Backed by a planning spike (`ARCHITECTURE.md` §10).

## ADR-012 — Accept valid-time-only (no system-time / bitemporality)
**Status:** Accepted

**Context.** PG19 provides application-time (valid time) only.
**Decision.** Do **not** implement system-time. Treat its absence as a deliberate talking point:
the system cannot say what it *believed* at a past instant, and a structural redesign is lossy about
modeling history (mitigation: archive old tables; full fix is `pg_bitemporal`).
**Rationale.** Honesty about the edge strengthens the talk; Event Sourcing is the more rigorous
choice where never-losing-original-facts matters, at the cost of projection machinery.

## ADR-013 — Layered testing; Playwright for end-to-end
**Status:** Accepted

**Context.** The demo must be provably correct *and* must not break live on stage; how to test both
the temporal behaviour and the browser experience.
**Decision.** A layered strategy (see `ARCHITECTURE.md` §10): (1) DB-level temporal-constraint tests,
(2) an automated **migration oracle** property test (board equal for every date across
`v1-wide → v2-split`), (3) as-of query tests, (4) shared-codec round-trips — all Gleam, strict TDD —
plus (5) **Playwright** end-to-end tests, one per demo beat, behaviour-driven (assert what the user
sees, never DOM internals).
**Rationale.** Each guarantee is checked at the cheapest level that can prove it. The migration
oracle turns the talk's boldest claim into a CI gate; Playwright is the safety net that the live
beats actually run in a real browser. A fixed seed "now" makes every layer reproducible.
**Open.** Playwright against `v2-split` only (recommended) vs both tags for UI parity.
**Alternatives.** E2E-only (too coarse to localize temporal bugs, slow); DB-only (misses
integration/UI breakage — unacceptable for a live talk).

---

## Documentation format
**Status:** Accepted

Design captured as `PRD.md` (product/requirements), `ARCHITECTURE.md` (technical design), and
`DECISIONS.md` (this log) at the repo root — per user request, in place of a single combined spec.
