//// The workflow registry: maps a workflow `kind` to its schema, and derives every
//// per-workflow datum the HTTP and instance layers need (first step, the gated
//// "finance" step, the commit permission, the title) FROM the schema — so those
//// layers never name a specific workflow. `schema_for` takes `Context` because some
//// schemas (project creation) source choices from the database.

import gleam/list
import gleam/option.{type Option, None, Some}
import shared/workflow/schema.{type Step, type WorkflowSchema}
import tempo/server/context.{type Context}
import tempo/server/workflow/project_schema as project
import tempo/server/workflow/schema as onboard

pub fn schema_for(kind: String, ctx: Context) -> Result(WorkflowSchema, Nil) {
  case kind {
    "onboard_engineer" -> Ok(onboard.onboard_schema())
    "create_project" -> project.create_project_schema(ctx)
    _ -> Error(Nil)
  }
}

pub fn step_ids(schema: WorkflowSchema) -> List(String) {
  list.map(schema.steps, fn(step) { step.id })
}

pub fn first_step(schema: WorkflowSchema) -> String {
  case schema.steps {
    [step, ..] -> step.id
    [] -> ""
  }
}

pub fn gated_step(schema: WorkflowSchema) -> Option(Step) {
  list.find(schema.steps, fn(step) {
    case step.requires_permission {
      Some(_) -> True
      None -> False
    }
  })
  |> option.from_result
}

pub fn finance_step(schema: WorkflowSchema) -> String {
  case gated_step(schema) {
    Some(step) -> step.id
    None -> first_step(schema)
  }
}

pub fn title(schema: WorkflowSchema) -> String {
  schema.title
}
