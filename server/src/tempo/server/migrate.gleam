//// Numbered-migration runner; applies priv/migrations in order and records them.

import filepath
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import pog
import simplifile
import tempo/server/context.{type Context}

/// What a single `run` did: versions applied this time and versions that were
/// already recorded (so the report distinguishes "did work" from "no-op").
pub type RunReport {
  RunReport(applied: List(String), already_applied: List(String))
}

/// Everything that can go wrong applying migrations. Errors keep the underlying
/// `simplifile`/`pog` cause so callers can log specifics.
pub type MigrateError {
  PrivDirNotFound
  ReadError(simplifile.FileError)
  DbError(pog.QueryError)
  ApplyFailed(version: String, error: pog.QueryError)
}

/// Apply pending migrations and print a summary. Invoked via the
/// `tempo/migrate` alias (`gleam run -m tempo/migrate`).
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  case run(ctx) {
    Ok(RunReport(applied: [], ..)) ->
      io.println("Migrations: nothing to apply.")
    Ok(RunReport(applied:, ..)) -> {
      io.println("Migrations applied:")
      list.each(applied, fn(version) { io.println("  " <> version) })
    }
    Error(error) -> io.println("Migration failed: " <> string.inspect(error))
  }
}

/// Apply every migration file in `priv/migrations` that has not yet been
/// recorded, in version order, each inside its own transaction. Records each
/// in `schema_migrations(version, applied_at)`. Re-running is a no-op.
pub fn run(context: Context) -> Result(RunReport, MigrateError) {
  let db = context.db
  use _ <- result.try(ensure_table(db))
  use done <- result.try(applied_versions(db))
  use files <- result.try(migration_files())

  let pending =
    list.filter(files, fn(file) { !list.contains(done, file.version) })
  use applied <- result.map(apply_all(db, pending))
  RunReport(applied:, already_applied: done)
}

/// A migration file discovered on disk: its `version` (the filename) and the
/// raw SQL `body` to execute.
type Migration {
  Migration(version: String, body: String)
}

/// Create `schema_migrations` if it does not exist.
fn ensure_table(db: pog.Connection) -> Result(Nil, MigrateError) {
  let sql =
    "CREATE TABLE IF NOT EXISTS schema_migrations (
       version text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )"
  pog.query(sql)
  |> pog.execute(on: db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(DbError)
}

/// The versions already recorded, so pending files can be filtered out.
fn applied_versions(db: pog.Connection) -> Result(List(String), MigrateError) {
  let row_decoder = {
    use version <- decode.field(0, decode.string)
    decode.success(version)
  }
  pog.query("SELECT version FROM schema_migrations")
  |> pog.returning(row_decoder)
  |> pog.execute(on: db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(DbError)
}

/// Read and sort every `NNN_*.sql` file under `priv/migrations`. Ordering is by
/// filename, which the `NNN_` prefix makes numeric.
fn migration_files() -> Result(List(Migration), MigrateError) {
  use priv <- result.try(
    application.priv_directory("tempo")
    |> result.replace_error(PrivDirNotFound),
  )
  let dir = filepath.join(priv, "migrations")
  use entries <- result.try(
    simplifile.read_directory(dir) |> result.map_error(ReadError),
  )
  let versions =
    entries
    |> list.filter(string.ends_with(_, ".sql"))
    |> list.sort(string.compare)
  use migrations <- result.map(
    list.try_map(versions, fn(version) {
      use body <- result.map(
        simplifile.read(filepath.join(dir, version))
        |> result.map_error(ReadError),
      )
      Migration(version:, body:)
    }),
  )
  migrations
}

/// Apply each pending migration in order, recording it in the same transaction.
/// Returns the versions applied this run.
fn apply_all(
  db: pog.Connection,
  pending: List(Migration),
) -> Result(List(String), MigrateError) {
  list.try_map(pending, fn(migration) { apply_one(db, migration) })
}

/// Run one migration's statements and record its version in a single
/// transaction, so a failing statement rolls the whole file back.
fn apply_one(
  db: pog.Connection,
  migration: Migration,
) -> Result(String, MigrateError) {
  let Migration(version:, body:) = migration
  let statements = split_statements(body)
  let outcome =
    pog.transaction(db, fn(conn) {
      use _ <- result.try(run_statements(conn, statements))
      record_version(conn, version)
    })
  case outcome {
    Ok(_) -> Ok(version)
    Error(pog.TransactionRolledBack(error)) ->
      Error(ApplyFailed(version, error))
    Error(pog.TransactionQueryError(error)) ->
      Error(ApplyFailed(version, error))
  }
}

/// Execute each statement of a migration in turn against the open transaction.
fn run_statements(
  conn: pog.Connection,
  statements: List(String),
) -> Result(Nil, pog.QueryError) {
  list.try_each(statements, fn(statement) {
    pog.query(statement) |> pog.execute(on: conn) |> result.map(fn(_) { Nil })
  })
}

/// Insert the version row that marks this migration as applied.
fn record_version(
  conn: pog.Connection,
  version: String,
) -> Result(Nil, pog.QueryError) {
  pog.query("INSERT INTO schema_migrations (version) VALUES ($1)")
  |> pog.parameter(pog.text(version))
  |> pog.execute(on: conn)
  |> result.map(fn(_) { Nil })
}

/// Split a raw SQL file into individual statements, ignoring semicolons that
/// appear inside single-quoted strings, dollar-quoted blocks, or comments. Each
/// returned statement keeps its trailing `;`; whitespace-only chunks are
/// dropped.
pub fn split_statements(sql: String) -> List(String) {
  scan(string.to_graphemes(sql), Normal, "", [])
  |> list.reverse
  |> list.filter_map(fn(chunk) {
    let trimmed = string.trim(chunk)
    case trimmed {
      "" -> Error(Nil)
      _ -> Ok(trimmed)
    }
  })
}

/// Lexer state while scanning SQL for top-level statement boundaries.
type ScanState {
  Normal
  InSingleQuote
  InLineComment
  InBlockComment
  InDollarQuote(tag: String)
}

/// Character-by-character scan that accumulates the current statement until an
/// unquoted, uncommented `;` ends it. `acc` holds the current statement in
/// reverse-append order via string concatenation; `done` holds finished
/// statements (most recent first).
fn scan(
  chars: List(String),
  state: ScanState,
  acc: String,
  done: List(String),
) -> List(String) {
  case state, chars {
    // End of input: flush whatever is buffered.
    _, [] -> [acc, ..done]

    // Top level: handle quotes, comments, dollar-quote openers, and the
    // statement-terminating semicolon.
    Normal, ["'", ..rest] -> scan(rest, InSingleQuote, acc <> "'", done)
    Normal, ["-", "-", ..rest] -> scan(rest, InLineComment, acc <> "--", done)
    Normal, ["/", "*", ..rest] -> scan(rest, InBlockComment, acc <> "/*", done)
    Normal, ["$", ..rest] -> {
      case take_dollar_tag(rest) {
        Ok(#(tag, after)) -> scan(after, InDollarQuote(tag), acc <> tag, done)
        Error(Nil) -> scan(rest, Normal, acc <> "$", done)
      }
    }
    Normal, [";", ..rest] -> scan(rest, Normal, "", [acc <> ";", ..done])

    // Inside a single-quoted string: a doubled '' is an escaped quote.
    InSingleQuote, ["'", "'", ..rest] ->
      scan(rest, InSingleQuote, acc <> "''", done)
    InSingleQuote, ["'", ..rest] -> scan(rest, Normal, acc <> "'", done)

    // Line comment ends at newline.
    InLineComment, ["\n", ..rest] -> scan(rest, Normal, acc <> "\n", done)

    // Block comment ends at */.
    InBlockComment, ["*", "/", ..rest] -> scan(rest, Normal, acc <> "*/", done)

    // Dollar-quoted block ends at a matching closing tag.
    InDollarQuote(tag), ["$", ..rest] -> {
      case take_dollar_tag(rest) {
        Ok(#(found, after)) if found == tag ->
          scan(after, Normal, acc <> found, done)
        _ -> scan(rest, InDollarQuote(tag), acc <> "$", done)
      }
    }

    // Any other character is appended verbatim in the current state.
    _, [char, ..rest] -> scan(rest, state, acc <> char, done)
  }
}

/// Try to read a dollar-quote tag (`$$` or `$name$`) starting just after the
/// opening `$`. Returns the full tag including both dollars and the remaining
/// characters, or `Error` if what follows is not a valid tag.
fn take_dollar_tag(
  chars: List(String),
) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..rest] -> Ok(#("$$", rest))
    _ -> read_tag_name(chars, "")
  }
}

/// Read an identifier tag body up to its closing `$`, e.g. `body$` -> tag
/// `$body$`. Only letters, digits, and underscores are valid tag characters.
fn read_tag_name(
  chars: List(String),
  name: String,
) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..rest] -> Ok(#("$" <> name <> "$", rest))
    [char, ..rest] ->
      case is_tag_char(char) {
        True -> read_tag_name(rest, name <> char)
        False -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

fn is_tag_char(char: String) -> Bool {
  case char {
    "_" -> True
    _ -> string.lowercase(char) != string.uppercase(char) || is_digit(char)
  }
}

fn is_digit(char: String) -> Bool {
  case char {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
