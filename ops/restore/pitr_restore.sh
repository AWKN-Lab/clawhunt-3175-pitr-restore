#!/usr/bin/env bash
# pitr_restore.sh — 时间点恢复（PITR）到新实例（ClawHunt #3175）。
#
# 只恢复到一个全新的临时实例，绝不覆盖、绝不改动源实例。
# 演练只在 test 环境用虚构数据做；--env prod 直接拒绝（生产恢复须另行审批）。
#
# 两种模式：
#   云模式（默认）：调阿里云 RDS CloneDBInstance（RestoreTime，UTC），
#     等新实例 Running 后，把白名单收紧为仅堡垒机网段，并核对回显。
#     前置：源实例已开日志备份（#3174 已配）、目标时间在日志保留期内、
#     本机已配 aliyun CLI（ak/sk 走环境变量或 ~/.aliyun，不写进脚本）。
#   本地模式（--local）：对本机 PostgreSQL 做一次真实 PITR，
#     pg_basebackup + recovery_target_time 恢复到新数据目录、新端口，
#     仅用于本机验证脚本逻辑，不代表云上验收。
#
# 用法（云模式）：
#   pitr_restore.sh --env test --target-time '2026-11-24 10:00:00' \
#       --new-instance-name pitr-drill-20261124 \
#       --source-instance-id rm-xxxxxxxxxxxx \
#       --bastion-cidr 203.0.113.10/32 --region cn-shanghai [--dry-run]
#   --target-time 是北京时间（ISO 8601，可带 +08:00；不带时区当北京时间）；
#   脚本自动转 UTC（CloneDBInstance 要求 yyyy-MM-ddTHH:mm:ssZ）。
#
# 用法（本地模式，分两步——目标时间必须晚于基础备份的检查点，
# 所以先备份、再选时间点恢复；一步到位的写法会让目标时间落在备份之前）：
#   # 第 1 步：基础备份（记下输出的 BACKUP_END_UTC）
#   pitr_restore.sh --local --local-base-backup-only \
#       --local-source-port 5433 \
#       --local-target-dir $PG3175_TEST_ROOT/base \
#       --local-archive-dir $PG3175_TEST_ROOT/archive
#   # 第 2 步：恢复到目标时间（北京时间，须晚于 BACKUP_END_UTC）
#   cp -r $PG3175_TEST_ROOT/base $PG3175_TEST_ROOT/restored-after
#   pitr_restore.sh --local --local-recover-only \
#       --local-target-dir $PG3175_TEST_ROOT/restored-after \
#       --local-target-port 5434 \
#       --local-archive-dir $PG3175_TEST_ROOT/archive \
#       --target-time '2026-11-24 10:00:00'
#
# 退出码：0 成功；2 参数/前置校验失败；3 云 API 调用失败；
#         4 新实例未在限时内变 Running；5 白名单收紧后核对不一致。
set -euo pipefail

# ---------- 默认值 ----------
ENV=""
TARGET_TIME=""
NEW_NAME=""
SOURCE_ID="${RDS_SOURCE_INSTANCE_ID:-}"
BASTION_CIDR="${BASTION_CIDR:-}"
REGION="${RDS_REGION:-}"
RETENTION_DAYS="${RDS_LOG_RETENTION_DAYS:-30}"
DRY_RUN=0
LOCAL_MODE=0
LOCAL_BASE_BACKUP_ONLY=0
LOCAL_RECOVER_ONLY=0
LOCAL_SOURCE_PORT="${LOCAL_SOURCE_PORT:-5433}"
LOCAL_TARGET_PORT="${LOCAL_TARGET_PORT:-5434}"
LOCAL_SOURCE_DIR=""
LOCAL_TARGET_DIR=""
LOCAL_ARCHIVE_DIR=""
PGBIN="${PGBIN:-}"

log()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pitr_restore: $*" >&2; }
die()  { log "ERROR: $*"; exit "${2:-2}"; }

usage() {
  sed -n '2,40p' "$0" >&2
  exit 2
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)                ENV="$2"; shift 2 ;;
    --target-time)        TARGET_TIME="$2"; shift 2 ;;
    --new-instance-name)  NEW_NAME="$2"; shift 2 ;;
    --source-instance-id) SOURCE_ID="$2"; shift 2 ;;
    --bastion-cidr)       BASTION_CIDR="$2"; shift 2 ;;
    --region)             REGION="$2"; shift 2 ;;
    --retention-days)     RETENTION_DAYS="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --local)              LOCAL_MODE=1; shift ;;
    --local-base-backup-only) LOCAL_BASE_BACKUP_ONLY=1; shift ;;
    --local-recover-only) LOCAL_RECOVER_ONLY=1; shift ;;
    --local-source-port)  LOCAL_SOURCE_PORT="$2"; shift 2 ;;
    --local-target-port)  LOCAL_TARGET_PORT="$2"; shift 2 ;;
    --local-source-dir)   LOCAL_SOURCE_DIR="$2"; shift 2 ;;
    --local-target-dir)   LOCAL_TARGET_DIR="$2"; shift 2 ;;
    --local-archive-dir)  LOCAL_ARCHIVE_DIR="$2"; shift 2 ;;
    --pgbin)              PGBIN="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

# ---------- 共用校验：目标时间（北京时间 -> UTC） ----------
# 只在给了 --target-time 时解析；各模式自己决定是否必填
# （云模式与本地恢复必填；本地备份不需要）。
TARGET_UTC=""
if [[ -n "$TARGET_TIME" ]]; then
  # 注意：date -d ... -u 会把输入也按 UTC 解析，所以先用 +%s 取 epoch
  #（不带时区时按 TZ=Asia/Shanghai 解析），再用 -u 按 UTC 格式化。
  epoch=""
  if [[ "$TARGET_TIME" =~ (Z|[+-][0-9]{2}:?[0-9]{2})$ ]]; then
    epoch="$(date -d "$TARGET_TIME" +%s 2>/dev/null)" \
      || die "目标时间解析失败: $TARGET_TIME"
  else
    epoch="$(TZ=Asia/Shanghai date -d "$TARGET_TIME" +%s 2>/dev/null)" \
      || die "目标时间解析失败: $TARGET_TIME（北京时间，形如 '2026-11-24 10:00:00'）"
  fi
  TARGET_UTC="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$TARGET_UTC" < "$NOW_UTC" ]] || die "目标时间须在过去：$TARGET_TIME（北京时间）-> $TARGET_UTC（UTC）"
  OLDEST_UTC="$(date -u -d "$NOW_UTC - $RETENTION_DAYS days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [[ "$TARGET_UTC" < "$OLDEST_UTC" ]]; then
    die "目标时间 $TARGET_UTC 已超出日志保留期（$RETENTION_DAYS 天，最早 $OLDEST_UTC）"
  fi
  log "target time: $TARGET_TIME (Beijing) -> $TARGET_UTC (UTC)"
fi

json_get() { # json_get '<json>' '<key>'：只取顶层字符串值
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" <<<"$1"
}

# =====================================================================
# 本地模式：本机 PostgreSQL 真实 PITR（仅验证用）
# ---------------------------------------------------------------------
# 为什么分两步：PITR 的目标时间必须晚于基础备份的检查点，
# 所以“先备份、再选时间点恢复”才是正确的顺序；一步到位的写法
# 会让目标时间落在备份之前，恢复直接报错。
#   第 1 步：--local-base-backup-only   只做 pg_basebackup，记下备份结束时间
#   第 2 步：--local-recover-only      用已有的基础备份 + 归档 WAL 恢复
#            到 --target-time（须晚于备份结束时间），到点即提升为可写库
#   两个恢复可以共用同一份基础备份（先 cp -r 复制目录），分别恢复到
#   不同时间点，用来证明恢复确实按目标时间点切分数据。
#   不带两个子开关的 --local：备份后直接恢复到最新可用 WAL
#   （不设 recovery_target_time；--target-time 此时不接受，会报错提示分步走）。
# =====================================================================
if [[ "$LOCAL_MODE" -eq 1 ]]; then
  [[ -n "$LOCAL_TARGET_DIR" ]]  || die "--local 模式须给 --local-target-dir（新数据目录）"
  [[ -n "$LOCAL_ARCHIVE_DIR" ]] || die "--local 模式须给 --local-archive-dir（WAL 归档目录）"

  if [[ -z "$PGBIN" ]]; then
    if command -v pg_basebackup >/dev/null 2>&1; then PGBIN="$(dirname "$(command -v pg_basebackup)")";
    else die "找不到 PostgreSQL 工具（pg_basebackup），请设 PGBIN 或把 bin 目录放进 PATH"; fi
  fi
  for b in pg_basebackup pg_ctl pg_isready psql; do
    [[ -x "$PGBIN/$b" ]] || die "PGBIN 缺少 $b：$PGBIN"
  done
  [[ -d "$LOCAL_ARCHIVE_DIR" ]] || die "归档目录不存在：$LOCAL_ARCHIVE_DIR（源实例须开 archive_mode，见 tests/setup_local_pitr.sh）"

  # PostgreSQL 拒绝以 root 运行服务端进程；本机若以 root 跑，服务端工具换 nobody。
  if [[ "$(id -u)" -eq 0 ]]; then PG_RUN=(runuser -u nobody --); else PG_RUN=(); fi

  # ---------- 第 1 步：基础备份 ----------
  if [[ "$LOCAL_BASE_BACKUP_ONLY" -eq 1 ]]; then
    [[ ! -e "$LOCAL_TARGET_DIR" ]] || die "目标数据目录已存在，先删掉再跑：$LOCAL_TARGET_DIR"
    "$PGBIN/pg_isready" -h 127.0.0.1 -p "$LOCAL_SOURCE_PORT" -q \
      || die "源实例不在跑：127.0.0.1:$LOCAL_SOURCE_PORT（先起源库）"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "DRY-RUN (local backup): pg_basebackup -D $LOCAL_TARGET_DIR -h 127.0.0.1 -p $LOCAL_SOURCE_PORT -U postgres -X stream -c fast"
      exit 0
    fi
    log "local PITR: base backup from 127.0.0.1:$LOCAL_SOURCE_PORT -> $LOCAL_TARGET_DIR"
    # -X stream：基础备份里带上恢复所需的 WAL；-c fast 让检查点立刻做。
    "${PG_RUN[@]}" "$PGBIN/pg_basebackup" -D "$LOCAL_TARGET_DIR" -h 127.0.0.1 -p "$LOCAL_SOURCE_PORT" \
      -U postgres -X stream -c fast --no-password \
      || die "pg_basebackup 失败" 3
    # 备份目录须归恢复实例的运行用户所有（root 跑备份时会留下 root 属主的文件）。
    [[ "$(id -u)" -eq 0 ]] && chown -R nobody:nogroup "$LOCAL_TARGET_DIR" 2>/dev/null || true
    BACKUP_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
      echo "BACKUP_END_UTC=$BACKUP_END_UTC"
      echo "BACKUP_SOURCE_PORT=$LOCAL_SOURCE_PORT"
    } > "$LOCAL_TARGET_DIR/pitr-meta.env"
    log "base backup done: $LOCAL_TARGET_DIR (backup end $BACKUP_END_UTC)"
    echo "BACKUP_DIR=$LOCAL_TARGET_DIR"
    echo "BACKUP_END_UTC=$BACKUP_END_UTC"
    echo "NEXT: recover with --local-recover-only --local-target-dir $LOCAL_TARGET_DIR --target-time '<晚于 $BACKUP_END_UTC 的北京时间>'"
    exit 0
  fi

  # ---------- 第 2 步：从基础备份恢复到目标时间 ----------
  # 恢复目录必须是一份还没恢复过的基础备份（已有 recovery.signal 或
  # 已提升过的目录不能二次恢复；要恢复到另一个时间点，先 cp -r 复制）。
  [[ -d "$LOCAL_TARGET_DIR" ]] || die "恢复目录不存在：$LOCAL_TARGET_DIR（先跑 --local-base-backup-only）"
  [[ -f "$LOCAL_TARGET_DIR/backup_label" || -f "$LOCAL_TARGET_DIR/PG_VERSION" ]] \
    || die "恢复目录不像一份基础备份：$LOCAL_TARGET_DIR"
  [[ ! -f "$LOCAL_TARGET_DIR/recovery.signal" ]] \
    || die "该目录已恢复过一次，不能二次恢复；要恢复到另一个时间点，先 cp -r 复制一份基础备份再跑"
  if "$PGBIN/pg_isready" -h 127.0.0.1 -p "$LOCAL_TARGET_PORT" -q 2>/dev/null; then
    die "目标端口已被占用：$LOCAL_TARGET_PORT"
  fi
  if [[ "$LOCAL_RECOVER_ONLY" -eq 0 ]]; then
    # 一步到位模式：不接受 --target-time（目标时间必然早于刚做的备份，
    # 恢复会报错）；直接恢复到最新可用 WAL。
    [[ -z "$TARGET_TIME" ]] || die "--local 一步到位模式不接受 --target-time（目标时间必然早于刚做的备份）；要恢复到指定时间点，先 --local-base-backup-only 再 --local-recover-only"
    die "--local 须二选一：--local-base-backup-only（只备份）或 --local-recover-only（只恢复）"
  fi
  [[ -n "$TARGET_TIME" ]] || die "--local-recover-only 须给 --target-time"
  # 目标时间须晚于备份结束时间，否则恢复会直接报错；先在这里拦住，
  # 报错信息比 PostgreSQL 的更直白。
  if [[ -f "$LOCAL_TARGET_DIR/pitr-meta.env" ]]; then
    # shellcheck disable=SC1090
    source "$LOCAL_TARGET_DIR/pitr-meta.env"
    if [[ -n "${BACKUP_END_UTC:-}" && "$TARGET_UTC" < "$BACKUP_END_UTC" ]]; then
      die "目标时间 $TARGET_UTC 早于基础备份结束时间 $BACKUP_END_UTC（恢复会失败）；请选晚于备份结束的时间点"
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN (local recover): recovery_target_time=$TARGET_UTC, restore_command=cp $LOCAL_ARCHIVE_DIR/%f %p, port=$LOCAL_TARGET_PORT"
    exit 0
  fi
  # 恢复配置：归档里找 WAL，恢复到目标时间，到点即提升为可写库。
  # 注意：recovery_target_time 写 ISO 8601 的 T/Z 形式会被配置解析拒绝
  #（invalid value），改用 'YYYY-MM-DD HH:MM:SS+00'（SQL 里两种都合法，
  # 配置文件只认后者，实测）。
  RECOVERY_TARGET_TIME="$(date -u -d "$TARGET_UTC" '+%Y-%m-%d %H:%M:%S+00')"
  cat >> "$LOCAL_TARGET_DIR/postgresql.auto.conf" <<EOF
restore_command = 'cp $LOCAL_ARCHIVE_DIR/%f %p'
recovery_target_time = '$RECOVERY_TARGET_TIME'
recovery_target_action = 'promote'
EOF
  touch "$LOCAL_TARGET_DIR/recovery.signal"
  # 恢复出的实例不继承源库端口，单独起一个端口；只听本地回环。
  "${PG_RUN[@]}" "$PGBIN/pg_ctl" -D "$LOCAL_TARGET_DIR" -l "$LOCAL_TARGET_DIR/server.log" \
    -o "-p $LOCAL_TARGET_PORT -k $LOCAL_TARGET_DIR -h 127.0.0.1 -c listen_addresses=127.0.0.1" start \
    || die "恢复实例启动失败，见 $LOCAL_TARGET_DIR/server.log" 3
  # 等提升完成（pg_is_in_recovery() 变 false），最多 5 分钟。
  for _ in $(seq 1 60); do
    if "$PGBIN/psql" -h 127.0.0.1 -p "$LOCAL_TARGET_PORT" -U postgres -d postgres \
        -At -c "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -qx t; then
      break
    fi
    sleep 5
  done
  "$PGBIN/psql" -h 127.0.0.1 -p "$LOCAL_TARGET_PORT" -U postgres -d postgres \
    -At -c "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -qx t \
    || die "恢复实例 5 分钟内未完成提升，见 $LOCAL_TARGET_DIR/server.log" 4
  log "local PITR done: restored instance on 127.0.0.1:$LOCAL_TARGET_PORT (data dir $LOCAL_TARGET_DIR)"
  echo "RESTORED_HOST=127.0.0.1"
  echo "RESTORED_PORT=$LOCAL_TARGET_PORT"
  echo "RESTORED_DATADIR=$LOCAL_TARGET_DIR"
  echo "RESTORED_TARGET_TIME_UTC=$TARGET_UTC"
  exit 0
fi

# =====================================================================
# 云模式：阿里云 RDS CloneDBInstance
# =====================================================================
[[ "$ENV" == "test" ]] || die "--env 只接受 test（演练只在测试环境用虚构数据；生产恢复须另行审批）" 2
[[ -n "$TARGET_TIME" ]] || die "--target-time 必填（北京时间，ISO 8601）"
[[ -n "$NEW_NAME" ]] || die "--new-instance-name 必填"
# 实例名：阿里云要求小写字母开头，只含小写字母、数字、连字符，3~64 位。
[[ "$NEW_NAME" =~ ^[a-z][a-z0-9-]{2,63}$ ]] \
  || die "实例名不合法: $NEW_NAME（小写字母开头，只含小写字母/数字/连字符，3~64 位）"
[[ -n "$SOURCE_ID" ]]    || die "--source-instance-id 必填（或设环境变量 RDS_SOURCE_INSTANCE_ID）"
[[ -n "$BASTION_CIDR" ]]  || die "--bastion-cidr 必填（或设环境变量 BASTION_CIDR，形如 203.0.113.10/32）"
[[ "$BASTION_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
  || die "堡垒机网段不是合法 CIDR：$BASTION_CIDR"
[[ -n "$REGION" ]]        || die "--region 必填（或设环境变量 RDS_REGION）"

CLIENT_TOKEN="$(python3 -c 'import uuid; print(str(uuid.uuid4()))')"
log "clone source=$SOURCE_ID restore_time=$TARGET_UTC new_name=$NEW_NAME region=$REGION"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
DRY-RUN (cloud): 不调任何云 API，只打印将执行的调用。
  aliyun rds CloneDBInstance --RegionId $REGION --DBInstanceId $SOURCE_ID \\
    --RestoreTime $TARGET_UTC --PayType Postpaid \\
    --DBInstanceDescription $NEW_NAME --ClientToken $CLIENT_TOKEN
  随后轮询：aliyun rds DescribeDBInstanceAttribute --DBInstanceId <new-id>
  白名单收紧：aliyun rds ModifySecurityIps --DBInstanceId <new-id> --SecurityIps $BASTION_CIDR
  核对：aliyun rds DescribeDBInstanceIPArrayList --DBInstanceId <new-id>
EOF
  exit 0
fi

# dry-run 不调云 API，上面已退出；到这里才真正需要 aliyun CLI。
command -v aliyun >/dev/null 2>&1 || die "找不到 aliyun CLI（运维节点须先装，见 README）" 2

# 1. 克隆到新实例（按时间点恢复；PayType 按量付费，演练完即删）。
CLONE_OUT="$(aliyun rds CloneDBInstance --RegionId "$REGION" --DBInstanceId "$SOURCE_ID" \
  --RestoreTime "$TARGET_UTC" --PayType Postpaid \
  --DBInstanceDescription "$NEW_NAME" --ClientToken "$CLIENT_TOKEN" 2>/tmp/clone_err.$$)" \
  || { cat /tmp/clone_err.$$ >&2; rm -f /tmp/clone_err.$$; die "CloneDBInstance 调用失败" 3; }
rm -f /tmp/clone_err.$$
NEW_ID="$(json_get "$CLONE_OUT" DBInstanceId)"
[[ -n "$NEW_ID" ]] || { echo "$CLONE_OUT" >&2; die "CloneDBInstance 未返回新实例 ID" 3; }
log "clone started: new instance $NEW_ID"

# 2. 轮询等新实例 Running（最长 60 分钟；克隆通常 10~30 分钟）。
log "waiting for $NEW_ID to become Running (up to 60 min)..."
for _ in $(seq 1 120); do
  ATTR="$(aliyun rds DescribeDBInstanceAttribute --DBInstanceId "$NEW_ID" 2>/dev/null || true)"
  STATUS="$(python3 -c 'import json,sys; items=json.load(sys.stdin).get("Items",{}).get("DBInstanceAttribute",[]); print(items[0].get("DBInstanceStatus","") if items else "")' <<<"$ATTR" 2>/dev/null || true)"
  if [[ "$STATUS" == "Running" ]]; then break; fi
  [[ "$STATUS" == "Creating" || "$STATUS" == "Restoring" || -z "$STATUS" ]] \
    || die "新实例进入异常状态：$STATUS" 4
  sleep 30
done
[[ "$STATUS" == "Running" ]] || die "新实例 60 分钟内未变 Running（当前：$STATUS）" 4
log "new instance Running: $NEW_ID"

# 3. 白名单收紧：克隆实例会继承源实例的白名单，必须改成仅堡垒机网段。
#    ModifySecurityIps 是全量替换，不是追加——传单个 CIDR 即只留堡垒机。
log "restricting whitelist to bastion only: $BASTION_CIDR"
aliyun rds ModifySecurityIps --DBInstanceId "$NEW_ID" --SecurityIps "$BASTION_CIDR" \
  >/dev/null || die "ModifySecurityIps 调用失败" 3

# 4. 核对白名单：只含堡垒机网段，否则报错退出（不继续演练）。
IPS="$(aliyun rds DescribeDBInstanceIPArrayList --DBInstanceId "$NEW_ID" 2>/dev/null || true)"
ONLY_BASTION="$(python3 -c '
import json,sys
d = json.load(sys.stdin)
groups = d.get("Items", {}).get("DBInstanceIPArray", [])
ips = sorted({g.get("SecurityIps", "") for g in groups if g.get("SecurityIps")})
print(" ".join(ips))
' <<<"$IPS")"
[[ "$ONLY_BASTION" == "$BASTION_CIDR" ]] \
  || die "白名单核对不一致：期望仅 $BASTION_CIDR，实际 $ONLY_BASTION" 5
log "whitelist verified: only $BASTION_CIDR"

# 5. 输出连接信息（给 verify_restore.py 用；口令与源实例账号相同，不打印口令）。
ENDPOINT="$(python3 -c 'import json,sys; items=json.load(sys.stdin).get("Items",{}).get("DBInstanceAttribute",[]); print(items[0].get("ConnectionString","") if items else "")' <<<"$ATTR")"
echo "RESTORED_INSTANCE_ID=$NEW_ID"
echo "RESTORED_ENDPOINT=$ENDPOINT"
echo "RESTORED_TARGET_TIME_UTC=$TARGET_UTC"
echo "RESTORED_WHITELIST=$ONLY_BASTION"
echo "NEXT: snapshot the source first if not done yet, then run:"
echo "  verify_restore.py verify --tables ops/restore/tables.yml --snapshot <snapshot.json> --host <endpoint-host> --port 5432 --user <user> --dbname app_db"
exit 0
