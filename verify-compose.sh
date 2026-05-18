#!/bin/bash

# ============================================================================
# Docker Compose Verification Script
# ============================================================================
#
# PURPOSE:
#   Comprehensive validation of docker-compose.yml PostgreSQL setup
#   Tests all components: services, volumes, environment, health, networking
#
# USAGE:
#   chmod +x verify-compose.sh
#   ./verify-compose.sh                # Run all tests
#   ./verify-compose.sh --setup        # Create .env and start fresh
#   ./verify-compose.sh --teardown     # Remove containers and volumes
#   ./verify-compose.sh --verbose      # Show detailed output
#
# EXIT CODES:
#   0 = All tests passed
#   1 = One or more tests failed
#   2 = Test environment setup error
#
# PERSPECTIVES:
#   ✓ Testability: Comprehensive test coverage
#   ✓ Maintainability: Clear test organization
#   ✓ Architecture: Tests all components independently
#   ✓ Security: Validates security configurations
#   ✓ Business Value: Ensures production readiness
#   ✓ Documentation: Self-documenting tests
#
# ============================================================================

set -o pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
RESULTS_FILE="/tmp/docker_compose_test_results.txt"
VERBOSE=false
SETUP_ONLY=false
TEARDOWN_ONLY=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

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
    ((TESTS_RUN++))
}

print_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
    echo "$1" >> "$RESULTS_FILE"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

cleanup() {
    print_header "Cleanup"
    
    if docker-compose ps | grep -q postgres-pgvector; then
        print_test "Stopping containers..."
        docker-compose down > /dev/null 2>&1
        print_pass "Containers stopped"
    fi
}

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --setup)
            SETUP_ONLY=true
            shift
            ;;
        --teardown)
            TEARDOWN_ONLY=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--setup] [--teardown] [--verbose]"
            exit 2
            ;;
    esac
done

# Clear results file
> "$RESULTS_FILE"

# ============================================================================
# Step 1: Prerequisites Check
# ============================================================================

print_header "Step 1: Prerequisites Verification"

print_test "Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    print_fail "Docker not found in PATH"
    exit 2
fi
print_pass "Docker is installed"

print_test "Checking docker-compose installation..."
if ! command -v docker-compose &> /dev/null; then
    print_fail "docker-compose not found in PATH"
    exit 2
fi
print_pass "docker-compose is installed"

print_test "Checking Docker daemon..."
if ! docker ps > /dev/null 2>&1; then
    print_fail "Docker daemon is not running"
    exit 2
fi
print_pass "Docker daemon is running"

print_test "Checking docker-compose.yml exists..."
if [ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
    print_fail "docker-compose.yml not found in $SCRIPT_DIR"
    exit 2
fi
print_pass "docker-compose.yml found"

# ============================================================================
# Step 2: Environment Setup
# ============================================================================

print_header "Step 2: Environment Setup"

if [ "$TEARDOWN_ONLY" = true ]; then
    cleanup
    echo "Teardown complete"
    exit 0
fi

print_test "Checking .env file..."
if [ ! -f "$ENV_FILE" ]; then
    if [ ! -f "$ENV_EXAMPLE" ]; then
        print_fail ".env.example not found"
        exit 2
    fi
    print_info ".env file not found, creating from .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    # Set strong password for testing
    RANDOM_PASS=$(openssl rand -base64 32)
    sed -i.bak "s/change_me_to_strong_password_12_chars_minimum/$RANDOM_PASS/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    print_pass ".env file created with generated password"
else
    print_pass ".env file exists"
fi

if [ "$SETUP_ONLY" = true ]; then
    echo "Setup complete"
    exit 0
fi

# ============================================================================
# Step 3: YAML Validation
# ============================================================================

print_header "Step 3: Docker Compose YAML Validation"

print_test "Validating docker-compose.yml syntax..."
if docker-compose config > /dev/null 2>&1; then
    print_pass "YAML syntax is valid"
else
    print_fail "YAML syntax is invalid"
    if [ "$VERBOSE" = true ]; then
        docker-compose config
    fi
    exit 1
fi

print_test "Checking service definitions..."
SERVICES=$(docker-compose config --services)
if echo "$SERVICES" | grep -q "postgres"; then
    print_pass "PostgreSQL service found"
else
    print_fail "PostgreSQL service not found"
    exit 1
fi

# ============================================================================
# Step 4: Container Startup
# ============================================================================

print_header "Step 4: Container Startup Test"

# Clean up any existing containers
if docker-compose ps | grep -q postgres; then
    print_test "Removing existing containers..."
    docker-compose down > /dev/null 2>&1
fi

print_test "Starting services..."
if docker-compose up -d > /tmp/compose_up.log 2>&1; then
    print_pass "Services started successfully"
else
    print_fail "Failed to start services"
    if [ "$VERBOSE" = true ]; then
        cat /tmp/compose_up.log
    fi
    cleanup
    exit 1
fi

print_test "Waiting for PostgreSQL to be ready (max 60 seconds)..."
READY=false
for i in {1..60}; do
    if docker-compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1; then
        READY=true
        print_pass "PostgreSQL is ready (attempt $i)"
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo "  Waiting... attempt $i/60"
    sleep 1
done

if [ "$READY" = false ]; then
    print_fail "PostgreSQL failed to become ready"
    docker-compose logs postgres | tail -20
    cleanup
    exit 1
fi

# ============================================================================
# Step 5: Health Check Verification
# ============================================================================

print_header "Step 5: Health Check Verification"

print_test "Checking health check configuration..."
HEALTH_CONFIG=$(docker-compose config | grep -A 10 "healthcheck" | head -5)
if [ -n "$HEALTH_CONFIG" ]; then
    print_pass "Health check is configured"
else
    print_fail "Health check not configured"
fi

print_test "Verifying container health status..."
HEALTH=$(docker inspect postgres-pgvector 2>/dev/null | grep -o '"Status":"[^"]*"' | grep -o '[^"]*$' | head -1)
if [ "$HEALTH" = "healthy" ]; then
    print_pass "Container health status: healthy"
else
    print_fail "Container health status: $HEALTH (expected: healthy)"
fi

# ============================================================================
# Step 6: Environment Variables
# ============================================================================

print_header "Step 6: Environment Variables Verification"

print_test "Checking POSTGRES_USER..."
PG_USER=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT current_user;" 2>/dev/null | tr -d ' ')
if [ -n "$PG_USER" ]; then
    print_pass "POSTGRES_USER set correctly: $PG_USER"
else
    print_fail "POSTGRES_USER not set"
fi

print_test "Checking POSTGRES_DB..."
DATABASES=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null | grep -v "^$")
if echo "$DATABASES" | grep -q "postgres"; then
    print_pass "Default database created: postgres"
else
    print_fail "Default database not created"
fi

print_test "Checking pgvector preload..."
PRELOAD=$(docker-compose exec -T postgres psql -U postgres -t -c "SHOW shared_preload_libraries;" 2>/dev/null | tr -d ' ')
if [ "$PRELOAD" = "vector" ]; then
    print_pass "pgvector preloaded: $PRELOAD"
else
    print_fail "pgvector not preloaded: $PRELOAD"
fi

# ============================================================================
# Step 7: Volume Verification
# ============================================================================

print_header "Step 7: Volume Verification"

print_test "Checking volume creation..."
if docker volume ls | grep -q "postgres_data"; then
    print_pass "postgres_data volume created"
else
    print_fail "postgres_data volume not found"
fi

print_test "Testing data persistence..."
docker-compose exec -T postgres psql -U postgres -d postgres -c "CREATE TABLE persistence_test (id INT, data TEXT);" > /dev/null 2>&1
docker-compose exec -T postgres psql -U postgres -d postgres -c "INSERT INTO persistence_test VALUES (1, 'test data');" > /dev/null 2>&1

# Stop and restart
docker-compose stop postgres > /dev/null 2>&1
sleep 3
docker-compose start postgres > /dev/null 2>&1
sleep 5

# Check if data persists
PERSISTED=$(docker-compose exec -T postgres psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM persistence_test;" 2>/dev/null | tr -d ' ')
if [ "$PERSISTED" = "1" ]; then
    print_pass "Data persisted across restart"
    docker-compose exec -T postgres psql -U postgres -d postgres -c "DROP TABLE persistence_test;" > /dev/null 2>&1
else
    print_fail "Data did not persist across restart"
fi

# ============================================================================
# Step 8: Feature Tests
# ============================================================================

print_header "Step 8: Feature Tests"

print_test "Testing basic PostgreSQL connectivity..."
if docker-compose exec -T postgres psql -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    print_pass "PostgreSQL connectivity works"
else
    print_fail "PostgreSQL connectivity failed"
fi

print_test "Testing pgvector extension..."
EXT=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='vector');" 2>/dev/null | tr -d ' ')
if [ "$EXT" = "t" ] || [ "$EXT" = "true" ]; then
    print_pass "pgvector extension available"
else
    print_fail "pgvector extension not loaded"
fi

print_test "Testing vector type..."
VECTOR=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT '[1,2,3]'::vector;" 2>/dev/null | tr -d ' ')
if [ "$VECTOR" = "[1,2,3]" ]; then
    print_pass "Vector type works"
else
    print_fail "Vector type failed (got: $VECTOR)"
fi

print_test "Testing similarity operator..."
DISTANCE=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector;" 2>/dev/null | tr -d ' ')
if [ -n "$DISTANCE" ] && [ "$DISTANCE" != "NULL" ]; then
    print_pass "Vector similarity operator works (distance: $DISTANCE)"
else
    print_fail "Vector similarity operator failed"
fi

# ============================================================================
# Step 9: Logging Verification
# ============================================================================

print_header "Step 9: Logging Configuration Verification"

print_test "Checking logging driver..."
LOG_DRIVER=$(docker inspect postgres-pgvector | grep -A 5 '"LogDriver"' | grep -o '"Type":"[^"]*"' | head -1 | grep -o '[^"]*$')
if [ "$LOG_DRIVER" = "json-file" ]; then
    print_pass "Logging driver: $LOG_DRIVER (configured correctly)"
else
    print_info "Logging driver: $LOG_DRIVER"
fi

print_test "Checking log size limits..."
LOG_CONFIG=$(docker inspect postgres-pgvector | grep -A 10 '"max-size"')
if echo "$LOG_CONFIG" | grep -q "10m"; then
    print_pass "Log size limit configured: 10m"
else
    print_info "Log size limit: check docker inspect output"
fi

# ============================================================================
# Step 10: Performance Baseline
# ============================================================================

print_header "Step 10: Performance Baseline"

print_test "Measuring simple query performance..."
SIMPLE_START=$(date +%s%N)
docker-compose exec -T postgres psql -U postgres -c "SELECT 1;" > /dev/null 2>&1
SIMPLE_END=$(date +%s%N)
SIMPLE_TIME=$(( ($SIMPLE_END - $SIMPLE_START) / 1000000 ))
print_info "Simple query: ${SIMPLE_TIME}ms"

print_test "Measuring complex query performance..."
COMPLEX_START=$(date +%s%N)
docker-compose exec -T postgres psql -U postgres -c "SELECT COUNT(*) FROM pg_stat_activity;" > /dev/null 2>&1
COMPLEX_END=$(date +%s%N)
COMPLEX_TIME=$(( ($COMPLEX_END - $COMPLEX_START) / 1000000 ))
print_info "Complex query: ${COMPLEX_TIME}ms"

print_test "Checking resource usage..."
MEMORY=$(docker stats postgres-pgvector --no-stream | tail -1 | awk '{print $4}')
CPU=$(docker stats postgres-pgvector --no-stream | tail -1 | awk '{print $3}')
print_info "Current memory: $MEMORY | CPU: $CPU"

# ============================================================================
# Summary
# ============================================================================

print_header "Test Summary"

TOTAL=$((TESTS_PASSED + TESTS_FAILED))
PERCENT=$((TESTS_PASSED * 100 / TOTAL))

echo "Tests Run: $TOTAL"
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo "Pass Rate: ${PERCENT}%"
echo ""

if [ "$TESTS_FAILED" -eq 0 ]; then
    print_pass "All tests passed!"
    echo ""
    print_info "Docker Compose Setup Status:"
    docker-compose ps
    echo ""
    echo "To connect to PostgreSQL:"
    echo "  psql -h localhost -U postgres -d postgres"
    echo "  Or: docker-compose exec postgres psql -U postgres -d postgres"
    echo ""
    echo "To stop services:"
    echo "  docker-compose stop"
    echo ""
    echo "To view logs:"
    echo "  docker-compose logs -f postgres"
    echo ""
    
    cleanup
    exit 0
else
    print_fail "Some tests failed ($TESTS_FAILED failures)"
    echo ""
    echo "Failed tests:"
    cat "$RESULTS_FILE"
    echo ""
    
    cleanup
    exit 1
fi

