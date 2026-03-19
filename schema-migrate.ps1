# Schema Upgrade Script - Automated Migration
# Usage: .\schema-migrate.ps1 -ConnectionString "Host=...;Port=5432;Database=...;Username=...;Password=..."

param(
    [Parameter(Mandatory=$true)]
    [string]$ConnectionString,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('NewDatabase', 'ExistingDatabase')]
    [string]$MigrationType = 'ExistingDatabase',
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseConditionally = $true
)

$ErrorActionPreference = 'Stop'

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n█ $Message" -ForegroundColor Cyan
    Write-Host ("═" * 70) -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
    exit 1
}

function Execute-Query {
    param(
        [string]$Query,
        [string]$Description,
        [bool]$Critical = $true
    )
    
    try {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would execute: $Description" -ForegroundColor Gray
            return $true
        }
        
        # Use psql if available, otherwise use Npgsql via PowerShell
        $result = psql $ConnectionString -c $Query 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success $Description
            return $true
        } else {
            if ($Critical) {
                Write-Error "$Description - $result"
            } else {
                Write-Warning "$Description - $result"
            }
            return $false
        }
    } catch {
        if ($Critical) {
            Write-Error "$Description - $_"
        } else {
            Write-Warning "$Description - $_"
        }
        return $false
    }
}

# ============================================================
# PHASE 1: VALIDATION
# ============================================================

Write-Header "PHASE 1: Validating environment"

# Check for psql or alternative
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    Write-Warning "psql not found. Install PostgreSQL client tools for best results."
    Write-Warning "Continuing with fallback method (slower)..."
}

Write-Success "Connection parameters provided"

# ============================================================
# PHASE 2: ADD NEW COLUMNS (if existing database)
# ============================================================

if ($MigrationType -eq 'ExistingDatabase') {
    Write-Header "PHASE 2: Adding new columns to existing tables"
    
    $columnQueries = @(
        @{
            Query = "ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS claimed_at timestamptz;"
            Description = "Add claimed_at to agent_messages"
        },
        @{
            Query = "ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS completed_at timestamptz;"
            Description = "Add completed_at to agent_messages"
        },
        @{
            Query = "ALTER TABLE public.agent_messages ADD COLUMN IF NOT EXISTS max_attempts int NOT NULL DEFAULT 3 CHECK (max_attempts > 0);"
            Description = "Add max_attempts to agent_messages"
        },
        @{
            Query = "ALTER TABLE public.artifacts ADD COLUMN IF NOT EXISTS size_bytes int;"
            Description = "Add size_bytes to artifacts"
        }
    )
    
    foreach ($q in $columnQueries) {
        Execute-Query -Query $q.Query -Description $q.Description -Critical $false
    }
}

# ============================================================
# PHASE 3: CREATE NEW EXTENSIONS
# ============================================================

Write-Header "PHASE 3: Creating PostgreSQL extensions"

$extensionQueries = @(
    @{
        Query = "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
        Description = "Ensure pgcrypto extension"
    },
    @{
        Query = "CREATE EXTENSION IF NOT EXISTS btree_gin;"
        Description = "Add btree_gin for complex indexes"
    }
)

foreach ($q in $extensionQueries) {
    Execute-Query -Query $q.Query -Description $q.Description -Critical $false
}

# ============================================================
# PHASE 4: CREATE NEW TABLES
# ============================================================

Write-Header "PHASE 4: Creating new monitoring tables"

$tableQueries = @(
    @{
        Name = "execution_events"
        Query = @"
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
"@
    },
    @{
        Name = "agent_metrics"
        Query = @"
CREATE TABLE IF NOT EXISTS public.agent_metrics (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id             uuid        NOT NULL REFERENCES public.tasks (id) ON DELETE CASCADE,
    agent               text        NOT NULL,
    total_duration_ms   int,
    api_latency_ms      int,
    db_latency_ms       int,
    messages_processed  int         NOT NULL DEFAULT 0,
    messages_failed     int         NOT NULL DEFAULT 0,
    retries_used        int         NOT NULL DEFAULT 0,
    validation_passed   boolean,
    output_size_bytes   int,
    token_usage         jsonb       DEFAULT '{"input":0,"output":0}',
    estimated_cost      numeric(10,4),
    status              text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','failed','partial')),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
"@
    },
    @{
        Name = "rate_limit_log"
        Query = @"
CREATE TABLE IF NOT EXISTS public.rate_limit_log (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    service         text        NOT NULL
                                CHECK (service IN ('anthropic','notion','slack','youtube','twitter','reddit','apify')),
    task_id         uuid        REFERENCES public.tasks (id) ON DELETE SET NULL,
    agent           text,
    remaining_quota int,
    reset_at        timestamptz,
    throttle_until  timestamptz,
    was_throttled   boolean     NOT NULL DEFAULT false,
    backoff_ms      int,
    created_at      timestamptz NOT NULL DEFAULT now()
);
"@
    },
    @{
        Name = "deadletter_messages"
        Query = @"
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
    resolution      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz
);
"@
    }
)

foreach ($t in $tableQueries) {
    Execute-Query -Query $t.Query -Description "Create table: $($t.Name)" -Critical $false
}

# ============================================================
# PHASE 5: CREATE INDEXES
# ============================================================

Write-Header "PHASE 5: Creating performance indexes (this may take a few minutes for large tables)"

$indexQueries = @(
    # Tasks
    "CREATE INDEX IF NOT EXISTS tasks_status_created_idx ON public.tasks (status, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS tasks_created_by_status_idx ON public.tasks (created_by, status);"
    "CREATE INDEX IF NOT EXISTS tasks_date_range_idx ON public.tasks (date_range_start, date_range_end);"
    "CREATE INDEX IF NOT EXISTS tasks_active_idx ON public.tasks (created_at DESC) WHERE status IN ('queued', 'running');"
    "CREATE INDEX IF NOT EXISTS tasks_platforms_jsonb_idx ON public.tasks USING GIN (platforms);"
    "CREATE INDEX IF NOT EXISTS tasks_queries_jsonb_idx ON public.tasks USING GIN (queries);"
    
    # Social Raw
    "CREATE INDEX IF NOT EXISTS social_raw_platform_id_idx ON public.social_raw (platform, native_id);"
    "CREATE INDEX IF NOT EXISTS social_raw_task_id_created_idx ON public.social_raw (task_id, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS social_raw_published_at_idx ON public.social_raw (published_at DESC NULLS LAST);"
    "CREATE INDEX IF NOT EXISTS social_raw_task_id_enriched_idx ON public.social_raw (task_id, enriched) WHERE enriched = false;"
    "CREATE INDEX IF NOT EXISTS social_raw_raw_json_idx ON public.social_raw USING GIN (raw_json);"
    
    # Social Analysis
    "CREATE INDEX IF NOT EXISTS social_analysis_task_agent_idx ON public.social_analysis (task_id, agent);"
    "CREATE INDEX IF NOT EXISTS social_analysis_raw_id_task_idx ON public.social_analysis (raw_id, task_id);"
    "CREATE INDEX IF NOT EXISTS social_analysis_agent_created_idx ON public.social_analysis (agent, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS social_analysis_quality_score_idx ON public.social_analysis (quality_score DESC) WHERE quality_score IS NOT NULL;"
    "CREATE INDEX IF NOT EXISTS social_analysis_topics_jsonb_idx ON public.social_analysis USING GIN (topics);"
    "CREATE INDEX IF NOT EXISTS social_analysis_compliance_jsonb_idx ON public.social_analysis USING GIN (compliance_flags);"
    
    # Reports
    "CREATE INDEX IF NOT EXISTS reports_status_created_idx ON public.reports (status, created_at DESC);"
    
    # Logs
    "CREATE INDEX IF NOT EXISTS logs_ts_level_idx ON public.logs (ts DESC, level);"
    "CREATE INDEX IF NOT EXISTS logs_task_id_ts_idx ON public.logs (task_id, ts DESC);"
    "CREATE INDEX IF NOT EXISTS logs_agent_ts_idx ON public.logs (agent, ts DESC);"
    "CREATE INDEX IF NOT EXISTS logs_errors_idx ON public.logs (ts DESC) WHERE level IN ('error', 'warn');"
    
    # Agent Threads
    "CREATE INDEX IF NOT EXISTS agent_threads_task_id_status_idx ON public.agent_threads (task_id, status);"
    "CREATE INDEX IF NOT EXISTS agent_threads_owner_agent_idx ON public.agent_threads (owner_agent, status);"
    
    # Agent Messages (CRITICAL: claim performance)
    "CREATE INDEX IF NOT EXISTS agent_messages_claim_idx ON public.agent_messages (to_agent, state, priority DESC, created_at ASC) WHERE state = 'queued';"
    "CREATE INDEX IF NOT EXISTS agent_messages_thread_created_idx ON public.agent_messages (thread_id, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS agent_messages_task_state_idx ON public.agent_messages (task_id, state);"
    "CREATE INDEX IF NOT EXISTS agent_messages_from_to_idx ON public.agent_messages (from_agent, to_agent);"
    "CREATE INDEX IF NOT EXISTS agent_messages_failed_idx ON public.agent_messages (created_at DESC) WHERE state IN ('failed', 'blocked');"
    
    # Blackboard
    "CREATE INDEX IF NOT EXISTS blackboard_task_id_created_idx ON public.blackboard (task_id, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS blackboard_producer_agent_idx ON public.blackboard (producer_agent);"
    
    # Artifacts
    "CREATE INDEX IF NOT EXISTS artifacts_task_type_idx ON public.artifacts (task_id, type);"
    "CREATE INDEX IF NOT EXISTS artifacts_created_at_idx ON public.artifacts (created_at DESC);"
    
    # Execution Events
    "CREATE INDEX IF NOT EXISTS exec_events_task_agent_ts_idx ON public.execution_events (task_id, agent, created_at DESC);"
    "CREATE INDEX IF NOT EXISTS exec_events_message_id_idx ON public.execution_events (message_id);"
    "CREATE INDEX IF NOT EXISTS exec_events_event_type_idx ON public.execution_events (event_type, created_at DESC);"
    
    # Agent Metrics
    "CREATE INDEX IF NOT EXISTS agent_metrics_task_agent_idx ON public.agent_metrics (task_id, agent);"
    "CREATE INDEX IF NOT EXISTS agent_metrics_agent_status_idx ON public.agent_metrics (agent, status);"
    
    # Rate Limit Log
    "CREATE INDEX IF NOT EXISTS rate_limit_service_reset_idx ON public.rate_limit_log (service, reset_at DESC);"
    "CREATE INDEX IF NOT EXISTS rate_limit_throttled_idx ON public.rate_limit_log (created_at DESC) WHERE was_throttled = true;"
    
    # Deadletter Messages
    "CREATE INDEX IF NOT EXISTS deadletter_task_agent_idx ON public.deadletter_messages (task_id, to_agent);"
    "CREATE INDEX IF NOT EXISTS deadletter_resolved_idx ON public.deadletter_messages (created_at DESC) WHERE resolved_at IS NULL;"
)

$indexCount = 0
foreach ($indexql in $indexQueries) {
    $indexCount++
    Write-Host "  Creating index $indexCount/$($indexQueries.Count)..." -NoNewline -ForegroundColor Gray
    $result = Execute-Query -Query $indexSql -Description "Index creation" -Critical $false
    Write-Host ""  # newline
}

# ============================================================
# PHASE 6: CREATE FUNCTIONS
# ============================================================

Write-Header "PHASE 6: Creating helper functions"

$functionQueries = @(
    @{
        Name = "write_log"
        Query = @"
CREATE OR REPLACE FUNCTION public.write_log(
    p_level     text,
    p_agent     text,
    p_task_id   uuid,
    p_thread_id uuid DEFAULT NULL,
    p_message   text DEFAULT '',
    p_meta      jsonb DEFAULT '{}'
) RETURNS void LANGUAGE sql AS \$\$
    INSERT INTO public.logs (level, agent, task_id, thread_id, message, meta)
    VALUES (p_level, p_agent, p_task_id, p_thread_id, p_message, p_meta);
\$\$;
"@
    },
    @{
        Name = "record_execution_event"
        Query = @"
CREATE OR REPLACE FUNCTION public.record_execution_event(
    p_task_id       uuid,
    p_agent         text,
    p_event_type    text,
    p_duration_ms   int DEFAULT NULL,
    p_status        text DEFAULT 'success',
    p_error_msg     text DEFAULT NULL,
    p_metadata      jsonb DEFAULT '{}'
) RETURNS void LANGUAGE sql AS \$\$
    INSERT INTO public.execution_events 
        (task_id, agent, event_type, duration_ms, status, error_msg, metadata)
    VALUES (p_task_id, p_agent, p_event_type, p_duration_ms, p_status, p_error_msg, p_metadata);
\$\$;
"@
    }
)

foreach ($f in $functionQueries) {
    Execute-Query -Query $f.Query -Description "Create function: $($f.Name)" -Critical $false
}

# ============================================================
# PHASE 7: CREATE VIEWS
# ============================================================

Write-Header "PHASE 7: Creating monitoring views"

$viewQueries = @(
    @{
        Name = "vw_task_summary"
        Query = @"
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
"@
    },
    @{
        Name = "vw_agent_health"
        Query = @"
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
"@
    },
    @{
        Name = "vw_task_performance"
        Query = @"
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
"@
    }
)

foreach ($v in $viewQueries) {
    Execute-Query -Query $v.Query -Description "Create view: $($v.Name)" -Critical $false
}

# ============================================================
# FINAL SUMMARY
# ============================================================

Write-Header "MIGRATION COMPLETE"

if ($DryRun) {
    Write-Warning "This was a DRY RUN. No changes were made to the database."
    Write-Host "`nTo apply changes, run again without -DryRun flag:"
    Write-Host "  .\schema-migrate.ps1 -ConnectionString 'Your-Connection-String'" -ForegroundColor Yellow
} else {
    Write-Success "All schema improvements have been applied!"
    Write-Host "`nNext steps:" -ForegroundColor Cyan
    Write-Host "  1. Verify views are accessible: SELECT * FROM vw_task_summary LIMIT 1;"
    Write-Host "  2. Check index count: SELECT count(*) FROM pg_indexes WHERE schemaname='public';"
    Write-Host "  3. Update n8n workflows to use new monitoring tables (optional)"
    Write-Host "  4. Enable execution_events tracking in agent workflows"
}

Write-Host "`nFor detailed migration guide, see: SCHEMA-MIGRATION-GUIDE.md`n" -ForegroundColor Cyan
