//// The facts the system records — the typed information schema. Each variant is
//// a thing that happened/holds that we persist as a temporal row; `repository`
//// maps it to the SQL that records it. The temporal database preserves the
//// history (a new version per Change); the only history a fact loses is a
//// back-dated edit that overwrites an earlier value, which the event_log audits.
////
//// This is the event-sourced shape without the event-log+projection machinery:
//// the facts ARE the rows, recorded directly.

import gleam/time/calendar.{type Date}

pub type Fact {
  /// An engineer's contact details in force from `effective`.
  EngineerContactDetails(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
    effective: Date,
  )
  /// An engineer's banking details in force from `effective`.
  EngineerBankingDetails(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    effective: Date,
  )
  /// An engineer's emergency contact in force from `effective`.
  EngineerEmergencyContact(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
    effective: Date,
  )
  /// A client's profile in force from `effective`.
  ClientProfile(client_id: Int, name: String, effective: Date)
  /// A project's profile (title/summary) in force from `effective`.
  ProjectProfile(
    project_id: Int,
    title: String,
    summary: String,
    effective: Date,
  )
  /// A project's plan (budget/target) in force from `effective`.
  ProjectPlan(
    project_id: Int,
    budget: Float,
    target_completion: Date,
    effective: Date,
  )
  /// Hours an engineer worked on a project on a day (0 clears the day).
  EngineerWorkedHours(
    engineer_id: Int,
    project_id: Int,
    day: Date,
    hours: Float,
  )
}
