-- ============================================================================
-- PostgreSQL pgvector Test Data
-- ============================================================================
--
-- PURPOSE:
--   Initialize test tables and sample data for verification
--   Runs automatically on container first startup
--   Provides reproducible test dataset
--
-- EXECUTION:
--   Runs in /docker-entrypoint-initdb.d/ at container startup
--   Executed by postgres superuser in the POSTGRES_DB database
--
-- ============================================================================

-- =========================================================================
-- Test Table 1: Documents with embeddings
-- =========================================================================
-- Simulates storing document embeddings from an LLM (e.g., OpenAI embeddings)

CREATE TABLE IF NOT EXISTS documents (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    content TEXT NOT NULL,
    embedding vector(3),  -- Using 3-dimensional vectors for testing
    created_at TIMESTAMP DEFAULT NOW(),
    metadata JSONB
);

-- Create HNSW index for fast similarity search
-- PERSPECTIVE: Performance/Business Value
CREATE INDEX IF NOT EXISTS idx_documents_embedding 
ON documents 
USING hnsw (embedding vector_cosine_ops)
WITH (m = 5, ef_construction = 10);  -- Smaller values for small test dataset

-- Create IVFFLAT index as alternative (faster to build, slower to search)
-- Uncomment to test different index types
-- CREATE INDEX IF NOT EXISTS idx_documents_embedding_ivf
-- ON documents
-- USING ivfflat (embedding vector_cosine_ops)
-- WITH (lists = 10);

-- Insert test documents
INSERT INTO documents (title, content, embedding, metadata) VALUES
(
    'PostgreSQL Introduction',
    'PostgreSQL is a powerful, open source object-relational database system.',
    '[0.1, 0.2, 0.3]'::vector,
    '{"source": "documentation", "version": "16"}'
),
(
    'pgvector Features',
    'pgvector provides vector similarity search capabilities for machine learning applications.',
    '[0.15, 0.25, 0.35]'::vector,
    '{"source": "blog", "author": "pgvector team"}'
),
(
    'Vector Search Tutorial',
    'Learn how to build semantic search using vector embeddings and pgvector.',
    '[0.12, 0.22, 0.32]'::vector,
    '{"source": "tutorial", "difficulty": "intermediate"}'
),
(
    'Machine Learning with PostgreSQL',
    'Integrate machine learning models directly into your PostgreSQL database.',
    '[0.2, 0.3, 0.4]'::vector,
    '{"source": "whitepaper", "year": 2024}'
),
(
    'Database Optimization',
    'Tips and tricks for optimizing PostgreSQL performance with vector indices.',
    '[0.11, 0.21, 0.31]'::vector,
    '{"source": "guide", "difficulty": "advanced"}'
);

-- =========================================================================
-- Test Table 2: Products with embeddings
-- =========================================================================
-- Simulates an e-commerce product catalog with embedding-based search

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    embedding vector(2),  -- Different dimension to test flexibility
    price DECIMAL(10, 2) NOT NULL,
    in_stock BOOLEAN DEFAULT true
);

-- Create index for product search
CREATE INDEX IF NOT EXISTS idx_products_embedding
ON products
USING hnsw (embedding vector_cosine_ops);

-- Insert test products
INSERT INTO products (sku, name, description, embedding, price, in_stock) VALUES
(
    'LAPTOP-001',
    'Professional Laptop',
    'High-performance laptop for developers',
    '[0.8, 0.9]'::vector,
    1299.99,
    true
),
(
    'MOUSE-001',
    'Wireless Mouse',
    'Ergonomic wireless mouse',
    '[0.2, 0.3]'::vector,
    29.99,
    true
),
(
    'KEYBOARD-001',
    'Mechanical Keyboard',
    'RGB mechanical keyboard',
    '[0.7, 0.8]'::vector,
    129.99,
    true
),
(
    'MONITOR-001',
    '4K Monitor',
    'Ultra HD 4K display for professionals',
    '[0.85, 0.95]'::vector,
    599.99,
    false
);

-- =========================================================================
-- Test Table 3: Vector Operations (minimal table for operation testing)
-- =========================================================================

CREATE TABLE IF NOT EXISTS vector_test (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    vec vector(3)
);

INSERT INTO vector_test (name, vec) VALUES
('Test 1', '[1, 0, 0]'::vector),
('Test 2', '[0, 1, 0]'::vector),
('Test 3', '[0, 0, 1]'::vector),
('Test 4', '[1, 1, 0]'::vector),
('Test 5', '[1, 1, 1]'::vector);

-- =========================================================================
-- Verification Views
-- =========================================================================
-- Provide easy access to test results

-- View: Find similar documents
CREATE OR REPLACE VIEW v_similar_documents AS
SELECT 
    d1.id,
    d1.title,
    d2.id as similar_id,
    d2.title as similar_title,
    d1.embedding <-> d2.embedding as distance
FROM documents d1
JOIN documents d2 ON d1.id < d2.id
ORDER BY distance ASC;

-- View: Product recommendations by similarity
CREATE OR REPLACE VIEW v_product_recommendations AS
SELECT 
    p1.id,
    p1.name,
    p2.id as similar_product_id,
    p2.name as similar_product_name,
    p1.embedding <-> p2.embedding as similarity_distance
FROM products p1
JOIN products p2 ON p1.id < p2.id
ORDER BY similarity_distance ASC;

-- =========================================================================
-- Summary Table
-- =========================================================================

CREATE TABLE IF NOT EXISTS test_summary (
    test_name VARCHAR(255),
    expected_result TEXT,
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO test_summary VALUES
(
    'pgvector Extension Loaded',
    'Extension should be available in pg_available_extensions',
    'Verified at container startup'
),
(
    'Vector Type Creation',
    'Should be able to create vector(n) columns',
    'Documents and products tables created successfully'
),
(
    'Vector Type Casting',
    'Should cast string to vector: ''[1,2,3]''::vector',
    'Test vectors inserted successfully'
),
(
    'Vector Similarity Operators',
    'Should support <->, <#>, <=> operators',
    'Can be tested via SELECT queries'
),
(
    'Vector Index Creation',
    'Should be able to create HNSW and IVFFLAT indexes',
    'Indexes created on documents and products tables'
),
(
    'Aggregate Functions',
    'Should support avg(vector) and sum(vector)',
    'Can be tested via SELECT AVG/SUM queries'
);

-- =========================================================================
-- Create Test User (non-superuser)
-- =========================================================================
-- PERSPECTIVE: Security - test non-superuser permissions

CREATE ROLE app_user WITH LOGIN PASSWORD 'app_password';
GRANT CONNECT ON DATABASE testdb TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- =========================================================================
-- Test Completion Marker
-- =========================================================================

COMMENT ON TABLE documents IS 'Test data initialized successfully. Vector dimension: 3';
COMMENT ON TABLE products IS 'Test data initialized successfully. Vector dimension: 2';

-- =========================================================================
-- Verification Queries
-- =========================================================================
--
-- Run these manually to verify setup:
--
-- 1. Check pgvector is loaded:
--    SELECT default_version FROM pg_available_extensions WHERE name='pgvector';
--
-- 2. Check tables exist:
--    SELECT tablename FROM pg_tables WHERE schemaname='public';
--
-- 3. Check indexes exist:
--    SELECT indexname FROM pg_indexes WHERE tablename='documents';
--
-- 4. Test similarity search:
--    SELECT id, title, embedding <-> '[0.1, 0.2, 0.3]'::vector AS distance
--    FROM documents
--    ORDER BY embedding <-> '[0.1, 0.2, 0.3]'::vector
--    LIMIT 3;
--
-- 5. Test aggregate functions:
--    SELECT avg(embedding) FROM documents;
--
-- 6. Check test summary:
--    SELECT * FROM test_summary;
--
-- =========================================================================
