import gleam/json
import gleam/option.{None, Some}
import shared/project_capability/view.{
  GapRecommendations, Pairing, Recommendation,
}

pub fn gap_recommendations_codec_round_trip_test() {
  let gap =
    GapRecommendations(
      capability_id: 1,
      capability_name: "Payments Platform",
      target_level: 3,
      quantity: 2.0,
      covered: 1,
      recommendations: [
        Recommendation(
          engineer_id: 4,
          name: "Omar Haddad",
          level: 4,
          proficiency: 3.0,
          free: 0.4,
          rationale: "covers the Payments Platform gap at 3.0; 40% available",
          pairing: None,
        ),
        Recommendation(
          engineer_id: 8,
          name: "Rohan Sharma",
          level: 2,
          proficiency: 0.8888888888888888,
          free: 0.5,
          rationale: "growth: learns Payment Gateways under Priya Sharma; 50% available",
          pairing: Some(Pairing(
            teacher_id: 1,
            teacher_name: "Priya Sharma",
            skill_name: "Payment Gateways",
          )),
        ),
      ],
    )
  let round_tripped =
    view.encode_gap_recommendations(gap)
    |> json.to_string
    |> json.parse(view.gap_recommendations_decoder())
  assert round_tripped == Ok(gap)
}
