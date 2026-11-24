# 验收状态（ClawHunt #3175）

> 状态分三档：**通过**（已实测）、**本地通过**（本机等价环境实测通过，
> 不等于云上验收）、**未执行**（须真实云实例与堡垒机，本机没有）。
> 净额按报价 × 75%：报价 $130.50，净 $97.87（每单扣 $15 是算错的、作废）。

## 验收对照

| # | 验收标准（问题原文） | 状态 | 证据 |
|---|---|---|---|
| 1 | 在 test 环境完成一次时间点恢复到新实例，演练记录写明实际耗时 | **未执行** | 无真实云实例、无客户云账号与堡垒机。本机做了等价 PITR（`pg_basebackup` + `recovery_target_time` 恢复到新实例，见 `evidence/test-local-drill.log`），但那不是 test 环境云实例，不能冒充。真实演练须客户方按 `docs/restore-drill.md` 执行，记录补进 `docs/drills/` |
| 2 | 数据一致时 `verify_restore.py` 输出 PASS，人为删掉 1 行后输出 FAIL 并指出表名 | **本地通过** | 本地恢复实例实测：一致时 PASS；删 1 行 `members` 后 FAIL，报告列出 `members` 表（`evidence/test-local-drill.log`、`evidence/verify-pass.json`、`evidence/verify-fail.json`）。另有反向证明：恢复到标记行插入之前的时间点，FAIL（行数不一致） |
| 3 | 恢复出的临时实例白名单只含堡垒机网段（附截图） | **未执行** | 无真实云实例。脚本逻辑已写死：克隆后 `ModifySecurityIps` 全量替换为仅堡垒机 CIDR，再回读 `DescribeDBInstanceIPArrayList` 核对，不一致报错退出（退出码 5）；`--dry-run` 打印将执行的调用（`evidence/test-pitr-dryrun.log`）。截图须在真实演练时补 |
| 4 | 手册含删除临时实例的命令与演练记录模板 | **通过** | `docs/restore-drill.md` §3（删除命令，含删前确认清单）与 §4（演练记录模板） |

## 本轮实测（本地等价环境）

- `tests/run_all.sh`：参数校验与 dry-run、单元测试、本地完整演练，ALL PASS。
- 单元测试：`tests/.venv/bin/pytest tests/test_verify_restore_unit.py` ——
  tables.yml 解析、行哈希规范化、表比对逻辑。
- 本地 PITR：基础备份 → 插 1 行标记数据 → 快照 → 恢复到标记时间点 →
  PASS；删 1 行 → FAIL（`members`）；恢复到标记行之前 → FAIL。
- 逻辑恢复：#3174 备份脚本出当日备份 → `logical_restore.sh` 解密、
  sha256 核对、恢复到临时库，行数与源库一致。
- 云 API 参数核实：`CloneDBInstance`（`RestoreTime`，UTC，
  `yyyy-MM-ddTHH:mm:ssZ`，须 `BackupId` 或 `RestoreTime` 二选一；
  须源实例开日志备份；克隆实例继承源实例白名单）——阿里云官方文档，
  链接见 README 底部。

## 已核实的前提偏差

1. 克隆实例**继承源实例的白名单**（阿里云文档原话），所以“白名单只含堡垒机网段”
   不是克隆自带的，必须恢复后调 `ModifySecurityIps` 全量替换——脚本已这样做，
   并回读核对。
2. `CloneDBInstance` 的 `RestoreTime` 必须是 UTC，北京时间须换算——脚本自动换算，
   并在 dry-run 里同时打印两个时间。
3. 阿里云 RDS 的 PITR 要求源实例开日志备份（#3174 已配）；目标时间必须在
   日志保留期内——脚本按保留期（默认 30 天）校验，超期拒绝。

## 参考

- 阿里云 CloneDBInstance API 文档：
  https://www.alibabacloud.com/help/en/rds/api-restore-data-to-a-new-apsaradb-rds-instance
