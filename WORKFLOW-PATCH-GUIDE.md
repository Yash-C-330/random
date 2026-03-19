# Workflow Patch Script - User Guide

## What This Script Does

Automatically applies **5 critical fixes** to all 16 n8n workflows:

1. ✅ **Change polling** from 1-minute to 5-minute interval (75% cost reduction)
2. ✅ **Add HTTP retry** to Claude API calls (auto-recover from failures)  
3. ✅ **Update rate limiting** to use environment variables (consistent config)
4. 📝 **Mark for timeout guard** (requires manual code node addition)
5. 📝 **Flag webhook validation** (SaaS API, requires manual HMAC addition)

---

## Before You Run

### Prerequisites
- PowerShell 5.0 or higher (built-in Windows)
- All 16 workflow files must be in `./workflow` folder
- Have a backup plan (script auto-backups original files)

### Choose Your Risk Level

**Option A: DRY RUN (Safest - See What Would Change)**
```powershell
# No changes made, just shows what would happen
.\apply-workflow-patches.ps1 -DryRun
```

**Option B: Polling Fix Only (Low Risk)**
```powershell
# Only applies Fix #1 (most impactful, simplest)
.\apply-workflow-patches.ps1 -ApplyFix1Only
```

**Option C: All Critical Fixes (Recommended)**
```powershell
# Applies all 5 fixes at once
.\apply-workflow-patches.ps1 -ApplyAll
```

**Option D: Default (All except manual fixes)**
```powershell
# Same as Option C
.\apply-workflow-patches.ps1
```

---

## Step-by-Step Usage

### Step 1: Test with Dry Run
```powershell
cd E:\n8n_git\random

# See what changes without making them
.\apply-workflow-patches.ps1 -DryRun
```

**Expected Output:**
```
█ n8n Workflow Patch Script - Critical Fixes
Mode: DRY RUN (no changes)
Found 16 workflow files

█ Step 1: Backing Up Workflows
  [DRY RUN] Would backup workflows to: .\workflow-backup

█ Step 2: Applying Critical Fixes
Processing: 1-Coordinator_Task_Router.json
  ✓ 1-Coordinator_Task_Router - Changed cron from everyMinute to 5-minute interval
  ✓ 1-Coordinator_Task_Router - Added retryOnFail to HTTP node: Claude Analyze
  ... [more changes] ...

█ Step 3: Validating Workflows
  ✓ 1-Coordinator_Task_Router - Valid JSON structure
  ✓ 2-YouTube_Ingestion_Agent - Valid JSON structure
  ... [all 16 files] ...

█ Summary
This was a DRY RUN. No changes were made.
To apply changes, run:
  .\apply-workflow-patches.ps1 -WorkflowPath '.\workflow' -BackupFolder '.\workflow-backup'
```

Review the changes. If everything looks good, proceed to Step 2.

### Step 2: Apply Fixes
```powershell
# Apply all critical fixes
.\apply-workflow-patches.ps1

# Or just polling (safest):
.\apply-workflow-patches.ps1 -ApplyFix1Only
```

**Expected Output:**
```
█ n8n Workflow Patch Script - Critical Fixes
Mode: LIVE (applying changes)

█ Step 1: Backing Up Workflows
  ✓ All workflows backed up to: .\workflow-backup

█ Step 2: Applying Critical Fixes
Processing: 1-Coordinator_Task_Router.json
  ✓ 1-Coordinator_Task_Router - Changed cron from everyMinute to 5-minute interval
  ✓ 1-Coordinator_Task_Router - Added retryOnFail to HTTP node: Claude Analyze
  ... [15 more files] ...

█ Step 3: Validating Workflows
  ✓ All 16 workflows - Valid JSON structure

█ Summary
Fix #1 (Polling):       15 changes
Fix #2 (HTTP Retry):    14 changes
Fix #3 (Rate Limiting): 14 changes

Manual steps required:
  1. Add timeout guard code nodes
  2. Add webhook signature validation  
  3. Add error handling branches

Status: ✓ Ready
```

### Step 3: Verify Changes
```powershell
# Check backup was created
ls .\workflow-backup

# Spot-check a workflow file
cat .\workflow\8-Creative_Analyst_Agent.json | ConvertFrom-Json | % {$_.nodes} | where {$_.type -eq "n8n-nodes-base.cron"} | select parameters
```

### Step 4: Test in n8n
1. Open n8n UI
2. Go to **Workflows → Import from File**
3. Import each updated workflow
4. Activate one workflow
5. Trigger manually: Check it polls every 5 minutes
6. Check logs: Should show retry on HTTP failures

### Step 5: Deploy All Workflows
Once testing passes:
1. Import all 16 updated workflows
2. Activate them in n8n UI

---

## What Each Fix Does

### Fix #1: Change Polling Interval
**Before:**
```json
"triggerTimes": {
  "item": [{"mode": "everyMinute"}]
}
```

**After:**
```json
"triggerTimes": {
  "item": [{
    "mode": "interval",
    "value": 5,
    "unit": "minutes"
  }]
}
```

**Impact:** Coordinator & 14 agents now poll every 5 minutes (not 1 minute)
**Savings:** -1,152 database queries per hour = -27,648 per day ✅

---

### Fix #2: Add HTTP Retry
**Before:**
```json
{
  "type": "n8n-nodes-base.httpRequest",
  "parameters": {
    "url": "https://api.anthropic.com/v1/messages",
    "method": "POST"
  }
}
```

**After:**
```json
{
  "type": "n8n-nodes-base.httpRequest",
  "parameters": {
    "url": "https://api.anthropic.com/v1/messages",
    "method": "POST",
    "retryOnFail": true,
    "maxRetries": 1,
    "options": {"timeout": 90000}
  }
}
```

**Impact:** Claude API calls automatically retry once on failure
**Benefit:** Handles transient network issues gracefully ✅

---

### Fix #3: Rate Limiting via Environment Variable
**Before:**
```json
"amount": 1200
```

**After:**
```json
"amount": "={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}"
```

**Impact:** Rate limit delay can be changed via ENV variable (no workflow edit needed)
**Benefit:** Consistent config across all agents ✅

---

### Fix #4: Timeout Guard (Manual)
**Script flags but doesn't implement** because it requires adding new Code nodes.

See [`DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md) Phase 3 Fix #4 for manual implementation.

---

### Fix #5: Webhook Validation (Manual)
**Only applies to SaaS API workflow** - requires manual HMAC-SHA256 validation code.

See [`WORKFLOW-IMPROVEMENTS.md`](WORKFLOW-IMPROVEMENTS.md) section 5 for code example.

---

## Troubleshooting

### Issue: "No workflow files found"
```powershell
# Make sure you're in the right directory
cd E:\n8n_git\random

# And the workflow folder exists
ls .\workflow
```

### Issue: "INVALID JSON structure"
```powershell
# The script may have corrupted a file
# Restore from backup:
Remove-Item .\workflow\*.json
Copy-Item .\workflow-backup\*.json .\workflow\
```

### Issue: Script hangs
```powershell
# Press Ctrl+C to stop, then:
# Try with DryRun first to debug
.\apply-workflow-patches.ps1 -DryRun

# Or apply to one specific fix
.\apply-workflow-patches.ps1 -ApplyFix1Only
```

### Issue: Changes didn't apply
```powershell
# Check if files are read-only
Get-ChildItem .\workflow\*.json | % {$_.Attributes}

# If read-only, make writable:
Get-ChildItem .\workflow\*.json | % {$_.Attributes = 'Normal'}

# Then try again
.\apply-workflow-patches.ps1
```

---

## Command Reference

### Syntax
```powershell
.\apply-workflow-patches.ps1 `
  -WorkflowPath ".\workflow" `          # Where workflows are
  -BackupFolder ".\workflow-backup" `   # Where to backup originals
  -DryRun `                              # Don't change files, just preview
  -ApplyFix1Only `                       # Only fix #1 (polling)
  -ApplyAll                              # All fixes (default)
```

### Quick Commands

**Just see what would change:**
```powershell
.\apply-workflow-patches.ps1 -DryRun
```

**Apply only polling fix (safest):**
```powershell
.\apply-workflow-patches.ps1 -ApplyFix1Only
```

**Apply all fixes at once:**
```powershell
.\apply-workflow-patches.ps1 -ApplyAll
```

**Apply with custom paths:**
```powershell
.\apply-workflow-patches.ps1 `
  -WorkflowPath "E:\n8n_git\random\workflow" `
  -BackupFolder "E:\n8n_git\random\backup"
```

**Restore from backup:**
```powershell
Remove-Item .\workflow\*.json -Force
Copy-Item .\workflow-backup\*.json -Destination .\workflow -Force
```

---

## After Patching: Manual Steps Required

The script automates Fixes 1-3. You must manually implement Fixes 4-5:

### Manual Step 1: Add Timeout Guard (Every Agent)
See [`DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md) Phase 3 Fix #4

Code snippet to add:
```javascript
// Code node: "Init Timeout Guard"
const startTime = Date.now();
return [{
  json: {
    ...$json,
    _start_time_ms: startTime,
    _max_duration_ms: 120000
  }
}];
```

### Manual Step 2: Add Webhook Validation (SaaS API Only)
See [`WORKFLOW-IMPROVEMENTS.md`](WORKFLOW-IMPROVEMENTS.md) section 5

Code snippet to replace in "Validate API Key" node:
```javascript
const crypto = require('crypto');
const signature = $json.headers?.['x-webhook-signature'];
const secret = $env.WEBHOOK_SECRET;

if (!signature || !secret) {
  return [{ json: { auth_ok: false } }];
}

const payload = JSON.stringify($json.rawBody || $json.body);
const expectedSig = crypto
  .createHmac('sha256', secret)
  .update(payload)
  .digest('hex');

const isValid = signature === expectedSig;
return [{ json: { ...$json, auth_ok: isValid } }];
```

### Manual Step 3: Add Error Handling Branches (Every Agent)
See [`DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md) Phase 3 Fix #2

---

## Validation Checklist

After running the script, verify all changes:

```powershell
# Check all workflows were modified
Get-ChildItem .\workflow\*.json | % {
  $content = Get-Content $_ -Raw
  $hasInterval = $content -like "*interval*"
  $hasRetry = $content -like "*retryOnFail*"
  Write-Host "$($_.BaseName): Interval=$hasInterval, Retry=$hasRetry"
}

# Count changes
(Get-Content .\workflow\*.json -Raw | Select-String "interval" | Measure-Object).Count
# Should be ≈15 (one per polling workflow)

(Get-Content .\workflow\*.json -Raw | Select-String "retryOnFail" | Measure-Object).Count  
# Should be ≈14 (one per HTTP request in agents)
```

---

## Rollback

If something goes wrong:

```powershell
# View backup contents
ls .\workflow-backup\

# Restore original files
Remove-Item .\workflow\*.json -Force
Copy-Item .\workflow-backup\*.json .\workflow\ -Force

Write-Host "Restored original files from backup"
```

---

## Next Steps

1. ✅ Run script with `-DryRun` to preview changes
2. ✅ Run script without flags to apply fixes
3. 📝 Manually add timeout guard (Fixes 4)
4. 📝 Manually add webhook validation (Fix 5)
5. 🧪 Test one workflow in n8n UI
6. 🚀 Deploy all workflows

---

## Support

- **See what changed:** Review output from script
- **Understand what changed:** Read [`WORKFLOW-IMPROVEMENTS.md`](WORKFLOW-IMPROVEMENTS.md)
- **Manual implementation:** See [`DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md)
- **Code examples:** [`WORKFLOW-IMPROVEMENTS.md`](WORKFLOW-IMPROVEMENTS.md) sections 2-5

---

**Ready to modernize your workflows?**

```powershell
.\apply-workflow-patches.ps1 -DryRun  # Preview first
.\apply-workflow-patches.ps1          # Then apply
```

