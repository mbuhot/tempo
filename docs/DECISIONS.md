# Tempo — Decision Log

Architecture/product decisions made while designing the demo, with rationale and the alternatives
considered. Newest decisions append to the end. See `PRD.md` and `ARCHITECTURE.md` for the resulting
design.

Status legend: **Accepted** · Superseded · Proposed

---

## ADR-001 — Purpose: conference talk / live demo
**Status:** Accepted; **superseded by ADR-017** — re-baselined so model fidelity leads; the talk-first goal is dropped (PRD archived).

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
**Status:** Accepted; **amended by ADR-018** (predicate-named periods) and **ADR-030** (id-only anchors + edit-grouped facts).

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
**Status:** Accepted; **amended by ADR-014** — the single package became three path-wired packages (the contract is unchanged; only the packaging moved).

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
**Status:** Accepted; **amended by ADR-031** — the migration-oracle equivalence gate is removed; the git tags + numbered migrations stand.

**Context.** How to show a structural redesign on stage.
**Decision.** Encode each schema generation as a **git tag** (`v1-wide`, `v2-split`); the presenter
checks out a tag and runs hand-written numbered SQL migrations.
**Rationale.** Lower-risk than an in-app button, and it reinforces the thesis: this is
version-controlled SQL you own. Each tag is an internally-consistent tree (schema + generated code +
shared types + UI).
**Alternatives.** A live "migrate now" button; a sandbox side-by-side.
**Amended by ADR-031.** The git tags and numbered migrations stand, but the automated board-equivalence
oracle that proved the `v1→v2` transform correct is removed; correctness is now argued from the
migration text and the constraints, not a CI gate.

## ADR-007 — Migration shape: decompose + temporally coalesce (range algebra)
**Status:** Accepted; **amended by ADR-024** (no longer the centerpiece) and **superseded in part by ADR-031** — the oracle that validated the transform is removed; the split-migration text remains.

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
**Superseded by ADR-031.** The migration oracle that validated this transform (board equal for every
date across `v1→v2`) is removed; the split migration text remains but its automated correctness gate
is gone.

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
**Status:** Accepted (supersedes "seeded integrity demo only"); **superseded by ADR-025** — logging hours is now the `LogTimesheet` command on `POST /api/operations`; the timesheet route is read-only.

**Context.** The timesheet could be seeded data purely for the FK demo.
**Decision.** Make it **interactive**: an engineer scrubs to a day, sees their allocations as of that
day, and enters hours per project; `POST /api/timesheet` writes it. The app therefore has two views
(read-only **org board**; read+write **my timesheet**) sharing the slider.
**Rationale.** Ties a temporal *read* directly to a temporal *write*, both behind the shared types,
and makes the PERIOD-FK integrity reachable live without being a gimmick (the UI shows truth; the DB
guarantees it).
**Amended (ADR-019).** The timesheet write is now one of many domain operations behind a single
`POST /api/operations`; the app gains an operations console and an event-log panel.
**Amended (ADR-025).** The timesheet is no longer a separate write path at all: `POST /api/timesheet`
is gone, the route is read-only (GET form), and logging hours is the `LogTimesheet` command on
`POST /api/operations` like every other write.

## ADR-011 — Range types decomposed at the Squirrel boundary
**Status:** Accepted

**Context.** Squirrel's mapping of `daterange`/`datemultirange` is unverified.
**Decision.** Queries **return** `lower(valid_at)`/`upper(valid_at)` as plain `date`s and **accept**
ranges built in SQL (`daterange($from,$to,'[)')`); shared types carry `valid_from`/`valid_to` dates.
**Rationale.** Keeps Squirrel on well-trodden scalar types regardless of range-type support.
**Status note.** Backed by a planning spike (`ARCHITECTURE.md` §10).

## ADR-012 — Accept valid-time-only (no system-time / bitemporality)
**Status:** Accepted; **amended by ADR-021** — an append-only `event_log` now records system-time provenance beside the facts.

**Context.** PG19 provides application-time (valid time) only.
**Decision.** Do **not** implement system-time. Treat its absence as a deliberate talking point:
the system cannot say what it *believed* at a past instant, and a structural redesign is lossy about
modeling history (mitigation: archive old tables; full fix is `pg_bitemporal`).
**Rationale.** Honesty about the edge strengthens the talk; Event Sourcing is the more rigorous
choice where never-losing-original-facts matters, at the cost of projection machinery.
**Amended (ADR-021).** Still valid-time-only, but an append-only `event_log` now records system-time
*provenance* beside the facts (who/when/what), and back-dating-erases-belief is explicitly accepted.

## ADR-013 — Layered testing; Playwright for end-to-end
**Status:** Accepted; **partly superseded by ADR-031** — the automated migration-oracle property test is removed; the other test layers stand.

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
**Partly superseded by ADR-031.** Layer (2), the automated migration-oracle property test, is removed
along with the oracle. The other layers stand: DB-level temporal-constraint tests, as-of query tests,
shared-codec round-trips, and the Playwright end-to-end suite (now 129 Gleam tests + 14 Playwright
specs).

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
**Status:** Accepted (amends ADR-010); **amended by ADR-025 and ADR-027/028** — event emission, dispatch, and handler responsibilities refined.

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
**Amended (ADR-025).** `dispatch` is slimmed to route + persist; each aggregate's `handle` now owns its
own event emission (tag/summary/payload) and returns the events, which `dispatch` returns to the
caller.
**Amended (ADR-027/028).** The aggregate `handle` is now a pure dispatch to **named per-operation
functions** (an unrouted command `panic`s — a routing bug, never a silent `Ok`); `operation.try/run`
encapsulate the SQLSTATE→`OperationError` classification the operations repeated; the standalone
`events(command)` function is gone — each named op **builds its own event(s)** after the write.

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
**Status:** Accepted (amends ADR-012); **amended by ADR-032** — facts now carry an `audit_id` FK INTO
`event_log` (a provenance pointer, set by the repository; the as-of reads never consult it), so the
"no FKs in or out" below holds only for FKs OUT of event_log; the model stays valid-time-only.

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
**Status:** **Superseded by ADR-031** — the operations-replay seeder and its equivalence test are removed; a SQL seed is canonical again (`002_seed.sql` since ADR-033).

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
**Superseded by ADR-031.** The operations-replay seeder (`seed.gleam`) and the seed-equivalence test
are removed; `003_seed.sql` is again the canonical running-app seed, with `bin/seed-invoices` the
on-demand financial seed.

## ADR-024 — Operations target the clean schema; `v1→v2` kept as a historical artifact
**Status:** Accepted (amends ADR-007); **amended by ADR-031** — the retained oracle is removed; the `010` split-migration text stays, unguarded.

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
**Amended by ADR-031.** The oracle that this ADR retained "as is" is now removed; the `010` split
migration text stays but is no longer guarded by an automated equivalence check.

## ADR-025 — Command handlers own event emission; `dispatch` only routes and persists
**Status:** Accepted (amends ADR-010, ADR-019); **amended by ADR-032** (handlers now return
`fact.Recorded(entry, facts)`; `repository.record_facts` appends the entry then writes the facts)

**Context.** Under ADR-019, `dispatch` did the routing *and* built the journal `event_log` row —
deriving the `operation` tag, the human summary, and the re-encoded payload itself — while the
aggregates did only their temporal writes. That concentrated cross-aggregate knowledge in `command`
(389 lines) and left the timesheet on its own residual write path (`POST /api/timesheet` →
`timesheet.log`, ADR-010), inconsistent with every other operation. The web handler also returned only
an acknowledgement, so the client had to refetch the journal to see what it had just written.
**Decision.** Each aggregate exposes **`handle(conn, command)`** returning
`Result(List(Event), OperationError)` and **owns its own event emission** — its tag, summary, and
`codecs.encode_command` payload. `command.dispatch` is reduced to two responsibilities: **route** the
command to the right `handle`, and **persist** each emitted event via `event.append`, all in one
transaction; it **returns the created events**, which `POST /api/operations` echoes as a JSON array (no
fetch-newest). The timesheet write is folded into this path as the `LogTimesheet` command (reusing the
existing `log_in` core); `POST /api/timesheet` is removed and the route is read-only (GET form). A leaf
module **`operation.gleam`** holds the journal `Event` type, `OperationError`, the SQLSTATE/constraint
`classify` helpers, and the date helpers — imported by both `command` and the aggregates — breaking the
`command` ↔ aggregate import cycle that returning typed events would otherwise create.
**Rationale.** SLAP (ADR-016): each `handle` keeps one operation's writes and its journal entry at one
level, instead of `dispatch` reaching into every aggregate's vocabulary; `command` drops from 389 to
114 lines. One write path (ADR-019's command bus) for *all* writes, including the timesheet, removes
the inconsistent special case. Returning the persisted events makes the response self-describing and
lets the client update without a second read.
**Alternatives.** Keep `dispatch` building events (rejected — the 389-line god-function and the
cross-aggregate coupling it codified); put `Event`/`OperationError` in `command` (rejected — aggregates
returning events would import `command`, which routes to them: a cycle); leave the timesheet on its own
endpoint (rejected — the very inconsistency this refactor removes).
**Amended (ADR-027/028).** `handle` is no longer a single command-destructuring body: it is a pure
dispatch to named per-operation functions (ADR-027), and those functions now **build** their own
events directly (the `events(command)` function is gone, ADR-028). A single `INSERT … RETURNING` row
is read with `let assert [row]`, so the created-record id flows into the event summary instead of
being fabricated.

## ADR-026 — Financials: temporal invoice lifecycle, agreed-rate billing, proration, P&L as a query
**Status:** Accepted (extends ADR-004, ADR-009, ADR-019/025; see `PRD-financials.md`); **amended by ADR-030** — invoice/payroll periods are now immutable 1:1 facts on id-only anchors.

**Context.** Invoicing, payroll, and a P&L turn the staffing model into money, and money is where
temporal correctness bites hardest. Three questions had to be answered consistently with the existing
model (`PRD-financials.md` §1): how to identify an invoice and track its lifecycle; *which* charge
rate an invoice bills; and how to pay for partial periods. The financial tables also reference project
*entities* that — like `contract` — have no single-row identity table to PERIOD-FK against.
**Decision.**
- **Invoice identity + temporal status lifecycle.** An `invoice(id, project_id, billing_period)` is
  one durable thing with an immutable subject; its **state** is the temporal fact
  `invoice_status(invoice_id, status, status_during)` (`draft → issued → paid`, `WITHOUT OVERLAPS`).
  Issue/Pay are status **Changes** (cap-and-assert, ADR-020) with a guard that the current status is
  the expected predecessor, so an out-of-order transition is rejected (`InvalidValue`), and "what was
  the status of invoice N on date D" is a plain as-of query (FR-F4). Lines are **snapshotted at
  draft** (plain rows), so an issued invoice does not retro-change.
- **Agreed-rate billing pinned to `lower(contract.term)`.** A line's `day_rate` is `rate_card[level]`
  **as of the contract's signing date**, not as of the billing month (FR-F2). A later `ReviseRateCard`
  does not change what an already-agreed contract bills; the board's as-of-today rate and the invoice's
  billed rate visibly diverge. We do **not** model an explicit `agreed_rate_at` separate from the term
  start — an amendment would be a new contract term version (PRD §8, accepted limitation).
- **Salary as a cost `rate_card`.** `salary(level, monthly_salary, effective_during)` is the cost
  analogue of `rate_card` — same `WITHOUT OVERLAPS` per level, same `FOR PORTION OF` revision
  (`SetSalary`).
- **Payroll proration over `employment ∩ role`, leave paid in full.** `RunPayroll(month)` prorates by
  day over the intersection of employment, the role (level) version, the salary version, and the
  month, split by `engineer_role` so a mid-month promotion is paid partly at each level's salary;
  hire/termination clip, promotion splits, and **leave does not reduce pay** — the `leave` table is
  not consulted (FR-F5/F6).
- **P&L as a read query.** `GET /api/pnl?as_of=` computes month + YTD revenue (issued/paid invoice
  lines, recognized on issue, read as-of the window's upper bound) vs cost (payroll lines), with a
  per-engineer breakdown (profit, margin %, capacity-share utilization %). No stored P&L — it is
  derived on read so it always reflects current facts.
**Rationale.** Reuses the established patterns wholesale: facts-not-state (ADR-004), the temporal
Change (ADR-020), the two-hop `engineer_role × rate_card`/`salary` join (ADR-009), and the command
bus with per-aggregate `handle` (ADR-025). The hard temporal cases get the spotlight (agreed rate
after a revision; blended-rate promotion; leave at full pay) while the rest is plain as-of reads.
**Alternatives.** Bill at the month's current rate (rejected — loses the agreed-rate point, FR-F2);
status as a mutable column on `invoice` (rejected — no history, can't ask the as-of question);
cross-entity PERIOD FKs from the financial tables (rejected — no identity table for project/contract
entities to key against; containment lives in the computing queries, PRD §3/§8); a materialized P&L
(rejected — would diverge from facts and need invalidation; a query is simpler and always current).
**Amended by ADR-030.** The invoice's `(project_id, billing_period)` and the payroll run's `period` are
now immutable 1:1 facts (`invoice_subject`, `payroll_period`) on id-only anchors, and the "no identity
table to PERIOD-FK against" premise no longer holds: `016`/`017` give `project`/`contract` id-only
anchors, so the `invoice_subject.billing_period ⊂ project_run.active_during` PERIOD FK now exists
(migrations `013`/`017`). The lifecycle, billing, proration, and P&L decisions are otherwise unchanged.

## ADR-027 — Aggregate `handle` dispatches to named operations; `operation.try/run` encapsulate classification; an unrouted command panics
**Status:** Accepted (refines ADR-019, ADR-025); **amended by ADR-032** (named ops now return
`fact.Recorded`; `operation.try/run` are used by `repository`, not the handlers)

**Context.** Under ADR-025 each aggregate gained a `handle(conn, command)`, but the body was a single
case that destructured the command's fields *and* did the writes *and* built the event inline, mixing
abstraction levels (SLAP, ADR-016). Every temporal write also repeated the same
`result.try(sql.… |> result.map_error(operation.classify))` ceremony, and the multi-write paths
(insert loops, the journal append) were hand-rolled recursion. `command.route` had already narrowed
each aggregate to the variants it owns, so an aggregate `handle` receiving a foreign variant could
only be a routing bug — yet the fall-through risked being papered over as an `Ok`.
**Decision.** Each aggregate's `handle` is a **pure dispatch**: `case command { <Variant>(..) ->
<named_op>(conn, command) ; _ -> panic as "<aggregate>.handle: … (dispatch bug)" }`. It routes to
**named per-operation functions** (`onboard_engineer`, `promote`, `terminate_employment`;
`assign_to_project`, `change_allocation_fraction`, `roll_off`; `revise_rate_card`,
`adjust_rate_for_portion`; `sign_contract`, `start_project`; `take_leave`; `set_salary`;
`run_payroll`; `log_timesheet`; `draft_invoice`, `issue_invoice`, `pay_invoice`), each a flat readable
sequence. The unrouted arm **`panic`s** — an unrouted command is a routing bug, never a silent `Ok`.
The `operation` leaf gains two helpers that encapsulate the classify: **`try`** (chain a write, mapping
`pog.QueryError → OperationError`, into the next step via `use <-`) and **`run`** (a single terminal
write, or a `list.try_map` of writes); hand-rolled recursion is gone — insert loops and the journal
persist use `list.try_map`.
**Rationale.** SLAP (ADR-016): the dispatch level (which operation?) is separated from the operation
level (what writes, in what order?); each named op reads as a sequence of `use _ <- operation.try(…)`
with one obvious shape. The `panic` makes the routing invariant load-bearing instead of silently
absorbed — if `command.route` and an aggregate's `handle` ever disagree, the bug crashes loudly in a
test rather than returning a misleading success. `try`/`run` remove the classification boilerplate the
operations otherwise repeat verbatim, so the classify lives in one place (ADR-022).
**Alternatives.** Keep the one-case `handle` doing destructure+write+event (rejected — mixes three
abstraction levels and grows unreadable as aggregates gain operations); return an `Error`/`Ok(Nil)` on
the unrouted arm (rejected — it would hide a dispatch bug as a benign result); leave the
`map_error(classify)` ceremony inline at every write (rejected — repetitive and easy to forget on a new
write).

## ADR-028 — Handlers build their own events (carrying created-record ids); single `RETURNING` rows are read with `let assert`, never fabricating id 0
**Status:** Accepted (refines ADR-025); **superseded by ADR-032** — created-record ids now come from an
identity sequence reserved up-front (`repository.next_id`), so create-ops no longer read back a
`RETURNING` id; the journal entry is the `Recorded` entry `record_facts` appends

**Context.** ADR-025 moved event *ownership* to the aggregates, but a standalone `events(command)`
function still derived the journal event from the *command alone*, separately from the writes. That
left two problems. First, a command does not know the ids the database mints — so a create operation's
event could not name the record it created. Second, the create-ops read their `INSERT … RETURNING id`
row with a defensive `case rows { [r, ..] -> r.id ; [] -> 0 }`, **fabricating id 0** on an
"impossible" empty result and silently swallowing a SQL/driver bug into a bogus id.
**Decision.** Each named operation (ADR-027) **constructs its own event(s)** after its writes and
returns `Result(List(Event), OperationError)`; the standalone `events(command)` function is **deleted
from every aggregate**, and `dispatch` only routes and persists the returned events (it no longer
builds them). Because the event is built *after* the write, it carries **write-time data**: the five
create-ops (`onboard_engineer`, `sign_contract`, `start_project`, `draft_invoice`, `run_payroll`)
surface the minted `RETURNING` id in the event summary. A single `INSERT … RETURNING` row is read with
**`let assert [row] = …`** on a one-element list — in the five create-ops, `event.append`, and the
connection smoke check — never the old `[] -> 0` fabrication. An empty/multi result crashes as the
SQL/pog-driver bug it would be, never a fabricated id.
**Rationale.** Provenance should describe what actually happened, which is only fully known after the
write commits the minted ids; building the event from the command alone could not include them. The
`let assert` states the SQL invariant ("`RETURNING` from a single insert yields exactly one row")
directly in code — a violation is a driver/schema bug and should crash, not be laundered into id 0 that
flows downstream into a summary and an `event_log` payload. Deleting `events()` removes the last place
event-shaping lived apart from the operation that earns it (SLAP, ADR-016).
**Alternatives.** Keep `events(command)` and have `dispatch` re-query for the new id (rejected — a
second read, and a race outside the write's own row); keep the `[] -> 0` fallback (rejected — it
fabricates a lie and hides the bug it claims to guard against); return an `Error` on the empty case
(rejected — an empty `RETURNING` is not a domain error the caller can act on, it is a broken invariant
that should `panic`).

## ADR-029 — CSS source as `client/styles` components copied by the build, with a central design-token `theme.css`
**Status:** Accepted

**Context.** The stylesheet was a single hand-served `styles.css` full of magic numbers (literal sizes,
weights, colours, radii) repeated and drifting across the board, timesheet, console, event-log, and
financial areas. There was no single place to re-tune spacing or shift the palette, and the served file
was an edited artifact rather than a build output like `app.js`.
**Decision.** CSS source lives in **`client/styles/`** as plain-CSS component files (`base`, `slider`,
`board`, `timesheet`, `console`, `event-log`, `financials`) imported in page order by `main.css`;
`bin/build` copies `client/styles/ → server/priv/static/styles/` (a gitignored build artifact, like
`app.js`). The old hand-served `styles.css` is gone and `index.html` links `/static/styles/main.css`.
**`client/styles/theme.css` is the single source of design tokens**: t-shirt sizing scales
(`--space-xs..xl`, `--text-xs..xl`, `--size-xs..page`), `--weight-{normal,medium,bold}`, a semantic
`--color-*` palette, `--border`/`--border-thin`, `--tracking-{tight,tighter}`, `--leading`, `--radius`,
`--font-root`. Every component references `var(--token)` — there are **no magic numbers** left in any
component; the values all live on the central scales.
**Rationale.** One edit to a token re-tunes the whole app (tighten spacing, shift the palette, change
the type ramp) and propagates everywhere, because nothing hard-codes a value. Splitting by UI area
keeps each component file small and matched to the part of the page it styles (the same
isolate-by-concern discipline as the server layers, ADR-016). Treating the served CSS as a copied build
artifact mirrors how `app.js` is produced, so the served tree is never hand-edited and a fresh build is
authoritative.
**Alternatives.** Keep one hand-served `styles.css` (rejected — magic numbers drift, no single tuning
point, and the served file is an edited artifact); a CSS preprocessor (Sass/Less) for variables
(rejected — CSS custom properties already give cascade-aware tokens with no build-time toolchain); a
utility/atomic CSS framework (rejected — out of proportion for the demo and obscures the page-area
structure the component split makes legible).

## ADR-030 — Every entity is an id-only anchor; all attributes are edit-grouped facts, read as-of or latest
**Status:** Accepted (amends ADR-004, ADR-009, ADR-018, ADR-026)

**Context.** Even after ADR-004's facts-not-state and ADR-018's semantic periods, the durable
identity tables still **carried attributes**: `engineer.name`, `client.name`, `contract.(client_id,
term)`, `project.(name, active_during, …)`, plus `invoice.(project_id, billing_period)` and
`payroll_run.period`. So "identity" and "a current descriptive attribute" lived in one row, an attribute
edit touched the anchor every FK keys against, and the contact/banking/emergency/profile/plan detail had
no home at all. The model wanted a clean separation: an entity is a bare referent; everything else is a
dated fact about it.
**Decision.** Make **every entity an ID-ONLY anchor** (`engineer`, `client`, `contract`, `project`,
`invoice`, `payroll_run` — each just `(id)`), and move all attributes into **edit-grouped fact tables**
keyed to the anchor PK (migrations `014`–`017`). Facts come in **three temporal flavours**, and the
application chooses the read per query:
- **Valid-time, read AS-OF a date.** The period is named for the predicate it asserts (ADR-018):
  `employed_during`, `held_during`, `on_leave_during`, `allocated_during`, `term`, `active_during`,
  `effective_during`, `status_during`, `work_day`, `planned_during`. The slider reads the version in
  force on the chosen date. New here: `contract_terms(contract_id, client_id, term)`,
  `project_run(project_id, contract_id, active_during)`, `project_plan(budget, target_completion)`.
- **Latest-read, period `recorded_during`** (transaction-time character). A new edit is a new row
  covering `[effective, NULL)`; the **most-recently-effective row is current truth**, older rows are the
  history; current value is exposed via `*_current` views (`engineer_current`, `client_current`,
  `project_current`) as `DISTINCT ON (anchor_id) ORDER BY lower(recorded_during) DESC`. Used for
  descriptive/contact detail: `engineer_contact(name, email, phone, postal)`, `engineer_banking`,
  `engineer_emergency`, `client_profile(name)`, `project_profile(title, summary)`.
- **Immutable 1:1 subject** set once and never versioned: `invoice_subject(invoice_id, project_id,
  billing_period)` and `payroll_period(run_id, period)` — keyed by the anchor PK (no `WITHOUT OVERLAPS`,
  no `*_current` view); reads INNER JOIN the fact directly. `payroll_period` carries the no-overlap
  EXCLUDE that moved off `payroll_run`.
Pre-existing facts are unchanged (`employment`, `engineer_role`, `leave`, `allocation`, `rate_card`,
`salary`, `timesheet`, `invoice_status`, `invoice_line`, `payroll_line`, `event_log`). Writes go through
the command bus (ADR-025/027/028) as temporal Changes: new commands `UpdateContactDetails`,
`UpdateBankingDetails`, `UpdateEmergencyContact`, `UpdateClientProfile`, `UpdateProjectProfile`,
`UpdateProjectPlan`, with new domain aggregates `engineer_details`, `client_details`, `project_details`;
`sign_contract` / `start_project` / `onboard_engineer` now mint the anchor and open the founding fact
rows. Reads that surfaced an entity name re-point to the `*_current` views, coalesced so the `String`
contract holds (Squirrel infers view columns nullable). External JSON (board / financials) is
**byte-identical**.
**Rationale.** The key mechanic is that **renaming a table/column carries its `PERIOD` FKs with it**:
`016` renames `contract → contract_terms` (id → `contract_id`) and `project → project_run` (id →
`project_id`), so `project_within_contract`, `allocation_within_project`, and `invoice_within_project`
**auto-follow** to the renamed parent with no FK drop/re-add — then mints a fresh id-only anchor under
each. Where columns *move tables* instead of being renamed (`017`'s invoice/payroll), the keying
constraints don't auto-follow and are explicitly dropped from the anchor and re-added on the fact. The
three flavours make the read mode explicit at the call site (as-of for valid-time claims about the
world; latest for "as last recorded" detail; a plain join for the immutable subject), and the temporal
containment chain now reads as a sentence: `contract_terms → project_run → allocation → timesheet`,
`employment → {engineer_role, leave, allocation}`, and `invoice_subject ⊂ project_run`. The contact /
banking / emergency facts deliberately key the anchor with a **plain** (non-PERIOD) FK — they are
properties of the person, not facts contained by employment, so an ex-employee still has a name and bank
account on file.
**Alternatives.** Keep names on the anchors and version only the "rich" detail (rejected — leaves
identity and attribute tangled, and an attribute edit still touches the FK target); one wide
`*_details` valid-time fact per entity (rejected — couples unrelated edits and forces an as-of read on
descriptive detail that has no valid-time meaning); a generic `valid_at` on the new facts (rejected —
ADR-018: the period name is documentation, and `recorded_during` signals the transaction-time read).

## ADR-031 — Remove the migration oracle and the seed-via-operations equivalence
**Status:** Accepted (supersedes ADR-023; amends ADR-006, ADR-007, ADR-013, ADR-024)

**Context.** Two automated correctness gates had outlived their value. The **migration oracle**
(ADR-013 layer 2, validating ADR-007's `v1→v2` `range_agg` coalescing by asserting the board equal for
every date) and the **seed-equivalence test** (ADR-023, asserting "seed via replayed operations" equals
"seed via migration") both pinned the project to maintaining two seed paths and a v1 fixture, while the
re-baseline (ADR-017/024) had already moved the centre of gravity to the operations layer on the clean
schema and the anchor/fact redesign (ADR-030).
**Decision.** **Delete the oracle entirely** — `server/src/tempo/oracle.gleam`, `bin/oracle`, the
operations-replay seeder `server/src/tempo/seed.gleam`, and `server/test/seed_equivalence_test.gleam`.
The `v1→v2` board-equivalence verification and the seed-via-operations equivalence check are gone.
the SQL seed is again the **canonical running-app seed** (later consolidated to `002_seed.sql`, ADR-033);
`bin/seed-invoices` remains the on-demand financial seed. `bin/` is now build, db, e2e, erd, migrate,
seed-invoices, serve, squirrel, test, up (no `bin/oracle`). The suite is **129 Gleam tests + 14
Playwright specs**.
**Rationale.** The remaining test layers (DB-level temporal-constraint tests, as-of query tests,
shared-codec round-trips, and the behaviour-driven Playwright suite) cover the live demo; the oracle's
specific claim — that the lossy `range_agg` split preserves the board — is argued from the migration
text and the validating constraints, not a CI gate, now that the migration is a historical artifact
rather than the sole centerpiece (ADR-024). Dropping the operations seeder removes the second seed path
and its fixture, simplifying the seed story back to one canonical SQL seed.
**Alternatives.** Keep the oracle as a dormant CI check (rejected — it forces the v1 fixture and a
second seed path to be maintained for a beat that is no longer central); keep `seed.gleam` as the app
seed (rejected — ADR-030's anchor/fact founding writes are exercised by the command-bus tests, and the
SQL seed is simpler and deterministic).

---

## ADR-032 — A typed `Fact` schema + `repository` persistence seam; handlers return `Recorded`; per-fact `audit_id`; explicit id sequences
**Status:** Accepted (amends ADR-025, ADR-027; supersedes ADR-028)

**Context.** Under ADR-025/027/028 each aggregate's named op did its own `sql.*` temporal writes, then
built the journal `Event` it returned, and `dispatch` persisted those events. The write SEMANTIC (which
`FOR PORTION OF` shape, which cascade, the delete-then-insert upsert) was spread across thirteen
aggregate modules, the create-ops minted ids by reading back a single `INSERT … RETURNING` row
(`engineer`/`invoice`/`payroll_run` via `GENERATED ALWAYS AS IDENTITY`; `contract`/`project` via a
race-prone `coalesce(max(id),0)+1`), and the event_log sat beside the facts with no link between a
fact row and the command that wrote it. The information the system records was implicit in scattered
writes rather than stated as a type.

**Decision.** Introduce a **`Fact`** union — the typed information schema — whose variants are *states
that hold over a period* (not events): identity anchors, `EngineerEmployed`/`AtLevel`/`OnLeave`/
`AllocatedToProject`, the contact/banking/emergency/profile/plan/client details, `RateCard`, `Salary`,
`ContractTerms`, `ProjectRun`, the invoice/payroll facts, `EngineerWorkedHours`, and the retraction
facts `EngineerOffProject`/`EngineerDeparted`. A handler returns **`fact.Recorded(entry, facts)`** — the
command's audit `entry` (an `operation.Event`: tag, summary, payload) plus the facts it records (anchors
first, then the facts contained by them). A single **`repository.record_facts(conn, actor, entry,
facts)`** is the one place a fact's write SEMANTIC lives: it appends the `entry` to `event_log`, then
writes each fact, **passing the appended entry's id as the `audit_id` every fact carries** — its FK back
to the command that recorded that row-version. It maps each fact to its SQL (a plain insert; a
versioned-attribute *change-or-open* that falls back to an open when no version yet exists, keyed off
the live row count, so the founding write and a later edit are the same fact; a cap-then-open status; a
cap + cascade retraction; the worked-hours upsert), and classifies any rejection. Its companion
**`repository.next_id(conn, sequence)`** reserves an anchor id from a `GENERATED BY DEFAULT` identity
sequence, so a create-op threads the id into every fact it emits with no read-back.

Per-fact provenance is set **explicitly** on each write — an insert supplies `audit_id` as a column; a
revise SETs it on the changed `[from, NULL)` portion while PG copies the original onto the carved-off
leftover; a delete (a retraction's cap) leaves no row, so a retraction's provenance lives only in
event_log. `audit_id` is **nullable**: the application and the seed always set it, but the low-level
constraint-test fixtures that insert facts directly need not fabricate an entry.

**Rationale.** The Fact union makes the recorded information schema legible at a glance; concentrating
the write semantics in `repository` (SLAP, ADR-016) lets handlers read as declarative `Command →
Recorded` mappings. The audit `entry` is batch metadata, not a pretend fact, so there is no special
journal variant in the repository — and the per-fact `audit_id` FK is a genuine capability gain: a row
joins back to the command that wrote it, and "everything command X touched" is one query. Explicit
sequences fix the `contract`/`project` mint race and let every create-op reserve its id up-front
uniformly. This is the event-sourced shape (commands → facts) without an event-log+projection engine:
the facts ARE the temporal rows; the bitemporal design preserves history, with event_log as the audit
for the one lossy case (a back-dated overwrite).

**Alternatives.** A `CommandHandled` audit *fact* in the returned list (rejected — the audit is
batch metadata, not a state, and special-casing it in the repository read awkwardly); fill `audit_id`
from a session GUC via a per-table trigger (rejected — implicit action-at-a-distance, where an explicit
write param reads plainly and was the maintainer's call); model every `sql` write 1:1 as a Fact variant
including opens/closes (rejected — reads as an event log, not a state schema, and mirrors `sql.gleam`);
keep `GENERATED ALWAYS AS IDENTITY` + `RETURNING` (rejected — forbids supplying the id, and the
`max(id)+1` mint races).

---

## ADR-033 — Consolidate the migration chain into one schema + one seed
**Status:** Accepted (supersedes the 001–018 migration files)

**Context.** The schema had been built by eighteen incremental migrations: the initial tables, the
allocation split, the event_log, the financial layer, the engineer/client/contract/project anchor
refactors, the invoice/payroll subject split, and the id sequences. Each step made sense as it landed,
but the net effect was a schema spread across a dozen rename-and-reshape files (the live `allocation`
no longer even had the `day_rate` the early files added and a later one dropped), and a seed whose
fragmented-allocation rows + a `DO`-block invariant existed only for the long-removed `v1→v2` range_agg
oracle (ADR-031). Reading "what is the schema" meant replaying the chain.

**Decision.** Collapse the chain into two files that build the final state directly: **`001_schema.sql`**
(every table, named constraint, PERIOD FK, `WITHOUT OVERLAPS` PK, `CHECK`, id sequence, the per-fact
`audit_id` FK, and the `*_current` views, in one pass) and **`002_seed.sql`** (the deterministic demo
seed with its realistic event_log history). The dead "narrow/wide" machinery is dropped: allocations
are whole-engagement rows (the cost layer derives the charge rate live from `rate_card × engineer_role`),
and the rate-cache seed invariant is gone. Verified behaviour-preserving: regenerating `sql.gleam` from
the consolidated schema is byte-identical, and the full suite (129 + 14) stays green. The DB is dropped
and recreated from the two files; there is no production database to migrate forward.

**Rationale.** The project re-baselines freely (ADR-017/024) — migrations are a means to the schema, not
a ledger to preserve. With no live database to migrate, the incremental history's only value is
documentation, which git history and these ADRs already carry. One schema file is the readable source of
truth; one seed file is the fixture. `bin/squirrel` regenerating identically is the proof the squash
changed nothing.

**Alternatives.** Keep appending migrations (rejected — the schema stays unreadable as a pile of
reshapes, and new work like the `audit_id` column adds yet another layer); a tool-generated `pg_dump`
baseline (rejected — loses the documented intent the hand-written DDL carries).

---

## ADR-034 — Leave balances as a temporal calculation: versioned per-level policy, accrued − taken, take_leave guard
**Status:** Accepted

**Context.** Leave was an unconstrained `leave` fact (an engineer on leave over a period, contained by
employment). There was no notion of entitlement or balance, so nothing stopped recording more leave
than an engineer had accrued, and "how much leave does X have on date D?" was unanswerable.

**Decision.** Model entitlement as a temporal **`leave_policy(kind, level, days_per_year,
effective_during)`** (versioned, `WITHOUT OVERLAPS` per `(kind, level)`, like `rate_card`/`salary`), and
compute the balance as a **pure as-of query** — never a stored counter. `accrued_leave(eng, kind,
as_of)` integrates `days_per_year` over each `employment ∩ engineer_role ∩ leave_policy[kind, level] ∩
(−∞, as_of)` sub-period (the same shape as `payroll_amounts`, so a promotion blends the rate across its
date); `taken_leave` sums calendar days taken; the balance is their difference. Accrual is **leap-aware**
via a `year_fraction(d)` coordinate (`year + day-of-year/year-length`), so a full leap year accrues
exactly the annual grant. `take_leave` guards on the balance **on return** (accrued − taken as of
`valid_to` ≥ days requested), rejecting a shortfall as `InsufficientLeaveBalance` (→ 422); a kind with no
policy is unlimited.

**Rationale.** The balance falls straight out of the temporal model the system already uses — it is the
leave analogue of payroll's salary integration — so it is correct at any past or future date by
construction, and a policy change ("25 days from 2027") is just another `FOR PORTION OF` versioned row
with no change to the calculation. Per-level keying makes a promotion visibly affect entitlement.
Computing rather than storing the balance means it can never drift from the facts (employment, role,
policy, leave) it derives from. Guarding on the balance *on return* matches the intent (never negative
when the engineer comes back) and lets future-dated leave draw on accrual it will have by then.

**Alternatives.** A stored running balance updated on each leave (rejected — denormalised state that can
drift from the facts and must be recomputed on any back-dated correction); a flat company-wide
entitlement ignoring level (rejected — senior levels should accrue more, and per-level is no harder given
the role-version integration); `÷ 365` accrual (rejected — drifts across leap years; the `year_fraction`
coordinate is exact). A runtime `SetLeavePolicy` command + console UI is deferred — policies are seeded
versioned data for now.

---

## ADR-035 — Demo identity gate, not real authentication
**Status:** Accepted

**Context.** The frontend overhaul (PRD-frontend.md) needs a login screen and a sense of "who is using
the app." Every operation already carries a nominal `actor` string (PRD FR-11) that lands in the
`event_log`; the question was whether to build real auth (users, password hashes, sessions, role
guards — new tables and middleware) or a lighter identity mechanism.

**Decision.** Ship a **demo identity gate**: a "sign in as" screen lists the seeded engineers and two
roles (Admin, Ops); choosing one sets the `actor` and enters the app, "sign out" returns to the gate.
No password, session token, or access control — identity only stamps the activity log. It is a client
view-state plus the existing `actor`, with **zero backend additions**.

**Rationale.** Tempo is a temporal-modelling showcase, not a security product; real auth would add
schema, middleware, and threat surface that teach nothing about the bitemporal thesis. The gate gives
the app the *feel* of multi-user accountability (named actors in the journal) for almost no cost, and
nothing about it blocks adding real auth later — it would slot in behind the same gate.

**Alternatives.** Full auth with RBAC (rejected for v1 — large, off-thesis, defer<-able); no login at
all / a free-text actor box (rejected — loses the product feel and lets the journal be stamped with
junk).

---

## ADR-036 — One global as-of date as the application's spine
**Status:** Accepted

**Context.** The old client had a slider bound to the board and timesheet only. The overhaul spans
seven pages, and the distinctive idea is *viewing the company as of a chosen instant*. Each page could
own its own date control, or one date could be shared by all.

**Decision.** A **single application-wide as-of date**, owned by a **time rail** in the top bar and
mirrored in the URL (`?date=YYYY-MM-DD`). Every page reads from it; changing it re-renders the active
page's as-of-bound views. It is **application (valid) time** — the axis the board, finance, balances,
and entity details resolve against. The **Activity** journal is **system time** (when changes were
recorded), a different axis (PRD §5), so the rail explicitly does **not** filter it; that page documents
the distinction rather than pretending the rail applies.

**Rationale.** A single shared date makes the temporal model the app's point of view rather than a
per-screen widget, and keeps deep links/reloads landing on the same instant. Modelling the rail as
valid-time (and carving Activity out as system-time) keeps the two axes honest instead of conflating
them under one slider.

**Alternatives.** Per-page date controls (rejected — fragments the thesis, lets pages disagree on
"when"); binding the rail to system time too and filtering the journal by it (rejected — conflates the
two temporal axes the project exists to distinguish).

---

## ADR-037 — Contextual operations, not one monolithic console
**Status:** Accepted

**Context.** The write model is a typed `Command` vocabulary dispatched through `POST /api/operations`
(PRD FR-9). The old client exposed it as one operations console: a `<select>` of command kinds over a
shared bag of input fields. In a multi-page app that console is both out of place and discoverable only
as a power-user screen.

**Decision.** Surface each command as a **contextual action on the page the subject lives on** —
Assign / Draft invoice on a project, Promote / Take leave / Roll off on a person, Issue / Mark paid on
an invoice, Onboard on People, Sign contract on Clients, Revise rate on Settings. Each opens a small
form pre-scoped to its subject, composes the same `Command`, and posts it to the unchanged
`/api/operations` endpoint as the signed-in actor; a refused operation shows its typed domain error
(PRD FR-5) inline. The wire contract and domain dispatch are untouched — this is purely how the writes
are presented.

**Rationale.** Actions belong next to the thing they act on; pre-scoping the form (the project/engineer
is known from context) removes the console's free-form id-typing and its main source of error. Reusing
the exact command envelope means no backend change and the Activity journal still records one row per
operation.

**Alternatives.** Keep the monolithic console as the only write surface (rejected — poor fit for a
real app, error-prone id entry); contextual actions *and* a parallel console (rejected for v1 as
redundant; a generic admin console can return later if a power-user need appears).

---

## ADR-038 — Token-only, modular CSS for the app (extends ADR-029)
**Status:** Accepted

**Context.** ADR-029 established plain-CSS sources in `client/styles/` (a `theme.css` token file plus
per-area component files wired by `main.css`, copied to `priv/static/styles` by the build). The
overhaul is much larger (shell, seven pages) and the user requires that the theme system be honoured
strictly: no hard-coded colour or size constants in any rule.

**Decision.** Keep the modular `@import` structure and extend `theme.css` into a fuller token system —
t-shirt **spacing / font-size / weight / radius** scales, semantic **colour** names, layout **sizes**,
and a **`--cat-*` categorical palette** for data-indexed colours (avatars, project swatches). **Every
rule references `var(--token)`; no rule carries a literal colour, size, weight, or radius**, and even
script-emitted inline styles reference tokens (data-driven values like a computed width % or a
`--cat-N` pick are the only inline exceptions). New per-area files (app-shell, sidebar, time-rail,
login, board, people, clients-projects, finance, activity, settings) join the `main.css` manifest in
page order.

**Amended (CSS v2 — strict consistency, enforced).** The first cut centralised too much and too finely.
The standing rules, to be upheld by every future change:
- **Small scales, not many.** Spacing is **5** steps (`--space-xs/sm/md/lg/xl`), font-size **≤6**, letter-
  spacing **3** (`tight/normal/wide`). Don't grow them; map a new need to the nearest step.
- **One shared size scale.** Component dimensions reference a shared scale step or a named layout token.
  A value that doesn't fit **snaps to the nearest step** or is achieved by layout (flex / `minmax`+`fr` /
  the spacing scale) — never a bespoke number. Viewport-relative units (`clamp()`/`%`) belong only on
  layout regions (sidebar, content width), never on atoms (icons, avatars, inputs).
- **No per-component constants.** There are **zero** CSS custom-property declarations outside `theme.css`
  and **zero** literal colours/sizes/type in component files — every value is `var(--shared-token)`. A
  new constant is allowed only as a **named, semantic, shared** token in `theme.css`, and only when it is
  a genuinely reusable decision (used, or plausibly reusable, in more than one place). "This component
  needs a number" is not a justification — snap to the scale. This bar exists specifically to stop the
  token system rotting into a pile of locally-justified one-offs.
- **Colours:** a neutral+accent palette with intent-revealing names (`--color-surface` raised vs
  `--color-surface-sunken` inset; one `--color-border`; `--color-accent` + `--color-accent-hover`; the
  brand gradient is a single `--gradient-brand` token), followed by a separate **Domain & status colours**
  section (`leave*`, invoice-lifecycle `ok`/`warn`) so domain meaning is not mixed into the base palette.
- **File split:** `base.css` is reset + element defaults + universal text utilities only; shared cross-
  page atoms (`btn`, `pill`, `panel`, `stat`, table, tabs, `kv`, op-form) live in `components.css`; page-
  specific rules live in their owner file.
- **Class naming:** BEM (`block__element--modifier`); no terse collision-prone names.
- **Enforced** by three greps that must print nothing: literal hex / literal `px|rem|em` / any `--` decl,
  each outside `theme.css` (hex also allows `login.css`'s gradient stops, and the `px` grep allows
  `responsive.css`'s media-query breakpoint — a `@media` condition cannot reference a `var(--token)`).
- **Responsive** overrides live in `responsive.css`, imported LAST so they win the cascade over the
  component base rules they relax (a media block earlier in the cascade silently loses to later
  same-specificity component rules).

**Rationale.** A single token source means re-tuning spacing or shifting the palette is a one-file edit
that propagates everywhere, and categorical colours stop being scattered literals. Extending ADR-029
rather than replacing it keeps the existing build copy-step and the styling-by-class discipline that
keeps the Playwright suite (which asserts text/ARIA, never CSS) unaffected.

**Alternatives.** A CSS framework / utility classes (rejected — drags in literals and a build
dependency, and fights the token discipline); inline styles in Lustre views (rejected — scatters
constants and defeats theming).

---

## ADR-039 — Client module split: shell + page modules
**Status:** Accepted

**Context.** `client/src/client/app.gleam` is one ~2400-line module holding model, update, view, the
slider, and every panel. The overhaul adds routing, a login gate, a global date, and seven pages —
untenable in one file, and hard to reason about or edit reliably.

**Decision.** Split the client into a **shell** plus **page modules** (ADR-014's single JS package is
unchanged — this is internal module structure). `app.gleam` keeps the top-level model, the global
as-of date, the login gate, the sidebar, and the `modem` router; routing dispatches to one module per
page under `client/page/` (`board`, `people`, `clients`, `projects`, `finance`, `activity`,
`settings`), with shared view helpers (avatar, pill, stat, panel, table, kv) in `client/ui/` and the
time rail in `client/time`. Pages import `shared/*` (the contract types/codecs) and the fetch helpers,
never each other's internals.

**Rationale.** One purpose per module makes each page independently understandable and testable, keeps
files small enough to edit reliably, and mirrors the server's web-handler-per-endpoint layout (§3).
The split is mechanical given the page boundaries the PRDs already draw.

**Alternatives.** Keep one growing module (rejected — already too large, gets far worse); split into
many JS packages (rejected — needless; ADR-014's single client package builds fine, the problem is
intra-package organisation).

---

## ADR-040 — Frontend spec: prototype-first, decomposed into umbrella + per-page PRDs
**Status:** Accepted

**Context.** "Beautiful UI" was the goal, and the overhaul is large (a shell plus seven pages). A single
combined spec would be unwieldy, and visual direction is hard to settle in prose.

**Decision.** Two structural choices. (1) **Prototype-first**: build a self-contained static HTML
prototype (rendered as an Artifact, token-only CSS, real seed-shaped data and a working as-of rail) to
settle visuals, IA, and the time-rail interaction *before* porting to Lustre. (2) **Decomposed spec**:
an umbrella `PRD-frontend.md` (login, nav, global as-of, routing, CSS/theme, visual identity, new
backend reads) plus six page PRDs (`-board`, `-people`, `-clients-projects`, `-finance`, `-activity`,
`-settings`), each carrying its own functional requirements and acceptance, built in order (shell
first). This follows the established three-doc convention (below) extended per-page for size.

**Rationale.** The prototype turns a subjective "is it beautiful" conversation into something
clickable, and its token-only CSS lifts straight into the modular files (ADR-038). Per-page PRDs keep
each spec small enough to drive one focused plan → implementation cycle, and let pages be specified and
built incrementally without one monolithic document drifting out of date.

**Alternatives.** One combined frontend spec (rejected — too large to review or implement in one pass);
porting straight to Lustre with no prototype (acceptable to the user, but rejected as the lead since
visuals were the explicit goal and are cheaper to iterate in HTML).

---

## ADR-041 — No eyebrow kickers over page headings; the section name IS the heading
**Status:** Accepted

**Context.** Page headers shipped as a three-line stack: a small uppercase "eyebrow" kicker (the section
name, e.g. FINANCE), then a large heading, then a supporting sentence. Because the real section word was
spent on the kicker, the heading had to be *invented* — which produced filler like a "FINANCE" eyebrow
over a heading literally titled **"Money"**. No business app should have a page headed "Money"; the word
"Finance" should simply have been the heading.

**Decision.** **Banned.** A page's heading is the section's own name (Board, People, Clients, Projects,
Finance, Activity, Settings) or, on a detail page, the entity's name (e.g. "Priya Sharma"). There is NO
eyebrow kicker stacked above a heading, and NO decorative/invented heading. `ui.page_head` takes no
`eyebrow`; real metadata that previously hid in a detail-page eyebrow (an engineer's level, a project's
client) moves into a plain subtitle/meta line, not an uppercase kicker. A single supporting sentence
(the blurb) below the heading is fine. This is forbidden from re-introduction: do not add an eyebrow
label above any heading, and do not invent a heading because the obvious word was used as a kicker.

(The uppercase micro-label style remains acceptable only as a *functional* label that is NOT a heading
kicker — a stat caption like "UTILIZATION", a control label like the rail's "VIEWING AS OF", a list-
group label — never stacked above a page/entity heading.)

**Rationale.** The kicker pattern is a generic-template tell that forces filler headings; removing it
makes every header say the true thing in one line. Naming the bar explicitly stops it creeping back.

**Alternatives.** Keep the eyebrow but make it non-redundant (rejected — it still demotes the real word
and invites filler); drop the heading and keep only the eyebrow (rejected — headings should be headings).

---

## Documentation format
**Status:** Accepted

Design captured as `PRD.md` (product/requirements), `ARCHITECTURE.md` (technical design), and
`DECISIONS.md` (this log) — per user request, in place of a single combined spec. These and the other
design/run docs live under `docs/` (only `README.md` stays at the repo root); superseded generations
are archived under `docs/archive/` (e.g. the original talk-first `PRD-v1-conference-talk.md`,
superseded by ADR-017) rather than deleted. Large feature areas get a companion PRD
(`PRD-financials.md`; the frontend overhaul adds `PRD-frontend.md` plus per-page PRDs — ADR-040).
