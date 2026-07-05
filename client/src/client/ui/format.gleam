//// Presentation formatters shared across pages: money, percentage, fraction,
//// and day-count rendering, plus the level -> seniority-band label.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import shared/level

/// Format a money amount as whole dollars with thousands separators ("$84,000"),
/// negatives prefixed with a minus ("-$32,000"). Seeded as round figures so no
/// cents are shown.
pub fn money(amount: Float) -> String {
  let rounded = float.round(amount)
  let sign = case rounded < 0 {
    True -> "-"
    False -> ""
  }
  sign <> "$" <> group_thousands(int.absolute_value(rounded))
}

/// Format a money amount compactly: "$84k"/"$7.6k" above a thousand, otherwise
/// the full `money` form. Mirrors the prototype's `fmtMoneyK`.
pub fn money_k(amount: Float) -> String {
  case amount >=. 1000.0 {
    False -> money(amount)
    True -> {
      let thousands = amount /. 1000.0
      let rendered = case amount >=. 10_000.0 {
        True -> int.to_string(float.round(thousands))
        False -> one_decimal(thousands)
      }
      "$" <> rendered <> "k"
    }
  }
}

/// Format a percentage as a whole number with a "%" suffix (54.3 -> "54%").
pub fn pct(value: Float) -> String {
  int.to_string(float.round(value)) <> "%"
}

/// Format an allocation fraction as a percentage (0.5 -> "50%").
pub fn fraction(value: Float) -> String {
  int.to_string(float.round(value *. 100.0)) <> "%"
}

/// Format a day/hour count: a whole number when integral ("30"), otherwise one
/// decimal place ("15.5").
pub fn days(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> one_decimal(value)
  }
}

/// The seniority band name for a level, the pure presentation label that replaces
/// the dropped `band` wire field. Levels 1..5 mirror the prototype's `LEVELS`;
/// 6/7 extend the ladder. Returned as "L<n> · <band>".
pub fn level_band(level: Int) -> String {
  level.band(level)
}

/// Group a non-negative integer's digits into thousands ("84000" -> "84,000").
fn group_thousands(value: Int) -> String {
  int.to_string(value)
  |> string.to_graphemes
  |> list.reverse
  |> list.sized_chunk(into: 3)
  |> list.map(fn(chunk) { chunk |> list.reverse |> string.concat })
  |> list.reverse
  |> string.join(",")
}

/// A float rounded to one decimal place ("7.55" -> "7.6").
fn one_decimal(value: Float) -> String {
  float.to_string(float.to_precision(value, 1))
}
