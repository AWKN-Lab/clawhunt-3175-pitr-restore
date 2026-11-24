#!/usr/bin/env bash
# run_all.sh — #3175 全部本地验证一键跑（参数校验 + 单元测试 + 本地完整演练）。
# 实测输出进 evidence/（test-pitr-dryrun.log / test-unit.log / test-local-drill.log）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/evidence"

echo "=== 1. pitr_restore.sh 参数校验与 dry-run ==="
bash "$ROOT/tests/test_pitr_dryrun.sh" 2>&1 | tee "$ROOT/evidence/test-pitr-dryrun.log"

echo "=== 2. verify_restore.py 单元测试 ==="
if ! "$ROOT/tests/.venv/bin/python" -c "import pytest" 2>/dev/null; then
  echo "(bootstrapping tests/.venv: python3 -m venv + pip install pytest)"
  python3 -m venv "$ROOT/tests/.venv"
  "$ROOT/tests/.venv/bin/pip" install -q pytest
fi
"$ROOT/tests/.venv/bin/pytest" "$ROOT/tests/test_verify_restore_unit.py" -q 2>&1 | tee "$ROOT/evidence/test-unit.log"

echo "=== 3. 本地完整演练（PITR + 校验 PASS/FAIL + 逻辑恢复） ==="
bash "$ROOT/tests/test_local_drill.sh" 2>&1 | tee "$ROOT/evidence/test-local-drill.log"

echo "run_all: ALL PASS"
