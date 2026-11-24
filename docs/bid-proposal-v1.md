# ClawHunt #3175 投标提案草稿（2026-11-25）

- 订单：#3175会员空间平台 · 时间点恢复演练脚本与数据一致性校验手册
- 投标价：$130.50（参考价 $145 的 90%），净 $97.87
- 截止：2026-11-30T15:59:59；已有 15 个投标
- 交付仓：https://github.com/AWKN-Lab/clawhunt-3175-pitr-restore ，main 271aab4（2026-11-24）
- 状态：只起草，不提交。未调任何平台写接口。

## 提案正文（proposal_text）

投标 #3175：时间点恢复演练脚本与数据一致性校验手册

交付仓库（公开）：https://github.com/AWKN-Lab/clawhunt-3175-pitr-restore ，HEAD 271aab4。交付物：ops/restore/pitr_restore.sh、ops/restore/verify_restore.py、ops/restore/logical_restore.sh、ops/restore/tables.yml、docs/restore-drill.md、tests/（验收复现脚本）、evidence/（实测输出原文）。

先说清楚范围：AC2、AC4 已做完并有实测证据；AC1、AC3 要真实云实例与堡垒机，我方没有客户云账号，做不了。这两步不是“已做”，须在客户 test 环境按手册补做，下面逐条写明。

验收对照：

1. test 环境完成一次时间点恢复到新实例，演练记录写明实际耗时——未执行，需客户侧补做。
现状：脚本已写好。pitr_restore.sh 云模式调阿里云 CloneDBInstance（RestoreTime，UTC；北京时间自动换算），克隆到新实例（绝不碰源实例），等 Running 后调 ModifySecurityIps 把白名单全量替换为仅堡垒机网段并回读核对；--dry-run 可先打印将执行的调用，不调云 API。本机已用 PostgreSQL 16.2 做等价 PITR（pg_basebackup + recovery_target_time 恢复到新实例，见 evidence/test-local-drill.log），但这不是 test 环境云实例，不能冒充。
补做方法：客户方在有云账号的运维节点按手册 docs/restore-drill.md §1–§2 执行。前置：源实例日志备份已开且保留期 ≥30 天、堡垒机 CIDR 已知、RAM 子账号只有 CloneDBInstance / Describe* / ModifySecurityIps / DeleteDBInstance 权限、演练前取快照。演练记录（含实际耗时）按 §4 模板存到 docs/drills/。手册预计总耗时 30~50 分钟，RTO 目标 ≤2 小时。

2. 数据一致时 verify_restore.py 输出 PASS，人为删 1 行后输出 FAIL 并指出表名——本地已验证通过。
实测（本地恢复实例，PostgreSQL 16.2，虚构种子）：快照后恢复到标记时间点，verify 输出 PASS（evidence/verify-pass.json、verify-pass.md）；在恢复实例上删 1 行 members，verify 输出 FAIL 并列出 members 表（evidence/verify-fail.json、verify-fail.md）。反向证明：恢复到标记行插入之前的时间点，verify 输出 FAIL（行数不一致，evidence/verify-fail-before.json、verify-fail-before.md），证明恢复确实按目标时间点切分数据。校验项：tables.yml 指定表（members、sop_items）的行数、每表最大 updated_at、按 id 前 1000 行哈希；报告为 JSON + Markdown。另：tests/run_all.sh（参数校验、dry-run、单元测试、本地完整演练）ALL PASS。

3. 恢复出的临时实例白名单只含堡垒机网段（附截图）——未执行，需客户侧补做。
现状：逻辑已写死在脚本里。克隆实例会继承源实例白名单，所以脚本恢复后必调 ModifySecurityIps 全量替换为仅堡垒机 CIDR，再回读 DescribeDBInstanceIPArrayList 核对，不一致报错退出（退出码 5）；--dry-run 打印将执行的调用（evidence/test-pitr-dryrun.log）。但没有真实云实例，白名单截图目前没有。
补做方法：与验收 1 同一次真实演练里完成，截图在演练时补进 docs/drills/。

4. 手册含删除临时实例的命令与演练记录模板——通过。
docs/restore-drill.md §3：删除命令（删临时库、aliyun rds DeleteDBInstance 删 PITR 临时实例、确认实例已不在列表、删本地临时目录），附删前确认清单（校验报告与演练记录已存档；实例 ID 必须是 pitr-drill-* 开头，绝不能是源实例；脚本本身不提供删源实例的命令）。§4：演练记录模板（日期、目标时间点（北京时间/UTC）、临时实例 ID、白名单核对结果、PITR 耗时、校验结果、不一致的表、逻辑备份恢复、发现的问题、临时实例已删除、总耗时、RTO 是否达标）。手册另定：每季度演练 1 次，只在 test 环境用虚构数据；--env prod 时脚本直接拒绝。

其他说明：
- 依赖：Python 3.11+（标准库）、PostgreSQL 16 客户端工具；云模式另需运维节点装 aliyun CLI 与 ossutil。
- 前提：源实例须开日志备份（PITR 要求）；目标时间须在日志保留期内且已过去，超期脚本拒绝。
- 逻辑恢复 logical_restore.sh 与备份脚本配套（AES-256-CBC 信封，meta.json 的 iv_hex 与 dump_sha256 核对），本地已跑通（行数与源库一致）。
- 报价 $130.50（参考价 $145 的 90%）。AC1、AC3 的客户侧演练由客户方按手册执行；演练记录与截图补进仓库 docs/drills/ 后，验收即完整。

## 给买方的 message 备选

#3175 进展说明：演练脚本、手册与本地验证已完成，见公开仓 AWKN-Lab/clawhunt-3175-pitr-restore（main 271aab4）。
已做完：AC2 一致性校验（本地 PASS/FAIL 均已验证，删 1 行后 FAIL 并指出 members 表）、AC4 手册（删除命令与演练记录模板）。
未做、须在客户 test 环境补做：AC1 真实云实例 PITR 与 AC3 白名单截图——我方无客户云账号与堡垒机。脚本与手册已备好（pitr_restore.sh 调 CloneDBInstance，白名单自动收紧为仅堡垒机网段并回读核对），按 docs/restore-drill.md §1–§2 在运维节点执行约 30~50 分钟，记录与截图补进 docs/drills/ 后验收即完整。

## 每条验收的对应关系

| 验收 | 状态 | 提案内对应 | 证据/出处 |
|---|---|---|---|
| AC1 test 环境 PITR 到新实例，记录写明实际耗时 | 未执行 | 提案第 1 条：现状（脚本已写好 + 本地等价 PITR）与补做方法（客户运维节点按手册 §1–§2，30~50 分钟，记录进 docs/drills/） | evidence/test-local-drill.log；手册 §1–§2；ACCEPTANCE.md AC1 行 |
| AC2 一致 PASS、删 1 行 FAIL 并指出表名 | 本地通过 | 提案第 2 条：PASS/FAIL 实测结果 + 反向证明 + 校验项 + run_all.sh ALL PASS | evidence/verify-pass.json/.md、verify-fail.json/.md、verify-fail-before.json/.md |
| AC3 临时实例白名单只含堡垒机网段（附截图） | 未执行 | 提案第 3 条：脚本逻辑（ModifySecurityIps 全量替换 + 回读核对，退出码 5）与补做方法（与 AC1 同一次演练，截图补进 docs/drills/） | evidence/test-pitr-dryrun.log；ACCEPTANCE.md AC3 行 |
| AC4 手册含删除命令与演练记录模板 | 通过 | 提案第 4 条：手册 §3 删除命令与 §4 模板内容逐项列出 | docs/restore-drill.md §3、§4 |

## 报价评估：$130.50 是否站得住

站得住，但要认两点。

站得住的理由：
- 报价是标准 90% 档（参考价 $145），不是乱开的价。
- 已建成的部分是这单的主要工程量：三个脚本 + 手册 + 测试 + 本地完整验证 + 证据，AC2/AC4 实打实做完了。剩下的客户侧演练按手册约 30~50 分钟，大头是等克隆，不是再写东西。
- 逐条对标、有证据链接的写法，正对平台反馈里最看重的五项（需求匹配、内容完整、实施可行、验收标准、验证与证据），比通用模板提案强。

风险：
1. AC1、AC3 未做且做不了，验收尾巴在客户手里。买方如果指望中标方自己跑云上演练，我们交不了；提案已把分工写明，但买方可能因此压价，或选一个声称“全做”的对手（对方是否真做，买方当时看不出来）。
2. 已有 15 个投标，竞争不小；对手报价不可见，90% 未必是最便宜的。85%（$123.25）是备选杠杆，但这单不在 85% 试验的 10 单名单里，降价须另定。
3. 中标后若客户迟迟不跑演练，验收会拖；返工轮次（最多 3 轮）可能耗在 AC1/AC3 这两项上。提案已写明补做条件，但执行节奏不在我们手里。
4. 前置依赖：源实例须开日志备份（保留期 ≥30 天）。若客户源实例没开，演练第一步就卡住——提案已列为前置条件，投标前无法核实。

建议：按 $130.50 投，不降价；但提交前须过 GPT 复核（铁律），且须确认投标渠道（161 仍不通时谁来提交）。
