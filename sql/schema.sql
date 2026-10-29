-- ========================================================================
-- Streamlined Website AI Chatbot Schema (Supabase pgvector + RLS)
-- ========================================================================

-- 1. Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Knowledge Documents Catalog
CREATE TABLE IF NOT EXISTS kb_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  source_type TEXT NOT NULL CHECK (source_type IN ('faq', 'policy', 'article', 'catalog')),
  source_url TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. Knowledge Chunks with Content Hash Deduplication
CREATE TABLE IF NOT EXISTS kb_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID REFERENCES kb_documents(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  content_hash TEXT UNIQUE NOT NULL, -- Deduplication key
  source_url TEXT,
  embedding VECTOR(1536), -- text-embedding-3-small
  created_at TIMESTAMPTZ DEFAULT now()
);

-- HNSW Index for rapid, accurate vector similarity search
CREATE INDEX IF NOT EXISTS idx_kb_chunks_hnsw 
ON kb_chunks USING hnsw (embedding vector_cosine_ops);

-- 4. Vector Match Function (Calibrated Cosine Threshold: 0.45)
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
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
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
END;
$$;

-- 5. Support Handoff Escalation Tickets
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

CREATE INDEX IF NOT EXISTS idx_handoffs_status ON handoffs(status);
CREATE INDEX IF NOT EXISTS idx_handoffs_created_at ON handoffs(created_at DESC);

-- 6. Operational View: Unanswered Queries & Open Tickets
CREATE OR REPLACE VIEW v_unanswered_queries AS
SELECT 
  id,
  session_id,
  contact_email,
  contact_name,
  summary,
  created_at
FROM handoffs
WHERE status = 'open'
ORDER BY created_at DESC;

-- 7. Row Level Security (RLS) Configuration
ALTER TABLE kb_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE kb_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE handoffs ENABLE ROW LEVEL SECURITY;

-- Anonymous users (public) can read public knowledge base
CREATE POLICY "Public read knowledge chunks"
ON kb_chunks FOR SELECT
TO anon, authenticated
USING (true);

-- Handoffs are private: anonymous users can only INSERT tickets
CREATE POLICY "Public insert handoffs"
ON handoffs FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Only service role can read or update handoff tickets
CREATE POLICY "Service role full access handoffs"
ON handoffs FOR ALL
TO service_role
USING (true);

-- 8. Data Retention & PII Cleanup Routine
CREATE OR REPLACE FUNCTION purge_expired_handoffs()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM handoffs WHERE created_at < now() - INTERVAL '90 days';
END;
$$;
