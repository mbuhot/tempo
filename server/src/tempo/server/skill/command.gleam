//// Domain: the skill aggregate — the skill-identity lifecycle, the leaf nodes of
//// the capability taxonomy. `command.route` destructures each skill command and
//// calls the matching operation here with its already-narrowed fields; the
//// operation returns the `Fact`s it records, and `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// `create_skill` reserves the skill id (so it threads into the founding
//// `SkillProfile` fact without a read-back) then records the anchor and profile.
//// `define_skill` re-states the profile from a date onward (the repository's
//// upsert — the same fact as the founding write). `retire_skill` records
//// `SkillRetired`, which the repository implements as the cascade (every
//// capability's mapping to the skill capped first, then the profile).

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{SkillCommand} as gateway
import shared/skill/command.{
  type SkillCommand, CreateSkill, DefineSkill, RetireSkill,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Route a skill command to its operation, returning the audit entry and the
/// facts it records. The `case` is exhaustive over `SkillCommand`, so a new skill
/// command with no arm is a compile error.
pub fn route(
  conn: pog.Connection,
  command: SkillCommand,
) -> Result(Recorded, OperationError) {
  case command {
    CreateSkill(name:, summary:, effective:) ->
      create_skill(conn, command, name:, summary:, effective:)
    DefineSkill(skill_id:, name:, summary:, effective:) ->
      define_skill(command, skill_id:, name:, summary:, effective:)
    RetireSkill(skill_id:, effective:) ->
      retire_skill(command, skill_id:, effective:)
  }
}

/// Found a skill: reserve the id, then record the anchor and its founding
/// profile, with the journal entry.
pub fn create_skill(
  conn: pog.Connection,
  command: SkillCommand,
  name name: String,
  summary summary: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  use skill_id <- result.try(repository.create_skill(conn))
  let fact.SkillId(id) = skill_id
  Ok(
    Recorded(
      entry: Event(
        operation: "create_skill",
        summary: "Create skill "
          <> name
          <> " (skill "
          <> int.to_string(id)
          <> ") from "
          <> operation.iso(effective),
        payload: gateway.encode_command(SkillCommand(command)),
      ),
      facts: [fact.SkillProfile(skill_id:, name:, summary:, from: effective)],
    ),
  )
}

/// Re-state a skill's profile from `effective` onward, with the journal entry.
pub fn define_skill(
  command: SkillCommand,
  skill_id skill_id: Int,
  name name: String,
  summary summary: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "define_skill",
        summary: "Define skill "
          <> int.to_string(skill_id)
          <> " as "
          <> name
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(SkillCommand(command)),
      ),
      facts: [
        fact.SkillProfile(
          skill_id: fact.SkillId(skill_id),
          name:,
          summary:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Retire a skill from `effective`, with the journal entry. The `SkillRetired`
/// fact caps the profile and cascades the cap to every capability's mapping to
/// the skill in the repository.
pub fn retire_skill(
  command: SkillCommand,
  skill_id skill_id: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "retire_skill",
        summary: "Retire skill "
          <> int.to_string(skill_id)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(SkillCommand(command)),
      ),
      facts: [
        fact.SkillRetired(skill_id: fact.SkillId(skill_id), from: effective),
      ],
    ),
  )
}
