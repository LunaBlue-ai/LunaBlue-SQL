# Multi-Step SQL Testing Plan
**LunaBlue-SQL: Audit, PII, and RAG Schemas**

---

## Executive Summary

This document outlines an incremental, multi-perspective approach to generating SQL-based tests for three critical schemas: audit, pii, and rag. Each step is small, testable, and independently verifiable before proceeding to the next.

**Perspectives Evaluated**:
- ✓ Maintainability: Modular test structure, clear test naming, isolated test functions
- ✓ Testability: Unit-testable assertions, no hidden dependencies, mockable setup
- ✓ Architecture: Separation of concerns, schema isolation, clean test boundaries
- ✓ Security: No test data in production, encryption pattern verification
- ✓ Business Value: Compliance validation, data integrity checks
- ✓ Documentation: Inline comments, test purpose documentation

---

## Step 1: Create Test Schema Foundation
**Status**: Not Started  
**Complexity**: Low  
**Time Estimate**: 30 minutes

### Objective
Create a dedicated `test_audit` schema for isolated test execution without affecting production audit data.

### Perspective Influence
- **Maintainability**: Dedicated test schema prevents test pollution of production data
- **Testability**: Tests can be run in isolation and rolled back without side effects
- **Architecture**: Clear separation between production and test infrastructure
- **Security**: Test data cannot be accidentally committed to production
- **Business Value**: Safe to run comprehensive tests during business hours

### Implementation Steps
1. Create `test_audit` schema with proper authorization
2. Create test metadata table to track test execution history
3. Create helper function to set up and tear down tests atomically
4. Document test execution guidelines

### Testability Strategy
```sql
-- Verify schema exists and is isolated from audit schema
-- Verify helper functions are callable
-- Verify test metadata table accepts records
-- Verify cleanup transactions work correctly
```

### Validation Checklist
- [ ] `test_audit` schema created with proper permissions
- [ ] `test_execution_log` table tracks test runs with timestamps
- [ ] `setup_test_environment()` function works atomically
- [ ] `teardown_test_environment()` function cleans up completely
- [ ] Can verify isolation by comparing `audit` and `test_audit` table counts

---

## Step 2: Audit Schema - Settings Table Tests
**Status**: Not Started  
**Complexity**: Low  
**Time Estimate**: 45 minutes

### Objective
Create isolated unit tests for `audit.settings` table validating configuration management.

### Perspective Influence
- **Testability**: Each test verifies one specific behavior (single responsibility)
- **Maintainability**: Named test functions clearly describe what they test
- **Architecture**: Tests don't depend on other tests or data
- **Security**: Verify that INSERT/DELETE permissions are properly revoked
- **Business Value**: Ensure audit configuration is reliable and immutable

### Test Coverage
| Test | Purpose | Input | Expected Output |
|------|---------|-------|-----------------|
| `test_settings_default_values_exist` | Verify initial settings are loaded | Query `settings` table | 9 rows with correct default values |
| `test_settings_can_update_value` | Verify UPDATE works on enabled columns | Update `retention_days` | Value changes, `updated_at` changes |
| `test_settings_prevents_insert` | Verify PUBLIC cannot INSERT | Attempt INSERT as public role | ERROR: permission denied |
| `test_settings_prevents_delete` | Verify PUBLIC cannot DELETE | Attempt DELETE as public role | ERROR: permission denied |
| `test_settings_type_validation` | Verify CHECK constraint on types | INSERT invalid type | ERROR: constraint violation |
| `test_settings_boolean_parsing` | Verify boolean values stored correctly | Query `enabled` setting | Returns 'true' as varchar |

### Testability Strategy
- Each test runs in isolated transaction that rolls back after completion
- Tests use `ASSERT` statements to verify expected outcomes
- Tests capture `sqlstate` to verify correct error codes

### Validation Checklist
- [ ] All 6 settings tests execute without syntax errors
- [ ] Each test properly rolls back after execution
- [ ] Permission tests verify correct DENIED errors
- [ ] Type validation tests check CHECK constraint behavior

---

## Step 3: Audit Schema - System Log Table Tests
**Status**: Not Started  
**Complexity**: Medium  
**Time Estimate**: 60 minutes

### Objective
Create comprehensive tests for `audit.system_log` table validating append-only audit trail behavior.

### Perspective Influence
- **Testability**: Tests verify immutability, timestamp consistency, JSON validation
- **Maintainability**: Tests modeled as reusable assertion patterns
- **Architecture**: Tests validate append-only contract
- **Security**: Verify UPDATE/DELETE are prevented, audit trail is immutable
- **Business Value**: Compliance requirement - proof that audit cannot be tampered with

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_system_log_insert_creates_record` | Basic INSERT works | Record exists with correct values |
| `test_system_log_timestamp_auto_generated` | Timestamp defaults to NOW() | `created_at` is TIMESTAMPTZ and recent |
| `test_system_log_prevents_update` | UPDATE is blocked | ERROR: relation is append-only |
| `test_system_log_prevents_delete` | DELETE is blocked | ERROR: relation is append-only |
| `test_system_log_jsonb_metadata_valid` | JSONB validation works | Invalid JSON rejected, valid JSON stored |
| `test_system_log_event_severity_validation` | CHECK constraint on severity | Only valid severity levels accepted |
| `test_system_log_user_audit_field_required` | `user_action` cannot be null | Constraint enforces non-null |
| `test_system_log_events_ordered_by_time` | Events maintain chronological order | Query ORDER BY created_at returns proper sequence |

### Testability Strategy
- Use PL/pgSQL functions to wrap each test with setup/teardown
- Verify immutability by attempting write operations and catching exceptions
- Test JSONB with both valid and invalid payloads

### Validation Checklist
- [ ] All 8 system log tests pass without errors
- [ ] Immutability tests properly catch and validate error messages
- [ ] Timestamp tests verify timezone handling (TIMESTAMPTZ)
- [ ] JSONB tests validate with both valid/invalid payloads

---

## Step 4: PII Schema - Encryption Configuration Tests
**Status**: Not Started  
**Complexity**: Low  
**Time Estimate**: 45 minutes

### Objective
Create tests validating encryption configuration table structure and security constraints.

### Perspective Influence
- **Security**: Verify encryption configuration is properly secured
- **Testability**: Test encryption metadata without exposing actual keys
- **Maintainability**: Clear test structure for encryption validation
- **Business Value**: Compliance verification (GDPR, HIPAA require encryption validation)
- **Architecture**: Tests verify encryption abstraction layer

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_encryption_config_defaults_exist` | Initial configs loaded | 3 rows with correct algorithms |
| `test_encryption_config_algorithm_validation` | Only allowed algorithms | Supported values: AES-256-GCM, Bcrypt |
| `test_encryption_config_key_version_required` | Version tracking enforced | key_version NOT NULL and >= 1 |
| `test_encryption_config_rotation_interval_valid` | Rotation policy configured | Intervals in days, NULL for no rotation |
| `test_encryption_config_enabled_flag` | Enable/disable encryption | enabled boolean flag works |
| `test_encryption_config_expiration_logic` | Key expiration timestamps | expires_at can be null or future date |

### Testability Strategy
- Test configuration metadata without requiring actual KMS/Vault access
- Verify constraints and data types
- Mock key_id values (they point to external KMS)

### Validation Checklist
- [ ] All 6 encryption config tests pass
- [ ] No tests expose or reference actual encryption keys
- [ ] Tests verify structure but not cryptographic implementation

---

## Step 5: PII Schema - PII Categories and Access Control Tests
**Status**: Not Started  
**Complexity**: Medium  
**Time Estimate**: 60 minutes

### Objective
Create tests validating PII category enum and row-level security patterns.

### Perspective Influence
- **Security**: Verify access control is properly implemented
- **Testability**: Test RLS policies in isolation
- **Maintainability**: Clear test structure for security policies
- **Business Value**: GDPR compliance - proof of data minimization and access control
- **Documentation**: Test comments explain RLS policy enforcement

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_pii_categories_enum_exists` | Enum type properly created | All 9 categories present |
| `test_pii_categories_valid_values` | Only valid categories allowed | Invalid category INSERT rejected |
| `test_pii_access_control_rls_enabled` | Row-level security enforced | RLS policies prevent unauthorized access |
| `test_pii_sensitive_field_encryption_marked` | Encrypted fields identified | Metadata indicates encryption status |
| `test_pii_access_audit_trail` | Access logged for compliance | SELECT on PII creates audit record |

### Testability Strategy
- Test enum with valid and invalid values
- Create test users with different roles to verify RLS
- Verify audit logging of PII access

### Validation Checklist
- [ ] Enum tests verify all 9 PII categories
- [ ] RLS tests use multiple roles to verify enforcement
- [ ] Access audit tests confirm logging occurs

---

## Step 6: RAG Schema - Configuration and Documents Table Tests
**Status**: Not Started  
**Complexity**: Medium  
**Time Estimate**: 60 minutes

### Objective
Create tests validating RAG configuration and document management without requiring vector embeddings.

### Perspective Influence
- **Testability**: Document lifecycle independent of embedding engine
- **Maintainability**: Clear test structure for RAG patterns
- **Architecture**: Separate concerns: document management vs. vector storage
- **Business Value**: RAG pipeline reliability
- **Documentation**: Tests explain document processing workflow

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_rag_config_defaults_exist` | Configuration loaded | 8 config rows with correct defaults |
| `test_rag_config_embedding_model_valid` | Embedding model defined | Model name, dimensions, provider set |
| `test_rag_config_chunk_parameters_valid` | Chunking parameters configured | chunk_size, overlap, top_k set |
| `test_rag_config_index_parameters_valid` | Index tuning parameters | hnsw_ef_construction, hnsw_m set |
| `test_rag_documents_insert_creates_record` | Document creation works | Record created with status='processing' |
| `test_rag_documents_status_validation` | Status enum enforced | Only valid statuses: uploaded, processing, ready, failed |
| `test_rag_documents_timestamp_auto_generated` | created_at auto-set | Timestamp defaults to NOW() |
| `test_rag_documents_metadata_jsonb_valid` | Metadata JSONB stored | Valid JSON stored, invalid rejected |
| `test_rag_documents_language_default` | Language defaults to 'en' | Insert without language_code = 'en' |
| `test_rag_documents_indexes_exist` | All indexes created | 4 indexes on status, source, language, created_at |

### Testability Strategy
- Test configuration independently from embedding generation
- Test document lifecycle: inserted → processing → ready/failed
- Verify indexes improve query performance

### Validation Checklist
- [ ] All 10 RAG tests pass without errors
- [ ] Configuration tests verify all 8 config entries
- [ ] Document tests verify complete lifecycle
- [ ] Index tests confirm indexes exist and are usable

---

## Step 7: Integration Tests - Cross-Schema Audit Validation
**Status**: Not Started  
**Complexity**: High  
**Time Estimate**: 90 minutes

### Objective
Create integration tests verifying that audit logging captures PII access and RAG operations.

### Perspective Influence
- **Architecture**: Verify schema interactions work correctly
- **Security**: Prove that sensitive operations are logged
- **Business Value**: Compliance validation - audit trail for sensitive data
- **Testability**: Integration tests verify end-to-end workflows
- **Maintainability**: Clear documentation of schema dependencies

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_pii_access_triggers_audit_log` | PII SELECT logged | audit.system_log contains PII read event |
| `test_rag_document_insert_logged` | Document creation audited | audit.system_log records INSERT |
| `test_audit_settings_change_logged` | Config changes audited | UPDATE on audit.settings logged |
| `test_audit_log_immutability_across_schemas` | Cannot alter audit from other schema | Attempt UPDATE on audit.system_log fails |
| `test_audit_captures_dml_operations` | INSERT/UPDATE/DELETE captured | All DML operations create audit records |

### Testability Strategy
- Insert test data into pii/rag schemas
- Query audit.system_log to verify logging occurred
- Verify audit records contain correct event details
- Test both successful and failed operations

### Validation Checklist
- [ ] All 5 integration tests pass
- [ ] Audit records correctly reference source schema
- [ ] Timestamps are correlated between schemas
- [ ] Failed operations are also logged for security

---

## Step 8: Edge Case and Error Handling Tests
**Status**: Not Started  
**Complexity**: High  
**Time Estimate**: 120 minutes

### Objective
Create comprehensive tests for edge cases, boundary conditions, and error scenarios.

### Perspective Influence
- **Testability**: Edge cases prevent production bugs
- **Maintainability**: Clear documentation of expected behavior
- **Security**: Error handling cannot expose sensitive data
- **Business Value**: Reliability under stress
- **Architecture**: Graceful degradation patterns

### Test Coverage
| Test | Purpose | Validation |
|------|---------|-----------|
| `test_audit_settings_unicode_characters` | UTF-8 handling in description | Unicode stored and retrieved correctly |
| `test_pii_encryption_config_missing_key_id` | Null key_id allowed | External KMS key reference optional |
| `test_rag_documents_large_content_storage` | Large documents handled | Can store > 1MB content |
| `test_rag_documents_null_optional_fields` | Optional fields nullable | error_message, processed_at can be NULL |
| `test_audit_concurrent_writes_handled` | Concurrent inserts don't corrupt | Multiple simultaneous INSERTs succeed |
| `test_timestamp_timezone_consistency` | All timestamps use UTC | TIMESTAMPTZ ensures UTC |
| `test_jsonb_deeply_nested_metadata` | Complex JSON structures | Deeply nested JSONB parsed correctly |
| `test_empty_string_vs_null_distinction` | Empty string != NULL | '' and NULL handled differently |
| `test_index_query_performance` | Indexed queries are fast | EXPLAIN shows index usage |
| `test_constraint_violation_messages` | Errors are informative | CHECK violations show constraint name |

### Testability Strategy
- Generate test data with boundary values
- Test with unicode, emoji, special characters
- Use EXPLAIN to verify index usage
- Simulate concurrent access patterns

### Validation Checklist
- [ ] All 10 edge case tests pass
- [ ] Performance tests show index usage
- [ ] Error messages don't expose sensitive data
- [ ] Concurrent access tests use parallelism

---

## Step 9: Performance and Scalability Baseline Tests
**Status**: Not Started  
**Complexity**: High  
**Time Estimate**: 90 minutes

### Objective
Establish performance baselines and verify scalability under load.

### Perspective Influence
- **Business Value**: System must support production scale
- **Testability**: Performance tests detect regressions
- **Maintainability**: Baseline documents expected performance
- **Architecture**: Identify scaling bottlenecks

### Test Coverage
| Test | Purpose | Measurement |
|------|---------|------------|
| `test_audit_log_write_performance` | Single INSERT latency | < 10ms for append operations |
| `test_audit_log_read_performance_indexed` | Indexed SELECT performance | < 50ms for time-range query |
| `test_rag_document_bulk_insert_performance` | Bulk document loading | 1000 docs in < 5 seconds |
| `test_rag_index_performance_with_scale` | Index effectiveness at scale | Index is used, sequential scan avoided |
| `test_pii_encryption_config_query_performance` | Metadata lookup speed | < 5ms for single row lookup |

### Testability Strategy
- Use `pg_stat_statements` to capture execution plans
- Measure elapsed time with microsecond precision
- Generate realistic data volumes (1000+ rows)
- Document baseline results

### Validation Checklist
- [ ] All performance tests establish baseline metrics
- [ ] Results recorded in test report
- [ ] No obvious performance bottlenecks identified
- [ ] Indexes verified to be used by query planner

---

## Step 10: Documentation and Test Runner Setup
**Status**: Not Started  
**Complexity**: Medium  
**Time Estimate**: 60 minutes

### Objective
Create comprehensive test documentation and automated test runner script.

### Perspective Influence
- **Documentation**: Clear test execution instructions
- **Maintainability**: Test runner is repeatable and reliable
- **Testability**: Automated execution prevents manual errors
- **Business Value**: Continuous testing in CI/CD pipeline

### Deliverables
1. **test_audit_schema.sql** - Complete audit schema tests
2. **test_pii_schema.sql** - Complete PII schema tests
3. **test_rag_schema.sql** - Complete RAG schema tests
4. **test_integration.sql** - Cross-schema integration tests
5. **test_runner.sh** - Bash script to execute all tests
6. **TEST_RESULTS_REPORT.md** - Test execution summary
7. **TEST_EXECUTION_GUIDELINES.md** - How to run tests

### Validation Checklist
- [ ] All test files have proper header comments
- [ ] Test runner script is executable and idempotent
- [ ] README documents how to execute all tests
- [ ] Report template captures pass/fail/error metrics

---

## Execution Order & Dependencies

```
┌─────────────────────────────────────────────────────────────────┐
│ Step 1: Test Schema Foundation                                  │
│ (Prerequisite for all other steps)                              │
└──────────────────────────────┬──────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│ Step 2: Audit     │ │ Step 4: PII       │ │ Step 6: RAG       │
│ Settings Tests    │ │ Encryption Tests  │ │ Config Tests      │
└─────────┬─────────┘ └─────────┬─────────┘ └─────────┬─────────┘
          │                     │                     │
          ▼                     ▼                     ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│ Step 3: Audit     │ │ Step 5: PII       │ │ (Already done)    │
│ System Log Tests  │ │ Access Tests      │ │ in Step 6         │
└─────────┬─────────┘ └─────────┬─────────┘ └──────────────────┘
          │                     │
          └──────────────────────┼──────────────────┐
                                 │                  │
                                 ▼                  ▼
                        ┌──────────────────────────────────┐
                        │ Step 7: Integration Tests        │
                        │ (Depends on Steps 2-6)          │
                        └──────────────┬──────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
                    ▼                  ▼                  ▼
            ┌────────────────┐ ┌────────────────┐ ┌─────────────────┐
            │ Step 8: Edge   │ │ Step 9: Perf   │ │ Step 10: Docs   │
            │ Cases          │ │ Baseline       │ │ & Runner        │
            └────────────────┘ └────────────────┘ └─────────────────┘
```

---

## Quality Metrics

### Coverage Goals
- **audit.settings**: 100% coverage (6 tests)
- **audit.system_log**: 100% coverage (8 tests)
- **pii.encryption_config**: 100% coverage (6 tests)
- **pii.pii_categories**: 100% coverage (5 tests)
- **rag.schema_config**: 100% coverage (4 tests)
- **rag.documents**: 100% coverage (6 tests)
- **Integration**: All schema interactions (5 tests)
- **Edge Cases**: 10 tests for boundary conditions
- **Performance**: 5 performance baseline tests

**Total Test Count**: ~55 SQL tests

### Pass/Fail Criteria
- ✓ All tests must pass on clean schema
- ✓ All tests must be idempotent (safe to run multiple times)
- ✓ All tests must clean up after themselves (no data pollution)
- ✓ All tests must execute in < 5 minutes total
- ✓ No test may modify production audit data

---

## Risk Mitigation

| Risk | Mitigation | Responsible Step |
|------|-----------|-----------------|
| Tests corrupt production data | Use isolated `test_` schema | Step 1 |
| Tests have hidden dependencies | Document all dependencies | Each step |
| Tests are hard to debug | Clear test names + comments | Each step |
| Performance issues undetected | Baseline performance tests | Step 9 |
| Missing documentation | Generate comprehensive guide | Step 10 |

---

## Next Steps

1. **Review this plan** with stakeholders
2. **Execute Step 1** to create test infrastructure
3. **Proceed incrementally** through steps 2-6
4. **Validate integration** in step 7
5. **Execute edge cases** in step 8
6. **Establish baselines** in step 9
7. **Automate execution** in step 10
8. **Integrate into CI/CD** pipeline

