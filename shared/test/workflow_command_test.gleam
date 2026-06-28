//// The workflow commit command round-trips through the top-level `Command` codec,
//// proving the new aggregate is wired into the envelope's encode and op-dispatch.

import gleam/json
import shared/command.{WorkflowCommand}
import shared/workflow/command as workflow_command

pub fn commit_onboarding_round_trips_through_command_test() {
  let command = WorkflowCommand(workflow_command.CommitOnboarding("wf-1"))

  let assert Ok(decoded) =
    json.parse(
      json.to_string(command.encode_command(command)),
      command.command_decoder(),
    )

  assert decoded == command
}
