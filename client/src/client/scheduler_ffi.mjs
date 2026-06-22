// Schedule `callback` to run after `delayMs` milliseconds. The Gleam `callback` is
// a nullary function; setTimeout invokes it with no arguments.
export function schedule(delayMs, callback) {
  setTimeout(callback, delayMs);
}
