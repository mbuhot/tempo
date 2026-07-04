//// Domain: the capability aggregate — the capability-identity lifecycle and the
//// skill mappings that compose it. `command.route` destructures each capability
//// command and calls the matching operation here with its already-narrowed
//// fields; the operation returns the `Fact`s it records, and `command.dispatch`
//// records them (through `repository`) and persists the journal in ONE
//// transaction. No HTTP — never imports `wisp`.
////
//// `create_capability` reserves the capability id (so it threads into the
//// founding `CapabilityProfile` fact without a read-back) then records the
//// anchor and profile. `define_capability` re-states the profile from a date
//// onward (the repository's upsert — the same fact as the founding write).
//// `retire_capability` records `CapabilityRetired`, which the repository
//// implements as the cascade (skill mappings capped first, then the profile).
//// `set_capability_skill`/`remove_capability_skill` write the weighted
//// composition matrix.

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/capability/command.{
  type CapabilityCommand, CreateCapability, DefineCapability,
  RemoveCapabilitySkill, RetireCapability, SetCapabilitySkill,
}
import shared/command.{CapabilityCommand} as gateway
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Route a capability command to its operation, returning the audit entry and the
/// facts it records. The `case` is exhaustive over `CapabilityCommand`, so a new
/// capability command with no arm is a compile error.
pub fn route(
  conn: pog.Connection,
  command: CapabilityCommand,
) -> Result(Recorded, OperationError) {
  case command {
    CreateCapability(name:, summary:, effective:) ->
      create_capability(conn, command, name:, summary:, effective:)
    DefineCapability(capability_id:, name:, summary:, effective:) ->
      define_capability(command, capability_id:, name:, summary:, effective:)
    RetireCapability(capability_id:, effective:) ->
      retire_capability(command, capability_id:, effective:)
    SetCapabilitySkill(capability_id:, skill_id:, weight:, effective:) ->
      set_capability_skill(
        command,
        capability_id:,
        skill_id:,
        weight:,
        effective:,
      )
    RemoveCapabilitySkill(capability_id:, skill_id:, effective:) ->
      remove_capability_skill(command, capability_id:, skill_id:, effective:)
  }
}

/// Found a capability: reserve the id, then record the anchor and its founding
/// profile, with the journal entry.
pub fn create_capability(
  conn: pog.Connection,
  command: CapabilityCommand,
  name name: String,
  summary summary: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  use capability_id <- result.try(repository.create_capability(conn))
  let fact.CapabilityId(id) = capability_id
  Ok(
    Recorded(
      entry: Event(
        operation: "create_capability",
        summary: "Create capability "
          <> name
          <> " (capability "
          <> int.to_string(id)
          <> ") from "
          <> operation.iso(effective),
        payload: gateway.encode_command(CapabilityCommand(command)),
      ),
      facts: [
        fact.CapabilityProfile(capability_id:, name:, summary:, from: effective),
      ],
    ),
  )
}

/// Re-state a capability's profile from `effective` onward, with the journal
/// entry.
pub fn define_capability(
  command: CapabilityCommand,
  capability_id capability_id: Int,
  name name: String,
  summary summary: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "define_capability",
        summary: "Define capability "
          <> int.to_string(capability_id)
          <> " as "
          <> name
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(CapabilityCommand(command)),
      ),
      facts: [
        fact.CapabilityProfile(
          capability_id: fact.CapabilityId(capability_id),
          name:,
          summary:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Retire a capability from `effective`, with the journal entry. The
/// `CapabilityRetired` fact caps the profile and cascades the cap to the
/// capability's skill mappings in the repository.
pub fn retire_capability(
  command: CapabilityCommand,
  capability_id capability_id: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "retire_capability",
        summary: "Retire capability "
          <> int.to_string(capability_id)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(CapabilityCommand(command)),
      ),
      facts: [
        fact.CapabilityRetired(
          capability_id: fact.CapabilityId(capability_id),
          from: effective,
        ),
      ],
    ),
  )
}

/// Set the weight a skill contributes to a capability's composition from
/// `effective` onward, with the journal entry.
pub fn set_capability_skill(
  command: CapabilityCommand,
  capability_id capability_id: Int,
  skill_id skill_id: Int,
  weight weight: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "set_capability_skill",
        summary: "Set skill "
          <> int.to_string(skill_id)
          <> " on capability "
          <> int.to_string(capability_id)
          <> " to weight "
          <> int.to_string(weight)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(CapabilityCommand(command)),
      ),
      facts: [
        fact.CapabilitySkillSet(
          capability_id: fact.CapabilityId(capability_id),
          skill_id: fact.SkillId(skill_id),
          weight:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Remove a skill from a capability's composition from `effective`, with the
/// journal entry.
pub fn remove_capability_skill(
  command: CapabilityCommand,
  capability_id capability_id: Int,
  skill_id skill_id: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "remove_capability_skill",
        summary: "Remove skill "
          <> int.to_string(skill_id)
          <> " from capability "
          <> int.to_string(capability_id)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(CapabilityCommand(command)),
      ),
      facts: [
        fact.CapabilitySkillRemoved(
          capability_id: fact.CapabilityId(capability_id),
          skill_id: fact.SkillId(skill_id),
          from: effective,
        ),
      ],
    ),
  )
}
