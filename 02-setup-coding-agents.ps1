#Requires -Version 5.1
<#
.SYNOPSIS
    Script 2: Install VS Code AI extensions and the CAC CLI tool.
.DESCRIPTION
    Installs a curated set of VS Code extensions for AI-assisted coding, then
    installs the CAC (CodingAgentConfigCopy) CLI via WSL Ubuntu or Git Bash.
    Remote installer execution is explicitly confirmed before it runs.
.PARAMETER AllowRemoteScriptInstall
    Allow automatic CAC installation using the remote installer fetched from GitHub.
.NOTES
    Run as a normal user AFTER Script 1 (01-setup-wsl-ssh.ps1) and a reboot.
#>

param(
    [switch]$AllowRemoteScriptInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Confirm-Action {
    param(
        [string]$Prompt,
        [bool]$DefaultNo = $true
    )

    $suffix = if ($DefaultNo) { '[y/N]' } else { '[Y/n]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return (-not $DefaultNo)
    }

    return ($answer -match '^[Yy]')
}

# ─────────────────────────────────────────────────────────────
# Phase 1 — VS Code Extensions
# ─────────────────────────────────────────────────────────────

Write-Step "Checking for VS Code CLI (code)"

$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if (-not $codeCmd) {
    Write-Fail "'code' not found on PATH. Is VS Code installed and added to PATH?"
    Write-Warn "Skipping extension installs. Re-run after installing VS Code."
} else {
    Write-Success "Found: $($codeCmd.Source)"

    $extensions = [ordered]@{
        'anthropic.claude-code'                  = 'Claude Code'
        'openai.chatgpt'                         = 'OpenAI / ChatGPT'
        'ms-python.python'                       = 'Python'
        'ms-python.vscode-pylance'               = 'Pylance (Python type checking)'
        'google.geminicodeassist'                = 'Gemini Code Assist'
        'continue.continue'                      = 'Continue.dev (multi-AI)'
        'GitHub.copilot'                         = 'GitHub Copilot'
        'GitHub.copilot-chat'                    = 'GitHub Copilot Chat'
        'ms-toolsai.jupyter'                     = 'Jupyter Notebooks'
        'eamodio.gitlens'                        = 'GitLens'
        'VisualStudioExptTeam.vscodeintellicode' = 'IntelliCode'
        'ms-python.black-formatter'              = 'Black Formatter'
        'pablodelucca.pixel-agents'              = 'Pixel Agents'
    }

    $extResults = [ordered]@{}

    Write-Host ""
    foreach ($id in $extensions.Keys) {
        $name = $extensions[$id]
        Write-Host "  Installing $name ($id)..." -ForegroundColor Gray -NoNewline
        try {
            & code --install-extension $id --force 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " OK" -ForegroundColor Green
                $extResults[$id] = 'Installed'
            } else {
                Write-Host " WARN (exit $LASTEXITCODE)" -ForegroundColor Yellow
                $extResults[$id] = "Exit $LASTEXITCODE"
            }
        } catch {
            Write-Host " FAIL" -ForegroundColor Red
            $extResults[$id] = "Error: $_"
        }
    }

    Write-Host ""
    Write-Host "Extension Install Summary:" -ForegroundColor White
    foreach ($id in $extResults.Keys) {
        $status = $extResults[$id]
        $color  = if ($status -eq 'Installed') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-52} {1}" -f $id, $status) -ForegroundColor $color
    }
}

# ─────────────────────────────────────────────────────────────
# Phase 2 — CAC Installation
# ─────────────────────────────────────────────────────────────

Write-Step "Installing CAC (CodingAgentConfigCopy)"

$cacInstallCmd = 'curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | bash -s -- --user --backend local'
$cacInstalled = $false
$remoteInstallAllowed = $AllowRemoteScriptInstall

if (-not $remoteInstallAllowed) {
    Write-Warn 'Automatic CAC installation uses a remote shell script fetched from GitHub.'
    $remoteInstallAllowed = Confirm-Action -Prompt 'Allow automatic remote CAC installer execution via WSL or Git Bash?'
}

if ($remoteInstallAllowed) {
    Write-Host '  Checking for WSL Ubuntu/Debian...' -ForegroundColor Gray
    try {
        $wslList = (wsl -l -v 2>&1) -replace "`0", ''
        $linuxDistros = $wslList | Where-Object {
            $_ -match '(Ubuntu|Debian)' -and $_ -notmatch '[Dd]ocker'
        }

        if ($linuxDistros) {
            $preferUbuntu = $linuxDistros | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1
            $distroLine = if ($preferUbuntu) { $preferUbuntu } else { $linuxDistros | Select-Object -First 1 }
            $distroName = ($distroLine -replace '^\s*\*?\s*', '') -split '\s+' | Select-Object -First 1

            Write-Host "  Found WSL distro: $distroName" -ForegroundColor Gray
            Write-Host "  Running CAC installer inside WSL ($distroName)..." -ForegroundColor Gray
            try {
                wsl -d "$distroName" bash -c $cacInstallCmd
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "CAC installed via WSL ($distroName)"
                    $cacInstalled = $true
                } else {
                    Write-Warn "WSL CAC installer exited with code $LASTEXITCODE — trying fallback"
                }
            } catch {
                Write-Warn "WSL install attempt failed: $_ — trying fallback"
            }
        } else {
            Write-Warn 'No Ubuntu/Debian WSL distro found'
        }
    } catch {
        Write-Warn "Could not query WSL distros: $_"
    }
} else {
    Write-Warn 'Skipping automatic WSL-based CAC install because remote script execution was not approved.'
}

if (-not $cacInstalled -and $remoteInstallAllowed) {
    $gitBash = $null
    $gitBashCandidates = @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($gitExe) {
        $inferredBash = Join-Path (Split-Path (Split-Path $gitExe.Source)) 'bin\bash.exe'
        $gitBashCandidates = @($inferredBash) + $gitBashCandidates
    }
    foreach ($candidate in $gitBashCandidates) {
        if (Test-Path $candidate) {
            $gitBash = $candidate
            break
        }
    }

    Write-Host '  Checking for Git Bash...' -ForegroundColor Gray
    if ($gitBash) {
        Write-Host '  Running CAC installer via Git Bash...' -ForegroundColor Gray
        try {
            & $gitBash -c $cacInstallCmd
            if ($LASTEXITCODE -eq 0) {
                Write-Success 'CAC installed via Git Bash'
                $cacInstalled = $true
            } else {
                Write-Warn "Git Bash CAC installer exited with code $LASTEXITCODE"
            }
        } catch {
            Write-Warn "Git Bash install attempt failed: $_"
        }
    } else {
        Write-Warn 'Git Bash not found (checked common paths and git.exe location)'
    }
} elseif (-not $cacInstalled) {
    Write-Warn 'Skipping automatic Git Bash-based CAC install because remote script execution was not approved.'
}

if (-not $cacInstalled) {
    $cloneDest = 'C:\Learning\bpm-CodingAgentConfigCopy'
    Write-Warn 'Automatic CAC installation not possible — falling back to repo clone'
    Write-Host "  Cloning repository to: $cloneDest" -ForegroundColor Gray

    try {
        if (Test-Path $cloneDest) {
            Write-Warn "Directory already exists: $cloneDest — skipping clone"
        } else {
            git clone 'https://github.com/BPMspaceUG/bpm-CodingAgentConfigCopy.git' $cloneDest
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Repository cloned to $cloneDest"
            } else {
                Write-Fail "git clone failed (exit code $LASTEXITCODE)"
            }
        }
    } catch {
        Write-Fail "Clone failed: $_"
    }

    Write-Host ''
    Write-Host '  Manual CAC installation steps:' -ForegroundColor Yellow
    Write-Host '    1. Install WSL Ubuntu:   wsl --install -d Ubuntu' -ForegroundColor White
    Write-Host '    2. Open WSL bash:        wsl -d Ubuntu' -ForegroundColor White
    Write-Host '    3. Run the installer:    cd /mnt/c/Learning/bpm-CodingAgentConfigCopy && bash install.sh' -ForegroundColor White
}

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
Write-Host ' Setup Complete — Next Steps' -ForegroundColor Cyan
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. Open VS Code → Extensions sidebar → confirm AI extensions are listed'
Write-Host '  2. Open WSL Ubuntu:'
Write-Host '       wsl -d Ubuntu' -ForegroundColor White
Write-Host '  3. Inside WSL, run CAC to install AI CLIs:'
Write-Host '       cac env install' -ForegroundColor White
Write-Host '  4. Verify CAC version:'
Write-Host '       cac --version' -ForegroundColor White
Write-Host ''
