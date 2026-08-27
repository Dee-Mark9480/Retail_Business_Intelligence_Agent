
SELECT
    COUNT(DISTINCT customer_key) FILTER (
        WHERE is_genuine_repeat_customer = TRUE
    ) AS genuine_repeat_customers,
    
    COUNT(DISTINCT customer_key) AS total_customers,

    ROUND(
        100.0 *
        COUNT(DISTINCT customer_key) FILTER (
            WHERE is_genuine_repeat_customer = TRUE
        )
        / COUNT(DISTINCT customer_key),
        2
    ) AS genuine_repeat_pct
FROM fact_orders;