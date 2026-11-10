-- Step 4 · Where to look first (BigQuery, go4stage2.go4.stg_* tables). Each query tests one hypothesis about the commercial engine.

-- Q4.1 Fill rate by metro, April vs August vs September (which metros drive the company decline?)
SELECT metro,
       ROUND(MAX(IF(month = '2026-04', shifts_filled / shifts_posted, NULL)), 3) AS fill_apr,
       ROUND(MAX(IF(month = '2026-08', shifts_filled / shifts_posted, NULL)), 3) AS fill_aug,
       ROUND(MAX(IF(month = '2026-09', shifts_filled / shifts_posted, NULL)), 3) AS fill_sep,
       MAX(IF(month = '2026-09', shifts_posted - shifts_filled, NULL))           AS unfilled_sep
FROM `go4stage2.go4.stg_marketplace`
GROUP BY metro
ORDER BY unfilled_sep DESC;

-- Q4.2 Demand vs supply growth, April to September (is the problem demand outrunning AT supply?)
SELECT s.metro,
       ROUND(s.shifts_posted / a.shifts_posted - 1, 3) AS posted_growth,
       ROUND(s.working_ats  / a.working_ats  - 1, 3)  AS at_growth,
       ROUND(a.shifts_filled / a.working_ats, 2)       AS filled_per_at_apr,
       ROUND(s.shifts_filled / s.working_ats, 2)       AS filled_per_at_sep,
       ROUND(s.shifts_posted / s.working_ats, 2)       AS posted_per_at_sep
FROM `go4stage2.go4.stg_marketplace` s
JOIN `go4stage2.go4.stg_marketplace` a ON a.metro = s.metro AND a.month = '2026-04'
WHERE s.month = '2026-09'
ORDER BY s.shifts_posted / a.shifts_posted - s.working_ats / a.working_ats DESC;

-- Q4.3 Share of the company's unfilled shifts, September
SELECT
  metro,
  shifts_posted - shifts_filled AS unfilled,
  ROUND(
    100 * (shifts_posted - shifts_filled) /
    NULLIF((SELECT SUM(shifts_posted - shifts_filled)
            FROM `go4stage2.go4.stg_marketplace`
            WHERE month = '2026-09'), 0),
    1) AS pct_of_total_unfilled
FROM `go4stage2.go4.stg_marketplace`
WHERE month = '2026-09'
ORDER BY pct_of_total_unfilled DESC

-- Q4.4: Renewal outcomes by metro and
-- pre-renewal marketplace fulfillment
--
-- Business question:
-- Are contracts more likely to churn in metros
-- with weaker marketplace fulfillment?
--
-- Grain:
-- 1. Contract-level renewal cohort
-- 2. Contract-level pre-renewal fill context
-- 3. Final aggregation: one row per metro
--
-- Important:
-- Metro fill rate is not customer-specific coverage.
-- This analysis identifies associations, not causation.

WITH renewal_cohort AS (
    SELECT
        contract_id,
        account,
        metro,
        segment,
        end_date,
        annual_value_usd,
        renewal_status

    FROM `go4stage2.go4.stg_contracts`

    WHERE end_date BETWEEN DATE '2026-01-01'
                       AND DATE '2026-09-30'
      AND renewal_status IN ('Renewed', 'Churned')
),

contract_fill AS (
    SELECT
        c.contract_id,
        c.account,
        c.metro,
        c.segment,
        c.end_date,
        c.annual_value_usd,
        c.renewal_status,

        COUNT(m.month) AS observed_months,

        SAFE_DIVIDE(
            SUM(m.shifts_filled),
            SUM(m.shifts_posted)
        ) AS pre_renewal_fill_rate

    FROM renewal_cohort c

    LEFT JOIN `go4stage2.go4.stg_marketplace` m
        ON m.metro = c.metro
       AND PARSE_DATE('%Y-%m', m.month)
           BETWEEN DATE_TRUNC(
               DATE_SUB(c.end_date, INTERVAL 2 MONTH),
               MONTH
           )
           AND DATE_TRUNC(c.end_date, MONTH)

    GROUP BY
        c.contract_id,
        c.account,
        c.metro,
        c.segment,
        c.end_date,
        c.annual_value_usd,
        c.renewal_status
)

SELECT
    metro,

    COUNT(*) AS contracts_due,

    COUNTIF(renewal_status = 'Renewed')
        AS renewed,

    COUNTIF(renewal_status = 'Churned')
        AS churned,

    ROUND(
        100 * SAFE_DIVIDE(
            COUNTIF(renewal_status = 'Renewed'),
            COUNT(*)
        ), 2
    ) AS logo_retention_pct,

    SUM(annual_value_usd)
        AS annual_value_due,

    SUM(
        IF(renewal_status = 'Churned',
           annual_value_usd, 0)
    ) AS churned_annual_value,

    COUNTIF(observed_months = 3)
        AS contracts_with_full_fill_history,

    COUNTIF(observed_months BETWEEN 1 AND 2)
        AS contracts_with_partial_fill_history,

    COUNTIF(observed_months = 0)
        AS contracts_without_fill_history,

    ROUND(
        100 * AVG(
            IF(renewal_status = 'Renewed',
               pre_renewal_fill_rate, NULL)
        ), 2
    ) AS avg_fill_renewed_pct,

    ROUND(
        100 * AVG(
            IF(renewal_status = 'Churned',
               pre_renewal_fill_rate, NULL)
        ), 2
    ) AS avg_fill_churned_pct

FROM contract_fill

GROUP BY metro

ORDER BY churned_annual_value DESC;

-- Q4.5 Same split, two groups: Philadelphia + Baltimore vs every other metro
SELECT IF(metro IN ('Philadelphia', 'Baltimore'), 'Philadelphia + Baltimore', 'All other metros') AS grp,
       COUNT(*) AS due, COUNTIF(renewal_status = 'Renewed') AS renewed,
       ROUND(COUNTIF(renewal_status = 'Renewed') / COUNT(*), 3) AS logo_retention,
       ROUND(SUM(IF(renewal_status = 'Renewed', annual_value_usd, 0)) / SUM(annual_value_usd), 3) AS value_retention
FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30'
GROUP BY grp;

-- Q4.6 Renewal outcome by segment (is churn a segment problem rather than a metro problem?)
SELECT segment, COUNT(*) AS due, COUNTIF(renewal_status = 'Renewed') AS renewed,
       ROUND(COUNTIF(renewal_status = 'Renewed') / COUNT(*), 3) AS logo_retention,
       COUNTIF(renewal_status = 'Churned' AND metro IN ('Philadelphia', 'Baltimore')) AS churned_in_phl_bal
FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30'
GROUP BY segment;

-- Q4.7 Renewals coming up next: the book at risk, by renewal window and metro
-- Two windows answer two questions:
--   1. Oct-Dec 2026 = immediate renewal intervention
--   2. Jan-Mar 2027 = longer-term renewal planning
-- Only contracts whose renewal decision was still open at the 09/30 snapshot ('Not yet due').
-- LEFT JOIN: a metro with no September marketplace row is flagged, never dropped from the risk list.
-- A customer who renews early in a later snapshot leaves this list (decision already made).
SELECT IF(c.end_date <= DATE '2026-12-31', '1. Oct-Dec 2026', '2. Jan-Mar 2027') AS renewal_window,
       c.metro,
       COUNT(*) AS contracts,
       CAST(SUM(c.annual_value_usd) AS INT64) AS value_up_for_renewal,
       ROUND(SAFE_DIVIDE(m.shifts_filled, m.shifts_posted), 3) AS metro_fill_sep,
       IF(m.metro IS NULL, 'No September marketplace data', NULL) AS fill_flag,
       STRING_AGG(CONCAT(c.account, ' (', FORMAT_DATE('%Y-%m', c.end_date), ', $', CAST(CAST(c.annual_value_usd / 1000 AS INT64) AS STRING), 'k)'),
                  ' | ' ORDER BY c.account) AS accounts
FROM `go4stage2.go4.stg_contracts` c
LEFT JOIN `go4stage2.go4.stg_marketplace` m
       ON m.metro = c.metro
      AND m.month = '2026-09'
WHERE c.end_date BETWEEN DATE '2026-10-01' AND DATE '2027-03-31'
  AND c.renewal_status = 'Not yet due'
GROUP BY renewal_window, c.metro, m.metro, m.shifts_filled, m.shifts_posted
ORDER BY renewal_window, metro_fill_sep;

-- Q4.8 New business: win rate by lead source and by segment, 2026 YTD
SELECT 'lead_source' AS cut, lead_source AS grp, COUNTIF(result = 'Won') AS won, COUNT(*) AS closed,
       ROUND(COUNTIF(result = 'Won') / COUNT(*), 3) AS win_rate
FROM `go4stage2.go4.stg_pipeline` WHERE result IN ('Won', 'Lost') AND closed_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30'
GROUP BY lead_source
UNION ALL
SELECT 'segment', segment, COUNTIF(result = 'Won'), COUNT(*), ROUND(COUNTIF(result = 'Won') / COUNT(*), 3)
FROM `go4stage2.go4.stg_pipeline` WHERE result IN ('Won', 'Lost') AND closed_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30'
GROUP BY segment
ORDER BY cut, win_rate DESC;

-- Q4.9 Why deals are lost, 2026 YTD (first sentence of the note)
SELECT IF(STRPOS(notes, '.') > 0, SUBSTR(notes, 1, STRPOS(notes, '.') - 1), notes) AS loss_reason,
       COUNT(*) AS deals, CAST(SUM(value_usd) AS INT64) AS value
FROM `go4stage2.go4.stg_pipeline`
WHERE result = 'Lost' AND closed_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30'
GROUP BY loss_reason
ORDER BY deals DESC;

-- Q4.10 Sizing the fill fix: Philadelphia and Baltimore fulfillment scenarios
-- Fixed September demand, README sensitivity of $32,750 annual gross profit per company fill point.
--   75% = back to Go4's productive-metro fill threshold
--   80% = operational improvement beyond that threshold
-- Shifts are whole units, so each metro's gap is rounded up (CEIL).
-- Scenario calculations, not forecasts: intervention cost and feasibility need separate validation.
WITH september AS (
  SELECT
    metro,
    shifts_posted,
    shifts_filled
  FROM `go4stage2.go4.stg_marketplace`
  WHERE month = '2026-09'
),

company_total AS (
  SELECT
    SUM(shifts_posted) AS posted,
    SUM(shifts_filled) AS filled
  FROM september
),

scenarios AS (
  SELECT
    target_fill,

    SUM(
      CAST(
        CEIL(
          GREATEST(
            target_fill * shifts_posted
              - shifts_filled,
            0
          )
        ) AS INT64
      )
    ) AS extra_shifts

  FROM september

  CROSS JOIN UNNEST([0.75, 0.80]) AS target_fill

  WHERE metro IN ('Philadelphia', 'Baltimore')

  GROUP BY target_fill
)

SELECT
  ROUND(100 * target_fill, 0)
    AS metro_target_pct,

  extra_shifts,

  ROUND(
    100 * SAFE_DIVIDE(extra_shifts, posted),
    2
  ) AS company_fill_lift_pp,

  ROUND(
    100 * SAFE_DIVIDE(
      filled + extra_shifts, posted
    ), 2
  ) AS new_company_fill_pct,

  ROUND(
    32750 * 100 *
    SAFE_DIVIDE(extra_shifts, posted),
    0
  ) AS annual_gp_sensitivity_usd

FROM scenarios
CROSS JOIN company_total

ORDER BY target_fill;

-- Q4.11A Retention exposure: what Philadelphia + Baltimore churn cost, and what the next renewals there are worth
SELECT 'Churned in PHL+BAL, 2026 YTD' AS item, COUNT(*) AS contracts, CAST(SUM(annual_value_usd) AS INT64) AS annual_value_usd
FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN DATE '2026-01-01' AND DATE '2026-09-30' AND renewal_status = 'Churned' AND metro IN ('Philadelphia', 'Baltimore')
UNION ALL
SELECT 'Up for renewal in PHL+BAL, Oct-Dec 2026 (immediate)', COUNT(*), CAST(SUM(annual_value_usd) AS INT64)
FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN DATE '2026-10-01' AND DATE '2026-12-31' AND renewal_status = 'Not yet due' AND metro IN ('Philadelphia', 'Baltimore')
UNION ALL
SELECT 'Up for renewal in PHL+BAL, Oct 2026-Mar 2027 (planning)', COUNT(*), CAST(SUM(annual_value_usd) AS INT64)
FROM `go4stage2.go4.stg_contracts`
WHERE end_date BETWEEN DATE '2026-10-01' AND DATE '2027-03-31' AND renewal_status = 'Not yet due' AND metro IN ('Philadelphia', 'Baltimore');

-- Q4.11B: 2026 retention target feasibility
-- As-of date: September 30, 2026
--
-- Distinguishes:
-- 1. Historical outcomes needed to reach 70%
-- 2. Minimum consecutive future renewals needed
-- 3. Renewals required from the actual remaining
--    2026 contract cohort
-- 4. Maximum additional churn allowed
--
-- Contract-term retention, not deduplicated logo retention.
-- Whole-number arithmetic (0.70 = 7/10, 1 - 0.70 = 3/10) so CEIL cannot round a whole answer up by one.
-- max_additional_churn_allowed is NULL when 70% cannot be reached.

WITH retention AS (
    SELECT
        COUNT(*) AS due,
        COUNTIF(renewal_status = 'Renewed')
            AS renewed

    FROM `go4stage2.go4.stg_contracts`

    WHERE end_date BETWEEN DATE '2026-01-01'
                       AND DATE '2026-09-30'
      AND renewal_status IN ('Renewed', 'Churned')
),

remaining_2026 AS (
    SELECT
        COUNT(*) AS due_rest_of_2026,

        COUNTIF(
            metro IN ('Philadelphia', 'Baltimore')
        ) AS due_rest_of_2026_phl_bal

    FROM `go4stage2.go4.stg_contracts`

    WHERE end_date BETWEEN DATE '2026-10-01'
                       AND DATE '2026-12-31'
      AND renewal_status = 'Not yet due'
),

targets AS (
    SELECT
        r.due,
        r.renewed,
        f.due_rest_of_2026,
        f.due_rest_of_2026_phl_bal,

        CAST(
            GREATEST(
                0,
                CEIL(SAFE_DIVIDE(7 * r.due, 10))
                    - r.renewed
            ) AS INT64
        ) AS historical_decisions_needed_to_change,

        CAST(
            GREATEST(
                0,
                CEIL(
                    SAFE_DIVIDE(
                        7 * r.due - 10 * r.renewed,
                        3
                    )
                )
            ) AS INT64
        ) AS min_consecutive_future_renewals,

        CAST(
            GREATEST(
                0,
                CEIL(
                    SAFE_DIVIDE(
                        7 * (r.due + f.due_rest_of_2026)
                            - 10 * r.renewed,
                        10
                    )
                )
            ) AS INT64
        ) AS renewals_needed_rest_of_2026

    FROM retention r
    CROSS JOIN remaining_2026 f
),

final_metrics AS (
    SELECT
        *,

        IF(
            renewals_needed_rest_of_2026 > due_rest_of_2026,
            NULL,
            due_rest_of_2026 - renewals_needed_rest_of_2026
        ) AS max_additional_churn_allowed,

        ROUND(
            100 * SAFE_DIVIDE(renewed, due),
            2
        ) AS current_retention_pct,

        ROUND(
            100 * SAFE_DIVIDE(
                renewed + due_rest_of_2026,
                due + due_rest_of_2026
            ),
            2
        ) AS best_case_2026_retention_pct,

        IF(
            due_rest_of_2026 = 0,
            NULL,
            ROUND(
                100 * SAFE_DIVIDE(
                    renewed + due_rest_of_2026 - 1,
                    due + due_rest_of_2026
                ),
                2
            )
        ) AS if_one_more_churn_2026_retention_pct

    FROM targets
)

SELECT
    *,

    CASE
        WHEN renewals_needed_rest_of_2026
             > due_rest_of_2026
            THEN 'Not reachable in 2026'

        WHEN renewals_needed_rest_of_2026 = 0
            THEN 'Already at or above 70%'

        WHEN max_additional_churn_allowed = 0
            THEN 'Every remaining contract must renew'

        ELSE 'Reachable with some additional churn'
    END AS target_2026_verdict

FROM final_metrics;

-- Q4.12 Metro commercial exposure profile, September (contracts are staffed from the same AT pool)
-- Exploratory only: neither contract count nor contract value per AT measures staffing workload or capacity.
-- A real load analysis needs contracted coverage hours, scheduled shifts, AT hours available and hours delivered (not in the pack).
-- contracts_per_100_ats is a rough contract-to-supply ratio that, unlike value per AT, is not driven by price.
SELECT m.metro, m.working_ats,
       COUNT(c.contract_id) AS active_contracts, CAST(COALESCE(SUM(c.annual_value_usd), 0) AS INT64) AS active_annual_value,
       ROUND(100 * SAFE_DIVIDE(COUNT(c.contract_id), m.working_ats), 2) AS contracts_per_100_ats,
       ROUND(m.shifts_filled / m.working_ats, 2) AS marketplace_shifts_per_at,
       ROUND(m.shifts_filled / m.shifts_posted, 3) AS fill_sep
FROM `go4stage2.go4.stg_marketplace` m
LEFT JOIN `go4stage2.go4.stg_contracts` c ON c.metro = m.metro AND c.start_date <= DATE '2026-09-30' AND c.end_date >= DATE '2026-09-30'
WHERE m.month = '2026-09'
GROUP BY m.metro, m.working_ats, m.shifts_filled, m.shifts_posted
ORDER BY fill_sep;
