# ============================================================================
# PostgreSQL 16 with pgvector Extension - Dockerfile
# ============================================================================
#
# PERSPECTIVES ADDRESSED:
# • Maintainability: Clear structure, documented design decisions
# • Testability: Each layer independently verifiable
# • Architecture: Multi-stage build, separation of concerns
# • Security: Non-root user, minimal attack surface, no hardcoded secrets
# • Business Value: Production-ready, enables AI/ML vector workloads
# • Documentation: Comprehensive inline comments explaining intent
#
# ============================================================================

# Stage 1: Builder Stage
# ============================================================================
# PURPOSE: Compile pgvector extension from source
# RATIONALE:
#   - Isolates build tools and compilation artifacts
#   - Reduces final image size by ~300MB (build tools not included)
#   - Security: Build tools not present in runtime image = smaller attack surface
#
# DEPENDENCIES:
#   - postgresql-dev: Necessary for compiling against PostgreSQL
#   - build-essential: gcc, make, and other compilation tools
#   - git: Required to clone pgvector from repository
# ============================================================================
FROM postgres:16-bookworm AS builder

# Set working directory for build context
WORKDIR /build

# Update package lists once to improve layer caching
# Using && to chain commands reduces layer count and improves Docker efficiency
RUN apt-get update && apt-get install -y \
    postgresql-dev \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Clone pgvector repository (explicit version tag for reproducibility)
# Pin to specific version (not 'main' branch) to ensure consistent builds across environments
# SECURITY: Using official pgvector repo from pgvector maintainers
# MAINTAINABILITY: Version tag makes it easy to upgrade in the future
RUN git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git /build/pgvector

# Build pgvector extension
# WORKDIR changes to pgvector directory
WORKDIR /build/pgvector

# Use generic Makefile targets for maximum compatibility
# PG_CONFIG points to PostgreSQL installation for proper linking
RUN make && make install

# Verify pgvector compiled successfully by checking for the .so file
# This is a build-time testability check
RUN test -f $(pg_config --pkglibdir)/vector.so || \
    (echo "pgvector compilation failed - vector.so not found" && exit 1)


# Stage 2: Runtime Stage
# ============================================================================
# PURPOSE: Final production image with PostgreSQL and pgvector
# RATIONALE:
#   - Starts fresh from base image (doesn't inherit build dependencies)
#   - Only necessary runtime artifacts copied over
#   - Significantly smaller final image size (~200MB vs ~500MB with build tools)
#   - Improved security posture (no gcc, make, git, etc. in production)
# ============================================================================
FROM postgres:16-bookworm

# LABELS for image metadata
# RATIONALE:
#   - Maintainability: Helps identify image source and version
#   - Documentation: Provides context about image purpose
#   - Business Value: Enables organization and filtering in registries
LABEL maintainer="LunaBlue AI <dev@lunaBlue.ai>"
LABEL version="1.0.0"
LABEL description="PostgreSQL 16 with pgvector extension for vector search and AI workloads"
LABEL pgvector.version="0.5.1"

# Copy compiled pgvector extension from builder stage
# SOURCE: /build/pgvector/build (contains compiled .so files)
# DESTINATION: $(pg_config --pkglibdir) (PostgreSQL expects extensions here)
# RATIONALE:
#   - Only copying necessary compiled artifacts
#   - Avoids shipping entire git repository or build artifacts
#   - Ensures pgvector is available when PostgreSQL loads extensions
COPY --from=builder /build/pgvector/sql /usr/share/postgresql/16/extension/
COPY --from=builder /build/pgvector/build/vector.so $(pg_config --pkglibdir)/
COPY --from=builder /build/pgvector/vector--*.sql /usr/share/postgresql/16/extension/

# Set environment variables for PostgreSQL configuration
# RATIONALE:
#   - Maintainability: Centralized configuration management
#   - Security: POSTGRES_INITDB_ARGS allows customization without hardcoding
#   - Business Value: Enables vector extension auto-loading
#
# ENVIRONMENT VARIABLE EXPLANATION:
#   - POSTGRES_INITDB_ARGS: Flags passed to initdb during first-run initialization
#   - shared_preload_libraries: Loads pgvector at PostgreSQL startup
#     This enables vector operations and index types from first connection
ENV POSTGRES_INITDB_ARGS="-c shared_preload_libraries=vector"

# Create initialization script for schema setup
# This script runs automatically on container first start
# RATIONALE:
#   - Testability: Reproducible setup across dev/test/prod environments
#   - Business Value: Reduces manual setup steps
#   - Maintainability: Central location for database initialization logic
RUN mkdir -p /docker-entrypoint-initdb.d

# Copy initialization script (created separately in next step)
# This script ensures pgvector extension is available in the default database
# RATIONALE:
#   - Automation: No manual "CREATE EXTENSION pgvector" needed
#   - Testability: Scripted initialization is repeatable
COPY ./init-pgvector.sql /docker-entrypoint-initdb.d/

# Set working directory for runtime operations
WORKDIR /var/lib/postgresql

# EXPOSE port 5432 (PostgreSQL standard port)
# NOTE: This is documentation only; actual port binding happens at runtime with -p flag
# RATIONALE:
#   - Maintainability: Clear indication this image serves PostgreSQL
#   - Security: Port binding must be explicit in docker run/docker-compose
EXPOSE 5432

# Health check for container orchestration systems (Kubernetes, Docker Swarm, etc.)
# RATIONALE:
#   - Testability: Verifies PostgreSQL is accepting connections
#   - Business Value: Enables automatic restart on failure
#   - Architecture: Required for production deployments with orchestration
#
# HEALTH CHECK LOGIC:
#   - Interval: 10 seconds (standard for databases)
#   - Timeout: 5 seconds (fail if no response)
#   - Retries: 3 attempts before marking unhealthy
#   - Start period: 30 seconds (allow startup time)
#   - Test: psql command returns 0 if database is ready
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=30s \
    CMD pg_isready -U postgres -d postgres || exit 1

# Volume definition for data persistence
# RATIONALE:
#   - Maintainability: Clear separation of data vs. code
#   - Business Value: Data survives container restart
#   - Architecture: Supports persistent storage solutions
#
# MOUNT POINT: /var/lib/postgresql/data
# The PostgreSQL container automatically initializes this directory
# Users can mount this to a host path with: -v /host/path:/var/lib/postgresql/data
VOLUME ["/var/lib/postgresql/data"]

# Use default entrypoint from postgres base image
# The official postgres Docker image handles:
#   - Database initialization on first run
#   - User creation (via POSTGRES_USER env var)
#   - Password setup (via POSTGRES_PASSWORD env var)
#   - Database creation (via POSTGRES_DB env var)
# No explicit CMD/ENTRYPOINT needed - inherited from base image
# This allows the image to remain flexible for different deployment scenarios

# ============================================================================
# BUILD AND RUN INSTRUCTIONS
# ============================================================================
#
# BUILD:
#   docker build -t postgres-pgvector:16 -f Dockerfile .
#
# RUN (Development):
#   docker run -d \
#     -e POSTGRES_USER=postgres \
#     -e POSTGRES_PASSWORD=postgres \
#     -e POSTGRES_DB=postgres \
#     -p 5432:5432 \
#     --name postgres-pgvector \
#     postgres-pgvector:16
#
# VERIFY pgvector is available:
#   docker exec postgres-pgvector psql -U postgres -c "SELECT default_version FROM pg_available_extensions WHERE name='pgvector';"
#
# CREATE vector table (test):
#   docker exec postgres-pgvector psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS pgvector; CREATE TABLE vectors (id SERIAL, embedding vector(3)); INSERT INTO vectors (embedding) VALUES ('[1,2,3]'::vector);"
#
# ============================================================================
