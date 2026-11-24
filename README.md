# ClawHunt #3175：时间点恢复演练脚本与数据一致性校验手册

会员空间平台 · 时间点恢复演练脚本与数据一致性校验手册。

> **范围说明（先说清楚）**：本单只做一半。`pitr_restore.sh`、
> `verify_restore.py`、`logical_restore.sh`、`tables.yml` 与手册都写好了，
> 且在本机 PostgreSQL 上真实跑通过；但验收 1（test 环境云实例 PITR）
> 与验收 3（临时实例白名单截图）要真实云实例与堡垒机，本机没有，
> **这两步未执行**，不拿本地验证冒充云上验收。详见 `ACCEPTANCE.md` 与
> `docs/restore-drill.md` §7。

## 交付物

| 文件 | 作用 |
|---|---|
| `ops/restore/pitr_restore.sh` | 时间点恢复到新实例。云模式调阿里云 RDS `CloneDBInstance`（`RestoreTime`，UTC），等 Running 后把白名单收紧为仅堡垒机网段并回读核对；`--local` 模式对本机 PG 做真实 PITR（`pg_basebackup` + `recovery_target_time`）；`--dry-run` 只打印将执行的调用 |
| `ops/restore/verify_restore.py` | 一致性校验（标准库 + psql，无额外依赖）。`snapshot` 在演练前取快照（行数、每表最大 `updated_at`、按 id 前 1000 行哈希）；`verify` 对恢复实例比对，输出 PASS / FAIL（JSON + Markdown），FAIL 列出不一致的表名 |
| `ops/restore/logical_restore.sh` | 从 backups 桶取指定日期的 pg_dump 文件，解密（与 #3174 的 AES-256-CBC 信封配套）并 `pg_restore` 到新建临时库，核对解密后 sha256 |
| `ops/restore/tables.yml` | 校验的表：`members`、`sop_items`（贴合平台统一约定，虚构数据） |
| `docs/restore-drill.md` | 演练手册：每季度 1 次、分步操作与预计耗时、RTO ≤ 2 小时、删除临时实例的命令、演练记录模板、未执行项清单 |
| `tests/` | 验收复现脚本：参数校验与 dry-run、单元测试、本地完整演练（PITR + 校验 PASS/FAIL + 逻辑恢复） |
| `evidence/` | 本轮实测输出原文 |

## 关键设计

- **只恢复到新实例，绝不碰源实例**：云模式用 `CloneDBInstance`（克隆），
本地模式用 `pg_basebackup` 到新数据目录；脚本里没有任何删、改源实例的命令。
- **白名单默认收紧**：克隆实例会继承源实例的白名单，所以恢复后必须调
`ModifySecurityIps` 全量替换为仅堡垒机 CIDR，再回读核对，不一致报错退出。
- **演练只在 test 环境**：`pitr_restore.sh` 与 `logical_restore.sh` 遇到
`--env prod` 直接拒绝；生产恢复须另行审批。
- **时间口径**：`--target-time` 按北京时间给，脚本自动转 UTC
（`CloneDBInstance` 要求 `yyyy-MM-ddTHH:mm:ssZ`）；目标时间须在过去、
且在日志保留期（默认 30 天）内，否则拒绝。
- **只用虚构数据**：种子数据与 #3174 同源（虚构企业与 SOP 条目），无真实个人信息。
- **依赖**：Python 3.11+（标准库）、PostgreSQL 16 客户端工具（`psql`、`pg_basebackup`、
`pg_restore`）、云模式另需 `aliyun` CLI 与 `ossutil`（运维节点装）。

## 云上演练（真实环境，按手册执行）

```bash
# 1. 演练前在源实例取快照
export PGHOST=<源实例内网地址> PGPORT=5432 PGUSER=<只读账号> PGDATABASE=app_db
export PGPASSWORD='<只读账号口令>'
python3 ops/restore/verify_restore.py snapshot \
--tables ops/restore/tables.yml --out snapshot-2026-11-24.json

# 2. PITR 到新实例（北京时间 10:00；脚本自动转 UTC）
ops/restore/pitr_restore.sh --env test --target-time '2026-11-24 10:00:00' \
--new-instance-name pitr-drill-20261124 \
--source-instance-id <源实例 ID> --bastion-cidr <堡垒机 CIDR> --region <地域>

# 3. 对新实例校验（连新实例内网地址）
python3 ops/restore/verify_restore.py verify \
--tables ops/restore/tables.yml --snapshot snapshot-2026-11-24.json \
--report report-2026-11-24.json --report-md report-2026-11-24.md

# 4. 逻辑备份恢复（另一条路）
ops/restore/logical_restore.sh --env test --date 2026-11-24 \
--target-db app_db_restored --tables ops/restore/tables.yml

# 5. 演练完删临时实例（见手册 §3；删前确认报告已存档）
aliyun rds DeleteDBInstance --DBInstanceId <新实例 ID>
```

先跑 `--dry-run` 看将执行的调用，不调任何云 API：

```bash
ops/restore/pitr_restore.sh --env test --target-time '2026-11-24 10:00:00' \
--new-instance-name pitr-drill-20261124 --source-instance-id rm-xxxx \
--bastion-cidr 203.0.113.10/32 --region cn-shanghai --dry-run
```

## 本地验证（本机已跑通过）

```bash
bash tests/run_all.sh # 参数校验 + dry-run + 单元测试 + 本地完整演练
```

本地演练用 #3174 的本地等价环境（PostgreSQL 16.2，端口 5433，虚构种子），
再加 WAL 归档（`tests/setup_local_pitr.sh`），流程：

1. 基础备份 → 插入 1 行标记数据 → 切换 WAL → 取快照；
2. `--local` PITR 恢复到标记时间点的新实例（新端口 5434）→ `verify` 输出 **PASS**；
3. 在恢复实例上删 1 行 → `verify` 输出 **FAIL**，指出 `members` 表；
4. PITR 到标记行插入**之前**的时间点 → `verify` 输出 **FAIL**（行数不一致），
证明恢复确实按目标时间点切分数据；
5. 用 #3174 的备份脚本出一份当日逻辑备份 → `logical_restore.sh` 解密恢复到
临时库，行数与源库一致。

实测输出原文见 `evidence/`。

## 与 #3174 的关系

- #3174 配了备份策略（03:00Z–04:00Z、日志备份、保留期）与逻辑备份脚本；
本单的 PITR 以此为前提（日志备份不开，`CloneDBInstance` 按时间点恢复会失败）。
- 逻辑恢复的加密信封与 #3174 的 `pg_logical_backup.sh` 完全配套
（AES-256-CBC，`meta.json` 里的 `iv_hex` 与 `dump_sha256` 核对）。

## 未执行项

见 `ACCEPTANCE.md` 与 `docs/restore-drill.md` §7：验收 1 与验收 3
须真实云实例与堡垒机，本机没有，未执行；真实 test 环境演练须客户方
在运维节点按手册执行，演练记录与白名单截图到时补进 `docs/drills/`。

## 投标提案

- 最终版：`docs/bid-proposal-v2.md`（v1 见 `docs/bid-proposal-v1.md`，复核记录见 `docs/GPT-review.md`）。
- GPT 两轮复核均通过（第一轮修改后 GO，第二轮 GO），报价 $130.50（参考价 $145 的 90%），净额 $97.87。
- 当前状态：未投出。投标渠道待通（161 未通，平台写操作走 161 受控通道），渠道恢复后按 v2 投出。
