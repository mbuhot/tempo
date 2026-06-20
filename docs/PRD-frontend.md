# Tempo — Frontend Application (Product Requirements, umbrella)

Turn the Lustre SPA from a dev-only command-driver into a real consultancy-management application:
a login gate, persistent navigation, routed pages, and one global "as-of" date that every page
respects. Same stack and same discipline as the rest of Tempo — reads are as-of queries, writes go
through the command bus (`POST /api/operations`), and the bitemporal model stays the centerpiece.

> Companion to `PRD.md` (the core staffing model) and `PRD-financials.md`. This is the **umbrella**
> spec for the frontend overhaul: it owns the cross-cutting concerns (shell, identity, the global
> as-of date, routing, the CSS/theme system, visual identity, and the new backend reads). Each page is
> specified in its own PRD (§3). See `ARCHITECTURE.md §14` for the client architecture and
> `DECISIONS.md` for the frontend ADRs (ADR-035…).

---

## 1. Motivation

The current client (`client/src/client/app.gleam`, ~2400 lines) is a single screen: a slider, the
board, a timesheet, an operations console, and an event-log panel stacked together. It proves the
temporal model but is not an application — there is no sense of *who is using it*, no navigation, no
separable pages, and every capability is on one scroll. The backend is feature-complete (board,
timesheet, operations, events, invoices, payroll, P&L, roster); the gap is almost entirely on the
client, plus a thin login gate and a few new read endpoints.

The overhaul makes Tempo feel like a product an engineering consultancy would actually run on, while
making its one distinctive idea — *scrub to any date and the whole company re-renders as of that
instant* — the spine of the entire UI rather than one control on one screen.

## 2. The thesis: one global as-of date

Every page reads from a single application-wide **as-of date**, owned by a **time rail** in the top
bar (a slider with year ticks, a date input, day-step buttons, and a "Today" reset). Moving it
re-renders the board, the roster, finance, balances, project teams — all to the same instant. The
as-of date is mirrored in the URL so a link or reload reopens on the same moment. This is the
product's point of view: you do not look at "now," you look at a *chosen* point in time. (The Activity
journal is the one system-time view; see its PRD for how the date applies there.)

## 3. Decomposition — the page PRDs

The work is too large for one spec, so it is split into this umbrella plus six page PRDs. Build order
is top-to-bottom: the shell (this PRD) first, then each page.

| PRD | Covers | Primary reads |
|---|---|---|
| **PRD-frontend.md** (this) | Login gate, sidebar, time rail, routing, CSS/theme system, visual identity, new read endpoints | — |
| **PRD-frontend-board.md** | The org board: stats, by-project allocations, on-leave, unassigned | `GET /api/board` |
| **PRD-frontend-people.md** | Roster + engineer detail (facts, history, allocations, leave, timesheet) | `GET /api/people`, `/api/engineers/:id`, `/api/timesheet` |
| **PRD-frontend-clients-projects.md** | Client list/detail and project list/detail | `roster`, `GET /api/clients/:id`, `/api/projects/:id` |
| **PRD-frontend-finance.md** | Invoices (lifecycle), Payroll, P&L | `invoices`(+`:id`), `payroll`, `pnl` |
| **PRD-frontend-activity.md** | The `event_log` provenance journal | `GET /api/events` |
| **PRD-frontend-settings.md** | Rate card, salary bands, leave policy | rate card / salary / `leave_policy` reads |

## 4. Cross-cutting functional requirements

- **FR-U1 — Application shell.** A persistent left **sidebar** (brand, primary navigation, the
  signed-in identity) and a top **time rail**, with routed page content between them. Replaces the
  single stacked screen.
- **FR-U2 — Demo identity gate.** A "sign in as" screen lists the seeded engineers and two roles
  (Admin, Ops). Choosing one sets the nominal `actor` already carried by `OperationRequest` (PRD
  FR-11) and enters the app; "sign out" returns to the gate. No password, session, or security —
  identity only stamps the activity log (ADR-035).
- **FR-U3 — Global as-of date.** One application-wide as-of date, owned by the time rail and mirrored
  in the URL (`?date=YYYY-MM-DD`). Changing it re-renders every as-of-bound view on the active page.
  The rail offers a slider over the seed range, a date input, single-day step, and "Today" (ADR-036).
- **FR-U4 — Routing & deep links.** Client-side routes for each page and for entity details
  (`/people/:id`, `/clients/:id`, `/projects/:id`), via `lustre/modem`. Routes are deep-linkable and
  honor browser back/forward; the as-of date persists across navigation.
- **FR-U5 — Contextual operations.** The typed command vocabulary (PRD FR-9) is surfaced as
  contextual actions on the page each belongs to (the per-page PRDs enumerate which). Each opens a form
  that composes a `Command` and posts it to `POST /api/operations` as the signed-in actor, exactly as
  the console does today; a rejected operation surfaces the server's typed domain error (PRD FR-5)
  inline (ADR-037).
- **FR-U6 — Themed, modular CSS.** All styling is token-driven: a single token source (`theme.css`)
  plus per-area component files, with **no literal colour, size, weight, or radius in any rule** —
  only `var(--token)` references. Categorical colours (avatars, project swatches) are `--cat-*`
  tokens, not inline hex (ADR-038, extending ADR-029).
- **FR-U7 — Visual identity.** Modern-SaaS aesthetic: neutral cool palette with one indigo/violet
  accent, monospace for temporal and financial figures (dates, money, counts) to reinforce the
  bitemporal/ledger nature, and a clock-dial brand mark (a moment marked on a dial — the as-of idea).

## 5. New backend reads required

The write path is unchanged — every operation already exists as a `Command` and a `POST /api/operations`
dispatch. The pages do need read endpoints the current API does not expose, all as-of queries over the
existing `*_current` views and fact tables (ARCHITECTURE §14):

- `GET /api/people?as_of=` — the roster list with each engineer's level, status, allocation, and leave
  balance as of the date (a superset of what the board already computes).
- `GET /api/engineers/:id?as_of=` — the engineer detail bundle: contact / banking / emergency, the
  employment and role history, allocations, and leave balance + history.
- `GET /api/clients/:id` and `GET /api/projects/:id?as_of=` — the client / project detail bundles
  (profile, contracts / plan, related entities).
- Settings reads for the rate card, salary bands, and leave policy (a `GET /api/settings` or per-table
  reads — decided in the Settings PRD/plan).

These reuse the domain's existing as-of machinery; no schema change is required.

## 6. Success criteria

- Signing in as a person, then scrubbing the time rail, re-renders the active page as of the chosen
  date — including past dates (history) and future dates (scheduled facts), with no reload.
- Each of the seven pages is reachable by sidebar navigation and by a deep link, and entity detail
  pages are deep-linkable with the as-of date preserved.
- A contextual action composes and posts the same `Command` the console does today, the change appears
  in the Activity log stamped with the signed-in actor, and a refused operation shows its typed error.
- No CSS rule contains a literal colour or size; re-tuning a token in `theme.css` re-themes the app.
- The existing Playwright beats (board/slider, timesheet, operations, financials) still pass against
  the new shell (selectors updated to the new layout; behaviour unchanged).

## 7. Non-goals (this iteration)

Real authentication, passwords, sessions, or role-based access control (ADR-035); mobile-first layout
(the app degrades responsively but targets desktop); offline mode; internationalization; a separate
design-system/component package.
