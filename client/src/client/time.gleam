//// The one global as-of (ADR-036): the time rail and all the date arithmetic the
//// app needs to map the rail's integer slider position to a fixed absolute
//// calendar date.
////
//// This module is stateless — the selected date lives in the shell model. `view`
//// renders the rail for a given date and emits a message when the presenter scrubs
//// the slider (`AsOfScrubbed` — fired on every drag tick so the readout tracks the
//// thumb instantly; the shell debounces the refetch), or steps a day, picks a date,
//// or presses Today (`AsOfChanged` — a discrete change the shell applies at once).
//// The shell maps these into its own messages via `element.map` (Gleam has no
//// constructor re-export, so the shell owns distinct constructors). The slider
//// position is a unix-day index between fixed seed-range endpoints, so every
//// position is a deterministic absolute date independent of the wall clock, and
//// Today resets to the seed "now" rather than the real clock.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

/// The fixed seed "now" the app first renders as of (003_seed.sql). The rail
/// starts here so the served page is deterministic and never depends on the wall
/// clock; scrubbing moves it across the whole seed range. Today resets here.
pub const seed_now = calendar.Date(year: 2026, month: calendar.June, day: 15)

/// Inclusive rail bounds, as FIXED absolute seed-range endpoints (003_seed.sql:
/// every fact lives within daterange('2024-01-01','2027-01-01')). The slider's
/// integer value is a unix-day index between these two days; the open upper bound
/// 2027-01-01 is exclusive, so the last selectable day is 2026-12-31.
pub const range_start = calendar.Date(
  year: 2024,
  month: calendar.January,
  day: 1,
)

pub const range_end = calendar.Date(
  year: 2026,
  month: calendar.December,
  day: 31,
)

/// Messages the rail emits, mapped into the shell's own constructors via
/// `element.map(time.view(as_of), ...)` (these are NOT re-exported).
pub type Msg {
  /// A discrete change — a day step, a date pick, or Today. The shell applies it
  /// at once (instant refetch + URL sync).
  AsOfChanged(date: calendar.Date)
  /// A slider drag tick, fired on EVERY `input`. The shell updates the as-of (so
  /// the readout tracks the thumb) immediately, but debounces the refetch + URL
  /// sync to a settle once the drag stops.
  AsOfScrubbed(date: calendar.Date)
}

/// Render the time rail for `as_of`: the as-of readout (label, dot, date, and a
/// relative "in N days"/"N days ago"), the scrubber (year/half-year ticks, the
/// background rail, the fill up to the current position, and the range slider),
/// and the controls (step back/forward a day, a date picker, and Today). Mirrors
/// the prototype's `.time-rail` markup and classes verbatim.
pub fn view(as_of: calendar.Date) -> Element(Msg) {
  let day_index = date_to_day_index(as_of)
  html.div([attribute.class("time-rail")], [
    html.div([attribute.class("time-rail__asof")], [
      html.div([attribute.class("time-rail__asof-label")], [
        html.span([attribute.class("time-rail__dot")], []),
        html.span([attribute.class("eyebrow")], [html.text("Viewing as of")]),
      ]),
      html.div([attribute.class("time-rail__date mono")], [
        html.text(format_date(as_of)),
      ]),
      html.div([attribute.class("time-rail__rel")], [
        html.text(relative_to_today(as_of)),
      ]),
    ]),
    html.div([attribute.class("time-rail__scrub")], [
      html.div([attribute.class("time-rail__ticks")], view_ticks()),
      html.div([attribute.class("time-rail__track")], [
        html.div([attribute.class("time-rail__rail-bg")], []),
        html.div(
          [
            attribute.class("time-rail__rail-fill"),
            attribute.style("width", fill_pct(day_index)),
          ],
          [],
        ),
        html.input([
          attribute.type_("range"),
          attribute.min(int.to_string(date_to_day_index(range_start))),
          attribute.max(int.to_string(date_to_day_index(range_end))),
          attribute.value(int.to_string(day_index)),
          attribute.attribute("aria-label", "As-of date"),
          event.on_input(on_slider_scrub),
        ]),
      ]),
    ]),
    html.div([attribute.class("time-rail__controls")], [
      html.button(
        [
          attribute.class("time-rail__step"),
          attribute.attribute("aria-label", "Previous day"),
          event.on_click(AsOfChanged(step_day(as_of, -1))),
        ],
        [html.text("‹")],
      ),
      html.input([
        attribute.type_("date"),
        attribute.min(iso_date(range_start)),
        attribute.max(iso_date(range_end)),
        attribute.value(iso_date(as_of)),
        event.on_change(on_date_input),
      ]),
      html.button(
        [
          attribute.class("time-rail__step"),
          attribute.attribute("aria-label", "Next day"),
          event.on_click(AsOfChanged(step_day(as_of, 1))),
        ],
        [html.text("›")],
      ),
      html.button(
        [
          attribute.class("time-rail__today"),
          event.on_click(AsOfChanged(seed_now)),
        ],
        [html.text("Today")],
      ),
    ]),
  ])
}

/// The year/half-year ticks across the rail: a "YYYY" label at each Jan 1 and a
/// "Jul" label at each Jul 1 within bounds, positioned by their fraction of the
/// rail. Mirrors the prototype's `buildTicks`.
fn view_ticks() -> List(Element(Msg)) {
  list.flat_map([2024, 2025, 2026], fn(year) {
    [
      #(
        calendar.Date(year:, month: calendar.January, day: 1),
        int.to_string(year),
      ),
      #(calendar.Date(year:, month: calendar.July, day: 1), "Jul"),
    ]
    |> list.filter(fn(entry) {
      let index = date_to_day_index(entry.0)
      index >= date_to_day_index(range_start)
      && index <= date_to_day_index(range_end)
    })
    |> list.map(fn(entry) {
      html.div(
        [
          attribute.class("time-rail__tick"),
          attribute.style("left", float.to_string(range_pct(entry.0)) <> "%"),
        ],
        [html.text(entry.1)],
      )
    })
  })
}

/// A date's position along the rail as a percentage of the [range_start,
/// range_end] span — NOT of the absolute unix-day index, which is epoch-relative
/// and would bunch every position near the right. Matches the native slider's own
/// (value − min) / (max − min) placement so ticks and fill line up with the thumb.
fn range_pct(date: calendar.Date) -> Float {
  let start = date_to_day_index(range_start)
  let span = date_to_day_index(range_end) - start
  int.to_float(date_to_day_index(date) - start) /. int.to_float(span) *. 100.0
}

/// The rail-fill width as a percentage of the rail span.
fn fill_pct(day_index: Int) -> String {
  float.to_string(range_pct(day_index_to_date(day_index))) <> "%"
}

/// Parse the range input's string value into an `AsOfScrubbed`, clamping to the
/// rail bounds and holding the seed "now" if the value is somehow not an integer
/// (range inputs never emit one).
fn on_slider_scrub(raw_value: String) -> Msg {
  case int.parse(raw_value) {
    Ok(day_index) -> AsOfScrubbed(clamp_date(day_index_to_date(day_index)))
    Error(Nil) -> AsOfScrubbed(seed_now)
  }
}

/// Parse the date picker's ISO-8601 value into an `AsOfChanged`, clamping to the
/// rail bounds; an unparseable value holds the seed "now".
fn on_date_input(raw_value: String) -> Msg {
  case parse_iso_date(raw_value) {
    Ok(date) -> AsOfChanged(clamp_date(date))
    Error(Nil) -> AsOfChanged(seed_now)
  }
}

/// The date `delta` days from `date`, clamped to the rail bounds.
fn step_day(date: calendar.Date, delta: Int) -> calendar.Date {
  clamp_date(day_index_to_date(date_to_day_index(date) + delta))
}

// --- Date arithmetic --------------------------------------------------------
// The slider value is a unix-day index; converting to/from a calendar date keeps
// every position a fixed absolute seed-range date, independent of the wall clock.

/// Days are 86_400 seconds; the index times this is the unix timestamp of midnight.
const seconds_per_day = 86_400

/// The unix-day index of a calendar date (days since the unix epoch at UTC
/// midnight).
pub fn date_to_day_index(date: calendar.Date) -> Int {
  let instant = timestamp.from_calendar(date, midnight(), calendar.utc_offset)
  float.round(timestamp.to_unix_seconds(instant)) / seconds_per_day
}

/// The calendar date at a unix-day index.
pub fn day_index_to_date(day_index: Int) -> calendar.Date {
  let instant = timestamp.from_unix_seconds(day_index * seconds_per_day)
  let #(date, _time) = timestamp.to_calendar(instant, calendar.utc_offset)
  date
}

fn midnight() -> calendar.TimeOfDay {
  calendar.TimeOfDay(hours: 0, minutes: 0, seconds: 0, nanoseconds: 0)
}

/// The Monday of the week containing `date`, as a calendar date. Working in day
/// indices (unix-day 0 is a Thursday = ISO weekday 4), the Monday-of-week index
/// for a day index `d` is `d - modulo(d + 3, 7)`.
pub fn week_start_of(date: calendar.Date) -> calendar.Date {
  let day_index = date_to_day_index(date)
  let weekday = int.modulo(day_index + 3, 7) |> result.unwrap(0)
  day_index_to_date(day_index - weekday)
}

/// The first day of the calendar month containing `date`.
pub fn first_of_month(date: calendar.Date) -> calendar.Date {
  calendar.Date(year: date.year, month: date.month, day: 1)
}

/// The first day of the month AFTER the one containing `date` (the exclusive
/// upper bound of the month window); December rolls over to the next January.
pub fn first_of_next_month(date: calendar.Date) -> calendar.Date {
  case calendar.month_to_int(date.month) {
    12 -> calendar.Date(year: date.year + 1, month: calendar.January, day: 1)
    month ->
      case calendar.month_from_int(month + 1) {
        Ok(next) -> calendar.Date(year: date.year, month: next, day: 1)
        Error(Nil) ->
          calendar.Date(year: date.year, month: calendar.January, day: 1)
      }
  }
}

/// Clamp a `Date` to the rail's inclusive bounds via its day index, so a URL date
/// outside the seed range still lands on a valid rail position.
pub fn clamp_date(date: calendar.Date) -> calendar.Date {
  let low = date_to_day_index(range_start)
  let high = date_to_day_index(range_end)
  day_index_to_date(int.clamp(date_to_day_index(date), min: low, max: high))
}

/// Render a `Date` as ISO-8601 "YYYY-MM-DD".
pub fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `Date`.
pub fn parse_iso_date(text: String) -> Result(calendar.Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      Ok(calendar.Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

// --- Date display -----------------------------------------------------------

/// Render a date as "15 Jun 2026" for the as-of readout (the prototype's
/// `fmtDate`).
fn format_date(date: calendar.Date) -> String {
  int.to_string(date.day)
  <> " "
  <> month_abbrev(date.month)
  <> " "
  <> int.to_string(date.year)
}

/// The relative phrase from the seed "today" to `date`: "today", "N days ago",
/// or "in N days" (the prototype's `relDays`, anchored to the deterministic seed
/// now rather than the wall clock).
fn relative_to_today(date: calendar.Date) -> String {
  case date_to_day_index(date) - date_to_day_index(seed_now) {
    0 -> "today"
    diff if diff < 0 -> int.to_string(-diff) <> day_word(-diff) <> " ago"
    diff -> "in " <> int.to_string(diff) <> day_word(diff)
  }
}

fn day_word(count: Int) -> String {
  case count {
    1 -> " day"
    _ -> " days"
  }
}

fn month_abbrev(month: calendar.Month) -> String {
  case month {
    calendar.January -> "Jan"
    calendar.February -> "Feb"
    calendar.March -> "Mar"
    calendar.April -> "Apr"
    calendar.May -> "May"
    calendar.June -> "Jun"
    calendar.July -> "Jul"
    calendar.August -> "Aug"
    calendar.September -> "Sep"
    calendar.October -> "Oct"
    calendar.November -> "Nov"
    calendar.December -> "Dec"
  }
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
