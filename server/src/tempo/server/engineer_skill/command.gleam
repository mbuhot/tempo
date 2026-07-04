//// Domain: the engineer-skill aggregate — an engineer's assessed level on a
//// skill, versioned over time. `command.route` destructures the engineer-skill
//// command and calls the operation here with its already-narrowed fields; the
//// operation returns the `Fact` it records, and `command.dispatch` records it
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`. The authorization gate (`skills.assess`) runs before
//// dispatch, so only a manager or owner reaches here.
////
//// `assess_skill` re-states the level from a date onward (the repository's
//// change), mirroring `engineer/command.promote`.

import gleam/int
import gleam/time/calendar.{type Date}
import shared/command.{EngineerSkillCommand} as gateway
import shared/engineer_skill/command.{type EngineerSkillCommand, AssessSkill}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route an engineer-skill command to its operation, returning the audit entry
/// and the fact it records. Exhaustive over `EngineerSkillCommand`.
pub fn route(
  command: EngineerSkillCommand,
) -> Result(Recorded, OperationError) {
  case command {
    AssessSkill(engineer_id:, skill_id:, level:, effective:) ->
      assess_skill(command, engineer_id:, skill_id:, level:, effective:)
  }
}

/// Record an engineer's assessed level on a skill from `effective` onward, with
/// the journal entry.
pub fn assess_skill(
  command: EngineerSkillCommand,
  engineer_id engineer_id: Int,
  skill_id skill_id: Int,
  level level: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "assess_skill",
        summary: "Assess engineer "
          <> int.to_string(engineer_id)
          <> " on skill "
          <> int.to_string(skill_id)
          <> " at level "
          <> int.to_string(level)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(EngineerSkillCommand(command)),
      ),
      facts: [
        fact.EngineerSkillAssessed(
          engineer_id: fact.EngineerId(engineer_id),
          skill_id: fact.SkillId(skill_id),
          level:,
          from: effective,
        ),
      ],
    ),
  )
}
