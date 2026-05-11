#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the active scripts from fallback-scripts or a dated snapshot.
.PARAMETER Snapshot
    Optional dated snapshot directory name under fallback-scripts\snapshots.
#>

param(
    [string]$Snapshot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$fallbackRoot = Join-Path $scriptRoot 'fallback-scripts'
$snapshotSource = if ($Snapshot) {
    Join-Path (Join-Path $fallbackRoot 'snapshots') $Snapshot
} else {
    $fallbackRoot
}
$files = @(
    '00-preflight.ps1',
    '00-preflight.sh',
    '00-setup.ps1',
    '00-setup.sh',
    '01-setup-wsl-ssh.ps1',
    '02-setup-coding-agents.ps1',
    '03-setup-pizza-ml-trainer.ps1',
    '03-setup-pizza-ml-trainer.sh',
    'launch.bat'
)

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

if (-not (Test-Path $snapshotSource)) {
    throw "Fallback source not found: $snapshotSource"
}

Write-Step "Restoring scripts from $snapshotSource"
foreach ($file in $files) {
    $source = Join-Path $snapshotSource $file
    if (-not (Test-Path $source)) {
        throw "Missing fallback file: $source"
    }
    Copy-Item -Path $source -Destination (Join-Path $scriptRoot $file) -Force
    Write-Ok $file
}

Write-Host "`nRestore complete." -ForegroundColor Yellow