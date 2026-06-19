UPDATE report_batches SET report_type = 'monthly' WHERE report_type NOT IN ('monthly', 'annual');

ALTER TABLE report_batches
  CHANGE COLUMN report_type report_scope ENUM('monthly','annual') NOT NULL DEFAULT 'monthly',
  DROP COLUMN include_sheet_establishment,
  DROP COLUMN include_sheet_country_sum,
  DROP COLUMN include_sheet_monthly,
  ADD CONSTRAINT uq_report_batches_scope_period UNIQUE (report_scope, period_year, period_month);