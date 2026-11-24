# Restore verification: FAIL

- checked at (UTC): 2026-11-24T00:47:13Z
- snapshot: /tmp/pg3175-test/snapshot-after.json (generated 2026-11-24T00:47:09Z)
- database: app_db on 127.0.0.1:5434

FAILED tables: members

## members: FAIL
- count: snapshot=4 actual=3
- max_updated_at: snapshot=2026-11-24T00:47:05.579267+00 actual=2026-11-24T00:46:53.029606+00
- row_hash mismatch (first 1000 rows by id differ)

## sop_items: PASS
- count=2 max_updated_at=2026-11-24T00:46:53.030448+00 row_hash=41a6b1e24ba81304...
