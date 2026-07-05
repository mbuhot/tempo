import client/page/meetings

pub fn local_time_applies_a_positive_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", 60) == "10:00"
}

pub fn local_time_applies_a_negative_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", -420) == "02:00"
}
