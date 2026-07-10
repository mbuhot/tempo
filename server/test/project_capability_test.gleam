//// Domain tests for the assignment-recommender read (#40 Phase 3 Stage 2):
//// `project_capability_view.recommendations`. Purely a read against the seeded
//// bench (server/priv/seed/base_seed.sql's engineers 4-11, added Stage 1)
//// against Ledger Migration (project 100)'s Payments Platform gap, so no
//// fixture rows are inserted and no `rolling_back` transaction is needed —
//// the same direct-read shape as `schedule_test.gleam`.

import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{Date}
import shared/project_capability/view.{
  GapRecommendations, Pairing, Recommendation,
}
import tempo/server/project_capability/view as project_capability_view
import test_pool

pub fn recommendations_ranks_ready_now_then_growth_against_the_seeded_gap_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      100,
      Date(2026, calendar.June, 15),
    )

  assert gaps
    == [
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
            engineer_id: 6,
            name: "Mei Lin",
            level: 5,
            proficiency: 3.6666666666666665,
            free: 0.0,
            rationale: "covers the Payments Platform gap at 3.7; 0% available",
            pairing: None,
          ),
          Recommendation(
            engineer_id: 5,
            name: "Sofia Rossi",
            level: 4,
            proficiency: 2.6666666666666665,
            free: 1.0,
            rationale: "covers the Payments Platform gap at 2.7; 100% available",
            pairing: None,
          ),
          Recommendation(
            engineer_id: 7,
            name: "Tunde Okafor",
            level: 3,
            proficiency: 2.0,
            free: 0.2,
            rationale: "covers the Payments Platform gap at 2.0; 20% available",
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
          Recommendation(
            engineer_id: 9,
            name: "Dmitri Volkov",
            level: 2,
            proficiency: 0.5555555555555556,
            free: 0.0,
            rationale: "growth: learns Ledger Accounting Systems under Priya Sharma; 0% available",
            pairing: Some(Pairing(
              teacher_id: 1,
              teacher_name: "Priya Sharma",
              skill_name: "Ledger Accounting Systems",
            )),
          ),
        ],
      ),
    ]
}

// Frontend Delivery is fully covered by Priya alone (proficiency 1.5 against a
// target of 1 x1.0) so it produces no gap at all — the seeded second
// requirement never shows up in the recommender output.
pub fn recommendations_omits_a_fully_covered_requirement_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      100,
      Date(2026, calendar.June, 15),
    )

  assert list.find(gaps, fn(gap) { gap.capability_id == 3 }) == Error(Nil)
}

// Mei's rollup (33/9) sits above the target_level of 3, so her capped fit
// ties Omar's at 1.0 and free breaks the tie (Omar's 0.4 over Mei's 0.0,
// asserted by the ordering above) — but the record itself always reports her
// RAW, uncapped proficiency; the cap affects only the ranking, never the
// displayed number.
pub fn recommendations_reports_raw_uncapped_proficiency_for_an_above_target_fit_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      100,
      Date(2026, calendar.June, 15),
    )
  let assert Ok(payments) = list.find(gaps, fn(gap) { gap.capability_id == 1 })
  let assert Ok(mei) =
    list.find(payments.recommendations, fn(rec) { rec.engineer_id == 6 })

  assert mei.proficiency == 3.6666666666666665
}

// Candidates omitted entirely from the seeded gap: Priya (on the project),
// Aisha (on leave on the as-of date), Marcus (below target with only a
// weight-1 learner skill, no qualifying pairing), Jonas (zero fit, no mapped
// skill at all), Hannah (below target with a level-4 API Design assessment —
// not a level-1/2 LEARNER skill, so no pairing).
pub fn recommendations_omits_candidates_with_no_fit_and_no_pairing_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      100,
      Date(2026, calendar.June, 15),
    )
  let assert Ok(payments) = list.find(gaps, fn(gap) { gap.capability_id == 1 })
  let engineer_ids =
    list.map(payments.recommendations, fn(rec) { rec.engineer_id })

  assert !list.contains(engineer_ids, 1)
  assert !list.contains(engineer_ids, 2)
  assert !list.contains(engineer_ids, 3)
  assert !list.contains(engineer_ids, 10)
  assert !list.contains(engineer_ids, 11)
}

// Six months later: Omar's project-200 allocation and Rohan's project-300
// allocation have both ended, freeing them fully; Aisha is back from leave and
// now enters as a growth row (her Payment Gateways level-1 skill paired with
// Priya, still 1.0-allocated to project 300 so still 0% free). Payments
// Platform stays covered by exactly Priya (covered: 1) since nothing about
// the project's own team changed.
pub fn recommendations_reflects_ended_allocations_and_returning_leave_six_months_later_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      100,
      Date(2026, calendar.December, 15),
    )
  let assert Ok(payments) = list.find(gaps, fn(gap) { gap.capability_id == 1 })

  assert payments.covered == 1

  let assert [first, ..] = payments.recommendations
  assert first.engineer_id == 4
  assert first.free == 1.0

  let assert Ok(rohan) =
    list.find(payments.recommendations, fn(rec) { rec.engineer_id == 8 })
  let assert Ok(dmitri) =
    list.find(payments.recommendations, fn(rec) { rec.engineer_id == 9 })
  assert rohan.free == 1.0
  assert dmitri.free == 0.0
  let assert Ok(rohan_index) =
    list.index_map(payments.recommendations, fn(rec, index) {
      #(rec.engineer_id, index)
    })
    |> list.find(fn(pair) { pair.0 == 8 })
  let assert Ok(dmitri_index) =
    list.index_map(payments.recommendations, fn(rec, index) {
      #(rec.engineer_id, index)
    })
    |> list.find(fn(pair) { pair.0 == 9 })
  assert rohan_index.1 < dmitri_index.1

  let assert Ok(aisha) =
    list.find(payments.recommendations, fn(rec) { rec.engineer_id == 3 })
  assert aisha.proficiency == 0.3333333333333333
  assert aisha.free == 0.0
  assert aisha.pairing
    == Some(Pairing(
      teacher_id: 1,
      teacher_name: "Priya Sharma",
      skill_name: "Payment Gateways",
    ))
  assert aisha.rationale
    == "growth: learns Payment Gateways under Priya Sharma; 0% available"
}

// Warehouse Automation (project 600, seeded with two SIMULTANEOUS unmet
// requirements) is the cross-capability contamination regression: Ines Duarte
// (engineer 13) has zero Data Engineering skill (proficiency 0, growth-
// eligible but no qualifying Data Engineering pairing) and a level-1 CI/CD
// skill that only qualifies her for a Platform Infrastructure pairing under
// Noah Fischer (engineer 12, level-4 CI/CD, on the Warehouse Automation
// team). A pairing lookup that isn't scoped to the requirement's own
// capability would leak Noah's CI/CD pairing into the Data Engineering gap.
pub fn growth_recommendations_never_leak_a_pairing_from_another_unmet_requirement_test() {
  let assert Ok(Ok(gaps)) =
    project_capability_view.recommendations(
      test_pool.ctx(),
      600,
      Date(2026, calendar.June, 15),
    )

  let assert Ok(data_engineering) =
    list.find(gaps, fn(gap) { gap.capability_id == 2 })
  let assert Ok(platform_infrastructure) =
    list.find(gaps, fn(gap) { gap.capability_id == 4 })

  assert list.find(data_engineering.recommendations, fn(rec) {
      rec.engineer_id == 13
    })
    == Error(Nil)

  let assert Ok(ines) =
    list.find(platform_infrastructure.recommendations, fn(rec) {
      rec.engineer_id == 13
    })
  assert ines.pairing
    == Some(Pairing(
      teacher_id: 12,
      teacher_name: "Noah Fischer",
      skill_name: "CI/CD",
    ))
}
