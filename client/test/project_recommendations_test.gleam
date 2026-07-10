import client/page/projects/update
import client/ui/ops
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar
import shared/project_capability/view.{
  type Recommendation, Pairing, Recommendation,
}

fn as_of() -> calendar.Date {
  calendar.Date(2026, calendar.June, 15)
}

fn blank_form() -> ops.OpForm {
  ops.blank_op_form(ops.OpAssignToProject, as_of())
}

fn recommendation(free: Float) -> Recommendation {
  Recommendation(
    engineer_id: 42,
    name: "Marcus Chen",
    level: 4,
    proficiency: 2.8,
    free:,
    rationale: "Closest ready-now fit: Payments rollup 2.8.",
    pairing: None,
  )
}

pub fn recommendation_op_form_prefills_engineer_date_and_fraction_test() {
  let form =
    update.recommendation_op_form(blank_form(), as_of(), recommendation(0.4))
  assert form.engineer_id == "42"
  assert form.valid_from == "2026-06-15"
  assert form.fraction == "0.4"
}

pub fn recommendation_op_form_blanks_the_fraction_when_free_is_zero_test() {
  let form =
    update.recommendation_op_form(blank_form(), as_of(), recommendation(0.0))
  assert form.fraction == ""
}

pub fn recommendation_op_form_formats_a_whole_free_capacity_without_a_decimal_test() {
  let form =
    update.recommendation_op_form(blank_form(), as_of(), recommendation(1.0))
  assert form.fraction == "1"
}

fn ready_now_recommendation(name: String) -> Recommendation {
  Recommendation(
    engineer_id: 1,
    name:,
    level: 4,
    proficiency: 3.0,
    free: 0.4,
    rationale: "covers the gap; 40% available",
    pairing: None,
  )
}

fn growth_recommendation(name: String) -> Recommendation {
  Recommendation(
    engineer_id: 2,
    name:,
    level: 2,
    proficiency: 0.5,
    free: 0.5,
    rationale: "growth: learns the skill under a teacher; 50% available",
    pairing: Some(Pairing(
      teacher_id: 99,
      teacher_name: "Priya Sharma",
      skill_name: "Payment Gateways",
    )),
  )
}

pub fn ranked_recommendations_shows_only_the_top_four_ready_now_candidates_test() {
  let ready_now_names = [
    "Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor", "Amara Nwosu",
  ]
  let recommendations = list.map(ready_now_names, ready_now_recommendation)

  let displayed = update.ranked_recommendations(recommendations)

  assert list.map(displayed, fn(recommendation) { recommendation.name })
    == ["Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor"]
}

pub fn ranked_recommendations_shows_every_growth_candidate_past_the_ready_now_cutoff_test() {
  let ready_now_names = [
    "Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor", "Amara Nwosu",
  ]
  let growth_names = ["Rohan Sharma", "Dmitri Volkov"]
  let recommendations =
    list.append(
      list.map(ready_now_names, ready_now_recommendation),
      list.map(growth_names, growth_recommendation),
    )

  let displayed = update.ranked_recommendations(recommendations)

  assert list.map(displayed, fn(recommendation) { recommendation.name })
    == [
      "Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor", "Rohan Sharma",
      "Dmitri Volkov",
    ]
}

pub fn ranked_recommendations_numbers_ranks_continuously_across_the_ready_now_growth_boundary_test() {
  let ready_now_names = [
    "Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor", "Amara Nwosu",
  ]
  let growth_names = ["Rohan Sharma", "Dmitri Volkov"]
  let recommendations =
    list.append(
      list.map(ready_now_names, ready_now_recommendation),
      list.map(growth_names, growth_recommendation),
    )

  let displayed = update.ranked_recommendations(recommendations)

  assert list.index_map(displayed, fn(recommendation, index) {
      #(index + 1, recommendation.name)
    })
    == [
      #(1, "Omar Haddad"),
      #(2, "Mei Lin"),
      #(3, "Sofia Rossi"),
      #(4, "Tunde Okafor"),
      #(5, "Rohan Sharma"),
      #(6, "Dmitri Volkov"),
    ]
}
