import client/page/projects/update
import client/ui/ops
import gleam/option.{None}
import gleam/time/calendar
import shared/project_capability/view.{type Recommendation, Recommendation}

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
