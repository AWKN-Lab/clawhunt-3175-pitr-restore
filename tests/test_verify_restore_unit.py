"""Unit tests for verify_restore.py (no database needed).

Run: tests/.venv/bin/pytest tests/test_verify_restore_unit.py -v
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ops" / "restore"))

import pytest

import verify_restore as vr


@pytest.fixture()
def tables_yml(tmp_path):
    p = tmp_path / "tables.yml"
    p.write_text(
        "tables:\n"
        "  - name: members\n"
        "    columns: [id, org_id, company_name, updated_at, deleted_at]\n"
        "    order_by: id\n"
        "    limit: 1000\n"
        "  - name: sop_items\n"
        "    columns: [id, title, updated_at]\n"
        "    order_by: id\n"
        "    limit: 1000\n",
        encoding="utf-8",
    )
    return str(p)


def test_parse_tables_yml_ok(tables_yml):
    tables = vr.parse_tables_yml(tables_yml)
    assert len(tables) == 2
    assert tables[0]["name"] == "members"
    assert tables[0]["columns"] == ["id", "org_id", "company_name", "updated_at", "deleted_at"]
    assert tables[0]["order_by"] == "id"
    assert tables[0]["limit"] == 1000
    assert tables[1]["columns"] == ["id", "title", "updated_at"]


def test_parse_tables_yml_rejects_bad_shape(tmp_path):
    p = tmp_path / "bad.yml"
    p.write_text("tables:\n  - name: members\n    columns: id, org_id\n", encoding="utf-8")
    with pytest.raises(ValueError):
        vr.parse_tables_yml(str(p))


def test_parse_tables_yml_rejects_unknown_key(tmp_path):
    p = tmp_path / "bad2.yml"
    p.write_text(
        "tables:\n  - name: members\n    columns: [id]\n    frobnicate: yes\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError):
        vr.parse_tables_yml(str(p))


def test_quote_ident_rejects_injection():
    with pytest.raises(ValueError):
        vr.quote_ident('members"; DROP TABLE members; --')
    assert vr.quote_ident("members") == '"members"'
    assert vr.qualified("public.members") == '"public"."members"'
    with pytest.raises(ValueError):
        vr.qualified("a.b.c")


class FakePsql:
    """Canned psql: row output + counts per table name."""

    def __init__(self, rows_by_table, counts):
        self.rows_by_table = rows_by_table  # table -> list of raw output lines
        self.counts = counts

    def table_exists(self, table):
        return table in self.counts

    def column_exists(self, table, column):
        return True

    def query(self, sql):
        if "count(*)" in sql:
            for t, c in self.counts.items():
                if f'"{t}"' in sql:
                    return f"{c}\n"
            raise AssertionError(f"count query for unknown table: {sql}")
        if "max(updated_at)" in sql:
            return "2026-11-24T02:00:00.123456+00\n"
        if "SELECT" in sql:
            for t, rows in self.rows_by_table.items():
                if f'"{t}"' in sql:
                    return "".join(r + "\n" for r in rows)
            raise AssertionError(f"select for unknown table: {sql}")
        raise AssertionError(f"unexpected sql: {sql}")


def _spec(name="members", cols=("id", "company_name", "updated_at")):
    return {"name": name, "columns": list(cols), "order_by": "id", "limit": 1000}


def test_snapshot_table_hash_is_stable():
    rows = ["11111111-1111-1111-1111-111111111111\x1fAcme", "22222222-2222-2222-2222-222222222222\x1fBeta"]
    psql = FakePsql({"members": rows}, {"members": 2})
    s1 = vr.snapshot_table(psql, _spec())
    s2 = vr.snapshot_table(psql, _spec())
    assert s1["row_hash"] == s2["row_hash"]
    assert s1["count"] == 2
    assert s1["count_hashed_rows"] == 2
    assert s1["max_updated_at"] == "2026-11-24T02:00:00.123456+00"


def test_snapshot_table_hash_changes_when_a_row_changes():
    rows_a = ["11111111-1111-1111-1111-111111111111\x1fAcme"]
    rows_b = ["11111111-1111-1111-1111-111111111111\x1fAcme CHANGED"]
    h_a = vr.snapshot_table(FakePsql({"members": rows_a}, {"members": 1}), _spec())["row_hash"]
    h_b = vr.snapshot_table(FakePsql({"members": rows_b}, {"members": 1}), _spec())["row_hash"]
    assert h_a != h_b


def test_compare_table_pass_and_fail():
    snap = {"count": 3, "max_updated_at": "2026-11-24T02:00:00+00", "row_hash": "aa"}
    ok, diffs = vr.compare_table("members", snap, dict(snap))
    assert ok and diffs == []
    ok, diffs = vr.compare_table("members", snap, {**snap, "count": 2})
    assert not ok and any("count" in d for d in diffs)
    ok, diffs = vr.compare_table("members", snap, {**snap, "row_hash": "bb"})
    assert not ok and any("row_hash" in d for d in diffs)
    ok, diffs = vr.compare_table("members", snap, {**snap, "max_updated_at": "2026-11-24T03:00:00+00"})
    assert not ok and any("max_updated_at" in d for d in diffs)


def test_snapshot_table_rejects_missing_table():
    psql = FakePsql({}, {})
    with pytest.raises(ValueError, match="table not found"):
        vr.snapshot_table(psql, _spec())
