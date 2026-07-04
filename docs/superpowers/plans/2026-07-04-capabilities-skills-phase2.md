# Capabilities & Skills — Phase 2 implementation plan

**Issue:** #39 (part of #24) · **Design:** `docs/2026-06-30-capabilities-skills-design.md` · **Prototype:** `docs/prototypes/2026-06-30-capabilities-skills.html` (coverage section)

Phase 1 shipped (`docs/superpowers/plans/2026-07-04-capabilities-skills-phase1.md`); its conventions, decisions D1–D8, and environment notes carry over verbatim. This plan covers the delta: `project_capability` demand + the coverage read + the project-detail Capability coverage tab.

## Resume tracker

- [x] 1. Migration (`project_capability`)
- [x] 2. SQL query files + squirrel
- [x] 3. Shared command + envelope + coverage view types
- [x] 4. Server fact / repository / handler / policy arm
- [x] 5. Server coverage read model / http / router
- [x] 6. Client project-detail Capability coverage tab + Set-requirement modal
- [x] 7. Seed (Payments gap on Ledger Migration)
- [x] 8. Tests (codec, operations clear-then-set + containment, api coverage read, e2e)
- [x] 9. Gates green

## Decisions

- **P2-D1:** Seed stays on the 3-engineer cast. The Payments gap needs only "1 covering, 2 required" — Priya covers Payments Platform at ≥ target; quantity 2 leaves a visible gap. The ~11-engineer bench moves to Phase 3 where the recommender demo needs candidates.
- **P2-D2:** No new permission. `SetProjectCapability` rides `project.manage` (design decision #7): policy `key` arm maps the new wrapper to the existing `ManageProjects` CommandKey — no access.gleam, rbac_seed, or access_test count changes.
- **P2-D3:** Coverage counting: an allocated engineer covers a requirement when their rolled-up proficiency (Phase 1 `capability_rollup` math) ≥ `target_level`, counted as whole engineers against `quantity` (allocation fraction ignored for counting; shown in the detail row). `quantity` stays `numeric(4,2)` per the design DDL.
- **P2-D4:** Deferrable PK inline (Phase 1 D1 applies: the clear-then-set write is two statements, but keep the PK `DEFERRABLE INITIALLY IMMEDIATE` for consistency with the other temporal tables in this system).

## 1. Migration

`server/priv/migrations/<timestamp>_project_capability.sql` — design DDL verbatim plus conventions:

```sql
CREATE TABLE project_capability (
  project_id      int NOT NULL REFERENCES project(id),
  capability_id   int NOT NULL REFERENCES capability(id),
  target_level    int NOT NULL CONSTRAINT project_capability_target_check CHECK (target_level BETWEEN 0 AND 4),
  quantity        numeric(4,2) NOT NULL CONSTRAINT project_capability_quantity_check CHECK (quantity > 0),
  required_during daterange NOT NULL,
  audit_id        bigint REFERENCES event_log(id),
  CONSTRAINT project_capability_no_overlap
    PRIMARY KEY (project_id, capability_id, required_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE,
  CONSTRAINT project_capability_within_run
    FOREIGN KEY (project_id, PERIOD required_during)
    REFERENCES project_run (project_id, PERIOD active_during)
);
CREATE INDEX project_capability_audit_id_idx ON project_capability (audit_id);
```

## 2. SQL + squirrel

New `server/src/tempo/server/project_capability/sql/`:

- `project_capability_clear.sql` / `project_capability_set.sql` — the bounded clear-then-set pair, mirror `project_requirement/sql/` exactly (two statements driven by `repository.record_requirement`'s shape).
- `project_capabilities.sql` — a project's requirements as-of (`required_during @> $2::date`), joined through `capability_profile` as-of for names.
- `capability_coverage.sql` — per required capability as-of: the project's allocated engineers (allocation as-of), each with rolled-up proficiency (reuse Phase 1 `capability_rollup` join shape scoped to the team), split into covering (≥ target) and not. Ranges decompose via the `lower/coalesce(upper)/upper_inf` trio; proficiency via `::numeric` → Float.

Squirrel regen with the port-corrected URL (see Phase 1 plan Environment).

## 3. Shared

- NEW `shared/src/shared/project_capability/command.gleam` — `SetProjectCapability(project_id: Int, capability_id: Int, target_level: Int, quantity: Float, valid_from: Date, valid_to: Date)`, codec mirrors `project_requirement/command.gleam` (quantity uses `lenient_float_decoder`).
- EDIT `shared/src/shared/command.gleam` — +1 wrapper variant, encode arm, decoder line.
- EDIT `shared/src/shared/access/policy.gleam` — `key`: `ProjectCapabilityCommand(_) -> ManageProjects` (P2-D2; no CommandKey/requirement changes).
- Coverage view types + codecs beside the Phase 1 ones (`shared/skill/view.gleam` or a sibling `project_capability/view.gleam`): requirement rows (capability name, target, quantity, from/to) + coverage rows (covering/non-covering engineers with proficiency and allocation share).

## 4. Server write side

- `fact.gleam`: `ProjectCapabilityRequired(project_id: ProjectId, capability_id: CapabilityId, target_level: Int, quantity: Float, from: Date, to: Date)`.
- `repository.gleam`: arm mirroring `record_requirement` (clear-then-set, audit on the set).
- NEW `server/src/tempo/server/project_capability/command.gleam` — pure `route(command)` mirroring `project_requirement/command.gleam`.
- `server/command.gleam` route arm + `auth.gleam` command_tag (`"set_project_capability"`).

## 5. Server read model

- NEW `project_capability/view.gleam` + `http.gleam` — GET `/api/projects/:id/coverage?as_of=` (or fold into the project detail read if that module composes more naturally — check `project/view.gleam` first; a separate endpoint mirrors Phase 1's engineer_skill split and keeps the tab lazily fetched).
- Router arm adjacent to the project detail route, `guard.authenticated` + the project-read guard used by the sibling route.

## 6. Client

- Project-detail **Capability coverage** tab, mirroring Phase 1's Skills tab mechanics (tab state, sibling load-state field, as-of stale guard) on the project detail page.
- Coverage bars per prototype (`.coverage*` CSS block deferred from Phase 1 — lift it into `client/styles/capabilities.scss` now): per requirement, target + have-N-of-M, gap highlight, covering engineers listed.
- "Set requirement" modal gated on `project.manage`: capability select, target level select (0–4), quantity, bounded from/to dates. Follow the page's existing write pattern (project detail hosts ui.OpKind machinery — add `OpSetProjectCapability` mirroring the bounded `OpSetRequirement` if one exists; otherwise page-local direct-submit per Phase 1 D5).

## 7. Seed

`base_seed.sql`: `project_capability` rows on Ledger Migration — Payments Platform target 3 quantity 2 (Priya covers, gap of 1) plus one fully-covered requirement for contrast. Bounded within Ledger Migration's `project_run`. One event_log CTE per logical op. Reseed ritual per Phase 1 §5.

## 8. Tests

- codec round-trip for `SetProjectCapability`.
- operations_test: clear-then-set over an existing window; re-set replaces; `project_capability_within_run` containment rejection; journal assertions.
- constraint_test: `project_capability_target_check`, `project_capability_quantity_check`, `project_capability_no_overlap` arms.
- api_test: coverage read exact values from the seed (Payments gap: covering=[Priya], need 2); 404/400/403 mirrors.
- e2e: coverage tab renders the seeded gap (bar states, covering engineer named); set-requirement flow round-trips; rbac hide/show for the Set-requirement launcher.

## 9. Gates

Phase 1 plan §11 verbatim (drop stale test/e2e DBs, clean builds, `bin/test`, `bin/erd` → SCHEMA.md, `bin/e2e`). Ports per the environment note: everything on `TEMPO_DB_PORT=5435` while the 5434 proxy wedge persists.

## Orchestration (how Phase 1 was executed — repeat it)

Staged Workflow of **Sonnet** subagents (`model: 'sonnet'`); the orchestrator only plans, unblocks, reviews, and runs final gates. This plan is detailed enough that the cheaper model executes each stage reliably.

- **Stages, sequential, one commit each, aborting the run if blocked:** migration+sql+squirrel → shared (command/envelope/policy/view types — must land together to keep `policy.key` exhaustive) → server write side → read model → client tab/modal ∥ seed+docs (parallel only because the packages are disjoint — two agents must never build the same gleam package concurrently) → tests → e2e serial run.
- **Effort tiers:** `medium` for mechanical mirroring (migration, shared, seed, codec/auth tests), `high` for fan-out or fiddly stages (server write side, client, operations/api tests, e2e).
- **Every agent prompt carries:** the plan section to execute, the mirror files to read first, `TEMPO_DB_PORT=5435`, the house rules (no inline comments, `let assert`, plain `assert ==`, `rm -rf build && gleam check` after union changes, never pipe test output through filters), explicit-path commits with no attribution lines, and a structured ok/blocked report with verification evidence.
- **After implementation:** an adversarial review workflow (Sonnet finders per dimension → per-finding refutation verifiers, only confirmed findings acted on), then a fix workflow, then the full gates. Phase 1's review confirmed 10/14 findings this way — worth the ~1M Sonnet tokens.
- Phase 1 cost ≈ 3.8M subagent tokens, ~85% Sonnet; the orchestrator model stayed out of implementation entirely.
