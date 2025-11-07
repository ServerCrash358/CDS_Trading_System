-- Step 1: Create the database
CREATE DATABASE CDSS_Trading_System;

-- Step 2: Use the database
USE CDSS_Trading_System;

-- Step 3: Create Reference_Entity table (no dependencies)
CREATE TABLE Reference_Entity (
    ref_entity_id INT PRIMARY KEY,
    entity_name VARCHAR(255) NOT NULL,
    sector VARCHAR(100),
    country VARCHAR(100)
);

-- Step 4: Create Credit_Curve table (depends on Reference_Entity)
CREATE TABLE Credit_Curve (
    curve_id INT PRIMARY KEY,
    ref_entity_id INT,
    spread_bps DECIMAL(10,4),
    curve_date DATE,
    tenor INT,
    FOREIGN KEY (ref_entity_id) REFERENCES Reference_Entity(ref_entity_id)
);

-- Step 5: Create Counterparty table (no dependencies)
CREATE TABLE Counterparty (
    party_id INT PRIMARY KEY,
    party_name VARCHAR(255) NOT NULL,
    credit_rating VARCHAR(10)
);

-- Step 6: Create CDS_Contract table (depends on Reference_Entity)
CREATE TABLE CDS_Contract (
    contract_id INT PRIMARY KEY,
    ref_entity_id INT,
    notional_amount DECIMAL(18,2),
    maturity_date DATE,
    currency VARCHAR(10),
    FOREIGN KEY (ref_entity_id) REFERENCES Reference_Entity(ref_entity_id)
);

-- Step 7: Create Trade table (depends on CDS_Contract and Counterparty)
CREATE TABLE Trade (
    trade_id INT PRIMARY KEY,
    contract_id INT,
    buyer_party_id INT,
    seller_party_id INT,
    trade_date DATE,
    trade_price DECIMAL(18,2),
    FOREIGN KEY (contract_id) REFERENCES CDS_Contract(contract_id),
    FOREIGN KEY (buyer_party_id) REFERENCES Counterparty(party_id),
    FOREIGN KEY (seller_party_id) REFERENCES Counterparty(party_id)
);

-- Step 8: Create Portfolio_Position table (depends on CDS_Contract and Counterparty)
CREATE TABLE Portfolio_Position (
    position_id INT PRIMARY KEY,
    contract_id INT,
    party_id INT,
    net_notional_position DECIMAL(18,2),
    FOREIGN KEY (contract_id) REFERENCES CDS_Contract(contract_id),
    FOREIGN KEY (party_id) REFERENCES Counterparty(party_id)
);

-- Step 9: Create Audit_Log table (depends on Portfolio_Position)
CREATE TABLE Audit_Log (
    log_id INT PRIMARY KEY,
    position_id INT,
    log_timestamp DATETIME,
    event_description TEXT,
    FOREIGN KEY (position_id) REFERENCES Portfolio_Position(position_id)
);
