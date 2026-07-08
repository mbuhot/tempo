import gleam/json
import gleam/option.{None, Some}
import shared/meeting/command.{Optional, Required}
import shared/meeting/view

pub fn candidate_slot_codec_round_trip_test() {
  let slot =
    view.CandidateSlot(
      starts_at: "2026-06-15T23:00:00Z",
      ends_at: "2026-06-16T00:00:00Z",
      attendees: [
        view.SlotAttendee(
          engineer_id: 1,
          name: "Priya Sharma",
          attendance: Required,
          timezone: Some("Australia/Sydney"),
          offset_minutes: Some(600),
        ),
        view.SlotAttendee(
          engineer_id: 3,
          name: "Aisha Okafor",
          attendance: Optional,
          timezone: None,
          offset_minutes: None,
        ),
      ],
      viewer_offset_minutes: 60,
    )
  let round_tripped =
    view.encode_candidate_slot(slot)
    |> json.to_string
    |> json.parse(view.candidate_slot_decoder())
  assert round_tripped == Ok(slot)
}
