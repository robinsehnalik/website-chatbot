-- ========================================================================
-- Hardened Website AI Chatbot Schema (Supabase pgvector + Strict Service-Role Isolation)
-- ========================================================================

-- 1. Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Revoke default privileges from public, anon, and authenticated roles
REVOKE ALL ON SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO service_role;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL ROUTINES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON ROUTINES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;

-- 3. Knowledge Documents Catalog
-- Note: 'catalog' source type removed per scope (no product prices or stock in KB)
CREATE TABLE IF NOT EXISTS kb_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  source_type TEXT NOT NULL CHECK (source_type IN ('faq', 'policy', 'article')),
  source_url TEXT NOT NULL UNIQUE,
  content_hash TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 4. Knowledge Chunks with Document-Scoped Content Hash
CREATE TABLE IF NOT EXISTS kb_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  source_url TEXT,
  embedding VECTOR(1536), -- text-embedding-3-small
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_document_chunk_hash UNIQUE (document_id, content_hash)
);

-- HNSW Index for approximate vector similarity search
CREATE INDEX IF NOT EXISTS idx_kb_chunks_hnsw 
ON kb_chunks USING hnsw (embedding vector_cosine_ops);

-- 5. Vector Match Function (SECURITY INVOKER, service_role only)
-- match_threshold default is 0.45 (provisional; tune via eval/)
CREATE OR REPLACE FUNCTION match_kb_chunks(
  query_embedding VECTOR(1536),
  match_threshold FLOAT DEFAULT 0.45,
  match_count INT DEFAULT 4
)
RETURNS TABLE (
  id UUID,
  document_id UUID,
  content TEXT,
  similarity FLOAT,
  source_url TEXT,
  document_title TEXT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  SELECT 
    c.id,
    c.document_id,
    c.content,
    1 - (c.embedding <=> query_embedding) AS similarity,
    c.source_url,
    d.title AS document_title
  FROM kb_chunks c
  LEFT JOIN kb_documents d ON c.document_id = d.id
  WHERE 1 - (c.embedding <=> query_embedding) >= match_threshold
  ORDER BY c.embedding <=> query_embedding
  LIMIT match_count;
$$;

REVOKE EXECUTE ON FUNCTION match_kb_chunks(VECTOR(1536), FLOAT, INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION match_kb_chunks(VECTOR(1536), FLOAT, INT) TO service_role;

-- 6. Support Handoff Escalation Tickets
CREATE TABLE IF NOT EXISTS handoffs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id TEXT NOT NULL,
  contact_email TEXT NOT NULL,
  contact_name TEXT,
  summary TEXT NOT NULL,
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),
  created_at TIMESTAMPTZ DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_handoffs_session ON handoffs(session_id);
CREATE INDEX IF NOT EXISTS idx_handoffs_status ON handoffs(status);
CREATE INDEX IF NOT EXISTS idx_handoffs_created_at ON handoffs(created_at DESC);

-- 7. Operational View: Open Handoff Tickets (Replaces old v_unanswered_queries)
CREATE OR REPLACE VIEW v_open_handoffs 
WITH (security_invoker = true) AS
SELECT 
  id,
  session_id,
  contact_email,
  contact_name,
  summary,
  created_at
FROM handoffs
WHERE status = 'open';

REVOKE ALL ON v_open_handoffs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON v_open_handoffs TO service_role;

-- 8. Gap Analytics: Query Logs
CREATE TABLE IF NOT EXISTS rag_queries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT now(),
  session_hash TEXT NOT NULL,
  query_text TEXT NOT NULL,
  top_similarity FLOAT,
  answerable BOOLEAN NOT NULL,
  escalated BOOLEAN NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rag_queries_created_at ON rag_queries(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rag_queries_answerable ON rag_queries(answerable);

-- Operational View: Gap Analytics for Unanswered Questions
CREATE OR REPLACE VIEW v_unanswered_queries 
WITH (security_invoker = true) AS
SELECT 
  id,
  created_at,
  session_hash,
  query_text,
  top_similarity,
  escalated
FROM rag_queries
WHERE answerable = false;

REVOKE ALL ON v_unanswered_queries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON v_unanswered_queries TO service_role;

-- 9. Atomic Rate Limiting Table & Function
CREATE TABLE IF NOT EXISTS rate_limits (
  key TEXT PRIMARY KEY,
  window_start TIMESTAMPTZ NOT NULL,
  count INTEGER NOT NULL DEFAULT 1
);

CREATE OR REPLACE FUNCTION increment_rate_limit(
  p_key TEXT,
  p_window_start TIMESTAMPTZ
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO rate_limits (key, window_start, count)
  VALUES (p_key, p_window_start, 1)
  ON CONFLICT (key) DO UPDATE
  SET count = rate_limits.count + 1
  RETURNING count INTO v_count;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION increment_rate_limit(TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION increment_rate_limit(TEXT, TIMESTAMPTZ) TO service_role;

-- 10. Row Level Security: Deny-by-Default on All Tables
-- Service role bypasses RLS; anon/authenticated have zero policies
ALTER TABLE kb_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE kb_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE handoffs ENABLE ROW LEVEL SECURITY;
ALTER TABLE rag_queries ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;

-- 11. Automated Data Retention Purge Routine
CREATE OR REPLACE FUNCTION purge_expired_data()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Handoff tickets: 90 days
  DELETE FROM handoffs WHERE created_at < now() - INTERVAL '90 days';
  -- Query logs: 30 days
  DELETE FROM rag_queries WHERE created_at < now() - INTERVAL '30 days';
  -- Rate limit windows: 2 days
  DELETE FROM rate_limits WHERE window_start < now() - INTERVAL '2 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION purge_expired_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION purge_expired_data() TO service_role;

-- 12. Optional pg_cron Scheduling (if pg_cron extension is available on the instance)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'purge-retention-job',
      '0 4 * * *',
      'SELECT public.purge_expired_data();'
    );
  END IF;
END;
$$;

-- 13. Service Role Full Access Grant
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA public TO service_role;
