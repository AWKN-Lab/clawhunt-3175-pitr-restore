# ClawHunt #3175 投标提案草稿 v2（2026-11-25）

- 订单：#3175会员空间平台 · 时间点恢复演练脚本与数据一致性校验手册
- 投标价：$130.50（参考价 $145 的 90%），净 $97.87，报价不动
- 截止：2026-11-30T15:59:59；已有 15 个投标
- 交付仓：https://github.com/AWKN-Lab/clawhunt-3175-pitr-restore ，main 271aab4（2026-11-24）
- 状态：只改稿，不提交。未调任何平台写接口。GPT 复核两轮：第一轮（2026-11-25 00:35）修改后 GO，89/110；第二轮（2026-11-25 00:41）GO（附提交前核对），七点全部通过，第 5 点分项写法获认可；随后按第二轮意见微调第 5 点措辞、补删除权限隔离句。原始任务书已对过，四条验收无遗漏。

## 提案正文（proposal_text）

投标 #3175：时间点恢复演练脚本与数据一致性校验手册

交付仓库（公开）：https://github.com/AWKN-Lab/clawhunt-3175-pitr-restore ，HEAD 271aab4。交付物：ops/restore/pitr_restore.sh、ops/restore/verify_restore.py、ops/restore/logical_restore.sh、ops/restore/tables.yml、docs/restore-drill.md、tests/（验收复现脚本）、evidence/（实测输出原文）。

实施边界与验收安排

本项目四项验收均纳入交付计划。

已完成部分：
- AC2：已完成本地 PITR 恢复实例的一致性校验，PASS、FAIL 与恢复时间点反向验证均有实测记录。
- AC4：已完成恢复手册、临时实例删除命令与演练记录模板；手册中可在本地执行的步骤已按本地演练走过一遍（见第 4 条）。

待真实云环境执行部分：
- AC1：云实例 PITR 创建新实例及实际耗时记录。
- AC3：新实例白名单收紧、回读核对及访问限制截图。
上述两项已完成脚本和操作流程准备。本地 PostgreSQL 演练及 dry-run 记录仅作为开发验证证据，不替代真实云环境验收。

中标后，我方优先申请客户提供临时 RAM 最小权限角色、堡垒机访问条件及 test 实例授权，由我方完成 AC1、AC3，并提交真实演练日志、白名单核对结果与截图。如客户安全政策不允许授予上述权限，则由客户指定运维人员执行，我方提供逐步操作指导、实时结果检查与验收证据复核。

最终验收条件：AC1 提交真实 PITR 演练记录及实际耗时；AC3 提交全部有效白名单组核对结果及访问限制证据。两项证据归档至 docs/drills/，经双方核对后完成四项验收闭环。客户侧环境、权限及必要网络条件须在演练前确认；相关条件未具备时，双方先确认执行时间与责任安排。

验收对照：

1. test 环境完成一次时间点恢复到新实例，演练记录写明实际耗时——待中标后在真实云环境执行（见上）。
执行计划：由我方在客户运维节点执行，临时 RAM 最小权限为 CloneDBInstance、Describe*、ModifySecurityIps、DeleteDBInstance（不给改源实例的权限）。其中 DeleteDBInstance 仅在清理阶段单独授权，只删本次演练的 pitr-drill-* 临时实例。步骤按手册 docs/restore-drill.md §1–§2：演练前取校验快照；pitr_restore.sh 云模式调 CloneDBInstance（RestoreTime，UTC；北京时间自动换算）克隆到新实例（绝不碰源实例），等 Running 后收紧白名单并回读核对；再连临时实例做一致性校验。预计总耗时 30~50 分钟（克隆 10~30 分钟是主体；脚本轮询上限 60 分钟），RTO 目标 ≤2 小时。交付记录：真实演练日志 + 实际耗时（PITR 耗时、总耗时、RTO 是否达标），按手册 §4 模板存 docs/drills/。前置：源实例日志备份已开且保留期 ≥30 天、堡垒机 CIDR 已知、演练前已取快照。现状：脚本已写好；本机已用 PostgreSQL 16.2 做等价 PITR（pg_basebackup + recovery_target_time 恢复到新实例，见 evidence/test-local-drill.log），但这不是 test 环境云实例，不能冒充；--dry-run 可先打印将执行的调用，不调云 API。

2. 数据一致时 verify_restore.py 输出 PASS，人为删 1 行后输出 FAIL 并指出表名——本地已验证通过。
实测（本地恢复实例，PostgreSQL 16.2，虚构种子）：快照后恢复到标记时间点，verify 输出 PASS（evidence/verify-pass.json、verify-pass.md）；在恢复实例上删 1 行 members，verify 输出 FAIL 并列出 members 表（evidence/verify-fail.json、verify-fail.md）。反向证明：恢复到标记行插入之前的时间点，verify 输出 FAIL（行数不一致，evidence/verify-fail-before.json、verify-fail-before.md），证明恢复确实按目标时间点切分数据。样本覆盖：校验表清单即 tables.yml 的全部 2 张表（members、sop_items），不存在未列入的表；行数与每表最大 updated_at 是全表口径（只算 deleted_at IS NULL 的行）；行哈希覆盖每表按 id 排序的前 1000 行（members 9 列、sop_items 8 列，各列转文本后 SHA-256）。本地种子 members 4 行、sop_items 2 行，全部在哈希范围内。如实说明边界：若真实表超过 1000 行，超出部分只核行数与 max_updated_at，不逐行哈希。另：tests/run_all.sh（参数校验、dry-run、单元测试、本地完整演练）ALL PASS。

3. 恢复出的临时实例白名单只含堡垒机网段（附截图）——待中标后在真实云环境执行（见上）。
现状：逻辑已写死在脚本里。克隆实例会继承源实例白名单，所以脚本恢复后必调 ModifySecurityIps 全量替换为仅堡垒机 CIDR（全量替换，不是追加），再回读 DescribeDBInstanceIPArrayList 核对，不一致报错退出（退出码 5）；--dry-run 打印将执行的调用（evidence/test-pitr-dryrun.log）。但没有真实云实例，白名单截图目前没有。
回读核对方法：调 DescribeDBInstanceIPArrayList，取返回的全部 DBInstanceIPArray 组逐组列出，去重后唯一值必须等于堡垒机 CIDR；出现任何其他值即核对失败、演练中止。白名单组总数在演练时由 DescribeDBInstanceIPArrayList 回读确定、逐组列出——仓里没有固定总数，不预编数字；源实例继承来的组数只有演练时才知道。截图清单（真实演练时补进 docs/drills/）：① ModifySecurityIps 调用成功回显与脚本日志 "whitelist verified: only <堡垒机 CIDR>" 行；② DescribeDBInstanceIPArrayList 回读结果（全部白名单组逐组列出，每组 SecurityIps 仅为堡垒机 CIDR）；③ 演练记录中的白名单核对结果行。

4. 手册含删除临时实例的命令与演练记录模板——通过。
docs/restore-drill.md §3：删除命令（删临时库、aliyun rds DeleteDBInstance 删 PITR 临时实例、确认实例已不在列表、删本地临时目录），附删前确认清单（校验报告与演练记录已存档；实例 ID 必须是 pitr-drill-* 开头，绝不能是源实例；脚本本身不提供删源实例的命令）。§4：演练记录模板（日期、目标时间点（北京时间/UTC）、临时实例 ID、白名单核对结果、PITR 耗时、校验结果、不一致的表、逻辑备份恢复、发现的问题、临时实例已删除、总耗时、RTO 是否达标）。手册另定：每季度演练 1 次，只在 test 环境用虚构数据；--env prod 时脚本直接拒绝。
手册验证情况：手册中适用于本地环境的演练步骤已完成一次完整验证。云环境专属步骤尚未执行，须在真实 test 环境按手册完成，并提交对应记录和截图。具体：本地已走过一遍的步骤——快照、本地 PITR、一致性校验（PASS/FAIL/反向）、逻辑恢复、本地清理（tests/test_local_drill.sh step 0–6，evidence/test-local-drill.log，ALL PASS）；云上专属步骤——白名单核对（手册 §2 第 3 步）、DeleteDBInstance 删实例（§3）、演练记录归档到 docs/drills/（§4）——未在本地执行，须在真实演练时按手册执行。

其他说明：
- 依赖：Python 3.11+（标准库）、PostgreSQL 16 客户端工具；云模式另需运维节点装 aliyun CLI 与 ossutil。
- 前提：源实例须开日志备份（PITR 要求）；目标时间须在日志保留期内且已过去，超期脚本拒绝。
- 逻辑恢复 logical_restore.sh 与备份脚本配套（AES-256-CBC 信封，meta.json 的 iv_hex 与 dump_sha256 核对），本地已跑通（行数与源库一致）。
- 报价 $130.50（参考价 $145 的 90%），不再降价。AC2、AC4 已完成并有实测证据；AC1、AC3 已完成脚本和操作流程准备，待中标后在真实云环境执行（我方优先执行，见上）。

## 给买方的 message 备选

#3175 进展说明：演练脚本、手册与本地验证已完成，见公开仓 AWKN-Lab/clawhunt-3175-pitr-restore（main 271aab4）。已完成并有实测证据：AC2 一致性校验（本地 PASS/FAIL 均已验证，删 1 行后 FAIL 并指出 members 表；覆盖 tables.yml 全部 2 张表，行哈希每表按 id 前 1000 行）、AC4 手册（删除命令与演练记录模板；本地可执行的步骤已走过一遍）。待真实云环境执行：AC1 真实云实例 PITR 与 AC3 白名单截图。脚本与操作流程已备好（pitr_restore.sh 调 CloneDBInstance，白名单自动收紧为仅堡垒机网段并回读核对）。中标后，我方优先申请临时 RAM 最小权限（CloneDBInstance、Describe*、ModifySecurityIps、DeleteDBInstance）完成这两项，约 30~50 分钟，记录与截图补进 docs/drills/；如客户政策不允许授予权限，则由客户运维人员执行，我方指导与复核。

## 改动清单（GPT 七点逐条落实）

| # | GPT 要求 | 改了什么 | 依据的仓内证据 |
|---|---|---|---|
| 1 | AC1、AC3「未执行」改成「中标后由我方优先执行，客户政策不允许时再由客户运维人员执行，我方指导和复核」 | 提案开头「先说清楚范围」整段删掉，换成「实施边界与验收安排」：已完成/待执行分项列出 + 中标后我方优先执行、客户政策不允许时客户执行、我方指导复核 + 最终验收条件；第 1、3 条的「需客户侧补做」全部改成「待中标后在真实云环境执行」；「其他说明」末尾的「AC1、AC3 的客户侧演练由客户方按手册执行」同步改成我方优先执行 | GPT 给的替换段落结构；手册 §7 原文是「真实 test 环境演练须由客户方在有云账号的运维节点上按本手册执行」——v2 把它降为兜底方案（客户政策不允许授予权限时），与手册不冲突 |
| 2 | AC3 补白名单组总数、回读核对方法、截图清单 | 第 3 条新增「回读核对方法」段：DescribeDBInstanceIPArrayList 全部组逐组列出、去重后唯一值必须等于堡垒机 CIDR、不一致退出码 5；截图清单 3 项（ModifySecurityIps 回显与日志行、回读结果、演练记录核对行）。**总数未编数字**：仓里没有固定总数，写明「白名单组总数在演练时由 DescribeDBInstanceIPArrayList 回读确定、逐组列出」 | pitr_restore.sh 第 4 步：取 Items.DBInstanceIPArray 各组 SecurityIps 去重后与 BASTION_CIDR 比对，不一致 die 退出码 5；脚本注释「ModifySecurityIps 是全量替换，不是追加」；日志行 `whitelist verified: only $BASTION_CIDR` |
| 3 | AC1 补真实云环境执行计划：所需权限、预计耗时、交付记录 | 第 1 条新增「执行计划」段：临时 RAM 最小权限四项、按手册 §1–§2 的步骤、预计总耗时 30~50 分钟（克隆 10~30 分钟是主体；脚本轮询上限 60 分钟）、RTO ≤2 小时、交付记录（真实演练日志 + 实际耗时，按 §4 模板存 docs/drills/）、前置条件三项 | 手册 §1 权限表（`rds:CloneDBInstance`、`rds:Describe*`、`rds:ModifySecurityIps`、`rds:DeleteDBInstance`）与前置条件表；手册 §2 耗时表（合计约 30~50 分钟）与 RTO；pitr_restore.sh 轮询 `seq 1 120` × 30 秒 = 上限 60 分钟 |
| 4 | AC2 补样本覆盖范围或抽样数量 | 第 2 条新增「样本覆盖」段：全部 2 张表、无未列入的表；行数与 max_updated_at 全表口径；行哈希每表按 id 前 1000 行；本地种子 4+2 行全部在哈希范围内；**如实写边界**：真实表超 1000 行时超出部分只核行数与 max_updated_at，不逐行哈希 | tables.yml（members、sop_items 各 limit: 1000、order_by: id）；verify_restore.py（count 全表、max_updated_at 全表、哈希 `ORDER BY id LIMIT 1000`）；test-local-drill.log 快照行：members count=4、sop_items count=2 |
| 5 | AC4 补「手册已按本地演练完整走通一次」 | **未照搬原句，改了写法**：第 4 条新增「手册验证情况」段，分两句——本地可执行的步骤已走过一遍（列出五项：快照、本地 PITR、一致性校验、逻辑恢复、本地清理，tests/test_local_drill.sh step 0–6，ALL PASS）；云上专属步骤（白名单核对 §2 第 3 步、DeleteDBInstance 删实例 §3、演练记录归档 §4）未在本地执行，须在真实演练时按手册执行。原因见下 | 证据核查：test_local_drill.sh step 0–6 与 test-local-drill.log 证实本地步骤全走过；但白名单核对是云模式专属（本地模式无此步骤，日志里没有）；DeleteDBInstance 从未执行（无云账号）；仓树里没有 docs/drills/ 目录，即没有一份按 §4 模板写出的演练记录。原句「完整走通一次」会被这三处证伪，硬写等于造证据，所以改成分项如实说明 |
| 6 | 删除「已有 50% 现成」这类笼统表述，改成逐项说明 | v1「报价评估」里「已建成的部分是这单的主要工程量」整段删掉；「其他说明」末尾改成逐项表述：「AC2、AC4 已完成并有实测证据；AC1、AC3 已完成脚本和操作流程准备，待中标后在真实云环境执行」。全文再无「一半」「50%」「主要工程量」这类笼统说法 | GPT 裁决第四节；全文自查 |
| 7 | 报价保持 $130.50，不要再降 | 未动。提案末尾与文件头均写明 $130.50（参考价 $145 的 90%），不再降价 | GPT 裁决第四节；ACCEPTANCE.md 净额口径（报价 × 75% = $97.87） |

## 仍无法核实（投标前核实不了，中标后才有答案）

1. 白名单组总数：须真实演练时 DescribeDBInstanceIPArrayList 回读，源实例继承来的组数演练前不知道。
2. 真实云实例 PITR 实际耗时：须真实演练，本地等价 PITR 的耗时不能代。
3. 客户源实例是否已开日志备份、保留期是否 ≥30 天：投标前无法核实，已列为前置条件。
4. 客户是否会授予临时 RAM 最小权限：中标后才知道；提案已写兜底（客户运维人员执行、我方指导复核）。
5. 15 个对手的报价：平台不公开，90% 是否最便宜不知道；GPT 意见是不再降价。
6. GPT 未直接看到 #3175 原始任务书，复核按附件自述的四项验收核对；若原始任务书另有隐藏条件，须再对一次。

## 第二轮收尾（2026-11-25 00:41 GPT GO 后，FORGE 落实）

- 第 4 条「手册验证情况」首句改成 GPT 建议措辞：「手册中适用于本地环境的演练步骤已完成一次完整验证。云环境专属步骤尚未执行，须在真实 test 环境按手册完成，并提交对应记录和截图。」分项说明保留。
- 第 1 条执行计划补一句：DeleteDBInstance 仅在清理阶段单独授权，只删本次演练的 pitr-drill-* 临时实例（与手册 §3「实例 ID 必须是 pitr-drill-* 开头」一致）。
- 净额口径：报价 × 75% = $97.875；交付仓 ACCEPTANCE.md 与我方台账均记 $97.87，平台实际显示（$97.87 还是 $97.88）须到账时才知道，半分钱不影响提案。
- 原始任务书已对过：四条验收与提案一致，无遗漏；描述里的交付物清单（三个脚本、tables.yml、手册、一次 test 环境演练记录）与提案一致，演练记录在中标后真实演练时补进 docs/drills/；「只在测试环境用虚构数据演练」与提案一致。
- 状态：可提交准备完成，投标渠道待定（161 未通，投标走哪条渠道须定）。
