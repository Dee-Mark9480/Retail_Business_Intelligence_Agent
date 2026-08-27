-- DROP TABLE IF EXISTS temp_rfm;

-- CREATE TEMP TABLE temp_rfm AS
-- WITH customer_rfm_base AS (
--     SELECT
--         customer_key,
--         MAX(order_purchase_timestamp) AS last_purchase_ts,
--         COUNT(*) AS order_count,
--         BOOL_OR(is_genuine_repeat_customer) AS is_repeat,
--         SUM(total_payment_value) AS monetary
--     FROM fact_orders
--     GROUP BY customer_key
-- ),
-- snapshot AS (
--     SELECT MAX(order_purchase_timestamp) + INTERVAL '1 day' AS snapshot_date
--     FROM fact_orders
-- ),
-- customer_rfm AS (
--     SELECT
--         b.customer_key,
--         b.order_count,
--         b.is_repeat,
--         b.monetary,
--         EXTRACT(DAY FROM (s.snapshot_date - b.last_purchase_ts))::int AS recency_days
--     FROM customer_rfm_base b
--     CROSS JOIN snapshot s
-- ),
-- customer_rfm_scored AS (
--     SELECT
--         *,
--         (6 - NTILE(5) OVER (ORDER BY recency_days ASC)) AS r_score,
--         NTILE(5) OVER (ORDER BY monetary ASC NULLS FIRST) AS m_score,
--         CASE
--             WHEN NOT is_repeat THEN 1
--             WHEN is_repeat AND order_count = 2 THEN 2
--             WHEN is_repeat AND order_count >= 3 THEN 3
--         END AS f_score
--     FROM customer_rfm
-- )
-- SELECT
--     customer_key, recency_days, order_count, is_repeat, monetary,
--     r_score, f_score, m_score,
--     CASE
--         WHEN f_score >= 2 THEN 'Repeat Customer'
--         WHEN r_score >= 4 AND m_score >= 4 THEN 'Champion (One-Time, High Value, Recent)'
--         WHEN r_score >= 4 AND m_score <= 2 THEN 'Recent Low-Value'
--         WHEN r_score <= 2 AND m_score >= 4 THEN 'High-Value Lapsed'
--         WHEN r_score <= 2 AND m_score <= 2 THEN 'Lost / Dormant'
--         ELSE 'Mid-Tier'
--     END AS rfm_segment
-- FROM customer_rfm_scored;


----------------------------------------------------------------------------------
----------------------------- VALIDATION ----------------------------

-- SELECT COUNT(*) FROM temp_rfm;

-- SELECT SUM(monetary) FROM temp_rfm;

-- SELECT COUNT(*) FILTER (WHERE is_repeat) FROM temp_rfm;

--------- Segment sizes
-- SELECT rfm_segment, COUNT(*) 
-- FROM temp_rfm 
-- GROUP BY rfm_segment 
-- ORDER BY COUNT(*) DESC;

-------- Customer 49313 check (expect m_score = 1)
SELECT * 
FROM temp_rfm 
WHERE customer_key = 49313;