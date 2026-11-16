-- ============================================================
-- SQL/6_views.sql
-- Warehouse-facing views for the Streamlit dashboard.
-- Every definition below is copied from an already-frozen,
-- independently-validated query in 1_window_function.sql through
-- 5_dashboard_metrics.sql. No new business logic is introduced here.
--
-- Safe to re-run: every view uses CREATE OR REPLACE, so running this
-- file again updates the definitions instead of failing with
-- "relation already exists".
-- Validation queries live in 7_views_validation.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. v_monthly_revenue_trend
-- Source: 5_dashboard_metrics.sql, Metric 1
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_revenue_trend AS
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
CREATE OR REPLACE VIEW v_category_revenue AS
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
CREATE OR REPLACE VIEW v_seller_revenue AS
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
CREATE OR REPLACE VIEW v_customer_historical_value AS
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
CREATE OR REPLACE VIEW v_kpi_summary AS
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
-- Source: 3_RFM.sql, full scored + segmented query. One row per customer.
-- customer_key is a deterministic tiebreaker on both NTILE calls: without
-- it, customers with tied recency/monetary values land in different
-- buckets on different runs, so segment counts change between reruns.
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 7. v_rfm_segment_summary
-- One row per segment, built on top of v_rfm_segments (must be created
-- after it). Keeps the segment-count aggregation in SQL so the dashboard's
-- queries.py still does no GROUP BY of its own.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_rfm_segment_summary AS
SELECT
    rfm_segment,
    COUNT(*) AS customer_count
FROM v_rfm_segments
GROUP BY rfm_segment;

-- ------------------------------------------------------------
-- 8. v_delivery_review_by_state
-- Source: 4_delivery_review_analysis.sql, Extension 1
-- HAVING >= 20 retained (data-quality decision); display ORDER BY dropped.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_delivery_review_by_state AS
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
-- 9. v_delivery_review_by_category
-- Source: 4_delivery_review_analysis.sql, Extension 2
-- HAVING >= 20 retained; display ORDER BY/LIMIT 15 dropped.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_delivery_review_by_category AS
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
