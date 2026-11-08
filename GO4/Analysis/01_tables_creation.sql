CREATE SCHEMA IF NOT EXISTS `go4stage2.go4`
OPTIONS (location = 'US');

CREATE OR REPLACE VIEW `go4stage2.go4.stg_pipeline` AS
SELECT
  TRIM(CAST(deal_id AS STRING)) AS deal_id,
  TRIM(CAST(account AS STRING)) AS account,
  TRIM(CAST(segment AS STRING)) AS segment,
  TRIM(CAST(lead_source AS STRING)) AS lead_source,
  TRIM(CAST(stage AS STRING)) AS stage,
  SAFE_CAST(value AS NUMERIC) AS value_usd,
  TRIM(CAST(owner AS STRING)) AS owner,
  SAFE_CAST(NULLIF(TRIM(CAST(created AS STRING)), '') AS DATE) AS created_date,
  SAFE_CAST(NULLIF(TRIM(CAST(closed AS STRING)), '') AS DATE) AS closed_date,
  TRIM(CAST(result AS STRING)) AS result,
  CAST(contact AS STRING) AS contact,
  CAST(scope AS STRING) AS scope,
  CAST(notes AS STRING) AS notes
FROM `go4stage2.go4_raw.pipeline`;


CREATE OR REPLACE VIEW `go4stage2.go4.stg_contrats` AS
SELECT
  TRIM(CAST(contract_id AS STRING)) AS contract_id,
  TRIM(CAST(account AS STRING)) AS account,
  TRIM(CAST(segment AS STRING)) AS segment,
  TRIM(CAST(metro AS STRING)) AS metro,
  SAFE_CAST(NULLIF(TRIM(CAST(start_date AS STRING)), '') AS DATE) AS start_date,
  SAFE_CAST(NULLIF(TRIM(CAST(end_date AS STRING)), '') AS DATE) AS end_date,
  SAFE_CAST(annual_value AS NUMERIC) AS annual_value_usd,
  TRIM(CAST(renewal_status AS STRING)) AS renewal_status
FROM `go4stage2.go4_raw.contracts`;


CREATE OR REPLACE VIEW `go4stage2.go4.stg_marketplace` AS
SELECT
  TRIM(CAST(month AS STRING)) AS month,
  TRIM(CAST(metro AS STRING)) AS metro,
  SAFE_CAST(shifts_posted AS INT64) AS shifts_posted,
  SAFE_CAST(shifts_filled AS INT64) AS shifts_filled,
  SAFE_CAST(working_ats AS INT64) AS working_ats,
  SAFE_CAST(fill_rate_stored AS FLOAT64) AS supplied_fill_rate
FROM `go4stage2.go4_raw.marketplace`;


-- Confirm the load matches the data pack. Every row should show status = 'OK'.
-- Expected values were computed from the CSVs in this folder.

SELECT 'Pipeline' AS dataset, COUNT(*) AS row_count
FROM go4stage2.go4.stg_pipeline

UNION ALL

SELECT 'Contracts', COUNT(*)
FROM go4stage2.go4.stg_contrats

UNION ALL

SELECT 'Marketplace', COUNT(*)
FROM go4stage2.go4.stg_marketplace;


WITH checks AS (
  SELECT 'pipeline rows' AS check_name, COUNT(*) AS actual, 65 AS expected
  FROM `go4stage2.go4.stg_pipeline`

  UNION ALL
  SELECT 'pipeline total value', CAST(SUM(value_usd) AS INT64), 3597000
  FROM `go4stage2.go4.stg_pipeline`

  UNION ALL
  SELECT 'pipeline open deals (closed_date IS NULL)', COUNTIF(closed_date IS NULL), 15
  FROM `go4stage2.go4.stg_pipeline`

  UNION ALL
  SELECT 'contracts rows', COUNT(*), 49
  FROM go4stage2.go4.stg_contrats
  UNION ALL
  SELECT 'contracts total annual value', CAST(SUM(annual_value_usd) AS INT64), 3934000
  FROM go4stage2.go4.stg_contrats

  UNION ALL
  SELECT 'marketplace rows', COUNT(*), 63
  FROM `go4stage2.go4.stg_marketplace`

  UNION ALL
  SELECT 'marketplace shifts posted', SUM(shifts_posted), 49446
  FROM `go4stage2.go4.stg_marketplace`

  UNION ALL
  SELECT 'marketplace shifts filled', SUM(shifts_filled), 39957
  FROM `go4stage2.go4.stg_marketplace`
)
SELECT
  check_name,
  actual,
  expected,
  IF(actual = expected, 'OK', 'MISMATCH') AS status
FROM checks
ORDER BY check_name;



