# Typebot Deployment & Configuration Guide

This directory contains the deployment resources and flow specifications for self-hosting **Typebot** as the embeddable conversational frontend for the Website AI Chatbot System.

---

## 1. Quickstart Self-Hosting (Docker Compose)

The provided [`docker-compose.yml`](./docker-compose.yml) deploys the complete Typebot stack with pinned image versions (`v3.4.1` for builder and viewer, and PostgreSQL 16).

### Step 1: Environment Configuration
Create a `.env` file in this directory alongside `docker-compose.yml`:

```env
# PostgreSQL Configuration
POSTGRES_DB=typebot
POSTGRES_USER=typebot
POSTGRES_PASSWORD=replace_with_a_secure_database_password

# Typebot URLs (configure with your public domain in production)
NEXTAUTH_URL=http://localhost:3000
NEXT_PUBLIC_VIEWER_URL=http://localhost:3001

# Security Secrets (generate a random 32-character string, e.g.: openssl rand -hex 16)
ENCRYPTION_SECRET=replace_with_a_32_character_hex_encryption_secret

# Administrator Email (grants initial admin privileges on first signup)
ADMIN_EMAIL=admin@yourdomain.com
DISABLE_SIGNUP=false
```

### Step 2: Start the Stack
```bash
docker compose up -d
```
Verify container health:
* Typebot Builder: `http://localhost:3000`
* Typebot Viewer: `http://localhost:3001`

---

## 2. Conversational Flow Setup

Follow the block-by-block instructions in [`typebot-flow.spec.md`](./typebot-flow.spec.md) to construct the flow in Typebot Builder:

1. **Bot Disclosure & Greeting**: Greets the visitor, states the assistant is automated, and provides a link to the company privacy policy.
2. **Server-Side HTTP Request**: Calls the Supabase Edge Function (`https://<PROJECT_REF>.supabase.co/functions/v1/rag-query`) with the `X-Rag-Secret` header. **Ensure this block is marked to execute server-side** so that the secret header is not visible to the client browser.
3. **Escalation Gating**: Evaluates `needs_human`. If `false`, displays the answer with clickable source citations; if `true`, collects visitor name, email, and inquiry context.
4. **Handoff Webhook**: Dispatches a `POST` request to n8n (`/webhook/chat/handoff`) with header `X-Webhook-Secret`.
5. **Fallback Handling**: If the handoff webhook fails (non-200), presents a direct support email address so the visitor is never left stranded.

---

## 3. Data Storage & Privacy in Typebot

* **Default Behavior**: Typebot persists conversation responses, user inputs, and session logs in its PostgreSQL database (`Results` and `Answers` tables) to provide visual analytics in the builder dashboard.
* **Retention Management**: If your data compliance policy mandates minimal transcript retention, you can schedule periodic cleanups on the Typebot database:
  ```sql
  -- Purge results older than 30 days
  DELETE FROM "Result" WHERE "createdAt" < NOW() - INTERVAL '30 days';
  ```
* **Client Turnstile Protection**: For production websites, consider wrapping the chat widget with Cloudflare Turnstile to prevent bot scraping and automated query quota abuse.

---

## 4. Website Embedding

Embed the Typebot chat bubble on your website before the closing `</body>` tag:

```html
<script type="module">
  import Typebot from 'https://cdn.jsdelivr.net/npm/@typebot.io/js@0.3/dist/web.js';

  Typebot.initBubble({
    typebot: "website-ai-assistant",
    apiHost: "https://viewer.yourdomain.com", // Your Typebot Viewer URL (omit if using Typebot Cloud)
    theme: {
      button: {
        backgroundColor: "#0042DA",
        customIcon: "💬"
      }
    }
  });
</script>
```
