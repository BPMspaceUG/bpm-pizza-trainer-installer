#!/usr/bin/env bash

set -euo pipefail

NO_PROMPT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: bash 00-preflight.sh [--no-prompt]

Reports setup prerequisites without changing the machine.
EOF
            exit 0
            ;;
        *)
            echo "[FAIL] Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

step() { echo -e "\n${CYAN}==> $*${RESET}"; }
ok() { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $*"; }

declare -a WARNINGS=()
declare -a BLOCKING=()

recommended_free_gb=30
blocking_free_gb=20

has_command() {
    command -v "$1" >/dev/null 2>&1
}

check_endpoint() {
    local url="$1"

    if has_command curl; then
        curl -fsSI --max-time 5 "$url" >/dev/null 2>&1
    elif has_command wget; then
        wget --spider --timeout=5 "$url" >/dev/null 2>&1
    else
        return 2
    fi
}

step "Collecting platform information"

kernel="$(uname -s)"
ok "Detected platform: $kernel"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "Detected distribution: ${PRETTY_NAME:-${ID:-unknown}}"
elif [[ "$kernel" == "Darwin" ]]; then
    if has_command sw_vers; then
        ok "Detected macOS: $(sw_vers -productVersion)"
    fi
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "Running inside WSL"
fi

if [[ "$kernel" != "Darwin" ]]; then
    free_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
    free_gb="$((free_kb / 1024 / 1024))"
else
    free_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
    free_gb="$((free_kb / 1024 / 1024))"
fi

if (( free_gb < blocking_free_gb )); then
    BLOCKING+=("Only ${free_gb} GB free under $HOME. At least ${blocking_free_gb} GB is required to avoid unstable training setup behavior.")
    fail "Low disk space under $HOME: ${free_gb} GB free"
elif (( free_gb < recommended_free_gb )); then
    WARNINGS+=("Only ${free_gb} GB free under $HOME. ${recommended_free_gb} GB or more is strongly recommended.")
    warn "Disk space is lower than recommended under $HOME: ${free_gb} GB free"
else
    ok "Disk space looks sufficient under $HOME: ${free_gb} GB free"
fi

step "Checking required commands"

for cmd in git python3 bash curl zip; do
    if has_command "$cmd"; then
        ok "Found command: $cmd"
    else
        case "$cmd" in
            git)
                WARNINGS+=("git is missing. Repository cloning and updates will fail until Git is installed.")
                ;;
            python3)
                WARNINGS+=("python3 is missing. Script 03 cannot prepare the trainer environment until Python 3.10+ is installed.")
                ;;
            bash)
                BLOCKING+=("bash is missing. The shell setup flow cannot run without bash.")
                ;;
            curl)
                WARNINGS+=("curl is missing. Some network checks and remote installer paths will be limited.")
                ;;
            zip)
                WARNINGS+=("zip is missing. Install it with your package manager (e.g. sudo apt-get install zip).")
                ;;
        esac
        warn "Missing command: $cmd"
    fi
done

pkg_mgr_found=0
for pkg_mgr in apt-get dnf brew; do
    if has_command "$pkg_mgr"; then
        ok "Found package manager: $pkg_mgr"
        pkg_mgr_found=1
    fi
done

if [[ "$pkg_mgr_found" -eq 0 ]]; then
    WARNINGS+=("No supported package manager was found. Package installation will be limited.")
    warn "No supported package manager found"
fi

if has_command code; then
    ok "Found command: code"
else
    WARNINGS+=("VS Code CLI (code) is missing. Extension installation will need to be done manually.")
    warn "Missing command: code"
fi

step "Checking network reachability"

for endpoint in https://github.com https://download.pytorch.org; do
    if check_endpoint "$endpoint"; then
        ok "Reachable: $endpoint"
    else
        WARNINGS+=("Could not reach $endpoint. Package, repo, or model dependency setup may fail without internet access.")
        warn "Unreachable: $endpoint"
    fi
done

step "Preflight summary"

if [[ ${#WARNINGS[@]} -eq 0 && ${#BLOCKING[@]} -eq 0 ]]; then
    ok "No issues detected"
    exit 0
fi

for item in "${WARNINGS[@]}"; do
    warn "$item"
done

for item in "${BLOCKING[@]}"; do
    fail "$item"
done

if [[ ${#BLOCKING[@]} -gt 0 ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        echo ""
        read -rp "Blocking issues detected. Continue anyway? [y/N] " response
        if [[ "${response,,}" == y* ]]; then
            warn "Continuing despite blocking issues"
            exit 0
        fi
    fi
    exit 1
fi

exit 0