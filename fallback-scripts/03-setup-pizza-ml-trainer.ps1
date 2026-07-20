#Requires -Version 5.1
<#
.SYNOPSIS
    Script 3: Trainer setup for the pizza-ml lab environment.
.DESCRIPTION
    Automates the trainer preparation steps from the Trainer Setup Guide (Option B).
    Covers:
      - Verify Python 3.10+
      - Clone or copy the pizza-ml project
      - Create a Python virtual environment
      - Install PyTorch + dependencies (CPU or CUDA)
      - Verify the installation
      - Prepare the Food-101 training data
      - Run a quick end-to-end training test
      - Clean up model files for participant distribution
.PARAMETER RepoUrl
    Git URL of the pizza-ml repository. Defaults to placeholder REPO_URL.
.PARAMETER ProjectDir
    Local path where the project will be cloned/placed. Defaults to $HOME\Learning\pizza-ml.
.PARAMETER UseCuda
    Switch: install the CUDA (GPU) build of PyTorch instead of the CPU build.
.PARAMETER SkipDataPrep
    Switch: skip downloading the Food-101 dataset (useful when data already exists).
.PARAMETER SkipTrainingTest
    Switch: skip the quick training smoke-test.
.NOTES
    Run as a normal user. No Administrator rights required.
    Example:
        .\03-setup-pizza-ml-trainer.ps1 -RepoUrl https://github.com/example/pizza-ml
        .\03-setup-pizza-ml-trainer.ps1 -UseCuda -SkipDataPrep
        .\03-setup-pizza-ml-trainer.ps1 -SkipDataPrep -SkipTrainingTest
#>

param(
    [string]$RepoUrl         = 'REPO_URL',
    [string]$ProjectDir      = '',
    [switch]$UseCuda,
    [switch]$SkipDataPrep,
    [switch]$SkipTrainingTest,
    [switch]$Resume,
    [switch]$ResetCheckpoint,
    [string]$CheckpointPath  = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$script:SoftFailures = New-Object System.Collections.Generic.List[string]

if (-not $ProjectDir) { $ProjectDir = Join-Path (Join-Path $HOME 'Learning') 'pizza-ml' }
if (-not $CheckpointPath) { $CheckpointPath = Join-Path (Join-Path $HOME '.pizza-trainer') '03-setup-pizza-ml-trainer.json' }

# ==============================================================
# Helpers
# ==============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Add-SoftFailure {
    param([string]$Message)
    $script:SoftFailures.Add($Message)
    Write-Warn $Message
}

function Complete-Setup {
    param([bool]$ChecklistPassed)

    Set-CheckpointStep -Step 'completed'

    if (-not $ChecklistPassed -and -not ($script:SoftFailures -contains 'Pre-lab checklist is incomplete.')) {
        $script:SoftFailures.Add('Pre-lab checklist is incomplete.')
    }

    if ($script:SoftFailures.Count -eq 0) {
        Write-Success 'Trainer setup completed without recorded issues.'
        exit 0
    }

    Write-Warn "Trainer setup completed with $($script:SoftFailures.Count) recorded issue(s)."
    foreach ($item in $script:SoftFailures) {
        Write-Host "    - $item" -ForegroundColor Yellow
    }
    exit 2
}

function Initialize-CheckpointState {
    $script:CheckpointState = [ordered]@{
        ProjectDir = $ProjectDir
        UpdatedAt  = ''
        Steps      = @{}
    }
}

function Save-CheckpointState {
    $checkpointDir = Split-Path -Parent $CheckpointPath
    if (-not (Test-Path $checkpointDir)) {
        New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
    }

    $script:CheckpointState.ProjectDir = $ProjectDir
    $script:CheckpointState.UpdatedAt = (Get-Date).ToString('o')
    $payload = [pscustomobject]@{
        ProjectDir = $script:CheckpointState.ProjectDir
        UpdatedAt  = $script:CheckpointState.UpdatedAt
        Steps      = [pscustomobject]$script:CheckpointState.Steps
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $CheckpointPath -Encoding UTF8
}

function Load-CheckpointState {
    if (-not (Test-Path $CheckpointPath)) {
        Initialize-CheckpointState
        return
    }

    try {
        $loaded = Get-Content $CheckpointPath -Raw | ConvertFrom-Json
        Initialize-CheckpointState
        if ($loaded.ProjectDir) {
            $script:CheckpointState.ProjectDir = [string]$loaded.ProjectDir
        }
        if ($loaded.UpdatedAt) {
            $script:CheckpointState.UpdatedAt = [string]$loaded.UpdatedAt
        }
        if ($loaded.Steps) {
            foreach ($property in $loaded.Steps.PSObject.Properties) {
                $script:CheckpointState.Steps[$property.Name] = [bool]$property.Value
            }
        }
    } catch {
        Write-Warn ("Could not load checkpoint file at {0}: {1}" -f $CheckpointPath, $_)
        Initialize-CheckpointState
    }
}

function Test-CheckpointStep {
    param([string]$Step)
    return [bool]$script:CheckpointState.Steps[$Step]
}

function Set-CheckpointStep {
    param([string]$Step)
    $script:CheckpointState.Steps[$Step] = $true
    Save-CheckpointState
}

function Write-CheckpointSkip {
    param([string]$Message)
    Write-Step "$Message (resume checkpoint)"
}

if ($ResetCheckpoint -and (Test-Path $CheckpointPath)) {
    Remove-Item $CheckpointPath -Force
}

Load-CheckpointState

if ($Resume -and $script:CheckpointState.ProjectDir -and ($script:CheckpointState.ProjectDir -ne $ProjectDir)) {
    Write-Warn "Checkpoint was created for $($script:CheckpointState.ProjectDir), not $ProjectDir. Resetting checkpoint state for this run."
    Initialize-CheckpointState
}

$dataV1 = Join-Path $ProjectDir 'data\v1'
$dataV2 = Join-Path $ProjectDir 'data\v2'

function Invoke-Venv {
    param([string[]]$Params)
    & "$ProjectDir\venv\Scripts\python.exe" @Params
}

function Invoke-Pip {
    param([string[]]$Params)
    & "$ProjectDir\venv\Scripts\pip.exe" @Params
}

# ==============================================================
# Phase 0 -- Execution policy guard
# ==============================================================

Write-Step "Checking PowerShell execution policy"
$policy = $null
try {
    $policy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction Stop
} catch {
    Write-Warn 'Could not query execution policy in this host. Continuing without policy validation.'
}

if ($null -eq $policy) {
    Write-Info 'Execution policy check skipped because Get-ExecutionPolicy is unavailable.'
} elseif ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
    Write-Warn "Execution policy is '$policy' -- attempting to relax for CurrentUser"
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Success "Execution policy set to RemoteSigned for CurrentUser"
    } catch {
        Write-Fail "Could not set execution policy: $_"
        Add-SoftFailure 'Could not set execution policy automatically. Run Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser if needed.'
    }
} else {
    Write-Success "Execution policy OK ($policy)"
}

# ==============================================================
# Phase 1 -- Verify Python 3.10+
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'python_validated')) {
    Write-CheckpointSkip 'Skipping Python validation'
} else {
    Write-Step "Checking Python installation"

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd) {
        Write-Fail "'python' not found on PATH."
        Write-Warn "Install Python 3.10+ from https://www.python.org/downloads/"
        Write-Warn "Make sure to check 'Add Python to PATH' during installation."
        exit 1
    }

    $rawVersion = & python --version 2>&1
    if ($rawVersion -match 'Python (\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
            Write-Fail "Python $major.$minor found -- version 3.10 or newer required."
            exit 1
        }
        Write-Success "$rawVersion ($(Split-Path $pythonCmd.Source -Leaf))"
        Set-CheckpointStep -Step 'python_validated'
    } else {
        Write-Fail "Could not parse Python version from: $rawVersion"
        exit 1
    }
}

# ==============================================================
# Phase 2 -- Clone or copy the project
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'project_ready')) {
    Write-CheckpointSkip 'Skipping project setup'
} else {
    Write-Step "Setting up project directory: $ProjectDir"

    if (Test-Path $ProjectDir) {
        Write-Warn "Directory already exists -- skipping clone: $ProjectDir"
    } elseif ($RepoUrl -eq 'REPO_URL') {
        Write-Fail "No -RepoUrl specified and '$ProjectDir' does not exist."
        Write-Warn "Pass -RepoUrl [url] or copy the project folder to: $ProjectDir"
        exit 1
    } else {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitCmd) {
            Write-Fail "'git' not found on PATH. Install Git from https://git-scm.com/ and re-run."
            exit 1
        }
        Write-Host "  Cloning $RepoUrl -> $ProjectDir" -ForegroundColor Gray
        git clone $RepoUrl $ProjectDir
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "git clone failed (exit $LASTEXITCODE)"
            Write-Warn "Common causes:"
            Write-Host "    - Repository is private (need credentials or SSH key)" -ForegroundColor Gray
            Write-Host "    - URL is incorrect or repo does not exist" -ForegroundColor Gray
            Write-Host "    - No internet connection" -ForegroundColor Gray
            exit 1
        }
        Write-Success "Repository cloned"
    }
    Set-CheckpointStep -Step 'project_ready'
}

Set-Location $ProjectDir

# ==============================================================
# Phase 3 -- Create Python virtual environment
# ==============================================================

$venvPath = Join-Path $ProjectDir 'venv'
if ($Resume -and (Test-CheckpointStep -Step 'venv_ready')) {
    Write-CheckpointSkip 'Skipping virtual environment creation'
} else {
    Write-Step "Creating Python virtual environment"

    if (Test-Path $venvPath) {
        Write-Warn "venv already exists -- skipping creation"
    } else {
        python -m venv venv
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to create virtual environment (exit $LASTEXITCODE)"
            exit 1
        }
        Write-Success "Virtual environment created at $venvPath"
    }

    if (-not (Test-Path "$venvPath\Scripts\python.exe")) {
        Write-Fail "python.exe not found inside venv -- venv may be corrupt. Delete the venv folder and re-run."
        exit 1
    }

    Write-Success "venv Python: $(& "$venvPath\Scripts\python.exe" --version 2>&1)"
    Set-CheckpointStep -Step 'venv_ready'
}

# ==============================================================
# Phase 4 -- Install PyTorch and dependencies
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'deps_installed')) {
    Write-CheckpointSkip 'Skipping dependency installation'
} else {
    Write-Step "Installing PyTorch and dependencies"

    if ($UseCuda) {
        $torchIndex = 'https://download.pytorch.org/whl/cu124'
        Write-Host "  Mode: CUDA (GPU) build" -ForegroundColor Gray
    } else {
        $torchIndex = 'https://download.pytorch.org/whl/cpu'
        Write-Host "  Mode: CPU-only build (~200 MB)" -ForegroundColor Gray
    }

    Write-Host "  pip install torch torchvision --index-url $torchIndex" -ForegroundColor Gray
    Invoke-Pip @('install', 'torch', 'torchvision', '--index-url', $torchIndex)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "PyTorch installation failed (exit $LASTEXITCODE)"
        exit 1
    }
    Write-Success "torch + torchvision installed"

    Write-Host "  pip install tqdm Pillow" -ForegroundColor Gray
    Invoke-Pip @('install', 'tqdm', 'Pillow')
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "tqdm/Pillow installation failed (exit $LASTEXITCODE)"
        exit 1
    }
    Write-Success "tqdm + Pillow installed"

    $reqFile = Join-Path $ProjectDir 'requirements.txt'
    if (Test-Path $reqFile) {
        Write-Host "  pip install -r requirements.txt" -ForegroundColor Gray
        Invoke-Pip @('install', '-r', 'requirements.txt')
        if ($LASTEXITCODE -eq 0) {
            Write-Success "requirements.txt installed"
        } else {
            Add-SoftFailure "requirements.txt install returned exit $LASTEXITCODE (non-fatal)"
        }
    }
    Set-CheckpointStep -Step 'deps_installed'
}

# ==============================================================
# Phase 5 -- Verify the installation
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'verification_done')) {
    Write-CheckpointSkip 'Skipping installation verification'
} else {
    Write-Step "Verifying installation"

    $checkScript = Join-Path $ProjectDir 'check_environment.py'
    if (Test-Path $checkScript) {
        Write-Host "  Running check_environment.py..." -ForegroundColor Gray
        Invoke-Venv @('check_environment.py')
        if ($LASTEXITCODE -eq 0) {
            Write-Success "check_environment.py passed"
        } else {
            Add-SoftFailure "check_environment.py reported issues (exit $LASTEXITCODE)"
        }
    } else {
        Add-SoftFailure 'check_environment.py not found -- skipping environment verification script.'
    }

    Write-Host "  Testing PyTorch import (30s timeout)..." -ForegroundColor Gray
    $torchPy   = "$venvPath\Scripts\python.exe"
    $torchCode = "import torch; print('PyTorch ' + torch.__version__); print('CUDA available: ' + str(torch.cuda.is_available()))"
    $job = Start-Job { & $using:torchPy -c $using:torchCode }
    if (Wait-Job $job -Timeout 30) {
        $torchTest = Receive-Job $job
        Write-Host "  $torchTest" -ForegroundColor Gray
        Write-Success "PyTorch import OK"
    } else {
        Stop-Job $job
        Add-SoftFailure 'PyTorch import timed out (CUDA probe may be slow) -- continuing anyway.'
    }
    Remove-Job $job -Force
    Set-CheckpointStep -Step 'verification_done'
}

# ==============================================================
# Phase 6 -- Prepare training data
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'data_prepared')) {
    Write-CheckpointSkip 'Skipping data preparation'
} elseif ($SkipDataPrep) {
    Write-Step "Skipping data preparation (-SkipDataPrep)"
    Set-CheckpointStep -Step 'data_prepared'
} else {
    Write-Step "Preparing Food-101 training data (~5 GB download, 5-10 min)"

    if ((Test-Path $dataV1) -and (Test-Path $dataV2)) {
        Write-Warn "data/v1 and data/v2 already exist -- skipping prepare_data.py"
    } else {
        $prepScript = Join-Path $ProjectDir 'prepare_data.py'
        if (-not (Test-Path $prepScript)) {
            Write-Fail "prepare_data.py not found in $ProjectDir"
            exit 1
        }
        Invoke-Venv @('prepare_data.py')
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "prepare_data.py failed (exit $LASTEXITCODE)"
            exit 1
        }
        Write-Success "Training data prepared"
    }

    $rawDir = Join-Path $ProjectDir 'data\_food101_raw'
    if (Test-Path $rawDir) {
        Write-Host "  Removing raw download: $rawDir" -ForegroundColor Gray
        Remove-Item -Recurse -Force $rawDir
        Write-Success "Deleted data\_food101_raw (freed ~5 GB)"
    }

    Write-Host ""
    Write-Host "  Data directory counts:" -ForegroundColor White
    $splits = @('v1\train\pizza','v1\train\not_pizza','v1\test\pizza','v1\test\not_pizza',
                'v2\train\pizza','v2\train\not_pizza','v2\test\pizza','v2\test\not_pizza')
    foreach ($split in $splits) {
        $dir = Join-Path $ProjectDir "data\$split"
        if (Test-Path $dir) {
            $count = @(Get-ChildItem $dir -File).Count
            Write-Host ("    {0,-35} {1} images" -f $split, $count) -ForegroundColor Gray
        } else {
            Write-Warn "Missing: data\$split"
        }
    }
    Set-CheckpointStep -Step 'data_prepared'
}

# ==============================================================
# Phase 7 -- Quick end-to-end training smoke-test
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'training_test_done')) {
    Write-CheckpointSkip 'Skipping training smoke-test'
} elseif ($SkipTrainingTest) {
    Write-Step "Skipping training smoke-test (-SkipTrainingTest)"
    Set-CheckpointStep -Step 'training_test_done'
} else {
    Write-Step "Running quick training smoke-test (2 epochs)"

    $trainScript = @(
        Join-Path $ProjectDir 'train_tinyvgg.py'
        Join-Path $ProjectDir 'train-pizza-creation.py'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not (Test-Path $trainScript)) {
        Write-Warn 'No supported training script found -- skipping smoke-test'
    } else {
        $trainScriptName = Split-Path $trainScript -Leaf
        $testModel = Join-Path $ProjectDir 'test_run.pth'
        $testImage = Join-Path $ProjectDir 'test_pizza1.jpg'
        if (-not (Test-Path $testImage)) {
            $sampleCandidates = @()
            $sampleCandidates += @(Get-ChildItem (Join-Path $dataV1 'test\pizza') -File -ErrorAction SilentlyContinue)
            $sampleCandidates += @(Get-ChildItem (Join-Path $dataV2 'test\pizza') -File -ErrorAction SilentlyContinue)
            $testImage = $sampleCandidates | Select-Object -First 1 -ExpandProperty FullName
        }

        Write-Host "  Training for 2 epochs on data\v1..." -ForegroundColor Gray
        Invoke-Venv @($trainScriptName, '--data-dir', $dataV1, '--epochs', '2', '--output', $testModel)
        if ($LASTEXITCODE -ne 0) {
            Add-SoftFailure "Training run failed (exit $LASTEXITCODE)"
        } else {
            Write-Success "Training completed"

            if (Test-Path $testImage) {
                Write-Host ("  Running prediction on {0}..." -f (Split-Path $testImage -Leaf)) -ForegroundColor Gray
                Invoke-Venv @($trainScriptName, '--predict', $testImage, '--output', $testModel)
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "Prediction succeeded"
                } else {
                    Add-SoftFailure "Prediction returned exit $LASTEXITCODE"
                }
            } else {
                Write-Warn 'No pizza sample image found for prediction test -- skipping prediction check.'
            }
        }

        if (Test-Path $testModel) {
            Remove-Item $testModel -Force
            Write-Success ("Removed temporary {0}" -f (Split-Path $testModel -Leaf))
        }
    }
    Set-CheckpointStep -Step 'training_test_done'
}

# ==============================================================
# Phase 8 -- Clean up for participant distribution
# ==============================================================

if ($Resume -and (Test-CheckpointStep -Step 'cleanup_done')) {
    Write-CheckpointSkip 'Skipping cleanup'
} else {
    Write-Step "Cleaning up model files for participant distribution"

    $pthFiles = @(Get-ChildItem $ProjectDir -Filter '*.pth' -File)
    if ($pthFiles.Count -eq 0) {
        Write-Success "No .pth files found -- directory is clean"
    } else {
        foreach ($f in $pthFiles) {
            Remove-Item $f.FullName -Force
            Write-Success "Removed $($f.Name)"
        }
    }
    Set-CheckpointStep -Step 'cleanup_done'
}

# ==============================================================
# Final checklist
# ==============================================================

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Pre-Lab Checklist" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$torchImportOk = $false
try {
    & "$venvPath\Scripts\python.exe" -c "import torch" 2>&1 | Out-Null
    $torchImportOk = ($LASTEXITCODE -eq 0)
} catch {
    $torchImportOk = $false
}

$ckPython  = $null -ne (Get-Command python -EA SilentlyContinue)
$ckVenv    = Test-Path (Join-Path $ProjectDir 'venv\Scripts\python.exe')
$ckDataV1  = Test-Path (Join-Path $ProjectDir 'data\v1')
$ckDataV2  = Test-Path (Join-Path $ProjectDir 'data\v2')
$ckRawGone = -not (Test-Path (Join-Path $ProjectDir 'data\_food101_raw'))
$ckNoPth   = @(Get-ChildItem $ProjectDir -Filter '*.pth' -File).Count -eq 0
$ckLegacyTrainScript = Test-Path (Join-Path $ProjectDir 'train_tinyvgg.py')
$ckModernCreateScript = Test-Path (Join-Path $ProjectDir 'train-pizza-creation.py')
$ckModernFinetuneScript = Test-Path (Join-Path $ProjectDir 'train-pizza-finetuning.py')

$checks = [ordered]@{
    "Python 3.10+ installed"      = $ckPython
    "Virtual environment exists"  = $ckVenv
    "PyTorch importable"          = $torchImportOk
    "data/v1 exists"              = $ckDataV1
    "data/v2 exists"              = $ckDataV2
    "data/_food101_raw removed"   = $ckRawGone
    "No .pth model files present" = $ckNoPth
}

if ($ckLegacyTrainScript) {
    $checks['exercise1.md present'] = Test-Path (Join-Path $ProjectDir 'exercise1.md')
    $checks['exercise2.md present'] = Test-Path (Join-Path $ProjectDir 'exercise2.md')
} elseif ($ckModernCreateScript -or $ckModernFinetuneScript) {
    $checks['train-pizza-creation.py present'] = $ckModernCreateScript
    $checks['train-pizza-finetuning.py present'] = $ckModernFinetuneScript
}

foreach ($label in $checks.Keys) {
    $ok    = $checks[$label]
    $mark  = if ($ok) { '[x]' } else { '[ ]' }
    $color = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0} {1}" -f $mark, $label) -ForegroundColor $color
}

$allChecksPassed = -not ($checks.Values -contains $false)

Write-Host ""
Write-Host "  Note (PowerShell participants):" -ForegroundColor Yellow
Write-Host "    - Activate venv:   .\venv\Scripts\Activate.ps1"
Write-Host "    - Replace wget:    Invoke-WebRequest -Uri URL -OutFile filename"
Write-Host "    - Or install wget: winget install GnuWin32.Wget"
Write-Host ""
Write-Host "  Troubleshooting:" -ForegroundColor White
Write-Host "    python not found       -> check PATH or use python3"
Write-Host "    No module named torch  -> run .\venv\Scripts\Activate.ps1"
Write-Host "    CUDA out of memory     -> add --batch-size 16 or remove -UseCuda"
Write-Host "    prepare_data.py fails  -> check internet, dataset is ~5 GB"
Write-Host ""

Complete-Setup -ChecklistPassed:$allChecksPassed
