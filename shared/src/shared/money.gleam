//// Exact decimal currency, replacing money-as-`Float` across the wire, the shared
//// read models, and Gleam-side arithmetic. Backed by `bigdecimal` (pure Gleam, so
//// it compiles for both the Erlang server and the JavaScript client) held at a
//// fixed scale of 2 (cents). `add`/`subtract`/`sum` are exact; `scale_by` and
//// `ratio` (the rate-times-fraction estimate and the margin percentage) rescale to
//// the cent with banker's rounding. Money never round-trips through `Float` for
//// storage, transport, or arithmetic — `to_float` exists only for display
//// formatting and ratio display, never to re-enter money math.

import bigdecimal.{type BigDecimal}
import bigdecimal/rounding
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/json.{type Json}
import gleam/list
import gleam/order.{type Order, Eq}
import gleam/result
import gleam/string

const cents_scale = 2

/// A currency amount, exact to the cent.
pub opaque type Money {
  Money(amount: BigDecimal)
}

fn quantize(amount: BigDecimal) -> Money {
  Money(bigdecimal.rescale(amount, cents_scale, rounding.HalfEven))
}

/// Zero dollars.
pub fn zero() -> Money {
  quantize(bigdecimal.zero())
}

/// Parse a decimal string (e.g. `"1234.50"`, `"1234.5"`, `"1234"`) into `Money`,
/// rescaled to the cent. Used by the wire decoder and by SQL `numeric::text` rows.
pub fn from_string(text: String) -> Result(Money, Nil) {
  bigdecimal.from_string(text)
  |> result.map(quantize)
}

/// Parse a trusted, server-generated SQL `numeric::text` column into `Money`;
/// a parse failure is a violated invariant and crashes.
pub fn trusted_from_string(text: String) -> Money {
  let assert Ok(amount) = from_string(text)
  amount
}

/// Render `Money` as a plain decimal string at the cent scale (`"1234.50"`).
pub fn to_string(money: Money) -> String {
  bigdecimal.to_plain_string(money.amount)
}

/// The amount as a `Float`, for display formatting and ratio display ONLY — never
/// to re-enter money arithmetic.
pub fn to_float(money: Money) -> Float {
  let assert Ok(value) = float.parse(ensure_decimal_point(to_string(money)))
  value
}

fn ensure_decimal_point(text: String) -> String {
  case string.contains(text, ".") {
    True -> text
    False -> text <> ".0"
  }
}

/// Exact sum of two amounts.
pub fn add(a: Money, b: Money) -> Money {
  Money(bigdecimal.add(a.amount, b.amount))
}

/// Exact difference `a - b`.
pub fn subtract(a: Money, b: Money) -> Money {
  Money(bigdecimal.subtract(a.amount, b.amount))
}

/// Exact sum of a list of amounts (`zero` when empty).
pub fn sum(amounts: List(Money)) -> Money {
  quantize(bigdecimal.sum(list.map(amounts, fn(money) { money.amount })))
}

/// Negate an amount.
pub fn negate(money: Money) -> Money {
  Money(bigdecimal.negate(money.amount))
}

/// Absolute value of an amount.
pub fn absolute_value(money: Money) -> Money {
  Money(bigdecimal.absolute_value(money.amount))
}

/// Compare two amounts.
pub fn compare(a: Money, b: Money) -> Order {
  bigdecimal.compare(a.amount, b.amount)
}

/// Multiply an amount by a dimensionless ratio (an allocation `fraction`), rounding
/// the result to the cent. For display estimates such as a team member's daily cost.
pub fn scale_by(money: Money, ratio: Float) -> Money {
  quantize(bigdecimal.multiply(money.amount, bigdecimal.from_float(ratio)))
}

/// The ratio `numerator / denominator` as a `Float` (for a margin percentage),
/// `0.0` when the denominator is zero.
pub fn ratio(numerator: Money, denominator: Money) -> Float {
  case bigdecimal.compare(denominator.amount, bigdecimal.zero()) {
    Eq -> 0.0
    _ -> to_float(numerator) /. to_float(denominator)
  }
}

/// Encode as a JSON decimal string.
pub fn encode(money: Money) -> Json {
  json.string(to_string(money))
}

/// Decode a JSON decimal string into `Money`.
pub fn decoder() -> Decoder(Money) {
  use text <- decode.then(decode.string)
  case from_string(text) {
    Ok(money) -> decode.success(money)
    Error(Nil) -> decode.failure(zero(), "Money")
  }
}
