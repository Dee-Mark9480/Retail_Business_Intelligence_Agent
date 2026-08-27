-- ============================================================
-- 05_dashboard_metrics.sql
-- 1. Revenue trend / order trend / AOV
-- ============================================================
-- Grain: fact_orders (one row per order) — safe, no double-counting risk.
-- Revenue = total_payment_value (actual money collected, includes freight).
-- AOV = revenue / order_count, same grain, no mixing with item-price revenue.

SELECT
    MAKE_DATE(d.year, d.month, 1) AS month_start,
    COUNT(*) AS order_count,
    SUM(fo.total_payment_value) AS revenue,
    ROUND(SUM(fo.total_payment_value) / COUNT(*), 2) AS aov
FROM fact_orders fo
JOIN dim_date d ON fo.purchase_date_key = d.date_key
GROUP BY d.year, d.month
ORDER BY month_start;

-- ============================================================
-- VALIDATION
-- ============================================================

-- V1: monthly revenue/order totals must sum to the known validated figures
SELECT
    COUNT(*) AS total_orders,
    SUM(total_payment_value) AS total_revenue
FROM fact_orders;
-- expect: 99,441 / 16,008,872.12

-- V2: close the R$165,318.42 price+freight vs payment_value gap —
-- hypothesis: no-item orders (order failed before items were recorded)
-- still captured payment, contributing to total_payment_value with
-- nothing in fact_order_items to offset it.
SELECT
    COUNT(*) AS orders_with_no_items,
    SUM(fo.total_payment_value) AS revenue_from_no_item_orders
FROM fact_orders fo
WHERE NOT EXISTS (
    SELECT 1 FROM fact_order_items oi WHERE oi.order_key = fo.order_key
);
-- if revenue_from_no_item_orders lands near 165,318.42, gap is explained


-- V3: does the missing-payment order's item value account for the remaining gap?
SELECT
    fo.order_id, fo.total_payment_value,
    SUM(oi.price) AS item_price, SUM(oi.freight_value) AS item_freight
FROM fact_orders fo
JOIN fact_order_items oi ON fo.order_key = oi.order_key
WHERE fo.total_payment_value IS NULL
GROUP BY fo.order_id, fo.total_payment_value;

-- V4: broader check — for orders that have BOTH items and a non-null payment,
-- how well does price+freight actually track total_payment_value?
-- Tells us if the residual is diffuse (many tiny differences, e.g. rounding/discounts)
-- or concentrated (a few outlier orders worth naming specifically).
WITH order_item_totals AS (
    SELECT order_key, SUM(price) + SUM(freight_value) AS item_freight_total
    FROM fact_order_items
    GROUP BY order_key
)
SELECT
    COUNT(*) AS orders_compared,
    SUM(fo.total_payment_value - oit.item_freight_total) AS net_diff,
    SUM(ABS(fo.total_payment_value - oit.item_freight_total)) AS total_abs_diff,
    MAX(ABS(fo.total_payment_value - oit.item_freight_total)) AS max_abs_diff,
    COUNT(*) FILTER (WHERE ABS(fo.total_payment_value - oit.item_freight_total) > 0.01) AS orders_with_any_diff
FROM fact_orders fo
JOIN order_item_totals oit ON fo.order_key = oit.order_key
WHERE fo.total_payment_value IS NOT NULL;

-- ============================================================
-- 05_dashboard_metrics.sql (continued)
-- 2. Top product categories
-- ============================================================
-- Grain: fact_order_items (item-level). Revenue = item price only (SUM(price)),
-- NOT total_payment_value — see Metric 1 reconciliation note.
-- NULL category_english (610 products) surfaced explicitly as 'unknown_category',
-- never silently dropped.

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

-- ============================================================
-- 3. Top sellers
-- ============================================================
-- Grain: fact_order_items (item-level). Same revenue definition as categories.
-- seller_id (natural key) shown for readability; ranked by item revenue.

SELECT
    s.seller_id,
    COUNT(DISTINCT oi.order_key) AS order_count,
    COUNT(*) AS item_count,
    SUM(oi.price) AS item_revenue,
    RANK() OVER (ORDER BY SUM(oi.price) DESC) AS revenue_rank
FROM fact_order_items oi
JOIN dim_sellers s ON oi.seller_key = s.seller_key
GROUP BY s.seller_id
ORDER BY revenue_rank
LIMIT 20;

-- ============================================================
-- VALIDATION
-- ============================================================

-- V5: category revenue must sum EXACTLY to the known item-price total,
-- and item_count across all categories must sum to 112,650 —
-- proves no product/category silently dropped items
WITH category_revenue AS (
    SELECT
        COALESCE(p.category_english, 'unknown_category') AS category,
        COUNT(*) AS item_count,
        SUM(oi.price) AS item_revenue
    FROM fact_order_items oi
    JOIN dim_products p ON oi.product_key = p.product_key
    GROUP BY COALESCE(p.category_english, 'unknown_category')
)
SELECT
    SUM(item_revenue) AS total_category_revenue,
    SUM(item_count) AS total_items_across_categories
FROM category_revenue;
-- expect: 13,591,643.70 / 112,650

-- V6: item_count specifically for the unknown_category bucket —
-- confirms it's populated (not silently empty) and gives its real size
SELECT COUNT(*) AS unknown_category_item_count
FROM fact_order_items oi
JOIN dim_products p ON oi.product_key = p.product_key
WHERE p.category_english IS NULL;

-- V7: seller revenue (ALL sellers, not just top 20) must sum to the same
-- item-price total — proves no seller_key silently dropped items
WITH seller_revenue AS (
    SELECT s.seller_id, COUNT(*) AS item_count, SUM(oi.price) AS item_revenue
    FROM fact_order_items oi
    JOIN dim_sellers s ON oi.seller_key = s.seller_key
    GROUP BY s.seller_id
)
SELECT
    SUM(item_revenue) AS total_seller_revenue,
    SUM(item_count) AS total_items_across_sellers
FROM seller_revenue;
-- expect: 13,591,643.70 / 112,650-- ============================================================


-- ============================================================
-- 05_dashboard_metrics.sql (continued)
-- 4. Historical Customer Value (NOT predictive LTV — see documentation note)
-- ============================================================
SELECT
    customer_key,
    COUNT(*) AS order_count,
    SUM(total_payment_value) AS historical_value,
    MIN(order_purchase_timestamp) AS first_purchase,
    MAX(order_purchase_timestamp) AS last_purchase
FROM fact_orders
GROUP BY customer_key
ORDER BY historical_value DESC NULLS LAST
LIMIT 20;

-- distribution summary for the dashboard KPI card (median is more honest
-- than mean here, given the top-heavy skew top-20 will show)
SELECT
    COUNT(*) AS total_customers,
    ROUND(AVG(historical_value), 2) AS avg_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY historical_value) AS median_value,
    MAX(historical_value) AS max_value
FROM (
    SELECT customer_key, SUM(total_payment_value) AS historical_value
    FROM fact_orders GROUP BY customer_key
) t;

-- ============================================================
-- VALIDATION
-- ============================================================

-- V8: total must reconcile to Step 1's validated figure exactly
SELECT SUM(historical_value) AS total_historical_value
FROM (SELECT customer_key, SUM(total_payment_value) AS historical_value FROM fact_orders GROUP BY customer_key) t;
-- expect: 16,008,872.12

-- V9: exactly one customer with NULL historical_value, and it must be 49313
SELECT customer_key, order_count, historical_value
FROM (
    SELECT customer_key, COUNT(*) AS order_count, SUM(total_payment_value) AS historical_value
    FROM fact_orders GROUP BY customer_key
) t
WHERE historical_value IS NULL;