--------- Running monthly revenue + running order count -----------

-- WITH monthly_orders AS (
--     SELECT
--         MAKE_DATE(d.year, d.month, 1) AS month_start,
--         COUNT(*) AS order_count,
--         SUM(fo.total_payment_value) AS revenue
--     FROM fact_orders fo
--     JOIN dim_date d ON fo.purchase_date_key = d.date_key
--     GROUP BY d.year, d.month
-- )
-- SELECT
--     month_start,
--     order_count,
--     revenue,
--     SUM(order_count) OVER (ORDER BY month_start) AS running_order_count,
--     SUM(revenue) OVER (ORDER BY month_start) AS running_revenue
-- FROM monthly_orders
-- ORDER BY month_start;

------------- validation -------------------
-- SELECT COUNT(*) AS total_orders, SUM(total_payment_value) AS total_revenue FROM fact_orders;

------------------------------------------------------------------------------

----------------- Month-over-month revenue growth + order growth -----------------

-- WITH monthly_orders AS (
--     SELECT
--         MAKE_DATE(d.year, d.month, 1) AS month_start,
--         COUNT(*) AS order_count,
--         SUM(fo.total_payment_value) AS revenue
--     FROM fact_orders fo
--     JOIN dim_date d ON fo.purchase_date_key = d.date_key
--     GROUP BY d.year, d.month
-- )
-- SELECT
--     month_start,
--     order_count,
--     revenue,
--     LAG(order_count) OVER (ORDER BY month_start) AS prev_month_orders,
--     ROUND(100.0 * (order_count - LAG(order_count) OVER (ORDER BY month_start))
--           / NULLIF(LAG(order_count) OVER (ORDER BY month_start), 0), 2) AS order_growth_pct,
--     LAG(revenue) OVER (ORDER BY month_start) AS prev_month_revenue,
--     ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month_start))
--           / NULLIF(LAG(revenue) OVER (ORDER BY month_start), 0), 2) AS revenue_growth_pct
-- FROM monthly_orders
-- ORDER BY month_start;

-------------------------------------------------------------------------------------------

--------------- Customer ranking by revenue -------------------------------------------

-- WITH customer_revenue AS (
--     SELECT
--         customer_key,
--         COUNT(*) AS order_count,
--         SUM(total_payment_value) AS total_revenue,
--         MIN(order_purchase_timestamp) AS first_purchase_date,
--         MAX(order_purchase_timestamp) AS last_purchase_date
--     FROM fact_orders
--     GROUP BY customer_key
-- )
-- SELECT
--     customer_key,
--     order_count,
--     total_revenue,
--     RANK() OVER (
--         ORDER BY total_revenue DESC NULLS LAST
--     ) AS revenue_rank,
--     DENSE_RANK() OVER (
--         ORDER BY total_revenue DESC NULLS LAST
--     ) AS revenue_dense_rank,
--     NTILE(100) OVER (
--         ORDER BY total_revenue DESC NULLS LAST
--     ) AS revenue_percentile_bucket
-- FROM customer_revenue
-- ORDER BY revenue_rank
-- LIMIT 20;

------------------- validate --------------------------
-- WITH customer_revenue AS (
--     SELECT
--         customer_key,
--         COUNT(*) AS order_count,
--         SUM(total_payment_value) AS total_revenue,
--         MIN(order_purchase_timestamp) AS first_purchase_date,
--         MAX(order_purchase_timestamp) AS last_purchase_date
--     FROM fact_orders
--     GROUP BY customer_key
-- )
-- SELECT
--     SUM(total_revenue) AS customer_total_revenue,
--     (SELECT SUM(total_payment_value) FROM fact_orders) AS order_total_revenue
-- FROM customer_revenue;

----------------------------------------------------------------------------------------

----------------------- Seller ranking by revenue -----------------------------------
-- WITH seller_revenue AS (
--     SELECT
--         seller_key,
--         COUNT(DISTINCT order_key) AS order_count,
--         COUNT(*) AS item_count,
--         SUM(price) AS total_item_revenue,
--         SUM(freight_value) AS total_freight
--     FROM fact_order_items
--     GROUP BY seller_key
-- )
-- SELECT
--     seller_key,
--     order_count,
--     item_count,
--     total_item_revenue,
--     RANK() OVER (ORDER BY total_item_revenue DESC) AS revenue_rank
-- FROM seller_revenue
-- ORDER BY revenue_rank
-- LIMIT 20;

----------------------------------------------------------------
----------------------- validate ---------------------------------
-- SELECT SUM(price) AS total_item_price, COUNT(*) AS total_items FROM fact_order_items;

------------------------------------------------------------------------------------------

-------------------- Product & category ranking ------------------------------------
-- WITH product_revenue AS (
--     SELECT
--         p.product_key,
--         COALESCE(p.category_english, 'unknown_category') AS category_english,
--         COUNT(*) AS item_count,
--         SUM(oi.price) AS total_revenue
--     FROM fact_order_items oi
--     JOIN dim_products p ON oi.product_key = p.product_key
--     GROUP BY p.product_key, COALESCE(p.category_english, 'unknown_category')
-- ),
-- ranked_products AS (
--     SELECT
--         *,
--         ROW_NUMBER() OVER (PARTITION BY category_english ORDER BY total_revenue DESC) AS rank_in_category
--     FROM product_revenue
-- )
-- SELECT * FROM ranked_products
-- WHERE rank_in_category <= 5
-- ORDER BY category_english, rank_in_category;

----------------------------------------------------------------------------------------
---------------------- Category-level ranking (no partition needed — one flat ranking): ----------
-- WITH category_revenue AS (
--     SELECT
--         COALESCE(p.category_english, 'unknown_category') AS category_english,
--         COUNT(*) AS item_count,
--         SUM(oi.price) AS total_revenue
--     FROM fact_order_items oi
--     JOIN dim_products p ON oi.product_key = p.product_key
--     GROUP BY COALESCE(p.category_english, 'unknown_category')
-- )
-- SELECT
--     category_english,
--     total_revenue,
--     RANK() OVER (ORDER BY total_revenue DESC) AS category_rank
-- FROM category_revenue
-- ORDER BY category_rank
-- LIMIT 15;

----------------- validations -------------------------------

-- WITH category_revenue AS (
--     SELECT
--         COALESCE(p.category_english, 'unknown_category') AS category_english,
--         SUM(oi.price) AS total_revenue
--     FROM fact_order_items oi
--     JOIN dim_products p
--         ON oi.product_key = p.product_key
--     GROUP BY COALESCE(p.category_english, 'unknown_category')
-- )
-- SELECT SUM(total_revenue) AS category_total_revenue
-- FROM category_revenue;
-----------------------------------------------------------------------
-- SELECT COUNT(*) AS null_category_products
-- FROM dim_products
-- WHERE category_english IS NULL;
------------------------------------------------------------------------
-- SELECT SUM(freight_value) AS total_freight
-- FROM fact_order_items;

------------------------------------------------------------------
----------- some checks --------------------

------------------- Confirm customer 49313 --------------------
-- SELECT
--     order_id,
--     customer_key,
--     total_payment_value,
--     order_status
-- FROM fact_orders
-- WHERE customer_key = 49313;

------------------ how many customers have NULL total revenue ---------------
-- SELECT COUNT(*) AS customers_with_null_revenue
-- FROM (
--     SELECT
--         customer_key,
--         SUM(total_payment_value) AS total_revenue
--     FROM fact_orders
--     GROUP BY customer_key
-- ) t
-- WHERE total_revenue IS NULL;

----------------------------- confirm November 2016 --------------------------------------
-- SELECT COUNT(*) AS november_2016_orders
-- FROM fact_orders
-- WHERE purchase_date_key BETWEEN 20161101 AND 20161130;

--------------------------------------------------------------------------------
-- SELECT
--     COUNT(*) AS total_products,
--     COUNT(category_english) AS non_null_category_english,
--     COUNT(*) FILTER (WHERE category_english IS NULL) AS null_category_english
-- FROM dim_products;

----------------------------------------------------------------------------------
SELECT SUM(total_payment_value) FROM fact_orders WHERE order_id IN (
    SELECT order_id FROM fact_orders fo
    WHERE NOT EXISTS (SELECT 1 FROM fact_order_items oi WHERE oi.order_key = fo.order_key)
);


