# Website AI Chatbot Automation — Implementation Guide & Overview

## 1. System Overview
The **Website AI Chatbot Automation** provides intelligent, grounded customer assistance without the complexity of custom frontend widgets or n8n synchronous streaming bottlenecks.

The architecture decouples the **real-time visitor conversational loop** from the **asynchronous automation layer**, offering two clear deployment options:
* **Option A (Lightweight / Asynchronous)**: **Typebot + n8n + Supabase** — Ideal for fast setup, lead capture forms, and asynchronous email/Slack escalation.
* **Option B (Omnichannel / Live Agent Intervention)**: **Chatwoot + n8n + Supabase** — Ideal for dedicated support teams requiring real-time live chat takeover inside the same widget.

```
OPTION A: Lightweight Asynchronous Flow
[Website Visitor] ──► [Typebot Widget] ──► [Native RAG / OpenAI Direct]
                              │
                    [Escalation / Low Conf]
                              │
                              ▼
            [n8n BOT-02 Handoff Manager] ──► [Slack / Email Notification]

OPTION B: Omnichannel Live Chat Flow
[Website Visitor] ──► [Chatwoot Widget]
                              │ (Webhook)
                              ▼
                 [n8n BOT-01 Bot Agent] ──► [Supabase pgvector]
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
            [Grounded Reply]     [Human Escalation]
                    │                   │
                    ▼                   ▼
           [Post to Chatwoot]    [Reassign to Live Agent & Mute Bot]
```

---

## 2. Choosing Your Deployment Path

| Feature | Option A: Typebot | Option B: Chatwoot |
| :--- | :--- | :--- |
| **Best For** | Lead capture, marketing qualification, async support. | Active support teams, live agent takeover, omnichannel. |
| **Hosting Footprint** | ~1 GB RAM (Lightweight Docker or Hosted Cloud). | ~2–4 GB RAM (Web, Worker, Redis, Postgres). |
| **Escalation Style** | Collects email/name; sends email/Slack ticket. | Live human agent claims chat inside widget in real time. |
| **Setup Guide** | [`deployments/typebot/README.md`](./deployments/typebot/README.md) | [`deployments/chatwoot/README.md`](./deployments/chatwoot/README.md) |

---

## 3. Workflows Included (`n8n-workflows/`)

| File | Name | Trigger | Primary Purpose |
| :--- | :--- | :--- | :--- |
| [`bot-01-chat-orchestrator.json`](./n8n-workflows/bot-01-chat-orchestrator.json) | BOT-01 Chatwoot Bot Agent | Webhook (`POST /chat/chatwoot-agent`) | Ingests Chatwoot visitor messages, executes RAG query, posts bot reply, or reassigns conversation to human. |
| [`bot-02-handoff-manager.json`](./n8n-workflows/bot-02-handoff-manager.json) | BOT-02 Handoff Manager | Webhook (`POST /chat/handoff`) | Ingests escalation tickets from Typebot or Chatwoot, logs to Supabase, and dispatches email/Slack alerts. |
| [`bot-03-knowledge-sync.json`](./n8n-workflows/bot-03-knowledge-sync.json) | BOT-03 Knowledge Sync | Schedule (`0 2 * * *` Daily) | Re-chunks content documents, computes vector embeddings, and upserts into `kb_chunks`. |
| [`bot-04-analytics-gap-report.json`](./n8n-workflows/bot-04-analytics-gap-report.json) | BOT-04 Analytics & Gap Report | Schedule (`0 23 * * 0` Sundays) | Analyzes unresolved questions and emails executive FAQ recommendations. |
| [`bot-err-error-handler.json`](./n8n-workflows/bot-err-error-handler.json) | BOT-ERR Error Handler | Error Trigger | Global runtime exception trap; logs errors and alerts administrator. |

---

## 4. Database Setup (Supabase)

Execute [`sql/schema.sql`](./sql/schema.sql) in your Supabase SQL Editor to configure pgvector and required tables:

```sql
-- Enable pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Knowledge chunks with cosine index
CREATE TABLE IF NOT EXISTS kb_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  source_type TEXT NOT NULL CHECK (source_type IN ('faq', 'policy', 'page', 'product')),
  source_url TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS kb_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID REFERENCES kb_documents(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  embedding VECTOR(1536),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Semantic match function
CREATE OR REPLACE FUNCTION match_kb_chunks(
  query_embedding VECTOR(1536),
  match_threshold FLOAT DEFAULT 0.70,
  match_count INT DEFAULT 4
)
RETURNS TABLE (id UUID, document_id UUID, content TEXT, similarity FLOAT)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT kb_chunks.id, kb_chunks.document_id, kb_chunks.content, 1 - (kb_chunks.embedding <=> query_embedding) AS similarity
  FROM kb_chunks
  WHERE 1 - (kb_chunks.embedding <=> query_embedding) >= match_threshold
  ORDER BY kb_chunks.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

-- Escalation handoffs & interaction logs
CREATE TABLE IF NOT EXISTS handoffs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id TEXT NOT NULL,
  contact_email TEXT,
  contact_name TEXT,
  reason TEXT,
  summary TEXT,
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved')),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS workflow_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_name TEXT NOT NULL,
  node_name TEXT,
  error_message TEXT,
  execution_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

---

## 5. Environment Variables Configuration

| Variable | Description | Used In |
| :--- | :--- | :--- |
| `LINK_TO_YOUR_N8N_INSTANCE` | Base URL of n8n | All Workflows |
| `LINK_TO_YOUR_SUPABASE_URL` | Supabase API endpoint | `BOT-01`, `BOT-02`, `BOT-03`, `BOT-04` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase Service Role key | `BOT-01`, `BOT-02`, `BOT-03`, `BOT-04` |
| `OPENAI_API_KEY` | OpenAI API key (`gpt-4o` & embeddings) | `BOT-01`, `BOT-02`, `BOT-03`, `BOT-04` |
| `LINK_TO_YOUR_CHATWOOT_URL` | Base URL of Chatwoot (Option B) | `BOT-01` |
| `CHATWOOT_BOT_TOKEN` | Bot Agent access token in Chatwoot (Option B) | `BOT-01` |
| `RESEND_API_KEY` | Resend API key for alerts | `BOT-02`, `BOT-04`, `BOT-ERR` |
| `SYSTEM_SENDER_EMAIL` | Verified sending address | `BOT-02`, `BOT-04`, `BOT-ERR` |
| `OWNER_NOTIFICATION_EMAIL` | Owner address for handoffs | `BOT-02`, `BOT-04`, `BOT-ERR` |
| `LINK_TO_YOUR_DASHBOARD` | Dashboard inbox URL | `BOT-02` |

---

## 6. Deployment Guides

* For **Typebot Setup** (Option A), follow [`deployments/typebot/README.md`](./deployments/typebot/README.md).
* For **Chatwoot Setup** (Option B), follow [`deployments/chatwoot/README.md`](./deployments/chatwoot/README.md).
