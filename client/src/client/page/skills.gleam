//// The Skills taxonomy admin page (behind `skills.manage`; the sidebar shows it
//// under Admin). The service taxonomy: the capability catalog, the skill catalog,
//// and the weighted composition matrix mapping skills onto capabilities. Reads
//// `GET /api/skills?as_of=`; every write (create a capability/skill, set or
//// remove a composition weight) is a page-local `CapabilityCommand`/`SkillCommand`
//// through the normal operations pipeline, then the page refetches the snapshot
//// so the catalog and matrix reflect the new truth. The create and composition
//// forms are page-local direct-submit (not the shared `ui.OpForm` machinery) —
//// their steppers and multi-field creates don't fit that engine.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg).

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/access as perm
import shared/capability/command as capability_command
import shared/command.{CapabilityCommand, SkillCommand}
import shared/skill/command as skill_command
import shared/skill/view.{
  type CapabilityInfo, type CapabilitySkillMapping, type SkillInfo,
  type TaxonomySnapshot, CapabilityInfo, CapabilitySkillMapping, SkillInfo,
} as skill_view

pub type Model {
  Model(as_of: Date, state: State, modal: Modal)
}

/// The page's load state: fetching, the loaded snapshot, or a load failure.
pub type State {
  Loading
  Loaded(snapshot: TaxonomySnapshot)
  Failed(detail: String)
}

/// The one modal the page can have open at a time, carrying its own form state.
pub type Modal {
  NoModal
  NewCapability(name: String, summary: String)
  NewSkill(name: String, summary: String)
  Composition(capability_id: Int)
}

pub type Msg {
  SnapshotReturned(
    as_of: Date,
    result: Result(TaxonomySnapshot, rsvp.Error(String)),
  )
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
  CapabilityModalOpened
  SkillModalOpened
  CompositionModalOpened(capability_id: Int)
  ModalDismissed
  CapabilityNameEdited(value: String)
  CapabilitySummaryEdited(value: String)
  CapabilityCreateConfirmed
  SkillNameEdited(value: String)
  SkillSummaryEdited(value: String)
  SkillCreateConfirmed
  CapabilitySkillWeightSet(capability_id: Int, skill_id: Int, weight: Int)
  CapabilitySkillRemoved(capability_id: Int, skill_id: Int)
}

pub fn init(_route, as_of: Date, _actor: String) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, state: Loading, modal: NoModal), fetch(as_of))
}

pub fn refetch(
  model: Model,
  as_of: Date,
  _actor: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:), fetch(as_of))
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/skills?as_of=" <> time.iso_date(as_of),
    skill_view.taxonomy_snapshot_decoder(),
    fn(result) { SnapshotReturned(as_of:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    SnapshotReturned(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(snapshot) -> Loaded(snapshot)
            Error(error) -> Failed(api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }

    CapabilityModalOpened -> #(
      Model(..model, modal: NewCapability(name: "", summary: "")),
      effect.none(),
      [],
    )
    SkillModalOpened -> #(
      Model(..model, modal: NewSkill(name: "", summary: "")),
      effect.none(),
      [],
    )
    CompositionModalOpened(capability_id:) -> #(
      Model(..model, modal: Composition(capability_id:)),
      effect.none(),
      [],
    )
    ModalDismissed -> #(Model(..model, modal: NoModal), effect.none(), [])

    CapabilityNameEdited(value:) ->
      case model.modal {
        NewCapability(summary:, ..) -> #(
          Model(..model, modal: NewCapability(name: value, summary:)),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }
    CapabilitySummaryEdited(value:) ->
      case model.modal {
        NewCapability(name:, ..) -> #(
          Model(..model, modal: NewCapability(name:, summary: value)),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }
    CapabilityCreateConfirmed ->
      case model.modal {
        NewCapability(name:, summary:) -> #(
          Model(..model, modal: NoModal),
          submit_capability(capability_command.CreateCapability(
            name:,
            summary:,
            effective: model.as_of,
          )),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    SkillNameEdited(value:) ->
      case model.modal {
        NewSkill(summary:, ..) -> #(
          Model(..model, modal: NewSkill(name: value, summary:)),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }
    SkillSummaryEdited(value:) ->
      case model.modal {
        NewSkill(name:, ..) -> #(
          Model(..model, modal: NewSkill(name:, summary: value)),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }
    SkillCreateConfirmed ->
      case model.modal {
        NewSkill(name:, summary:) -> #(
          Model(..model, modal: NoModal),
          submit_skill(skill_command.CreateSkill(
            name:,
            summary:,
            effective: model.as_of,
          )),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    CapabilitySkillWeightSet(capability_id:, skill_id:, weight:) ->
      case capability_id > 0 && skill_id > 0 {
        True -> #(
          Model(
            ..model,
            state: optimistic_weight(
              model.state,
              capability_id:,
              skill_id:,
              weight:,
            ),
          ),
          submit_capability(capability_command.SetCapabilitySkill(
            capability_id:,
            skill_id:,
            weight:,
            effective: model.as_of,
          )),
          [],
        )
        False -> #(model, effect.none(), [])
      }
    CapabilitySkillRemoved(capability_id:, skill_id:) -> #(
      model,
      submit_capability(capability_command.RemoveCapabilitySkill(
        capability_id:,
        skill_id:,
        effective: model.as_of,
      )),
      [],
    )

    // A write landed (or failed): refetch the snapshot so the catalog and matrix
    // show the server's truth, and signal the write so Activity can refresh.
    OperationReturned(Ok(_)) -> #(model, fetch(model.as_of), [
      OperationCommitted,
    ])
    OperationReturned(Error(_)) -> #(model, fetch(model.as_of), [])
  }
}

/// Optimistically apply a weight edit to a loaded snapshot's mappings so rapid
/// stepper clicks compound off the just-set weight instead of the stale
/// render-captured one; the refetch after the write still reconciles with the
/// server's truth.
fn optimistic_weight(
  state: State,
  capability_id capability_id: Int,
  skill_id skill_id: Int,
  weight weight: Int,
) -> State {
  case state {
    Loaded(snapshot) -> {
      let matched =
        list.any(snapshot.mappings, fn(mapping) {
          mapping.capability_id == capability_id && mapping.skill_id == skill_id
        })
      let mappings = case matched {
        True ->
          list.map(snapshot.mappings, fn(mapping) {
            case
              mapping.capability_id == capability_id
              && mapping.skill_id == skill_id
            {
              True -> CapabilitySkillMapping(capability_id:, skill_id:, weight:)
              False -> mapping
            }
          })
        False -> [
          CapabilitySkillMapping(capability_id:, skill_id:, weight:),
          ..snapshot.mappings
        ]
      }
      Loaded(skill_view.TaxonomySnapshot(..snapshot, mappings:))
    }
    _ -> state
  }
}

fn submit_capability(
  command: capability_command.CapabilityCommand,
) -> Effect(Msg) {
  api.submit_operation(CapabilityCommand(command), OperationReturned)
}

fn submit_skill(command: skill_command.SkillCommand) -> Effect(Msg) {
  api.submit_operation(SkillCommand(command), OperationReturned)
}

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  html.div([attribute.class("skills")], [
    ui.page_head(
      title: "Capabilities & skills",
      blurb: "The service taxonomy: what we deliver (capabilities), what consultants know (skills), and how skills compose into a capability.",
      actions: view_actions(permissions),
    ),
    case model.state {
      Loading -> ui.empty_state(message: "Loading the taxonomy…")
      Failed(detail) ->
        ui.empty_state(message: "Could not load the taxonomy: " <> detail)
      Loaded(snapshot) -> view_loaded(snapshot)
    },
    view_modal(model),
  ])
}

fn view_actions(permissions: Set(String)) -> List(Element(Msg)) {
  case set.contains(permissions, perm.skills_manage) {
    True -> [
      ui.button(
        label: "+ Skill",
        kind: ui.Ghost,
        size: ui.Medium,
        on_press: SkillModalOpened,
      ),
      ui.button(
        label: "+ Capability",
        kind: ui.Primary,
        size: ui.Medium,
        on_press: CapabilityModalOpened,
      ),
    ]
    False -> []
  }
}

fn view_loaded(snapshot: TaxonomySnapshot) -> Element(Msg) {
  html.div([], [
    view_stats(snapshot),
    view_tax_grid(snapshot),
    view_matrix_panel(snapshot),
  ])
}

fn view_stats(snapshot: TaxonomySnapshot) -> Element(Msg) {
  html.div([attribute.class("stats stats--cols-3")], [
    ui.stat(
      value: int.to_string(list.length(snapshot.capabilities)),
      unit: "",
      label: "Capabilities",
      pct: ui.NoPct,
    ),
    ui.stat(
      value: int.to_string(list.length(snapshot.skills)),
      unit: "",
      label: "Skills",
      pct: ui.NoPct,
    ),
    ui.stat(
      value: int.to_string(list.length(snapshot.mappings)),
      unit: "",
      label: "Mappings",
      pct: ui.NoPct,
    ),
  ])
}

fn view_tax_grid(snapshot: TaxonomySnapshot) -> Element(Msg) {
  html.div([attribute.class("tax-grid")], [
    view_capabilities_panel(snapshot),
    view_skills_panel(snapshot),
  ])
}

fn view_capabilities_panel(snapshot: TaxonomySnapshot) -> Element(Msg) {
  let rows =
    list.index_map(snapshot.capabilities, fn(capability, index) {
      view_capability_row(capability, index, snapshot)
    })
  ui.panel(
    title: "Capabilities",
    count: int.to_string(list.length(snapshot.capabilities)),
    right: [],
    body: [html.div([attribute.role("list")], rows)],
  )
}

fn view_capability_row(
  capability: CapabilityInfo,
  index: Int,
  snapshot: TaxonomySnapshot,
) -> Element(Msg) {
  let CapabilityInfo(capability_id:, name:, summary:) = capability
  let skill_count =
    list.length(
      list.filter(snapshot.mappings, fn(mapping) {
        mapping.capability_id == capability_id
      }),
    )
  html.div(
    [
      attribute.class("list-row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      ui.swatch(category: index + 1, inline: False),
      html.div([], [
        html.div([attribute.class("list-row__name")], [html.text(name)]),
        html.div([attribute.class("list-row__sub")], [html.text(summary)]),
      ]),
      html.span([attribute.class("list-row__meta")], [
        html.text(int.to_string(skill_count) <> " skills"),
      ]),
      html.button(
        [
          attribute.class("list-row__edit"),
          event.on_click(CompositionModalOpened(capability_id:)),
        ],
        [html.text("Edit")],
      ),
    ],
  )
}

fn view_skills_panel(snapshot: TaxonomySnapshot) -> Element(Msg) {
  let rows =
    list.map(snapshot.skills, fn(skill) { view_skill_row(skill, snapshot) })
  ui.panel(
    title: "Skills",
    count: int.to_string(list.length(snapshot.skills)),
    right: [],
    body: [html.div([attribute.role("list")], rows)],
  )
}

fn view_skill_row(
  skill: SkillInfo,
  snapshot: TaxonomySnapshot,
) -> Element(Msg) {
  let SkillInfo(skill_id:, name:, ..) = skill
  let capability_count =
    list.length(
      list.filter(snapshot.mappings, fn(mapping) {
        mapping.skill_id == skill_id
      }),
    )
  html.div(
    [
      attribute.class("list-row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.div([attribute.class("list-row__name")], [html.text(name)]),
      html.span([attribute.class("list-row__meta")], [
        html.text("in " <> int.to_string(capability_count) <> " caps"),
      ]),
    ],
  )
}

fn view_matrix_panel(snapshot: TaxonomySnapshot) -> Element(Msg) {
  ui.panel(
    title: "Composition",
    count: "capability × skill · weight",
    right: [
      html.span([attribute.class("note")], [
        html.text(
          "type a weight (1–3) in a cell, or ＋ to add a skill — feeds the weighted-average rollup",
        ),
      ]),
    ],
    body: [
      html.div([attribute.class("access__matrix-scroll")], [
        html.table([attribute.class("access__matrix")], [
          html.thead([], [
            html.tr([], [
              html.th([attribute.class("access__perm")], [
                html.text("skill ↓ · capability →"),
              ]),
              ..list.map(snapshot.capabilities, fn(capability) {
                html.th([], [html.text(capability.name)])
              })
            ]),
          ]),
          html.tbody(
            [],
            list.map(snapshot.skills, fn(skill) {
              view_matrix_row(skill, snapshot)
            }),
          ),
        ]),
      ]),
    ],
  )
}

fn view_matrix_row(
  skill: SkillInfo,
  snapshot: TaxonomySnapshot,
) -> Element(Msg) {
  html.tr([], [
    html.td([attribute.class("access__perm")], [html.text(skill.name)]),
    ..list.map(snapshot.capabilities, fn(capability) {
      view_matrix_cell(capability.capability_id, skill.skill_id, snapshot)
    })
  ])
}

fn view_matrix_cell(
  capability_id: Int,
  skill_id: Int,
  snapshot: TaxonomySnapshot,
) -> Element(Msg) {
  case
    list.find(snapshot.mappings, fn(mapping) {
      mapping.capability_id == capability_id && mapping.skill_id == skill_id
    })
  {
    Ok(mapping) ->
      html.td([attribute.class("access__cell access__cell--on")], [
        view_weight_input(capability_id, skill_id, mapping.weight),
      ])
    Error(Nil) ->
      html.td([attribute.class("access__cell")], [
        view_cap_add_button(capability_id, skill_id),
      ])
  }
}

fn view_weight_input(
  capability_id: Int,
  skill_id: Int,
  weight: Int,
) -> Element(Msg) {
  html.input([
    attribute.class("weight-input"),
    attribute.type_("number"),
    attribute.attribute("min", "1"),
    attribute.attribute("max", "3"),
    attribute.value(int.to_string(weight)),
    event.on_change(fn(raw) {
      CapabilitySkillWeightSet(
        capability_id:,
        skill_id:,
        weight: parse_weight(raw),
      )
    }),
  ])
}

fn view_cap_add_button(capability_id: Int, skill_id: Int) -> Element(Msg) {
  html.button(
    [
      attribute.class("cap-add"),
      event.on_click(CapabilitySkillWeightSet(
        capability_id:,
        skill_id:,
        weight: 1,
      )),
    ],
    [html.text("＋")],
  )
}

fn parse_weight(raw: String) -> Int {
  int.parse(raw) |> result.unwrap(1) |> int.clamp(min: 1, max: 3)
}

fn view_modal(model: Model) -> Element(Msg) {
  case model.modal {
    NoModal -> element.none()
    NewCapability(name:, summary:) -> view_capability_modal(name, summary)
    NewSkill(name:, summary:) -> view_skill_modal(name, summary)
    Composition(capability_id:) ->
      case model.state {
        Loaded(snapshot) -> view_composition_modal(snapshot, capability_id)
        _ -> element.none()
      }
  }
}

fn view_capability_modal(name: String, summary: String) -> Element(Msg) {
  ui.modal(
    title: "New capability",
    error: "",
    body: [
      view_text_field(
        label: "Name",
        value: name,
        placeholder: "e.g. Cloud Platform Engineering",
        to_msg: CapabilityNameEdited,
      ),
      view_text_field(
        label: "Summary",
        value: summary,
        placeholder: "What we deliver",
        to_msg: CapabilitySummaryEdited,
      ),
    ],
    on_cancel: ModalDismissed,
    on_confirm: CapabilityCreateConfirmed,
    confirm_label: "Create",
  )
}

fn view_skill_modal(name: String, summary: String) -> Element(Msg) {
  ui.modal(
    title: "New skill",
    error: "",
    body: [
      view_text_field(
        label: "Name",
        value: name,
        placeholder: "e.g. Kubernetes",
        to_msg: SkillNameEdited,
      ),
      view_text_field(
        label: "Summary",
        value: summary,
        placeholder: "What a consultant knows",
        to_msg: SkillSummaryEdited,
      ),
    ],
    on_cancel: ModalDismissed,
    on_confirm: SkillCreateConfirmed,
    confirm_label: "Create",
  )
}

fn view_text_field(
  label label: String,
  value value: String,
  placeholder placeholder: String,
  to_msg to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.placeholder(placeholder),
      attribute.value(value),
      event.on_input(to_msg),
    ]),
  ])
}

fn view_composition_modal(
  snapshot: TaxonomySnapshot,
  capability_id: Int,
) -> Element(Msg) {
  let capability_name = case
    list.find(snapshot.capabilities, fn(capability) {
      capability.capability_id == capability_id
    })
  {
    Ok(capability) -> capability.name
    Error(Nil) -> ""
  }
  let mapped =
    list.filter(snapshot.mappings, fn(mapping) {
      mapping.capability_id == capability_id
    })
  let unmapped =
    list.filter(snapshot.skills, fn(skill) {
      !list.any(mapped, fn(mapping) { mapping.skill_id == skill.skill_id })
    })
  ui.modal(
    title: "Composition — " <> capability_name,
    error: "",
    body: list.flatten([
      [
        html.p([attribute.class("note")], [
          html.text(
            "Which skills make up this capability, and how heavily each weighs in an engineer's rolled-up proficiency.",
          ),
        ]),
      ],
      list.map(mapped, fn(mapping) { view_weight_row(mapping, snapshot) }),
      [view_add_skill_field(capability_id, unmapped)],
    ]),
    on_cancel: ModalDismissed,
    on_confirm: ModalDismissed,
    confirm_label: "Save composition",
  )
}

fn view_weight_row(
  mapping: CapabilitySkillMapping,
  snapshot: TaxonomySnapshot,
) -> Element(Msg) {
  let CapabilitySkillMapping(capability_id:, skill_id:, weight:) = mapping
  let skill_name = case
    list.find(snapshot.skills, fn(skill) { skill.skill_id == skill_id })
  {
    Ok(skill) -> skill.name
    Error(Nil) -> ""
  }
  html.div([attribute.class("weight-row")], [
    html.span([attribute.class("weight-row__name")], [html.text(skill_name)]),
    html.span([attribute.class("stepper")], [
      html.button(
        [
          event.on_click(CapabilitySkillWeightSet(
            capability_id:,
            skill_id:,
            weight: int.clamp(weight - 1, min: 1, max: 3),
          )),
        ],
        [html.text("−")],
      ),
      html.span([], [html.text(int.to_string(weight))]),
      html.button(
        [
          event.on_click(CapabilitySkillWeightSet(
            capability_id:,
            skill_id:,
            weight: int.clamp(weight + 1, min: 1, max: 3),
          )),
        ],
        [html.text("+")],
      ),
    ]),
    html.button(
      [
        attribute.class("weight-row__remove"),
        attribute.attribute("title", "remove"),
        event.on_click(CapabilitySkillRemoved(capability_id:, skill_id:)),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_add_skill_field(
  capability_id: Int,
  unmapped: List(SkillInfo),
) -> Element(Msg) {
  html.div(
    [
      attribute.class("op-form"),
      attribute.style("margin-top", "var(--space-md)"),
    ],
    [
      html.label([attribute.class("op-form__field")], [
        html.span([], [html.text("Add a skill")]),
        html.select(
          [
            event.on_change(fn(raw) {
              CapabilitySkillWeightSet(
                capability_id:,
                skill_id: parse_skill_id(raw),
                weight: 1,
              )
            }),
          ],
          [
            html.option([attribute.value("")], "Choose a skill…"),
            ..list.map(unmapped, fn(skill) {
              html.option(
                [attribute.value(int.to_string(skill.skill_id))],
                skill.name,
              )
            })
          ],
        ),
      ]),
    ],
  )
}

fn parse_skill_id(raw: String) -> Int {
  int.parse(raw) |> result.unwrap(0)
}
