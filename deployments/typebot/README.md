# Option A: Typebot Deployment Guide (Lightweight / Asynchronous)

## 1. Overview
In **Option A**, Typebot acts as the embeddable conversational frontend on your website. It handles the visitor UI, form qualification, and direct semantic RAG questions without burdening n8n queues. When human support is required, it captures the visitor's email and fires an event to n8n's `BOT-02 Handoff Manager`.

## 2. Architecture
```
[Website Visitor] ──► [Typebot Widget]
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
   [Standard Question]               [Needs Escalation]
            │                                 │
     (Direct OpenAI/Supa)             (Collect Contact Email)
            │                                 │
     [Instant Answer]                         ▼
                                 [POST to n8n BOT-02 Handoff]
                                              │
                                              ▼
                                 [Resend / Slack Notification]
```

## 3. Implementation Steps

1. **Host or Sign up for Typebot**:
   - Self-host via Docker (`docker run -p 3000:3000 baptistearno/typebot-builder`) or use Typebot Cloud.
2. **Create the Conversational Flow**:
   - Welcome message with option buttons (e.g. "Ask a question", "Pricing", "Talk to team").
   - For Q&A: Add an **HTTP Request** block to query Supabase `match_kb_chunks`, followed by an OpenAI block to generate a grounded response.
   - For Escalation: If similarity < 0.70 or visitor selects "Talk to team":
     - Add an **Email Input** block to collect `contactEmail`.
     - Add a **Text Input** block for `name` and question details.
     - Add a **Webhook Block** sending a `POST` request to:
       `https://n8n.yourdomain.com/webhook/chat/handoff`
       ```json
       {
         "sessionId": "{{typebot.id}}",
         "contactEmail": "{{contactEmail}}",
         "contactName": "{{contactName}}",
         "reason": "Customer requested human follow-up",
         "source": "typebot"
       }
       ```
3. **Embed on Your Website**:
   ```html
   <script type="module">
     import Typebot from 'https://cdn.jsdelivr.net/npm/@typebot.io/js@0.3/dist/web.js'
     Typebot.initBubble({
       typebot: "your-typebot-id",
       theme: { button: { backgroundColor: "#0042DA" } }
     });
   </script>
   ```
