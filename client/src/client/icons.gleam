//// Inline SVG icons (from Lucide, MIT-licensed — https://lucide.dev). Each returns
//// an `Element` whose `stroke` is `currentColor`, so it inherits the colour of its
//// surrounding text, and whose size is `100%`, so its container decides the box.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg

fn icon(children: List(Element(msg))) -> Element(msg) {
  svg.svg(
    [
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("width", "100%"),
      attribute.attribute("height", "100%"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.attribute("aria-hidden", "true"),
    ],
    children,
  )
}

fn path(d: String) -> Element(msg) {
  svg.path([attribute.attribute("d", d)])
}

fn rect(
  x: String,
  y: String,
  width: String,
  height: String,
  rx: String,
) -> Element(msg) {
  svg.rect([
    attribute.attribute("x", x),
    attribute.attribute("y", y),
    attribute.attribute("width", width),
    attribute.attribute("height", height),
    attribute.attribute("rx", rx),
  ])
}

fn circle(cx: String, cy: String, r: String) -> Element(msg) {
  svg.circle([
    attribute.attribute("cx", cx),
    attribute.attribute("cy", cy),
    attribute.attribute("r", r),
  ])
}

/// `layout-dashboard`
pub fn board() -> Element(msg) {
  icon([
    rect("3", "3", "7", "9", "1"),
    rect("14", "3", "7", "5", "1"),
    rect("14", "12", "7", "9", "1"),
    rect("3", "16", "7", "5", "1"),
  ])
}

/// `users`
pub fn people() -> Element(msg) {
  icon([
    path("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"),
    circle("9", "7", "4"),
    path("M22 21v-2a4 4 0 0 0-3-3.87"),
    path("M16 3.13a4 4 0 0 1 0 7.75"),
  ])
}

/// `building-2`
pub fn clients() -> Element(msg) {
  icon([
    path("M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"),
    path("M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"),
    path("M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"),
    path("M10 6h4"),
    path("M10 10h4"),
    path("M10 14h4"),
    path("M10 18h4"),
  ])
}

/// `folder-kanban`
pub fn projects() -> Element(msg) {
  icon([
    path(
      "M4 20a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2Z",
    ),
    path("M8 10v4"),
    path("M12 10v2"),
    path("M16 10v6"),
  ])
}

/// `banknote`
pub fn finance() -> Element(msg) {
  icon([
    rect("2", "6", "20", "12", "2"),
    circle("12", "12", "2"),
    path("M6 12h.01"),
    path("M18 12h.01"),
  ])
}

/// `activity`
pub fn activity() -> Element(msg) {
  icon([path("M22 12h-4l-3 9L9 3l-3 9H2")])
}

/// `settings`
pub fn settings() -> Element(msg) {
  icon([
    path(
      "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2Z",
    ),
    circle("12", "12", "3"),
  ])
}

/// `shield`
pub fn access() -> Element(msg) {
  icon([
    path(
      "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z",
    ),
  ])
}
