# Multi-Agent n8n System (Self-hosted) with Supabase + Notion

This project provides a production-oriented multi-agent workflow system in self-hosted n8n. It ingests social data (YouTube, X/Twitter, TikTok via Apify, Reddit, optional Meta Ads), performs distributed analysis with Claude, coordinates agents through a Supabase Postgres mailbox/blackboard, and writes final reports to Notion.

## Architecture Summary

- **Orchestration**: `Coordinator (Task Router)` claims queued tasks, creates collaboration threads, and dispatches mailbox messages to specialist agents.
- **Collaboration Layer**: `agent_threads`, `agent_messages`, and `blackboard` tables implement mailbox + blackboard communication.
- **Analysis**: each agent claims one message atomically (`FOR UPDATE SKIP LOCKED`), sanitizes input, calls Anthropic Messages API, validates JSON, retries/repairs on malformed output, and writes results to DB.
- **Report Sink**: `Report Writer Agent` writes artifacts into Postgres and creates a Notion page in `NOTION_DATABASE_ID`.
- **Notifications**: `Notifier Agent` can send Slack alerts (toggle) and optional callback webhooks.
- **SaaS API**: n8n webhook workflow exposes task creation, status, reports, and optional agent introspection.

---

## 1) Setup

### A. Provision Supabase and run SQL

1. Create a Supabase project.
2. Open Supabase **SQL Editor**.
3. Run `schema.sql` from this repo.
4. Confirm extension enabled:
   - `create extension if not exists pgcrypto;`

### B. Create dedicated DB user (least privilege)

Use a dedicated role for n8n, for example `n8n_agent`, and grant minimum required rights:

- `SELECT, INSERT, UPDATE` on operational tables.
- `USAGE, SELECT` on sequences.
- Avoid superuser and avoid granting broad DDL rights in production.

### C. Configure n8n credentials (by name)

Create these n8n credential records:

- **Postgres** credential named: `Supabase Postgres`
  - Host: `SUPABASE_DB_HOST`
  - Port: `SUPABASE_DB_PORT`
  - Database: `SUPABASE_DB_NAME`
  - User: `SUPABASE_DB_USER`
  - Password: `SUPABASE_DB_PASSWORD`
  - SSL: enabled (`sslmode=require`)
- **Notion API** credential named: `Notion API`
- **Slack API** credential named: `Slack API` (optional)
- Anthropic uses HTTP node headers from env (`x-api-key`); no hard-coded secrets in workflow JSON.

### D. Configure environment variables

1. Copy `.env.example` to `.env`.
2. Fill all required values.
3. For Docker, pass `.env` into n8n container.

Minimal required values for baseline operation:

- Supabase direct DB credentials
- `ANTHROPIC_API_KEY`
- `NOTION_API_KEY`
- `NOTION_DATABASE_ID`
- `SAAS_API_KEY`

### E. Import workflows

1. In n8n UI: **Workflows → Import from File**.
2. Import `n8n-export.json`.
3. Verify all workflows are present:
   - Coordinator
   - 14 agent workflows
   - SaaS API workflow
4. Activate workflows as needed.

---

## 2) Docker Compose example

```yaml
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    env_file:
      - .env
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - ./n8n_data:/home/node/.n8n
```

---

## 3) Multi-agent mailbox protocol

### Message claiming

Each agent executes atomic claim SQL:

```sql
UPDATE public.agent_messages
SET state='claimed', attempts=attempts+1, updated_at=now()
WHERE id = (
  SELECT id FROM public.agent_messages
  WHERE to_agent=$AGENT_NAME AND state='queued'
  ORDER BY priority DESC, created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING *;
```

This prevents race conditions when multiple workers poll concurrently.

### Message lifecycle

`queued -> claimed -> in_progress -> done`

Failure path:

- validation/tool/API error → `queued` retry (until max attempts)
- max attempts exceeded → `failed`

### Agent collaboration

- Use `kind='ask'` to request peer assistance with `expected_schema`.
- Peer returns `kind='answer'` with structured payload.
- Shared durable context is written to `blackboard(task_id, key, value, producer_agent)`.

---

## 4) Notion reporting

### Required Notion setup

1. Create a Notion integration; copy token to `NOTION_API_KEY`.
2. Share target database with integration.
3. Set `NOTION_DATABASE_ID`.

### Suggested Notion database properties

- `Name` (title)
- `Task ID` (rich_text)
- `Status` (select)
- `Created At` (date)
- `Platforms` (multi_select)
- `Quality Score Avg` (number)
- `Notion URL` (url, optional if mirrored)

### Report writer behavior

- Writes `markdown`, `html`, `json_summary` to `public.reports` + `public.artifacts`.
- Creates/updates Notion page using the Notion node.
- Stores Notion page id/url back to report metadata.

---

## 5) Cost, quotas, and rate-limits

### Platform quotas

- **YouTube Data API**: monitor quota units; cap by query/date window.
- **X/Twitter v2**: strict rate controls depending on app tier.
- **Apify TikTok**: cost tied to actor runs and dataset size.
- **Reddit**: respect OAuth limits and user agent policy.
- **Meta Ads Library**: policy/region constraints; keep optional behind toggle.

### Recommended defaults

- `BATCH_SIZE=10`
- `RATE_LIMIT_DELAY_MS=1200`
- retries: max 3 with random jitter (`MESSAGE_RETRY_JITTER_MS=2000`)
- keep `max_items` conservative per platform to avoid spikes

### Retry/backoff

- On `429`/`5xx`: wait + requeue message.
- Persist error details to `agent_messages.error` and `logs.meta`.

---

## 6) Troubleshooting

### JSON schema validation failures (LLM output)

- Symptom: message loops with invalid JSON.
- Fix:
  - lower temperature (`ANTHROPIC_TEMPERATURE=0.2-0.3`)
  - enforce strict system prompt (`JSON only`)
  - keep repair step enabled (repair prompt branch)

### Stuck `claimed` / `in_progress` messages

- Check agent workflow execution status in n8n.
- Inspect `public.agent_messages` for stale rows.
- Add sweeper job to requeue stale claims older than SLA threshold.

### 429/5xx bursts

- Increase `RATE_LIMIT_DELAY_MS`.
- Lower `BATCH_SIZE`.
- Add platform-specific cooldown in ingestion workflows.

### Supabase SSL issues

- Ensure Postgres credential uses SSL with `sslmode=require`.
- Verify network egress/firewall from n8n host.

### Token rotation

- Rotate API tokens regularly.
- Keep credentials in n8n credential store and env, never in node literals.

---

## 7) Security and compliance notes

- Protect SaaS endpoints with `x-api-key` (`SAAS_API_KEY`).
- Restrict optional introspection endpoints (`/v1/agents/threads*`) to internal usage.
- Keep optional connectors behind toggles:
  - `ENABLE_TWITTER`
  - `ENABLE_TIKTOK`
  - `ENABLE_META_ADS`
  - `ENABLE_SLACK`
- Respect platform Terms of Service and scraping policies.
- For Supabase REST/PostgREST usage, apply RLS policies and prefer `service_role` server-side access only.
- Direct Postgres (recommended for n8n server workflows) should use least-privilege DB users.

---

## 8) Files in this deliverable

- `n8n-export.json` → single n8n export containing all workflows
- `schema.sql` → Supabase-compatible DDL + indexes + helper function
- `openapi.yaml` → OpenAPI 3.0 spec for SaaS endpoints
- `.env.example` → required env vars and feature toggles
- `README.md` → setup, operations, troubleshooting, security guidance
