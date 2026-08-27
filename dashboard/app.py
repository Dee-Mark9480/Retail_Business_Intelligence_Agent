import streamlit as st
import pandas as pd
import queries as q

st.set_page_config(page_title="Olist Business Intelligence", layout="wide")
st.title("Olist E-Commerce — Business Intelligence Dashboard")
st.caption(
    "Built on a validated PostgreSQL star schema (Weeks 1–3). "
    "All metrics below are computed in SQL views, not in this app."
)

# ============================================================
# 1. TOP KPIs
# ============================================================
kpi = q.get_kpi_summary()

if kpi.empty:
    st.error("KPI summary returned no data — check the database connection.")
else:
    row = kpi.iloc[0]
    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Revenue", f"R$ {row['revenue']:,.2f}")
    c2.metric("Orders", f"{int(row['orders']):,}")
    c3.metric("Customers", f"{int(row['customers']):,}")
    c4.metric("AOV", f"R$ {row['aov']:,.2f}")
    c5.metric("Genuine Repeat Rate", f"{row['genuine_repeat_pct']:.2f}%")

st.divider()

# ============================================================
# 2. REVENUE & ORDERS
# ============================================================
st.header("Revenue & Orders")
st.caption(
    "Revenue here is `total_payment_value` (actual money collected, includes freight) — "
    "not the same figure used for category/seller revenue below, which is item price only. "
    "See README for the full reconciliation between the two."
)

trend = q.get_monthly_revenue_trend()
if trend.empty:
    st.warning("No revenue trend data available.")
else:
    tab1, tab2, tab3 = st.tabs(["Revenue", "Orders", "AOV"])
    with tab1:
        st.line_chart(trend, x="month_start", y="revenue")
    with tab2:
        st.line_chart(trend, x="month_start", y="order_count")
    with tab3:
        st.line_chart(trend, x="month_start", y="aov")

st.divider()

# ============================================================
# 3. PRODUCT / SUPPLIER
# ============================================================
st.header("Product / Supplier")

st.subheader("Top Categories (by item price revenue)")
n_cat = st.slider("Categories to show", 5, 30, 15, key="cat_slider")
cat_df = q.get_category_revenue(top_n=n_cat)
if cat_df.empty:
    st.warning("No category data available.")
else:
    st.bar_chart(cat_df.set_index("category")["item_revenue"])
    with st.expander("View data"):
        st.dataframe(cat_df, width="stretch")
    if "unknown_category" in cat_df["category"].values:
        st.caption(
            "'unknown_category' represents 610 products with no English category "
            "translation in the source data — shown explicitly, not excluded."
        )

st.subheader("Top Sellers (by item price revenue)")
n_sell = st.slider("Sellers to show", 5, 30, 20, key="seller_slider")
seller_df = q.get_seller_revenue(top_n=n_sell)
if seller_df.empty:
    st.warning("No seller data available.")
else:
    st.dataframe(
        seller_df[["seller_id", "order_count", "item_count", "item_revenue", "revenue_rank"]],
        width="stretch",
    )

st.divider()

# ============================================================
# 4. CUSTOMER
# ============================================================
st.header("Customer")

st.subheader("RFM Segments")
rfm_df = q.get_rfm_segments()
if rfm_df.empty:
    st.warning("No RFM segment data available.")
else:
    st.bar_chart(rfm_df.set_index("rfm_segment")["customer_count"])

st.subheader("Historical Customer Value")
st.caption(
    "Observed spend to date, NOT a predictive lifetime-value model. "
    "One customer's value is unknown (missing payment record) and is "
    "shown as such, not treated as zero."
)
n_cust = st.slider("Customers to show", 5, 50, 20, key="cust_slider")
hv_df = q.get_customer_historical_value(top_n=n_cust)
if hv_df.empty:
    st.warning("No customer value data available.")
else:
    display_df = hv_df.copy()
    display_df["historical_value"] = display_df["historical_value"].apply(
        lambda v: "Unknown" if pd.isna(v) else f"R$ {v:,.2f}"
    )
    st.dataframe(
        display_df[["customer_key", "order_count", "historical_value", "first_purchase", "last_purchase"]],
        width="stretch",
    )

st.divider()

# ============================================================
# 5. OPERATIONS / CUSTOMER EXPERIENCE
# ============================================================
st.header("Operations / Customer Experience")

if kpi.empty:
    st.warning("Late delivery rate unavailable.")
else:
    st.metric("Late Delivery Rate", f"{kpi.iloc[0]['late_delivery_pct']:.2f}%")

st.caption(
    "On-time vs. late review scores below are shown only for states/categories "
    "with at least 20 late orders (a data-quality threshold set in Week 3) — "
    "thinner segments are excluded to avoid noisy single-digit-sample comparisons."
)

st.subheader("Delivery Impact on Review Score — by State")
state_df = q.get_delivery_review_by_state()
if state_df.empty:
    st.warning("No state-level delivery/review data available.")
else:
    st.dataframe(state_df, width="stretch")

st.subheader("Delivery Impact on Review Score — by Category")
cat_review_df = q.get_delivery_review_by_category()
if cat_review_df.empty:
    st.warning("No category-level delivery/review data available.")
else:
    st.dataframe(cat_review_df, width="stretch")