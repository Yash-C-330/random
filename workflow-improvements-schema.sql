-- ============================================================
-- Workflow Improvements - Supporting SQL Tables
-- Add these to support workflow optimization changes
-- ============================================================

-- ─── Agents Registry ────────────────────────────────────────
-- Purpose: Define available agents, enable/disable without code changes
-- Use: Dynamic dispatch in Coordinator workflow

CREATE TABLE IF NOT EXISTS public.agents_registry (
    name                text    PRIMARY KEY,
    display_name        text,
    description         text,
    enabled             boolean NOT NULL DEFAULT true,
    
    -- Execution parameters
    priority            int     NOT NULL DEFAULT 1 CHECK (priority >= 0 AND priority <= 10),
    max_parallel        int     NOT NULL DEFAULT 5 CHECK (max_parallel > 0),
    timeout_ms          int     NOT NULL DEFAULT 90000 CHECK (timeout_ms > 0),
    max_retries         int     NOT NULL DEFAULT 3 CHECK (max_retries >= 0),
    retry_backoff_ms    int     NOT NULL DEFAULT 2000,
    
    -- Resource limits
    max_daily_messages  int     CHECK (max_daily_messages IS NULL OR max_daily_messages > 0),
    max_concurrent      int     NOT NULL DEFAULT 1,
    rate_limit_rps      numeric(6,2) DEFAULT 1.0,  -- requests per second
    
    -- Routing
    requires_enrichment boolean DEFAULT true,
    depends_on          text[],  -- Agent names this depends on
    conflicts_with      text[],  -- Agents that can't run in parallel
    
    -- Metadata
    owner               text,
    slack_channel       text,
    tags                text[] DEFAULT '{}',
    
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Populate with your agents
INSERT INTO public.agents_registry (name, display_name, enabled, priority, timeout_ms, description)
VALUES
    ('youtube_ingestion', 'YouTube Ingestion', true, 3, 120000, 'Fetch and normalize YouTube video data'),
    ('twitter_ingestion', 'Twitter/X Ingestion', true, 2, 120000, 'Fetch and normalize tweets'),
    ('tiktok_ingestion', 'TikTok Ingestion', true, 2, 120000, 'Fetch TikTok videos via Apify'),
    ('reddit_ingestion', 'Reddit Ingestion', true, 2, 120000, 'Fetch Reddit posts'),
    ('meta_ads_ingestion', 'Meta Ads Ingestion', true, 1, 150000, 'Fetch Meta Ad Library'),
    ('enrichment', 'Enrichment Agent', true, 3, 90000, 'Enrich raw social data'),
    ('creative_analyst', 'Creative Analyst', true, 2, 90000, 'Analyze creative elements'),
    ('audience_persona', 'Audience Persona', true, 2, 90000, 'Build audience profiles'),
    ('compliance_risk', 'Compliance Risk', true, 2, 90000, 'Flag compliance/brand risks'),
    ('performance_scoring', 'Performance Scoring', true, 2, 90000, 'Score content performance'),
    ('synthesis_insights', 'Synthesis Insights', true, 2, 90000, 'Synthesize findings'),
    ('report_writer', 'Report Writer', true, 1, 120000, 'Write final reports'),
    ('qa_validator', 'QA Validator', true, 1, 90000, 'Validate output quality'),
    ('notifier', 'Notifier', true, 1, 30000, 'Send notifications')
ON CONFLICT (name) DO NOTHING;

CREATE INDEX IF NOT EXISTS agents_registry_enabled_idx ON public.agents_registry (enabled);
CREATE INDEX IF NOT EXISTS agents_registry_priority_idx ON public.agents_registry (priority DESC);

-- ─── Configuration Table ──────────────────────────────────
-- Purpose: Runtime configuration without workflow edits
-- Use: In Code nodes to fetch runtime settings

CREATE TABLE IF NOT EXISTS public.workflow_config (
    key             text    PRIMARY KEY,
    value           text    NOT NULL,
    data_type       text    DEFAULT 'string' CHECK (data_type IN ('string','int','float','bool','json')),
    env             text    NOT NULL DEFAULT 'prod' CHECK (env IN ('dev','staging','prod','test')),
    
    -- Metadata
    description     text,
    category        text,    -- 'performance', 'security', 'api', 'database'
    last_set_by     text,
    last_set_at     timestamptz DEFAULT now(),
    updated_at      timestamptz DEFAULT now()
);

-- Core performance configs
INSERT INTO public.workflow_config (key, value, data_type, env, category, description)
VALUES
    ('BATCH_SIZE', '10', 'int', 'prod', 'performance', 'Items per batch for Claude analysis'),
    ('RATE_LIMIT_DELAY_MS', '1200', 'int', 'prod', 'performance', 'Default delay between API calls'),
    ('ANTHROPIC_TIMEOUT_MS', '90000', 'int', 'prod', 'api', 'Claude API call timeout'),
    ('MAX_MESSAGE_DURATION_MS', '120000', 'int', 'prod', 'performance', 'Max time to process one message'),
    ('COORDINATOR_POLL_INTERVAL_SEC', '300', 'int', 'prod', 'performance', 'Coordinator cron interval (now 5 min)'),
    ('AGENT_POLL_INTERVAL_SEC', '300', 'int', 'prod', 'performance', 'Agent cron interval (now 5 min)'),
    ('MESSAGE_MAX_RETRIES', '3', 'int', 'prod', 'performance', 'Max retries before dead-letter'),
    ('WEBHOOK_SIGNATURE_REQUIRED', 'true', 'bool', 'prod', 'security', 'Enforce HMAC signatures'),
    ('CIRCUIT_BREAKER_THRESHOLD', '50', 'int', 'prod', 'performance', 'Fail rate % to disable agent (0-100)'),
    ('CIRCUIT_BREAKER_WINDOW_SEC', '300', 'int', 'prod', 'performance', 'Time window for fail rate calculation'),
    ('ENABLE_MESSAGE_DEDUPLICATION', 'true', 'bool', 'prod', 'performance', 'Check idempotency keys'),
    ('LOG_LEVEL', 'info', 'string', 'prod', 'performance', 'Log verbosity: debug, info, warn, error'),
    ('ENABLE_EXECUTION_EVENTS', 'true', 'bool', 'prod', 'performance', 'Track execution_events for debugging')
ON CONFLICT (key) DO NOTHING;

CREATE INDEX IF NOT EXISTS config_env_category_idx ON public.workflow_config (env, category);
CREATE INDEX IF NOT EXISTS config_key_env_idx ON public.workflow_config (key, env);

-- ─── Agent Dependency Graph ──────────────────────────────
-- Purpose: Define which agents must complete before others start
-- Use: Coordinator checks this before routing

CREATE TABLE IF NOT EXISTS public.agent_dependencies (
    dependent_agent text NOT NULL REFERENCES public.agents_registry (name) ON DELETE CASCADE,
    required_agent  text NOT NULL REFERENCES public.agents_registry (name) ON DELETE CASCADE,
    sort_order      int  NOT NULL DEFAULT 0,
    
    PRIMARY KEY (dependent_agent, required_agent),
    UNIQUE (dependent_agent, required_agent, sort_order)
);

-- Define execution order
INSERT INTO public.agent_dependencies (dependent_agent, required_agent, sort_order)
VALUES
    -- Enrichment must run after all ingestions
    ('enrichment', 'youtube_ingestion', 1),
    ('enrichment', 'twitter_ingestion', 2),
    ('enrichment', 'tiktok_ingestion', 3),
    ('enrichment', 'reddit_ingestion', 4),
    ('enrichment', 'meta_ads_ingestion', 5),
    
    -- Analysis must run after enrichment
    ('creative_analyst', 'enrichment', 1),
    ('audience_persona', 'enrichment', 1),
    ('compliance_risk', 'enrichment', 1),
    ('performance_scoring', 'enrichment', 1),
    
    -- Synthesis depends on all analysis
    ('synthesis_insights', 'creative_analyst', 1),
    ('synthesis_insights', 'audience_persona', 2),
    ('synthesis_insights', 'compliance_risk', 3),
    ('synthesis_insights', 'performance_scoring', 4),
    
    -- Report writing depends on synthesis
    ('report_writer', 'synthesis_insights', 1),
    
    -- QA happens after report
    ('qa_validator', 'report_writer', 1),
    
    -- Notifier is last
    ('notifier', 'qa_validator', 1)
ON CONFLICT DO NOTHING;

CREATE INDEX IF NOT EXISTS agent_deps_required_idx ON public.agent_dependencies (required_agent);
CREATE INDEX IF NOT EXISTS agent_deps_dependent_idx ON public.agent_dependencies (dependent_agent);

-- ─── Agent Health Snapshots ──────────────────────────────
-- Purpose: Track health metrics for circuit breaker decisions
-- Use: Quick lookup of agent status without aggregating messages table

CREATE TABLE IF NOT EXISTS public.agent_health_snapshot (
    agent               text        NOT NULL REFERENCES public.agents_registry (name) ON DELETE CASCADE,
    snapshot_time       timestamptz NOT NULL DEFAULT now(),
    
    -- Status counters (last 5 min window)
    queued_messages     int         NOT NULL DEFAULT 0,
    processing_messages int         NOT NULL DEFAULT 0,
    completed_messages  int         NOT NULL DEFAULT 0,
    failed_messages     int         NOT NULL DEFAULT 0,
    blocked_messages    int         NOT NULL DEFAULT 0,
    
    -- Metrics
    success_rate        numeric(5,2),
    avg_duration_ms     int,
    p95_duration_ms     int,
    
    -- Status
    status              text        CHECK (status IN ('healthy','degraded','unhealthy','offline')),
    status_reason       text,
    
    PRIMARY KEY (agent, snapshot_time DESC)
);

CREATE INDEX IF NOT EXISTS agent_health_agent_time_idx ON public.agent_health_snapshot (agent, snapshot_time DESC);
CREATE INDEX IF NOT EXISTS agent_health_status_idx ON public.agent_health_snapshot (status, snapshot_time DESC);

-- ─── API Rate Limit Tracking ──────────────────────────────
-- Purpose: Track external API quota usage
-- Use: Coordinator checks before dispatching to prevent cascade failures

CREATE TABLE IF NOT EXISTS public.api_quota_tracking (
    service             text        NOT NULL 
                                    CHECK (service IN ('anthropic','notion','slack','youtube','twitter','reddit','apify','openai')),
    period_start        timestamptz NOT NULL,
    period_end          timestamptz NOT NULL,
    
    -- Quota info
    quota_limit         int,
    quota_used          int         DEFAULT 0,
    quota_remaining     int,
    last_reset_at       timestamptz,
    
    -- Status
    is_throttled        boolean     DEFAULT false,
    throttle_until      timestamptz,
    
    -- Metadata
    updated_at          timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS quota_service_period_idx ON public.api_quota_tracking (service, period_start DESC);
CREATE INDEX IF NOT EXISTS quota_throttled_idx ON public.api_quota_tracking (service) WHERE is_throttled = true;

-- ─── Workflow Execution Plan ────────────────────────────
-- Purpose: Pre-calculated execution path for a task
-- Use: Coordinator follows this plan instead of hardcoded dispatch

CREATE TABLE IF NOT EXISTS public.task_execution_plan (
    task_id             uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    sequence            int         NOT NULL,
    agent_name          text        NOT NULL REFERENCES public.agents_registry (name) ON DELETE CASCADE,
    
    -- Conditions
    run_if_condition    text,   -- SQL WHERE clause, NULL = always run
    parallel_with       int[],  -- sequence numbers that can run in parallel
    
    -- Metadata
    estimated_duration_ms int,
    created_at          timestamptz DEFAULT now(),
    
    PRIMARY KEY (task_id, sequence)
);

CREATE INDEX IF NOT EXISTS exec_plan_task_sequence_idx ON public.task_execution_plan (task_id, sequence);

-- ─── Idempotency Keys ──────────────────────────────────
-- Purpose: Track processed messages to prevent duplicates
-- Use: INSERT ... ON CONFLICT (idempotency_key) DO NOTHING

ALTER TABLE public.agent_messages 
ADD COLUMN IF NOT EXISTS idempotency_key text UNIQUE;

CREATE INDEX IF NOT EXISTS agent_msg_idempotency_idx ON public.agent_messages (idempotency_key) 
WHERE idempotency_key IS NOT NULL;

-- ─── Helper Function: Get Agent Execution Config ───────
CREATE OR REPLACE FUNCTION public.get_agent_config(
    p_agent_name text
) RETURNS TABLE (
    name text,
    priority int,
    max_retries int,
    timeout_ms int,
    is_enabled boolean
) LANGUAGE sql AS $$
    SELECT 
        name,
        priority,
        max_retries,
        timeout_ms,
        enabled
    FROM public.agents_registry
    WHERE name = p_agent_name;
$$;

-- ─── Helper Function: Get Workflow Config ──────────────
CREATE OR REPLACE FUNCTION public.get_config_value(
    p_key text,
    p_env text DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$
    SELECT value
    FROM public.workflow_config
    WHERE key = p_key
      AND (p_env IS NULL OR env = p_env OR env = 'prod')
    ORDER BY env DESC  -- Prefer specific env, fall back to prod
    LIMIT 1;
$$;

-- ─── Helper Function: Check Circuit Breaker ────────────
CREATE OR REPLACE FUNCTION public.should_dispatch_to_agent(
    p_agent_name text
) RETURNS boolean LANGUAGE sql AS $$
    WITH recent_messages AS (
        SELECT 
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE state = 'failed') as failed
        FROM public.agent_messages
        WHERE to_agent = p_agent_name
          AND created_at > NOW() - INTERVAL '5 minutes'
    )
    SELECT 
        CASE 
            WHEN NOT EXISTS(SELECT 1 FROM agents_registry WHERE name = p_agent_name AND enabled)
                THEN false
            WHEN (SELECT total FROM recent_messages) = 0
                THEN true  -- No data yet, allow dispatch
            WHEN (SELECT ROUND(100.0 * failed / NULLIF(total, 0))::int FROM recent_messages) > 50
                THEN false  -- >50% failure rate, circuit open
            ELSE true
        END;
$$;

-- ─── Helper Function: Calculate Exponential Backoff ────────
CREATE OR REPLACE FUNCTION public.calculate_backoff_ms(
    p_attempts int,
    p_base_delay_ms int DEFAULT 2000,
    p_max_delay_ms int DEFAULT 60000
) RETURNS int LANGUAGE sql AS $$
    SELECT LEAST(
        p_base_delay_ms * (1 << p_attempts),  -- 2^attempts
        p_max_delay_ms
    );
$$;

-- ─── Helper Function: Get Agent Dependencies ────────────
CREATE OR REPLACE FUNCTION public.get_dependencies_for_agent(
    p_agent_name text
) RETURNS TABLE (
    required_agent text,
    sort_order int
) LANGUAGE sql AS $$
    SELECT required_agent, sort_order
    FROM public.agent_dependencies
    WHERE dependent_agent = p_agent_name
    ORDER BY sort_order;
$$;

-- ─── View: Agent Registry Status ───────────────────────
CREATE OR REPLACE VIEW public.vw_agent_registry_status AS
SELECT 
    ar.name,
    ar.display_name,
    ar.enabled,
    ar.priority,
    ahs.status,
    ahs.success_rate,
    ahs.queued_messages,
    ahs.avg_duration_ms,
    CASE 
        WHEN ahs.status = 'unhealthy' THEN 'Circuit Open'
        WHEN ar.enabled = false THEN 'Disabled'
        WHEN ahs.status = 'healthy' THEN 'Ready'
        ELSE 'Degraded'
    END as dispatch_status
FROM public.agents_registry ar
LEFT JOIN LATERAL (
    SELECT * FROM public.agent_health_snapshot
    WHERE agent = ar.name
    ORDER BY snapshot_time DESC
    LIMIT 1
) ahs ON true;

-- ─── View: Dependency Graph (For Coordinator) ──────────
CREATE OR REPLACE VIEW public.vw_agent_execution_order AS
SELECT DISTINCT
    ar.name,
    ar.priority,
    ar.enabled,
    COALESCE(STRING_AGG(DISTINCT d.required_agent, ', '), 'none') as depends_on
FROM public.agents_registry ar
LEFT JOIN public.agent_dependencies d ON ar.name = d.dependent_agent
GROUP BY ar.name, ar.priority, ar.enabled
ORDER BY ar.priority DESC, ar.name;

-- ─── Migration Notes ──────────────────────────────────
-- 1. New columns added to existing tables:
--    - agent_messages.idempotency_key (for dedup)
--
-- 2. New tables:
--    - agents_registry (agent definitions)
--    - workflow_config (runtime settings)
--    - agent_dependencies (execution order)
--    - agent_health_snapshot (circuit breaker data)
--    - api_quota_tracking (rate limit tracking)
--    - task_execution_plan (pre-planned routes)
--
-- 3. New functions:
--    - get_agent_config()
--    - get_config_value()
--    - should_dispatch_to_agent() [circuit breaker]
--    - calculate_backoff_ms()
--    - get_dependencies_for_agent()
--
-- 4. New views:
--    - vw_agent_registry_status
--    - vw_agent_execution_order

-- ============================================================
-- COORDINATOR QUERY EXAMPLES
-- ============================================================

-- Example: Get enabled agents in priority order
-- SELECT name, display_name, priority
-- FROM agents_registry
-- WHERE enabled = true
-- ORDER BY priority DESC;

-- Example: Check if agent should be dispatched
-- SELECT public.should_dispatch_to_agent('creative_analyst') as can_dispatch;

-- Example: Get runtime config value
-- SELECT public.get_config_value('BATCH_SIZE', 'prod');

-- Example: Get dependencies for an agent
-- SELECT * FROM public.get_dependencies_for_agent('synthesis_insights');

-- ============================================================
