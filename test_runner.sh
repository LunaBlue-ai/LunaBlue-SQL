#!/bin/bash

# ============================================================================
# SQL TEST RUNNER - LunaBlue-SQL Testing Suite
# ============================================================================
#
# PURPOSE:
#   Execute all SQL test steps in correct order with detailed reporting
#   Validates audit, pii, and rag schemas comprehensively
#
# USAGE:
#   ./test_runner.sh              # Run with default settings
#   ./test_runner.sh --verbose    # Show detailed output
#   ./test_runner.sh --step 2     # Run only Step 2 tests
#   ./test_runner.sh --help       # Show this help message
#
# PREREQUISITES:
#   - PostgreSQL 16+ with pgvector extension
#   - All schema files (audit.sql, pii.sql, rag.sql) already loaded
#   - psql command available in PATH
#   - Environment variables: PGHOST, PGUSER, PGPASSWORD (optional)
#
# EXIT CODES:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Invalid arguments
#   3 - Database connection failed
#
# ============================================================================

set -e

# Configuration
VERBOSE=false
SPECIFIC_STEP=""
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
TESTS_DIR="tests"
RESULTS_FILE="TEST_RESULTS_$(date +%Y%m%d_%H%M%S).md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help           Show this help message"
    echo "  --verbose        Show detailed output"
    echo "  --step N         Run only step N (1-10)"
    echo "  --all            Run all steps (default)"
    echo ""
    echo "Environment Variables:"
    echo "  PGHOST           PostgreSQL host (default: localhost)"
    echo "  PGPORT           PostgreSQL port (default: 5432)"
    echo "  PGUSER           PostgreSQL user (default: postgres)"
    echo "  PGDATABASE       PostgreSQL database (default: postgres)"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

run_sql_file() {
    local step=$1
    local step_name=$2
    local file_path="${TESTS_DIR}/${step_name}.sql"
    
    if [ ! -f "$file_path" ]; then
        log_error "Test file not found: $file_path"
        return 1
    fi
    
    log_info "Running Step $step: $step_name"
    
    # Run the SQL file
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -f "$file_path" 2>&1; then
        log_success "Step $step PASSED: $step_name"
        return 0
    else
        log_error "Step $step FAILED: $step_name"
        return 1
    fi
}

test_database_connection() {
    log_info "Testing database connection..."
    
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1" > /dev/null 2>&1; then
        log_success "Database connection successful"
        return 0
    else
        log_error "Cannot connect to database at $PGHOST:$PGPORT"
        log_info "Make sure PostgreSQL is running and credentials are correct:"
        log_info "  PGHOST=$PGHOST PGPORT=$PGPORT PGUSER=$PGUSER PGDATABASE=$PGDATABASE"
        return 3
    fi
}

verify_schemas_exist() {
    log_info "Verifying required schemas exist..."
    
    # Check for audit schema
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'audit'" 2>/dev/null | grep -q 1; then
        log_success "audit schema exists"
    else
        log_error "audit schema not found - run audit.sql first"
        return 1
    fi
    
    # Check for pii schema
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'pii'" 2>/dev/null | grep -q 1; then
        log_success "pii schema exists"
    else
        log_error "pii schema not found - run pii.sql first"
        return 1
    fi
    
    # Check for rag schema
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'rag'" 2>/dev/null | grep -q 1; then
        log_success "rag schema exists"
    else
        log_error "rag schema not found - run rag.sql first"
        return 1
    fi
    
    return 0
}

run_all_steps() {
    local failed_steps=()
    local passed_steps=()
    
    # Step 1: Test Schema Foundation
    if run_sql_file 1 "step_1_foundation"; then
        passed_steps+=("1")
    else
        failed_steps+=("1")
    fi
    
    # Step 2: Audit Settings Tests
    if run_sql_file 2 "step_2_audit_settings"; then
        passed_steps+=("2")
    else
        failed_steps+=("2")
    fi
    
    # Step 3: Audit System Log Tests
    if run_sql_file 3 "step_3_audit_system_log"; then
        passed_steps+=("3")
    else
        failed_steps+=("3")
    fi
    
    # Step 4: PII Encryption Tests
    if run_sql_file 4 "step_4_pii_encryption"; then
        passed_steps+=("4")
    else
        failed_steps+=("4")
    fi
    
    # Step 5: PII Access Control Tests
    if run_sql_file 5 "step_5_pii_access"; then
        passed_steps+=("5")
    else
        failed_steps+=("5")
    fi
    
    # Step 6: RAG Configuration Tests
    if run_sql_file 6 "step_6_rag_config"; then
        passed_steps+=("6")
    else
        failed_steps+=("6")
    fi
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "TEST EXECUTION SUMMARY"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ${#passed_steps[@]} -gt 0 ]; then
        echo -e "${GREEN}Passed Steps: ${passed_steps[*]}${NC}"
    fi
    
    if [ ${#failed_steps[@]} -gt 0 ]; then
        echo -e "${RED}Failed Steps: ${failed_steps[*]}${NC}"
        return 1
    else
        echo -e "${GREEN}All tests PASSED!${NC}"
        return 0
    fi
}

run_specific_step() {
    local step=$1
    
    case $step in
        1)
            run_sql_file 1 "step_1_foundation"
            ;;
        2)
            run_sql_file 2 "step_2_audit_settings"
            ;;
        3)
            run_sql_file 3 "step_3_audit_system_log"
            ;;
        4)
            run_sql_file 4 "step_4_pii_encryption"
            ;;
        5)
            run_sql_file 5 "step_5_pii_access"
            ;;
        6)
            run_sql_file 6 "step_6_rag_config"
            ;;
        *)
            log_error "Invalid step number: $step (valid: 1-6)"
            return 2
            ;;
    esac
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                print_usage
                exit 0
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --step)
                SPECIFIC_STEP="$2"
                shift 2
                ;;
            --all)
                SPECIFIC_STEP=""
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 2
                ;;
        esac
    done
    
    # Display configuration
    echo "════════════════════════════════════════════════════════════════"
    echo "LunaBlue-SQL Test Runner"
    echo "════════════════════════════════════════════════════════════════"
    echo "Database:  $PGHOST:$PGPORT/$PGDATABASE"
    echo "User:      $PGUSER"
    echo "Verbose:   $VERBOSE"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    # Check database connection
    if ! test_database_connection; then
        exit 3
    fi
    
    # Verify schemas exist
    if ! verify_schemas_exist; then
        exit 1
    fi
    
    echo ""
    
    # Run tests
    if [ -n "$SPECIFIC_STEP" ]; then
        log_info "Running only Step $SPECIFIC_STEP..."
        run_specific_step "$SPECIFIC_STEP"
        TEST_EXIT_CODE=$?
    else
        log_info "Running all test steps (1-6)..."
        run_all_steps
        TEST_EXIT_CODE=$?
    fi
    
    # Results summary
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
        echo "════════════════════════════════════════════════════════════════"
        exit 0
    else
        echo -e "${RED}✗ SOME TESTS FAILED${NC}"
        echo "════════════════════════════════════════════════════════════════"
        exit 1
    fi
}

# Run main function
main "$@"

