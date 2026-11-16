"""
Data-access layer only. Every function below retrieves from an already-
validated PostgreSQL view (SQL/6_views.sql). No revenue, AOV, RFM scoring,
ranking, or percentage math happens in this file — that logic lives
entirely in the views. ORDER BY / LIMIT here are presentation choices
(what the dashboard shows), never new business definitions.
"""
import pandas as pd
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from db import get_engine


def _read(sql: str, params: dict | None = None) -> pd.DataFrame:
    """
    Single point of query execution and error handling, so each function
    below doesn't repeat its own try/except. A view returning zero rows
    is not an error — pandas already returns an empty DataFrame for that,
    no special-casing needed. This only catches real connection/query failures.
    """
    try:
        return pd.read_sql(text(sql), get_engine(), params=params or {})
    except SQLAlchemyError as e:
        raise RuntimeError(f"Dashboard query failed: {e}") from e


def _clamp(n: int, lo: int = 1, hi: int = 100) -> int:
    return max(lo, min(int(n), hi))


def get_kpi_summary() -> pd.DataFrame:
    return _read("SELECT * FROM v_kpi_summary")


def get_monthly_revenue_trend() -> pd.DataFrame:
    # ORDER BY here guarantees chart order — a view's internal ORDER BY
    # isn't a contractual guarantee once wrapped in an outer SELECT.
    return _read("SELECT * FROM v_monthly_revenue_trend ORDER BY month_start")


def get_category_revenue(top_n: int = 15) -> pd.DataFrame:
    top_n = _clamp(top_n)
    return _read(
        "SELECT * FROM v_category_revenue ORDER BY item_revenue DESC LIMIT :top_n",
        {"top_n": top_n},
    )


def get_seller_revenue(top_n: int = 20) -> pd.DataFrame:
    top_n = _clamp(top_n)
    return _read(
        "SELECT * FROM v_seller_revenue ORDER BY revenue_rank LIMIT :top_n",
        {"top_n": top_n},
    )


def get_customer_historical_value(top_n: int = 20) -> pd.DataFrame:
    # NULLS LAST preserved: customer 49313's unknown value stays last,
    # never silently coerced to zero or dropped.
    top_n = _clamp(top_n)
    return _read(
        "SELECT * FROM v_customer_historical_value ORDER BY historical_value DESC NULLS LAST LIMIT :top_n",
        {"top_n": top_n},
    )


def get_rfm_segments() -> pd.DataFrame:
    # The per-segment count is done in the v_rfm_segment_summary view
    # (SQL/6_views.sql), so no aggregation happens here.
    return _read(
        "SELECT * FROM v_rfm_segment_summary ORDER BY customer_count DESC"
    )


def get_delivery_review_by_state() -> pd.DataFrame:
    return _read(
        "SELECT * FROM v_delivery_review_by_state ORDER BY (avg_score_on_time - avg_score_late) DESC"
    )


def get_delivery_review_by_category(top_n: int = 15) -> pd.DataFrame:
    top_n = _clamp(top_n)
    return _read(
        "SELECT * FROM v_delivery_review_by_category "
        "ORDER BY (avg_score_on_time - avg_score_late) DESC LIMIT :top_n",
        {"top_n": top_n},
    )