import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { query, sessionId } = await req.json();

    if (!query || typeof query !== "string") {
      return new Response(JSON.stringify({ error: "Missing 'query' parameter" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const openAiKey = Deno.env.get("OPENAI_API_KEY");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!openAiKey || !supabaseUrl || !supabaseServiceKey) {
      throw new Error("Missing required environment variables in Edge Function.");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // 1. Generate Query Embedding
    const embedRes = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "text-embedding-3-small",
        input: query.trim(),
      }),
    });

    if (!embedRes.ok) {
      throw new Error(`OpenAI embedding failed: ${await embedRes.text()}`);
    }

    const embedData = await embedRes.json();
    const queryVector = embedData.data[0].embedding;

    // 2. Vector Search via Calibrated RPC (Threshold: 0.45 for text-embedding-3-small)
    const { data: chunks, error: rpcError } = await supabase.rpc("match_kb_chunks", {
      query_embedding: queryVector,
      match_threshold: 0.45,
      match_count: 4,
    });

    if (rpcError) {
      throw new Error(`RPC error: ${rpcError.message}`);
    }

    // 3. Fallback: If no chunks pass calibrated threshold -> Flag for Escalation
    if (!chunks || chunks.length === 0) {
      return new Response(
        JSON.stringify({
          answer: "I don't have enough specific information in our knowledge base to answer that accurately. Would you like me to connect you with our support team?",
          needs_human: true,
          sources: [],
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // 4. Grounded Completion via gpt-4o-mini
    const contextText = chunks.map((c: any, i: number) => `[Source ${i+1}]: ${c.content}`).join("\n\n");
    const sources = chunks.map((c: any) => ({
      title: c.document_title || "Help Article",
      url: c.source_url || null,
      similarity: c.similarity,
    }));

    const completionRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0.2,
        messages: [
          {
            role: "system",
            content: "You are the Official Website AI Support Assistant.\nAnswer the visitor's inquiry strictly and accurately using only the provided context.\nIf the context does not contain the answer, say you do not know and advise contacting support.\nKeep replies concise, friendly, and under 3 paragraphs.\n\nCONTEXT:\n" + contextText,
          },
          {
            role: "user",
            content: query,
          },
        ],
      }),
    });

    const completionData = await completionRes.json();
    const answerText = completionData.choices?.[0]?.message?.content || "Thank you for reaching out. How else can I help?";

    return new Response(
      JSON.stringify({
        answer: answerText,
        needs_human: false,
        sources: sources,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
