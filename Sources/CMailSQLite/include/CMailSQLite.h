#ifndef CMAILSQLITE_H
#define CMAILSQLITE_H

struct sqlite3;

/// Stops this connection from checkpointing the WAL (and deleting it) when
/// it closes, even if it is the last connection to the database.
///
/// Wraps `sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, ...)`,
/// which Swift cannot call directly because it is variadic.
///
/// Returns an SQLite result code; `SQLITE_OK` (0) on success.
int cmail_sqlite_disable_checkpoint_on_close(struct sqlite3 *db);

#endif
