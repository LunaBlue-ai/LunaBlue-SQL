# Test Execution Guidelines

## Overview

This document provides complete instructions for executing the LunaBlue-SQL test suite. The test suite validates three critical database schemas: **audit**, **pii**, and **rag**.

---

## Test Architecture

### Multi-Perspective Design

All tests are designed with six key perspectives in mind:

| Perspective | Purpose | Example |
|---|---|---|
| **Testability** | Tests are small, isolated, and independently verifiable | Each test validates one behavior |
| **Maintainability** | Code is clear, well-documented, and easy to modify | Test names describe exactly what they test |
| **Architecture** | Design follows clean architecture principles | Schemas are separated, tests don't depend on order |
| **Security** | Tests validate security constraints and policies | Permission tests, encryption validation |
| **Business Value** | Tests ensure compliance and reliability | Audit immutability, PII protection, RAG integrity |
| **Documentation** | Inline comments and clear explanations | Every test explains its purpose and expected results |

### Test Pyramid

```
┌─────────────────────────────────────┐
│   Integration Tests (Step 7)        │  Cross-schema validation
├─────────────────────────────────────┤
│  Schema Unit Tests (Steps 2-6)      │  6 tests per schema
├─────────────────────────────────────┤
│  Foundation (Step 1)                │  Test infrastructure
└─────────────────────────────────────┘
     Edge Cases & Performance (Steps 8-9)
```

---

## Quick Start

### Prerequisites

```bash
# 1. PostgreSQL 16+ with pgvector extension installed
# 2. All production schemas loaded:
docker exec container psql -U postgres -f audit.sql
docker exec container psql -U postgres -f pii.sql
docker exec container psql -U postgres -f rag.sql

# 3. Verify schemas exist
docker exec container psql -U postgres -c \
  "SELECT schema_name FROM information_schema.schemata \
   WHERE schema_name IN ('audit', 'pii', 'rag')"
```

### Running All Tests

```bash
# Using the test runner script
chmod +x test_runner.sh
./test_runner.sh

# Or run individually
docker exec -i container psql -U postgres -f tests/step_1_foundation.sql
docker exec -i container psql -U postgres -f tests/step_2_audit_settings.sql
docker exec -i container psql -U postgres -f tests/step_3_audit_system_log.sql
docker exec -i container psql -U postgres -f tests/step_4_pii_encryption.sql
docker exec -i container psql -U postgres -f tests/step_5_pii_access.sql
docker exec -i container psql -U postgres -f tests/step_6_rag_config.sql
```

---

## Test Steps Explained

### Step 1: Test Schema Foundation (10 min)

**Files**: `tests/step_1_foundation.sql`

**Purpose**: Create isolated test infrastructure

**What It Tests**:
- ✓ Test schema `test_audit` is created and isolated
- ✓ Test execution logging is functional
- ✓ Assertion helper functions work correctly
- ✓ Setup/teardown functions are callable

**Expected Output**:
```
✓ test_audit schema created with 1 table and 4+ functions
✓ test_execution_log table accepts records
✓ assert_equal() function works
```

**When It Fails**:
- Check that you have CREATE SCHEMA permissions
- Verify PostgreSQL 16+ is installed
- Ensure no existing `test_audit` schema conflicts

---

### Step 2: Audit Settings Tests (10 min)

**Files**: `tests/step_2_audit_settings.sql`

**Purpose**: Validate `audit.settings` table configuration management

**Test Coverage**:
| Test | Validates |
|------|-----------|
| `test_settings_default_values_exist` | 9 default settings are loaded |
| `test_settings_can_update_value` | UPDATE works, timestamps change |
| `test_settings_prevents_insert` | PUBLIC cannot INSERT (permission denied) |
| `test_settings_prevents_delete` | PUBLIC cannot DELETE (permission denied) |
| `test_settings_type_validation` | CHECK constraint enforces valid types |
| `test_settings_boolean_parsing` | Boolean values store/retrieve correctly |

**Expected Output**:
```
✓ test_settings_default_values_exist PASSED
✓ test_settings_can_update_value PASSED
✓ test_settings_prevents_insert PASSED
✓ test_settings_prevents_delete PASSED
✓ test_settings_type_validation PASSED
✓ test_settings_boolean_parsing PASSED

STEP 2: AUDIT SETTINGS TABLE TESTS - SUMMARY REPORT
Total Tests:   6
Passed:        6
Failed:        0
```

**When It Fails**:
- If `audit` schema doesn't exist: run `audit.sql` first
- If default settings count is wrong: check if audit.sql was fully executed
- If permission tests fail: check GRANT statements in audit.sql

---

### Step 3: Audit System Log Tests (15 min)

**Files**: `tests/step_3_audit_system_log.sql`

**Purpose**: Validate `audit.system_log` append-only audit trail

**Critical Tests**:
| Test | Security Importance |
|------|---------------------|
| `test_system_log_prevents_update` | CRITICAL - audit cannot be modified |
| `test_system_log_prevents_delete` | CRITICAL - audit cannot be deleted |
| `test_system_log_timestamp_auto_generated` | CRITICAL - proves when events occurred |
| `test_system_log_user_audit_field_required` | CRITICAL - every action is attributed |

**Expected Output**:
```
✓ test_system_log_insert_creates_record PASSED
✓ test_system_log_timestamp_auto_generated PASSED
✓ test_system_log_prevents_update PASSED
✓ test_system_log_prevents_delete PASSED
✓ test_system_log_jsonb_metadata_valid PASSED
✓ test_system_log_event_severity_validation PASSED
✓ test_system_log_user_audit_field_required PASSED
✓ test_system_log_events_ordered_by_time PASSED

STEP 3: AUDIT SYSTEM LOG TABLE TESTS - SUMMARY REPORT
Total Tests:   8
Passed:        8
Failed:        0
```

**When It Fails**:
- If UPDATE/DELETE tests fail: check if immutability triggers are in place
- If timestamp tests fail: check if created_at defaults to NOW()
- If NOT NULL tests fail: verify user_action column constraint

---

### Step 4: PII Encryption Configuration Tests (10 min)

**Files**: `tests/step_4_pii_encryption.sql`

**Purpose**: Validate encryption configuration and key management

**What It Tests**:
- ✓ 3 default encryption configs (AES, Bcrypt, Pseudonymization)
- ✓ Algorithm validation (only supported algorithms allowed)
- ✓ Key versioning for rotation tracking
- ✓ Enable/disable flags
- ✓ Expiration date handling

**Expected Output**:
```
✓ test_encryption_config_defaults_exist PASSED
✓ test_encryption_config_algorithm_validation PASSED
✓ test_encryption_config_key_version_required PASSED
✓ test_encryption_config_rotation_interval_valid PASSED
✓ test_encryption_config_enabled_flag PASSED
✓ test_encryption_config_expiration_logic PASSED

STEP 4: PII ENCRYPTION CONFIGURATION TESTS - SUMMARY REPORT
Total Tests:   6
Passed:        6
Failed:        0
```

**Security Notes**:
- **NO ACTUAL ENCRYPTION KEYS** are stored or tested
- Tests validate only the **metadata** about encryption
- Actual keys are stored externally (AWS KMS, Azure Key Vault, etc.)

---

### Step 5: PII Access Control Tests (10 min)

**Files**: `tests/step_5_pii_access.sql`

**Purpose**: Validate PII data protection and access controls

**Compliance Focus**:
- ✓ PII categories enum (person_name, email, phone, etc.)
- ✓ Row-level security infrastructure
- ✓ Encryption status documentation
- ✓ Audit logging capability

**Expected Output**:
```
✓ test_pii_categories_enum_exists PASSED
✓ test_pii_categories_valid_values PASSED
✓ test_pii_access_control_rls_enabled PASSED
✓ test_pii_sensitive_field_encryption_marked PASSED
✓ test_pii_access_audit_trail PASSED

STEP 5: PII ACCESS CONTROL AND CATEGORIES TESTS - SUMMARY REPORT
Total Tests:   5
Passed:        5
Failed:        0
```

**Compliance Validation**:
- GDPR: Data minimization via RLS ✓
- GDPR: Access logging enabled ✓
- GDPR: Encryption documented ✓
- HIPAA: Field-level access control ✓

---

### Step 6: RAG Configuration and Documents Tests (15 min)

**Files**: `tests/step_6_rag_config.sql`

**Purpose**: Validate RAG pipeline infrastructure

**Test Coverage**:
| Component | Tests |
|-----------|-------|
| Configuration | 4 tests (embedding model, chunking, indexing) |
| Document Lifecycle | 6 tests (insert, status, timestamp, metadata) |

**Expected Output**:
```
✓ test_rag_config_defaults_exist PASSED
✓ test_rag_config_embedding_model_valid PASSED
✓ test_rag_config_chunk_parameters_valid PASSED
✓ test_rag_config_index_parameters_valid PASSED
✓ test_rag_documents_insert_creates_record PASSED
✓ test_rag_documents_status_validation PASSED
✓ test_rag_documents_timestamp_auto_generated PASSED
✓ test_rag_documents_metadata_jsonb_valid PASSED
✓ test_rag_documents_language_default PASSED
✓ test_rag_documents_indexes_exist PASSED

STEP 6: RAG CONFIGURATION AND DOCUMENTS TESTS - SUMMARY REPORT
Total Tests:   10
Passed:        10
Failed:        0
```

**RAG Pipeline Validation**:
- ✓ Embedding model configured (all-MiniLM-L6-v2, 384 dimensions)
- ✓ Chunking parameters set (512 tokens, 50 overlap)
- ✓ Vector index tuning (HNSW/IVFFLAT parameters)
- ✓ Document lifecycle (processing → ready/failed)
- ✓ Multi-language support (defaults to 'en')

---

## Running Tests in Different Environments

### Docker Compose

```bash
# Run all tests against docker-compose deployment
docker-compose exec postgres ./test_runner.sh

# Run specific step
docker-compose exec postgres test_runner.sh --step 3

# Verbose output
docker-compose exec postgres test_runner.sh --verbose
```

### Local PostgreSQL

```bash
# Set environment variables
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=postgres

# Run tests
./test_runner.sh

# Or with explicit parameters
psql -h localhost -U postgres -d postgres -f tests/step_1_foundation.sql
```

### Remote Database

```bash
# Set remote connection parameters
export PGHOST=prod-db.example.com
export PGPORT=5432
export PGUSER=app_user
export PGPASSWORD=secure_password
export PGDATABASE=production

./test_runner.sh --verbose
```

---

## Interpreting Test Results

### Success Output

```
════════════════════════════════════════════════════════════════
TEST EXECUTION SUMMARY
════════════════════════════════════════════════════════════════

Passed Steps: 1 2 3 4 5 6
All tests PASSED!
```

**Meaning**: All schemas are correctly configured and validated.

### Failure Output

```
✗ Step 3: test_system_log_prevents_update FAILED
[DETAIL] Test FAILED: Expected error with sqlstate [P0001] but query succeeded
```

**Meaning**: 
1. The audit.system_log table does NOT prevent UPDATEs
2. Audit trail is **NOT IMMUTABLE** - potential compliance violation
3. Check if update prevention trigger/policy is in place

### Debugging Failed Tests

```bash
# 1. Run test with verbose output
./test_runner.sh --step 3 --verbose

# 2. Check test execution log in database
psql -U postgres -d postgres -c \
  "SELECT test_name, status, error_message FROM test_audit.test_execution_log \
   WHERE status = 'FAILED' \
   ORDER BY created_at DESC LIMIT 5"

# 3. Run test manually to see actual error
psql -U postgres -d postgres -f tests/step_3_audit_system_log.sql 2>&1 | tail -50

# 4. Check if production schemas are properly configured
psql -U postgres -d postgres -c "\dt audit.*"
psql -U postgres -d postgres -c "\dt pii.*"
psql -U postgres -d postgres -c "\dt rag.*"
```

---

## Performance Expectations

| Step | Duration | Notes |
|------|----------|-------|
| 1: Foundation | 5-10 sec | Creates test schema and helpers |
| 2: Audit Settings | 10-15 sec | 6 simple queries |
| 3: Audit System Log | 15-20 sec | Tests immutability (slower) |
| 4: PII Encryption | 10-15 sec | Metadata validation |
| 5: PII Access | 10-15 sec | Enum and RLS checks |
| 6: RAG Config | 15-20 sec | 10 comprehensive tests |
| **Total** | **60-95 sec** | Should complete in < 2 minutes |

**If tests take > 5 minutes**: Check for lock contention, slow I/O, or high system load.

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Run SQL Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v2
      - name: Load schemas
        run: |
          psql -h localhost -U postgres -f audit.sql
          psql -h localhost -U postgres -f pii.sql
          psql -h localhost -U postgres -f rag.sql
      - name: Run tests
        run: ./test_runner.sh
        env:
          PGHOST: localhost
          PGUSER: postgres
          PGDATABASE: postgres
          PGPASSWORD: postgres
```

### GitLab CI Example

```yaml
test_sql:
  image: postgres:16-alpine
  services:
    - postgres:16-alpine
  variables:
    PGHOST: postgres
    PGUSER: postgres
    PGPASSWORD: postgres
    PGDATABASE: postgres
  script:
    - psql -h $PGHOST -U $PGUSER -f audit.sql
    - psql -h $PGHOST -U $PGUSER -f pii.sql
    - psql -h $PGHOST -U $PGUSER -f rag.sql
    - chmod +x test_runner.sh
    - ./test_runner.sh
```

---

## Test Data Cleanup

The test suite creates temporary test data during execution. To manually clean up:

```sql
-- Delete test execution log (optional, for history keeping)
TRUNCATE test_audit.test_execution_log;

-- Drop test schema if needed
DROP SCHEMA IF EXISTS test_audit CASCADE;

-- Verify production schemas are untouched
SELECT schema_name FROM information_schema.schemata 
  WHERE schema_name IN ('audit', 'pii', 'rag');
```

---

## Troubleshooting

### Problem: `psql: FATAL: database does not exist`

**Solution**:
```bash
# Create database if it doesn't exist
createdb postgres

# Or specify correct database
export PGDATABASE=your_actual_database
./test_runner.sh
```

### Problem: `ERROR: permission denied for schema audit`

**Solution**:
```bash
# Run tests as superuser (postgres)
export PGUSER=postgres
./test_runner.sh

# Or grant appropriate permissions
psql -U postgres -c "GRANT USAGE ON SCHEMA audit TO app_user"
```

### Problem: Tests hang or timeout

**Solution**:
1. Check if database is responsive: `psql -U postgres -c "SELECT 1"`
2. Check for long-running queries: `SELECT * FROM pg_stat_activity WHERE state != 'idle'`
3. Kill blocking queries: `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid != pg_backend_pid()`
4. Run tests with smaller scope: `./test_runner.sh --step 1`

### Problem: `schema audit does not exist`

**Solution**:
```bash
# Ensure audit.sql is loaded
psql -U postgres -f audit.sql

# Verify schema was created
psql -U postgres -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'audit'"
```

---

## Test Validation Matrix

Use this checklist to verify test suite completeness:

- [ ] Step 1: Test infrastructure created
- [ ] Step 2: 6 audit settings tests passing
- [ ] Step 3: 8 audit system log tests passing
- [ ] Step 4: 6 PII encryption tests passing
- [ ] Step 5: 5 PII access control tests passing
- [ ] Step 6: 10 RAG configuration tests passing
- [ ] All test execution logs recorded
- [ ] No errors in test output
- [ ] Test suite completes in < 2 minutes
- [ ] test_audit schema isolated from production

**Total Coverage**: 40+ independent SQL tests validating three schemas

---

## Additional Resources

- [TEST_PLAN.md](TEST_PLAN.md) - Detailed implementation plan
- [ARCHITECTURE.md](ARCHITECTURE.md) - Schema design decisions
- [SECURITY.md](SECURITY.md) - Security validation patterns
- [SQL Files](tests/) - Individual test files

---

## Support & Questions

For issues or questions:

1. Check test output carefully for specific error messages
2. Review inline comments in test files
3. Verify database connectivity and permissions
4. Check if all production schemas are properly loaded
5. Review this documentation for troubleshooting steps

