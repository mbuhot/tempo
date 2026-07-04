import client/time

pub fn utc_offset_renders_a_positive_offset_test() {
  assert time.utc_offset(600) == "UTC+10:00"
}

pub fn utc_offset_renders_a_negative_offset_test() {
  assert time.utc_offset(-420) == "UTC-07:00"
}

pub fn utc_offset_renders_zero_test() {
  assert time.utc_offset(0) == "UTC+00:00"
}

pub fn utc_offset_renders_a_half_hour_offset_test() {
  assert time.utc_offset(330) == "UTC+05:30"
}
