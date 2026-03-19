# Workflow Patch Script - Apply Critical Fixes to All Workflows
# Purpose: Automatically apply critical improvements to all 16 workflows
# Usage: .\apply-workflow-patches.ps1 -DryRun

param(
    [Parameter(Mandatory=$false)]
    [string]$WorkflowPath = ".\workflow",
    
    [Parameter(Mandatory=$false)]
    [string]$BackupFolder = ".\workflow-backup",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

$ErrorActionPreference = 'Continue'

# Color output helpers
function Show-Header {
    param([string]$Text)
    Write-Host "`n█ $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Show-Success {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Show-Warning {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Show-Error {
    param([string]$Text)
    Write-Host "  ✗ $Text" -ForegroundColor Red
}

function Show-Info {
    param([string]$Text)
    Write-Host "  → $Text" -ForegroundColor Gray
}

# Validate paths
if (-not (Test-Path $WorkflowPath)) {
    Show-Error "Workflow path not found: $WorkflowPath"
    exit 1
}

Show-Header "n8n Workflow Patch Script - Critical Fixes"

if ($DryRun) {
    Write-Host "       Mode: DRY RUN (no changes)" -ForegroundColor Yellow
}

# Get workflow files
$workflowFiles = @(Get-ChildItem -Path $WorkflowPath -Filter "*.json" -ErrorAction SilentlyContinue)

if ($workflowFiles.Count -eq 0) {
    Show-Error "No workflow files found in: $WorkflowPath"
    exit 1
}

Show-Info "Found $($workflowFiles.Count) workflow files`n"

# ============================================================
# BACKUP WORKFLOWS
# ============================================================

Show-Header "Step 1: Creating Backup"

if (-not $DryRun) {
    if (Test-Path $BackupFolder) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $BackupFolder = "$BackupFolder-$timestamp"
        Show-Warning "Backup folder exists, using: $BackupFolder"
    }
    
    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
    foreach ($file in $workflowFiles) {
        Copy-Item -Path $file.FullName -Destination $BackupFolder -Force
    }
    Show-Success "Backed up $($workflowFiles.Count) workflows to: $BackupFolder"
} else {
    Show-Info "[DRY-RUN] Would create backup at: $BackupFolder"
}

# ============================================================
# APPLY FIXES
# ============================================================

Show-Header "Step 2: Applying Critical Fixes"

$fix1Total = 0
$fix2Total = 0
$fix3Total = 0

foreach ($file in $workflowFiles) {
    $fileName = Split-Path $file -Leaf
    
    try {
        $content = Get-Content -Path $file.FullName -Raw
        $json = $content | ConvertFrom-Json -ErrorAction Stop
        $modified = $false
        
        # FIX 1: Change polling from everyMinute to 5-minute interval
        foreach ($node in $json.nodes) {
            if ($node.type -eq "n8n-nodes-base.cron") {
                if ($node.parameters.triggerTimes.item[0].mode -eq "everyMinute") {
                    $node.parameters.triggerTimes.item[0].mode = "interval"
                    $node.parameters.triggerTimes.item[0].value = 5
                    $node.parameters.triggerTimes.item[0].unit = "minutes"
                    $modified = $true
                    $fix1Total++
                    Show-Success "$fileName - Changed polling: everyMinute → 5 minutes"
                }
            }
        }
        
        # FIX 2: Add HTTP retry configuration
        foreach ($node in $json.nodes) {
            if ($node.type -eq "n8n-nodes-base.httpRequest") {
                if (-not $node.parameters.retryOnFail) {
                    $node.parameters | Add-Member -NotePropertyName "retryOnFail" -NotePropertyValue $true -Force
                    $node.parameters | Add-Member -NotePropertyName "maxRetries" -NotePropertyValue 1 -Force
                    
                    if (-not $node.parameters.options) {
                        $node.parameters | Add-Member -NotePropertyName "options" -NotePropertyValue @{} -Force
                    }
                    $node.parameters.options | Add-Member -NotePropertyName "timeout" -NotePropertyValue 90000 -Force
                    
                    $modified = $true
                    $fix2Total++
                    Show-Success "$fileName - Added HTTP retry: $($node.name)"
                }
            }
        }
        
        # FIX 3: Update rate limit to use environment variable
        foreach ($node in $json.nodes) {
            if ($node.type -eq "n8n-nodes-base.wait") {
                if ($node.parameters.amount -and $node.parameters.amount -ne '={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}') {
                    $node.parameters.amount = '={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}'
                    $node.parameters.unit = "milliseconds"
                    $modified = $true
                    $fix3Total++
                    Show-Success "$fileName - Updated rate limit: using env variable"
                }
            }
        }
        
        # Save if modified and not dry run
        if ($modified -and -not $DryRun) {
            $json | ConvertTo-Json -Depth 100 | Set-Content -Path $file.FullName -Encoding UTF8
            Show-Info "$fileName - Changes saved"
        } elseif ($modified -and $DryRun) {
            Show-Info "$fileName - [DRY-RUN] Changes would be applied"
        }
        
    } catch {
        Show-Error "$fileName - Error processing: $_"
    }
}

# ============================================================
# VALIDATION
# ============================================================

Show-Header "Step 3: Validating Workflows"

$validCount = 0
$invalidCount = 0

foreach ($file in $workflowFiles) {
    try {
        $content = Get-Content -Path $file.FullName -Raw
        $json = $content | ConvertFrom-Json -ErrorAction Stop
        $validCount++
        Show-Success "$(Split-Path $file -Leaf) - Valid JSON"
    } catch {
        $invalidCount++
        Show-Error "$(Split-Path $file -Leaf) - Invalid JSON: $_"
    }
}

# ============================================================
# SUMMARY
# ============================================================

Show-Header "Summary"

Write-Host "`nFix Results:"
Write-Host "  Fix #1 (Polling Interval):  $fix1Total changes"
Write-Host "  Fix #2 (HTTP Retry):        $fix2Total changes"
Write-Host "  Fix #3 (Rate Limiting):     $fix3Total changes"
Write-Host "  ───────────────────────────────────────"
Write-Host "  Total Automated Changes:    $($fix1Total + $fix2Total + $fix3Total)"

Write-Host "`nValidation:"
Write-Host "  Valid workflows:   $validCount/$($workflowFiles.Count)"
Write-Host "  Invalid workflows: $invalidCount"

if ($invalidCount -gt 0) {
    Show-Error "Some workflows are invalid!"
    if (-not $DryRun) {
        Show-Warning "Attempting rollback..."
        if (Test-Path $BackupFolder) {
            foreach ($file in $workflowFiles) {
                $backupFile = Join-Path $BackupFolder (Split-Path $file -Leaf)
                if (Test-Path $backupFile) {
                    Copy-Item -Path $backupFile -Destination $file -Force
                }
            }
            Show-Info "Restored from backup"
        }
    }
    exit 1
}

Write-Host ""

# Manual fixes required
Show-Header "Manual Fixes Required"

Write-Host "`nThe following fixes require manual implementation:"
Write-Host "`n  Fix #4: Timeout Guard (All Workflows)"
Write-Host "    → Add code node to detect stuck messages"
Write-Host "    → See: DEPLOYMENT-CHECKLIST.md Phase 3"

Write-Host "`n  Fix #5: Webhook Validation (SaaS API Only)"
Write-Host "    → Add HMAC signature verification"
Write-Host "    → See: WORKFLOW-IMPROVEMENTS.md Section 5"

# Next steps
Show-Header "Next Steps"

if ($DryRun) {
    Write-Host ""
    Write-Host "This was a DRY RUN - no changes were made." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To apply changes, run:"
    Write-Host "  .\apply-workflow-patches.ps1" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "✓ Automated fixes applied successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Backup Location: $BackupFolder" -ForegroundColor Green
    Write-Host ""
    Write-Host "Now do the following:"
    Write-Host "  1. Implement manual Fix #4 (Timeout Guard)"
    Write-Host "  2. Implement manual Fix #5 (Webhook Validation)"
    Write-Host "  3. Test a workflow in n8n UI"
    Write-Host "  4. Verify polling occurs every 5 minutes (not 1)"
    Write-Host "  5. Activate all workflows"
    Write-Host ""
    Write-Host "See documentation:"
    Write-Host "  - DEPLOYMENT-CHECKLIST.md"
    Write-Host "  - WORKFLOW-IMPROVEMENTS.md"
    Write-Host "  - WORKFLOW-PATCH-GUIDE.md"
    Write-Host ""
}

Write-Host "Status: $(if ($invalidCount -eq 0) { '✓ Success' } else { '✗ Failed' })" -ForegroundColor $(if ($invalidCount -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
