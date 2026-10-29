# Node-Level Implementation Requirements for n8n Workflows

In accordance with system policy (Rule 0.4: *"Never fabricate n8n workflow JSON... If you cannot edit safely, leave the file unchanged and describe the exact node-level edits in CHANGES-REQUIRED.md next to it"*), this document provides the exact node-by-node architectural blueprint for advanced workflow logic that requires graph rewiring beyond the core validated JSON exports.

---

## 1. BOT-02 Handoff & Escalation Manager: Deduplication & Rate Limiting

The baseline workflow [`bot-02-handoff-manager.json`](./bot-02-handoff-manager.json) currently handles:
1. `Webhook: /chat/handoff` trigger.
2. `Verify Secret & Normalize Payload` (validates `X-Webhook-Secret`, email regex, session ID, 1,000-char inquiry length, and HTML-escapes content).
3. `Supabase: Insert Handoff Ticket` (persists ticket with `service_role`).
4. `Resend: Send Support Notification` (dispatches support team email alert).
5. `Respond to Webhook` (returns `{ success: true, ticket_id }`).

### Required Additional Nodes

To prevent alert fatigue and inbox flooding from automated or repeated user clicks, the following two guardrails must be inserted between `Verify Secret & Normalize Payload` and `Supabase: Insert Handoff Ticket`:

#### Node A: Check 10-Minute Session Deduplication
* **Node Type**: `n8n-nodes-base.httpRequest`
* **Name**: `Supabase: Check Recent Session Handoff`
* **Method**: `GET`
* **URL**: `={{ $env.SUPABASE_URL }}/rest/v1/handoffs?session_id=eq.{{ $json.session_id }}&created_at=gte.{{ new Date(Date.now() - 10 * 60 * 1000).toISOString() }}&select=id,created_at&limit=1`
* **Headers**:
  * `apikey`: `={{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  * `Authorization`: `Bearer {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
* **Purpose**: Identifies if an escalation ticket was already created for this session within the past 10 minutes.

#### Node B: If Session Already Escalated
* **Node Type**: `n8n-nodes-base.if`
* **Name**: `If Session Duplicate`
* **Conditions**: String `{{ $json[0]?.id }}` is not empty.
* **True Branch**: Connect to `Respond: Duplicate Acknowledged`
  * Response Body:
    ```json
    {
      "success": true,
      "deduplicated": true,
      "ticket_id": "{{ $('Supabase: Check Recent Session Handoff').item.json[0].id }}",
      "message": "Your ticket is already being reviewed by our team."
    }
    ```
* **False Branch**: Route to **Node C**.

#### Node C: Check 24-Hour Per-Email Rate Limit
* **Node Type**: `n8n-nodes-base.httpRequest`
* **Name**: `Supabase: Count Recent Email Handoffs`
* **Method**: `GET`
* **URL**: `={{ $env.SUPABASE_URL }}/rest/v1/handoffs?contact_email=eq.{{ $json.contact_email }}&created_at=gte.{{ new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString() }}&select=id`
* **Headers**:
  * `apikey`: `={{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  * `Authorization`: `Bearer {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  * `Prefer`: `count=exact`
* **Purpose**: Counts tickets created by this email address in the last 24 hours.

#### Node D: If Email Rate Limit Exceeded
* **Node Type**: `n8n-nodes-base.if`
* **Name**: `If Email Limit Exceeded ( > 3 )`
* **Conditions**: Number of returned items `{{ $json.length }}` is greater than `3`.
* **True Branch**: Connect to `Respond: Rate Limited`
  * Response Body:
    ```json
    {
      "success": true,
      "rate_limited": true,
      "message": "Maximum support requests reached for this email in 24 hours. Our team is already processing your earlier inquiries."
    }
    ```
* **False Branch**: Proceed to `Supabase: Insert Handoff Ticket` ➔ `Resend: Send Support Notification` ➔ `Respond to Webhook`.

---

## 2. BOT-03 Knowledge Ingestion & Sync: Complete Document Crawler & Deletion Algorithm

The baseline workflow [`bot-03-knowledge-sync.json`](./bot-03-knowledge-sync.json) executes on a daily schedule (`0 3 * * *`), reads `kb_documents`, chunks content, generates embeddings via `text-embedding-3-small`, and upserts to `kb_chunks`.

To maintain a true synchronized reflection of live public documentation, the crawler logic must be extended with HTTP fetching and stale chunk deletion:

### Node-Level Crawl & Ingestion Sequence

```
[Daily Schedule / Manual Trigger]
              │
              ▼
[1. Supabase: Fetch All kb_documents]
              │
              ▼
[2. SplitInBatches (Batch Size: 1)]
              │
              ▼
[3. HTTP Request: Fetch Live URL Content] ──── (404 or 410) ────► [3A. Supabase: Delete Document]
              │                                                     - DELETE /rest/v1/kb_documents?id=eq.{{$json.id}}
              ▼ (200 OK)                                             - (Cascades automatically to kb_chunks)
[4. Code: Clean HTML, Chunk & Hash]
   - Parse HTML, extract text, strip navigation/scripts/footers.
   - Sliding window: 400 chars, 50 char overlap.
   - Compute SHA-256 content_hash per chunk.
   - Output: array of chunks + list of current_hashes for this doc.
              │
              ▼
[5. OpenAI: Generate Embeddings]
   - Batch embed chunks using text-embedding-3-small.
              │
              ▼
[6. Supabase: Upsert Chunks]
   - POST /rest/v1/kb_chunks
   - Prefer: resolution=merge-duplicates (on conflict: document_id, content_hash)
              │
              ▼
[7. Supabase: Prune Stale Chunks]
   - Execute deletion RPC or query:
     DELETE FROM kb_chunks 
     WHERE document_id = {{ $json.document_id }} 
       AND content_hash NOT IN ({{ $json.current_hashes.join(',') }});
              │
              ▼
[8. Loop Back to SplitInBatches]
```

### Stale Chunk Deletion Query Specification
When a public documentation page is updated, old chunks that no longer exist in the new revision must be purged to avoid hallucinating obsolete policies:

```sql
-- PostgREST RPC call or direct SQL via postgres node
DELETE FROM kb_chunks
WHERE document_id = $1
  AND content_hash != ALL($2::text[]);
```

If a URL returns HTTP 404 (Not Found) or HTTP 410 (Gone):
```sql
DELETE FROM kb_documents WHERE id = $1;
-- Foreign key ON DELETE CASCADE automatically deletes all child chunks in kb_chunks
```
