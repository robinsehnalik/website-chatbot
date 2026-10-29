# Option B: Chatwoot Deployment Guide (Omnichannel / Live Agent Takeover)

## 1. Overview
In **Option B**, Chatwoot provides an omnichannel live chat widget, agent inbox, team routing, and mobile applications. `BOT-01 Chatwoot Bot Agent` handles automated RAG responses. When an escalation occurs, `BOT-01` reassigns the conversation to a human agent and sets status to `open`, which automatically silences the bot.

## 2. Architecture
```
[Visitor in Chatwoot Widget]
            │
            ▼
 [Chatwoot Webhook Event]
            │
            ▼
  [n8n BOT-01 Bot Agent]
            │
   ┌────────┴────────┐
   ▼                 ▼
[Normal Q&A]   [Escalation / Low Confidence]
   │                 │
(Query pgvector)  (PATCH /conversations/{id} status: "open")
   │                 │
   ▼                 ▼
[POST Bot Reply]  [Push Notification to Live Agent]
                     │
                     ▼
             [Human Agent Replies Live]
```

## 3. Implementation Steps

1. **Deploy Chatwoot**:
   - Self-host Chatwoot via Docker or Linux package (requires ~2-4 GB RAM).
2. **Create a Website Channel**:
   - In Chatwoot, go to **Settings > Inboxes > Add Inbox > Website Channel**.
   - Copy the embed code and paste it on your website.
3. **Create an Agent Bot**:
   - Go to **Settings > Inboxes > your website inbox > Collaborators**.
   - Create an Agent Bot or API Access Token under **Profile Settings > Access Token**.
   - Store this token as `CHATWOOT_BOT_TOKEN` in your n8n environment.
4. **Configure Webhook**:
   - Go to **Settings > Integrations > Webhooks > Add New Webhook**.
   - Set the URL to:
     `https://n8n.yourdomain.com/webhook/chat/chatwoot-agent`
   - Select events: `message_created`.
5. **Verify Bot Muting**:
   - When a human agent clicks "Assign to me" or types in the Chatwoot dashboard, `status` becomes `open`. `BOT-01` automatically ignores further visitor messages in that thread, allowing the human agent to communicate seamlessly.
