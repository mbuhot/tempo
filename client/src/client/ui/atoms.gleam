//// Pure data -> `Element(msg)` view atoms, generic over the host page's `msg`.
//// Emits the prototype's class names verbatim; categorical colours are passed
//// through as inline `style` referencing `var(--cat-N)` tokens — NEVER a
//// literal hex.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

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

/// The standard list-page template: the page head (title, blurb, page-level
/// actions) above the body wrapped in a `.panel` card with no redundant title —
/// the page title is the only heading. Keeping `.panel` preserves the card chrome
/// and the `.panel:has(.dt){overflow:visible}` popover fix the data table relies on.
pub fn list_page(
  title title: String,
  blurb blurb: String,
  actions actions: List(Element(msg)),
  body body: Element(msg),
) -> Element(msg) {
  html.div([], [
    page_head(title:, blurb:, actions:),
    html.div([attribute.class("panel")], [
      html.div([attribute.class("panel__body")], [body]),
    ]),
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
  html.div(
    [
      attribute.class("panel"),
      attribute.role("region"),
      attribute.aria_label(title),
    ],
    [
      html.div([attribute.class("panel__head")], [
        html.h2([], [html.text(title)]),
        count_badge,
        right_cluster,
      ]),
      html.div([attribute.class("panel__body")], body),
    ],
  )
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
    [attribute.class(class), attribute.style("background", cat_color(category))],
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
    [attribute.class(class), attribute.style("background", cat_color(category))],
    [],
  )
}

/// A status pill: a coloured dot and a label, the colour selected by `variant`
/// (e.g. "draft"/"issued"/"paid"/"active"/"ended"). Mirrors the prototype's
/// `.pill`.
pub fn pill(variant variant: String, label label: String) -> Element(msg) {
  html.span([attribute.class("pill pill--" <> variant)], [html.text(label)])
}

/// How a `chip` is toned: `Neutral` reads as the sunken-surface neutral palette
/// (level, day-rate), `Accent` as the accent-soft palette (allocation fraction).
pub type ChipTone {
  Neutral
  Accent
}

/// A compact, dotless pill for dense card sub-lines (the board/team cards' level,
/// allocation-fraction, and day-rate badges). Emits `<span class="chip chip--…">`
/// so the tight 2px/4px padding can never be applied without the primitive. Unlike
/// `pill` it carries no leading dot and a tighter, square-cornered shape.
pub fn chip(label label: String, tone tone: ChipTone) -> Element(msg) {
  let tone_class = case tone {
    Neutral -> "chip chip--neutral"
    Accent -> "chip chip--accent"
  }
  html.span([attribute.class(tone_class)], [html.text(label)])
}

/// A `chip` rendered as a clickable `<button>` — the meeting attendance pill
/// toggle: `text` is the chip's own caption (e.g. "Required"), `label` the
/// accessible name for the action clicking it performs (e.g. "Make optional"),
/// also rendered as its tooltip. Kept distinct from `chip` (which is inert) so a
/// clickable pill can never be built without an accessible name.
pub fn chip_button(
  label label: String,
  text text: String,
  tone tone: ChipTone,
  on_press on_press: msg,
) -> Element(msg) {
  let tone_class = case tone {
    Neutral -> "chip chip--neutral chip--btn"
    Accent -> "chip chip--accent chip--btn"
  }
  html.button(
    [
      attribute.class(tone_class),
      attribute.attribute("aria-label", label),
      attribute.attribute("title", label),
      event.on_click(on_press),
    ],
    [html.text(text)],
  )
}

/// How an `icon_button` is tinted on hover: `IconNeutral` the default accent
/// tint (row actions like Reschedule/Add attendee), `IconDanger` a red tint
/// (destructive actions like Cancel), `IconPlain` a borderless glyph that only
/// picks up a subtle danger tint on hover (inline removes/dismissals).
pub type IconTone {
  IconNeutral
  IconDanger
  IconPlain
}

/// An icon-only button: the icon (from `client/icons`) is decorative
/// (`aria-hidden`), so `label` alone is the accessible name — also rendered as
/// a `title` tooltip. The only place the `icon-btn` class is emitted, so an
/// icon button can never be built without an accessible name.
pub fn icon_button(
  label label: String,
  icon icon: Element(msg),
  tone tone: IconTone,
  on_press on_press: msg,
) -> Element(msg) {
  let tone_class = case tone {
    IconNeutral -> "icon-btn"
    IconDanger -> "icon-btn icon-btn--danger"
    IconPlain -> "icon-btn icon-btn--plain"
  }
  html.button(
    [
      attribute.class(tone_class),
      attribute.attribute("aria-label", label),
      attribute.attribute("title", label),
      event.on_click(on_press),
    ],
    [icon],
  )
}

/// How a `button` is styled and sized. `Primary` is the filled accent button,
/// `Ghost` the bordered surface variant; `Medium` is the default size, `Small`
/// the dense `btn--sm` variant.
pub type ButtonKind {
  Primary
  Ghost
}

pub type ButtonSize {
  Medium
  Small
}

/// A button: the only place the `btn` class (and its `btn--ghost` / `btn--sm`
/// modifiers) is emitted, so the class can never be used without a real
/// `<button>` carrying its click handler and visible label. Keeping the visible
/// text means e2e `getByRole("button", { name })` still matches.
pub fn button(
  label label: String,
  kind kind: ButtonKind,
  size size: ButtonSize,
  on_press on_press: msg,
) -> Element(msg) {
  let kind_class = case kind {
    Primary -> ""
    Ghost -> " btn--ghost"
  }
  let size_class = case size {
    Medium -> ""
    Small -> " btn--sm"
  }
  html.button(
    [
      attribute.class("btn" <> kind_class <> size_class),
      event.on_click(on_press),
    ],
    [html.text(label)],
  )
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
pub fn cat_color(category: Int) -> String {
  let index = { int.modulo(category, 7) |> result.unwrap(0) } + 1
  "var(--cat-" <> int.to_string(index) <> ")"
}

/// The `var(--lvl-N)` seniority-ramp token for a level (1..7 lightest to deepest).
pub fn lvl_color(level: Int) -> String {
  "var(--lvl-" <> int.to_string(level) <> ")"
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
    html.div(
      [
        attribute.class("modal"),
        attribute.role("dialog"),
        attribute.aria_modal(True),
        attribute.aria_label(title),
        swallow_click(on_cancel),
      ],
      [
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
      ],
    ),
  ])
}

/// A modal that hosts arbitrary `body` content and owns NO footer — for flows (like
/// the onboarding wizard) that supply their own actions. The backdrop and a header
/// title are provided; clicking the backdrop raises `on_dismiss`.
pub fn dialog(
  title title: String,
  on_dismiss on_dismiss: msg,
  body body: Element(msg),
) -> Element(msg) {
  html.div([attribute.class("modal-backdrop"), event.on_click(on_dismiss)], [
    html.div(
      [
        attribute.class("modal modal--wide"),
        attribute.role("dialog"),
        attribute.aria_modal(True),
        attribute.aria_label(title),
        attribute.attribute("tabindex", "-1"),
        swallow_click(on_dismiss),
      ],
      [
        html.div([attribute.class("modal__header")], [html.text(title)]),
        html.div([attribute.class("modal__body")], [body]),
      ],
    ),
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
