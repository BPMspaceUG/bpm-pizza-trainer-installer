#!/usr/bin/env bash
# 00-setup.sh — Pizza Trainer master setup (Linux / WSL2 / macOS)
#
# Supports: Ubuntu/Debian (apt), Fedora/RHEL (dnf), WSL2, macOS (Homebrew)
# Usage:    bash 00-setup.sh [--skip-preflight]
#
# pnpm is a Node.js package — it is installed via: npm install -g pnpm
# (not via apt/dnf/brew). This script handles that automatically.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNING_DIR="$HOME/Learning"
SKIP_PREFLIGHT=0
ACTION=""
REMOVE_MODULES=0
GIT_CLEAN=0
REINSTALL=0
REMOVE_PYTHON_ENV=0
REMOVE_REPOS=0
DRY_RUN=0
PIZZA_REPO_URL=""
NONINTERACTIVE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-preflight)
            SKIP_PREFLIGHT=1
            shift
            ;;
        --action)
            ACTION="$2"
            NONINTERACTIVE=1
            shift 2
            ;;
        --remove-modules)
            REMOVE_MODULES=1
            shift
            ;;
        --git-clean)
            GIT_CLEAN=1
            shift
            ;;
        --reinstall)
            REINSTALL=1
            shift
            ;;
        --remove-python-env)
            REMOVE_PYTHON_ENV=1
            shift
            ;;
        --remove-repos)
            REMOVE_REPOS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --pizza-repo-url)
            PIZZA_REPO_URL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash 00-setup.sh [--skip-preflight] [--action <name>]"
            exit 0
            ;;
        *)
            echo "[FAIL] Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Repos: "url|destination|run_install_sh|setup_script|prompt_url"
# prompt_url=1 means ask for URL at runtime if not cloned (e.g. pizza-ml)
REPOS=(
    "https://github.com/BPMspaceUG/bpm-CodingAgentConfigCopy|$LEARNING_DIR/bpm-CodingAgentConfigCopy|1||0"
    "https://github.com/BPMspaceUG/bpm-pizza-ml|$LEARNING_DIR/pizza-ml|0|03-setup-pizza-ml-trainer.sh|0"
)

# ─────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
RESET='\033[0m'

log_step() { echo -e "\n${CYAN}==> $1${RESET}"; }
log_ok()   { echo -e "  ${GREEN}[OK]   $1${RESET}"; }
log_warn() { echo -e "  ${YELLOW}[WARN] $1${RESET}"; }
log_fail() { echo -e "  ${RED}[FAIL] $1${RESET}"; }
log_info() { echo -e "  ${GRAY}[INFO] $1${RESET}"; }

SETUP_FAILURES=()

reset_failures() {
    SETUP_FAILURES=()
}

record_failure() {
    local message="$1"
    SETUP_FAILURES+=("$message")
    log_warn "$message"
}

show_run_summary() {
    local label="$1"
    if [ ${#SETUP_FAILURES[@]} -eq 0 ]; then
        log_ok "$label completed without recorded failures."
        return 0
    fi

    log_warn "$label completed with ${#SETUP_FAILURES[@]} recorded issue(s)."
    for item in "${SETUP_FAILURES[@]}"; do
        echo "    - $item"
    done
    return 1
}

# ─────────────────────────────────────────────────────────────
# Platform & package manager detection
# ─────────────────────────────────────────────────────────────
PLATFORM="linux"
PKG_MGR="none"
OS_ID=""

detect_platform() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        PLATFORM="macos"
        OS_ID="macos"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        PLATFORM="wsl2"
        if [ -f /etc/os-release ]; then
            OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
            PLATFORM="wsl2-${OS_ID}"
        fi
    elif [ -f /etc/os-release ]; then
        OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
        PLATFORM="linux-${OS_ID}"
    fi
    log_info "Platform detected: $PLATFORM"
}

ensure_homebrew() {
    if command -v brew &>/dev/null; then
        return 0
    fi
    log_warn "Homebrew not found."
    read -rp "  Install Homebrew now? [Y/n] " answer
    if [[ "${answer,,}" != n* ]]; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Add brew to PATH for Apple Silicon Macs
        if [ -f /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    else
        log_warn "Homebrew is required on macOS. Package installs will be skipped."
        return 1
    fi
}

detect_pkg_manager() {
    if [[ "$PLATFORM" == "macos" ]]; then
        ensure_homebrew && PKG_MGR="brew" || PKG_MGR="none"
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        log_warn "No supported package manager found (apt/dnf/brew). Package installs will be limited."
    fi
    log_info "Package manager: $PKG_MGR"
}

# ─────────────────────────────────────────────────────────────
# Package definitions
# Format: "WingetID|check_cmd|display_name|linux_method|brew_method"
#
# linux_method / brew_method values:
#   pkg:<apt>:<dnf>         — native package (linux only)
#   formula:<name>          — brew install <name> (macOS only)
#   cask:<name>             — brew install --cask <name> (macOS only)
#   npm:<package>           — npm install -g <package> (all platforms)
#   special:<name>          — custom install function
#   skip:<reason>           — not available on this platform
# ─────────────────────────────────────────────────────────────
PACKAGE_DEFS=(
    "Git.Git|git|Git|pkg:git:git|formula:git"
    "Python.Python.3.12|python3|Python 3.12|pkg:python3:python3|formula:python@3.12"
    "OpenJS.NodeJS.LTS|node|Node.js LTS|special:nodejs|formula:node"
    "Microsoft.VisualStudioCode|code|VS Code|special:vscode|cask:visual-studio-code"
    "Tailscale.Tailscale|tailscale|Tailscale|special:tailscale|cask:tailscale"
    "Docker.DockerDesktop|docker|Docker Desktop|special:docker|cask:docker"
    "Microsoft.PowerShell|pwsh|PowerShell|special:powershell|cask:powershell"
    "Anthropic.ClaudeCode|claude|Claude Code (CLI)|npm:@anthropic-ai/claude-code|npm:@anthropic-ai/claude-code"
    "OpenAI.Codex|codex|OpenAI Codex (CLI)|npm:@openai/codex|npm:@openai/codex"
    "Google.Chrome|google-chrome|Google Chrome|special:chrome|cask:google-chrome"
    "Anthropic.Claude|claude-app|Claude Desktop|skip:Desktop app not available on Linux/WSL|cask:claude"
    "Google.Antigravity|antigravity|Google Antigravity|pkg:antigravity:antigravity|formula:antigravity"
)

# pnpm is handled separately — it's an npm global, not a system package

# ─────────────────────────────────────────────────────────────
# Install helpers
# ─────────────────────────────────────────────────────────────
pkg_install() {
    # args: apt_name dnf_name
    case "$PKG_MGR" in
        apt)  sudo apt-get install -y "$1" ;;
        dnf)  sudo dnf install -y "$2" ;;
        *)    log_warn "pkg_install: no package manager available for $1" ; return 1 ;;
    esac
}

brew_install() {
    # args: type(formula|cask) name
    local type="$1" name="$2"
    if [ "$type" = "cask" ]; then
        brew install --cask "$name"
    else
        brew install "$name"
    fi
}

install_nodejs() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install formula node
        return
    fi
    log_info "Installing Node.js LTS via NodeSource..."
    if [ "$PKG_MGR" = "apt" ]; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    elif [ "$PKG_MGR" = "dnf" ]; then
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
        sudo dnf install -y nodejs
    else
        log_warn "Cannot install Node.js — no supported package manager."
        return 1
    fi
}

install_vscode() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install cask visual-studio-code
        return
    fi
    log_info "Installing VS Code..."
    if [ "$PKG_MGR" = "apt" ]; then
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor \
            | sudo install -D -o root -g root -m 644 /dev/stdin /etc/apt/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" \
            | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
        sudo apt-get update && sudo apt-get install -y code
    elif [ "$PKG_MGR" = "dnf" ]; then
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
            | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
        sudo dnf install -y code
    fi
}

install_tailscale() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install cask tailscale
        return
    fi
    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
}

install_docker() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install cask docker
        log_info "Launch Docker Desktop from Applications to complete setup."
        return
    fi
    log_info "Installing Docker CE..."
    curl -fsSL https://get.docker.com | sh
    if command -v systemctl &>/dev/null; then
        sudo systemctl enable --now docker 2>/dev/null || true
    fi
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    log_info "You may need to log out and back in for docker group to take effect."
}

install_powershell() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install cask powershell
        return
    fi
    log_info "Installing PowerShell..."
    if [ "$PKG_MGR" = "apt" ]; then
        local version
        version="$(. /etc/os-release && echo "${VERSION_ID}")"
        wget -q "https://packages.microsoft.com/config/ubuntu/${version}/packages-microsoft-prod.deb" \
            -O /tmp/packages-microsoft-prod.deb
        sudo dpkg -i /tmp/packages-microsoft-prod.deb
        rm -f /tmp/packages-microsoft-prod.deb
        sudo apt-get update && sudo apt-get install -y powershell
    elif [ "$PKG_MGR" = "dnf" ]; then
        curl -s https://packages.microsoft.com/config/rhel/8/prod.repo \
            | sudo tee /etc/yum.repos.d/microsoft.repo > /dev/null
        sudo dnf install -y powershell
    fi
}

install_chrome() {
    if [[ "$PLATFORM" == "macos" ]]; then
        brew_install cask google-chrome
        return
    fi
    log_info "Installing Google Chrome..."
    if [ "$PKG_MGR" = "apt" ]; then
        wget -qO /tmp/chrome.deb \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        sudo apt-get install -y /tmp/chrome.deb
        rm -f /tmp/chrome.deb
    elif [ "$PKG_MGR" = "dnf" ]; then
        sudo dnf install -y \
            https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    fi
}

install_npm_global() {
    local pkg="$1"
    if ! command -v npm &>/dev/null; then
        log_warn "npm not found — install Node.js first, then run: npm install -g $pkg"
        return 1
    fi
    log_info "Running: npm install -g $pkg"
    npm install -g "$pkg"
}

verify_pizza_ml_venv() {
    local project_dir="$1"
    local venv_py="$project_dir/venv/bin/python"
    local all_ok=0

    echo ""
    echo -e "  ${WHITE}Pizza-ML venv verification:${RESET}"

    _venv_check() {
        local label="$1"; shift
        if "$@" &>/dev/null 2>&1; then
            echo -e "  ${GREEN}[x] $label${RESET}"
        else
            echo -e "  ${YELLOW}[ ] $label${RESET}"
            all_ok=1
        fi
    }

    _venv_check "venv exists"       test -d "$project_dir/venv"
    _venv_check "venv python"       test -f "$venv_py"
    _venv_check "data/v1 exists"    test -d "$project_dir/data/v1"
    _venv_check "data/v2 exists"    test -d "$project_dir/data/v2"

    if [ -f "$venv_py" ]; then
        local py_ver
        py_ver="$("$venv_py" --version 2>&1)"
        _venv_check "Python version ($py_ver)" "$venv_py" -c "import sys; assert sys.version_info >= (3,10)"
        local torch_ver
        torch_ver="$("$venv_py" -c "import torch; print(torch.__version__)" 2>&1)"
        _venv_check "PyTorch importable ($torch_ver)" "$venv_py" -c "import torch"
    else
        echo -e "  ${YELLOW}[ ] Python version (venv not found)${RESET}"
        echo -e "  ${YELLOW}[ ] PyTorch importable (venv not found)${RESET}"
        all_ok=1
    fi

    if [ "$all_ok" -eq 0 ]; then
        log_ok "Pizza-ML venv is ready."
    else
        log_warn "Some venv checks failed — re-run script 03 or check output above."
    fi
    return $all_ok
}

ensure_pnpm() {
    if command -v pnpm &>/dev/null; then
        return 0
    fi
    log_info "pnpm not found — installing via npm (npm install -g pnpm)..."
    install_npm_global "pnpm"
}

# ─────────────────────────────────────────────────────────────
# Check if a package is installed
# ─────────────────────────────────────────────────────────────
is_installed() {
    local check_cmd="$1"
    [ -z "$check_cmd" ] && return 1
    command -v "$check_cmd" &>/dev/null
}

# ─────────────────────────────────────────────────────────────
# Menu
# ─────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo ""
    echo -e "  ${CYAN}+==========================================+"
    echo -e "  |   Pizza Trainer -- Environment Setup    |"
    echo -e "  +==========================================+"
    echo -e "  |                                         |"
    echo -e "  |  [1] Check installed packages           |"
    echo -e "  |  [2] Install missing packages           |"
    echo -e "  |  [3] Clone / update repos               |"
    echo -e "  |  [4] Run full setup  (1+2+3+scripts)    |"
    echo -e "  |  [5] Cleanup repos                      |"
    echo -e "  |  [6] Update installed packages          |"
    echo -e "  |  [7] Configure coding agents (OpenRouter)|"
    echo -e "  |  [Q] Quit                               |"
    echo -e "  |                                         |"
    echo -e "  +==========================================+${RESET}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Option 1 — Check packages
# ─────────────────────────────────────────────────────────────
MISSING_PACKAGES=()

check_packages() {
    log_step "Checking installed packages"
    MISSING_PACKAGES=()

    echo ""
    printf "  ${WHITE}%-44s %s${RESET}\n" "Package ID" "Status"
    printf "  ${GRAY}%-44s %s${RESET}\n"  "----------" "------"

    for def in "${PACKAGE_DEFS[@]}"; do
        local winget_id check_cmd linux_method brew_method active_method
        winget_id="$(echo "$def" | cut -d'|' -f1)"
        check_cmd="$(echo "$def" | cut -d'|' -f2)"
        linux_method="$(echo "$def" | cut -d'|' -f4)"
        brew_method="$(echo "$def" | cut -d'|' -f5)"

        # Pick the active method based on platform
        if [[ "$PKG_MGR" == "brew" ]]; then
            active_method="$brew_method"
        else
            active_method="$linux_method"
        fi

        if [[ "$active_method" == skip:* ]]; then
            printf "  ${GRAY}[--]  %-42s SKIP (%s)${RESET}\n" "$winget_id" "${active_method#skip:}"
        elif is_installed "$check_cmd"; then
            printf "  ${GREEN}[OK]  %-42s installed${RESET}\n" "$winget_id"
        else
            printf "  ${YELLOW}[--]  %-42s MISSING${RESET}\n" "$winget_id"
            MISSING_PACKAGES+=("$winget_id")
        fi
    done

    # Check pnpm separately (npm global, not a system package on any platform)
    echo ""
    echo -e "  ${GRAY}--- Node.js globals ---${RESET}"
    if command -v pnpm &>/dev/null; then
        printf "  ${GREEN}[OK]  %-42s installed${RESET}\n" "pnpm (npm global)"
    else
        printf "  ${YELLOW}[--]  %-42s MISSING (will install via npm)${RESET}\n" "pnpm (npm global)"
    fi

    echo ""
    if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
        log_ok "All packages are installed."
    else
        log_warn "${#MISSING_PACKAGES[@]} package(s) missing."
    fi
}

# ─────────────────────────────────────────────────────────────
# Option 2 — Install missing packages
# ─────────────────────────────────────────────────────────────
do_install_package() {
    local winget_id="$1"
    local linux_method="" brew_method="" method=""

    for def in "${PACKAGE_DEFS[@]}"; do
        if [[ "$(echo "$def" | cut -d'|' -f1)" == "$winget_id" ]]; then
            linux_method="$(echo "$def" | cut -d'|' -f4)"
            brew_method="$(echo "$def"  | cut -d'|' -f5)"
            break
        fi
    done

    if [[ "$PKG_MGR" == "brew" ]]; then
        method="$brew_method"
    else
        method="$linux_method"
    fi

    case "$method" in
        skip:*)
            log_warn "Skipping $winget_id: ${method#skip:}"
            ;;
        pkg:*:*)
            local apt_pkg dnf_pkg
            apt_pkg="$(echo "${method#pkg:}" | cut -d: -f1)"
            dnf_pkg="$(echo "${method#pkg:}" | cut -d: -f2)"
            pkg_install "$apt_pkg" "$dnf_pkg"
            ;;
        formula:*)
            brew_install formula "${method#formula:}"
            ;;
        cask:*)
            brew_install cask "${method#cask:}"
            ;;
        special:nodejs)     install_nodejs ;;
        special:vscode)     install_vscode ;;
        special:tailscale)  install_tailscale ;;
        special:docker)     install_docker ;;
        special:powershell) install_powershell ;;
        special:chrome)     install_chrome ;;
        npm:*)
            install_npm_global "${method#npm:}"
            ;;
        *)
            log_warn "No install method defined for $winget_id — skipping"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# Option 6 — Update installed packages
# ─────────────────────────────────────────────────────────────
#
# Updates are driven strictly from PACKAGE_DEFS, never a blanket
# "upgrade everything on this machine" — the installer only touches
# what it installed.
pkg_upgrade() {
    # args: apt_name dnf_name
    case "$PKG_MGR" in
        apt)  sudo apt-get install -y --only-upgrade "$1" ;;
        dnf)  sudo dnf upgrade -y "$2" ;;
        *)    log_warn "pkg_upgrade: no package manager available for $1" ; return 1 ;;
    esac
}

brew_upgrade() {
    # args: type(formula|cask) name
    local type="$1" name="$2"
    if [ "$type" = "cask" ]; then
        brew upgrade --cask "$name" 2>&1 | grep -v "already installed" || true
    else
        brew upgrade "$name" 2>&1 | grep -v "already installed" || true
    fi
}

do_update_package() {
    local winget_id="$1" method="$2"

    case "$method" in
        skip:*)
            log_warn "Skipping $winget_id: ${method#skip:}"
            ;;
        pkg:*:*)
            local apt_pkg dnf_pkg
            apt_pkg="$(echo "${method#pkg:}" | cut -d: -f1)"
            dnf_pkg="$(echo "${method#pkg:}" | cut -d: -f2)"
            pkg_upgrade "$apt_pkg" "$dnf_pkg"
            ;;
        formula:*)
            brew_upgrade formula "${method#formula:}"
            ;;
        cask:*)
            brew_upgrade cask "${method#cask:}"
            ;;
        # The special installers all fetch the current release, so re-running
        # them IS the update path.
        special:nodejs)     install_nodejs ;;
        special:vscode)     install_vscode ;;
        special:tailscale)  install_tailscale ;;
        special:docker)     install_docker ;;
        special:powershell) install_powershell ;;
        special:chrome)     install_chrome ;;
        npm:*)
            install_npm_global "${method#npm:}@latest"
            ;;
        *)
            log_warn "No update method defined for $winget_id — skipping"
            ;;
    esac
}

update_packages() {
    log_step "Updating installed packages"

    local updated=0 skipped=0

    for def in "${PACKAGE_DEFS[@]}"; do
        local winget_id check_cmd linux_method brew_method active_method
        winget_id="$(echo "$def" | cut -d'|' -f1)"
        check_cmd="$(echo "$def" | cut -d'|' -f2)"
        linux_method="$(echo "$def" | cut -d'|' -f4)"
        brew_method="$(echo "$def" | cut -d'|' -f5)"

        if [[ "$PKG_MGR" == "brew" ]]; then
            active_method="$brew_method"
        else
            active_method="$linux_method"
        fi

        # Not available on this platform at all — never suggest installing it.
        if [[ "$active_method" == skip:* ]]; then
            log_info "$winget_id not available on this platform: ${active_method#skip:}"
            skipped=$((skipped + 1))
            continue
        fi

        # Only update what is actually present — updating a missing package
        # would silently turn this into an install.
        if ! is_installed "$check_cmd"; then
            log_info "$winget_id not installed — skipping (use option [2] to install)"
            skipped=$((skipped + 1))
            continue
        fi

        # On WSL several tools are provided by the Windows host rather than the
        # distro — Docker Desktop's integration puts its CLI at
        # /mnt/wsl/docker-desktop/..., for example. Those binaries resolve under
        # /mnt/, and running the Linux installer for them would build a second,
        # competing copy inside the distro. Update them on Windows instead.
        local resolved
        resolved="$(command -v "$check_cmd" 2>/dev/null || true)"
        [ -n "$resolved" ] && resolved="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
        case "$resolved" in
            /mnt/*)
                log_info "$winget_id comes from the Windows host ($resolved) — update it there, skipping."
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        if [ "$DRY_RUN" = "1" ]; then
            log_info "[dry-run] would update $winget_id via ${active_method}"
            updated=$((updated + 1))
            continue
        fi

        log_step "Updating $winget_id"
        if do_update_package "$winget_id" "$active_method"; then
            log_ok "$winget_id up to date."
            updated=$((updated + 1))
        else
            record_failure "$winget_id update may have failed — check output above."
        fi
    done

    # pnpm (npm global, all platforms)
    if command -v pnpm &>/dev/null; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "[dry-run] would update pnpm via npm install -g pnpm@latest"
        else
            log_step "Updating pnpm (npm global)"
            install_npm_global "pnpm@latest"
        fi
    else
        log_info "pnpm not installed — skipping"
        skipped=$((skipped + 1))
    fi

    echo ""
    log_info "Update pass complete: $updated updated, $skipped skipped (not installed, unavailable, or Windows-managed)."

    # The OpenRouter balance check runs on update too, so a trainee finds out
    # their credit ran dry here rather than mid-exercise.
    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        echo ""
        log_step "Checking OpenRouter balance"
        openrouter_check_key "$OPENROUTER_API_KEY" || \
            log_warn "OpenRouter key is missing or invalid — re-run option [7] to fix."
    fi
}

# ─────────────────────────────────────────────────────────────
# Option 7 — Coding agents via OpenRouter
# ─────────────────────────────────────────────────────────────
#
# One OpenRouter key drives both CLIs. OpenRouter serves an
# Anthropic-compatible /messages endpoint (Claude Code) and an
# OpenAI Responses endpoint /responses (Codex), so neither CLI
# needs a shim.
OPENROUTER_BASE_URL="https://openrouter.ai/api/v1"
OPENROUTER_CLAUDE_MODEL="deepseek/deepseek-v4-pro"
OPENROUTER_CODEX_MODEL="z-ai/glm-5.2"

# Validate a key and print the account balance.
# Returns 0 when the key is accepted, 1 otherwise.
openrouter_check_key() {
    local key="$1" body http

    body="$(curl -s -m 20 -w $'\n%{http_code}' \
        "$OPENROUTER_BASE_URL/credits" \
        -H "Authorization: Bearer $key" 2>/dev/null)" || {
        log_warn "Could not reach OpenRouter to validate the key (network problem?)."
        return 1
    }

    http="$(printf '%s' "$body" | tail -n1)"
    body="$(printf '%s' "$body" | sed '$d')"

    if [ "$http" != "200" ]; then
        log_warn "OpenRouter rejected the key (HTTP $http)."
        return 1
    fi

    log_ok "OpenRouter key is valid."

    # Field names are not pinned by us — print what we recognise, and fall
    # back to the raw payload so the trainee always sees the balance.
    python3 - "$body" <<'PY' 2>/dev/null || echo "  Balance response: $body"
import json, sys
d = json.loads(sys.argv[1])
d = d.get("data", d)
total = d.get("total_credits", d.get("limit"))
used  = d.get("total_usage", d.get("usage"))
if total is not None and used is not None:
    print(f"  Credits purchased: ${float(total):.2f}")
    print(f"  Credits used:      ${float(used):.2f}")
    print(f"  Remaining:         ${float(total) - float(used):.2f}")
elif used is not None:
    print(f"  Credits used: ${float(used):.2f} (no limit set — pay-as-you-go)")
else:
    print(f"  Balance response: {json.dumps(d)}")
PY
    return 0
}

# Prompt for a key until one validates, or the trainee gives up.
openrouter_prompt_key() {
    local key
    while true; do
        echo "" >&2
        echo -e "  ${CYAN}Get a key at https://openrouter.ai/keys${RESET}" >&2
        read -rp "  Paste your OpenRouter API key (blank to skip): " key
        if [ -z "$key" ]; then
            return 1
        fi
        if openrouter_check_key "$key" >&2; then
            printf '%s' "$key"
            return 0
        fi
        log_warn "That key did not work — try again, or press Enter to skip." >&2
    done
}

# Persist the key so Codex (which reads it via env_key) can find it.
openrouter_persist_key() {
    local key="$1" profile="$HOME/.bashrc"
    [ -n "${ZSH_VERSION:-}" ] && profile="$HOME/.zshrc"

    if grep -q '^export OPENROUTER_API_KEY=' "$profile" 2>/dev/null; then
        # Replace in place; use a non-/ delimiter since keys contain no '|'
        sed -i "s|^export OPENROUTER_API_KEY=.*|export OPENROUTER_API_KEY='$key'|" "$profile"
    else
        printf "\n# Added by pizza-trainer setup\nexport OPENROUTER_API_KEY='%s'\n" "$key" >> "$profile"
    fi
    export OPENROUTER_API_KEY="$key"
    log_ok "Key saved to $profile (open a new shell to pick it up)."
}

# Merge the OpenRouter env block into ~/.claude/settings.json without
# discarding any settings the trainee already has.
openrouter_configure_claude() {
    local key="$1" dir="$HOME/.claude"
    mkdir -p "$dir"

    OR_KEY="$key" OR_URL="$OPENROUTER_BASE_URL" OR_MODEL="$OPENROUTER_CLAUDE_MODEL" \
    python3 - "$dir/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError
except (FileNotFoundError, ValueError, json.JSONDecodeError):
    cfg = {}
env = cfg.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = os.environ["OR_URL"]
env["ANTHROPIC_AUTH_TOKEN"] = os.environ["OR_KEY"]
env["ANTHROPIC_MODEL"] = os.environ["OR_MODEL"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
    if [ $? -eq 0 ]; then
        log_ok "Claude Code configured ($OPENROUTER_CLAUDE_MODEL)."
    else
        record_failure "Could not write $dir/settings.json"
    fi
}

# Codex reads the key from the env var named by env_key, so the secret
# stays out of config.toml.
openrouter_configure_codex() {
    local dir="$HOME/.codex" file
    file="$dir/config.toml"
    mkdir -p "$dir"

    if [ -f "$file" ] && ! grep -q 'model_providers.openrouter' "$file"; then
        cp "$file" "$file.bak"
        log_info "Existing config.toml backed up to config.toml.bak"
    fi

    cat > "$file" <<EOF
# Written by pizza-trainer setup — Codex via OpenRouter
model = "$OPENROUTER_CODEX_MODEL"
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "$OPENROUTER_BASE_URL"
env_key = "OPENROUTER_API_KEY"
EOF
    log_ok "Codex configured ($OPENROUTER_CODEX_MODEL)."
}

setup_openrouter_agents() {
    log_step "Configuring coding agents via OpenRouter"

    local key="${OPENROUTER_API_KEY:-}"

    if [ -n "$key" ]; then
        log_info "Found an OpenRouter key in the environment — validating..."
        if ! openrouter_check_key "$key"; then
            log_warn "The existing key is no longer valid."
            key=""
        fi
    else
        log_info "No OpenRouter key found in the environment."
    fi

    if [ -z "$key" ]; then
        if [ "$NONINTERACTIVE" -eq 1 ]; then
            record_failure "No valid OpenRouter key and running non-interactively — skipping agent config."
            return 1
        fi
        key="$(openrouter_prompt_key)" || {
            log_warn "Skipped — coding agents left unconfigured."
            return 1
        }
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log_info "[dry-run] would configure Claude Code ($OPENROUTER_CLAUDE_MODEL) and Codex ($OPENROUTER_CODEX_MODEL)"
        return 0
    fi

    openrouter_persist_key "$key"
    openrouter_configure_claude "$key"
    openrouter_configure_codex
}

install_missing() {
    # Refresh package list
    check_packages

    if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
        log_ok "All packages already installed."
    else
        echo ""
        echo -e "  ${YELLOW}${#MISSING_PACKAGES[@]} package(s) to install:${RESET}"
        for id in "${MISSING_PACKAGES[@]}"; do
            echo "    - $id"
        done
        echo ""
        read -rp "  Install all missing packages? [Y/n] " answer
        if [[ "${answer,,}" != n* ]]; then
            for id in "${MISSING_PACKAGES[@]}"; do
                log_step "Installing $id"
                if do_install_package "$id"; then
                    log_ok "$id installed."
                else
                    record_failure "$id installation may have failed — check output above."
                fi
            done
        else
            log_warn "Package installation skipped."
        fi
    fi

    # Always ensure pnpm (npm global on all platforms)
    ensure_pnpm
}

# ─────────────────────────────────────────────────────────────
# Option 3 — Clone / update repos
# ─────────────────────────────────────────────────────────────
detect_repo_pkg_manager() {
    local dir="$1"
    [ -f "$dir/pnpm-lock.yaml" ]    && echo "pnpm" && return
    [ -f "$dir/yarn.lock" ]          && echo "yarn" && return
    [ -f "$dir/package-lock.json" ]  && echo "npm"  && return
    [ -f "$dir/package.json" ]       && echo "npm"  && return
    echo ""
}

sync_repos() {
    log_step "Cloning / updating repositories"

    mkdir -p "$LEARNING_DIR"

    for entry in "${REPOS[@]}"; do
        local url dir name run_install_sh setup_script prompt_url
        IFS='|' read -r url dir run_install_sh setup_script prompt_url <<< "$entry"
        name="$(basename "$dir")"

        echo ""
        echo -e "  ${WHITE}$name${RESET}"

        # Resolve URL — may need to prompt (e.g. pizza-ml)
        if [ -z "$url" ] && [ ! -d "$dir/.git" ]; then
            if [ "$prompt_url" = "1" ]; then
                if [ -n "$PIZZA_REPO_URL" ]; then
                    url="$PIZZA_REPO_URL"
                elif [ "$NONINTERACTIVE" = "1" ]; then
                    log_warn "$name has no URL and action mode is non-interactive — skipping"
                    continue
                else
                    read -rp "  Enter Git URL for $name (or press Enter to skip): " url
                fi
                if [ -z "$url" ]; then
                    log_warn "$name has no URL — skipping"
                    continue
                fi
            else
                log_warn "$name has no URL configured — skipping"
                continue
            fi
        fi

        echo -e "  ${GRAY}$url${RESET}"

        if [ -d "$dir/.git" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "[dry-run] Would pull latest changes..."
            else
                log_info "Pulling latest changes..."
                if git -C "$dir" pull; then
                    log_ok "Updated: $dir"
                else
                    record_failure "$name: git pull failed — check for conflicts"
                fi
            fi
        else
            if [ "$DRY_RUN" = "1" ]; then
                log_info "[dry-run] Would clone repository..."
            else
                log_info "Cloning..."
                if git clone "$url" "$dir"; then
                    log_ok "Cloned to: $dir"
                else
                    log_fail "git clone failed — skipping install step"
                    record_failure "$name: git clone failed"
                    continue
                fi
            fi
        fi

        # Run install.sh if flagged (e.g. bpm-CodingAgentConfigCopy)
        if [ "$run_install_sh" = "1" ] && [ -f "$dir/install.sh" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "[dry-run] Would run install.sh..."
            else
                log_info "Running install.sh..."
                if (cd "$dir" && bash install.sh); then
                    log_ok "install.sh completed in $name"
                else
                    record_failure "install.sh failed in $name"
                fi
            fi
        fi

        # Run setup script if configured (e.g. 03-setup-pizza-ml-trainer.sh for pizza-ml)
        if [ -n "$setup_script" ]; then
            local script_path="$SCRIPT_DIR/$setup_script"
            if [ -f "$script_path" ]; then
                if [ "$NONINTERACTIVE" = "1" ]; then
                    if [ "$DRY_RUN" = "1" ]; then
                        log_info "[dry-run] Would skip $setup_script in non-interactive action mode. Use pizza-trainer trainer separately."
                    else
                        log_info "Skipping $setup_script in non-interactive action mode. Use pizza-trainer trainer separately."
                    fi
                else
                read -rp "  Run $setup_script for $name now? [Y/n] " run_s
                if [[ "${run_s,,}" != n* ]]; then
                    read -rp "  Use CUDA (GPU) build of PyTorch? [y/N] " use_cuda
                    read -rp "  Skip Food-101 data download? [y/N] "      skip_data
                    read -rp "  Skip training smoke-test? [y/N] "          skip_test
                    local s_args=()
                    [ -n "$url" ]                            && s_args+=( "--repo-url" "$url" )
                    [[ "${use_cuda,,}"  == y* ]]             && s_args+=( "--cuda" )
                    [[ "${skip_data,,}" == y* ]]             && s_args+=( "--skip-data" )
                    [[ "${skip_test,,}" == y* ]]             && s_args+=( "--skip-test" )
                    log_step "Running $setup_script..."
                    if bash "$script_path" "${s_args[@]}"; then
                        :
                    else
                        setup_exit=$?
                        record_failure "$setup_script exited with code $setup_exit for $name"
                    fi
                    # Verify venv after setup script
                    if ! verify_pizza_ml_venv "$dir"; then
                        record_failure "$name: post-setup verification failed"
                    fi
                fi
                fi
            else
                record_failure "$setup_script not found in $SCRIPT_DIR"
            fi
        fi

        # Run JS package manager install if applicable
        local pm
        pm="$(detect_repo_pkg_manager "$dir")"
        if [ -n "$pm" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "[dry-run] Would run $pm install"
            else
                log_info "Detected package manager: $pm — running $pm install"
                if [ "$pm" = "pnpm" ]; then
                    ensure_pnpm
                fi
                if command -v "$pm" &>/dev/null; then
                    if (cd "$dir" && "$pm" install); then
                        log_ok "$pm install completed in $name"
                    else
                        record_failure "$pm install failed in $name"
                    fi
                else
                    record_failure "$pm not found on PATH — run '$pm install' manually in $dir"
                fi
            fi
        fi
    done
}

# ─────────────────────────────────────────────────────────────
# Script 02 / 02b equivalents — VS Code extensions and CAC (prompted separately)
# ─────────────────────────────────────────────────────────────
setup_vscode_extensions() {
    log_step "Installing VS Code AI extensions (script 02 equivalent)"

    if ! command -v code &>/dev/null; then
        record_failure "'code' not found on PATH — skipping VS Code extensions"
        log_info "Install VS Code first, then re-run this step."
        return
    fi

    local extensions=(
        'anthropic.claude-code'
        'openai.chatgpt'
        'ms-python.python'
        'ms-python.vscode-pylance'
        'google.geminicodeassist'
        'continue.continue'
        'GitHub.copilot'
        'GitHub.copilot-chat'
        'ms-toolsai.jupyter'
        'eamodio.gitlens'
        'VisualStudioExptTeam.vscodeintellicode'
        'ms-python.black-formatter'
        'pablodelucca.pixel-agents'
    )

    for ext in "${extensions[@]}"; do
        log_info "Installing $ext..."
        if code --install-extension "$ext" --force 2>/dev/null; then
            log_ok "$ext"
        else
            record_failure "$ext installation failed or could not be verified"
        fi
    done
}

setup_cac() {
    log_step "Setting up CAC (CodingAgentConfigCopy)"
    local cac_dir="$LEARNING_DIR/bpm-CodingAgentConfigCopy"

    if [ -f "$cac_dir/install.sh" ]; then
        log_info "Running install.sh from $cac_dir..."
        if (cd "$cac_dir" && bash install.sh); then
            log_ok "CAC installed."
        else
            record_failure "CAC install.sh failed — check output above."
        fi
    else
        log_info "bpm-CodingAgentConfigCopy not yet cloned — running via curl..."
        if curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | bash; then
            log_ok "CAC installed via curl."
        else
            record_failure "CAC curl install failed. Clone the repo first via option [3]."
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# Option 5 — Cleanup repos
# ─────────────────────────────────────────────────────────────
cleanup_repos() {
    echo ""
    echo -e "  ${WHITE}Cleanup options:${RESET}"
    echo -e "  ${CYAN}[1] Remove node_modules${RESET}"
    echo -e "  ${CYAN}[2] Remove node_modules + re-run install${RESET}"
    echo -e "  ${CYAN}[3] git clean -fd (remove untracked files)${RESET}"
    echo -e "  ${CYAN}[4] All of the above (JS repos)${RESET}"
    echo -e "  ${CYAN}[5] Remove Python venv + data/  (pizza-ml teardown)${RESET}"
    echo -e "  ${CYAN}[6] Delete cloned repos (full teardown)${RESET}"
    echo -e "  ${CYAN}[Q] Back${RESET}"
    echo ""
    read -rp "  Select option: " c

    local do_modules=0 do_reinstall=0 do_git=0 do_python=0 do_remove_repos=0
    case "${c^^}" in
        1) do_modules=1 ;;
        2) do_modules=1; do_reinstall=1 ;;
        3) do_git=1 ;;
        4) do_modules=1; do_reinstall=1; do_git=1 ;;
        5) do_python=1 ;;
        6) do_remove_repos=1 ;;
        Q) return ;;
        *) log_warn "Invalid option."; return ;;
    esac

    for entry in "${REPOS[@]}"; do
        cleanup_repo_entry "$entry" "$do_modules" "$do_reinstall" "$do_git" "$do_python" "$do_remove_repos"
    done
}

cleanup_repo_entry() {
    local entry="$1" do_modules="$2" do_reinstall="$3" do_git="$4" do_python="$5" do_remove_repos="$6"
    local url dir name
    IFS='|' read -r url dir _ _ _ <<< "$entry"
    name="$(basename "$dir")"
    if [ ! -d "$dir" ]; then log_warn "$name not found — skipping"; return; fi
    log_info "$name"

    if [ "$do_remove_repos" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "  [dry-run] Would remove cloned repository directory..."
        else
            log_info "  Removing cloned repository directory..."
            rm -rf "$dir"
            log_ok "  repository removed"
        fi
        return
    fi

    if [ "$do_modules" = "1" ]; then
        if [ -d "$dir/node_modules" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "  [dry-run] Would remove node_modules..."
            else
                log_info "  Removing node_modules..."
                rm -rf "$dir/node_modules"
                log_ok "  node_modules removed"
            fi
        else
            log_info "  node_modules not present"
        fi
    fi

    if [ "$do_python" = "1" ]; then
        if [ -d "$dir/venv" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "  [dry-run] Would remove venv/..."
            else
                log_info "  Removing venv/..."
                rm -rf "$dir/venv"
                log_ok "  venv removed"
            fi
        fi
        if [ -d "$dir/data" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log_info "  [dry-run] Would remove data/..."
            else
                log_info "  Removing data/..."
                rm -rf "$dir/data"
                log_ok "  data/ removed"
            fi
        fi
        local pth_count=0
        while IFS= read -r pth; do
            if [ "$DRY_RUN" = "1" ]; then
                log_info "  [dry-run] Would remove $(basename "$pth")"
            else
                rm -f "$pth"
                log_ok "  Removed $(basename "$pth")"
            fi
            pth_count=$((pth_count+1))
        done < <(find "$dir" -maxdepth 1 -name "*.pth" -type f 2>/dev/null)
        [ "$pth_count" -eq 0 ] && log_info "  No .pth files found"
    fi

    if [ "$do_git" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "  [dry-run] Would run git clean -fd..."
        else
            log_info "  Running git clean -fd..."
            git -C "$dir" clean -fd
        fi
        if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git -C "$dir" ls-files -- data 2>/dev/null)" ]; then
            if [ -d "$dir/data/_food101_raw" ]; then
                log_info "  Removing data/_food101_raw/..."
                rm -rf "$dir/data/_food101_raw"
                log_ok "  data/_food101_raw removed"
            fi
            log_info "  data/ contains tracked files — leaving repository data in place"
        else
            log_info "  Removing data/..."
            rm -rf "$dir/data"
            log_ok "  data/ removed"
        fi
    fi

    if [ "$do_reinstall" = "1" ]; then
        local pm
        pm="$(detect_repo_pkg_manager "$dir")"
        if [ -n "$pm" ]; then
            [ "$pm" = "pnpm" ] && ensure_pnpm
            if command -v "$pm" &>/dev/null; then
                if [ "$DRY_RUN" = "1" ]; then
                    log_info "  [dry-run] Would run $pm install..."
                else
                    log_info "  Running $pm install..."
                    if (cd "$dir" && "$pm" install); then
                        log_ok "  $pm install done"
                    else
                        log_warn "  $pm install failed"
                    fi
                fi
            else
                log_warn "  $pm not found on PATH"
            fi
        fi
    fi
}

show_repo_status() {
    log_step "Checking repositories"
    for entry in "${REPOS[@]}"; do
        local url dir name
        IFS='|' read -r url dir _ _ _ <<< "$entry"
        name="$(basename "$dir")"
        local status="Not cloned"
        if [ -d "$dir/.git" ]; then
            status="Cloned"
            if [[ "$name" == "pizza-ml" ]]; then
                if [ -f "$dir/venv/bin/python" ]; then
                    if "$dir/venv/bin/python" -c "import torch" &>/dev/null; then
                        status="Cloned | venv OK"
                    else
                        status="Cloned | venv no torch"
                    fi
                else
                    status="Cloned | venv missing"
                fi
            fi
        fi
        if [ -d "$dir/.git" ]; then
            echo -e "  ${GREEN}[OK]${RESET} $name"
        else
            echo -e "  ${YELLOW}[--]${RESET} $name"
        fi
        echo -e "       ${GRAY}$status${RESET}"
        echo -e "       ${GRAY}$dir${RESET}"
    done
}

install_missing_noninteractive() {
    check_packages
    if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
        log_ok "All packages already installed."
        return 0
    fi
    for id in "${MISSING_PACKAGES[@]}"; do
        log_step "Installing $id"
        if do_install_package "$id"; then
            log_ok "$id installed."
        else
            record_failure "$id installation failed"
        fi
    done
}

full_setup_noninteractive() {
    reset_failures
    echo ""
    echo -e "  ${CYAN}Running full environment setup...${RESET}"
    if [ "$DRY_RUN" = "1" ]; then
        check_packages
        if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
            log_ok "All packages already installed."
        else
            log_step "Dry-run package installation"
            for id in "${MISSING_PACKAGES[@]}"; do
                log_info "[dry-run] Would install $id"
            done
        fi
    else
        install_missing_noninteractive
    fi
    sync_repos
    show_run_summary "Full setup"
}

run_action_mode() {
    case "$ACTION" in
        packages-status)
            check_packages
            ;;
        packages-install)
            reset_failures
            install_missing_noninteractive
            show_run_summary "Package installation"
            ;;
        packages-update)
            reset_failures
            update_packages
            show_run_summary "Package update"
            ;;
        coding-agents-config)
            reset_failures
            setup_openrouter_agents
            show_run_summary "Coding agent setup"
            ;;
        repos-status)
            show_repo_status
            ;;
        repos-sync)
            reset_failures
            sync_repos
            show_run_summary "Repository sync"
            ;;
        repos-cleanup)
            if [ "$REMOVE_MODULES" -eq 0 ] && [ "$GIT_CLEAN" -eq 0 ] && [ "$REINSTALL" -eq 0 ] && [ "$REMOVE_PYTHON_ENV" -eq 0 ] && [ "$REMOVE_REPOS" -eq 0 ]; then
                log_fail "repos-cleanup requires at least one cleanup flag"
                return 1
            fi
            for entry in "${REPOS[@]}"; do
                cleanup_repo_entry "$entry" "$REMOVE_MODULES" "$REINSTALL" "$GIT_CLEAN" "$REMOVE_PYTHON_ENV" "$REMOVE_REPOS"
            done
            ;;
        full-setup)
            full_setup_noninteractive
            ;;
        *)
            log_fail "Unknown action: $ACTION"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# Option 4 — Full setup
# ─────────────────────────────────────────────────────────────
full_setup() {
    reset_failures
    echo ""
    echo -e "  ${CYAN}Running full environment setup...${RESET}"

    # Step 1+2: packages
    install_missing

    # Step 3: repos (includes bpm-CodingAgentConfigCopy install.sh)
    sync_repos

    # Step 4: VS Code extensions (script 02 equivalent)
    echo ""
    read -rp "  Install VS Code AI extensions? [Y/n] " run_ext
    if [[ "${run_ext,,}" != n* ]]; then
        setup_vscode_extensions
    fi

    # Step 5: CAC CLI
    echo ""
    read -rp "  Set up CAC (CodingAgentConfigCopy) CLI? [Y/n] " run_cac
    if [[ "${run_cac,,}" != n* ]]; then
        setup_cac
    fi

    echo ""
    if show_run_summary "Full setup"; then
        echo -e "  ${GREEN}================================================${RESET}"
        echo -e "  ${GREEN} Full setup complete!${RESET}"
        echo -e "  ${GREEN}================================================${RESET}"
    else
        echo -e "  ${YELLOW}================================================${RESET}"
        echo -e "  ${YELLOW} Full setup completed with issues.${RESET}"
        echo -e "  ${YELLOW}================================================${RESET}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    if [[ -f "$SCRIPT_DIR/00-preflight.sh" ]]; then
        echo ""
        echo -e "  ${GRAY}Running preflight checks...${RESET}"
        if ! bash "$SCRIPT_DIR/00-preflight.sh" --no-prompt; then
            echo ""
            read -rp "  Preflight reported blocking issues. Continue into setup anyway? [y/N] " continue_setup
            if [[ "${continue_setup,,}" != y* ]]; then
                echo ""
                echo -e "  ${YELLOW}Setup cancelled after preflight.${RESET}"
                exit 1
            fi
        fi
    else
        echo ""
        echo -e "  ${YELLOW}[WARN]${RESET} Preflight script not found at $SCRIPT_DIR/00-preflight.sh"
    fi
fi

detect_platform
detect_pkg_manager

if [ -n "$ACTION" ]; then
    run_action_mode
    exit $?
fi

while true; do
    show_menu
    read -rp "  Select option: " choice

    case "${choice^^}" in
        1)
            check_packages
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        2)
            reset_failures
            install_missing
            show_run_summary "Package installation"
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        3)
            reset_failures
            sync_repos
            show_run_summary "Repository sync"
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        4)
            full_setup
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        5)
            cleanup_repos
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        6)
            reset_failures
            update_packages
            show_run_summary "Package update"
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        7)
            reset_failures
            setup_openrouter_agents
            show_run_summary "Coding agent setup"
            echo ""
            read -rp "  Press Enter to return to menu..." _dummy
            ;;
        Q)
            echo ""
            echo -e "  ${CYAN}Goodbye!${RESET}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "  ${YELLOW}Invalid option. Enter 1-5 or Q.${RESET}"
            sleep 1
            ;;
    esac
done
