//// Unit tests for the table query builder's filter extraction. `number_range_of`
//// reads the raw-string bounds a user typed and parses them to floats at the SQL
//// boundary, accepting both integer and decimal strings and dropping anything that
//// is empty or unparseable.

import gleam/dict
import gleam/option.{None, Some}
import shared/table/query.{NumberRange}
import tempo/server/table/builder

pub fn number_range_of_parses_integer_string_test() {
  let filters = dict.from_list([#("total", NumberRange(Some("5"), None))])
  assert builder.number_range_of(filters, "total") == #(Some(5.0), None)
}

pub fn number_range_of_parses_decimal_string_test() {
  let filters = dict.from_list([#("total", NumberRange(None, Some("5.5")))])
  assert builder.number_range_of(filters, "total") == #(None, Some(5.5))
}

pub fn number_range_of_parses_both_bounds_test() {
  let filters =
    dict.from_list([#("total", NumberRange(Some("10"), Some("99.25")))])
  assert builder.number_range_of(filters, "total") == #(Some(10.0), Some(99.25))
}

pub fn number_range_of_drops_empty_and_garbage_test() {
  let filters = dict.from_list([#("total", NumberRange(Some(""), Some("abc")))])
  assert builder.number_range_of(filters, "total") == #(None, None)
}

pub fn number_range_of_absent_filter_test() {
  assert builder.number_range_of(dict.new(), "total") == #(None, None)
}
