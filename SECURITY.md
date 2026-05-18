# Security Hardening Guide for PostgreSQL 16 + pgvector

## Executive Summary

This guide provides security best practices for deploying PostgreSQL 16 with pgvector in development, testing, and production environments. It covers image-level security, runtime security, operational security, and pgvector-specific considerations.

---

## 1. Image-Level Security

### ✓ What's Already Secure in This Image

#### Non-Root User Execution
```bash
# PostgreSQL process runs as 'postgres' user (non-root)
docker run postgres-pgvector whoami
# Output: postgres
```

**Why This Matters**: If PostgreSQL is exploited, attacker cannot immediately gain root access.

#### Multi-Stage Build
**Security Implication**: Build tools (gcc, git, make) are NOT in the final image
- ✓ Smaller attack surface (no compiler tools to abuse)
- ✓ Fewer CVEs (fewer packages = fewer vulnerabilities)
- ✓ Cannot be used as pivot point by attackers

**Verification**:
```bash
# Verify build tools are not present
docker run --rm postgres-pgvector which gcc
# Output: not found ✓

docker run --rm postgres-pgvector which make
# Output: not found ✓
```

#### Version Pinning
**Security Implication**: Known versions can be audited and monitored
```dockerfile
FROM postgres:16-bookworm  # Specific base version
git clone --branch v0.5.1  # Specific pgvector version
```

**Audit Trail**:
```bash
# Know exactly what's in production
docker inspect postgres-pgvector | grep '"RepoDigests"'
# Shows exact SHA of base image used
```

### ⚠ What Requires Runtime Security Configuration

#### Database User Credentials
**NOT secure in image**: Password must be provided at runtime

**Vulnerable Pattern** (DO NOT DO THIS):
```dockerfile
# ❌ WRONG
ENV POSTGRES_PASSWORD=hardcoded_password_here
```

**Secure Pattern** (DO THIS):
```bash
# Option 1: Command line (development only)
docker run -e POSTGRES_PASSWORD="$(openssl rand -base64 32)" postgres-pgvector

# Option 2: Docker Secrets (production - Docker Swarm)
docker secret create postgres_password -
docker service create --secret postgres_password \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password postgres-pgvector

# Option 3: Kubernetes Secrets (production - Kubernetes)
kubectl create secret generic postgres-secret \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl set env deployment/postgres -e POSTGRES_PASSWORD_FILE=/var/run/secrets/kubernetes.io/serviceaccount/password

# Option 4: External secret manager (production)
# HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, etc.
```

---

## 2. Runtime Security

### Network Isolation

#### Principle: Minimal Network Exposure
```bash
# ❌ WRONG - exposes to entire network
docker run -p 5432:5432 postgres-pgvector

# ✓ BETTER - binds only to localhost (for local testing)
docker run -p 127.0.0.1:5432:5432 postgres-pgvector

# ✓ BEST - no port mapping, use docker network
docker network create postgres-net
docker run --network postgres-net --name postgres postgres-pgvector
docker run --network postgres-net app-container  # Can connect via 'postgres' hostname
```

#### Production Network Policy (Kubernetes)
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-network-policy
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend-service
    ports:
    - protocol: TCP
      port: 5432
  # DENY all other traffic
```

### Volume Security

#### Data at Rest Encryption
```bash
# Kubernetes: Use encrypted volumes
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  storageClassName: encrypted
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
```

#### File Permissions
```bash
# PostgreSQL data directory should be:
# Owner: postgres user (not root)
# Permissions: 0700 (only postgres can read)

# Verify in running container
docker exec postgres-pgvector ls -la /var/lib/postgresql/data
# Output: drwx------ postgres postgres /var/lib/postgresql/data
```

#### Backup Encryption
```bash
# Create encrypted backup
docker exec postgres-pgvector pg_dump -U postgres postgres | \
  openssl enc -aes-256-cbc -salt -out backup.dump.enc

# Restore from encrypted backup
openssl enc -d -aes-256-cbc -in backup.dump.enc | \
  docker exec -i postgres-pgvector psql -U postgres
```

---

## 3. Operational Security

### User Permissions (PostgreSQL-Level)

#### Principle: Least Privilege
```sql
-- ❌ WRONG - superuser for application
CREATE ROLE app_user WITH SUPERUSER LOGIN PASSWORD 'password';

-- ✓ RIGHT - minimal permissions
CREATE ROLE app_user WITH LOGIN PASSWORD 'password';
CREATE DATABASE app_db OWNER app_user;
GRANT CONNECT ON DATABASE app_db TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;

-- ✓ BETTER - role-based access control
CREATE ROLE readers;
CREATE ROLE writers;
CREATE ROLE app_user;
GRANT readers TO app_user;
GRANT writers TO app_user;
GRANT SELECT ON table_name TO readers;
GRANT INSERT, UPDATE, DELETE ON table_name TO writers;
```

#### pgvector-Specific Permissions
```sql
-- Allow app user to create vectors
CREATE TABLE IF NOT EXISTS embeddings (
    id SERIAL PRIMARY KEY,
    embedding vector(1536),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Only allow app user to work with this table
GRANT SELECT, INSERT ON embeddings TO app_user;
GRANT USAGE, SELECT ON SEQUENCE embeddings_id_seq TO app_user;

-- Prevent app user from modifying structure
REVOKE ALTER ON TABLE embeddings FROM app_user;
```

### Connection Security

#### SSL/TLS Encryption in Transit
```bash
# Generate self-signed certificate (development)
openssl req -new -x509 -days 365 -nodes \
  -out /var/lib/postgresql/server.crt \
  -keyout /var/lib/postgresql/server.key

# For production: Use CA-signed certificate

# Enable SSL in PostgreSQL
docker run \
  -e POSTGRES_INIT_ARGS="-c ssl=on" \
  -v /certs/server.crt:/var/lib/postgresql/server.crt:ro \
  -v /certs/server.key:/var/lib/postgresql/server.key:ro \
  postgres-pgvector
```

#### Connection Limiting
```sql
-- Limit connections per user to prevent DoS
ALTER ROLE app_user WITH CONNECTION LIMIT 50;

-- Limit total connections
-- In PostgreSQL config: max_connections = 100
```

#### Idle Connection Timeout
```sql
-- Close idle connections after 30 minutes
-- In PostgreSQL config: idle_in_transaction_session_timeout = 1800000
```

### Audit Logging

#### Query Logging (High-Volume - Use Sparingly)
```sql
-- Log all queries (for forensics)
-- In PostgreSQL config: log_statement = 'all'
-- In PostgreSQL config: log_min_duration_statement = 0

-- Better: Log only dangerous operations
-- In PostgreSQL config: log_statement = 'ddl, dml'
-- In PostgreSQL config: log_duration = on
```

#### Connection Logging
```sql
-- Always log connections
-- In PostgreSQL config: log_connections = on
-- In PostgreSQL config: log_disconnections = on
```

#### JSON Audit Table (Recommended)
```sql
CREATE TABLE IF NOT EXISTS audit_log (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50),
    user_name VARCHAR(255),
    database_name VARCHAR(255),
    query TEXT,
    executed_at TIMESTAMP DEFAULT NOW(),
    source_address INET,
    parameters JSONB
);

-- Grant app user write-only access
GRANT INSERT ON audit_log TO app_user;
REVOKE SELECT, UPDATE, DELETE ON audit_log FROM app_user;
```

---

## 4. pgvector-Specific Security Considerations

### Vector Data Access Control

#### Sensitive Embeddings
```sql
-- Create separate table for sensitive embeddings
CREATE TABLE sensitive_embeddings (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Row-level security: User can only see their own embeddings
CREATE POLICY user_embeddings ON sensitive_embeddings
    FOR SELECT
    USING (user_id = current_user_id());

ALTER TABLE sensitive_embeddings ENABLE ROW LEVEL SECURITY;
```

### Index Security

#### HNSW Index Resource Limits
```sql
-- HNSW indexes can consume significant memory
-- Monitor memory usage:
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelname::regclass)) as size
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelname::regclass) DESC;

-- Limit index size by partitioning:
CREATE TABLE embeddings_partition_2024 PARTITION OF embeddings
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

### Query Injection Prevention

#### Parameterized Queries (Required)
```sql
-- ❌ WRONG - SQL injection vulnerable
SELECT * FROM embeddings 
WHERE embedding <-> '[' + user_input + ']'::vector LIMIT 10;

-- ✓ CORRECT - parameterized query
PREPARE search_embedding AS 
    SELECT * FROM embeddings 
    WHERE embedding <-> $1::vector 
    ORDER BY embedding <-> $1::vector 
    LIMIT $2;

EXECUTE search_embedding('[1,2,3]'::vector, 10);
```

#### Application-Level Protection
```python
# Python + psycopg2 example
import psycopg2
from psycopg2.sql import SQL, Literal

query_vector = [1.0, 2.0, 3.0]  # From user input

# Safe: Parameter binding
cursor.execute(
    SQL("SELECT * FROM embeddings WHERE embedding <-> %s::vector LIMIT %s"),
    (query_vector, 10)
)

# Unsafe: String concatenation
# cursor.execute(f"SELECT * FROM embeddings WHERE embedding <-> '{query_vector}'")
```

---

## 5. Vulnerability Monitoring

### Container Image Scanning

#### Scan Before Deployment
```bash
# Use Trivy (OSS vulnerability scanner)
trivy image postgres-pgvector:16

# Output shows all CVEs with severity
# HIGH: OpenSSL version X.Y.Z has CVE-XXXX-XXXXX

# Use Docker Scout (Docker-native)
docker scout cves postgres-pgvector:16
```

#### Automated Scanning in CI/CD
```yaml
# GitHub Actions example
name: Container Security Scan
on: [push, pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
    - name: Build image
      run: docker build -t postgres-pgvector:16 .
    - name: Scan with Trivy
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: postgres-pgvector:16
        severity: CRITICAL,HIGH
        exit-code: 1  # Fail CI if vulnerabilities found
```

### Runtime Monitoring

#### Health Check Verification
```bash
# Monitor container health status
watch -n 5 'docker inspect postgres-pgvector | grep -A 5 '"'"'Health'"'"''

# Alert if status becomes "unhealthy"
docker events --filter type=container --filter status=unhealthy
```

#### PostgreSQL Log Monitoring
```bash
# Stream logs
docker logs -f postgres-pgvector

# Grep for errors
docker logs postgres-pgvector | grep ERROR

# Parse JSON logs for analysis
docker logs postgres-pgvector --timestamps | jq -r '.[] | select(.level == "ERROR")'
```

---

## 6. Security Checklist

### Pre-Deployment
- [ ] Image scanned with Trivy/Docker Scout (0 CRITICAL/HIGH CVEs)
- [ ] Base image updated to latest patch version
- [ ] pgvector version is latest stable (v0.5.1 or newer)
- [ ] Secrets management strategy selected (Vault/K8s Secrets/AWS Secrets)
- [ ] Network isolation policy defined
- [ ] Backup encryption method chosen
- [ ] Audit logging configured

### At Deployment Time
- [ ] Random password generated for postgres superuser
- [ ] Non-root user verified (docker inspect)
- [ ] Volume permissions are 0700 (docker exec ls -la)
- [ ] Network is restricted (not exposed to internet)
- [ ] Health check is passing
- [ ] Logs show no ERROR messages
- [ ] SSL/TLS configured (if production)

### Post-Deployment
- [ ] Health check passes consistently
- [ ] Connection monitoring active
- [ ] Audit logs are flowing to secure storage
- [ ] Backup tests passing (restore backup, verify data)
- [ ] Performance baseline established
- [ ] Alert rules configured for security events

---

## 7. Compliance & Standards

### GDPR Compliance
- [ ] Data at rest encrypted
- [ ] Data in transit encrypted (SSL/TLS)
- [ ] Access audit trails maintained
- [ ] Data retention policy enforced
- [ ] Right to be forgotten implemented (delete procedures)

### HIPAA Compliance (Healthcare)
- [ ] Encryption in transit and at rest (FIPS 140-2)
- [ ] Role-based access control (RBAC) implemented
- [ ] Comprehensive audit logging enabled
- [ ] Data integrity verification in place
- [ ] Disaster recovery plan documented

### PCI-DSS Compliance (Payment Cards)
- [ ] Network segmented from cardholder data
- [ ] Encryption of cardholder data at rest and in transit
- [ ] Regular security testing (vulnerability scans)
- [ ] Access control via roles and authentication
- [ ] Audit logging for all access

---

## 8. Incident Response

### If PostgreSQL Is Compromised

#### Immediate Actions (0-15 minutes)
```bash
# 1. Isolate the container
docker network disconnect postgres-net postgres-container

# 2. Preserve logs for forensics
docker logs postgres-container > /secure/forensics/logs.txt

# 3. Preserve database snapshot
docker exec postgres-container pg_dumpall > /secure/forensics/backup.sql

# 4. Shut down gracefully
docker stop postgres-container
```

#### Investigation (15-60 minutes)
```bash
# Check what was accessed
grep "LOG:" /secure/forensics/logs.txt | grep -v "connection"

# Find modified data
# Compare backup from forensics to previous known-good backup
```

#### Recovery (1-4 hours)
```bash
# 1. Patch or rebuild image
docker build --no-cache -t postgres-pgvector:16-patched .

# 2. Verify new image is secure
docker scout cves postgres-pgvector:16-patched

# 3. Restore from backup
docker run postgres-pgvector:16-patched
# Restore database from known-good backup
psql < /secure/forensics/backup.sql

# 4. Rotate all credentials
# Change all PostgreSQL user passwords
# Regenerate SSL certificates
```

---

## Resources

- [PostgreSQL Official Security](https://www.postgresql.org/support/security/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [OWASP Top 10](https://owasp.org/Top10/)
- [Trivy Vulnerability Scanner](https://github.com/aquasecurity/trivy)
- [Docker Security Best Practices](https://docs.docker.com/develop/dev-best-practices/)

---

## Questions?

Reach out to the security team or review the ARCHITECTURE.md for design rationale.

