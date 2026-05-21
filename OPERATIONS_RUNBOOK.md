# Operations Runbook: LunaBlue-SQL

## Executive Summary

This runbook provides step-by-step procedures for operating the LunaBlue-SQL PostgreSQL database system in production and development environments.

---

## Table of Contents

1. [Prerequisites & Access](#1-prerequisites--access)
2. [Startup Procedures](#2-startup-procedures)
3. [Health Monitoring](#3-health-monitoring)
4. [Database Maintenance](#4-database-maintenance)
5. [Backup & Recovery](#5-backup--recovery)
6. [Scaling & Performance](#6-scaling--performance)
7. [Troubleshooting & Incident Response](#7-troubleshooting--incident-response)
8. [Security Operations](#8-security-operations)
9. [Compliance & Audit](#9-compliance--audit)
10. [Runbook Maintenance](#10-runbook-maintenance)

---

## 1. Prerequisites & Access

### 1.1 Required Tools

```bash
# Docker and Docker Compose (minimum versions)
docker --version       # 24.0+
docker-compose --version  # 2.0+

# PostgreSQL client tools (for administration)
psql --version         # 16+

# Backup and monitoring tools
pg_dump               # Included with PostgreSQL
pg_restore            # Included with PostgreSQL

# System utilities
jq                    # JSON query (for metrics)
curl                  # HTTP requests (for health checks)
```

### 1.2 Access Controls

**Production Access**:
- ✅ PostgreSQL superuser (`postgres`) - only for emergencies
- ✅ Application user (`app_user`) - normal operations
- ✅ Read-only user (`readonly_user`) - queries and monitoring
- ❌ Public access - disabled

**Test/Dev Access**:
- ✅ Full schema read-write for testing
- ✅ Can create/drop test tables
- ❌ Cannot modify production audit schema

### 1.3 Connection Credentials

```bash
# Set environment variables for easy access
export PGHOST=localhost        # or Docker service name
export PGPORT=5432
export PGUSER=postgres         # For admin operations
export PGDATABASE=postgres

# Test connection
psql -c "SELECT 1"

# Expected output: 
# ?column?
# ----------
#        1
```

---

## 2. Startup Procedures

### 2.1 Cold Start (First Run)

**Step 1: Initialize Docker environment**

```bash
# Navigate to project directory
cd /path/to/LunaBlue-SQL

# Create necessary directories
mkdir -p data backups logs

# Set correct permissions
chmod 700 data          # PostgreSQL needs exclusive access
chmod 755 backups logs
```

**Step 2: Configure environment**

```bash
# Create .env file with production settings
cat > .env << 'EOF'
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_secure_password_here
POSTGRES_PORT=5432
EOF

# Verify .env is created (and NOT in version control)
ls -la .env
grep -v "^#" .env
```

**Step 3: Build and start**

```bash
# Build Docker image
docker build -t lunablue:postgres-16 .

# Start services
docker-compose up -d

# Monitor initialization
docker-compose logs -f postgres | grep "ready to accept"

# Should see: "database system is ready to accept connections"
# Wait for this message before proceeding
```

**Step 4: Verify initialization**

```bash
# Check container health
docker-compose ps
# STATUS should be "healthy"

# Verify schemas exist
docker exec lunablue-postgres psql -U postgres -c "\dn"

# Expected output:
#  List of schemas
#  Name |  Owner   |
# ------+----------+
#  audit | postgres |
#  pii   | postgres |
#  public| postgres |
#  rag   | postgres |

# Verify audit tables exist
docker exec lunablue-postgres psql -U postgres -c "\dt audit.*"

# Verify PII tables exist
docker exec lunablue-postgres psql -U postgres -c "\dt pii.*"

# Verify RAG tables exist
docker exec lunablue-postgres psql -U postgres -c "\dt rag.*"
```

**Step 5: Create initial backup**

```bash
# Create backups directory
mkdir -p backups

# Create initial backup
docker exec lunablue-postgres pg_dump -U postgres -Fc postgres \
  > backups/lunablue_initial.dump

# Verify backup
ls -lh backups/lunablue_initial.dump
# Should be 1-10 MB depending on schema size
```

### 2.2 Warm Start (Restart)

```bash
# Start existing container (data preserved)
docker-compose up -d

# Wait for health check to pass
docker-compose ps
# STATUS should become "healthy" within 30 seconds

# Verify connectivity
docker exec lunablue-postgres pg_isready -U postgres
# Expected: "accepting connections"

# Verify data is intact
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT COUNT(*) FROM audit.system_log"
```

### 2.3 Startup Health Checks

**Automated checks**:

```bash
#!/bin/bash
# startup_checks.sh - Verify all systems operational

echo "✓ Checking container status..."
docker-compose ps | grep -q "healthy" || exit 1

echo "✓ Checking PostgreSQL connectivity..."
docker exec lunablue-postgres pg_isready -U postgres || exit 1

echo "✓ Checking schemas..."
for schema in audit pii rag; do
  docker exec lunablue-postgres psql -U postgres -c \
    "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$schema'" | grep -q 1 || exit 1
done

echo "✓ Checking critical tables..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT COUNT(*) FROM audit.settings" > /dev/null || exit 1

echo "✅ All startup checks passed!"
```

---

## 3. Health Monitoring

### 3.1 Daily Health Checks

**Every hour** (automated):

```bash
#!/bin/bash
# hourly_health_check.sh

# Check container is running
docker inspect lunablue-postgres -f '{{.State.Running}}' | grep -q true || \
  echo "ALERT: Container not running"

# Check disk usage
disk_usage=$(df -h ./data | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$disk_usage" -gt 80 ]; then
  echo "WARNING: Disk usage at ${disk_usage}%"
fi

# Check memory usage
memory_usage=$(docker stats lunablue-postgres --no-stream | tail -1 | awk '{print $7}' | sed 's/%//')
if [ "$memory_usage" -gt 80 ]; then
  echo "WARNING: Memory usage at ${memory_usage}%"
fi

# Check database connections
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT count(*) as connections FROM pg_stat_activity" | grep -q "1" && \
  echo "✓ Database accepting connections"
```

**Daily checks** (manual):

```bash
#!/bin/bash
# daily_health_check.sh

echo "=== Daily Health Check ==="

# 1. Audit log health
echo "1. Checking audit logs..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT COUNT(*) as audit_events FROM audit.system_log WHERE created_at > NOW() - INTERVAL '24 hours'"

# 2. Database size
echo "2. Checking database size..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) \
   FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC"

# 3. Index health
echo "3. Checking index usage..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch \
   FROM pg_stat_user_indexes ORDER BY idx_scan DESC LIMIT 10"

# 4. Long-running queries
echo "4. Checking for long-running queries..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT pid, now() - query_start as duration, query \
   FROM pg_stat_activity WHERE state != 'idle' ORDER BY duration DESC"

# 5. Connection pool health
echo "5. Checking connections..."
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT COUNT(*) as active_connections FROM pg_stat_activity WHERE state = 'active'"

echo "=== Health Check Complete ==="
```

### 3.2 Metrics Dashboard Queries

**Query 1: System health overview**

```sql
SELECT 
    COUNT(*) as total_connections,
    COUNT(*) FILTER (WHERE state = 'active') as active_queries,
    COUNT(*) FILTER (WHERE state = 'idle') as idle_connections,
    COUNT(*) FILTER (WHERE wait_event IS NOT NULL) as waiting_queries
FROM pg_stat_activity;
```

**Query 2: Audit log volume**

```sql
SELECT 
    DATE_TRUNC('day', created_at) as day,
    COUNT(*) as events,
    COUNT(DISTINCT user_action) as unique_actions
FROM audit.system_log
GROUP BY DATE_TRUNC('day', created_at)
ORDER BY day DESC
LIMIT 30;
```

**Query 3: Performance metrics**

```sql
SELECT 
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    ROUND(100.0 * idx_scan / (seq_scan + idx_scan), 2) as index_usage_percent
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
```

---

## 4. Database Maintenance

### 4.1 Routine Maintenance Schedule

**Daily**:
- ✅ Health checks (see section 3.1)
- ✅ Backup (automated or scheduled)
- ✅ Log rotation (handled by docker logging)

**Weekly**:
- ✅ Analyze query performance
- ✅ Review error logs
- ✅ Verify backup integrity

**Monthly**:
- ✅ Full system backup test
- ✅ Review capacity planning metrics
- ✅ Security audit log review

**Quarterly**:
- ✅ Update PostgreSQL extensions
- ✅ Review access control policies
- ✅ Audit trail analysis

### 4.2 Regular Maintenance Tasks

**Vacuum and analyze** (nightly):

```bash
#!/bin/bash
# nightly_maintenance.sh

docker exec lunablue-postgres psql -U postgres << EOF
  -- Audit schema
  VACUUM ANALYZE audit.system_log;
  VACUUM ANALYZE audit.settings;
  
  -- PII schema
  VACUUM ANALYZE pii.encryption_config;
  VACUUM ANALYZE pii.pii_categories;
  
  -- RAG schema
  VACUUM ANALYZE rag.documents;
  VACUUM ANALYZE rag.chunks;
  VACUUM ANALYZE rag.embeddings;
  
  -- Report statistics
  SELECT 
      schemaname,
      tablename,
      ROUND(pg_total_relation_size(schemaname || '.' || tablename) / 1024.0 / 1024.0, 2) as size_mb
  FROM pg_tables
  WHERE schemaname IN ('audit', 'pii', 'rag')
  ORDER BY size_mb DESC;
EOF
```

**Reindex** (weekly):

```bash
#!/bin/bash
# weekly_reindex.sh

docker exec lunablue-postgres psql -U postgres << EOF
  -- Reindex critical tables
  REINDEX INDEX CONCURRENTLY audit.system_log_created_at_idx;
  REINDEX INDEX CONCURRENTLY rag.documents_status_idx;
  REINDEX INDEX CONCURRENTLY rag.embeddings_vector_idx;
EOF
```

**Clean old audit logs** (monthly, optional):

```sql
-- Keep audit logs for 1 year
DELETE FROM audit.system_log 
WHERE created_at < NOW() - INTERVAL '1 year'
AND severity_level != 'CRITICAL';
```

---

## 5. Backup & Recovery

### 5.1 Backup Strategy

**Backup types**:

| Type | Frequency | Retention | Purpose |
|------|-----------|-----------|---------|
| Full backup | Daily | 30 days | Recovery point |
| Incremental | 6-hourly | 7 days | RPO < 6 hours |
| Archive backup | Monthly | 1 year | Compliance |

### 5.2 Automated Backup

**Daily backup script** (`backup_daily.sh`):

```bash
#!/bin/bash

CONTAINER_NAME="lunablue-postgres"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/lunablue_${TIMESTAMP}.dump"
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

echo "[$(date)] Starting backup..." | tee -a "$LOG_FILE"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Perform backup
if docker exec "$CONTAINER_NAME" pg_dump -U postgres -Fc postgres > "$BACKUP_FILE" 2>> "$LOG_FILE"; then
    echo "[$(date)] Backup successful: $BACKUP_FILE ($(du -h $BACKUP_FILE | cut -f1))" | tee -a "$LOG_FILE"
    
    # Compress backup
    gzip "$BACKUP_FILE"
    echo "[$(date)] Backup compressed: ${BACKUP_FILE}.gz" | tee -a "$LOG_FILE"
    
    # Delete old backups (keep 30 days)
    find "$BACKUP_DIR" -name "lunablue_*.dump.gz" -mtime +30 -delete
    echo "[$(date)] Old backups deleted" | tee -a "$LOG_FILE"
    
    exit 0
else
    echo "[$(date)] ❌ Backup FAILED" | tee -a "$LOG_FILE"
    exit 1
fi
```

**Schedule with cron**:

```bash
# crontab -e
# Run backup daily at 2 AM
0 2 * * * /path/to/backup_daily.sh

# Verify backup is running
crontab -l | grep backup_daily
```

### 5.3 Restore Procedures

**From latest backup**:

```bash
#!/bin/bash
# restore_from_latest.sh

BACKUP_DIR="./backups"
LATEST_BACKUP=$(ls -1t "${BACKUP_DIR}"/lunablue_*.dump.gz | head -1)
CONTAINER_NAME="lunablue-postgres"

if [ ! -f "$LATEST_BACKUP" ]; then
  echo "❌ No backup found"
  exit 1
fi

echo "Restoring from: $LATEST_BACKUP"

# Stop current container (optional, to release locks)
# docker-compose stop

# Decompress backup
DUMP_FILE="${LATEST_BACKUP%.gz}"
gunzip -c "$LATEST_BACKUP" > "$DUMP_FILE"

# Restore to running container
docker exec -i "$CONTAINER_NAME" pg_restore -U postgres -Fc -d postgres < "$DUMP_FILE"

echo "✅ Restore complete"

# Clean up
rm "$DUMP_FILE"
```

**Point-in-time recovery** (if WAL archiving enabled):

```sql
-- Restore to specific timestamp
SELECT pg_wal_replay_pause();
-- Wait until pg_wal_lsn_diff(...) indicates desired time reached
SELECT pg_wal_replay_resume();
```

### 5.4 Backup Verification

**Monthly backup test**:

```bash
#!/bin/bash
# verify_backup.sh

BACKUP_FILE="$1"
CONTAINER_NAME="lunablue-postgres"
TEST_DB="lunablue_test_restore"

echo "Starting backup verification..."

# Create test database
docker exec "$CONTAINER_NAME" createdb "$TEST_DB"

# Restore backup to test database
docker exec -i "$CONTAINER_NAME" pg_restore -U postgres -Fc -d "$TEST_DB" < "$BACKUP_FILE"

# Verify restore was successful
docker exec "$CONTAINER_NAME" psql -U postgres -d "$TEST_DB" -c \
  "SELECT COUNT(*) FROM audit.system_log"

# Drop test database
docker exec "$CONTAINER_NAME" dropdb "$TEST_DB"

echo "✅ Backup verification complete"
```

---

## 6. Scaling & Performance

### 6.1 Capacity Planning

**Monitor growth**:

```bash
#!/bin/bash
# capacity_monitor.sh

echo "=== Capacity Monitoring ==="
echo "Current Date: $(date)"

# Database size
DB_SIZE=$(docker exec lunablue-postgres psql -U postgres -tc \
  "SELECT pg_size_pretty(pg_database_size('postgres'))")
echo "Total database size: $DB_SIZE"

# Audit log size
AUDIT_SIZE=$(docker exec lunablue-postgres psql -U postgres -tc \
  "SELECT pg_size_pretty(pg_total_relation_size('audit.system_log'))")
echo "Audit log size: $AUDIT_SIZE"

# Row counts
echo "Audit events: $(docker exec lunablue-postgres psql -U postgres -tc \
  "SELECT COUNT(*) FROM audit.system_log")"

echo "RAG documents: $(docker exec lunablue-postgres psql -U postgres -tc \
  "SELECT COUNT(*) FROM rag.documents")"

# Disk usage
DISK_USAGE=$(df -h ./data | tail -1 | awk '{print $3, $2, "(" $5 ")"}'
echo "Disk usage: $DISK_USAGE"
```

### 6.2 Performance Tuning

**If queries slow** (> 1 second):

```bash
# 1. Check slow query log
docker exec lunablue-postgres tail -f /var/log/postgresql/*.log | grep "duration:"

# 2. Identify missing indexes
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT schemaname, tablename, indexname FROM pg_indexes \
   WHERE schemaname IN ('audit', 'pii', 'rag') \
   ORDER BY tablename"

# 3. Add missing index if needed
docker exec lunablue-postgres psql -U postgres -c \
  "CREATE INDEX idx_audit_severity ON audit.system_log(severity_level) CONCURRENTLY"

# 4. Analyze impact
docker exec lunablue-postgres psql -U postgres -c \
  "EXPLAIN ANALYZE SELECT * FROM audit.system_log WHERE severity_level = 'CRITICAL'"
```

**If memory usage high** (> 80%):

```bash
# 1. Check shared_buffers setting
docker exec lunablue-postgres psql -U postgres -c \
  "SHOW shared_buffers"

# 2. Check work_mem allocation
docker exec lunablue-postgres psql -U postgres -c \
  "SHOW work_mem"

# 3. Monitor active connections
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT count(*) FROM pg_stat_activity"

# 4. Kill idle connections if needed
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
   WHERE state = 'idle' AND query_start < now() - INTERVAL '1 hour'"
```

---

## 7. Troubleshooting & Incident Response

### 7.1 Incident Response Workflow

```
1. DETECT: Identify issue (health check failure, slow queries, etc.)
   ↓
2. ASSESS: Determine severity and impact
   ↓
3. MITIGATE: Apply immediate fix (if possible)
   ↓
4. INVESTIGATE: Root cause analysis
   ↓
5. RESOLVE: Apply permanent fix
   ↓
6. DOCUMENT: Record issue and solution
   ↓
7. PREVENT: Implement monitoring to catch earlier next time
```

### 7.2 Common Issues & Solutions

| Issue | Symptom | Diagnosis | Solution |
|-------|---------|-----------|----------|
| **Container won't start** | `docker-compose ps` shows "Exited" | `docker-compose logs postgres \| grep ERROR` | Check disk space, re-init scripts |
| **High memory usage** | `docker stats` shows > 90% | `docker exec ... psql -c "SELECT * FROM pg_stat_activity"` | Reduce `shared_buffers`, kill idle connections |
| **Slow audit queries** | Query > 5 seconds | `EXPLAIN ANALYZE` the query | Add index on `created_at`, use partitioning |
| **Disk full** | Backup fails, inserts fail | `df -h ./data` | Delete old backups, compress, or extend volume |
| **Connection timeout** | Application can't connect | `docker exec ... pg_isready` | Restart container, check network |
| **Data corruption** | Checksums mismatch | `REINDEX`, `VACUUM FULL` | Restore from backup, investigate cause |

### 7.3 Serious Issues: Disaster Recovery

**If audit trail is corrupted**:

```bash
# 1. DO NOT DELETE - preserve for forensics
# 2. Create read-only snapshot
docker-compose stop

# 3. Copy data for analysis
cp -r ./data ./data_backup_corrupted_$(date +%Y%m%d)

# 4. Restore from backup
# (See section 5.3)
```

**If entire database lost**:

```bash
# 1. Stop container
docker-compose down

# 2. Remove corrupted data
rm -rf ./data/*

# 3. Start fresh (will run init scripts again)
docker-compose up -d

# 4. Restore from backup (if schemas initialized)
# (See section 5.3)
```

---

## 8. Security Operations

### 8.1 Access Control Management

**Create application user** (for developers):

```sql
-- Connect as superuser
docker exec lunablue-postgres psql -U postgres << EOF

-- Create application user
CREATE ROLE app_user WITH LOGIN PASSWORD 'secure_password_here';

-- Grant read access to audit
GRANT USAGE ON SCHEMA audit TO app_user;
GRANT SELECT ON audit.system_log TO app_user;
GRANT SELECT ON audit.settings TO app_user;

-- Grant read access to PII
GRANT USAGE ON SCHEMA pii TO app_user;
GRANT SELECT ON pii.encryption_config TO app_user;

-- Grant read/write access to RAG
GRANT USAGE ON SCHEMA rag TO app_user;
GRANT SELECT, INSERT, UPDATE ON rag.documents TO app_user;
GRANT SELECT, INSERT ON rag.chunks TO app_user;
GRANT SELECT, INSERT ON rag.embeddings TO app_user;

-- Grant sequence permissions
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA rag TO app_user;

EOF
```

**Create read-only user** (for monitoring):

```sql
CREATE ROLE readonly_user WITH LOGIN PASSWORD 'secure_password';

GRANT USAGE ON SCHEMA audit, pii, rag TO readonly_user;

GRANT SELECT ON ALL TABLES IN SCHEMA audit TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA pii TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA rag TO readonly_user;
```

### 8.2 Password Management

**Rotate passwords** (quarterly):

```bash
#!/bin/bash
# rotate_passwords.sh

CONTAINER_NAME="lunablue-postgres"
USERS=("app_user" "readonly_user")

for user in "${USERS[@]}"; do
  NEW_PASSWORD=$(openssl rand -base64 32)
  echo "Changing password for $user..."
  
  docker exec "$CONTAINER_NAME" psql -U postgres -c \
    "ALTER ROLE $user WITH PASSWORD '$NEW_PASSWORD'"
  
  # Save password securely (e.g., to password manager)
  echo "$user:$NEW_PASSWORD" | openssl enc -aes-256-cbc -salt -out "${user}.enc"
  
  echo "Password rotated for $user"
done
```

### 8.3 Audit Trail Review

**Weekly security audit**:

```bash
#!/bin/bash
# security_audit.sh

docker exec lunablue-postgres psql -U postgres << EOF

-- Failed connections
SELECT 'Failed auth attempts' as type, COUNT(*) as count
FROM audit.system_log
WHERE event_type = 'AUTH_FAILED'
AND created_at > NOW() - INTERVAL '7 days';

-- Privilege escalations
SELECT 'Privilege changes' as type, COUNT(*) as count
FROM audit.system_log
WHERE event_type = 'PRIVILEGE_CHANGE'
AND created_at > NOW() - INTERVAL '7 days';

-- Data access violations
SELECT 'Access violations' as type, COUNT(*) as count
FROM audit.system_log
WHERE event_type = 'ACCESS_DENIED'
AND created_at > NOW() - INTERVAL '7 days';

-- Schema modifications
SELECT 'Schema changes' as type, COUNT(*) as count
FROM audit.system_log
WHERE event_type IN ('CREATE', 'DROP', 'ALTER')
AND created_at > NOW() - INTERVAL '7 days';

EOF
```

---

## 9. Compliance & Audit

### 9.1 Compliance Reporting

**GDPR compliance report**:

```sql
-- Data retention policy
SELECT 
    'Audit logs retention' as policy,
    COUNT(*) as event_count,
    MIN(created_at) as earliest_event,
    MAX(created_at) as latest_event,
    DATE_TRUNC('day', MAX(created_at) - MIN(created_at)) as age_days
FROM audit.system_log;

-- PII inventory
SELECT 
    'PII categories in use' as inventory,
    COUNT(DISTINCT category) as categories
FROM pii.pii_categories;

-- Access log
SELECT 
    'Access events (last 30 days)' as report,
    user_action,
    COUNT(*) as count
FROM audit.system_log
WHERE created_at > NOW() - INTERVAL '30 days'
GROUP BY user_action
ORDER BY count DESC;
```

**HIPAA compliance report**:

```sql
-- Audit trail completeness
SELECT 
    'Audit trail' as control,
    COUNT(*) as total_events,
    COUNT(*) FILTER (WHERE user_action IS NOT NULL) as attributed_events,
    ROUND(100.0 * COUNT(*) FILTER (WHERE user_action IS NOT NULL) / COUNT(*), 2) as attribution_percent
FROM audit.system_log;

-- Access control verification
SELECT 
    'Role-based access' as control,
    COUNT(*) as users
FROM information_schema.role_usage;

-- Data protection
SELECT 
    'Encryption configuration' as control,
    COUNT(*) as algorithms
FROM pii.encryption_config
WHERE enabled = TRUE;
```

### 9.2 Audit Log Export

**Export for compliance review**:

```bash
#!/bin/bash
# export_audit_logs.sh

CONTAINER_NAME="lunablue-postgres"
EXPORT_DATE=$(date +%Y%m%d)
EXPORT_FILE="audit_export_${EXPORT_DATE}.csv"

# Export to CSV
docker exec "$CONTAINER_NAME" psql -U postgres -c \
  "COPY (SELECT * FROM audit.system_log ORDER BY created_at) \
   TO STDOUT WITH CSV HEADER" > "$EXPORT_FILE"

# Verify export
echo "Exported $(wc -l < $EXPORT_FILE) rows to $EXPORT_FILE"

# Archive with encryption
tar czf "${EXPORT_FILE}.tar.gz" "$EXPORT_FILE"
rm "$EXPORT_FILE"

# Sign archive
gpg --detach-sign "${EXPORT_FILE}.tar.gz"

# Verify signature
gpg --verify "${EXPORT_FILE}.tar.gz.sig" "${EXPORT_FILE}.tar.gz" && \
  echo "✅ Archive signed and verified"
```

---

## 10. Runbook Maintenance

### 10.1 Runbook Updates

This runbook should be updated when:
- ✅ Procedures change (e.g., new backup strategy)
- ✅ Issues discovered and resolved
- ✅ New operations requirements added
- ✅ Performance tuning applied

### 10.2 Change Log

| Date | Change | Reason | Author |
|------|--------|--------|--------|
| 2026-05-20 | Initial runbook | System launch | DevOps |
| | | | |

---

## Quick Reference: Common Commands

```bash
# Status & Health
docker-compose ps                          # Container status
docker-compose logs -f postgres            # Live logs
docker exec ... pg_isready -U postgres     # Connection test
docker stats lunablue-postgres             # Resource usage

# Backup & Restore
docker exec ... pg_dump -U postgres -Fc postgres > backup.dump
docker exec -i ... pg_restore -U postgres < backup.dump

# Database Access
docker exec -it ... psql -U postgres       # Interactive SQL
docker exec ... psql -U postgres -c "..."  # Run SQL command

# Maintenance
docker exec ... psql -U postgres -c "VACUUM ANALYZE"
docker exec ... psql -U postgres -c "REINDEX TABLE ..."

# Security
docker exec ... psql -U postgres -c "CREATE ROLE ..."
docker exec ... psql -U postgres -c "GRANT ... ON ... TO ..."

# Monitoring
docker exec ... psql -U postgres -c "SELECT * FROM pg_stat_activity"
docker exec ... psql -U postgres -c "SELECT * FROM audit.system_log LIMIT 10"
```

---

**Last Updated**: May 20, 2026  
**Version**: 1.0  
**Status**: Complete

