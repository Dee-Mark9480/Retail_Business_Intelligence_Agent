-- WITH customer_cohort AS (
--     -- one row per customer: which calendar month did they FIRST buy in?
--     SELECT
--         customer_key,
--         DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
--     FROM fact_orders
--     GROUP BY customer_key
-- ),
-- customer_activity AS (
--     -- every (customer, month) pair in which that customer placed at least one order
--     -- DISTINCT matters: a customer with 3 orders in the same month must count once, not 3x
--     SELECT DISTINCT
--         customer_key,
--         DATE_TRUNC('month', order_purchase_timestamp)::date AS activity_month
--     FROM fact_orders
-- ),
-- cohort_activity AS (
--     SELECT
--         cc.cohort_month,
--         (DATE_PART('year', ca.activity_month) - DATE_PART('year', cc.cohort_month)) * 12
--           + (DATE_PART('month', ca.activity_month) - DATE_PART('month', cc.cohort_month)) AS month_number,
--         COUNT(DISTINCT cc.customer_key) AS active_customers
--     FROM customer_cohort cc
--     JOIN customer_activity ca ON cc.customer_key = ca.customer_key
--     GROUP BY cc.cohort_month, month_number
-- ),
-- cohort_size AS (
--     SELECT cohort_month, COUNT(*) AS cohort_customers
--     FROM customer_cohort
--     GROUP BY cohort_month
-- )
-- SELECT
--     ca.cohort_month,
--     cs.cohort_customers,
--     ca.month_number,
--     ca.active_customers,
--     ROUND(100.0 * ca.active_customers / cs.cohort_customers, 2) AS retention_pct
-- FROM cohort_activity ca
-- JOIN cohort_size cs ON ca.cohort_month = cs.cohort_month
-- ORDER BY ca.cohort_month, ca.month_number;


-------------------------------------------------------------------------------
----------------------- Validation 1 -----------------------------------

-- WITH customer_cohort AS (
--     SELECT
--         customer_key,
--         DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
--     FROM fact_orders
--     GROUP BY customer_key
-- ),
-- customer_activity AS (
--     SELECT DISTINCT
--         customer_key,
--         DATE_TRUNC('month', order_purchase_timestamp)::date AS activity_month
--     FROM fact_orders
-- ),
-- cohort_activity AS (
--     SELECT
--         cc.cohort_month,
--         (
--             DATE_PART('year', ca.activity_month)
--             - DATE_PART('year', cc.cohort_month)
--         ) * 12
--         +
--         (
--             DATE_PART('month', ca.activity_month)
--             - DATE_PART('month', cc.cohort_month)
--         ) AS month_number,
--         COUNT(DISTINCT cc.customer_key) AS active_customers
--     FROM customer_cohort cc
--     JOIN customer_activity ca
--         ON cc.customer_key = ca.customer_key
--     GROUP BY cc.cohort_month, month_number
-- ),
-- cohort_size AS (
--     SELECT cohort_month, COUNT(*) AS cohort_customers
--     FROM customer_cohort
--     GROUP BY cohort_month
-- )
-- SELECT *
-- FROM cohort_activity ca
-- JOIN cohort_size cs
--     ON ca.cohort_month = cs.cohort_month
-- WHERE ca.month_number = 0
--   AND ca.active_customers <> cs.cohort_customers;

----------------------- Validation 2 -----------------------------------
-- WITH customer_cohort AS (
--     SELECT
--         customer_key,
--         DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
--     FROM fact_orders
--     GROUP BY customer_key
-- ),
-- cohort_size AS (
--     SELECT
--         cohort_month,
--         COUNT(*) AS cohort_customers
--     FROM customer_cohort
--     GROUP BY cohort_month
-- )
-- SELECT SUM(cohort_customers) AS total_customers
-- FROM cohort_size;

---------------------------------------------------------------------

-- Blended retention curve: all cohorts combined, by month number
-- (only include cohorts old enough to have reached that month, avoiding the censoring trap above)
-- WITH customer_cohort AS (
--     SELECT
--         customer_key,
--         DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
--     FROM fact_orders
--     GROUP BY customer_key
-- ),

-- customer_activity AS (
--     SELECT DISTINCT
--         customer_key,
--         DATE_TRUNC('month', order_purchase_timestamp)::date AS activity_month
--     FROM fact_orders
-- ),

-- cohort_activity AS (
--     SELECT
--         cc.cohort_month,
--         (
--             DATE_PART('year', ca.activity_month)
--             - DATE_PART('year', cc.cohort_month)
--         ) * 12
--         +
--         (
--             DATE_PART('month', ca.activity_month)
--             - DATE_PART('month', cc.cohort_month)
--         ) AS month_number,
--         COUNT(DISTINCT cc.customer_key) AS active_customers
--     FROM customer_cohort cc
--     JOIN customer_activity ca
--         ON cc.customer_key = ca.customer_key
--     GROUP BY cc.cohort_month, month_number
-- ),

-- cohort_size AS (
--     SELECT
--         cohort_month,
--         COUNT(*) AS cohort_customers
--     FROM customer_cohort
--     GROUP BY cohort_month
-- ),

-- dataset_end AS (
--     SELECT
--         DATE_TRUNC(
--             'month',
--             MAX(order_purchase_timestamp)
--         )::date AS last_month
--     FROM fact_orders
-- )

-- SELECT
--     ca.month_number,
--     SUM(cs.cohort_customers) AS eligible_cohort_customers,
--     SUM(ca.active_customers) AS active_customers,
--     ROUND(
--         100.0 * SUM(ca.active_customers)
--         / NULLIF(SUM(cs.cohort_customers), 0),
--         2
--     ) AS blended_retention_pct
-- FROM cohort_activity ca
-- JOIN cohort_size cs
--     ON ca.cohort_month = cs.cohort_month
-- CROSS JOIN dataset_end de
-- WHERE ca.cohort_month
--       <= de.last_month
--          - (ca.month_number || ' months')::interval
-- GROUP BY ca.month_number
-- ORDER BY ca.month_number;

-----------------------------------------------------------------------------------------
-- Fixed-checkpoint view: month 1 / 3 / 6 / 12 retention per cohort, one row per cohort
-- (much more report-friendly than the full sparse matrix)
-- WITH customer_cohort AS (
--     SELECT customer_key, DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
--     FROM fact_orders GROUP BY customer_key
-- ),
-- customer_activity AS (
--     SELECT DISTINCT customer_key, DATE_TRUNC('month', order_purchase_timestamp)::date AS activity_month
--     FROM fact_orders
-- ),
-- cohort_activity AS (
--     SELECT cc.cohort_month,
--            (DATE_PART('year', ca.activity_month) - DATE_PART('year', cc.cohort_month)) * 12
--              + (DATE_PART('month', ca.activity_month) - DATE_PART('month', cc.cohort_month)) AS month_number,
--            COUNT(DISTINCT cc.customer_key) AS active_customers
--     FROM customer_cohort cc JOIN customer_activity ca ON cc.customer_key = ca.customer_key
--     GROUP BY cc.cohort_month, month_number
-- ),
-- cohort_size AS (
--     SELECT cohort_month, COUNT(*) AS cohort_customers FROM customer_cohort GROUP BY cohort_month
-- )
-- SELECT
--     cs.cohort_month,
--     cs.cohort_customers,
--     ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 1), 0) / cs.cohort_customers, 2) AS m1_retention_pct,
--     ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 3), 0) / cs.cohort_customers, 2) AS m3_retention_pct,
--     ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 6), 0) / cs.cohort_customers, 2) AS m6_retention_pct
-- FROM cohort_size cs
-- LEFT JOIN cohort_activity ca ON cs.cohort_month = ca.cohort_month
-- GROUP BY cs.cohort_month, cs.cohort_customers
-- ORDER BY cs.cohort_month;

------------------------------------------------------------------------------------------

WITH customer_cohort AS (
    SELECT customer_key, DATE_TRUNC('month', MIN(order_purchase_timestamp))::date AS cohort_month
    FROM fact_orders GROUP BY customer_key
),
customer_activity AS (
    SELECT DISTINCT customer_key, DATE_TRUNC('month', order_purchase_timestamp)::date AS activity_month
    FROM fact_orders
),
cohort_activity AS (
    SELECT cc.cohort_month,
           (DATE_PART('year', ca.activity_month) - DATE_PART('year', cc.cohort_month)) * 12
             + (DATE_PART('month', ca.activity_month) - DATE_PART('month', cc.cohort_month)) AS month_number,
           COUNT(DISTINCT cc.customer_key) AS active_customers
    FROM customer_cohort cc JOIN customer_activity ca ON cc.customer_key = ca.customer_key
    GROUP BY cc.cohort_month, month_number
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS cohort_customers FROM customer_cohort GROUP BY cohort_month
),
max_month AS (
    SELECT DATE_TRUNC('month', MAX(order_purchase_timestamp))::date AS last_month FROM fact_orders
)
SELECT
    cs.cohort_month,
    cs.cohort_customers,
    CASE WHEN cs.cohort_month + INTERVAL '1 month' <= (SELECT last_month FROM max_month)
         THEN ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 1), 0) / cs.cohort_customers, 2)
         ELSE NULL END AS m1_retention_pct,
    CASE WHEN cs.cohort_month + INTERVAL '3 month' <= (SELECT last_month FROM max_month)
         THEN ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 3), 0) / cs.cohort_customers, 2)
         ELSE NULL END AS m3_retention_pct,
    CASE WHEN cs.cohort_month + INTERVAL '6 month' <= (SELECT last_month FROM max_month)
         THEN ROUND(100.0 * COALESCE(MAX(ca.active_customers) FILTER (WHERE ca.month_number = 6), 0) / cs.cohort_customers, 2)
         ELSE NULL END AS m6_retention_pct
FROM cohort_size cs
LEFT JOIN cohort_activity ca ON cs.cohort_month = ca.cohort_month
GROUP BY cs.cohort_month, cs.cohort_customers
ORDER BY cs.cohort_month;