# n8n Workflow Integration Guide - New Monitoring Features

This guide shows how to update your n8n agent workflows to use the new monitoring tables for better observability.

---

## Quick Start: Add 5 Lines of Monitoring to Any Agent Workflow

### Where to Add: After successful message claim

```
[Merge Trigger] → [Set Config] → [Claim Message]
                                        ↓
                                   [Message Claimed?] → [YES]
                                        ↓
                                   ✅ [NEW] Record Event: Message Claimed
                                        ↓
                                   [Sanitize Input] → ...
```

**Code Node: "Record Event: Message Claimed"**
```javascript
const { execSync } = require('child_process');

// Get timing
const claimedAt = new Date().toISOString();

// Record the event
return [{
  json: {
    ...$json,
    _event_claimed_at: claimedAt,
    _event_start_ms: Date.now()
  }
}];
```

**Postgres Node after: "Insert Claim Event"**
```sql
SELECT public.record_execution_event(
  '{{$json.task_id}}'::uuid,
  '{{$json.agent_name}}',
  'message_claimed',
  NULL,
  'success'
);
```

---

## Pattern 1: Track API Latency (Claude Calls)

### Setup: Measure time spent in Claude API

**Before Claude API call:**
```javascript
// Code node: "Start API Timer"
return [{
  json: {
    ...$json,
    _api_start_ms: Date.now()
  }
}];
```

**After Claude API call (in Validate JSON step):**
```javascript
// JavaScript Code Node: "Calculate API Duration"
const duration = Date.now() - $json._api_start_ms;
return [{
  json: {
    ...$json,
    _api_duration_ms: duration,
    _validation_passed: $json.valid
  }
}];
```

**Postgres Node: "Log API Duration"**
```sql
SELECT public.record_execution_event(
  '{{$json.task_id}}'::uuid,
  '{{$json.agent_name}}',
  'api_call_end',
  '{{$json._api_duration_ms}}'::int,
  CASE WHEN '{{$json._validation_passed}}' = 'true' THEN 'success' ELSE 'failure' END,
  ''
);
```

---

## Pattern 2: Track Message Processing (End-to-End)

### After message is marked DONE

**Postgres Node: "Write Agent Metrics"**
```sql
INSERT INTO public.agent_metrics (
  task_id, agent,
  api_latency_ms, messages_processed,
  validation_passed, status
) VALUES (
  '{{$json.task_id}}'::uuid,
  '{{$json.agent_name}}',
  '{{$json._api_duration_ms}}'::int,
  1,  -- This agent processed 1 message
  '{{$json._validation_passed}}'::boolean,
  'completed'
);
```

---

## Pattern 3: Detect & Record Rate Limiting

### In Error Handler branch (when Claude API returns 429)

**Postgres Node: "Log Rate Limit"**
```sql
INSERT INTO public.rate_limit_log (
  service, agent, task_id,
  was_throttled, throttle_until,
  backoff_ms
) VALUES (
  'anthropic',
  '{{$json.agent_name}}',
  '{{$json.task_id}}'::uuid,
  true,
  NOW() + INTERVAL '{{$json.retry_after_seconds}} seconds',
  '{{$json.retry_after_seconds}}'::int * 1000
);
```

Then implement exponential backoff:
```javascript
// Code node: "Calculate Backoff"
const attempt = parseInt($json.attempts || 0);
const baseDelay = 1000; // 1 second
const delay = baseDelay * Math.pow(2, attempt);  // Double each time: 1s, 2s, 4s, 8s...

return [{
  json: {
    ...$json,
    backoff_ms: Math.min(delay, 60000)  // Cap at 60 seconds
  }
}];
```

---

## Pattern 4: Send Failed Messages to Deadletter Queue

### In "Invalid JSON?" error branch

**Postgres Node: "Send to Deadletter"**
```sql
INSERT INTO public.deadletter_messages (
  original_msg_id, task_id, thread_id,
  from_agent, to_agent, kind,
  payload, attempts, final_error
) VALUES (
  '{{$json.id}}'::uuid,
  '{{$json.task_id}}'::uuid,
  '{{$json.thread_id}}'::uuid,
  '{{$json.from_agent}}',
  '{{$json.to_agent}}',
  '{{$json.kind}}',
  '{{JSON.stringify($json.payload)}}'::jsonb,
  '{{$json.attempts}}'::int,
  '{{$json.validation_reason}}'
);
```

Then mark original message as failed:
```sql
UPDATE public.agent_messages
SET state = CASE 
  WHEN attempts >= max_attempts THEN 'failed'
  ELSE 'queued'
END,
error = '{{$json.validation_reason}}'
WHERE id = '{{$json.id}}'::uuid;
```

---

## Pattern 5: Compliance Tracking (Optional)

### Track compliance flags during analysis

**After compliance check (if your agent checks this):**
```javascript
// Code node: "Extract Compliance Info"
const analysis = $json.parsed || {};
return [{
  json: {
    ...$json,
    _compliance_flags: analysis.compliance_flags || [],
    _has_risks: (analysis.compliance_flags || []).length > 0
  }
}];
```

**Update metrics with compliance status:**
```sql
UPDATE public.agent_metrics
SET notes = CASE 
  WHEN '{{$json._has_risks}}' = 'true' 
    THEN 'Compliance flags: {{$json._compliance_flags}}'
  ELSE 'Clean'
END
WHERE task_id = '{{$json.task_id}}'::uuid
ORDER BY created_at DESC
LIMIT 1;
```

---

## Complete Example: YouTube Ingestion Agent with Full Monitoring

Here's how to enhance `2-YouTube_Ingestion_Agent.json`:

```
[Cron] → [Webhook] → [Merge] → [Set Config] 
                                    ↓
                            [Claim Message] 
                                    ↓
[YES] ← [Message Claimed?]
  ↓
[NEW] Record Claim Event ← INSERT INTO execution_events
  ↓
[Sanitize Input]
  ↓
[Split In Batches]
  ↓
[Rate Limit Wait]
  ↓
[START TIMER] ← Code node: get current time
  ↓
[Claude Analyze] ← API call
  ↓
[STOP TIMER] ← Code node: calculate duration
  ↓
[Validate JSON]
  ↓
[Record API Event] ← INSERT INTO execution_events (api_call_end)
  ↓
[Valid JSON?]
  ├─[YES] → [Write Analysis] → [Write Blackboard] → [Post Answer] → [Mark Done] 
  │           ↓
  │       [Record Metrics] ← INSERT INTO agent_metrics
  │
  └─[NO] → [Build Repair Prompt]
            ↓
        [Claude Repair]
            ↓
        [Validate Repaired JSON]
            ↓
        [Valid After Repair?]
          ├─[YES] → [Write Analysis] → [Mark Done]
          │           ↓
          │       [Record Metrics]
          │
          └─[NO] → [Send to Deadletter] ← INSERT INTO deadletter_messages
                    ↓
                [Mark Failed]
```

---

## Dashboard Queries for Your Monitoring

### Copy these into your BI tool (Grafana, Metabase, etc.)

**Agent Performance SLA Tracker**
```sql
SELECT 
  am.agent,
  COUNT(*) as total_messages,
  COUNT(*) FILTER (WHERE am.state = 'done') as succeeded,
  ROUND(100.0 * COUNT(*) FILTER (WHERE am.state = 'done') / COUNT(*), 1) as success_rate_pct,
  ROUND(AVG(EXTRACT(EPOCH FROM (am.completed_at - am.claimed_at)))::numeric, 0)::int as avg_processing_sec,
  MAX(am.updated_at) as last_seen
FROM agent_messages am
WHERE am.claimed_at > NOW() - INTERVAL '24 hours'
GROUP BY am.agent
ORDER BY success_rate_pct ASC;
```

**Real-time Task Progress**
```sql
SELECT 
  t.id,
  t.status,
  COUNT(DISTINCT sr.id) as social_items,
  COUNT(DISTINCT sa.id) as analyzed_items,
  COUNT(DISTINCT am.id) FILTER (WHERE am.state = 'done') as completed_messages,
  COUNT(DISTINCT am.id) FILTER (WHERE am.state = 'failed') as failed_messages,
  ROUND((EXTRACT(EPOCH FROM (NOW() - t.created_at))/60)::numeric, 1)::float as elapsed_minutes
FROM tasks t
LEFT JOIN social_raw sr ON sr.task_id = t.id
LEFT JOIN social_analysis sa ON sa.task_id = t.id  
LEFT JOIN agent_messages am ON am.task_id = t.id
WHERE t.status IN ('queued', 'running')
GROUP BY t.id, t.status
ORDER BY t.created_at DESC;
```

**API Rate Limit Alerts**
```sql
SELECT 
  service,
  COUNT(*) as incidents_24h,
  MAX(created_at) as latest_incident,
  COUNT(*) FILTER (WHERE was_throttled) as throttled_count,
  AVG(backoff_ms)::int as avg_backoff_ms
FROM rate_limit_log
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY service
HAVING COUNT(*) > 0
ORDER BY incidents_24h DESC;
```

**Failed Message Queue (Manual Review)**
```sql
SELECT 
  id,
  task_id,
  to_agent,
  kind,
  attempts,
  final_error,
  created_at,
  resolution
FROM deadletter_messages
WHERE resolved_at IS NULL
ORDER BY created_at DESC;
```

**API Latency Trend (Last 7 Days)**
```sql
SELECT 
  DATE_TRUNC('hour', ee.created_at) as hour,
  ee.agent,
  COUNT(*) as api_calls,
  ROUND(AVG(ee.duration_ms)::numeric, 0)::int as avg_latency_ms,
  MAX(ee.duration_ms)::int as max_latency_ms
FROM execution_events ee
WHERE ee.event_type = 'api_call_end'
  AND ee.created_at > NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('hour', ee.created_at), ee.agent
ORDER BY hour DESC, avg_latency_ms DESC;
```

---

## Minimal Effort: Which Patterns to Implement First?

**Priority 1 (Essential):**
- Pattern 1 (Track API Latency) - Tells you if Claude is slow
- Pattern 4 (Deadletter Queue) - Prevents losing failed messages

**Priority 2 (Recommended):**
- Pattern 2 (Message Processing) - Shows agent throughput
- Pattern 3 (Rate Limiting) - Prevents API quota issues

**Priority 3 (Optional):**
- Pattern 5 (Compliance Tracking) - Domain-specific

---

## Testing Your Monitoring Implementation

### 1. Trigger a task manually
```sql
INSERT INTO public.tasks (
  queries, competitors, platforms, max_items, created_by
) VALUES (
  '["test query"]'::jsonb,
  '[]'::jsonb,
  '["youtube"]'::jsonb,
  5,
  'test_user'
) RETURNING id;
```

### 2. Check execution_events are recorded
```sql
SELECT agent, event_type, status, duration_ms, created_at
FROM execution_events
WHERE task_id = (SELECT id FROM tasks ORDER BY created_at DESC LIMIT 1)
ORDER BY created_at DESC;
```

### 3. Check agent_metrics
```sql
SELECT agent, messages_processed, api_latency_ms, status
FROM agent_metrics
WHERE task_id = (SELECT id FROM tasks ORDER BY created_at DESC LIMIT 1);
```

### 4. Verify task summary view
```sql
SELECT 
  id, status, 
  total_social_items, total_analyzed, total_messages,
  last_activity
FROM vw_task_summary
ORDER BY created_at DESC
LIMIT 1;
```

---

## Troubleshooting

**Problem: Postgres node says "function doesn't exist"?**
- Ensure migration script was run successfully
- Verify: `SELECT proname FROM pg_proc WHERE proname = 'record_execution_event';`

**Problem: Monitoring tables are empty?**
- Make sure you're actually running the INSERT statements in your workflows
- Check n8n execution logs for SQL errors
- Verify PostgreSQL user has INSERT permissions

**Problem: Queries are slow?**
- Ensure indexes were created: `SELECT * FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename;`
- May need to REINDEX if dataset is very large

**Problem: Need to clear old monitoring data?**
- Safe to delete old records: `DELETE FROM execution_events WHERE created_at < NOW() - INTERVAL '30 days';`
- Or use: `TRUNCATE execution_events CASCADE;` to reset everything

---

## Next Steps

1. **Run schema-migrate.ps1** to apply the improved schema
2. **Pick 1-2 patterns** above and implement in one agent workflow
3. **Test** by running a task and checking the monitoring tables
4. **Deploy** to other agent workflows once comfortable
5. **Create dashboards** in your BI tool using the provided queries

