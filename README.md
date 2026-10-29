# Website AI Chatbot System — Deployment & Implementation Guide

## 1. System Overview

The **Website AI Chatbot System** provides intelligent customer support and seamless human handoff with zero n8n workflow queue congestion.

* **Visitor Query Loop**: Powered by **Typebot** and a serverless **Supabase Edge Function (`rag-query`)**. Visitor questions are embedded, searched via calibrated pgvector similarity ($\ge 0.45$), and answered with grounded citations in ~1.2 seconds.
* **Human Escalation Loop**: Handled asynchronously by **n8n (`BOT-02`)**. When a visitor requests human help or an answer cannot be grounded, Typebot collects the visitor's contact info and dispatches an authenticated webhook (`X-Webhook-Secret`) to n8n, which logs the ticket and alerts the team via Resend.

```
VISITOR QUERY LOOP (Real-time, Sub-2s)
[Visitor] ──► [Typebot Widget] ──► [Supabase Edge Function: rag-query]
                                                    │
                               ┌────────────────────┴────────────────────┐
                               ▼                                         ▼
                   [OpenAI Embeddings & LLM]                   [Supabase pgvector (HNSW)]

ASYNCHRONOUS ESCALATION LOOP
[Visitor Requests Human] ──► [Typebot Collects Email]
                                       │
                                       ▼ (Webhook with X-Webhook-Secret)
                         [n8n BOT-02 Handoff Manager]
                                       │
                               ┌───────┴───────┐
                               ▼               ▼
                        [Supabase Ticket] [Resend Email Alert to Team]
```

---

## 2. Quickstart Deployment

### Step 1: Execute Database Schema
Run [`sql/schema.sql`](./sql/schema.sql) in your Supabase SQL Editor. This enables `pgvector`, creates `kb_documents`, `kb_chunks` (with HNSW index), `handoffs`, and configures Row Level Security (RLS).

### Step 2: Deploy Supabase Edge Function
Deploy the `rag-query` function using the Supabase CLI:
```bash
supabase functions deploy rag-query --project-ref YOUR_PROJECT_REF
supabase secrets set OPENAI_API_KEY=sk-... --project-ref YOUR_PROJECT_REF
```

### Step 3: Import Typebot Visual Flow
1. Open your Typebot Builder dashboard.
2. Create a new Typebot and select **Import**.
3. Upload [`deployments/typebot/typebot-flow-export.json`](./deployments/typebot/typebot-flow-export.json).
4. Update the Webhook blocks with your Supabase Edge Function URL and n8n webhook URL.
5. Publish the bot.

### Step 4: Import n8n Workflows
Import the workflows from `n8n-workflows/`:
* [`bot-02-handoff-manager.json`](./n8n-workflows/bot-02-handoff-manager.json)
* [`bot-03-knowledge-sync.json`](./n8n-workflows/bot-03-knowledge-sync.json)
* [`bot-err-error-handler.json`](./n8n-workflows/bot-err-error-handler.json)

---

## 3. Environment Variables

| Variable | Description | Used In |
| :--- | :--- | :--- |
| `OPENAI_API_KEY` | OpenAI API Key (`text-embedding-3-small` & `gpt-4o-mini`) | Edge Function, `BOT-03` |
| `SUPABASE_URL` | Supabase API endpoint (`https://xyz.supabase.co`) | Edge Function, `BOT-02`, `BOT-03` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase Service Role key | Edge Function, `BOT-02`, `BOT-03` |
| `CHAT_WEBHOOK_SECRET` | Shared secret header (`X-Webhook-Secret`) to authenticate handoffs | Typebot, `BOT-02` |
| `RESEND_API_KEY` | Resend API key for support ticket alerts | `BOT-02`, `BOT-ERR` |
| `SYSTEM_SENDER_EMAIL` | Verified sender address (e.g. `support@yourdomain.com`) | `BOT-02`, `BOT-ERR` |
| `OWNER_NOTIFICATION_EMAIL` | Destination email for human handoff alerts | `BOT-02` |
| `LINK_TO_YOUR_DASHBOARD` | URL to your support ticket dashboard or CRM | `BOT-02` |

---

## 4. Website Embedding Snippet

Paste this snippet into your website before the closing `</body>` tag:

```html
<script type="module">
  import Typebot from 'https://cdn.jsdelivr.net/npm/@typebot.io/js@0.3/dist/web.js';

  Typebot.initBubble({
    typebot: "website-ai-assistant",
    apiHost: "https://typebot.yourdomain.com", // Omit if using Typebot Cloud
    theme: {
      button: {
        backgroundColor: "#0042DA",
        customIcon: "💬"
      }
    }
  });
</script>
```
