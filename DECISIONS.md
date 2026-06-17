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
**Amended (ADR-017).** Re-baselined to lead with model fidelity; the talk-first PRD is superseded.

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
**Amended (ADR-018).** The uniform `valid_at` is renamed per fact to a predicate-named period; the
facts-not-state frame is deepened (decomposition by rate-of-change; correction = retroactive change).

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
**Amended (P4, see ADR-014).** This ADR originally assumed `shared`, `server`, and `client` could be
modules in a **single** package, kept JS-safe by import discipline alone. P4 disproved that: Gleam
1.17 compiles a whole package per target with no per-module target exclusion, so the client JS build
type-checks the Erlang-only server modules and fails. The contract is unchanged; only the packaging
moved — `shared` and `client` are now separate packages wired by path dependencies (ADR-014).

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
**Amended (ADR-024).** Retained as a historical artifact; the operations layer targets the clean
(v2) schema, so this migration is no longer the sole centerpiece.

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
**Amended (ADR-019).** The timesheet write is now one of many domain operations behind a single
`POST /api/operations`; the app gains an operations console and an event-log panel.

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
**Amended (ADR-021).** Still valid-time-only, but an append-only `event_log` now records system-time
*provenance* beside the facts (who/when/what), and back-dating-erases-belief is explicitly accepted.

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
**Resolved.** The **same** Playwright suite must pass *unmodified* against both `v1-wide` and
`v2-split` (v2 derived by migrating the v1 seed) — the suite is a UI-level behavioural contract
across the migration, and is maintained continuously through development. This holds by construction
because the tests assert only user-visible behaviour, which is unchanged by the redesign.
**Alternatives.** E2E-only (too coarse to localize temporal bugs, slow); DB-only (misses
integration/UI breakage — unacceptable for a live talk); Playwright on `v2` only (rejected — leaves
the v1 app, shown live, untested and forgoes the UI-level parity proof).

## ADR-014 — Three-package workspace (server + `shared` + `client`) wired by path dependencies
**Status:** Accepted (supersedes the single-package assumption in ADR-005)

**Context.** `lustre/dev build` runs `gleam build --target javascript`. Gleam 1.17 compiles a *whole
package* per target with **no per-module target exclusion** (`@target`, `internal_modules`, etc. do
not gate the JS compile), so building the client for JS type-checks **every** module in the package —
including the Erlang-only server subtree (`pog`/`wisp`/`mist`/`gleam_otp` and the Squirrel-generated
`sql.gleam` with bare `@external(erlang, …)` calls) — and fails with ~30 "Unsupported target" errors
(P4-T01). Import discipline alone (the ADR-005 assumption) cannot prevent this; the failures are
purely the server subtree, while `client/app`, `shared/types`, and `shared/codecs` compile clean for
JS.
**Decision.** Split into a three-package Gleam workspace: the root `tempo` server package; a `shared`
package (target-agnostic — depends only on gleam_stdlib + gleam_json, compiles for both Erlang and
JS); and a `client` package (JS target — lustre/rsvp/gleam_json/gleam_time, `[tools.lustre.build]`
outdir `../priv/static`). Both `tempo` and `client` take a **path dependency** on `shared`
(`{ path = "..." }`); neither depends on `client`/server respectively. The client is built with
`cd client && gleam run -m lustre/dev build client/app`.
**Rationale.** This is the canonical Lustre + Wisp layout and the only clean way to keep `sql.gleam`
Squirrel-generated (per-definition `@target(erlang)` gating is lost on every regeneration, ADR-006)
and the server + its tests untouched. The client's JS dependency graph now physically excludes all
server code, so the bundle builds; `shared` remains the single source of the API contract that breaks
both ends on a contract change (ADR-005 intent preserved).
**Alternatives.** Per-definition `@target(erlang)` gating across `sql.gleam` + the DB test suite —
rejected: mechanically works but is erased by Squirrel regeneration and is unmaintainable. An
isolated build package whose `src/` **symlinks** to the canonical sources (the P4 stopgap,
`client_build/`) — rejected: the symlinks were absolute, so it worked only on the author's machine
and broke on CI and any fresh clone (non-portable). Path dependencies need no symlinks and are
portable everywhere.

## ADR-015 — Board as three all-non-null as-of queries (so `Unassigned` is representable)
**Status:** Accepted

**Context.** The org board must show **every employed engineer exactly once** as of any date in one
of three states — allocated to a project, unassigned, or on leave — and the shared contract models
this as a `BoardRow` whose `engagement` is an `Engagement` sum (`OnProject` / `Unassigned` /
`OnLeave`). The natural single query (`ARCHITECTURE.md` §5's original form) `LEFT JOIN`s
`allocation`/`project`/`contract`/`client` onto `employment` so an employed-but-unallocated engineer
still produces a row with null project/client/fraction/rate.
**Decision.** Split the board into **three queries**, each using **`INNER JOIN`s only** so every
selected column is non-null, merged and re-sorted by engineer name in `board.snapshot`, one per
`Engagement` variant: `board_as_of` (employed + allocated, leave-suppressed → `OnProject`),
`board_unassigned_as_of` (employed, not allocated, not on leave → `Unassigned`), and
`board_leave_as_of` (covered by a `leave` fact → `OnLeave`).
**Rationale.** Squirrel introspects the prepared statement and types a `LEFT JOIN`ed column as
**non-null** (it cannot know the join may miss), so a single `LEFT JOIN` board query generates a
`sql.gleam` row that decodes the null project/client/rate as if present — and the handler **500s** on
exactly the dates an engineer is employed but unallocated (the state the `Unassigned` variant exists
to show). Three INNER-JOIN queries sidestep the typing mismatch entirely: each row is genuinely
all-non-null, decodes without `Option` plumbing, and maps cleanly to one closed `Engagement` variant,
so the unassigned state is first-class rather than a bag of nulls. The split is invisible to the
client and the Playwright contract (it asserts only what the user sees), and is exercised by the
migration oracle, which runs the production `board_as_of.sql` text and renders each date
NULL-tolerantly (`ARCHITECTURE.md` §10).
**Alternatives.** A single `LEFT JOIN` query decoding the joined columns as `Option` — rejected:
Squirrel types them non-null on regeneration, so the Option plumbing is not even expressible from the
generated row without hand-editing `sql.gleam` (erased on every codegen, same failure mode as
ADR-014's `@target` gating). A hand-written `pog` query outside Squirrel for the board — rejected:
forfeits the "schema change breaks the query at codegen" thesis (PRD §1) for the demo's central read
path. `COALESCE(... , sentinel)` to force non-null columns — rejected: a sentinel rate/project is a
lie in the read model and would corrupt the oracle's board comparison.

## ADR-016 — Server layered into web / domain / data access
**Status:** Accepted

**Context.** The HTTP handlers, business logic, and data access were tangled in one module per
resource (`board.gleam`/`timesheet.gleam` each parsed requests, chose status codes, ran the queries,
and imported `sql`). The decoded request type `WriteRequest` lived server-side even though its
encoder was already in `shared`.
**Decision.** Split the server into three layers: a **web** layer (`server/web/`: `router`, the
`board`/`timesheet` handlers, request parsing, and a leaf `response` helper) that owns routing, status
codes, and parsing into typed values; a **domain** layer (`server/board.gleam`, `timesheet.gleam`)
whose functions take already-parsed values, apply rules, and call persistence, returning domain
`Result`s (`WriteError`/`NotAllocated`); and the existing **data access** (`sql`, `context`). The web
layer never imports `sql`; the domain never imports `wisp`. `WriteRequest` and its decoder moved to
`shared`, pairing with the existing `encode_write_request`.
**Rationale.** "Isolated, not ignorant" — the domain is insulated from HTTP, but still openly depends
on the SQL/data-access layer, because in this project the temporal rules deliberately live in the
database (ADR-004/007); a fully persistence-ignorant repository port would be indirection over a thin
domain. The shared `response` helper is a leaf module both the router and handlers import, avoiding
the router↔handler import cycle.
**Alternatives.** Strict persistence ignorance via an injected repository port (rejected as ceremony
over a thin domain); helpers inside `router.gleam` (rejected — creates a handler↔router cycle).

## ADR-017 — Re-baseline: model fidelity leads, the demo follows
**Status:** Accepted (amends ADR-001, ADR-002)

**Context.** The repo nailed the temporal *mechanism* (ranges, `WITHOUT OVERLAPS`, `PERIOD` FKs) but
built little domain *vocabulary* on top: a uniform `valid_at`, and the only write path was the seed's
hand-written SQL plus `timesheet.log`. ADR-001 optimized everything for a talk's frozen beats.
**Decision.** Re-prioritize: **model fidelity leads, the demo follows.** Where a modeling decision
conflicts with talk-legibility, modeling wins and the demo shifts to match. The original talk-first
PRD is superseded (archived at `docs/archive/PRD-v1-conference-talk.md`); a new `PRD.md` replaces it.
**Rationale.** The interesting, ORM-impossible substance is the *write* cycle — how facts accumulate
and change over time — not the as-of read. Centering it is a stronger study and a better talk.
**Alternatives.** Refine in place behind the frozen beats (rejected — too constrained to surface the
write model); a parallel exploration branch leaving `main` as the talk (rejected — `main` is being
re-baselined).

## ADR-018 — Semantically-named validity periods, renamed in place
**Status:** Accepted (amends ADR-004, ADR-011)

**Context.** Every fact carried a generic `valid_at daterange`, which says *that* a period exists but
not *what it means*. A project is not "valid" over a period — it is *active*; an engineer *holds* a
level; a rate is *in effect*.
**Decision.** Name each period for the predicate it asserts — `employed_during`, `held_during`,
`effective_during`, `term`, `active_during`, `allocated_during`, `on_leave_during` (`timesheet.work_day`
already did this). Apply the rename **in place** in the existing migration files (`002`, `010`), not
as a new migration layered on top.
**Rationale.** The name is documentation the compiler and the SQL carry. PG19 lets a `PERIOD` FK name
child and parent periods differently, so containment reads as a sentence (`engineer_role … PERIOD
held_during REFERENCES employment … PERIOD employed_during`). In-place rather than a layered `011`
because the migration oracle replays migrations and runs the production board SQL — a rename-on-top
would run pre-rename generations against post-rename query text. The `v1-wide`/`v2-split` git tags are
historical commits and stay untouched.
**Consequence.** Touches the migration files, the `.sql` query sources, and regenerated `sql.gleam`;
the `lower()/upper() AS valid_from/valid_to` aliases are unchanged, so the `shared` types are untouched.

## ADR-019 — Domain operations layer: typed Command API + HTTP/UI
**Status:** Accepted (amends ADR-010)

**Context.** The write side was implicit (the seed) or single-purpose (`timesheet.log`). The system
should model the *business processes* by which data accumulates — onboarding, promotion, allocation,
roll-off, rate revision, leave, offboarding — as first-class operations.
**Decision.** A typed **`Command`** union lives in `shared` (client encodes, server decodes the same
value). Per-aggregate domain modules (`engineer`, `allocation`, `rate_card`, `engagement`, `leave`,
plus the existing `timesheet`) expose operations; a `command.dispatch(context, actor, command)` seam
opens one transaction, routes to the aggregate, and appends one `event_log` row. Exposed as a single
`POST /api/operations`; the Lustre client gains an **operations console** and an **event-log panel**.
The seed is replayed `Command`s (ADR-023).
**Rationale.** "Reading is trivial compared to the sophistication of the insert/update cycle." One
command vocabulary end-to-end matches the `shared`-contract thesis (ADR-005); per-aggregate modules
keep units small and testable (ADR-016); `dispatch` owning the event write makes provenance impossible
to forget.
**Alternatives.** RESTful per-operation endpoints (rejected — many handlers, the uniform command/event
path lost); one `operations.gleam` god-module (rejected — fights SLAP, hard to test in isolation);
event-sourced command log as source of truth (rejected — reframes the architecture; the facts stay the
source of truth, ADR-021).

## ADR-020 — Writes use native `FOR PORTION OF` (no hand-rolled cap-and-insert)
**Status:** Accepted

**Context.** A "change" (cap the current fact, assert a new one) and a "close" (cap a fact) could be
hand-coded as read-then-delete-then-reinsert in Gleam, with an explicit empty-period rule.
**Decision.** Use PG19 `FOR PORTION OF` directly. **Change** = `UPDATE … FOR PORTION OF p FROM
$effective TO NULL SET … WHERE … @> $effective` (the `WHERE` confines it to the version in effect; the
engine re-inserts the before-leftover; a scheduled future version is untouched). **Surgical** = the
same with a concrete `TO`. **Close/cascade** = `DELETE … FOR PORTION OF FROM $end TO NULL`.
**Correction** = a range covering the whole fact → zero leftovers → the prior assertion is dropped.
**Rationale.** Confirmed against the PG19 docs: the engine produces the before/after temporal leftovers
and deletes a fully-covered row itself, and `TO NULL` expresses an unbounded end. Hand-rolling it would
reimplement in application code exactly what the database does natively — contradicting the "SQL the
ORM can't express" thesis (PRD §1).
**Consequence.** The Squirrel ↔ `FOR PORTION OF` spike is **load-bearing** (almost all writes route
through it); fallback is hand-written `pog` for the write functions. The data layer shrinks to
per-aggregate `insert` / `update_for_portion` / `delete_for_portion`.

## ADR-021 — Application-time only, with an `event_log` for system-time provenance
**Status:** Accepted (amends ADR-012)

**Context.** ADR-012 accepted valid-time-only and named the absence of system-time as a talking point.
But there is still value in recording *that* a change was made — by whom, when.
**Decision.** Stay application-time only. **Back-dating a fact erases the previously-held belief, and
that is accepted** — a correction ≡ a retroactive change (ADR-020); the tables cannot distinguish "the
world changed" from "we recorded it wrong," and do not try. Add a single append-only
`event_log(occurred_at, actor, operation, summary, payload)` recording system-time provenance *beside*
the facts (no FKs in or out), written one row per operation in the same transaction as the writes.
**Rationale.** The cheap, honest sliver of the system-time axis: it answers "what did we do, and
when?" but **not** "what did we believe was true on date X?" (that needs versioning every fact by
system time — full bitemporality, declined). It never constrains or contaminates the facts. Two clocks
become explicit: `occurred_at` is the real wall clock; valid-time "now" is the fixed seed date.
**Alternatives.** Lossy `correct_*` operations distinct from `change_*` (rejected — in valid-time-only
they are the same write; a separate primitive earns nothing); full bitemporality / `pg_bitemporal`
(rejected — doubles period bookkeeping on every table and query for a story the demo does not need).

## ADR-022 — Named constraints + typed `OperationError` classification
**Status:** Accepted

**Context.** Temporal integrity lives in the database (ADR-004/008). The existing code classifies
exactly one violation (`timesheet`'s PERIOD FK → `NotAllocated`) by matching PG's autogenerated
constraint name.
**Decision.** Give every `PERIOD` FK and `WITHOUT OVERLAPS` exclusion constraint an **explicit, stable
name** in the schema (e.g. `allocation_within_employment`). Generalize the classifier: SQLSTATE +
constraint name → a typed `OperationError` (`ContainmentViolated` / `OverlappingFact` / `InvalidValue`
/ `DatabaseError`) → HTTP status (409/422/500); a body that won't decode is a 400 at the web layer.
**Rationale.** "Constraints, not code" (PRD FR-5) — the domain issues writes and lets the DB reject,
then translates the rejection into a domain-meaningful, testable error rather than an opaque 500.
Stable names make the classifier readable and tests robust against regeneration.
**Alternatives.** Pre-flight validation queries in the domain (rejected — duplicates the DB's checks
and races them); matching autogenerated names (rejected — brittle).

## ADR-023 — The seed is a replayed sequence of operations
**Status:** Accepted

**Context.** The clean-schema app needs founding data, and the operations layer (ADR-019) should be
exercised by the most realistic possible path.
**Decision.** Express the running app's seed as an ordered `List(Command)` (`seed.gleam`) replayed
through `dispatch`, producing the founding facts *and* the founding `event_log` history. A
**seed-equivalence test** asserts the resulting board matches a reference snapshot across a dense date
range.
**Rationale.** The seed becomes a narrative of business operations rather than opaque `INSERT`s, and
replaying it is a free end-to-end exercise of every operation. The hand-written `003_seed.sql` is
retained separately as the **v1 fixture for the migration oracle** (ADR-024).
**Alternatives.** Keep a hand-written SQL seed for the app too (rejected — bypasses the operations
layer and the event log, and the data would not prove the operations work).

## ADR-024 — Operations target the clean schema; `v1→v2` kept as a historical artifact
**Status:** Accepted (amends ADR-007)

**Context.** v1-wide caches `day_rate` on `allocation`; the `v1→v2` `range_agg` coalescing (ADR-007),
validated by the oracle (ADR-013), was the talk's centerpiece. An operations layer interacts with that
cache directly (a v1 rate revision would have to cascade-restamp allocations).
**Decision.** Build the operations layer on the **clean (v2) normalized schema**, where charge rate is
derived from `engineer_role × rate_card`. Leave the `day_rate` cache, the `010` split migration, and
the oracle **as is**, as a retained historical artifact — no longer the sole centerpiece; the
operations layer + temporal integrity share the stage.
**Rationale.** Lowest-risk path that still delivers both the semantic rename and the operations layer
without reworking the proven migration/oracle. The cache-cost-as-centerpiece variant (v1 operations
forced to fragment history) is a compelling future enhancement, deliberately deferred.
**Alternatives.** Make the cache's cost the new centerpiece (deferred — richest but most work); drop
the cache and the migration beat entirely (rejected for now — discards a working, proven demo asset).

---

## Documentation format
**Status:** Accepted

Design captured as `PRD.md` (product/requirements), `ARCHITECTURE.md` (technical design), and
`DECISIONS.md` (this log) at the repo root — per user request, in place of a single combined spec.
Superseded generations are archived under `docs/archive/` (e.g. the original talk-first
`PRD-v1-conference-talk.md`, superseded by ADR-017) rather than deleted.
