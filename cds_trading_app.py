# Install these packages only:
# pip install streamlit mysql-connector-python pandas plotly yfinance

import streamlit as st
import mysql.connector
import pandas as pd
import plotly.graph_objects as go
import yfinance as yf
from datetime import datetime, timedelta

# Database connection configuration
DB_CONFIG = {
    'host': 'localhost',
    'user': 'root',  # Change this to your MySQL username
    'password': 'Shubhang358?',  # Change this to your MySQL password
    'database': 'CDS_Trading_System'
}

# Function to connect to database
@st.cache_resource
def get_database_connection():
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        st.error(f"Database connection failed: {e}")
        return None

# Function to execute queries
def execute_query(query, params=None):
    conn = get_database_connection()
    if conn:
        cursor = conn.cursor(dictionary=True)
        cursor.execute(query, params or ())
        result = cursor.fetchall()
        cursor.close()
        return result
    return []

# Function to execute INSERT/UPDATE queries
def execute_update(query, params=None):
    conn = get_database_connection()
    if conn:
        cursor = conn.cursor()
        cursor.execute(query, params or ())
        conn.commit()
        cursor.close()
        return True
    return False

# Function to call stored procedures
def call_procedure(procedure_name, params=None):
    conn = get_database_connection()
    if conn:
        cursor = conn.cursor(dictionary=True)
        cursor.callproc(procedure_name, params or ())
        results = []
        for result in cursor.stored_results():
            results.extend(result.fetchall())
        cursor.close()
        return results
    return []

# Function to get live stock data
@st.cache_data(ttl=60)  # Cache for 60 seconds
def get_live_stock_data(ticker):
    try:
        stock = yf.Ticker(ticker)
        hist = stock.history(period="5d", interval="1h")
        info = stock.info
        return hist, info
    except Exception as e:
        st.error(f"Error fetching stock data: {e}")
        return None, None

# Page configuration
st.set_page_config(
    page_title="CDS Trading System",
    page_icon="📊",
    layout="wide"
)

# Custom CSS
st.markdown("""
    <style>
    .main-header {
        font-size: 42px;
        font-weight: bold;
        color: #1f77b4;
        text-align: center;
        margin-bottom: 30px;
    }
    .metric-card {
        background-color: #f0f2f6;
        padding: 20px;
        border-radius: 10px;
        margin: 10px 0;
    }
    </style>
""", unsafe_allow_html=True)

# Main header
st.markdown('<p class="main-header">🏦 CDS Trading & Portfolio Management System</p>', unsafe_allow_html=True)

# Sidebar navigation
st.sidebar.title("Navigation")
page = st.sidebar.radio("Select Page", [
    "📊 Dashboard",
    "💼 Trade Execution",
    "📈 Live Market Data",
    "🔍 Query Database",
    "📋 Reports"
])

# ============================================
# PAGE 1: DASHBOARD
# ============================================
if page == "📊 Dashboard":
    st.header("System Dashboard")
    
    # Key Metrics
    col1, col2, col3, col4 = st.columns(4)
    
    with col1:
        contracts = execute_query("SELECT COUNT(*) as count FROM CDS_Contract")
        st.metric("Total Contracts", contracts[0]['count'] if contracts else 0)
    
    with col2:
        trades = execute_query("SELECT COUNT(*) as count FROM Trade")
        st.metric("Total Trades", trades[0]['count'] if trades else 0)
    
    with col3:
        counterparties = execute_query("SELECT COUNT(*) as count FROM Counterparty")
        st.metric("Active Counterparties", counterparties[0]['count'] if counterparties else 0)
    
    with col4:
        total_notional = execute_query("SELECT SUM(notional_amount) as total FROM CDS_Contract")
        notional = total_notional[0]['total'] if total_notional and total_notional[0]['total'] else 0
        st.metric("Total Notional", f"${notional:,.0f}")
    
    st.markdown("---")
    
    # Recent Trades
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("Recent Trades")
        recent_trades = execute_query("""
            SELECT t.trade_id, t.trade_date, t.trade_price, 
                   c.contract_id, re.entity_name,
                   buyer.party_name as buyer, seller.party_name as seller
            FROM Trade t
            JOIN CDS_Contract c ON t.contract_id = c.contract_id
            JOIN Reference_Entity re ON c.ref_entity_id = re.ref_entity_id
            JOIN Counterparty buyer ON t.buyer_party_id = buyer.party_id
            JOIN Counterparty seller ON t.seller_party_id = seller.party_id
            ORDER BY t.trade_date DESC
            LIMIT 10
        """)
        if recent_trades:
            df_trades = pd.DataFrame(recent_trades)
            st.dataframe(df_trades, use_container_width=True, hide_index=True)
        else:
            st.info("No trades found")
    
    with col2:
        st.subheader("Counterparty Exposure")
        exposure_data = call_procedure('generate_exposure_report')
        if exposure_data:
            df_exposure = pd.DataFrame(exposure_data)
            st.dataframe(df_exposure, use_container_width=True, hide_index=True)
        else:
            st.info("No exposure data available")
    
    st.markdown("---")
    
    # Portfolio Positions
    st.subheader("Portfolio Positions by Reference Entity")
    positions = execute_query("""
        SELECT re.entity_name, re.sector, re.country,
               SUM(ABS(pp.net_notional_position)) as total_exposure,
               COUNT(DISTINCT pp.party_id) as num_counterparties
        FROM Portfolio_Position pp
        JOIN CDS_Contract c ON pp.contract_id = c.contract_id
        JOIN Reference_Entity re ON c.ref_entity_id = re.ref_entity_id
        GROUP BY re.entity_name, re.sector, re.country
        ORDER BY total_exposure DESC
    """)
    
    if positions:
        df_positions = pd.DataFrame(positions)
        
        # Create bar chart
        fig = go.Figure(data=[
            go.Bar(x=df_positions['entity_name'], y=df_positions['total_exposure'],
                   marker_color='lightblue')
        ])
        fig.update_layout(
            title="Exposure by Reference Entity",
            xaxis_title="Reference Entity",
            yaxis_title="Total Exposure ($)",
            height=400
        )
        st.plotly_chart(fig, use_container_width=True)

# ============================================
# PAGE 2: TRADE EXECUTION
# ============================================
elif page == "💼 Trade Execution":
    st.header("Execute CDS Trade")
    
    st.markdown("""
    ### Understanding CDS Trading
    A **Credit Default Swap (CDS)** is a financial derivative that allows an investor to "swap" or transfer 
    the credit risk of a reference entity. 
    
    - **Buyer (Protection Buyer)**: Pays periodic premiums and receives payment if the reference entity defaults
    - **Seller (Protection Seller)**: Receives premiums and must pay if a credit event occurs
    - **Reference Entity**: The company/sovereign whose credit risk is being traded
    """)
    
    st.markdown("---")
    
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("Trade Details")
        
        # Get available contracts
        contracts = execute_query("""
            SELECT c.contract_id, re.entity_name, c.notional_amount, c.maturity_date, c.currency
            FROM CDS_Contract c
            JOIN Reference_Entity re ON c.ref_entity_id = re.ref_entity_id
        """)
        
        if contracts:
            contract_options = {f"{c['contract_id']} - {c['entity_name']} ({c['currency']} {c['notional_amount']:,.0f})": c['contract_id'] 
                              for c in contracts}
            selected_contract = st.selectbox("Select CDS Contract", options=list(contract_options.keys()))
            contract_id = contract_options[selected_contract]
            
            # Get counterparties
            counterparties = execute_query("SELECT party_id, party_name, credit_rating FROM Counterparty")
            cp_options = {f"{cp['party_name']} (Rating: {cp['credit_rating']})": cp['party_id'] 
                         for cp in counterparties}
            
            buyer = st.selectbox("Protection Buyer", options=list(cp_options.keys()))
            buyer_id = cp_options[buyer]
            
            seller = st.selectbox("Protection Seller", options=list(cp_options.keys()))
            seller_id = cp_options[seller]
            
            trade_price = st.number_input("Trade Price ($)", min_value=0.0, value=100000.0, step=1000.0)
            trade_date = st.date_input("Trade Date", value=datetime.now())
            
            if st.button("Execute Trade", type="primary"):
                if buyer_id == seller_id:
                    st.error("Buyer and Seller cannot be the same counterparty!")
                else:
                    # Get next trade ID
                    max_trade = execute_query("SELECT MAX(trade_id) as max_id FROM Trade")
                    next_trade_id = (max_trade[0]['max_id'] or 9000) + 1
                    
                    # Call stored procedure
                    try:
                        call_procedure('execute_cds_trade', 
                                     (next_trade_id, contract_id, buyer_id, seller_id, 
                                      trade_date, trade_price))
                        st.success(f"✅ Trade {next_trade_id} executed successfully!")
                        st.balloons()
                    except Exception as e:
                        st.error(f"Trade execution failed: {e}")
    
    with col2:
        st.subheader("CDS Pricing Reference")
        
        # Show credit curves for selected contract
        if contracts:
            selected_contract_id = contract_options[selected_contract]
            contract_info = execute_query("""
                SELECT c.*, re.entity_name, re.sector
                FROM CDS_Contract c
                JOIN Reference_Entity re ON c.ref_entity_id = re.ref_entity_id
                WHERE c.contract_id = %s
            """, (selected_contract_id,))
            
            if contract_info:
                info = contract_info[0]
                st.info(f"""
                **Reference Entity:** {info['entity_name']}  
                **Sector:** {info['sector']}  
                **Notional Amount:** {info['currency']} {info['notional_amount']:,.2f}  
                **Maturity Date:** {info['maturity_date']}
                """)
                
                # Get credit curve data
                curves = execute_query("""
                    SELECT curve_date, spread_bps, tenor
                    FROM Credit_Curve cc
                    JOIN CDS_Contract c ON cc.ref_entity_id = c.ref_entity_id
                    WHERE c.contract_id = %s
                    ORDER BY curve_date DESC
                    LIMIT 10
                """, (selected_contract_id,))
                
                if curves:
                    st.write("**Recent Credit Spreads (bps):**")
                    df_curves = pd.DataFrame(curves)
                    st.dataframe(df_curves, use_container_width=True, hide_index=True)
                    
                    # Plot spread evolution
                    fig = go.Figure()
                    fig.add_trace(go.Scatter(
                        x=df_curves['curve_date'], 
                        y=df_curves['spread_bps'],
                        mode='lines+markers',
                        name='Spread (bps)',
                        line=dict(color='red', width=2)
                    ))
                    fig.update_layout(
                        title="Credit Spread History",
                        xaxis_title="Date",
                        yaxis_title="Spread (basis points)",
                        height=300
                    )
                    st.plotly_chart(fig, use_container_width=True)

# ============================================
# PAGE 3: LIVE MARKET DATA
# ============================================
elif page == "📈 Live Market Data":
    st.header("Live Stock Market Data & CDS Correlation")
    
    st.markdown("""
    ### How Stock Prices Relate to CDS Spreads
    CDS spreads typically move **inversely** to stock prices:
    - **Stock Price Falls** → Credit risk increases → **CDS Spread Widens** (protection costs more)
    - **Stock Price Rises** → Credit risk decreases → **CDS Spread Tightens** (protection costs less)
    """)
    
    st.markdown("---")
    
    col1, col2 = st.columns([1, 2])
    
    with col1:
        st.subheader("Select Stock")
        
        # Map reference entities to stock tickers
        ticker_map = {
            "Tesla Inc": "TSLA",
            "Deutsche Bank AG": "DB",
            "ArcelorMittal SA": "MT",
            "Vodafone Group PLC": "VOD"
        }
        
        entities = execute_query("SELECT entity_name, sector FROM Reference_Entity WHERE entity_name IN ('Tesla Inc', 'Deutsche Bank AG', 'ArcelorMittal SA', 'Vodafone Group PLC')")
        
        if entities:
            entity_names = [e['entity_name'] for e in entities]
            selected_entity = st.selectbox("Reference Entity", entity_names)
            ticker = ticker_map.get(selected_entity, "TSLA")
            
            st.info(f"Ticker Symbol: **{ticker}**")
            
            if st.button("Fetch Live Data", type="primary"):
                with st.spinner("Fetching real-time data..."):
                    hist, info = get_live_stock_data(ticker)
                    
                    if hist is not None and not hist.empty:
                        st.session_state['stock_hist'] = hist
                        st.session_state['stock_info'] = info
                        st.session_state['selected_entity'] = selected_entity
                        st.success("Data loaded successfully!")
    
    with col2:
        st.subheader("Live Market Data")
        
        if 'stock_hist' in st.session_state:
            hist = st.session_state['stock_hist']
            info = st.session_state['stock_info']
            
            # Display key metrics
            col_a, col_b, col_c, col_d = st.columns(4)
            with col_a:
                st.metric("Current Price", f"${info.get('currentPrice', 'N/A')}")
            with col_b:
                change_pct = info.get('regularMarketChangePercent', 0)
                st.metric("Change %", f"{change_pct:.2f}%")
            with col_c:
                market_cap = info.get('marketCap', 0)
                if market_cap:
                    st.metric("Market Cap", f"${market_cap/1e9:.2f}B")
                else:
                    st.metric("Market Cap", "N/A")
            with col_d:
                st.metric("52W High", f"${info.get('fiftyTwoWeekHigh', 'N/A')}")
            
            # Plot stock price
            fig = go.Figure()
            fig.add_trace(go.Candlestick(
                x=hist.index,
                open=hist['Open'],
                high=hist['High'],
                low=hist['Low'],
                close=hist['Close'],
                name='Price'
            ))
            fig.update_layout(
                title=f"{st.session_state['selected_entity']} - 5 Day Price Chart",
                xaxis_title="Date",
                yaxis_title="Price ($)",
                height=400
            )
            st.plotly_chart(fig, use_container_width=True)
            
            # Get CDS spread for this entity
            spread_data = execute_query("""
                SELECT cc.spread_bps, cc.curve_date
                FROM Credit_Curve cc
                JOIN Reference_Entity re ON cc.ref_entity_id = re.ref_entity_id
                WHERE re.entity_name = %s
                ORDER BY cc.curve_date DESC
                LIMIT 1
            """, (st.session_state['selected_entity'],))
            
            if spread_data:
                current_spread = spread_data[0]['spread_bps']
                st.success(f"**Current CDS Spread:** {current_spread} basis points")
                
                # Interpret the data
                if change_pct < -5:
                    st.warning("⚠️ **Stock price fell significantly.** Expect CDS spreads to widen as credit risk increases.")
                elif change_pct > 5:
                    st.info("✅ **Stock price rose significantly.** Expect CDS spreads to tighten as credit risk decreases.")

# ============================================
# PAGE 4: QUERY DATABASE
# ============================================
elif page == "🔍 Query Database":
    st.header("Database Query Interface")
    
    st.write("Execute custom SQL queries on the CDS Trading System database")
    
    # Predefined queries
    st.subheader("Quick Queries")
    col1, col2, col3 = st.columns(3)
    
    with col1:
        if st.button("All Contracts"):
            results = execute_query("SELECT * FROM CDS_Contract")
            st.dataframe(pd.DataFrame(results), use_container_width=True, hide_index=True)
    
    with col2:
        if st.button("All Trades"):
            results = execute_query("SELECT * FROM Trade")
            st.dataframe(pd.DataFrame(results), use_container_width=True, hide_index=True)
    
    with col3:
        if st.button("All Counterparties"):
            results = execute_query("SELECT * FROM Counterparty")
            st.dataframe(pd.DataFrame(results), use_container_width=True, hide_index=True)
    
    st.markdown("---")
    
    # Custom query
    st.subheader("Custom SQL Query")
    query = st.text_area("Enter your SQL SELECT query:", height=150, 
                         value="SELECT * FROM Reference_Entity LIMIT 10")
    
    if st.button("Execute Query", type="primary"):
        if query.strip().upper().startswith("SELECT"):
            try:
                results = execute_query(query)
                if results:
                    df = pd.DataFrame(results)
                    st.success(f"Query returned {len(df)} rows")
                    st.dataframe(df, use_container_width=True, hide_index=True)
                    
                    # Download option
                    csv = df.to_csv(index=False)
                    st.download_button(
                        label="Download as CSV",
                        data=csv,
                        file_name="query_results.csv",
                        mime="text/csv"
                    )
                else:
                    st.info("Query returned no results")
            except Exception as e:
                st.error(f"Query error: {e}")
        else:
            st.error("Only SELECT queries are allowed")

# ============================================
# PAGE 5: REPORTS
# ============================================
elif page == "📋 Reports":
    st.header("System Reports")
    
    tab1, tab2, tab3 = st.tabs(["Exposure Report", "Audit Log", "Credit Curves"])
    
    with tab1:
        st.subheader("Counterparty Exposure Report")
        exposure = call_procedure('generate_exposure_report')
        if exposure:
            df_exp = pd.DataFrame(exposure)
            st.dataframe(df_exp, use_container_width=True, hide_index=True)
            
            # Visualization
            fig = go.Figure(data=[
                go.Bar(name='Long Exposure', x=df_exp['party_name'], y=df_exp['long_exposure'], marker_color='green'),
                go.Bar(name='Short Exposure', x=df_exp['party_name'], y=df_exp['short_exposure'], marker_color='red')
            ])
            fig.update_layout(barmode='group', title="Counterparty Long vs Short Exposure", height=400)
            st.plotly_chart(fig, use_container_width=True)
    
    with tab2:
        st.subheader("Recent Audit Log")
        audit = execute_query("""
            SELECT al.log_id, al.log_timestamp, al.event_description,
                   pp.position_id, c.party_name
            FROM Audit_Log al
            JOIN Portfolio_Position pp ON al.position_id = pp.position_id
            JOIN Counterparty c ON pp.party_id = c.party_id
            ORDER BY al.log_timestamp DESC
            LIMIT 50
        """)
        if audit:
            st.dataframe(pd.DataFrame(audit), use_container_width=True, hide_index=True)
    
    with tab3:
        st.subheader("Credit Curve Analysis")
        curves = execute_query("""
            SELECT re.entity_name, cc.curve_date, cc.spread_bps, cc.tenor
            FROM Credit_Curve cc
            JOIN Reference_Entity re ON cc.ref_entity_id = re.ref_entity_id
            ORDER BY cc.curve_date DESC, re.entity_name
        """)
        if curves:
            df_curves = pd.DataFrame(curves)
            st.dataframe(df_curves, use_container_width=True, hide_index=True)
            
            # Plot curves by entity
            fig = go.Figure()
            for entity in df_curves['entity_name'].unique():
                entity_data = df_curves[df_curves['entity_name'] == entity]
                fig.add_trace(go.Scatter(
                    x=entity_data['curve_date'],
                    y=entity_data['spread_bps'],
                    mode='lines+markers',
                    name=entity
                ))
            fig.update_layout(
                title="Credit Spread Evolution",
                xaxis_title="Date",
                yaxis_title="Spread (bps)",
                height=400
            )
            st.plotly_chart(fig, use_container_width=True)

# Footer
st.sidebar.markdown("---")
st.sidebar.info("""
**CDS Trading System v1.0**  
Built with Python, MySQL & Streamlit  
© 2025
""")
