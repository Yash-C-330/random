-- ============================================================
-- Multi-Agent n8n System — Supabase Postgres DDL (IMPROVED)
-- Enhanced with: better indexes, constraints, monitoring tables
-- Run this in Supabase SQL Editor (or psql) as a superuser.
-- ============================================================

-- ─── Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gin;  -- For complex index types

-- ============================================================
-- MAIN OPERATIONAL TABLES
-- ============================================================

-- ─── Tasks ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tasks (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    status              text        NOT NULL DEFAULT 'queued'
                                    CHECK (status IN ('queued','running','done','failed','cancelled')),
    queries             jsonb       NOT NULL DEFAULT '[]',
    competitors         jsonb       NOT NULL DEFAULT '[]',
    platforms           jsonb       NOT NULL DEFAULT '["youtube"]',
    date_range_start    date,
    date_range_end      date,
    max_items           int         NOT NULL DEFAULT 50,
    language            text        NOT NULL DEFAULT 'en',
    notify_webhook      text,
    created_by          text,
    error               text,
    progress            jsonb       NOT NULL DEFAULT '{}',
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes for common filter + sort patterns
CREATE INDEX IF NOT EXISTS tasks_status_created_idx     ON public.tasks (status, created_at DESC);
CREATE INDEX IF NOT EXISTS tasks_created_by_status_idx  ON public.tasks (created_by, status);
CREATE INDEX IF NOT EXISTS tasks_date_range_idx         ON public.tasks (date_range_start, date_range_end);

-- Partial index: active tasks only (faster queries)
CREATE INDEX IF NOT EXISTS tasks_active_idx             ON public.tasks (created_at DESC) 
    WHERE status IN ('queued', 'running');

-- JSONB containment indexes
CREATE INDEX IF NOT EXISTS tasks_platforms_jsonb_idx    ON public.tasks USING GIN (platforms);
CREATE INDEX IF NOT EXISTS tasks_queries_jsonb_idx      ON public.tasks USING GIN (queries);

-- ─── Social Raw ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.social_raw (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
    platform        text        NOT NULL,
    native_id       text        NOT NULL,
    dedupe_key      text        NOT NULL UNIQUE,      -- sha256(platform || ':' || native_id)
    url             text,
    title           text,
    description     text,
    author          text,
    author_id       text,
    body_text       text,
    thumbnail_url   text,
    canonical_url   text,
    language        text,
    published_at    timestamptz,
    raw_json        jsonb       NOT NULL DEFAULT '{}',
    enriched        boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes for common queries
CREATE INDEX IF NOT EXISTS social_raw_platform_id_idx           ON public.social_raw (platform, native_id);
CREATE INDEX IF NOT EXISTS social_raw_task_id_created_idx       ON public.social_raw (task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS social_raw_published_at_idx          ON public.social_raw (published_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS social_raw_task_id_enriched_idx      ON public.social_raw (task_id, enriched)
    WHERE enriched = false;

-- JSONB indexes
CREATE INDEX IF NOT EXISTS social_raw_raw_json_idx              ON public.social_raw USING GIN (raw_json);

-- ─── Social Analysis ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.social_analysis (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_id                  uuid        NOT NULL REFERENCES public.social_raw (id) ON DELETE CASCADE,
    task_id                 uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    agent                   text        NOT NULL,
    topics                  jsonb       DEFAULT '[]',
    creative_type           text,
    hook_style              text,
    target_audience         text,
    emotional_tone          text,
    compliance_flags        jsonb       DEFAULT '[]',
    cta_type                text,
    claims_summary          text,
    quality_score           int         CHECK (quality_score BETWEEN 0 AND 100),
    reasons                 text,
    top_quote               text,
    hashtags                jsonb       DEFAULT '[]',
    entities                jsonb       DEFAULT '{}',
    suggested_counter_angles jsonb      DEFAULT '[]',
    brand_safety_risks      jsonb       DEFAULT '[]',
    language                text,
    detected_format         text,
    raw_llm_response        jsonb,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes
CREATE INDEX IF NOT EXISTS social_analysis_task_agent_idx       ON public.social_analysis (task_id, agent);
CREATE INDEX IF NOT EXISTS social_analysis_raw_id_task_idx      ON public.social_analysis (raw_id, task_id);
CREATE INDEX IF NOT EXISTS social_analysis_agent_created_idx    ON public.social_analysis (agent, created_at DESC);
CREATE INDEX IF NOT EXISTS social_analysis_quality_score_idx    ON public.social_analysis (quality_score DESC)
    WHERE quality_score IS NOT NULL;

-- JSONB indexes for filtering
CREATE INDEX IF NOT EXISTS social_analysis_topics_jsonb_idx     ON public.social_analysis USING GIN (topics);
CREATE INDEX IF NOT EXISTS social_analysis_compliance_jsonb_idx ON public.social_analysis USING GIN (compliance_flags);

-- ─── Reports ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reports (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        NOT NULL UNIQUE REFERENCES public.tasks (id) ON DELETE CASCADE,
    status          text        NOT NULL DEFAULT 'draft'
                                CHECK (status IN ('draft','final','failed')),
    title           text,
    markdown        text,
    html            text,
    json_summary    jsonb,
    notion_page_id  text,
    notion_url      text,
    meta            jsonb       DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Covering index for common status query
CREATE INDEX IF NOT EXISTS reports_status_created_idx   ON public.reports (status, created_at DESC);

-- ─── Logs ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.logs (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ts          timestamptz NOT NULL DEFAULT now(),
    level       text        NOT NULL DEFAULT 'info'
                            CHECK (level IN ('debug','info','warn','error')),
    agent       text        NOT NULL,
    task_id     uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
    thread_id   uuid        REFERENCES public.agent_threads (id) ON DELETE SET NULL,
    message     text        NOT NULL,
    meta        jsonb       DEFAULT '{}'
);

-- Covering indexes for common queries
CREATE INDEX IF NOT EXISTS logs_ts_level_idx            ON public.logs (ts DESC, level);
CREATE INDEX IF NOT EXISTS logs_task_id_ts_idx          ON public.logs (task_id, ts DESC);
CREATE INDEX IF NOT EXISTS logs_agent_ts_idx            ON public.logs (agent, ts DESC);

-- Partial index: error logs only (useful for alert queries)
CREATE INDEX IF NOT EXISTS logs_errors_idx              ON public.logs (ts DESC)
    WHERE level IN ('error', 'warn');

-- ─── Agent Threads ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_threads (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    topic       text        NOT NULL,
    status      text        NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open','closing','closed')),
    owner_agent text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes
CREATE INDEX IF NOT EXISTS agent_threads_task_id_status_idx ON public.agent_threads (task_id, status);
CREATE INDEX IF NOT EXISTS agent_threads_owner_agent_idx     ON public.agent_threads (owner_agent, status);

-- ─── Agent Messages (Mailbox) ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_messages (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id       uuid        NOT NULL REFERENCES public.agent_threads (id) ON DELETE CASCADE,
    task_id         uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    from_agent      text        NOT NULL,
    to_agent        text        NOT NULL,
    kind            text        NOT NULL
                                CHECK (kind IN ('task','ask','answer','tool','log','error')),
    priority        int         NOT NULL DEFAULT 1 CHECK (priority >= 0 AND priority <= 10),
    state           text        NOT NULL DEFAULT 'queued'
                                CHECK (state IN ('queued','claimed','in_progress','done','blocked','failed')),
    attempts        int         NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts    int         NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
    payload         jsonb       NOT NULL DEFAULT '{}',
    expected_schema jsonb,
    error           text,
    claimed_at      timestamptz,
    completed_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Critical covering indexes: optimize the atomic claim query
CREATE INDEX IF NOT EXISTS agent_messages_claim_idx    ON public.agent_messages (to_agent, state, priority DESC, created_at ASC)
    WHERE state = 'queued';

-- Additional covering indexes
CREATE INDEX IF NOT EXISTS agent_messages_thread_created_idx   ON public.agent_messages (thread_id, created_at DESC);
CREATE INDEX IF NOT EXISTS agent_messages_task_state_idx       ON public.agent_messages (task_id, state);
CREATE INDEX IF NOT EXISTS agent_messages_from_to_idx          ON public.agent_messages (from_agent, to_agent);

-- Partial index: failed/blocked messages for quick error queries
CREATE INDEX IF NOT EXISTS agent_messages_failed_idx    ON public.agent_messages (created_at DESC)
    WHERE state IN ('failed', 'blocked');

-- ─── Blackboard ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.blackboard (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    key             text        NOT NULL,
    value           jsonb       NOT NULL DEFAULT '{}',
    producer_agent  text        NOT NULL,
    version         int         NOT NULL DEFAULT 1,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (task_id, key)
);

-- Covering indexes
CREATE INDEX IF NOT EXISTS blackboard_task_id_created_idx   ON public.blackboard (task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS blackboard_producer_agent_idx    ON public.blackboard (producer_agent);

-- ─── Artifacts ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.artifacts (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    type        text        NOT NULL
                            CHECK (type IN ('markdown','html','json','csv','image','raw')),
    label       text        NOT NULL,
    content     text,
    size_bytes  int,
    meta        jsonb       DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes
CREATE INDEX IF NOT EXISTS artifacts_task_type_idx     ON public.artifacts (task_id, type);
CREATE INDEX IF NOT EXISTS artifacts_created_at_idx    ON public.artifacts (created_at DESC);

-- ============================================================
-- MONITORING & OBSERVABILITY TABLES
-- ============================================================

-- ─── Execution Events (fine-grained tracing)────────────────
CREATE TABLE IF NOT EXISTS public.execution_events (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    thread_id       uuid        REFERENCES public.agent_threads (id) ON DELETE CASCADE,
    message_id      uuid        REFERENCES public.agent_messages (id) ON DELETE CASCADE,
    agent           text        NOT NULL,
    event_type      text        NOT NULL
                                CHECK (event_type IN ('message_claimed','api_call_start','api_call_end','validation_pass','validation_fail','db_write','retry')),
    duration_ms     int,
    status          text        CHECK (status IN ('success','failure','partial')),
    error_msg       text,
    metadata        jsonb       DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes for tracing
CREATE INDEX IF NOT EXISTS exec_events_task_agent_ts_idx  ON public.execution_events (task_id, agent, created_at DESC);
CREATE INDEX IF NOT EXISTS exec_events_message_id_idx     ON public.execution_events (message_id);
CREATE INDEX IF NOT EXISTS exec_events_event_type_idx     ON public.execution_events (event_type, created_at DESC);

-- ─── Agent Metrics (aggregated performance)──────────────────
CREATE TABLE IF NOT EXISTS public.agent_metrics (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id             uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    agent               text        NOT NULL,
    
    -- Execution timing
    total_duration_ms   int,
    api_latency_ms      int,
    db_latency_ms       int,
    
    -- Efficiency
    messages_processed  int         NOT NULL DEFAULT 0,
    messages_failed     int         NOT NULL DEFAULT 0,
    retries_used        int         NOT NULL DEFAULT 0,
    
    -- Quality
    validation_passed   boolean,
    output_size_bytes   int,
    
    -- Cost (if tracking)
    token_usage         jsonb       DEFAULT '{"input":0,"output":0}',
    estimated_cost      numeric(10,4),
    
    -- Status
    status              text        NOT NULL DEFAULT 'pending'
                                    CHECK (status IN ('pending','completed','failed','partial')),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Covering indexes for metrics queries
CREATE INDEX IF NOT EXISTS agent_metrics_task_agent_idx   ON public.agent_metrics (task_id, agent);
CREATE INDEX IF NOT EXISTS agent_metrics_agent_status_idx ON public.agent_metrics (agent, status);

-- ─── Rate Limit Log (API quota tracking)─────────────────────
CREATE TABLE IF NOT EXISTS public.rate_limit_log (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    service         text        NOT NULL
                                CHECK (service IN ('anthropic','notion','slack','youtube','twitter','reddit','apify')),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
    agent           text,
    
    -- Rate limit info
    remaining_quota int,
    reset_at        timestamptz,
    throttle_until  timestamptz,
    
    -- Incident
    was_throttled   boolean     NOT NULL DEFAULT false,
    backoff_ms      int,
    
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Indexes for quota alerts
CREATE INDEX IF NOT EXISTS rate_limit_service_reset_idx   ON public.rate_limit_log (service, reset_at DESC);
CREATE INDEX IF NOT EXISTS rate_limit_throttled_idx       ON public.rate_limit_log (created_at DESC)
    WHERE was_throttled = true;

-- ─── Deadletter Messages (failed after retries)──────────────
CREATE TABLE IF NOT EXISTS public.deadletter_messages (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    original_msg_id uuid        REFERENCES public.agent_messages (id) ON DELETE SET NULL,
    task_id         uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    thread_id       uuid        REFERENCES public.agent_threads (id) ON DELETE CASCADE,
    from_agent      text        NOT NULL,
    to_agent        text        NOT NULL,
    kind            text        NOT NULL,
    payload         jsonb       NOT NULL DEFAULT '{}',
    attempts        int         NOT NULL,
    final_error     text,
    resolution      text,       -- e.g., 'manual_retry', 'escalated', 'skipped'
    created_at      timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz
);

-- Indexes for deadletter queue monitoring
CREATE INDEX IF NOT EXISTS deadletter_task_agent_idx     ON public.deadletter_messages (task_id, to_agent);
CREATE INDEX IF NOT EXISTS deadletter_resolved_idx       ON public.deadletter_messages (created_at DESC)
    WHERE resolved_at IS NULL;

-- ============================================================
-- HELPER FUNCTIONS & VIEWS
-- ============================================================

-- ─── Log Writer Function ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.write_log(
    p_level     text,
    p_agent     text,
    p_task_id   uuid,
    p_thread_id uuid DEFAULT NULL,
    p_message   text DEFAULT '',
    p_meta      jsonb DEFAULT '{}'
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.logs (level, agent, task_id, thread_id, message, meta)
    VALUES (p_level, p_agent, p_task_id, p_thread_id, p_message, p_meta);
$$;

-- ─── Record Execution Event ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_execution_event(
    p_task_id       uuid,
    p_agent         text,
    p_event_type    text,
    p_duration_ms   int DEFAULT NULL,
    p_status        text DEFAULT 'success',
    p_error_msg     text DEFAULT NULL,
    p_metadata      jsonb DEFAULT '{}'
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.execution_events 
        (task_id, agent, event_type, duration_ms, status, error_msg, metadata)
    VALUES (p_task_id, p_agent, p_event_type, p_duration_ms, p_status, p_error_msg, p_metadata);
$$;

-- ─── Task Summary View ──────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_task_summary AS
SELECT 
    t.id,
    t.status,
    t.created_by,
    t.created_at,
    COUNT(DISTINCT sr.id)::int              AS total_social_items,
    COUNT(DISTINCT sa.id)::int              AS total_analyzed,
    COUNT(DISTINCT am.id)::int              AS total_messages,
    COUNT(DISTINCT am.id) FILTER (WHERE am.state = 'failed')::int AS failed_messages,
    MAX(am.updated_at)                      AS last_activity,
    (SELECT COUNT(*) FROM public.reports WHERE task_id = t.id) AS report_count
FROM public.tasks t
LEFT JOIN public.social_raw sr            ON sr.task_id = t.id
LEFT JOIN public.social_analysis sa       ON sa.task_id = t.id
LEFT JOIN public.agent_messages am        ON am.task_id = t.id
GROUP BY t.id, t.status, t.created_by, t.created_at;

-- ─── Agent Health View ──────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_agent_health AS
SELECT 
    agent,
    COUNT(*)::int                           AS total_messages,
    COUNT(*) FILTER (WHERE state = 'done')::int AS completed,
    COUNT(*) FILTER (WHERE state = 'failed')::int AS failed,
    ROUND(100.0 * COUNT(*) FILTER (WHERE state = 'done') / NULLIF(COUNT(*), 0), 1) AS success_rate,
    AVG(EXTRACT(EPOCH FROM (COALESCE(completed_at, now()) - created_at)) * 1000)::int AS avg_duration_ms,
    MAX(updated_at)                         AS last_activity
FROM public.agent_messages
GROUP BY agent;

-- ─── Task Performance View ──────────────────────────────────
CREATE OR REPLACE VIEW public.vw_task_performance AS
SELECT 
    am.task_id,
    am.agent,
    COUNT(*)::int                           AS message_count,
    COUNT(*) FILTER (WHERE am.state = 'failed')::int AS failed_count,
    AVG(am.attempts)::numeric(4,2)          AS avg_attempts,
    MIN(am.created_at)                      AS start_time,
    MAX(am.updated_at)                      AS end_time,
    EXTRACT(EPOCH FROM (MAX(am.updated_at) - MIN(am.created_at)))::int / 60 AS duration_minutes
FROM public.agent_messages am
GROUP BY am.task_id, am.agent;

-- ============================================================
-- MIGRATION NOTES
-- ============================================================
-- 1. New columns added to `agent_messages`:
--    - claimed_at, completed_at (for precise timing)
--    - max_attempts (configurable per message)
--
-- 2. New monitoring tables:
--    - execution_events: fine-grained tracing for debugging
--    - agent_metrics: aggregated performance metrics
--    - rate_limit_log: API quota monitoring
--    - deadletter_messages: failed messages for manual review
--
-- 3. Three useful views added:
--    - vw_task_summary: overview of each task's progress
--    - vw_agent_health: agent success rates and latencies
--    - vw_task_performance: per-task-agent performance breakdown
--
-- 4. Index improvements:
--    - Covering indexes reduce multi-table lookups
--    - Partial indexes on common status filters
--    - JSONB indexes for filtering on array/object fields
--    - Atomic claim query has dedicated index
--
-- 5. To migrate from old schema:
--    - Add new columns with ALTER TABLE if they don't exist
--    - Run CREATE INDEX IF NOT EXISTS to add new indexes
--    - No data loss; old tables remain functional
--
-- ============================================================
-- MIGRATION SQL (for existing databases)
-- ============================================================
-- ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
-- ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS completed_at timestamptz;
-- ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS max_attempts int NOT NULL DEFAULT 3;
--
-- Then create all new tables and indexes using statements above.
-- ============================================================
