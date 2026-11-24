#!/usr/bin/env python3
"""verify_restore.py — 恢复演练的数据一致性校验（ClawHunt #3175）。

只用 Python 标准库 + psql 命令行，不额外装驱动。

两个子命令：
  snapshot --tables ops/restore/tables.yml --out snapshot.json
      连接源实例，对 tables.yml 里的每张表记录校验快照：
      行数（未软删除的行）、每表最大 updated_at、按 id 排序前 1000 行的哈希。
      快照在演练前取，存下来给 verify 用。
  verify --tables ops/restore/tables.yml --snapshot snapshot.json
         --report report.json [--report-md report.md]
      连接恢复出的临时实例，逐项对比快照，输出 PASS / FAIL。
      FAIL 时在报告里列出不一致的表名（验收 2 要求）。

连接：默认读 PG* 环境变量（PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD）；
  也可以用 --host/--port/--user/--dbname/--password 覆盖，
  或 --dsn 传一条 libpq 连接串。
psql 位置：PATH 里找，或 PGBIN 环境变量。

校验细节：
  * 行数与哈希只算 deleted_at IS NULL 的行（平台软删除约定）。
  * 行哈希：每行各列转文本（NULL 记为 <NULL>），列间用 \\x1f 分隔，
    行间用换行分隔，整体 SHA-256。查询前固定 DateStyle=ISO, YMD 与
    TimeZone=UTC，让两边输出逐字节可比。
  * max(updated_at) 用 to_char 钉成 ISO 文本；表里没有 updated_at 列
    时该项记为 null，并在报告里注明 skipped。
  * 表名与列名只接受 [A-Za-z_][A-Za-z0-9_]*（可带一个 schema 前缀），
    拼 SQL 前做标识符转义，tables.yml 不是可信输入就报错退出。

退出码：0 PASS（verify）/ 快照成功（snapshot）；1 FAIL；2 用法或配置错误。
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def quote_ident(name):
    """SQL 标识符转义；不合法直接报错，不拼进 SQL。"""
    if not IDENT.match(name):
        raise ValueError(f"illegal identifier: {name!r}")
    return '"' + name + '"'


def qualified(table):
    """表名可带一个 schema 前缀：public.members。"""
    parts = table.split(".")
    if len(parts) > 2 or not all(parts):
        raise ValueError(f"illegal table name: {table!r}")
    return ".".join(quote_ident(p) for p in parts)


# ---------------------------------------------------------------- tables.yml
# 只解析本交付约定的固定形状，不做通用 YAML 解析：
#   tables:
#     - name: members
#       columns: [id, org_id, ...]
#       order_by: id
#       limit: 1000
# 其它写法一律报错，避免静默误读。

def parse_tables_yml(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    tables = []
    current = None
    seen_tables = False
    for raw in lines:
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        if stripped == "tables:":
            seen_tables = True
            continue
        if line.startswith("  - name:"):
            if current is not None:
                tables.append(current)
            current = {"name": line.split(":", 1)[1].strip(), "columns": None,
                       "order_by": "id", "limit": 1000}
            continue
        if current is None:
            raise ValueError(f"unexpected line in {path}: {raw!r}")
        if stripped.startswith("columns:"):
            val = stripped.split(":", 1)[1].strip()
            if not (val.startswith("[") and val.endswith("]")):
                raise ValueError(f"columns must be an inline list: {raw!r}")
            cols = [c.strip() for c in val[1:-1].split(",") if c.strip()]
            if not cols:
                raise ValueError(f"empty columns list: {raw!r}")
            current["columns"] = cols
            continue
        if stripped.startswith("order_by:"):
            current["order_by"] = stripped.split(":", 1)[1].strip()
            continue
        if stripped.startswith("limit:"):
            try:
                current["limit"] = int(stripped.split(":", 1)[1].strip())
            except ValueError:
                raise ValueError(f"limit must be an integer: {raw!r}")
            continue
        raise ValueError(f"unsupported line in {path}: {raw!r}")
    if current is not None:
        tables.append(current)
    if not seen_tables or not tables:
        raise ValueError(f"{path}: no tables found")
    for t in tables:
        if not t["name"] or t["columns"] is None:
            raise ValueError(f"table entry incomplete: {t!r}")
        qualified(t["name"])  # 校验表名合法
        for c in t["columns"]:
            quote_ident(c)
        quote_ident(t["order_by"])
        if t["limit"] <= 0:
            raise ValueError(f"limit must be positive: {t!r}")
    return tables


# ---------------------------------------------------------------- psql
class Psql:
    def __init__(self, args):
        self.psql = self._find_psql()
        self.env = dict(os.environ)
        if args.dsn:
            self.dbname = args.dsn
        else:
            if args.host:
                self.env["PGHOST"] = args.host
            if args.port:
                self.env["PGPORT"] = str(args.port)
            if args.user:
                self.env["PGUSER"] = args.user
            if args.dbname:
                self.env["PGDATABASE"] = args.dbname
            if args.password:
                self.env["PGPASSWORD"] = args.password
            self.dbname = self.env.get("PGDATABASE", "")
        if not self.dbname and not args.dsn:
            raise ValueError("no database: set PGDATABASE or pass --dbname/--dsn")
        self.host = self.env.get("PGHOST", "localhost")
        self.port = self.env.get("PGPORT", "5432")
        # 输出格式钉死（不发 SET 命令——psql -At 下 SET 会输出 SET 标签，
        # 混进结果里；环境变量由 libpq 在连接时生效，且不污染输出）：
        self.env.setdefault("PGDATESTYLE", "ISO, YMD")
        self.env.setdefault("PGTZ", "UTC")

    @staticmethod
    def _find_psql():
        pgbin = os.environ.get("PGBIN", "")
        if pgbin:
            cand = os.path.join(pgbin, "psql")
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
            raise ValueError(f"PGBIN set but no psql there: {pgbin}")
        for d in os.environ.get("PATH", "").split(os.pathsep):
            cand = os.path.join(d, "psql")
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
        raise ValueError("psql not found (set PGBIN or put psql on PATH)")

    def query(self, sql):
        """跑一条只读 SQL，返回 stdout 文本（-At，每行一条记录）。"""
        cmd = [self.psql, "-X", "--no-psqlrc", "-v", "ON_ERROR_STOP=1",
               "-At", "-F", "\x1f", "-d", self.dbname, "-c", sql]
        p = subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError(f"psql failed ({p.returncode}): {p.stderr.strip()}")
        return p.stdout

    def table_exists(self, table):
        schema, _, name = table.rpartition(".")
        schema = schema or "public"
        sql = ("SELECT count(*) FROM information_schema.tables "
               f"WHERE table_schema = '{schema}' AND table_name = '{name}'")
        return self.query(sql).strip() == "1"

    def column_exists(self, table, column):
        schema, _, name = table.rpartition(".")
        schema = schema or "public"
        sql = ("SELECT count(*) FROM information_schema.columns "
               f"WHERE table_schema = '{schema}' AND table_name = '{name}' "
               f"AND column_name = '{column}'")
        return self.query(sql).strip() == "1"


# ---------------------------------------------------------------- 校验核心
def snapshot_table(psql, spec):
    table = spec["name"]
    cols = spec["columns"]
    if not psql.table_exists(table):
        raise ValueError(f"table not found: {table}")
    for c in cols:
        if not psql.column_exists(table, c):
            raise ValueError(f"column {c} not found in table {table}")
    has_updated = "updated_at" in cols and psql.column_exists(table, "updated_at")
    has_deleted = psql.column_exists(table, "deleted_at")
    where = "WHERE deleted_at IS NULL" if has_deleted else ""
    order = quote_ident(spec["order_by"])
    select_list = ", ".join(
        f"COALESCE({quote_ident(c)}::text, '<NULL>')" for c in cols)
    sql = (f"SELECT {select_list} FROM {qualified(table)} {where} "
           f"ORDER BY {order} LIMIT {spec['limit']}")
    out = psql.query(sql)
    h = hashlib.sha256()
    rows = 0
    for line in out.splitlines():
        h.update(line.encode("utf-8"))
        h.update(b"\n")
        rows += 1
    count_sql = f"SELECT count(*) FROM {qualified(table)} {where}"
    count = int(psql.query(count_sql).strip())
    max_updated = None
    if has_updated:
        max_sql = ("SELECT to_char(max(updated_at), 'YYYY-MM-DD\"T\"HH24:MI:SS.USOF') "
                   f"FROM {qualified(table)} {where}")
        max_updated = psql.query(max_sql).strip() or None
    return {
        "count": count,
        "count_hashed_rows": rows,
        "max_updated_at": max_updated,
        "max_updated_at_skipped": not has_updated,
        "row_hash": h.hexdigest(),
        "columns": cols,
        "order_by": spec["order_by"],
        "limit": spec["limit"],
    }


def compare_table(name, snap, actual):
    """返回 (ok, [差异说明])。"""
    diffs = []
    if snap["count"] != actual["count"]:
        diffs.append(f"count: snapshot={snap['count']} actual={actual['count']}")
    if snap["max_updated_at"] != actual["max_updated_at"]:
        diffs.append(f"max_updated_at: snapshot={snap['max_updated_at']} "
                     f"actual={actual['max_updated_at']}")
    if snap["row_hash"] != actual["row_hash"]:
        diffs.append("row_hash mismatch (first 1000 rows by id differ)")
    return (not diffs, diffs)


# ---------------------------------------------------------------- 子命令
def cmd_snapshot(args):
    specs = parse_tables_yml(args.tables)
    psql = Psql(args)
    snap = {
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "database": psql.dbname,
        "host": psql.host,
        "port": psql.port,
        "tables": {},
    }
    for spec in specs:
        snap["tables"][spec["name"]] = snapshot_table(psql, spec)
        t = snap["tables"][spec["name"]]
        print(f"snapshot {spec['name']}: count={t['count']} "
              f"max_updated_at={t['max_updated_at']} hash={t['row_hash'][:12]}...")
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(snap, f, indent=2, sort_keys=True)
    print(f"snapshot written: {args.out}")
    return 0


def cmd_verify(args):
    specs = parse_tables_yml(args.tables)
    with open(args.snapshot, encoding="utf-8") as f:
        snap = json.load(f)
    psql = Psql(args)
    results = {}
    failed_tables = []
    for spec in specs:
        name = spec["name"]
        if name not in snap.get("tables", {}):
            results[name] = {"status": "FAIL",
                             "diffs": [f"table {name} missing from snapshot"]}
            failed_tables.append(name)
            continue
        actual = snapshot_table(psql, spec)
        ok, diffs = compare_table(name, snap["tables"][name], actual)
        results[name] = {"status": "PASS" if ok else "FAIL", "diffs": diffs,
                         "snapshot": snap["tables"][name], "actual": actual}
        if not ok:
            failed_tables.append(name)
    overall = "PASS" if not failed_tables else "FAIL"
    report = {
        "result": overall,
        "checked_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "snapshot_file": args.snapshot,
        "snapshot_generated_at_utc": snap.get("generated_at_utc"),
        "database": psql.dbname,
        "host": psql.host,
        "port": psql.port,
        "failed_tables": failed_tables,
        "tables": results,
    }
    with open(args.report, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
    if args.report_md:
        lines = [f"# Restore verification: {overall}", "",
                 f"- checked at (UTC): {report['checked_at_utc']}",
                 f"- snapshot: {args.snapshot} "
                 f"(generated {snap.get('generated_at_utc')})",
                 f"- database: {psql.dbname} on {psql.host}:{psql.port}", ""]
        if failed_tables:
            lines.append(f"FAILED tables: {', '.join(failed_tables)}")
            lines.append("")
        for name in sorted(results):
            r = results[name]
            lines.append(f"## {name}: {r['status']}")
            for d in r["diffs"]:
                lines.append(f"- {d}")
            if r["status"] == "PASS":
                s = r["snapshot"]
                lines.append(f"- count={s['count']} max_updated_at={s['max_updated_at']} "
                             f"row_hash={s['row_hash'][:16]}...")
            lines.append("")
        with open(args.report_md, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
    print(f"RESULT: {overall}")
    if failed_tables:
        print(f"FAILED tables: {', '.join(failed_tables)}")
    for name in sorted(results):
        r = results[name]
        print(f"  {name}: {r['status']}" + (f" — {'; '.join(r['diffs'])}" if r["diffs"] else ""))
    print(f"report written: {args.report}" + (f" + {args.report_md}" if args.report_md else ""))
    return 0 if overall == "PASS" else 1


def main(argv=None):
    p = argparse.ArgumentParser(description="PITR restore verification (ClawHunt #3175)")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--user")
    p.add_argument("--dbname")
    p.add_argument("--password")
    p.add_argument("--dsn", help="libpq connection string (overrides PG* env)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="record a pre-drill checksum snapshot")
    s.add_argument("--tables", required=True, help="tables.yml path")
    s.add_argument("--out", required=True, help="snapshot JSON path")
    s.set_defaults(func=cmd_snapshot)

    v = sub.add_parser("verify", help="compare a restored instance against a snapshot")
    v.add_argument("--tables", required=True, help="tables.yml path")
    v.add_argument("--snapshot", required=True, help="snapshot JSON path")
    v.add_argument("--report", required=True, help="report JSON path")
    v.add_argument("--report-md", help="report Markdown path (optional)")
    v.set_defaults(func=cmd_verify)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, RuntimeError, FileNotFoundError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
