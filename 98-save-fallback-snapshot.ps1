#Requires -Version 5.1
<#
.SYNOPSIS
    Save a dated fallback snapshot of the training setup scripts.
.DESCRIPTION
    Refreshes the fallback-scripts root copy and also writes a timestamped copy
    under fallback-scripts\snapshots\<timestamp>.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$fallbackRoot = Join-Path $scriptRoot 'fallback-scripts'
$snapshotsRoot = Join-Path $fallbackRoot 'snapshots'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$snapshotDir = Join-Path $snapshotsRoot $timestamp
$files = @(
    '00-preflight.ps1',
    '00-preflight.sh',
    '00-setup.ps1',
    '00-setup.sh',
    '01-setup-wsl-ssh.ps1',
    '02-setup-coding-agents.ps1',
    '02b-setup-cac.ps1',
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

New-Item -ItemType Directory -Path $fallbackRoot -Force | Out-Null
New-Item -ItemType Directory -Path $snapshotsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

Write-Step "Refreshing fallback-scripts root copy"
foreach ($file in $files) {
    Copy-Item -Path (Join-Path $scriptRoot $file) -Destination (Join-Path $fallbackRoot $file) -Force
    Write-Ok $file
}

Write-Step "Saving dated snapshot to $snapshotDir"
foreach ($file in $files) {
    Copy-Item -Path (Join-Path $scriptRoot $file) -Destination (Join-Path $snapshotDir $file) -Force
    Write-Ok $file
}

Write-Host "`nSaved fallback snapshot: $timestamp" -ForegroundColor Yellow