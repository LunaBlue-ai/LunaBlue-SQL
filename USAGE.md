# PostgreSQL 16 + pgvector - Usage Guide

This guide provides copy-paste-ready examples for common deployment scenarios: development, testing, and production.

---

## Build the Image

### Build Locally
```bash
cd /path/to/postgres/dockerfile
docker build -t postgres-pgvector:16 -f Dockerfile .

# Verify build
docker images | grep postgres-pgvector
# Output: postgres-pgvector  16   <image_id>  <size>
```

### Build for Multiple Architectures
```bash
# Build for both amd64 and arm64 (e.g., for Mac M1/M2)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t postgres-pgvector:16 \
  -f Dockerfile \
  .
```

---

## Usage Pattern 1: Local Development

### Quick Start (No Persistence)
```bash
# Start PostgreSQL with pgvector - data lost on container stop
docker run -d \
  --name postgres-dev \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -p 127.0.0.1:5432:5432 \
  postgres-pgvector:16

# Wait for startup
sleep 5

# Verify health
docker inspect postgres-dev | jq '.[] | select(.State.Health.Status)'
# Output: "healthy"
```

### With Data Persistence
```bash
# Create named volume for data
docker volume create postgres-dev-data

# Start container with persistent storage
docker run -d \
  --name postgres-dev \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -p 127.0.0.1:5432:5432 \
  -v postgres-dev-data:/var/lib/postgresql/data \
  postgres-pgvector:16

# Data survives container restart
docker stop postgres-dev
docker start postgres-dev  # Data is still there
```

### Connect from Application
```bash
# From Python
import psycopg2
conn = psycopg2.connect(
    host="localhost",
    port=5432,
    user="postgres",
    password="postgres",
    database="postgres"
)

# From Node.js
const pg = require('pg');
const client = new pg.Client({
    host: 'localhost',
    port: 5432,
    user: 'postgres',
    password: 'postgres',
    database: 'postgres'
});

# From psql CLI
psql -h localhost -U postgres -d postgres
# Password: postgres
```

### Create Test Tables
```bash
# Create test tables with vectors
docker exec postgres-dev psql -U postgres -d postgres << 'EOF'
CREATE TABLE IF NOT EXISTS documents (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(768),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    description TEXT,
    embedding vector(384),
    price DECIMAL(10,2)
);

-- Insert test data
INSERT INTO documents (content, embedding) VALUES 
    ('PostgreSQL is a powerful database', '[0.1, 0.2, 0.3]'::vector);

INSERT INTO products (name, description, embedding, price) VALUES 
    ('Laptop', 'High-performance laptop', '[0.5, 0.6, 0.7]'::vector, 999.99);
EOF

# Verify
docker exec postgres-dev psql -U postgres -d postgres -c "\dt"
# Output shows documents and products tables
```

### Cleanup
```bash
# Stop and remove container (data persists in volume)
docker rm -f postgres-dev

# Remove volume (delete data)
docker volume rm postgres-dev-data
```

---

## Usage Pattern 2: Testing/CI Pipeline

### Docker Compose for Testing
```yaml
# docker-compose.test.yml
version: '3.8'

services:
  postgres:
    image: postgres-pgvector:16
    environment:
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
      POSTGRES_DB: testdb
    ports:
      - "127.0.0.1:5432:5432"
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "testuser", "-d", "testdb"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    volumes:
      - ./test-init.sql:/docker-entrypoint-initdb.d/01-test-init.sql
    tmpfs:  # Use in-memory filesystem for faster tests
      - /var/lib/postgresql/data

  # Your application container
  app-tests:
    image: myapp:test
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://testuser:testpass@postgres:5432/testdb
    command: pytest tests/ -v
```

### Run Tests
```bash
# Start services and run tests
docker-compose -f docker-compose.test.yml up --abort-on-container-exit

# Cleanup
docker-compose -f docker-compose.test.yml down -v  # -v removes volumes
```

### CI/CD Pipeline Example (GitHub Actions)
```yaml
name: Database Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres-pgvector:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: testdb
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
    - uses: actions/checkout@v3
    - name: Run tests
      env:
        DATABASE_URL: postgresql://postgres:postgres@localhost:5432/testdb
      run: |
        python -m pip install -r requirements.txt
        pytest tests/ -v
```

---

## Usage Pattern 3: Production Deployment

### Docker Swarm (Orchestration)
```bash
# Create Docker Secret for password
openssl rand -base64 32 | docker secret create postgres_password -

# Deploy service
docker service create \
  --name postgres-prod \
  --secret postgres_password \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -e POSTGRES_DB=production \
  --publish mode=host,target=5432,published=5432 \
  --constraint node.role==manager \
  --replicas 1 \
  --update-parallelism 1 \
  --update-delay 30s \
  postgres-pgvector:16

# Check service status
docker service ls
docker service ps postgres-prod
```

### Kubernetes Deployment

#### Create Secret
```bash
kubectl create secret generic postgres-secret \
  --from-literal=password=$(openssl rand -base64 32)
```

#### StatefulSet Definition
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-pgvector
  namespace: default
spec:
  serviceName: postgres-pgvector
  replicas: 1
  selector:
    matchLabels:
      app: postgres-pgvector
  template:
    metadata:
      labels:
        app: postgres-pgvector
    spec:
      containers:
      - name: postgres
        image: postgres-pgvector:16
        imagePullPolicy: Always
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_USER
          value: postgres
        - name: POSTGRES_DB
          value: production
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U postgres -d production
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U postgres -d production
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
          subPath: postgres
  volumeClaimTemplates:
  - metadata:
      name: postgres-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast
      resources:
        requests:
          storage: 100Gi
```

#### Service Definition
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-pgvector
  namespace: default
spec:
  clusterIP: None  # Headless service for StatefulSet
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgres-pgvector
```

#### Deploy
```bash
kubectl apply -f postgres-statefulset.yaml
kubectl apply -f postgres-service.yaml

# Check status
kubectl get statefulset postgres-pgvector
kubectl get pods postgres-pgvector-0
kubectl get svc postgres-pgvector
```

### Cloud Container Services

#### Azure Container Instances (ACI)
```bash
az container create \
  --resource-group myResourceGroup \
  --name postgres-pgvector \
  --image postgres-pgvector:16 \
  --environment-variables \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD="$(openssl rand -base64 32)" \
    POSTGRES_DB=production \
  --ports 5432 \
  --memory 2 \
  --cpu 1 \
  --restart-policy OnFailure
```

#### AWS Elastic Container Service (ECS)
```json
{
  "family": "postgres-pgvector",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "postgres",
      "image": "postgres-pgvector:16",
      "memory": 1024,
      "cpu": 256,
      "portMappings": [
        {
          "containerPort": 5432,
          "hostPort": 5432,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "POSTGRES_USER",
          "value": "postgres"
        },
        {
          "name": "POSTGRES_DB",
          "value": "production"
        }
      ],
      "secrets": [
        {
          "name": "POSTGRES_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:region:account:secret:postgres-password"
        }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "pg_isready -U postgres -d production"],
        "interval": 10,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/postgres-pgvector",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

---

## Common Operations

### Backup & Restore

#### Full Database Backup
```bash
# Backup to file (running container)
docker exec postgres-pgvector pg_dumpall -U postgres > backup-$(date +%Y%m%d-%H%M%S).sql

# Backup with compression
docker exec postgres-pgvector pg_dump -U postgres -Fc production > backup.dump

# Backup specific table with vectors
docker exec postgres-pgvector pg_dump -U postgres -t documents -Fc production > documents-backup.dump
```

#### Restore from Backup
```bash
# Restore full database
docker exec -i postgres-pgvector psql -U postgres < backup.sql

# Restore from compressed backup
docker exec -i postgres-pgvector pg_restore -U postgres -d production < backup.dump

# Restore specific table
docker exec -i postgres-pgvector pg_restore -U postgres -d production -t documents < documents-backup.dump
```

### Create Application User
```sql
-- Connect as postgres superuser
docker exec postgres-pgvector psql -U postgres << 'EOF'
-- Create application user
CREATE ROLE app_user WITH LOGIN PASSWORD 'secure_password_here';

-- Create application database
CREATE DATABASE app_db OWNER app_user;

-- Grant permissions
GRANT CONNECT ON DATABASE app_db TO app_user;
GRANT USAGE ON SCHEMA public TO app_db;
GRANT CREATE ON SCHEMA public TO app_user;
EOF

# Verify
docker exec postgres-pgvector psql -U app_user -d app_db -c "CREATE TABLE test (id INT); DROP TABLE test;"
```

### Monitor Performance

#### Check Vector Index Size
```bash
docker exec postgres-pgvector psql -U postgres -d production << 'EOF'
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelname::regclass)) as size
FROM pg_indexes
WHERE tablename LIKE '%document%'
ORDER BY pg_relation_size(indexrelname::regclass) DESC;
EOF
```

#### Query Performance
```bash
docker exec postgres-pgvector psql -U postgres -d production << 'EOF'
-- Enable query timing
\timing on

-- Test vector similarity search
SELECT id, embedding <-> '[0.1, 0.2, 0.3]'::vector AS distance
FROM documents
ORDER BY embedding <-> '[0.1, 0.2, 0.3]'::vector
LIMIT 10;
EOF
```

### Update pgvector Version
```bash
# 1. Update Dockerfile to new version
# Change: git clone --branch v0.5.1 ...
# To:     git clone --branch v0.6.0 ...

# 2. Rebuild image
docker build -t postgres-pgvector:16 -f Dockerfile .

# 3. Create new container with new image (old data persists)
docker stop postgres-pgvector
docker run -d \
  --name postgres-pgvector-new \
  -v postgres-data:/var/lib/postgresql/data \
  postgres-pgvector:16

# 4. Verify
docker exec postgres-pgvector-new psql -U postgres -c \
  "SELECT default_version FROM pg_available_extensions WHERE name='pgvector';"
```

---

## Troubleshooting

### Container Won't Start
```bash
# Check logs
docker logs postgres-pgvector

# Common errors:
# "POSTGRES_PASSWORD env variable is not set"
# → Provide password: docker run -e POSTGRES_PASSWORD=...

# "pgvector.so not found"
# → Rebuild image: docker build --no-cache -f Dockerfile .

# "permission denied: /var/lib/postgresql/data"
# → Check volume permissions: docker exec whoami
```

### Health Check Failing
```bash
# Check health status
docker inspect postgres-pgvector | jq '.[] | select(.State.Health)'

# Manually test health
docker exec postgres-pgvector pg_isready -U postgres

# Check PostgreSQL logs
docker logs postgres-pgvector | grep ERROR
```

### Slow Vector Queries
```bash
# Create index for faster similarity search
docker exec postgres-pgvector psql -U postgres -d production << 'EOF'
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 100);  -- Adjust 'lists' for your data size
EOF

# For larger datasets, use HNSW index (slower to build, faster to query)
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops) 
WITH (m = 16, ef_construction = 64);
```

### Connection Issues
```bash
# Verify port is exposed
docker port postgres-pgvector
# Output: 5432/tcp -> 127.0.0.1:5432

# Test connectivity
docker exec postgres-pgvector psql -U postgres -c "SELECT 1"

# From external host
psql -h <host-ip> -U postgres -d postgres
```

---

## Environment Variables Reference

| Variable | Example | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_PASSWORD` | `secret123` | Superuser password (required) |
| `POSTGRES_DB` | `production` | Default database to create |
| `POSTGRES_INITDB_ARGS` | `-c max_connections=100` | Extra initdb arguments |
| `PGUSER` | `postgres` | Default user for psql (inside container) |

---

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions
- Read [SECURITY.md](SECURITY.md) for production hardening
- See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for testing strategy

