#!/usr/bin/env bash
# ==============================================================
# Script 3 (WSL/Bash): Trainer setup for the pizza-ml lab
#                       environment (Option A — WSL2 / Linux)
# ==============================================================
# BEGIN_HELP
# Usage:
#   bash 03-setup-pizza-ml-trainer.sh [OPTIONS]
#
# Options:
#   --repo-url  URL    Git URL of the pizza-ml repo (required if
#                      project dir does not already exist)
#   --project-dir DIR  Where to clone/find the project
#                      (default: $HOME/Learning/pizza-ml)
#   --cuda             Install CUDA (GPU) build of PyTorch
#                      instead of CPU build
#   --skip-data        Skip Food-101 download (data already exists)
#   --skip-test        Skip the quick training smoke-test
#   --resume           Resume from the last saved checkpoint
#   --reset-checkpoint Remove the saved checkpoint before running
#   -h, --help         Show this help message
# --------------------------------------------------------------
# Example:
#   bash 03-setup-pizza-ml-trainer.sh --repo-url https://github.com/example/pizza-ml
#   bash 03-setup-pizza-ml-trainer.sh --cuda --skip-data
# END_HELP

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────
REPO_URL=""
PROJECT_DIR="$HOME/Learning/pizza-ml"
USE_CUDA=false
SKIP_DATA=false
SKIP_TEST=false
RESUME=false
RESET_CHECKPOINT=false
CHECKPOINT_PATH="$HOME/.pizza-trainer/03-setup-pizza-ml-trainer.state"

# ─────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-url)    REPO_URL="$2";      shift 2 ;;
        --project-dir) PROJECT_DIR="$2";   shift 2 ;;
        --cuda)        USE_CUDA=true;       shift   ;;
        --skip-data)   SKIP_DATA=true;      shift   ;;
        --skip-test)   SKIP_TEST=true;      shift   ;;
        --resume)      RESUME=true;         shift   ;;
        --reset-checkpoint) RESET_CHECKPOINT=true; shift ;;
        --checkpoint-path) CHECKPOINT_PATH="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# BEGIN_HELP/,/^# END_HELP/p' "$0" | sed 's/^# \?//' | grep -v 'BEGIN_HELP\|END_HELP'
            exit 0
            ;;
        *) echo "[FAIL] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
RESET='\033[0m'

step()    { echo -e "\n${CYAN}==> $*${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
fail()    { echo -e "  ${RED}[FAIL]${RESET} $*"; }
info()    { echo -e "  ${GRAY}$*${RESET}"; }

checklist_pass() { echo -e "  ${GREEN}[x]${RESET} $*"; }
checklist_fail() { echo -e "  ${YELLOW}[ ]${RESET} $*"; }

VENV_PYTHON="$PROJECT_DIR/venv/bin/python"
VENV_PIP="$PROJECT_DIR/venv/bin/pip"
DATA_V1="$PROJECT_DIR/data/v1"
DATA_V2="$PROJECT_DIR/data/v2"

declare -A STEP_STATE=()

init_checkpoint_state() {
    STEP_STATE=()
}

save_checkpoint() {
    mkdir -p "$(dirname "$CHECKPOINT_PATH")"
    {
        printf 'PROJECT_DIR=%q\n' "$PROJECT_DIR"
        for key in "${!STEP_STATE[@]}"; do
            printf 'STEP_%s=%q\n' "$key" "${STEP_STATE[$key]}"
        done
    } > "$CHECKPOINT_PATH"
}

load_checkpoint() {
    init_checkpoint_state
    [[ -f "$CHECKPOINT_PATH" ]] || return 0
    while IFS='=' read -r raw_key raw_value; do
        [[ -n "$raw_key" ]] || continue
        value="${raw_value#\'}"
        value="${value%\'}"
        case "$raw_key" in
            PROJECT_DIR)
                CHECKPOINT_PROJECT_DIR="$value"
                ;;
            STEP_*)
                STEP_STATE["${raw_key#STEP_}"]="$value"
                ;;
        esac
    done < "$CHECKPOINT_PATH"
}

step_done() {
    [[ "${STEP_STATE[$1]:-0}" == "1" ]]
}

mark_step_done() {
    STEP_STATE["$1"]=1
    save_checkpoint
}

checkpoint_skip() {
    step "$1 (resume checkpoint)"
}

if $RESET_CHECKPOINT && [[ -f "$CHECKPOINT_PATH" ]]; then
    rm -f "$CHECKPOINT_PATH"
fi

CHECKPOINT_PROJECT_DIR=""
load_checkpoint

if $RESUME && [[ -n "$CHECKPOINT_PROJECT_DIR" && "$CHECKPOINT_PROJECT_DIR" != "$PROJECT_DIR" ]]; then
    warn "Checkpoint was created for $CHECKPOINT_PROJECT_DIR, not $PROJECT_DIR. Resetting checkpoint state for this run."
    init_checkpoint_state
fi

# ─────────────────────────────────────────────────────────────
# Phase 0 — System dependencies (apt)
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done system_dependencies; then
    checkpoint_skip "Skipping system dependency installation"
else
    step "Installing system dependencies (python3, pip, venv, wget)"

    if ! command -v python3 &>/dev/null || ! command -v pip3 &>/dev/null; then
        info "Running: sudo apt update && sudo apt install -y python3 python3-pip python3-venv wget"
        sudo apt update -qq && sudo apt install -y python3 python3-pip python3-venv wget
        ok "System packages installed"
    else
        ok "python3/pip3 already available"
    fi
    mark_step_done system_dependencies
fi

# ─────────────────────────────────────────────────────────────
# Phase 1 — Verify Python 3.10+
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done python_validated; then
    checkpoint_skip "Skipping Python validation"
else
    step "Checking Python version"

    if ! command -v python3 &>/dev/null; then
        fail "python3 not found after install attempt"
        exit 1
    fi

    raw_ver=$(python3 --version 2>&1)
    IFS='.' read -r maj min _ <<< "${raw_ver#Python }"
    if (( maj < 3 || (maj == 3 && min < 10) )); then
        fail "$raw_ver found — 3.10 or newer required"
        exit 1
    fi
    ok "$raw_ver"
    mark_step_done python_validated
fi

# ─────────────────────────────────────────────────────────────
# Phase 2 — Clone or copy the project
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done project_ready; then
    checkpoint_skip "Skipping project setup"
else
    step "Setting up project directory: $PROJECT_DIR"

    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Directory already exists — skipping clone: $PROJECT_DIR"
    elif [[ -z "$REPO_URL" ]]; then
        fail "No --repo-url specified and '$PROJECT_DIR' does not exist."
        echo "      Either pass --repo-url <url> or copy the project folder to: $PROJECT_DIR"
        exit 1
    else
        if ! command -v git &>/dev/null; then
            info "git not found — installing..."
            sudo apt install -y git
        fi
        info "Cloning $REPO_URL -> $PROJECT_DIR"
        git clone "$REPO_URL" "$PROJECT_DIR"
        ok "Repository cloned"
    fi
    mark_step_done project_ready
fi

cd "$PROJECT_DIR"

# ─────────────────────────────────────────────────────────────
# Phase 3 — Create Python virtual environment
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done venv_ready; then
    checkpoint_skip "Skipping virtual environment creation"
else
    step "Creating Python virtual environment"

    if [[ -f "$VENV_PYTHON" ]]; then
        warn "venv already exists — skipping creation"
    else
        python3 -m venv venv
        ok "Virtual environment created"
    fi

    ok "venv Python: $($VENV_PYTHON --version 2>&1)"
    mark_step_done venv_ready
fi

# ─────────────────────────────────────────────────────────────
# Phase 4 — Install PyTorch and dependencies
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done deps_installed; then
    checkpoint_skip "Skipping dependency installation"
else
    step "Installing PyTorch and dependencies"

    if $USE_CUDA; then
        TORCH_INDEX="https://download.pytorch.org/whl/cu124"
        info "Mode: CUDA (GPU) build"
    else
        TORCH_INDEX="https://download.pytorch.org/whl/cpu"
        info "Mode: CPU-only build (~200 MB)"
    fi

    info "pip install torch torchvision --index-url $TORCH_INDEX"
    "$VENV_PIP" install --quiet torch torchvision --index-url "$TORCH_INDEX"
    ok "torch + torchvision installed"

    info "pip install tqdm Pillow"
    "$VENV_PIP" install --quiet tqdm Pillow
    ok "tqdm + Pillow installed"

    if [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
        info "pip install -r requirements.txt"
        "$VENV_PIP" install --quiet -r requirements.txt \
            && ok "requirements.txt installed" \
            || warn "requirements.txt install had issues (non-fatal)"
    fi
    mark_step_done deps_installed
fi

# ─────────────────────────────────────────────────────────────
# Phase 5 — Verify the installation
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done verification_done; then
    checkpoint_skip "Skipping installation verification"
else
    step "Verifying installation"

    if [[ -f "$PROJECT_DIR/check_environment.py" ]]; then
        info "Running check_environment.py..."
        "$VENV_PYTHON" check_environment.py \
            && ok "check_environment.py passed" \
            || warn "check_environment.py reported issues"
    else
        warn "check_environment.py not found — skipping"
    fi

    info "Testing PyTorch import..."
    if ! torch_out=$("$VENV_PYTHON" -c \
        "import torch; print(f'PyTorch {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')" \
        2>&1); then
        fail "PyTorch import failed: $torch_out"
        exit 1
    fi
    echo -e "  ${GRAY}$torch_out${RESET}"
    ok "PyTorch import OK"
    mark_step_done verification_done
fi

# ─────────────────────────────────────────────────────────────
# Phase 6 — Prepare training data
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done data_prepared; then
    checkpoint_skip "Skipping data preparation"
elif $SKIP_DATA; then
    step "Skipping data preparation (--skip-data)"
    mark_step_done data_prepared
else
    step "Preparing Food-101 training data (~5 GB download, 5-10 min)"

    if [[ -d "$DATA_V1" && -d "$DATA_V2" ]]; then
        warn "data/v1 and data/v2 already exist — skipping prepare_data.py"
    else
        if [[ ! -f "$PROJECT_DIR/prepare_data.py" ]]; then
            fail "prepare_data.py not found in $PROJECT_DIR"
            exit 1
        fi
        "$VENV_PYTHON" prepare_data.py
        ok "Training data prepared"
    fi

    RAW_DIR="$PROJECT_DIR/data/_food101_raw"
    if [[ -d "$RAW_DIR" ]]; then
        info "Removing raw download: $RAW_DIR"
        rm -rf "$RAW_DIR"
        ok "Deleted data/_food101_raw (freed ~5 GB)"
    fi

    echo ""
    echo -e "  ${RESET}Data directory counts:"
    for split in v1/train/pizza v1/train/not_pizza v1/test/pizza v1/test/not_pizza \
                 v2/train/pizza v2/train/not_pizza v2/test/pizza v2/test/not_pizza; do
        dir="$PROJECT_DIR/data/$split"
        if [[ -d "$dir" ]]; then
            count=$(find "$dir" -maxdepth 1 -type f | wc -l)
            printf "  ${GRAY}  %-35s %s images${RESET}\n" "$split" "$count"
        else
            warn "Missing: data/$split"
        fi
    done
    mark_step_done data_prepared
fi

# ─────────────────────────────────────────────────────────────
# Phase 7 — Quick end-to-end training smoke-test
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done training_test_done; then
    checkpoint_skip "Skipping training smoke-test"
elif $SKIP_TEST; then
    step "Skipping training smoke-test (--skip-test)"
    mark_step_done training_test_done
else
    step "Running quick training smoke-test (2 epochs)"

    TRAIN_SCRIPT=""
    for candidate in "$PROJECT_DIR/train_tinyvgg.py" "$PROJECT_DIR/train-pizza-creation.py"; do
        if [[ -f "$candidate" ]]; then
            TRAIN_SCRIPT="$candidate"
            break
        fi
    done

    if [[ -z "$TRAIN_SCRIPT" ]]; then
        warn "No supported training script found — skipping smoke-test"
    else
        TRAIN_SCRIPT_NAME="$(basename "$TRAIN_SCRIPT")"
        TEST_MODEL="$PROJECT_DIR/test_run.pth"
        TEST_IMAGE="$PROJECT_DIR/test_pizza1.jpg"
        if [[ ! -f "$TEST_IMAGE" ]]; then
            TEST_IMAGE=$(find "$PROJECT_DIR/data" -path '*/test/pizza/*' -type f 2>/dev/null | head -n 1 || true)
        fi

        info "Training for 2 epochs on data/v1..."
        "$VENV_PYTHON" "$TRAIN_SCRIPT_NAME" --data-dir ./data/v1 --epochs 2 --output "$TEST_MODEL"
        ok "Training completed"

        if [[ -n "$TEST_IMAGE" && -f "$TEST_IMAGE" ]]; then
            info "Running prediction on $(basename "$TEST_IMAGE")..."
            "$VENV_PYTHON" "$TRAIN_SCRIPT_NAME" --predict "$TEST_IMAGE" --output "$TEST_MODEL" \
                && ok "Prediction succeeded" \
                || warn "Prediction returned non-zero exit code"
        else
            warn "No pizza sample image found — skipping prediction test"
        fi

        [[ -f "$TEST_MODEL" ]] && rm -f "$TEST_MODEL" && ok "Removed temporary $(basename "$TEST_MODEL")"
    fi
    mark_step_done training_test_done
fi

# ─────────────────────────────────────────────────────────────
# Phase 8 — Clean up for participant distribution
# ─────────────────────────────────────────────────────────────
if $RESUME && step_done cleanup_done; then
    checkpoint_skip "Skipping cleanup"
else
    step "Cleaning up model files for participant distribution"

    pth_files=("$PROJECT_DIR"/*.pth)
    if [[ ! -e "${pth_files[0]}" ]]; then
        ok "No .pth files found — directory is clean"
    else
        for f in "${pth_files[@]}"; do
            rm -f "$f"
            ok "Removed $(basename "$f")"
        done
    fi
    mark_step_done cleanup_done
fi

# ─────────────────────────────────────────────────────────────
# Final checklist
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN} Pre-Lab Checklist${RESET}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

check() {
    local label="$1"; shift
    if "$@" &>/dev/null 2>&1; then checklist_pass "$label"
    else                           checklist_fail "$label"
    fi
}

check "python3 3.10+ installed"         python3 -c "import sys; assert sys.version_info >= (3,10)"
check "Virtual environment exists"      test -f "$PROJECT_DIR/venv/bin/python"
check "PyTorch importable"              "$VENV_PYTHON" -c "import torch"
check "data/v1 exists"                  test -d "$PROJECT_DIR/data/v1"
check "data/v2 exists"                  test -d "$PROJECT_DIR/data/v2"
check "data/_food101_raw removed"       test ! -d "$PROJECT_DIR/data/_food101_raw"
check "No .pth model files present"     bash -c "ls '$PROJECT_DIR'/*.pth 2>/dev/null | wc -l | grep -q '^0$'"
if [[ -f "$PROJECT_DIR/train_tinyvgg.py" ]]; then
    check "exercise1.md present"        test -f "$PROJECT_DIR/exercise1.md"
    check "exercise2.md present"        test -f "$PROJECT_DIR/exercise2.md"
elif [[ -f "$PROJECT_DIR/train-pizza-creation.py" || -f "$PROJECT_DIR/train-pizza-finetuning.py" ]]; then
    check "train-pizza-creation.py present"   test -f "$PROJECT_DIR/train-pizza-creation.py"
    check "train-pizza-finetuning.py present" test -f "$PROJECT_DIR/train-pizza-finetuning.py"
fi

echo ""
echo -e "  ${YELLOW}Note (WSL participants):${RESET}"
echo "    - Activate venv:   source venv/bin/activate"
echo "    - Download images: wget 'URL' -O filename.jpg"
echo ""
echo -e "  ${RESET}Troubleshooting reference:"
echo "    python3: command not found  -> sudo apt install python3"
echo "    No module named torch       -> venv not active; run: source venv/bin/activate"
echo "    CUDA out of memory          -> add --batch-size 16 or omit --cuda"
echo "    prepare_data.py fails       -> check internet; dataset is ~5 GB"
echo ""
