-- Q2.1 Row counts and date coverage per table
SELECT 'pipeline' AS tbl, COUNT(*) AS n_rows, CAST(MIN(created_date) AS STRING) AS min_date, CAST(MAX(created_date) AS STRING) AS max_date FROM go4stage2.go4.stg_pipeline
UNION ALL SELECT 'contracts', COUNT(*), CAST(MIN(start_date) AS STRING), CAST(MAX(end_date) AS STRING) FROM go4stage2.go4.stg_contrats
UNION ALL SELECT 'marketplace', COUNT(*), MIN(month), MAX(month) FROM go4stage2.go4.stg_marketplace;

-- Q2.2 Primary keys are unique
SELECT 'pipeline' AS tbl, deal_id AS id, COUNT(*) AS n FROM go4stage2.go4.stg_pipeline GROUP BY deal_id HAVING COUNT(*) > 1
UNION ALL SELECT 'contracts', contract_id, COUNT(*) FROM go4stage2.go4.stg_contrats GROUP BY contract_id HAVING COUNT(*) > 1
UNION ALL SELECT 'marketplace', CONCAT(month, ' ', metro), COUNT(*) FROM go4stage2.go4.stg_marketplace GROUP BY month, metro HAVING COUNT(*) > 1;

-- Q2.3 Pipeline: stage, result and closed date agree (open deals have no close date, closed deals do, close is after create)
SELECT deal_id, stage, result, created_date, closed_date
FROM go4stage2.go4.stg_pipeline
WHERE (result = 'Open'  AND (closed_date IS NOT NULL OR stage = 'Closed'))
   OR (result <> 'Open' AND (closed_date IS NULL OR stage <> 'Closed'))
   OR closed_date < created_date
   OR value_usd IS NULL OR value_usd <= 0;

-- Q2.4 Pipeline: the same opportunity entered more than once (same account, contact and scope)
SELECT account, contact, scope, COUNT(*) AS n_deals,
       STRING_AGG(CONCAT(deal_id, ' ', owner, ' $', CAST(CAST(value_usd AS INT64) AS STRING)), ' | ' ORDER BY deal_id) AS deals,
       STRING_AGG(notes, ' | ' ORDER BY deal_id) AS notes
FROM go4stage2.go4.stg_pipeline
GROUP BY account, contact, scope
HAVING COUNT(*) > 1;
/*account	contact	scope	n_deals	deals	notes
Cedar Valley School District	"T. Brennan, Director of Athletics"	AT coverage for North HS and South HS · winter and spring 2027	2	D-1056 R. Patel $96000 | D-1059 M. Ortiz $96000	Proposal sent 08/24. One price covers both campuses. | Separate deal for the second campus.*/

-- Q2.5 Contracts: every term is 12 months (end = start + 1 year - 1 day)
SELECT contract_id, account, start_date, end_date,
       DATE_SUB(DATE_ADD(start_date, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS expected_end
FROM go4stage2.go4.stg_contrats
WHERE end_date <> DATE_SUB(DATE_ADD(start_date, INTERVAL 1 YEAR), INTERVAL 1 DAY);

-- Q2.6 Contracts: renewal status agrees with the 09/30 snapshot (ended means Renewed/Churned, still running means Not yet due)
SELECT contract_id, account, end_date, renewal_status
FROM go4stage2.go4.stg_contrats
WHERE (end_date <= DATE '2026-09-30' AND renewal_status NOT IN ('Renewed', 'Churned'))
   OR (end_date >  DATE '2026-09-30' AND renewal_status <> 'Not yet due');

-- Q2.7 Contracts: every Renewed row has a successor row (same account, starts the day after it ends) and no Churned row does
SELECT o.contract_id, o.account, o.end_date, o.renewal_status, n.contract_id AS successor
FROM go4stage2.go4.stg_contrats o
LEFT JOIN go4stage2.go4.stg_contrats n
  ON n.account = o.account AND n.start_date = DATE_ADD(o.end_date, INTERVAL 1 DAY)
WHERE (o.renewal_status = 'Renewed' AND n.contract_id IS NULL)
   OR (o.renewal_status = 'Churned' AND n.contract_id IS NOT NULL);
-- Q2.8 Won deals reconcile to a contract (same account, same value, contract starts after the deal closed)
SELECT p.deal_id, p.account, p.closed_date, p.value_usd, c.contract_id, c.start_date, c.annual_value_usd, c.metro,
       CASE WHEN c.contract_id IS NULL THEN 'no contract'
            WHEN c.annual_value_usd <> p.value_usd THEN 'value differs'
            WHEN c.start_date < p.closed_date THEN 'starts before close'
            ELSE 'ok' END AS check_result
FROM go4stage2.go4.stg_pipeline p
LEFT JOIN go4stage2.go4.stg_contrats c ON c.account = p.account
WHERE p.result = 'Won'
ORDER BY p.closed_date;

-- Q2.9 New contracts starting Nov 2025 or later with no won deal in the CRM extract (deal created before Sep 2025, or missing from the CRM?)
SELECT c.contract_id, c.account, c.metro, c.start_date, c.annual_value_usd
FROM go4stage2.go4.stg_contrats c
WHERE c.start_date >= DATE '2025-11-01'
  AND NOT EXISTS (SELECT 1 FROM go4stage2.go4.stg_pipeline p WHERE p.account = c.account AND p.result = 'Won')
  AND NOT EXISTS (SELECT 1 FROM go4stage2.go4.stg_contrats o WHERE o.account = c.account AND c.start_date = DATE_ADD(o.end_date, INTERVAL 1 DAY))
ORDER BY c.start_date;
-- Q2.10 Marketplace: supplied fill rate matches filled / posted, filled never exceeds posted
SELECT month, metro, shifts_posted, shifts_filled, supplied_fill_rate,
       ROUND(shifts_filled / shifts_posted, 4) AS fill_rate_calc
FROM go4stage2.go4.stg_marketplace
WHERE ABS(supplied_fill_rate - shifts_filled / shifts_posted) > 0.0001
   OR shifts_filled > shifts_posted;

-- Q2.11 Marketplace: metros per month and tiny metros (small denominators distort an average of rates)
SELECT month, COUNT(*) AS n_metros,
       COUNTIF(working_ats < 25) AS metros_under_25_ats,
       STRING_AGG(CASE WHEN shifts_posted < 100 THEN CONCAT(metro, ' (', CAST(shifts_posted AS STRING), ' shifts)') END, ', ') AS tiny_metros
FROM go4stage2.go4.stg_marketplace
GROUP BY month
ORDER BY month;

-- Q2.12 Every contract metro has marketplace data (coverage is staffed from that metro's AT pool)
SELECT DISTINCT c.metro
FROM go4stage2.go4.stg_contrats c
WHERE c.metro NOT IN (SELECT metro FROM go4stage2.go4.stg_marketplace);
