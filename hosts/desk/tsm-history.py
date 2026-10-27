"""Record WoW auction-house prices into a SQLite history.

  tsm-history tsm <history.db> <AppData.lua> [item_cache.json]
  tsm-history auctionator <history.db> <Auctionator.lua>...

tsm: AppData.lua, which the TSM app rewrites on every sync, holds one
LoadData(...) line per data set and scope, each with its own downloadTime. A
set is stored once per (dataset, scope, downloadTime), so a rerun on the same
file adds nothing. Values are decoded the way the addon does
(AuctionDB/Core.lua): base 32, in copper for prices; a bare numeric item key
is "i:<id>".

auctionator: Auctionator's account-wide saved variables, written on logout
and /reload. AUCTIONATOR_PRICE_DATABASE holds one CBOR string per realm
(Source/Variables/Main.lua): item key -> {l, h, a}, each keyed by days since
2020-01-01: the lowest and highest lowest-buyout seen that day, in copper,
and the most auctions seen. Auctionator prunes old days, the history keeps
them; a day seen again (or by the other account) keeps the lowest low, the
highest high and the most auctions.
"""

import datetime
import json
import re
import sqlite3
import sys
import time

import cbor2

LINE = re.compile(
    r'LoadData\("([^"]+)","([^"]+)",\[\[return \{downloadTime=(\d+),'
    r'fields=\{([^}]*)\},data=\{(.*)\}\}\]\]\)'
)
ROW = re.compile(r"\{([^{}]*)\}")

SCAN_DAY_0 = datetime.date(2020, 1, 1)
PRICE_DB = re.compile(rb"^AUCTIONATOR_PRICE_DATABASE = \{\r?\n", re.M)
REALM = re.compile(rb'\["([^"]+)"\] = "')
ESCAPE = re.compile(rb'\\(\d{1,3}|\r\n|.)', re.S)
ESCAPES = {
    b"n": b"\n", b"r": b"\r", b"t": b"\t", b"a": b"\a", b"b": b"\b",
    b"f": b"\f", b"v": b"\v", b"\\": b"\\", b'"': b'"', b"'": b"'",
    b"\n": b"\n", b"\r\n": b"\n",
}

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
CREATE TABLE IF NOT EXISTS auctionator_day (
    realm TEXT NOT NULL,
    item TEXT NOT NULL,
    day TEXT NOT NULL,
    low INTEGER,
    high INTEGER,
    available INTEGER,
    PRIMARY KEY (realm, item, day)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS auctionator_day_item ON auctionator_day (item);
CREATE VIEW IF NOT EXISTS auctionator AS
    SELECT a.realm, a.day, a.item, i.name, a.low, a.high, a.available
    FROM auctionator_day a
    LEFT JOIN item i ON i.item = a.item;
"""


def item_key(token):
    token = token.strip('"')
    return "i:" + token if token.isdigit() else token


def record_tsm(db, lua_path):
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
                    rows.append((snapshot_id, item, name, int(token, 32)))
            db.executemany("INSERT INTO value VALUES (?, ?, ?, ?)", rows)
            added.append(f"{dataset}/{scope} ({len(rows)} values)")
    return added


def record_names(db, cache_path):
    try:
        with open(cache_path, encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, ValueError):
        return
    db.executemany(
        "INSERT OR REPLACE INTO item VALUES (?, ?)",
        [(item_key(k), v["name"]) for k, v in cache.items() if v.get("name")],
    )


def lua_string(buf, start):
    """Return the bytes of the quoted Lua string at buf[start:] and its end."""
    end = start
    while True:
        end = buf.index(b'"', end)
        slashes = 0
        while buf[end - 1 - slashes] == 0x5C:
            slashes += 1
        if slashes % 2 == 0:
            break
        end += 1

    def unescape(m):
        e = m.group(1)
        return bytes([int(e)]) if e.isdigit() else ESCAPES.get(e, e)

    return ESCAPE.sub(unescape, buf[start:end]), end


def auctionator_realms(path):
    """Yield (realm, decoded price table) from an Auctionator.lua."""
    with open(path, "rb") as f:
        buf = f.read()
    m = PRICE_DB.search(buf)
    if not m:
        return
    pos = m.end()
    # One entry per line until the closing brace; __dbversion is a number.
    while not buf.startswith(b"}", pos):
        r = REALM.match(buf, pos)
        end = pos
        if r:
            raw, end = lua_string(buf, r.end())
            yield r.group(1).decode("utf-8"), cbor2.loads(raw)
        pos = buf.index(b"\n", end) + 1


def day_date(day):
    return (SCAN_DAY_0 + datetime.timedelta(days=int(day))).isoformat()


def text(v):
    return v.decode("utf-8") if isinstance(v, bytes) else str(v)


def by_day(table):
    # Lua's empty table serializes as an empty CBOR array.
    if not isinstance(table, dict):
        return {}
    return {text(k): v for k, v in table.items()}


def record_auctionator(db, path):
    added = []
    for realm, items in auctionator_realms(path):
        rows = []
        for key, data in items.items():
            if not isinstance(data, dict):
                continue  # the "version" entry
            data = {text(k): v for k, v in data.items()}
            item = item_key(text(key))
            low, high = by_day(data.get("l")), by_day(data.get("h"))
            available = by_day(data.get("a"))
            for day in set(low) | set(high) | set(available):
                # Auctionator records l only below h: its low is l or h.
                rows.append((
                    realm, item, day_date(day),
                    low.get(day, high.get(day)), high.get(day),
                    available.get(day),
                ))
        db.executemany(
            "INSERT INTO auctionator_day VALUES (?, ?, ?, ?, ?, ?)"
            " ON CONFLICT DO UPDATE SET"
            " low = min(coalesce(low, excluded.low),"
            " coalesce(excluded.low, low)),"
            " high = max(coalesce(high, excluded.high),"
            " coalesce(excluded.high, high)),"
            " available = max(coalesce(available, excluded.available),"
            " coalesce(excluded.available, available))",
            rows,
        )
        added.append(f"{realm} ({len(items)} items, {len(rows)} item-days)")
    return added


def main():
    mode, db_path, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    db = sqlite3.connect(db_path, timeout=60)
    db.executescript(SCHEMA)
    added = []
    with db:
        if mode == "tsm":
            added = record_tsm(db, paths[0])
            if len(paths) > 1:
                record_names(db, paths[1])
        elif mode == "auctionator":
            for path in paths:
                try:
                    added += record_auctionator(db, path)
                except (OSError, ValueError, cbor2.CBORDecodeError) as e:
                    print(f"tsm-history: skipping {path}: {e}")
        else:
            sys.exit(f"tsm-history: unknown mode {mode}")
    db.close()
    print("tsm-history: " + ("; ".join(added) if added else "nothing new"))


if __name__ == "__main__":
    main()
