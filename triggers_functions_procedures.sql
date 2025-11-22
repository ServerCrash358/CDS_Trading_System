-- Use your existing database
USE CDS_Trading_System;

-- ===========================================
-- EXISTING TRIGGERS (2)
-- ===========================================

-- Trigger 1: Automatically log trade insertions in Audit_Log
DELIMITER $$
CREATE TRIGGER after_trade_insert
AFTER INSERT ON Trade
FOR EACH ROW
BEGIN
    DECLARE buyer_position INT;
    DECLARE seller_position INT;
    
    SELECT position_id INTO buyer_position
    FROM Portfolio_Position
    WHERE contract_id = NEW.contract_id AND party_id = NEW.buyer_party_id
    LIMIT 1;
    
    SELECT position_id INTO seller_position
    FROM Portfolio_Position
    WHERE contract_id = NEW.contract_id AND party_id = NEW.seller_party_id
    LIMIT 1;
    
    IF buyer_position IS NOT NULL THEN
        INSERT INTO Audit_Log (position_id, log_timestamp, event_description)
        VALUES (buyer_position, NOW(), 
                CONCAT('Trade ', NEW.trade_id, ' executed - Buyer protection at price ', NEW.trade_price));
    END IF;
    
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
    IF NEW.notional_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Notional amount must be greater than zero';
    END IF;
    
    IF NEW.maturity_date <= CURDATE() THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Maturity date must be in the future';
    END IF;
END$$
DELIMITER ;

-- Trigger 3: Log credit curve updates
DELIMITER $$
CREATE TRIGGER after_credit_curve_insert
AFTER INSERT ON Credit_Curve
FOR EACH ROW
BEGIN
    DECLARE entity_name_var VARCHAR(255);
    
    SELECT entity_name INTO entity_name_var
    FROM Reference_Entity
    WHERE ref_entity_id = NEW.ref_entity_id;
    
    -- Log to a position related to this entity (if exists)
    INSERT INTO Audit_Log (position_id, log_timestamp, event_description)
    SELECT pp.position_id, NOW(), 
           CONCAT('Credit curve updated for ', entity_name_var, ': Spread = ', NEW.spread_bps, ' bps')
    FROM Portfolio_Position pp
    JOIN CDS_Contract c ON pp.contract_id = c.contract_id
    WHERE c.ref_entity_id = NEW.ref_entity_id
    LIMIT 1;
END$$
DELIMITER ;

-- Trigger 4: Prevent deletion of active contracts
DELIMITER $$
CREATE TRIGGER before_contract_delete
BEFORE DELETE ON CDS_Contract
FOR EACH ROW
BEGIN
    DECLARE trade_count INT;
    
    SELECT COUNT(*) INTO trade_count
    FROM Trade
    WHERE contract_id = OLD.contract_id;
    
    IF trade_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot delete contract with existing trades';
    END IF;
END$$
DELIMITER ;

-- Trigger 5: Auto-archive old trades (mark in audit log)
DELIMITER $$
CREATE TRIGGER after_trade_update
AFTER UPDATE ON Trade
FOR EACH ROW
BEGIN
    IF OLD.trade_price != NEW.trade_price THEN
        INSERT INTO Audit_Log (position_id, log_timestamp, event_description)
        SELECT pp.position_id, NOW(),
               CONCAT('Trade ', NEW.trade_id, ' price updated from ', OLD.trade_price, ' to ', NEW.trade_price)
        FROM Portfolio_Position pp
        WHERE pp.contract_id = NEW.contract_id
        LIMIT 1;
    END IF;
END$$
DELIMITER ;

-- ===========================================
-- EXISTING FUNCTIONS (2)
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
-- NEW FUNCTIONS (3 MORE)
-- ===========================================

-- Function 3: Calculate Value at Risk (simplified)
DELIMITER $$
CREATE FUNCTION calculate_var(party INT, confidence_level DECIMAL(5,2))
RETURNS DECIMAL(18,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE var_amount DECIMAL(18,2);
    DECLARE total_exposure DECIMAL(18,2);
    
    SELECT COALESCE(SUM(ABS(net_notional_position)), 0)
    INTO total_exposure
    FROM Portfolio_Position
    WHERE party_id = party;
    
    -- Simplified VaR = exposure * confidence_level * 0.01
    SET var_amount = total_exposure * confidence_level * 0.01;
    
    RETURN var_amount;
END$$
DELIMITER ;

-- Function 4: Calculate days to maturity for a contract
DELIMITER $$
CREATE FUNCTION days_to_maturity(contract INT)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE days INT;
    
    SELECT DATEDIFF(maturity_date, CURDATE())
    INTO days
    FROM CDS_Contract
    WHERE contract_id = contract;
    
    RETURN COALESCE(days, 0);
END$$
DELIMITER ;

-- Function 5: Get counterparty risk rating score
DELIMITER $$
CREATE FUNCTION risk_rating_score(rating VARCHAR(10))
RETURNS INT
DETERMINISTIC
BEGIN
    DECLARE score INT;
    
    CASE rating
        WHEN 'AAA' THEN SET score = 100;
        WHEN 'AA+' THEN SET score = 95;
        WHEN 'AA' THEN SET score = 90;
        WHEN 'AA-' THEN SET score = 85;
        WHEN 'A+' THEN SET score = 80;
        WHEN 'A' THEN SET score = 75;
        WHEN 'A-' THEN SET score = 70;
        WHEN 'BBB+' THEN SET score = 65;
        WHEN 'BBB' THEN SET score = 60;
        WHEN 'BBB-' THEN SET score = 55;
        ELSE SET score = 50;
    END CASE;
    
    RETURN score;
END$$
DELIMITER ;

-- ===========================================
-- EXISTING PROCEDURES (2)
-- ===========================================

-- Procedure 1: Execute a new CDS trade
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
    
    SELECT notional_amount INTO contract_notional
    FROM CDS_Contract
    WHERE contract_id = p_contract_id;
    
    INSERT INTO Trade (trade_id, contract_id, buyer_party_id, seller_party_id, trade_date, trade_price)
    VALUES (p_trade_id, p_contract_id, p_buyer_party_id, p_seller_party_id, p_trade_date, p_trade_price);
    
    INSERT INTO Portfolio_Position (position_id, contract_id, party_id, net_notional_position)
    VALUES ((p_trade_id * 10), p_contract_id, p_buyer_party_id, contract_notional)
    ON DUPLICATE KEY UPDATE 
        net_notional_position = net_notional_position + contract_notional;
    
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

-- Procedure 3: Calculate portfolio VaR for all counterparties
DELIMITER $$
CREATE PROCEDURE calculate_portfolio_var(IN confidence DECIMAL(5,2))
BEGIN
    SELECT 
        c.party_id,
        c.party_name,
        c.credit_rating,
        calculate_counterparty_exposure(c.party_id) AS total_exposure,
        calculate_var(c.party_id, confidence) AS value_at_risk,
        risk_rating_score(c.credit_rating) AS risk_score
    FROM Counterparty c
    ORDER BY value_at_risk DESC;
END$$
DELIMITER ;

-- Procedure 4: Get contracts expiring soon
DELIMITER $$
CREATE PROCEDURE contracts_expiring_soon(IN days_threshold INT)
BEGIN
    SELECT 
        c.contract_id,
        re.entity_name,
        c.notional_amount,
        c.maturity_date,
        days_to_maturity(c.contract_id) AS days_remaining,
        COUNT(t.trade_id) AS trade_count
    FROM CDS_Contract c
    JOIN Reference_Entity re ON c.ref_entity_id = re.ref_entity_id
    LEFT JOIN Trade t ON c.contract_id = t.contract_id
    WHERE days_to_maturity(c.contract_id) <= days_threshold
        AND days_to_maturity(c.contract_id) > 0
    GROUP BY c.contract_id, re.entity_name, c.notional_amount, c.maturity_date
    ORDER BY days_to_maturity(c.contract_id);
END$$
DELIMITER ;

-- Procedure 5: Market risk analysis by sector
DELIMITER $$
CREATE PROCEDURE sector_risk_analysis()
BEGIN
    SELECT 
        re.sector,
        COUNT(DISTINCT re.ref_entity_id) AS num_entities,
        COUNT(DISTINCT c.contract_id) AS num_contracts,
        SUM(c.notional_amount) AS total_notional,
        AVG(get_latest_spread(re.ref_entity_id)) AS avg_spread,
        MAX(get_latest_spread(re.ref_entity_id)) AS max_spread,
        MIN(get_latest_spread(re.ref_entity_id)) AS min_spread
    FROM Reference_Entity re
    LEFT JOIN CDS_Contract c ON re.ref_entity_id = c.ref_entity_id
    GROUP BY re.sector
    ORDER BY total_notional DESC;
END$$
DELIMITER ;

-- ===========================================
-- VERIFY CREATION
-- ===========================================

SHOW TRIGGERS;
SHOW FUNCTION STATUS WHERE Db = 'CDS_Trading_System';
SHOW PROCEDURE STATUS WHERE Db = 'CDS_Trading_System';
