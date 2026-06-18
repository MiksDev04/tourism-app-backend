-- ============================================================
-- MIGRATION: Per-establishment reports with batch tracking
--
-- BEFORE  →  one reports row covers ALL establishments
-- AFTER   →  one report_batches row (the generation event)
--            + one reports row PER establishment PER batch
--
-- Example: 3 approved businesses + one admin action
--   INSERT report_batches → 1 row
--   INSERT reports        → 3 rows  (one per business)
--
-- Requirements: MySQL 8.0.13+
-- ============================================================


-- ------------------------------------------------------------
-- STEP 1 ── Create report_batches
--   Stores everything that is shared across all establishment
--   reports generated in the same admin run:
--     • which period (month / year)
--     • which admin triggered it
--     • which sheets to include
-- ------------------------------------------------------------
CREATE TABLE report_batches (
  id                          CHAR(36)     NOT NULL DEFAULT (UUID()),
  report_type                 VARCHAR(100) NOT NULL DEFAULT 'DAE-1B',
  period_month                SMALLINT     NOT NULL,
  period_year                 SMALLINT     NOT NULL,
  generated_by                CHAR(36),               -- FK → users.id; NULL = system-triggered
  generated_at                DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  include_sheet_establishment BOOLEAN      NOT NULL DEFAULT TRUE,
  include_sheet_country_sum   BOOLEAN      NOT NULL DEFAULT TRUE,
  include_sheet_monthly       BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT report_batches_pkey              PRIMARY KEY (id),
  CONSTRAINT report_batches_generated_by_fkey FOREIGN KEY (generated_by)
    REFERENCES users (id),
  CONSTRAINT chk_batch_period_month CHECK (period_month BETWEEN 1 AND 12),
  CONSTRAINT chk_batch_period_year  CHECK (period_year  >= 2000)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
-- STEP 2 ── Clear old all-establishment report rows
--   Existing rows have no business_id and cannot satisfy the
--   NOT NULL constraint added in Step 4.
--   TRUNCATE also releases the FK check cleanly.
-- ------------------------------------------------------------
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE reports;
SET FOREIGN_KEY_CHECKS = 1;


-- ------------------------------------------------------------
-- STEP 3 ── Drop constraints + columns that move to report_batches
--
--   Order inside one ALTER TABLE matters in MySQL 8:
--     1. DROP FOREIGN KEY  (releases the FK-backing index)
--     2. DROP INDEX        (explicit drop of the freed index)
--     3. DROP CHECK        (no dependency on columns yet)
--     4. DROP COLUMN       (idx_reports_period auto-drops when
--                           both period_year and period_month go)
-- ------------------------------------------------------------
ALTER TABLE reports
  DROP FOREIGN KEY reports_generated_by_fkey,
  DROP INDEX       idx_reports_generated_by,
  DROP CHECK       chk_period_month,
  DROP CHECK       chk_period_year,
  DROP COLUMN      report_type,
  DROP COLUMN      period_month,
  DROP COLUMN      period_year,
  DROP COLUMN      generated_at,
  DROP COLUMN      generated_by,
  DROP COLUMN      include_sheet_establishment,
  DROP COLUMN      include_sheet_country_sum,
  DROP COLUMN      include_sheet_monthly;
-- NOTE: idx_reports_period (period_year, period_month) is
--       automatically removed when both its columns are dropped.


-- ------------------------------------------------------------
-- STEP 4 ── Add batch_id and business_id to reports
--
--   reports now stores only per-establishment output:
--     id          → the report row itself
--     batch_id    → which generation run this belongs to
--     business_id → which establishment this file is for
--     file_url    → the generated .xlsx / .pdf for that business
--
--   ON DELETE CASCADE on batch_id:
--     deleting a batch (to regenerate) automatically cleans up
--     all its child report rows.
--
--   UNIQUE (batch_id, business_id):
--     prevents duplicate reports for the same establishment
--     in the same generation run.
-- ------------------------------------------------------------
ALTER TABLE reports
  ADD COLUMN  batch_id    CHAR(36) NOT NULL AFTER id,
  ADD COLUMN  business_id CHAR(36) NOT NULL AFTER batch_id,
  ADD CONSTRAINT reports_batch_id_fkey     FOREIGN KEY (batch_id)
    REFERENCES report_batches (id) ON DELETE CASCADE,
  ADD CONSTRAINT reports_business_id_fkey  FOREIGN KEY (business_id)
    REFERENCES businesses (id),
  ADD CONSTRAINT uq_reports_batch_business UNIQUE (batch_id, business_id);


-- ------------------------------------------------------------
-- STEP 5 ── Indexes
-- ------------------------------------------------------------

-- report_batches
CREATE INDEX idx_report_batches_period       ON report_batches (period_year, period_month);
CREATE INDEX idx_report_batches_generated_by ON report_batches (generated_by);

-- reports
-- (batch_id + business_id are already covered by the UNIQUE key,
--  but explicit single-column indexes speed up individual lookups)
CREATE INDEX idx_reports_batch_id    ON reports (batch_id);
CREATE INDEX idx_reports_business_id ON reports (business_id);


-- ============================================================
-- RESULTING SCHEMA (for reference)
-- ============================================================
--
--  report_batches
--  ┌─────────────────────────────┬──────────────┬──────────────────┐
--  │ id                          │ CHAR(36) PK  │ DEFAULT (UUID()) │
--  │ report_type                 │ VARCHAR(100) │ DEFAULT 'DAE-1B' │
--  │ period_month                │ SMALLINT     │ NOT NULL         │
--  │ period_year                 │ SMALLINT     │ NOT NULL         │
--  │ generated_by                │ CHAR(36)     │ FK → users.id    │
--  │ generated_at                │ DATETIME     │ DEFAULT NOW()    │
--  │ include_sheet_establishment │ BOOLEAN      │ DEFAULT TRUE     │
--  │ include_sheet_country_sum   │ BOOLEAN      │ DEFAULT TRUE     │
--  │ include_sheet_monthly       │ BOOLEAN      │ DEFAULT TRUE     │
--  └─────────────────────────────┴──────────────┴──────────────────┘
--
--  reports  (lean — per-establishment output only)
--  ┌─────────────┬──────────────┬───────────────────────────────────┐
--  │ id          │ CHAR(36) PK  │ DEFAULT (UUID())                  │
--  │ batch_id    │ CHAR(36)     │ NOT NULL, FK → report_batches.id  │
--  │             │              │ ON DELETE CASCADE                 │
--  │ business_id │ CHAR(36)     │ NOT NULL, FK → businesses.id      │
--  │ file_url    │ VARCHAR(1000)│ nullable until file is ready      │
--  │ UNIQUE      │ (batch_id, business_id)                          │
--  └─────────────┴──────────────┴───────────────────────────────────┘
--
-- ============================================================
-- EXAMPLE USAGE (Dart / app layer)
-- ============================================================
--
-- 1. Admin clicks "Generate" for June 2026, all sheets on:
--
--    INSERT INTO report_batches
--      (period_month, period_year, generated_by,
--       include_sheet_establishment, include_sheet_country_sum,
--       include_sheet_monthly)
--    VALUES (6, 2026, '<admin-user-id>', TRUE, TRUE, TRUE);
--    -- capture the new batch UUID: @batch_id
--
-- 2. For each approved business, insert a report row:
--
--    INSERT INTO reports (batch_id, business_id)
--    VALUES (@batch_id, '<biz-uuid-1>'),
--           (@batch_id, '<biz-uuid-2>'),
--           (@batch_id, '<biz-uuid-3>');
--
-- 3. After each file finishes generating, update file_url:
--
--    UPDATE reports
--    SET    file_url = 'https://storage.example.com/reports/biz1_jun2026.xlsx'
--    WHERE  batch_id = @batch_id AND business_id = '<biz-uuid-1>';
--
-- 4. Query all reports for a batch:
--
--    SELECT  r.id,
--            b.business_name,
--            rb.period_month,
--            rb.period_year,
--            r.file_url
--    FROM    reports        r
--    JOIN    report_batches rb ON rb.id = r.batch_id
--    JOIN    businesses     b  ON b.id  = r.business_id
--    WHERE   rb.period_year  = 2026
--      AND   rb.period_month = 6
--    ORDER BY b.business_name;
--
-- ============================================================