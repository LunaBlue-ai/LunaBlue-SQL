# Docker & Docker Compose Setup Guide

## Overview

This document provides comprehensive guidance on building and running the LunaBlue-SQL PostgreSQL database in Docker containers.

---

## Table of Contents

1. [Docker Image Strategy](#1-docker-image-strategy)
2. [Dockerfile Design](#2-dockerfile-design)
3. [Docker Compose Orchestration](#3-docker-compose-orchestration)
4. [Environment Configuration](#4-environment-configuration)
5. [Volume Management](#5-volume-management)
6. [Network Configuration](#6-network-configuration)
7. [Build & Run Procedures](#7-build--run-procedures)
8. [Health Checks](#8-health-checks)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Docker Image Strategy

### 1.1 Multi-Stage Build Approach

**Design Decision**: Use multi-stage Dockerfile to keep image size minimal.

```dockerfile
# Stage 1: Builder (includes pgvector compilation)
FROM postgres:16-bookworm AS builder
  # Install build tools for pgvector
  # Compile pgvector extension
  # 500MB+ of dependencies

# Stage 2: Runtime (only compiled binaries)
FROM postgres:16-bookworm
  # Copy compiled pgvector from builder
  # Copy initialization scripts
  # Total size: ~200MB
```

### 1.2 Perspective Analysis

| Perspective | Rationale | Implementation |
|---|---|---|
| **Maintainability** | Smaller images are easier to distribute and update | Multi-stage build removes build dependencies |
| **Testability** | Reproducible builds ensure consistent test environments | Pin PostgreSQL version (16-bookworm) |
| **Architecture** | Separation of concerns (build vs. runtime) | Builder and runtime stages |
| **Security** | Fewer dependencies = smaller attack surface | Multi-stage removes gcc, make, etc. from final image |
| **Business Value** | Faster deployments, less bandwidth | Smaller image size |
| **Documentation** | Clear build process | Inline Dockerfile comments |

---

## 2. Dockerfile Design

### 2.1 Complete Dockerfile Structure

```dockerfile
# ============================================================================
# LunaBlue-SQL PostgreSQL 16 with pgvector
# ============================================================================
# Multi-stage build for minimal image size
# Final image: ~200MB (includes compiled pgvector extension)
# ============================================================================

# ============================================================================
# STAGE 1: BUILDER
# Purpose: Compile pgvector extension with all build dependencies
# This stage is NOT included in final image (saves 300MB+)
# ============================================================================

FROM postgres:16-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-16 \
    git \
    && rm -rf /var/lib/apt/lists/*

# Clone and compile pgvector
WORKDIR /tmp
RUN git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git && \
    cd pgvector && \
    make && \
    make install

# ============================================================================
# STAGE 2: RUNTIME
# Purpose: PostgreSQL 16 with compiled pgvector extension
# This is the final image used in production
# ============================================================================

FROM postgres:16-bookworm

# Copy compiled pgvector from builder stage
COPY --from=builder /usr/lib/postgresql/16/lib/vector.so \
    /usr/lib/postgresql/16/lib/
COPY --from=builder /usr/share/postgresql/16/extension/vector* \
    /usr/share/postgresql/16/extension/

# Health check: Verify PostgreSQL is accepting connections
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=30s \
    CMD pg_isready -U postgres -d postgres || exit 1

# Initialization directory for SQL scripts
# PostgreSQL runs everything in /docker-entrypoint-initdb.d/ on first start
COPY init-pgvector.sql /docker-entrypoint-initdb.d/01_init-pgvector.sql
COPY init_all.sql /docker-entrypoint-initdb.d/02_init_all.sql
COPY audit.sql /docker-entrypoint-initdb.d/03_audit.sql
COPY pii.sql /docker-entrypoint-initdb.d/04_pii.sql
COPY rag.sql /docker-entrypoint-initdb.d/05_rag.sql

# Set environment for PostgreSQL initialization
ENV POSTGRES_DB=postgres \
    POSTGRES_USER=postgres

# Expose PostgreSQL port (not to internet, only for docker-compose networks)
EXPOSE 5432

# Default command (inherited from postgres:16-bookworm base image)
# CMD ["postgres"]
```

### 2.2 Key Design Decisions

| Element | Decision | Rationale |
|---------|----------|-----------|
| **Base Image** | `postgres:16-bookworm` | Stable, well-maintained, includes necessary libraries |
| **pgvector Version** | v0.5.1 (pinned) | Reproducibility, known stable version |
| **Multi-stage** | Builder + Runtime | Security (removes build tools), size efficiency |
| **Initialization Scripts** | Numbered files in `/docker-entrypoint-initdb.d/` | PostgreSQL convention, runs on first start |
| **Health Check** | pg_isready command | Orchestration support, fast startup detection |
| **Exposed Port** | 5432 (internal only) | Standard PostgreSQL port, not exposed to host by default |

---

## 3. Docker Compose Orchestration

### 3.1 Docker Compose File Strategy

**Purpose**: Define complete PostgreSQL service with persistent storage and network configuration.

### 3.2 Complete docker-compose.yml

```yaml
# ============================================================================
# LunaBlue-SQL Docker Compose Configuration
# ============================================================================
# Services:
#   - postgres: PostgreSQL 16 with pgvector
# Volumes:
#   - postgres_data: Persistent database storage
#   - backups: Backup directory
# Networks:
#   - lunablue: Internal network for services
#
# Usage:
#   docker-compose up -d           # Start services
#   docker-compose down            # Stop services
#   docker-compose logs postgres   # View logs
# ============================================================================

version: '3.9'

services:
  postgres:
    # Image reference: local build or registry
    build:
      context: .
      dockerfile: Dockerfile
    
    # Service name in network
    container_name: lunablue-postgres
    
    # PostgreSQL configuration
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}  # Override with env variable
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --locale=en_US.UTF-8"
    
    # Port mapping: host:container (internal network only)
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
    
    # Persistent storage
    volumes:
      # Main data directory
      - postgres_data:/var/lib/postgresql/data
      
      # Backup directory (mounted from host)
      - ./backups:/backups
      
      # Custom postgresql.conf (optional)
      - ./postgresql.conf:/etc/postgresql/postgresql.conf:ro
      
      # Custom pg_hba.conf (optional)
      - ./pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      
      # Initialization scripts (override with local versions if needed)
      # - ./init_all.sql:/docker-entrypoint-initdb.d/02_init_all.sql:ro
    
    # Network connectivity
    networks:
      - lunablue
    
    # Resource limits
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
    
    # Restart policy
    restart: unless-stopped
    
    # Health check
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    
    # Logging configuration
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "10"

# Named volumes
volumes:
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ./data

# Named networks
networks:
  lunablue:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: br-lunablue
    ipam:
      config:
        - subnet: 172.25.0.0/16
```

### 3.3 Compose Design Decisions

| Element | Choice | Rationale | Perspective |
|---------|--------|-----------|------------|
| **Version** | 3.9 | Latest stable, supports all features | Maintainability |
| **Build Strategy** | Local Dockerfile | Control over image, version pinning | Security, Maintainability |
| **Volume Mounts** | Named + bind | Persistent data + backups | Business Value |
| **Networks** | Custom bridge | Service isolation, predictable IPs | Security, Architecture |
| **Resource Limits** | 2 CPU / 4GB max | Prevent runaway container | Testability, Architecture |
| **Restart Policy** | unless-stopped | Auto-recovery without infinite loops | Business Value |
| **Health Checks** | pg_isready | Orchestration awareness | Testability |
| **Logging** | JSON files with rotation | Prevent disk fill-up | Operations |

---

## 4. Environment Configuration

### 4.1 Environment Variables

Create `.env` file for compose settings:

```bash
# .env - Database Configuration
# Source this file: docker-compose config

# PostgreSQL Settings
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=changeme_securely_in_production
POSTGRES_PORT=5432

# Application Settings (referenced in compose)
POSTGRES_HOST=postgres
POSTGRES_POOL_SIZE=20

# Backup Settings
BACKUP_SCHEDULE="0 2 * * *"  # Daily at 2 AM
BACKUP_RETENTION_DAYS=30

# Logging
LOG_LEVEL=INFO
```

### 4.2 Configuration Files (Optional Overrides)

**postgresql.conf** - PostgreSQL server configuration:

```ini
# Performance tuning (for 4GB container)
shared_buffers = 1GB
effective_cache_size = 3GB
work_mem = 50MB
maintenance_work_mem = 256MB

# Logging
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'

# Replication / WAL
wal_level = replica
max_wal_senders = 3
wal_keep_size = 1GB

# Extension configuration
shared_preload_libraries = 'vector'
```

**pg_hba.conf** - Host-based authentication:

```
# IPv4 local connections (docker bridge network)
host    postgres    postgres    172.25.0.0/16    md5

# Replication (if configured)
host    replication postgres    172.25.0.0/16    md5

# All other connections (deny by default)
```

---

## 5. Volume Management

### 5.1 Data Volume Strategy

```
lunablue-postgres (container)
├── /var/lib/postgresql/data (mounted as postgres_data volume)
│   ├── base/          (database files)
│   ├── global/        (cluster-wide files)
│   ├── pg_wal/        (transaction logs, for recovery)
│   └── postmaster.pid
├── /backups           (mounted as ./backups from host)
│   ├── lunablue_20260520_0200.dump
│   ├── lunablue_20260521_0200.dump
│   └── lunablue_20260522_0200.dump
└── /var/log/postgresql/ (logs)
```

### 5.2 Backup Strategy

**Daily backup script** (`backup.sh`):

```bash
#!/bin/bash

CONTAINER_NAME="lunablue-postgres"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/lunablue_${TIMESTAMP}.dump"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Create backup
docker exec "$CONTAINER_NAME" \
  pg_dump -U postgres -Fc postgres > "$BACKUP_FILE"

# Compress backup
gzip "$BACKUP_FILE"

# Delete old backups (keep 30 days)
find "$BACKUP_DIR" -name "lunablue_*.dump.gz" -mtime +30 -delete

echo "Backup created: ${BACKUP_FILE}.gz"
```

**Restore backup**:

```bash
#!/bin/bash

CONTAINER_NAME="lunablue-postgres"
BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE"
  exit 1
fi

# Restore backup
docker exec -i "$CONTAINER_NAME" \
  pg_restore -U postgres -Fc -d postgres < "$BACKUP_FILE"

echo "Restored from: $BACKUP_FILE"
```

---

## 6. Network Configuration

### 6.1 Network Topology

```
┌─────────────────────────────────────────┐
│         Host Machine                    │
│  ┌───────────────────────────────────┐  │
│  │  Docker Bridge Network            │  │
│  │  Name: br-lunablue                │  │
│  │  Subnet: 172.25.0.0/16            │  │
│  │                                   │  │
│  │  ┌────────────────────────────┐   │  │
│  │  │  lunablue-postgres         │   │  │
│  │  │  IP: 172.25.0.2            │   │  │
│  │  │  Port: 5432 (internal)     │   │  │
│  │  │  Exposed: :5432 (host)     │   │  │
│  │  └────────────────────────────┘   │  │
│  │                                   │  │
│  └───────────────────────────────────┘  │
│                                         │
│  Connection from host:                  │
│  - localhost:5432                       │
│  - 127.0.0.1:5432                      │
│                                         │
│  Connection from Docker service:        │
│  - postgres:5432 (service name)         │
│  - 172.25.0.2:5432 (IP)                │
└─────────────────────────────────────────┘
```

### 6.2 Connection Examples

**From host machine** (psql client):

```bash
# Using localhost
psql -h localhost -U postgres -d postgres

# Using IP
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres

# Using environment variables
PGHOST=localhost PGUSER=postgres psql
```

**From another Docker container** (same network):

```bash
# Using service name (preferred)
docker exec other-container psql -h postgres -U postgres

# Using IP address
docker exec other-container psql -h 172.25.0.2 -U postgres
```

---

## 7. Build & Run Procedures

### 7.1 Development Workflow

**Step 1: Build Docker image**

```bash
# Navigate to project directory
cd /path/to/LunaBlue-SQL

# Build image with tag
docker build -t lunablue:postgres-16 .

# Verify image built
docker images | grep lunablue
```

**Step 2: Start services**

```bash
# Start PostgreSQL container in background
docker-compose up -d

# Verify container is running
docker-compose ps

# Check logs
docker-compose logs -f postgres
```

**Step 3: Verify initialization**

```bash
# Wait for "database system is ready to accept connections"
docker-compose logs postgres | grep "ready to accept"

# Connect and verify schemas
docker exec -it lunablue-postgres psql -U postgres -c "\dn"

# Should see: audit | pii | rag | public
```

### 7.2 Production Deployment

```bash
# 1. Build with version tag
docker build -t lunablue:postgres-16-v1.0.0 .

# 2. Push to registry (if using Docker Hub, ECR, GCR, etc.)
docker push lunablue:postgres-16-v1.0.0

# 3. Deploy with docker-compose
export POSTGRES_PASSWORD=secure_password_here
docker-compose up -d

# 4. Verify health
docker-compose ps
docker-compose exec postgres pg_isready

# 5. Create first backup
./backup.sh

# 6. Monitor logs
docker-compose logs -f --tail 100
```

### 7.3 Stopping & Cleanup

```bash
# Stop container (preserves data volume)
docker-compose stop

# Stop and remove container (preserves data volume)
docker-compose down

# Stop and remove everything (WARNING: deletes data!)
docker-compose down -v

# Remove image
docker rmi lunablue:postgres-16
```

---

## 8. Health Checks

### 8.1 Healthcheck Configuration

The Dockerfile includes:

```dockerfile
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=30s \
    CMD pg_isready -U postgres -d postgres || exit 1
```

**This means**:
- ✅ Container waits 30 seconds before first health check
- ✅ Every 10 seconds, runs `pg_isready`
- ✅ If check takes > 5 seconds, it times out
- ✅ After 3 consecutive failures, container marked unhealthy

### 8.2 Manual Health Checks

```bash
# Check container health status
docker inspect lunablue-postgres | grep -A 10 "Health"

# Manual PostgreSQL readiness check
docker-compose exec postgres pg_isready -U postgres

# Check database connectivity
docker-compose exec postgres psql -U postgres -c "SELECT 1"

# Check schemas are initialized
docker-compose exec postgres psql -U postgres -c "\dn"
```

### 8.3 Monitoring

```bash
# View resource usage
docker stats lunablue-postgres

# View logs (last 100 lines, follow)
docker-compose logs -f --tail 100 postgres

# View PostgreSQL logs inside container
docker exec lunablue-postgres tail -f /var/log/postgresql/*.log
```

---

## 9. Troubleshooting

### 9.1 Common Issues

| Issue | Symptom | Solution |
|-------|---------|----------|
| Port already in use | `bind: address already in use` | Change `POSTGRES_PORT` in .env or `docker-compose down` other containers |
| Permission denied on backups | Cannot write to `/backups` | `chmod 755 ./backups` or run as appropriate user |
| Container exits immediately | `docker-compose ps` shows "Exited" | Check logs: `docker-compose logs postgres` |
| Slow initialization | Takes > 2 minutes to start | Normal if schemas are large, check disk I/O |
| Cannot connect from host | `psql: error: could not connect` | Verify `POSTGRES_PORT` is correct, check `docker-compose ps` |

### 9.2 Debugging Steps

**If container won't start**:

```bash
# 1. Check container logs
docker-compose logs postgres

# 2. Try manual run with verbose output
docker run -it --rm \
  -e POSTGRES_PASSWORD=test \
  -v ./data:/var/lib/postgresql/data \
  lunablue:postgres-16

# 3. Inspect image
docker inspect lunablue:postgres-16

# 4. Check available disk space
df -h ./data
```

**If initialization scripts fail**:

```bash
# 1. Verify scripts exist in image
docker run -it --rm lunablue:postgres-16 \
  ls -la /docker-entrypoint-initdb.d/

# 2. Manually run scripts
docker exec lunablue-postgres \
  psql -U postgres -f /docker-entrypoint-initdb.d/03_audit.sql

# 3. Check postgresql logs
docker exec lunablue-postgres \
  grep ERROR /var/log/postgresql/*.log
```

### 9.3 Performance Tuning

If experiencing slow queries or high resource usage:

1. **Check resource limits**:
   ```bash
   docker inspect lunablue-postgres | grep -A 10 "Resources"
   ```

2. **Monitor during operation**:
   ```bash
   docker stats lunablue-postgres --no-stream
   ```

3. **Adjust memory if needed**:
   Edit `docker-compose.yml`:
   ```yaml
   deploy:
     resources:
       limits:
         memory: 8G  # Increase from 4G
   ```

4. **Rebuild and restart**:
   ```bash
   docker-compose down
   docker-compose up -d
   ```

---

## Summary: Perspective Evaluation

| Perspective | Implementation | Quality |
|---|---|---|
| **Maintainability** | Clear Dockerfile, documented compose file, example scripts | ✅ High |
| **Testability** | Health checks, volume persistence, reproducible builds | ✅ High |
| **Architecture** | Multi-stage build, service separation, volume management | ✅ High |
| **Security** | No build tools in runtime image, volume constraints | ✅ Moderate (add RBAC, secrets management in future) |
| **Business Value** | Fast deployment, easy backup/restore, scalable | ✅ High |
| **Documentation** | Comprehensive, with examples and troubleshooting | ✅ High |

---

**Last Updated**: May 20, 2026  
**Version**: 1.0  
**Status**: Complete

