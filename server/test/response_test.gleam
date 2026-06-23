//// Unit tests for the web response helpers — the database-error-to-HTTP mapping
//// that surfaces connection-pool exhaustion as a retryable 503 rather than a 500.

import pog
import tempo/server/web/response

// A checkout that timed out waiting for a free connection is pool saturation:
// the client should get a retryable 503, not a 500.
pub fn query_timeout_is_503_test() {
  let result = response.db_error_response(pog.QueryTimeout)

  assert result.status == 503
}

// No connection available at all is likewise a capacity/connectivity problem
// surfaced as 503.
pub fn connection_unavailable_is_503_test() {
  let result = response.db_error_response(pog.ConnectionUnavailable)

  assert result.status == 503
}

// A genuine database fault (a query that ran and errored) is a real server
// fault and stays a 500.
pub fn postgres_error_is_500_test() {
  let result =
    response.db_error_response(pog.PostgresqlError(
      "42P01",
      "undefined_table",
      "boom",
    ))

  assert result.status == 500
}
