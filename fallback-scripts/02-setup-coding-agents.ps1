#Requires -Version 5.1
<#
.SYNOPSIS
    Script 2: Install VS Code AI extensions.
.DESCRIPTION
    Installs a curated set of VS Code extensions for AI-assisted coding.

    CAC (CodingAgentConfigCopy) installation lives in 02b-setup-cac.ps1 so it can
    be run independently of the extension set.
.NOTES
    Run as a normal user AFTER Script 1 (01-setup-wsl-ssh.ps1) and a reboot.
#>

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

# ─────────────────────────────────────────────────────────────
# VS Code Extensions
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

# ──────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
Write-Host ' VS Code Extensions Complete — Next Steps' -ForegroundColor Cyan
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. Open VS Code → Extensions sidebar → confirm AI extensions are listed'
Write-Host '  2. Install the CAC CLI (separate script):'
Write-Host '       .\02b-setup-cac.ps1' -ForegroundColor White
Write-Host ''
