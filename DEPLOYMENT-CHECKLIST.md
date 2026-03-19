# Deployment Checklist - Improvements Implementation

## Pre-Deployment (Before You Start)

- [ ] Backup your Supabase database
- [ ] Backup your n8n workflows (export JSON)
- [ ] Schedule maintenance window (if making breaking changes)
- [ ] Notify team: "Workflow improvements incoming"
- [ ] Read `IMPROVEMENTS-MASTER-SUMMARY.md` (takes 5 min)

---

## Phase 1: Database Improvements (30 minutes)

### Database Migration

**Option A: Automated (Recommended)**
```powershell
cd e:\n8n_git\random

# First, do a dry run
.\schema-migrate.ps1 -ConnectionString "Host=...;Port=5432;Database=...;Username=...;Password=..." -DryRun

# Review the output, then run for real
.\schema-migrate.ps1 -ConnectionString "Host=...;Port=5432;Database=...;Username=...;Password=..."
```

**Option B: Manual**
1. [ ] Open Supabase SQL Editor
2. [ ] Copy content from `schema-improved.sql`
3. [ ] Run in database (takes 2-5 minutes)
4. [ ] Verify: Check for new tables and indexes

### Verify Migration
```sql
-- Run these in Supabase SQL Editor:

-- Check new tables exist
SELECT tablename FROM pg_tables 
WHERE schemaname='public' AND tablename IN ('execution_events','agent_metrics','rate_limit_log','deadletter_messages');

-- Check indexes created
SELECT COUNT(*) as index_count FROM pg_indexes WHERE schemaname='public' AND indexname LIKE '%_idx%';
-- Should show at least 40+ indexes

-- Check views exist
SELECT viewname FROM pg_views WHERE schemaname='public' AND viewname LIKE 'vw_%';

-- Test a view
SELECT * FROM vw_agent_health LIMIT 5;
```

- [ ] All tables exist
- [ ] All indexes created
- [ ] All views accessible

---

## Phase 2: Deploy Workflow Support Tables (20 minutes)

### Create Supporting Tables

1. [ ] Open Supabase SQL Editor
2. [ ] Copy content from `workflow-improvements-schema.sql`
3. [ ] Run in database (takes 1-2 minutes)

### Verify Tables

```sql
-- Check tables created
SELECT tablename FROM pg_tables 
WHERE schemaname='public' AND tablename IN ('agents_registry','workflow_config','agent_dependencies','agent_health_snapshot','api_quota_tracking','task_execution_plan');

-- Check agents are populated
SELECT COUNT(*) as agent_count FROM agents_registry WHERE enabled = true;
-- Should show 14

-- Check config values exist
SELECT COUNT(*) as config_count FROM workflow_config;
-- Should show 13+

-- Test functions work
SELECT public.get_config_value('BATCH_SIZE', 'prod');
```

- [ ] agents_registry table created and populated with 14 agents
- [ ] workflow_config table created and populated with settings
- [ ] All helper functions created
- [ ] All views created

---

## Phase 3: Critical Workflow Fixes (120 minutes)

### Fix #1: Change Polling from 1-minute to 5 minutes (15 min)

**Workflows to update:**
- [ ] 1-Coordinator_Task_Router.json
- [ ] 2-YouTube_Ingestion_Agent.json
- [ ] 3-XTwitter_Ingestion_Agent.json
- [ ] 4-TikTok_Ingestion_Agent.json
- [ ] 5-Reddit_Ingestion_Agent.json
- [ ] 6-Meta_Ad_Library_Agent.json
- [ ] 7-Enrichment_Agent.json
- [ ] 8-Creative_Analyst_Agent.json
- [ ] 9-Audience_Persona_Agent.json
- [ ] 10-Compliance_Risk_Agent.json
- [ ] 11-Performance_Scoring_Agent.json
- [ ] 12-Synthesis_Insights_Agent.json
- [ ] 13-Report_Writer_Agent.json
- [ ] 14-QAValidator_Agent.json
- [ ] 15-Notifier_Agent.json

**How to change:**
In n8n UI:
```
Workflows → [workflow name] → Edit
  Find: "Cron Trigger" or "Cron Poll" node
  Edit → Change "Mode" from "everyMinute" to "interval: 5 minutes"
  Save
```

**Testing:**
- [ ] Coordinator still polls every 5 min
- [ ] Agents still pick up messages
- [ ] Check database: fewer queries in 5-minute window

**Impact:** -34K queries/day, -75% polling cost ✅

---

### Fix #2: Add Error Handling to Agents (60 min)

Edit **each agent workflow** to add error paths:

**For each of 14 agent workflows:**

1. [ ] Find "Claude Analyze" (HTTP Request node)
2. [ ] Click the node, go to "Express" tab
3. [ ] Add error handling:
   ```json
   "retryOnFail": true,
   "maxRetries": 1
   ```
4. [ ] Add Code node after validation: "Calculate Exponential Backoff"
   Copy code from `WORKFLOW-IMPROVEMENTS.md` section 2
5. [ ] Add Postgres node in error branch: "Send to Deadletter"
   Copy SQL from `WORKFLOW-IMPROVEMENTS.md` section 2
6. [ ] Test: Manually trigger with bad data, verify deadletter entry

**Validation:**
```sql
-- After testing, should see entries:
SELECT * FROM deadletter_messages WHERE created_at > NOW() - INTERVAL '1 hour';
```

- [ ] All 14 agents have error handling
- [ ] Deadletter entries created on failures
- [ ] No messages stuck in "claimed" state

**Impact:** Zero message loss ✅

---

### Fix #3: Dynamic Rate Limiting (30 min)

Edit **each agent workflow**:

1. [ ] Find "Validate JSON" code node
2. [ ] Add after "Claude Analyze" node: "Parse Rate Limit Headers"
   Copy code from `WORKFLOW-IMPROVEMENTS.md` section 3
3. [ ] Update "Rate Limit Wait" node to use dynamic delay:
   ```
   change: $env.RATE_LIMIT_DELAY_MS
   to:     $json.backoff_ms (from previous step)
   ```
4. [ ] Test: Trigger rate limit (call >5x in sequence), verify backoff

**Validation:**
```sql
-- Check rate limit log
SELECT * FROM rate_limit_log WHERE was_throttled = true;
```

- [ ] Rate limit headers parsed
- [ ] Dynamic backoff applied
- [ ] Respects API retry-after header

**Impact:** Handles throttling without manual intervention ✅

---

### Fix #4: Request Timeout Protection (20 min)

Edit **Coordinator and each agent**:

1. [ ] Add Code node at message start: "Init Timeout Guard"
   ```javascript
   const startTime = Date.now();
   return [{
     json: {
       ...$json,
       _start_time_ms: startTime,
       _max_duration_ms: 120000  // 2 minutes
     }
   }];
   ```

2. [ ] Add validation Code nodes before each critical step:
   ```javascript
   const elapsed = Date.now() - $json._start_time_ms;
   if (elapsed > $json._max_duration_ms) {
     throw new Error(`Timeout after ${elapsed}ms`);
   }
   return [$json];
   ```

3. [ ] Add error branch to catch timeout, mark message as "blocked"

- [ ] Timeouts detected before hanging
- [ ] Messages marked appropriately
- [ ] No stuck messages in "claimed" state

**Impact:** Prevent forever-stuck messages ✅

---

### Fix #5: Webhook Signature Validation (25 min)

Edit **16-SaaS_API_Workflow.json**:

1. [ ] Find "Validate API Key" code node
2. [ ] Replace with new validation: "Validate Request Signature"
   Copy code from `WORKFLOW-IMPROVEMENTS.md` section 5

3. [ ] Test with signature:
   ```powershell
   # Generate signature and test webhook endpoint
   $payload = @{queries=@("test")} | ConvertTo-Json
   $secret = $env:WEBHOOK_SECRET
   # Calculate HMAC-SHA256 and test
   ```

4. [ ] Require signature header in callers:
   ```
   Header: x-webhook-signature: <calculated_hash>
   ```

- [ ] Webhooks validate signatures
- [ ] Unauthenticated requests rejected
- [ ] All callers updated to send signatures

**Impact:** API injection attacks prevented ✅

---

## Phase 4: Testing (60 minutes)

### Local Testing

**Create a test task:**
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

### Workflow Testing

Activate workflows one at a time and test:

1. [ ] Coordinator picks up task within 5 minutes
2. [ ] Agents claim messages
3. [ ] Claude calls succeed
4. [ ] Results written to database
5. [ ] Monitoring events recorded

### Verify Monitoring

```sql
-- Check execution events
SELECT agent, event_type, COUNT(*) 
FROM execution_events 
WHERE task_id = (SELECT id FROM tasks ORDER BY created_at DESC LIMIT 1)
GROUP BY agent, event_type;

-- Check agent metrics
SELECT agent, messages_processed, validation_passed
FROM agent_metrics
WHERE task_id = (SELECT id FROM tasks ORDER BY created_at DESC LIMIT 1);

-- Check views work
SELECT * FROM vw_task_summary 
WHERE id = (SELECT id FROM tasks ORDER BY created_at DESC LIMIT 1);
```

- [ ] Task created and claimed
- [ ] All agents processed messages
- [ ] Execution events recorded
- [ ] Agent metrics calculated
- [ ] Dashboard views show data

---

## Phase 5: Production Rollout (30 minutes)

### Pre-Production Checklist

- [ ] All critical fixes deployed
- [ ] Test passes on 5+ sample tasks
- [ ] Monitoring shows healthy agent status
- [ ] Error handling works (verified with deadletter)
- [ ] Rate limiting adaptive (verified with throttle)
- [ ] Database performance improved (indexes active)

### Production Activation

1. [ ] Coordinator workflow: **Activate**
2. [ ] 14 agent workflows: **Activate**
3. [ ] SaaS API workflow: **Activate** (if needed)

### Post-Activation Monitoring (First 24 hours)

Check every 4 hours:

```sql
-- Agent health
SELECT agent, success_rate, avg_duration_ms 
FROM vw_agent_health;

-- Active tasks
SELECT status, COUNT(*) FROM vw_task_summary GROUP BY status;

-- Error rate
SELECT COUNT(*) FROM deadletter_messages 
WHERE created_at > NOW() - INTERVAL '4 hours';

-- No stuck messages
SELECT COUNT(*) FROM agent_messages 
WHERE state = 'claimed' AND updated_at < NOW() - INTERVAL '10 minutes';
```

If everything shows:
- ✅ Success rate 95%+
- ✅ No stuck messages
- ✅ Few deadletter entries
- ✅ Latencies stable

→ **Deployment successful!** 🎉

---

## Phase 6: Optional Enhancements (Next Week)

After critical fixes are stable:

- [ ] Deploy agents registry + dynamic dispatch
- [ ] Add message deduplication
- [ ] Implement circuit breaker for agent health
- [ ] Add structured JSON logging
- [ ] Create config management table
- [ ] Build health dashboard
- [ ] Implement batch processing

See `WORKFLOW-IMPROVEMENTS.md` for details.

---

## Troubleshooting

### Issue: Migration script fails
```powershell
# Run with diagnostics
.\schema-migrate.ps1 -ConnectionString "..." -DryRun -Verbose
```

### Issue: Workflows won't activate
1. Check credentials are configured (Supabase Postgres, Anthropic)
2. Verify database is accessible
3. Check Postgres credential in n8n has right permissions

### Issue: Messages stuck in "claimed" state
1. Check Agent Health: `SELECT * FROM vw_agent_health;`
2. Look for errors: `SELECT * FROM logs WHERE level='error' LIMIT 10;`
3. Check timeout guard added to workflows

### Issue: Rate limiting not working
1. Verify "Parse Rate Limit Headers" code node exists
2. Check response from Claude includes retry-after header
3. Verify backoff_ms is being calculated

### Issue: Deadletter entries for valid messages
1. Check JSON validation logic
2. Review log: `SELECT error FROM deadletter_messages WHERE created_at > NOW() - INTERVAL '1 hour';`
3. Fix validation code if needed

---

## Rollback Plan (If Needed)

If something breaks catastrophically:

```sql
-- Keep old messages flowing:
-- 1. Deactivate broken workflows
-- 2. Deactivate improved schema (keep it, don't delete):
DROP INDEX IF EXISTS <new_index_name>;  -- Only drop if critical
-- 3. Messages will still process with old schema

-- To fully revert:
DROP TABLE IF EXISTS execution_events CASCADE;
DROP TABLE IF EXISTS agent_metrics CASCADE;
DROP TABLE IF EXISTS rate_limit_log CASCADE;
DROP TABLE IF EXISTS deadletter_messages CASCADE;
-- Original tables untouched
```

---

## Success Criteria

After deployment, you should see:

| Metric | Target | How to Check |
|--------|--------|-------------|
| Polling cost | 75% reduction | DB query stats |
| Message loss | 0% | Deadletter empty |
| Error recovery | Automatic | Error logs decline |
| Agent visibility | Full | vw_agent_health accurate |
| API throttling | Handled gracefully | No 429 errors in logs |

---

## Sign-Off Checklist

- [ ] Database migration completed
- [ ] Support tables deployed
- [ ] 5 critical fixes applied to all workflows
- [ ] Testing passed
- [ ] Monitoring verified
- [ ] Production activated
- [ ] 24-hour post-launch monitoring completed
- [ ] Team notified of improvements
- [ ] Documentation updated

---

## Next Steps (After Stabilization)

1. **Week 2:** Implement optional enhancements (agents registry, circuit breaker)
2. **Week 3:** Deploy advanced features (batching, task-aware routing)
3. **Week 4:** Fine-tune based on monitoring data

---

## Support Docs Reference

| Document | Use When |
|----------|----------|
| `IMPROVEMENTS-MASTER-SUMMARY.md` | Want overview of all improvements |
| `WORKFLOW-IMPROVEMENTS.md` | Need detailed explanation of an issue |
| `WORKFLOW-QUICK-FIX.md` | Want quick checklist |
| `schema-improved.sql` | Deploying database changes |
| `SCHEMA-MIGRATION-GUIDE.md` | Need migration walkthrough |
| `N8N-MONITORING-INTEGRATION.md` | Adding monitoring to workflows |
| `workflow-improvements-schema.sql` | Deploying support tables |

---

## Estimated Timeline

- Pre-deployment prep: **15 min**
- Database migration: **30 min**
- Support tables: **20 min**
- Critical workflow fixes: **120 min**
- Testing: **60 min**
- Production rollout: **30 min**
- **Total:** ~4.5 hours

---

**You got this! 💪**

Start with the database migration (safest), then apply workflow fixes incrementally.

