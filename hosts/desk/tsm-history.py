"""Record each TSM AppData.lua download into a SQLite history.

Usage: tsm-history <AppData.lua> <history.db> [item_cache.json]

AppData.lua holds one LoadData(...) line per data set and scope, each with
its own downloadTime. The TSM app rewrites the whole file on every sync, most
of it unchanged, so a set is stored once per (dataset, scope, downloadTime)
and a rerun on the same file adds nothing.

Values are decoded the way the addon does (AuctionDB/Core.lua): base 32, in
copper for prices; a bare numeric item key is "i:<id>".
"""

import json
import re
import sqlite3
import sys
import time

LINE = re.compile(
    r'LoadData\("([^"]+)","([^"]+)",\[\[return \{downloadTime=(\d+),'
    r'fields=\{([^}]*)\},data=\{(.*)\}\}\]\]\)'
)
ROW = re.compile(r"\{([^{}]*)\}")

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshot (
    id INTEGER PRIMARY KEY,
    dataset TEXT NOT NULL,
    scope TEXT NOT NULL,
    download_time INTEGER NOT NULL,
    captured_at INTEGER NOT NULL,
    fields TEXT NOT NULL,
    UNIQUE (dataset, scope, download_time)
);
CREATE TABLE IF NOT EXISTS value (
    snapshot_id INTEGER NOT NULL REFERENCES snapshot(id),
    item TEXT NOT NULL,
    field TEXT NOT NULL,
    value INTEGER NOT NULL,
    PRIMARY KEY (snapshot_id, item, field)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS value_item ON value (item, field);
CREATE TABLE IF NOT EXISTS item (
    item TEXT PRIMARY KEY,
    name TEXT NOT NULL
);
CREATE VIEW IF NOT EXISTS price AS
    SELECT s.dataset, s.scope,
           datetime(s.download_time, 'unixepoch') AS downloaded,
           v.item, i.name, v.field, v.value
    FROM value v
    JOIN snapshot s ON s.id = v.snapshot_id
    LEFT JOIN item i ON i.item = v.item;
"""


def decode(token):
    return int(token, 32)


def item_key(token):
    token = token.strip('"')
    return "i:" + token if token.isdigit() else token


def record(lua_path, db):
    added = []
    now = int(time.time())
    with open(lua_path, encoding="utf-8") as f:
        for line in f:
            m = LINE.search(line)
            if not m:
                continue
            dataset, scope, download_time, fields, data = m.groups()
            fields = [x.strip('"') for x in fields.split(",")]
            cur = db.execute(
                "INSERT OR IGNORE INTO snapshot"
                " (dataset, scope, download_time, captured_at, fields)"
                " VALUES (?, ?, ?, ?, ?)",
                (dataset, scope, int(download_time), now, json.dumps(fields)),
            )
            if cur.rowcount == 0:
                continue
            snapshot_id = cur.lastrowid
            rows = []
            for r in ROW.finditer(data):
                parts = r.group(1).split(",")
                item = item_key(parts[0])
                for name, token in zip(fields[1:], parts[1:]):
                    rows.append((snapshot_id, item, name, decode(token)))
            db.executemany("INSERT INTO value VALUES (?, ?, ?, ?)", rows)
            added.append(f"{dataset}/{scope} ({len(rows)} values)")
    return added


def record_names(cache_path, db):
    try:
        with open(cache_path, encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, ValueError):
        return
    db.executemany(
        "INSERT OR REPLACE INTO item VALUES (?, ?)",
        [(item_key(k), v["name"]) for k, v in cache.items() if v.get("name")],
    )


def main():
    lua_path, db_path = sys.argv[1], sys.argv[2]
    db = sqlite3.connect(db_path, timeout=60)
    db.executescript(SCHEMA)
    with db:
        added = record(lua_path, db)
        if len(sys.argv) > 3:
            record_names(sys.argv[3], db)
    db.close()
    print("tsm-history: " + ("; ".join(added) if added else "nothing new"))


if __name__ == "__main__":
    main()
