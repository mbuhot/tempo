//// Domain: who may do what. The authenticated `Principal` (an actor display name
//// plus a role) and the authorization gate `command.dispatch` consults before any
//// transaction opens — ONE place that covers all 24 commands (issue #6).
////
//// No HTTP and no database: the web layer authenticates the request (a signed
//// session cookie) and hands the derived `Principal` inward; this module decides
//// whether that principal may run a given `Command`. Identity is stamped on the
//// journal from the principal's `actor`, never from the request body — so the
//// audit `actor` is unforgeable.
////
//// Credentials live in the `account` table (the `account` concept owns login); this
//// module no longer keeps a hardcoded identity registry. Session validation is
//// stateless: the cookie is HMAC-signed, so a well-formed `actor|role` payload that
//// verifies is TRUSTED without a DB read — only the signing key could have produced
//// it. Admin may run every command; everyone else is denied the financial commands
//// (salary, payroll, invoicing) — the gate that makes the difference observable.

import gleam/string
import shared/command.{
  type Command, InvoiceCommand, PayrollCommand, SalaryCommand,
}
import shared/invoice/command as invoice_command
import shared/payroll/command as payroll_command
import shared/salary/command as salary_command

/// A role bundles the commands a principal may run. `Admin` is unrestricted; `Ops`
/// and `Engineer` are denied the financial commands.
pub type Role {
  Admin
  Ops
  Engineer
}

/// An authenticated identity: the display `actor` stamped on the journal and the
/// `role` the authorization gate keys on. Built ONLY from a verified session (or a
/// verified credential at login), so a caller can never present a forged actor.
pub type Principal {
  Principal(actor: String, role: Role)
}

/// Why authorization refused a command: the principal's role does not grant it.
pub type AuthzError {
  Forbidden(actor: String, command: String)
}

/// Authorize a principal to run a command, BEFORE any transaction opens (issue
/// #6): the ONE gate covering all 24 commands. `Admin` may run everything;
/// everyone else is denied the financial commands (set salary, run payroll, and
/// the invoice lifecycle). Returns the principal's actor for stamping when allowed.
pub fn authorize(
  principal: Principal,
  command: Command,
) -> Result(String, AuthzError) {
  case principal.role, is_financial(command) {
    Admin, _ -> Ok(principal.actor)
    _, False -> Ok(principal.actor)
    _, True ->
      Error(Forbidden(actor: principal.actor, command: command_tag(command)))
  }
}

/// Whether a command moves money: setting a salary, running payroll, or any
/// invoice-lifecycle transition. These are the commands only `Admin` may run.
fn is_financial(command: Command) -> Bool {
  case command {
    SalaryCommand(salary_command.SetSalary(..))
    | PayrollCommand(payroll_command.RunPayroll(..))
    | InvoiceCommand(_) -> True
    _ -> False
  }
}

// --- session encoding --------------------------------------------------------
// A session is the principal serialized as `actor|role`. The web layer signs the
// string into a cookie (so the client cannot tamper with it) and verifies it back;
// this module owns the string<->Principal mapping so the wire format lives in one
// place.

/// Serialize a principal to its signed-cookie payload `actor|role`.
pub fn to_session(principal: Principal) -> String {
  principal.actor <> "|" <> role_to_string(principal.role)
}

/// Parse a verified session payload back to its `Principal`. The cookie is signed,
/// so a payload that verified is trusted: this only re-checks shape — a non-empty
/// actor and a known role. `Error(Nil)` on a missing separator, an empty actor, or
/// an unknown role string.
pub fn from_session(session: String) -> Result(Principal, Nil) {
  case string.split_once(session, "|") {
    Ok(#(actor, role)) ->
      case actor, role_from_string(role) {
        "", _ -> Error(Nil)
        _, Ok(role) -> Ok(Principal(actor:, role:))
        _, Error(Nil) -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn role_to_string(role: Role) -> String {
  case role {
    Admin -> "admin"
    Ops -> "ops"
    Engineer -> "engineer"
  }
}

/// Map a role's wire string back to its `Role`. Shared by session decoding and the
/// `account` concept (whose `role` column carries the same strings). Unknown → error.
pub fn role_from_string(role: String) -> Result(Role, Nil) {
  case role {
    "admin" -> Ok(Admin)
    "ops" -> Ok(Ops)
    "engineer" -> Ok(Engineer)
    _ -> Error(Nil)
  }
}

/// A short tag naming a command for an authorization-error message (so a 403 body
/// can say which command was refused without leaking its parameters).
fn command_tag(command: Command) -> String {
  case command {
    SalaryCommand(salary_command.SetSalary(..)) -> "set_salary"
    PayrollCommand(payroll_command.RunPayroll(..)) -> "run_payroll"
    InvoiceCommand(invoice_command.DraftInvoice(..)) -> "draft_invoice"
    InvoiceCommand(invoice_command.IssueInvoice(..)) -> "issue_invoice"
    InvoiceCommand(invoice_command.PayInvoice(..)) -> "pay_invoice"
    _ -> "command"
  }
}
