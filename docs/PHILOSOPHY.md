# Philosophy

The codebase optimizes for the next change being safe. Every convention is set up so that deviation is a compile error, a failed gate, or a crash.

## Articulate the domain

The first priority is to clearly articulate the domain concepts. The system is decomposed by domain concept — engineer, project, client, allocation, leave, invoice — and every module belongs to exactly one concept.

```
shared/src/shared/<concept>/
  command.gleam        # write contract + JSON codec
  view.gleam           # read-model types + JSON codecs

server/src/tempo/server/<concept>/
  command.gleam        # write handling
  view.gleam           # read queries
  http.gleam           # routes
  sql/*.sql            # hand-written queries
  sql.gleam            # generated (squirrel)

client/src/tempo/client/pages/<concept>.gleam
```

A newcomer should be able to understand a concept by reading one directory.

Names are domain-literal and carry the semantics: temporal ranges are named for the predicate they assert (`employed_during`, `held_during`, `allocated_during`), operations for the business action (`onboard_engineer`, `promote`, `roll_off`).

## Scale through modularity

The system grows by adding concepts. Each addition is a new directory with a small, predictable set of files.

- Split a file before it reaches a thousand lines; the split boundary is a domain idea with a name.
- Split a directory before its file listing stops telling the story; every file's purpose should be obvious from its name and location.
- Cross-cutting modules (`wire`, `access/policy`, `repository`) stay few, small, and domain-neutral.
- Sanctioned exception: `repository.gleam` grows with every concept because it is the one place a fact's write semantic lives. Its job is mechanical fact→SQL mapping with near-zero logic, so it scales by organization — one clearly divided section per concept — while keeping the one-seam property.
- Prune machinery that stops earning its keep. Infrastructure must justify itself continuously.

## Make the machine enforce the rules

Recurring judgments are pushed into something that fails loudly.

- **Exhaustive unions as architecture.** `Command`, `Fact`, `CommandKey` are closed unions; adding a variant is a compile error at every site that must handle it.
- **Illegal states unrepresentable.** Opaque `Money`, single-constructor id wrappers (`EngineerId`, `ProjectId`), status unions in place of boolean flags.
- **Constraints in the database.** Overlap and containment rules live in Postgres (`WITHOUT OVERLAPS`, `FOR PORTION OF`, period FKs); violations are classified into typed `OperationError`s at the seam.
- **Gates in `bin/test`.** Formatting, the CSS token lint, and the test suite run as one gate.
- **Generated where drift is possible.** Typed SQL comes from squirrel introspecting the live schema; the ER diagram is regenerated from `pg_catalog`.

### Vocabularies are closed or data-driven

Every domain vocabulary (a status, kind, or level) is exactly one of two things, decided by one test: **does code branch on the value?**

- **Closed** — code branches on it (a `case`, a transition guard, per-value UI treatment). Define a union in `shared`; mirror it with a DB `CHECK`; make `to_string`/`from_string` exhaustive with zero catch-all arms — an unknown value from the DB is a violated invariant and crashes. Adding a value is adding a variant, and the compiler names every site that must handle it.
- **Data-driven** — code treats every value uniquely by identity only (store, compare, join) and the set may grow without a deploy. The DB table is the authority; UI option lists come from a query; code contains zero literals of the vocabulary.

Each vocabulary has one authoritative definition; every other appearance is derived from it. A string literal of a closed vocabulary outside its union module, or a hardcoded option list for a data-driven one, is a review-visible violation. The hybrid — literals scattered through code with an open set — makes each site its own authority and is the failure mode this rule exists to prevent.

## One seam per concern

- All writes flow through `POST /api/operations` → authorize → one transaction → route → append to `event_log`. A fact's write semantic lives in exactly one place.
- The permission policy is defined once in `shared/access/policy` and consumed by both server enforcement and client gating.
- Dependencies (`Context`, `pog.Connection`) are passed explicitly as function arguments.

## Facts can change; ledgers cannot

The domain is temporal in valid time: the business talks about its state in the past and future, and the data is our recording of that truth — fallible, and corrected when wrong. A back-dated correction rewrites fact rows through the write seam; that is the system working as designed.

- The `event_log` records who changed what, when, and why. It exists for audit and human understanding.
- Where a correction has real-world consequences — financials above all — an immutable **ledger** (invoices, payroll runs) records what was actually issued or paid. A correction to facts leaves the ledger untouched; **reconciliation** recomputes from the current facts and surfaces the discrepancy to the operator. A back-dated pay rise shows as back-pay owing in payroll reconciliation; a corrected rate card recomputes the invoice and yields a credit note.
- Transaction-time reconstruction of the database is a job for the Postgres transaction log. History is preserved where it carries a business meaning, and a ledger plus reconciliation is that meaning for financials.

## Crash loudly on violated invariants

`Result` plumbing is the default for expected failures. `let assert` and `panic` are reserved for stated invariants — a violated SQL invariant or a routing bug should crash with a message naming the bug. A defensive fallback that fabricates a value launders the bug into silent data corruption.

## Test against real things

- DB tests run against real Postgres inside rolled-back transactions.
- Test data comes from a deterministic seed; assertions trace to specific seed facts.
- Test names are behavioural sentences (`promotion_blends_accrual_rate_test`); e2e asserts what the user sees, via ARIA roles and visible content.
- e2e locates elements by their accessible affordances: field labels, roles, alt text, accessible names. When only a CSS class can find an element, the element is missing accessibility metadata — fix the markup, then the locator.

## Keep decisions on the record

`DECISIONS.md` holds ADRs with a status lifecycle. Superseded decisions stay, with a pointer to what replaced them — including reversals and why. Module doc headers state each module's one purpose and its place in the architecture.

## Kept out

Things deliberately absent, to stay absent:

- ORMs, DI containers, decorators, auto-wiring, framework magic that hides the seam.
- Mocks and stubs; factory-sequence assertions; conditional assertions; tests asserting CSS classes, ids, or internal DOM structure; tests that a non-feature is absent.
- Boolean flags for state (especially co-varying pairs); stringly-typed domain values; generic names (`valid_at`, `data`, `types.gleam`).
- Function-grouped buckets (`codecs/`, `handlers/`, `routes/`) that scatter a concept across the tree.
- Inline narration comments inside functions.
- Defensive fallbacks that swallow invariant violations; writes bypassing the operations seam; corrections applied to a ledger in place of reconciliation.
- Config sprawl and speculative abstraction.
