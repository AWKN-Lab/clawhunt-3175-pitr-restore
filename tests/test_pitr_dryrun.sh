#!/usr/bin/env bash
# test_pitr_dryrun.sh — pitr_restore.sh 参数校验与 dry-run（不调任何云 API）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/ops/restore/pitr_restore.sh"
FAIL=0

check() { # check <描述> <期望退出码> <命令...>
  local desc="$1" want="$2"; shift 2
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [[ "$rc" -eq "$want" ]]; then echo "PASS: $desc (exit $rc)";
  else echo "FAIL: $desc (want exit $want, got $rc)"; echo "$out" | head -5; FAIL=1; fi
}
check_contains() { # check_contains <描述> <子串> <命令...>
  local desc="$1" needle="$2"; shift 2
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [[ "$rc" -eq 0 && "$out" == *"$needle"* ]]; then echo "PASS: $desc";
  else echo "FAIL: $desc (rc=$rc)"; echo "$out" | head -8; FAIL=1; fi
}

# --- 参数校验：都应以退出码 2 拒绝 ---
check "缺 --target-time（云模式）" 2 "$SCRIPT" --env test --new-instance-name pitr-x
check "prod 环境拒绝" 2 "$SCRIPT" --env prod --target-time '2026-11-24 10:00:00' --new-instance-name pitr-x
check "非法实例名（大写）" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name Pitr-X
check "非法实例名（太短）" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name ab
check "非法目标时间" 2 "$SCRIPT" --env test --target-time 'not-a-time' --new-instance-name pitr-x
check "未来目标时间拒绝" 2 "$SCRIPT" --env test --target-time '2999-01-01 10:00:00' --new-instance-name pitr-x
check "超出保留期拒绝" 2 "$SCRIPT" --env test --target-time '2020-01-01 10:00:00' --new-instance-name pitr-x --retention-days 30
check "缺源实例 ID" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name pitr-x --bastion-cidr 203.0.113.10/32 --region cn-shanghai
check "缺堡垒机 CIDR" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name pitr-x --source-instance-id rm-xxxx --region cn-shanghai
check "非法堡垒机 CIDR" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name pitr-x --source-instance-id rm-xxxx --bastion-cidr 203.0.113.10 --region cn-shanghai
check "缺地域" 2 "$SCRIPT" --env test --target-time '2026-11-24 10:00:00' --new-instance-name pitr-x --source-instance-id rm-xxxx --bastion-cidr 203.0.113.10/32
check "未知参数拒绝" 2 "$SCRIPT" --bogus

# --- dry-run：北京时间 -> UTC 换算 + 将执行的调用（不调云 API） ---
check_contains "dry-run 打印 CloneDBInstance" "CloneDBInstance" \
  "$SCRIPT" --env test --target-time '2026-11-23 10:00:00' --new-instance-name pitr-drill-20261123 \
  --source-instance-id rm-xxxxxxxxxxxx --bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run
check_contains "dry-run 北京时间 10:00 转 UTC 02:00" "2026-11-23T02:00:00Z" \
  "$SCRIPT" --env test --target-time '2026-11-23 10:00:00' --new-instance-name pitr-drill-20261123 \
  --source-instance-id rm-xxxxxxxxxxxx --bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run
check_contains "dry-run 带时区输入换算一致" "2026-11-23T02:00:00Z" \
  "$SCRIPT" --env test --target-time '2026-11-23T10:00:00+08:00' --new-instance-name pitr-drill-20261123 \
  --source-instance-id rm-xxxxxxxxxxxx --bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run
check_contains "dry-run 打印白名单收紧调用" "ModifySecurityIps" \
  "$SCRIPT" --env test --target-time '2026-11-23 10:00:00' --new-instance-name pitr-drill-20261123 \
  --source-instance-id rm-xxxxxxxxxxxx --bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run
check_contains "dry-run 白名单只含堡垒机 CIDR" "203.0.113.10/32" \
  "$SCRIPT" --env test --target-time '2026-11-23 10:00:00' --new-instance-name pitr-drill-20261123 \
  --source-instance-id rm-xxxxxxxxxxxx --bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run

# --- 本地模式参数校验 ---
check "本地备份缺目标目录" 2 "$SCRIPT" --local --local-base-backup-only --local-archive-dir /tmp
check "本地恢复缺目标时间" 2 "$SCRIPT" --local --local-recover-only --local-target-dir /tmp/nope --local-archive-dir /tmp

[[ "$FAIL" -eq 0 ]] && echo "test_pitr_dryrun: ALL PASS" || { echo "test_pitr_dryrun: FAILED"; exit 1; }
