//// The FULLY-ENUMERATED contextual-operation form engine: `OpKind` covers every
//// `Command`-backed write across all seven pages, `OpField` is the superset of
//// every command's fields, and `build_command` is TOTAL over `OpKind`. Launcher
//// gating mints an opaque `Permit` through the SAME `shared/access/policy` table
//// the server enforces with.

import client/time
import client/ui/atoms.{type ButtonKind, type ButtonSize, Medium, Primary}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/access/policy
import shared/allocation/command as allocation_command
import shared/client/command as client_command
import shared/command.{type Command} as gateway
import shared/engagement/command as engagement_command
import shared/engineer/command as engineer_command
import shared/engineer_skill/command as engineer_skill_command
import shared/invoice/command as invoice_command
import shared/leave/command as leave_command
import shared/location/command as location_command
import shared/meeting/command as meeting_command
import shared/money
import shared/payroll/command as payroll_command
import shared/project/command as project_command
import shared/project_capability/command as project_capability_command
import shared/rate_card/command as rate_card_command
import shared/roster/view.{type Ref}
import shared/salary/command as salary_command
import shared/timesheet/command as timesheet_command

/// Every contextual operation a page can compose. One variant per `Command`-backed
/// write (PRD §6) — frozen here so adding a page never widens this union.
pub type OpKind {
  OpOnboardEngineer
  OpCreateProject
  OpPromote
  OpTakeLeave
  OpRollOff
  OpTerminateEmployment
  OpUpdateContact
  OpUpdateBanking
  OpUpdateEmergency
  OpLogWeek
  OpSignContract
  OpUpdateClientProfile
  OpStartProject
  OpAssignToProject
  OpChangeAllocationFraction
  OpUpdateProjectProfile
  OpUpdateProjectPlan
  OpDraftInvoice
  OpIssueInvoice
  OpPayInvoice
  OpRunPayroll
  OpReviseRateCard
  OpAdjustRateForPortion
  OpSetSalary
  OpSetProjectRequirement
  OpAssessSkill
  OpSetProjectCapability
  OpSetLocation
  OpRescheduleMeeting
  OpCancelMeeting
  OpAddAttendee
  OpRemoveAttendee
}

/// The shared command key a launcher's op resolves to — so the client gates each
/// launcher through the SAME `shared/access/policy` table the server enforces with,
/// never a parallel permission list. Total over `OpKind`: a new op must say which
/// command it composes. (The permission each key needs lives once, in the shared policy.)
fn op_command_key(kind: OpKind) -> policy.CommandKey {
  case kind {
    OpOnboardEngineer -> policy.Onboard
    OpCreateProject -> policy.ManageEngagement
    OpPromote -> policy.Promote
    OpTerminateEmployment -> policy.Terminate
    OpUpdateContact -> policy.UpdateProfile
    OpUpdateBanking -> policy.UpdateProfile
    OpUpdateEmergency -> policy.UpdateProfile
    OpTakeLeave -> policy.TakeLeave
    OpLogWeek -> policy.LogTimesheet
    OpRollOff -> policy.ManageAllocation
    OpAssignToProject -> policy.ManageAllocation
    OpChangeAllocationFraction -> policy.ManageAllocation
    OpSignContract -> policy.ManageEngagement
    OpStartProject -> policy.ManageEngagement
    OpUpdateClientProfile -> policy.UpdateClient
    OpUpdateProjectProfile -> policy.ManageProject
    OpUpdateProjectPlan -> policy.ManageProject
    OpSetProjectRequirement -> policy.ManageProject
    OpSetProjectCapability -> policy.ManageProject
    OpDraftInvoice -> policy.ManageInvoice
    OpIssueInvoice -> policy.ManageInvoice
    OpPayInvoice -> policy.ManageInvoice
    OpRunPayroll -> policy.RunPayroll
    OpReviseRateCard -> policy.ManageRateCard
    OpAdjustRateForPortion -> policy.ManageRateCard
    OpSetSalary -> policy.SetSalary
    OpAssessSkill -> policy.AssessSkills
    OpSetLocation -> policy.ManageLocation
    OpRescheduleMeeting -> policy.ManageMeeting
    OpCancelMeeting -> policy.ManageMeeting
    OpAddAttendee -> policy.ManageMeeting
    OpRemoveAttendee -> policy.ManageMeeting
  }
}

/// A CAPABILITY to launch a write op: proof that the acting principal's permissions (and
/// ownership, where the op is ownership-sensitive) satisfy the op's requirement under the
/// shared policy. Opaque, and minted ONLY by `permit` — so a launcher message that
/// carries a `Permit` cannot be constructed without the check having passed. An ungated
/// launcher therefore cannot be expressed: forgetting to gate, or gating with the wrong
/// permission, is a COMPILE error, not a button that 403s. The server stays the boundary.
pub opaque type Permit {
  Permit(kind: OpKind)
}

/// Mint a permit to launch `kind` iff `permissions` (with `own` = the principal owns the
/// record the op targets, which only matters for the ownership-sensitive ops) satisfy the
/// shared write policy; `Error(Nil)` otherwise. The sole source of a `Permit`.
pub fn permit(
  permissions: Set(String),
  own own: Bool,
  kind kind: OpKind,
) -> Result(Permit, Nil) {
  case
    policy.satisfies(
      permissions,
      own:,
      requirement: policy.requirement(op_command_key(kind)),
    )
  {
    True -> Ok(Permit(kind))
    False -> Error(Nil)
  }
}

/// The op a permit authorizes — for an `update` handler to open the matching form from
/// the permit its launcher message carried.
pub fn permit_kind(permit: Permit) -> OpKind {
  permit.kind
}

/// Render `build(permit)` only when the op is permitted, otherwise nothing. The element
/// `build` returns can only carry the permit it is handed, so a launcher rendered through
/// `when_permitted` is always authorized — even a raw `html.button` (e.g. one that needs
/// `stop_propagation`, which the `button` atom does not expose).
pub fn when_permitted(
  permit: Result(Permit, Nil),
  build: fn(Permit) -> Element(msg),
) -> Element(msg) {
  case permit {
    Ok(granted) -> build(granted)
    Error(_) -> element.none()
  }
}

/// A permitted op-launching `button`: shown only when `permit` was granted, dispatching
/// `to_msg(permit)` (the page's op-start message, which therefore carries the permit).
pub fn launch(
  permit: Result(Permit, Nil),
  to_msg to_msg: fn(Permit) -> msg,
  label label: String,
  kind kind: ButtonKind,
  size size: ButtonSize,
) -> Element(msg) {
  when_permitted(permit, fn(granted) {
    atoms.button(label:, kind:, size:, on_press: to_msg(granted))
  })
}

/// THE canonical page-level primary action: a `launch` fixed to `Primary, Medium`,
/// the one style every list page uses for its primary action so the title bar reads
/// identically everywhere. Medium balances the large page title.
pub fn page_action(
  permit: Result(Permit, Nil),
  to_msg: fn(Permit) -> msg,
  label: String,
) -> Element(msg) {
  launch(permit, to_msg:, label:, kind: Primary, size: Medium)
}

/// Names a slot of the shared `OpForm`, so one edit message targets every text
/// input without a message variant per field. The SUPERSET of every command's
/// fields; date slots are reused across commands with consistent meaning
/// (`FEffective` for "effective", `FValidFrom`/`FValidTo` for a bounded window).
pub type OpField {
  FName
  FEngineerId
  FProjectId
  FContractId
  FInvoiceId
  FClient
  FClientId
  FSkillId
  FCapabilityId
  FLevel
  FFraction
  FDayRate
  FMonthlySalary
  FBudget
  FKind
  FTitle
  FSummary
  FEmail
  FPhone
  FPostalAddress
  FBank
  FBranch
  FAccountNo
  FAccountName
  FRelation
  FEmergencyName
  FEmergencyPhone
  FEmergencyEmail
  FTargetCompletion
  FEffective
  FValidFrom
  FValidTo
  FCountry
  FRegion
  FTimezone
  FMeetingId
  FStartsAt
  FDurationMinutes
  FAttendance
}

/// The raw text typed into an operation's fields, shared across every kind (each
/// kind reads only the fields it needs). Kept as strings so a partially-typed or
/// invalid value simply fails `build_command` with a prompt, rather than forcing
/// the model to hold half-parsed values.
pub type OpForm {
  OpForm(
    name: String,
    engineer_id: String,
    project_id: String,
    contract_id: String,
    invoice_id: String,
    client: String,
    client_id: String,
    skill_id: String,
    capability_id: String,
    level: String,
    fraction: String,
    day_rate: String,
    monthly_salary: String,
    budget: String,
    kind: String,
    title: String,
    summary: String,
    email: String,
    phone: String,
    postal_address: String,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    relation: String,
    emergency_name: String,
    emergency_phone: String,
    emergency_email: String,
    target_completion: String,
    effective: String,
    valid_from: String,
    valid_to: String,
    country: String,
    region: String,
    timezone: String,
    meeting_id: String,
    starts_at: String,
    duration_minutes: String,
    attendance: String,
  )
}

/// An in-flight contextual operation: the `kind` being composed, the editable
/// `form`, and an optional validation/submit prompt (`None` while clean). Shared
/// by every page that opens an operation modal so the modal state never drifts
/// per page.
pub type OpState {
  OpState(kind: OpKind, form: OpForm, error: Option(String))
}

/// A fresh form for `kind`: text fields empty, every date field defaulting to
/// `default_date` (the rail's current day) so an operation lands on the visible
/// instant unless the presenter types another date. `kind` is accepted so a page
/// can seed kind-specific defaults later; the blank shape is the same for every
/// kind.
pub fn blank_op_form(
  kind kind: OpKind,
  default_date default_date: calendar.Date,
) -> OpForm {
  let _ = kind
  let today = iso_date(default_date)
  OpForm(
    name: "",
    engineer_id: "",
    project_id: "",
    contract_id: "",
    invoice_id: "",
    client: "",
    client_id: "",
    skill_id: "",
    capability_id: "",
    level: "",
    fraction: "",
    day_rate: "",
    monthly_salary: "",
    budget: "",
    kind: "",
    title: "",
    summary: "",
    email: "",
    phone: "",
    postal_address: "",
    bank: "",
    branch: "",
    account_no: "",
    account_name: "",
    relation: "",
    emergency_name: "",
    emergency_phone: "",
    emergency_email: "",
    target_completion: today,
    effective: today,
    valid_from: today,
    valid_to: today,
    country: "",
    region: "",
    timezone: "",
    meeting_id: "",
    starts_at: "",
    duration_minutes: "60",
    attendance: "required",
  )
}

/// Write `value` into the `OpForm` slot named by `field`. One place maps an
/// `OpField` to its record update, so the view binds inputs by field name.
pub fn update_op_form(form: OpForm, field: OpField, value: String) -> OpForm {
  case field {
    FName -> OpForm(..form, name: value)
    FEngineerId -> OpForm(..form, engineer_id: value)
    FProjectId -> OpForm(..form, project_id: value)
    FContractId -> OpForm(..form, contract_id: value)
    FInvoiceId -> OpForm(..form, invoice_id: value)
    FClient -> OpForm(..form, client: value)
    FClientId -> OpForm(..form, client_id: value)
    FSkillId -> OpForm(..form, skill_id: value)
    FCapabilityId -> OpForm(..form, capability_id: value)
    FLevel -> OpForm(..form, level: value)
    FFraction -> OpForm(..form, fraction: value)
    FDayRate -> OpForm(..form, day_rate: value)
    FMonthlySalary -> OpForm(..form, monthly_salary: value)
    FBudget -> OpForm(..form, budget: value)
    FKind -> OpForm(..form, kind: value)
    FTitle -> OpForm(..form, title: value)
    FSummary -> OpForm(..form, summary: value)
    FEmail -> OpForm(..form, email: value)
    FPhone -> OpForm(..form, phone: value)
    FPostalAddress -> OpForm(..form, postal_address: value)
    FBank -> OpForm(..form, bank: value)
    FBranch -> OpForm(..form, branch: value)
    FAccountNo -> OpForm(..form, account_no: value)
    FAccountName -> OpForm(..form, account_name: value)
    FRelation -> OpForm(..form, relation: value)
    FEmergencyName -> OpForm(..form, emergency_name: value)
    FEmergencyPhone -> OpForm(..form, emergency_phone: value)
    FEmergencyEmail -> OpForm(..form, emergency_email: value)
    FTargetCompletion -> OpForm(..form, target_completion: value)
    FEffective -> OpForm(..form, effective: value)
    FValidFrom -> OpForm(..form, valid_from: value)
    FValidTo -> OpForm(..form, valid_to: value)
    FCountry -> OpForm(..form, country: value)
    FRegion -> OpForm(..form, region: value)
    FTimezone -> OpForm(..form, timezone: value)
    FMeetingId -> OpForm(..form, meeting_id: value)
    FStartsAt -> OpForm(..form, starts_at: value)
    FDurationMinutes -> OpForm(..form, duration_minutes: value)
    FAttendance -> OpForm(..form, attendance: value)
  }
}

/// Build the `Command` for `kind` from the form's text fields, reading only the
/// fields that kind needs. Returns `Error(prompt)` naming the first missing or
/// invalid field so the page can show why it could not apply. TOTAL over `OpKind`
/// — every write has an arm here.
pub fn build_command(kind: OpKind, form: OpForm) -> Result(Command, String) {
  case kind {
    OpOnboardEngineer -> {
      use name <- result.try(require_text(form.name, "name"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.OnboardEngineer(
          name:,
          level:,
          effective:,
        )),
      )
    }
    OpPromote -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.Promote(
          engineer_id:,
          level:,
          effective:,
        )),
      )
    }
    OpTakeLeave -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use kind <- result.try(require_text(form.kind, "leave kind"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.LeaveCommand(leave_command.TakeLeave(
          engineer_id:,
          kind:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpRollOff -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.AllocationCommand(allocation_command.RollOff(
          engineer_id:,
          project_id:,
          effective:,
        )),
      )
    }
    OpTerminateEmployment -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id:,
          effective:,
        )),
      )
    }
    OpUpdateContact -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use name <- result.try(require_text(form.name, "name"))
      use email <- result.try(require_text(form.email, "email"))
      use phone <- result.try(require_text(form.phone, "phone"))
      use postal_address <- result.try(require_text(
        form.postal_address,
        "postal address",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.UpdateContactDetails(
          engineer_id:,
          name:,
          email:,
          phone:,
          postal_address:,
          effective:,
        )),
      )
    }
    OpUpdateBanking -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use bank <- result.try(require_text(form.bank, "bank"))
      use branch <- result.try(require_text(form.branch, "branch"))
      use account_no <- result.try(require_text(
        form.account_no,
        "account number",
      ))
      use account_name <- result.try(require_text(
        form.account_name,
        "account name",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.UpdateBankingDetails(
          engineer_id:,
          bank:,
          branch:,
          account_no:,
          account_name:,
          effective:,
        )),
      )
    }
    OpUpdateEmergency -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use relation <- result.try(require_text(form.relation, "relation"))
      use name <- result.try(require_text(form.emergency_name, "name"))
      use phone <- result.try(require_text(form.emergency_phone, "phone"))
      use email <- result.try(require_text(form.emergency_email, "email"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.UpdateEmergencyContact(
          engineer_id:,
          relation:,
          name:,
          phone:,
          email:,
          effective:,
        )),
      )
    }
    OpLogWeek -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(
        gateway.TimesheetCommand(
          timesheet_command.LogWeek(engineer_id:, entries: []),
        ),
      )
    }
    OpSignContract -> {
      use client <- result.try(require_text(form.client, "client"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.EngagementCommand(engagement_command.SignContract(
          client:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpUpdateClientProfile -> {
      use client_id <- result.try(require_int(form.client_id, "client id"))
      use name <- result.try(require_text(form.name, "name"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.ClientCommand(client_command.UpdateClientProfile(
          client_id:,
          name:,
          effective:,
        )),
      )
    }
    OpStartProject -> {
      use name <- result.try(require_text(form.name, "name"))
      use contract_id <- result.try(require_int(form.contract_id, "contract id"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.EngagementCommand(engagement_command.StartProject(
          name:,
          contract_id:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpAssignToProject -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use fraction <- result.try(require_float(form.fraction, "fraction"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.AllocationCommand(allocation_command.AssignToProject(
          engineer_id:,
          project_id:,
          fraction:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpChangeAllocationFraction -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use fraction <- result.try(require_float(form.fraction, "fraction"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.AllocationCommand(allocation_command.ChangeAllocationFraction(
          engineer_id:,
          project_id:,
          fraction:,
          effective:,
        )),
      )
    }
    OpUpdateProjectProfile -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use title <- result.try(require_text(form.title, "title"))
      use summary <- result.try(require_text(form.summary, "summary"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.ProjectCommand(project_command.UpdateProjectProfile(
          project_id:,
          title:,
          summary:,
          effective:,
        )),
      )
    }
    OpUpdateProjectPlan -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use budget <- result.try(require_money(form.budget, "budget"))
      use target_completion <- result.try(require_date(
        form.target_completion,
        "target completion",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.ProjectCommand(project_command.UpdateProjectPlan(
          project_id:,
          budget:,
          target_completion:,
          effective:,
        )),
      )
    }
    OpDraftInvoice -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use billing_from <- result.try(require_date(
        form.valid_from,
        "billing from",
      ))
      use billing_to <- result.try(require_date(form.valid_to, "billing to"))
      Ok(
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          project_id:,
          billing_from:,
          billing_to:,
        )),
      )
    }
    OpIssueInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(gateway.InvoiceCommand(invoice_command.IssueInvoice(invoice_id:, at:)))
    }
    OpPayInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(gateway.InvoiceCommand(invoice_command.PayInvoice(invoice_id:, at:)))
    }
    OpRunPayroll -> {
      use period_from <- result.try(require_date(form.valid_from, "period from"))
      use period_to <- result.try(require_date(form.valid_to, "period to"))
      Ok(
        gateway.PayrollCommand(payroll_command.RunPayroll(
          period_from:,
          period_to:,
        )),
      )
    }
    OpReviseRateCard -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_money(form.day_rate, "day rate"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.RateCardCommand(rate_card_command.ReviseRateCard(
          level:,
          day_rate:,
          effective:,
        )),
      )
    }
    OpAdjustRateForPortion -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_money(form.day_rate, "day rate"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.RateCardCommand(rate_card_command.AdjustRateForPortion(
          level:,
          day_rate:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpSetSalary -> {
      use level <- result.try(require_int(form.level, "level"))
      use monthly_salary <- result.try(require_money(
        form.monthly_salary,
        "monthly salary",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.SalaryCommand(salary_command.SetSalary(
          level:,
          monthly_salary:,
          effective:,
        )),
      )
    }
    OpSetProjectRequirement -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use level <- result.try(require_int(form.level, "level"))
      use quantity <- result.try(require_float(form.fraction, "quantity"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.ProjectCommand(project_command.SetProjectRequirement(
          project_id:,
          level:,
          quantity:,
          valid_from:,
          valid_to:,
        )),
      )
    }
    OpSetProjectCapability -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use capability_id <- result.try(require_int(
        form.capability_id,
        "capability",
      ))
      use target_level <- result.try(require_int(form.level, "target level"))
      use quantity <- result.try(require_float(form.fraction, "quantity"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(
        gateway.ProjectCapabilityCommand(
          project_capability_command.SetProjectCapability(
            project_id:,
            capability_id:,
            target_level:,
            quantity:,
            valid_from:,
            valid_to:,
          ),
        ),
      )
    }
    OpAssessSkill -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use skill_id <- result.try(require_int(form.skill_id, "skill"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerSkillCommand(engineer_skill_command.AssessSkill(
          engineer_id:,
          skill_id:,
          level:,
          effective:,
        )),
      )
    }
    OpSetLocation -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use country <- result.try(require_text(form.country, "country"))
      use timezone <- result.try(require_text(form.timezone, "timezone"))
      use effective <- result.try(require_date(form.effective, "effective"))
      let region = case string.trim(form.region) {
        "" -> option.None
        other -> option.Some(other)
      }
      Ok(
        gateway.LocationCommand(location_command.SetEngineerLocation(
          engineer_id:,
          country:,
          region:,
          timezone:,
          effective:,
        )),
      )
    }
    OpRescheduleMeeting -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use timezone <- result.try(require_text(form.timezone, "timezone"))
      use date <- result.try(require_date(form.effective, "date"))
      use starts_at <- result.try(require_text(form.starts_at, "start time"))
      use duration_minutes <- result.try(require_int(
        form.duration_minutes,
        "duration",
      ))
      Ok(
        gateway.MeetingCommand(meeting_command.RescheduleMeeting(
          meeting_id:,
          timezone:,
          date:,
          starts_at:,
          duration_minutes:,
        )),
      )
    }
    OpCancelMeeting -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      Ok(gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id:)))
    }
    OpAddAttendee -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      let attendance = case form.attendance {
        "optional" -> meeting_command.Optional
        _ -> meeting_command.Required
      }
      Ok(
        gateway.MeetingCommand(meeting_command.AddAttendee(
          meeting_id:,
          engineer_id:,
          attendance:,
        )),
      )
    }
    OpRemoveAttendee -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(
        gateway.MeetingCommand(meeting_command.RemoveAttendee(
          meeting_id:,
          engineer_id:,
        )),
      )
    }
    OpCreateProject -> Error("Create project is handled by the wizard.")
  }
}

/// A labelled input bound to an `OpForm` slot; editing it raises `to_msg(field,
/// value)` so the host page folds the edit through `update_op_form`.
/// `input_type` is the HTML input type ("text"/"number"/"date").
pub fn op_field(
  label label: String,
  field field: OpField,
  value value: String,
  input_type input_type: String,
  to_msg to_msg: fn(OpField, String) -> msg,
) -> Element(msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_(input_type),
      attribute.attribute("aria-label", label),
      attribute.value(value),
      event.on_input(fn(value) { to_msg(field, value) }),
    ]),
  ])
}

/// A labelled `<select>` over a directory of `Ref`s (engineers/projects/clients):
/// option value is the id as text, option label the name. While `refs` is empty
/// (still loading) it renders a single disabled placeholder so the control is
/// inert rather than misleadingly empty. On change it raises `to_msg(field,
/// value)` carrying the chosen id string into the same slot a text input would.
pub fn ref_select(
  label label: String,
  field field: OpField,
  refs refs: List(Ref),
  selected selected: String,
  to_msg to_msg: fn(OpField, String) -> msg,
) -> Element(msg) {
  let options = case refs {
    [] -> [
      html.option([attribute.value(""), attribute.disabled(True)], "Loading…"),
    ]
    refs ->
      list.map(refs, fn(reference) {
        let id = int.to_string(reference.id)
        html.option(
          [attribute.value(id), attribute.selected(id == selected)],
          reference.name,
        )
      })
  }
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.select(
      [
        attribute.attribute("aria-label", label),
        event.on_change(fn(value) { to_msg(field, value) }),
      ],
      options,
    ),
  ])
}

/// Reconcile a form's entity-reference slots against a freshly-loaded directory:
/// the engineer/project slots snap to the first available option when empty or
/// holding an id absent from the as-of directory, so `build_command` reads a
/// valid id rather than a stale or empty one. An empty directory leaves the slot
/// unchanged.
pub fn reconcile_form(
  form: OpForm,
  engineers: List(Ref),
  projects: List(Ref),
) -> OpForm {
  OpForm(
    ..form,
    engineer_id: reconcile_ref(form.engineer_id, engineers),
    project_id: reconcile_ref(form.project_id, projects),
  )
}

/// Pick the value the matching `<select>` will show: keep `current` if it names
/// an id present in `refs`, otherwise fall back to the first option's id (or the
/// unchanged value if `refs` is empty).
pub fn reconcile_ref(current: String, refs: List(Ref)) -> String {
  let present =
    list.any(refs, fn(reference) { int.to_string(reference.id) == current })
  case present, refs {
    True, _ -> current
    False, [first, ..] -> int.to_string(first.id)
    False, [] -> current
  }
}

/// A non-empty text field, or a prompt to fill it in.
fn require_text(raw: String, label: String) -> Result(String, String) {
  case string.trim(raw) {
    "" -> Error("Enter a " <> label <> ".")
    text -> Ok(text)
  }
}

/// Parse an integer field, or a prompt naming it.
fn require_int(raw: String, label: String) -> Result(Int, String) {
  case int.parse(string.trim(raw)) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Enter a whole number for " <> label <> ".")
  }
}

/// Parse a numeric (int-or-decimal) field, or a prompt naming it.
fn require_float(raw: String, label: String) -> Result(Float, String) {
  case parse_number(string.trim(raw)) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Enter a number for " <> label <> ".")
  }
}

/// Parse a money field into the exact `Money` type, or a prompt naming it.
fn require_money(raw: String, label: String) -> Result(money.Money, String) {
  case money.from_string(string.trim(raw)) {
    Ok(amount) -> Ok(amount)
    Error(Nil) -> Error("Enter an amount for " <> label <> ".")
  }
}

/// Parse an ISO-8601 date field, or a prompt naming it.
fn require_date(raw: String, label: String) -> Result(calendar.Date, String) {
  case time.parse_iso_date(string.trim(raw)) {
    Ok(date) -> Ok(date)
    Error(Nil) -> Error("Enter " <> label <> " as YYYY-MM-DD.")
  }
}

fn parse_number(raw: String) -> Result(Float, Nil) {
  case float.parse(raw) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      case int.parse(raw) {
        Ok(value) -> Ok(int.to_float(value))
        Error(Nil) -> Error(Nil)
      }
  }
}

fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
