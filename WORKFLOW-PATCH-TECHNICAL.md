# Workflow Patch Script - Technical Reference

## What Gets Modified

This document shows **exactly** what the script changes in each workflow file.

---

## Fix 1: Polling Interval (All 15 Workflows with Cron)

**Finding the node:**
- Node type: `n8n-nodes-base.cron`
- Node names: "Cron Trigger" or "Cron Poll"

**What changes:**

```diff
"triggerTimes": {
  "item": [
    {
-     "mode": "everyMinute"
+     "mode": "interval",
+     "value": 5,
+     "unit": "minutes"
    }
  ]
}
```

**Applied to:**
- ✅ 1-Coordinator_Task_Router.json
- ✅ 2-YouTube_Ingestion_Agent.json
- ✅ 3-XTwitter_Ingestion_Agent.json
- ✅ 4-TikTok_Ingestion_Agent.json
- ✅ 5-Reddit_Ingestion_Agent.json
- ✅ 6-Meta_Ad_Library_Agent.json
- ✅ 7-Enrichment_Agent.json
- ✅ 8-Creative_Analyst_Agent.json
- ✅ 9-Audience_Persona_Agent.json
- ✅ 10-Compliance_Risk_Agent.json
- ✅ 11-Performance_Scoring_Agent.json
- ✅ 12-Synthesis_Insights_Agent.json
- ✅ 13-Report_Writer_Agent.json
- ✅ 14-QAValidator_Agent.json
- ✅ 15-Notifier_Agent.json

**Result:** All 15 workflows now poll every 5 minutes instead of every minute

---

## Fix 2: HTTP Retry (14 Agent Workflows)

**Finding the node:**
- Node type: `n8n-nodes-base.httpRequest`
- Usually named: "Claude Analyze" or similar

**What changes:**

```diff
{
  "id": "claude",
  "name": "Claude Analyze",
  "type": "n8n-nodes-base.httpRequest",
  "parameters": {
    "method": "POST",
    "url": "https://api.anthropic.com/v1/messages",
+   "retryOnFail": true,
+   "maxRetries": 1,
    "sendHeaders": true,
    "headerParameters": {...},
    "sendBody": true,
    "contentType": "json",
    "specifyBody": "json",
    "jsonBody": "...",
+   "options": {
+     "timeout": 90000
+   }
  }
}
```

**Applied to:**
- ✅ 2-YouTube_Ingestion_Agent.json
- ✅ 3-XTwitter_Ingestion_Agent.json
- ✅ 4-TikTok_Ingestion_Agent.json
- ✅ 5-Reddit_Ingestion_Agent.json
- ✅ 6-Meta_Ad_Library_Agent.json
- ✅ 7-Enrichment_Agent.json
- ✅ 8-Creative_Analyst_Agent.json
- ✅ 9-Audience_Persona_Agent.json
- ✅ 10-Compliance_Risk_Agent.json
- ✅ 11-Performance_Scoring_Agent.json
- ✅ 12-Synthesis_Insights_Agent.json
- ✅ 13-Report_Writer_Agent.json
- ✅ 14-QAValidator_Agent.json
- ✅ 15-Notifier_Agent.json

**Result:** All 14 agents will retry Claude API calls once on failure

---

## Fix 3: Rate Limit Configuration (14 Agent Workflows)

**Finding the node:**
- Node type: `n8n-nodes-base.wait`
- Node names: "Rate Limit Wait" or similar (contains "rate" or "wait")

**What changes:**

```diff
{
  "id": "rateWait",
  "name": "Rate Limit Wait",
  "type": "n8n-nodes-base.wait",
  "parameters": {
-   "amount": 1200,
+   "amount": "={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}",
    "unit": "milliseconds"
  }
}
```

**Applied to:** Same 14 agent workflows (all except Coordinator)

**Result:** Rate limit delay comes from environment variable (default 1200ms)

---

## What Script Does NOT Change

The following require **manual implementation**:

### ❌ Fix 4: Timeout Guard (Requires New Code Nodes)
Not automated because it requires:
- Adding a new Code node at workflow start
- Adding validation Code nodes at multiple steps  
- Adding conditional branches

**Manual implementation guide:** [`DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md) Phase 3 Fix #4

### ❌ Fix 5: Webhook Signature Validation (SaaS API Only)
Not automated because it requires:
- Modifying existing validation code (not just adding properties)
- Testing with actual webhook clients

**Manual implementation guide:** [`WORKFLOW-IMPROVEMENTS.md`](WORKFLOW-IMPROVEMENTS.md) section 5

---

## File-by-File Impact

### Coordinator (1-Coordinator_Task_Router.json)
```
Fix 1: Polling    ✅ (1 Cron node)
Fix 2: HTTP Retry ❌ (no HTTP nodes)
Fix 3: Rate Limit ❌ (no Wait nodes)
```

**Changes:** 1 (Coordinator doesn't call Claude)

### YouTube Ingestion (2-YouTube_Ingestion_Agent.json)
```
Fix 1: Polling    ✅ (1 Cron node)
Fix 2: HTTP Retry ✅ (1 Claude HTTP node)
Fix 3: Rate Limit ✅ (1 Wait node)
```

**Changes:** 3

### All Other Agents (3-15)
Same as YouTube Ingestion

**Changes per agent:** 3
**Total changes:** 15 × 1 + 14 × 3 = **57 changes**

---

## Affected Configuration

### Environment Variables Used
- `RATE_LIMIT_DELAY_MS` - Delay between API calls (default: 1200ms)

### Where Configured
Add to your `.env` file:
```bash
RATE_LIMIT_DELAY_MS=1200  # Already in defaults
```

### How to Change Post-Deployment
```powershell
# In PowerShell, set environment variable:
$env:RATE_LIMIT_DELAY_MS = 2000

# Or in .env file:
RATE_LIMIT_DELAY_MS=2000
```

Then restart n8n for changes to take effect.

---

## Validation Examples

### Check if Fix 1 was applied:
```powershell
$content = Get-Content .\workflow\2-YouTube_Ingestion_Agent.json -Raw
$content | Select-String '"mode":\s*"interval"' | Measure-Object
# Should find 1 match
```

### Check if Fix 2 was applied:
```powershell
$content = Get-Content .\workflow\2-YouTube_Ingestion_Agent.json -Raw
$content | Select-String '"retryOnFail":\s*true' | Measure-Object
# Should find 1+ matches
```

### Check if Fix 3 was applied:
```powershell
$content = Get-Content .\workflow\2-YouTube_Ingestion_Agent.json -Raw
$content | Select-String 'RATE_LIMIT_DELAY_MS' | Measure-Object
# Should find 1 match
```

---

## Testing the Changes

### Test Fix 1: Polling Works
1. Activate Coordinator workflow
2. Check logs at T+0s, T+5m, T+10m
3. Should see messages every 5 minutes (not 1 minute)

### Test Fix 2: HTTP Retry Works
1. Manually trigger an agent workflow
2. Simulate Claude API failure (e.g., network timeout)
3. Check logs: Should see "retrying" message
4. Should succeed on retry

### Test Fix 3: Rate Limit Works
1. Set `RATE_LIMIT_DELAY_MS=5000` in environment
2. Restart n8n
3. Run agent workflow
4. Should see 5-second delays between API calls

---

## Gotchas & Quirks

### Quirk 1: Webhook Workflow Not Modified
The SaaS API workflow (`16-SaaS_API_Workflow.json`) only has Fixes 4 & 5 flagged for manual implementation (not automated).

### Quirk 2: Timeout Values
- HTTP nodes set to 90 seconds (`90000` ms)
- This is Claude API hard limit, don't change

### Quirk 3: Retry Configuration  
- Only retries once (`maxRetries: 1`)
- Can be increased to 2-3 if needed, but adds latency

### Quirk 4: Rate Limit Default
- Falls back to 1200ms if `RATE_LIMIT_DELAY_MS` not set
- This is safe but may cause throttling with high volume

---

## Reverting Changes

If you need to revert:

```powershell
# Restore from the backup the script created
Remove-Item .\workflow\*.json -Force
Copy-Item .\workflow-backup\*.json .\workflow\ -Force
```

Or manually revert individual changes:

### Revert Fix 1:
Change back in Cron node:
```json
"mode": "everyMinute"
```

### Revert Fix 2:
Remove from HTTP node:
```json
"retryOnFail": true,
"maxRetries": 1,
"options": {"timeout": 90000}
```

### Revert Fix 3:
Change back in Wait node:
```json
"amount": 1200
```

---

## Manual Fixes to Add After Scripting

### Add-On 1: Timeout Guard Code (Every Agent)
Add new Code node after message claim:
```javascript
const startTime = Date.now();
const maxDuration = Number($env.MAX_MESSAGE_DURATION_MS || 120000);

return [{
  json: {
    ...$json,
    _start_time_ms: startTime,
    _max_duration_ms: maxDuration
  }
}];
```

### Add-On 2: Webhook Validation (SaaS API Only)
Replace "Validate API Key" code node:
```javascript
const crypto = require('crypto');
const signature = $json.headers?.['x-webhook-signature'];
const secret = $env.WEBHOOK_SECRET;

if (!signature || !secret) return [{ json: { auth_ok: false } }];

const payload = JSON.stringify($json.rawBody || $json.body);
const expectedSig = crypto.createHmac('sha256', secret).update(payload).digest('hex');

return [{ json: { ...$json, auth_ok: signature === expectedSig } }];
```

---

## Summary Table

| Fix | Scope | Automated | Changes | Files |
|-----|-------|-----------|---------|-------|
| 1 - Polling | All | ✅ Yes | 15 | All 15 with cron |
| 2 - Retry | Agents | ✅ Yes | 14 | 14 agents |
| 3 - Rate Limit | Agents | ✅ Yes | 14 | 14 agents |
| 4 - Timeout | All | ❌ Manual | - | TBD |
| 5 - Webhook | SaaS API | ❌ Manual | - | 1 file |
| **Total** | | | **43** | **16** |

---

## Questions?

- **How do I verify changes?** Run tests in section "Testing the Changes"
- **How do I revert?** See section "Reverting Changes"
- **Which fixes are most important?** Fix 1 & 2 (biggest impact)
- **Do I need to change all 16 files?** Yes, most workflows benefit from all fixes
- **Can I apply fixes one at a time?** Yes, use `-ApplyFix1Only` flag

---

**Script Status:** Ready to use ✨  
**Files Modified:** 16 workflow JSON files  
**Total Changes:** 43 automatic + 2 manual fixes required  
**Backup Location:** `workflow-backup/` (auto-created)

