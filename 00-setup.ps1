#Requires -Version 5.1
<#
.SYNOPSIS
    Master setup script for the Pizza Trainer environment (Windows).
.DESCRIPTION
    Launches a WinForms GUI (default) or interactive terminal menu (-NoGui).
    Checks / installs packages via winget, clones exercise repos, and runs
    the full environment setup sequence. Compatible with PowerShell 5.1+.
.PARAMETER NoGui
    Force terminal menu mode (useful over SSH or in headless environments).
.NOTES
    Administrator rights needed only for 01-setup-wsl-ssh.ps1.
    All other operations run as a normal user.
#>
param(
    [switch]$NoGui,
    [switch]$SkipPreflight,
    [ValidateSet('packages-status', 'packages-install', 'repos-status', 'repos-sync', 'repos-cleanup', 'full-setup')]
    [string]$Action,
    [switch]$RemoveModules,
    [switch]$GitClean,
    [switch]$Reinstall,
    [switch]$RemovePythonEnv,
    [switch]$RemoveRepos,
    [switch]$DryRun,
    [string]$PizzaRepoUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Execution policy warning ─────────────────────────────────
try {
    $_policy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction Stop
    if ($_policy -eq 'Restricted' -or $_policy -eq 'AllSigned') {
        $msg = @"
WARNING: PowerShell script execution is blocked (policy: $_policy).

You should launch this tool using launch.bat (double-click it), NOT by running the .ps1 directly.

To fix manually, run this in PowerShell:
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

The script will attempt to continue anyway via the current process bypass, but some child scripts may fail.
"@
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show(
                $msg,
                'Script Execution Policy Warning',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } catch {
            Write-Warning $msg
        }
    }
} catch {
    Write-Verbose 'Skipping execution policy warning because Get-ExecutionPolicy is unavailable in this host.'
}

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PackagesJson = Join-Path $ScriptDir 'packages.winget.json'
$LearningDir  = Join-Path $HOME 'Learning'
$PreflightPs1 = Join-Path $ScriptDir '00-preflight.ps1'

$Repos = @(
    @{ Url = 'https://github.com/BPMspaceUG/bpm-CodingAgentConfigCopy'; Dir = "$LearningDir\bpm-CodingAgentConfigCopy"; RunInstallSh = $true;  SetupScript = '';                              PromptUrl = $false },
    @{ Url = 'https://github.com/BPMspaceUG/bpm-pizza-ml';                Dir = "$LearningDir\pizza-ml";                  RunInstallSh = $false; SetupScript = '03-setup-pizza-ml-trainer.ps1'; PromptUrl = $false }
)

# Script-scoped GUI delegates — set by Start-GuiMode so Sync-Repos can show dialogs
$script:GuiPromptUrl      = $null   # scriptblock(repoName) -> url string
$script:GuiRunSetupScript = $null   # scriptblock(scriptPath) -> void

# ─────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────
$script:GuiLog = $null   # set to TextBox when GUI is active
$script:RunFailures = New-Object System.Collections.Generic.List[string]
$script:LastChildExitCode = 0

function Write-Step  { param([string]$M); Write-Host "`n==> $M" -ForegroundColor Cyan;   if ($script:GuiLog) { $script:GuiLog.AppendText("`r`n==> $M`r`n"); [System.Windows.Forms.Application]::DoEvents() } }
function Write-Ok    { param([string]$M); Write-Host "  [OK]   $M" -ForegroundColor Green;  if ($script:GuiLog) { $script:GuiLog.AppendText("  [OK]   $M`r`n"); [System.Windows.Forms.Application]::DoEvents() } }
function Write-Warn  { param([string]$M); Write-Host "  [WARN] $M" -ForegroundColor Yellow; if ($script:GuiLog) { $script:GuiLog.AppendText("  [WARN] $M`r`n"); [System.Windows.Forms.Application]::DoEvents() } }
function Write-Fail  { param([string]$M); Write-Host "  [FAIL] $M" -ForegroundColor Red;    if ($script:GuiLog) { $script:GuiLog.AppendText("  [FAIL] $M`r`n"); [System.Windows.Forms.Application]::DoEvents() } }
function Write-Info  { param([string]$M); Write-Host "  [INFO] $M" -ForegroundColor Gray;   if ($script:GuiLog) { $script:GuiLog.AppendText("  [INFO] $M`r`n"); [System.Windows.Forms.Application]::DoEvents() } }

function Reset-RunFailures {
    $script:RunFailures.Clear()
}

function Add-RunFailure {
    param([string]$Message)
    $script:RunFailures.Add($Message)
    Write-Warn $Message
}

function Show-RunSummary {
    param([string]$Label = 'Operation')

    if ($script:RunFailures.Count -eq 0) {
        Write-Ok "$Label completed without recorded failures."
        return $true
    }

    Write-Warn "$Label completed with $($script:RunFailures.Count) recorded issue(s)."
    foreach ($failure in $script:RunFailures) {
        Write-Host "    - $failure" -ForegroundColor Yellow
        if ($script:GuiLog) {
            $script:GuiLog.AppendText("    - $failure`r`n")
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    return $false
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SetupPreflight {
    if ($SkipPreflight) {
        Write-Host '  Skipping preflight checks.' -ForegroundColor Yellow
        return $true
    }

    if (-not (Test-Path $PreflightPs1)) {
        Write-Warn "Preflight script not found at: $PreflightPs1"
        return $true
    }

    Write-Host ''
    Write-Host '  Running preflight checks...' -ForegroundColor Gray
    & $PreflightPs1 -NoPrompt
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    Write-Host ''
    Write-Host '  Preflight reported blocking issues.' -ForegroundColor Yellow
    $answer = Read-Host '  Continue into setup anyway? [y/N]'
    return ($answer -match '^[Yy]')
}

function Read-PackageIds {
    if (-not (Test-Path $PackagesJson)) { Write-Fail "packages.winget.json not found at: $PackagesJson"; return @() }
    $json = Get-Content $PackagesJson -Raw | ConvertFrom-Json
    $ids  = @()
    foreach ($src in $json.Sources) { foreach ($pkg in $src.Packages) { $ids += $pkg.PackageIdentifier } }
    return $ids
}

function Test-WingetInstalled {
    param([string]$Id)
    $out = winget list --id $Id --exact 2>&1
    return ($LASTEXITCODE -eq 0 -and ($out -match [regex]::Escape($Id)))
}

function Get-NodePackageManager {
    param([string]$Dir)
    if (Test-Path (Join-Path $Dir 'pnpm-lock.yaml'))   { return 'pnpm' }
    if (Test-Path (Join-Path $Dir 'yarn.lock'))         { return 'yarn' }
    if (Test-Path (Join-Path $Dir 'package-lock.json')) { return 'npm'  }
    if (Test-Path (Join-Path $Dir 'package.json'))      { return 'npm'  }
    return $null
}

function Ensure-GitBashZip {
    if (Get-Command zip -ErrorAction SilentlyContinue) {
        return $true
    }

    $zipDirectories = @(
        'C:\Program Files (x86)\GnuWin32\bin',
        'C:\Program Files\GnuWin32\bin',
        'C:\Program Files\Git\usr\bin'
    )

    foreach ($directory in $zipDirectories) {
        $zipExe = Join-Path $directory 'zip.exe'
        if (Test-Path $zipExe) {
            if (-not (($env:PATH -split ';') -contains $directory)) {
                $env:PATH = "$directory;$env:PATH"
            }
            return $true
        }
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn 'zip is not available and winget is not installed, so Git Bash fallback cannot self-heal.'
        return $false
    }

    Write-Info 'zip not found - installing GnuWin32.Zip for Git Bash fallback...'
    winget install --id GnuWin32.Zip --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Failed to install GnuWin32.Zip automatically.'
        return $false
    }

    foreach ($directory in $zipDirectories) {
        $zipExe = Join-Path $directory 'zip.exe'
        if (Test-Path $zipExe) {
            if (-not (($env:PATH -split ';') -contains $directory)) {
                $env:PATH = "$directory;$env:PATH"
            }
            return $true
        }
    }

    return [bool](Get-Command zip -ErrorAction SilentlyContinue)
}

function Invoke-ShellInstall {
    # Runs install.sh from a repo dir via WSL (preferred) or Git Bash (fallback).
    param([string]$RepoDir)
    $installSh = Join-Path $RepoDir 'install.sh'
    if (-not (Test-Path $installSh)) { Write-Warn "install.sh not found in $RepoDir"; return $false }

    $normalizedRepoDir = [System.IO.Path]::GetFullPath($RepoDir)
    if ($normalizedRepoDir -notmatch '^[A-Za-z]:') {
        Write-Warn "install.sh auto-run expects a Windows drive path. Got: $normalizedRepoDir"
        return $false
    }

    $driveLetter = $normalizedRepoDir.Substring(0, 1).ToLowerInvariant()
    $pathTail = ($normalizedRepoDir.Substring(2) -replace '\\', '/')
    $wslPath = "/mnt/$driveLetter$pathTail"
    $tempInstall = Join-Path $RepoDir '.mitsm-install.tmp.sh'
    $repoName = Split-Path $normalizedRepoDir -Leaf
    $installArgs = ''
    if ($repoName -eq 'bpm-CodingAgentConfigCopy') {
        $installArgs = '--user --backend local'
        Write-Info 'Using unattended CAC installer defaults: --user --backend local'
    }

    try {
        $installContent = [System.IO.File]::ReadAllText($installSh)
        $normalizedContent = $installContent -replace "`r`n", "`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempInstall, $normalizedContent, $utf8NoBom)

        $tempPathTail = ($tempInstall.Substring(2) -replace '\\', '/')
        $wslTempPath = "/mnt/$driveLetter$tempPathTail"
        $gitBashTempPath = "/$driveLetter$tempPathTail"
        $cmd = if ([string]::IsNullOrWhiteSpace($installArgs)) {
            "cd '$wslPath'; bash '$wslTempPath' </dev/null"
        } else {
            "cd '$wslPath'; bash '$wslTempPath' $installArgs </dev/null"
        }

        # Try WSL first
        $wslDistro = $null
        try {
            $wslList = (wsl -l -v 2>&1) -replace "`0", ""
            $wslDistro = ($wslList | Where-Object { $_ -match '(Ubuntu|Debian)' -and $_ -notmatch '[Dd]ocker' } | Select-Object -First 1)
            if ($wslDistro) {
                $wslDistro = ($wslDistro -replace '^\s*\*?\s*', '') -split '\s+' | Select-Object -First 1
            }
        } catch {}

        if ($wslDistro) {
            Write-Info "Running install.sh via WSL ($wslDistro)..."
            wsl -d $wslDistro bash -c $cmd
            if ($LASTEXITCODE -eq 0) { Write-Ok "install.sh completed via WSL."; return $true }
            Write-Warn "WSL run failed - trying Git Bash..."
        }

        # Try Git Bash
        $gitBash = $null
        $candidates = @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')
        $gitExe = Get-Command git -ErrorAction SilentlyContinue
        if ($gitExe) { $candidates = @((Join-Path (Split-Path (Split-Path $gitExe.Source)) 'bin\bash.exe')) + $candidates }
        foreach ($c in $candidates) { if (Test-Path $c) { $gitBash = $c; break } }

        if ($gitBash) {
            if (-not (Get-Command zip -ErrorAction SilentlyContinue)) {
                [void](Ensure-GitBashZip)
            }
            Write-Info "Running install.sh via Git Bash..."
            $posixPath = "/$driveLetter$pathTail"
            $gitBashCmd = if ([string]::IsNullOrWhiteSpace($installArgs)) {
                "cd '$posixPath'; bash '$gitBashTempPath' </dev/null"
            } else {
                "cd '$posixPath'; bash '$gitBashTempPath' $installArgs </dev/null"
            }
            & $gitBash -c $gitBashCmd
            if ($LASTEXITCODE -eq 0) { Write-Ok "install.sh completed via Git Bash."; return $true }
        }

        Write-Warn "Could not run install.sh automatically."
        if ([string]::IsNullOrWhiteSpace($installArgs)) {
            Write-Info ("To run manually: open WSL or Git Bash and run: cd '{0}'; bash install.sh" -f $RepoDir)
        } else {
            Write-Info ("To run manually: open WSL or Git Bash and run: cd '{0}'; bash install.sh {1}" -f $RepoDir, $installArgs)
        }
        return $false
    } finally {
        if (Test-Path $tempInstall) {
            Remove-Item $tempInstall -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PizzaMlVenv {
    param([string]$ProjectDir)
    $results = [ordered]@{}

    $venvPy = Join-Path $ProjectDir 'venv\Scripts\python.exe'
    $results['venv exists']        = Test-Path (Join-Path $ProjectDir 'venv')
    $results['venv python.exe']    = Test-Path $venvPy
    $results['data/v1 exists']     = Test-Path (Join-Path $ProjectDir 'data\v1')
    $results['data/v2 exists']     = Test-Path (Join-Path $ProjectDir 'data\v2')

    if (Test-Path $venvPy) {
        $pyVer = & $venvPy --version 2>&1
        $results["Python version ($pyVer)"] = ($pyVer -match 'Python 3\.(1[0-9]|[2-9]\d)')

        $torchCheck = & $venvPy -c "import torch; print(torch.__version__)" 2>&1
        $results["PyTorch importable ($torchCheck)"] = ($LASTEXITCODE -eq 0)
    } else {
        $results['Python version']  = $false
        $results['PyTorch importable'] = $false
    }

    Write-Host ""
    Write-Host "  Pizza-ML venv verification:" -ForegroundColor White
    $allOk = $true
    foreach ($label in $results.Keys) {
        $ok = $results[$label]
        if ($ok) {
            Write-Host ("  [x] {0}" -f $label) -ForegroundColor Green
        } else {
            Write-Host ("  [ ] {0}" -f $label) -ForegroundColor Yellow
            $allOk = $false
        }
        if ($script:GuiLog) {
            $mark = if ($ok) { '[x]' } else { '[ ]' }
            $script:GuiLog.AppendText("  $mark $label`r`n")
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    if ($allOk) { Write-Ok "Pizza-ML venv is ready." } else { Write-Warn "Some venv checks failed - re-run script 03 or check output above." }
    return $allOk
}

function Ensure-Pnpm {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) { return }
    Write-Info "pnpm not found - installing via npm..."
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        npm install -g pnpm
        if ($LASTEXITCODE -eq 0) { Write-Ok "pnpm installed." } else { Write-Warn "npm install -g pnpm failed." }
    } else { Write-Warn "npm not found - install Node.js first." }
}

# Returns array of hashtables: @{ Id; Type('winget'|'npm'); NpmPkg; Installed; Skip; SkipReason }
function Get-PackageStatus {
    $wingetIds = Read-PackageIds
    $result    = @()
    foreach ($id in $wingetIds) {
        $installed = Test-WingetInstalled -Id $id
        $result += @{ Id = $id; Type = 'winget'; NpmPkg = ''; Installed = $installed; Skip = $false; SkipReason = '' }
    }
    # pnpm as a special npm-global entry
    $pnpmInstalled = [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
    $result += @{ Id = 'pnpm (npm global)'; Type = 'npm'; NpmPkg = 'pnpm'; Installed = $pnpmInstalled; Skip = $false; SkipReason = '' }
    return $result
}

function Install-Packages {
    param([string[]]$Ids, [object[]]$StatusMap)
    foreach ($id in $Ids) {
        $entry = $StatusMap | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $entry) { continue }
        if ($entry.Type -eq 'npm') {
            Write-Step "Installing pnpm (npm install -g pnpm)"
            npm install -g pnpm
            if ($LASTEXITCODE -eq 0) { Write-Ok "pnpm installed." } else { Add-RunFailure 'pnpm install failed.' }
        } else {
            Write-Step "Installing $id"
            winget install --id $id --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) { Write-Ok "$id installed." } else { Add-RunFailure "$id - winget exit code $LASTEXITCODE" }
        }
    }
}

function Sync-Repos {
    param(
        [object[]]$RepoList,
        [switch]$NonInteractive,
        [switch]$DryRun
    )
    if (-not (Test-Path $LearningDir)) { New-Item -ItemType Directory -Path $LearningDir -Force | Out-Null }
    foreach ($repo in $RepoList) {
        $name = Split-Path $repo.Dir -Leaf
        Write-Host ""
        Write-Host "  $name" -ForegroundColor White
        if ($script:GuiLog) { $script:GuiLog.AppendText("`r`n  $name`r`n"); [System.Windows.Forms.Application]::DoEvents() }

        # Resolve URL - may need to prompt for pizza-ml
        $url = $repo.Url
        if ([string]::IsNullOrEmpty($url) -and -not (Test-Path (Join-Path $repo.Dir '.git'))) {
            if ($repo.PromptUrl) {
                if ($PizzaRepoUrl) {
                    $url = $PizzaRepoUrl
                } elseif ($script:GuiPromptUrl) {
                    $url = & $script:GuiPromptUrl $name
                } elseif ($NonInteractive) {
                    Write-Warn "$name has no URL and action mode is non-interactive - skipping"
                    continue
                } else {
                    $url = (Read-Host "  Enter Git URL for $name (or press Enter to skip)").Trim()
                }
                if ([string]::IsNullOrEmpty($url)) {
                    Write-Warn "$name has no URL and directory does not exist - skipping"
                    continue
                }
            } else {
                Write-Warn "$name has no URL configured - skipping"
                continue
            }
        }

        Write-Host "  $url" -ForegroundColor DarkGray
        if ($script:GuiLog) { $script:GuiLog.AppendText("  $url`r`n"); [System.Windows.Forms.Application]::DoEvents() }

        if (Test-Path (Join-Path $repo.Dir '.git')) {
            if ($DryRun) {
                Write-Info "[dry-run] Would pull latest changes..."
            } else {
                Write-Info "Pulling..."
                git -C $repo.Dir pull
                if ($LASTEXITCODE -eq 0) { Write-Ok "Updated" } else { Add-RunFailure ("{0}: git pull failed" -f $name) }
            }
        } else {
            if ($DryRun) {
                Write-Info "[dry-run] Would clone repository..."
            } else {
                Write-Info "Cloning..."
                git clone $url $repo.Dir
                if ($LASTEXITCODE -ne 0) { Write-Fail "Clone failed - skipping install"; Add-RunFailure ("{0}: git clone failed" -f $name); continue }
                Write-Ok "Cloned to $($repo.Dir)"
            }
        }

        # Run install.sh if flagged (e.g. bpm-CodingAgentConfigCopy)
        if ($repo.RunInstallSh) {
            if ($DryRun) {
                Write-Info "[dry-run] Would run install.sh if present."
            } elseif (-not (Invoke-ShellInstall -RepoDir $repo.Dir)) {
                Add-RunFailure ("{0}: install.sh did not complete successfully" -f $name)
            }
        }

        # Run setup script if configured (e.g. 03-setup-pizza-ml-trainer.ps1 for pizza-ml)
        if (-not [string]::IsNullOrEmpty($repo.SetupScript)) {
            if ($NonInteractive) {
                if ($DryRun) {
                    Write-Info "[dry-run] Would skip $($repo.SetupScript) in non-interactive action mode. Use pizza-trainer trainer separately."
                } else {
                    Write-Info "Skipping $($repo.SetupScript) in non-interactive action mode. Use pizza-trainer trainer separately."
                }
                continue
            }
            $scriptPath = Join-Path $ScriptDir $repo.SetupScript
            if (Test-Path $scriptPath) {
                if ($script:GuiRunSetupScript) {
                    & $script:GuiRunSetupScript $scriptPath
                } else {
                    $r = Read-Host "  Run $($repo.SetupScript) for $name now? [Y/n]"
                    if ($r -notmatch '^[Nn]') {
                        Write-Info "Running $($repo.SetupScript)..."
                        & $scriptPath -RepoUrl $url
                        if ($LASTEXITCODE -ne 0) {
                            Add-RunFailure ("{0}: {1} exited with code {2}" -f $name, $repo.SetupScript, $LASTEXITCODE)
                        }
                    }
                }
                # Verify venv after setup script
                if (-not (Test-PizzaMlVenv -ProjectDir $repo.Dir)) {
                    Add-RunFailure ("{0}: post-setup verification failed" -f $name)
                }
            } else {
                Add-RunFailure ("{0}: {1} not found in {2}" -f $name, $repo.SetupScript, $ScriptDir)
            }
        }

        # Run JS package manager install if applicable
        $pm = Get-NodePackageManager -Dir $repo.Dir
        if ($pm) {
            if ($DryRun) {
                Write-Info "[dry-run] Would run $pm install..."
            } else {
                if ($pm -eq 'pnpm') { Ensure-Pnpm }
                $pmCmd = Get-Command $pm -ErrorAction SilentlyContinue
                if ($pmCmd) {
                    Write-Info "Running $pm install..."
                    Push-Location $repo.Dir
                    try { & $pm install; if ($LASTEXITCODE -eq 0) { Write-Ok "$pm install done" } else { Add-RunFailure ("{0}: {1} install failed" -f $name, $pm) } }
                    finally { Pop-Location }
                } else { Add-RunFailure ("{0}: {1} not found on PATH; run {1} install manually in {2}" -f $name, $pm, $repo.Dir) }
            }
        }
    }
}

function Invoke-CleanupRepos {
    param(
        [object[]]$RepoList,
        [switch]$RemoveModules,
        [switch]$GitClean,
        [switch]$Reinstall,
        [switch]$RemovePythonEnv,   # removes venv/, generated data, and *.pth files (pizza-ml)
        [switch]$RemoveRepos,
        [switch]$DryRun
    )
    Write-Step "Cleaning up repositories"
    foreach ($repo in $RepoList) {
        $name = Split-Path $repo.Dir -Leaf
        if (-not (Test-Path $repo.Dir)) { Write-Warn "$name not found - skipping"; continue }
        Write-Info "$name"

        if ($RemoveRepos) {
            if ($DryRun) {
                Write-Info "  [dry-run] Would remove cloned repository directory..."
            } else {
                Write-Info "  Removing cloned repository directory..."
                try {
                    Remove-Item $repo.Dir -Recurse -Force -ErrorAction Stop
                    Write-Ok "  repository removed"
                } catch {
                    Add-RunFailure "${name}: failed to remove repository directory: $_"
                }
            }
            continue
        }

        if ($RemoveModules) {
            $nm = Join-Path $repo.Dir 'node_modules'
            if (Test-Path $nm) {
                if ($DryRun) {
                    Write-Info "  [dry-run] Would remove node_modules..."
                } else {
                    Write-Info "  Removing node_modules..."
                    try {
                        Remove-Item $nm -Recurse -Force -ErrorAction Stop
                        Write-Ok "  node_modules removed"
                    } catch {
                        Add-RunFailure "${name}: failed to remove node_modules: $_"
                    }
                }
            } else { Write-Info "  node_modules not present" }
        }

        if ($RemovePythonEnv) {
            # venv
            $venvDir = Join-Path $repo.Dir 'venv'
            if (Test-Path $venvDir) {
                if ($DryRun) {
                    Write-Info "  [dry-run] Would remove venv..."
                } else {
                    Write-Info "  Removing venv..."
                    try {
                        Remove-Item $venvDir -Recurse -Force -ErrorAction Stop
                        Write-Ok "  venv removed"
                    } catch {
                        Add-RunFailure "${name}: failed to remove venv: $_"
                    }
                }
            }

            # data/
            $dataDir = Join-Path $repo.Dir 'data'
            if (Test-Path $dataDir) {
                $trackedDataFiles = @()
                if (Test-Path (Join-Path $repo.Dir '.git')) {
                    $trackedDataFiles = @(git -C $repo.Dir ls-files -- data 2>$null)
                }
                $rawDataDir = Join-Path $dataDir '_food101_raw'

                if ($trackedDataFiles.Count -gt 0) {
                    if (Test-Path $rawDataDir) {
                        if ($DryRun) {
                            Write-Info "  [dry-run] Would remove data/_food101_raw..."
                        } else {
                            Write-Info "  Removing data/_food101_raw..."
                            try {
                                Remove-Item $rawDataDir -Recurse -Force -ErrorAction Stop
                                Write-Ok "  data/_food101_raw removed"
                            } catch {
                                Add-RunFailure "${name}: failed to remove data/_food101_raw: $_"
                            }
                        }
                    }
                    Write-Info "  data/ contains tracked files - leaving repository data in place"
                } elseif ($DryRun) {
                    Write-Info "  [dry-run] Would remove data/..."
                } else {
                    Write-Info "  Removing data/..."
                    try {
                        Remove-Item $dataDir -Recurse -Force -ErrorAction Stop
                        Write-Ok "  data/ removed"
                    } catch {
                        Add-RunFailure "${name}: failed to remove data/: $_"
                    }
                }
            }
            # *.pth model files
            $pthFiles = @(Get-ChildItem $repo.Dir -Filter '*.pth' -File -ErrorAction SilentlyContinue)
            foreach ($f in $pthFiles) {
                if ($DryRun) {
                    Write-Info "  [dry-run] Would remove $($f.Name)"
                } else {
                    try {
                        Remove-Item $f.FullName -Force -ErrorAction Stop
                        Write-Ok "  Removed $($f.Name)"
                    } catch {
                        Add-RunFailure "${name}: failed to remove $($f.Name): $_"
                    }
                }
            }
            if ($pthFiles.Count -eq 0) { Write-Info "  No .pth files found" }
        }

        if ($GitClean) {
            if ($DryRun) {
                Write-Info "  [dry-run] Would run git clean -fd..."
            } else {
                Write-Info "  Running git clean -fd..."
                git -C $repo.Dir clean -fd
            }
        }

        if ($Reinstall) {
            $pm = Get-NodePackageManager -Dir $repo.Dir
            if ($pm) {
                if ($pm -eq 'pnpm') { Ensure-Pnpm }
                $pmCmd = Get-Command $pm -ErrorAction SilentlyContinue
                if ($pmCmd) {
                    if ($DryRun) {
                        Write-Info "  [dry-run] Would run $pm install..."
                    } else {
                        Write-Info "  Running $pm install..."
                        Push-Location $repo.Dir
                        try { & $pm install; if ($LASTEXITCODE -eq 0) { Write-Ok "  $pm install done" } else { Add-RunFailure "${name}: $pm install failed" } }
                        finally { Pop-Location }
                    }
                } else { Write-Warn "  $pm not found on PATH" }
            }
        }
    }
}

function Show-PackageStatusAction {
    Write-Step "Checking installed packages"
    $status = Get-PackageStatus
    Write-Host ""
    Write-Host ("  {0,-44} {1}" -f "Package ID", "Status") -ForegroundColor White
    Write-Host ("  {0,-44} {1}" -f "----------", "------") -ForegroundColor DarkGray
    foreach ($item in $status) {
        if ($item.Installed) {
            Write-Host ("  [OK]  {0,-42} installed" -f $item.Id) -ForegroundColor Green
        } else {
            Write-Host ("  [--]  {0,-42} MISSING" -f $item.Id) -ForegroundColor Yellow
        }
    }
    return $status
}

function Get-EffectiveRepos {
    $effective = @()
    foreach ($repo in $Repos) {
        $copy = @{}
        foreach ($key in $repo.Keys) {
            $copy[$key] = $repo[$key]
        }
        if ($PizzaRepoUrl -and $copy.PromptUrl -and [string]::IsNullOrEmpty($copy.Url)) {
            $copy.Url = $PizzaRepoUrl
        }
        $effective += $copy
    }
    return $effective
}

function Show-RepoStatusAction {
    param([object[]]$RepoList)

    Write-Step "Checking repositories"
    foreach ($repo in $RepoList) {
        $name = Split-Path $repo.Dir -Leaf
        $cloned = Test-Path (Join-Path $repo.Dir '.git')
        $status = if ($cloned) { 'Cloned' } else { 'Not cloned' }
        if ($cloned -and -not [string]::IsNullOrEmpty($repo.SetupScript)) {
            $venvPy = Join-Path $repo.Dir 'venv\Scripts\python.exe'
            if (Test-Path $venvPy) {
                & $venvPy -c "import torch" 2>$null | Out-Null
                $status = if ($LASTEXITCODE -eq 0) { 'Cloned | venv OK' } else { 'Cloned | venv no torch' }
            } else {
                $status = 'Cloned | venv missing'
            }
        }

        $color = if ($cloned) { 'Green' } else { 'Yellow' }
        Write-Host ("  [{0}] {1,-24} {2}" -f ($(if ($cloned) { 'OK' } else { '--' }), $name, $status)) -ForegroundColor $color
        Write-Host ("       {0}" -f $repo.Dir) -ForegroundColor DarkGray
    }
}

function Invoke-ActionMode {
    $repoList = Get-EffectiveRepos

    switch ($Action) {
        'packages-status' {
            Show-PackageStatusAction | Out-Null
            return 0
        }
        'packages-install' {
            Reset-RunFailures
            $status = Get-PackageStatus
            $toInstall = @($status | Where-Object { -not $_.Installed -and -not $_.Skip })
            if ($toInstall.Count -eq 0) {
                Write-Ok 'All packages already installed.'
            } else {
                Install-Packages -Ids ($toInstall | ForEach-Object { $_.Id }) -StatusMap $toInstall
            }
            if (Show-RunSummary -Label 'Package installation') { return 0 }
            return 2
        }
        'repos-status' {
            Show-RepoStatusAction -RepoList $repoList
            return 0
        }
        'repos-sync' {
            Reset-RunFailures
            Sync-Repos -RepoList $repoList -NonInteractive -DryRun:$DryRun
            if (Show-RunSummary -Label 'Repository sync') { return 0 }
            return 2
        }
        'repos-cleanup' {
            if (-not ($RemoveModules -or $GitClean -or $Reinstall -or $RemovePythonEnv -or $RemoveRepos)) {
                Write-Fail 'repos-cleanup requires at least one cleanup flag.'
                return 1
            }
            Reset-RunFailures
            Invoke-CleanupRepos -RepoList $repoList -RemoveModules:$RemoveModules -GitClean:$GitClean -Reinstall:$Reinstall -RemovePythonEnv:$RemovePythonEnv -RemoveRepos:$RemoveRepos -DryRun:$DryRun
            if (Show-RunSummary -Label 'Repository cleanup') { return 0 }
            return 2
        }
        'full-setup' {
            Reset-RunFailures
            $status = Get-PackageStatus
            $toInstall = @($status | Where-Object { -not $_.Installed -and -not $_.Skip })
            if ($toInstall.Count -gt 0 -and -not $DryRun) {
                Install-Packages -Ids ($toInstall | ForEach-Object { $_.Id }) -StatusMap $toInstall
            } elseif ($toInstall.Count -gt 0 -and $DryRun) {
                Write-Step 'Dry-run package installation'
                foreach ($entry in $toInstall) {
                    Write-Info "[dry-run] Would install $($entry.Id)"
                }
            } else {
                Write-Ok 'All packages already installed.'
            }
            Sync-Repos -RepoList $repoList -NonInteractive -DryRun:$DryRun
            if (Show-RunSummary -Label 'Full setup') { return 0 }
            return 2
        }
        default {
            Write-Fail "Unknown action: $Action"
            return 1
        }
    }
}

# ─────────────────────────────────────────────────────────────
# GUI Mode (WinForms)
# ─────────────────────────────────────────────────────────────
function Start-GuiMode {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $PAD  = 10
    $FW   = 720  # form client width
    $BTNW = 150; $BTNH = 28

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Pizza Trainer - Environment Setup'
    $form.ClientSize      = New-Object System.Drawing.Size($FW, 920)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    # ── Header ──────────────────────────────────────────────
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text      = 'Pizza Trainer - Environment Setup'
    $lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize  = $true
    $lblTitle.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $form.Controls.Add($lblTitle)

    # ── Packages GroupBox ────────────────────────────────────
    $grpPkg = New-Object System.Windows.Forms.GroupBox
    $grpPkg.Text     = 'Packages'
    $grpPkg.Location = New-Object System.Drawing.Point($PAD, 42)
    $grpPkg.Size     = New-Object System.Drawing.Size(($FW - $PAD*2), 310)
    $form.Controls.Add($grpPkg)

    $lvPkg = New-Object System.Windows.Forms.ListView
    $lvPkg.View          = [System.Windows.Forms.View]::Details
    $lvPkg.CheckBoxes    = $true
    $lvPkg.FullRowSelect = $true
    $lvPkg.GridLines     = $true
    $lvPkg.Location      = New-Object System.Drawing.Point(8, 20)
    $lvPkg.Size          = New-Object System.Drawing.Size(($grpPkg.Width - 18), 240)
    $lvPkg.Columns.Add('Package ID',    260) | Out-Null
    $lvPkg.Columns.Add('Status',        100) | Out-Null
    $lvPkg.Columns.Add('Notes',         ($grpPkg.Width - 18 - 260 - 100 - 5)) | Out-Null
    $grpPkg.Controls.Add($lvPkg)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text     = 'Refresh Status'
    $btnRefresh.Location = New-Object System.Drawing.Point(8, 268)
    $btnRefresh.Size     = New-Object System.Drawing.Size($BTNW, $BTNH)
    $grpPkg.Controls.Add($btnRefresh)

    $btnSelMissing = New-Object System.Windows.Forms.Button
    $btnSelMissing.Text     = 'Select All Missing'
    $btnSelMissing.Location = New-Object System.Drawing.Point(($BTNW + 14), 268)
    $btnSelMissing.Size     = New-Object System.Drawing.Size($BTNW, $BTNH)
    $grpPkg.Controls.Add($btnSelMissing)

    $btnInstSel = New-Object System.Windows.Forms.Button
    $btnInstSel.Text      = 'Install Selected'
    $btnInstSel.Location  = New-Object System.Drawing.Point(($BTNW*2 + 20), 268)
    $btnInstSel.Size      = New-Object System.Drawing.Size($BTNW, $BTNH)
    $btnInstSel.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnInstSel.ForeColor = [System.Drawing.Color]::White
    $btnInstSel.FlatStyle = 'Flat'
    $grpPkg.Controls.Add($btnInstSel)

    # ── Repos GroupBox ────────────────────────────────────────
    $grpRepo = New-Object System.Windows.Forms.GroupBox
    $grpRepo.Text     = 'Repositories'
    $grpRepo.Location = New-Object System.Drawing.Point($PAD, 362)
    $grpRepo.Size     = New-Object System.Drawing.Size(($FW - $PAD*2), 180)
    $form.Controls.Add($grpRepo)

    $lvRepo = New-Object System.Windows.Forms.ListView
    $lvRepo.View          = [System.Windows.Forms.View]::Details
    $lvRepo.CheckBoxes    = $true
    $lvRepo.FullRowSelect = $true
    $lvRepo.GridLines     = $true
    $lvRepo.Location      = New-Object System.Drawing.Point(8, 20)
    $lvRepo.Size          = New-Object System.Drawing.Size(($grpRepo.Width - 18), 110)
    $lvRepo.Columns.Add('Repository', 200) | Out-Null
    $lvRepo.Columns.Add('Status',     110) | Out-Null
    $lvRepo.Columns.Add('Local Path', ($grpRepo.Width - 18 - 200 - 110 - 5)) | Out-Null
    $grpRepo.Controls.Add($lvRepo)

    $btnClone = New-Object System.Windows.Forms.Button
    $btnClone.Text     = 'Clone/Update Selected'
    $btnClone.Location = New-Object System.Drawing.Point(8, 138)
    $btnClone.Size     = New-Object System.Drawing.Size($BTNW, $BTNH)
    $btnClone.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnClone.ForeColor = [System.Drawing.Color]::White
    $btnClone.FlatStyle = 'Flat'
    $grpRepo.Controls.Add($btnClone)

    $btnCleanup = New-Object System.Windows.Forms.Button
    $btnCleanup.Text     = 'Cleanup Repos'
    $btnCleanup.Location = New-Object System.Drawing.Point(($BTNW + 14), 138)
    $btnCleanup.Size     = New-Object System.Drawing.Size($BTNW, $BTNH)
    $grpRepo.Controls.Add($btnCleanup)

    # ── Action bar ───────────────────────────────────────────
    $btnFullSetup = New-Object System.Windows.Forms.Button
    $btnFullSetup.Text      = 'Run Full Setup'
    $btnFullSetup.Location  = New-Object System.Drawing.Point($PAD, 552)
    $btnFullSetup.Size      = New-Object System.Drawing.Size($BTNW, 32)
    $btnFullSetup.BackColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
    $btnFullSetup.ForeColor = [System.Drawing.Color]::White
    $btnFullSetup.FlatStyle = 'Flat'
    $btnFullSetup.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnFullSetup)

    $lblAdmin = New-Object System.Windows.Forms.Label
    $lblAdmin.AutoSize = $true
    $lblAdmin.Location = New-Object System.Drawing.Point(($BTNW + $PAD*2), 558)
    $lblAdmin.ForeColor = if (Test-Admin) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Gray }
    $lblAdmin.Text = if (Test-Admin) { '  Running as Administrator' } else { '  Not Administrator (scripts 01 WSL/SSH will be skipped)' }
    $form.Controls.Add($lblAdmin)

    # ── Setup Scripts GroupBox ───────────────────────────────
    $grpScripts = New-Object System.Windows.Forms.GroupBox
    $grpScripts.Text     = 'Setup Scripts'
    $grpScripts.Location = New-Object System.Drawing.Point($PAD, 594)
    $grpScripts.Size     = New-Object System.Drawing.Size(($FW - $PAD*2), 78)
    $form.Controls.Add($grpScripts)

    $BW3 = [int](($FW - $PAD*2 - 16 - 20) / 3)   # width of each of the 3 script buttons

    $btnS01 = New-Object System.Windows.Forms.Button
    $btnS01.Text      = "01 - WSL2 + SSH  (Admin)"
    $btnS01.Location  = New-Object System.Drawing.Point(8, 22)
    $btnS01.Size      = New-Object System.Drawing.Size($BW3, 30)
    $btnS01.ForeColor = [System.Drawing.Color]::Gray
    $grpScripts.Controls.Add($btnS01)

    $btnS02 = New-Object System.Windows.Forms.Button
    $btnS02.Text      = "02 - VS Code Extensions + CAC"
    $btnS02.Location  = New-Object System.Drawing.Point(($BW3 + 18), 22)
    $btnS02.Size      = New-Object System.Drawing.Size($BW3, 30)
    $grpScripts.Controls.Add($btnS02)

    $btnS03 = New-Object System.Windows.Forms.Button
    $btnS03.Text      = "03 - Pizza ML Trainer"
    $btnS03.Location  = New-Object System.Drawing.Point(($BW3*2 + 26), 22)
    $btnS03.Size      = New-Object System.Drawing.Size($BW3, 30)
    $btnS03.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnS03.ForeColor = [System.Drawing.Color]::White
    $btnS03.FlatStyle = 'Flat'
    $grpScripts.Controls.Add($btnS03)

    # ── Log GroupBox ─────────────────────────────────────────
    $grpLog = New-Object System.Windows.Forms.GroupBox
    $grpLog.Text     = 'Log'
    $grpLog.Location = New-Object System.Drawing.Point($PAD, 682)
    $grpLog.Size     = New-Object System.Drawing.Size(($FW - $PAD*2), 228)
    $form.Controls.Add($grpLog)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline   = $true
    $txtLog.ReadOnly    = $true
    $txtLog.ScrollBars  = 'Vertical'
    $txtLog.Location    = New-Object System.Drawing.Point(8, 20)
    $txtLog.Size        = New-Object System.Drawing.Size(($grpLog.Width - 18), 195)
    $txtLog.BackColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor   = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $txtLog.Font        = New-Object System.Drawing.Font('Consolas', 8.5)
    $grpLog.Controls.Add($txtLog)

    $script:GuiLog = $txtLog

    # ── Shared helpers ────────────────────────────────────────
    function GuiLog { param([string]$Msg); $txtLog.AppendText("$Msg`r`n"); $txtLog.ScrollToCaret(); [System.Windows.Forms.Application]::DoEvents() }

    # Delegate: prompt for repo URL via input dialog
    $script:GuiPromptUrl = {
        param([string]$RepoName)
        $dlgUrl = New-Object System.Windows.Forms.Form
        $dlgUrl.Text = "Repo URL - $RepoName"
        $dlgUrl.ClientSize = New-Object System.Drawing.Size(430, 110)
        $dlgUrl.StartPosition = 'CenterParent'; $dlgUrl.FormBorderStyle = 'FixedDialog'; $dlgUrl.MaximizeBox = $false
        $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Git URL for $RepoName (leave blank to skip):"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(12, 12); $dlgUrl.Controls.Add($lbl)
        $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = New-Object System.Drawing.Point(12, 34); $txt.Size = New-Object System.Drawing.Size(400, 23); $dlgUrl.Controls.Add($txt)
        $bOk = New-Object System.Windows.Forms.Button; $bOk.Text = 'OK'; $bOk.Location = New-Object System.Drawing.Point(12, 68); $bOk.Size = New-Object System.Drawing.Size(80, 26); $bOk.DialogResult = 'OK'; $dlgUrl.AcceptButton = $bOk; $dlgUrl.Controls.Add($bOk)
        $bCl = New-Object System.Windows.Forms.Button; $bCl.Text = 'Skip'; $bCl.Location = New-Object System.Drawing.Point(102, 68); $bCl.Size = New-Object System.Drawing.Size(80, 26); $bCl.DialogResult = 'Cancel'; $dlgUrl.Controls.Add($bCl)
        if ($dlgUrl.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $txt.Text.Trim() }
        return ''
    }

    # Delegate: run setup script (03) with options dialog
    $script:GuiRunSetupScript = {
        param([string]$ScriptPath)
        $s03Args = Show-Script03Dialog
        if ($null -ne $s03Args) {
            GuiLog "`r`n==> Running $(Split-Path $ScriptPath -Leaf)..."
            GuiRunScript -Path $ScriptPath -ExtraArgs $s03Args
        }
    }

    function GuiRunScript {
        param([string]$Path, [string[]]$ExtraArgs)
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $ExtraArgs
        & powershell @psArgs 2>&1 | ForEach-Object { GuiLog "  $_"; [System.Windows.Forms.Application]::DoEvents() }
        $script:LastChildExitCode = $LASTEXITCODE
    }

    function Show-Script03Dialog {
        $opts = New-Object System.Windows.Forms.Form
        $opts.Text = 'Pizza ML Trainer Options'; $opts.ClientSize = New-Object System.Drawing.Size(430, 260)
        $opts.StartPosition = 'CenterParent'; $opts.FormBorderStyle = 'FixedDialog'; $opts.MaximizeBox = $false

        $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Pizza-ML repo URL (leave blank if already cloned):'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(12, 12); $opts.Controls.Add($l1)
        $tUrl = New-Object System.Windows.Forms.TextBox; $tUrl.Location = New-Object System.Drawing.Point(12, 32); $tUrl.Size = New-Object System.Drawing.Size(400, 23); $opts.Controls.Add($tUrl)

        $cCuda = New-Object System.Windows.Forms.CheckBox; $cCuda.Text = 'Use CUDA (GPU) build of PyTorch'; $cCuda.Location = New-Object System.Drawing.Point(12, 68); $cCuda.AutoSize = $true; $opts.Controls.Add($cCuda)
        $cData = New-Object System.Windows.Forms.CheckBox; $cData.Text = 'Skip Food-101 data download  (data/v1 and data/v2 already exist)'; $cData.Location = New-Object System.Drawing.Point(12, 96); $cData.AutoSize = $true; $opts.Controls.Add($cData)
        $cTest = New-Object System.Windows.Forms.CheckBox; $cTest.Text = 'Skip training smoke-test'; $cTest.Location = New-Object System.Drawing.Point(12, 124); $cTest.AutoSize = $true; $opts.Controls.Add($cTest)

        $bRun = New-Object System.Windows.Forms.Button; $bRun.Text = 'Run Setup'; $bRun.Location = New-Object System.Drawing.Point(12, 175); $bRun.Size = New-Object System.Drawing.Size(110, 30); $bRun.DialogResult = 'OK'; $opts.AcceptButton = $bRun; $opts.Controls.Add($bRun)
        $bSkip = New-Object System.Windows.Forms.Button; $bSkip.Text = 'Skip'; $bSkip.Location = New-Object System.Drawing.Point(132, 175); $bSkip.Size = New-Object System.Drawing.Size(80, 30); $bSkip.DialogResult = 'Cancel'; $opts.Controls.Add($bSkip)

        if ($opts.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $args03 = @()
        if ($tUrl.Text)    { $args03 += @('-RepoUrl', $tUrl.Text) }
        if ($cCuda.Checked){ $args03 += '-UseCuda' }
        if ($cData.Checked){ $args03 += '-SkipDataPrep' }
        if ($cTest.Checked){ $args03 += '-SkipTrainingTest' }
        return $args03
    }

    # ── Populate package ListView ─────────────────────────────
    function Refresh-PackageList {
        $lvPkg.Items.Clear()
        GuiLog "==> Checking packages..."
        $status = Get-PackageStatus
        foreach ($s in $status) {
            $item = New-Object System.Windows.Forms.ListViewItem($s.Id)
            if ($s.Installed) {
                $item.SubItems.Add('Installed') | Out-Null
                $item.SubItems.Add('')           | Out-Null
                $item.ForeColor = [System.Drawing.Color]::DarkGreen
                $item.Checked   = $false
            } else {
                $item.SubItems.Add('MISSING') | Out-Null
                $note = if ($s.Type -eq 'npm') { "npm install -g $($s.NpmPkg)" } else { 'winget install' }
                $item.SubItems.Add($note) | Out-Null
                $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 60, 0)
                $item.Checked   = $true
            }
            $item.Tag = $s
            $lvPkg.Items.Add($item) | Out-Null
            [System.Windows.Forms.Application]::DoEvents()
        }
        GuiLog "Package check complete."
    }

    # ── Populate repo ListView ────────────────────────────────
    function Refresh-RepoList {
        $lvRepo.Items.Clear()
        foreach ($repo in $Repos) {
            $name   = Split-Path $repo.Dir -Leaf
            $cloned = Test-Path (Join-Path $repo.Dir '.git')

            # Extra status for repos with a Python venv (pizza-ml)
            $status = if ($cloned) { 'Cloned' } else { 'Not cloned' }
            if ($cloned -and -not [string]::IsNullOrEmpty($repo.SetupScript)) {
                $venvPy = Join-Path $repo.Dir 'venv\Scripts\python.exe'
                if (Test-Path $venvPy) {
                    $torchOk = & $venvPy -c "import torch" 2>&1
                    $status  = if ($LASTEXITCODE -eq 0) { 'Cloned  |  venv OK' } else { 'Cloned  |  venv no torch' }
                } else {
                    $status = 'Cloned  |  venv missing'
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($name)
            $item.SubItems.Add($status)   | Out-Null
            $item.SubItems.Add($repo.Dir) | Out-Null
            $item.ForeColor = if ($cloned) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::FromArgb(180,60,0) }
            $item.Checked   = $true
            $item.Tag       = $repo
            $lvRepo.Items.Add($item) | Out-Null
        }
    }

    # ── Button: Refresh ───────────────────────────────────────
    $btnRefresh.Add_Click({
        $txtLog.Clear()
        Refresh-PackageList
        Refresh-RepoList
    })

    # ── Button: Select All Missing ────────────────────────────
    $btnSelMissing.Add_Click({
        foreach ($item in $lvPkg.Items) {
            $item.Checked = ($item.SubItems[1].Text -eq 'MISSING')
        }
    })

    # ── Button: Install Selected ──────────────────────────────
    $btnInstSel.Add_Click({
        Reset-RunFailures
        $selected = @()
        foreach ($item in $lvPkg.Items) {
            if ($item.Checked) { $selected += $item.Tag }
        }
        if ($selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No packages checked.', 'Install', 'OK', 'Information') | Out-Null
            return
        }
        $btnInstSel.Enabled = $false
        $btnRefresh.Enabled = $false
        GuiLog "`r`n==> Installing $($selected.Count) selected package(s)..."
        $toInstall = $selected | ForEach-Object { $_.Id }
        $statusMap = $selected
        Install-Packages -Ids $toInstall -StatusMap $statusMap
        GuiLog "Done. Refreshing..."
        Refresh-PackageList
        [void](Show-RunSummary -Label 'Package installation')
        $btnInstSel.Enabled = $true
        $btnRefresh.Enabled = $true
    })

    # ── Button: Clone/Update Selected ────────────────────────
    $btnClone.Add_Click({
        Reset-RunFailures
        $repoList = @()
        foreach ($item in $lvRepo.Items) { if ($item.Checked) { $repoList += $item.Tag } }
        if ($repoList.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No repos checked.', 'Clone', 'OK', 'Information') | Out-Null
            return
        }
        $btnClone.Enabled = $false
        GuiLog "`r`n==> Cloning / updating repos..."
        Sync-Repos -RepoList $repoList
        Refresh-RepoList
        [void](Show-RunSummary -Label 'Repository sync')
        $btnClone.Enabled = $true
    })

    # ── Button: Cleanup Repos ─────────────────────────────────
    $btnCleanup.Add_Click({
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text            = 'Cleanup Repositories'
        $dlg.ClientSize      = New-Object System.Drawing.Size(420, 265)
        $dlg.StartPosition   = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox     = $false

        $chkMod = New-Object System.Windows.Forms.CheckBox
        $chkMod.Text = 'Remove node_modules folders'
        $chkMod.Location = New-Object System.Drawing.Point(15, 15)
        $chkMod.AutoSize = $true
        $chkMod.Checked  = $true
        $dlg.Controls.Add($chkMod)

        $chkReinst = New-Object System.Windows.Forms.CheckBox
        $chkReinst.Text = 'Re-run package install after cleanup'
        $chkReinst.Location = New-Object System.Drawing.Point(15, 45)
        $chkReinst.AutoSize = $true
        $dlg.Controls.Add($chkReinst)

        $chkGit = New-Object System.Windows.Forms.CheckBox
        $chkGit.Text = 'git clean -fd  (remove untracked files)'
        $chkGit.Location = New-Object System.Drawing.Point(15, 75)
        $chkGit.AutoSize = $true
        $dlg.Controls.Add($chkGit)

        $chkPy = New-Object System.Windows.Forms.CheckBox
        $chkPy.Text = 'Remove Python venv + data/  (pizza-ml teardown)'
        $chkPy.Location = New-Object System.Drawing.Point(15, 105)
        $chkPy.AutoSize = $true
        $dlg.Controls.Add($chkPy)

        $chkRepo = New-Object System.Windows.Forms.CheckBox
        $chkRepo.Text = 'Delete cloned repository folders  (full teardown)'
        $chkRepo.Location = New-Object System.Drawing.Point(15, 135)
        $chkRepo.AutoSize = $true
        $dlg.Controls.Add($chkRepo)

        $btnGo = New-Object System.Windows.Forms.Button
        $btnGo.Text        = 'Run Cleanup'
        $btnGo.Location    = New-Object System.Drawing.Point(15, 195)
        $btnGo.Size        = New-Object System.Drawing.Size(110, 28)
        $btnGo.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.AcceptButton  = $btnGo
        $dlg.Controls.Add($btnGo)

        $btnCancelDlg = New-Object System.Windows.Forms.Button
        $btnCancelDlg.Text        = 'Cancel'
        $btnCancelDlg.Location    = New-Object System.Drawing.Point(135, 195)
        $btnCancelDlg.Size        = New-Object System.Drawing.Size(80, 28)
        $btnCancelDlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Controls.Add($btnCancelDlg)

        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $btnCleanup.Enabled = $false
            Invoke-CleanupRepos -RepoList $Repos `
                -RemoveModules:($chkMod.Checked)    `
                -GitClean:($chkGit.Checked)          `
                -Reinstall:($chkReinst.Checked)      `
                -RemovePythonEnv:($chkPy.Checked)    `
                -RemoveRepos:($chkRepo.Checked)
            Refresh-RepoList
            $btnCleanup.Enabled = $true
        }
    })

    # ── Button: Script 01 (WSL2 + SSH) ───────────────────────
    $btnS01.Add_Click({
        $s01 = Join-Path $ScriptDir '01-setup-wsl-ssh.ps1'
        if (-not (Test-Path $s01)) { GuiLog "[WARN] 01-setup-wsl-ssh.ps1 not found."; return }
        if (-not (Test-Admin))     { [System.Windows.Forms.MessageBox]::Show('Script 01 requires Administrator rights. Re-run PowerShell as Administrator.','Admin Required','OK','Warning') | Out-Null; return }
        $r = [System.Windows.Forms.MessageBox]::Show('Run 01-setup-wsl-ssh.ps1 (WSL2 + OpenSSH)?  May require a reboot.','Script 01','YesNo','Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $btnS01.Enabled = $false
            GuiLog "`r`n==> Running 01-setup-wsl-ssh.ps1..."
            GuiRunScript -Path $s01
            if ($script:LastChildExitCode -ne 0) {
                Add-RunFailure "01-setup-wsl-ssh.ps1 exited with code $($script:LastChildExitCode)"
            }
            $btnS01.Enabled = $true
        }
    })

    # ── Button: Script 02 (VS Code + CAC) ────────────────────
    $btnS02.Add_Click({
        $s02 = Join-Path $ScriptDir '02-setup-coding-agents.ps1'
        if (-not (Test-Path $s02)) { GuiLog "[WARN] 02-setup-coding-agents.ps1 not found."; return }
        $r = [System.Windows.Forms.MessageBox]::Show('Run 02-setup-coding-agents.ps1 (VS Code AI extensions + CAC CLI)?','Script 02','YesNo','Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $btnS02.Enabled = $false
            GuiLog "`r`n==> Running 02-setup-coding-agents.ps1..."
            GuiRunScript -Path $s02
            if ($script:LastChildExitCode -ne 0) {
                Add-RunFailure "02-setup-coding-agents.ps1 exited with code $($script:LastChildExitCode)"
            }
            $btnS02.Enabled = $true
        }
    })

    # ── Button: Script 03 (Pizza ML) ─────────────────────────
    $btnS03.Add_Click({
        $s03 = Join-Path $ScriptDir '03-setup-pizza-ml-trainer.ps1'
        if (-not (Test-Path $s03)) { GuiLog "[WARN] 03-setup-pizza-ml-trainer.ps1 not found."; return }
        $s03Args = Show-Script03Dialog
        if ($null -ne $s03Args) {
            $btnS03.Enabled = $false
            GuiLog "`r`n==> Running 03-setup-pizza-ml-trainer.ps1..."
            GuiRunScript -Path $s03 -ExtraArgs $s03Args
            if ($script:LastChildExitCode -ne 0) {
                Add-RunFailure "03-setup-pizza-ml-trainer.ps1 exited with code $($script:LastChildExitCode)"
            }
            $btnS03.Enabled = $true
        }
    })

    # ── Button: Full Setup ────────────────────────────────────
    $btnFullSetup.Add_Click({
        Reset-RunFailures
        $btnFullSetup.Enabled = $false
        GuiLog "`r`n==> Running full setup..."

        # 1: Install all missing
        GuiLog "Step 1/3: Packages..."
        Refresh-PackageList
        $toInstall = @()
        $statusMap  = @()
        foreach ($item in $lvPkg.Items) {
            if ($item.SubItems[1].Text -eq 'MISSING') {
                $toInstall += $item.Tag.Id
                $statusMap  += $item.Tag
            }
        }
        if ($toInstall.Count -gt 0) {
            Install-Packages -Ids $toInstall -StatusMap $statusMap
            Refresh-PackageList
        } else { GuiLog "  All packages already installed." }

        # 2: Repos
        GuiLog "`r`nStep 2/3: Repos..."
        Sync-Repos -RepoList $Repos
        Refresh-RepoList

        # 3: Setup scripts
        GuiLog "`r`nStep 3/3: Setup scripts..."
        $btnS01.PerformClick()
        $btnS02.PerformClick()
        $btnS03.PerformClick()

        $ok = Show-RunSummary -Label 'Full setup'
        if ($ok) {
            GuiLog "`r`n==> Full setup complete!"
            [System.Windows.Forms.MessageBox]::Show('Full setup complete!', 'Done', 'OK', 'Information') | Out-Null
        } else {
            GuiLog "`r`n==> Full setup completed with issues."
            [System.Windows.Forms.MessageBox]::Show('Full setup completed with recorded issues. Review the log.', 'Done', 'OK', 'Warning') | Out-Null
        }
        $btnFullSetup.Enabled = $true
    })

    # Populate after the form is visible so the window appears immediately
    $form.Add_Shown({
        Refresh-PackageList
        Refresh-RepoList
    })

    $form.ShowDialog() | Out-Null
    $script:GuiLog = $null
}

# ─────────────────────────────────────────────────────────────
# Terminal Mode
# ─────────────────────────────────────────────────────────────
function Show-TerminalMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +==========================================+" -ForegroundColor Cyan
    Write-Host "  |   Pizza Trainer -- Environment Setup    |" -ForegroundColor Cyan
    Write-Host "  +==========================================+" -ForegroundColor Cyan
    Write-Host "  |                                         |" -ForegroundColor Cyan
    Write-Host "  |  [1] Check installed packages           |" -ForegroundColor Cyan
    Write-Host "  |  [2] Install packages (choose each)     |" -ForegroundColor Cyan
    Write-Host "  |  [3] Clone / update repos               |" -ForegroundColor Cyan
    Write-Host "  |  [4] Run full setup  (1+2+3+scripts)    |" -ForegroundColor Cyan
    Write-Host "  |  [5] Cleanup repos                      |" -ForegroundColor Cyan
    Write-Host "  |  [Q] Quit                               |" -ForegroundColor Cyan
    Write-Host "  |                                         |" -ForegroundColor Cyan
    Write-Host "  +==========================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Select-PackagesToInstall {
    param([object[]]$StatusMap)

    $missing = $StatusMap | Where-Object { -not $_.Installed -and -not $_.Skip }
    if ($missing.Count -eq 0) { Write-Ok "All packages are installed."; return @() }

    # Build a toggling selection list
    $selected = @{}
    foreach ($s in $missing) { $selected[$s.Id] = $true }

    while ($true) {
        Write-Host ""
        Write-Host "  Packages (toggle with number, A=all, N=none, I=install, Q=cancel):" -ForegroundColor White
        Write-Host ""
        $i = 1
        $indexMap = @{}
        foreach ($s in $missing) {
            $check   = if ($selected[$s.Id]) { 'x' } else { ' ' }
            $note    = if ($s.Type -eq 'npm') { "  npm install -g $($s.NpmPkg)" } else { '' }
            $color   = if ($selected[$s.Id]) { 'Yellow' } else { 'DarkGray' }
            Write-Host ("  [{0}] [{1}] {2,-42}{3}" -f $i, $check, $s.Id, $note) -ForegroundColor $color
            $indexMap["$i"] = $s.Id
            $i++
        }
        Write-Host ""
        $input = (Read-Host "  > ").Trim().ToUpper()

        if ($input -eq 'Q') { return @() }
        if ($input -eq 'I') { break }
        if ($input -eq 'A') { foreach ($k in $selected.Keys) { $selected[$k] = $true }; continue }
        if ($input -eq 'N') { foreach ($k in $selected.Keys) { $selected[$k] = $false }; continue }

        # Toggle individual numbers (space-separated)
        foreach ($token in ($input -split '\s+')) {
            if ($indexMap.ContainsKey($token)) {
                $id = $indexMap[$token]
                $selected[$id] = -not $selected[$id]
            }
        }
    }

    return ($missing | Where-Object { $selected[$_.Id] })
}

function Invoke-TerminalCleanup {
    Write-Host ""
    Write-Host "  Cleanup options:" -ForegroundColor White
    Write-Host "  [1] Remove node_modules" -ForegroundColor Cyan
    Write-Host "  [2] Remove node_modules + re-run install" -ForegroundColor Cyan
    Write-Host "  [3] git clean -fd (remove untracked files)" -ForegroundColor Cyan
    Write-Host "  [4] All of the above (JS repos)" -ForegroundColor Cyan
    Write-Host "  [5] Remove Python venv + data/  (pizza-ml teardown)" -ForegroundColor Cyan
    Write-Host "  [6] Delete cloned repos (full teardown)" -ForegroundColor Cyan
    Write-Host "  [Q] Back" -ForegroundColor Cyan
    Write-Host ""
    $c = (Read-Host "  Select option").Trim().ToUpper()

    switch ($c) {
        '1' { Invoke-CleanupRepos -RepoList $Repos -RemoveModules }
        '2' { Invoke-CleanupRepos -RepoList $Repos -RemoveModules -Reinstall }
        '3' { Invoke-CleanupRepos -RepoList $Repos -GitClean }
        '4' { Invoke-CleanupRepos -RepoList $Repos -RemoveModules -GitClean -Reinstall }
        '5' { Invoke-CleanupRepos -RepoList $Repos -RemovePythonEnv }
        '6' { Invoke-CleanupRepos -RepoList $Repos -RemoveRepos }
        'Q' { return }
        default { Write-Warn "Invalid option." }
    }
}

function Start-TerminalMode {
    $running = $true
    while ($running) {
        Show-TerminalMenu
        $choice = (Read-Host "  Select option").Trim().ToUpper()

        switch ($choice) {
            '1' {
                Write-Step "Checking installed packages"
                $status = Get-PackageStatus
                Write-Host ""
                Write-Host ("  {0,-44} {1}" -f "Package ID", "Status") -ForegroundColor White
                Write-Host ("  {0,-44} {1}" -f "----------", "------") -ForegroundColor DarkGray
                foreach ($s in $status) {
                    if ($s.Installed) {
                        Write-Host ("  [OK]  {0,-42} installed" -f $s.Id) -ForegroundColor Green
                    } else {
                        Write-Host ("  [--]  {0,-42} MISSING"   -f $s.Id) -ForegroundColor Yellow
                    }
                }
                Write-Host ""
                $miss = ($status | Where-Object { -not $_.Installed }).Count
                if ($miss -eq 0) { Write-Ok "All packages installed." } else { Write-Warn "$miss package(s) missing." }
                Write-Host ""; Read-Host "  Press Enter to return"
            }
            '2' {
                Reset-RunFailures
                Write-Step "Checking packages..."
                $status   = Get-PackageStatus
                $toInstall = Select-PackagesToInstall -StatusMap $status
                if ($toInstall.Count -gt 0) {
                    Install-Packages -Ids ($toInstall | ForEach-Object { $_.Id }) -StatusMap $toInstall
                } else { Write-Warn "Nothing selected." }
                [void](Show-RunSummary -Label 'Package installation')
                Write-Host ""; Read-Host "  Press Enter to return"
            }
            '3' {
                Reset-RunFailures
                Sync-Repos -RepoList $Repos
                [void](Show-RunSummary -Label 'Repository sync')
                Write-Host ""; Read-Host "  Press Enter to return"
            }
            '4' {
                Reset-RunFailures
                Write-Host ""
                Write-Host "  Running full environment setup..." -ForegroundColor Cyan

                $status    = Get-PackageStatus
                $toInstall = Select-PackagesToInstall -StatusMap $status
                if ($toInstall.Count -gt 0) {
                    Install-Packages -Ids ($toInstall | ForEach-Object { $_.Id }) -StatusMap $toInstall
                }
                Sync-Repos -RepoList $Repos

                $s01 = Join-Path $ScriptDir '01-setup-wsl-ssh.ps1'
                if (Test-Path $s01) {
                    if (Test-Admin) {
                        $r = Read-Host "`n  Run 01-setup-wsl-ssh.ps1 (WSL2 + OpenSSH)? [Y/n]"
                        if ($r -notmatch '^[Nn]') { Write-Step "Running 01..."; & $s01; if ($LASTEXITCODE -ne 0) { Add-RunFailure "01-setup-wsl-ssh.ps1 exited with code $LASTEXITCODE" } }
                    } else { Write-Warn "Not Administrator - skipping 01-setup-wsl-ssh.ps1" }
                }
                $s02 = Join-Path $ScriptDir '02-setup-coding-agents.ps1'
                if (Test-Path $s02) {
                    $r = Read-Host "`n  Run 02-setup-coding-agents.ps1 (VS Code extensions + CAC)? [Y/n]"
                    if ($r -notmatch '^[Nn]') { Write-Step "Running 02-setup-coding-agents.ps1..."; & $s02; if ($LASTEXITCODE -ne 0) { Add-RunFailure "02-setup-coding-agents.ps1 exited with code $LASTEXITCODE" } }
                }
                $s03 = Join-Path $ScriptDir '03-setup-pizza-ml-trainer.ps1'
                if (Test-Path $s03) {
                    $r = Read-Host "`n  Run 03-setup-pizza-ml-trainer.ps1 (pizza ML trainer)? [Y/n]"
                    if ($r -notmatch '^[Nn]') {
                        $url        = Read-Host "  Pizza-ML repo URL (leave blank if already cloned)"
                        $cuda       = Read-Host "  Use CUDA (GPU) build? [y/N]"
                        $skipData   = Read-Host "  Skip Food-101 download? [y/N]"
                        $skipTest   = Read-Host "  Skip training smoke-test? [y/N]"
                        $s03Args = @()
                        if ($url)                          { $s03Args += @('-RepoUrl', $url) }
                        if ($cuda     -match '^[Yy]')      { $s03Args += '-UseCuda' }
                        if ($skipData -match '^[Yy]')      { $s03Args += '-SkipDataPrep' }
                        if ($skipTest -match '^[Yy]')      { $s03Args += '-SkipTrainingTest' }
                        Write-Step "Running 03-setup-pizza-ml-trainer.ps1..."
                        & $s03 @s03Args
                        if ($LASTEXITCODE -ne 0) { Add-RunFailure "03-setup-pizza-ml-trainer.ps1 exited with code $LASTEXITCODE" }
                    }
                }
                Write-Host ""
                if (Show-RunSummary -Label 'Full setup') {
                    Write-Host "  ================================================" -ForegroundColor Green
                    Write-Host "   Full setup complete!" -ForegroundColor Green
                    Write-Host "  ================================================" -ForegroundColor Green
                } else {
                    Write-Host "  ================================================" -ForegroundColor Yellow
                    Write-Host "   Full setup completed with issues." -ForegroundColor Yellow
                    Write-Host "  ================================================" -ForegroundColor Yellow
                }
                Write-Host ""; Read-Host "  Press Enter to return"
            }
            '5' {
                Invoke-TerminalCleanup
                Write-Host ""; Read-Host "  Press Enter to return"
            }
            'Q' {
                $running = $false
                Write-Host ""
                Write-Host "  Goodbye!" -ForegroundColor Cyan
                Write-Host ""
            }
            default {
                Write-Host "  Invalid option. Enter 1-5 or Q." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────
if (-not (Invoke-SetupPreflight)) {
    Write-Host ''
    Write-Host '  Setup cancelled after preflight.' -ForegroundColor Yellow
    exit 1
}

if ($Action) {
    exit (Invoke-ActionMode)
}

if ($NoGui) {
    Start-TerminalMode
} else {
    Write-Host "  Loading GUI..." -ForegroundColor Gray
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
        Start-GuiMode
    } catch {
        Write-Host ""
        Write-Host "  GUI failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Falling back to terminal menu. (Run with -NoGui to skip this.)" -ForegroundColor Yellow
        Write-Host ""
        Start-Sleep -Seconds 2
        Start-TerminalMode
    }
}
