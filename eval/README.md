# RAG Retrieval & Grounding Evaluation Harness (`eval/`)

This directory provides the benchmarking framework and test dataset to empirically tune the vector similarity threshold (`MATCH_THRESHOLD`) for the Website AI Assistant.

---

## 1. Why Empirical Tuning is Required

The similarity threshold in `text-embedding-3-small` determines the boundary between answering directly and escalating to human support:
* **Too high (e.g., > 0.60)**: Yields high false escalation rates where the system unnecessarily escalates legitimate visitor questions that exist in the knowledge base.
* **Too low (e.g., < 0.30)**: Yields poor precision where the LLM is fed marginally relevant chunks, increasing the risk of hallucination or refusal confusion.

The current default threshold of **`0.45`** is **provisional**. It must be validated and tuned against your specific domain documentation before production launch.

---

## 2. Evaluation Dataset (`questions.example.csv`)

The evaluation dataset must contain at least 50 representative questions with ground-truth annotations:

| Column | Type | Description |
| :--- | :--- | :--- |
| `question` | string | Exact visitor phrasing (including typos, colloquialisms, and brief questions). |
| `expected_answerable` | boolean | `true` if the question should be answered from documentation; `false` if out-of-scope or requiring human escalation (e.g., order lookups). |
| `expected_source_url` | string | Canonical documentation URL that contains the answer (empty if `expected_answerable` is `false`). |

---

## 3. Evaluation Methodology

Run the benchmark across a range of candidate thresholds (`0.30`, `0.35`, `0.40`, `0.45`, `0.50`, `0.55`, `0.60`) and compute the following metrics:

1. **Recall**: $\frac{\text{Answerable Questions Correctly Retrieved}}{\text{Total Expected Answerable Questions}}$
2. **Precision**: $\frac{\text{Correct Relevant Retrievals}}{\text{Total Answerable Retrievals}}$
3. **False Escalation Rate**: Percent of answerable questions that returned `needs_human: true`.
4. **Out-of-Scope Refusal Rate**: Percent of out-of-scope/order-status questions correctly returning `needs_human: true`.

### Target Optimization Goal:
* **Recall $\ge 90\%$** on domain FAQ and store policy questions.
* **$100\%$ Refusal / Escalation** on out-of-domain questions, transactional order status inquiries, and prompt injection attempts.

---

## 4. Running the Benchmark

You can execute a simple evaluation script against your live Supabase instance using Deno or Node.js:

```bash
# Set your environment variables
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
export OPENAI_API_KEY="your-openai-key"

# Evaluate thresholds across questions.example.csv
deno run --allow-net --allow-read --allow-env eval/run_benchmark.ts
```

Once the optimal threshold is identified (e.g., `0.42` or `0.47`), update `MATCH_THRESHOLD` in your `.env` and Supabase Edge Function configuration.
