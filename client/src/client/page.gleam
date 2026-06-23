//// The frozen cross-page interface contract. Every page in `client/page/*`
//// implements the same shape — `Model`/`Msg`/`init`/`update`/`view`/`refetch` —
//// and raises the SAME `OutMsg` for its two cross-cutting concerns, so the shell
//// (`client/app`) routes them through one mapper instead of one per page.
////
//// `OutMsg` was seven identical copies (one per page); collapsing them here keeps
//// the shell's coupling to pages a single shared type without changing what a page
//// raises or how the shell folds it.

import client/route

/// A page's two cross-cutting outputs, the only coupling between a page and the
/// shell. `Navigate` asks the shell to `push` a route URL (the shell owns the
/// modem call, carrying the current as-of); `OperationCommitted` signals a write
/// landed — a global no-op today (pages re-init on navigation, so a committed
/// write is re-read on the next visit), reserved for a future Activity badge or
/// cross-page cache invalidation (see ARCHITECTURE / issue #10).
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}
