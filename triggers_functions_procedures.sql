-- Use your existing database
USE CDSS_Trading_System;

-- ===========================================
-- TRIGGERS
-- ===========================================

-- Trigger 1: Automatically log trade insertions in Audit_Log
DELIMITER $$
CREATE TRIGGER after_trade_insert
AFTER INSERT ON Trade
FOR EACH ROW
BEGIN
    DECLARE buyer_position INT;
    DECLARE seller_position INT;
    
    -- Find buyer's position
    SELECT position_id INTO buyer_position
    FROM Portfolio_Position
    WHERE contract_id = NEW.contract_id AND party_id = NEW.buyer_party_id
    LIMIT 1;
    
    -- Find seller's position
    SELECT position_id INTO seller_position
    FROM Portfolio_Position
    WHERE contract_id = NEW.contract_id AND party_id = NEW.seller_party_id
    LIMIT 1;
    
    -- Log buyer trade
    IF buyer_position IS NOT NULL THEN
        INSERT INTO Audit_Log (position_id, log_timestamp, event_description)
        VALUES (buyer_position, NOW(), 
                CONCAT('Trade ', NEW.trade_id, ' executed - Buyer protection at price ', NEW.trade_price));
    END IF;
    
    -- Log seller trade
    IF seller_position IS NOT NULL THEN
        INSERT INTO Audit_Log (position_id, log_timestamp, event_description)
        VALUES (seller_position, NOW(), 
                CONCAT('Trade ', NEW.trade_id, ' executed - Seller protection at price ', NEW.trade_price));
    END IF;
END$$
DELIMITER ;

-- Trigger 2: Validate notional amount before inserting CDS contract
DELIMITER $$
CREATE TRIGGER before_contract_insert
BEFORE INSERT ON CDS_Contract
FOR EACH ROW
BEGIN
    -- Ensure notional amount is positive
    IF NEW.notional_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Notional amount must be greater than zero';
    END IF;
    
    -- Ensure maturity date is in the future
    IF NEW.maturity_date <= CURDATE() THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Maturity date must be in the future';
    END IF;
END$$
DELIMITER ;

-- ===========================================
-- FUNCTIONS
-- ===========================================

-- Function 1: Calculate total exposure for a counterparty
DELIMITER $$
CREATE FUNCTION calculate_counterparty_exposure(party INT)
RETURNS DECIMAL(18,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE total_exposure DECIMAL(18,2);
    
    SELECT COALESCE(SUM(ABS(net_notional_position)), 0)
    INTO total_exposure
    FROM Portfolio_Position
    WHERE party_id = party;
    
    RETURN total_exposure;
END$$
DELIMITER ;

-- Function 2: Get the latest spread for a reference entity
DELIMITER $$
CREATE FUNCTION get_latest_spread(entity_id INT)
RETURNS DECIMAL(10,4)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE latest_spread DECIMAL(10,4);
    
    SELECT spread_bps INTO latest_spread
    FROM Credit_Curve
    WHERE ref_entity_id = entity_id
    ORDER BY curve_date DESC
    LIMIT 1;
    
    RETURN COALESCE(latest_spread, 0);
END$$
DELIMITER ;

-- ===========================================
-- STORED PROCEDURES
-- ===========================================

-- Procedure 1: Execute a new CDS trade and update positions
DELIMITER $$
CREATE PROCEDURE execute_cds_trade(
    IN p_trade_id INT,
    IN p_contract_id INT,
    IN p_buyer_party_id INT,
    IN p_seller_party_id INT,
    IN p_trade_date DATE,
    IN p_trade_price DECIMAL(18,2)
)
BEGIN
    DECLARE contract_notional DECIMAL(18,2);
    
    -- Get contract notional amount
    SELECT notional_amount INTO contract_notional
    FROM CDS_Contract
    WHERE contract_id = p_contract_id;
    
    -- Insert the trade
    INSERT INTO Trade (trade_id, contract_id, buyer_party_id, seller_party_id, trade_date, trade_price)
    VALUES (p_trade_id, p_contract_id, p_buyer_party_id, p_seller_party_id, p_trade_date, p_trade_price);
    
    -- Update or create buyer's portfolio position
    INSERT INTO Portfolio_Position (position_id, contract_id, party_id, net_notional_position)
    VALUES ((p_trade_id * 10), p_contract_id, p_buyer_party_id, contract_notional)
    ON DUPLICATE KEY UPDATE 
        net_notional_position = net_notional_position + contract_notional;
    
    -- Update or create seller's portfolio position
    INSERT INTO Portfolio_Position (position_id, contract_id, party_id, net_notional_position)
    VALUES ((p_trade_id * 10 + 1), p_contract_id, p_seller_party_id, -contract_notional)
    ON DUPLICATE KEY UPDATE 
        net_notional_position = net_notional_position - contract_notional;
    
    SELECT 'Trade executed successfully' AS message;
END$$
DELIMITER ;

-- Procedure 2: Generate counterparty exposure report
DELIMITER $$
CREATE PROCEDURE generate_exposure_report()
BEGIN
    SELECT 
        c.party_id,
        c.party_name,
        c.credit_rating,
        COUNT(DISTINCT pp.position_id) AS total_positions,
        SUM(ABS(pp.net_notional_position)) AS total_exposure,
        SUM(CASE WHEN pp.net_notional_position > 0 THEN pp.net_notional_position ELSE 0 END) AS long_exposure,
        SUM(CASE WHEN pp.net_notional_position < 0 THEN ABS(pp.net_notional_position) ELSE 0 END) AS short_exposure
    FROM Counterparty c
    LEFT JOIN Portfolio_Position pp ON c.party_id = pp.party_id
    GROUP BY c.party_id, c.party_name, c.credit_rating
    ORDER BY total_exposure DESC;
END$$
DELIMITER ;

-- ===========================================
-- VERIFY CREATION
-- ===========================================

-- Show all triggers
SHOW TRIGGERS;

-- Show all functions
SHOW FUNCTION STATUS WHERE Db = 'CDS_Trading_System';

-- Show all procedures
SHOW PROCEDURE STATUS WHERE Db = 'CDS_Trading_System';
