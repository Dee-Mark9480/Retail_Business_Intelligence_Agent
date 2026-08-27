-- Base correlation — should reproduce Week 1's -0.267 (days_late) / -0.334 (delivery_days)
WITH delivered_reviewed AS (
    SELECT
        fo.order_key,
        fo.delivery_days,
        fo.days_late,
        fo.is_late,
        fr.review_score
    FROM fact_orders fo
    JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE
      AND fo.order_status = 'delivered'
      AND fo.delivery_date_missing_flag = FALSE
)
SELECT
    CORR(days_late, review_score) AS corr_days_late,
    CORR(delivery_days, review_score) AS corr_delivery_days,
    ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 2) AS avg_score_on_time,
    ROUND(AVG(review_score) FILTER (WHERE is_late), 2) AS avg_score_late,
    COUNT(*) AS n
FROM delivered_reviewed;

-----------------------------------------------------------------------------------------------------

-- Extension 1: by customer state — where does the lateness/review penalty bite hardest?
WITH delivered_reviewed AS (
    SELECT fo.order_key, fo.customer_key, fo.is_late, fr.review_score
    FROM fact_orders fo
    JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE
      AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
)
SELECT
    dc.state,
    ROUND(AVG(dr.review_score) FILTER (WHERE NOT dr.is_late), 2) AS avg_score_on_time,
    ROUND(AVG(dr.review_score) FILTER (WHERE dr.is_late), 2) AS avg_score_late,
    COUNT(*) FILTER (WHERE dr.is_late) AS n_late
FROM delivered_reviewed dr
JOIN dim_customers dc ON dr.customer_key = dc.customer_key
GROUP BY dc.state
HAVING COUNT(*) FILTER (WHERE dr.is_late) >= 20
ORDER BY (AVG(dr.review_score) FILTER (WHERE NOT dr.is_late) - AVG(dr.review_score) FILTER (WHERE dr.is_late)) DESC;


--------------------------------------------------------------------------------------------------------

-- Extension 2: by product category — item grain, so this goes through fact_order_items
-- NOTE: an order can span multiple categories; review_score gets attributed to EACH
-- category in that order. Legitimate for "which categories co-occur with bad reviews,"
-- NOT valid for summing/averaging into an order-level total (same caution as Step 1 item-grain queries).
WITH delivered_reviewed AS (
    SELECT fo.order_key, fo.is_late, fr.review_score
    FROM fact_orders fo
    JOIN fact_reviews fr ON fo.order_key = fr.order_key
    WHERE fr.is_most_recent_review = TRUE
      AND fo.order_status = 'delivered' AND fo.delivery_date_missing_flag = FALSE
)
SELECT
    COALESCE(p.category_english, 'unknown_category') AS category,-
    ROUND(AVG(dr.review_score) FILTER (WHERE NOT dr.is_late), 2) AS avg_score_on_time,
    ROUND(AVG(dr.review_score) FILTER (WHERE dr.is_late), 2) AS avg_score_late,
    COUNT(DISTINCT dr.order_key) FILTER (WHERE dr.is_late) AS n_late_orders
FROM delivered_reviewed dr
JOIN fact_order_items oi ON dr.order_key = oi.order_key
JOIN dim_products p ON oi.product_key = p.product_key
GROUP BY COALESCE(p.category_english, 'unknown_category')
HAVING COUNT(DISTINCT dr.order_key) FILTER (WHERE dr.is_late) >= 20
ORDER BY (AVG(dr.review_score) FILTER (WHERE NOT dr.is_late) - AVG(dr.review_score) FILTER (WHERE dr.is_late)) DESC
LIMIT 15;