//// The client's view-atom library and contextual-operation form engine, generic
//// over the host page's `msg` so every page reuses the same building blocks.
////
//// Three concerns live here:
////
////   * Pure data -> `Element(msg)` view atoms (`page_head`, `panel`, `stat`, `kv`,
////     `avatar`, `swatch`, `pill`, `data_table`, `empty_state`) emitting the
////     prototype's class names verbatim. Categorical colours are passed through as
////     inline `style` referencing `var(--cat-N)` tokens — NEVER a literal hex.
////
////   * Formatters (`money`, `money_k`, `pct`, `fraction`, `days`) and
////     `level_band`, the pure level -> band-name presentation label that replaces
////     the dropped `band` wire field across every read type.
////
////   * The FULLY-ENUMERATED operation form engine: `OpKind` covers every
////     `Command`-backed write across all seven pages, `OpField` is the superset of
////     every command's fields, and `build_command` is TOTAL over `OpKind`. This is
////     a frozen deliverable so the per-page agents never serialize on shared edits
////     to this module.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{
  type Command, type Ref, AdjustRateForPortion, AssignToProject,
  ChangeAllocationFraction, DraftInvoice, IssueInvoice, LogWeek, OnboardEngineer,
  PayInvoice, Promote, ReviseRateCard, RollOff, RunPayroll, SetSalary,
  SignContract, StartProject, TakeLeave, TerminateEmployment,
  UpdateBankingDetails, UpdateClientProfile, UpdateContactDetails,
  UpdateEmergencyContact, UpdateProjectPlan, UpdateProjectProfile,
}

// --- View atoms -------------------------------------------------------------

/// The standard page header: the heading IS the section/entity name (no eyebrow
/// kicker — ADR-041), a supporting paragraph, and an optional cluster of action
/// elements on the right.
pub fn page_head(
  title title: String,
  blurb blurb: String,
  actions actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("page-head")], [
    html.div([], [
      html.h1([], [html.text(title)]),
      html.p([], [html.text(blurb)]),
    ]),
    html.div([attribute.class("action-row")], actions),
  ])
}

/// A bordered panel with a heading, an optional count badge, an optional cluster
/// of right-aligned controls, and a body. Mirrors the prototype's `.panel`.
pub fn panel(
  title title: String,
  count count: String,
  right right: List(Element(msg)),
  body body: List(Element(msg)),
) -> Element(msg) {
  let count_badge = case count {
    "" -> element.none()
    text -> html.span([attribute.class("panel__count")], [html.text(text)])
  }
  let right_cluster = case right {
    [] -> element.none()
    controls -> html.div([attribute.class("panel__actions")], controls)
  }
  html.div([attribute.class("panel")], [
    html.div([attribute.class("panel__head")], [
      html.h2([], [html.text(title)]),
      count_badge,
      right_cluster,
    ]),
    html.div([attribute.class("panel__body")], body),
  ])
}

/// A single stat card: a big value, an optional unit suffix, a label, and an
/// optional spark bar filled to `pct` percent. Mirrors the prototype's `.stat`.
pub fn stat(
  value value: String,
  unit unit: String,
  label label: String,
  pct pct: StatPct,
) -> Element(msg) {
  let spark = case pct {
    NoPct -> element.none()
    Pct(value) ->
      html.div([attribute.class("spark")], [
        html.i([attribute.style("width", clamp_pct(value) <> "%")], []),
      ])
  }
  html.div([attribute.class("stat")], [
    html.div([attribute.class("stat__head")], [
      html.span([attribute.class("stat__value")], [html.text(value)]),
      html.span([attribute.class("stat__unit")], [html.text(unit)]),
    ]),
    html.div([attribute.class("stat__label eyebrow")], [html.text(label)]),
    spark,
  ])
}

/// Whether a `stat` shows a spark bar and at what percentage.
pub type StatPct {
  NoPct
  Pct(Int)
}

fn clamp_pct(value: Int) -> String {
  int.to_string(int.min(value, 100))
}

/// One key/value row of a detail panel's `.kv` list: the key on the left, the
/// value on the right (monospaced when `mono`). Mirrors the prototype's `kv`.
pub fn kv(
  key key: String,
  value value: String,
  mono mono: Bool,
) -> Element(msg) {
  let value_class = case mono {
    True -> "kv__value mono"
    False -> "kv__value"
  }
  html.div([attribute.class("kv__row")], [
    html.span([attribute.class("kv__key")], [html.text(key)]),
    html.span([attribute.class(value_class)], [html.text(value)]),
  ])
}

/// A round avatar showing a person's initials, tinted by a categorical token.
/// `category` indexes the `--cat-N` palette (wrapped to 1..7); the tint is passed
/// as inline `style` referencing the token, never a literal colour. `class`
/// selects the size variant (e.g. "avatar avatar--sm").
pub fn avatar(
  name name: String,
  category category: Int,
  class class: String,
) -> Element(msg) {
  html.div(
    [attribute.class(class), attribute.style("background", cat_var(category))],
    [html.text(initials(name))],
  )
}

/// A small square project swatch tinted by a categorical token. `inline` renders
/// it for inline use beside a title. The tint references `--cat-N`, never hex.
pub fn swatch(category category: Int, inline inline: Bool) -> Element(msg) {
  let class = case inline {
    True -> "swatch swatch--inline"
    False -> "swatch"
  }
  html.span(
    [attribute.class(class), attribute.style("background", cat_var(category))],
    [],
  )
}

/// A status pill: a coloured dot and a label, the colour selected by `variant`
/// (e.g. "draft"/"issued"/"paid"/"active"/"ended"). Mirrors the prototype's
/// `.pill`.
pub fn pill(variant variant: String, label label: String) -> Element(msg) {
  html.span([attribute.class("pill pill--" <> variant)], [html.text(label)])
}

/// A table from a header spec and pre-rendered rows. Each header is `#(label,
/// numeric?)` — a numeric header gets the right-aligned monospaced `.num` class.
/// Rows are rendered by the caller (so cells can carry click handlers, pills,
/// avatars). Mirrors the prototype's `table` markup.
pub fn data_table(
  headers headers: List(#(String, Bool)),
  rows rows: List(Element(msg)),
) -> Element(msg) {
  html.table([], [
    html.thead([], [
      html.tr(
        [],
        list.map(headers, fn(header) {
          let #(label, numeric) = header
          let attrs = case numeric {
            True -> [attribute.class("num")]
            False -> []
          }
          html.th(attrs, [html.text(label)])
        }),
      ),
    ]),
    html.tbody([], rows),
  ])
}

/// A centred placeholder for an empty list/region. Mirrors the prototype's
/// `.empty`.
pub fn empty_state(message message: String) -> Element(msg) {
  html.div([attribute.class("empty")], [html.text(message)])
}

/// The `var(--cat-N)` token for a categorical index, wrapped to 1..7 exactly as
/// the prototype's `catVar`. Returned as a CSS value string for an inline `style`.
fn cat_var(category: Int) -> String {
  let index = { int.modulo(category, 7) |> result.unwrap(0) } + 1
  "var(--cat-" <> int.to_string(index) <> ")"
}

/// A name's initials (up to two upper-case letters), mirroring the prototype's
/// `initials`.
fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(fn(word) {
    string.first(word) |> result.map(string.uppercase)
  })
  |> list.take(2)
  |> string.concat
}

// --- Formatters -------------------------------------------------------------

/// Format a money amount as whole dollars with thousands separators ("$84,000"),
/// negatives prefixed with a minus ("-$32,000"). Seeded as round figures so no
/// cents are shown.
pub fn money(amount: Float) -> String {
  let rounded = float.round(amount)
  let sign = case rounded < 0 {
    True -> "-"
    False -> ""
  }
  sign <> "$" <> group_thousands(int.absolute_value(rounded))
}

/// Format a money amount compactly: "$84k"/"$7.6k" above a thousand, otherwise
/// the full `money` form. Mirrors the prototype's `fmtMoneyK`.
pub fn money_k(amount: Float) -> String {
  case amount >=. 1000.0 {
    False -> money(amount)
    True -> {
      let thousands = amount /. 1000.0
      let rendered = case amount >=. 10_000.0 {
        True -> int.to_string(float.round(thousands))
        False -> one_decimal(thousands)
      }
      "$" <> rendered <> "k"
    }
  }
}

/// Format a percentage as a whole number with a "%" suffix (54.3 -> "54%").
pub fn pct(value: Float) -> String {
  int.to_string(float.round(value)) <> "%"
}

/// Format an allocation fraction as a percentage (0.5 -> "50%").
pub fn fraction(value: Float) -> String {
  int.to_string(float.round(value *. 100.0)) <> "%"
}

/// Format a day/hour count: a whole number when integral ("30"), otherwise one
/// decimal place ("15.5").
pub fn days(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> one_decimal(value)
  }
}

/// The seniority band name for a level, the pure presentation label that replaces
/// the dropped `band` wire field. Levels 1..5 mirror the prototype's `LEVELS`;
/// 6/7 extend the ladder. Returned as "L<n> · <band>".
pub fn level_band(level: Int) -> String {
  let band = case level {
    1 -> "Associate"
    2 -> "Engineer"
    3 -> "Senior"
    4 -> "Staff"
    5 -> "Principal"
    6 -> "Distinguished"
    7 -> "Fellow"
    _ -> "Engineer"
  }
  "L" <> int.to_string(level) <> " · " <> band
}

/// Group a non-negative integer's digits into thousands ("84000" -> "84,000").
fn group_thousands(value: Int) -> String {
  int.to_string(value)
  |> string.to_graphemes
  |> list.reverse
  |> list.sized_chunk(into: 3)
  |> list.map(fn(chunk) { chunk |> list.reverse |> string.concat })
  |> list.reverse
  |> string.join(",")
}

/// A float rounded to one decimal place ("7.55" -> "7.6").
fn one_decimal(value: Float) -> String {
  float.to_string(float.to_precision(value, 1))
}

// --- Operation form engine --------------------------------------------------
// Every Command-backed write across all seven pages, frozen as a single union so
// the pages share one form model and one assembly path. `OpKind` is total in
// `build_command`; `OpField` is the superset of every command's fields.

/// Every contextual operation a page can compose. One variant per `Command`-backed
/// write (PRD §6) — frozen here so adding a page never widens this union.
pub type OpKind {
  OpOnboardEngineer
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
  )
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
      Ok(OnboardEngineer(name:, level:, effective:))
    }
    OpPromote -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(Promote(engineer_id:, level:, effective:))
    }
    OpTakeLeave -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use kind <- result.try(require_text(form.kind, "leave kind"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(TakeLeave(engineer_id:, kind:, valid_from:, valid_to:))
    }
    OpRollOff -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(RollOff(engineer_id:, project_id:, effective:))
    }
    OpTerminateEmployment -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(TerminateEmployment(engineer_id:, effective:))
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
      Ok(UpdateContactDetails(
        engineer_id:,
        name:,
        email:,
        phone:,
        postal_address:,
        effective:,
      ))
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
      Ok(UpdateBankingDetails(
        engineer_id:,
        bank:,
        branch:,
        account_no:,
        account_name:,
        effective:,
      ))
    }
    OpUpdateEmergency -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use relation <- result.try(require_text(form.relation, "relation"))
      use name <- result.try(require_text(form.emergency_name, "name"))
      use phone <- result.try(require_text(form.emergency_phone, "phone"))
      use email <- result.try(require_text(form.emergency_email, "email"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(UpdateEmergencyContact(
        engineer_id:,
        relation:,
        name:,
        phone:,
        email:,
        effective:,
      ))
    }
    OpLogWeek -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(LogWeek(engineer_id:, entries: []))
    }
    OpSignContract -> {
      use client <- result.try(require_text(form.client, "client"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(SignContract(client:, valid_from:, valid_to:))
    }
    OpUpdateClientProfile -> {
      use client_id <- result.try(require_int(form.client_id, "client id"))
      use name <- result.try(require_text(form.name, "name"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(UpdateClientProfile(client_id:, name:, effective:))
    }
    OpStartProject -> {
      use name <- result.try(require_text(form.name, "name"))
      use contract_id <- result.try(require_int(form.contract_id, "contract id"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(StartProject(name:, contract_id:, valid_from:, valid_to:))
    }
    OpAssignToProject -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use fraction <- result.try(require_float(form.fraction, "fraction"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(AssignToProject(
        engineer_id:,
        project_id:,
        fraction:,
        valid_from:,
        valid_to:,
      ))
    }
    OpChangeAllocationFraction -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use fraction <- result.try(require_float(form.fraction, "fraction"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(ChangeAllocationFraction(
        engineer_id:,
        project_id:,
        fraction:,
        effective:,
      ))
    }
    OpUpdateProjectProfile -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use title <- result.try(require_text(form.title, "title"))
      use summary <- result.try(require_text(form.summary, "summary"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(UpdateProjectProfile(project_id:, title:, summary:, effective:))
    }
    OpUpdateProjectPlan -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use budget <- result.try(require_float(form.budget, "budget"))
      use target_completion <- result.try(require_date(
        form.target_completion,
        "target completion",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(UpdateProjectPlan(project_id:, budget:, target_completion:, effective:))
    }
    OpDraftInvoice -> {
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use billing_from <- result.try(require_date(
        form.valid_from,
        "billing from",
      ))
      use billing_to <- result.try(require_date(form.valid_to, "billing to"))
      Ok(DraftInvoice(project_id:, billing_from:, billing_to:))
    }
    OpIssueInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(IssueInvoice(invoice_id:, at:))
    }
    OpPayInvoice -> {
      use invoice_id <- result.try(require_int(form.invoice_id, "invoice id"))
      use at <- result.try(require_date(form.effective, "date"))
      Ok(PayInvoice(invoice_id:, at:))
    }
    OpRunPayroll -> {
      use period_from <- result.try(require_date(form.valid_from, "period from"))
      use period_to <- result.try(require_date(form.valid_to, "period to"))
      Ok(RunPayroll(period_from:, period_to:))
    }
    OpReviseRateCard -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_float(form.day_rate, "day rate"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(ReviseRateCard(level:, day_rate:, effective:))
    }
    OpAdjustRateForPortion -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_float(form.day_rate, "day rate"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:))
    }
    OpSetSalary -> {
      use level <- result.try(require_int(form.level, "level"))
      use monthly_salary <- result.try(require_float(
        form.monthly_salary,
        "monthly salary",
      ))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(SetSalary(level:, monthly_salary:, effective:))
    }
  }
}

/// A centred modal over a dimmed full-screen backdrop: a header naming the
/// operation, a body of form fields, an optional rejection line, and a footer with
/// a ghost Cancel and a primary Confirm right-aligned. Clicking the backdrop raises
/// `on_cancel`; a click inside the modal is stopped so it never closes the dialog.
pub fn modal(
  title title: String,
  error error: String,
  body body: List(Element(msg)),
  on_cancel on_cancel: msg,
  on_confirm on_confirm: msg,
  confirm_label confirm_label: String,
) -> Element(msg) {
  let error_line = case error {
    "" -> element.none()
    message ->
      html.div([attribute.class("op-form__error")], [html.text(message)])
  }
  html.div([attribute.class("modal-backdrop"), event.on_click(on_cancel)], [
    html.div([attribute.class("modal"), swallow_click(on_cancel)], [
      html.div([attribute.class("modal__header")], [html.text(title)]),
      html.div([attribute.class("modal__body op-form")], body),
      error_line,
      html.div([attribute.class("modal__footer")], [
        html.button(
          [attribute.class("btn btn--ghost"), event.on_click(on_cancel)],
          [html.text("Cancel")],
        ),
        html.button([attribute.class("btn"), event.on_click(on_confirm)], [
          html.text(confirm_label),
        ]),
      ]),
    ]),
  ])
}

/// A click handler that stops the event reaching parent elements but dispatches
/// nothing: the decoder reads a path that is never present on a click event, so it
/// always fails and no message is raised, while the `stop_propagation` flag still
/// fires at the DOM level (Lustre applies it before running the decoder). Used
/// inside `modal` so a click in the dialog never closes it via the backdrop. The
/// `witness` only fixes the decoder's `msg` type; it is never actually dispatched.
fn swallow_click(witness: msg) -> attribute.Attribute(msg) {
  event.on(
    "click",
    decode.at(["__never__"], decode.string) |> decode.map(fn(_) { witness }),
  )
  |> event.stop_propagation
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

// --- Field parsing ----------------------------------------------------------

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

/// Parse an ISO-8601 date field, or a prompt naming it.
fn require_date(raw: String, label: String) -> Result(calendar.Date, String) {
  case parse_iso_date(string.trim(raw)) {
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

fn parse_iso_date(text: String) -> Result(calendar.Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      Ok(calendar.Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
