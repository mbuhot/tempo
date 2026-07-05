//// The enumerated set of invoice statuses, for exhaustive dispatch on status.

/// Every supported invoice status, in lifecycle order.
pub type InvoiceStatus {
  Draft
  Issued
  Paid
}

/// Render an `InvoiceStatus` to its wire/DB string.
pub fn to_string(status: InvoiceStatus) -> String {
  case status {
    Draft -> "draft"
    Issued -> "issued"
    Paid -> "paid"
  }
}

/// Parse a wire/DB string into an `InvoiceStatus`, or `Error(Nil)` if unrecognised.
pub fn from_string(text: String) -> Result(InvoiceStatus, Nil) {
  case text {
    "draft" -> Ok(Draft)
    "issued" -> Ok(Issued)
    "paid" -> Ok(Paid)
    _ -> Error(Nil)
  }
}
