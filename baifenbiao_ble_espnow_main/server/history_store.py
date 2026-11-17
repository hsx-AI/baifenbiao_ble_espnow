from __future__ import annotations

import math
import sqlite3
import time
from datetime import datetime
from pathlib import Path
from typing import Any

DB_PATH = Path(__file__).resolve().parent / "meter_history.db"
RETENTION_HOURS = 168  # keep 7 days; export uses last 24h


def _connect() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    return connection


def init_db() -> None:
    with _connect() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meter_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at REAL NOT NULL,
                recorded_at_iso TEXT NOT NULL,
                meter_id INTEGER NOT NULL,
                node_id INTEGER,
                value_mm REAL NOT NULL,
                unit TEXT,
                ble_rssi INTEGER,
                ble_connected INTEGER,
                sequence INTEGER,
                source TEXT
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_meter_samples_time ON meter_samples(recorded_at)"
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_meter_samples_meter_time "
            "ON meter_samples(meter_id, recorded_at)"
        )


def prune_old_samples(retention_hours: float = RETENTION_HOURS) -> int:
    cutoff = time.time() - retention_hours * 3600
    with _connect() as connection:
        cursor = connection.execute(
            "DELETE FROM meter_samples WHERE recorded_at < ?",
            (cutoff,),
        )
        return int(cursor.rowcount or 0)


def save_minute_snapshot(meters: dict[int, dict[str, Any]]) -> int:
    """Save one sample per meter that currently has a valid reading.

    Returns the number of rows inserted. Returns 0 (and writes nothing)
    when no meter has usable data.
    """
    now = time.time()
    iso = datetime.fromtimestamp(now).strftime("%Y-%m-%d %H:%M:%S")
    rows: list[tuple[Any, ...]] = []
    for meter_id, meter in meters.items():
        if not isinstance(meter, dict):
            continue
        if not meter.get("valid"):
            continue
        try:
            value = float(meter.get("value_mm"))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(value):
            continue
        rows.append(
            (
                now,
                iso,
                int(meter_id),
                int(meter.get("node_id") or 0),
                value,
                str(meter.get("unit") or "mm"),
                int(meter.get("ble_rssi") or 0),
                1 if meter.get("ble_connected") else 0,
                int(meter.get("sequence") or 0),
                str(meter.get("source") or ""),
            )
        )
    if not rows:
        return 0

    with _connect() as connection:
        connection.executemany(
            """
            INSERT INTO meter_samples (
                recorded_at, recorded_at_iso, meter_id, node_id, value_mm,
                unit, ble_rssi, ble_connected, sequence, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
    prune_old_samples()
    return len(rows)


def fetch_history(hours: float = 24.0) -> dict[int, list[dict[str, Any]]]:
    cutoff = time.time() - hours * 3600
    result: dict[int, list[dict[str, Any]]] = {meter_id: [] for meter_id in range(1, 21)}
    with _connect() as connection:
        cursor = connection.execute(
            """
            SELECT recorded_at, recorded_at_iso, meter_id, node_id, value_mm,
                   unit, ble_rssi, ble_connected, sequence, source
            FROM meter_samples
            WHERE recorded_at >= ?
            ORDER BY meter_id ASC, recorded_at ASC
            """,
            (cutoff,),
        )
        for row in cursor:
            meter_id = int(row["meter_id"])
            if meter_id not in result:
                continue
            result[meter_id].append(
                {
                    "recorded_at": float(row["recorded_at"]),
                    "recorded_at_iso": str(row["recorded_at_iso"]),
                    "meter_id": meter_id,
                    "node_id": int(row["node_id"] or 0),
                    "value_mm": float(row["value_mm"]),
                    "unit": str(row["unit"] or "mm"),
                    "ble_rssi": int(row["ble_rssi"] or 0),
                    "ble_connected": bool(row["ble_connected"]),
                    "sequence": int(row["sequence"] or 0),
                    "source": str(row["source"] or ""),
                }
            )
    return result


def history_stats(hours: float = 24.0) -> dict[str, Any]:
    cutoff = time.time() - hours * 3600
    with _connect() as connection:
        total = connection.execute(
            "SELECT COUNT(*) AS n FROM meter_samples WHERE recorded_at >= ?",
            (cutoff,),
        ).fetchone()["n"]
        meters = connection.execute(
            """
            SELECT COUNT(DISTINCT meter_id) AS n
            FROM meter_samples
            WHERE recorded_at >= ?
            """,
            (cutoff,),
        ).fetchone()["n"]
    return {"hours": hours, "sample_count": int(total), "meter_count": int(meters)}
