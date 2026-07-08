// The browser's own clock, for the Meetings page's viewer-local time toggle
// (#57). `timezone_offset_minutes` reads the offset the browser would apply
// AT `iso` (not its current offset), so a DST transition between the meeting
// and today is honoured; `Date#getTimezoneOffset` is minutes WEST of UTC, so
// it is negated to match the app's minutes-EAST convention.
export function timezone_offset_minutes(iso) {
  return -new Date(iso).getTimezoneOffset();
}

export function browser_timezone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}
