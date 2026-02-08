#!/usr/bin/env bash
# ==============================================================================
#
#   YetiForge — Single-File Deployment Script
#
#   AI-Powered Telegram Bot Framework
#
#   Usage:
#     # Fresh install (curl pipe)
#     curl -fsSL https://raw.githubusercontent.com/sasquatch-vide-coder/yetiforge_self_improve/main/deploy.sh | sudo bash
#
#     # Fresh install (from cloned repo)
#     sudo bash deploy.sh
#
#     # Update existing installation
#     sudo bash deploy.sh update
#
#     # Uninstall
#     sudo bash deploy.sh uninstall
#
#     # Non-interactive install (automated)
#     YETIFORGE_BOT_TOKEN="123:ABC" \
#     YETIFORGE_USER_IDS="12345" \
#     YETIFORGE_DOMAIN="bot.example.com" \
#     sudo bash deploy.sh --auto
#
#   Version: 2.0.0
#
# ==============================================================================

set -euo pipefail

DEPLOY_VERSION="2.0.0"

# Capture start time
SECONDS=0

# ══════════════════════════════════════════════════════════════════════════════
# Section 2: Constants & Defaults
# ══════════════════════════════════════════════════════════════════════════════

REPO_URL="${YETIFORGE_REPO:-https://github.com/sasquatch-vide-coder/yetiforge_self_improve.git}"
INSTALL_BRANCH="${YETIFORGE_BRANCH:-main}"
DEFAULT_INSTALL_DIR="/opt/yetiforge"
DEFAULT_PORT="3069"
DEFAULT_TIMEOUT="300000"

# ══════════════════════════════════════════════════════════════════════════════
# Section 3: Argument Parser
# ══════════════════════════════════════════════════════════════════════════════

MODE="install"
AUTO_MODE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        update)
            MODE="update"
            shift
            ;;
        uninstall)
            MODE="uninstall"
            shift
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "YetiForge Deployment Script v${DEPLOY_VERSION}"
            echo ""
            echo "Usage: sudo bash deploy.sh [mode] [flags]"
            echo ""
            echo "Modes:"
            echo "  (default)   Fresh installation"
            echo "  update      Update existing installation"
            echo "  uninstall   Remove YetiForge from this system"
            echo ""
            echo "Flags:"
            echo "  --auto      Non-interactive mode (reads YETIFORGE_* env vars)"
            echo "  --dry-run   Show what would be done without executing"
            echo "  --help      Show this help message"
            echo ""
            echo "Non-interactive env vars:"
            echo "  YETIFORGE_BOT_TOKEN    Telegram bot token (required)"
            echo "  YETIFORGE_USER_IDS     Allowed Telegram user IDs (required)"
            echo "  YETIFORGE_DOMAIN       Domain name (optional)"
            echo "  YETIFORGE_PORT         Status dashboard port (default: 3069)"
            echo "  YETIFORGE_PROJECT_DIR  Default project directory"
            echo "  YETIFORGE_CLAUDE_PATH  Path to Claude CLI binary"
            echo "  YETIFORGE_JWT_SECRET   Admin JWT secret"
            echo "  YETIFORGE_GITHUB_PAT   GitHub personal access token"
            echo "  YETIFORGE_TIMEOUT      Claude CLI timeout in ms (default: 300000)"
            echo "  YETIFORGE_SSL_EMAIL    Email for Let's Encrypt SSL"
            echo "  YETIFORGE_REPO         Git repo URL override"
            echo "  YETIFORGE_BRANCH       Git branch override (default: main)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run 'bash deploy.sh --help' for usage."
            exit 1
            ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
# Section 4: UI Helpers (from banner.sh)
# ══════════════════════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Symbols
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
ARROW="${CYAN}→${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"

# Divider widths
DIVIDER_STEP=$(printf '%.0s─' $(seq 1 60))
DIVIDER_SUB=$(printf '%.0s─' $(seq 1 52))

# Step counter
CURRENT_STEP=0
TOTAL_STEPS=9

show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    cat << 'BANNER'

    ██╗   ██╗███████╗████████╗██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
    ╚██╗ ██╔╝██╔════╝╚══██╔══╝██║██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
     ╚████╔╝ █████╗     ██║   ██║█████╗  ██║   ██║██████╔╝██║  ███╗█████╗
      ╚██╔╝  ██╔══╝     ██║   ██║██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
       ██║   ███████╗   ██║   ██║██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
       ╚═╝   ╚══════╝   ╚═╝   ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝

BANNER
    echo -e "${NC}"
    echo -e "    ${WHITE}${BOLD}AI-Powered Telegram Bot Framework${NC}  ${DIM}v${DEPLOY_VERSION}${NC}"
    echo -e "    ${DIM}One-command deployment • Production-ready • Open source${NC}"
    echo ""
    echo -e "    ${DIM}${DIVIDER_SUB}${NC}"
    echo ""
}

step_header() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "  ${BOLD}${WHITE}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${BOLD}$1${NC}"
    echo -e "  ${DIM}${DIVIDER_STEP}${NC}"
}

log_info() {
    echo -e "  ${INFO}  $1"
}

log_success() {
    echo -e "  ${CHECK}  $1"
}

log_warn() {
    echo -e "  ${WARN}  $1"
}

log_error() {
    echo -e "  ${CROSS}  ${RED}$1${NC}"
}

log_step() {
    echo -e "  ${ARROW}  $1"
}

spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local c=${spin:i++%${#spin}:1}
        printf "\r  ${CYAN}${c}${NC}  ${msg}" >&2
        sleep 0.1
    done
    printf "\r\033[K" >&2
}

prompt_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local required="${4:-false}"

    # In auto mode, use default (env var should have been set already)
    if [[ "$AUTO_MODE" == "true" ]]; then
        eval "local current_val=\"\${$var_name:-}\""
        if [[ -n "$current_val" ]]; then
            eval "$var_name='$current_val'"
        else
            eval "$var_name='$default_val'"
        fi
        return
    fi

    while true; do
        if [[ -n "$default_val" ]]; then
            echo -en "  ${ARROW}  ${prompt_text} ${DIM}[${default_val}]${NC}: "
        else
            echo -en "  ${ARROW}  ${prompt_text}: "
        fi
        read -r input < /dev/tty
        local value="${input:-$default_val}"

        if [[ "$required" == "true" && -z "$value" ]]; then
            log_error "This field is required. Please enter a value."
            continue
        fi

        eval "$var_name='$value'"
        break
    done
}

prompt_yn() {
    local prompt_text="$1"
    local default="${2:-y}"
    local var_name="$3"

    # In auto mode, use the default
    if [[ "$AUTO_MODE" == "true" ]]; then
        if [[ "$default" == "y" ]]; then
            eval "$var_name=true"
        else
            eval "$var_name=false"
        fi
        return
    fi

    local hint="Y/n"
    [[ "$default" == "n" ]] && hint="y/N"

    echo -en "  ${ARROW}  ${prompt_text} ${DIM}[${hint}]${NC}: "
    read -r input < /dev/tty
    input="${input:-$default}"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "y" || "$input" == "yes" ]]; then
        eval "$var_name=true"
    else
        eval "$var_name=false"
    fi
}

prompt_secret() {
    local prompt_text="$1"
    local var_name="$2"
    local required="${3:-true}"
    local hidden="${4:-true}"

    # In auto mode, the value should already be set via env var
    if [[ "$AUTO_MODE" == "true" ]]; then
        return
    fi

    while true; do
        echo -en "  ${ARROW}  ${prompt_text}: "
        if [[ "$hidden" == "true" ]]; then
            read -rs input < /dev/tty
            echo ""
        else
            read -r input < /dev/tty
        fi

        if [[ "$required" == "true" && -z "$input" ]]; then
            log_error "This field is required. Please enter a value."
            continue
        fi

        eval "$var_name='$input'"
        break
    done
}

show_box() {
    local title="$1"
    shift
    local width=64

    echo ""
    echo -e "  ${CYAN}╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
    echo -e "  ${CYAN}║${NC}  ${BOLD}${WHITE}${title}$(printf ' %.0s' $(seq 1 $((width - ${#title} - 2))))${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╠$(printf '═%.0s' $(seq 1 $width))╣${NC}"
    for line in "$@"; do
        local clean_line
        clean_line=$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')
        local padding=$((width - ${#clean_line} - 2))
        [[ $padding -lt 0 ]] && padding=0
        echo -e "  ${CYAN}║${NC}  ${line}$(printf ' %.0s' $(seq 1 $padding))${CYAN}║${NC}"
    done
    echo -e "  ${CYAN}╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
    echo ""
}

is_private_ip() {
    local ip="$1"
    case "$ip" in
        10.*)          return 0 ;;
        172.1[6-9].*)  return 0 ;;
        172.2[0-9].*)  return 0 ;;
        172.3[0-1].*)  return 0 ;;
        192.168.*)     return 0 ;;
        *)             return 1 ;;
    esac
}

handle_error() {
    local exit_code=$1
    local line_no=$2
    local command="$3"

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        log_error "Deployment failed at line ${line_no}"
        log_error "Command: ${command}"
        log_error "Exit code: ${exit_code}"
        echo ""
        log_info "Check the log file for details: ${INSTALL_LOG:-/tmp/yetiforge-deploy.log}"
        log_info "You can re-run the script after fixing the issue."
        echo ""
        exit $exit_code
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 5: run_preflight() (from preflight.sh)
# ══════════════════════════════════════════════════════════════════════════════

run_preflight() {
    step_header "Preflight Checks"

    # --- Root / Sudo Check ---
    if [[ $EUID -eq 0 ]]; then
        # If invoked via sudo, use the original user for service ownership
        INSTALL_USER="${SUDO_USER:-root}"
        SUDO_CMD=""
        log_success "Running as root (service user: ${INSTALL_USER})"
    elif sudo -n true 2>/dev/null; then
        INSTALL_USER=$(whoami)
        SUDO_CMD="sudo"
        log_success "Running as ${INSTALL_USER} with sudo access"
    else
        log_error "This installer requires root or sudo access."
        log_info "Run with: sudo bash deploy.sh"
        exit 1
    fi

    # --- OS Detection ---
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        OS_PRETTY="$PRETTY_NAME"
    else
        log_error "Cannot detect operating system. /etc/os-release not found."
        log_info "YetiForge requires Ubuntu 20.04+ or Debian 11+"
        exit 1
    fi

    case "$OS_NAME" in
        ubuntu)
            if [[ "${OS_VERSION%%.*}" -lt 20 ]]; then
                log_error "Ubuntu ${OS_VERSION} is not supported. Requires 20.04+"
                exit 1
            fi
            log_success "OS: ${OS_PRETTY}"
            ;;
        debian)
            if [[ "${OS_VERSION%%.*}" -lt 11 ]]; then
                log_error "Debian ${OS_VERSION} is not supported. Requires 11+"
                exit 1
            fi
            log_success "OS: ${OS_PRETTY}"
            ;;
        *)
            log_warn "Unsupported OS: ${OS_PRETTY}"
            log_warn "YetiForge is tested on Ubuntu 20.04+ and Debian 11+"
            prompt_yn "Continue anyway? (things might break)" "n" CONTINUE_UNSUPPORTED
            if [[ "$CONTINUE_UNSUPPORTED" != "true" ]]; then
                exit 1
            fi
            ;;
    esac

    # --- Architecture ---
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            log_success "Architecture: x86_64"
            ;;
        aarch64|arm64)
            log_success "Architecture: ARM64"
            ;;
        *)
            log_warn "Unusual architecture: ${ARCH}. May encounter issues."
            ;;
    esac

    # --- Memory Check ---
    TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [[ -n "$TOTAL_MEM_MB" ]]; then
        if [[ "$TOTAL_MEM_MB" -lt 512 ]]; then
            log_warn "Low memory: ${TOTAL_MEM_MB}MB. Recommended: 1GB+"
            log_warn "Build process may fail or be very slow."
        else
            log_success "Memory: ${TOTAL_MEM_MB}MB"
        fi
    fi

    # --- Disk Space Check ---
    local check_dir="${INSTALL_DIR}"
    [[ ! -d "$check_dir" ]] && check_dir="/"
    AVAIL_DISK_MB=$(df -m "${check_dir}" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$AVAIL_DISK_MB" ]]; then
        if [[ "$AVAIL_DISK_MB" -lt 1024 ]]; then
            log_warn "Low disk space: ${AVAIL_DISK_MB}MB available. Recommended: 2GB+"
        else
            log_success "Disk space: ${AVAIL_DISK_MB}MB available"
        fi
    fi

    # --- Internet Connectivity ---
    if curl -sf --connect-timeout 5 https://registry.npmjs.org/ > /dev/null 2>&1; then
        log_success "Internet: Connected (npm registry reachable)"
    elif curl -sf --connect-timeout 5 https://google.com > /dev/null 2>&1; then
        log_success "Internet: Connected"
        log_warn "npm registry unreachable — install may have issues"
    else
        log_error "No internet connectivity detected."
        log_info "YetiForge requires internet to download dependencies."
        exit 1
    fi

    # --- Git Check ---
    if command -v git &> /dev/null; then
        log_success "Git: $(git --version | head -1)"
    else
        log_step "Git not found — will be installed"
        GIT_NEEDED=true
    fi

    # --- Existing Installation Check ---
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        log_warn "Existing YetiForge installation detected at ${INSTALL_DIR}"
        prompt_yn "Overwrite configuration? (your .env will be backed up)" "n" OVERWRITE_CONFIG
        if [[ "$OVERWRITE_CONFIG" == "true" ]]; then
            local backup_name=".env.backup.$(date +%Y%m%d%H%M%S)"
            cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/${backup_name}"
            log_success "Backed up existing .env to ${backup_name}"
            FRESH_CONFIG=true
        else
            FRESH_CONFIG=false
            log_info "Keeping existing configuration"
        fi
    else
        FRESH_CONFIG=true
    fi

    # --- Check for running service ---
    if systemctl is-active --quiet yetiforge 2>/dev/null; then
        log_warn "YetiForge service is currently running"
        log_info "It will be restarted after installation completes"
        SERVICE_WAS_RUNNING=true
    else
        SERVICE_WAS_RUNNING=false
    fi

    echo ""
    log_success "Preflight checks passed"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 6: install_dependencies() (from install-deps.sh)
# ══════════════════════════════════════════════════════════════════════════════

install_dependencies() {
    step_header "Installing Dependencies"

    # --- Update package lists ---
    log_step "Updating package lists..."
    $SUDO_CMD apt-get update -qq >> "$INSTALL_LOG" 2>&1
    log_success "Package lists updated"

    # --- Essential packages ---
    local base_packages="curl wget gnupg2 ca-certificates lsb-release software-properties-common build-essential"
    log_step "Installing base packages..."
    $SUDO_CMD apt-get install -y -qq $base_packages >> "$INSTALL_LOG" 2>&1
    log_success "Base packages installed"

    # --- Git ---
    if [[ "$GIT_NEEDED" == "true" ]] || ! command -v git &> /dev/null; then
        log_step "Installing Git..."
        $SUDO_CMD apt-get install -y -qq git >> "$INSTALL_LOG" 2>&1
        log_success "Git installed: $(git --version)"
    else
        log_success "Git: already installed"
    fi

    # --- Node.js 22 ---
    if command -v node &> /dev/null; then
        local node_ver
        node_ver=$(node -v 2>/dev/null | sed 's/v//')
        local node_major="${node_ver%%.*}"
        if [[ "$node_major" -ge 22 ]]; then
            log_success "Node.js: v${node_ver} (already installed)"
            SKIP_NODE=true
        else
            log_warn "Node.js v${node_ver} found but v22+ required"
            SKIP_NODE=false
        fi
    else
        SKIP_NODE=false
    fi

    if [[ "$SKIP_NODE" != "true" ]]; then
        log_step "Installing Node.js 22..."

        if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]] && [[ ! -f /usr/share/keyrings/nodesource.gpg ]]; then
            if [[ -n "$SUDO_CMD" ]]; then
                curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO_CMD -E bash - >> "$INSTALL_LOG" 2>&1
            else
                curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >> "$INSTALL_LOG" 2>&1
            fi
        fi

        $SUDO_CMD apt-get install -y -qq nodejs >> "$INSTALL_LOG" 2>&1

        if command -v node &> /dev/null; then
            log_success "Node.js installed: $(node -v)"
        else
            log_error "Node.js installation failed. Check ${INSTALL_LOG}"
            exit 1
        fi
    fi

    # --- npm check ---
    if command -v npm &> /dev/null; then
        log_success "npm: $(npm -v)"
    else
        log_error "npm not found after Node.js installation."
        exit 1
    fi

    # --- Nginx ---
    if command -v nginx &> /dev/null; then
        log_success "Nginx: already installed"
    else
        log_step "Installing Nginx..."
        $SUDO_CMD apt-get install -y -qq nginx >> "$INSTALL_LOG" 2>&1
        if command -v nginx &> /dev/null; then
            log_success "Nginx installed: $(nginx -v 2>&1)"
        else
            log_error "Nginx installation failed. Check ${INSTALL_LOG}"
            exit 1
        fi
    fi

    # --- Certbot ---
    if command -v certbot &> /dev/null; then
        log_success "Certbot: already installed"
    else
        log_step "Installing Certbot..."
        $SUDO_CMD apt-get install -y -qq certbot python3-certbot-nginx >> "$INSTALL_LOG" 2>&1
        if command -v certbot &> /dev/null; then
            log_success "Certbot installed"
        else
            log_warn "Certbot installation failed — SSL setup will be unavailable"
        fi
    fi

    # --- UFW ---
    if command -v ufw &> /dev/null; then
        log_success "UFW firewall: available"
        UFW_AVAILABLE=true
    else
        log_info "UFW not installed — firewall rules must be managed manually"
        UFW_AVAILABLE=false
    fi

    echo ""
    log_success "All dependencies installed"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 7: clone_or_update_repo() (NEW)
# ══════════════════════════════════════════════════════════════════════════════

clone_or_update_repo() {
    step_header "Setting Up Repository"

    # Check if we're already inside a YetiForge repo
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo "")"

    if [[ -n "$script_dir" ]] && [[ -d "${script_dir}/.git" ]] && [[ -f "${script_dir}/package.json" ]]; then
        # Verify it's actually yetiforge — match the "name" field specifically
        if grep -qE '"name"\s*:\s*"yetiforge"' "${script_dir}/package.json" 2>/dev/null; then
            INSTALL_DIR="$script_dir"
            log_success "Running from existing repo: ${INSTALL_DIR}"
            return 0
        fi
    fi

    # Not inside a repo — clone to default location
    INSTALL_DIR="${DEFAULT_INSTALL_DIR}"

    # Build authenticated clone URL if a GitHub PAT is available
    local clone_url="$REPO_URL"
    if [[ -n "${YETIFORGE_GITHUB_PAT:-}" ]] && [[ "$clone_url" == https://github.com/* ]]; then
        clone_url="${clone_url/https:\/\/github.com/https:\/\/${YETIFORGE_GITHUB_PAT}@github.com}"
    fi

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        log_step "Existing clone found at ${INSTALL_DIR} — updating..."
        cd "$INSTALL_DIR"
        # Update remote URL in case PAT changed
        git remote set-url origin "$clone_url" 2>/dev/null || true
        git fetch origin "$INSTALL_BRANCH" >> "$INSTALL_LOG" 2>&1
        git reset --hard "origin/$INSTALL_BRANCH" >> "$INSTALL_LOG" 2>&1
        # Strip PAT from stored remote URL after fetch
        git remote set-url origin "$REPO_URL" 2>/dev/null || true
        log_success "Repository updated to latest ${INSTALL_BRANCH}"
    else
        log_step "Cloning YetiForge to ${INSTALL_DIR}..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would clone ${REPO_URL} to ${INSTALL_DIR}"
            return 0
        fi
        $SUDO_CMD git clone -b "$INSTALL_BRANCH" "$clone_url" "$INSTALL_DIR" >> "$INSTALL_LOG" 2>&1
        # Strip PAT from stored remote URL after clone
        if [[ "$clone_url" != "$REPO_URL" ]]; then
            cd "$INSTALL_DIR"
            git remote set-url origin "$REPO_URL" 2>/dev/null || true
        fi
        log_success "Repository cloned to ${INSTALL_DIR}"
    fi

    # Fix ownership if running as sudo
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$INSTALL_USER" != "root" ]]; then
        $SUDO_CMD chown -R "${SUDO_USER}:${SUDO_USER}" "$INSTALL_DIR"
        log_success "Fixed ownership to ${SUDO_USER}"
    fi

    cd "$INSTALL_DIR"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 8: run_configuration() (from configure.sh)
# ══════════════════════════════════════════════════════════════════════════════

run_configuration() {
    step_header "Configuration"

    if [[ "$FRESH_CONFIG" != "true" ]]; then
        log_info "Using existing .env configuration"
        log_info "Edit ${INSTALL_DIR}/.env to change settings later"
        return 0
    fi

    # In auto mode, pull values from YETIFORGE_* env vars
    if [[ "$AUTO_MODE" == "true" ]]; then
        CFG_BOT_TOKEN="${YETIFORGE_BOT_TOKEN:-}"
        CFG_USER_IDS="${YETIFORGE_USER_IDS:-}"
        CFG_DOMAIN="${YETIFORGE_DOMAIN:-}"
        CFG_PORT="${YETIFORGE_PORT:-$DEFAULT_PORT}"
        CFG_PROJECT_DIR="${YETIFORGE_PROJECT_DIR:-/home/${INSTALL_USER}}"
        CFG_CLAUDE_PATH="${YETIFORGE_CLAUDE_PATH:-claude}"
        CFG_JWT_SECRET="${YETIFORGE_JWT_SECRET:-$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | base64 | tr -d '=/+' | head -c 64)}"
        CFG_GITHUB_PAT="${YETIFORGE_GITHUB_PAT:-}"
        CFG_CLAUDE_TIMEOUT="${YETIFORGE_TIMEOUT:-$DEFAULT_TIMEOUT}"

        if [[ -z "$CFG_BOT_TOKEN" ]]; then
            log_error "YETIFORGE_BOT_TOKEN is required in --auto mode"
            exit 1
        fi
        if [[ ! "$CFG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            log_error "YETIFORGE_BOT_TOKEN has invalid format. Expected: 123456:ABC-DEF..."
            exit 1
        fi
        if [[ -z "$CFG_USER_IDS" ]]; then
            log_error "YETIFORGE_USER_IDS is required in --auto mode"
            exit 1
        fi
        if [[ ! "$CFG_USER_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            log_error "YETIFORGE_USER_IDS has invalid format. Expected: numeric IDs separated by commas (e.g., 123456789,987654321)"
            exit 1
        fi

        if [[ -n "$CFG_DOMAIN" ]]; then
            HAS_DOMAIN=true
        else
            HAS_DOMAIN=false
        fi

        log_success "Configuration loaded from environment variables"
    else
        # Interactive configuration wizard
        echo ""
        echo -e "  ${WHITE}${BOLD}Let's set up your YetiForge instance.${NC}"
        echo -e "  ${DIM}Required fields are marked with *. Press Enter to accept defaults.${NC}"
        echo ""

        # ── Telegram Configuration ──
        echo -e "  ${BOLD}${MAGENTA}Telegram Bot Setup${NC}"
        echo -e "  ${DIM}Create a bot at https://t.me/BotFather to get your token${NC}"
        echo ""

        while true; do
            prompt_secret "* Telegram Bot Token" CFG_BOT_TOKEN true false
            if [[ "$CFG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                log_success "Bot token format looks valid"
                break
            else
                log_error "Invalid bot token format. Expected: 123456:ABC-DEF..."
                log_info "Get your token from @BotFather on Telegram"
            fi
        done

        echo ""

        echo -e "  ${DIM}Your Telegram user ID controls who can use the bot.${NC}"
        echo -e "  ${DIM}Send /start to @userinfobot on Telegram to find your ID.${NC}"
        echo -e "  ${DIM}Separate multiple IDs with commas.${NC}"
        while true; do
            prompt_with_default "* Allowed Telegram User IDs" "" CFG_USER_IDS true
            if [[ "$CFG_USER_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                log_success "User IDs set"
                break
            else
                log_error "Invalid format. Enter numeric IDs separated by commas (e.g., 123456789,987654321)"
            fi
        done

        echo ""

        # ── Apply sensible defaults silently ──
        CFG_DOMAIN=""
        HAS_DOMAIN=false
        log_info "No domain configured — using IP-only access"

        CFG_PORT="$DEFAULT_PORT"
        log_success "Status port: ${CFG_PORT}"

        CFG_PROJECT_DIR="/home/${INSTALL_USER}"
        log_success "Project dir: ${CFG_PROJECT_DIR}"

        # Detect Claude CLI path
        local detected_claude=""
        if command -v claude &> /dev/null; then
            detected_claude=$(which claude)
        elif [[ -f "/home/${INSTALL_USER}/.local/bin/claude" ]]; then
            detected_claude="/home/${INSTALL_USER}/.local/bin/claude"
        elif [[ -f "/usr/local/bin/claude" ]]; then
            detected_claude="/usr/local/bin/claude"
        fi
        CFG_CLAUDE_PATH="${detected_claude:-claude}"
        if [[ -n "$detected_claude" ]]; then
            log_success "Claude CLI: ${detected_claude}"
        else
            log_info "Claude CLI: will be installed"
        fi

        # Auto-generate JWT secret
        CFG_JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | base64 | tr -d '=/+' | head -c 64)
        log_success "JWT secret: auto-generated"

        # Skip GitHub integration by default
        CFG_GITHUB_PAT=""

        # Use default timeout
        CFG_CLAUDE_TIMEOUT="$DEFAULT_TIMEOUT"

        log_info "Customize later by editing ${INSTALL_DIR}/.env"
        echo ""
    fi

    # ── Write .env file ──
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write .env to ${INSTALL_DIR}/.env"
        return 0
    fi

    log_step "Writing configuration to .env..."

    cat > "${INSTALL_DIR}/.env" << ENVFILE
# ==============================================================================
# YetiForge Configuration
# Generated by deploy.sh v${DEPLOY_VERSION} on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ==============================================================================

# --- Telegram Bot (REQUIRED) ---
TELEGRAM_BOT_TOKEN=${CFG_BOT_TOKEN}
ALLOWED_USER_IDS=${CFG_USER_IDS}

# --- Server ---
STATUS_PORT=${CFG_PORT}
$([ -n "${CFG_DOMAIN:-}" ] && echo "STATUS_HOST=${CFG_DOMAIN}" || echo "# STATUS_HOST=your-domain.com")
$([ -n "${CFG_DOMAIN:-}" ] && echo "WEBHOOK_HOST=${CFG_DOMAIN}" || echo "# WEBHOOK_HOST=your-domain.com")

# --- Claude Code CLI ---
CLAUDE_CLI_PATH=${CFG_CLAUDE_PATH}
CLAUDE_TIMEOUT_MS=${CFG_CLAUDE_TIMEOUT}

# --- Projects ---
DEFAULT_PROJECT_DIR=${CFG_PROJECT_DIR}

# --- Data ---
DATA_DIR=./data

# --- Security ---
ADMIN_JWT_SECRET=${CFG_JWT_SECRET}

# --- Optional: GitHub ---
$([ -n "${CFG_GITHUB_PAT:-}" ] && echo "GITHUB_PAT=${CFG_GITHUB_PAT}" || echo "# GITHUB_PAT=ghp_your_token_here")
ENVFILE

    chmod 600 "${INSTALL_DIR}/.env"
    log_success "Configuration saved to .env (permissions: 600)"

    echo ""
    log_success "Configuration complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 9: install_claude_cli() (NEW)
# ══════════════════════════════════════════════════════════════════════════════

install_claude_cli() {
    # This is not a numbered step — it runs within the build phase or after deps
    if command -v claude &> /dev/null; then
        log_success "Claude CLI: already installed ($(claude --version 2>/dev/null || echo 'unknown version'))"
        return 0
    fi

    # Check common install locations
    local claude_locations=(
        "/usr/local/bin/claude"
        "/home/${INSTALL_USER}/.local/bin/claude"
        "/home/${INSTALL_USER}/.npm-global/bin/claude"
    )
    for loc in "${claude_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            log_success "Claude CLI found at: ${loc}"
            return 0
        fi
    done

    echo ""
    log_info "Claude CLI not found — installing automatically..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Claude Code CLI"
        return 0
    fi

    log_step "Installing Claude Code CLI..."
    # Install as the service user, not root, so the binary lands in the right home dir
    local cli_installed=false
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${INSTALL_USER}" != "root" ]]; then
        if sudo -H -u "${INSTALL_USER}" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >> "$INSTALL_LOG" 2>&1; then
            cli_installed=true
        fi
    else
        if curl -fsSL https://claude.ai/install.sh | bash >> "$INSTALL_LOG" 2>&1; then
            cli_installed=true
        fi
    fi

    if [[ "$cli_installed" == "true" ]]; then
        # Add ~/.local/bin to user's bashrc and current session
        local user_bashrc="/home/${INSTALL_USER}/.bashrc"
        if [[ -f "$user_bashrc" ]] && ! grep -qF '.local/bin' "$user_bashrc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$user_bashrc"
            log_success "Added ~/.local/bin to PATH in .bashrc"
        fi
        export PATH="/home/${INSTALL_USER}/.local/bin:$PATH"

        if command -v claude &> /dev/null; then
            log_success "Claude CLI installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
        else
            log_success "Claude CLI installed"
        fi
    else
        log_warn "Claude CLI installation failed (non-fatal)"
        log_info "Install manually later with: curl -fsSL https://claude.ai/install.sh | bash"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 9b: authenticate_claude() — interactive auth prompt
# ══════════════════════════════════════════════════════════════════════════════

authenticate_claude() {
    step_header "Claude CLI Authentication"

    # Skip in auto mode
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Skipping interactive auth in --auto mode"
        log_info "Run 'claude auth' manually after install"
        CLAUDE_AUTH_OK=false
        return 0
    fi

    # Check if claude is available
    local claude_bin=""
    if command -v claude &> /dev/null; then
        claude_bin="claude"
    elif [[ -f "/home/${INSTALL_USER}/.local/bin/claude" ]]; then
        claude_bin="/home/${INSTALL_USER}/.local/bin/claude"
    fi

    if [[ -z "$claude_bin" ]]; then
        log_warn "Claude CLI not found — skipping authentication"
        CLAUDE_AUTH_OK=false
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prompt for Claude CLI authentication"
        CLAUDE_AUTH_OK=false
        return 0
    fi

    echo ""
    echo -e "  ${DIM}Claude CLI needs to be authenticated with your Anthropic account.${NC}"
    echo -e "  ${DIM}This will open a browser-based login flow.${NC}"
    echo ""

    prompt_yn "Authenticate Claude CLI now?" "y" DO_CLAUDE_AUTH

    if [[ "$DO_CLAUDE_AUTH" != "true" ]]; then
        log_info "Skipping — you can authenticate later with: claude auth"
        CLAUDE_AUTH_OK=false
        return 0
    fi

    log_step "Running claude auth (follow the browser prompts)..."
    echo ""

    local auth_ok=false
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${INSTALL_USER}" != "root" ]]; then
        if sudo -H -u "${INSTALL_USER}" bash -c "'${claude_bin}' auth" < /dev/tty; then
            auth_ok=true
        fi
    else
        if "${claude_bin}" auth < /dev/tty; then
            auth_ok=true
        fi
    fi

    echo ""
    if [[ "$auth_ok" == "true" ]]; then
        log_success "Claude CLI authenticated successfully"
        CLAUDE_AUTH_OK=true
    else
        log_warn "Claude auth did not complete — you can retry later with: claude auth"
        CLAUDE_AUTH_OK=false
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 10: run_build() (from build.sh)
# ══════════════════════════════════════════════════════════════════════════════

run_build() {
    step_header "Building YetiForge"

    cd "${INSTALL_DIR}" || { log_error "Cannot access ${INSTALL_DIR}"; exit 1; }

    # --- Create data directory ---
    if [[ ! -d "${INSTALL_DIR}/data" ]]; then
        mkdir -p "${INSTALL_DIR}/data"
        log_success "Created data directory"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run npm install + build"
        return 0
    fi

    # --- Install server dependencies ---
    log_step "Installing server dependencies..."
    npm install --production=false >> "$INSTALL_LOG" 2>&1 &
    spinner $! "Installing server dependencies..."
    wait $!
    local npm_exit=$?

    if [[ $npm_exit -ne 0 ]]; then
        log_error "npm install failed. Check ${INSTALL_LOG} for details."
        echo ""
        log_info "Last 20 lines of log:"
        tail -20 "$INSTALL_LOG" | while read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
        exit 1
    fi
    log_success "Server dependencies installed"

    # --- Install client dependencies ---
    if [[ -f "${INSTALL_DIR}/status/client/package.json" ]]; then
        log_step "Installing dashboard dependencies..."
        cd "${INSTALL_DIR}/status/client" || { log_error "Cannot access status/client"; exit 1; }
        npm install --production=false >> "$INSTALL_LOG" 2>&1 &
        spinner $! "Installing dashboard dependencies..."
        wait $!
        local client_npm_exit=$?

        if [[ $client_npm_exit -ne 0 ]]; then
            log_error "Client npm install failed. Check ${INSTALL_LOG}"
            exit 1
        fi
        log_success "Dashboard dependencies installed"
        cd "${INSTALL_DIR}"
    fi

    # --- Compile TypeScript ---
    log_step "Compiling TypeScript..."
    npx tsc >> "$INSTALL_LOG" 2>&1 &
    spinner $! "Compiling TypeScript..."
    wait $!
    local tsc_exit=$?

    if [[ $tsc_exit -ne 0 ]]; then
        log_error "TypeScript compilation failed."
        echo ""
        log_info "Last 30 lines of log:"
        tail -30 "$INSTALL_LOG" | while read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
        exit 1
    fi

    if [[ -f "${INSTALL_DIR}/dist/index.js" ]]; then
        log_success "TypeScript compiled → dist/"
    else
        log_error "Build completed but dist/index.js not found"
        exit 1
    fi

    # --- Build React dashboard ---
    if [[ -f "${INSTALL_DIR}/status/client/package.json" ]]; then
        log_step "Building status dashboard..."
        cd "${INSTALL_DIR}/status/client"
        npm run build >> "$INSTALL_LOG" 2>&1 &
        spinner $! "Building status dashboard..."
        wait $!
        local client_build_exit=$?

        if [[ $client_build_exit -ne 0 ]]; then
            log_error "Dashboard build failed."
            log_info "Last 20 lines of log:"
            tail -20 "$INSTALL_LOG" | while read -r line; do
                echo -e "  ${DIM}${line}${NC}"
            done
            log_warn "Continuing without dashboard — bot will still work"
        else
            if [[ -f "${INSTALL_DIR}/status/client/dist/index.html" ]]; then
                log_success "Dashboard built → status/client/dist/"
            else
                log_warn "Dashboard build completed but index.html not found"
            fi
        fi
        cd "${INSTALL_DIR}"
    fi

    # --- Fix ownership after build ---
    # Build steps run as root, but service runs as INSTALL_USER
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${INSTALL_USER}" != "root" ]]; then
        chown -R "${INSTALL_USER}:${INSTALL_USER}" "${INSTALL_DIR}"
        log_success "Fixed ownership to ${INSTALL_USER}"
    fi

    echo ""
    log_success "Build complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 11: setup_services() (from services.sh)
# ══════════════════════════════════════════════════════════════════════════════

setup_services() {
    step_header "Setting Up Services"

    local service_user="${INSTALL_USER}"
    local service_dir="${INSTALL_DIR}"
    local service_home
    service_home=$(eval echo "~${service_user}" 2>/dev/null || echo "/home/${service_user}")
    local node_path
    node_path=$(which node)

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create systemd service and nginx config"
        return 0
    fi

    # ── systemd Service ──
    log_step "Generating systemd service..."

    cat > /tmp/yetiforge.service << SVCFILE
[Unit]
Description=YetiForge AI Bot Framework
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${service_user}
WorkingDirectory=${service_dir}
ExecStart=${node_path} dist/index.js
Restart=always
RestartSec=10
EnvironmentFile=${service_dir}/.env
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${service_home}/.local/bin

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${service_dir}/data ${service_dir} ${service_home}
ProtectHome=false

# Resource limits
LimitNOFILE=65536
MemoryMax=1G

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=yetiforge

[Install]
WantedBy=multi-user.target
SVCFILE

    $SUDO_CMD cp /tmp/yetiforge.service /etc/systemd/system/yetiforge.service
    $SUDO_CMD systemctl daemon-reload
    $SUDO_CMD systemctl enable yetiforge >> "$INSTALL_LOG" 2>&1

    log_success "systemd service installed and enabled"

    # ── Nginx Configuration ──
    log_step "Generating Nginx configuration..."

    local status_port="${CFG_PORT:-$DEFAULT_PORT}"
    local client_dist="${service_dir}/status/client/dist"

    if [[ "$HAS_DOMAIN" == "true" ]] && [[ -n "${CFG_DOMAIN:-}" ]]; then
        local server_name="${CFG_DOMAIN}"
        local listen_directive="listen 80;\n    listen [::]:80;"
    else
        local server_name="_"
        local listen_directive="listen 80 default_server;\n    listen [::]:80 default_server;"
    fi

    cat > /tmp/yetiforge-nginx.conf << NGINXCONF
# YetiForge — Nginx Reverse Proxy
# Generated by deploy.sh v${DEPLOY_VERSION} on $(date -u +"%Y-%m-%d %H:%M:%S UTC")

upstream yetiforge_api {
    server 127.0.0.1:${status_port};
    keepalive 32;
}

server {
    $(echo -e "${listen_directive}")
    server_name ${server_name};

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;

    # Static files — React dashboard
    location / {
        root ${client_dist};
        try_files \$uri \$uri/ /index.html;

        # Cache static assets aggressively
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
    }

    # API proxy
    location /api/ {
        proxy_pass http://yetiforge_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # Webhook endpoint
    location /webhook/ {
        proxy_pass http://yetiforge_api;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Block access to sensitive files
    location ~ /\. {
        deny all;
        return 404;
    }
}
NGINXCONF

    $SUDO_CMD cp /tmp/yetiforge-nginx.conf /etc/nginx/sites-available/yetiforge
    $SUDO_CMD ln -sf /etc/nginx/sites-available/yetiforge /etc/nginx/sites-enabled/yetiforge

    # Remove default site if it exists
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        $SUDO_CMD rm -f /etc/nginx/sites-enabled/default
        log_success "Default Nginx site removed"
    fi

    # Test nginx config
    if $SUDO_CMD nginx -t >> "$INSTALL_LOG" 2>&1; then
        $SUDO_CMD systemctl reload nginx
        if [[ "$HAS_DOMAIN" == "true" ]]; then
            log_success "Nginx configured for ${CFG_DOMAIN}"
        else
            log_success "Nginx configured (IP-based access on port 80)"
        fi
    else
        log_error "Nginx configuration test failed!"
        log_info "Check with: sudo nginx -t"
        $SUDO_CMD rm -f /etc/nginx/sites-enabled/yetiforge
        log_warn "Nginx config saved but not activated. Fix manually."
    fi

    # ── Firewall ──
    if [[ "$UFW_AVAILABLE" == "true" ]]; then
        log_step "Configuring firewall rules..."
        $SUDO_CMD ufw allow 80/tcp >> "$INSTALL_LOG" 2>&1
        $SUDO_CMD ufw allow 443/tcp >> "$INSTALL_LOG" 2>&1
        $SUDO_CMD ufw allow "${CFG_PORT:-$DEFAULT_PORT}/tcp" >> "$INSTALL_LOG" 2>&1
        $SUDO_CMD ufw allow 22/tcp >> "$INSTALL_LOG" 2>&1

        if ! $SUDO_CMD ufw status | grep -q "Status: active"; then
            echo "y" | $SUDO_CMD ufw enable >> "$INSTALL_LOG" 2>&1
            log_success "Firewall enabled"
        fi
        log_success "Firewall rules configured"
    else
        log_warn "UFW not found — firewall rules must be configured manually"
        log_info "Run these commands to open the required ports:"
        log_info "  ${GREEN}sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT${NC}"
        log_info "  ${GREEN}sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT${NC}"
        log_info "  ${GREEN}sudo iptables -A INPUT -p tcp --dport ${CFG_PORT:-$DEFAULT_PORT} -j ACCEPT${NC}"
        log_info "To persist rules across reboots: ${GREEN}sudo apt-get install -y iptables-persistent${NC}"
    fi

    echo ""
    log_success "Services configured"
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 12: setup_ssl() (from ssl.sh)
# ══════════════════════════════════════════════════════════════════════════════

setup_ssl() {
    step_header "SSL Certificate (Optional)"

    if [[ "$HAS_DOMAIN" != "true" ]] || [[ -z "${CFG_DOMAIN:-}" ]]; then
        log_info "No domain configured — skipping SSL setup"
        log_info "You can set up SSL later with: sudo certbot --nginx -d yourdomain.com"
        return 0
    fi

    if ! command -v certbot &> /dev/null; then
        log_warn "Certbot not available — skipping SSL"
        log_info "Install certbot later and run: sudo certbot --nginx -d ${CFG_DOMAIN}"
        return 0
    fi

    if [[ -d "/etc/letsencrypt/live/${CFG_DOMAIN}" ]]; then
        log_success "SSL certificate already exists for ${CFG_DOMAIN}"
        SSL_CONFIGURED=true
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would request SSL certificate for ${CFG_DOMAIN}"
        return 0
    fi

    echo ""
    echo -e "  ${DIM}SSL will secure your dashboard with HTTPS using Let's Encrypt.${NC}"
    echo -e "  ${DIM}Your domain (${CFG_DOMAIN}) must already point to this server.${NC}"
    echo ""

    prompt_yn "Set up free SSL certificate for ${CFG_DOMAIN}?" "y" SETUP_SSL_NOW

    if [[ "$SETUP_SSL_NOW" != "true" ]]; then
        log_info "Skipping SSL — you can set it up later:"
        log_info "  sudo certbot --nginx -d ${CFG_DOMAIN}"
        return 0
    fi

    # In auto mode, use env var for email
    local ssl_email="${YETIFORGE_SSL_EMAIL:-}"
    if [[ "$AUTO_MODE" != "true" ]]; then
        prompt_with_default "Email for SSL certificate notifications" "" CFG_SSL_EMAIL false
        ssl_email="${CFG_SSL_EMAIL:-}"
    fi

    local certbot_flags="--nginx -d ${CFG_DOMAIN} --non-interactive --agree-tos"
    if [[ -n "$ssl_email" ]]; then
        certbot_flags="${certbot_flags} --email ${ssl_email}"
    else
        certbot_flags="${certbot_flags} --register-unsafely-without-email"
    fi

    log_step "Requesting SSL certificate..."
    if $SUDO_CMD certbot ${certbot_flags} >> "$INSTALL_LOG" 2>&1; then
        log_success "SSL certificate installed for ${CFG_DOMAIN}"

        # Set up auto-renewal
        if ! $SUDO_CMD crontab -l 2>/dev/null | grep -q "certbot renew"; then
            ($SUDO_CMD crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | $SUDO_CMD crontab -
            log_success "Auto-renewal cron job configured (daily at 3 AM)"
        else
            log_success "Auto-renewal already configured"
        fi

        SSL_CONFIGURED=true
    else
        log_warn "SSL setup failed — dashboard will work over HTTP"
        log_info "Common causes: domain not pointing to this server, port 80 blocked"
        log_info "Try manually: sudo certbot --nginx -d ${CFG_DOMAIN}"
        SSL_CONFIGURED=false
    fi

    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 13: run_finalize() (from finalize.sh)
# ══════════════════════════════════════════════════════════════════════════════

run_finalize() {
    step_header "Finalizing Installation"

    local status_port="${CFG_PORT:-$DEFAULT_PORT}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would start service and run health check"
        return 0
    fi

    # ── Start the service ──
    log_step "Starting YetiForge service..."
    $SUDO_CMD systemctl start yetiforge

    sleep 3

    # ── Health Check ──
    log_step "Running health check..."

    local health_ok=false
    local retries=0
    local max_retries=5

    while [[ $retries -lt $max_retries ]]; do
        if curl -sf "http://localhost:${status_port}/api/health" > /dev/null 2>&1; then
            health_ok=true
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [[ "$health_ok" == "true" ]]; then
        log_success "Health check passed — YetiForge is running!"
    else
        log_warn "Health check failed after ${max_retries} attempts"
        log_info "The service may still be starting up. Check with:"
        log_info "  sudo systemctl status yetiforge"
        log_info "  sudo journalctl -u yetiforge -f"
    fi

    # ── Copy deploy.sh into repo if run from outside ──
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null)/$(basename "${BASH_SOURCE[0]}")"
    if [[ -f "$script_path" ]] && [[ "$script_path" != "${INSTALL_DIR}/deploy.sh" ]]; then
        cp "$script_path" "${INSTALL_DIR}/deploy.sh"
        chmod +x "${INSTALL_DIR}/deploy.sh"
        log_success "deploy.sh copied into ${INSTALL_DIR}/"
    fi

    # ── Determine access URLs ──
    local external_ip
    external_ip=$(curl -sf --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -sf --connect-timeout 3 https://icanhazip.com 2>/dev/null || echo "")
    local internal_ip
    internal_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

    local dashboard_url=""
    local api_url=""
    local internal_url=""
    local protocol="http"

    if [[ "$SSL_CONFIGURED" == "true" ]]; then
        protocol="https"
    fi

    if [[ "$HAS_DOMAIN" == "true" && -n "${CFG_DOMAIN:-}" ]]; then
        dashboard_url="${protocol}://${CFG_DOMAIN}"
        api_url="${protocol}://${CFG_DOMAIN}/api/status"
    else
        dashboard_url="http://${external_ip:-${internal_ip}}"
        api_url="http://${external_ip:-${internal_ip}}/api/status"
    fi

    if [[ -n "$internal_ip" ]] && [[ "$internal_ip" != "$external_ip" ]] && is_private_ip "$internal_ip"; then
        internal_url="http://${internal_ip}"
    fi

    # ── Installation Summary ──
    local install_time=$((SECONDS / 60))

    echo ""
    show_box "YetiForge Installation Complete!" \
        "" \
        "Your bot framework is ready to go."

    echo -e "  ${WHITE}${BOLD}Access Your Instance${NC}"
    echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
    echo -e "  ${ARROW}  Dashboard:  ${GREEN}${BOLD}${dashboard_url}${NC}"
    echo -e "  ${ARROW}  API Status: ${GREEN}${api_url}${NC}"
    echo -e "  ${ARROW}  Admin:      ${GREEN}${dashboard_url}/admin${NC}"
    if [[ -n "$internal_url" ]] && [[ "$internal_url" != "$dashboard_url" ]]; then
        echo -e "  ${ARROW}  LAN:        ${GREEN}${internal_url}${NC}"
        echo -e "  ${ARROW}  LAN Admin:  ${GREEN}${internal_url}/admin${NC}"
    fi
    echo ""

    echo -e "  ${WHITE}${BOLD}Telegram Bot${NC}"
    echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
    echo -e "  ${ARROW}  Open Telegram and send ${WHITE}/start${NC} to your bot"
    echo -e "  ${ARROW}  The bot will respond if your user ID is authorized"
    echo ""

    echo -e "  ${WHITE}${BOLD}Admin Dashboard Setup${NC}"
    echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
    echo -e "  ${ARROW}  Visit ${WHITE}${dashboard_url}/admin${NC}"
    echo -e "  ${ARROW}  On first visit, you'll create an admin account"
    echo -e "  ${ARROW}  Optional: Enable 2FA for extra security"
    echo ""

    echo -e "  ${WHITE}${BOLD}Useful Commands${NC}"
    echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
    echo -e "  ${ARROW}  Service status:   ${GREEN}sudo systemctl status yetiforge${NC}"
    echo -e "  ${ARROW}  View logs:        ${GREEN}sudo journalctl -u yetiforge -f${NC}"
    echo -e "  ${ARROW}  Restart service:  ${GREEN}sudo systemctl restart yetiforge${NC}"
    echo -e "  ${ARROW}  Stop service:     ${GREEN}sudo systemctl stop yetiforge${NC}"
    echo -e "  ${ARROW}  Edit config:      ${GREEN}nano ${INSTALL_DIR}/.env${NC}"
    echo -e "  ${ARROW}  Update:           ${GREEN}sudo bash ${INSTALL_DIR}/deploy.sh update${NC}"
    echo -e "  ${ARROW}  Uninstall:        ${GREEN}sudo bash ${INSTALL_DIR}/deploy.sh uninstall${NC}"
    echo ""

    # Claude CLI — show post-install steps only if auth was skipped
    if [[ "$CLAUDE_AUTH_OK" != "true" ]]; then
        echo -e "  ${WHITE}${BOLD}Claude CLI Setup${NC}"
        echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
        echo -e "  ${ARROW}  Authenticate Claude with your Anthropic account:"
        echo ""
        echo -e "     ${GREEN}${BOLD}claude auth${NC}"
        echo ""
        echo -e "  ${ARROW}  Then restart the service:"
        echo ""
        echo -e "     ${GREEN}${BOLD}sudo systemctl restart yetiforge${NC}"
        echo ""
        echo -e "  ${ARROW}  Set up your admin account at:"
        echo ""
        echo -e "     ${GREEN}${BOLD}${dashboard_url}/admin${NC}"
        echo ""
    fi

    if [[ "$HAS_DOMAIN" == "true" && "$SSL_CONFIGURED" != "true" ]]; then
        echo -e "  ${WHITE}${BOLD}🔒 SSL Certificate${NC}"
        echo -e "  ${DIM}${DIVIDER_SUB}${NC}"
        echo -e "  ${ARROW}  Set up HTTPS: ${GREEN}sudo certbot --nginx -d ${CFG_DOMAIN}${NC}"
        echo ""
    fi

    echo -e "  ${DIM}Installation took ~${install_time} minute(s)${NC}"
    echo -e "  ${DIM}Log file: ${INSTALL_LOG}${NC}"
    echo -e "  ${DIM}Install dir: ${INSTALL_DIR}${NC}"
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Happy forging! ⚒️${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 14: run_update() (NEW)
# ══════════════════════════════════════════════════════════════════════════════

run_update() {
    TOTAL_STEPS=5
    show_banner

    echo -e "  ${WHITE}${BOLD}YetiForge Update Mode${NC}"
    echo -e "  ${DIM}Pulling latest code, rebuilding, and restarting the service.${NC}"
    echo ""

    # Step 1: Verify existing installation
    step_header "Verifying Installation"

    # Determine install dir
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo "")"

    if [[ -n "$script_dir" ]] && [[ -f "${script_dir}/package.json" ]]; then
        INSTALL_DIR="$script_dir"
    elif [[ -d "${DEFAULT_INSTALL_DIR}" ]] && [[ -f "${DEFAULT_INSTALL_DIR}/package.json" ]]; then
        INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
    elif [[ -f /etc/systemd/system/yetiforge.service ]]; then
        # Parse WorkingDirectory from the systemd unit as a fallback
        local systemd_dir
        systemd_dir=$(grep -oP '^WorkingDirectory=\K.+' /etc/systemd/system/yetiforge.service 2>/dev/null || true)
        if [[ -n "$systemd_dir" ]] && [[ -f "${systemd_dir}/package.json" ]]; then
            INSTALL_DIR="$systemd_dir"
        else
            log_error "No YetiForge installation found."
            log_info "Expected at ${DEFAULT_INSTALL_DIR} or in the current directory."
            exit 1
        fi
    else
        log_error "No YetiForge installation found."
        log_info "Expected at ${DEFAULT_INSTALL_DIR} or in the current directory."
        exit 1
    fi

    if [[ ! -f "${INSTALL_DIR}/package.json" ]]; then
        log_error "Invalid installation at ${INSTALL_DIR} — package.json not found."
        exit 1
    fi

    log_success "Installation found at ${INSTALL_DIR}"

    if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        log_warn "No .env file found — configuration may be missing"
    else
        log_success ".env configuration present"
    fi

    # Determine sudo
    if [[ $EUID -eq 0 ]]; then
        SUDO_CMD=""
        INSTALL_USER="root"
    elif sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
        INSTALL_USER=$(whoami)
    else
        log_error "Update requires root or sudo access."
        exit 1
    fi

    # Step 2: Stop service
    step_header "Stopping Service"

    if systemctl is-active --quiet yetiforge 2>/dev/null; then
        $SUDO_CMD systemctl stop yetiforge
        log_success "YetiForge service stopped"
    else
        log_info "Service was not running"
    fi

    # Step 3: Pull latest code
    step_header "Updating Code"

    cd "$INSTALL_DIR"

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        log_step "Fetching latest changes..."
        # Use PAT for authenticated fetch if available
        local pat="${YETIFORGE_GITHUB_PAT:-}"
        if [[ -z "$pat" ]] && [[ -f "${INSTALL_DIR}/.env" ]]; then
            pat=$(grep -oP '^GITHUB_PAT=\K.+' "${INSTALL_DIR}/.env" 2>/dev/null || true)
        fi
        if [[ -n "$pat" ]]; then
            local current_url
            current_url=$(git remote get-url origin 2>/dev/null || true)
            if [[ "$current_url" == https://github.com/* ]]; then
                git remote set-url origin "${current_url/https:\/\/github.com/https:\/\/${pat}@github.com}" 2>/dev/null || true
            fi
        fi
        git fetch origin "$INSTALL_BRANCH" >> "$INSTALL_LOG" 2>&1
        git reset --hard "origin/$INSTALL_BRANCH" >> "$INSTALL_LOG" 2>&1
        # Strip PAT from stored remote URL
        git remote set-url origin "$REPO_URL" 2>/dev/null || true
        local latest_commit
        latest_commit=$(git log -1 --oneline 2>/dev/null)
        log_success "Updated to: ${latest_commit}"
    else
        log_warn "Not a git repository — skipping code pull"
        log_info "Rebuilding from current source"
    fi

    # Step 4: Rebuild
    step_header "Rebuilding"

    log_step "Installing server dependencies..."
    npm install --production=false >> "$INSTALL_LOG" 2>&1 &
    spinner $! "Installing server dependencies..."
    wait $!
    log_success "Server dependencies installed"

    if [[ -f "${INSTALL_DIR}/status/client/package.json" ]]; then
        log_step "Installing dashboard dependencies..."
        cd "${INSTALL_DIR}/status/client"
        npm install --production=false >> "$INSTALL_LOG" 2>&1 &
        spinner $! "Installing dashboard dependencies..."
        wait $!
        log_success "Dashboard dependencies installed"
        cd "${INSTALL_DIR}"
    fi

    log_step "Compiling TypeScript..."
    npx tsc >> "$INSTALL_LOG" 2>&1 &
    spinner $! "Compiling TypeScript..."
    wait $!

    if [[ -f "${INSTALL_DIR}/dist/index.js" ]]; then
        log_success "TypeScript compiled"
    else
        log_error "TypeScript compilation failed"
        log_info "Check: ${INSTALL_LOG}"
        exit 1
    fi

    if [[ -f "${INSTALL_DIR}/status/client/package.json" ]]; then
        log_step "Building dashboard..."
        cd "${INSTALL_DIR}/status/client"
        npm run build >> "$INSTALL_LOG" 2>&1 &
        spinner $! "Building dashboard..."
        wait $!
        if [[ -f "${INSTALL_DIR}/status/client/dist/index.html" ]]; then
            log_success "Dashboard built"
        else
            log_warn "Dashboard build may have failed — continuing"
        fi
        cd "${INSTALL_DIR}"
    fi

    # Step 5: Restart + health check
    step_header "Restarting Service"

    $SUDO_CMD systemctl daemon-reload
    $SUDO_CMD systemctl start yetiforge

    sleep 3

    local status_port
    status_port=$(grep -E '^STATUS_PORT=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "$DEFAULT_PORT")
    status_port="${status_port:-$DEFAULT_PORT}"

    local health_ok=false
    local retries=0

    while [[ $retries -lt 5 ]]; do
        if curl -sf "http://localhost:${status_port}/api/health" > /dev/null 2>&1; then
            health_ok=true
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [[ "$health_ok" == "true" ]]; then
        log_success "Health check passed — YetiForge is running!"
    else
        log_warn "Health check failed — check logs with: sudo journalctl -u yetiforge -f"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}Update complete!${NC}"
    echo -e "  ${DIM}Log file: ${INSTALL_LOG}${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 15: run_uninstall() (from uninstall.sh)
# ══════════════════════════════════════════════════════════════════════════════

run_uninstall() {
    # Determine install dir
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo "")"

    if [[ -n "$script_dir" ]] && [[ -f "${script_dir}/package.json" ]]; then
        INSTALL_DIR="$script_dir"
    elif [[ -d "${DEFAULT_INSTALL_DIR}" ]] && [[ -f "${DEFAULT_INSTALL_DIR}/package.json" ]]; then
        INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
    elif [[ -f /etc/systemd/system/yetiforge.service ]]; then
        # Parse WorkingDirectory from the systemd unit as a fallback
        local systemd_dir
        systemd_dir=$(grep -oP '^WorkingDirectory=\K.+' /etc/systemd/system/yetiforge.service 2>/dev/null || true)
        if [[ -n "$systemd_dir" ]] && [[ -f "${systemd_dir}/package.json" ]]; then
            INSTALL_DIR="$systemd_dir"
        else
            echo -e "  ${CROSS}  ${RED}No YetiForge installation found.${NC}"
            exit 1
        fi
    else
        echo -e "  ${CROSS}  ${RED}No YetiForge installation found.${NC}"
        exit 1
    fi

    SUDO_CMD=""
    [[ $EUID -ne 0 ]] && SUDO_CMD="sudo"

    echo ""
    echo -e "  ${CYAN}${BOLD}YetiForge Uninstaller${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${WARN}  ${YELLOW}This will remove YetiForge from your system.${NC}"
    echo -e "  ${DIM}  Install directory: ${INSTALL_DIR}${NC}"
    echo ""

    if [[ "$AUTO_MODE" == "true" ]]; then
        CONFIRM_UNINSTALL=true
    else
        echo -en "  ${ARROW}  Are you sure you want to uninstall? ${DIM}[y/N]${NC}: "
        read -r confirm < /dev/tty
        if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
            echo -e "  ${CHECK}  Uninstall cancelled"
            exit 0
        fi
    fi

    echo ""

    # --- Stop and disable service ---
    if systemctl is-active --quiet yetiforge 2>/dev/null; then
        echo -e "  ${ARROW}  Stopping yetiforge service..."
        $SUDO_CMD systemctl stop yetiforge
        echo -e "  ${CHECK}  Service stopped"
    fi

    if systemctl is-enabled --quiet yetiforge 2>/dev/null; then
        echo -e "  ${ARROW}  Disabling yetiforge service..."
        $SUDO_CMD systemctl disable yetiforge >> /dev/null 2>&1
        echo -e "  ${CHECK}  Service disabled"
    fi

    if [[ -f /etc/systemd/system/yetiforge.service ]]; then
        $SUDO_CMD rm -f /etc/systemd/system/yetiforge.service
        $SUDO_CMD systemctl daemon-reload
        echo -e "  ${CHECK}  systemd unit file removed"
    fi

    # --- Remove nginx config ---
    if [[ -f /etc/nginx/sites-enabled/yetiforge ]]; then
        $SUDO_CMD rm -f /etc/nginx/sites-enabled/yetiforge
        echo -e "  ${CHECK}  Nginx site disabled"
    fi

    if [[ -f /etc/nginx/sites-available/yetiforge ]]; then
        $SUDO_CMD rm -f /etc/nginx/sites-available/yetiforge
        echo -e "  ${CHECK}  Nginx config removed"
    fi

    if command -v nginx &> /dev/null; then
        $SUDO_CMD systemctl reload nginx 2>/dev/null || true
    fi

    # --- Remove data? ---
    echo ""
    if [[ "$AUTO_MODE" == "true" ]]; then
        remove_data="y"
    else
        echo -en "  ${WARN}  Remove all data (database, sessions, backups)? ${DIM}[y/N]${NC}: "
        read -r remove_data < /dev/tty
    fi

    if [[ "${remove_data,,}" == "y" || "${remove_data,,}" == "yes" ]]; then
        if [[ -d "${INSTALL_DIR}/data" ]]; then
            rm -rf "${INSTALL_DIR}/data"
            echo -e "  ${CHECK}  Data directory removed"
        fi
    else
        echo -e "  ${CHECK}  Data preserved at ${INSTALL_DIR}/data"
    fi

    # --- Remove .env? ---
    if [[ "$AUTO_MODE" == "true" ]]; then
        remove_env="y"
    else
        echo -en "  ${WARN}  Remove .env configuration? ${DIM}[y/N]${NC}: "
        read -r remove_env < /dev/tty
    fi

    if [[ "${remove_env,,}" == "y" || "${remove_env,,}" == "yes" ]]; then
        if [[ -f "${INSTALL_DIR}/.env" ]]; then
            rm -f "${INSTALL_DIR}/.env"
            echo -e "  ${CHECK}  .env removed"
        fi
    else
        echo -e "  ${CHECK}  .env preserved"
    fi

    # --- Remove node_modules and dist? ---
    if [[ "$AUTO_MODE" == "true" ]]; then
        remove_build="y"
    else
        echo -en "  ${ARROW}  Remove build artifacts (node_modules, dist)? ${DIM}[Y/n]${NC}: "
        read -r remove_build < /dev/tty
        remove_build="${remove_build:-y}"
    fi

    if [[ "${remove_build,,}" == "y" || "${remove_build,,}" == "yes" ]]; then
        rm -rf "${INSTALL_DIR}/node_modules" "${INSTALL_DIR}/dist"
        rm -rf "${INSTALL_DIR}/status/client/node_modules" "${INSTALL_DIR}/status/client/dist"
        echo -e "  ${CHECK}  Build artifacts removed"
    fi

    # --- Remove entire directory? ---
    echo ""
    if [[ "$AUTO_MODE" == "true" ]]; then
        remove_all="y"
    else
        echo -en "  ${WARN}  Remove entire YetiForge directory (${INSTALL_DIR})? ${DIM}[y/N]${NC}: "
        read -r remove_all < /dev/tty
    fi

    if [[ "${remove_all,,}" == "y" || "${remove_all,,}" == "yes" ]]; then
        cd /
        rm -rf "${INSTALL_DIR}"
        echo -e "  ${CHECK}  Directory removed"
    fi

    # --- UFW cleanup ---
    if command -v ufw &> /dev/null; then
        echo ""
        if [[ "$AUTO_MODE" == "true" ]]; then
            remove_ufw="y"
        else
            echo -en "  ${ARROW}  Remove firewall rules for ports 80, 443, 3069? ${DIM}[y/N]${NC}: "
            read -r remove_ufw < /dev/tty
        fi

        if [[ "${remove_ufw,,}" == "y" || "${remove_ufw,,}" == "yes" ]]; then
            $SUDO_CMD ufw delete allow 3069/tcp 2>/dev/null || true
            echo -e "  ${CHECK}  Firewall rules cleaned up"
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}YetiForge has been uninstalled.${NC}"
    echo -e "  ${DIM}Node.js and Nginx were left installed (they may be used by other apps).${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 16: main() Dispatcher
# ══════════════════════════════════════════════════════════════════════════════

main() {
    # ── Setup logging ──
    INSTALL_LOG="/tmp/yetiforge-deploy-$(date +%Y%m%d%H%M%S).log"
    touch "$INSTALL_LOG"
    exec > >(tee -a "$INSTALL_LOG") 2>&1

    # ── Error trap ──
    trap 'handle_error $? ${LINENO} "$BASH_COMMAND"' ERR

    # ── Initialize state variables ──
    GIT_NEEDED=false
    FRESH_CONFIG=true
    SERVICE_WAS_RUNNING=false
    HAS_DOMAIN=false
    SSL_CONFIGURED=false
    CLAUDE_AUTH_OK=false
    UFW_AVAILABLE=false
    INSTALL_DIR=""
    SUDO_CMD=""
    INSTALL_USER=""

    case "$MODE" in
        install)
            show_banner

            echo -e "  ${WHITE}${BOLD}Welcome to the YetiForge installer!${NC}"
            echo -e "  ${DIM}This will set up everything you need to run YetiForge on this server.${NC}"
            echo ""

            if [[ "$AUTO_MODE" != "true" ]]; then
                prompt_yn "Ready to begin?" "y" BEGIN_INSTALL
                if [[ "$BEGIN_INSTALL" != "true" ]]; then
                    echo ""
                    log_info "Installation cancelled. Run again when you're ready!"
                    exit 0
                fi
            fi

            # Temporarily set INSTALL_DIR for preflight disk check
            # clone_or_update_repo will set the real value
            INSTALL_DIR="${DEFAULT_INSTALL_DIR}"

            run_preflight           # Step 1: System checks
            install_dependencies    # Step 2: Install Node, nginx, etc.
            clone_or_update_repo    # Step 3: Clone or detect repo
            run_configuration       # Step 4: Interactive config wizard
            install_claude_cli      # Claude CLI (within step 4 context)
            run_build               # Step 5: npm install + build
            setup_services          # Step 6: systemd + nginx
            setup_ssl               # Step 7: Optional SSL
            authenticate_claude     # Step 8: Claude CLI auth
            run_finalize            # Step 9: Health check + summary

            # Cleanup temp files
            rm -f /tmp/yetiforge.service /tmp/yetiforge-nginx.conf
            ;;

        update)
            run_update
            ;;

        uninstall)
            run_uninstall
            ;;

        *)
            echo "Unknown mode: ${MODE}"
            exit 1
            ;;
    esac
}

# ── Run ──
main

exit 0
