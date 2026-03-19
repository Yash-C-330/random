# Workflow Patch Script
param([switch]$DryRun)

$workflowPath = ".\workflow"
$backupPath = ".\workflow-backup"

Write-Host "`nWorkflow Patch Script" -ForegroundColor Cyan
Write-Host "=====================" -ForegroundColor Cyan

$files = Get-ChildItem -Path $workflowPath -Filter "*.json"
Write-Host "Found $($files.Count) files`n" -ForegroundColor Green

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    Copy-Item -Path "$workflowPath\*.json" -Destination $backupPath -Force
    Write-Host "Backup created`n" -ForegroundColor Green
}

$fix1 = 0
$fix2 = 0
$fix3 = 0

foreach ($file in $files) {
    $content = Get-Content $file.FullName -Raw
    $json = $content | ConvertFrom-Json
    
    for ($i = 0; $i -lt $json.nodes.Count; $i++) {
        $node = $json.nodes[$i]
        
        # Fix 1: Polling - change mode and add value/unit
        if ($node.type -eq "n8n-nodes-base.cron") {
            if ($node.parameters.triggerTimes.item -and $node.parameters.triggerTimes.item[0].mode -eq "everyMinute") {
                $node.parameters.triggerTimes.item[0].mode = "interval"
                $node.parameters.triggerTimes.item[0] | Add-Member -NotePropertyName "value" -NotePropertyValue 5 -Force
                $node.parameters.triggerTimes.item[0] | Add-Member -NotePropertyName "unit" -NotePropertyValue "minutes" -Force
                $fix1++
                Write-Host "  $($file.Name) - polling fix" -ForegroundColor Green
            }
        }
        
        # Fix 2: HTTP retry
        if ($node.type -eq "n8n-nodes-base.httpRequest") {
            $hasProp = $node.parameters.PSObject.Properties.Name.Contains("retryOnFail")
            if (-not $hasProp) {
                $node.parameters | Add-Member -NotePropertyName "retryOnFail" -NotePropertyValue $true -Force
                $node.parameters | Add-Member -NotePropertyName "maxRetries" -NotePropertyValue 1 -Force
                if (-not $node.parameters.PSObject.Properties.Name.Contains("options")) {
                    $node.parameters | Add-Member -NotePropertyName "options" -NotePropertyValue @{} -Force
                }
                $node.parameters.options | Add-Member -NotePropertyName "timeout" -NotePropertyValue 90000 -Force
                $fix2++
            }
        }
        
        # Fix 3: Rate limit
        if ($node.type -eq "n8n-nodes-base.wait") {
            $amt = $node.parameters.amount
            if ($amt -and $amt -ne '={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}') {
                $node.parameters.amount = '={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}'
                $fix3++
            }
        }
    }
    
    if (-not $DryRun) {
        $json | ConvertTo-Json -Depth 100 | Set-Content -Path $file.FullName
    }
}

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Fix 1 (Polling):     $fix1" -ForegroundColor Yellow
Write-Host "  Fix 2 (HTTP Retry):  $fix2" -ForegroundColor Yellow
Write-Host "  Fix 3 (Rate Limit):  $fix3" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "`nDRY RUN - no changes applied" -ForegroundColor Yellow
} else {
    Write-Host "`nPatches applied!" -ForegroundColor Green
}

Write-Host ""
