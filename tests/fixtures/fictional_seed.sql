-- 逻辑备份本地验证用的虚构种子数据（无真实个人信息与企业信息）。
-- 表结构贴合本单统一约定：id(UUID)、org_id、site_id、created_at、created_by、updated_at、deleted_at。
-- TRUNCATE 让 setup 脚本可重复跑，结果稳定在 3 + 2 行。
-- gen_random_uuid() 是 PostgreSQL 13+ 内置函数，不需要 pgcrypto 扩展。
CREATE TABLE IF NOT EXISTS members (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  site_id    uuid NOT NULL,
  company_name text NOT NULL,
  contact_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT 'seed',
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS sop_items (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  site_id    uuid NOT NULL,
  title      text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT 'seed',
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

TRUNCATE members, sop_items;

INSERT INTO members (org_id, site_id, company_name, contact_name) VALUES
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '虚构测试企业 A', '测试联系人甲'),
  ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '虚构测试企业 B', '测试联系人乙'),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', '虚构测试企业 C', NULL);

INSERT INTO sop_items (org_id, site_id, title) VALUES
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '虚构 SOP 条目一'),
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '虚构 SOP 条目二');
