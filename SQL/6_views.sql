-- ============================================================
-- SQL/6_views.sql
-- Warehouse-facing views for the Streamlit dashboard.
-- Every definition below is copied from an already-frozen,
-- independently-validated query in 1_window_function.sql through
-- 5_dashboard_metrics.sql. No new business logic is introduced here.
-- ============================================================

-- ------------------------------------------------------------
-- 1. v_monthly_revenue_trend
-- Source: 5_dashboard_metrics.sql, Metric 1
-- ------------------------------------------------------------
CREATE VIEW v_monthly_revenue_trend AS
SELECT
    MAKE_DATE(d.year, d.month, 1) AS month_start,
    COUNT(*) AS order_count,
    SUM(fo.total_payment_value) AS revenue,
    ROUND(SUM(fo.total_payment_value) / COUNT(*), 2) AS aov
FROM fact_orders fo
JOIN dim_date d ON fo.purchase_date_key = d.date_key
GROUP BY d.year, d.month
ORDER BY month_start;

-- ------------------------------------------------------------
-- 2. v_category_revenue
-- Source: 5_dashboard_metrics.sql, Metric 2 (categories)
-- ------------------------------------------------------------
CREATE VIEW v_category_revenue AS
SELECT
    COALESCE(p.category_english, 'unknown_category') AS category,
    COUNT(DISTINCT oi.order_key) AS order_count,
    COUNT(*) AS item_count,
    SUM(oi.price) AS item_revenue,
    ROUND(100.0 * SUM(oi.price) / SUM(SUM(oi.price)) OVER (), 2) AS pct_of_item_revenue
FROM fact_order_items oi
JOIN dim_products p ON oi.product_key = p.product_key
GROUP BY COALESCE(p.category_english, 'unknown_category')
ORDER BY item_revenue DESC;

-- ------------------------------------------------------------
-- 3. v_seller_revenue
-- Source: 5_dashboard_metrics.sql, Metric 2 (sellers)
-- LIMIT 20 removed — full seller list; dashboard applies LIMIT when needed.
-- ------------------------------------------------------------
CREATE VIEW v_seller_revenue AS
SELECT
    s.seller_id,
    COUNT(DISTINCT oi.order_key) AS order_count,
    COUNT(*) AS item_count,
    SUM(oi.price) AS item_revenue,
    RANK() OVER (ORDER BY SUM(oi.price) DESC) AS revenue_rank
FROM fact_order_items oi
JOIN dim_sellers s ON oi.seller_key = s.seller_key
GROUP BY s.seller_id;

-- ------------------------------------------------------------
-- 4. v_customer_historical_value
-- Source: 5_dashboard_metrics.sql, Historical Customer Value metric
-- LIMIT 20 removed — full customer list. NULL preserved for customer 49313.
-- ------------------------------------------------------------
CREATE VIEW v_customer_historical_value AS
SELECT
    customer_key,
    COUNT(*) AS order_count,
    SUM(total_payment_value) AS historical_value,
    MIN(order_purchase_timestamp) AS first_purchase,
    MAX(order_purchase_timestamp) AS last_purchase
FROM fact_orders
GROUP BY customer_key;

-- ------------------------------------------------------------
-- 5. v_kpi_summary
-- Source: 5_dashboard_metrics.sql, KPI card summary. Single-row view.
-- ------------------------------------------------------------
CREATE VIEW v_kpi_summary AS
SELECT
    SUM(total_payment_value) AS revenue,
    COUNT(*) AS orders,
    COUNT(DISTINCT customer_key) AS customers,
    ROUND(SUM(total_payment_value) / COUNT(*), 2) AS aov,
    ROUND(100.0 * COUNT(DISTINCT customer_key) FILTER (WHERE is_genuine_repeat_customer)
        / COUNT(DISTINCT customer_key), 2) AS genuine_repeat_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*) FILTER (WHERE order_status = 'delivered' AND NOT delivery_date_missing_flag), 0), 2) AS late_delivery_pct
FROM fact_orders;

-- ------------------------------------------------------------
-- 6. v_rfm_segments
-- Source: 3_RFM.sql, full scored + segmented query
-- ------------------------------------------------------------
CREATE VIEW v_rfm_segments AS
WITH customer_rfm_base AS (
    SELECT
        customer_key,
        MAX(order_purchase_timestamp) AS last_purchase_ts,
        COUNT(*) AS order_count,
        BOOL_OR(is_genuine_repeat_customer) AS is_repeat,
        SUM(total_payment_value) AS monetary
    FROM fact_orders
    GROUP BY customer_key
),
snapshot AS (
    SELECT MAX(order_purchase_timestamp) + INTERVAL '1 day' AS snapshot_date
    FROM fact_orders
),
customer_rfm AS (
    SELECT
        b.customer_key, b.order_count, b.is_repeat, b.monetary,
        EXTRACT(DAY FROM (s.snapshot_date - b.last_purchase_ts))::int AS recency_days
    FROM customer_rfm_base b
    CROSS JOIN snapshot s
),
customer_rfm_scored AS (
    SELECT
        *,
        (6 - NTILE(5) OVER (ORDER BY recency_days ASC)) AS r_score,
        NTILE(5) OVER (ORDER BY monetary ASC NULLS FIRST) AS m_score,
        CASE
            WHEN NOT is_repeat THEN 1
            WHEN is_repeat AND order_count = 2 THEN 2
            WHEN is_repeat AND order_count >= 3 THEN 3
        END AS f_score
    FROM customer_rfm
)
SELECT
    customer_key, recency_days, order_count, is_repeat, monetary,
    r_score, f_score, m_score,
    CASE
        WHEN f_score >= 2 THEN 'Repeat Customer'
        WHEN r_score >= 4 AND m_score >= 4 THEN 'Champion (One-Time, High Value, Recent)'
        WHEN r_score >= 4 AND m_score <= 2 THEN 'Recent Low-Value'
        WHEN r_score <= 2 AND m_score >= 4 THEN 'High-Value Lapsed'
        WHEN r_score <= 2 AND m_score <= 2 THEN 'Lost / Dormant'
        ELSE 'Mid-Tier'
    END AS rfm_segment
FROM customer_rfm_scored;

-- ------------------------------------------------------------
-- 7. v_delivery_review_by_state
-- Source: 4_delivery_review_analysis.sql, Extension 1
-- HAVING >= 20 retained (data-quality decision); display ORDER BY dropped.
-- ------------------------------------------------------------
CREATE VIEW v_delivery_review_by_state AS
SELECT
    dc.state,
    ROUND(AVG(dr.review_score) FILTER (WHERE NOT dr.is_late), 2) AS avg_score_on_time,
    ROUND(AVG(dr.review_score) FILTER (WHERE dr.is_late), 2) AS avg_score_late,
    COUNT(*) FILTER (WHERE dr.is_late) AS n_late
FROM (
    SELECT fo.order_key, fo.customer_key, fo.is_late, fr.review_score
    FROM fact_orders fo
    JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE
      AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
) dr
JOIN dim_customers dc ON dr.customer_key = dc.customer_key
GROUP BY dc.state
HAVING COUNT(*) FILTER (WHERE dr.is_late) >= 20;

-- ------------------------------------------------------------
-- 8. v_delivery_review_by_category
-- Source: 4_delivery_review_analysis.sql, Extension 2
-- HAVING >= 20 retained; display ORDER BY/LIMIT 15 dropped.
-- ------------------------------------------------------------
CREATE VIEW v_delivery_review_by_category AS
SELECT
    COALESCE(p.category_english, 'unknown_category') AS category,
    ROUND(AVG(dr.review_score) FILTER (WHERE NOT dr.is_late), 2) AS avg_score_on_time,
    ROUND(AVG(dr.review_score) FILTER (WHERE dr.is_late), 2) AS avg_score_late,
    COUNT(DISTINCT dr.order_key) FILTER (WHERE dr.is_late) AS n_late_orders
FROM (
    SELECT fo.order_key, fo.is_late, fr.review_score
    FROM fact_orders fo
    JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE
      AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
) dr
JOIN fact_order_items oi ON dr.order_key = oi.order_key
JOIN dim_products p ON oi.product_key = p.product_key
GROUP BY COALESCE(p.category_english, 'unknown_category')
HAVING COUNT(DISTINCT dr.order_key) FILTER (WHERE dr.is_late) >= 20;

-- ============================================================
-- VALIDATION — each block is independently executable,
-- no dangling references to CTEs from other statements.
-- ============================================================

-- V1: v_monthly_revenue_trend
SELECT SUM(revenue) AS total_revenue, SUM(order_count) AS total_orders FROM v_monthly_revenue_trend;
-- expect: 16,008,872.12 / 99,441

-- V2: v_category_revenue
SELECT SUM(item_revenue) AS total_revenue, SUM(item_count) AS total_items FROM v_category_revenue;
-- expect: 13,591,643.70 / 112,650
SELECT item_count FROM v_category_revenue WHERE category = 'unknown_category';
-- expect: 1,603

-- V3: v_seller_revenue
SELECT SUM(item_revenue) AS total_revenue, SUM(item_count) AS total_items, COUNT(*) AS seller_count FROM v_seller_revenue;
-- expect: 13,591,643.70 / 112,650 / 3,095

-- V4: v_customer_historical_value
SELECT SUM(historical_value) AS total_value, COUNT(*) AS total_customers FROM v_customer_historical_value;
-- expect: 16,008,872.12 / 96,096
SELECT customer_key, historical_value FROM v_customer_historical_value WHERE historical_value IS NULL;
-- expect: exactly 1 row, customer_key = 49313

-- V5: v_kpi_summary — self-contained, independently recomputed from fact_orders directly
SELECT * FROM v_kpi_summary;
SELECT
    SUM(total_payment_value) AS revenue, COUNT(*) AS orders, COUNT(DISTINCT customer_key) AS customers,
    ROUND(SUM(total_payment_value)/COUNT(*),2) AS aov,
    ROUND(100.0*COUNT(DISTINCT customer_key) FILTER (WHERE is_genuine_repeat_customer)/COUNT(DISTINCT customer_key),2) AS genuine_repeat_pct,
    ROUND(100.0*COUNT(*) FILTER (WHERE is_late)/NULLIF(COUNT(*) FILTER (WHERE order_status='delivered' AND NOT delivery_date_missing_flag),0),2) AS late_delivery_pct
FROM fact_orders;
-- both rows must be identical: 16,008,872.12 / 99,441 / 96,096 / 160.99 / 2.21 / 6.77

-- V6: v_rfm_segments
SELECT COUNT(*) AS total_customers, SUM(monetary) AS total_monetary,
       COUNT(*) FILTER (WHERE is_repeat) AS repeat_customers
FROM v_rfm_segments;
-- expect: 96,096 / 16,008,872.12 / 2,122
SELECT rfm_segment, COUNT(*) FROM v_rfm_segments GROUP BY rfm_segment ORDER BY COUNT(*) DESC;
-- expect: Mid-Tier 34,007 / Lost-Dormant 15,832 / Champion 14,904 / Recent Low-Value 14,756 / High-Value Lapsed 14,475 / Repeat Customer 2,122

-- V7: v_delivery_review_by_state — self-contained base-table recomputation
SELECT SUM(n_late) AS total_late_in_view FROM v_delivery_review_by_state;
WITH dr AS (
    SELECT fo.order_key, fo.customer_key, fo.is_late, fr.review_score
    FROM fact_orders fo JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
)
SELECT COUNT(*) FILTER (WHERE dr.is_late) AS total_late_all_states
FROM dr;
-- NOTE: these will NOT match exactly — total_late_in_view excludes states below
-- the HAVING >= 20 threshold by design. total_late_all_states should equal 6,534
-- (Step 4/KPI's full late-order count); total_late_in_view will be slightly less.

-- V8: v_delivery_review_by_category — same caveat as V7
SELECT SUM(n_late_orders) AS total_late_in_view FROM v_delivery_review_by_category;
SELECT SUM(n_late_orders) AS category_view_total_late FROM v_delivery_review_by_category;

---------------------------------------------------------------------------------------------

-------------------------- correction after few wrong validations ---------------------------
CREATE OR REPLACE VIEW v_rfm_segments AS
WITH customer_rfm_base AS (
    SELECT
        customer_key,
        MAX(order_purchase_timestamp) AS last_purchase_ts,
        COUNT(*) AS order_count,
        BOOL_OR(is_genuine_repeat_customer) AS is_repeat,
        SUM(total_payment_value) AS monetary
    FROM fact_orders
    GROUP BY customer_key
),
snapshot AS (
    SELECT MAX(order_purchase_timestamp) + INTERVAL '1 day' AS snapshot_date
    FROM fact_orders
),
customer_rfm AS (
    SELECT
        b.customer_key, b.order_count, b.is_repeat, b.monetary,
        EXTRACT(DAY FROM (s.snapshot_date - b.last_purchase_ts))::int AS recency_days
    FROM customer_rfm_base b
    CROSS JOIN snapshot s
),
customer_rfm_scored AS (
    SELECT
        *,
        -- customer_key added as a deterministic tiebreaker on both NTILE calls
        (6 - NTILE(5) OVER (ORDER BY recency_days ASC, customer_key ASC)) AS r_score,
        NTILE(5) OVER (ORDER BY monetary ASC NULLS FIRST, customer_key ASC) AS m_score,
        CASE
            WHEN NOT is_repeat THEN 1
            WHEN is_repeat AND order_count = 2 THEN 2
            WHEN is_repeat AND order_count >= 3 THEN 3
        END AS f_score
    FROM customer_rfm
)
SELECT
    customer_key, recency_days, order_count, is_repeat, monetary,
    r_score, f_score, m_score,
    CASE
        WHEN f_score >= 2 THEN 'Repeat Customer'
        WHEN r_score >= 4 AND m_score >= 4 THEN 'Champion (One-Time, High Value, Recent)'
        WHEN r_score >= 4 AND m_score <= 2 THEN 'Recent Low-Value'
        WHEN r_score <= 2 AND m_score >= 4 THEN 'High-Value Lapsed'
        WHEN r_score <= 2 AND m_score <= 2 THEN 'Lost / Dormant'
        ELSE 'Mid-Tier'
    END AS rfm_segment
FROM customer_rfm_scored;

SELECT rfm_segment, COUNT(*) FROM v_rfm_segments GROUP BY rfm_segment ORDER BY COUNT(*) DESC;
