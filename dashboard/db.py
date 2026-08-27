import os
import streamlit as st
from sqlalchemy import create_engine
from sqlalchemy.engine import URL
from dotenv import load_dotenv

load_dotenv()

@st.cache_resource
def get_engine():
    """
    One cached SQLAlchemy engine for the whole Streamlit session.
    Reuses the same URL.create() + .env pattern already established
    in 2_RelationalModelling.ipynb — no new connection method introduced.
    """
    url = URL.create(
        drivername="postgresql+psycopg",
        username="postgres",
        password=os.getenv("PGPASSWORD"),
        host="localhost",
        port=5432,
        database="olist_analytics",
    )
    return create_engine(url)