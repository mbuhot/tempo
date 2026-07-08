//// FFI over the browser's own clock, backing the Meetings page's viewer-local
//// time toggle (#57): the UTC offset (minutes EAST of UTC, matching the
//// server's `offset_minutes` convention) the browser applies AT a given
//// instant — so DST is honoured per meeting rather than pinned to the
//// browser's current offset — and the browser's own IANA zone name for
//// display.

@external(javascript, "./browser_time_ffi.mjs", "timezone_offset_minutes")
pub fn timezone_offset_minutes(_iso: String) -> Int {
  panic as "JavaScript only"
}

@external(javascript, "./browser_time_ffi.mjs", "browser_timezone")
pub fn browser_timezone() -> String {
  panic as "JavaScript only"
}
