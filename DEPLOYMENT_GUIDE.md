# Deployment Guide: LunaBlue-SQL

## Overview

This guide provides step-by-step instructions for deploying LunaBlue-SQL from development through production environments, including infrastructure setup, configuration, validation, and rollback procedures.

---

## Table of Contents

1. [Pre-Deployment Checklist](#1-pre-deployment-checklist)
2. [Environment Preparation](#2-environment-preparation)
3. [Development Deployment](#3-development-deployment)
4. [Staging Deployment](#4-staging-deployment)
5. [Production Deployment](#5-production-deployment)
6. [Post-Deployment Validation](#6-post-deployment-validation)
7. [Rollback Procedures](#7-rollback-procedures)
8. [Continuous Integration/Deployment](#8-cicd-integration)

---

## 1. Pre-Deployment Checklist

### 1.1 Infrastructure Requirements

**Hardware**:
- [ ] CPU: 2+ cores (minimum 1 core per container)
- [ ] Memory: 4 GB minimum (8 GB recommended for production)
- [ ] Disk: 50 GB SSD (faster than HDD for database)
- [ ] Network: Stable internet (for pulling base image)

**Software**:
- [ ] Docker Engine 24.0+
- [ ] Docker Compose 2.0+
- [ ] PostgreSQL client tools (psql, pg_dump)
- [ ] Git (for version control)
- [ ] Bash 4.0+ (for scripts)

**Verification**:

```bash
#!/bin/bash
# verify_requirements.sh

echo "=== Checking Requirements ==="

# Docker
docker --version || { echo "❌ Docker not installed"; exit 1; }

# Docker Compose
docker-compose --version || { echo "❌ Docker Compose not installed"; exit 1; }

# PostgreSQL client
psql --version || { echo "❌ psql not installed"; exit 1; }

# Disk space
REQUIRED_GB=50
AVAILABLE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE" -lt "$REQUIRED_GB" ]; then
  echo "❌ Insufficient disk space: $AVAILABLE GB < $REQUIRED_GB GB required"
  exit 1
fi

echo "✅ All requirements satisfied"
```

### 1.2 Preparation Checklist

- [ ] Clone repository: `git clone <repo-url>`
- [ ] Create `.env` file with credentials
- [ ] Review `docker-compose.yml` for environment
- [ ] Create backup directory: `mkdir -p backups`
- [ ] Test database connection (after deployment)
- [ ] Review all SQL initialization scripts
- [ ] Set up monitoring (if applicable)
- [ ] Document baseline metrics
- [ ] Create deployment runbook (this document)

### 1.3 Access & Credentials

**Required credentials**:
- [ ] PostgreSQL superuser password
- [ ] Application user password
- [ ] Database backup encryption key
- [ ] SSH keys (if deploying to remote server)

**Storage**:
```bash
# Create secure credentials file (not in git)
touch .env
chmod 600 .env
# Store: POSTGRES_PASSWORD, APP_USER_PASSWORD, etc.
```

---

## 2. Environment Preparation

### 2.1 Directory Structure

Create required directories before deployment:

```bash
#!/bin/bash
# setup_directories.sh

PROJECT_ROOT="$(pwd)"

# Create required directories
mkdir -p "${PROJECT_ROOT}/data"          # PostgreSQL data volume
mkdir -p "${PROJECT_ROOT}/backups"       # Backup storage
mkdir -p "${PROJECT_ROOT}/logs"          # Application logs
mkdir -p "${PROJECT_ROOT}/config"        # Configuration files

# Set permissions
chmod 700 "${PROJECT_ROOT}/data"         # PostgreSQL exclusive access
chmod 755 "${PROJECT_ROOT}/backups"
chmod 755 "${PROJECT_ROOT}/logs"
chmod 755 "${PROJECT_ROOT}/config"

# Verify structure
tree -L 2 "${PROJECT_ROOT}" 2>/dev/null || find "${PROJECT_ROOT}" -maxdepth 2 -type d

echo "✅ Directory structure created"
```

### 2.2 Environment Configuration

Create `.env` file:

```bash
# .env - Database Configuration
# DO NOT COMMIT TO GIT!
# Copy: cp .env.example .env

# PostgreSQL Credentials
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=choose_strong_password_here
POSTGRES_PORT=5432
POSTGRES_HOST=postgres

# Application Configuration
APP_USER_NAME=app_user
APP_USER_PASSWORD=app_user_password_here
READONLY_USER_PASSWORD=readonly_password_here

# Container Configuration
CONTAINER_NAME=lunablue-postgres
CONTAINER_RESTART=unless-stopped
CONTAINER_LOG_DRIVER=json-file

# Resource Limits
CONTAINER_CPU_LIMIT=2
CONTAINER_MEMORY_LIMIT=4G
CONTAINER_MEMORY_RESERVATION=2G

# Database Configuration
POSTGRES_LOCALE=en_US.UTF-8
POSTGRES_ENCODING=UTF-8

# Backup Configuration
BACKUP_ENABLED=true
BACKUP_SCHEDULE="0 2 * * *"       # Daily at 2 AM
BACKUP_RETENTION_DAYS=30

# Logging
LOG_LEVEL=INFO
LOG_RETENTION_DAYS=7
```

**Security best practices**:

```bash
# Store passwords securely (not in .env for production)
# Option 1: Docker Secrets (Swarm/Kubernetes)
# Option 2: HashiCorp Vault
# Option 3: AWS Secrets Manager
# Option 4: Azure Key Vault

# For development/testing only:
export POSTGRES_PASSWORD=$(openssl rand -base64 32)
```

### 2.3 Network Setup

**Create custom bridge network** (optional but recommended):

```bash
#!/bin/bash
# setup_network.sh

NETWORK_NAME="lunablue-network"
NETWORK_SUBNET="172.25.0.0/16"

# Create network
docker network create \
  --driver bridge \
  --subnet "$NETWORK_SUBNET" \
  "$NETWORK_NAME"

# Verify
docker network inspect "$NETWORK_NAME"

echo "✅ Network $NETWORK_NAME created"
```

**Update docker-compose.yml**:

```yaml
services:
  postgres:
    networks:
      - lunablue-network

networks:
  lunablue-network:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: br-lunablue
```

---

## 3. Development Deployment

### 3.1 Local Development Setup

**Step 1: Clone and prepare**

```bash
cd ~/Development
git clone https://github.com/your-org/LunaBlue-SQL.git
cd LunaBlue-SQL
./setup_directories.sh
cp .env.example .env
```

**Step 2: Build Docker image**

```bash
# Build with development tag
docker build \
  --tag lunablue:postgres-16-dev \
  --target runtime \
  .

# Verify build
docker images | grep lunablue
```

**Step 3: Start containers**

```bash
# Start in foreground to see logs
docker-compose up

# Or start in background
docker-compose up -d

# Check status
docker-compose ps
```

**Step 4: Verify initialization**

```bash
# Wait for healthy status
while ! docker exec lunablue-postgres pg_isready -U postgres > /dev/null; do
  echo "Waiting for PostgreSQL..."
  sleep 2
done

# Verify schemas
docker exec lunablue-postgres psql -U postgres -c "\dn"
# Expected: audit, pii, rag schemas

# Test connection
docker exec lunablue-postgres psql -U postgres -c "SELECT 1"
```

**Step 5: Import test data** (optional)

```bash
# Run test data script
docker exec lunablue-postgres psql -U postgres -f /docker-entrypoint-initdb.d/test-data.sql

# Verify data inserted
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT 'audit' as schema, COUNT(*) as rows FROM audit.system_log
   UNION ALL
   SELECT 'rag', COUNT(*) FROM rag.documents"
```

### 3.2 Development Workflow

**Running tests**:

```bash
# Copy test scripts into container
docker cp tests/ lunablue-postgres:/tmp/

# Run test suite
docker exec lunablue-postgres bash /tmp/tests/test_runner.sh

# Expected: All tests pass
```

**Making schema changes**:

```bash
# 1. Edit SQL file locally
vim audit.sql

# 2. Rebuild image
docker-compose down
docker build -t lunablue:postgres-16-dev .
docker-compose up -d

# 3. Verify changes
docker exec lunablue-postgres psql -U postgres -c "\d audit.*"
```

---

## 4. Staging Deployment

### 4.1 Staging Environment Setup

**Purpose**: Production-like environment for final validation before production release.

**Infrastructure**:
```bash
# Staging server requirements
- Separate host from development
- Same Docker/Docker Compose versions as production
- Realistic data volume (1-10% of production)
- Network isolation (separate VLAN/subnet)
```

### 4.2 Staging Deployment Steps

**Step 1: Prepare staging host**

```bash
#!/bin/bash
# deploy_staging.sh

STAGING_HOST="staging.internal.example.com"
STAGING_USER="deploy"
STAGING_PATH="/opt/lunablue-sql"

# SSH into staging
ssh "$STAGING_USER@$STAGING_HOST" << 'EOF'

# Create deployment directory
sudo mkdir -p "$STAGING_PATH"
sudo chown "$STAGING_USER:$STAGING_USER" "$STAGING_PATH"
cd "$STAGING_PATH"

# Clone repository
git clone https://github.com/your-org/LunaBlue-SQL.git .

# Setup environment
./setup_directories.sh

# Create .env with staging credentials
cat > .env << 'ENVFILE'
POSTGRES_PASSWORD=staging_password_here
POSTGRES_PORT=5432
# ... other staging-specific vars
ENVFILE

chmod 600 .env

EOF

echo "✅ Staging environment prepared"
```

**Step 2: Build and deploy**

```bash
# On staging host
cd /opt/lunablue-sql

# Build production-tagged image
docker build -t lunablue:postgres-16-staging .

# Start services
docker-compose -f docker-compose.yml \
  -f docker-compose.staging.yml up -d

# Verify
docker-compose ps
```

**Step 3: Validation tests**

```bash
# Run comprehensive tests
./test_runner.sh --verbose

# Load test data
docker-compose exec postgres psql -U postgres -f test-data.sql

# Performance baseline
docker-compose exec postgres psql -U postgres << EOF
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
FROM pg_tables WHERE schemaname IN ('audit', 'pii', 'rag');
EOF
```

### 4.3 Staging Sign-Off

Before production promotion:

- [ ] All tests pass
- [ ] Load tests complete successfully
- [ ] Backup/restore validated
- [ ] Failover procedures tested
- [ ] Security scan passed
- [ ] Documentation reviewed and updated
- [ ] Performance baseline established

---

## 5. Production Deployment

### 5.1 Production Release Strategy

**Approach**: Blue-green deployment with rolling restart.

```
┌─────────────────────────────────────────────┐
│         Production Environment              │
├─────────────────────────────────────────────┤
│                                             │
│  Blue (Current)      Green (New)            │
│  Container v1.0.0    Container v1.1.0      │
│  ✓ Active            (Standby)              │
│                                             │
│  Switch traffic after validation            │
│                                             │
└─────────────────────────────────────────────┘
```

### 5.2 Production Deployment Procedure

**Pre-deployment**:

```bash
#!/bin/bash
# pre_deploy_checklist.sh

echo "=== Pre-Deployment Checklist ==="

# 1. Backup current state
echo "Creating pre-deployment backup..."
docker-compose exec postgres pg_dump -U postgres -Fc postgres \
  > backups/pre_deploy_$(date +%Y%m%d_%H%M%S).dump

# 2. Document current version
echo "Current image: $(docker images lunablue:* --format 'table {{.Repository}}:{{.Tag}}')"

# 3. Verify staging success
echo "Verify staging tests passed at: [staging URL]"
read -p "Confirm staging tests passed (y/n): " confirm
[ "$confirm" = "y" ] || exit 1

# 4. Drain connections
echo "Draining active connections..."
# (Implement graceful shutdown logic)

# 5. Verify backup integrity
echo "Verifying backup..."
docker-compose exec postgres pg_restore -l backups/pre_deploy_*.dump | head -5
echo "✅ All pre-checks passed"
```

**Deployment**:

```bash
#!/bin/bash
# deploy_production.sh

PROD_VERSION="1.1.0"
PROD_IMAGE="lunablue:postgres-16-v${PROD_VERSION}"

echo "=== Deploying Production Version ${PROD_VERSION} ==="

# 1. Build production image
docker build \
  -t "${PROD_IMAGE}" \
  -t lunablue:postgres-16-latest \
  .

# 2. Tag for registry (if applicable)
docker tag "${PROD_IMAGE}" \
  "registry.example.com/database/${PROD_IMAGE}"

# 3. Push to registry
docker push "registry.example.com/database/${PROD_IMAGE}"

# 4. Update docker-compose.yml to new image
sed -i "s/image:.*/image: ${PROD_IMAGE}/" docker-compose.yml

# 5. Restart with new image (rolling restart)
docker-compose pull
docker-compose up -d

# 6. Monitor restart
echo "Waiting for container to be healthy..."
while ! docker exec lunablue-postgres pg_isready -U postgres > /dev/null; do
  sleep 2
done

# 7. Verify new version
docker exec lunablue-postgres postgres --version

# 8. Run smoke tests
./test_runner.sh --step all

echo "✅ Production deployment complete"
```

**Post-deployment**:

```bash
#!/bin/bash
# post_deploy_validation.sh

echo "=== Post-Deployment Validation ==="

# 1. Data integrity check
docker-compose exec postgres psql -U postgres << EOF
-- Verify audit logs not corrupted
SELECT COUNT(*) as total_events FROM audit.system_log;

-- Verify rag documents accessible  
SELECT COUNT(*) as total_docs FROM rag.documents;

-- Check for errors in recent logs
SELECT COUNT(*) as recent_errors FROM audit.system_log
WHERE severity_level = 'ERROR'
AND created_at > NOW() - INTERVAL '10 minutes';
EOF

# 2. Performance metrics
docker stats lunablue-postgres --no-stream

# 3. Backup validation
./backup_daily.sh

# 4. Monitoring alert check
# Verify no alerts triggered by deployment

# 5. Notification
echo "✅ Production deployment validated - notify stakeholders"
```

---

## 6. Post-Deployment Validation

### 6.1 Immediate Validation (First Hour)

```bash
#!/bin/bash
# immediate_validation.sh

echo "=== Immediate Post-Deployment Validation ==="
echo "Time: $(date)"

# Health check
echo "1. Container health:"
docker-compose ps

# Connection test
echo "2. Database connectivity:"
docker exec lunablue-postgres pg_isready -U postgres

# Schema verification
echo "3. Schema verification:"
docker exec lunablue-postgres psql -U postgres -c "\dn"

# Data consistency
echo "4. Data consistency check:"
docker exec lunablue-postgres psql -U postgres << EOF
SELECT 'audit.system_log' as table_name, COUNT(*) as rows FROM audit.system_log
UNION ALL
SELECT 'rag.documents', COUNT(*) FROM rag.documents
UNION ALL
SELECT 'pii.pii_categories', COUNT(*) FROM pii.pii_categories;
EOF

# Recent errors
echo "5. Recent errors in audit log:"
docker exec lunablue-postgres psql -U postgres -c \
  "SELECT COUNT(*) FROM audit.system_log WHERE severity_level = 'ERROR' AND created_at > NOW() - INTERVAL '1 hour'"

# Performance baseline
echo "6. Performance metrics:"
docker stats lunablue-postgres --no-stream | tail -1

echo "✅ Immediate validation complete"
```

### 6.2 Scheduled Validations

**Daily (first week)**:
- [ ] Health check script runs successfully
- [ ] No error spikes in audit logs
- [ ] Backup completes successfully
- [ ] Query performance within baseline

**Weekly (first month)**:
- [ ] Full test suite passes
- [ ] Backup restore tested
- [ ] Security scans clean
- [ ] Capacity monitoring normal

---

## 7. Rollback Procedures

### 7.1 Quick Rollback (If Critical Issue)

```bash
#!/bin/bash
# rollback_immediate.sh

echo "!!! INITIATING EMERGENCY ROLLBACK !!!"

# 1. Stop current deployment
docker-compose stop

# 2. Restore from backup
BACKUP_FILE="backups/pre_deploy_*.dump"
LATEST_BACKUP=$(ls -1t $BACKUP_FILE | head -1)

docker-compose down
rm -rf ./data/*
docker-compose up -d

echo "Restoring from $LATEST_BACKUP..."
docker exec -i lunablue-postgres pg_restore -U postgres -Fc -d postgres < "$LATEST_BACKUP"

# 3. Verify restoration
docker exec lunablue-postgres pg_isready -U postgres

# 4. Verify data
docker exec lunablue-postgres psql -U postgres -c "SELECT COUNT(*) FROM audit.system_log"

echo "✅ Rollback complete - verify data integrity and notify team"
```

### 7.2 Gradual Rollback (Controlled)

**If issue not critical but version revert needed**:

```bash
#!/bin/bash
# rollback_version.sh

PREVIOUS_VERSION="1.0.0"
CURRENT_VERSION="1.1.0"

echo "Rolling back from v${CURRENT_VERSION} to v${PREVIOUS_VERSION}"

# 1. Create backup of new version data (for analysis)
docker-compose exec postgres pg_dump -U postgres -Fc postgres \
  > backups/rollback_from_v${CURRENT_VERSION}_$(date +%s).dump

# 2. Verify previous backup
PREV_BACKUP="backups/pre_deploy_*.dump"
LATEST=$(ls -1t $PREV_BACKUP | head -1)
echo "Using backup: $LATEST"

# 3. Switch image
docker-compose down
docker rmi lunablue:postgres-16-v${CURRENT_VERSION}
sed -i "s/postgres-16-v${CURRENT_VERSION}/postgres-16-v${PREVIOUS_VERSION}/" docker-compose.yml

# 4. Restore and restart
docker-compose up -d
sleep 10

# 5. Verify
docker exec lunablue-postgres pg_isready -U postgres

# 6. Run tests
./test_runner.sh --verbose

echo "✅ Rollback to v${PREVIOUS_VERSION} complete"
```

---

## 8. CI/CD Integration

### 8.1 GitHub Actions Pipeline

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy LunaBlue-SQL

on:
  push:
    branches: [main, staging]
  workflow_dispatch:

env:
  REGISTRY: docker.io
  IMAGE_NAME: lunablue

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
      
      - name: Login to Docker Registry
        uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:postgres-16-${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:postgres-16-latest
  
  test:
    runs-on: ubuntu-latest
    needs: build
    services:
      postgres:
        image: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:postgres-16-${{ github.sha }}
        env:
          POSTGRES_PASSWORD: test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Run tests
        run: |
          apt-get update && apt-get install -y postgresql-client
          psql -h postgres -U postgres -c "SELECT 1"
          # Run test suite
          ./test_runner.sh --verbose
  
  deploy-staging:
    if: github.ref == 'refs/heads/staging'
    runs-on: ubuntu-latest
    needs: test
    steps:
      - name: Deploy to staging
        run: |
          # SSH into staging and deploy
          ssh deploy@staging.example.com << 'EOF'
          cd /opt/lunablue-sql
          docker-compose pull
          docker-compose up -d
          ./test_runner.sh
          EOF
  
  deploy-production:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    needs: test
    environment: production
    steps:
      - name: Deploy to production
        run: |
          # Require manual approval before production deployment
          echo "Requires manual approval in GitHub Actions"
```

### 8.2 GitLab CI Pipeline

Create `.gitlab-ci.yml`:

```yaml
stages:
  - build
  - test
  - deploy-staging
  - deploy-production

variables:
  DOCKER_IMAGE: $CI_REGISTRY_IMAGE:postgres-16-$CI_COMMIT_SHA

build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t $DOCKER_IMAGE .
    - docker push $DOCKER_IMAGE

test:
  stage: test
  image: $DOCKER_IMAGE
  services:
    - postgres:16
  script:
    - apt-get update && apt-get install -y postgresql-client
    - ./test_runner.sh --verbose

deploy_staging:
  stage: deploy-staging
  image: alpine:latest
  only:
    - staging
  script:
    - apk add --no-cache openssh-client
    - ssh-keyscan staging.example.com >> ~/.ssh/known_hosts
    - ssh deploy@staging.example.com "cd /opt/lunablue-sql && docker-compose pull && docker-compose up -d"

deploy_production:
  stage: deploy-production
  image: alpine:latest
  only:
    - main
  when: manual
  script:
    - apk add --no-cache openssh-client
    - ssh-keyscan prod.example.com >> ~/.ssh/known_hosts
    - ssh deploy@prod.example.com "cd /opt/lunablue-sql && docker-compose pull && docker-compose up -d"
```

---

## Quick Reference: Deployment Commands

```bash
# Build
docker build -t lunablue:postgres-16 .

# Deploy
docker-compose up -d

# Health check
docker-compose exec postgres pg_isready -U postgres

# Backup
docker-compose exec postgres pg_dump -U postgres -Fc postgres > backup.dump

# Restore
docker-compose exec -i postgres pg_restore -U postgres -Fc -d postgres < backup.dump

# Logs
docker-compose logs -f postgres

# Scale (if using Docker Swarm)
docker service scale postgres=1

# Rollback
docker-compose down
# Restore from backup
# docker-compose up -d
```

---

**Last Updated**: May 20, 2026  
**Version**: 1.0  
**Status**: Complete

