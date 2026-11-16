# Retail Business Intelligence Agent

A real-data analytics engineering project built on Olist's Brazilian e-commerce
dataset — raw CSVs → validated PostgreSQL star schema → SQL analytics → a
Streamlit BI dashboard. Weeks 1–3 are documented here; Week 4 (ML + FastAPI)
and the LLM data-analyst agent capstone are tracked separately.

## 1. Project Overview

**What this is:** an end-to-end analytics pipeline over the
[Olist Brazilian E-Commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
(Kaggle) — 99,441 real orders, 2016–2018, across 9 relational source tables.

**Pipeline:** Python EDA/cleaning → Parquet artifacts → PostgreSQL star schema
→ SQL analytics & views → Streamlit dashboard.

**Why it's built this way:** most portfolio projects using this dataset stop
at a notebook. This one is built the way a real analytics team would: proper
dimensional modeling instead of flat tables, transaction-safe ETL with
foreign-key validation, and every metric independently reconciled against an
earlier, differently-computed version of the same number before being trusted.

## 2. Architecture

```
Raw Data (9 Kaggle CSVs)
   ↓
Python EDA / Cleaning        (notebooks/1_EDA.ipynb)
   ↓
Parquet artifacts             (dataset/processed/)
   ↓
PostgreSQL Star Schema        (notebooks/2_RelationalModelling.ipynb, SQL/schema.sql)
   ↓
SQL Analytics / Views         (SQL/1_window_function.sql … SQL/6_views.sql)
   ↓
Streamlit Dashboard            (dashboard/)
```

## 3. Data Warehouse

**Fact tables**

| Table | Grain | Rows | Notes |
|---|---|---|---|
| `fact_orders` | one row per order | 99,441 | order status, dates, payment totals, delivery/lateness flags |
| `fact_order_items` | one row per order line item | 112,650 | product/seller/price/freight — separate from `fact_orders` specifically so item-level analysis (category, seller) never has to duplicate order-level measures across items |
| `fact_reviews` | one row per **retained raw review record** | 99,224 | deliberately **not deduplicated** — see §6 |

**Dimensions**

| Table | Grain | Rows | Notes |
|---|---|---|---|
| `dim_customers` | one row per `customer_unique_id` | 96,096 | Type 1 (most recent order's zip/city/state) |
| `dim_products` | one row per `product_id` | 32,951 | `category_english` nullable (610 products) |
| `dim_sellers` | one row per `seller_id` | 3,095 | |
| `dim_date` | one row per calendar day, 2016–2019 | 1,461 | padded past the data's actual range to safely cover long-delayed deliveries |
| `dim_geolocation` | one row per cleaned zip prefix | 19,001 | confidence-tiered (High 11,847 / Medium 5,148 / Low 2,006); snowflaked off customers/sellers, not joined directly to facts |

**Why this design:**
- **Two fact tables, not one** — `fact_orders` (order-grain KPIs: funnel, lateness, revenue) and `fact_order_items` (item-grain: category/seller revenue) share conformed dimensions rather than forcing one grain to serve both, which would require either losing item detail or duplicating order-level measures across items.
- **`fact_reviews` is a fact, not a dimension** — a review is a business event with its own measure (`review_score`) and its own date, not a reusable attribute. Confirmed necessary by evidence, not assumed: 547 orders (0.55%) genuinely have multiple distinct reviews with different scores/text.
- **Surrogate integer keys** on every dimension, natural keys (e.g. `customer_unique_id`, `product_id`) retained as plain columns for traceability.

## 4. Key Analytical Definitions

- **Revenue** = `SUM(total_payment_value)` from `fact_orders` — actual money collected, includes freight and installment handling.
- **Category / seller revenue** = `SUM(price)` from `fact_order_items` — item price **only**, excludes freight. Deliberately a different figure from Revenue above; see the reconciliation in §6.
- **AOV** = payment revenue ÷ order count, at order grain.
- **Historical Customer Value ≠ predictive LTV.** It is `SUM(total_payment_value)` per customer, to date — an observed figure, not a model of future value. One customer's value is genuinely unknown (`NULL`, one order with no payment record) and is preserved as unknown, never coerced to zero.
- **Genuine repeat customer** = more than one order **and** elapsed time between first and last order > 0 days. This excludes same-day, same-checkout-session order splits (Olist assigns a separate `order_id` per seller in one cart) from counting as "repeat" behavior.
- **RFM Frequency** is a coarse 3-tier score (1 = one-time, 2 = two orders, 3 = three+), not a `NTILE`, because 96.9% of customers are one-time buyers — a finer split would only separate ties arbitrarily.

## 5. Key Findings

- **99,441 orders**, **96,096 unique customers**, **R$16,008,872.12** total payment revenue.
- **2.21% genuine repeat-customer rate** (2,122 customers) — after correcting for same-day cart-split orders, which had inflated the naive figure to 3.12%.
- **6.77% late-delivery rate** (6,534 of 96,470 valid delivered orders).
- **Delivery lateness strongly predicts review score**: on-time orders average 4.29, late orders average 2.27 (corr with `days_late` = −0.267, with total `delivery_days` = −0.334, n = 95,824).
- **Review score is not comparable across order outcomes** — delivered orders average 4.16, but canceled (1.80), unavailable (1.53), and processing (1.26) orders score far lower despite never being received, indicating these reviews reflect the purchase/cancellation experience, not product satisfaction.
- **Cohort retention is extremely low and flat**, not a typical decay curve — month-1-onward retention sits in the 0.1–0.8% range across nearly every cohort, consistent with the low overall repeat rate rather than an early-loyalty-then-drop-off pattern.

## 6. Validation & Data Quality

- **Every fact-table load is transaction-safe**: hard foreign-key validation runs before any `COPY`, the entire ETL executes as one Postgres transaction, and any failure triggers a full rollback rather than a partial load.
- **Real bugs caught during the build, not assumed away:**
  - Pandas silently upcasting nullable integer columns to float (`225` → `"225.0"`) broke Postgres `COPY` for several columns, including date-key FKs — fixed with explicit nullable-`Int64` casting.
  - `RANK()`/`NTILE()` sorting `NULL` values *first* by default caused a customer with an unknown (missing) payment value to falsely rank #1 by revenue — fixed with explicit `NULLS LAST`/`NULLS FIRST`, applied consistently everywhere revenue is ranked.
  - `NTILE(5)` on tied values produced different RFM segment counts across identical reruns of the same query — fixed by adding `customer_key` as an explicit tiebreaker, verified deterministic across repeated runs.
- **Independently cross-validated, not just internally consistent**: the order-status funnel, late-delivery rate, review-score-by-status table, and on-time-vs-late review score were all recomputed directly in SQL against the warehouse and matched the original Week 1 pandas analysis exactly.
- **`NULL` payment handling**: exactly one order has no payment record; its value is preserved as `NULL` throughout every downstream metric, never treated as zero.
- **Missing product categories**: 610 of 32,951 products have no English category; 13 were manually patched via the translation table, the rest are surfaced explicitly as `unknown_category` in every category-level view — never silently dropped.
- **`review_id` is not unique in the source data** — 789 review IDs are each attached to 2–3 different orders/products for the same customer, with identical score/text/date. Documented as observed source behavior; `fact_reviews` is deliberately not deduplicated on this basis.
- **Item-price + freight vs. payment-value reconciliation**: R$13,591,643.70 (items) + R$2,251,909.54 (freight) ≠ R$16,008,872.12 (payment) by R$165,318.88 — fully explained, not left open: R$162,591.95 from 775 orders that captured payment before failing (no item rows exist); −R$143.46 from the one order with items but no payment; R$2,870.39 net rounding/discount difference across 303 orders. The two revenue figures are intentionally treated as separate metrics, not expected to reconcile to one number.

## 7. Dashboard

A Streamlit app (`dashboard/`) connects directly to the PostgreSQL warehouse
via SQLAlchemy/psycopg3. All analytical logic lives in 9 validated SQL views
(`SQL/6_views.sql`, checked by `SQL/7_views_validation.sql`) — the Python layer only retrieves and displays;
`queries.py` performs no aggregation, ranking, or metric calculation.

Sections: **Top KPIs** → **Revenue & Orders** → **Product / Supplier** →
**Customer** → **Operations / Customer Experience**.

*(Screenshot to be added once the layout is finalized.)*

## 8. How to Run

Requires Python 3.12+ and a local PostgreSQL server.

1. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```
2. **Get the data** — download the 9 CSVs from
   [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) into `dataset/raw/`.
3. **Set the database password** — copy `.env.example` to `.env` and set `PGPASSWORD`.
   The code connects as user `postgres` to `localhost:5432`.
4. **Create the database and tables**
   ```bash
   psql -U postgres -c "CREATE DATABASE olist_analytics"
   ```
   ```bash
   psql -U postgres -d olist_analytics -f SQL/schema.sql
   ```
5. **Clean the data** — run `notebooks/1_EDA.ipynb` top to bottom; it writes the
   Parquet files to `dataset/processed/`.
6. **Load the warehouse** — run `notebooks/2_RelationalModelling.ipynb`; it loads all
   dimensions and facts in one transaction.
7. **Create the views**, then check them
   ```bash
   psql -U postgres -d olist_analytics -f SQL/6_views.sql
   ```
   ```bash
   psql -U postgres -d olist_analytics -f SQL/7_views_validation.sql
   ```
8. **Start the dashboard**
   ```bash
   streamlit run dashboard/app.py
   ```

`schema.sql` is run once on an empty database. `6_views.sql` can be re-run at any time.

## Project Structure

```
Retail_Business_Intelligence_Agent/
├── dataset/
│   ├── raw/            # source CSVs (gitignored)
│   └── processed/      # cleaned Parquet artifacts (gitignored)
├── notebooks/
│   ├── 1_EDA.ipynb
│   └── 2_RelationalModelling.ipynb
├── SQL/
│   ├── 1_window_function.sql
│   ├── 2_Cohort_Retention.sql
│   ├── 3_RFM.sql
│   ├── 4_delivery_review_analysis.sql
│   ├── 5_dashboard_metrics.sql
│   ├── 6_views.sql              # the 9 dashboard views (re-runnable)
│   ├── 7_views_validation.sql   # expected-value checks for those views
│   ├── schema.sql               # star schema DDL + dim_date population
│   └── Validation.sql           # genuine-repeat-rate check
├── dashboard/
│   ├── app.py
│   ├── db.py
│   └── queries.py
├── requirements.txt
├── .env.example
└── README.md
```