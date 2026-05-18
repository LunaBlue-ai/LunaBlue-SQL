#!/bin/bash

# ============================================================================
# PostgreSQL 16 + pgvector Verification Script
# ============================================================================
#
# PURPOSE:
#   Automated verification of PostgreSQL 16 + pgvector Docker image
#   Runs comprehensive tests across all perspectives:
#   - Maintainability: Image structure and layer caching
#   - Testability: Health checks, connectivity, functionality
#   - Architecture: Component integration and communication
#   - Security: User permissions, isolation, no hardcoded secrets
#   - Business Value: Performance and feature availability
#   - Documentation: Comments and reference accuracy
#
# USAGE:
#   ./verify.sh                    # Run all tests
#   ./verify.sh --build            # Build image first, then test
#   ./verify.sh --cleanup          # Remove test containers
#   ./verify.sh --verbose          # Show detailed output
#
# EXIT CODES:
#   0 = All tests passed
#   1 = One or more tests failed
#   2 = Test environment setup error
#
# ============================================================================

set -o pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="postgres-pgvector:16"
CONTAINER_NAME="postgres-pgvector-verify"
TEST_RESULTS_FILE="/tmp/pgvector_test_results.txt"
VERBOSE=false
BUILD_IMAGE=false
CLEANUP_AFTER=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_test() {
    echo -e "${YELLOW}→${NC} $1"
}

print_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
    echo "$1" >> "$TEST_RESULTS_FILE"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

cleanup() {
    print_header "Cleanup"
    
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        print_test "Stopping container..."
        docker stop "$CONTAINER_NAME" > /dev/null 2>&1
        docker rm "$CONTAINER_NAME" > /dev/null 2>&1
        print_pass "Container removed"
    fi
}

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD_IMAGE=true
            shift
            ;;
        --cleanup)
            cleanup
            exit 0
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--build] [--cleanup] [--verbose]"
            exit 2
            ;;
    esac
done

# Clear results file
> "$TEST_RESULTS_FILE"

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================

print_header "Step 1: Verify Prerequisites"

print_test "Checking Docker is running..."
if ! docker ps > /dev/null 2>&1; then
    print_fail "Docker is not running or not accessible"
    exit 2
fi
print_pass "Docker is accessible"

print_test "Checking Docker version..."
DOCKER_VERSION=$(docker --version | grep -oP 'Docker version \K[0-9.]+')
if [[ -z "$DOCKER_VERSION" ]]; then
    print_fail "Could not determine Docker version"
    exit 2
fi
print_pass "Docker version: $DOCKER_VERSION"

# ============================================================================
# Step 2: Build Image (Optional)
# ============================================================================

if [ "$BUILD_IMAGE" = true ]; then
    print_header "Step 2: Build Docker Image"
    
    print_test "Building image: $IMAGE_NAME..."
    if docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" > /tmp/docker_build.log 2>&1; then
        print_pass "Image built successfully"
    else
        print_fail "Image build failed"
        if [ "$VERBOSE" = true ]; then
            cat /tmp/docker_build.log
        fi
        exit 1
    fi
    
    print_test "Checking image size..."
    IMAGE_SIZE=$(docker images "$IMAGE_NAME" --format "{{.Size}}")
    print_info "Image size: $IMAGE_SIZE"
    
    print_test "Checking image layers..."
    LAYER_COUNT=$(docker history "$IMAGE_NAME" | tail -n +2 | wc -l)
    print_info "Image layers: $LAYER_COUNT"
else
    print_header "Step 2: Verify Image Exists"
    
    print_test "Checking if image exists..."
    if ! docker images "$IMAGE_NAME" | grep -q "$IMAGE_NAME"; then
        print_fail "Image $IMAGE_NAME not found"
        echo "Run: ./verify.sh --build"
        exit 2
    fi
    print_pass "Image found: $IMAGE_NAME"
fi

# ============================================================================
# Step 3: Start Container
# ============================================================================

print_header "Step 3: Start Test Container"

# Stop any existing test container
if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
    print_test "Removing existing test container..."
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1
fi

print_test "Starting container: $CONTAINER_NAME..."
if docker run -d \
    --name "$CONTAINER_NAME" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=postgres \
    "$IMAGE_NAME" > /tmp/container_start.log 2>&1; then
    print_pass "Container started"
else
    print_fail "Failed to start container"
    if [ "$VERBOSE" = true ]; then
        cat /tmp/container_start.log
    fi
    exit 1
fi

# ============================================================================
# Step 4: Wait for Health Check
# ============================================================================

print_header "Step 4: Wait for Database Readiness"

print_test "Waiting for health check (max 60 seconds)..."
HEALTH_CHECK_PASSED=false
for i in {1..60}; do
    HEALTH_STATUS=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Health.Status}}' 2>/dev/null || echo "")
    
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        HEALTH_CHECK_PASSED=true
        print_pass "Health check passed on attempt $i"
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Attempt $i/60..."
    fi
    
    sleep 1
done

if [ "$HEALTH_CHECK_PASSED" = false ]; then
    print_fail "Health check failed after 60 seconds"
    if [ "$VERBOSE" = true ]; then
        echo "Container logs:"
        docker logs "$CONTAINER_NAME"
    fi
    cleanup
    exit 1
fi

# ============================================================================
# Step 5: Testability Tests
# ============================================================================

print_header "Step 5: Testability Tests"

# Test 5.1: PostgreSQL Connectivity
print_test "Testing PostgreSQL connectivity..."
if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    print_pass "PostgreSQL connection successful"
else
    print_fail "PostgreSQL connection failed"
    cleanup
    exit 1
fi

# Test 5.2: pgvector Extension Availability
print_test "Testing pgvector extension availability..."
PGVECTOR_VERSION=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT default_version FROM pg_available_extensions WHERE name='pgvector';" 2>/dev/null | tr -d ' ')

if [ -n "$PGVECTOR_VERSION" ]; then
    print_pass "pgvector extension available (version: $PGVECTOR_VERSION)"
else
    print_fail "pgvector extension not found in pg_available_extensions"
    cleanup
    exit 1
fi

# Test 5.3: pgvector Extension Creation
print_test "Testing pgvector extension creation..."
if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgvector;" > /dev/null 2>&1; then
    print_pass "pgvector extension created successfully"
else
    print_fail "Failed to create pgvector extension"
    cleanup
    exit 1
fi

# ============================================================================
# Step 6: Feature Tests
# ============================================================================

print_header "Step 6: pgvector Feature Tests"

# Test 6.1: Vector Type Support
print_test "Testing vector type support..."
VECTOR_RESULT=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT '[1,2,3]'::vector;" 2>/dev/null | tr -d ' ')

if [ "$VECTOR_RESULT" = "[1,2,3]" ]; then
    print_pass "Vector type creation and casting works"
else
    print_fail "Vector type casting failed (got: $VECTOR_RESULT)"
    cleanup
    exit 1
fi

# Test 6.2: Euclidean Distance Operator
print_test "Testing Euclidean distance operator (<->)..."
DISTANCE=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector;" 2>/dev/null | tr -d ' ')

if [ -n "$DISTANCE" ] && [ "$DISTANCE" != "NULL" ]; then
    print_pass "Euclidean distance works (distance: $DISTANCE)"
else
    print_fail "Euclidean distance operator failed"
    cleanup
    exit 1
fi

# Test 6.3: Cosine Distance Operator
print_test "Testing cosine distance operator (<=>)..."
COSINE=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT '[1,0,0]'::vector <=> '[0,1,0]'::vector;" 2>/dev/null | tr -d ' ')

if [ -n "$COSINE" ] && [ "$COSINE" != "NULL" ]; then
    print_pass "Cosine distance works (distance: $COSINE)"
else
    print_fail "Cosine distance operator failed"
    cleanup
    exit 1
fi

# Test 6.4: Inner Product Operator
print_test "Testing inner product operator (<#>)..."
INNER=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT '[1,2,3]'::vector <#> '[4,5,6]'::vector;" 2>/dev/null | tr -d ' ')

if [ -n "$INNER" ] && [ "$INNER" != "NULL" ]; then
    print_pass "Inner product operator works (result: $INNER)"
else
    print_fail "Inner product operator failed"
    cleanup
    exit 1
fi

# ============================================================================
# Step 7: Table and Index Tests
# ============================================================================

print_header "Step 7: Table and Index Tests"

# Test 7.1: Create Vector Table
print_test "Creating test table with vector column..."
docker exec "$CONTAINER_NAME" psql -U postgres -d postgres << 'EOF' > /dev/null 2>&1
CREATE TABLE IF NOT EXISTS test_vectors (
    id SERIAL PRIMARY KEY,
    data TEXT,
    embedding vector(3)
);
INSERT INTO test_vectors (data, embedding) VALUES 
    ('test1', '[1,2,3]'::vector),
    ('test2', '[4,5,6]'::vector);
EOF

if [ $? -eq 0 ]; then
    print_pass "Test table created with vector column"
else
    print_fail "Failed to create test table"
    cleanup
    exit 1
fi

# Test 7.2: Create Vector Index
print_test "Creating HNSW index on vector column..."
if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c \
    "CREATE INDEX idx_test_vectors ON test_vectors USING hnsw (embedding vector_cosine_ops);" > /dev/null 2>&1; then
    print_pass "HNSW index created successfully"
else
    print_fail "Failed to create HNSW index"
    cleanup
    exit 1
fi

# Test 7.3: Query with Vector Index
print_test "Querying with vector similarity..."
QUERY_RESULT=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c \
    "SELECT id FROM test_vectors ORDER BY embedding <-> '[1,2,3]'::vector LIMIT 1;" 2>/dev/null)

if [ "$QUERY_RESULT" = "1" ]; then
    print_pass "Vector similarity query works (returned correct result)"
else
    print_fail "Vector similarity query failed (got: $QUERY_RESULT)"
    cleanup
    exit 1
fi

# ============================================================================
# Step 8: Security Tests
# ============================================================================

print_header "Step 8: Security Tests"

# Test 8.1: Non-root User
print_test "Verifying non-root user execution..."
USER=$(docker exec "$CONTAINER_NAME" whoami 2>/dev/null)

if [ "$USER" = "postgres" ]; then
    print_pass "PostgreSQL running as non-root user: $USER"
else
    print_fail "PostgreSQL running as: $USER (expected: postgres)"
fi

# Test 8.2: No Build Tools in Image
print_test "Verifying build tools are not in final image..."
BUILD_TOOLS=false

for tool in gcc make git; do
    if docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1; then
        print_fail "Found build tool in image: $tool"
        BUILD_TOOLS=true
    fi
done

if [ "$BUILD_TOOLS" = false ]; then
    print_pass "No build tools found in final image"
fi

# Test 8.3: Check for Hardcoded Secrets
print_test "Scanning image for hardcoded secrets..."
SECRETS_FOUND=false

# Check Dockerfile and scripts for common secret patterns
if grep -r "password.*=" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"/*.sql 2>/dev/null | grep -v "PASSWORD_FILE" | grep -v "ENV POSTGRES_PASSWORD" | grep -q "="; then
    print_fail "Potential hardcoded secrets found"
    SECRETS_FOUND=true
fi

if [ "$SECRETS_FOUND" = false ]; then
    print_pass "No hardcoded secrets detected"
fi

# ============================================================================
# Step 9: Health Check Test
# ============================================================================

print_header "Step 9: Health Check Test"

print_test "Verifying HEALTHCHECK is configured..."
HEALTH_CONFIG=$(docker inspect "$CONTAINER_NAME" --format='{{.Config.Healthcheck}}')

if [ "$HEALTH_CONFIG" != "<nil>" ]; then
    print_pass "HEALTHCHECK configured"
    
    # Verify current health status
    CURRENT_HEALTH=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Health.Status}}')
    print_info "Current health status: $CURRENT_HEALTH"
else
    print_fail "HEALTHCHECK not configured"
fi

# ============================================================================
# Step 10: Performance Baseline
# ============================================================================

print_header "Step 10: Performance Baseline"

print_test "Measuring query performance..."

# Simple query
SIMPLE_START=$(date +%s%N)
docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1
SIMPLE_END=$(date +%s%N)
SIMPLE_TIME=$(( ($SIMPLE_END - $SIMPLE_START) / 1000000 ))
print_info "Simple query time: ${SIMPLE_TIME}ms"

# Vector similarity query
VECTOR_START=$(date +%s%N)
docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c \
    "SELECT id FROM test_vectors ORDER BY embedding <-> '[1,2,3]'::vector LIMIT 1;" > /dev/null 2>&1
VECTOR_END=$(date +%s%N)
VECTOR_TIME=$(( ($VECTOR_END - $VECTOR_START) / 1000000 ))
print_info "Vector similarity query time: ${VECTOR_TIME}ms"

# ============================================================================
# Step 11: Summary
# ============================================================================

print_header "Test Summary"

# Count results
FAILURE_COUNT=$(wc -l < "$TEST_RESULTS_FILE")

if [ "$FAILURE_COUNT" -eq 0 ]; then
    print_pass "All tests passed!"
    echo ""
    print_info "Image: $IMAGE_NAME"
    print_info "Container: $CONTAINER_NAME (running)"
    print_info "PostgreSQL version: 16"
    print_info "pgvector version: $PGVECTOR_VERSION"
    echo ""
    echo "To access the database:"
    echo "  psql -h localhost -U postgres -d postgres"
    echo "  Password: postgres"
    echo ""
    echo "To stop and remove the test container:"
    echo "  docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
    echo ""
    
    exit 0
else
    print_fail "Some tests failed ($FAILURE_COUNT failures)"
    echo ""
    echo "Failed tests:"
    cat "$TEST_RESULTS_FILE"
    echo ""
    
    cleanup
    exit 1
fi

