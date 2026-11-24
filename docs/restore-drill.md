# 时间点恢复（PITR）演练手册

> ClawHunt #3175 · 每季度演练 1 次 · 只在 test 环境用虚构数据演练。
> RTO 目标 ≤ 2 小时（从发现需要恢复，到临时实例可提供校验通过的数据）。
> 本手册的命令默认在运维节点上跑；本机无云账号、无堡垒机时，
> 云上步骤做不了，见 §7「未执行项」。

## 1. 演练前置条件

| 项 | 要求 | 核对方法 |
|---|---|---|
| 源实例日志备份 | 已开启，且保留期 ≥ 30 天 | #3174 的 Terraform：`backup_retention_period` 与日志备份开启；`DescribeDBInstanceAttribute` 看 `LogBackupRetentionPeriod` |
| 目标时间 | 在日志保留期内，且已过去 | `pitr_restore.sh` 会自动校验，超期直接拒绝 |
| 堡垒机网段 | 已知 CIDR（如 `203.0.113.10/32`），且堡垒机能连新实例 | 找运维确认，不要猜 |
| 演练账号 | RAM 子账号，只有 `rds:CloneDBInstance`、`rds:Describe*`、`rds:ModifySecurityIps`、`rds:DeleteDBInstance` | 最小权限，不给改源实例的权限 |
| 校验快照 | 演练前刚在源实例取过 | `verify_restore.py snapshot --tables ops/restore/tables.yml --out snapshot-<日期>.json` |

演练前先取快照（快照时间记进演练记录；目标时间一般取快照后 1 分钟内，
保证快照与恢复点之间源实例没有新写入——演练期间暂停 test 环境写入，
或选业务低峰时段）。

```bash
# 在源实例取快照（连接信息按真实环境填；口令走环境变量，不写进命令历史）
export PGHOST=<源实例内网地址> PGPORT=5432 PGUSER=<只读账号> PGDATABASE=app_db
export PGPASSWORD='<只读账号口令>'
python3 ops/restore/verify_restore.py snapshot \
  --tables ops/restore/tables.yml --out snapshot-2026-11-24.json
```

## 2. 演练步骤与预计耗时

| 步 | 做什么 | 命令 / 位置 | 预计耗时 |
|---|---|---|---|
| 1 | 取校验快照 | 上一条命令 | 1 分钟 |
| 2 | PITR 到新实例 | `ops/restore/pitr_restore.sh --env test --target-time '2026-11-24 10:00:00' --new-instance-name pitr-drill-20261124 --source-instance-id <源实例 ID> --bastion-cidr <堡垒机 CIDR> --region <地域>` | 克隆 10~30 分钟（脚本轮询等 Running） |
| 3 | 核对白名单 | 脚本第 3~4 步自动做：改成仅堡垒机网段，并回读核对；**不一致时脚本直接报错退出，不继续** | 含在第 2 步里 |
| 4 | 连临时实例做一致性校验 | `python3 ops/restore/verify_restore.py verify --tables ops/restore/tables.yml --snapshot snapshot-2026-11-24.json --report report-2026-11-24.json --report-md report-2026-11-24.md`（连临时实例的内网地址、只读账号） | 2 分钟 |
| 5 | 逻辑备份恢复（另一条路） | `ops/restore/logical_restore.sh --env test --date 2026-11-24 --target-db app_db_restored --tables ops/restore/tables.yml` | 5 分钟 |
| 6 | 删临时实例与临时库 | 见 §3 | 2 分钟 |
| 7 | 写演练记录 | 见 §4 模板，存到 `docs/drills/` | 10 分钟 |

合计约 30~50 分钟，远低于 RTO 2 小时；RTO 的大头是克隆等待，
不是人的操作时间。

## 3. 演练结束后删除临时实例

演练完必须删临时实例（按量付费，放着就一直扣钱；且临时实例含生产数据副本）。

```bash
# 1) 先删逻辑恢复用的临时库（在临时实例上，或本地演练库）
#    （按量实例删库不删实例，别弄混。）
# 2) 删 PITR 临时实例（删实例即删库，不可逆；删之前确认校验报告已存档）
aliyun rds DeleteDBInstance --DBInstanceId <新实例 ID>
# 3) 确认实例已不在列表里
aliyun rds DescribeDBInstances --RegionId <地域> | grep <新实例 ID> || echo "deleted"
# 4) 删本地演练产生的临时目录（如果用了 --local 模式）
#    先停恢复出的本地实例，再删目录：
#    <PGBIN>/pg_ctl -D <恢复目录> stop
#    rm -rf <恢复目录>
```

**删之前必须确认**：校验报告（JSON + Markdown）与演练记录已存档；
删错实例无法恢复——命令里的实例 ID 必须是 `pitr-drill-*` 开头的
临时实例 ID，绝不能是源实例 ID。脚本本身不提供删源实例的命令。

## 4. 演练记录模板

每次演练填一份，存到 `docs/drills/drill-<YYYY-MM-DD>.md`。

```markdown
# 演练记录 <YYYY-MM-DD>
- 演练人：
- 环境：test
- 源实例 ID：
- 目标时间点（北京时间）：
- 目标时间点（UTC）：
- 恢复出的临时实例 ID：
- 临时实例白名单（核对结果）：
- PITR 耗时（从执行克隆到实例 Running）：
- 校验结果：PASS / FAIL
- 校验报告文件：report-<日期>.json / .md
- 不一致的表（如有）：
- 逻辑备份恢复：做 / 未做；结果：
- 发现的问题：
- 临时实例已删除：是 / 否（删除时间）：
- 总耗时（从开始到删完实例）：
- RTO 是否达标（≤ 2 小时）：是 / 否
```

## 5. 校验 FAIL 时怎么办

1. 先看报告里列出的表名与差异项（行数 / max_updated_at / 行哈希）。
2. 行数差 1~几行：大概率是快照与恢复点之间源实例有新写入——
   检查快照时间与目标时间之间是否有写入；下次演练先停写入再取快照。
3. 行哈希不一致但行数一致：有行被改过（updated_at 变了）——
   同样先查快照后、目标时间前的写入。
4. 整表缺失：恢复点选在了建表之前，或备份集不含该表——
   检查目标时间与建表时间。
5. 以上都不是：把快照、报告、目标时间发给核心团队复核，
   不要自己改快照或改目标时间去“凑 PASS”。

## 6. 本机验证（无云账号时）

本机没有云实例与堡垒机，云上步骤跑不了；但脚本逻辑可以在本机
PostgreSQL 上完整验证，见 README「本地验证」一节与 `tests/run_all.sh`：

- `pitr_restore.sh --local`：pg_basebackup + recovery_target_time 真实恢复。
- `verify_restore.py`：快照 → 恢复后 PASS；删 1 行 → FAIL 并指出表名。
- `logical_restore.sh`：本地桶 + 本地等价 KMS 解密恢复。

本地验证通过只证明脚本逻辑正确，不等于云上验收通过（见 §7）。

## 7. 未执行项（诚实记录，不拿一半证据冒充）

| 验收 | 状态 | 原因 |
|---|---|---|
| 验收 1：在 test 环境完成一次时间点恢复到新实例，演练记录写明实际耗时 | **未执行** | 无真实云实例、无客户云账号与堡垒机；本地等价 PITR 已做（见 evidence/），但那不是 test 环境云实例 |
| 验收 2：数据一致时输出 PASS，人为删掉 1 行后输出 FAIL 并指出表名 | **本地已验证通过** | 对本地恢复实例实测：一致时 PASS；删 1 行后 FAIL，指出 `members` 表（见 evidence/） |
| 验收 3：恢复出的临时实例白名单只含堡垒机网段（附截图） | **未执行** | 无真实云实例；脚本逻辑是：克隆后调 ModifySecurityIps 全量替换为仅堡垒机 CIDR，再回读核对，不一致报错退出；截图须在真实演练时补 |
| 验收 4：手册含删除临时实例的命令与演练记录模板 | **已完成** | 见 §3 与 §4 |

真实 test 环境演练须由客户方在有云账号的运维节点上按本手册执行，
演练记录与白名单截图到时补进 `docs/drills/`。
