//// Builds the create_project WorkflowSchema with client choices sourced from the
//// database, so each call reflects the current client directory.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import shared/access
import shared/level
import shared/workflow/schema.{
  type Choice, type WorkflowSchema, BoolField, Choice, DateField, EnumField,
  Field, GroupField, IntField, MoneyField, OneColumn, Section, Step, TextField,
  TwoColumn, WorkflowSchema,
}
import tempo/server/client/sql as client_sql
import tempo/server/context.{type Context}

/// The workflow kind tag for all create-project instances.
pub const kind = "create_project"

/// Build the create_project schema, sourcing client choices from the DB.
pub fn create_project_schema(ctx: Context) -> Result(WorkflowSchema, Nil) {
  use returned <- result.map(
    client_sql.clients_for_choice(ctx.db)
    |> result.map_error(fn(_) { Nil }),
  )
  let client_options =
    [Choice("__new__", "+ New client")]
    |> list.append(
      list.filter_map(returned.rows, fn(row) {
        case row.id, row.name {
          Some(id), Some(name) -> Ok(Choice(int.to_string(id), name))
          _, _ -> Error(Nil)
        }
      }),
    )
  WorkflowSchema(kind:, title: "Create a project", steps: [
    Step(id: "client", title: "Client", requires_permission: None, sections: [
      Section(title: "", layout: TwoColumn, fields: [
        Field(
          "client",
          "Client",
          EnumField(options: client_options),
          True,
          Some(
            "Choose an existing client, or pick \"+ New client\" and enter a name below",
          ),
        ),
        Field("new_client_name", "New client name", TextField, False, None),
      ]),
    ]),
    Step(
      id: "description",
      title: "Description",
      requires_permission: None,
      sections: [
        Section(title: "", layout: OneColumn, fields: [
          Field("title", "Project title", TextField, True, None),
          Field("summary", "Summary", TextField, False, None),
        ]),
      ],
    ),
    Step(
      id: "timeframe",
      title: "Timeframe & budget",
      requires_permission: None,
      sections: [
        Section(title: "", layout: TwoColumn, fields: [
          Field("start", "Start date", DateField, True, None),
          Field("end", "End date", DateField, True, None),
          Field("budget", "Budget", MoneyField, True, None),
          Field(
            "target_completion",
            "Target completion",
            DateField,
            False,
            None,
          ),
        ]),
      ],
    ),
    Step(
      id: "team",
      title: "Team requirements",
      requires_permission: None,
      sections: [
        Section(title: "", layout: OneColumn, fields: [
          Field(
            "requirements",
            "Requirements",
            GroupField(
              item_fields: [
                Field(
                  "level",
                  "Level",
                  EnumField(options: level_options()),
                  True,
                  None,
                ),
                Field("quantity", "Quantity", IntField, True, None),
              ],
              add_label: "+ Add requirement",
            ),
            True,
            None,
          ),
        ]),
      ],
    ),
    Step(
      id: "contract",
      title: "Contract",
      requires_permission: None,
      sections: [
        Section(title: "", layout: TwoColumn, fields: [
          Field(
            "contract_from",
            "Contract start",
            DateField,
            True,
            Some("Selects the rate card this contract bills at"),
          ),
          Field("contract_to", "Contract end", DateField, True, None),
        ]),
      ],
    ),
    Step(
      id: "confirm",
      title: "Confirmation",
      requires_permission: Some(access.project_create_confirm),
      sections: [
        Section(title: "", layout: OneColumn, fields: [
          Field(
            "confirmed",
            "Confirmed for creation",
            BoolField,
            True,
            Some("An owner confirms the project details before it is created"),
          ),
        ]),
      ],
    ),
  ])
}

fn level_options() -> List(Choice) {
  [1, 2, 3, 4, 5, 6, 7]
  |> list.map(fn(rank) { Choice(int.to_string(rank), level.band(rank)) })
}
