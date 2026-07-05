//// Shared access-control vocabulary: the permission keys and role names that the
//// server's authorization gate, the seed's role->permission matrix, and the client's
//// UI gating all reference, so the three never drift. The temporal role->permission
//// and user->role maps live in the database (resolved as-of the current date); these
//// constants are just the canonical strings those rows carry.

// --- Permission keys ---------------------------------------------------------

/// Read the operational app: the board, projects, and clients.
pub const read_projects = "read.projects"

/// Read all engineer data: the people roster, any engineer's detail/timesheet, and the
/// activity journal. (An engineer reading their OWN record is allowed by ownership.)
pub const read_engineers = "read.engineers"

/// Read finances: invoices, payroll, P&L, forecast, and settings.
pub const read_finances = "read.finances"

/// Update one's OWN engineer profile (contact/banking/emergency).
pub const profile_update_own = "profile.update.own"

/// Update ANY engineer's profile.
pub const profile_update_any = "profile.update.any"

/// Log one's OWN timesheet.
pub const timesheet_log_own = "timesheet.log.own"

/// Log ANY engineer's timesheet.
pub const timesheet_log_any = "timesheet.log.any"

/// Take one's OWN leave.
pub const leave_take_own = "leave.take.own"

/// Record ANY engineer's leave.
pub const leave_take_any = "leave.take.any"

pub const engineer_onboard = "engineer.onboard"

pub const engineer_promote = "engineer.promote"

pub const engineer_terminate = "engineer.terminate"

/// Confirm payroll and commit a completed onboarding draft into real engineer facts
/// (the Finance side of the Manager -> Finance hand-off).
pub const engineer_onboard_commit = "engineer.onboard.commit"

/// Assign/reallocate/roll engineers off projects.
pub const allocation_manage = "allocation.manage"

/// Sign client contracts and start projects.
pub const engagement_manage = "engagement.manage"

/// Edit project profiles, plans, and capacity requirements.
pub const project_manage = "project.manage"

/// Confirm and create a project from a completed workflow draft.
pub const project_create_confirm = "project.create.confirm"

/// Edit client profiles.
pub const client_manage = "client.manage"

pub const salary_set = "salary.set"

/// Revise the rate card.
pub const ratecard_manage = "ratecard.manage"

/// Draft/issue/pay invoices.
pub const invoice_manage = "invoice.manage"

pub const payroll_run = "payroll.run"

/// Grant and revoke users' roles (the Access management page).
pub const roles_manage = "roles.manage"

/// Create/edit capabilities, skills, and the composition matrix.
pub const skills_manage = "skills.manage"

/// Record engineer skill assessments.
pub const skills_assess = "skills.assess"

/// Set any engineer's location (country/region/timezone over time).
pub const location_manage = "location.manage"

/// Schedule/reschedule/cancel a meeting and manage its attendees.
pub const meeting_manage = "meeting.manage"

// --- Role names --------------------------------------------------------------

pub const role_engineer = "engineer"

pub const role_manager = "manager"

pub const role_finance = "finance"

pub const role_owner = "owner"

/// Every permission key — the full catalog. Used to build an all-permissions principal
/// (e.g. the dev seed, which applies financial commands through the same gate).
pub fn all() -> List(String) {
  [
    read_projects, read_engineers, read_finances, profile_update_own,
    profile_update_any, timesheet_log_own, timesheet_log_any, leave_take_own,
    leave_take_any, engineer_onboard, engineer_onboard_commit, engineer_promote,
    engineer_terminate, allocation_manage, engagement_manage, project_manage,
    project_create_confirm, client_manage, salary_set, ratecard_manage,
    invoice_manage, payroll_run, roles_manage, skills_manage, skills_assess,
    location_manage, meeting_manage,
  ]
}
