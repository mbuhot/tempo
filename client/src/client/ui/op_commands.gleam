//// Builds the `Command` for each `OpKind` from its `OpForm` fields — the
//// per-concept knowledge the generic op-form engine (`client/ui/ops`) stays
//// free of.

import client/time
import client/ui/ops.{type OpForm, type OpKind}
import gleam/float
import gleam/int
import gleam/option
import gleam/result
import gleam/string
import gleam/time/calendar
import shared/allocation/command as allocation_command
import shared/availability/command as availability_command
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
import shared/salary/command as salary_command
import shared/timesheet/command as timesheet_command

/// Build the `Command` for `kind` from the form's text fields, reading only the
/// fields that kind needs. Returns `Error(prompt)` naming the first missing or
/// invalid field so the page can show why it could not apply. TOTAL over `OpKind`
/// — every write has an arm here.
pub fn build_command(kind: OpKind, form: OpForm) -> Result(Command, String) {
  case kind {
    ops.OpOnboardEngineer -> {
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
    ops.OpPromote -> {
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
    ops.OpTakeLeave -> {
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
    ops.OpRollOff -> {
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
    ops.OpTerminateEmployment -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(
        gateway.EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id:,
          effective:,
        )),
      )
    }
    ops.OpUpdateContact -> {
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
    ops.OpUpdateBanking -> {
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
    ops.OpUpdateEmergency -> {
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
    ops.OpLogWeek -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(
        gateway.TimesheetCommand(
          timesheet_command.LogWeek(engineer_id:, entries: []),
        ),
      )
    }
    ops.OpSignContract -> {
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
    ops.OpUpdateClientProfile -> {
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
    ops.OpStartProject -> {
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
    ops.OpAssignToProject -> {
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
    ops.OpChangeAllocationFraction -> {
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
    ops.OpUpdateProjectProfile -> {
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
    ops.OpUpdateProjectPlan -> {
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
    ops.OpDraftInvoice -> {
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
    ops.OpIssueInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(gateway.InvoiceCommand(invoice_command.IssueInvoice(invoice_id:, at:)))
    }
    ops.OpPayInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(gateway.InvoiceCommand(invoice_command.PayInvoice(invoice_id:, at:)))
    }
    ops.OpRunPayroll -> {
      use period_from <- result.try(require_date(form.valid_from, "period from"))
      use period_to <- result.try(require_date(form.valid_to, "period to"))
      Ok(
        gateway.PayrollCommand(payroll_command.RunPayroll(
          period_from:,
          period_to:,
        )),
      )
    }
    ops.OpReviseRateCard -> {
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
    ops.OpAdjustRateForPortion -> {
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
    ops.OpSetSalary -> {
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
    ops.OpSetProjectRequirement -> {
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
    ops.OpSetProjectCapability -> {
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
    ops.OpAssessSkill -> {
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
    ops.OpSetLocation -> {
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
    ops.OpRescheduleMeeting -> {
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
          check: meeting_command.AllowOverlap,
        )),
      )
    }
    ops.OpCancelMeeting -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      Ok(gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id:)))
    }
    ops.OpAddAttendee -> {
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
    ops.OpRemoveAttendee -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(
        gateway.MeetingCommand(meeting_command.RemoveAttendee(
          meeting_id:,
          engineer_id:,
        )),
      )
    }
    ops.OpAddFocusBlock -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use date <- result.try(require_date(form.effective, "date"))
      use starts_at <- result.try(require_text(form.starts_at, "start time"))
      use duration_minutes <- result.try(require_int(
        form.duration_minutes,
        "duration",
      ))
      use timezone <- result.try(require_text(form.timezone, "timezone"))
      use title <- result.try(require_text(form.title, "title"))
      Ok(
        gateway.AvailabilityCommand(availability_command.AddFocusBlock(
          engineer_id:,
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          title:,
        )),
      )
    }
    ops.OpRemoveFocusBlock -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use focus_block_id <- result.try(require_int(
        form.focus_block_id,
        "focus block id",
      ))
      Ok(
        gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
          engineer_id:,
          focus_block_id:,
        )),
      )
    }
    ops.OpCreateProject -> Error("Create project is handled by the wizard.")
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
