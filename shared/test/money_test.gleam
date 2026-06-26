//// Unit tests for the exact-decimal `Money` type (issue #21). Money replaces
//// money-as-`Float`; the load-bearing property is that amounts reconcile to the
//// cent across paths where binary floating point would drift.

import gleam/json
import gleam/order.{Eq, Gt, Lt}
import shared/money

fn money_of(text: String) -> money.Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

pub fn parse_and_format_round_trips_at_cent_scale_test() {
  assert money.to_string(money_of("1234.50")) == "1234.50"
}

pub fn from_string_pads_to_two_places_test() {
  assert money.to_string(money_of("1234")) == "1234.00"
  assert money.to_string(money_of("1234.5")) == "1234.50"
}

pub fn from_string_rejects_non_numeric_test() {
  assert money.from_string("not money") == Error(Nil)
}

pub fn add_is_exact_where_float_drifts_test() {
  assert money.to_string(money.add(money_of("0.10"), money_of("0.20")))
    == "0.30"
}

pub fn subtract_is_exact_test() {
  assert money.to_string(money.subtract(money_of("120000.00"), money_of("32000.00")))
    == "88000.00"
}

pub fn sum_reconciles_to_the_cent_test() {
  let lines = [money_of("36000.00"), money_of("30000.00"), money_of("54000.00")]
  assert money.to_string(money.sum(lines)) == "120000.00"
}

pub fn sum_of_empty_is_zero_test() {
  assert money.to_string(money.sum([])) == "0.00"
  assert money.to_string(money.zero()) == "0.00"
}

pub fn scale_by_fraction_rounds_to_the_cent_test() {
  assert money.to_string(money.scale_by(money_of("1000.00"), 0.5)) == "500.00"
}

pub fn ratio_yields_a_margin_fraction_test() {
  assert money.ratio(money_of("30.00"), money_of("120.00")) == 0.25
}

pub fn ratio_by_zero_is_zero_test() {
  assert money.ratio(money_of("30.00"), money.zero()) == 0.0
}

pub fn negate_and_absolute_value_test() {
  assert money.to_string(money.negate(money_of("12.34"))) == "-12.34"
  assert money.to_string(money.absolute_value(money_of("-12.34"))) == "12.34"
}

pub fn compare_orders_amounts_test() {
  assert money.compare(money_of("1.00"), money_of("2.00")) == Lt
  assert money.compare(money_of("2.00"), money_of("1.00")) == Gt
  assert money.compare(money_of("2.00"), money_of("2.00")) == Eq
}

pub fn json_round_trips_test() {
  let original = money_of("98765.43")
  let encoded = json.to_string(money.encode(original))
  assert json.parse(from: encoded, using: money.decoder()) == Ok(original)
}
