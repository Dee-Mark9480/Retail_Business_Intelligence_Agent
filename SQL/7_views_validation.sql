-- ============================================================
-- SQL/7_views_validation.sql
-- Read-only checks for the views in 6_views.sql. Run after that file.
-- Each block is independently executable; the expected value is in
-- the comment below it. Nothing here changes the database.
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
-- expect: Mid-Tier 34,005 / Lost-Dormant 15,831 / Champion 14,899 / Recent Low-Value 14,761 / High-Value Lapsed 14,478 / Repeat Customer 2,122
-- (these are the counts with the customer_key tiebreaker; the earlier 34,007 / 15,832 / 14,904 /
--  14,756 / 14,475 figures came from the pre-tiebreaker view, whose counts shifted between runs)

-- V7: v_rfm_segment_summary — must agree with v_rfm_segments
SELECT SUM(customer_count) AS total_customers, COUNT(*) AS segment_count FROM v_rfm_segment_summary;
-- expect: 96,096 / 6

-- V8: v_delivery_review_by_state — self-contained base-table recomputation
SELECT SUM(n_late) AS total_late_in_view FROM v_delivery_review_by_state;
WITH dr AS (
    SELECT fo.order_key, fo.customer_key, fo.is_late, fr.review_score
    FROM fact_orders fo JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
)
SELECT COUNT(*) FILTER (WHERE dr.is_late) AS total_late_all_states
FROM dr;
-- NOTE: these two numbers are not expected to match. total_late_in_view excludes
-- states below the HAVING >= 20 threshold by design, and both exclude late orders
-- that have no review, so both sit below the KPI's 6,534 late orders.

-- V9: v_delivery_review_by_category — same caveat as V8. An order with items in
-- several categories is counted once per category, so this sum is not an order count.
SELECT SUM(n_late_orders) AS total_late_in_view FROM v_delivery_review_by_category;
