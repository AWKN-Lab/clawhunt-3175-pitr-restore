#!/usr/bin/env bash
# logical_restore.sh — 从 backups 桶取指定日期的 pg_dump 文件，解密后恢复到临时库
# （ClawHunt #3175；与 #3174 pg_logical_backup.sh 的加密信封格式配套）。
#
# 流程：
#   1. 在 backups 桶 pg-logical/ 下找指定日期最新的 app_db_<env>_*.dump.enc
#      及其同名 .meta.json
#   2. 解密（AES-256-CBC；密钥来自 KMS Decrypt 或本地等价 KMS 目录），
#      并用 meta 里的 dump_sha256 核对解密结果
#   3. 建临时库（已存在时拒绝，除非 --replace），pg_restore -Fc 恢复
#   4. 打印各表行数（--tables 时对照 tables.yml 逐表打印）
#
# 加密信封（与 #3174 一致）：openssl enc -aes-256-cbc -K <数据密钥 hex>
#   -iv <meta.iv_hex>；meta 里还有 kms_key_id 与密文 blob。
#   本地等价模式：数据密钥就是 $KMS_LOCAL_DIR/datakeys/<key-id>.bin 的原文；
#   真实模式：调 aliyun kms Decrypt 解 meta 里的 kms_ciphertext_blob_b64，
#   返回的 Plaintext（base64）即数据密钥。
#
# 只在 test 环境用虚构数据演练；--env prod 直接拒绝。
# 恢复目标永远是新建的临时库，不碰原库。
#
# 用法：
#   logical_restore.sh --env test --date 2026-11-24 --target-db app_db_restored
#   环境变量：PGHOST/PGPORT/PGUSER（默认 app_ro；须对目标库有建库/写权限，
#     本地验证用 postgres 超级用户，见 tests/）
#     BACKUP_STORE local|oss（默认 local）、BACKUP_BUCKET_DIR、OSS_BUCKET、
#     KMS_KEY_ID（默认 app-db-backup-key）、KMS_LOCAL_DIR（设了走本地等价 KMS）
#
# 退出码：0 成功；2 参数/前置失败；3 下载或解密失败；4 恢复失败。
set -euo pipefail

ENV=""
DATE=""
TARGET_DB=""
REPLACE=0
TABLES_YML=""
BACKUP_STORE="${BACKUP_STORE:-local}"
BACKUP_BUCKET_DIR="${BACKUP_BUCKET_DIR:-./backups-bucket}"
OSS_BUCKET="${OSS_BUCKET:-}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-shanghai.aliyuncs.com}"
KMS_KEY_ID="${KMS_KEY_ID:-app-db-backup-key}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-app_ro}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) logical_restore: $*" >&2; }
die() { log "ERROR: $*"; exit "${2:-2}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)       ENV="$2"; shift 2 ;;
    --date)      DATE="$2"; shift 2 ;;
    --target-db) TARGET_DB="$2"; shift 2 ;;
    --replace)   REPLACE=1; shift ;;
    --tables)    TABLES_YML="$2"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0" >&2; exit 2 ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[[ "$ENV" == "test" ]] || die "--env 只接受 test（演练只在测试环境用虚构数据）"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date 须是 YYYY-MM-DD：$DATE"
[[ -n "$TARGET_DB" ]] || die "--target-db 必填（新建的临时库名）"
[[ "$TARGET_DB" =~ ^[a-z_][a-z0-9_]*$ ]] || die "临时库名不合法：$TARGET_DB"
if command -v pg_restore >/dev/null 2>&1; then PGBIN="$(dirname "$(command -v pg_restore)")";
elif [[ -n "${PGBIN:-}" && -x "$PGBIN/pg_restore" ]]; then :;
else die "找不到 pg_restore（请设 PGBIN 或把 PostgreSQL bin 目录放进 PATH）"; fi
for b in pg_restore psql createdb dropdb; do
  [[ -x "$PGBIN/$b" ]] || die "PGBIN 缺少 $b：$PGBIN"
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------- 1. 找备份文件 ----------
DATE_COMPACT="${DATE//-/}"
case "$BACKUP_STORE" in
  local)
    [[ -d "$BACKUP_BUCKET_DIR/pg-logical" ]] || die "本地桶目录不存在：$BACKUP_BUCKET_DIR/pg-logical"
    ENC_FILE="$(ls -1 "$BACKUP_BUCKET_DIR"/pg-logical/app_db_"${ENV}"_"${DATE_COMPACT}"*.dump.enc 2>/dev/null | sort | tail -n 1 || true)"
    [[ -n "$ENC_FILE" ]] || die "本地桶里没有 $DATE 的备份：$BACKUP_BUCKET_DIR/pg-logical/app_db_${ENV}_${DATE_COMPACT}*.dump.enc"
    META_FILE="${ENC_FILE%.dump.enc}.meta.json"
    [[ -f "$META_FILE" ]] || die "备份缺 meta 文件：$META_FILE"
    cp "$ENC_FILE" "$WORKDIR/backup.dump.enc"
    cp "$META_FILE" "$WORKDIR/backup.meta.json"
    ;;
  oss)
    [[ -n "$OSS_BUCKET" ]] || die "oss 模式须设 OSS_BUCKET"
    command -v ossutil >/dev/null 2>&1 || die "找不到 ossutil"
    ENC_NAME="$(ossutil ls "oss://$OSS_BUCKET/pg-logical/" -e "$OSS_ENDPOINT" 2>/dev/null \
      | grep -o "app_db_${ENV}_${DATE_COMPACT}[0-9]*\.dump\.enc" | sort | tail -n 1 || true)"
    [[ -n "$ENC_NAME" ]] || die "OSS 桶里没有 $DATE 的备份"
    ossutil cp "oss://$OSS_BUCKET/pg-logical/$ENC_NAME" "$WORKDIR/backup.dump.enc" -e "$OSS_ENDPOINT" \
      || die "下载备份失败：$ENC_NAME" 3
    ossutil cp "oss://$OSS_BUCKET/pg-logical/${ENC_NAME%.dump.enc}.meta.json" "$WORKDIR/backup.meta.json" -e "$OSS_ENDPOINT" \
      || die "下载 meta 失败" 3
    ;;
  *) die "未知 BACKUP_STORE：$BACKUP_STORE（local|oss）" ;;
esac
log "backup file: $(basename "$WORKDIR/backup.dump.enc")"

# ---------- 2. 解密并核对 sha256 ----------
IV_HEX="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["iv_hex"])' "$WORKDIR/backup.meta.json")"
EXPECT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dump_sha256"])' "$WORKDIR/backup.meta.json")"
META_KEY_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kms_key_id"])' "$WORKDIR/backup.meta.json")"
[[ -n "$IV_HEX" && -n "$EXPECT_SHA" ]] || die "meta 文件缺 iv_hex 或 dump_sha256"
[[ "$META_KEY_ID" == "$KMS_KEY_ID" ]] || log "注意：meta 里的 kms_key_id=$META_KEY_ID，与当前 KMS_KEY_ID=$KMS_KEY_ID 不同，仍按 meta 的 key id 解密"
KEY_ID="$META_KEY_ID"

KEY_HEX=""
if [[ -n "${KMS_LOCAL_DIR:-}" ]]; then
  # 本地等价 KMS：数据密钥原文就在 datakeys/<key-id>.bin（32 字节）。
  DK="$KMS_LOCAL_DIR/datakeys/$KEY_ID.bin"
  [[ -f "$DK" ]] || die "本地 KMS 缺数据密钥：$DK" 3
  KEY_HEX="$(python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], "rb").read().hex())' "$DK")"
  log "decrypt key from local KMS dir: $DK"
else
  # 真实 KMS：meta 里 kms_ciphertext_blob_b64 是 GenerateDataKey 的密文，
  # 调 Decrypt 拿回明文数据密钥（base64）。
  command -v aliyun >/dev/null 2>&1 || die "真实 KMS 模式须装 aliyun CLI" 3
  BLOB="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kms_ciphertext_blob_b64"])' "$WORKDIR/backup.meta.json")"
  [[ -n "$BLOB" ]] || die "meta 里没有 kms_ciphertext_blob_b64" 3
  DEC_OUT="$(aliyun kms Decrypt --CiphertextBlob "$BLOB" 2>/tmp/kms_dec_err.$$)" \
    || { cat /tmp/kms_dec_err.$$ >&2; rm -f /tmp/kms_dec_err.$$; die "KMS Decrypt 失败" 3; }
  rm -f /tmp/kms_dec_err.$$
  KEY_HEX="$(python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["Plaintext"]).hex())' <<<"$DEC_OUT")"
  log "decrypt key from real KMS (key id $KEY_ID)"
fi

DUMP="$WORKDIR/backup.dump"
openssl enc -d -aes-256-cbc -K "$KEY_HEX" -iv "$IV_HEX" \
  -in "$WORKDIR/backup.dump.enc" -out "$DUMP" 2>"$WORKDIR/dec.err" \
  || { cat "$WORKDIR/dec.err" >&2; die "解密失败（密钥或 iv 不对）" 3; }
ACTUAL_SHA="$(sha256sum "$DUMP" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECT_SHA" ]] \
  || die "解密后 sha256 与 meta 不符：期望 $EXPECT_SHA，实际 $ACTUAL_SHA（文件可能损坏）" 3
log "decrypt ok: sha256 matches meta ($ACTUAL_SHA)"

# ---------- 3. 恢复到临时库 ----------
export PGPASSWORD="${PGPASSWORD:-}"
DB_EXISTS="$("$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -At \
  -c "SELECT count(*) FROM pg_database WHERE datname = '$TARGET_DB'" 2>/dev/null || echo "?")"
if [[ "$DB_EXISTS" == "1" ]]; then
  if [[ "$REPLACE" -eq 1 ]]; then
    log "target database $TARGET_DB exists, dropping (--replace)"
    "$PGBIN/dropdb" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$TARGET_DB" \
      || die "删旧临时库失败" 4
  else
    die "临时库已存在：$TARGET_DB（加 --replace 才会先删再建）"
  fi
fi
"$PGBIN/createdb" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$TARGET_DB" \
  || die "建临时库失败" 4
"$PGBIN/pg_restore" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$TARGET_DB" \
  --no-owner --no-privileges "$DUMP" 2>"$WORKDIR/restore.err" \
  || { cat "$WORKDIR/restore.err" >&2; die "pg_restore 失败" 4; }
log "restored into database: $TARGET_DB"

# ---------- 4. 行数打印 ----------
if [[ -n "$TABLES_YML" ]]; then
  export TARGET_DB PGBIN
  python3 - "$TABLES_YML" <<'PYEOF'
import re, subprocess, sys, os
tables = []
cur = None
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line.startswith("  - name:"):
        if cur: tables.append(cur)
        cur = line.split(":", 1)[1].strip()
    elif line.strip() == "tables:":
        continue
for t in ([cur] if cur else []):
    tables.append(t)
env = dict(os.environ)
for t in tables:
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_.]*$", t):
        print(f"skip illegal table name: {t}", file=sys.stderr); continue
    p = subprocess.run([os.path.join(os.environ.get("PGBIN",""), "psql") if os.environ.get("PGBIN") else "psql",
                        "-X", "--no-psqlrc", "-At", "-h", os.environ.get("PGHOST","localhost"),
                        "-p", os.environ.get("PGPORT","5432"), "-U", os.environ.get("PGUSER","app_ro"),
                        "-d", os.environ["TARGET_DB"],
                        "-c", f'SELECT count(*) FROM "{t}" WHERE deleted_at IS NULL'],
                       capture_output=True, text=True, env=env)
    print(f"{t}: {p.stdout.strip() or '?'} rows (not soft-deleted)")
PYEOF
fi
echo "RESTORED_DB=$TARGET_DB"
echo "RESTORED_FROM=$(basename "$WORKDIR/backup.dump.enc")"
exit 0
