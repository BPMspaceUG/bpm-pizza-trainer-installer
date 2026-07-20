#Requires -Version 5.1
<#
.SYNOPSIS
    Preflight checks for the Windows training setup flow.
.DESCRIPTION
    Reports environment readiness without making changes. Intended to run
    before 00-setup.ps1 so setup issues are visible earlier.
.PARAMETER NoPrompt
    Do not prompt when blocking issues are detected.
#>

param(
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Test-Admin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-WebEndpoint {
    param([string]$Uri)

    try {
        Invoke-WebRequest -Uri $Uri -Method Head -UseBasicParsing -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        return $false
    }
}

$warnings = New-Object System.Collections.Generic.List[string]
$blocking = New-Object System.Collections.Generic.List[string]
$recommendedFreeGb = 30
$blockingFreeGb = 20

Write-Step "Collecting Windows preflight information"

try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Ok ("Detected OS: {0} ({1})" -f $os.Caption, $os.Version)
} catch {
    Write-Warn "Could not determine Windows version: $_"
}

if (Test-Admin) {
    Write-Ok "Running with Administrator rights"
} else {
    $warnings.Add('Not running as Administrator. Script 01 requires elevation for WSL features, sshd, and firewall changes.')
    Write-Warn "Not running as Administrator"
}

$homeRoot = [System.IO.Path]::GetPathRoot($HOME)
if ($homeRoot) {
    try {
        $driveName = $homeRoot.TrimEnd(':', '\')
        $drive = Get-PSDrive -Name $driveName
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGb -lt $blockingFreeGb) {
            $blocking.Add("Only $freeGb GB free on $homeRoot. At least $blockingFreeGb GB is required to avoid unstable training setup behavior.")
            Write-Fail "Low disk space on ${homeRoot}: $freeGb GB free"
        } elseif ($freeGb -lt $recommendedFreeGb) {
            $warnings.Add("Only $freeGb GB free on $homeRoot. $recommendedFreeGb GB or more is strongly recommended.")
            Write-Warn "Disk space is lower than recommended on ${homeRoot}: $freeGb GB free"
        } else {
            Write-Ok "Disk space looks sufficient on ${homeRoot}: $freeGb GB free"
        }
    } catch {
        Write-Warn "Could not inspect disk space for ${homeRoot}: $_"
    }
}

foreach ($cmd in @('git', 'winget', 'python', 'code', 'wsl', 'zip')) {
    if (Test-CommandAvailable -Name $cmd) {
        Write-Ok "Found command: $cmd"
    } else {
        $message = switch ($cmd) {
            'git' { 'git is missing. Repository cloning and updates will fail until Git is installed.' }
            'winget' { 'winget is missing. Package installation from 00-setup.ps1 will be limited.' }
            'python' { 'python is missing. Script 03 cannot prepare the trainer environment until Python 3.10+ is installed.' }
            'code' { 'VS Code CLI (code) is missing. Script 02 cannot install extensions automatically.' }
            'wsl' { 'wsl is missing. Script 01 cannot prepare the WSL environment.' }
            'zip' { 'zip is missing. 00-setup.ps1 will attempt to install GnuWin32.Zip for the Git Bash fallback.' }
            default { "$cmd is missing." }
        }
        $warnings.Add($message)
        Write-Warn "Missing command: $cmd"
    }
}

if (Test-CommandAvailable -Name 'wsl') {
    try {
        $distros = (wsl -l 2>&1) -replace "`0", ''
        if ($distros -match 'Ubuntu') {
            Write-Ok 'WSL reports an Ubuntu distro already installed'
        } else {
            $warnings.Add('WSL is present but no Ubuntu distro was detected. Script 01 may still need to install Ubuntu.')
            Write-Warn 'WSL found, but no Ubuntu distro detected'
        }
    } catch {
        $warnings.Add('WSL is installed but its current state could not be queried cleanly.')
        Write-Warn 'Could not query WSL distro state'
    }
}

Write-Step 'Checking network reachability'
foreach ($endpoint in @('https://github.com', 'https://download.pytorch.org', 'https://cdn.winget.microsoft.com')) {
    if (Test-WebEndpoint -Uri $endpoint) {
        Write-Ok "Reachable: $endpoint"
    } else {
        $warnings.Add("Could not reach $endpoint. Package, repo, or model dependency setup may fail without internet access.")
        Write-Warn "Unreachable: $endpoint"
    }
}

Write-Step 'Preflight summary'
if ($warnings.Count -eq 0 -and $blocking.Count -eq 0) {
    Write-Ok 'No issues detected'
    exit 0
}

foreach ($item in $warnings) {
    Write-Warn $item
}

foreach ($item in $blocking) {
    Write-Fail $item
}

if ($blocking.Count -gt 0) {
    if (-not $NoPrompt) {
        Write-Host ''
        $response = Read-Host 'Blocking issues detected. Continue anyway? [y/N]'
        if ($response -match '^[Yy]') {
            Write-Warn 'Continuing despite blocking issues'
            exit 0
        }
    }
    exit 1
}

exit 0