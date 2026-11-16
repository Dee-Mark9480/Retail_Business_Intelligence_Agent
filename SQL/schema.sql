

-- ============================================================
-- OLIST ANALYTICS WAREHOUSE — SCHEMA DDL
-- Order: dimensions first, then facts (FK dependency order)
-- ============================================================

-- ---------------------------------------------------
-- DIM_DATE
-- date_key = YYYYMMDD integer surrogate (standard convention)
-- Populated separately via generate_series (see bottom)
-- ---------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT PRIMARY KEY,
    full_date       DATE NOT NULL UNIQUE,
    year            SMALLINT NOT NULL,
    quarter         SMALLINT NOT NULL,
    month           SMALLINT NOT NULL,
    month_name      VARCHAR(10) NOT NULL,
    day             SMALLINT NOT NULL,
    day_of_week     SMALLINT NOT NULL,      -- 0=Sunday .. 6=Saturday
    day_name        VARCHAR(10) NOT NULL,
    is_weekend      BOOLEAN NOT NULL
);

-- ---------------------------------------------------
-- DIM_GEOLOCATION
-- Grain: one cleaned zip_code_prefix. Natural key as PK
-- (no surrogate needed — already unique post-cleaning).
-- Referenced from dim_customers/dim_sellers by natural key,
-- NOT enforced as a hard FK (geolocation coverage is incomplete).
-- ---------------------------------------------------
CREATE TABLE dim_geolocation (
    zip_code_prefix VARCHAR(5) PRIMARY KEY,
    lat             NUMERIC(9,6),
    lon             NUMERIC(9,6),
    n_points_used   INT,
    span_km         NUMERIC(10,2),
    confidence      VARCHAR(10) CHECK (confidence IN ('High','Medium','Low'))
);

-- ---------------------------------------------------
-- DIM_CUSTOMERS
-- Grain: one row per customer_unique_id (Type 1 — most recent
-- order's zip/city/state; ~0.26% of customers had multiple).
-- ---------------------------------------------------
CREATE TABLE dim_customers (
    customer_key        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_unique_id   VARCHAR(32) NOT NULL UNIQUE,
    zip_code_prefix       VARCHAR(5),
    city                   VARCHAR(60),
    state                  CHAR(2)
);

-- ---------------------------------------------------
-- DIM_PRODUCTS
-- Grain: one row per product_id.
-- ---------------------------------------------------
CREATE TABLE dim_products (
    product_key             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id                VARCHAR(32) NOT NULL UNIQUE,
    category_name              VARCHAR(60),   -- original Portuguese, nullable
    category_english            VARCHAR(60),   -- nullable (610 unmatched, 13 manually patched)
    weight_g                     INT,
    length_cm                     INT,
    height_cm                      INT,
    width_cm                        INT,
    photos_qty                       INT,
    name_length                       INT,
    description_length                 INT
);

-- ---------------------------------------------------
-- DIM_SELLERS
-- Grain: one row per seller_id (confirmed already unique in raw data).
-- ---------------------------------------------------
CREATE TABLE dim_sellers (
    seller_key       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id          VARCHAR(32) NOT NULL UNIQUE,
    zip_code_prefix      VARCHAR(5),
    city                   VARCHAR(60),
    state                   CHAR(2)
);

-- ---------------------------------------------------
-- FACT_ORDERS
-- Grain: one row per order_id.
-- review_score deliberately NOT here — lives only in fact_reviews.
-- ---------------------------------------------------
CREATE TABLE fact_orders (
    order_key                          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id                             VARCHAR(32) NOT NULL UNIQUE,

    customer_key                          INT NOT NULL REFERENCES dim_customers(customer_key),
    purchase_date_key                      INT NOT NULL REFERENCES dim_date(date_key),
    delivered_date_key                      INT REFERENCES dim_date(date_key),          -- NULL if not delivered
    estimated_delivery_date_key              INT NOT NULL REFERENCES dim_date(date_key),

    -- full timestamps retained (dim_date is day-grain only)
    order_purchase_timestamp                  TIMESTAMP NOT NULL,
    order_approved_at                          TIMESTAMP,
    order_delivered_carrier_date                TIMESTAMP,
    order_delivered_customer_date                TIMESTAMP,
    order_estimated_delivery_date                 DATE NOT NULL,

    order_status                                   VARCHAR(20) NOT NULL CHECK (
        order_status IN ('created','approved','invoiced','processing',
                          'shipped','delivered','canceled','unavailable')
    ),

    n_items                                          INT,
    total_price                                       NUMERIC(10,2),
    total_freight                                      NUMERIC(10,2),
    total_payment_value                                 NUMERIC(10,2),
    n_payment_methods                                    INT,
    max_installments                                      INT,

    delivery_days                                          INT,
    days_late                                               INT,
    is_late                                                  BOOLEAN,
    delivery_date_missing_flag                                BOOLEAN NOT NULL DEFAULT FALSE,

    -- Customer-level attribute denormalised onto every order of that customer:
    -- TRUE when the customer has >1 order AND first-to-last purchase spans > 0 days
    -- (excludes same-day cart splits). Computed in the ETL, see 2_RelationalModelling.ipynb.
    is_genuine_repeat_customer                                 BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fact_orders_customer   ON fact_orders(customer_key);
CREATE INDEX idx_fact_orders_purchase   ON fact_orders(purchase_date_key);
CREATE INDEX idx_fact_orders_status     ON fact_orders(order_status);
CREATE INDEX idx_fact_orders_is_late    ON fact_orders(is_late);

-- ---------------------------------------------------
-- FACT_ORDER_ITEMS
-- Grain: one row per raw order_items row.
-- ---------------------------------------------------
CREATE TABLE fact_order_items (
    order_item_key   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    order_key           INT NOT NULL REFERENCES fact_orders(order_key),
    order_id               VARCHAR(32) NOT NULL,   -- traceability, not unique alone
    order_item_seq           INT NOT NULL,          -- original order_item_id within the order

    product_key                INT REFERENCES dim_products(product_key),
    seller_key                  INT REFERENCES dim_sellers(seller_key),

    price                         NUMERIC(10,2),
    freight_value                  NUMERIC(10,2),

    UNIQUE (order_key, order_item_seq)
);

CREATE INDEX idx_fact_items_order    ON fact_order_items(order_key);
CREATE INDEX idx_fact_items_product  ON fact_order_items(product_key);
CREATE INDEX idx_fact_items_seller   ON fact_order_items(seller_key);

-- ---------------------------------------------------
-- FACT_REVIEWS
-- Grain: one row per RETAINED RAW review record. No dedup.
-- review_id intentionally NOT UNIQUE — see data quality log.
-- ---------------------------------------------------
CREATE TABLE fact_reviews (
    review_key                       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    review_id                          VARCHAR(32) NOT NULL,   -- non-unique by design

    order_key                            INT NOT NULL REFERENCES fact_orders(order_key),
    order_id                               VARCHAR(32) NOT NULL,
    review_date_key                          INT REFERENCES dim_date(date_key),

    review_creation_date                       TIMESTAMP,
    review_answer_timestamp                      TIMESTAMP,
    review_score                                   SMALLINT CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title                             TEXT,
    review_comment_message                             TEXT,

    has_logistics_keyword                                BOOLEAN NOT NULL DEFAULT FALSE,
    has_refund_keyword                                     BOOLEAN NOT NULL DEFAULT FALSE,
    response_days                                            INT,

    is_most_recent_review                                      BOOLEAN NOT NULL DEFAULT FALSE,
    review_id_reused_across_orders                               BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fact_reviews_order     ON fact_reviews(order_key);
CREATE INDEX idx_fact_reviews_review_id ON fact_reviews(review_id);
CREATE INDEX idx_fact_reviews_score     ON fact_reviews(review_score);

-- ============================================================
-- POPULATE DIM_DATE (2016-01-01 through 2019-12-31)
-- Run once, immediately after table creation.
-- ============================================================
INSERT INTO dim_date (date_key, full_date, year, quarter, month, month_name,
                       day, day_of_week, day_name, is_weekend)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INT,
    d,
    EXTRACT(YEAR FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT,
    EXTRACT(MONTH FROM d)::SMALLINT,
    TO_CHAR(d, 'Month'),
    EXTRACT(DAY FROM d)::SMALLINT,
    EXTRACT(DOW FROM d)::SMALLINT,
    TO_CHAR(d, 'Day'),
    EXTRACT(DOW FROM d) IN (0,6)
FROM generate_series('2016-01-01'::DATE, '2019-12-31'::DATE, '1 day'::INTERVAL) AS d;