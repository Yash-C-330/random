# Workflow Patch Script - Apply Critical Fixes to All Workflows
# Purpose: Automatically apply critical improvements to all 16 workflows
# Usage: .\apply-workflow-patches-fixed.ps1 -DryRun

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

Show-Header "Step 2: Analyzing & Applying Fixes"

$fix1Total = 0
$fix2Total = 0
$fix3Total = 0
$modifiedFiles = @()

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
                    Show-Success "$fileName - Fix #1: Changed polling everyMinute → 5 minutes"
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
                    Show-Success "$fileName - Fix #2: Added HTTP retry to $($node.name)"
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
                    Show-Success "$fileName - Fix #3: Updated rate limit to use env variable"
                }
            }
        }
        
        # Save if modified and not dry run
        if ($modified) {
            if (-not $DryRun) {
                $json | ConvertTo-Json -Depth 100 | Set-Content -Path $file.FullName -Encoding UTF8
            }
            $modifiedFiles += $fileName
        }
        
    } catch {
        Show-Error "$fileName - Error: $_"
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
    } catch {
        $invalidCount++
        Show-Error "$(Split-Path $file -Leaf) - Invalid JSON: $_"
    }
}

if ($validCount -eq $workflowFiles.Count) {
    Show-Success "All $validCount workflows are valid JSON"
}

# ============================================================
# SUMMARY & NEXT STEPS
# ============================================================

Show-Header "Results"

Write-Host ""
Write-Host "Automated Fixes Applied:" -ForegroundColor Cyan
Write-Host "  Fix #1 (Polling):       $fix1Total workflows"
Write-Host "  Fix #2 (HTTP Retry):    $fix2Total workflows"
Write-Host "  Fix #3 (Rate Limit):    $fix3Total workflows"
Write-Host "  ─────────────────────────────────────"
Write-Host "  Total Changes:          $($fix1Total + $fix2Total + $fix3Total)"

Write-Host ""
Write-Host "Validation:" -ForegroundColor Cyan
Write-Host "  Valid workflows:        $validCount/$($workflowFiles.Count)"
Write-Host "  Invalid workflows:      $invalidCount"

if ($DryRun) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "⚠ DRY RUN MODE - No files were modified" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To apply these $($fix1Total + $fix2Total + $fix3Total) changes, run:" -ForegroundColor Cyan
    Write-Host "  .\apply-workflow-patches-fixed.ps1" -ForegroundColor White
} else {
    if ($invalidCount -eq 0) {
        Write-Host ""
        Write-Host "✓ Patching completed successfully!" -ForegroundColor Green
        Write-Host "  Backup:  $BackupFolder" -ForegroundColor Green
        Write-Host "  Modified: $($modifiedFiles.Count) workflows" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "✗ Some workflows failed validation - attempting rollback..." -ForegroundColor Red
        if (Test-Path $BackupFolder) {
            foreach ($file in $workflowFiles) {
                $backupFile = Join-Path $BackupFolder (Split-Path $file -Leaf)
                if (Test-Path $backupFile) {
                    Copy-Item -Path $backupFile -Destination $file.FullName -Force
                }
            }
            Show-Success "Restored from backup"
        }
        exit 1
    }
}

Write-Host ""
Write-Host "Manual Fixes Required (2 remaining):" -ForegroundColor Cyan
Write-Host "  Fix #4: Timeout Guard" -ForegroundColor Yellow
Write-Host "    → Add code node to detect stuck messages"
Write-Host "    → See: DEPLOYMENT-CHECKLIST.md (Phase 3)"
Write-Host ""
Write-Host "  Fix #5: Webhook Validation" -ForegroundColor Yellow
Write-Host "    → Add HMAC signature verification"
Write-Host "    → See: WORKFLOW-IMPROVEMENTS.md (Section 5)"
Write-Host ""
Write-Host "Documentation:" -ForegroundColor Cyan
Write-Host "  • WORKFLOW-PATCH-GUIDE.md"
Write-Host "  • DEPLOYMENT-CHECKLIST.md"
Write-Host "  • WORKFLOW-IMPROVEMENTS.md"
Write-Host ""
