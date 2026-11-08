-- September 2026 Board Dashboard Reconstruction
-- MONTHLY REFRESH CHECKLIST:
-- 1. Refresh Pipeline, Contracts, Marketplace source data.
-- 2. Run Q2 data quality checks.
-- 3. Update report_end.
-- 4. Update draft_values from the new dashboard.
-- 5. Run this complete script.
-- 6. Investigate discrepancies and review flags.
-- 7. Obtain Finance cash floor confirmatio
-- ==========================================================
-- HOW TO RUN: run the WHOLE script in one go (it uses DECLARE and
-- TEMP tables, which only exist while the script runs). Highlighting
-- a single SUPPORT query on its own will fail. BigQuery shows one
-- result tab per statement: Output 1 is the corrected dashboard.
-- Next month: change report_end only.
-- For one-query-at-a-time checks, use 05_board_metrics.sql.
-- ==========================================================

DECLARE report_end DATE DEFAULT DATE '2026-09-30';
DECLARE prior_end DATE DEFAULT DATE_SUB(
  DATE_TRUNC(report_end, MONTH), INTERVAL 1 DAY
);
DECLARE year_start DATE DEFAULT DATE_TRUNC(report_end, YEAR);

DECLARE report_month STRING DEFAULT FORMAT_DATE('%Y-%m', report_end);
DECLARE prior_month STRING DEFAULT FORMAT_DATE('%Y-%m', prior_end);


-- ----------------------------------------------------------
-- 3.0 DRAFT VALUES
-- Transcribed from the draft dashboard, kept apart from the
-- calculations so the transcription can be checked on its own.
-- Percent metrics are 0-100, not 0-1. Update every month.
-- ----------------------------------------------------------

CREATE TEMP TABLE draft_values AS
SELECT 1 AS sort_order, 'Working ATs' AS metric, 'count' AS unit, 1866.0 AS draft_value
UNION ALL SELECT 2, 'Productive metros',  'count',   8.0
UNION ALL SELECT 3, 'Fill rate',          'percent', 83.62
UNION ALL SELECT 4, 'Contract book',      'USD',     2321000.0
UNION ALL SELECT 5, 'Contract retention', 'percent', 83.67
UNION ALL SELECT 6, 'Win rate',           'percent', 39.97
UNION ALL SELECT 7, 'Open pipeline',      'USD',     1012000.0
UNION ALL SELECT 8, 'Cash floor',         'USD',     1040000.0;


-- ----------------------------------------------------------
-- 3.1-3.3 MARKETPLACE KPI FOUNDATION
-- Working ATs, productive metros, weighted fill rate
-- ----------------------------------------------------------

CREATE TEMP TABLE marketplace_monthly AS
SELECT
  month,
  SUM(working_ats) AS working_ats,
  COUNT(*) AS all_metros,

  COUNTIF(
    working_ats >= 25
    AND SAFE_DIVIDE(shifts_filled, shifts_posted) >= 0.75
  ) AS productive_metros,

  SUM(shifts_posted) AS shifts_posted,
  SUM(shifts_filled) AS shifts_filled,
  SUM(shifts_posted - shifts_filled) AS unfilled_shifts,

  SAFE_DIVIDE(
    SUM(shifts_filled),
    SUM(shifts_posted)
  ) AS weighted_fill_rate,

  AVG(supplied_fill_rate) AS simple_avg_fill_rate

FROM `go4stage2.go4.stg_marketplace`
WHERE month IN (prior_month, report_month)
GROUP BY month;


-- ----------------------------------------------------------
-- 3.4 CONTRACT BOOK
-- Active annual contract value at month-end
-- ----------------------------------------------------------

CREATE TEMP TABLE contract_book AS
SELECT
    month_end,
    COUNT(c.contract_id) AS active_contracts,
    COALESCE(
        SUM(c.annual_value_usd), 0
    ) AS book_value

FROM UNNEST([prior_end, report_end]) AS month_end

LEFT JOIN `go4stage2.go4.stg_contracts` c
    ON c.start_date <= month_end
   AND c.end_date >= month_end

GROUP BY month_end;


-- ----------------------------------------------------------
-- 3.5 RETENTION
-- Eligible contracts: ended during 2026 YTD
-- ----------------------------------------------------------

CREATE TEMP TABLE renewal_cohort AS
SELECT
  contract_id,
  account,
  segment,
  metro,
  end_date,
  annual_value_usd,
  renewal_status

FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN year_start AND report_end;


-- ----------------------------------------------------------
-- 3.6 WIN RATE
-- Closed opportunities during 2026 YTD
-- ----------------------------------------------------------

CREATE TEMP TABLE closed_ytd AS
SELECT *
FROM `go4stage2.go4.stg_pipeline`
WHERE result IN ('Won', 'Lost')
  AND closed_date BETWEEN year_start AND report_end;


-- ----------------------------------------------------------
-- 3.7 OPEN PIPELINE
-- CRM extract is dated October 1. No deal in the extract was
-- created or closed after 09/30, so it equals the 09/30 position.
-- ----------------------------------------------------------

CREATE TEMP TABLE open_pipeline AS
SELECT *
FROM `go4stage2.go4.stg_pipeline`
WHERE result = 'Open';

-- Find suspected duplicate OPEN opportunities.
-- These are review candidates, not confirmed duplicates.

CREATE TEMP TABLE suspected_duplicates AS

WITH ranked AS (
  SELECT
    deal_id,
    account,
    contact,
    scope,
    value_usd,
    notes,

    ROW_NUMBER() OVER (
      PARTITION BY
        LOWER(TRIM(account)),
        LOWER(TRIM(contact)),
        LOWER(TRIM(scope)),
        value_usd
      ORDER BY deal_id
    ) AS duplicate_rank,

    COUNT(*) OVER (
      PARTITION BY
        LOWER(TRIM(account)),
        LOWER(TRIM(contact)),
        LOWER(TRIM(scope)),
        value_usd
    ) AS matching_records

  FROM open_pipeline
)

SELECT
  deal_id,
  account,
  contact,
  scope,
  value_usd,
  notes,
  matching_records

FROM ranked
WHERE duplicate_rank > 1;


-- ----------------------------------------------------------
-- 3.8-3.9 CONSOLIDATED BOARD RECONCILIATION
-- Status is calculated from the numbers only; explanations go in
-- the note column.
-- ----------------------------------------------------------

CREATE TEMP TABLE board_reconciliation AS

WITH calculated AS (

  SELECT
    'Working ATs' AS metric,
    CAST(working_ats AS FLOAT64) AS calculated_value,
    'Marketplace' AS source,
    'Sum across metros; assumes no AT works in two metros (needs AT-level data to confirm)' AS note
  FROM marketplace_monthly
  WHERE month = report_month

  UNION ALL

  SELECT
    'Productive metros',
    CAST(productive_metros AS FLOAT64),
    'Marketplace',
    'Metros with at least 25 working ATs and fill (filled / posted) of at least 75%'
  FROM marketplace_monthly
  WHERE month = report_month

  UNION ALL

  SELECT
    'Fill rate',
    ROUND(100 * weighted_fill_rate, 2),
    'Marketplace',
    CONCAT(
      'Draft averaged metro rates (', CAST(ROUND(100 * simple_avg_fill_rate, 2) AS STRING),
      '%), letting tiny metros count as much as large ones; definition is total filled / total posted. ',
      'See SUPPORT 0 for the "best month of the year" claim'
    )
  FROM marketplace_monthly
  WHERE month = report_month

  UNION ALL

  SELECT
    'Contract book',
    CAST(book_value AS FLOAT64),
    'Contracts',
    'Annual value of contracts active on the last day of the month'
  FROM contract_book
  WHERE month_end = report_end

  UNION ALL

  SELECT
    'Contract retention',
    ROUND(
      100 * SAFE_DIVIDE(
        COUNTIF(renewal_status = 'Renewed'),
        COUNT(*)
      ), 2
    ),
    'Contracts',
    CONCAT(
      'Definition: renewed / contracts due (ended ', CAST(year_start AS STRING), ' to ', CAST(report_end AS STRING),
      '), ', CAST(COUNTIF(renewal_status = 'Renewed') AS STRING), ' of ', CAST(COUNT(*) AS STRING),
      '. Draft divided by all contracts, counting those not yet due as retained (see SUPPORT 5)'
    )
  FROM renewal_cohort

  UNION ALL

  SELECT
    'Win rate',
    ROUND(
      100 * SAFE_DIVIDE(
        COUNTIF(result = 'Won'),
        COUNT(*)
      ), 2
    ),
    'Pipeline',
    CONCAT(
      'By count: ', CAST(COUNTIF(result = 'Won') AS STRING), ' won of ', CAST(COUNT(*) AS STRING),
      ' closed. Draft figure is win rate by value (',
      CAST(ROUND(100 * SAFE_DIVIDE(SUM(IF(result = 'Won', value_usd, 0)), SUM(value_usd)), 2) AS STRING),
      '%) under a by-count label (see SUPPORT 7)'
    )
  FROM closed_ytd

  UNION ALL

  SELECT
    'Open pipeline',
    CAST(SUM(value_usd) AS FLOAT64),
    'Pipeline',
    CONCAT(
      'Raw CRM total, ',
      CAST(COUNT(*) AS STRING),
      ' open opportunities. ',
      'Potential duplicates are reviewed separately ',
      'in SUPPORT 9. No unconfirmed exclusions applied.'
    )

  FROM open_pipeline

  UNION ALL

  SELECT
    'Cash floor',
    CAST(NULL AS FLOAT64),
    'Finance forecast not supplied',
    "From Finance's 09/28 cash forecast, not in the data pack. Ask Finance which retention and pipeline figures it assumes"
),

-- What a metric would be if open data-quality questions were
-- resolved. Shown next to the reported value, never in place of it.
sensitivity AS (
  SELECT
    'Open pipeline' AS metric,
    CAST(SUM(IF(d.deal_id IS NULL, o.value_usd, 0)) AS FLOAT64) AS if_candidates_confirmed
  FROM open_pipeline o
  LEFT JOIN suspected_duplicates d ON d.deal_id = o.deal_id
)

SELECT
  v.sort_order,
  v.metric,
  v.unit,
  v.draft_value,
  c.calculated_value,
  ROUND(c.calculated_value - v.draft_value, 2) AS variance,
  s.if_candidates_confirmed,
  c.source,

  -- Status uses the numbers only. PENDING REVIEW appears when the
  -- reported value matches but would change if a data-quality
  -- candidate were confirmed.
  CASE
    WHEN c.calculated_value IS NULL
      THEN 'NOT VERIFIED'
    WHEN ABS(c.calculated_value - v.draft_value) < 0.005
     AND ABS(COALESCE(s.if_candidates_confirmed, c.calculated_value) - c.calculated_value) >= 0.005
      THEN 'MATCH, PENDING REVIEW'
    WHEN ABS(c.calculated_value - v.draft_value) < 0.005
      THEN 'MATCH'
    ELSE 'DISCREPANCY'
  END AS audit_status,

  c.note

FROM draft_values v
LEFT JOIN calculated c ON c.metric = v.metric
LEFT JOIN sensitivity s ON s.metric = v.metric;


-- Output 1: Board reconciliation (the corrected dashboard)
SELECT * EXCEPT (sort_order)
FROM board_reconciliation
ORDER BY sort_order;


-- ----------------------------------------------------------
-- SUPPORT 0: FILL RATE EVERY MONTH THIS YEAR
-- Tests the draft's "best month of the year" claim.
-- Data starts in April 2026.
-- ----------------------------------------------------------

SELECT
  month,
  SUM(shifts_posted) AS shifts_posted,
  SUM(shifts_filled) AS shifts_filled,
  ROUND(100 * SAFE_DIVIDE(SUM(shifts_filled), SUM(shifts_posted)), 2) AS fill_pct,
  ROUND(100 * AVG(supplied_fill_rate), 2) AS draft_method_pct

FROM `go4stage2.go4.stg_marketplace`
WHERE month BETWEEN FORMAT_DATE('%Y-%m', year_start) AND report_month
GROUP BY month
ORDER BY month;


-- ----------------------------------------------------------
-- SUPPORT 1: AUGUST VS SEPTEMBER MARKETPLACE
-- ----------------------------------------------------------

SELECT
  month,
  working_ats,
  productive_metros,
  shifts_posted,
  shifts_filled,
  unfilled_shifts,
  ROUND(100 * weighted_fill_rate, 2) AS fill_pct,
  ROUND(100 * simple_avg_fill_rate, 2) AS draft_method_pct

FROM marketplace_monthly
ORDER BY month;


-- ----------------------------------------------------------
-- SUPPORT 2: WORKING AT CHANGE BY METRO
-- ----------------------------------------------------------

SELECT
  COALESCE(s.metro, a.metro) AS metro,
  a.working_ats AS august_ats,
  s.working_ats AS september_ats,

  COALESCE(s.working_ats, 0)
    - COALESCE(a.working_ats, 0) AS at_change

FROM (
  SELECT metro, working_ats
  FROM `go4stage2.go4.stg_marketplace`
  WHERE month = report_month
) s

FULL OUTER JOIN (
  SELECT metro, working_ats
  FROM `go4stage2.go4.stg_marketplace`
  WHERE month = prior_month
) a
  ON s.metro = a.metro

ORDER BY at_change DESC;


-- ----------------------------------------------------------
-- SUPPORT 3: NONPRODUCTIVE METROS
-- ----------------------------------------------------------

SELECT
  metro,
  working_ats,
  shifts_posted,
  shifts_filled,
  shifts_posted - shifts_filled AS unfilled_shifts,
  ROUND(
    100 * SAFE_DIVIDE(shifts_filled, shifts_posted), 2
  ) AS fill_rate_pct

FROM `go4stage2.go4.stg_marketplace`
WHERE month = report_month
  AND NOT COALESCE(
    working_ats >= 25
    AND SAFE_DIVIDE(shifts_filled, shifts_posted) >= 0.75,
    FALSE
  )

ORDER BY unfilled_shifts DESC;


-- ----------------------------------------------------------
-- SUPPORT 4: CONTRACT BOOK BRIDGE
-- ----------------------------------------------------------

WITH movements AS (

  SELECT
    'Ended' AS movement,
    contract_id,
    account,
    segment,
    -annual_value_usd AS book_change
  FROM `go4stage2.go4.stg_contracts`
  WHERE end_date >= prior_end
    AND end_date < report_end

  UNION ALL

  SELECT
    'Started',
    contract_id,
    account,
    segment,
    annual_value_usd
  FROM `go4stage2.go4.stg_contracts`
  WHERE start_date > prior_end
    AND start_date <= report_end
)

SELECT *
FROM movements
ORDER BY movement, book_change;


-- ----------------------------------------------------------
-- SUPPORT 5: RETENTION METHOD COMPARISON
-- ----------------------------------------------------------

WITH draft_method AS (
  SELECT
    SAFE_DIVIDE(
      COUNTIF(renewal_status <> 'Churned'),
      COUNT(*)
    ) AS draft_method_rate
  FROM `go4stage2.go4.stg_contracts`
),

eligible_method AS (
  SELECT
    COUNT(*) AS contracts_due,
    COUNTIF(renewal_status = 'Renewed') AS renewed,
    COUNTIF(renewal_status = 'Churned') AS churned,

    SAFE_DIVIDE(
      COUNTIF(renewal_status = 'Renewed'),
      COUNT(*)
    ) AS eligible_retention_rate,

    SUM(annual_value_usd) AS value_due,

    SUM(IF(
      renewal_status = 'Renewed',
      annual_value_usd, 0
    )) AS old_value_retained

  FROM renewal_cohort
)

SELECT
  ROUND(100 * d.draft_method_rate, 2)
    AS draft_method_pct,

  e.contracts_due,
  e.renewed,
  e.churned,

  ROUND(100 * e.eligible_retention_rate, 2)
    AS eligible_retention_pct,

  e.value_due,
  e.old_value_retained,

  ROUND(
    100 * SAFE_DIVIDE(
      e.old_value_retained, e.value_due
    ), 2
  ) AS gross_value_retention_pct

FROM draft_method d
CROSS JOIN eligible_method e;


-- ----------------------------------------------------------
-- SUPPORT 6: RENEWAL VALUE INCLUDING PRICE CHANGES
-- Avoid multiplying eligible rows through a direct join.
-- ----------------------------------------------------------

WITH renewal_values AS (
  SELECT
    o.contract_id,
    o.account,
    o.annual_value_usd AS old_value,
    o.renewal_status,

    (
      SELECT SUM(n.annual_value_usd)
      FROM `go4stage2.go4.stg_contracts` n
      WHERE n.account = o.account
        AND n.start_date =
          DATE_ADD(o.end_date, INTERVAL 1 DAY)
    ) AS successor_value

  FROM renewal_cohort o
)

SELECT
  COUNT(*) AS contracts_due,
  SUM(old_value) AS value_due,

  SUM(IF(
    renewal_status = 'Renewed',
    old_value, 0
  )) AS retained_old_value,

  SUM(IF(
    renewal_status = 'Renewed',
    COALESCE(successor_value, 0), 0
  )) AS renewed_value,

  ROUND(
    100 * SAFE_DIVIDE(
      SUM(IF(
        renewal_status = 'Renewed',
        COALESCE(successor_value, 0), 0
      )),
      SUM(old_value)
    ), 2
  ) AS renewal_cohort_value_retention_pct

FROM renewal_values;


-- ----------------------------------------------------------
-- SUPPORT 7: WIN RATE METHODS
-- ----------------------------------------------------------

SELECT
  COUNT(*) AS closed_deals,
  COUNTIF(result = 'Won') AS won,
  COUNTIF(result = 'Lost') AS lost,

  ROUND(
    100 * SAFE_DIVIDE(
      COUNTIF(result = 'Won'),
      COUNT(*)
    ), 2
  ) AS win_rate_count_pct,

  ROUND(
    100 * SAFE_DIVIDE(
      SUM(IF(result = 'Won', value_usd, 0)),
      SUM(value_usd)
    ), 2
  ) AS win_rate_value_pct

FROM closed_ytd;


-- ----------------------------------------------------------
-- SUPPORT 8: WIN RATE BY QUARTER
-- ----------------------------------------------------------

SELECT
  EXTRACT(YEAR FROM closed_date) AS year,
  EXTRACT(QUARTER FROM closed_date) AS quarter,

  COUNT(*) AS closed_deals,
  COUNTIF(result = 'Won') AS won_deals,

  ROUND(
    100 * SAFE_DIVIDE(
      COUNTIF(result = 'Won'), COUNT(*)
    ), 2
  ) AS win_rate_count_pct,

  ROUND(
    100 * SAFE_DIVIDE(
      SUM(IF(result = 'Won', value_usd, 0)),
      SUM(value_usd)
    ), 2
  ) AS win_rate_value_pct

FROM closed_ytd
GROUP BY year, quarter
ORDER BY year, quarter;


-- ----------------------------------------------------------
-- SUPPORT 9: OPEN PIPELINE DUPLICATE SENSITIVITY
-- Candidates come from suspected_duplicates (3.7), not a typed-in
-- deal ID, so next month's candidates are caught. The reported
-- pipeline stays at the CRM value until the business confirms.
-- ----------------------------------------------------------

SELECT
  COUNT(*) AS reported_open_deals,
  SUM(o.value_usd) AS reported_pipeline,

  COUNTIF(d.deal_id IS NULL)
    AS deals_if_confirmed,

  SUM(IF(
    d.deal_id IS NULL,
    o.value_usd, 0
  )) AS pipeline_if_confirmed,

  SUM(IF(
    d.deal_id IS NOT NULL,
    o.value_usd, 0
  )) AS value_pending_confirmation,

  STRING_AGG(d.deal_id, ', ') AS suspected_duplicate_ids

FROM open_pipeline o
LEFT JOIN suspected_duplicates d ON d.deal_id = o.deal_id;


-- ----------------------------------------------------------
-- SUPPORT 10: OPEN PIPELINE BY STAGE
-- Preserve the source values until duplicate is confirmed.
-- ----------------------------------------------------------

SELECT
  o.stage,
  COUNT(*) AS open_deals,
  SUM(o.value_usd) AS reported_value,

  SUM(IF(
    d.deal_id IS NULL,
    o.value_usd, 0
  )) AS value_if_confirmed

FROM open_pipeline o
LEFT JOIN suspected_duplicates d ON d.deal_id = o.deal_id
GROUP BY o.stage
ORDER BY CASE o.stage
  WHEN 'Negotiation' THEN 1
  WHEN 'Proposal' THEN 2
  WHEN 'Discovery' THEN 3
  ELSE 4
END;


-- ----------------------------------------------------------
-- SUPPORT 11: CONTRACT BOOK BRIDGE RECONCILIATION
-- Expected difference = 0
-- ----------------------------------------------------------

WITH bridge AS (
  SELECT
    SUM(CASE
      WHEN start_date > prior_end
       AND start_date <= report_end
      THEN annual_value_usd ELSE 0
    END) AS entering,

    SUM(CASE
      WHEN end_date >= prior_end
       AND end_date < report_end
      THEN annual_value_usd ELSE 0
    END) AS exiting
  FROM `go4stage2.go4.stg_contracts`
),

books AS (
  SELECT
    MAX(IF(month_end = prior_end, book_value, NULL))
      AS prior_book,
    MAX(IF(month_end = report_end, book_value, NULL))
      AS current_book
  FROM contract_book
)

SELECT
  prior_book,
  entering,
  exiting,
  current_book,

  prior_book + entering - exiting
    AS expected_current_book,

  current_book
    - (prior_book + entering - exiting)
    AS reconciliation_difference

FROM books
CROSS JOIN bridge;


-- ----------------------------------------------------------
-- SUPPORT 12: CHECK RENEWAL STATUS COMPLETENESS
-- These rows require investigation before finalizing
-- retention. Expected: no rows
-- ----------------------------------------------------------

SELECT
  contract_id,
  account,
  end_date,
  renewal_status

FROM renewal_cohort
WHERE renewal_status IS NULL
   OR renewal_status NOT IN ('Renewed', 'Churned');


-- ----------------------------------------------------------
-- SUPPORT 13: CHECK MULTIPLE RENEWAL SUCCESSORS
-- Expected: no rows
-- ----------------------------------------------------------

SELECT
  o.contract_id,
  o.account,
  COUNT(n.contract_id) AS successor_count

FROM renewal_cohort o

LEFT JOIN `go4stage2.go4.stg_contracts` n
  ON n.account = o.account
 AND n.start_date =
   DATE_ADD(o.end_date, INTERVAL 1 DAY)

GROUP BY o.contract_id, o.account
HAVING COUNT(n.contract_id) > 1;
