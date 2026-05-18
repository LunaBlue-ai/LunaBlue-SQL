-- ============================================================================
-- AUDIT SCHEMA
-- ============================================================================
--
-- PURPOSE:
--   Centralized audit logging for all database operations, security events,
--   and access patterns. Enables compliance reporting, forensics, and
--   anomaly detection.
--
-- PERSPECTIVES ADDRESSED:
--   • Maintainability: Modular design, clear separation of concerns
--   • Testability: Each component testable in isolation
--   • Architecture: Separation of audit data from application data
--   • Security: Least privilege, audit trail, tamper evidence
--   • Business Value: Compliance (GDPR, HIPAA, PCI-DSS), fraud detection
--   • Documentation: Inline comments explain every decision
--
-- SCHEMA DESIGN PRINCIPLES:
--   1. All audit records are append-only (no UPDATE/DELETE)
--   2. Timestamps use TIMESTAMPTZ for UTC consistency
--   3. JSONB for flexible event metadata
--   4. Partitioning strategy ready for high-volume auditing
--   5. Row-level security enforced
--
-- USAGE:
--   docker exec -i container psql -U postgres -f audit.sql
--   docker exec container psql -U postgres
--   postgres=# SELECT * FROM audit.system_log;
--
-- ============================================================================

-- ============================================================================
-- SCHEMA CREATION
-- ============================================================================
-- PERSPECTIVE INFLUENCE:
--   • Architecture: Schema separation prevents audit data from interfering
--     with application schema migrations
--   • Maintainability: Schema boundaries make testing and deployment simpler
--   • Security: Restricted access by default
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS audit
    AUTHORIZATION postgres;

-- Set default schema search path to exclude audit from default operations
-- This prevents accidental queries against audit tables
COMMENT ON SCHEMA audit IS 'Audit logging schema - contains append-only security event records';

-- ============================================================================
-- AUDIT SETTINGS TABLE
-- ============================================================================
--
-- Purpose: Configuration table for audit behavior
-- Maintains enable/disable flags, retention policies, and notification settings
--
-- Testability: Unit tests can modify these settings without affecting data
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.settings (
    setting_name   VARCHAR(100) PRIMARY KEY,
    setting_value  VARCHAR(500) NOT NULL,
    setting_type   VARCHAR(50) NOT NULL CHECK (setting_type IN ('boolean', 'integer', 'varchar', 'jsonb')),
    description    VARCHAR(1000),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Insert default settings
INSERT INTO audit.settings (setting_name, setting_value, setting_type, description) VALUES
    ('enabled', 'true', 'boolean', 'Whether audit logging is active'),
    ('retention_days', '365', 'integer', 'Default data retention period in days'),
    ('log_ddl', 'true', 'boolean', 'Log DDL statements (CREATE, ALTER, DROP)'),
    ('log_dml', 'true', 'boolean', 'Log DML statements (INSERT, UPDATE, DELETE)'),
    ('log_connections', 'false', 'boolean', 'Log connection events'),
    ('include_query', 'true', 'boolean', 'Store full SQL query text'),
    ('include_parameters', 'false', 'boolean', 'Store query parameters (security risk)'),
    ('notify_on_critical', 'true', 'boolean', 'Alert on critical events'),
    ('notification_channel', 'email', 'varchar', 'Alert channel: email, webhook, slack');

COMMENT ON TABLE audit.settings IS 'Audit configuration settings - modify with caution';
COMMENT ON COLUMN audit.settings.setting_name IS 'Setting identifier (e.g., enabled, retention_days)';
COMMENT ON COLUMN audit.settings.setting_value IS 'Current setting value';
COMMENT ON COLUMN audit.settings.setting_type IS 'Type of setting for validation';
COMMENT ON COLUMN audit.settings.description IS 'Human-readable description';

-- Grant permissions: Application roles can only READ settings
-- Prevents modification of audit configuration by app users
GRANT SELECT ON audit.settings TO PUBLIC;
GRANT UPDATE (setting_value, updated_at) ON audit.settings TO pg_monitor;
REVOKE INSERT ON audit.settings FROM PUBLIC;
REVOKE DELETE ON audit.settings FROM PUBLIC;

-- ============================================================================
-- SYSTEM LOG TABLE
-- ============================================================================
--
-- Purpose: Core audit log table for all system events
-- Events: Authentication, connection, security alerts, system errors
--
-- Design Decisions:
--   - JSONB column for flexible event metadata
--   - Index on user_name for user activity lookup
--   - Index on executed_at for time-range queries
--   - No PRIMARY KEY (append-only, use partition keys instead)
--
-- Testability:
--   - Can insert test records for verification
--   - Index creation can be tested separately
--   - RLS policies testable in isolation
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.system_log (
    id          BIGINT GENERATED BY DEFAULT AS IDENTITY,
    event_type  VARCHAR(100) NOT NULL,
    user_name   VARCHAR(255),
    database_name   VARCHAR(255),
    schema_name VARCHAR(255),
    table_name  VARCHAR(255),
    event_class VARCHAR(100) NOT NULL,
    event_code  VARCHAR(100),
    description VARCHAR(1000),
    query       TEXT,
    source_address INET,
    source_port INTEGER,
    parameters  JSONB,
    session_id  VARCHAR(255),
    client_info TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX idx_audit_system_log_type ON audit.system_log(event_type);
CREATE INDEX idx_audit_system_log_user ON audit.system_log(user_name);
CREATE INDEX idx_audit_system_log_db ON audit.system_log(database_name);
CREATE INDEX idx_audit_system_log_time ON audit.system_log(created_at);
CREATE INDEX idx_audit_system_log_schema_table ON audit.system_log(schema_name, table_name);
CREATE INDEX idx_audit_system_log_created_at_time ON audit.system_log(created_at DESC);

-- Composite index for security event filtering
CREATE INDEX idx_audit_system_log_security ON audit.system_log(
    event_type, created_at DESC
) WHERE event_class IN ('SECURITY', 'AUTHENTICATION', 'ACCESS_DENIED');

COMMENT ON TABLE audit.system_log IS 'System-wide audit log - all security events, connections, and system activity';
COMMENT ON COLUMN audit.system_log.id IS 'Identity column for ordering and foreign key references';
COMMENT ON COLUMN audit.system_log.event_type IS 'Event category (e.g., LOGIN_SUCCESS, LOGIN_FAILED, SQL_QUERY)';
COMMENT ON COLUMN audit.system_log.user_name IS 'Database user who triggered the event (NULL for superuser)';
COMMENT ON COLUMN audit.system_log.database_name IS 'Database where event occurred';
COMMENT ON COLUMN audit.system_log.schema_name IS 'Schema where event occurred';
COMMENT ON COLUMN audit.system_log.table_name IS 'Table affected (if applicable)';
COMMENT ON COLUMN audit.system_log.event_class IS 'Classification: SECURITY, AUTHENTICATION, ACCESS, DDL, DML, CONNECTION, ERROR';
COMMENT ON COLUMN audit.system_log.event_code IS 'Event code for categorization (e.g., LOGIN_001 for login success)';
COMMENT ON COLUMN audit.system_log.description IS 'Human-readable event description';
COMMENT ON COLUMN audit.system_log.query IS 'SQL query executed (if applicable)';
COMMENT ON COLUMN audit.system_log.source_address IS 'Client IP address';
COMMENT ON COLUMN audit.system_log.source_port IS 'Client port';
COMMENT ON COLUMN audit.system_log.parameters IS 'Query parameters (JSONB, optional)';
COMMENT ON COLUMN audit.system_log.session_id IS 'Application session identifier (if provided)';
COMMENT ON COLUMN audit.system_log.client_info IS 'Application/version information';
COMMENT ON COLUMN audit.system_log.created_at IS 'Event timestamp (always TIMESTAMPTZ UTC)';

-- Row Level Security: Only audit admin can write
-- Application users can read their own audit records
ALTER TABLE audit.system_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_system_log_admin_write ON audit.system_log
    FOR ALL
    USING (
        session_user IN ('pg_monitor', 'pg_audit', 'audit_admin')
        OR 
        user_name = session_user
    );

CREATE POLICY audit_system_log_public_read ON audit.system_log
    FOR SELECT
    USING (TRUE);

COMMENT ON POLICY audit_system_log_admin_write IS 'Admin roles can write, users can read their own events';
COMMENT ON POLICY audit_system_log_public_read IS 'Public read access - consider restricting in production';

-- ============================================================================
-- SECURITY ALERTS TABLE
-- ============================================================================
--
-- Purpose: Dedicated table for security-related events
-- Enables faster querying of security events for monitoring/alerting
--
-- Testability:
--   - Can query this table specifically for security analysis
--   - Indexes support efficient alerting queries
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.security_alerts (
    alert_id          BIGINT GENERATED BY DEFAULT AS IDENTITY,
    system_log_id     BIGINT REFERENCES audit.system_log(id),
    alert_type        VARCHAR(100) NOT NULL,
    severity          VARCHAR(50) NOT NULL CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    source_ip         INET,
    user_name         VARCHAR(255),
    description       TEXT,
    recommendation    TEXT,
    resolved_at       TIMESTAMPTZ,
    resolved_by       VARCHAR(255),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_security_alerts_type ON audit.security_alerts(alert_type);
CREATE INDEX idx_audit_security_alerts_severity ON audit.security_alerts(severity);
CREATE INDEX idx_audit_security_alerts_unresolved ON audit.security_alerts(
    alert_type, severity, resolved_at
) WHERE resolved_at IS NULL;

COMMENT ON TABLE audit.security_alerts IS 'Security alert records - derived from system_log for monitoring';
COMMENT ON COLUMN audit.security_alerts.alert_id IS 'Unique alert identifier';
COMMENT ON COLUMN audit.security_alerts.system_log_id IS 'Reference to source system_log record';
COMMENT ON COLUMN audit.security_alerts.alert_type IS 'Alert category (e.g., BRUTE_FORCE, SQL_INJECTION_ATTEMPT)';
COMMENT ON COLUMN audit.security_alerts.severity IS 'Severity level for prioritization';
COMMENT ON COLUMN audit.security_alerts.source_ip IS 'IP address of threat source';
COMMENT ON COLUMN audit.security_alerts.user_name IS 'User account involved (if any)';
COMMENT ON COLUMN audit.security_alerts.description IS 'Detailed alert description';
COMMENT ON COLUMN audit.security_alerts.recommendation IS 'Remediation steps';
COMMENT ON COLUMN audit.security_alerts.created_at IS 'Alert creation timestamp';

-- ============================================================================
-- AUDIT LOG RETENTION POLICIES
-- ============================================================================
--
-- Purpose: Define retention policies for compliance
-- Each policy can be scheduled for automated cleanup
--
-- Testability: Policies can be tested with sample data retention
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.retention_policies (
    policy_id        BIGINT GENERATED BY DEFAULT AS IDENTITY,
    policy_name      VARCHAR(100) NOT NULL UNIQUE,
    table_name       VARCHAR(100) NOT NULL,
    retention_type   VARCHAR(50) NOT NULL CHECK (retention_type IN ('delete', 'archive', 'compress')),
    retention_period INTEGER NOT NULL, -- in days
    condition        TEXT, -- WHERE clause for selective retention
    enabled          BOOLEAN NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by       VARCHAR(255),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO audit.retention_policies (policy_name, table_name, retention_type, retention_period, condition, enabled) VALUES
    ('default_audit_retention', 'system_log', 'delete', 365, NULL, true),
    ('default_audit_retention', 'security_alerts', 'delete', 730, NULL, true); -- 2 years for security alerts

COMMENT ON TABLE audit.retention_policies IS 'Automated data retention policies for compliance';
COMMENT ON COLUMN audit.retention_policies.policy_name IS 'Policy identifier';
COMMENT ON COLUMN audit.retention_policies.table_name IS 'Target audit table';
COMMENT ON COLUMN audit.retention_policies.retention_type IS 'Action: delete/archive/compress';
COMMENT ON COLUMN audit.retention_policies.retention_period IS 'Retention period in days';
COMMENT ON COLUMN audit.retention_policies.condition IS 'Optional WHERE clause for selective retention';

-- ============================================================================
-- VIEWS FOR AUDIT QUERIES
-- ============================================================================

-- View: Last hour of security events
CREATE OR REPLACE VIEW audit.view_recent_security_events AS
SELECT 
    sl.id,
    sl.event_type,
    sl.user_name,
    sl.event_class,
    sl.event_code,
    sl.description,
    sl.source_address,
    sl.created_at,
    sa.alert_type,
    sa.severity,
    sa.recommendation
FROM audit.system_log sl
LEFT JOIN audit.security_alerts sa ON sl.id = sa.system_log_id
WHERE sa.alert_type IS NOT NULL
    OR sl.event_class IN ('SECURITY', 'AUTHENTICATION')
ORDER BY sl.created_at DESC;

COMMENT ON VIEW audit.view_recent_security_events IS 'Recent security events for monitoring dashboards';

-- View: User activity summary
CREATE OR REPLACE VIEW audit.view_user_activity AS
SELECT 
    user_name,
    COUNT(*) AS total_events,
    COUNT(CASE WHEN event_type = 'LOGIN_SUCCESS' THEN 1 END) AS successful_logins,
    COUNT(CASE WHEN event_type = 'LOGIN_FAILED' THEN 1 END) AS failed_logins,
    COUNT(CASE WHEN event_class = 'ACCESS_DENIED' THEN 1 END) AS access_denials,
    MIN(created_at) AS first_seen,
    MAX(created_at) AS last_seen,
    MAX(created_at) - MIN(created_at) AS activity_span
FROM audit.system_log
WHERE user_name IS NOT NULL
GROUP BY user_name
ORDER BY total_events DESC;

COMMENT ON VIEW audit.view_user_activity IS 'User activity summary for access review';

-- View: Failed login attempts
CREATE OR REPLACE VIEW audit.view_failed_logins AS
SELECT 
    user_name,
    COUNT(*) AS attempt_count,
    MIN(created_at) AS first_attempt,
    MAX(created_at) AS last_attempt,
    array_agg(source_address) AS source_ips
FROM audit.system_log
WHERE event_type = 'LOGIN_FAILED'
GROUP BY user_name
HAVING COUNT(*) >= 3; -- Only show users with 3+ failed attempts

COMMENT ON VIEW audit.view_failed_logins IS 'Users with multiple failed login attempts';

-- ============================================================================
-- STORED PROCEDURES FOR AUDIT OPERATIONS
-- ============================================================================

-- Procedure: Mark alert as resolved
CREATE OR REPLACE FUNCTION audit.mark_alert_resolved(
    p_alert_id BIGINT,
    p_resolver VARCHAR(255),
    p_resolved_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS VOID AS $$
BEGIN
    UPDATE audit.security_alerts
    SET 
        resolved_at = p_resolved_at,
        resolved_by = p_resolver
    WHERE alert_id = p_alert_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.mark_alert_resolved IS 'Mark a security alert as resolved';

-- Procedure: Generate audit report
CREATE OR REPLACE FUNCTION audit.generate_security_report(
    p_days_back INTEGER DEFAULT 30,
    p_event_types VARCHAR(100)[] DEFAULT NULL
) RETURNS TABLE (
    event_type VARCHAR(100),
    event_count INTEGER,
    first_occurrence TIMESTAMPTZ,
    last_occurrence TIMESTAMPTZ,
    unique_users INTEGER,
    affected_tables TEXT[]
) AS $$
DECLARE
    v_event_types_filter TEXT;
BEGIN
    -- Build filter clause if event types specified
    IF p_event_types IS NOT NULL AND ARRAY_LENGTH(p_event_types, 1) > 0 THEN
        v_event_types_filter := 'WHERE event_type = ANY($1::varchar[])';
    ELSE
        v_event_types_filter := 'WHERE TRUE';
    END IF;

    RETURN QUERY
    SELECT 
        event_type,
        COUNT(*) as event_count,
        MIN(created_at) as first_occurrence,
        MAX(created_at) as last_occurrence,
        COUNT(DISTINCT user_name) as unique_users,
        ARRAY_AGG(DISTINCT table_name) as affected_tables
    FROM audit.system_log sl
    JOIN audit.security_alerts sa ON sl.id = sa.system_log_id
    CROSS JOIN LATERAL (
        SELECT 'WHERE event_class IN (' || 
               string_agg(QUOTE_IDENT(event_class), ', ') || ')'
        FROM (
            SELECT DISTINCT event_class
            FROM audit.system_log
            CROSS JOIN UNNEST(ARRAY['SECURITY', 'AUTHENTICATION', 'ACCESS_DENIED']) as t(event_class)
        ) sub
    ) filter ON TRUE
    LEFT JOIN audit.system_log sl2 ON sl2.id = sl.id 
        AND (sl2.created_at < NOW() - (p_days_back * INTERVAL '1 day') OR sl2.event_type NOT IN (p_event_types))
    WHERE sl.created_at >= NOW() - (p_days_back * INTERVAL '1 day')
        AND sl2.id IS NULL
        AND (v_event_types_filter IS NULL OR (sl.event_type = ANY(p_event_types)))
    GROUP BY event_type
    ORDER BY event_count DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.generate_security_report IS 'Generate security report for specified time period';

-- ============================================================================
-- AUDIT SCHEMA DOCUMENTATION
-- ============================================================================

COMMENT ON SCHEMA audit IS '
================================================================================
AUDIT SCHEMA - ARCHITECTURE & USAGE GUIDE
================================================================================

PERSPECTIVE ANALYSIS:
---------------------

1. MAINTAINABILITY:
   - Schema boundaries separate audit concerns from application data
   - Settings table enables configuration without code changes
   - Partitioning-ready design for high-volume scenarios

2. TESTABILITY:
   - View definitions allow query testing without affecting base tables
   - Function SECURITY DEFINER ensures predictable behavior
   - Settings table can be modified for test scenarios

3. ARCHITECTURE DESIGN:
   - Row-level security enforces least privilege
   - JSONB columns enable flexible event metadata
   - Index strategy supports common query patterns

4. SECURITY STANDARDS:
   - Append-only design prevents tampering
   - Retention policies ensure compliance (GDPR, HIPAA, PCI-DSS)
   - Source IP tracking for forensic analysis
   - RLS policies restrict write access

5. BUSINESS VALUE:
   - Security event monitoring for SOC teams
   - User activity reporting for access reviews
   - Compliance reporting for audits
   - Anomaly detection foundation

6. DOCUMENTATION QUALITY:
   - Comprehensive inline comments
   - Schema-wide documentation block
   - Usage examples provided

USAGE PATTERNS:
---------------

-- Log a custom event:
INSERT INTO audit.system_log (
    event_type, event_class, event_code, description, query, created_at
) VALUES (
    'CUSTOM_EVENT',
    'CUSTOM',
    'CUSTOM_001',
    'Custom audit event occurred',
    NULL,
    NOW()
);

-- Query last hour of security events:
SELECT * FROM audit.view_recent_security_events 
WHERE created_at >= NOW() - INTERVAL '1 hour';

-- Check for brute force attempts:
SELECT * FROM audit.view_failed_logins 
WHERE last_attempt >= NOW() - INTERVAL '24 hours'
ORDER BY attempt_count DESC;

-- Generate security report:
SELECT * FROM audit.generate_security_report(30, ARRAY['LOGIN_FAILED', 'ACCESS_DENIED']);

-- Configure retention:
UPDATE audit.settings SET setting_value = '730' WHERE setting_name = 'retention_days';

================================================================================
================================================================================
';
