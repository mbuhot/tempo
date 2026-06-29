//// The enumerated set of workflow kinds, for exhaustive dispatch on kind.

/// Every supported workflow kind.
pub type WorkflowKind {
  OnboardEngineer
  CreateProject
}

/// Render a `WorkflowKind` to its wire/DB string.
pub fn to_string(kind: WorkflowKind) -> String {
  case kind {
    OnboardEngineer -> "onboard_engineer"
    CreateProject -> "create_project"
  }
}

/// Parse a wire/DB string into a `WorkflowKind`, or `Error(Nil)` if unrecognised.
pub fn from_string(text: String) -> Result(WorkflowKind, Nil) {
  case text {
    "onboard_engineer" -> Ok(OnboardEngineer)
    "create_project" -> Ok(CreateProject)
    _ -> Error(Nil)
  }
}
