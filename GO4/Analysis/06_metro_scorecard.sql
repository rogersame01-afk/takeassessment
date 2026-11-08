-- Step 4b · Metro commercial scorecard (BigQuery Standard SQL, go4stage2.go4.stg_* tables)
--
-- Business question:
--   Which metros combine weak marketplace coverage, lost contract value and
--   contract value coming up for renewal, and what should each one get?
--
-- Grain: one row per metro (every metro in either Marketplace or Contracts).
--
-- Definitions match 04_board_reconciliation.sql:
--   fill               = shifts filled / shifts posted, report month
--   productive metro   = at least 25 working ATs and fill of at least 75%
--   retention cohort   = contracts that ended between Jan 1 and the report date (Renewed or Churned)
--   active book        = contracts with start <= report date <= end
--   renewal exposure   = 'Not yet due' contracts ending in the next 3 months (immediate)
--                        and the next 6 months (planning)
--   fill scenarios     = extra whole shifts to reach 75% / 80% at report-month demand,
--                        valued at the README's $32,750 annual gross profit per company fill point
--
-- Risk tiers are explicit rules, not a weighted score, so each tier maps to one action:
--   Act now           below the productive fill threshold AND (renewals due in 3 months OR churn this year)
--   Protect renewals  fill at or above threshold, but contract value renews in the next 3 months
--   Monitor           churn this year or fill down 3+ points vs baseline, nothing renewing in 3 months
--   Too small to rate fewer than 25 working ATs (fill rates on tiny volumes are noisy)
--   Stable            everything else
--
-- Caveats:
--   Metro fill is not customer-specific coverage; links between fill and churn are associations.
--   Fill scenarios are sensitivities at fixed demand, not forecasts, and exclude intervention cost.
--   Renewal exposure is annual contract revenue, not gross profit.
--
-- Next month: change report_end only.

WITH params AS (
  SELECT
    report_end,
    DATE_TRUNC(report_end, YEAR)                                        AS year_start,
    FORMAT_DATE('%Y-%m', report_end)                                    AS report_month,
    FORMAT_DATE('%Y-%m', DATE_SUB(report_end, INTERVAL 1 MONTH))        AS prior_month,
    FORMAT_DATE('%Y-%m', DATE_SUB(report_end, INTERVAL 5 MONTH))        AS baseline_month,  -- 6-month window start (April for September)
    DATE_ADD(report_end, INTERVAL 1 DAY)                                AS exposure_start,
    LAST_DAY(DATE_ADD(report_end, INTERVAL 3 MONTH))                    AS near_term_end,   -- Dec 31 for September
    LAST_DAY(DATE_ADD(report_end, INTERVAL 6 MONTH))                    AS planning_end,    -- Mar 31 for September
    25    AS productive_min_ats,
    0.75  AS productive_min_fill,
    0.80  AS stretch_fill,
    32750 AS gp_per_company_fill_point
  FROM (SELECT DATE '2026-09-30' AS report_end)
),

marketplace AS (
  SELECT
    m.metro,
    MAX(IF(m.month = p.report_month, m.working_ats,   NULL)) AS working_ats,
    MAX(IF(m.month = p.report_month, m.shifts_posted, NULL)) AS shifts_posted,
    MAX(IF(m.month = p.report_month, m.shifts_filled, NULL)) AS shifts_filled,
    SAFE_DIVIDE(MAX(IF(m.month = p.prior_month,    m.shifts_filled, NULL)),
                MAX(IF(m.month = p.prior_month,    m.shifts_posted, NULL))) AS fill_prior,
    SAFE_DIVIDE(MAX(IF(m.month = p.baseline_month, m.shifts_filled, NULL)),
                MAX(IF(m.month = p.baseline_month, m.shifts_posted, NULL))) AS fill_baseline
  FROM `go4stage2.go4.stg_marketplace` m
  CROSS JOIN params p
  GROUP BY m.metro
),

company AS (
  SELECT
    SUM(shifts_posted)                 AS posted,
    SUM(shifts_filled)                 AS filled,
    SUM(shifts_posted - shifts_filled) AS unfilled
  FROM marketplace
),

contracts AS (
  SELECT
    c.metro,

    -- Retention cohort, year to date
    COUNTIF(c.end_date BETWEEN p.year_start AND p.report_end
            AND c.renewal_status IN ('Renewed', 'Churned'))                    AS due_ytd,
    COUNTIF(c.end_date BETWEEN p.year_start AND p.report_end
            AND c.renewal_status = 'Renewed')                                  AS renewed_ytd,
    COUNTIF(c.end_date BETWEEN p.year_start AND p.report_end
            AND c.renewal_status = 'Churned')                                  AS churned_ytd,
    SUM(IF(c.end_date BETWEEN p.year_start AND p.report_end
           AND c.renewal_status = 'Churned', c.annual_value_usd, 0))           AS churned_value_ytd,

    -- Active book at the report date
    COUNTIF(c.start_date <= p.report_end AND c.end_date >= p.report_end)       AS active_contracts,
    SUM(IF(c.start_date <= p.report_end AND c.end_date >= p.report_end,
           c.annual_value_usd, 0))                                             AS active_book,

    -- Upcoming renewal exposure (decision still open at the snapshot)
    COUNTIF(c.end_date BETWEEN p.exposure_start AND p.near_term_end
            AND c.renewal_status = 'Not yet due')                              AS renewals_next_3m,
    SUM(IF(c.end_date BETWEEN p.exposure_start AND p.near_term_end
           AND c.renewal_status = 'Not yet due', c.annual_value_usd, 0))       AS renewal_value_next_3m,
    COUNTIF(c.end_date BETWEEN p.exposure_start AND p.planning_end
            AND c.renewal_status = 'Not yet due')                              AS renewals_next_6m,
    SUM(IF(c.end_date BETWEEN p.exposure_start AND p.planning_end
           AND c.renewal_status = 'Not yet due', c.annual_value_usd, 0))       AS renewal_value_next_6m

  FROM `go4stage2.go4.stg_contracts` c
  CROSS JOIN params p
  GROUP BY c.metro
),

metros AS (
  SELECT metro FROM marketplace
  UNION DISTINCT
  SELECT metro FROM contracts
),

scored AS (
  SELECT
    x.metro,
    k.working_ats,
    k.shifts_posted,
    k.shifts_filled,
    SAFE_DIVIDE(k.shifts_filled, k.shifts_posted)                   AS fill,
    k.fill_prior,
    k.fill_baseline,
    k.shifts_posted - k.shifts_filled                               AS unfilled_shifts,
    SAFE_DIVIDE(k.shifts_posted - k.shifts_filled, co.unfilled)     AS share_of_unfilled,
    COALESCE(k.working_ats >= p.productive_min_ats
             AND SAFE_DIVIDE(k.shifts_filled, k.shifts_posted) >= p.productive_min_fill, FALSE) AS is_productive,

    COALESCE(t.due_ytd, 0)               AS due_ytd,
    COALESCE(t.renewed_ytd, 0)           AS renewed_ytd,
    COALESCE(t.churned_ytd, 0)           AS churned_ytd,
    COALESCE(t.churned_value_ytd, 0)     AS churned_value_ytd,
    COALESCE(t.active_contracts, 0)      AS active_contracts,
    COALESCE(t.active_book, 0)           AS active_book,
    COALESCE(t.renewals_next_3m, 0)      AS renewals_next_3m,
    COALESCE(t.renewal_value_next_3m, 0) AS renewal_value_next_3m,
    COALESCE(t.renewals_next_6m, 0)      AS renewals_next_6m,
    COALESCE(t.renewal_value_next_6m, 0) AS renewal_value_next_6m,

    CAST(CEIL(GREATEST(p.productive_min_fill * k.shifts_posted - k.shifts_filled, 0)) AS INT64) AS shifts_to_75,
    CAST(CEIL(GREATEST(p.stretch_fill        * k.shifts_posted - k.shifts_filled, 0)) AS INT64) AS shifts_to_80,

    co.posted AS company_posted,
    p.productive_min_ats,
    p.productive_min_fill,
    p.gp_per_company_fill_point

  FROM metros x
  CROSS JOIN params p
  CROSS JOIN company co
  LEFT JOIN marketplace k ON k.metro = x.metro
  LEFT JOIN contracts   t ON t.metro = x.metro
),

tiered AS (
  SELECT
    *,
    CASE
      WHEN working_ats IS NULL OR working_ats < productive_min_ats
        THEN 'Too small to rate'
      WHEN fill < productive_min_fill
           AND (renewal_value_next_3m > 0 OR churned_value_ytd > 0)
        THEN 'Act now'
      WHEN renewal_value_next_3m > 0
        THEN 'Protect renewals'
      WHEN churned_value_ytd > 0
           OR fill - fill_baseline <= -0.03
        THEN 'Monitor'
      ELSE 'Stable'
    END AS risk_tier
  FROM scored
)

SELECT
  metro,
  risk_tier,

  -- Marketplace coverage
  working_ats,
  ROUND(100 * fill, 1)                          AS fill_pct,
  ROUND(100 * (fill - fill_prior), 1)           AS fill_change_vs_prior_month_pts,
  ROUND(100 * (fill - fill_baseline), 1)        AS fill_change_vs_baseline_pts,
  unfilled_shifts,
  ROUND(100 * share_of_unfilled, 1)             AS share_of_company_unfilled_pct,
  is_productive,

  -- Contract retention, year to date
  due_ytd,
  renewed_ytd,
  churned_ytd,
  ROUND(100 * SAFE_DIVIDE(renewed_ytd, due_ytd), 1) AS logo_retention_pct,
  churned_value_ytd,

  -- Book and upcoming renewal exposure
  active_contracts,
  active_book,
  renewals_next_3m,
  renewal_value_next_3m,
  renewals_next_6m,
  renewal_value_next_6m,

  -- Fill scenarios at report-month demand (gross-profit sensitivity, not forecast)
  shifts_to_75,
  ROUND(gp_per_company_fill_point * 100 * SAFE_DIVIDE(shifts_to_75, company_posted), 0) AS gp_sensitivity_at_75_usd,
  shifts_to_80,
  ROUND(gp_per_company_fill_point * 100 * SAFE_DIVIDE(shifts_to_80, company_posted), 0) AS gp_sensitivity_at_80_usd

FROM tiered

ORDER BY
  CASE risk_tier
    WHEN 'Act now'           THEN 1
    WHEN 'Protect renewals'  THEN 2
    WHEN 'Monitor'           THEN 3
    WHEN 'Stable'            THEN 4
    ELSE 5
  END,
  renewal_value_next_3m + churned_value_ytd DESC,
  metro;
