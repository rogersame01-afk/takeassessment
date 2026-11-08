--Investigate the Pipeline table
--The denominator of win rate is the sum of closed_ytd_flag, not all opportunities created during the year.
SELECT
    deal_id,
    account,
    segment,
    lead_source,
    result,
    value_usd,
    created_date,
    closed_date,

    CASE
        WHEN result IN ('Won', 'Lost')
         AND closed_date BETWEEN '2026-01-01'
                             AND '2026-09-30'
        THEN 1 ELSE 0
    END AS closed_ytd_flag,

    CASE
        WHEN result = 'Won'
         AND closed_date BETWEEN '2026-01-01'
                             AND '2026-09-30'
        THEN 1 ELSE 0
    END AS won_ytd_flag

FROM `go4_stage2.stg_pipeline`
ORDER BY deal_id;

---Investigate the Contracts table
SELECT
    contract_id,
    account,
    start_date,
    end_date,
    annual_value_usd,
    renewal_status,

    CASE
        WHEN start_date <= '2026-09-30'
         AND end_date >= '2026-09-30'
        THEN 1 ELSE 0
    END AS september_book_flag,

    CASE
        WHEN end_date BETWEEN '2026-01-01'
                          AND '2026-09-30'
         AND renewal_status IN ('Renewed', 'Churned')
        THEN 1 ELSE 0
    END AS renewal_eligible_flag

FROM `go4_stage2.stg_contracts`
ORDER BY contract_id;
/*
 september_book_flag: Does this contract contribute to September's active annual-value book?
renewal_eligible_flag: Has this contract reached an observable renewal decision during 2026 YTD?
*/
--Investigate the Marketplace table

SELECT
    month,
    metro,
    shifts_posted,
    shifts_filled,
    working_ats,

    shifts_posted - shifts_filled
        AS unfilled_shifts,

    ROUND(
        100 * SAFE_DIVIDE(shifts_filled, shifts_posted),
        2
    ) AS calculated_fill_pct,

    CASE
        WHEN working_ats >= 25
         AND SAFE_DIVIDE(shifts_filled, shifts_posted) >= 0.75
        THEN 1 ELSE 0
    END AS productive_flag

FROM `go4_stage2.stg_marketplace`
ORDER BY month, metro;
