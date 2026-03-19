-- ============================================================
-- Multi-Agent n8n System — Supabase Postgres DDL
-- Run this in Supabase SQL Editor (or psql) as a superuser.
-- ============================================================

-- ─── Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

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

CREATE INDEX IF NOT EXISTS tasks_status_idx       ON public.tasks (status);
CREATE INDEX IF NOT EXISTS tasks_created_at_idx   ON public.tasks (created_at DESC);

-- ─── Social Raw ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.social_raw (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
    platform        text        NOT NULL,
    native_id       text        NOT NULL,
    dedupe_key      text        NOT NULL,          -- sha256(platform || ':' || native_id)
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

CREATE UNIQUE INDEX IF NOT EXISTS social_raw_dedupe_key_uidx  ON public.social_raw (dedupe_key);
CREATE INDEX        IF NOT EXISTS social_raw_platform_id_idx  ON public.social_raw (platform, native_id);
CREATE INDEX        IF NOT EXISTS social_raw_published_at_idx ON public.social_raw (published_at DESC);
CREATE INDEX        IF NOT EXISTS social_raw_task_id_idx      ON public.social_raw (task_id);

-- ─── Social Analysis ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.social_analysis (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_id                  uuid        REFERENCES public.social_raw (id) ON DELETE CASCADE,
    task_id                 uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
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

CREATE INDEX IF NOT EXISTS social_analysis_raw_id_idx  ON public.social_analysis (raw_id);
CREATE INDEX IF NOT EXISTS social_analysis_task_id_idx ON public.social_analysis (task_id);
CREATE INDEX IF NOT EXISTS social_analysis_agent_idx   ON public.social_analysis (agent);

-- ─── Reports ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reports (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE CASCADE,
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

CREATE UNIQUE INDEX IF NOT EXISTS reports_task_id_uidx ON public.reports (task_id);
CREATE INDEX        IF NOT EXISTS reports_status_idx   ON public.reports (status);

-- ─── Logs ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.logs (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ts          timestamptz NOT NULL DEFAULT now(),
    level       text        NOT NULL DEFAULT 'info'
                            CHECK (level IN ('debug','info','warn','error')),
    agent       text        NOT NULL,
    task_id     uuid,
    thread_id   uuid,
    message     text        NOT NULL,
    meta        jsonb       DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS logs_task_id_idx  ON public.logs (task_id);
CREATE INDEX IF NOT EXISTS logs_agent_idx    ON public.logs (agent);
CREATE INDEX IF NOT EXISTS logs_ts_idx       ON public.logs (ts DESC);
CREATE INDEX IF NOT EXISTS logs_level_idx    ON public.logs (level);

-- ─── Agent Threads ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_threads (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     uuid        REFERENCES public.tasks (id) ON DELETE CASCADE,
    topic       text        NOT NULL,
    status      text        NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open','closing','closed')),
    owner_agent text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_threads_task_id_idx ON public.agent_threads (task_id);
CREATE INDEX IF NOT EXISTS agent_threads_status_idx  ON public.agent_threads (status);

-- ─── Agent Messages (Mailbox) ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_messages (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id       uuid        REFERENCES public.agent_threads (id) ON DELETE CASCADE,
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE CASCADE,
    from_agent      text        NOT NULL,
    to_agent        text        NOT NULL,
    kind            text        NOT NULL
                                CHECK (kind IN ('task','ask','answer','tool','log','error')),
    priority        int         NOT NULL DEFAULT 1,
    state           text        NOT NULL DEFAULT 'queued'
                                CHECK (state IN ('queued','claimed','in_progress','done','blocked','failed')),
    attempts        int         NOT NULL DEFAULT 0,
    payload         jsonb       NOT NULL DEFAULT '{}',
    expected_schema jsonb,
    error           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_messages_to_agent_state_idx ON public.agent_messages (to_agent, state);
CREATE INDEX IF NOT EXISTS agent_messages_thread_id_idx      ON public.agent_messages (thread_id);
CREATE INDEX IF NOT EXISTS agent_messages_task_id_idx        ON public.agent_messages (task_id);
CREATE INDEX IF NOT EXISTS agent_messages_priority_idx       ON public.agent_messages (priority DESC, created_at ASC);

-- ─── Blackboard ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.blackboard (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE CASCADE,
    key             text        NOT NULL,
    value           jsonb       NOT NULL DEFAULT '{}',
    producer_agent  text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS blackboard_task_key_uidx ON public.blackboard (task_id, key);
CREATE INDEX        IF NOT EXISTS blackboard_task_id_idx   ON public.blackboard (task_id);

-- ─── Artifacts ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.artifacts (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     uuid        REFERENCES public.tasks (id) ON DELETE CASCADE,
    type        text        NOT NULL
                            CHECK (type IN ('markdown','html','json','csv','image','raw')),
    label       text        NOT NULL,
    content     text,
    meta        jsonb       DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS artifacts_task_id_idx ON public.artifacts (task_id);
CREATE INDEX IF NOT EXISTS artifacts_type_idx    ON public.artifacts (type);

-- ============================================================
-- Helper: Atomic Message Claim (run inside your agent's Code
-- node via a Postgres execute-query node)
-- ============================================================
-- UPDATE public.agent_messages
-- SET    state = 'claimed', attempts = attempts + 1, updated_at = now()
-- WHERE  id = (
--     SELECT id
--     FROM   public.agent_messages
--     WHERE  to_agent = $1         -- bind: AGENT_NAME
--       AND  state    = 'queued'
--     ORDER BY priority DESC, created_at ASC
--     FOR UPDATE SKIP LOCKED
--     LIMIT 1
-- )
-- RETURNING *;

-- ============================================================
-- Helper: Log Writer
-- ============================================================
CREATE OR REPLACE FUNCTION public.write_log(
    p_level     text,
    p_agent     text,
    p_task_id   uuid,
    p_thread_id uuid,
    p_message   text,
    p_meta      jsonb DEFAULT '{}'
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.logs (level, agent, task_id, thread_id, message, meta)
    VALUES (p_level, p_agent, p_task_id, p_thread_id, p_message, p_meta);
$$;

-- ============================================================
-- Row-Level Security notes
-- ============================================================
-- If you access these tables via Supabase PostgREST/REST API
-- instead of direct Postgres (n8n Postgres node), you MUST
-- enable RLS on every table and grant `service_role` access.
-- Example:
--   ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
--   CREATE POLICY "service_role_all" ON public.tasks
--     USING (auth.role() = 'service_role');
--
-- When using direct Postgres credentials (recommended), RLS
-- is bypassed for the DB user — ensure the user has minimal
-- required privileges only:
--   GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO n8n_agent;
--   GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO n8n_agent;
-- ============================================================
