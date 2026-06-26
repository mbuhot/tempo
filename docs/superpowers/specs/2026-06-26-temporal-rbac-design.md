# Temporal RBAC — Permissions, Roles, and Access Management — Design

**Date:** 2026-06-26
**Status:** approved (design); implementation pending
**Builds on:** 2026-06-26-password-authentication-design.md (signed-cookie session, `account` table)

## Goal

Replace the single `Admin | Ops | Engineer` role with a **temporal, permission-based**
authorization system:

- **Permissions** are first-class catalog entries; **roles** are composed *sets* of
  permissions. There are four roles — **Engineer, Manager, Finance, Owner**.
- Both the role→permission mapping (`role_permission`) and the user→role mapping
  (`user_role`) are **temporal** (`daterange`, `WITHOUT OVERLAPS`), so grants are
  effective-dated and auditable as-of any date — matching the codebase's temporal-fact
  idiom (ADR-030).
- The gate covers **reads and writes** server-side. **Ownership** is enforced: an
  Engineer may read/update only *their own* engineer record.
- Owners get a **management UI** to assign/revoke user roles (a journaled, temporal
  operation) and to **visualize the role→permission matrix**.
- The client hides tabs/actions a user's permissions don't grant (UI gating on top of
  the server gate).

## 1. Data model

Mirrors the `engineer_role` temporal pattern (date ranges, `WITHOUT OVERLAPS`,
`audit_id` provenance, constraint-name suffixes `_no_overlap` / `_check`). Parents
here (`role`, `permission`, `account`) are **not** temporal facts, so plain FKs — no
PERIOD FK.

```sql
-- Static catalogs ("permissions just exist"; roles name a permission set)
CREATE TABLE permission (key text PRIMARY KEY, description text NOT NULL);
CREATE TABLE role       (name text PRIMARY KEY, description text NOT NULL);

-- Temporal: which permissions a role grants, over time
CREATE TABLE role_permission (
  role           text NOT NULL REFERENCES role(name),
  permission     text NOT NULL REFERENCES permission(key),
  granted_during daterange NOT NULL,
  audit_id       int NOT NULL REFERENCES event_log(id),
  CONSTRAINT role_permission_no_overlap
    PRIMARY KEY (role, permission, granted_during WITHOUT OVERLAPS)
);

-- Temporal: which roles a user (account) holds, over time
CREATE TABLE user_role (
  account_id  int NOT NULL REFERENCES account(id),
  role        text NOT NULL REFERENCES role(name),
  held_during daterange NOT NULL,
  audit_id    int NOT NULL REFERENCES event_log(id),
  CONSTRAINT user_role_no_overlap
    PRIMARY KEY (account_id, role, held_during WITHOUT OVERLAPS)
);

-- Link an account to its engineer (for ownership); drop the now-redundant role column
ALTER TABLE account ADD COLUMN engineer_id int REFERENCES engineer(id);
ALTER TABLE account DROP COLUMN role;
```

A user may hold several roles at once (distinct `role` rows); `WITHOUT OVERLAPS` only
forbids the *same* (account, role) overlapping itself. **Effective permissions =
union of `role_permission` over every role held, as-of `CURRENT_DATE`:**

```sql
SELECT DISTINCT rp.permission
  FROM user_role ur
  JOIN role_permission rp ON rp.role = ur.role
 WHERE ur.account_id = $1
   AND ur.held_during    @> CURRENT_DATE
   AND rp.granted_during @> CURRENT_DATE;
```

## 2. Permission catalog + role matrix

Ownership permissions are `.own` / `.any` pairs. The ownership rule: a command/read
targets engineer `E` → allow if the user has the `.any` form, **or** the `.own` form
and `account.engineer_id == E`.

| Permission | Engineer | Manager | Finance | Owner |
|---|:-:|:-:|:-:|:-:|
| `read.projects` — board, projects, clients | ✓ | ✓ | ✓ | ✓ |
| `read.engineers` — roster, any engineer/timesheet, activity log | | ✓ | ✓ | ✓ |
| `read.finances` — invoices, payroll, pnl, forecast, settings | | ✓ | ✓ | ✓ |
| `profile.update` (own / any) | own | any | | any |
| `timesheet.log` (own / any) | own | any | | any |
| `leave.take` (own / any) | own | any | | any |
| `engineer.onboard` | | ✓ | | ✓ |
| `engineer.promote` | | ✓ | | ✓ |
| `engineer.terminate` | | ✓ | | ✓ |
| `allocation.manage` | | ✓ | | ✓ |
| `engagement.manage` — sign contract / start project | | ✓ | | ✓ |
| `project.manage` — project details + requirements | | ✓ | | ✓ |
| `client.manage` | | ✓ | | ✓ |
| `salary.set` | | | ✓ | ✓ |
| `ratecard.manage` | | | ✓ | ✓ |
| `invoice.manage` — draft/issue/pay | | | ✓ | ✓ |
| `payroll.run` | | | ✓ | ✓ |
| `roles.manage` — grant/revoke user roles | | | | ✓ |

Owner holds **every** permission (incl. both `.own` and `.any` forms). An Engineer
reading their *own* engineer detail/timesheet is allowed by the ownership rule even
without `read.engineers`.

### Command → permission map (the write gate, all sub-commands)

| Command (aggregate · constructor) | Permission | Ownership target |
|---|---|---|
| Engineer · OnboardEngineer | `engineer.onboard` | — |
| Engineer · Promote | `engineer.promote` | — |
| Engineer · TerminateEmployment | `engineer.terminate` | — |
| EngineerDetails · Update{Contact,Banking,Emergency} | `profile.update` | engineer_id |
| Allocation · {Assign,ChangeFraction,RollOff} | `allocation.manage` | — |
| Engagement · {SignContract,StartProject} | `engagement.manage` | — |
| Leave · TakeLeave | `leave.take` | engineer_id |
| Timesheet · {LogTimesheet,LogWeek} | `timesheet.log` | engineer_id |
| ClientDetails · UpdateClientProfile | `client.manage` | — |
| ProjectDetails · Update{Profile,Plan} | `project.manage` | — |
| ProjectRequirement · SetProjectRequirement | `project.manage` | — |
| RateCard · {ReviseRateCard,AdjustRateForPortion} | `ratecard.manage` | — |
| Salary · SetSalary | `salary.set` | — |
| Invoice · {Draft,Issue,Pay} | `invoice.manage` | — |
| Payroll · RunPayroll | `payroll.run` | — |
| Role · {GrantUserRole,RevokeUserRole} *(new)* | `roles.manage` | — |

### Read endpoint → permission map (the read gate)

| Route | Permission |
|---|---|
| `/api/board` | `read.projects` |
| `/api/projects`, `/api/projects/:id`, `/api/clients`, `/api/clients/:id` | `read.projects` |
| `/api/people` | `read.engineers` |
| `/api/roster` | `read.projects` (it feeds the operational Board, not the HR People page) |
| `/api/engineers/:id` | `read.engineers` **or own** |
| `/api/timesheet?engineer=` | `read.engineers` **or own** |
| `/api/invoices`, `/api/invoices/:id`, `/api/payroll`, `/api/pnl`, `/api/forecast`, `/api/settings` | `read.finances` |
| `/api/events` (activity log) | `read.engineers` |
| `/api/access` *(new)* | `roles.manage` |

## 3. Authorization resolution

The signed session cookie can no longer carry a static role. It carries **`account_id`**
only (signed, as before). Per authenticated request the server resolves:

```gleam
pub type Principal {
  Principal(
    account_id: Int,
    actor: String,            // display_name, stamped on the journal
    engineer_id: Option(Int), // for ownership
    permissions: Set(String), // resolved as-of CURRENT_DATE (§1 query)
  )
}
```

- **`session.gleam`** — `issue` signs `account_id`; `principal(request, ctx)` verifies the
  cookie then loads the `Principal` from the DB (`account` row + the effective-permission
  query). `Error` on bad cookie or missing account.
- **`auth.gleam`** becomes the permission model: `required(command) -> #(permission, Owns)`
  where `Owns = NoOwnership | OwnsEngineer(Int)`; `authorize(principal, command)` checks
  the set (applying ownership) → `Forbidden` otherwise. Called in `command.dispatch`
  before the tx, exactly as today. The `Role` enum is removed.
- **Reads** — a `web/guard.require(req, ctx, permission, next)` resolves the principal,
  401s if unauthenticated, 403s if the permission is absent, else calls `next(principal)`.
  The router wraps each read route with its permission. The two ownership reads parse
  their target id and call `guard.require_engineer_read(...)` (allows `read.engineers`
  **or** own).
- **Login** returns `{actor, permissions:[…]}`; the client stores the set and gates the
  UI. (No session-restore-on-reload in scope; a cold reload still shows the gate, then
  login returns fresh permissions.)

## 4. Role management (commands + Access page)

### Commands (new `Role` aggregate, `shared/role/command`)
- `GrantUserRole(account_id, role, effective)` — open `user_role [effective, ∞)` for that
  pair if not currently held (idempotent).
- `RevokeUserRole(account_id, role, effective)` — `DELETE … FOR PORTION OF held_during
  FROM effective TO NULL` (caps the held period; mirrors `engineer_role_close_all`).

Both require `roles.manage`, run through the existing operations pipeline (journaled with
`audit_id`), and are Owner-only via the matrix.

### Read endpoint `GET /api/access` (permission `roles.manage`)
Returns, as-of today: the **roles** with their permission keys (the matrix), the full
**permission** catalog, and the **users** (accounts) with `account_id`, `username`,
`display_name`, `engineer_id`, and current `roles`.

### Client — new Owner-only "Access" page (sidebar item gated by `roles.manage`)
1. **Role → permission matrix** rendered as the visualization table in §2 (roles as
   columns, permissions as rows, ✓ where granted) — read-only, driven by `/api/access`.
2. **Users** list: each account with its current role chips and Owner controls to
   **grant** a role (select role → POST GrantUserRole effective today) or **revoke** one
   (POST RevokeUserRole effective today). The list refetches after each change and the
   Activity journal shows the grant/revoke event.

Editing the role→permission matrix itself (changing what a role grants) is **out of
scope** — the table is temporal and seed-defined; the matrix view is read-only for now.

## 5. Client UI gating

Login response carries `permissions`. The shell stores them on the model and:
- shows sidebar items by permission — Board/Projects/Clients (`read.projects`),
  People + Activity (`read.engineers`), Finance + Settings (`read.finances`), Access
  (`roles.manage`);
- hides/disables in-page actions lacking their permission — Promote (`engineer.promote`),
  Assign/RollOff (`allocation.manage`), onboard/terminate (`engineer.*`), invoice actions
  (`invoice.manage`), Run Payroll (`payroll.run`), Set Salary (`salary.set`), rate-card
  edits (`ratecard.manage`), profile edit on a detail page (`profile.update` own/any).

The server gate remains the security boundary; UI gating is for usability only.

**Implemented so far:** sidebar gating (each role sees only its tabs) + the Access page.
**Still pending:** hiding individual in-page action buttons (e.g. Promote on the engineer
detail, Run payroll on Finance) for a role that can open the page but lacks that one
permission. Until then those buttons are visible but the server refuses the write with a
403 — secure, but a rough edge for Finance/Manager. Threads `model.permissions` into each
page view.

## 6. Seed + migration

- Seed the `permission` catalog (all keys above) and `role` catalog (the four roles),
  and `role_permission` to the §2 matrix (effective from a back-date, open-ended), under
  a seed `event_log` row for `audit_id`.
- Map the existing dev accounts via `user_role`: `admin@`→**owner**, `ops@`→**manager**,
  the three engineers→**engineer**; add a new `finance@alembic.com.au`→**finance**. Link
  each engineer account's `engineer_id` by matching its seeded email to `engineer_contact`.
- Done idempotently in `tempo/seed` (alongside the account seed), outside the
  `already_seeded` guard, so it backfills an existing dev DB. Dev password unchanged.

## 7. Testing

- **gleam**: effective-permission resolution as-of a date (incl. a revoked/expired grant
  excluded); `authorize` for each command per role (the §2 map); ownership (own ✓, other
  ✗, `.any` ✓ for either); read-guard 401/403; `GrantUserRole`/`RevokeUserRole` open and
  cap `user_role`; `/api/access` shape.
- **e2e**: each role sees only its sidebar items; Engineer edits own profile but 403s on
  another engineer's and can't see Finance; Manager promotes/allocates but can't set
  salary; Finance runs payroll but can't allocate; Owner opens Access, sees the matrix,
  grants Manager a role and the user gains the tab.

## 8. Out of scope (future)

Editing the role→permission matrix at runtime; session-restore-on-reload (`/api/me`);
delegated/least-privilege sub-roles; per-field profile permissions; rate-limiting. The
temporal tables support effective-dated future grants via seed/SQL even before a UI exists.
