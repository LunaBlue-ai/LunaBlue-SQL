# Schema Design: LunaBlue-SQL

## Executive Summary

The LunaBlue-SQL database uses a three-schema architecture that logically separates concerns while residing in a single PostgreSQL instance. This design provides security boundaries, specialized index strategies, and clear operational ownership.

---

## Table of Contents

1. [Schema Overview](#1-schema-overview)
2. [Audit Schema](#2-audit-schema)
3. [PII Schema](#3-pii-schema)
4. [RAG Schema](#4-rag-schema)
5. [Cross-Schema Design](#5-cross-schema-design)
6. [Data Type Rationale](#6-data-type-rationale)
7. [Indexing Strategy](#7-indexing-strategy)
8. [Security Design](#8-security-design)
9. [Performance Characteristics](#9-performance-characteristics)

---

## 1. Schema Overview

### 1.1 Architecture Diagram

```
┌────────────────────────────────────────────────────────────┐
│                    PostgreSQL Database                     │
│                  (Single Instance, 3 Schemas)               │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  AUDIT SCHEMA   │  │   PII SCHEMA    │  │ RAG SCHEMA  │ │
│  │ (Compliance)    │  │  (Privacy)      │  │ (Vectors)   │ │
│  │                 │  │                 │  │             │ │
│  │ • system_log    │  │ • enc_config    │  │ • documents │ │
│  │ • settings      │  │ • pii_categories│  │ • chunks    │ │
│  │                 │  │ • (RLS ready)   │  │ • embeddings│ │
│  │ (Immutable)     │  │ (Encrypted)     │  │ • schema_cfg│ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│                                                             │
│  PUBLIC SCHEMA (utility functions, enums)                  │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

### 1.2 Schema Characteristics

| Aspect | Audit | PII | RAG |
|--------|-------|-----|-----|
| **Purpose** | Immutable event log | Private data mgmt | Vector embeddings |
| **Write Pattern** | Append-only | CRUD (guarded) | Insert-heavy |
| **Key Index Type** | BTREE on timestamp | Hashed keys | HNSW vectors |
| **Retention** | 1+ years | Lifecycle-based | Document-based |
| **Scale** | High volume (million events/day) | Low volume (thousands) | Moderate (thousands docs) |
| **Access** | Read-mostly | Encrypted | Read-heavy |

---

## 2. Audit Schema

### 2.1 Schema Purpose & Design

**Purpose**: Immutable, append-only audit trail for compliance and forensics.

**Design Decision**: 
- Separate schema isolates audit tables from application tables
- Prevents accidental data modification
- Simplifies compliance reporting
- Enables specialized indexing strategy

**Perspective Rationale**:
- **Compliance**: Audit trail for GDPR, HIPAA, PCI-DSS, SOC2
- **Security**: Prevents modification of audit records (no DELETE, no UPDATE)
- **Operations**: Easy to back up and archive independently
- **Architecture**: Single schema for all audit data, simplified permissions
- **Performance**: Specialized indexes for time-series queries
- **Maintainability**: Clear purpose, easy to understand

---

### 2.2 audit.settings Table

**Purpose**: Configuration state for audit behavior and system settings.

```sql
CREATE TABLE audit.settings (
    id INTEGER PRIMARY KEY,
    setting_key VARCHAR(100) NOT NULL UNIQUE,
    setting_value VARCHAR(1000) NOT NULL,
    data_type VARCHAR(50) NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by VARCHAR(100) DEFAULT 'SYSTEM'
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | INTEGER | PRIMARY KEY | Immutable identifier |
| `setting_key` | VARCHAR(100) | UNIQUE, NOT NULL | Config key (e.g., "RETENTION_DAYS") |
| `setting_value` | VARCHAR(1000) | NOT NULL | Config value (type-agnostic string) |
| `data_type` | VARCHAR(50) | NOT NULL | Semantic type: INTEGER, BOOLEAN, INTERVAL |
| `description` | TEXT | | Human-readable explanation |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | Audit timestamp |
| `updated_by` | VARCHAR(100) | DEFAULT 'SYSTEM' | Who changed the setting |

**Default Settings** (populated on init):

```sql
INSERT INTO audit.settings (setting_key, setting_value, data_type, description) VALUES
('RETENTION_DAYS', '365', 'INTEGER', 'How long to keep audit logs'),
('MAX_BATCH_SIZE', '1000', 'INTEGER', 'Batch size for bulk operations'),
('ENABLE_DEBUG_LOGGING', 'false', 'BOOLEAN', 'Enable verbose audit logging'),
('ENCRYPTION_ALGORITHM', 'AES-256', 'STRING', 'Default encryption for PII'),
('LOG_ROTATION_SIZE_MB', '100', 'INTEGER', 'Size before log file rotation'),
('ALERT_THRESHOLD', '1000', 'INTEGER', 'Events per hour triggering alert'),
('BACKUP_SCHEDULE', '0 2 * * *', 'CRON', 'Daily backup at 2 AM UTC'),
('MAX_QUERY_DURATION_SEC', '30', 'INTEGER', 'Long-running query threshold'),
('PGVECTOR_INDEX_TYPE', 'HNSW', 'STRING', 'Vector index algorithm');
```

**Design Decisions**:

1. **Single row per setting** - Easy to update without transactions
2. **String storage with type hints** - Flexible configuration, parseability
3. **NOT UPDATABLE directly** - Only through application (prevents accidental changes)
4. **CHECK constraints** - Validated values:
   ```sql
   CONSTRAINT valid_data_type CHECK (
       data_type IN ('INTEGER', 'BOOLEAN', 'STRING', 'INTERVAL', 'CRON')
   )
   ```

**Indexes**:
```sql
CREATE UNIQUE INDEX idx_settings_key ON audit.settings(setting_key);
CREATE INDEX idx_settings_type ON audit.settings(data_type);
```

**Access Control**:
```sql
GRANT SELECT ON audit.settings TO PUBLIC;
GRANT UPDATE ON audit.settings TO audit_admin;  -- Only admins can change
```

---

### 2.3 audit.system_log Table

**Purpose**: Immutable event log for all system activities, configuration changes, errors, and security events.

```sql
CREATE TABLE audit.system_log (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    severity_level VARCHAR(20) NOT NULL,
    user_action VARCHAR(100) NOT NULL,
    schema_name VARCHAR(100),
    table_name VARCHAR(100),
    operation VARCHAR(20),
    record_id UUID,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ip_address INET,
    session_id UUID,
    error_message TEXT
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | BIGSERIAL | PRIMARY KEY | Immutable event identifier |
| `event_type` | VARCHAR(50) | NOT NULL | Category: AUTH, DATA_CHANGE, CONFIG, ERROR |
| `severity_level` | VARCHAR(20) | NOT NULL, CHECK | CRITICAL, ERROR, WARNING, INFO, DEBUG |
| `user_action` | VARCHAR(100) | NOT NULL | User who triggered event |
| `schema_name` | VARCHAR(100) | | Target schema (audit, pii, rag) |
| `table_name` | VARCHAR(100) | | Target table |
| `operation` | VARCHAR(20) | | INSERT, UPDATE, DELETE, SELECT |
| `record_id` | UUID | | Affected record identifier |
| `metadata` | JSONB | DEFAULT '{}' | Extensible context (query params, etc.) |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | When event occurred |
| `ip_address` | INET | | Client IP for remote connections |
| `session_id` | UUID | | Session identifier for correlation |
| `error_message` | TEXT | | Exception message if applicable |

**Design Decisions**:

1. **JSONB metadata field** - Extensible without schema changes
2. **Immutability enforced** - No triggers, no UPDATE/DELETE allowed
3. **Chronological index** - For time-range queries
4. **Soft partitioning ready** - Can add PARTITION BY RANGE (created_at) later

**CHECK Constraints**:

```sql
CONSTRAINT valid_severity CHECK (severity_level IN 
    ('CRITICAL', 'ERROR', 'WARNING', 'INFO', 'DEBUG')),
CONSTRAINT valid_operation CHECK (operation IN 
    ('INSERT', 'UPDATE', 'DELETE', 'SELECT', 'CALL', 'TRUNCATE'))
```

**Indexes**:

```sql
-- Time-range queries (most common)
CREATE INDEX idx_system_log_created_at 
    ON audit.system_log(created_at DESC)
    WHERE severity_level IN ('CRITICAL', 'ERROR');

-- Event type filtering
CREATE INDEX idx_system_log_event_type 
    ON audit.system_log(event_type, created_at DESC);

-- User action tracking
CREATE INDEX idx_system_log_user_action 
    ON audit.system_log(user_action, created_at DESC);

-- Schema/table changes
CREATE INDEX idx_system_log_schema_table 
    ON audit.system_log(schema_name, table_name, created_at DESC);

-- Session correlation
CREATE INDEX idx_system_log_session 
    ON audit.system_log(session_id, created_at DESC);

-- JSONB queries (for metadata search)
CREATE INDEX idx_system_log_metadata_gin 
    ON audit.system_log USING gin(metadata);
```

**Immutability Enforcement**:

```sql
-- Prevent UPDATE
CREATE TRIGGER tr_audit_log_no_update
BEFORE UPDATE ON audit.system_log
FOR EACH ROW EXECUTE FUNCTION raise_immutable_error();

-- Prevent DELETE  
CREATE TRIGGER tr_audit_log_no_delete
BEFORE DELETE ON audit.system_log
FOR EACH ROW EXECUTE FUNCTION raise_immutable_error();

-- Helper function
CREATE OR REPLACE FUNCTION raise_immutable_error()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit logs are immutable. Cannot modify.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Retention & Cleanup**:

```sql
-- Archive old records (configurable from audit.settings)
DELETE FROM audit.system_log 
WHERE created_at < NOW() - INTERVAL '1 year'
AND severity_level NOT IN ('CRITICAL', 'ERROR');
-- Preserves critical events for longer periods

-- Cost-effective storage: GZIP compression
ALTER TABLE audit.system_log SET (fillfactor = 70);
```

**Example Events**:

```sql
-- Authentication success
INSERT INTO audit.system_log 
(event_type, severity_level, user_action, metadata)
VALUES ('AUTH', 'INFO', 'user@example.com', 
    '{"method": "password", "mfa": true}'::jsonb);

-- Data modification
INSERT INTO audit.system_log
(event_type, severity_level, user_action, schema_name, table_name, operation, record_id)
VALUES ('DATA_CHANGE', 'INFO', 'app_user', 'rag', 'documents', 'UPDATE', 
    '550e8400-e29b-41d4-a716-446655440000'::uuid);

-- Configuration change (high severity)
INSERT INTO audit.system_log
(event_type, severity_level, user_action, metadata)
VALUES ('CONFIG_CHANGE', 'CRITICAL', 'admin', 
    '{"setting": "RETENTION_DAYS", "old": "365", "new": "180"}'::jsonb);
```

---

## 3. PII Schema

### 3.1 Schema Purpose & Design

**Purpose**: Manage encryption configurations and PII data categorization. Designed for external key management and Row-Level Security (RLS).

**Design Decision**:
- Separate schema prevents accidental mixing with audit/rag data
- Supports future RLS policies per user/role
- Encryption metadata decoupled from actual encrypted data
- Extensible for future PII categories

---

### 3.2 pii.encryption_config Table

**Purpose**: Store encryption algorithm configurations and rotation policies.

```sql
CREATE TABLE pii.encryption_config (
    id SERIAL PRIMARY KEY,
    algorithm VARCHAR(100) NOT NULL,
    key_version INTEGER NOT NULL,
    encryption_key_id UUID UNIQUE,
    key_rotation_interval INTERVAL,
    last_rotation_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB DEFAULT '{}'
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | SERIAL | PRIMARY KEY | Configuration identifier |
| `algorithm` | VARCHAR(100) | NOT NULL | Algorithm name: AES-256, BCRYPT, PSEUDONYM |
| `key_version` | INTEGER | NOT NULL | Version for key rotation tracking |
| `encryption_key_id` | UUID | UNIQUE | Reference to external key store |
| `key_rotation_interval` | INTERVAL | | How often to rotate (e.g., 90 days) |
| `last_rotation_at` | TIMESTAMPTZ | | When key was last rotated |
| `expires_at` | TIMESTAMPTZ | | When key expires and must be rotated |
| `enabled` | BOOLEAN | NOT NULL, DEFAULT | Active/inactive toggle |
| `metadata` | JSONB | DEFAULT '{}' | Algorithm-specific config |

**Default Configurations** (populated on init):

```sql
INSERT INTO pii.encryption_config 
(algorithm, key_version, key_rotation_interval, enabled, metadata) 
VALUES
(
    'AES-256-GCM',  -- AES encryption with authentication
    1,
    INTERVAL '90 days',
    TRUE,
    '{"key_length": 256, "mode": "GCM", "iv_length": 16}'::jsonb
),
(
    'BCRYPT',       -- Password hashing
    1,
    INTERVAL '180 days',
    TRUE,
    '{"rounds": 12, "cost": 12}'::jsonb
),
(
    'PSEUDONYMIZATION',  -- Irreversible transformation
    1,
    INTERVAL '365 days',
    TRUE,
    '{"method": "hash", "salt_length": 32, "hash_algorithm": "SHA256"}'::jsonb
);
```

**Indexes**:

```sql
CREATE UNIQUE INDEX idx_encryption_config_algorithm 
    ON pii.encryption_config(algorithm, key_version);
    
CREATE INDEX idx_encryption_config_active 
    ON pii.encryption_config(enabled)
    WHERE enabled = TRUE;
```

**Design Rationale**:

1. **Key version tracking** - Enables key rotation without data re-encryption
2. **External key store reference** - Implements HSM/Vault integration pattern
3. **Metadata flexibility** - Algorithm-specific parameters without schema changes
4. **Rotation scheduling** - Automate key rotation with cron jobs

---

### 3.3 pii.pii_categories Table

**Purpose**: Define and track categories of personally identifiable information.

```sql
CREATE TABLE pii.pii_categories (
    id SERIAL PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    data_type VARCHAR(50) NOT NULL,
    encryption_algorithm_id INTEGER NOT NULL REFERENCES pii.encryption_config(id),
    anonymization_method VARCHAR(100),
    retention_days INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | SERIAL | PRIMARY KEY | Category identifier |
| `category_name` | VARCHAR(100) | UNIQUE, NOT NULL | E.g., "EMAIL", "SSN", "CREDIT_CARD" |
| `description` | TEXT | | What data this category includes |
| `data_type` | VARCHAR(50) | NOT NULL | Data type (EMAIL, PHONE, NUMERIC, UUID) |
| `encryption_algorithm_id` | INTEGER | FK, NOT NULL | Which encryption to use |
| `anonymization_method` | VARCHAR(100) | | How to anonymize (HASH, MASK, TOKENIZE) |
| `retention_days` | INTEGER | | How long to keep before deletion |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | When category was defined |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | Last modification |

**Default Categories** (populated on init):

```sql
INSERT INTO pii.pii_categories 
(category_name, description, data_type, encryption_algorithm_id, anonymization_method, retention_days)
SELECT 'EMAIL', 'Email addresses', 'EMAIL', id, 'PSEUDONYMIZATION', 2555
FROM pii.encryption_config WHERE algorithm = 'PSEUDONYMIZATION';

INSERT INTO pii.pii_categories 
(category_name, description, data_type, encryption_algorithm_id, anonymization_method, retention_days)
SELECT 'PHONE', 'Phone numbers', 'PHONE', id, 'MASKING', 1825
FROM pii.encryption_config WHERE algorithm = 'AES-256-GCM';

INSERT INTO pii.pii_categories 
(category_name, description, data_type, encryption_algorithm_id, anonymization_method, retention_days)
SELECT 'SSN', 'Social Security Numbers', 'NUMERIC', id, 'TOKENIZATION', 2555
FROM pii.encryption_config WHERE algorithm = 'AES-256-GCM';

INSERT INTO pii.pii_categories 
(category_name, description, data_type, encryption_algorithm_id, anonymization_method, retention_days)
SELECT 'PASSWORD', 'Hashed passwords', 'HASH', id, NULL, NULL
FROM pii.encryption_config WHERE algorithm = 'BCRYPT';
```

**Indexes**:

```sql
CREATE UNIQUE INDEX idx_pii_categories_name 
    ON pii.pii_categories(category_name);
    
CREATE INDEX idx_pii_categories_data_type 
    ON pii.pii_categories(data_type);
```

**Design Rationale**:

1. **Standardized categories** - Consistency across organization
2. **Encryption binding** - Links category to encryption algorithm
3. **Retention rules** - Enforces data lifecycle per category
4. **Anonymization methods** - Multiple strategies per category

---

## 4. RAG Schema

### 4.1 Schema Purpose & Design

**Purpose**: Store documents, text chunks, vector embeddings for retrieval-augmented generation (RAG) systems.

**Design Decision**:
- Separate schema isolates RAG data from audit/pii
- Specialized indexes for vector similarity (HNSW)
- Multi-language support for document chunks
- Efficient chunk-to-embedding mapping

---

### 4.2 rag.schema_config Table

**Purpose**: Configuration for RAG behavior (embedding model, chunking parameters, etc.).

```sql
CREATE TABLE rag.schema_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(100) NOT NULL UNIQUE,
    config_value VARCHAR(1000) NOT NULL,
    description TEXT,
    config_type VARCHAR(50),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by VARCHAR(100) DEFAULT 'SYSTEM'
);
```

**Default Configuration** (populated on init):

```sql
INSERT INTO rag.schema_config 
(config_key, config_value, config_type, description) VALUES
('EMBEDDING_MODEL', 'text-embedding-3-large', 'STRING', 'OpenAI embedding model'),
('EMBEDDING_DIMENSION', '3072', 'INTEGER', 'Embedding vector dimension'),
('CHUNK_SIZE_TOKENS', '512', 'INTEGER', 'Tokens per text chunk'),
('CHUNK_OVERLAP_TOKENS', '50', 'INTEGER', 'Overlap between chunks'),
('VECTOR_INDEX_TYPE', 'HNSW', 'STRING', 'Vector search index algorithm'),
('HNSW_EF_CONSTRUCTION', '64', 'INTEGER', 'HNSW construction parameter'),
('HNSW_M', '16', 'INTEGER', 'HNSW maximum connections'),
('SIMILARITY_THRESHOLD', '0.7', 'FLOAT', 'Min similarity score for results');
```

**Indexes**:

```sql
CREATE UNIQUE INDEX idx_rag_config_key 
    ON rag.schema_config(config_key);
```

---

### 4.3 rag.documents Table

**Purpose**: Store document metadata and lifecycle.

```sql
CREATE TABLE rag.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(500) NOT NULL,
    source_uri VARCHAR(2000),
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    language VARCHAR(10) DEFAULT 'en',
    metadata JSONB DEFAULT '{}',
    chunk_count INTEGER DEFAULT 0,
    embedding_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    indexed_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | UUID | PRIMARY KEY, DEFAULT | Distributed unique ID |
| `title` | VARCHAR(500) | NOT NULL | Document display name |
| `source_uri` | VARCHAR(2000) | | Where document came from (URL, S3, etc.) |
| `status` | VARCHAR(50) | NOT NULL, DEFAULT | PENDING, PROCESSING, INDEXED, FAILED, DELETED |
| `language` | VARCHAR(10) | DEFAULT 'en' | Document language for chunking |
| `metadata` | JSONB | DEFAULT '{}' | Author, type, tags, etc. |
| `chunk_count` | INTEGER | DEFAULT 0 | Number of chunks created |
| `embedding_count` | INTEGER | DEFAULT 0 | Number of embeddings generated |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | When document added |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | Last status change |
| `indexed_at` | TIMESTAMPTZ | | When indexing completed |
| `deleted_at` | TIMESTAMPTZ | | Soft-delete timestamp |

**CHECK Constraints**:

```sql
CONSTRAINT valid_status CHECK (status IN 
    ('PENDING', 'PROCESSING', 'INDEXED', 'FAILED', 'DELETED')),
CONSTRAINT valid_language CHECK (language ~ '^[a-z]{2}(-[A-Z]{2})?$')
```

**Indexes**:

```sql
-- Status filtering (most common queries)
CREATE INDEX idx_documents_status 
    ON rag.documents(status, created_at DESC)
    WHERE status IN ('INDEXED', 'FAILED');

-- Language filtering (for multi-language support)
CREATE INDEX idx_documents_language 
    ON rag.documents(language, status);

-- Time-based queries
CREATE INDEX idx_documents_created_at 
    ON rag.documents(created_at DESC);

-- Soft-delete queries
CREATE INDEX idx_documents_not_deleted 
    ON rag.documents(status)
    WHERE deleted_at IS NULL;

-- Full-text search ready (future enhancement)
CREATE INDEX idx_documents_title_fts 
    ON rag.documents USING gin(to_tsvector('english', title));
```

**Example Records**:

```sql
INSERT INTO rag.documents 
(title, source_uri, status, language, metadata)
VALUES (
    'PostgreSQL 16 Documentation',
    'https://www.postgresql.org/docs/16/',
    'INDEXED',
    'en',
    '{"source_type": "documentation", "version": "16.0", "tags": ["database", "sql"]}'::jsonb
);

INSERT INTO rag.documents
(title, source_uri, status, language)
VALUES (
    'pgvector Quick Start',
    's3://docs/pgvector-quickstart.pdf',
    'PENDING',
    'en'
);
```

---

### 4.4 rag.chunks Table

**Purpose**: Store text chunks from documents.

```sql
CREATE TABLE rag.chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES rag.documents(id) ON DELETE CASCADE,
    chunk_number INTEGER NOT NULL,
    chunk_text TEXT NOT NULL,
    token_count INTEGER,
    language VARCHAR(10) DEFAULT 'en',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(document_id, chunk_number)
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | UUID | PRIMARY KEY, DEFAULT | Distributed unique ID |
| `document_id` | UUID | FK, NOT NULL | Parent document |
| `chunk_number` | INTEGER | NOT NULL | Sequence within document |
| `chunk_text` | TEXT | NOT NULL | Actual text content |
| `token_count` | INTEGER | | Tokens in chunk (for billing/tracking) |
| `language` | VARCHAR(10) | DEFAULT 'en' | Override document language |
| `metadata` | JSONB | DEFAULT '{}' | Page number, section, etc. |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | When chunk created |

**Indexes**:

```sql
-- Foreign key lookup
CREATE INDEX idx_chunks_document_id 
    ON rag.chunks(document_id, chunk_number);

-- Chunk retrieval by document
CREATE INDEX idx_chunks_document_ordered 
    ON rag.chunks(document_id, chunk_number ASC);

-- Token counting (for quotas)
CREATE INDEX idx_chunks_token_count 
    ON rag.chunks(token_count) 
    WHERE token_count IS NOT NULL;
```

**Cascade Behavior**:

```sql
-- When document deleted, automatically cascade to chunks and embeddings
ON DELETE CASCADE
```

---

### 4.5 rag.embeddings Table

**Purpose**: Store vector embeddings for semantic search.

```sql
CREATE TABLE rag.embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chunk_id UUID NOT NULL REFERENCES rag.chunks(id) ON DELETE CASCADE,
    document_id UUID NOT NULL REFERENCES rag.documents(id),
    embedding vector(3072),  -- pgvector extension
    model_name VARCHAR(100) NOT NULL,
    model_version VARCHAR(20),
    similarity_searched INTEGER DEFAULT 0,
    similarity_hit INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(chunk_id, model_name)
);
```

| Column | Type | Constraints | Rationale |
|--------|------|-----------|-----------|
| `id` | UUID | PRIMARY KEY, DEFAULT | Distributed unique ID |
| `chunk_id` | UUID | FK, NOT NULL | Parent chunk |
| `document_id` | UUID | FK, NOT NULL | Parent document (denormalized for queries) |
| `embedding` | vector(3072) | NOT NULL | pgvector 3072-dim vector |
| `model_name` | VARCHAR(100) | NOT NULL | Model used for embedding |
| `model_version` | VARCHAR(20) | | Version of model |
| `similarity_searched` | INTEGER | DEFAULT 0 | Times searched with this embedding |
| `similarity_hit` | INTEGER | DEFAULT 0 | Times returned in results |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT | When embedding generated |

**Indexes** (pgvector-specific):

```sql
-- HNSW index for fast similarity search
CREATE INDEX idx_embeddings_vector_hnsw 
    ON rag.embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- IVFFLAT index (alternative, faster for very large datasets)
-- CREATE INDEX idx_embeddings_vector_ivfflat 
--     ON rag.embeddings USING ivfflat (embedding vector_cosine_ops)
--     WITH (lists = 100);

-- Metadata lookups
CREATE INDEX idx_embeddings_chunk_id 
    ON rag.embeddings(chunk_id, model_name);

CREATE INDEX idx_embeddings_document_id 
    ON rag.embeddings(document_id);

-- Model tracking
CREATE INDEX idx_embeddings_model 
    ON rag.embeddings(model_name, model_version);
```

**Similarity Search Example**:

```sql
-- Find most similar documents to query embedding
SELECT 
    d.title,
    c.chunk_text,
    1 - (e.embedding <=> query_embedding) as similarity_score
FROM rag.embeddings e
JOIN rag.chunks c ON e.chunk_id = c.id
JOIN rag.documents d ON e.document_id = d.id
WHERE e.embedding <=> query_embedding < 0.3  -- Top 30% similar
ORDER BY e.embedding <=> query_embedding
LIMIT 10;
```

---

## 5. Cross-Schema Design

### 5.1 Referential Integrity

**No foreign keys between schemas** - By design:
- Audit logs reference tables by name, not FK
- PII categories are independent lookups
- RAG embeddings don't reference audit

**Rationale**:
- Audit schema immutable, PII may change - loose coupling
- Easier to backup/restore each schema independently
- RAG can be populated from external sources

### 5.2 Shared Functions

**Utility functions in PUBLIC schema**:

```sql
-- Paragraph separator
CREATE OR REPLACE FUNCTION public.get_setting(p_key VARCHAR)
RETURNS VARCHAR AS $$
    SELECT setting_value FROM audit.settings 
    WHERE setting_key = p_key;
$$ LANGUAGE SQL SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.log_event(
    p_event_type VARCHAR,
    p_severity VARCHAR,
    p_user VARCHAR,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS BIGINT AS $$
    INSERT INTO audit.system_log 
    (event_type, severity_level, user_action, metadata)
    VALUES (p_event_type, p_severity, p_user, p_metadata)
    RETURNING id;
$$ LANGUAGE SQL SECURITY DEFINER;
```

---

## 6. Data Type Rationale

### 6.1 Special Data Types

| Type | Usage | Rationale |
|------|-------|-----------|
| **TIMESTAMPTZ** | All timestamps | Timezone-aware, UTC storage |
| **UUID** | Primary keys (RAG) | Distributed IDs, mergeable |
| **SERIAL/BIGSERIAL** | Sequential IDs (audit/pii) | Simple, ordered, efficient |
| **JSONB** | Flexible metadata | Queryable, indexable, extensible |
| **BYTEA** | Encrypted data | Binary storage for encrypted values |
| **INET** | IP addresses | Native IPv4/IPv6 support |
| **vector(n)** | Embeddings | pgvector type, 1-2000 dimensions |

### 6.2 Data Type Conversions

```sql
-- JSONB parsing
SELECT (metadata->>'model_name') as model FROM rag.embeddings;
SELECT metadata::text as json_string FROM rag.documents;

-- UUID generation
SELECT gen_random_uuid();  -- Cryptographically random
SELECT uuid_generate_v4(); -- UUIDv4 (also available)

-- TIMESTAMPTZ handling
SELECT created_at AT TIME ZONE 'America/New_York' as local_time
FROM audit.system_log;

-- Vector operations
SELECT 1 - (embedding <=> query_vector) as similarity
FROM rag.embeddings;
```

---

## 7. Indexing Strategy

### 7.1 Index Design Philosophy

**Goals**:
- ✅ Minimize INSERT overhead (audit logs)
- ✅ Accelerate SELECT queries (RAG searches)
- ✅ Keep index maintenance manageable

**Strategy**:
- **Audit schema**: Time-based BTREE indexes
- **PII schema**: Key lookup HASH indexes  
- **RAG schema**: Vector HNSW indexes

### 7.2 Index Creation Order

```sql
-- Audit (immediate)
CREATE INDEX idx_system_log_created_at ON audit.system_log(created_at DESC);
CREATE INDEX idx_system_log_user_action ON audit.system_log(user_action);

-- PII (immediate)
CREATE UNIQUE INDEX idx_pii_categories_name ON pii.pii_categories(category_name);

-- RAG (concurrent, in background)
CREATE INDEX CONCURRENTLY idx_embeddings_vector_hnsw 
    ON rag.embeddings USING hnsw (embedding vector_cosine_ops);

-- Full text search (future)
CREATE INDEX idx_documents_fts ON rag.documents 
    USING gin(to_tsvector('english', title));
```

### 7.3 Index Monitoring

```sql
-- Check index bloat
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- Unused indexes (candidates for removal)
SELECT schemaname, tablename, indexname
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND idx_tup_read = 0;

-- Index size
SELECT schemaname, tablename, indexname, 
       pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;
```

---

## 8. Security Design

### 8.1 Role-Based Access Control (RBAC)

**Three roles per schema**:

```sql
-- AUDIT schema roles
CREATE ROLE audit_reader;      -- SELECT only
CREATE ROLE audit_writer;      -- INSERT only (append)
CREATE ROLE audit_admin;       -- Full management

-- PII schema roles  
CREATE ROLE pii_reader;        -- SELECT (filtered by RLS)
CREATE ROLE pii_writer;        -- INSERT/UPDATE (for admins)
CREATE ROLE pii_admin;         -- Full control + key management

-- RAG schema roles
CREATE ROLE rag_reader;        -- SELECT (semantic search)
CREATE ROLE rag_writer;        -- INSERT (document ingestion)
CREATE ROLE rag_admin;         -- Reindex, configuration

-- Application roles
CREATE ROLE app_user;          -- Combined reader for all schemas
CREATE ROLE readonly_user;     -- SELECT-only for monitoring
```

**Grant Statements**:

```sql
-- Example: app_user gets read access to audit, read-write to RAG
GRANT USAGE ON SCHEMA audit, pii, rag TO app_user;
GRANT SELECT ON audit.system_log, audit.settings TO app_user;
GRANT SELECT ON pii.pii_categories, pii.encryption_config TO app_user;
GRANT SELECT, INSERT, UPDATE ON rag.documents, rag.chunks, rag.embeddings TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA rag TO app_user;
```

### 8.2 Row-Level Security (RLS)

**Future RLS policies** (implemented as needed):

```sql
-- Enable RLS on sensitive tables
ALTER TABLE pii.encryption_config ENABLE ROW LEVEL SECURITY;

-- Policy: Only users with 'pii_admin' role can see all configs
CREATE POLICY pii_config_admin ON pii.encryption_config
FOR SELECT USING (current_user IN (SELECT rolname FROM pg_roles WHERE rolname = 'pii_admin'));

-- Policy: Regular users see only enabled configs
CREATE POLICY pii_config_user ON pii.encryption_config
FOR SELECT USING (enabled = TRUE);
```

### 8.3 Encryption at Rest

**PII data encryption pattern**:

```sql
-- Encrypted column definition (not yet implemented, but structure ready)
ALTER TABLE pii.encryption_config ADD COLUMN 
    private_key_encrypted BYTEA;  -- Stores encrypted key material

-- Application layer encryption/decryption:
-- 1. SELECT encrypted_data FROM table
-- 2. Application uses HSM/KMS to decrypt
-- 3. Process plaintext in memory
-- 4. Clear memory after use
```

---

## 9. Performance Characteristics

### 9.1 Expected Query Latencies

| Query Type | Table(s) | Index | Expected Latency |
|------------|----------|-------|------------------|
| Audit log by timestamp | audit.system_log | BTREE | < 5ms |
| Last 1000 events | audit.system_log | DESC BTREE | < 50ms |
| PII category lookup | pii.pii_categories | UNIQUE | < 2ms |
| Vector similarity (top 10) | rag.embeddings | HNSW | 10-50ms |
| Document search by status | rag.documents | BTREE | < 5ms |
| Full-text search | rag.documents | GIN FTS | 50-200ms |

### 9.2 Storage Estimates

| Table | Estimated Size | Growth Rate |
|-------|----------------|-------------|
| audit.system_log (1M events) | 500 MB | 1-5 GB/month |
| pii.encryption_config | < 1 MB | Minimal |
| pii.pii_categories | < 1 MB | Minimal |
| rag.documents (10K docs) | 50 MB | 1-10 GB/month |
| rag.chunks (100K chunks) | 200 MB | 1-10 GB/month |
| rag.embeddings (100K vectors @ 3072 dims) | 1.2 GB | Minimal (recompute-heavy) |

**Total estimate**: ~2 GB for 100K documents with embeddings

### 9.3 Scaling Considerations

**Audit schema partitioning** (when > 100M events):

```sql
-- Partition by month
CREATE TABLE audit.system_log_2026_01 PARTITION OF audit.system_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

CREATE TABLE audit.system_log_2026_02 PARTITION OF audit.system_log
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
```

**RAG vector index tuning** (for > 1M embeddings):

```sql
-- Switch to IVFFLAT for faster searches on very large datasets
DROP INDEX idx_embeddings_vector_hnsw;
CREATE INDEX idx_embeddings_vector_ivfflat ON rag.embeddings
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 1000);  -- Increase for very large datasets
```

---

## Summary Table: Schema Comparison

| Aspect | Audit | PII | RAG |
|--------|-------|-----|-----|
| **Primary Purpose** | Compliance logging | Sensitive data mgmt | Semantic search |
| **Write Pattern** | Append-only | CRUD (guarded) | Insert-heavy |
| **Read Pattern** | Time-range, event-type | Key lookup | Similarity search |
| **Typical Queries/Day** | Millions | Thousands | Hundreds of thousands |
| **Data Lifetime** | 1+ years | 1-7 years | Document lifecycle |
| **Key Index** | BTREE(created_at) | HASH(key) | HNSW(embedding) |
| **Scaling Approach** | Partition by date | Vertical scale | Vector optimization |
| **Compliance** | GDPR/HIPAA audit trail | GDPR/data protection | N/A (metadata only) |

---

**Last Updated**: May 20, 2026  
**Version**: 1.0  
**Status**: Complete

