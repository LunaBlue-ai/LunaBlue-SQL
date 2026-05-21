# PostgreSQL Multi-Schema Architecture Documentation

## Executive Summary

This document provides a comprehensive architectural overview of the LunaBlue-SQL PostgreSQL database system. It explains the design decisions for supporting three critical business functions within a single PostgreSQL 16 instance using schema separation:

1. **Audit Logging** - Append-only security event logging
2. **PII Storage** - Temporary encrypted sensitive data management
3. **RAG (Retrieval-Augmented Generation)** - Vector embedding storage for LLM integration

---

## 1. Architectural Overview

### 1.1 System Context Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application Layer                       │
│  (Your microservices, APIs, and business logic)                 │
└──────────┬──────────────────────────────────────────────┬───────┘
           │                                              │
      ┌────▼────────────────────────────────────────────▼─────┐
      │          PostgreSQL 16 with pgvector Extension         │
      │                                                         │
      │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
      │  │   AUDIT      │  │     PII      │  │     RAG      │ │
      │  │   SCHEMA     │  │    SCHEMA    │  │    SCHEMA    │ │
      │  │              │  │              │  │              │ │
      │  │ • system_log │  │ • encryption │  │ • documents  │ │
      │  │ • settings   │  │ • categories │  │ • chunks     │ │
      │  │              │  │ • users      │  │ • embeddings │ │
      │  └──────────────┘  └──────────────┘  └──────────────┘ │
      │                                                         │
      │  ┌──────────────────────────────────────────────────┐  │
      │  │   Shared Infrastructure (Backups, Replication)   │  │
      │  └──────────────────────────────────────────────────┘  │
      └─────────────────────────────────────────────────────────┘
```

### 1.2 Design Philosophy: Schema Separation

**Core Principle**: One PostgreSQL instance, three isolated schemas, each optimized for its specific use case.

**Rationale**:
- **Simplicity**: Single database instance to manage
- **Shared Infrastructure**: Common backup/replication strategy
- **Security Boundaries**: Schema-level access control
- **Resource Efficiency**: Shared connection pools, shared memory
- **Operational Consistency**: One version of PostgreSQL, one set of extensions

---

## 2. Schema Architecture

### 2.1 AUDIT Schema

**Purpose**: Tamper-proof, append-only logging of all security events and compliance-relevant operations.

**Core Tables**:

```
audit.system_log
├── id (BIGSERIAL PK)
├── user_action (VARCHAR, NOT NULL)
├── severity_level (VARCHAR, CHECK constraint)
├── event_type (VARCHAR)
├── source_table (VARCHAR)
├── description (TEXT)
├── metadata (JSONB)
└── created_at (TIMESTAMPTZ, auto-populated)

audit.settings
├── setting_name (VARCHAR PK)
├── setting_value (VARCHAR)
├── setting_type (VARCHAR)
└── timestamps
```

**Design Decisions**:

| Decision | Rationale | Perspective Influenced |
|----------|-----------|------------------------|
| Append-only (no UPDATE/DELETE) | Immutable audit trail prevents tampering | Security, Business Value |
| JSONB metadata | Flexible event data without schema changes | Maintainability, Architecture |
| TIMESTAMPTZ | UTC consistency across timezones | Compliance, Testability |
| Row-level security policies | Fine-grained access control | Security |
| Partitioning ready | Supports high-volume logging | Architecture, Business Value |

**Access Pattern**:
- Application writes events only via INSERT
- Admin reads via time-range queries
- No modification allowed (immutable)

### 2.2 PII Schema

**Purpose**: Temporary storage of sensitive personally identifiable information with field-level encryption support.

**Core Tables**:

```
pii.encryption_config
├── config_key (VARCHAR PK)
├── algorithm (VARCHAR)
├── key_id (VARCHAR, points to KMS/Vault)
├── key_version (INTEGER)
└── enabled (BOOLEAN)

pii.pii_categories (ENUM type)
├── person_name
├── email_address
├── phone_number
├── physical_address
├── social_security
├── financial_account
├── biometric
├── health_record
└── ip_address (context-dependent)
```

**Design Decisions**:

| Decision | Rationale | Perspective Influenced |
|----------|-----------|------------------------|
| External key storage | Never store encryption keys in database | Security |
| Encryption metadata table | Track which fields are encrypted | Security, Compliance |
| PII categories enum | Enforce consistent PII classification | Testability, Documentation |
| Schema separation | Isolate sensitive data from application schema | Security, Architecture |
| Row-level security | Database-enforced access control | Security |

**Access Pattern**:
- Keys managed externally (AWS KMS, Azure Key Vault, HashiCorp Vault)
- Database stores only encryption metadata
- Application handles encrypt/decrypt operations
- RLS policies limit access by role

### 2.3 RAG Schema

**Purpose**: Store document chunks and vector embeddings for retrieval-augmented generation LLM integration.

**Core Tables**:

```
rag.documents
├── document_id (BIGSERIAL PK)
├── title (VARCHAR)
├── content (TEXT)
├── source_url (VARCHAR)
├── source_type (VARCHAR: pdf, docx, html, text)
├── metadata (JSONB)
├── language (VARCHAR, default 'en')
├── status (VARCHAR: uploaded, processing, ready, failed)
├── error_message (TEXT, nullable)
├── created_at (TIMESTAMPTZ)
└── processed_at (TIMESTAMPTZ, nullable)

rag.chunks
├── chunk_id (BIGSERIAL PK)
├── document_id (BIGINT FK)
├── chunk_text (TEXT)
├── chunk_position (INTEGER)
└── metadata (JSONB)

rag.embeddings (with pgvector)
├── embedding_id (BIGSERIAL PK)
├── chunk_id (BIGINT FK)
├── vector (vector(384))
├── model (VARCHAR)
├── created_at (TIMESTAMPTZ)
└── indexes (HNSW/IVFFLAT for similarity search)

rag.schema_config
├── config_key (VARCHAR PK)
├── config_value (JSONB)
└── description (VARCHAR)
```

**Design Decisions**:

| Decision | Rationale | Perspective Influenced |
|----------|-----------|------------------------|
| pgvector extension | Production-grade vector similarity search | Architecture, Business Value |
| Vector indexing (HNSW) | Fast approximate nearest neighbor search | Business Value, Performance |
| Separation of documents/chunks | Flexible document processing | Architecture, Maintainability |
| Status lifecycle | Track document processing progress | Business Value, Testability |
| Language metadata | Support multi-language RAG | Business Value |
| JSONB config | Flexible embedding model configuration | Maintainability, Architecture |

**Access Pattern**:
- Documents inserted as they arrive (status='uploaded')
- Chunking service processes to 'processing' state
- Embeddings generated via external service
- Indexed for similarity search (ready state)
- Queries use vector distance metrics

---

## 3. Architecture Patterns

### 3.1 Schema Isolation Pattern

Each schema is a **separate concern**:

```sql
-- Audit: Historical, immutable, compliance-focused
SELECT * FROM audit.system_log WHERE created_at > NOW() - INTERVAL '7 days';

-- PII: Temporary, encrypted, access-controlled
SELECT * FROM pii.encryption_config WHERE enabled = TRUE;

-- RAG: High-volume, vector-indexed, embedding-focused
SELECT * FROM rag.documents WHERE status = 'ready' LIMIT 100;
```

**Benefits**:
- Applications can query only their schema
- Security policies applied per-schema
- Different index strategies per use case
- Clear data ownership and lifecycle

### 3.2 Configuration-as-Data Pattern

Settings stored in tables, not environment variables:

```sql
-- AUDIT settings
INSERT INTO audit.settings (setting_name, setting_value, setting_type)
VALUES ('retention_days', '365', 'integer');

-- PII encryption configuration
INSERT INTO pii.encryption_config (config_key, algorithm, enabled)
VALUES ('standard_aes_256', 'AES-256-GCM', TRUE);

-- RAG model configuration
INSERT INTO rag.schema_config (config_key, config_value)
VALUES ('embedding_model', '{"name": "all-MiniLM-L6-v2", "dimensions": 384}');
```

**Rationale**:
- Configuration is queryable and auditable
- Can be changed without application restart
- Each schema owns its configuration
- Single source of truth in database

### 3.3 Append-Only Pattern (AUDIT only)

```sql
-- CREATE RULE prevents UPDATE/DELETE
CREATE RULE audit_no_update AS ON UPDATE TO audit.system_log
    DO INSTEAD NOTHING;

CREATE RULE audit_no_delete AS ON DELETE FROM audit.system_log
    DO INSTEAD NOTHING;
```

**This ensures**:
- Audit trail cannot be modified after creation
- Compliance requirement: tamper-proof logging
- Forensic capability: complete history preserved

---

## 4. Database Design Decisions

### 4.1 Why PostgreSQL 16?

| Feature | Benefit | Perspective |
|---------|---------|------------|
| JSONB support | Flexible metadata storage | Architecture, Maintainability |
| pgvector extension | Native vector similarity search | Business Value |
| Row-level security | Database-level access control | Security |
| TIMESTAMPTZ | Timezone-aware timestamps | Compliance, Testability |
| Partitioning capability | Handle high-volume audit logs | Business Value, Architecture |
| Advanced indexing (BRIN, HASH) | Optimize different access patterns | Architecture |

### 4.2 Why Schema Separation (Not Multiple Databases)?

**Schema Separation:**
- ✅ Simpler operational model (one pg_dump, one backup strategy)
- ✅ Shared infrastructure (connection pooling, shared memory)
- ✅ Easy cross-schema transactions if needed
- ✅ Single PostgreSQL version to manage
- ✅ Can add more schemas later without restructuring

**Alternative: Multiple Databases:**
- ❌ Separate backup strategies
- ❌ Separate security patches
- ❌ Separate connection pool management
- ❌ Cross-database transactions are harder
- ✅ Complete isolation (if needed in future)

**Decision**: Schema separation is optimal for current requirements.

### 4.3 Timestamp Strategy

All timestamps use **TIMESTAMPTZ** (with timezone):

```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

**Rationale**:
- Ensures UTC consistency across systems
- Can display in user's local timezone on client
- Prevents timezone conversion bugs
- Compliance requirement for audit trails

### 4.4 Data Types

| Schema | Data Type | Rationale |
|--------|-----------|-----------|
| AUDIT | JSONB (metadata) | Flexible event data, queryable |
| AUDIT | TIMESTAMPTZ | UTC timestamps, timezone-aware |
| PII | TEXT (field names, algorithms) | Security doesn't require strict type |
| PII | BOOLEAN (flags) | Simple enable/disable |
| RAG | TEXT (content) | Flexible document storage |
| RAG | vector (pgvector) | Native vector similarity |
| RAG | JSONB (config) | Model configuration |

---

## 5. Security Architecture

### 5.1 Defense in Depth

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Network Security                              │
│  • PostgreSQL port not exposed to internet               │
│  • Private subnet in container orchestration             │
└─────────────────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────────────────┐
│  Layer 2: Authentication                                │
│  • Database roles with specific permissions              │
│  • Application user has minimal privileges               │
│  • Postgres superuser isolated                           │
└─────────────────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Authorization                                 │
│  • Schema-level access control                          │
│  • Row-level security policies                          │
│  • Column-level grants (future)                         │
└─────────────────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────────────────┐
│  Layer 4: Data Protection                               │
│  • Encryption keys stored externally (KMS/Vault)        │
│  • Database stores only encryption metadata              │
│  • Application handles encrypt/decrypt                  │
└─────────────────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────────────────┐
│  Layer 5: Audit & Compliance                            │
│  • Immutable audit log (append-only)                    │
│  • All modifications logged                              │
│  • Compliance reporting queries                         │
└─────────────────────────────────────────────────────────┘
```

### 5.2 Role-Based Access Control

**Three roles per schema**:

```
┌────────────────────────────────────────────────────────┐
│  AUDIT Schema Roles                                    │
├────────────────────────────────────────────────────────┤
│ audit_writer   → Can INSERT audit events               │
│ audit_reader   → Can SELECT from audit tables          │
│ audit_admin    → Can modify audit settings             │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│  PII Schema Roles                                      │
├────────────────────────────────────────────────────────┤
│ pii_writer     → Can INSERT/UPDATE PII data            │
│ pii_reader     → Can SELECT PII data (RLS filters)     │
│ pii_admin      → Can modify encryption config          │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│  RAG Schema Roles                                      │
├────────────────────────────────────────────────────────┤
│ rag_writer     → Can INSERT documents/embeddings       │
│ rag_reader     → Can SELECT for similarity search      │
│ rag_admin      → Can modify config                     │
└────────────────────────────────────────────────────────┘
```

**Principle**: Least privilege - each role has minimum required permissions.

### 5.3 Encryption Strategy

**PII Data**:
- Encryption keys **never stored in database**
- Keys stored in external KMS (AWS KMS, Azure Key Vault, HashiCorp Vault)
- Database stores only key IDs and metadata
- Application layer handles encrypt/decrypt
- Supports key rotation without database changes

**Audit Data**:
- No encryption needed (events are not sensitive)
- Immutability is more important than confidentiality
- Can be backed up/replicated in clear

**RAG Data**:
- Document content may be encrypted by application
- Vector embeddings typically not encrypted (derived from content)
- Source URLs can be logged in audit trail

---

## 6. Performance Architecture

### 6.1 Index Strategy

| Schema | Table | Index | Rationale |
|--------|-------|-------|-----------|
| AUDIT | system_log | created_at (DESC) | Time-range queries for compliance reports |
| AUDIT | system_log | (user_action, created_at) | Find events by user in time range |
| AUDIT | system_log | severity_level | Quickly find critical events |
| PII | encryption_config | config_key (PK) | Fast lookup of encryption settings |
| RAG | documents | status | Query processing queue |
| RAG | documents | created_at (DESC) | Recent documents first |
| RAG | documents | language | Filter by language |
| RAG | embeddings | (chunk_id, vector) | HNSW index for similarity search |

### 6.2 Query Patterns

**AUDIT**:
```sql
-- Time-range query (indexed)
SELECT * FROM audit.system_log 
WHERE created_at BETWEEN $1 AND $2
ORDER BY created_at DESC;

-- Severity filtering (indexed)
SELECT * FROM audit.system_log
WHERE severity_level = 'CRITICAL'
AND created_at > NOW() - INTERVAL '24 hours';
```

**PII**:
```sql
-- Config lookup (fast)
SELECT * FROM pii.encryption_config
WHERE config_key = $1;

-- Active encryptions (indexed)
SELECT * FROM pii.encryption_config
WHERE enabled = TRUE;
```

**RAG**:
```sql
-- Vector similarity search (HNSW index)
SELECT chunk_id, 1 - (vector <=> $1) AS similarity
FROM rag.embeddings
ORDER BY vector <=> $1
LIMIT 10;

-- Processing queue
SELECT document_id FROM rag.documents
WHERE status = 'uploaded'
ORDER BY created_at
LIMIT 100;
```

### 6.3 Partitioning Strategy (Future)

For high-volume audit logging, consider partitioning:

```sql
-- Partition by time (yearly or monthly)
CREATE TABLE audit.system_log_2024_q1 PARTITION OF audit.system_log
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

-- Partition by range maintains immutability
-- Old partitions can be archived/compressed
```

---

## 7. Perspective Evaluation

### 7.1 Maintainability ✓

**Design Choices**:
- **Schema separation** makes each area independently maintainable
- **Configuration-as-data** reduces hardcoded values
- **JSONB flexibility** avoids schema migrations
- **Clear naming conventions** (e.g., `pii_categories` enum)

**Tradeoffs**:
- Learning curve for developers (3 schemas)
- Documentation essential for consistent usage

### 7.2 Testability ✓

**Design Choices**:
- **Isolated schemas** allow independent testing
- **Append-only audit** easy to verify immutability
- **Status lifecycle** in RAG allows testing state transitions
- **RLS policies** testable in isolation

**Tradeoffs**:
- Requires test database setup
- RLS policies need multiple roles to test fully

### 7.3 Architecture Design ✓

**Design Choices**:
- **Single PostgreSQL instance** simplifies operations
- **Schema separation** provides logical boundaries
- **Configuration tables** enable runtime changes
- **Indexes aligned with queries** optimize access patterns

**Tradeoffs**:
- Not suitable for extreme scale (100k+ writes/sec)
- Cross-schema transactions have performance cost

### 7.4 Security Standards ✓

**Design Choices**:
- **Append-only audit** ensures tamper-proof logging
- **External key storage** keeps encryption keys secure
- **RLS policies** enforce database-level access control
- **Role-based access** implements least privilege

**Tradeoffs**:
- Key management complexity (requires KMS/Vault)
- RLS policies require careful testing

### 7.5 Business Value ✓

**Design Choices**:
- **High-volume audit support** (partitioning ready)
- **PII encryption support** (GDPR, HIPAA compliance)
- **RAG vector storage** (LLM integration ready)
- **Configuration flexibility** (no application redeploy needed)

**Tradeoffs**:
- Initial setup more complex than single-table database
- Operational complexity of managing 3 schemas

### 7.6 Documentation Quality ✓

**Design Choices**:
- **Inline SQL comments** explain constraints
- **Architecture documentation** (this file)
- **Schema design documentation** (separate file)
- **Security documentation** (SECURITY.md)

**Tradeoffs**:
- Extensive documentation required
- Documentation must stay in sync with code

---

## 8. Disaster Recovery & Backup Strategy

### 8.1 Backup Approach

**Daily backups** using `pg_dump`:

```bash
# Full backup
pg_dump -U postgres -d postgres -Fc -f /backups/lunablue_$(date +%Y%m%d).dump

# Restore from backup
pg_restore -U postgres -d postgres -Fc /backups/lunablue_20260520.dump
```

**Rationale**:
- Audit schema: immutable, low change rate
- PII schema: small, critical data (encrypt at rest)
- RAG schema: large, can be regenerated

### 8.2 Point-in-Time Recovery

Enable WAL archiving for PITR:

```ini
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /mnt/wal-archive/%f && cp %p /mnt/wal-archive/%f'
```

**This enables**:
- Recovery to any point in time
- Replication to standby servers
- Disaster recovery procedures

### 8.3 Replication Strategy (Optional)

For production:
```
Primary (writes) → Streaming replication → Standby (reads)
```

---

## 9. Migration Path

### Phase 1: Development
- Single PostgreSQL instance
- Three schemas for separation
- Basic security (role-based access)

### Phase 2: Testing
- Add backup/restore procedures
- Enable audit logging
- Test RLS policies

### Phase 3: Production
- Enable WAL archiving
- Configure replication
- Implement monitoring and alerting
- Key management system integration

### Phase 4: Scale (if needed)
- Partition audit logs by time
- Read replicas for RAG similarity search
- Dedicated RAG cluster if embedding volume grows

---

## 10. Summary Table: Architecture Decisions

| Decision | Rationale | Perspective | Tradeoff |
|----------|-----------|-------------|----------|
| PostgreSQL 16 | Native JSONB, pgvector, RLS | All | Requires pg_config knowledge |
| Schema separation | Logical boundaries, security zones | Architecture, Security | Learning curve |
| Append-only audit | Tamper-proof compliance | Security, Business | Storage overhead |
| External key storage | Keys never in database | Security | KMS/Vault dependency |
| pgvector for RAG | Native vector similarity | Architecture, Business | Dependency on pgvector |
| JSONB config | Flexible, no migrations | Maintainability | Requires validation logic |
| TIMESTAMPTZ | UTC consistency | Compliance, Testing | Timezone conversion needed |
| Role-based access | Least privilege enforcement | Security | Operational complexity |

---

## 11. Next Steps

1. **Review Schema Files**: `audit.sql`, `pii.sql`, `rag.sql`
2. **Review Initialization**: `init_all.sql`, `init-pgvector.sql`
3. **Review Docker Setup**: `Dockerfile`, `docker-compose.yml`
4. **Review Security Policies**: `SECURITY.md`
5. **Review Operations**: `OPERATIONS_RUNBOOK.md`

---

**Last Updated**: May 20, 2026  
**Version**: 1.0  
**Status**: Complete

