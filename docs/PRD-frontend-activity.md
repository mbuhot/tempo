# Tempo — Frontend: Activity (Product Requirements)

The provenance journal — every operation that has been applied to the workspace, newest first. A page
PRD under `PRD-frontend.md` (umbrella); read the cross-cutting requirements there.

> Source: `GET /api/events` → `List(Event)` (`id`, `occurred_at`, `actor`, `operation`, `summary`,
> `payload`). No new endpoint required.

---

## 1. Purpose

Make the system-time audit trail (PRD FR-11) browsable: who did what, when, and the exact command
payload. One row per *operation*, not per fact-row touched.

## 2. Functional requirements

- **FR-AC1 — Journal.** A list of events newest-first, each row showing the recorded time
  (`occurred_at`), the operation tag, the human summary, and the actor (with avatar for a known
  engineer). Backed by `GET /api/events`.
- **FR-AC2 — Payload inspection.** A row expands to show its `payload` verbatim (the command re-encoded
  as JSON), rendered monospaced.
- **FR-AC3 — Time range (system time).** The journal is filtered by a **recorded-between** range over
  `occurred_at`, with quick presets (Today, Last 7 days, Last 30 days, This month, All time) and an
  explicit from/to. It defaults to a recent window (Last 30 days) rather than the unbounded history, so
  the page opens on something useful. The selected range is reflected in the URL alongside the route.
- **FR-AC4 — Operation & actor filters.** Filter the (time-ranged) journal by operation and by actor.
  Every filter changes the visible rows (the list content), not merely a chip, and combines with the
  time range.

## 3. The as-of date and this page (decision)

The global as-of date is **application time** — the date you are viewing the company *as of*. The event
log is **system time** — when each change was recorded. These are different axes (PRD §5), so the
top-bar time rail (valid time) does **not** drive this journal; Activity carries its **own system-time
range** (FR-AC3) instead. This is the one page whose content the global rail does not re-render, and the
UI must make that distinction legible — a clearly-labelled "recorded between" control on the page, not a
silent reuse of (or a silent ignoring of) the rail. As a convenience the page may offer a one-click
"jump to the rail's date" that sets the recorded-between range around the current as-of date, but the
two controls stay visibly separate.

> Filtering is server-side where it matters: `GET /api/events` gains optional `from`/`to`
> (system-time bounds) and may gain `operation`/`actor` params, so the journal need not ship the entire
> history to the client to filter it. Settled in the plan; the contract addition is small and additive.

## 4. Acceptance

- Opening Activity shows a bounded, recent window by default, newest-first — not the entire history.
- Choosing a preset or an explicit from/to changes which events are listed (by `occurred_at`).
- Operation and actor filters combine with the time range to reduce the visible rows.
- Every applied operation (including those performed via contextual actions on other pages) appears as
  a row with its actor and an expandable payload when within the selected range.
