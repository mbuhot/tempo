//// Domain: who may do what. The authenticated `Principal` (an actor display name
//// plus a role) and the authorization gate `command.dispatch` consults before any
//// transaction opens — ONE place that covers all 24 commands (issue #6).
////
//// No HTTP and no database: the web layer authenticates the request (a signed
//// session cookie) and hands the derived `Principal` inward; this module decides
//// whether that principal may run a given `Command`. Identity is stamped on the
//// journal from the principal's `actor`, never from the request body — so the
//// audit `actor` is unforgeable (ADR-035: real auth "slots in behind the same
//// gate").
////
//// The principal registry is the demo cast: the three seeded engineers plus the
//// Admin and Ops roles. Admin may run every command; everyone else is denied the
//// financial commands (salary, payroll, invoicing) — the gate that makes the
//// difference observable in a test. A free-text actor is not a principal: only a
//// known identity authenticates.

import gleam/list
import gleam/string
import shared/types.{
  type Command, DraftInvoice, InvoiceCommand, IssueInvoice, PayInvoice,
  RunPayroll, SalaryCommand, SetSalary,
}

/// A role bundles the commands a principal may run. `Admin` is unrestricted; `Ops`
/// and `Engineer` are denied the financial commands.
pub type Role {
  Admin
  Ops
  Engineer
}

/// An authenticated identity: the display `actor` stamped on the journal and the
/// `role` the authorization gate keys on. Built ONLY from a verified session, so a
/// caller can never present a forged actor.
pub type Principal {
  Principal(actor: String, role: Role)
}

/// Why authorization refused a command: the principal's role does not grant it.
pub type AuthzError {
  Forbidden(actor: String, command: String)
}

/// The demo principal registry (ADR-035): the three seeded engineers and the two
/// named roles. Authenticating as one of these is the demo's "sign in"; an unknown
/// actor is not a principal and cannot authenticate.
pub fn principals() -> List(Principal) {
  [
    Principal(actor: "Priya Sharma", role: Engineer),
    Principal(actor: "Marcus Chen", role: Engineer),
    Principal(actor: "Aisha Okafor", role: Engineer),
    Principal(actor: "Admin", role: Admin),
    Principal(actor: "Ops", role: Ops),
  ]
}

/// Look up the principal for an actor display name, or `Error(Nil)` when the name
/// is not in the registry. The login endpoint uses this to refuse an unknown
/// identity before issuing a session.
pub fn lookup(actor: String) -> Result(Principal, Nil) {
  list.find(principals(), fn(principal) { principal.actor == actor })
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
    SalaryCommand(SetSalary(..)) | RunPayroll(..) | InvoiceCommand(_) -> True
    _ -> False
  }
}

// --- session encoding --------------------------------------------------------
// A session is the principal serialized as `actor|role`. The web layer signs the
// string into a cookie (so the client cannot tamper with it) and verifies it back;
// this module owns the string<->Principal mapping so the wire format lives in one
// place beside the registry.

/// Serialize a principal to its signed-cookie payload `actor|role`.
pub fn to_session(principal: Principal) -> String {
  principal.actor <> "|" <> role_to_string(principal.role)
}

/// Parse a verified session payload back to its `Principal`, re-checking the actor
/// against the registry so a session for a retired identity (or one whose role no
/// longer matches) is rejected rather than trusted. `Error(Nil)` on any mismatch.
pub fn from_session(session: String) -> Result(Principal, Nil) {
  case string.split_once(session, "|") {
    Ok(#(actor, role)) ->
      case lookup(actor) {
        Ok(principal) ->
          case role_to_string(principal.role) == role {
            True -> Ok(principal)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
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

/// A short tag naming a command for an authorization-error message (so a 403 body
/// can say which command was refused without leaking its parameters).
fn command_tag(command: Command) -> String {
  case command {
    SalaryCommand(SetSalary(..)) -> "set_salary"
    RunPayroll(..) -> "run_payroll"
    InvoiceCommand(DraftInvoice(..)) -> "draft_invoice"
    InvoiceCommand(IssueInvoice(..)) -> "issue_invoice"
    InvoiceCommand(PayInvoice(..)) -> "pay_invoice"
    _ -> "command"
  }
}
