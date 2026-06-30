import client/workflow/render
import client/workflow/wizard
import gleam/dict
import gleam/option
import shared/workflow/kind
import shared/workflow/schema
import shared/workflow/value
import shared/workflow/view

fn role_field() -> schema.Field {
  schema.Field(
    key: "role",
    label: "Role",
    kind: schema.TextField,
    required: True,
    help: option.None,
  )
}

fn identity_step() -> schema.Step {
  let name =
    schema.Field(
      key: "full_name",
      label: "Name",
      kind: schema.TextField,
      required: True,
      help: option.None,
    )
  let team =
    schema.Field(
      key: "team",
      label: "Team",
      kind: schema.GroupField(item_fields: [role_field()], add_label: "Add"),
      required: False,
      help: option.None,
    )
  schema.Step(
    id: "identity",
    title: "Identity",
    sections: [
      schema.Section(title: "Identity", layout: schema.OneColumn, fields: [
        name, team,
      ]),
    ],
    requires_permission: option.None,
  )
}

fn loaded_model() -> wizard.Model {
  let workflow =
    schema.WorkflowSchema(kind: "onboard_engineer", title: "Onboard", steps: [
      identity_step(),
    ])
  let saved_step =
    dict.from_list([
      #("full_name", value.TextValue("Ada")),
      #(
        "team",
        value.RowsValue([dict.from_list([#("role", value.TextValue("Eng"))])]),
      ),
    ])
  let draft =
    view.DraftView(
      instance_id: "1",
      kind: "onboard_engineer",
      status: "draft",
      current_step: "identity",
      can_act: True,
      values: dict.from_list([#("identity", saved_step)]),
      step_status: dict.from_list([#("identity", view.Active)]),
    )
  let #(model, _) = wizard.init("1", kind.OnboardEngineer)
  let #(model, _, _) = wizard.update(model, wizard.SchemaFetched(Ok(workflow)))
  let #(model, _, _) = wizard.update(model, wizard.DraftFetched(Ok(draft)))
  model
}

fn team_rows(model: wizard.Model) -> List(dict.Dict(String, String)) {
  case dict.get(wizard.groups_map(model, identity_step()), "team") {
    Ok(rows) -> rows
    Error(_) -> []
  }
}

pub fn loading_a_draft_shows_its_saved_values_test() {
  let model = loaded_model()
  assert wizard.field_value(model, "identity", "full_name") == "Ada"
  assert team_rows(model) == [dict.from_list([#("role", "Eng")])]
}

pub fn a_group_keystroke_survives_an_autosave_re_render_test() {
  let typed =
    wizard.update(
      loaded_model(),
      wizard.FieldChanged(render.RowFieldChanged(
        step: "identity",
        field: "team",
        index: 0,
        item_key: "role",
        raw: "Engineering",
      )),
    )
  let #(typed_model, _, _) = typed
  assert team_rows(typed_model) == [dict.from_list([#("role", "Engineering")])]

  let #(re_rendered, _, _) = wizard.update(typed_model, wizard.Saved(Ok(Nil)))
  assert team_rows(re_rendered) == [dict.from_list([#("role", "Engineering")])]
}

pub fn a_scalar_keystroke_survives_an_autosave_re_render_test() {
  let #(typed_model, _, _) =
    wizard.update(
      loaded_model(),
      wizard.FieldChanged(render.Edited(
        step: "identity",
        field: "full_name",
        raw: "Ada Lovelace",
      )),
    )
  assert wizard.field_value(typed_model, "identity", "full_name")
    == "Ada Lovelace"

  let #(re_rendered, _, _) = wizard.update(typed_model, wizard.Saved(Ok(Nil)))
  assert wizard.field_value(re_rendered, "identity", "full_name")
    == "Ada Lovelace"
}
