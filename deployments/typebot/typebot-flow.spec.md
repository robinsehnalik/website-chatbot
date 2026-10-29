# Typebot Conversational Flow Specification

This document provides the canonical block-by-block visual specification for assembling the Website AI Assistant in Typebot Builder (or Typebot Cloud).

> [!IMPORTANT]
> The HTTP Request block querying the Supabase Edge Function (`rag-query`) MUST be executed **server-side** inside Typebot so that the `X-Rag-Secret` header is never exposed to the visitor's browser.

---

## 1. Flow Diagram Overview

```
[Start Event]
      │
      ▼
[Group 1: Greeting & Bot Disclosure]
  - Text Bubble: Bot disclosure + Privacy Notice link
  - Text Input: "Ask a question..." -> saves to {{query}}
      │
      ▼
[Group 2: Grounded RAG Query (Server-Side HTTP Request)]
  - HTTP Request: POST /functions/v1/rag-query
    Headers: X-Rag-Secret, Content-Type
    Body: { query, sessionId, history }
    Response mapping: answer -> {{botAnswer}}, needs_human -> {{needsHuman}}, sources -> {{sources}}
      │
      ▼
[Group 3: Escalation Check]
  - Condition: If {{needsHuman}} is equal to "true"
      ├── (True) ──────────────┐
      └── (False)              ▼
           │             [Group 5: Escalation Intake]
           ▼               - Text Bubble: "Connecting you with our team..."
[Group 4: Display Answer]  - Text Input: Full Name -> saves to {{contactName}}
  - Text Bubble: {{botAnswer}}  - Email Input: Validated Email -> saves to {{contactEmail}}
  - Text Bubble (conditional): Sources: {{sources}} - Long Text Input: Inquiry Details -> saves to {{inquiry}}
  - Choice Input:              │
    • "Ask another question"    ▼
    • "Talk to a person" ────► [Group 6: Asynchronous Handoff Webhook]
                               - HTTP Request: POST n8n /webhook/chat/handoff
                                 Headers: X-Webhook-Secret: {{CHAT_WEBHOOK_SECRET}}
                                 Body: { sessionId, contactEmail, contactName, inquiry, source: "typebot" }
                               - Condition: Check HTTP Status == 200
                                 ├── (Success) ──► [Group 7: Confirmation & SLA]
                                 └── (Failure) ──► [Group 8: Fallback Channel]
```

---

## 2. Block-by-Block Configuration

### Group 1: Greeting & Transparency Disclosure
1. **Text Bubble Block**:
   ```text
   👋 Hello! I am the automated AI Assistant for our store. I can answer questions regarding shipping, returns, warranty, and store policies based on our documentation.

   For information on how we process your inquiry, please review our [Privacy Notice](https://example.com/privacy).
   ```
2. **Text Input Block**:
   - Placeholder: `Ask a question about our policies or services...`
   - Variable Assignment: `{{query}}`

### Group 2: Server-Side RAG Query Block
1. **HTTP Request Block** (configured to run on server):
   - **Method**: `POST`
   - **URL**: `https://<YOUR_SUPABASE_PROJECT>.supabase.co/functions/v1/rag-query`
   - **Headers**:
     - `Content-Type`: `application/json`
     - `X-Rag-Secret`: `<RAG_SHARED_SECRET>`
   - **Request Body**:
     ```json
     {
       "query": "{{query}}",
       "sessionId": "{{sessionId}}",
       "history": "{{history}}"
     }
     ```
   - **Response Variable Mapping**:
     - `answer` ➔ `{{botAnswer}}`
     - `needs_human` ➔ `{{needsHuman}}`
     - `sources` ➔ `{{sources}}`

### Group 3: Escalation Decision Router
1. **Condition Block**:
   - Rule: `{{needsHuman}}` `equals` `true`
   - **Output A (True)**: Connect to **Group 5 (Escalation Intake)**.
   - **Default Output (False)**: Connect to **Group 4 (Display Answer)**.

### Group 4: Answer Presentation & Continuation Loop
1. **Text Bubble Block**:
   ```text
   {{botAnswer}}
   ```
2. **Choice Input Block** (Persistent Options):
   - Option 1: `Ask another question` ➔ Loops back to **Group 1 (Text Input)**.
   - Option 2: `Talk to a person` ➔ Connects to **Group 5 (Escalation Intake)**.

### Group 5: Escalation & Contact Capture
1. **Text Bubble Block**:
   ```text
   I would be happy to connect you with a member of our human support team. Please provide your contact details so we can investigate and follow up with you.
   ```
2. **Text Input Block**:
   - Label: `Full Name`
   - Variable Assignment: `{{contactName}}`
3. **Email Input Block** (with client-side regex email validation enabled):
   - Label: `Email Address`
   - Variable Assignment: `{{contactEmail}}`
4. **Long Text Input Block** (optional / prefilled):
   - Label: `Additional details (optional)`
   - Variable Assignment: `{{inquiry}}` (defaults to `{{query}}` if left blank)

### Group 6: Secure n8n Handoff Webhook
1. **HTTP Request Block** (executed server-side):
   - **Method**: `POST`
   - **URL**: `https://<YOUR_N8N_INSTANCE>/webhook/chat/handoff`
   - **Headers**:
     - `Content-Type`: `application/json`
     - `X-Webhook-Secret`: `<CHAT_WEBHOOK_SECRET>`
   - **Request Body**:
     ```json
     {
       "sessionId": "{{sessionId}}",
       "contactEmail": "{{contactEmail}}",
       "contactName": "{{contactName}}",
       "inquiry": "{{inquiry}}",
       "source": "typebot"
     }
     ```
   - **Save Response Status**: `{{handoffStatus}}`
2. **Condition Block**:
   - Rule: `{{handoffStatus}}` `equals` `200`
   - **Output A (True)**: Connect to **Group 7 (Confirmation & SLA)**.
   - **Output B (False / Failure)**: Connect to **Group 8 (Fallback Channel)**.

### Group 7: Confirmation & Expected SLA
1. **Text Bubble Block**:
   ```text
   Thank you, {{contactName}}! Your support ticket has been logged with our team.
   
   We typically review and reply to inquiries sent to {{contactEmail}} within 1 business day (Monday–Friday, 9:00 AM – 5:00 PM EST).
   ```

### Group 8: Fallback Channel (Graceful Degradation)
1. **Text Bubble Block**:
   ```text
   We encountered an issue submitting your request automatically.
   
   Please email our support team directly at support@example.com with your question, and we will assist you as soon as possible.
   ```

---

## 3. Session Variable Definitions

| Variable Name | Scope | Description |
| :--- | :--- | :--- |
| `sessionId` | Session / Visit | Unique identifier generated per visitor session (e.g., UUID or Typebot session ID). |
| `query` | Temporary | Current user question input string. |
| `history` | Session | Array of prior conversational turns formatted as `[{role, content}]`. |
| `botAnswer` | Temporary | Grounded answer returned by `rag-query`. |
| `needsHuman` | Temporary | Boolean flag returned by `rag-query` indicating whether context was insufficient. |
| `sources` | Temporary | List of source titles and URLs returned by `rag-query`. |
| `contactName` | Session | Visitor's full name. |
| `contactEmail` | Session | Visitor's verified email address. |
| `inquiry` | Session | Full customer question/context passed to human handoff (max 1,000 characters). |
| `handoffStatus` | Temporary | HTTP response status code from the n8n handoff webhook. |
