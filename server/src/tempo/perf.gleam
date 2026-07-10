//// EXPLAIN ANALYZE perf gate (issue #20; `gleam run -m tempo/perf`, via
//// `bin/perf`). For a fixed set of hot as-of reads — every query behind the
//// board/detail/pnl fan-outs, plus the deferred single-query candidates —
//// runs `EXPLAIN (ANALYZE, FORMAT JSON) <query>` against pinned parameters
//// five times and keeps the MINIMUM execution time (steady-state,
//// cache-warm), the same idea `bin/test` uses for stable timing: throw away
//// the cold-cache runs.
////
//// Two modes:
////   * default — measure, compare each query's minimum against the committed
////     baseline (`priv/perf/baseline.json`), print a table, and exit non-zero
////     if any query's ratio exceeds `regression_threshold`.
////   * `--update-baseline` — measure and REWRITE the baseline file from the
////     current run, with no comparison (the machine-local starting point
////     after an intentional query change).
////
//// Every query's SQL is read straight from its source file under
//// `src/tempo/server/<concept>/sql/` at runtime (NOT a copy under priv/) —
//// the exact text the app runs at request time, so the plan measured here can
//// never drift from the query actually shipped.

import argv
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{Date, January, July, June}
import pog
import simplifile
import tempo/server/context.{type Context}

/// One hot read to measure: a display name, the path to its `.sql` source
/// (relative to the `server` package root), the parameters to pin (in `$1..`
/// order), and a human-readable rendering of those parameters for the table
/// and the baseline file.
pub type Measured {
  Measured(
    name: String,
    sql_path: String,
    params: List(pog.Value),
    params_display: String,
  )
}

/// One committed baseline row, matched to a `Measured` by `name`.
pub type BaselineEntry {
  BaselineEntry(name: String, params: String, baseline_ms: Float)
}

/// Everything that can stop a perf run.
pub type PerfError {
  SqlReadFailed(path: String, error: simplifile.FileError)
  QueryFailed(name: String, error: pog.QueryError)
  PlanJsonInvalid(name: String, error: json.DecodeError)
  PlanJsonEmpty(name: String)
  BaselineReadFailed(error: simplifile.FileError)
  BaselineInvalid(error: json.DecodeError)
}

/// Where the committed baseline lives, relative to the `server` package root
/// (matching where `bin/perf` runs `gleam run` from).
const baseline_path = "priv/perf/baseline.json"

/// A query is a regression once its measured minimum exceeds this multiple of
/// its baseline. Generous on purpose: the baseline is machine-local (a laptop
/// isn't a CI runner), and this absorbs everyday variance so the gate only
/// fires on a genuine order-of-magnitude change — like the missing-index
/// regression the planted-regression check demonstrates.
const regression_threshold = 3.0

/// How many times each query runs; the minimum of the five is kept.
const runs_per_query = 5

/// `gleam run -m tempo/perf` (via `bin/perf`). With no arguments, measure and
/// gate against the committed baseline (exit non-zero on any regression);
/// with `--update-baseline`, measure and rewrite the baseline file instead.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  case argv.load().arguments {
    ["--update-baseline"] -> update_baseline(ctx)
    [] -> gate(ctx)
    other ->
      panic as {
        "perf: unrecognised arguments "
        <> string.inspect(other)
        <> " (expected none, or --update-baseline)"
      }
  }
}

/// Measure every query and rewrite `priv/perf/baseline.json` from the result.
fn update_baseline(context: Context) -> Nil {
  case measure_all(context) {
    Ok(results) -> {
      let entries =
        list.map(results, fn(result) {
          let #(measured, ms) = result
          BaselineEntry(measured.name, measured.params_display, ms)
        })
      case write_baseline(entries) {
        Ok(_) ->
          io.println(
            "perf: baseline updated ("
            <> int.to_string(list.length(entries))
            <> " queries) -> "
            <> baseline_path,
          )
        Error(error) ->
          panic as {
            "perf: failed writing baseline: " <> string.inspect(error)
          }
      }
    }
    Error(error) ->
      panic as { "perf: measurement failed: " <> string.inspect(error) }
  }
}

/// Measure every query, compare against the committed baseline, print the
/// table, and exit non-zero if any query regressed past the threshold.
fn gate(context: Context) -> Nil {
  case measure_all(context) {
    Ok(results) ->
      case read_baseline() {
        Ok(baseline) -> {
          let rows = list.map(results, to_gate_row(_, baseline))
          print_table(rows)
          case list.any(rows, fn(row) { row.ratio >. regression_threshold }) {
            True -> halt(1)
            False -> halt(0)
          }
        }
        Error(error) ->
          panic as {
            "perf: failed reading baseline: " <> string.inspect(error)
          }
      }
    Error(error) ->
      panic as { "perf: measurement failed: " <> string.inspect(error) }
  }
}

/// One printed/gated row: a measured query alongside its baseline (when one
/// exists — a query added since the last `--update-baseline` prints as `n/a`
/// and never gates).
type GateRow {
  GateRow(name: String, baseline_ms: Float, measured_ms: Float, ratio: Float)
}

fn to_gate_row(
  result: #(Measured, Float),
  baseline: List(BaselineEntry),
) -> GateRow {
  let #(measured, measured_ms) = result
  case list.find(baseline, fn(entry) { entry.name == measured.name }) {
    Ok(entry) ->
      GateRow(
        measured.name,
        entry.baseline_ms,
        measured_ms,
        measured_ms /. entry.baseline_ms,
      )
    Error(Nil) -> GateRow(measured.name, 0.0, measured_ms, 0.0)
  }
}

fn print_table(rows: List(GateRow)) -> Nil {
  io.println(
    string.pad_end("query", 28, " ")
    <> string.pad_start("baseline_ms", 12, " ")
    <> string.pad_start("measured_ms", 12, " ")
    <> string.pad_start("ratio", 8, " "),
  )
  list.each(rows, fn(row) {
    let ratio_display = case row.baseline_ms {
      0.0 -> "n/a"
      _ -> float.to_string(float.to_precision(row.ratio, 2)) <> "x"
    }
    io.println(
      string.pad_end(row.name, 28, " ")
      <> string.pad_start(format_ms(row.baseline_ms), 12, " ")
      <> string.pad_start(format_ms(row.measured_ms), 12, " ")
      <> string.pad_start(ratio_display, 8, " "),
    )
  })
}

fn format_ms(ms: Float) -> String {
  float.to_string(float.to_precision(ms, 2))
}

/// Run every `Measured` query and pair it with its minimum execution time
/// (ms), in the same order `measured_queries` defines them.
fn measure_all(
  context: Context,
) -> Result(List(#(Measured, Float)), PerfError) {
  measured_queries()
  |> list.try_map(fn(measured) {
    use ms <- result.map(minimum_execution_ms(context, measured))
    #(measured, ms)
  })
}

/// Run one query's `EXPLAIN (ANALYZE, FORMAT JSON)` `runs_per_query` times
/// and keep the minimum reported "Execution Time" — steady-state, cache-warm,
/// immune to the first run paying for a cold buffer cache.
fn minimum_execution_ms(
  context: Context,
  measured: Measured,
) -> Result(Float, PerfError) {
  use sql_text <- result.try(
    simplifile.read(measured.sql_path)
    |> result.map_error(SqlReadFailed(measured.sql_path, _)),
  )
  let explain_sql = "EXPLAIN (ANALYZE, FORMAT JSON) " <> sql_text
  use times <- result.try(
    list.repeat(Nil, runs_per_query)
    |> list.try_map(fn(_) { run_explain(context, measured, explain_sql) }),
  )
  case list.reduce(times, float.min) {
    Ok(minimum) -> Ok(minimum)
    Error(Nil) -> Error(PlanJsonEmpty(measured.name))
  }
}

/// Execute one `EXPLAIN (ANALYZE, FORMAT JSON)` pass and return its
/// "Execution Time" in milliseconds.
fn run_explain(
  context: Context,
  measured: Measured,
  explain_sql: String,
) -> Result(Float, PerfError) {
  let query =
    list.fold(measured.params, pog.query(explain_sql), fn(query, param) {
      pog.parameter(query, param)
    })
  use returned <- result.try(
    query
    |> pog.returning(single_text_column_decoder())
    |> pog.execute(on: context.db)
    |> result.map_error(QueryFailed(measured.name, _)),
  )
  use plan_json <- result.try(case returned.rows {
    [row] -> Ok(row)
    _ -> Error(PlanJsonEmpty(measured.name))
  })
  use execution_times <- result.try(
    json.parse(plan_json, execution_times_decoder())
    |> result.map_error(PlanJsonInvalid(measured.name, _)),
  )
  case execution_times {
    [time] -> Ok(time)
    _ -> Error(PlanJsonEmpty(measured.name))
  }
}

fn single_text_column_decoder() -> decode.Decoder(String) {
  use text <- decode.field(0, decode.string)
  decode.success(text)
}

/// `EXPLAIN (FORMAT JSON)` always returns exactly one row: a JSON array
/// holding one plan object. Decode just the `"Execution Time"` field of that
/// one object — the plan tree itself is inspected by hand (`psql`) when
/// evidence for the findings doc is needed, not parsed here.
fn execution_times_decoder() -> decode.Decoder(List(Float)) {
  decode.list(of: {
    use execution_time <- decode.field("Execution Time", decode.float)
    decode.success(execution_time)
  })
}

fn baseline_entry_decoder() -> decode.Decoder(BaselineEntry) {
  use name <- decode.field("name", decode.string)
  use params <- decode.field("params", decode.string)
  use baseline_ms <- decode.field("baseline_ms", decode.float)
  decode.success(BaselineEntry(name:, params:, baseline_ms:))
}

fn read_baseline() -> Result(List(BaselineEntry), PerfError) {
  use body <- result.try(
    simplifile.read(baseline_path) |> result.map_error(BaselineReadFailed),
  )
  json.parse(body, decode.list(baseline_entry_decoder()))
  |> result.map_error(BaselineInvalid)
}

/// Write the baseline file as one JSON object per line — plain
/// `gleam/json.to_string` collapses the whole array onto one line, which
/// makes every future update's diff unreadable; hand-formatting one entry per
/// line keeps `git diff` on this file meaningful.
fn write_baseline(
  entries: List(BaselineEntry),
) -> Result(Nil, simplifile.FileError) {
  let body =
    "[\n"
    <> {
      entries
      |> list.map(encode_baseline_entry)
      |> string.join(",\n")
    }
    <> "\n]\n"
  simplifile.write(baseline_path, body)
}

fn encode_baseline_entry(entry: BaselineEntry) -> String {
  "  "
  <> json.to_string(
    json.object([
      #("name", json.string(entry.name)),
      #("params", json.string(entry.params)),
      #("baseline_ms", json.float(float.to_precision(entry.baseline_ms, 3))),
    ]),
  )
}

/// The measured set (issue #20): every query behind the board/detail/pnl
/// fan-outs, plus the deferred single-query candidates that fan-out was never
/// applied to. Every as-of read pins the SAME as-of date (2025-06-15) and the
/// same mid-range entity ids, all of which exist in the scaled dataset
/// (`bin/seed-scale`) so every query returns real rows rather than measuring
/// an empty-result fast path.
fn measured_queries() -> List(Measured) {
  list.flatten([
    board_fanout_measurements(),
    engineer_detail_fanout_measurements(),
    project_detail_fanout_measurements(),
    pnl_fanout_measurements(),
    forecast_measurements(),
    deferred_fanout_candidate_measurements(),
  ])
}

/// The 5 queries behind the board fan-out.
fn board_fanout_measurements() -> List(Measured) {
  let as_of = Date(2025, June, 15)
  let as_of_display = "as_of=2025-06-15"

  [
    Measured(
      "board_engaged",
      "src/tempo/server/board/sql/board_engaged.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "board_unassigned",
      "src/tempo/server/board/sql/board_unassigned.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "board_leave",
      "src/tempo/server/board/sql/board_leave.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "board_unstaffed",
      "src/tempo/server/board/sql/board_unstaffed.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "leave_balances",
      "src/tempo/server/leave/sql/leave_balances.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
  ]
}

/// The 4 queries behind the engineer detail fan-out.
fn engineer_detail_fanout_measurements() -> List(Measured) {
  let as_of = Date(2025, June, 15)
  let as_of_display = "as_of=2025-06-15"
  let engineer_id = 250

  [
    Measured(
      "engineer_employment_asof",
      "src/tempo/server/engineer/sql/engineer_employment_asof.sql",
      [pog.int(engineer_id), pog.calendar_date(as_of)],
      "engineer_id=" <> int.to_string(engineer_id) <> ", " <> as_of_display,
    ),
    Measured(
      "engineer_allocations",
      "src/tempo/server/engineer/sql/engineer_allocations.sql",
      [pog.int(engineer_id), pog.calendar_date(as_of)],
      "engineer_id=" <> int.to_string(engineer_id) <> ", " <> as_of_display,
    ),
    Measured(
      "leave_history",
      "src/tempo/server/leave/sql/leave_history.sql",
      [pog.int(engineer_id)],
      "engineer_id=" <> int.to_string(engineer_id),
    ),
    Measured(
      "leave_balance",
      "src/tempo/server/leave/sql/leave_balance.sql",
      [pog.int(engineer_id), pog.text("annual"), pog.calendar_date(as_of)],
      "engineer_id="
        <> int.to_string(engineer_id)
        <> ", kind=annual, "
        <> as_of_display,
    ),
  ]
}

/// The 3 queries behind the project detail fan-out.
fn project_detail_fanout_measurements() -> List(Measured) {
  let as_of = Date(2025, June, 15)
  let as_of_display = "as_of=2025-06-15"
  let project_id = 100

  [
    Measured(
      "project_team",
      "src/tempo/server/project/sql/project_team.sql",
      [pog.int(project_id), pog.calendar_date(as_of)],
      "project_id=" <> int.to_string(project_id) <> ", " <> as_of_display,
    ),
    Measured(
      "project_requirements",
      "src/tempo/server/project/sql/project_requirements.sql",
      [pog.int(project_id)],
      "project_id=" <> int.to_string(project_id),
    ),
    Measured(
      "project_invoices",
      "src/tempo/server/project/sql/project_invoices.sql",
      [pog.int(project_id), pog.calendar_date(as_of)],
      "project_id=" <> int.to_string(project_id) <> ", " <> as_of_display,
    ),
  ]
}

/// The pnl fan-out: the month window and the YTD window are two separate
/// entries, both running the SAME pnl_rows.sql over different windows.
fn pnl_fanout_measurements() -> List(Measured) {
  let month_start = Date(2025, June, 1)
  let month_end = Date(2025, July, 1)
  let year_start = Date(2025, January, 1)

  [
    Measured(
      "pnl_rows_month",
      "src/tempo/server/pnl/sql/pnl_rows.sql",
      [pog.calendar_date(month_start), pog.calendar_date(month_end)],
      "period=[2025-06-01,2025-07-01)",
    ),
    Measured(
      "pnl_rows_ytd",
      "src/tempo/server/pnl/sql/pnl_rows.sql",
      [pog.calendar_date(year_start), pog.calendar_date(month_end)],
      "period=[2025-01-01,2025-07-01)",
    ),
  ]
}

/// The forecast query: a single query, no fan-out to compare against.
fn forecast_measurements() -> List(Measured) {
  let as_of = Date(2025, June, 15)
  let as_of_display = "as_of=2025-06-15"

  [
    Measured(
      "forecast",
      "src/tempo/server/forecast/sql/forecast.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
  ]
}

/// Deferred fan-out candidates (issue #20 decision question 2): client
/// detail, roster, and settings singles, never fanned out.
fn deferred_fanout_candidate_measurements() -> List(Measured) {
  let as_of = Date(2025, June, 15)
  let as_of_display = "as_of=2025-06-15"
  let client_id = 75

  [
    Measured(
      "client_contracts",
      "src/tempo/server/client/sql/client_contracts.sql",
      [pog.int(client_id), pog.calendar_date(as_of)],
      "client_id=" <> int.to_string(client_id) <> ", " <> as_of_display,
    ),
    Measured(
      "client_projects",
      "src/tempo/server/client/sql/client_projects.sql",
      [pog.int(client_id), pog.calendar_date(as_of)],
      "client_id=" <> int.to_string(client_id) <> ", " <> as_of_display,
    ),
    Measured(
      "roster_engineers",
      "src/tempo/server/roster/sql/roster_engineers.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "roster_projects",
      "src/tempo/server/roster/sql/roster_projects.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "roster_clients",
      "src/tempo/server/roster/sql/roster_clients.sql",
      [],
      "(none)",
    ),
    Measured(
      "rate_card_list",
      "src/tempo/server/rate_card/sql/rate_card_list.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "salary_list",
      "src/tempo/server/salary/sql/salary_list.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
    Measured(
      "leave_policy_list",
      "src/tempo/server/leave/sql/leave_policy_list.sql",
      [pog.calendar_date(as_of)],
      as_of_display,
    ),
  ]
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
