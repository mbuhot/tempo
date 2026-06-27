// localStorage access for per-user table layout preferences. A missing key (or any
// access failure, e.g. private-mode) reads back as the empty string, which the Gleam
// wrapper treats as "absent". Writes are best-effort and never throw.
export function read(key) {
  try {
    return window.localStorage.getItem(key) ?? "";
  } catch (_error) {
    return "";
  }
}

export function write(key, value) {
  try {
    window.localStorage.setItem(key, value);
  } catch (_error) {
    // ignore: a failed preference write must not break the app
  }
  return undefined;
}
