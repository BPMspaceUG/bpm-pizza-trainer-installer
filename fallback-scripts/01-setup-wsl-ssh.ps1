#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Script 1: Install WSL2 + Ubuntu and configure OpenSSH Server.
.DESCRIPTION
    Enables WSL2 Windows features, installs Ubuntu LTS, installs and starts
    OpenSSH Server, and opens firewall port 22. Requires a reboot if WSL
    features were not previously enabled.
.PARAMETER EnableLabWslDefaults
    Opt in to lab-style WSL user changes: empty password and passwordless sudo.
.PARAMETER OpenFirewall
    Open inbound Windows firewall port 22 for sshd without prompting.
.NOTES
    Run as Administrator. Reboot when prompted, then re-run to finalize.
#>

param(
    [switch]$EnableLabWslDefaults,
    [switch]$OpenFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$rebootRequired = $false
$wslLabDefaultsApplied = $false
$firewallOpened = $false

# ─────────────────────────────────────────────────────────────
# A — Enable WSL2 + Install Ubuntu
# ─────────────────────────────────────────────────────────────

Write-Step "Enabling Windows Subsystem for Linux feature"
try {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
    if ($wslFeature.State -eq 'Enabled') {
        Write-Success "WSL feature already enabled"
    } else {
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "WSL feature enabled (reboot required)"
            $rebootRequired = $true
        } else {
            Write-Fail "Failed to enable WSL feature (exit code $LASTEXITCODE)"
        }
    }
} catch {
    Write-Fail "Error enabling WSL feature: $_"
}

Write-Step "Enabling Virtual Machine Platform feature"
try {
    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($vmpFeature.State -eq 'Enabled') {
        Write-Success "Virtual Machine Platform already enabled"
    } else {
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Virtual Machine Platform enabled (reboot required)"
            $rebootRequired = $true
        } else {
            Write-Fail "Failed to enable Virtual Machine Platform (exit code $LASTEXITCODE)"
        }
    }
} catch {
    Write-Fail "Error enabling Virtual Machine Platform: $_"
}

if ($rebootRequired) {
    Write-Host "`n[!] WSL features were just enabled. A REBOOT IS REQUIRED before continuing." -ForegroundColor Yellow
    Write-Host "    Please reboot and re-run this script to install Ubuntu and finalize setup." -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "Reboot now? [Y/N]"
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    }
    exit 0
}

Write-Step "Setting WSL default version to 2"
try {
    wsl --set-default-version 2 | Out-Null
    Write-Success "WSL default version set to 2"
} catch {
    Write-Warn "Could not set WSL default version (may already be set or WSL not ready): $_"
}

Write-Step "Installing Ubuntu (latest LTS) via WSL"
try {
    # Check if Ubuntu is already installed
    $installedDistros = (wsl -l 2>&1) -replace "`0", ""
    if ($installedDistros -match 'Ubuntu') {
        Write-Success "Ubuntu distro already installed in WSL"
    } else {
        Write-Host "  Installing Ubuntu — this may take several minutes..." -ForegroundColor Gray
        wsl --install -d Ubuntu --no-launch
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Ubuntu installed successfully"
        } else {
            Write-Warn "wsl --install returned exit code $LASTEXITCODE — Ubuntu may still be downloading in background"
        }
    }
} catch {
    Write-Fail "Error installing Ubuntu: $_"
}

# ─────────────────────────────────────────────────────────────
# B — Configure WSL Ubuntu user (empty password + passwordless sudo)
# ─────────────────────────────────────────────────────────────

if ($EnableLabWslDefaults -or (Confirm-Action -Prompt 'Apply lab-style WSL defaults (empty password + passwordless sudo)?')) {
    Write-Step "Configuring WSL Ubuntu user with lab defaults"
    try {
        $bashScript = @'
#!/bin/bash
set -e
DEFAULT_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd 2>/dev/null)
if [ -z "$DEFAULT_USER" ]; then
    useradd -m -s /bin/bash ubuntu
    DEFAULT_USER=ubuntu
    echo "  Created user: $DEFAULT_USER"
fi
passwd -d "$DEFAULT_USER"
usermod -aG sudo "$DEFAULT_USER" 2>/dev/null || true
cat > /etc/sudoers.d/90-training-nopasswd <<EOF
$DEFAULT_USER ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/90-training-nopasswd
if command -v visudo >/dev/null 2>&1; then
    visudo -cf /etc/sudoers.d/90-training-nopasswd >/dev/null
fi
if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
    export DEFAULT_USER
    python3 - <<'PY'
import os
from pathlib import Path

default_user = os.environ['DEFAULT_USER']
path = Path('/etc/wsl.conf')
text = path.read_text(encoding='utf-8') if path.exists() else ''
lines = text.splitlines()
out = []
in_user = False
default_written = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        if in_user and not default_written:
            out.append(f'default = {default_user}')
        in_user = stripped == '[user]'
        default_written = False if in_user else default_written
        out.append(line)
        continue
    if in_user and stripped.startswith('default'):
        out.append(f'default = {default_user}')
        default_written = True
    else:
        out.append(line)
if '[user]' not in [line.strip() for line in lines]:
    if out and out[-1] != '':
        out.append('')
    out.extend(['[user]', f'default = {default_user}'])
elif in_user and not default_written:
    out.append(f'default = {default_user}')
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
else
    printf '[user]\ndefault = %s\n' "$DEFAULT_USER" > /etc/wsl.conf
fi
echo "Configured: $DEFAULT_USER (empty password, NOPASSWD sudo)"
'@

        $tmpFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.sh')
        [System.IO.File]::WriteAllText($tmpFile, $bashScript, [System.Text.Encoding]::UTF8)

        $winPath = $tmpFile -replace '\\', '/'
        $wslPath = (wsl -d Ubuntu -u root -- wslpath -a $winPath 2>&1)

        wsl -d Ubuntu -u root -- bash "$wslPath"
        if ($LASTEXITCODE -eq 0) {
            Write-Success "WSL Ubuntu user configured: empty password + NOPASSWD sudo"
            $wslLabDefaultsApplied = $true
        } else {
            Write-Warn "WSL user config returned exit code $LASTEXITCODE — check output above"
        }

        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "Could not auto-configure WSL user: $_"
        Write-Host "  Manual fix: create /etc/sudoers.d/90-training-nopasswd inside Ubuntu and validate it with visudo before use." -ForegroundColor Gray
    }
} else {
    Write-Warn 'Skipping lab-style WSL defaults. The Ubuntu user will keep standard authentication behavior.'
}

# ─────────────────────────────────────────────────────────────
# C — Install & Configure OpenSSH Server
# ─────────────────────────────────────────────────────────────

Write-Step "Installing OpenSSH Server Windows capability"
try {
    $sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($sshCapability.State -eq 'Installed') {
        Write-Success "OpenSSH Server already installed"
    } else {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
        Write-Success "OpenSSH Server installed"
    }
} catch {
    Write-Fail "Error installing OpenSSH Server: $_"
}

Write-Step "Configuring sshd service (Automatic startup)"
try {
    Set-Service -Name sshd -StartupType Automatic
    Write-Success "sshd startup type set to Automatic"
} catch {
    Write-Fail "Error setting sshd startup type: $_"
}

Write-Step "Starting sshd service"
try {
    $sshdStatus = (Get-Service -Name sshd).Status
    if ($sshdStatus -eq 'Running') {
        Write-Success "sshd is already running"
    } else {
        Start-Service sshd
        Write-Success "sshd started"
    }
    $sshdStatus = (Get-Service -Name sshd).Status
    Write-Host "  Service status: $sshdStatus" -ForegroundColor Gray
} catch {
    Write-Fail "Error starting sshd: $_"
}

Write-Step "Configuring Windows Firewall rule for OpenSSH (port 22)"
try {
    $existingRule = Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue
    if ($existingRule) {
        Write-Success "Firewall rule 'sshd' already exists"
        $firewallOpened = $true
    } elseif ($OpenFirewall -or (Confirm-Action -Prompt 'Open inbound Windows Firewall port 22 for sshd?')) {
        New-NetFirewallRule `
            -Name 'sshd' `
            -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -Profile Private `
            -LocalPort 22 | Out-Null
        Write-Success "Firewall rule created — port 22 open for inbound TCP on the Private profile"
        $firewallOpened = $true
    } else {
        Write-Warn 'Skipping firewall rule creation. sshd may still be usable locally, but inbound remote connections will remain blocked.'
    }
} catch {
    Write-Fail "Error creating firewall rule: $_"
}

# ─────────────────────────────────────────────────────────────
# D — Set Windows Terminal default profile to PowerShell 7 (pwsh)
# ─────────────────────────────────────────────────────────────

Write-Step "Setting Windows Terminal default profile to PowerShell 7 (pwsh)"
try {
    $wtSettingsPaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )

    $wtSettings = $null
    $wtSettingsPath = $null
    foreach ($path in $wtSettingsPaths) {
        if (Test-Path $path) {
            $wtSettings = Get-Content $path -Raw | ConvertFrom-Json
            $wtSettingsPath = $path
            break
        }
    }

    if (-not $wtSettings) {
        Write-Warn "Windows Terminal settings.json not found — skipping (open Windows Terminal once first)"
    } else {
        $pwshProfile = $wtSettings.profiles.list | Where-Object {
            $_.commandline -match 'pwsh' -or $_.source -match 'PowerShell'
        } | Select-Object -First 1

        if (-not $pwshProfile) {
            Write-Warn "No pwsh profile found in Windows Terminal — is PowerShell 7 installed?"
        } elseif ($wtSettings.defaultProfile -eq $pwshProfile.guid) {
            Write-Success "Windows Terminal already defaults to pwsh ($($pwshProfile.guid))"
        } else {
            $wtSettings.defaultProfile = $pwshProfile.guid
            # Back up settings before writing (ConvertFrom-Json strips JSONC comments)
            Copy-Item $wtSettingsPath "$wtSettingsPath.bak" -Force
            $wtSettings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
            Write-Success "Default profile set to '$($pwshProfile.name)' ($($pwshProfile.guid))"
            Write-Host "  [NOTE] Original settings backed up to: $wtSettingsPath.bak" -ForegroundColor Gray
        }
    }
} catch {
    Write-Warn "Could not configure Windows Terminal default profile: $_"
}

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Setup Complete — Summary" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

if ($wslLabDefaultsApplied) {
    Write-Host "`nWSL auth mode: lab defaults applied (empty password + passwordless sudo)" -ForegroundColor Yellow
} else {
    Write-Host "`nWSL auth mode: standard authentication retained" -ForegroundColor White
}

if ($firewallOpened) {
    Write-Host 'Windows firewall: inbound sshd rule present' -ForegroundColor White
} else {
    Write-Host 'Windows firewall: inbound sshd rule not created by this run' -ForegroundColor White
}

try {
    $wslDistros = (wsl -l -v 2>&1) -replace "`0", ""
    Write-Host "`nWSL Distros:" -ForegroundColor White
    Write-Host $wslDistros
} catch {
    Write-Warn "Could not list WSL distros"
}

try {
    $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    Write-Host "`nOpenSSH Server (sshd): $($sshdSvc.Status)" -ForegroundColor White
} catch {
    Write-Warn "Could not query sshd service"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open WSL:    wsl -d Ubuntu"
Write-Host "  2. Test SSH:    ssh localhost"
Write-Host "  3. If you opened port 22, prefer SSH keys before using remote access"
Write-Host "  4. Run Script2: .\02-setup-coding-agents.ps1  (VS Code AI extensions)"
Write-Host "  5. Run Script2b: .\02b-setup-cac.ps1          (CAC CLI)"
Write-Host ""
