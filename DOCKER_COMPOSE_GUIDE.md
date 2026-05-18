# Docker Compose Guide - PostgreSQL 16 + pgvector

Comprehensive guide for using `docker-compose.yml` to orchestrate PostgreSQL 16 with pgvector, featuring persistent encrypted volumes, environment configuration, and health monitoring.

---

## Quick Start

### 1. Setup Configuration
```bash
# Copy example environment file
cp .env.example .env

# Edit with your settings (especially POSTGRES_PASSWORD!)
nano .env  # Change POSTGRES_PASSWORD from default
```

### 2. Start Services
```bash
# Start PostgreSQL in background
docker-compose up -d

# Wait for health check to pass
sleep 10

# Verify it's running
docker-compose ps
# Expected: postgres-pgvector   Up   (healthy)
```

### 3. Connect & Test
```bash
# Connect with psql
psql -h localhost -U postgres -d postgres
# Password: (enter POSTGRES_PASSWORD from .env)

# From inside docker-compose
docker-compose exec postgres psql -U postgres -d postgres -c "SELECT 1;"

# Test pgvector
docker-compose exec postgres psql -U postgres -d postgres -c \
  "CREATE TABLE test_vectors (id SERIAL, embedding vector(3)); \
   INSERT INTO test_vectors VALUES (1, '[1,2,3]'::vector); \
   SELECT * FROM test_vectors;"
```

### 4. Stop & Cleanup
```bash
# Stop services (volumes persist)
docker-compose stop

# Resume services
docker-compose start

# Stop and remove containers (volumes persist)
docker-compose down

# Remove everything including volumes (WARNING: data loss!)
docker-compose down -v
```

---

## Configuration Management

### Development Setup
```bash
# Create local development config
cp .env.example .env

# Set strong password
echo "POSTGRES_PASSWORD=$(openssl rand -base64 32)" >> .env

# Start for development
docker-compose up -d
```

### Testing Setup
```bash
# Create test configuration
cp .env.example .env.test

# Minimal resources for CI pipeline
cat >> .env.test << 'EOF'
POSTGRES_PASSWORD=test_password_change_me
POSTGRES_DB=test_db
POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector -c max_connections=20
EOF

# Run tests
docker-compose --env-file .env.test up -d
docker-compose --env-file .env.test exec postgres psql -U postgres -d test_db -c "SELECT 1;"
docker-compose --env-file .env.test down -v
```

### Production Setup (Docker)
```bash
# Create production configuration
cp .env.example .env.prod

# Use strong password from secrets management
echo "POSTGRES_PASSWORD=$(vault read -field=password secret/postgres)" >> .env.prod

# Optimize for production workload
cat >> .env.prod << 'EOF'
POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector \
  -c max_connections=200 \
  -c shared_buffers=4GB \
  -c work_mem=256MB \
  -c effective_cache_size=12GB
EOF

# Start with production config
docker-compose --env-file .env.prod up -d

# Verify health
docker-compose ps
```

### Production Setup (Kubernetes)
For Kubernetes deployments, see [USAGE.md](USAGE.md#kubernetes-deployment) in the main documentation.

---

## Volume Management

### View Volumes
```bash
# List all volumes
docker volume ls | grep postgres

# Inspect volume details
docker volume inspect postgres_data

# Check volume location and usage
docker volume inspect postgres_data | jq '.[] | {Mountpoint, Labels}'
```

### Backup Database
```bash
# Create backup before major changes
docker-compose exec postgres pg_dumpall -U postgres | \
  gzip > backup-$(date +%Y%m%d-%H%M%S).sql.gz

# With compression (recommended for large databases)
docker-compose exec postgres pg_dump -U postgres -Fc postgres > \
  backup-$(date +%Y%m%d-%H%M%S).dump

# Backup via volume mount (while running)
docker run --rm \
  -v postgres_data:/data \
  -v ${PWD}:/backup \
  postgres:16 \
  tar -czf /backup/postgres-backup-$(date +%Y%m%d).tar.gz -C /data .
```

### Restore Database
```bash
# Restore from SQL dump
gunzip < backup-20240517-120000.sql.gz | \
  docker-compose exec -T postgres psql -U postgres

# Restore from Fc format
docker-compose exec postgres pg_restore -U postgres -d postgres \
  backup-20240517-120000.dump

# Restore from volume backup
docker volume create postgres_data_restored
docker run --rm \
  -v postgres_data_restored:/data \
  -v ${PWD}:/backup \
  postgres:16 \
  tar -xzf /backup/postgres-backup-20240517.tar.gz -C /data
```

### Migrate Data Between Instances
```bash
# Export from old instance
docker-compose exec postgres pg_dumpall -U postgres | \
  gzip > migration.sql.gz

# Stop old instance
docker-compose down

# Create new volume (old one still exists as backup)
docker volume create postgres_data_new

# Start with new volume
export POSTGRES_VOLUME=postgres_data_new
docker-compose up -d

# Import data
gunzip < migration.sql.gz | \
  docker-compose exec -T postgres psql -U postgres

# Verify data
docker-compose exec postgres psql -U postgres -d postgres -c \
  "SELECT datname FROM pg_database WHERE datistemplate = false;"
```

---

## Health Checks & Monitoring

### View Health Status
```bash
# Show all services and health
docker-compose ps

# Detailed health status
docker inspect postgres-pgvector | jq '.[] | .State.Health'

# Expected output when healthy:
# {
#   "Status": "healthy",
#   "FailingStreak": 0,
#   "Log": [...]
# }
```

### Monitor Logs
```bash
# View recent logs
docker logs postgres-pgvector

# Follow logs (tail -f style)
docker logs -f postgres-pgvector

# Filter for errors
docker logs postgres-pgvector | grep ERROR

# View last 100 lines
docker logs --tail 100 postgres-pgvector

# View since specific time
docker logs --since 2024-05-17T12:00:00 postgres-pgvector
```

### Monitor Resources
```bash
# Real-time resource usage
docker stats postgres-pgvector

# Expected for healthy instance:
# Memory: 100-300 MB (varies with workload)
# CPU: <5% at idle

# Check if hitting memory limit
docker stats postgres-pgvector --no-stream | grep -E "Limit|MEM"

# If near limit (e.g., 1.8GB of 2GB limit):
#   1. Increase memory limit in docker-compose.yml
#   2. Optimize PostgreSQL memory settings (work_mem, shared_buffers)
#   3. Add connection pooling (PgBouncer)
```

### Health Check Failures
```bash
# If health check failing:
docker-compose ps
# Status: Unhealthy or "Exited"

# Check logs
docker logs postgres-pgvector | tail -50

# Manually test connectivity
docker-compose exec postgres pg_isready -U postgres -d postgres

# Force restart
docker-compose restart postgres

# If still failing, check:
# 1. Password is correct (POSTGRES_PASSWORD in .env)
# 2. Port is not conflicting (5432 already in use)
# 3. Sufficient memory/CPU available
# 4. Volume permissions are correct (chmod 700)
```

---

## Performance Tuning

### Monitor Database Performance
```bash
# Connect to database
docker-compose exec postgres psql -U postgres -d postgres

# Inside psql:
# Show all databases
\l

# Show all tables
\dt

# Check table sizes
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) 
FROM pg_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

# Check index usage
SELECT schemaname, tablename, indexname, pg_size_pretty(pg_relation_size(indexrelname::regclass))
FROM pg_indexes ORDER BY pg_relation_size(indexrelname::regclass) DESC;

# Check connections
SELECT datname, usename, count(*) FROM pg_stat_activity GROUP BY datname, usename;

# Exit psql
\q
```

### Adjust PostgreSQL Settings
```bash
# Update POSTGRES_INITDB_ARGS in .env with more memory
# For 8GB server:
POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector \
  -c max_connections=150 \
  -c shared_buffers=2GB \
  -c work_mem=128MB \
  -c effective_cache_size=6GB

# Stop, remove volumes (careful!), and restart
docker-compose down -v
docker-compose up -d

# Note: This creates fresh database (data loss!)
# For existing data: Use SQL ALTER SYSTEM or postgresql.conf mount
```

### Create Indexes for Vector Search
```bash
# Connect to database
docker-compose exec postgres psql -U postgres -d postgres

# Create HNSW index for vector similarity
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops) \
  WITH (m = 16, ef_construction = 64);

# Or IVFFLAT index (faster to build, slower to search)
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops) \
  WITH (lists = 100);

# Check index size
SELECT indexname, pg_size_pretty(pg_relation_size(indexrelname::regclass))
FROM pg_indexes WHERE tablename = 'documents';
```

---

## Networking

### Local Access
```bash
# From host machine
psql -h localhost -U postgres -d postgres

# From Docker network
docker-compose exec postgres psql -U postgres -d postgres

# From another container on same network
docker run --network postgres_default postgres:16 \
  psql -h postgres-pgvector -U postgres -d postgres
```

### Add Application Container
```yaml
# In docker-compose.yml, add application service:

services:
  postgres:
    # ... existing postgres config

  app:
    image: my-app:latest
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
    ports:
      - "127.0.0.1:8000:8000"
```

### Override Network
```bash
# Create custom network
docker network create postgres-network

# Use custom network in docker-compose.yml
# Add to docker-compose.yml:
# networks:
#   postgres-network:
#     external: true

# Then use:
docker-compose --file docker-compose.yml -f docker-compose.custom-net.yml up -d
```

---

## Troubleshooting

### Container Won't Start
```bash
# Check error messages
docker logs postgres-pgvector

# Common errors:
# 1. "bind: address already in use"
#    → Port 5432 already in use
#    Solution: docker-compose down (other service)
#             Or change port: 127.0.0.1:5433:5432

# 2. "POSTGRES_PASSWORD env variable is not set"
#    → .env file not found or not loaded
#    Solution: Create .env from .env.example
#             Verify env_file path in docker-compose.yml

# 3. "permission denied" on /var/lib/postgresql/data
#    → Volume ownership/permissions issue
#    Solution: docker-compose down -v
#             Recreate volume (fresh start)
```

### Health Check Failing
```bash
# If postgres-pgvector status shows "Unhealthy"

# Test manually
docker-compose exec postgres pg_isready -U postgres -d postgres

# Check PostgreSQL process
docker-compose top postgres

# Check logs
docker logs postgres-pgvector | tail -20

# Force restart
docker-compose restart postgres
```

### Slow Queries
```bash
# Enable query logging
docker-compose exec postgres psql -U postgres -d postgres << 'EOF'
ALTER SYSTEM SET log_statement = 'all';
ALTER SYSTEM SET log_duration = on;
SELECT pg_reload_conf();
EOF

# Then check logs
docker logs -f postgres-pgvector | grep duration

# Analyze slow query
EXPLAIN ANALYZE SELECT * FROM documents 
  ORDER BY embedding <-> '[0.1, 0.2, ..., 0.768]'::vector LIMIT 10;
```

### Out of Memory
```bash
# Check current usage
docker stats postgres-pgvector --no-stream

# If near limit:
# 1. Increase memory limit in docker-compose.yml
#    deploy.resources.limits.memory: 4g
#    deploy.resources.reservations.memory: 2g

# 2. Reduce work_mem in .env
#    POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector -c work_mem=16MB

# 3. Reduce max_connections
#    POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector -c max_connections=50

# 4. Restart services
docker-compose down
docker-compose up -d
```

---

## Environment Variables Reference

| Variable | Default | Purpose |
|----------|---------|---------|
| `POSTGRES_USER` | postgres | Database superuser |
| `POSTGRES_PASSWORD` | (required) | Superuser password |
| `POSTGRES_DB` | postgres | Default database |
| `POSTGRES_INITDB_ARGS` | -c shared_preload_libraries=vector | Init parameters |

---

## File Reference

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Service orchestration definition |
| `.env.example` | Environment template (copy to .env) |
| `.env` | Local configuration (NOT in git) |
| `DOCKER_COMPOSE_PLAN.md` | Implementation plan |
| `Dockerfile` | PostgreSQL + pgvector image definition |

---

## Next Steps

- Read [SECURITY.md](SECURITY.md) for security hardening
- See [USAGE.md](USAGE.md) for deployment examples
- Check [Dockerfile](Dockerfile) for image details
- Review [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions

