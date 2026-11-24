#!/usr/bin/env bash
# setup_local_pitr.sh — 给 #3174 的本地等价环境开 WAL 归档（PITR 本地演练用）。
#
# 前置：先跑 #3174 的 tests/setup_local_env.sh（起 PostgreSQL 16.2，端口 5433，
#   灌虚构种子：members 3 行、sop_items 2 行）。
# 本脚本只做一件事：给源实例开 archive_mode（wal_level=replica、
# archive_command 拷到 /tmp/pg3175-test/archive），并验证归档链路通。
# 标记行不在这里插——test_local_drill.sh 在基础备份之后才插标记行，
# 这样才能证明恢复按目标时间点切分数据。
#
# 幂等：配置已对、归档已通就不再重启。
# 注意：源实例数据目录在 /tmp/pg3174-test（服务重启会清空，setup 可重复搭）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S3174="$HOME/workspace/goals/20/hidden_files/clawhunt-hourly-build/3174/clawhunt-3174-pg-backup"
TEST_ROOT="${PG3175_TEST_ROOT:-/tmp/pg3175-test}"
ARCHIVE_DIR="$TEST_ROOT/archive"
PGDATA="/tmp/pg3174-test/data"
PORT="${PGPORT:-5433}"

# --- 确保 #3174 本地环境在跑 ---
if [[ ! -f "$S3174/tests/local.env" ]]; then
  echo "setup_local_pitr: 先跑 #3174 的 setup_local_env.sh ..." >&2
  bash "$S3174/tests/setup_local_env.sh" >/dev/null || exit 1
fi
# shellcheck disable=SC1091
source "$S3174/tests/local.env"
if [[ ! -x "$PGBIN/pg_ctl" ]]; then
  bash "$S3174/tests/setup_local_env.sh" >/dev/null || exit 1
  source "$S3174/tests/local.env"
fi
PORT="${PGPORT:-5433}"
"$PGBIN/pg_isready" -h 127.0.0.1 -p "$PORT" -q \
  || { echo "setup_local_pitr: 源实例不在跑" >&2; exit 1; }

mkdir -p "$ARCHIVE_DIR" "$TEST_ROOT"
# 归档命令以 nobody（源实例运行用户）跑，目录须归 nobody 所有。
chown -R nobody:nogroup "$TEST_ROOT" 2>/dev/null || chown -R nobody "$TEST_ROOT"
chmod 700 "$TEST_ROOT"

PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -d postgres -At"

archive_works() { # 切一次 WAL，看归档目录 5 秒内是否多出文件
  local before after
  before="$(ls "$ARCHIVE_DIR" 2>/dev/null | wc -l)"
  $PSQL -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || return 1
  sleep 2
  after="$(ls "$ARCHIVE_DIR" 2>/dev/null | wc -l)"
  [[ "$after" -gt "$before" ]]
}

if ! archive_works; then
  echo "setup_local_pitr: archiving not working, configuring + restarting source..."
  CONF="$PGDATA/postgresql.conf"
  set_conf() { # set_conf <key> <value>
    # 不用 sed 替换：值里可能含 &（archive_command 里有 &&），sed 会把 &
    # 当成“整个匹配”展开。改成删旧行再追加。
    local key="$1" val="$2"
    grep -vE "^[# ]*$key[[:space:]]*=" "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    echo "$key = $val" >> "$CONF"
  }
  set_conf wal_level replica
  set_conf archive_mode on
  set_conf archive_command "'test ! -f $ARCHIVE_DIR/%f && cp %p $ARCHIVE_DIR/%f'"
  set_conf max_wal_senders 3
  chown nobody:nogroup "$CONF" 2>/dev/null || chown nobody "$CONF"
  runuser -u nobody -- "$PGBIN/pg_ctl" -D "$PGDATA" -l "$TEST_ROOT/source-restart.log" restart >/dev/null
  "$PGBIN/pg_isready" -h 127.0.0.1 -p "$PORT" -q
  archive_works || { echo "setup_local_pitr: 归档仍不通，archive_command 没生效" >&2; exit 1; }
fi
echo "setup_local_pitr: archiving ok ($(ls "$ARCHIVE_DIR" | wc -l) files in $ARCHIVE_DIR)"

cat > "$ROOT/tests/local-pitr.env" <<EOF
# setup_local_pitr.sh 生成（本地 PITR 演练用）
export PG3175_TEST_ROOT="$TEST_ROOT"
export PG3175_ARCHIVE_DIR="$ARCHIVE_DIR"
export PG3175_SOURCE_PORT="$PORT"
EOF
echo "local pitr env written to $ROOT/tests/local-pitr.env"
