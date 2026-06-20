# Tempo — Frontend: Clients & Projects (Product Requirements)

Two related list+detail pages: clients (who we work for) and projects (the engagements under their
contracts). Grouped into one PRD because they share structure and cross-link. A page PRD under
`PRD-frontend.md` (umbrella); read the cross-cutting requirements there.

> Sources: `GET /api/roster?as_of=` (existing — client/project `Ref`s), `GET /api/clients/:id` (new),
> `GET /api/projects/:id?as_of=` (new). Detail facts from `client_profile` / `project_profile` /
> `project_plan` (`*_current` views); a project's invoices from the existing invoices read filtered to
> the project. Writes via `POST /api/operations`.

---

## 1. Purpose

Navigate the client→project→allocation chain, and see each project's team, plan, and billing as of the
date. Clients are durable identities (no validity window); projects are active over a bounded period
under a contract.

## 2. Functional requirements — Clients

- **FR-CP1 — Client list.** Name, client-since date, project count, and an active/ended status derived
  from whether any of its projects is active on the date. Rows click through to detail.
- **FR-CP2 — Client detail (`/clients/:id`).** Profile (name, since, billing contact, contract status)
  and the client's projects (each linking to project detail, with budget, target, and active/ended as
  of the date).
- **FR-CP3 — Sign contract.** A "Sign contract" action composes `SignContract` (umbrella FR-U5).
- **FR-CP4 — Edit profile.** `UpdateClientProfile` from the detail page.

## 3. Functional requirements — Projects

- **FR-CP5 — Project list.** Project (swatch + client), active/ended state as of the date, team size on
  the date, budget, and target completion. Rows click through to detail.
- **FR-CP6 — Project detail (`/projects/:id`).** Header (client, title, summary); stats (budget, team
  count on the date, billable run-rate on the date, target); the **team allocated on the date** as
  engineer cards (click through to People detail); the project's invoices with status resolved as of the
  date; and the plan (budget, target, active period).
- **FR-CP7 — Contextual actions.** Start project (`StartProject`, from the list), and on detail: Assign
  (`AssignToProject`), Draft invoice (`DraftInvoice`), edit profile (`UpdateProjectProfile`), edit plan
  (`UpdateProjectPlan`) — umbrella FR-U5.

## 4. Acceptance

- A project shows active/ended consistently between its list row and detail header for the same date.
- Scrubbing changes the project's team and run-rate; the team cards match the board's `OnProject` rows
  for that project on the same date.
- An invoice's status on project detail matches its status on the Finance page for the same date.
