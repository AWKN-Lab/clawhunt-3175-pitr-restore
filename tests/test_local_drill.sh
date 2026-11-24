#!/usr/bin/env bash
# test_local_drill.sh — #3175 本地完整演练（本机 PostgreSQL，无云账号）。
#
# 流程（全部虚构数据）：
#   0. 搭 #3174 本地环境（种子 members 3 行、sop_items 2 行）+ 开 WAL 归档
#   1. 基础备份（pitr_restore.sh --local-base-backup-only），记下备份结束时间
#   2. 插 1 行 members 标记数据，切 WAL，取源实例快照（4 行）
#   3. 从同一份基础备份恢复出两个实例：
#      - 恢复到标记时间点之后（端口 5434）→ verify 应为 PASS
#      - 恢复到标记行插入之前（端口 5435）→ verify 应为 FAIL（行数不一致），
#        证明恢复确实按目标时间点切分数据
#   4. 在 5434 实例上删 1 行 members → verify 应为 FAIL，并指出 members 表（验收 2）
#   5. 逻辑备份恢复：#3174 备份脚本出当日备份 → logical_restore.sh 解密恢复到
#      临时库，行数与源库一致
#   6. 清理：停恢复实例、删临时库与临时目录；快照与报告拷进 evidence/
#
# 退出码：0 全部通过；1 任一步不符合预期。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S3174="$HOME/workspace/goals/20/hidden_files/clawhunt-hourly-build/3174/clawhunt-3174-pg-backup"
# /tmp 只有 512MB tmpfs：基础备份 + 两份恢复 + 归档约 280MB，刚够；
# 每轮开始清归档、结束清临时目录。/home 不支持 chown，nobody 跑的实例
# 目录放不了 workspace，只能放 /tmp。可用 PG3175_TEST_ROOT 覆盖。
TEST_ROOT="${PG3175_TEST_ROOT:-/tmp/pg3175-test}"
BASE_DIR="$TEST_ROOT/base"
AFTER_DIR="$TEST_ROOT/restored-after"
BEFORE_DIR="$TEST_ROOT/restored-before"
AFTER_PORT=5434
BEFORE_PORT=5435
FAIL=0

log() { echo "--- $*"; }

# --- 0. 搭环境 ---
log "step 0: setup #3174 local env + WAL archiving"
bash "$S3174/tests/setup_local_env.sh" >/dev/null
bash "$ROOT/tests/setup_local_pitr.sh" >/dev/null
# shellcheck disable=SC1091
source "$S3174/tests/local.env"
# shellcheck disable=SC1091
source "$ROOT/tests/local-pitr.env"
export PATH="$PGBIN:$PATH"
export PGBIN
PITR="$ROOT/ops/restore/pitr_restore.sh"
VERIFY="python3 $ROOT/ops/restore/verify_restore.py"
PSQL_SUPER="$PGBIN/psql -h 127.0.0.1 -p $PG3175_SOURCE_PORT -U postgres -d app_db -At"

stop_restored() { # 停掉之前残留的恢复实例（幂等；pg_ctl 须换 nobody 跑）
  local ctl=( "$PGBIN/pg_ctl" )
  [[ "$(id -u)" -eq 0 ]] && ctl=( runuser -u nobody -- "$PGBIN/pg_ctl" )
  for d in "$AFTER_DIR" "$BEFORE_DIR"; do
    if [[ -f "$d/postmaster.pid" ]]; then
      "${ctl[@]}" -D "$d" stop -m fast >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$BASE_DIR" "$AFTER_DIR" "$BEFORE_DIR"
  "$PGBIN/psql" -h 127.0.0.1 -p "$PG3175_SOURCE_PORT" -U postgres -d postgres -At \
    -c "DROP DATABASE IF EXISTS app_db_restored;" >/dev/null 2>&1 || true
}
stop_restored
mkdir -p "$TEST_ROOT"
chown nobody:nogroup "$TEST_ROOT" 2>/dev/null || chown nobody "$TEST_ROOT"
# 归档只留本轮的段：每轮都重新做基础备份，旧段恢复用不上；不清理会一直长大。
find "$PG3175_ARCHIVE_DIR" -type f -delete 2>/dev/null || true

# --- 1. 基础备份 ---
log "step 1: base backup"
BACKUP_OUT="$("$PITR" --local --local-base-backup-only \
  --local-source-port "$PG3175_SOURCE_PORT" \
  --local-target-dir "$BASE_DIR" \
  --local-archive-dir "$PG3175_ARCHIVE_DIR")"
echo "$BACKUP_OUT"
# shellcheck disable=SC1091
source "$BASE_DIR/pitr-meta.env"   # BACKUP_END_UTC
[[ -n "${BACKUP_END_UTC:-}" ]] || { echo "FAIL: no BACKUP_END_UTC recorded"; exit 1; }
echo "backup end (UTC): $BACKUP_END_UTC"

# --- 2. 插标记行（在备份结束 10 秒后，保证 TARGET_BEFORE 落在两者之间） ---
sleep 10
log "step 2: insert marker row + probe row + snapshot source"
$PSQL_SUPER -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO members (org_id, site_id, company_name, contact_name)
SELECT '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
       '虚构测试企业 D（PITR 标记行）', '测试联系人丁'
WHERE NOT EXISTS (
  SELECT 1 FROM members WHERE company_name = '虚构测试企业 D（PITR 标记行）');
SQL
"$PGBIN/psql" -h 127.0.0.1 -p "$PG3175_SOURCE_PORT" -U postgres -d postgres -At \
  -c "SELECT pg_switch_wal();" >/dev/null
# 探针行：恢复到目标时间需要 WAL 里有一条晚于目标时间的记录，否则恢复会
# 以“没达到目标时间”报错退出。探针写在 tables.yml 之外的表里，不影响快照。
# 标记行提交后 3 秒再写探针行，TARGET_AFTER 取两者之间。
sleep 3
$PSQL_SUPER -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE TABLE IF NOT EXISTS pitr_probe (id int PRIMARY KEY, note text, created_at timestamptz NOT NULL DEFAULT now());
-- id 用当前 epoch 秒，每轮都是新行、产生一条新的带时间戳的 WAL 记录。
INSERT INTO pitr_probe (id, note) VALUES (extract(epoch FROM now())::int, 'PITR probe row');
SQL
"$PGBIN/psql" -h 127.0.0.1 -p "$PG3175_SOURCE_PORT" -U postgres -d postgres -At \
  -c "SELECT pg_switch_wal();" >/dev/null
sleep 1
MARKER_EPOCH="$($PSQL_SUPER -c "SELECT extract(epoch FROM max(updated_at)) FROM members WHERE company_name = '虚构测试企业 D（PITR 标记行）';")"
BACKUP_EPOCH="$(date -d "$BACKUP_END_UTC" +%s)"
TARGET_AFTER_EPOCH="$(python3 -c "print(int(float('$MARKER_EPOCH')) + 2)")"
TARGET_BEFORE_EPOCH="$((BACKUP_EPOCH + 5))"
TARGET_AFTER_BJT="$(TZ=Asia/Shanghai date -d "@$TARGET_AFTER_EPOCH" '+%Y-%m-%d %H:%M:%S')"
TARGET_BEFORE_BJT="$(TZ=Asia/Shanghai date -d "@$TARGET_BEFORE_EPOCH" '+%Y-%m-%d %H:%M:%S')"
SNAP="$TEST_ROOT/snapshot-after.json"
PGHOST=127.0.0.1 PGPORT="$PG3175_SOURCE_PORT" PGUSER=postgres PGDATABASE=app_db \
  $VERIFY snapshot --tables "$ROOT/ops/restore/tables.yml" --out "$SNAP"
echo "source now: $($PSQL_SUPER -c 'SELECT count(*) FROM members') members, $($PSQL_SUPER -c 'SELECT count(*) FROM sop_items') sop_items"
echo "target before (Beijing): $TARGET_BEFORE_BJT  (backup end $BACKUP_END_UTC + 5s)"
echo "target after  (Beijing): $TARGET_AFTER_BJT  (marker commit + 2s)"

# --- 3. 两次恢复（共用同一份基础备份，先复制） ---
log "step 3: recover to two target times from the same base backup"
cp -r "$BASE_DIR" "$AFTER_DIR"
cp -r "$BASE_DIR" "$BEFORE_DIR"
# 复制品须归恢复实例的运行用户所有（cp 会留下当前用户的属主）。
chown -R nobody:nogroup "$AFTER_DIR" "$BEFORE_DIR" 2>/dev/null || chown -R nobody "$AFTER_DIR" "$BEFORE_DIR"
"$PITR" --local --local-recover-only \
  --local-target-dir "$AFTER_DIR" --local-target-port "$AFTER_PORT" \
  --local-archive-dir "$PG3175_ARCHIVE_DIR" \
  --target-time "$TARGET_AFTER_BJT"
"$PITR" --local --local-recover-only \
  --local-target-dir "$BEFORE_DIR" --local-target-port "$BEFORE_PORT" \
  --local-archive-dir "$PG3175_ARCHIVE_DIR" \
  --target-time "$TARGET_BEFORE_BJT"

# --- 3a. 恢复到标记时间点之后：应为 PASS ---
log "step 3a: verify restored-after (expect PASS)"
set +e
PGHOST=127.0.0.1 PGPORT="$AFTER_PORT" PGUSER=postgres PGDATABASE=app_db \
  $VERIFY verify --tables "$ROOT/ops/restore/tables.yml" --snapshot "$SNAP" \
  --report "$TEST_ROOT/verify-pass.json" --report-md "$TEST_ROOT/verify-pass.md"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then echo "PASS: restored-after verify PASS";
else echo "FAIL: restored-after verify should be PASS (exit $rc)"; FAIL=1; fi

# --- 3b. 恢复到标记行之前：应为 FAIL（members 行数 3 vs 4） ---
log "step 3b: verify restored-before (expect FAIL, members count mismatch)"
set +e
PGHOST=127.0.0.1 PGPORT="$BEFORE_PORT" PGUSER=postgres PGDATABASE=app_db \
  $VERIFY verify --tables "$ROOT/ops/restore/tables.yml" --snapshot "$SNAP" \
  --report "$TEST_ROOT/verify-fail-before.json" --report-md "$TEST_ROOT/verify-fail-before.md"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && grep -q '"members"' "$TEST_ROOT/verify-fail-before.json"; then
  echo "PASS: restored-before verify FAIL and names members"
else echo "FAIL: restored-before verify should FAIL naming members (exit $rc)"; FAIL=1; fi

# --- 4. 删 1 行：应为 FAIL 并指出 members（验收 2 后半） ---
log "step 4: delete 1 row on restored-after, verify again (expect FAIL naming members)"
"$PGBIN/psql" -h 127.0.0.1 -p "$AFTER_PORT" -U postgres -d app_db -q \
  -c "DELETE FROM members WHERE company_name = '虚构测试企业 D（PITR 标记行）';"
set +e
PGHOST=127.0.0.1 PGPORT="$AFTER_PORT" PGUSER=postgres PGDATABASE=app_db \
  $VERIFY verify --tables "$ROOT/ops/restore/tables.yml" --snapshot "$SNAP" \
  --report "$TEST_ROOT/verify-fail.json" --report-md "$TEST_ROOT/verify-fail.md"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["failed_tables"]==["members"], d["failed_tables"]' "$TEST_ROOT/verify-fail.json"; then
  echo "PASS: after delete, verify FAIL and failed_tables == [members]"
else echo "FAIL: after delete, verify should FAIL with failed_tables [members] (exit $rc)"; FAIL=1; fi

# --- 5. 逻辑备份恢复 ---
log "step 5: logical backup + logical restore"
TODAY_UTC="$(date -u +%F)"
BACKUP_TS="$(date -u +%Y%m%d%H%M)"
export BACKUP_TS
# shellcheck disable=SC1091
source "$S3174/tests/local.env"   # KMS_LOCAL_DIR / BACKUP_BUCKET_DIR / TEXTFILE_DIR
export PATH="$PGBIN:$PATH"
bash "$S3174/scripts/pg_logical_backup.sh" 2>&1 | tail -3
PGHOST=127.0.0.1 PGPORT="$PG3175_SOURCE_PORT" PGUSER=postgres \
  bash "$ROOT/ops/restore/logical_restore.sh" --env test --date "$TODAY_UTC" \
  --target-db app_db_restored --replace --tables "$ROOT/ops/restore/tables.yml" \
  2>&1 | tail -5
RESTORED_MEMBERS="$("$PGBIN/psql" -h 127.0.0.1 -p "$PG3175_SOURCE_PORT" -U postgres -d app_db_restored -At -c 'SELECT count(*) FROM members')"
RESTORED_SOP="$("$PGBIN/psql" -h 127.0.0.1 -p "$PG3175_SOURCE_PORT" -U postgres -d app_db_restored -At -c 'SELECT count(*) FROM sop_items')"
SOURCE_MEMBERS="$($PSQL_SUPER -c 'SELECT count(*) FROM members')"
SOURCE_SOP="$($PSQL_SUPER -c 'SELECT count(*) FROM sop_items')"
echo "logical restore counts: members $RESTORED_MEMBERS (source $SOURCE_MEMBERS), sop_items $RESTORED_SOP (source $SOURCE_SOP)"
if [[ "$RESTORED_MEMBERS" == "$SOURCE_MEMBERS" && "$RESTORED_SOP" == "$SOURCE_SOP" ]]; then
  echo "PASS: logical restore row counts match source"
else echo "FAIL: logical restore row counts differ"; FAIL=1; fi

# --- 6. 存证 + 清理 ---
log "step 6: save evidence + teardown"
mkdir -p "$ROOT/evidence"
cp "$SNAP" "$TEST_ROOT/verify-pass.json" "$TEST_ROOT/verify-pass.md" \
   "$TEST_ROOT/verify-fail-before.json" "$TEST_ROOT/verify-fail-before.md" \
   "$TEST_ROOT/verify-fail.json" "$TEST_ROOT/verify-fail.md" \
   "$ROOT/evidence/" 2>/dev/null || true
stop_restored
if [[ "$FAIL" -eq 0 ]]; then echo "test_local_drill: ALL PASS"; else echo "test_local_drill: FAILED"; exit 1; fi
