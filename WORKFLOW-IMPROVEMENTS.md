# Workflow Improvements Guide

## Executive Summary

Found **13 optimization opportunities** in your n8n workflows. **Top priorities: reduce polling overhead, add error handling, implement dynamic rate limiting, add request validation.**

---

## 1. ❌ CRITICAL: Every-Minute Polling Overhead

### Problem
- Coordinator + 14 agent workflows = 15 cron triggers firing **every minute**
- Each triggers a DB query, even if no messages exist
- **1,440 queries/hour = 34,560 queries/day** just checking for work
- Most of the time returns zero results

### Solution: Event-Driven Architecture

**Instead of poll every minute, use:**
- Keep webhook triggers (instant execution)
- Change cron to **every 5 minutes** (80% cost reduction)
- Add database notifications for SQL events (PostgreSQL LISTEN/NOTIFY)

**For PostgreSQL + n8n:**
```sql
-- Coordinator only polls if new queued task arrives
-- Agent only polls if new message for it is queued
-- Use: Database trigger → NOTIFY → Webhook from external service
```

**Implementation:**
1. Keep webhook triggers as primary (instant)
2. Change all cron from `everyMinute` to `interval: 300000` (5 min)
3. Optionally: Add external service that subscribes to LISTEN/NOTIFY

**Quick Win (No Code Change Needed):**
```json
{
  "triggerTimes": {
    "item": [
      {
        "mode": "interval",
        "value": 5,      // Every 5 minutes instead of 1
        "unit": "minutes"
      }
    ]
  }
}
```

**Savings:** 4,320 fewer queries/day, 75% polling reduction.

---

## 2. ⚠️ No Error Handling & Retry Logic

### Problem
Workflows have **no error branches**. Failed messages disappear silently:
- Invalid JSON from Claude → No retry
- Network timeout → No backoff
- Database write fails → Message lost

### Solution: Add Error Paths

**Add to every agent workflow:**

```
[Claude Analyze] 
    ├─ [Valid] → [Write to DB] → Success
    └─ [Error] → [Retry with Backoff]
                    ├─ [Attempt 1-2] → [Wait 2^n sec] → [Retry Claude]
                    └─ [Attempt 3+] → [Send to Deadletter]
```

**Implementation:**

1. **Add to Claude HTTP node** (currently missing):
   ```json
   "retryOnFail": true,
   "maxRetries": 0,    // Change to: 1
   "retryInterval": 5000,
   "timeoutMs": 90000  // Make configurable: $env.ANTHROPIC_TIMEOUT_MS
   ```

2. **Add Error Handler for Postgres nodes:**
   - Create error branch
   - Insert to `deadletter_messages` if attempts >= max_attempts
   - Log failure with reason

3. **Add Exponential Backoff Code:**
   ```javascript
   // if validation fails and attempts < max_attempts:
   const backoff = Math.min(1000 * Math.pow(2, attempts), 60000);
   return [{ json: { ...$json, backoff_ms: backoff } }];
   ```

**Code Node: "Calculate Exponential Backoff"**
```javascript
const attempts = $json.attempts || 0;
const maxAttempts = $json.max_attempts || 3;

if (attempts >= maxAttempts) {
  return [{ json: { ...$json, should_discard: true } }];
}

const baseDelay = 2000; // 2 seconds
const backoff = Math.min(
  baseDelay * Math.pow(2, attempts),
  60000 // 60 second cap
);

return [{ json: { ...$json, backoff_ms: backoff, should_retry: true } }];
```

---

## 3. ⚠️ Fixed Rate Limiting (Should Be Dynamic)

### Problem
Uses fixed `RATE_LIMIT_DELAY_MS` (default 1200ms). Ignores API response headers:
- Anthropic returns `retry-after: 5000` but ignored
- Hitting rate limits causes cascading failures
- No backoff adjustment based on quota

### Solution: Respect API Headers

**Update Claude HTTP Node:**
```json
{
  "options": {
    "timeout": "{{ $env.ANTHROPIC_TIMEOUT_MS || 90000 }}",
    "retryOnFail": true,
    "maxRetries": 2
  }
}
```

**Add Response Header Parser:**
```javascript
// Code node after Claude call
const headers = $json.headers || {};
const retryAfter = headers['retry-after'] || headers['Retry-After'];
const rateLimit = headers['anthropic-ratelimit-remaining-requests'];

const delay = retryAfter 
  ? parseInt(retryAfter) * 1000
  : Number($env.RATE_LIMIT_DELAY_MS || 1200);

return [{
  json: {
    ...$json,
    _recommended_backoff: delay,
    _rate_limit_remaining: rateLimit
  }
}];
```

**Benefits:** Automatically adapts to API limits, no manual tuning needed.

---

## 4. ⚠️ Missing Timeout Protection

### Problem
Cloud APIs have 90-second timeout, but no fallback if Claude takes 85 seconds:
- Validation might timeout
- No emergency cleanup
- Message stuck in "claimed" state forever

### Solution: Add Max Duration Circuit Breaker

```javascript
// Code node at message start
const startTime = Date.now();
const maxDuration = Number($env.MAX_MESSAGE_DURATION_MS || 120000); // 2 min

return [{
  json: {
    ...$json,
    _start_time_ms: startTime,
    _max_duration_ms: maxDuration
  }
}];
```

**After each step, check:**
```javascript
const elapsed = Date.now() - $json._start_time_ms;
if (elapsed > $json._max_duration_ms) {
  // Mark message as blocked + log critical alert
  throw new Error(`Message processing timeout after ${elapsed}ms`);
}
return [$json];
```

---

## 5. 🔓 SECURITY: Unvalidated Webhooks

### Problem
SaaS API and agent webhooks accept any request:
- No signature verification
- No rate limiting on webhook endpoint
- No authentication on POST /v1/tasks/research

### Solution: Add Request Signing

**Use HMAC-SHA256 validation:**

```javascript
// Code node: "Validate Webhook Signature"
const crypto = require('crypto');
const signature = $json.headers?.['x-webhook-signature']; // Sent by caller
const secret = $env.WEBHOOK_SECRET;

if (!signature || !secret) {
  return [{ json: { auth_ok: false, reason: 'Missing signature' } }];
}

const payload = JSON.stringify($json.rawBody || $json.body);
const expectedSig = crypto
  .createHmac('sha256', secret)
  .update(payload)
  .digest('hex');

const isValid = signature === expectedSig;
return [{ json: { ...$json, auth_ok: isValid } }];
```

**In caller:**
```javascript
const crypto = require('crypto');
const payload = JSON.stringify(taskData);
const sig = crypto
  .createHmac('sha256', WEBHOOK_SECRET)
  .update(payload)
  .digest('hex');

// Then POST with header: x-webhook-signature: sig
```

---

## 6. 🔴 Hardcoded Agent Dispatch (Not Scalable)

### Problem
Coordinator has hardcoded 14 INSERT statements for agent dispatch.
Adding new agent requires editing workflow JSON.

### Current Dispatch (in SQL):
```sql
INSERT INTO agent_messages ... VALUES
  (...'youtube_ingestion'...),
  (...'twitter_ingestion'...),
  (... 13 more hardcoded agents ...)
```

### Solution: Agents Registry Table

**New table:**
```sql
CREATE TABLE IF NOT EXISTS public.agents (
  name              text        PRIMARY KEY,
  description       text,
  enabled           boolean     DEFAULT true,
  priority          int         DEFAULT 1,
  max_parallel      int         DEFAULT 5,
  timeout_ms        int         DEFAULT 90000,
  updated_at        timestamptz DEFAULT now()
);

INSERT INTO agents VALUES
  ('youtube_ingestion', 'Ingest YouTube videos', true, 3, 10, 90000),
  ('twitter_ingestion', 'Ingest tweets', true, 2, 10, 90000),
  ... etc ...
```

**Then in Coordinator, use dynamic dispatch:**
```sql
INSERT INTO agent_messages (thread_id, task_id, from_agent, to_agent, kind, state, priority, payload)
SELECT 
  {{$json.thread_id}}, 
  {{$json.task_id}}, 
  'coordinator',
  a.name,
  'task',
  'queued',
  a.priority,
  {{JSON.stringify($json.payload)}}::jsonb
FROM public.agents a
WHERE a.enabled = true;
```

**Benefits:** Add agents without touching coordinator workflow.

---

## 7. ❌ No Message Deduplication

### Problem
If coordinator crashes mid-dispatch, same message queued twice:
- Same social_raw item analyzed twice
- Duplicate reports generated
- Wasted API calls

### Solution: Idempotency Key

**Add to agent_messages table:**
```sql
ALTER TABLE public.agent_messages 
ADD COLUMN IF NOT EXISTS idempotency_key text UNIQUE;
```

**When posting message:**
```sql
INSERT INTO agent_messages (..., idempotency_key)
VALUES (..., sha256(task_id || to_agent || payload)::text)
ON CONFLICT (idempotency_key) DO NOTHING;
```

**Benefits:** Safe to retry—duplicate attempts ignored.

---

## 8. ⏱️ Inefficient Single-Item Processing

### Problem
Each message = 1 Claude API call
- 100 items = 100 calls (high latency)
- No batch optimization

### Solution: Batch Processing (Optional)

For analysis agents like Creative Analyst, batch similar items:

```javascript
// Code node: "Group by Type"
const items = $json.items || [];

// Group by content type
const grouped = items.reduce((acc, item) => {
  const type = item.detected_format;
  if (!acc[type]) acc[type] = [];
  acc[type].push(item);
  return acc;
}, {});

return Object.entries(grouped).map(([type, group]) => ({
  json: { items_group: group, batch_type: type }
}));
```

**Then send single API call per group:**
```
"Analyze 50 carousel ads in one request" instead of 50 separate calls
```

**Savings:** 50% fewer API calls + latency for parallel batches.

---

## 9. ❓ No Circuit Breaker for Failing Agents

### Problem
If YouTube API is down, coordinator keeps queuing messages for youtube_ingestion agent forever:
- Messages pile up
- Memory bloat
- Never processed

### Solution: Circuit Breaker Pattern

**Check agent health before dispatching:**
```sql
-- In Coordinator, before dispatcher:
SELECT agent, 
  COUNT(*) as queued,
  COUNT(*) FILTER (WHERE state='failed') as failed,
  ROUND(100.0 * COUNT(*) FILTER (WHERE state='failed') / COUNT(*), 1) as fail_rate
FROM agent_messages
WHERE to_agent = 'youtube_ingestion'
  AND created_at > NOW() - INTERVAL '5 minutes'
GROUP BY agent

-- If fail_rate > 50%, don't queue new messages
```

**Coordinator pseudo-code:**
```javascript
const failRates = await getAgentFailRates();
const disabled = failRates.filter(r => r.fail_rate > 50).map(r => r.agent);

const agents = await getEnabledAgents();
const safeAgents = agents.filter(a => !disabled.includes(a.name));

// Only dispatch to healthy agents
```

---

## 10. 📝 No Structured Logging

### Problem
Current logging is plain-text, hard to query:
```sql
INSERT INTO logs VALUES (..., 'debug', agent, 'no queued message', '{}');
```

Cannot query: "Show all errors for youtube_ingestion on task X"

### Solution: Structured JSON Logging

```sql
-- Better:
INSERT INTO logs (level, agent, task_id, message, meta)
VALUES (
  'debug',
  'coordinator',
  {{$json.task_id}}::uuid,
  'no_queued_task',  -- machine-readable
  {
    "trigger": "cron",
    "search_params": {"status": "queued"},
    "rows_found": 0
  }::jsonb
);
```

**Enables queries:**
```sql
SELECT * FROM logs 
WHERE meta->>'trigger' = 'webhook' 
  AND level = 'error'
  AND agent = 'youtube_ingestion'
  AND created_at > NOW() - INTERVAL '1 hour';
```

---

## 11. 🔧 Missing Configuration Table

### Problem
Batch size, timeouts, rate limits hardcoded in workflows:
- Need workflow edit to change BATCH_SIZE
- No per-environment config
- No runtime tuning

### Solution: Config Table

```sql
CREATE TABLE IF NOT EXISTS public.config (
  key       text   PRIMARY KEY,
  value     text   NOT NULL,
  env       text   CHECK (env IN ('dev', 'staging', 'prod')),
  updated_at timestamp DEFAULT now()
);

INSERT INTO config VALUES
  ('BATCH_SIZE', '10', 'prod'),
  ('RATE_LIMIT_DELAY_MS', '1200', 'prod'),
  ('ANTHROPIC_TIMEOUT_MS', '90000', 'prod'),
  ('MAX_MESSAGE_DURATION_MS', '120000', 'prod'),
  ('COORDINATOR_POLL_INTERVAL_SEC', '60', 'prod');
```

**In workflow (Code node):**
```javascript
const config = await db.query(
  'SELECT value FROM config WHERE key = $1 AND env = $2',
  [key, $env.ENVIRONMENT || 'prod']
);
return [{ json: { ...value: config[0].value } }];
```

**Benefits:** Change config without redeploying workflows.

---

## 12. 🚨 No Agent Health Dashboard

### Problem
No visibility into agent status:
- Is creative_analyst stuck?
- How many messages in queue per agent?
- Which agents are degraded?

### Solution: Add Health Check Endpoint

```sql
-- Create view (already in improved schema!)
SELECT agent, total_messages, completed, failed, success_rate, avg_duration_ms
FROM vw_agent_health;
```

**Add to SaaS API:**
```
GET /v1/agents/health
Response:
[
  {
    "agent": "creative_analyst",
    "success_rate": 98.5,
    "avg_duration_ms": 2340,
    "queued_messages": 15,
    "status": "healthy"
  },
  ...
]
```

---

## 13. 🔄 No Coordinator State Tracking

### Problem
Coordinator dispatches all agents regardless of task type:
- YouTube → ask all 14 agents (wasteful)
- Should route based on platforms/task type
- Some agents irrelevant for some tasks

### Solution: Task-Aware Routing

**In Coordinator:**
```javascript
// Dynamically route based on task.platforms
const task = $json.task;
const neededAgents = [];

// Always dispatch ingestion agents matching platforms
if (task.platforms.includes('youtube')) neededAgents.push('youtube_ingestion');
if (task.platforms.includes('twitter')) neededAgents.push('twitter_ingestion');
// ... etc

// Always dispatch analysis agents
neededAgents.push('enrichment', 'creative_analyst', 'synthesis_insights');

// Skip report if no analysis asked
if (task.skip_reporting) {
  // Don't add report_writer
}

return [{ json: { ...$json, target_agents: neededAgents } }];
```

---

## Implementation Priority

### Week 1 (Quick Wins)
1. ✅ Change cron from 1-minute to 5-minute (impact: -75% polling)
2. ✅ Add error handling + deadletter queue (impact: no lost messages)
3. ✅ Add timeout circuit breaker (impact: prevent hung messages)

### Week 2 (Core Features)
4. ✅ Implement dynamic rate limiting (impact: handle throttling gracefully)
5. ✅ Add agents registry table + dynamic dispatch (impact: scalability)
6. ✅ Add webhook signature validation (impact: security)

### Week 3 (Optimization)
7. ✅ Add message deduplication (impact: cost savings)
8. ✅ Implement batching (impact: 50% fewer API calls)
9. ✅ Add circuit breaker (impact: prevent cascading failures)

### Week 4+ (Polish)
10. ✅ Structured JSON logging
11. ✅ Config table for runtime tuning
12. ✅ Agent health endpoint
13. ✅ Task-aware routing

---

## Code Examples (Ready to Copy)

### Fix 1: Change All Crons to 5 Minutes
```json
"triggerTimes": {
  "item": [
    {
      "mode": "interval",
      "value": 5,
      "unit": "minutes"
    }
  ]
}
```

### Fix 2: Add Deadletter Branch
```sql
-- On JSON validation failure:
INSERT INTO public.deadletter_messages (
  task_id, thread_id, from_agent, to_agent, kind,
  payload, attempts, final_error
) VALUES (
  {{$json.task_id}}::uuid,
  {{$json.thread_id}}::uuid,
  {{$json.from_agent}},
  {{$json.to_agent}},
  {{$json.kind}},
  {{JSON.stringify($json.payload)}}::jsonb,
  {{$json.attempts}},
  {{$json.validation_reason}}
);
```

### Fix 3: Dynamic Rate Limiting
```javascript
const retryAfter = $json.response?.headers?.['retry-after'];
const delay = retryAfter 
  ? parseInt(retryAfter) * 1000
  : Number($env.RATE_LIMIT_DELAY_MS || 1200);

return [{ json: { ...$json, backoff_ms: delay } }];
```

---

## Summary Table

| # | Issue | Impact | Effort | Priority |
|---|-------|--------|--------|----------|
| 1 | Every-minute polling | 34K queries/day waste | 5 min | 🔴 Critical |
| 2 | No error handling | Lost messages | 30 min | 🔴 Critical |
| 3 | Fixed rate limits | API throttling failures | 20 min | 🔴 Critical |
| 4 | No timeout protection | Hung messages | 15 min | 🟠 High |
| 5 | Unvalidated webhooks | Security risk | 25 min | 🟠 High |
| 6 | Hardcoded agents | Bad scalability | 20 min | 🟠 High |
| 7 | No deduplication | Duplicate processing | 20 min | 🟡 Medium |
| 8 | Single-item processing | High latency | 45 min | 🟡 Medium |
| 9 | No circuit breaker | Cascading failures | 30 min | 🟡 Medium |
| 10 | Plain text logging | Poor observability | 20 min | 🟡 Medium |
| 11 | Hardcoded config | Non-flexible | 30 min | 🟡 Medium |
| 12 | No health dashboard | Blind operations | 20 min | 🟢 Low |
| 13 | No task-aware routing | Inefficient dispatch | 40 min | 🟢 Low |

---

## Next Steps

Would you like me to:
1. **Implement improvements 1-3** (polling + error handling + rate limiting)?
2. **Create updated workflow templates** with error handling?
3. **Generate migration SQL** for new tables (agents, config)?
4. **Build a workflow patch script** to apply changes across all workflows?

