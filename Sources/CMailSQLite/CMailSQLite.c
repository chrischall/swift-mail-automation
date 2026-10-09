#include "CMailSQLite.h"
#include <sqlite3.h>

int cmail_sqlite_disable_checkpoint_on_close(struct sqlite3 *db) {
    int enabled = 0;
    int rc = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
    if (rc != SQLITE_OK) {
        return rc;
    }
    // Read back: an SQLite too old to know the option ignores it silently.
    return enabled == 1 ? SQLITE_OK : SQLITE_ERROR;
}
