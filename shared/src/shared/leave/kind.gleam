//// The enumerated set of leave kinds, for exhaustive dispatch on kind.

/// Every supported leave kind, in display order.
pub type LeaveKind {
  Annual
  Sick
  Parental
  Unpaid
}

/// Every `LeaveKind`, in display order — the option list a `<select>` renders from.
pub fn all() -> List(LeaveKind) {
  [Annual, Sick, Parental, Unpaid]
}

/// Render a `LeaveKind` to its wire/DB string.
pub fn to_string(kind: LeaveKind) -> String {
  case kind {
    Annual -> "annual"
    Sick -> "sick"
    Parental -> "parental"
    Unpaid -> "unpaid"
  }
}

/// Parse a wire/DB string into a `LeaveKind`, or `Error(Nil)` if unrecognised.
pub fn from_string(text: String) -> Result(LeaveKind, Nil) {
  case text {
    "annual" -> Ok(Annual)
    "sick" -> Ok(Sick)
    "parental" -> Ok(Parental)
    "unpaid" -> Ok(Unpaid)
    _ -> Error(Nil)
  }
}
