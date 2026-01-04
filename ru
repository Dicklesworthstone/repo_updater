#!/usr/bin/env bash
#
# ru - Repo Updater
#
# A beautiful, automation-friendly CLI for synchronizing GitHub repositories.
# Keep dozens (or hundreds) of repos in sync with a single command.
#
# FEATURES:
#   - Clone missing repos automatically
#   - Pull updates for existing repos
#   - Detect and report conflicts with resolution help
#   - Git plumbing for reliable status detection (no string parsing)
#   - Beautiful terminal UI with gum (with ANSI fallbacks)
#   - JSON output for scripting
#   - Meaningful exit codes for automation
#
# USAGE:
#   ru [command] [options]
#
# COMMANDS:
#   sync          Clone missing repos and pull updates (default)
#   status        Show repository status without making changes
#   init          Initialize configuration directory and files
#   add <repo>    Add a repository to your list
#   list          Show configured repositories
#   doctor        Run system diagnostics
#   self-update   Update ru to the latest version
#   config        Show or set configuration values
#   prune         Find and manage orphan repositories
#
# GLOBAL OPTIONS:
#   -h, --help           Show help message
#   -v, --version        Show version
#   --json               Output JSON to stdout
#   -q, --quiet          Minimal output (errors only)
#   --verbose            Detailed output
#   --non-interactive    Never prompt (for CI/automation)
#
# CONFIGURATION:
#   Config directory: ~/.config/ru/
#   Repo lists:       ~/.config/ru/repos.d/
#   Logs:             ~/.local/state/ru/logs/
#
# EXIT CODES:
#   0 - Success (all repos synced or already current)
#   1 - Partial failure (some repos failed)
#   2 - Conflicts exist (repos need manual resolution)
#   3 - Dependency/system error (gh missing, auth failed, doctor issues)
#   4 - Invalid arguments (bad CLI options, missing config)
#   5 - Interrupted sync detected (use --resume or --restart)
#
# REPOSITORY:
#   https://github.com/Dicklesworthstone/repo_updater
#
# LICENSE:
#   MIT License - Copyright (c) 2025 Jeffrey Emanuel
#
#==============================================================================

# Shell options: strict mode WITHOUT set -e
# We explicitly avoid set -e because:
#   1. `output=$(failing_cmd); exit_code=$?` exits before capturing exit_code
#   2. We need repos to continue processing after individual failures
#   3. Explicit error handling is more predictable
set -uo pipefail

# Basic sanity: this script relies heavily on $HOME for defaults.
: "${HOME:?ru: HOME must be set}"

# Bash >= 4.3 is required (namerefs + associative arrays). macOS ships Bash 3.2 by default.
if [[ -z "${BASH_VERSINFO[*]:-}" ]] || (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'ru: Bash >= 4.3 is required (found: %s)\n' "${BASH_VERSION:-unknown}" >&2

    # Check if we're on macOS and can offer to install via Homebrew
    if [[ "$OSTYPE" == "darwin"* ]]; then
        printf 'ru: On macOS, the system Bash is outdated.\n' >&2

        # Check if Homebrew is available and if we have an interactive terminal
        if command -v brew &>/dev/null && [[ -t 0 && -t 2 ]]; then
            printf '\n' >&2
            printf 'Would you like to install Bash 5.x via Homebrew now? [y/N] ' >&2
            read -r response
            case "${response:-}" in
                [yY]|[yY][eE][sS])
                    printf '\nInstalling Bash via Homebrew...\n' >&2
                    if brew install bash; then
                        printf '\n' >&2
                        printf '✓ Bash installed successfully!\n' >&2
                        printf '\n' >&2
                        printf 'Please run ru again using the new Bash:\n' >&2
                        # Handle both Apple Silicon (/opt/homebrew) and Intel (/usr/local) Macs
                        printf '  %s %s\n' "$(brew --prefix)/bin/bash" "${BASH_SOURCE[0]}" >&2
                        printf '\n' >&2
                        printf 'Or add this to your shell profile for permanent use:\n' >&2
                        printf '  alias ru="%s %s"\n' "$(brew --prefix)/bin/bash" "${BASH_SOURCE[0]}" >&2
                    else
                        printf '\n' >&2
                        printf '✗ Failed to install Bash via Homebrew\n' >&2
                        printf 'Try running: brew install bash\n' >&2
                    fi
                    ;;
                *)
                    printf '\n' >&2
                    printf 'To install manually: brew install bash\n' >&2
                    printf 'Then run: $(brew --prefix)/bin/bash %s\n' "${BASH_SOURCE[0]}" >&2
                    ;;
            esac
        else
            printf 'Install Bash: brew install bash\n' >&2
            printf 'Then run: $(brew --prefix)/bin/bash %s\n' "${BASH_SOURCE[0]}" >&2
        fi
    else
        printf 'ru: Install Bash 4.3+ from your package manager\n' >&2
    fi
    exit 3
fi

#==============================================================================
# SECTION 1: VERSION AND CONSTANTS
#==============================================================================

# Version: read from VERSION file, fallback to embedded
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    VERSION="$(cat "$SCRIPT_DIR/VERSION")"
fi

# GitHub repository constants (for self-update - used by cmd_self_update bd-1006)
# shellcheck disable=SC2034
RU_REPO_OWNER="Dicklesworthstone"
# shellcheck disable=SC2034
RU_REPO_NAME="repo_updater"
# shellcheck disable=SC2034
RU_GITHUB_API="https://api.github.com"

# XDG Base Directory defaults
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# ru-specific directories (can be overridden via env vars)
RU_CONFIG_DIR="${RU_CONFIG_DIR:-$XDG_CONFIG_HOME/ru}"
RU_STATE_DIR="${RU_STATE_DIR:-$XDG_STATE_HOME/ru}"
RU_CACHE_DIR="${RU_CACHE_DIR:-$XDG_CACHE_HOME/ru}"
RU_LOG_DIR="$RU_STATE_DIR/logs"

# Default configuration values
DEFAULT_PROJECTS_DIR="${RU_PROJECTS_DIR:-$HOME/projects}"
DEFAULT_LAYOUT="flat"           # flat | owner-repo | full
DEFAULT_UPDATE_STRATEGY="ff-only"  # ff-only | rebase | merge
DEFAULT_AUTOSTASH="false"
DEFAULT_PARALLEL="1"

#==============================================================================
# SECTION 2: ANSI COLOR DEFINITIONS
#==============================================================================

# Colors (disabled if stderr is not a terminal or NO_COLOR is set)
# We check -t 2 (stderr) because all log functions output to stderr
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

#==============================================================================
# SECTION 3: RUNTIME STATE VARIABLES
#==============================================================================

# These are set during argument parsing and runtime
COMMAND=""
PROJECTS_DIR=""
LAYOUT=""
UPDATE_STRATEGY=""
AUTOSTASH=""
PARALLEL=""
JSON_OUTPUT="false"
QUIET="false"
VERBOSE="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
CLONE_ONLY="false"
PULL_ONLY="false"
FETCH_REMOTES="true"

# Results tracking (NDJSON temp file)
RESULTS_FILE=""
RESULTS_LOCK_FILE=""

# Resume support
RESUME="false"
RESTART="false"
SYNC_INTERRUPTED="false"

# Init command options
INIT_EXAMPLE="false"

# Gum availability
GUM_AVAILABLE="false"

# Network timeout configuration (abort if transfer rate drops below threshold)
GIT_TIMEOUT="${GIT_TIMEOUT:-30}"  # Seconds before aborting slow operations
GIT_LOW_SPEED_LIMIT="${GIT_LOW_SPEED_LIMIT:-1000}"  # Bytes/second threshold

#==============================================================================
# SECTION 4: CORE UTILITIES
#==============================================================================

# Check if running interactively (TTY attached)
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Check if we can prompt the user (interactive and not --non-interactive)
can_prompt() {
    is_interactive && [[ "$NON_INTERACTIVE" != "true" ]]
}

# Ensure a directory exists
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# mktemp compatibility: BSD (macOS) mktemp requires a template or -t.
mktemp_file() {
    local tmp
    if tmp=$(mktemp 2>/dev/null); then
        printf '%s\n' "$tmp"
        return 0
    fi
    tmp=$(mktemp -t ru 2>/dev/null) || return 1
    printf '%s\n' "$tmp"
}

mktemp_dir() {
    local tmp
    if tmp=$(mktemp -d 2>/dev/null); then
        printf '%s\n' "$tmp"
        return 0
    fi
    tmp=$(mktemp -d -t ru 2>/dev/null) || return 1
    printf '%s\n' "$tmp"
}

# Expand a leading "~" (bash doesn't expand tildes in variables)
# shellcheck disable=SC2088  # Tilde is used as literal pattern, not expansion
expand_tilde() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf '%s\n' "$HOME"
    elif [[ "$path" == "~/"* ]]; then
        printf '%s\n' "$HOME/${path:2}"
    else
        printf '%s\n' "$path"
    fi
}

# Validation helpers
is_positive_int() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#${1:-0} > 0 )); }
is_boolean() { [[ "${1:-}" == "true" || "${1:-}" == "false" ]]; }
is_valid_config_key() { [[ "${1:-}" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

# Escape a string for JSON (handles quotes, backslashes, control characters)
json_escape() {
    local str="$1"
    # Escape backslashes first, then quotes, then control characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\b'/\\b}"
    str="${str//$'\f'/\\f}"
    printf '%s\n' "$str"
}

# Write a result to the NDJSON results file
write_result() {
    local repo_name="$1"
    local action="$2"
    local status="$3"
    local duration="${4:-}"
    local message="${5:-}"
    local local_path="${6:-}"  # Optional: full local path for accurate reporting

    if [[ -n "$RESULTS_FILE" ]]; then
        # Escape all string fields for JSON safety
        local safe_repo safe_message safe_path safe_action safe_status
        safe_repo=$(json_escape "$repo_name")
        safe_message=$(json_escape "$message")
        safe_path=$(json_escape "$local_path")
        safe_action=$(json_escape "$action")
        safe_status=$(json_escape "$status")

        # Validate duration is numeric
        local duration_num="${duration:-0}"
        [[ "$duration_num" =~ ^[0-9]+$ ]] || duration_num=0

        local ts line
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf -v line '{"repo":"%s","path":"%s","action":"%s","status":"%s","duration":%s,"message":"%s","timestamp":"%s"}\n' \
            "$safe_repo" "$safe_path" "$safe_action" "$safe_status" "$duration_num" "$safe_message" "$ts"

        # In parallel mode multiple processes append concurrently; lock if flock is available
        if [[ -n "${RESULTS_LOCK_FILE:-}" ]] && command -v flock &>/dev/null; then
            { flock -x 200; printf '%s' "$line" >> "$RESULTS_FILE"; } 200>"$RESULTS_LOCK_FILE"
        else
            printf '%s' "$line" >> "$RESULTS_FILE"
        fi
    fi
}

#==============================================================================
# SECTION 5: LOGGING FUNCTIONS
# Stream separation: stderr for humans, stdout for data
#==============================================================================

log_info() {
    [[ "$QUIET" == "true" ]] && return
    printf '%b\n' "${BLUE}ℹ${RESET} $*" >&2
}

log_success() {
    [[ "$QUIET" == "true" ]] && return
    printf '%b\n' "${GREEN}✓${RESET} $*" >&2
}

log_warn() {
    printf '%b\n' "${YELLOW}⚠${RESET} $*" >&2
}

log_error() {
    printf '%b\n' "${RED}✗${RESET} $*" >&2
}

log_step() {
    [[ "$QUIET" == "true" ]] && return
    printf '%b\n' "${CYAN}→${RESET} $*" >&2
}

log_verbose() {
    [[ "$VERBOSE" != "true" ]] && return
    printf '%b\n' "${DIM}$*${RESET}" >&2
}

# Output JSON to stdout (only in --json mode)
output_json() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$1"
    fi
}

#==============================================================================
# SECTION 6: HELP AND VERSION
#==============================================================================

show_version() {
    echo "ru version $VERSION"
}

show_help() {
    cat >&2 << 'EOF'
ru - Repo Updater

A beautiful, automation-friendly CLI for synchronizing GitHub repositories.

USAGE:
    ru [command] [options]

COMMANDS:
    sync            Clone missing repos and pull updates (default)
    status          Show repository status without making changes
    init            Initialize configuration directory and files
    add <repo>      Add a repository to your list
    remove <repo>   Remove a repository from your list
    list            Show configured repositories
    doctor          Run system diagnostics
    self-update     Update ru to the latest version
    config          Show or set configuration values
    prune           Find and manage orphan repositories
    import <file>   Import repos from file with auto visibility detection
    review          Review GitHub issues and PRs using Claude Code

GLOBAL OPTIONS:
    -h, --help           Show this help message
    -v, --version        Show version
    --json               Output JSON to stdout
    -q, --quiet          Minimal output (errors only)
    --verbose            Detailed output
    --non-interactive    Never prompt (for CI/automation)

SYNC OPTIONS:
    --clone-only         Only clone missing repos, don't pull
    --pull-only          Only pull existing repos, don't clone
    --autostash          Stash changes before pull, pop after
    --rebase             Use git pull --rebase
    --dry-run            Show what would happen without making changes
    --dir PATH           Override projects directory
    --parallel N, -j N   Sync N repos concurrently (default: 1, sequential)
    --resume             Resume an interrupted sync from where it left off
    --restart            Discard interrupted sync state and start fresh
    --timeout SECONDS    Network timeout for slow operations (default: 30)

STATUS OPTIONS:
    --fetch              Fetch remotes first (default)
    --no-fetch           Skip fetch, use cached state

INIT OPTIONS:
    --example            Include example repositories in initial config

ADD OPTIONS:
    --private            Add to private.txt instead of repos.txt
    --from-cwd           Detect repo from current working directory

LIST OPTIONS:
    --paths              Show local paths instead of URLs
    --public             Show only repos from repos.txt
    --private            Show only repos from private.txt

PRUNE OPTIONS:
    (no options)         List orphan repositories (dry run)
    --archive            Move orphans to archive directory
    --delete             Delete orphans (requires confirmation)

IMPORT OPTIONS:
    --public             Force all repos to be added as public
    --private            Force all repos to be added as private
    --dry-run            Preview import without modifying config

REVIEW OPTIONS:
    --plan               Generate review plans only, no mutations (default)
    --apply              Execute approved plans from previous --plan run
    --mode=MODE          Driver: auto, ntm, or local (default: auto)
    --parallel=N, -jN    Concurrent review sessions (default: 4)
    --repos=PATTERN      Filter repos by pattern
    --priority=LEVEL     Min priority: all, critical, high, normal, low
    --skip-days=N        Skip repos reviewed within N days (default: 7)
    --dry-run            Discovery only, don't start sessions
    --resume             Resume interrupted review from checkpoint
    --push               Allow pushing changes (with --apply)
    --max-repos=N        Limit number of repos to review
    --max-runtime=MIN    Time budget in minutes
    --max-questions=N    Question budget before pausing

EXAMPLES:
    ru sync              Sync all configured repos
    ru sync --dry-run    Preview sync without changes
    ru status            Show status of all repos
    ru add owner/repo    Add a repository
    ru remove owner/repo Remove a repository
    ru doctor            Check system configuration
    ru prune             Find orphan repos not in config
    ru prune --archive   Archive orphan repos
    ru import repos.txt  Import repos from file (auto-detects visibility)
    ru review --dry-run  Discover issues/PRs without starting reviews
    ru review            Start AI-assisted review of issues/PRs
    ru review --apply    Execute approved changes from plan

CONFIGURATION:
    Config:  ~/.config/ru/config
    Repos:   ~/.config/ru/repos.d/repos.txt
    Logs:    ~/.local/state/ru/logs/

EXIT CODES:
    0  Success
    1  Partial failure (some repos failed)
    2  Conflicts exist (need manual resolution)
    3  Dependency/system error (gh missing, auth failed, doctor issues)
    4  Invalid arguments
    5  Interrupted sync detected (use --resume or --restart)

More info: https://github.com/Dicklesworthstone/repo_updater
EOF
}

#==============================================================================
# SECTION 7: CONFIGURATION
#==============================================================================

# Get a configuration value with priority: CLI > env > file > default
get_config_value() {
    local key="$1"
    local default="$2"
    local cli_value="${3:-}"
    local env_var="RU_${key^^}"  # Uppercase key with RU_ prefix

    # Priority 1: CLI argument
    if [[ -n "$cli_value" ]]; then
        echo "$cli_value"
        return
    fi

    # Priority 2: Environment variable
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return
    fi

    # Priority 3: Config file
    local config_file="$RU_CONFIG_DIR/config"
    if [[ -f "$config_file" ]]; then
        local file_value
        file_value=$(grep "^${key}=" "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$file_value" ]]; then
            echo "$file_value"
            return
        fi
    fi

    # Priority 4: Default
    echo "$default"
}

# Resolve all configuration values
resolve_config() {
    PROJECTS_DIR=$(get_config_value "PROJECTS_DIR" "$DEFAULT_PROJECTS_DIR" "$PROJECTS_DIR")
    LAYOUT=$(get_config_value "LAYOUT" "$DEFAULT_LAYOUT" "$LAYOUT")
    UPDATE_STRATEGY=$(get_config_value "UPDATE_STRATEGY" "$DEFAULT_UPDATE_STRATEGY" "$UPDATE_STRATEGY")
    AUTOSTASH=$(get_config_value "AUTOSTASH" "$DEFAULT_AUTOSTASH" "$AUTOSTASH")
    PARALLEL=$(get_config_value "PARALLEL" "$DEFAULT_PARALLEL" "$PARALLEL")
}

# Set a configuration value in the config file
set_config_value() {
    local key="$1"
    local value="$2"
    local config_file="$RU_CONFIG_DIR/config"

    ensure_dir "$RU_CONFIG_DIR"

    # If config file doesn't exist, create it with header
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << 'EOF'
# ru configuration file
# See: https://github.com/Dicklesworthstone/repo_updater
#
# Configuration priority: CLI args > environment variables > this file > defaults
EOF
    fi

    # Check if key already exists
    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        # Escape special sed replacement characters in value:
        #   & means "matched text" in sed replacement
        #   \ is the escape character
        #   | is our delimiter
        local escaped_value="$value"
        escaped_value="${escaped_value//\\/\\\\}"  # Escape backslashes first
        escaped_value="${escaped_value//&/\\&}"    # Escape ampersands
        escaped_value="${escaped_value//|/\\|}"    # Escape our delimiter

        # Update existing key (use sed with different delimiter for paths with /)
        # macOS sed requires -i '' while GNU sed uses -i
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${escaped_value}|" "$config_file"
        else
            sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$config_file"
        fi
    else
        # Append new key
        echo "${key}=${value}" >> "$config_file"
    fi
}

# Ensure config directory and default files exist
ensure_config_exists() {
    local created_any="false"

    # Create config directory
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        ensure_dir "$RU_CONFIG_DIR"
        created_any="true"
    fi

    # Create repos.d directory
    local repos_dir="$RU_CONFIG_DIR/repos.d"
    if [[ ! -d "$repos_dir" ]]; then
        ensure_dir "$repos_dir"
        created_any="true"
    fi

    # Create default config file
    local config_file="$RU_CONFIG_DIR/config"
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << EOF
# ru configuration file
# See: https://github.com/Dicklesworthstone/repo_updater
#
# Configuration priority: CLI args > environment variables > this file > defaults

# Base directory for repositories
PROJECTS_DIR=$DEFAULT_PROJECTS_DIR

# Directory layout: flat | owner-repo | full
#   flat:       \$PROJECTS_DIR/repo
#   owner-repo: \$PROJECTS_DIR/owner/repo
#   full:       \$PROJECTS_DIR/github.com/owner/repo
LAYOUT=$DEFAULT_LAYOUT

# Update strategy: ff-only | rebase | merge
UPDATE_STRATEGY=$DEFAULT_UPDATE_STRATEGY

# Auto-stash local changes before pull
AUTOSTASH=$DEFAULT_AUTOSTASH

# Parallel operations (1 = serial)
PARALLEL=$DEFAULT_PARALLEL
EOF
        created_any="true"
        log_verbose "Created config file: $config_file"
    fi

    # Create repos.txt (simplified single file instead of public.txt/private.txt)
    local repos_file="$repos_dir/repos.txt"
    if [[ ! -f "$repos_file" ]]; then
        cat > "$repos_file" << 'EOF'
# Repository list for ru
# Add one repository per line
#
# Supported formats:
#   owner/repo                    - GitHub shorthand
#   owner/repo@branch             - Pin to specific branch
#   https://github.com/owner/repo - Full URL
#   git@github.com:owner/repo.git - SSH URL
#
# Examples:
#   charmbracelet/gum
#   cli/cli@main
#   koalaman/shellcheck
EOF
        created_any="true"
        log_verbose "Created repos file: $repos_file"
    fi

    # Create state directories
    if [[ ! -d "$RU_STATE_DIR" ]]; then
        ensure_dir "$RU_STATE_DIR"
    fi
    if [[ ! -d "$RU_LOG_DIR" ]]; then
        ensure_dir "$RU_LOG_DIR"
    fi

    echo "$created_any"
}

#==============================================================================
# SECTION 8: GUM INTEGRATION
#==============================================================================

# Check if gum is available
check_gum() {
    if command -v gum &>/dev/null; then
        GUM_AVAILABLE="true"
    fi
}

# Confirm prompt with gum fallback
gum_confirm() {
    local prompt="$1"
    local default="${2:-false}"

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        if gum confirm "$prompt"; then
            return 0
        else
            return 1
        fi
    else
        # ANSI fallback
        local yn
        if [[ "$default" == "true" ]]; then
            read -rp "$prompt [Y/n] " yn
            case "${yn,,}" in
                n|no) return 1 ;;
                *) return 0 ;;
            esac
        else
            read -rp "$prompt [y/N] " yn
            case "${yn,,}" in
                y|yes) return 0 ;;
                *) return 1 ;;
            esac
        fi
    fi
}

# Print styled banner at startup
print_banner() {
    [[ "$QUIET" == "true" ]] && return

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        gum style --border rounded --padding "0 2" \
            "🔄 ru v$VERSION" "Repo Updater" >&2
    else
        printf '%b\n' "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&2
        printf '%b\n' "  ${BOLD}ru${RESET} v$VERSION - Repo Updater" >&2
        printf '%b\n' "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&2
    fi
}

# Show spinner during operation with fallback
gum_spin() {
    local title="$1"
    shift

    if [[ "$GUM_AVAILABLE" == "true" && "$QUIET" != "true" ]]; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        [[ "$QUIET" != "true" ]] && printf '%b\n' "${CYAN}→${RESET} $title" >&2
        "$@"
    fi
}

#==============================================================================
# SECTION 8.1: DEPENDENCY MANAGEMENT
#==============================================================================

# Check if gh CLI is installed
check_gh_installed() {
    command -v gh &>/dev/null
}

# Check if gh CLI is authenticated
check_gh_auth() {
    gh auth status &>/dev/null
}

# Ensure dependencies are available
# Returns: 0 if all deps OK, 3 if missing/failed
ensure_dependencies() {
    local require_auth="${1:-true}"

    # Check for gh CLI
    if ! check_gh_installed; then
        log_error "GitHub CLI (gh) is not installed"
        echo "" >&2
        log_info "Install gh:"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_info "  brew install gh"
        else
            log_info "  sudo apt install gh   # Debian/Ubuntu"
            log_info "  sudo dnf install gh   # Fedora"
        fi
        log_info "  See: https://cli.github.com/"

        if can_prompt; then
            echo "" >&2
            if gum_confirm "Would you like to open the install page?"; then
                open "https://cli.github.com/" 2>/dev/null || \
                    xdg-open "https://cli.github.com/" 2>/dev/null || true
            fi
        fi
        return 3
    fi

    # Check authentication if required
    if [[ "$require_auth" == "true" ]] && ! check_gh_auth; then
        log_error "GitHub CLI (gh) is not authenticated"
        echo "" >&2

        if can_prompt; then
            log_info "Run: gh auth login"
            if gum_confirm "Would you like to authenticate now?"; then
                if gh auth login; then
                    log_success "Authentication successful"
                    return 0
                else
                    log_error "Authentication failed"
                    return 3
                fi
            fi
        else
            log_info "Authenticate with:"
            log_info "  gh auth login          # Interactive"
            log_info "  export GH_TOKEN=...    # Non-interactive"
        fi
        return 3
    fi

    return 0
}

# Detect operating system
detect_os() {
    case "$OSTYPE" in
        darwin*)  echo "macos" ;;
        linux*)   echo "linux" ;;
        msys*|cygwin*|mingw*) echo "windows" ;;
        *)        echo "unknown" ;;
    esac
}

#==============================================================================
# SECTION 9: URL & PATH PARSING
#==============================================================================

# Validate a path segment is safe (no path traversal, no command injection)
# Returns: 0 if safe, 1 if unsafe
_is_safe_path_segment() {
    local segment="$1"
    # Reject empty
    [[ -z "$segment" ]] && return 1
    # Reject dot-only names (path traversal: . or ..)
    [[ "$segment" =~ ^\.+$ ]] && return 1
    # Reject leading dash (could be confused with git options)
    [[ "$segment" == -* ]] && return 1
    # Reject path separators (path traversal via subdirectories)
    [[ "$segment" == */* || "$segment" == *\\* ]] && return 1
    # Reject control characters (security: prevent terminal escape sequences)
    [[ "$segment" =~ [[:cntrl:]] ]] && return 1
    return 0
}

# Parse all GitHub URL formats and extract components
# Supports: https://github.com/owner/repo, git@github.com:owner/repo.git,
#           github.com/owner/repo, owner/repo (assumes github.com)
# Uses nameref (-n) to return multiple values (requires Bash 4.3+)
parse_repo_url() {
    local url="$1"
    local -n _host=$2
    local -n _owner=$3
    local -n _repo=$4

    # Normalize: strip .git suffix and trailing slashes
    url="${url%.git}"
    url="${url%/}"

    local matched="false"

    # SSH scp-like format: git@host:owner/repo (repo must not contain /)
    if [[ "$url" =~ ^git@([^:]+):([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
        matched="true"
    # SSH URL format: ssh://git@host/owner/repo (optional user part)
    elif [[ "$url" =~ ^ssh://([^@/]+@)?([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[2]}"
        _owner="${BASH_REMATCH[3]}"
        _repo="${BASH_REMATCH[4]}"
        matched="true"
    # HTTPS format: https://host/owner/repo (optional user@ for auth)
    elif [[ "$url" =~ ^https?://([^@/]+@)?([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[2]}"
        _owner="${BASH_REMATCH[3]}"
        _repo="${BASH_REMATCH[4]}"
        matched="true"
    # Host/owner/repo format (no protocol): github.com/owner/repo
    elif [[ "$url" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
        matched="true"
    # Shorthand: owner/repo (assumes github.com)
    elif [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
        _host="github.com"
        _owner="${BASH_REMATCH[1]}"
        _repo="${BASH_REMATCH[2]}"
        matched="true"
    fi

    # Validate parsed components for path safety
    if [[ "$matched" == "true" ]]; then
        # Strip optional :port from host (avoid filesystem-unfriendly ':' in full layout)
        _host="${_host%%:*}"
        if ! _is_safe_path_segment "$_owner" || ! _is_safe_path_segment "$_repo"; then
            return 1
        fi
        return 0
    fi

    # Invalid format
    return 1
}

# Normalize URL to canonical HTTPS form
normalize_url() {
    local url="$1"
    local host owner repo

    if ! parse_repo_url "$url" host owner repo; then
        echo ""
        return 1
    fi

    echo "https://${host}/${owner}/${repo}"
}

# Convert URL to local filesystem path based on layout setting
# Layout modes:
#   flat:       $PROJECTS_DIR/repo
#   owner-repo: $PROJECTS_DIR/owner/repo
#   full:       $PROJECTS_DIR/host/owner/repo
url_to_local_path() {
    local url="$1"
    local projects_dir="${2:-$PROJECTS_DIR}"
    local layout="${3:-$LAYOUT}"

    local host owner repo
    if ! parse_repo_url "$url" host owner repo; then
        log_error "Failed to parse URL: $url"
        return 1
    fi

    case "$layout" in
        flat)
            echo "${projects_dir}/${repo}"
            ;;
        owner-repo)
            echo "${projects_dir}/${owner}/${repo}"
            ;;
        full)
            echo "${projects_dir}/${host}/${owner}/${repo}"
            ;;
        *)
            log_error "Unknown layout: $layout"
            return 1
            ;;
    esac
}

# Convert URL to clone target for gh repo clone (owner/repo format)
url_to_clone_target() {
    local url="$1"
    local host owner repo

    if ! parse_repo_url "$url" host owner repo; then
        log_error "Failed to parse URL: $url"
        return 1
    fi

    echo "${owner}/${repo}"
}

# Sanitize a path segment for filesystem safety
# Removes/replaces dangerous characters to prevent path traversal and other issues
sanitize_path_segment() {
    local segment="$1"

    # Reject empty input
    [[ -z "$segment" ]] && return 1

    # Remove leading/trailing whitespace
    segment="${segment#"${segment%%[![:space:]]*}"}"
    segment="${segment%"${segment##*[![:space:]]}"}"

    # Replace potentially problematic characters
    segment="${segment//\//_}"    # Forward slash
    segment="${segment//\\/_}"    # Backslash
    segment="${segment//:/_}"     # Colon (problematic on Windows)
    segment="${segment//\*/_}"    # Asterisk
    segment="${segment//\?/_}"    # Question mark
    segment="${segment//\"/_}"    # Double quote
    segment="${segment//\</_}"    # Less than
    segment="${segment//\>/_}"    # Greater than
    segment="${segment//\|/_}"    # Pipe

    # Remove leading dots (hidden files/directories)
    while [[ "$segment" == .* ]]; do
        segment="${segment#.}"
    done

    # Reject if empty after sanitization
    [[ -z "$segment" ]] && return 1

    echo "$segment"
}

#==============================================================================
# SECTION 9B: REPO LIST MANAGEMENT
# Loading, parsing, and deduplication of repository lists
#==============================================================================

# Load repositories from a list file
# Skips comments (#) and blank lines, trims whitespace
# Args: file_path
# Output: One repo spec per line
load_repo_list() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 0  # Empty list, not an error
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip if empty after trimming
        [[ -z "$line" ]] && continue

        echo "$line"
    done < "$file"
}

# Parse a repo specification with optional branch and custom name
# Syntax patterns:
#   owner/repo                    -> url, empty branch, empty local_name
#   owner/repo@develop            -> url, develop branch, empty local_name
#   owner/repo as myname          -> url, empty branch, myname local_name
#   owner/repo@develop as myname  -> url, develop branch, myname local_name
#   owner/repo@feature/foo        -> url, feature/foo branch (branches can contain /)
# Args: spec, url_var, branch_var, local_name_var (namerefs)
parse_repo_spec() {
    local spec="$1"
    local -n _prs_url=$2
    local -n _prs_branch=$3
    local -n _prs_local_name=$4

    # Extract 'as <name>' if present (must be last)
    if [[ "$spec" =~ ^(.+)[[:space:]]+as[[:space:]]+([^[:space:]]+)$ ]]; then
        spec="${BASH_REMATCH[1]}"
        # Trim trailing whitespace from spec (greedy .+ may capture trailing spaces)
        spec="${spec%"${spec##*[![:space:]]}"}"
        _prs_local_name="${BASH_REMATCH[2]}"
    else
        _prs_local_name=""
    fi

    # Default: no branch
    _prs_url="$spec"
    _prs_branch=""

    # Extract '@branch' by splitting on the LAST '@' and only accepting it if the
    # left side is a valid repo URL. This avoids mis-parsing ssh://git@host/... forms
    # while still supporting branch names with / like feature/foo
    if [[ "$spec" == *"@"* ]]; then
        local maybe_url maybe_branch host owner repo
        maybe_url="${spec%@*}"
        maybe_branch="${spec##*@}"
        # Only accept as branch if: left side parses as URL, branch is non-empty and has no spaces
        if [[ -n "$maybe_url" && -n "$maybe_branch" && "$maybe_branch" != *[[:space:]]* ]]; then
            if parse_repo_url "$maybe_url" host owner repo; then
                _prs_url="$maybe_url"
                _prs_branch="$maybe_branch"
            fi
        fi
    fi
}

# Resolve a repo spec into validated parts and a local path
# This is the central function for parsing and validating repo specifications.
# Args: spec projects_dir layout url_var branch_var custom_var path_var repo_id_var (namerefs)
# repo_id is canonical for reporting (host/owner/repo, or owner/repo for github.com)
# Returns: 0 on success, 1 on invalid spec
resolve_repo_spec() {
    local spec="$1"
    local projects_dir="$2"
    local layout="$3"
    local -n _rrs_url=$4
    local -n _rrs_branch=$5
    local -n _rrs_custom=$6
    local -n _rrs_path=$7
    local -n _rrs_repo_id=$8

    # Use unique prefixes to avoid shadowing caller's nameref targets and
    # avoid conflicts with namerefs in parse_repo_spec and parse_repo_url
    local spec_url spec_branch spec_custom spec_host spec_owner spec_repo
    parse_repo_spec "$spec" spec_url spec_branch spec_custom

    # Validate branch name to prevent option-injection into git checkout/switch
    if [[ -n "$spec_branch" ]]; then
        # Reject branches starting with - (option injection)
        [[ "$spec_branch" == -* ]] && return 1
        # Use git to validate ref format if available
        if command -v git &>/dev/null; then
            git check-ref-format --branch "$spec_branch" >/dev/null 2>&1 || return 1
        fi
    fi

    # Parse and validate the URL
    if ! parse_repo_url "$spec_url" spec_host spec_owner spec_repo; then
        return 1
    fi

    # Validate custom name if provided
    if [[ -n "$spec_custom" ]]; then
        _is_safe_path_segment "$spec_custom" || return 1
        _rrs_path="${projects_dir}/${spec_custom}"
    else
        case "$layout" in
            flat)       _rrs_path="${projects_dir}/${spec_repo}" ;;
            owner-repo) _rrs_path="${projects_dir}/${spec_owner}/${spec_repo}" ;;
            full)       _rrs_path="${projects_dir}/${spec_host}/${spec_owner}/${spec_repo}" ;;
            *)          return 1 ;;
        esac
    fi

    _rrs_url="$spec_url"
    _rrs_branch="$spec_branch"
    _rrs_custom="$spec_custom"

    # Build canonical repo ID for display/reporting
    if [[ "$spec_host" == "github.com" ]]; then
        _rrs_repo_id="${spec_owner}/${spec_repo}"
    else
        _rrs_repo_id="${spec_host}/${spec_owner}/${spec_repo}"
    fi

    return 0
}

# Deduplicate repos by resolved local path
# Input: lines of repo specs (stdin)
# Output: unique repo specs by path (first occurrence wins)
dedupe_repos() {
    local -A seen_paths

    while IFS= read -r spec; do
        local url branch local_name path repo_id
        if ! resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch local_name path repo_id; then
            log_warn "Skipping invalid repo spec: $spec"
            continue
        fi

        if [[ -z "${seen_paths[$path]:-}" ]]; then
            seen_paths[$path]=1
            echo "$spec"
        else
            log_verbose "Skipping duplicate: $spec (same path as previous)"
        fi
    done
}

# Detect path collisions (different repos -> same path)
# Input: lines of repo specs (stdin)
# Output: collision warnings to stderr, return 1 if collisions found
detect_collisions() {
    local -A path_to_repo
    local collisions=0

    while IFS= read -r spec; do
        local url branch local_name path repo_id
        if ! resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch local_name path repo_id; then
            log_warn "Invalid repo spec (cannot check collisions): $spec"
            ((collisions++))
            continue
        fi

        # Build display label
        local repo_label="$repo_id"
        [[ -n "$local_name" ]] && repo_label="${repo_id} as ${local_name}"

        if [[ -n "${path_to_repo[$path]:-}" && "${path_to_repo[$path]}" != "$repo_label" ]]; then
            log_warn "Collision detected:"
            log_warn "  Path: $path"
            log_warn "  Configured: ${path_to_repo[$path]} (will be synced)"
            log_warn "  Skipped:    $repo_label (same path)"
            log_warn "  To fix: Change layout to 'owner-repo' in config"
            ((collisions++))
        else
            path_to_repo[$path]="$repo_label"
        fi
    done

    [[ $collisions -eq 0 ]]
}

# Get all repos from all list files in repos.d/
# Output: unique repo specs (deduplicated)
get_all_repos() {
    local repos_dir="${RU_CONFIG_DIR}/repos.d"
    local all_repos=""

    if [[ ! -d "$repos_dir" ]]; then
        return 0
    fi

    # Process all .txt files in repos.d/
    for list_file in "$repos_dir"/*.txt; do
        [[ -f "$list_file" ]] || continue

        while IFS= read -r spec; do
            all_repos+="${spec}"$'\n'
        done < <(load_repo_list "$list_file")
    done

    # Deduplicate and output
    if [[ -n "$all_repos" ]]; then
        echo -n "$all_repos" | dedupe_repos
    fi
}

#==============================================================================
# SECTION 10: GIT OPERATIONS
# Uses git plumbing for reliable status detection (no string parsing)
#==============================================================================

# Check if directory is a valid git repository
is_git_repo() {
    local dir="$1"
    # Fast check for .git directory, then verify with plumbing
    [[ -d "$dir/.git" ]] || git -C "$dir" rev-parse --git-dir &>/dev/null
}

# Get repository status using git plumbing
# Returns: STATUS=<status> AHEAD=<n> BEHIND=<n> DIRTY=<bool> BRANCH=<name>
# Status values: current, ahead, behind, diverged, no_upstream, not_git
get_repo_status() {
    local repo_path="$1"
    local do_fetch="${2:-false}"

    # Check if it's a git repo
    if ! is_git_repo "$repo_path"; then
        echo "STATUS=not_git AHEAD=0 BEHIND=0 DIRTY=false BRANCH="
        return 1
    fi

    # Fetch if requested
    if [[ "$do_fetch" == "true" ]]; then
        git -C "$repo_path" fetch --quiet 2>/dev/null || true
    fi

    # Check dirty status using porcelain (machine-readable)
    local dirty="false"
    if [[ -n $(git -C "$repo_path" status --porcelain 2>/dev/null) ]]; then
        dirty="true"
    fi

    # Get current branch
    local branch
    branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

    # Check for upstream tracking branch
    if ! git -C "$repo_path" rev-parse --verify '@{u}' &>/dev/null; then
        echo "STATUS=no_upstream AHEAD=0 BEHIND=0 DIRTY=$dirty BRANCH=$branch"
        return 0
    fi

    # Get ahead/behind counts using plumbing (deterministic, locale-independent)
    local ahead=0 behind=0
    # shellcheck disable=SC1083  # @{u} is valid git syntax for upstream tracking branch
    read -r ahead behind < <(git -C "$repo_path" rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0 0")

    # Determine status based on ahead/behind
    local status
    if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        status="current"
    elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
        status="behind"
    elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
        status="ahead"
    else
        status="diverged"
    fi

    echo "STATUS=$status AHEAD=$ahead BEHIND=$behind DIRTY=$dirty BRANCH=$branch"
}

# Get the remote URL for a repository
get_remote_url() {
    local repo_path="$1"
    local remote="${2:-origin}"
    git -C "$repo_path" remote get-url "$remote" 2>/dev/null
}

# Check if local repo's remote matches expected URL
# Returns 0 (true) if there IS a mismatch or missing remote
# Returns 1 (false) if remotes match correctly
check_remote_mismatch() {
    local repo_path="$1"
    local expected_url="$2"

    local actual_url
    actual_url=$(get_remote_url "$repo_path")
    if [[ -z "$actual_url" ]]; then
        return 0  # No remote = treat as mismatch
    fi

    # Normalize both URLs for comparison
    local expected_normalized actual_normalized
    if ! expected_normalized=$(normalize_url "$expected_url"); then
        log_verbose "Could not normalize expected URL: $expected_url"
        return 0  # Can't normalize = treat as mismatch
    fi
    if ! actual_normalized=$(normalize_url "$actual_url"); then
        log_verbose "Could not normalize actual URL: $actual_url"
        return 0  # Can't normalize = treat as mismatch
    fi

    [[ "$expected_normalized" != "$actual_normalized" ]]
}

# Set up git environment for network timeouts
# These variables cause git to abort if transfer rate drops too low for too long
setup_git_timeout() {
    export GIT_HTTP_LOW_SPEED_LIMIT="$GIT_LOW_SPEED_LIMIT"
    export GIT_HTTP_LOW_SPEED_TIME="$GIT_TIMEOUT"
}

# Check if a git error indicates a timeout
is_timeout_error() {
    local output="$1"
    # Check for common timeout-related error messages
    [[ "$output" == *"RPC failed"* ]] ||
    [[ "$output" == *"timed out"* ]] ||
    [[ "$output" == *"The remote end hung up unexpectedly"* ]] ||
    [[ "$output" == *"transfer rate"* ]]
}

# Clone repository using gh
# Args: url target_dir repo_name [branch]
do_clone() {
    local url="$1"
    local target_dir="$2"
    local repo_name="$3"
    local branch="${4:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        local branch_info=""
        [[ -n "$branch" ]] && branch_info=" (branch: $branch)"
        log_info "[DRY RUN] Would clone: $url -> $target_dir$branch_info"
        write_result "$repo_name" "clone" "dry_run" "0" "" "$target_dir"
        return 0
    fi

    # Check for gh (required for cloning)
    if ! command -v gh &>/dev/null; then
        log_error "Cannot clone: gh is not installed"
        write_result "$repo_name" "clone" "dep_error" "0" "gh not installed" "$target_dir"
        return 3
    fi

    local clone_target
    clone_target=$(url_to_clone_target "$url")

    local start_time
    start_time=$(date +%s)

    # Create parent directory if needed
    mkdir -p "$(dirname "$target_dir")"

    # Set up timeout environment
    setup_git_timeout

    local output
    if output=$(gh repo clone "$clone_target" "$target_dir" -- --quiet 2>&1); then
        local duration=$(($(date +%s) - start_time))

        # If a specific branch was requested, check it out
        if [[ -n "$branch" ]]; then
            local checkout_output
            if ! checkout_output=$(git -C "$target_dir" checkout "$branch" 2>&1); then
                # Branch might be a remote branch, try fetching and checking out
                if ! checkout_output=$(git -C "$target_dir" checkout -b "$branch" "origin/$branch" 2>&1); then
                    log_warn "Cloned $repo_name but could not checkout branch '$branch'"
                    log_verbose "  $checkout_output"
                    write_result "$repo_name" "clone" "ok" "$duration" "branch checkout failed: $checkout_output" "$target_dir"
                    return 0
                fi
            fi
            log_success "Cloned: $repo_name@$branch (${duration}s)"
        else
            log_success "Cloned: $repo_name (${duration}s)"
        fi
        write_result "$repo_name" "clone" "ok" "$duration" "" "$target_dir"
        return 0
    else
        local exit_code=$?
        if is_timeout_error "$output"; then
            log_error "Timeout: $repo_name (network too slow)"
            write_result "$repo_name" "clone" "timeout" "0" "$output" "$target_dir"
        else
            log_error "Failed to clone: $repo_name"
            log_verbose "  $output"
            write_result "$repo_name" "clone" "failed" "0" "$output" "$target_dir"
        fi
        return $exit_code
    fi
}

# Pull updates with strategy support
# Strategies: ff-only (safe default), rebase, merge
# Args: repo_path repo_name [strategy] [autostash] [branch]
do_pull() {
    local repo_path="$1"
    local repo_name="$2"
    local strategy="${3:-ff-only}"
    local autostash="${4:-false}"
    local branch="${5:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        local branch_info=""
        [[ -n "$branch" ]] && branch_info=" branch: $branch,"
        log_info "[DRY RUN] Would pull: $repo_name (${branch_info}strategy: $strategy)"
        write_result "$repo_name" "pull" "dry_run" "0" "" "$repo_path"
        return 0
    fi

    local start_time
    start_time=$(date +%s)

    # If a specific branch was requested, ensure we're on it
    if [[ -n "$branch" ]]; then
        local current_branch
        current_branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
        if [[ "$current_branch" != "$branch" ]]; then
            local checkout_output
            if ! checkout_output=$(git -C "$repo_path" checkout "$branch" 2>&1); then
                # Try to checkout as tracking branch
                if ! checkout_output=$(git -C "$repo_path" checkout -b "$branch" "origin/$branch" 2>&1); then
                    log_warn "Could not switch to branch '$branch' for $repo_name"
                    log_verbose "  $checkout_output"
                    write_result "$repo_name" "pull" "branch_error" "0" "branch checkout failed: $checkout_output" "$repo_path"
                    return 1
                fi
            fi
            log_verbose "Switched to branch: $branch"
        fi
    fi

    # Set up timeout environment
    setup_git_timeout

    # Build pull arguments based on strategy
    local pull_args=()
    case "$strategy" in
        ff-only) pull_args+=(--ff-only) ;;
        rebase)  pull_args+=(--rebase) ;;
        merge)   pull_args+=(--no-ff) ;;
    esac

    [[ "$autostash" == "true" ]] && pull_args+=(--autostash)

    # Get current HEAD for comparison (don't parse "Already up to date")
    local old_head
    old_head=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")

    local output
    if output=$(git -C "$repo_path" pull "${pull_args[@]}" 2>&1); then
        local duration=$(($(date +%s) - start_time))
        local new_head
        new_head=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")

        # Determine if anything changed by comparing HEADs (not by parsing strings)
        if [[ "$old_head" == "$new_head" ]]; then
            log_info "Current: $repo_name"
            write_result "$repo_name" "pull" "current" "$duration" "" "$repo_path"
        else
            log_success "Updated: $repo_name (${duration}s)"
            write_result "$repo_name" "pull" "updated" "$duration" "" "$repo_path"
        fi
        return 0
    else
        local exit_code=$?
        local reason="failed"

        # Categorize the failure
        if is_timeout_error "$output"; then
            reason="timeout"
            log_error "Timeout: $repo_name (network too slow)"
        elif [[ "$output" =~ (divergent|cannot\ be\ fast-forwarded) ]]; then
            reason="diverged"
            log_warn "Diverged: $repo_name (needs manual merge or --rebase)"
        elif [[ "$output" =~ (conflict|CONFLICT) ]]; then
            reason="conflict"
            log_error "Merge conflict: $repo_name"
        else
            log_error "Pull failed: $repo_name"
        fi

        log_verbose "  $output"
        write_result "$repo_name" "pull" "$reason" "0" "$output" "$repo_path"
        return $exit_code
    fi
}

# Fetch remote without merging (for status checks)
do_fetch() {
    local repo_path="$1"
    git -C "$repo_path" fetch --quiet 2>/dev/null
}

#==============================================================================
# SECTION 10.5: SYNC STATE MANAGEMENT (for resume support)
#==============================================================================

# Get path to sync state file
get_sync_state_file() {
    echo "$RU_STATE_DIR/sync_state.json"
}

# Generate a hash of the current repo configuration (for detecting changes)
get_config_hash() {
    local input
    input=$(get_all_repos 2>/dev/null | sort)
    if command -v md5sum &>/dev/null; then
        printf '%s\n' "$input" | md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        # macOS uses 'md5' instead of 'md5sum'; -q for quiet (hash only)
        printf '%s\n' "$input" | md5 -q
    else
        # Fallback: use wc and date for a rough "hash"
        echo "${#input}-$(date +%s)"
    fi
}

# Load sync state from file
# Sets: SYNC_RUN_ID, SYNC_STATUS, SYNC_CONFIG_HASH, SYNC_COMPLETED (array), SYNC_PENDING (array)
load_sync_state() {
    local state_file
    state_file=$(get_sync_state_file)

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # Parse JSON state file (using pure bash - no jq dependency)
    local content
    content=$(<"$state_file")

    # Extract fields using grep/sed (simple JSON structure)
    SYNC_RUN_ID=$(echo "$content" | grep -o '"run_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"\([^"]*\)"/\1/')
    SYNC_STATUS=$(echo "$content" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"\([^"]*\)"/\1/')
    SYNC_CONFIG_HASH=$(echo "$content" | grep -o '"config_hash"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"\([^"]*\)"/\1/')

    # Extract completed array (comma-separated inside brackets)
    local completed_str
    completed_str=$(echo "$content" | grep -o '"completed"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/.*\[\([^]]*\)\]/\1/')
    SYNC_COMPLETED=()
    if [[ -n "$completed_str" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && SYNC_COMPLETED+=("$item")
        done < <(echo "$completed_str" | tr ',' '\n' | sed 's/[[:space:]]*"\([^"]*\)".*/\1/' | grep -v '^$')
    fi

    # Extract pending array
    local pending_str
    pending_str=$(echo "$content" | grep -o '"pending"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/.*\[\([^]]*\)\]/\1/')
    SYNC_PENDING=()
    if [[ -n "$pending_str" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && SYNC_PENDING+=("$item")
        done < <(echo "$pending_str" | tr ',' '\n' | sed 's/[[:space:]]*"\([^"]*\)".*/\1/' | grep -v '^$')
    fi

    return 0
}

# Save sync state to file (atomic write)
# Args: status completed_array pending_array
save_sync_state() {
    local status="$1"
    shift
    local -n completed_ref=$1
    shift
    local -n pending_ref=$1

    local state_file
    state_file=$(get_sync_state_file)
    local tmp_file="${state_file}.tmp.$$"

    ensure_dir "$(dirname "$state_file")"

    # Build JSON
    local run_id
    run_id="${SYNC_RUN_ID:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local config_hash
    config_hash=$(get_config_hash)

    # Build completed array JSON (handle empty array with set -u)
    local completed_json=""
    if [[ ${#completed_ref[@]} -gt 0 ]]; then
        for item in "${completed_ref[@]}"; do
            [[ -n "$completed_json" ]] && completed_json+=","
            completed_json+="\"$(json_escape "$item")\""
        done
    fi

    # Build pending array JSON (handle empty array with set -u)
    local pending_json=""
    if [[ ${#pending_ref[@]} -gt 0 ]]; then
        for item in "${pending_ref[@]}"; do
            [[ -n "$pending_json" ]] && pending_json+=","
            pending_json+="\"$(json_escape "$item")\""
        done
    fi

    cat > "$tmp_file" <<EOF
{
  "run_id": "$run_id",
  "status": "$status",
  "config_hash": "$config_hash",
  "results_file": "${RESULTS_FILE:-}",
  "completed": [$completed_json],
  "pending": [$pending_json]
}
EOF

    # Atomic rename
    mv "$tmp_file" "$state_file"
    SYNC_RUN_ID="$run_id"
}

# Clean up sync state file (on successful completion)
cleanup_sync_state() {
    local state_file
    state_file=$(get_sync_state_file)
    [[ -f "$state_file" ]] && rm -f "$state_file"
}

# Check if a repo name is in the completed list
is_repo_completed() {
    local repo_name="$1"
    # Handle empty array with set -u
    [[ ${#SYNC_COMPLETED[@]} -eq 0 ]] && return 1
    local item
    for item in "${SYNC_COMPLETED[@]}"; do
        [[ "$item" == "$repo_name" ]] && return 0
    done
    return 1
}

#==============================================================================
# SECTION 10.6: PARALLEL SYNC SUPPORT
#==============================================================================

# Process a single repo spec (used by both sequential and parallel modes)
# Writes result status to stdout (for aggregation)
# Args: repo_spec current total projects_dir layout update_strategy autostash clone_only pull_only fetch_remotes
process_single_repo_worker() {
    local repo_spec="$1"
    local projects_dir="$2"
    local layout="$3"
    local update_strategy="$4"
    local autostash="$5"
    local clone_only="$6"
    local pull_only="$7"
    local fetch_remotes="$8"

    # Parse and resolve the repo spec
    local url branch custom_name local_path repo_id
    if ! resolve_repo_spec "$repo_spec" "$projects_dir" "$layout" url branch custom_name local_path repo_id; then
        write_result "$repo_spec" "skip" "invalid" "0" "invalid repo spec" ""
        echo "FAIL:invalid:$repo_spec"
        return 1
    fi

    # Build display label
    local repo_label="$repo_id"
    [[ -n "$custom_name" ]] && repo_label="${repo_id} as ${custom_name}"

    # Check if repo exists locally
    if [[ ! -d "$local_path" ]]; then
        if [[ "$pull_only" == "true" ]]; then
            write_result "$repo_label" "skip" "skipped" "0" "pull-only mode" "$local_path"
            echo "SKIP:skipped:$repo_label"
            return 0
        fi

        if do_clone "$url" "$local_path" "$repo_label" "$branch" >/dev/null 2>&1; then
            echo "OK:cloned:$repo_label"
        else
            echo "FAIL:failed:$repo_label"
        fi
    else
        if [[ "$clone_only" == "true" ]]; then
            write_result "$repo_label" "skip" "skipped" "0" "clone-only mode" "$local_path"
            echo "SKIP:skipped:$repo_label"
            return 0
        fi

        if ! is_git_repo "$local_path"; then
            write_result "$repo_label" "skip" "not_git" "0" "" "$local_path"
            echo "CONFLICT:not_git:$repo_label"
            return 0
        fi

        if check_remote_mismatch "$local_path" "$url"; then
            write_result "$repo_label" "pull" "mismatch" "0" "" "$local_path"
            echo "CONFLICT:mismatch:$repo_label"
            return 0
        fi

        local status_info dirty status
        status_info=$(get_repo_status "$local_path" "$fetch_remotes")
        status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
        dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')

        if [[ "$dirty" == "true" && "$autostash" != "true" ]]; then
            write_result "$repo_label" "pull" "dirty" "0" "" "$local_path"
            echo "CONFLICT:dirty:$repo_label"
            return 0
        fi

        if [[ "$status" == "current" ]]; then
            write_result "$repo_label" "pull" "current" "0" "" "$local_path"
            echo "OK:current:$repo_label"
            return 0
        fi

        if [[ "$status" == "diverged" ]]; then
            write_result "$repo_label" "pull" "diverged" "0" "" "$local_path"
            echo "CONFLICT:diverged:$repo_label"
            return 0
        fi

        if do_pull "$local_path" "$repo_label" "$update_strategy" "$autostash" "$branch" >/dev/null 2>&1; then
            echo "OK:updated:$repo_label"
        else
            echo "FAIL:failed:$repo_label"
        fi
    fi
}

# Run parallel sync with worker pool
# Args: pending_repos array ref, parallel count
run_parallel_sync() {
    local -n repos_ref=$1
    local parallel_count=$2

    # Validate parallel count
    if [[ ! "$parallel_count" =~ ^[0-9]+$ ]] || [[ "$parallel_count" -lt 1 ]]; then
        log_error "Invalid parallel count: $parallel_count (must be >= 1)"
        return 4
    fi

    local total=${#repos_ref[@]}
    if [[ $total -eq 0 ]]; then
        return 0
    fi

    # Limit parallel count to total repos
    if [[ $parallel_count -gt $total ]]; then
        parallel_count=$total
    fi

    log_info "Syncing $total repositories with $parallel_count workers..."
    echo "" >&2

    # Create temporary files for work queue and results
    local work_queue results_file lock_file progress_file
    work_queue=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    results_file=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    lock_file=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    progress_file=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }

    # Write repos to work queue
    printf '%s\n' "${repos_ref[@]}" > "$work_queue"

    # Initialize progress counter
    echo "0" > "$progress_file"

    # Launch workers
    local worker_pids=()
    for ((i=0; i<parallel_count; i++)); do
        (
            while true; do
                # Atomically get next repo from queue
                local repo_spec
                {
                    flock -x 200
                    repo_spec=$(head -1 "$work_queue" 2>/dev/null)
                    if [[ -n "$repo_spec" ]]; then
                        # Remove from queue (portable sed)
                        tail -n +2 "$work_queue" > "${work_queue}.tmp" 2>/dev/null
                        mv "${work_queue}.tmp" "$work_queue" 2>/dev/null
                    fi
                } 200>"$lock_file"

                # Exit if no more work
                [[ -z "$repo_spec" ]] && break

                # Process the repo
                local result
                result=$(process_single_repo_worker "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
                    "$UPDATE_STRATEGY" "$AUTOSTASH" "$CLONE_ONLY" "$PULL_ONLY" "$FETCH_REMOTES")

                # Append result atomically
                echo "$result" >> "$results_file"

                # Update progress atomically
                {
                    flock -x 201
                    local current
                    current=$(cat "$progress_file")
                    echo $((current + 1)) > "$progress_file"
                    # Print progress
                    echo -ne "\r→ Progress: $((current + 1))/$total" >&2
                } 201>"${lock_file}.progress"
            done
        ) &
        worker_pids+=($!)
    done

    # Wait for all workers
    for pid in "${worker_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    echo "" >&2  # New line after progress

    # Parse results
    local cloned=0 updated=0 skipped=0 failed=0 conflicts=0
    while IFS=: read -r status reason repo_name; do
        case "$status" in
            OK)
                case "$reason" in
                    cloned) ((cloned++)) ;;
                    updated) ((updated++)) ;;
                    current) ((skipped++)) ;;
                esac
                ;;
            SKIP) ((skipped++)) ;;
            FAIL) ((failed++)) ;;
            CONFLICT) ((conflicts++)) ;;
        esac
    done < "$results_file"

    # Cleanup temp files
    rm -f "$work_queue" "$results_file" "$lock_file" "${lock_file}.progress" "$progress_file" 2>/dev/null

    # Return results via global variables (for summary)
    PARALLEL_CLONED=$cloned
    PARALLEL_UPDATED=$updated
    PARALLEL_SKIPPED=$skipped
    PARALLEL_FAILED=$failed
    PARALLEL_CONFLICTS=$conflicts

    return 0
}

#==============================================================================
# SECTION 11: EXIT TRAP AND CLEANUP
#==============================================================================

cleanup() {
    # If sync was interrupted, preserve state file
    if [[ "$SYNC_INTERRUPTED" == "true" ]]; then
        log_warn "Sync interrupted. Resume with: ru sync --resume"
        return
    fi

    # Remove temp files
    if [[ -n "${RESULTS_FILE:-}" && -f "$RESULTS_FILE" ]]; then
        rm -f "$RESULTS_FILE"
    fi
}

# Set up trap for cleanup
trap cleanup EXIT

#==============================================================================
# SECTION 12: ARGUMENT PARSING
#==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --json)
                JSON_OUTPUT="true"
                shift
                ;;
            -q|--quiet)
                QUIET="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE="true"
                shift
                ;;
            --dry-run)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                else
                    DRY_RUN="true"
                fi
                shift
                ;;
            --clone-only)
                CLONE_ONLY="true"
                shift
                ;;
            --pull-only)
                PULL_ONLY="true"
                shift
                ;;
            --autostash)
                AUTOSTASH="true"
                shift
                ;;
            --rebase)
                UPDATE_STRATEGY="rebase"
                shift
                ;;
            --dir)
                if [[ $# -lt 2 ]]; then
                    log_error "--dir requires a path argument"
                    exit 4
                fi
                PROJECTS_DIR="$2"
                shift 2
                ;;
            --fetch)
                FETCH_REMOTES="true"
                shift
                ;;
            --no-fetch)
                FETCH_REMOTES="false"
                shift
                ;;
            --resume)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                else
                    RESUME="true"
                fi
                shift
                ;;
            --restart)
                RESTART="true"
                shift
                ;;
            --timeout)
                if [[ $# -lt 2 ]]; then
                    log_error "--timeout requires a value in seconds"
                    exit 4
                fi
                GIT_TIMEOUT="$2"
                shift 2
                ;;
            --parallel)
                if [[ "$COMMAND" == "review" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "--parallel requires a number"
                        exit 4
                    fi
                    ARGS+=("--parallel=$2")
                    shift 2
                else
                    if [[ $# -lt 2 ]]; then
                        log_error "--parallel requires a number of workers"
                        exit 4
                    fi
                    PARALLEL="$2"
                    shift 2
                fi
                ;;
            -j)
                if [[ "$COMMAND" == "review" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "-j requires a number"
                        exit 4
                    fi
                    ARGS+=("-j$2")
                    shift 2
                else
                    if [[ $# -lt 2 ]]; then
                        log_error "-j requires a number of workers"
                        exit 4
                    fi
                    PARALLEL="$2"
                    shift 2
                fi
                ;;
            --example)
                INIT_EXAMPLE="true"
                shift
                ;;
            sync|status|init|add|remove|list|doctor|self-update|config|prune|import|review)
                COMMAND="$1"
                shift
                ;;
            --paths|--print|--set=*|--check|--archive|--delete|--private|--public|--from-cwd)
                # Subcommand-specific options - pass through to ARGS
                ARGS+=("$1")
                shift
                ;;
            --plan|--apply|--push|--mode=*|--repos=*|--skip-days=*|--priority=*|--max-repos=*|--max-runtime=*|--max-questions=*|--parallel=*|-j[0-9]*)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                    shift
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                ;;
            --mode|--repos|--skip-days|--priority|--max-repos|--max-runtime|--max-questions)
                if [[ "$COMMAND" == "review" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "$1 requires a value"
                        exit 4
                    fi
                    ARGS+=("$1=$2")
                    shift 2
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 4
                ;;
            *)
                # Positional argument - store for command
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Default command is sync
    if [[ -z "$COMMAND" ]]; then
        COMMAND="sync"
    fi
}

#==============================================================================
# SECTION 12.5: REPORTING AND SUMMARY FUNCTIONS
#==============================================================================

# Aggregate results from the NDJSON results file
# Returns: space-separated key=value pairs for counts
# Works without jq by using grep/sed fallback
aggregate_results() {
    local cloned=0 updated=0 current=0 failed=0 conflicts=0 skipped=0 system_errors=0

    if [[ ! -f "$RESULTS_FILE" ]] || [[ ! -s "$RESULTS_FILE" ]]; then
        echo "CLONED=0 UPDATED=0 CURRENT=0 SKIPPED=0 FAILED=0 CONFLICTS=0 SYSTEM_ERRORS=0"
        return
    fi

    # Use pure bash parsing - no jq dependency
    while IFS= read -r line; do
        # Extract status field using bash parameter expansion
        local status
        # Pattern: "status":"value" - extract value between quotes after status
        if [[ "$line" =~ \"status\":\"([^\"]+)\" ]]; then
            status="${BASH_REMATCH[1]}"
        else
            continue
        fi

        case "$status" in
            ok)          ((cloned++)) ;;
            updated)     ((updated++)) ;;
            current)     ((current++)) ;;
            skipped|dry_run) ((skipped++)) ;;
            dep_error|auth_error) ((system_errors++)) ;;
            failed|timeout)  ((failed++)) ;;
            diverged|dirty|conflict|mismatch|not_git|branch_error|no_remote|no_upstream|invalid) ((conflicts++)) ;;
            *)           ((skipped++)) ;;
        esac
    done < "$RESULTS_FILE"

    echo "CLONED=$cloned UPDATED=$updated CURRENT=$current SKIPPED=$skipped FAILED=$failed CONFLICTS=$conflicts SYSTEM_ERRORS=$system_errors"
}

# Print a beautiful summary box with gum or ANSI fallback
# Args: $1=cloned $2=updated $3=current $4=skipped $5=conflicts $6=failed $7=duration_seconds
print_summary() {
    local cloned="${1:-0}"
    local updated="${2:-0}"
    local current="${3:-0}"
    local skipped="${4:-0}"
    local conflicts="${5:-0}"
    local failed="${6:-0}"
    local duration="${7:-0}"
    local total=$((cloned + updated + current + skipped + conflicts + failed))

    # Format duration
    local duration_str
    if [[ "$duration" -ge 60 ]]; then
        local mins=$((duration / 60))
        local secs=$((duration % 60))
        duration_str="${mins}m ${secs}s"
    else
        duration_str="${duration}s"
    fi


    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        # Use gum for beautiful box
        local summary_text=""
        summary_text+="               📊 Sync Summary\n"
        summary_text+="─────────────────────────────────────────\n"
        [[ $cloned -gt 0 ]] && summary_text+="  ✅ Cloned:     $cloned repos\n"
        [[ $updated -gt 0 ]] && summary_text+="  ✅ Updated:    $updated repos\n"
        [[ $current -gt 0 ]] && summary_text+="  ⏭️  Current:    $current repos (already up to date)\n"
        [[ $skipped -gt 0 ]] && summary_text+="  ⏭️  Skipped:    $skipped repos\n"
        [[ $conflicts -gt 0 ]] && summary_text+="  ⚠️  Conflicts:  $conflicts repos (need attention)\n"
        [[ $failed -gt 0 ]] && summary_text+="  ❌ Failed:     $failed repos\n"
        summary_text+="─────────────────────────────────────────\n"
        summary_text+="  Total: $total repos processed in $duration_str\n"

        printf '%b' "$summary_text" | gum style --border rounded --padding "0 1" --border-foreground 212 >&2
    else
        # ANSI fallback
        echo "" >&2
        printf '%b\n' "${BOLD}╭─────────────────────────────────────────────────────────────╮${RESET}" >&2
        printf '%b\n' "${BOLD}│                    📊 Sync Summary                          │${RESET}" >&2
        printf '%b\n' "${BOLD}├─────────────────────────────────────────────────────────────┤${RESET}" >&2
        [[ $cloned -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ${GREEN}✅${RESET} Cloned:     $cloned repos                                   ${BOLD}│${RESET}" >&2
        [[ $updated -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ${GREEN}✅${RESET} Updated:    $updated repos                                   ${BOLD}│${RESET}" >&2
        [[ $current -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ⏭️  Current:    $current repos (already up to date)           ${BOLD}│${RESET}" >&2
        [[ $skipped -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ⏭️  Skipped:    $skipped repos                                   ${BOLD}│${RESET}" >&2
        [[ $conflicts -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ${YELLOW}⚠️${RESET}  Conflicts:  $conflicts repos (need attention)              ${BOLD}│${RESET}" >&2
        [[ $failed -gt 0 ]] && printf '%b\n' "${BOLD}│${RESET}  ${RED}❌${RESET} Failed:     $failed repos                                   ${BOLD}│${RESET}" >&2
        printf '%b\n' "${BOLD}├─────────────────────────────────────────────────────────────┤${RESET}" >&2
        printf '%b\n' "${BOLD}│${RESET}  Total: $total repos processed in $duration_str                      ${BOLD}│${RESET}" >&2
        printf '%b\n' "${BOLD}╰─────────────────────────────────────────────────────────────╯${RESET}" >&2
    fi
}

# Print actionable conflict resolution help
# Reads from RESULTS_FILE to find repos with issues
print_conflict_help() {
    if [[ ! -f "$RESULTS_FILE" ]] || [[ ! -s "$RESULTS_FILE" ]]; then
        return
    fi

    # Collect problematic repos
    local has_conflicts="false"
    local conflict_count=0

    # First pass: check if there are any conflicts
    while IFS= read -r line; do
        local status
        if [[ "$line" =~ \"status\":\"([^\"]+)\" ]]; then
            status="${BASH_REMATCH[1]}"
            case "$status" in
                diverged|dirty|conflict|mismatch|not_git|failed|timeout)
                    has_conflicts="true"
                    ((conflict_count++))
                    ;;
            esac
        fi
    done < "$RESULTS_FILE"

    [[ "$has_conflicts" != "true" ]] && return

    echo "" >&2
    printf '%b\n' "${BOLD}${YELLOW}Repositories Needing Attention${RESET}" >&2
    printf '%b\n' "─────────────────────────────────────────────────────────────" >&2
    echo "" >&2

    local num=0
    while IFS= read -r line; do
        local repo status path
        if [[ "$line" =~ \"repo\":\"([^\"]+)\" ]]; then
            repo="${BASH_REMATCH[1]}"
        else
            continue
        fi
        if [[ "$line" =~ \"status\":\"([^\"]+)\" ]]; then
            status="${BASH_REMATCH[1]}"
        else
            continue
        fi
        # Extract path from JSON (falls back to $PROJECTS_DIR/$repo for backwards compat)
        if [[ "$line" =~ \"path\":\"([^\"]+)\" ]]; then
            path="${BASH_REMATCH[1]}"
        else
            path="$PROJECTS_DIR/$repo"
        fi

        case "$status" in
            dirty)
                ((num++))
                printf '%b\n' "${BOLD}$num. $repo${RESET}" >&2
                printf '%b\n' "   Path:   $path" >&2
                printf '%b\n' "   Issue:  ${YELLOW}Dirty working tree${RESET} (uncommitted changes)" >&2
                echo "" >&2
                printf '%b\n' "   ${DIM}Resolution options:${RESET}" >&2
                printf '%b\n' "     ${GREEN}a)${RESET} Stash and pull:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git stash && git pull && git stash pop${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Commit your changes:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git add . && git commit -m \"WIP\"${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${RED}c)${RESET} Discard local changes (${RED}DESTRUCTIVE${RESET}):" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git checkout . && git clean -fd${RESET}" >&2
                echo "" >&2
                ;;
            diverged)
                ((num++))
                printf '%b\n' "${BOLD}$num. $repo${RESET}" >&2
                printf '%b\n' "   Path:   $path" >&2
                printf '%b\n' "   Issue:  ${YELLOW}Diverged${RESET} (local and remote both have new commits)" >&2
                echo "" >&2
                printf '%b\n' "   ${DIM}Resolution options:${RESET}" >&2
                printf '%b\n' "     ${GREEN}a)${RESET} Rebase your changes:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git pull --rebase${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Merge (creates merge commit):" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git pull --no-ff${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}c)${RESET} Push your changes first (if intentional):" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git push${RESET}" >&2
                echo "" >&2
                ;;
            mismatch)
                ((num++))
                printf '%b\n' "${BOLD}$num. $repo${RESET}" >&2
                printf '%b\n' "   Path:   $path" >&2
                printf '%b\n' "   Issue:  ${RED}Remote mismatch${RESET} (different repo at this path)" >&2
                echo "" >&2
                printf '%b\n' "   ${DIM}Resolution options:${RESET}" >&2
                printf '%b\n' "     ${GREEN}a)${RESET} Check current remote:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git remote -v${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Update remote URL:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git remote set-url origin <correct-url>${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${RED}c)${RESET} Remove and re-clone (${RED}DESTRUCTIVE${RESET}):" >&2
                printf '%b\n' "        ${CYAN}rm -rf \"$path\" && ru sync${RESET}" >&2
                echo "" >&2
                ;;
            not_git)
                ((num++))
                printf '%b\n' "${BOLD}$num. $repo${RESET}" >&2
                printf '%b\n' "   Path:   $path" >&2
                printf '%b\n' "   Issue:  ${RED}Not a git repository${RESET}" >&2
                echo "" >&2
                printf '%b\n' "   ${DIM}Resolution options:${RESET}" >&2
                printf '%b\n' "     ${GREEN}a)${RESET} Remove and re-clone:" >&2
                printf '%b\n' "        ${CYAN}rm -rf \"$path\" && ru sync${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Initialize as git repo:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git init && git remote add origin <url>${RESET}" >&2
                echo "" >&2
                ;;
            failed|timeout)
                ((num++))
                printf '%b\n' "${BOLD}$num. $repo${RESET}" >&2
                printf '%b\n' "   Path:   $path" >&2
                printf '%b\n' "   Issue:  ${RED}Operation failed${RESET} (network/auth issue)" >&2
                echo "" >&2
                printf '%b\n' "   ${DIM}Resolution options:${RESET}" >&2
                printf '%b\n' "     ${GREEN}a)${RESET} Check network connectivity and retry:" >&2
                printf '%b\n' "        ${CYAN}ru sync $repo${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Check GitHub authentication:" >&2
                printf '%b\n' "        ${CYAN}gh auth status${RESET}" >&2
                echo "" >&2
                ;;
        esac
    done < "$RESULTS_FILE"
}

# Generate JSON report for --json mode
# Outputs complete structured JSON to stdout
generate_json_report() {
    local cloned="${1:-0}"
    local updated="${2:-0}"
    local current="${3:-0}"
    local skipped="${4:-0}"
    local conflicts="${5:-0}"
    local failed="${6:-0}"
    local duration="${7:-0}"
    local total=$((cloned + updated + current + skipped + conflicts + failed))

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build repos array from results file
    local repos_json="[]"
    if [[ -f "$RESULTS_FILE" ]] && [[ -s "$RESULTS_FILE" ]]; then
        repos_json="["
        local first="true"
        while IFS= read -r line; do
            [[ "$first" == "true" ]] || repos_json+=","
            first="false"
            # Parse each field and rebuild with proper structure
            local repo action status repo_duration path
            [[ "$line" =~ \"repo\":\"([^\"]+)\" ]] && repo="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"action\":\"([^\"]+)\" ]] && action="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"status\":\"([^\"]+)\" ]] && status="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"duration\":([0-9]+) ]] && repo_duration="${BASH_REMATCH[1]}"
            # Extract path from NDJSON (falls back to computed path for backwards compat)
            local safe_path
            if [[ "$line" =~ \"path\":\"([^\"]+)\" ]]; then
                # Path from NDJSON is already JSON-escaped, use directly
                safe_path="${BASH_REMATCH[1]}"
            else
                # Fallback path needs escaping
                safe_path=$(json_escape "$PROJECTS_DIR/$repo")
            fi

            repos_json+="{\"name\":\"$repo\",\"path\":\"$safe_path\",\"action\":\"$action\",\"status\":\"$status\",\"duration\":${repo_duration:-0}}"
        done < "$RESULTS_FILE"
        repos_json+="]"
    fi

    # Escape paths for JSON
    local safe_projects_dir
    safe_projects_dir=$(json_escape "$PROJECTS_DIR")

    # Output structured JSON
    cat << EOF
{
  "version": "$VERSION",
  "timestamp": "$timestamp",
  "duration_seconds": $duration,
  "config": {
    "projects_dir": "$safe_projects_dir",
    "layout": "$LAYOUT",
    "update_strategy": "$UPDATE_STRATEGY"
  },
  "summary": {
    "total": $total,
    "cloned": $cloned,
    "updated": $updated,
    "current": $current,
    "skipped": $skipped,
    "conflicts": $conflicts,
    "failed": $failed
  },
  "repos": $repos_json
}
EOF
}

# Compute appropriate exit code based on results
# Args: $1=failed $2=conflicts $3=system_errors
# Returns: exit code (0, 1, 2, or 3)
compute_exit_code() {
    local failed="${1:-0}"
    local conflicts="${2:-0}"
    local system_errors="${3:-0}"

    if [[ "$system_errors" -gt 0 ]]; then
        return 3  # Dependency/system error (git/gh missing, etc.)
    elif [[ "$failed" -gt 0 ]]; then
        return 1  # Partial failure (network, auth, etc.)
    elif [[ "$conflicts" -gt 0 ]]; then
        return 2  # Conflicts exist (need manual resolution)
    else
        return 0  # Success
    fi
}

#==============================================================================
# SECTION 13: COMMAND STUBS (to be implemented)
#==============================================================================

cmd_sync() {
    # Check for required dependencies
    if ! command -v git &>/dev/null; then
        log_error "git is not installed"
        exit 3
    fi

    # Track start time for duration reporting
    local start_time
    start_time=$(date +%s)

    # Auto-init on first run
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_info "First run detected. Initializing configuration..."
        ensure_config_exists >/dev/null
        log_success "Created configuration at: $RU_CONFIG_DIR"
        echo "" >&2
    fi

    # Ensure projects directory exists
    ensure_dir "$PROJECTS_DIR"

    # Check for positional arguments (ad-hoc repos)
    if [[ ${#ARGS[@]} -gt 0 ]]; then
        # User passed repo URLs directly - sync them ad-hoc
        log_step "Syncing ${#ARGS[@]} repo(s)..."
        local repo_spec url branch custom_name path repo_id repo_label
        for repo_spec in "${ARGS[@]}"; do
            # Parse and resolve the repo spec
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name path repo_id; then
                log_error "Invalid repo spec: $repo_spec"
                write_result "$repo_spec" "skip" "invalid" "0" "invalid repo spec" ""
                continue
            fi
            repo_label="$repo_id"
            [[ -n "$custom_name" ]] && repo_label="${repo_id} as ${custom_name}"

            if [[ -d "$path" ]]; then
                # Exists - pull updates
                if ! is_git_repo "$path"; then
                    log_warn "Not a git repo: $path"
                    write_result "$repo_label" "skip" "not_git" "0" "" "$path"
                    continue
                fi
                do_pull "$path" "$repo_label" "$UPDATE_STRATEGY" "$AUTOSTASH" "$branch"
            else
                # Missing - clone
                do_clone "$url" "$path" "$repo_label" "$branch"
            fi
        done

        # Aggregate results and compute proper exit code
        eval "$(aggregate_results)"
        compute_exit_code "$FAILED" "$CONFLICTS" "$SYSTEM_ERRORS"
        exit $?
    fi

    # Load all repos from config (checks all .txt files in repos.d/)
    local repos=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && repos+=("$line")
    done < <(get_all_repos)

    # No arguments - check for configured repos
    if [[ ${#repos[@]} -eq 0 ]]; then
        log_info "No repositories configured yet."
        echo "" >&2
        log_info "To add repos:"
        log_info "  ru add owner/repo              # Add to list"
        log_info "  ru sync owner/repo             # Sync directly (without adding)"
        log_info "  echo 'owner/repo' >> $RU_CONFIG_DIR/repos.d/repos.txt  # Edit file directly"
        exit 0
    fi

    local total=${#repos[@]}
    local current=0
    local cloned=0 updated=0 skipped=0 failed=0 conflicts=0 resumed=0

    # Resume support: check for interrupted sync
    SYNC_COMPLETED=()
    local pending_repos=()

    if load_sync_state; then
        if [[ "$SYNC_STATUS" == "in_progress" ]]; then
            if [[ "$RESTART" == "true" ]]; then
                # User wants to start fresh
                log_info "Discarding interrupted sync state..."
                cleanup_sync_state
                pending_repos=("${repos[@]}")
            elif [[ "$RESUME" == "true" ]]; then
                # Resume from where we left off
                local completed_count=${#SYNC_COMPLETED[@]}
                log_info "Resuming sync: ${completed_count} repos already completed"

                # Check if config changed
                local current_hash
                current_hash=$(get_config_hash)
                if [[ "$current_hash" != "$SYNC_CONFIG_HASH" ]]; then
                    log_warn "Repository list has changed since last sync"
                fi

                # Filter out completed repos (use local_path for unique identification)
                for repo_spec in "${repos[@]}"; do
                    local url branch custom_name local_path repo_id
                    if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                        log_error "Invalid repo spec in config: $repo_spec"
                        continue
                    fi

                    if is_repo_completed "$local_path"; then
                        ((resumed++))
                    else
                        pending_repos+=("$repo_spec")
                    fi
                done
            else
                # State exists but no flag - warn user
                log_warn "Interrupted sync detected from ${SYNC_RUN_ID}"
                log_warn "${#SYNC_COMPLETED[@]} repos completed, ${#SYNC_PENDING[@]} pending"
                echo "" >&2
                log_info "Options:"
                log_info "  ru sync --resume   # Continue from where you left off"
                log_info "  ru sync --restart  # Start fresh, discard progress"
                exit 5
            fi
        else
            # State exists but completed - start fresh
            pending_repos=("${repos[@]}")
        fi
    else
        # No state file - fresh start
        pending_repos=("${repos[@]}")
    fi

    # Set up interrupt handler for graceful resume
    handle_sync_interrupt() {
        echo "" >&2
        log_warn "Sync interrupted!"
        SYNC_INTERRUPTED="true"
        # State is already saved after each repo
        exit 130
    }
    trap handle_sync_interrupt INT TERM

    # Initialize pending repos array for state tracking (use local_path for unique ID)
    local pending_names=()
    if [[ ${#pending_repos[@]} -gt 0 ]]; then
        for repo_spec in "${pending_repos[@]}"; do
            local url branch custom_name local_path repo_id
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                continue
            fi
            pending_names+=("$local_path")
        done

        # Save initial state
        save_sync_state "in_progress" SYNC_COMPLETED pending_names
    fi

    local pending_count=${#pending_repos[@]}

    # Only iterate if there are pending repos
    if [[ ${#pending_repos[@]} -eq 0 ]]; then
        log_info "No repositories to sync."
    fi

    # Check for parallel mode
    local parallel_count="${PARALLEL:-1}"

    # Check for flock availability before entering parallel mode
    if [[ -n "$PARALLEL" && "$parallel_count" -gt 1 ]]; then
        if ! command -v flock &>/dev/null; then
            log_warn "Parallel sync requires 'flock' which is not installed"
            log_warn "Falling back to sequential sync"
            log_info "To enable parallel sync on macOS: brew install flock"
            PARALLEL=""
            parallel_count="1"
        fi
    fi

    if [[ -n "$PARALLEL" && "$parallel_count" -gt 1 ]]; then
        # Parallel mode: use worker pool
        if [[ $resumed -gt 0 ]]; then
            log_info "Parallel sync: $pending_count repositories ($resumed already completed) with $parallel_count workers"
        fi

        run_parallel_sync pending_repos "$parallel_count"

        # Get results from global variables set by run_parallel_sync
        cloned=$PARALLEL_CLONED
        updated=$PARALLEL_UPDATED
        skipped=$PARALLEL_SKIPPED
        failed=$PARALLEL_FAILED
        conflicts=$PARALLEL_CONFLICTS

        # Skip state management for parallel mode (simpler, no resume support yet)
    else
        # Sequential mode (original behavior)
        if [[ $resumed -gt 0 ]]; then
            log_info "Syncing $pending_count repositories ($resumed already completed)..."
        else
            log_info "Syncing $total repositories..."
        fi
        echo "" >&2

    for repo_spec in "${pending_repos[@]+"${pending_repos[@]}"}"; do
        [[ -z "$repo_spec" ]] && continue
        ((current++))

        # Parse and validate the repo spec
        local url branch custom_name local_path repo_id repo_label
        if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
            log_warn "Invalid repo spec: $repo_spec"
            write_result "$repo_spec" "skip" "invalid" "0" "invalid repo spec" ""
            ((failed++))
            continue
        fi
        repo_label="$repo_id"
        [[ -n "$custom_name" ]] && repo_label="${repo_id} as ${custom_name}"

        log_step "[$current/$pending_count] $repo_label"

        # Check if repo exists locally
        if [[ ! -d "$local_path" ]]; then
            if [[ "$PULL_ONLY" == "true" ]]; then
                log_verbose "  Skipping clone (--pull-only)"
                ((skipped++))
                write_result "$repo_label" "skip" "skipped" "0" "pull-only mode" "$local_path"
                continue
            fi

            if do_clone "$url" "$local_path" "$repo_label" "$branch"; then
                ((cloned++))
            else
                ((failed++))
            fi
        else
            if [[ "$CLONE_ONLY" == "true" ]]; then
                log_verbose "  Skipping pull (--clone-only)"
                ((skipped++))
                write_result "$repo_label" "skip" "skipped" "0" "clone-only mode" "$local_path"
                continue
            fi

            if ! is_git_repo "$local_path"; then
                log_warn "Not a git repo: $local_path"
                ((conflicts++))
                write_result "$repo_label" "skip" "not_git" "0" "" "$local_path"
                continue
            fi

            if check_remote_mismatch "$local_path" "$url"; then
                log_warn "Remote mismatch: $repo_label"
                ((conflicts++))
                write_result "$repo_label" "pull" "mismatch" "0" "" "$local_path"
                continue
            fi

            local status_info dirty status
            status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
            status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
            dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')

            if [[ "$dirty" == "true" && "$AUTOSTASH" != "true" ]]; then
                log_warn "Dirty: $repo_label (uncommitted changes)"
                ((conflicts++))
                write_result "$repo_label" "pull" "dirty" "0" "" "$local_path"
                continue
            fi

            if [[ "$status" == "current" ]]; then
                log_info "Current: $repo_label"
                ((skipped++))
                write_result "$repo_label" "pull" "current" "0" "" "$local_path"
                continue
            fi

            if [[ "$status" == "diverged" ]]; then
                log_warn "Diverged: $repo_label"
                ((conflicts++))
                write_result "$repo_label" "pull" "diverged" "0" "" "$local_path"
                continue
            fi

            if do_pull "$local_path" "$repo_label" "$UPDATE_STRATEGY" "$AUTOSTASH" "$branch"; then
                ((updated++))
            else
                ((failed++))
            fi
        fi

        # Update state: mark this repo as completed (use local_path for unique ID)
        SYNC_COMPLETED+=("$local_path")
        # Remove from pending_names (handle empty array with set -u)
        local new_pending=()
        if [[ ${#pending_names[@]} -gt 0 ]]; then
            for p in "${pending_names[@]}"; do
                [[ "$p" != "$local_path" ]] && new_pending+=("$p")
            done
        fi
        pending_names=()
        if [[ ${#new_pending[@]} -gt 0 ]]; then
            pending_names=("${new_pending[@]}")
        fi
        # Save state after each repo (enables resume on interrupt)
        save_sync_state "in_progress" SYNC_COMPLETED pending_names
    done
    fi  # End of sequential mode else block

    echo "" >&2

    # Sync completed successfully - clean up state file
    cleanup_sync_state

    # Reset trap to normal cleanup
    trap cleanup EXIT

    # Calculate duration
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Get aggregated counts from results file
    eval "$(aggregate_results)"

    # Print summary using the new reporting functions
    print_summary "$CLONED" "$UPDATED" "$CURRENT" "$SKIPPED" "$CONFLICTS" "$FAILED" "$duration"

    # Print conflict resolution help if there are issues
    print_conflict_help

    # Output JSON report if --json flag is set
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        generate_json_report "$CLONED" "$UPDATED" "$CURRENT" "$SKIPPED" "$CONFLICTS" "$FAILED" "$duration"
    fi

    # Compute and use appropriate exit code
    compute_exit_code "$FAILED" "$CONFLICTS" "$SYSTEM_ERRORS"
    exit $?
}

cmd_status() {
    # Ensure config exists
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_info "No configuration found. Run: ru init"
        exit 0
    fi

    # Check for configured repos
    local repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
    if [[ ! -f "$repos_file" ]] || [[ ! -s "$repos_file" ]] || ! grep -Eqv '^[[:space:]]*#|^[[:space:]]*$' "$repos_file" 2>/dev/null; then
        log_info "No repositories configured."
        log_info "Add repos with: ru add owner/repo"
        exit 0
    fi

    # Load all repos from config
    local repos=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && repos+=("$line")
    done < <(get_all_repos)

    local total=${#repos[@]}

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        # JSON output mode
        echo "["
        local first="true"
        for repo_spec in "${repos[@]}"; do
            local url branch custom_name local_path repo_id
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                continue
            fi
            local status="missing" ahead=0 behind=0 dirty="false" branch_name=""
            if [[ -d "$local_path" ]] && is_git_repo "$local_path"; then
                local status_info
                status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
                status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
                ahead=$(echo "$status_info" | sed 's/.*AHEAD=\([^ ]*\).*/\1/')
                behind=$(echo "$status_info" | sed 's/.*BEHIND=\([^ ]*\).*/\1/')
                dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')
                branch_name=$(echo "$status_info" | sed 's/.*BRANCH=\([^ ]*\).*/\1/')
            elif [[ -d "$local_path" ]]; then
                status="not_git"
            fi
            [[ "$first" == "true" ]] || echo ","
            first="false"
            # Escape path for JSON safety (may contain special characters)
            local safe_path safe_branch
            safe_path=$(json_escape "$local_path")
            safe_branch=$(json_escape "$branch_name")
            printf '{"repo":"%s","path":"%s","status":"%s","branch":"%s","ahead":%d,"behind":%d,"dirty":%s}' \
                "$repo_id" "$safe_path" "$status" "$safe_branch" "$ahead" "$behind" "$dirty"
        done
        echo "]"
    else
        # Human-readable output
        log_info "Repository Status ($total repos)"
        [[ "$FETCH_REMOTES" == "true" ]] && log_info "Fetching remotes for accurate status..."
        echo "" >&2
        printf "%-30s %-12s %-15s %s\n" "Repository" "Status" "Branch" "Ahead/Behind" >&2
        printf "%-30s %-12s %-15s %s\n" "------------------------------" "------------" "---------------" "------------" >&2
        for repo_spec in "${repos[@]}"; do
            local url branch custom_name local_path repo_id
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                continue
            fi
            local status="missing" ahead=0 behind=0 dirty="false" branch_name="" status_display
            if [[ -d "$local_path" ]] && is_git_repo "$local_path"; then
                local status_info
                status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
                status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
                ahead=$(echo "$status_info" | sed 's/.*AHEAD=\([^ ]*\).*/\1/')
                behind=$(echo "$status_info" | sed 's/.*BEHIND=\([^ ]*\).*/\1/')
                dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')
                branch_name=$(echo "$status_info" | sed 's/.*BRANCH=\([^ ]*\).*/\1/')
            elif [[ -d "$local_path" ]]; then
                status="not_git"
            fi
            case "$status" in
                current)     status_display="${GREEN}current${RESET}" ;;
                behind)      status_display="${YELLOW}behind${RESET}" ;;
                ahead)       status_display="${CYAN}ahead${RESET}" ;;
                diverged)    status_display="${RED}diverged${RESET}" ;;
                missing)     status_display="${DIM}missing${RESET}" ;;
                not_git)     status_display="${RED}not_git${RESET}" ;;
                no_upstream) status_display="${YELLOW}no_upstrm${RESET}" ;;
                *)           status_display="$status" ;;
            esac
            [[ "$dirty" == "true" ]] && status_display="${status_display}${YELLOW}*${RESET}"
            printf "%-30s %-12b %-15s %d/%d\n" "${repo_id:0:30}" "$status_display" "${branch_name:0:15}" "$ahead" "$behind" >&2
        done
        echo "" >&2
        log_info "Legend: * = uncommitted changes"
    fi
}

cmd_init() {
    log_step "Initializing ru configuration..."

    local created
    created=$(ensure_config_exists)

    if [[ "$created" == "true" ]]; then
        log_success "Created configuration directory: $RU_CONFIG_DIR"
        log_success "Created repos file: $RU_CONFIG_DIR/repos.d/repos.txt"
        log_success "Created config file: $RU_CONFIG_DIR/config"

        # Handle --example flag: copy example repos to repos.txt
        if [[ "$INIT_EXAMPLE" == "true" ]]; then
            local example_file="$SCRIPT_DIR/examples/public.txt"
            local repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
            if [[ -f "$example_file" ]]; then
                # Overwrite the template repos.txt with example content
                cp "$example_file" "$repos_file"
                log_success "Added example repos from $example_file"
            else
                log_warn "Example file not found: $example_file"
            fi
        fi

        echo "" >&2
        log_info "Next steps:"
        log_info "  1. Add repos:  ru add owner/repo"
        log_info "  2. Sync:       ru sync"
        log_info "  3. Or edit:    $RU_CONFIG_DIR/repos.d/repos.txt"
    else
        log_info "Configuration already exists at: $RU_CONFIG_DIR"
        log_info "  Config:  $RU_CONFIG_DIR/config"
        log_info "  Repos:   $RU_CONFIG_DIR/repos.d/repos.txt"
    fi
}

cmd_add() {
    # Parse command-specific options
    local use_private="false"
    local from_cwd="false"
    local repo_args=()

    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --private) use_private="true" ;;
            --from-cwd) from_cwd="true" ;;
            *) repo_args+=("$arg") ;;
        esac
    done

    # Handle --from-cwd: detect repo from current directory
    if [[ "$from_cwd" == "true" ]]; then
        if ! is_git_repo "."; then
            log_error "Current directory is not a git repository"
            exit 4
        fi
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null)
        if [[ -z "$remote_url" ]]; then
            log_error "No 'origin' remote found in current directory"
            exit 4
        fi
        repo_args+=("$remote_url")
    fi

    if [[ ${#repo_args[@]} -eq 0 ]]; then
        log_error "Usage: ru add <repo> [repo2] ..."
        log_info "Examples:"
        log_info "  ru add owner/repo"
        log_info "  ru add https://github.com/owner/repo"
        log_info "  ru add --from-cwd          # Add current directory's repo"
        log_info "  ru add --private owner/repo  # Add to private list"
        exit 4
    fi

    # Ensure config exists
    ensure_config_exists >/dev/null

    # Select repos file based on --private flag
    local repos_file
    if [[ "$use_private" == "true" ]]; then
        repos_file="$RU_CONFIG_DIR/repos.d/private.txt"
        # Create private.txt if it doesn't exist
        if [[ ! -f "$repos_file" ]]; then
            echo "# Private repositories" > "$repos_file"
        fi
    else
        repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
    fi

    for repo in "${repo_args[@]}"; do
        # Parse the repo spec to extract URL (ignoring branch/custom name for dupe check)
        # shellcheck disable=SC2034  # spec_branch/spec_name set by nameref, intentionally unused
        local spec_url spec_branch spec_name
        parse_repo_spec "$repo" spec_url spec_branch spec_name

        # Validate the URL can be parsed and get canonical form
        local host owner repo_name
        if ! parse_repo_url "$spec_url" host owner repo_name; then
            log_error "Invalid repo format: $repo"
            continue
        fi

        # Build canonical form for duplicate detection: host/owner/repo
        local canonical="${host}/${owner}/${repo_name}"

        # Check if already in file by comparing normalized URLs
        # This handles owner/repo vs https://github.com/owner/repo as duplicates
        local already_exists="false"
        local matching_line=""

        # Read all non-comment lines and check each one
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            # Parse the existing spec to get its URL
            # shellcheck disable=SC2034  # existing_branch/existing_name set by nameref, intentionally unused
            local existing_url existing_branch existing_name
            parse_repo_spec "$line" existing_url existing_branch existing_name

            # Parse and normalize the existing URL
            local existing_host existing_owner existing_repo
            if parse_repo_url "$existing_url" existing_host existing_owner existing_repo; then
                local existing_canonical="${existing_host}/${existing_owner}/${existing_repo}"
                if [[ "$canonical" == "$existing_canonical" ]]; then
                    already_exists="true"
                    matching_line="$line"
                    break
                fi
            fi
        done < <(grep -v '^[[:space:]]*#' "$repos_file" 2>/dev/null)

        if [[ "$already_exists" == "true" ]]; then
            if [[ "$repo" == "$matching_line" ]]; then
                log_warn "Already configured: $repo"
            else
                log_warn "Already configured: $repo (matches: $matching_line)"
            fi
            continue
        fi

        # Also check the other repos file (public vs private)
        local other_file other_label
        if [[ "$use_private" == "true" ]]; then
            other_file="$RU_CONFIG_DIR/repos.d/repos.txt"
            other_label="public"
        else
            other_file="$RU_CONFIG_DIR/repos.d/private.txt"
            other_label="private"
        fi

        if [[ -f "$other_file" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                # shellcheck disable=SC2034  # existing_branch, existing_name set by nameref but only URL used
                local existing_url existing_branch existing_name
                parse_repo_spec "$line" existing_url existing_branch existing_name
                local existing_host existing_owner existing_repo
                if parse_repo_url "$existing_url" existing_host existing_owner existing_repo; then
                    local existing_canonical="${existing_host}/${existing_owner}/${existing_repo}"
                    if [[ "$canonical" == "$existing_canonical" ]]; then
                        log_warn "Already configured in $other_label list: $line"
                        already_exists="true"
                        break
                    fi
                fi
            done < <(grep -v '^[[:space:]]*#' "$other_file" 2>/dev/null)
        fi

        if [[ "$already_exists" == "true" ]]; then
            continue
        fi

        # Add to file
        echo "$repo" >> "$repos_file"
        local file_label=""
        [[ "$use_private" == "true" ]] && file_label=" (private)"
        log_success "Added: $repo$file_label"
    done
}

# Import repos from files with auto public/private detection
cmd_import() {
    local force_public="false"
    local force_private="false"
    local file_args=()

    # Parse import-specific options from ARGS
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --public)  force_public="true" ;;
            --private) force_private="true" ;;
            *)         file_args+=("$arg") ;;
        esac
    done

    if [[ ${#file_args[@]} -eq 0 ]]; then
        log_error "Usage: ru import [--dry-run] [--public|--private] <file> [file2] ..."
        log_info ""
        log_info "Import repositories from files into your ru configuration."
        log_info "By default, uses GitHub API to auto-detect public/private status."
        log_info ""
        log_info "Options:"
        log_info "  --dry-run   Preview changes without modifying config files"
        log_info "  --public    Force all repos to be added as public"
        log_info "  --private   Force all repos to be added as private"
        log_info ""
        log_info "Supported formats in files:"
        log_info "  owner/repo"
        log_info "  https://github.com/owner/repo"
        log_info "  git@github.com:owner/repo.git"
        exit 4
    fi

    # Check if we can auto-detect visibility (only works for github.com repos)
    local can_detect_visibility="false"
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        can_detect_visibility="true"
    fi

    if [[ "$can_detect_visibility" == "false" && "$force_public" == "false" && "$force_private" == "false" ]]; then
        log_warn "GitHub CLI (gh) not available or not authenticated"
        log_warn "Cannot auto-detect public/private status"
        log_info "Use --public or --private to specify, or authenticate gh"
        exit 3
    fi

    # Ensure config exists
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_error "No configuration found. Run: ru init"
        exit 3
    fi

    local repos_dir="$RU_CONFIG_DIR/repos.d"
    mkdir -p "$repos_dir"

    local public_file="$repos_dir/repos.txt"
    local private_file="$repos_dir/private.txt"

    # Initialize files if needed
    [[ ! -f "$public_file" ]] && touch "$public_file"
    [[ ! -f "$private_file" ]] && touch "$private_file"

    # Counters
    local imported_public=0
    local imported_private=0
    local skipped_duplicate=0
    local skipped_invalid=0
    local skipped_error=0
    local total_lines=0

    # Arrays for detailed reporting
    local invalid_repos=()
    local error_repos=()

    # Process each file
    for input_file in "${file_args[@]}"; do
        if [[ ! -f "$input_file" ]]; then
            log_error "File not found: $input_file"
            continue
        fi

        log_info "Processing: $input_file"
        local file_line_count=0

        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            line="${line%%#*}"
            # Trim leading and trailing whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue

            ((total_lines++))
            ((file_line_count++))

            # Parse the URL
            local host="" owner="" repo=""
            if ! parse_repo_url "$line" host owner repo 2>/dev/null; then
                ((skipped_invalid++))
                invalid_repos+=("$line")
                continue
            fi

            # Normalize to canonical form
            local normalized
            normalized=$(normalize_url "$line")

            # Check for duplicates in both files
            if grep -qxF "$normalized" "$public_file" 2>/dev/null || \
               grep -qxF "$normalized" "$private_file" 2>/dev/null; then
                ((skipped_duplicate++))
                continue
            fi

            # Determine visibility
            local is_private="unknown"

            if [[ "$force_private" == "true" ]]; then
                is_private="true"
            elif [[ "$force_public" == "true" ]]; then
                is_private="false"
            elif [[ "$can_detect_visibility" == "true" && "$host" == "github.com" ]]; then
                # Use GitHub API to detect visibility (only works for github.com)
                local api_response
                if api_response=$(gh api "repos/$owner/$repo" --jq '.private' 2>/dev/null); then
                    if [[ "$api_response" == "true" ]]; then
                        is_private="true"
                    else
                        is_private="false"
                    fi
                else
                    ((skipped_error++))
                    error_repos+=("$line|API lookup failed")
                    continue
                fi
            elif [[ "$host" != "github.com" ]]; then
                # Non-GitHub host: default to public (can't auto-detect visibility)
                is_private="false"
            fi

            # Add to appropriate file
            if [[ "$is_private" == "true" ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    printf '%s\n' "$normalized" >> "$private_file"
                fi
                ((imported_private++))
            else
                if [[ "$DRY_RUN" != "true" ]]; then
                    printf '%s\n' "$normalized" >> "$public_file"
                fi
                ((imported_public++))
            fi

        done < "$input_file"

        log_info "  Processed $file_line_count entries from $(basename "$input_file")"
    done

    # Print summary
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%b\n' "${BOLD}Import Preview${RESET} (dry-run)" >&2
    else
        printf '%b\n' "${BOLD}Import Summary${RESET}" >&2
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

    local total_imported=$((imported_public + imported_private))

    # Success stats
    if [[ $total_imported -gt 0 ]]; then
        printf '%b\n' "${GREEN}✓${RESET} Imported:    ${BOLD}$total_imported${RESET} repos" >&2
        if [[ $imported_public -gt 0 ]]; then
            printf '%b\n' "              └─ ${CYAN}$imported_public public${RESET}" >&2
        fi
        if [[ $imported_private -gt 0 ]]; then
            printf '%b\n' "              └─ ${MAGENTA}$imported_private private${RESET}" >&2
        fi
    fi

    # Skip stats
    if [[ $skipped_duplicate -gt 0 ]]; then
        printf '%b\n' "${YELLOW}⏭${RESET}  Duplicates: ${BOLD}$skipped_duplicate${RESET} (already configured)" >&2
    fi

    if [[ $skipped_invalid -gt 0 ]]; then
        printf '%b\n' "${RED}✗${RESET} Invalid:     ${BOLD}$skipped_invalid${RESET} (couldn't parse)" >&2
        if [[ "$VERBOSE" == "true" ]]; then
            for item in "${invalid_repos[@]}"; do
                printf '%b\n' "              └─ ${DIM}$item${RESET}" >&2
            done
        fi
    fi

    if [[ $skipped_error -gt 0 ]]; then
        printf '%b\n' "${RED}✗${RESET} Errors:      ${BOLD}$skipped_error${RESET} (API/network issues)" >&2
        if [[ "$VERBOSE" == "true" ]]; then
            for item in "${error_repos[@]}"; do
                local repo_part="${item%%|*}"
                local error_part="${item#*|}"
                printf '%b\n' "              └─ ${DIM}$repo_part: $error_part${RESET}" >&2
            done
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    printf '%b\n' "Total lines processed: ${BOLD}$total_lines${RESET}" >&2

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "" >&2
        log_info "Run without --dry-run to apply changes"
    fi

    # Exit with appropriate code
    if [[ $skipped_invalid -gt 0 || $skipped_error -gt 0 ]]; then
        exit 1  # Partial failure
    fi
    exit 0
}

cmd_remove() {
    if [[ ${#ARGS[@]} -eq 0 ]]; then
        log_error "Usage: ru remove <repo> [repo2] ..."
        log_info "Examples:"
        log_info "  ru remove owner/repo"
        log_info "  ru remove https://github.com/owner/repo"
        exit 4
    fi

    # Ensure config exists
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_error "No configuration found. Run: ru init"
        exit 3
    fi

    local repos_dir="$RU_CONFIG_DIR/repos.d"
    if [[ ! -d "$repos_dir" ]]; then
        log_error "No repositories configured"
        exit 3
    fi

    local removed=0 not_found=0

    for repo in "${ARGS[@]}"; do
        # Normalize the repo URL for matching
        local host owner repo_name
        if ! parse_repo_url "$repo" host owner repo_name; then
            log_error "Invalid repo format: $repo"
            continue
        fi

        local found_in_any="false"

        # Search all .txt files in repos.d/
        for repos_file in "$repos_dir"/*.txt; do
            [[ -f "$repos_file" ]] || continue

            # Parse each line and compare owner/repo to avoid substring matching issues
            local tmp_file="${repos_file}.tmp.$$"
            local found="false"

            while IFS= read -r line || [[ -n "$line" ]]; do
                # Skip empty lines and preserve them
                if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
                    echo "$line" >> "$tmp_file"
                    continue
                fi

                # Parse the line to extract URL and compare owner/repo
                # shellcheck disable=SC2034  # line_branch and line_custom_name are set by nameref but unused here
                local line_url line_branch line_custom_name
                parse_repo_spec "$line" line_url line_branch line_custom_name

                # shellcheck disable=SC2034  # line_host is set by nameref but unused here
                local line_host line_owner line_repo
                local should_remove="false"
                if parse_repo_url "$line_url" line_host line_owner line_repo; then
                    # Match if owner and repo name are exactly the same
                    if [[ "$line_owner" == "$owner" && "$line_repo" == "$repo_name" ]]; then
                        should_remove="true"
                    fi
                fi

                if [[ "$should_remove" == "true" ]]; then
                    found="true"
                    # Don't add to tmp file (remove it)
                else
                    echo "$line" >> "$tmp_file"
                fi
            done < "$repos_file"

            if [[ "$found" == "true" ]]; then
                mv "$tmp_file" "$repos_file"
                local file_name
                file_name=$(basename "$repos_file" .txt)
                log_success "Removed: $repo (from $file_name)"
                found_in_any="true"
                ((removed++))
            else
                rm -f "$tmp_file"
            fi
        done

        if [[ "$found_in_any" != "true" ]]; then
            log_warn "Not found in any list: $repo"
            ((not_found++))
        fi
    done

    if [[ $removed -eq 0 && $not_found -gt 0 ]]; then
        exit 1
    fi
}

cmd_list() {
    # Ensure config exists
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_info "No configuration found. Run: ru init"
        exit 0
    fi

    local show_paths="false"
    local filter_public="false"
    local filter_private="false"
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --paths) show_paths="true" ;;
            --public) filter_public="true" ;;
            --private) filter_private="true" ;;
        esac
    done

    # Validate mutually exclusive flags
    if [[ "$filter_public" == "true" && "$filter_private" == "true" ]]; then
        log_error "--public and --private are mutually exclusive"
        exit 4
    fi

    local repos=()
    if [[ "$filter_public" == "true" ]]; then
        # Only repos from repos.txt (public)
        local repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
        if [[ -f "$repos_file" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && repos+=("$line")
            done < <(load_repo_list "$repos_file")
        fi
    elif [[ "$filter_private" == "true" ]]; then
        # Only repos from private.txt
        local private_file="$RU_CONFIG_DIR/repos.d/private.txt"
        if [[ -f "$private_file" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && repos+=("$line")
            done < <(load_repo_list "$private_file")
        fi
    else
        # All repos (default behavior)
        while IFS= read -r line; do
            [[ -n "$line" ]] && repos+=("$line")
        done < <(get_all_repos)
    fi

    if [[ ${#repos[@]} -eq 0 ]]; then
        log_info "No repositories configured."
        log_info "Add repos with: ru add owner/repo"
        exit 0
    fi

    log_info "Configured repositories (${#repos[@]}):"
    echo "" >&2

    for repo_spec in "${repos[@]}"; do
        local url branch custom_name local_path repo_id
        if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
            continue
        fi

        if [[ "$show_paths" == "true" ]]; then
            echo "$local_path"
        else
            echo "$url"
        fi
    done
}

cmd_doctor() {
    local issues=0

    log_info "System Check"
    echo "────────────────────────────────────────" >&2

    # Check git
    if command -v git &>/dev/null; then
        local git_version
        git_version=$(git --version | sed 's/git version //')
        printf '%b\n' "${GREEN}[OK]${RESET} git: $git_version" >&2
    else
        printf '%b\n' "${RED}[!!]${RESET} git: not installed" >&2
        ((issues++))
    fi

    # Check gh CLI
    if command -v gh &>/dev/null; then
        local gh_version gh_user
        gh_version=$(gh --version | head -1 | awk '{print $3}')
        if gh auth status &>/dev/null; then
            gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
            printf '%b\n' "${GREEN}[OK]${RESET} gh: $gh_version (authenticated as $gh_user)" >&2
        else
            printf '%b\n' "${YELLOW}[??]${RESET} gh: $gh_version (not authenticated)" >&2
            ((issues++))
        fi
    else
        printf '%b\n' "${YELLOW}[??]${RESET} gh: not installed (needed for private repos)" >&2
    fi

    # Check config directory
    if [[ -d "$RU_CONFIG_DIR" ]]; then
        printf '%b\n' "${GREEN}[OK]${RESET} Config: $RU_CONFIG_DIR" >&2
    else
        printf '%b\n' "${YELLOW}[??]${RESET} Config: not initialized (run: ru init)" >&2
    fi

    # Check repos configured
    local repo_count=0
    if [[ -d "$RU_CONFIG_DIR/repos.d" ]]; then
        while IFS= read -r _; do
            ((repo_count++))
        done < <(get_all_repos 2>/dev/null)
    fi
    if [[ $repo_count -gt 0 ]]; then
        printf '%b\n' "${GREEN}[OK]${RESET} Repos: $repo_count configured" >&2
    else
        printf '%b\n' "${YELLOW}[??]${RESET} Repos: none configured" >&2
    fi

    # Check projects directory
    if [[ -d "$PROJECTS_DIR" ]]; then
        if [[ -w "$PROJECTS_DIR" ]]; then
            printf '%b\n' "${GREEN}[OK]${RESET} Projects: $PROJECTS_DIR (writable)" >&2
        else
            printf '%b\n' "${RED}[!!]${RESET} Projects: $PROJECTS_DIR (not writable)" >&2
            ((issues++))
        fi
    else
        printf '%b\n' "${YELLOW}[??]${RESET} Projects: $PROJECTS_DIR (will be created)" >&2
    fi

    # Check gum (optional)
    if command -v gum &>/dev/null; then
        local gum_version
        gum_version=$(gum --version 2>/dev/null | head -1 || echo "unknown")
        printf '%b\n' "${GREEN}[OK]${RESET} gum: $gum_version" >&2
    else
        printf '%b\n' "${DIM}[  ]${RESET} gum: not installed (optional, for prettier UI)" >&2
    fi

    echo "" >&2

    if [[ $issues -eq 0 ]]; then
        log_success "All checks passed!"
    else
        log_warn "$issues issue(s) found"
        exit 3
    fi
}

cmd_self_update() {
    local check_only="false"

    # Parse --check option
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --check) check_only="true" ;;
        esac
    done

    log_step "Checking for updates..."

    # Get current version
    local current_version="$VERSION"
    log_verbose "Current version: $current_version"

    # Fetch latest release version from GitHub API
    local api_url="$RU_GITHUB_API/repos/$RU_REPO_OWNER/$RU_REPO_NAME/releases/latest"
    local response
    if command -v curl &>/dev/null; then
        response=$(curl -sS "$api_url" 2>/dev/null) || {
            log_error "Failed to fetch latest release from GitHub"
            exit 3
        }
    elif command -v wget &>/dev/null; then
        response=$(wget -qO- "$api_url" 2>/dev/null) || {
            log_error "Failed to fetch latest release from GitHub"
            exit 3
        }
    else
        log_error "Neither curl nor wget found"
        exit 3
    fi

    # Check for "Not Found" response (no releases exist)
    if echo "$response" | grep -q '"message"[[:space:]]*:[[:space:]]*"Not Found"'; then
        log_info "No releases found on GitHub"
        log_info "You may be running a development version"
        exit 0
    fi

    # Extract version from response (simple grep for portability)
    local latest_version
    latest_version=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$latest_version" ]]; then
        log_error "Could not parse version from GitHub API response"
        log_verbose "Response: $response"
        exit 3
    fi

    # Remove 'v' prefix if present
    latest_version="${latest_version#v}"
    log_verbose "Latest version: $latest_version"

    # Compare versions
    if [[ "$current_version" == "$latest_version" ]]; then
        log_success "Already up to date (v$current_version)"
        exit 0
    fi

    # Version comparison (simple string comparison works for semver)
    log_info "Update available: v$current_version -> v$latest_version"

    if [[ "$check_only" == "true" ]]; then
        # --check mode: just report and exit
        echo "" >&2
        log_info "Run 'ru self-update' to install the update"
        exit 0
    fi

    # Prompt for confirmation if interactive
    if can_prompt; then
        if ! gum_confirm "Update to v$latest_version?"; then
            log_info "Update cancelled"
            exit 0
        fi
    fi

    # Create temp directory for download
    local temp_dir
    temp_dir=$(mktemp_dir) || { log_error "Failed to create temp directory"; exit 3; }
    # Clean up on exit, but preserve global cleanup behavior
    trap 'rm -rf "$temp_dir"; cleanup' EXIT

    # Download URLs
    local release_base="https://github.com/$RU_REPO_OWNER/$RU_REPO_NAME/releases/download/v$latest_version"
    local script_url="$release_base/ru"
    local checksum_url="$release_base/checksums.txt"

    # Download the new script
    log_step "Downloading v$latest_version..."
    if command -v curl &>/dev/null; then
        if ! curl -fsSL "$script_url" -o "$temp_dir/ru"; then
            log_error "Failed to download update"
            exit 1
        fi
    else
        if ! wget -q "$script_url" -O "$temp_dir/ru"; then
            log_error "Failed to download update"
            exit 1
        fi
    fi

    # Download and verify checksum
    log_step "Verifying checksum..."
    local checksum_verified="false"
    if command -v curl &>/dev/null; then
        curl -fsSL "$checksum_url" -o "$temp_dir/checksums.txt" 2>/dev/null || true
    else
        wget -q "$checksum_url" -O "$temp_dir/checksums.txt" 2>/dev/null || true
    fi

    if [[ -f "$temp_dir/checksums.txt" ]]; then
        local expected_checksum
        expected_checksum=$(grep -E "^[a-f0-9]{64}[[:space:]]+\*?ru$" "$temp_dir/checksums.txt" | cut -d' ' -f1)

        if [[ -n "$expected_checksum" ]]; then
            local actual_checksum
            if command -v sha256sum &>/dev/null; then
                actual_checksum=$(sha256sum "$temp_dir/ru" | cut -d' ' -f1)
            elif command -v shasum &>/dev/null; then
                actual_checksum=$(shasum -a 256 "$temp_dir/ru" | cut -d' ' -f1)
            fi

            if [[ -n "$actual_checksum" ]]; then
                if [[ "$actual_checksum" == "$expected_checksum" ]]; then
                    log_success "Checksum verified"
                    checksum_verified="true"
                else
                    log_error "Checksum verification failed!"
                    log_error "Expected: $expected_checksum"
                    log_error "Got:      $actual_checksum"
                    exit 1
                fi
            fi
        fi
    fi

    if [[ "$checksum_verified" != "true" ]]; then
        log_warn "Could not verify checksum (checksums.txt not found or incomplete)"
        if can_prompt; then
            if ! gum_confirm "Continue without checksum verification?"; then
                log_info "Update cancelled"
                exit 0
            fi
        else
            log_error "Cannot proceed without checksum verification in non-interactive mode"
            exit 1
        fi
    fi

    # Verify the downloaded script is valid bash
    if ! bash -n "$temp_dir/ru" 2>/dev/null; then
        log_error "Downloaded file is not valid bash script"
        exit 1
    fi

    # Get the path to the current script (with fallback for systems without realpath)
    local script_path
    if command -v realpath &>/dev/null; then
        script_path=$(realpath "${BASH_SOURCE[0]}")
    elif command -v readlink &>/dev/null && readlink -f "${BASH_SOURCE[0]}" &>/dev/null 2>&1; then
        script_path=$(readlink -f "${BASH_SOURCE[0]}")
    else
        # Fallback: use cd/pwd to resolve
        script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    fi

    # Check if we can write to the script location
    if [[ ! -w "$script_path" ]]; then
        log_error "Cannot write to $script_path (permission denied)"
        log_info "Try: sudo ru self-update"
        exit 1
    fi

    # Atomic replacement: copy to temp in same directory, then mv
    local script_dir
    script_dir=$(dirname "$script_path")
    local temp_script="$script_dir/.ru.update.$$"

    log_step "Installing update..."
    cp "$temp_dir/ru" "$temp_script"
    chmod +x "$temp_script"

    # Atomic move to replace
    if mv "$temp_script" "$script_path"; then
        log_success "Updated to v$latest_version"
        echo "" >&2
        log_info "Run 'ru --version' to verify"
    else
        rm -f "$temp_script"
        log_error "Failed to install update"
        exit 1
    fi
}

cmd_config() {
    # Check for --print flag
    local print_mode="false"
    local set_value=""

    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --print)
                print_mode="true"
                ;;
            --set=*)
                set_value="${arg#--set=}"
                ;;
        esac
    done

    # If --set provided, set the value
    if [[ -n "$set_value" ]]; then
        local key="${set_value%%=*}"
        local value="${set_value#*=}"
        if [[ "$key" == "$set_value" ]]; then
            log_error "Invalid format. Use: --set KEY=VALUE"
            exit 4
        fi
        set_config_value "$key" "$value"
        log_success "Set $key=$value"
        return
    fi

    # Print configuration
    log_info "Configuration (resolved):"
    echo "  PROJECTS_DIR=$PROJECTS_DIR" >&2
    echo "  LAYOUT=$LAYOUT" >&2
    echo "  UPDATE_STRATEGY=$UPDATE_STRATEGY" >&2
    echo "  AUTOSTASH=$AUTOSTASH" >&2
    echo "  PARALLEL=$PARALLEL" >&2
    echo "" >&2
    log_info "Config file: $RU_CONFIG_DIR/config"
    log_info "Repos file:  $RU_CONFIG_DIR/repos.d/repos.txt"

    if [[ "$print_mode" == "true" && -f "$RU_CONFIG_DIR/config" ]]; then
        echo "" >&2
        log_info "Config file contents:"
        cat "$RU_CONFIG_DIR/config" >&2
    fi
}

#------------------------------------------------------------------------------
# cmd_prune: Find and manage orphan repositories
#------------------------------------------------------------------------------
cmd_prune() {
    local archive_mode="false"
    local delete_mode="false"

    # Parse arguments
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --archive) archive_mode="true" ;;
            --delete) delete_mode="true" ;;
            -*)
                log_error "Unknown prune option: $arg"
                exit 4
                ;;
        esac
    done

    # Check for conflicting options
    if [[ "$archive_mode" == "true" && "$delete_mode" == "true" ]]; then
        log_error "Cannot use both --archive and --delete"
        exit 4
    fi

    # Check projects directory exists
    if [[ ! -d "$PROJECTS_DIR" ]]; then
        log_warn "Projects directory does not exist: $PROJECTS_DIR"
        return 0
    fi

    # Build list of expected paths from config
    local configured_paths
    configured_paths=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    # shellcheck disable=SC2064  # Immediate expansion is intentional - path is already known
    trap "rm -f \"$configured_paths\"" RETURN

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        local url branch custom_name local_path repo_id
        if resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
            echo "$local_path"
        fi
    done < <(get_all_repos) | sort -u > "$configured_paths"

    # Find all git repositories in projects directory
    # Depth to .git directory: flat=2, owner-repo=3, full=4
    local orphans=()
    local depth_limit
    case "$LAYOUT" in
        flat)       depth_limit=2 ;;
        owner-repo) depth_limit=3 ;;
        full)       depth_limit=4 ;;
        *)          depth_limit=4 ;;
    esac

    while IFS= read -r repo_path; do
        # Skip if in configured paths
        if grep -qxF "$repo_path" "$configured_paths" 2>/dev/null; then
            continue
        fi
        orphans+=("$repo_path")
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth "$depth_limit" -type d -name ".git" -exec dirname {} \; 2>/dev/null | sort)

    # Report results
    if [[ ${#orphans[@]} -eq 0 ]]; then
        log_success "No orphan repositories found"
        return 0
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        # JSON output
        local json_array="["
        local first="true"
        for path in "${orphans[@]}"; do
            if [[ "$first" == "true" ]]; then
                first="false"
            else
                json_array+=","
            fi
            local safe_path
            safe_path=$(json_escape "$path")
            json_array+="{\"path\":\"$safe_path\"}"
        done
        json_array+="]"
        echo "$json_array"
    else
        log_info "Found ${#orphans[@]} orphan repository(s):"
        for path in "${orphans[@]}"; do
            echo "  $path" >&2
        done
    fi

    # Handle archive mode
    if [[ "$archive_mode" == "true" ]]; then
        local archive_dir="${RU_STATE_DIR}/archived"
        mkdir -p "$archive_dir"

        log_info "Archiving ${#orphans[@]} orphan(s) to $archive_dir"
        local archived=0
        for path in "${orphans[@]}"; do
            local name
            name=$(basename "$path")
            local timestamp
            timestamp=$(date +%Y%m%d_%H%M%S)
            local dest="${archive_dir}/${name}_${timestamp}"

            if mv "$path" "$dest" 2>/dev/null; then
                log_step "Archived: $name -> $dest"
                ((archived++))
            else
                log_error "Failed to archive: $path"
            fi
        done
        log_success "Archived $archived orphan(s)"
        return 0
    fi

    # Handle delete mode
    if [[ "$delete_mode" == "true" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            log_warn "This will permanently delete ${#orphans[@]} repository(s)!"
            echo "" >&2
            for path in "${orphans[@]}"; do
                echo "  $path" >&2
            done
            echo "" >&2

            local confirm=""
            if [[ "$GUM_AVAILABLE" == "true" ]]; then
                if ! gum confirm "Delete these repositories?"; then
                    log_info "Aborted"
                    return 0
                fi
            else
                echo -n "Type 'delete' to confirm: " >&2
                read -r confirm
                if [[ "$confirm" != "delete" ]]; then
                    log_info "Aborted"
                    return 0
                fi
            fi
        fi

        local deleted=0
        for path in "${orphans[@]}"; do
            local name
            name=$(basename "$path")
            if rm -rf "$path" 2>/dev/null; then
                log_step "Deleted: $name"
                ((deleted++))
            else
                log_error "Failed to delete: $path"
            fi
        done
        log_success "Deleted $deleted orphan(s)"
        return 0
    fi

    # Default: just list (dry run)
    echo "" >&2
    log_info "Use --archive to move to archive or --delete to remove"
}

#------------------------------------------------------------------------------
# SECTION 13.5: REVIEW COMMAND SUPPORT FUNCTIONS
#------------------------------------------------------------------------------

# Check if review prerequisites are met
check_review_prerequisites() {
    local has_errors=false

    # Check for gh CLI
    if ! check_gh_installed; then
        log_error "GitHub CLI (gh) is required for review command"
        has_errors=true
    elif ! check_gh_auth; then
        log_error "gh CLI not authenticated. Run: gh auth login"
        has_errors=true
    fi

    # Check for Claude Code (claude command)
    if ! command -v claude &>/dev/null; then
        log_warn "Claude Code CLI not found. Review sessions will not work."
        log_warn "Install: npm install -g @anthropic-ai/claude-cli"
        # Not a hard error - might be doing discovery only
    fi

    [[ "$has_errors" == "true" ]] && return 1
    return 0
}

# Get path to review lock file
get_review_lock_file() {
    echo "${RU_STATE_DIR}/review.lock"
}

# Acquire review lock (prevents concurrent reviews)
acquire_review_lock() {
    local lock_file
    lock_file=$(get_review_lock_file)
    ensure_dir "$(dirname "$lock_file")"

    # Try to get exclusive lock
    exec 9>"$lock_file"
    if ! flock -n 9 2>/dev/null; then
        # Check if the lock holder is still running
        local pid=""
        if [[ -f "$lock_file" ]]; then
            pid=$(cat "$lock_file" 2>/dev/null || true)
        fi
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Another review is running (PID $pid)"
        else
            log_error "Stale lock file exists. Remove manually: $lock_file"
        fi
        return 1
    fi

    # Write our PID to the lock file
    echo $$ > "$lock_file"
    return 0
}

# Release review lock
release_review_lock() {
    local lock_file
    lock_file=$(get_review_lock_file)
    # Remove PID from file
    : > "$lock_file"
    # Release the flock (closing fd 9)
    exec 9>&-
}

# Detect which review driver to use
detect_review_driver() {
    # Check if ntm is available and running
    if command -v ntm &>/dev/null; then
        # Try to query ntm status
        if ntm list --robot 2>/dev/null | grep -q "session"; then
            echo "ntm"
            return
        fi
    fi

    # Fallback to local driver (tmux + stream-json)
    if command -v tmux &>/dev/null; then
        echo "local"
        return
    fi

    # No driver available
    echo "none"
}

#------------------------------------------------------------------------------
# UNIFIED SESSION DRIVER INTERFACE
#
# This interface defines the contract between the review orchestration layer
# and the session drivers (ntm, local). Both drivers implement these functions.
#
# Event Schema (normalized across drivers):
# {
#   "type": "init|generating|waiting|complete|error",
#   "session_id": "string",
#   "timestamp": "ISO-8601",
#   "wait_info": {                    # Only present when type="waiting"
#     "reason": "ask_user_question|agent_question_text|external_prompt|unknown",
#     "context": "string",
#     "options": ["a) ...", "b) ..."],
#     "recommended": "a",
#     "risk_level": "low|medium|high"
#   },
#   "error_info": {                   # Only present when type="error"
#     "code": "string",
#     "message": "string",
#     "retryable": boolean
#   }
# }
#------------------------------------------------------------------------------

# Load a review driver implementation
# Args: driver_name ("ntm" or "local")
# Returns: 0 on success, 1 on failure
load_review_driver() {
    local driver="$1"

    case "$driver" in
        ntm)
            # ntm driver uses robot mode API for advanced orchestration
            log_verbose "Loading ntm driver"
            LOADED_DRIVER="ntm"
            _enable_ntm_driver
            ;;
        local)
            # Local driver (tmux + stream-json)
            log_verbose "Loading local driver"
            LOADED_DRIVER="local"
            _enable_local_driver
            ;;
        none)
            log_error "No driver to load"
            return 1
            ;;
        *)
            log_error "Unknown driver: $driver"
            return 1
            ;;
    esac

    return 0
}

# Query driver capabilities
# Returns: JSON object with capability flags
driver_capabilities() {
    # Base implementation - drivers override this
    cat <<EOF
{
  "name": "${LOADED_DRIVER:-unknown}",
  "parallel_sessions": true,
  "activity_detection": false,
  "health_monitoring": false,
  "question_routing": true,
  "max_concurrent": 4
}
EOF
}

# Start a new Claude Code session in a worktree
# Args: worktree_path, session_name, initial_prompt
# Returns: session_id on stdout, 0 on success
driver_start_session() {
    # shellcheck disable=SC2034  # Variables used by driver implementations
    local wt_path="$1" session_name="$2" prompt="$3"

    # Stub - drivers must implement
    log_error "driver_start_session not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# Send a message/answer to an existing session
# Args: session_id, message
# Returns: 0 on success
driver_send_to_session() {
    local session_id="$1"
    local message="$2"

    # Stub - drivers must implement
    log_error "driver_send_to_session not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# Get current state of a session
# Args: session_id
# Returns: JSON with state info on stdout
driver_get_session_state() {
    local session_id="$1"

    # Stub - drivers must implement
    cat <<EOF
{
  "session_id": "$session_id",
  "state": "unknown",
  "error": "driver_get_session_state not implemented"
}
EOF
    return 1
}

# Stop/kill a session gracefully
# Args: session_id
# Returns: 0 on success
driver_stop_session() {
    local session_id="$1"

    # Stub - drivers must implement
    log_error "driver_stop_session not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# Interrupt a session (Ctrl+C equivalent)
# Args: session_id
# Returns: 0 on success
driver_interrupt_session() {
    local session_id="$1"

    # Stub - drivers must implement
    log_error "driver_interrupt_session not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# Stream events from a session
# Args: session_id, callback_function_name
# The callback receives: event_type, event_json
# Blocks until session completes or is interrupted
driver_stream_events() {
    # shellcheck disable=SC2034  # Variables used by driver implementations
    local session_id="$1" callback="$2"

    # Stub - drivers must implement
    log_error "driver_stream_events not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# List all active sessions for this driver
# Returns: newline-separated session IDs
driver_list_sessions() {
    # Stub - drivers must implement
    log_error "driver_list_sessions not implemented for driver: ${LOADED_DRIVER:-none}"
    return 1
}

# Check if a session is still alive
# Args: session_id
# Returns: 0 if alive, 1 if dead/unknown
driver_session_alive() {
    local session_id="$1"

    # Stub - drivers must implement (default: unknown = dead)
    return 1
}

#------------------------------------------------------------------------------
# LOCAL DRIVER IMPLEMENTATION (tmux + stream-json)
#
# This driver uses tmux to manage Claude Code sessions and parses the
# stream-json output format for event detection.
#------------------------------------------------------------------------------

# Local driver: Start a new Claude Code session
local_driver_start_session() {
    local wt_path="$1"
    local session_name="$2"
    local prompt="$3"

    # Validate tmux is available
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is required for local driver"
        return 1
    fi

    # Create .ru directory for session artifacts
    local ru_dir="$wt_path/.ru"
    ensure_dir "$ru_dir"

    local log_file="$ru_dir/session.log"
    local event_pipe="$ru_dir/events.pipe"
    local state_file="$ru_dir/session.state"

    # Create named pipe for event streaming
    rm -f "$event_pipe"
    if ! mkfifo "$event_pipe" 2>/dev/null; then
        log_error "Failed to create event pipe: $event_pipe"
        return 1
    fi

    # Initialize state file
    cat > "$state_file" <<EOF
{
  "session_id": "$session_name",
  "state": "starting",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Build claude command with stream-json output
    # shellcheck disable=SC2016  # Single quotes intentional for tmux
    local claude_cmd
    claude_cmd='claude -p '"$(printf '%q' "$prompt")"' --output-format stream-json'

    # Create tmux session running claude
    if ! tmux new-session -d -s "$session_name" -c "$wt_path" \
        "exec bash -c '$claude_cmd 2>&1 | tee \"$log_file\" > \"$event_pipe\"'"; then
        log_error "Failed to create tmux session: $session_name"
        rm -f "$event_pipe"
        return 1
    fi

    # Update state to running
    cat > "$state_file" <<EOF
{
  "session_id": "$session_name",
  "state": "generating",
  "worktree": "$wt_path",
  "log_file": "$log_file",
  "event_pipe": "$event_pipe",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Return session info on stdout
    cat "$state_file"
    return 0
}

# Local driver: Send a message to an existing session
local_driver_send_to_session() {
    local session_id="$1"
    local message="$2"

    # Check if session exists
    if ! tmux has-session -t "$session_id" 2>/dev/null; then
        log_error "Session not found: $session_id"
        return 1
    fi

    # Send via tmux (each line as Enter-terminated input)
    tmux send-keys -t "$session_id" "$message" Enter

    return $?
}

# Local driver: Get current session state
local_driver_get_session_state() {
    local session_id="$1"

    # Check if tmux session exists
    if ! tmux has-session -t "$session_id" 2>/dev/null; then
        cat <<EOF
{
  "session_id": "$session_id",
  "state": "dead",
  "reason": "tmux session not found"
}
EOF
        return 0
    fi

    # Check if process is running in the session
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session_id" -F "#{pane_pid}" 2>/dev/null | head -1)

    if [[ -z "$pane_pid" ]]; then
        cat <<EOF
{
  "session_id": "$session_id",
  "state": "unknown",
  "reason": "no pane found"
}
EOF
        return 0
    fi

    # Check if child process (claude) is running
    local children
    children=$(pgrep -P "$pane_pid" 2>/dev/null | wc -l)

    local state="generating"
    if [[ "$children" -eq 0 ]]; then
        state="complete"
    fi

    cat <<EOF
{
  "session_id": "$session_id",
  "state": "$state",
  "pane_pid": $pane_pid
}
EOF
    return 0
}

# Local driver: Stop/kill a session gracefully
local_driver_stop_session() {
    local session_id="$1"

    # Kill tmux session
    tmux kill-session -t "$session_id" 2>/dev/null || true

    return 0
}

# Local driver: Interrupt a session (Ctrl+C equivalent)
local_driver_interrupt_session() {
    local session_id="$1"

    # Check if session exists
    if ! tmux has-session -t "$session_id" 2>/dev/null; then
        return 1
    fi

    # Send Ctrl+C
    tmux send-keys -t "$session_id" C-c

    return 0
}

#------------------------------------------------------------------------------
# STREAM-JSON EVENT PARSING (bd-8zt6)
# Parse Claude Code's --output-format stream-json NDJSON output
#------------------------------------------------------------------------------

# Parse a single stream-json event line
# Args:
#   $1 - JSON line to parse
#   $2 - nameref for event_type output
#   $3 - nameref for event_data output
# Returns:
#   0 if valid JSON, 1 if invalid
parse_stream_json_event() {
    local line="$1"
    local -n _pse_event_type=$2
    local -n _pse_event_data=$3

    # Validate JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
        _pse_event_type="invalid"
        _pse_event_data="$line"
        return 1
    fi

    _pse_event_type=$(echo "$line" | jq -r '.type // "unknown"')

    case "$_pse_event_type" in
        system)
            local subtype
            subtype=$(echo "$line" | jq -r '.subtype // ""')
            if [[ "$subtype" == "init" ]]; then
                _pse_event_data=$(echo "$line" | jq -c '{session_id, tools, cwd}')
            else
                _pse_event_data=$(echo "$line" | jq -c '.')
            fi
            ;;
        assistant)
            _pse_event_data=$(echo "$line" | jq -c '.message.content // []')
            ;;
        user)
            _pse_event_data=$(echo "$line" | jq -c '.message.content // []')
            ;;
        result)
            _pse_event_data=$(echo "$line" | jq -c '{status, duration_ms, session_id, cost_usd}')
            ;;
        *)
            _pse_event_data="$line"
            ;;
    esac

    return 0
}

# Detect if an assistant event contains AskUserQuestion tool use
# Args:
#   $1 - Event data (message.content array)
# Returns:
#   0 if AskUserQuestion found, 1 otherwise
detect_ask_user_question() {
    local event_data="$1"

    # Check if any content block is AskUserQuestion
    echo "$event_data" | jq -e \
        '.[] | select(.type == "tool_use" and .name == "AskUserQuestion")' \
        >/dev/null 2>&1
}

# Extract question information from AskUserQuestion tool use
# Args:
#   $1 - Event data (message.content array)
# Outputs:
#   JSON object with question details
extract_question_info() {
    local event_data="$1"

    # Extract the AskUserQuestion input
    local question_input
    question_input=$(echo "$event_data" | jq -c \
        '[.[] | select(.name == "AskUserQuestion")] | .[0].input // {}')

    # Parse first question (usually only one)
    local tool_use_id
    tool_use_id=$(echo "$event_data" | jq -r \
        '[.[] | select(.name == "AskUserQuestion")] | .[0].id // ""')

    # Format for queue
    echo "$question_input" | jq --arg tool_id "$tool_use_id" '{
        questions: .questions,
        tool_use_id: $tool_id,
        detected_at: (now | todate)
    }'
}

# Detect questions in plain text output (fallback detection)
# Args:
#   $1 - Text to check for question patterns
# Returns:
#   0 if question pattern found, 1 otherwise
detect_text_question() {
    local text="$1"

    # Question patterns
    local -a patterns=(
        'Should I'
        'Do you want'
        'Would you like'
        'Please confirm'
        'Choose.*:'
        'Which.*\?'
        'What.*\?'
        'How should'
        '\[y/N\]'
        '\[Y/n\]'
        'Enter.*:'
        'Press.*to'
    )

    for pattern in "${patterns[@]}"; do
        if echo "$text" | grep -qiE "$pattern"; then
            return 0
        fi
    done

    return 1
}

# Extract text content from assistant message
# Args:
#   $1 - Event data (message.content array)
# Outputs:
#   Plain text extracted from text blocks
extract_text_content() {
    local event_data="$1"

    echo "$event_data" | jq -r \
        '[.[] | select(.type == "text") | .text] | join("\n")'
}

# Check if event contains tool use
# Args:
#   $1 - Event data (message.content array)
# Outputs:
#   Tool names used (newline-separated)
get_tool_uses() {
    local event_data="$1"

    echo "$event_data" | jq -r \
        '[.[] | select(.type == "tool_use") | .name] | .[]'
}

# Process stream-json events from a file/pipe
# Args:
#   $1 - Path to log file or named pipe
#   $2 - Callback function name (receives: event_type, event_data)
# Returns:
#   0 on successful completion, 1 on error
process_stream_json() {
    local source="$1"
    local callback="$2"

    # Validate callback is a function
    if ! declare -F "$callback" >/dev/null 2>&1; then
        log_error "process_stream_json: callback '$callback' is not a function"
        return 1
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local event_type event_data
        if ! parse_stream_json_event "$line" event_type event_data; then
            log_verbose "Skipping invalid JSON line"
            continue
        fi

        case "$event_type" in
            system)
                "$callback" "init" "$event_data"
                ;;
            assistant)
                # Check for AskUserQuestion
                if detect_ask_user_question "$event_data"; then
                    local question_info
                    question_info=$(extract_question_info "$event_data")
                    "$callback" "question" "$question_info"
                else
                    # Check for text content with question patterns
                    local text_content
                    text_content=$(extract_text_content "$event_data")
                    if [[ -n "$text_content" ]] && detect_text_question "$text_content"; then
                        "$callback" "text_question" "$text_content"
                    else
                        "$callback" "assistant" "$event_data"
                    fi
                fi
                ;;
            user)
                "$callback" "user" "$event_data"
                ;;
            result)
                "$callback" "complete" "$event_data"
                break
                ;;
            *)
                "$callback" "unknown" "$event_data"
                ;;
        esac
    done < "$source"
}

# Local driver: Stream events from a session
# Parses NDJSON from Claude's stream-json output
local_driver_stream_events() {
    local session_id="$1"
    local callback="$2"
    local wt_path="${3:-}"

    # If worktree path not provided, try to discover it
    if [[ -z "$wt_path" ]]; then
        # Look for session artifacts in state directory
        local session_dir="$RU_STATE_DIR/sessions/$session_id"
        if [[ -d "$session_dir" ]]; then
            wt_path=$(cat "$session_dir/worktree_path" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$wt_path" ]] || [[ ! -d "$wt_path" ]]; then
        log_error "Cannot find worktree for session: $session_id"
        return 1
    fi

    local log_file="$wt_path/.ru/session.log"
    local event_pipe="$wt_path/.ru/events.pipe"

    # Prefer pipe if exists, otherwise use log file with tail -f
    if [[ -p "$event_pipe" ]]; then
        process_stream_json "$event_pipe" "$callback"
    elif [[ -f "$log_file" ]]; then
        # Use tail -f for real-time streaming
        tail -f "$log_file" | process_stream_json /dev/stdin "$callback"
    else
        log_error "No event source found for session: $session_id"
        return 1
    fi
}

# Local driver: List all active sessions
local_driver_list_sessions() {
    # List tmux sessions with ru- prefix
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^ru-" || true
}

# Local driver: Check if a session is still alive
local_driver_session_alive() {
    local session_id="$1"

    tmux has-session -t "$session_id" 2>/dev/null
    return $?
}

#------------------------------------------------------------------------------
# NTM DRIVER IMPLEMENTATION
# Uses ntm robot mode API for advanced session orchestration
#------------------------------------------------------------------------------

# Check if ntm is available and working
ntm_is_available() {
    if ! command -v ntm &>/dev/null; then
        return 1
    fi
    # Verify ntm responds to status query
    if ! ntm --robot-status &>/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ntm driver: Start a new Claude Code session
ntm_driver_start_session() {
    local wt_path="$1"
    local session_name="$2"
    local prompt="$3"

    # Validate ntm is available
    if ! ntm_is_available; then
        log_error "ntm is not available or not responding"
        return 1
    fi

    # Create .ru directory for session artifacts
    local ru_dir="$wt_path/.ru"
    ensure_dir "$ru_dir"

    local state_file="$ru_dir/session.state"
    local log_file="$ru_dir/session.log"

    # Initialize state file
    cat > "$state_file" <<EOF
{
  "session_id": "$session_name",
  "state": "starting",
  "driver": "ntm",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Use ntm robot-spawn to create session
    local spawn_result
    if ! spawn_result=$(ntm --robot-spawn "$session_name" --dir "$wt_path" --prompt "$prompt" 2>&1); then
        log_error "ntm spawn failed: $spawn_result"
        return 1
    fi

    # Parse spawn result for pane info
    local pane_id
    pane_id=$(echo "$spawn_result" | jq -r '.panes[0] // empty' 2>/dev/null)

    if [[ -z "$pane_id" ]]; then
        pane_id=$(tmux list-panes -t "$session_name" -F "#{pane_id}" 2>/dev/null | head -1)
    fi

    # Update state to running
    cat > "$state_file" <<EOF
{
  "session_id": "$session_name",
  "pane_id": "${pane_id:-unknown}",
  "state": "generating",
  "driver": "ntm",
  "worktree": "$wt_path",
  "log_file": "$log_file",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    cat "$state_file"
    return 0
}

# ntm driver: Send a message to an existing session
ntm_driver_send_to_session() {
    local session_id="$1"
    local message="$2"

    # Get pane ID from ntm status
    local pane_id
    pane_id=$(ntm --robot-status 2>/dev/null | jq -r ".sessions[\"$session_id\"].panes[0] // empty" 2>/dev/null)

    if [[ -z "$pane_id" ]]; then
        pane_id=$(tmux list-panes -t "$session_id" -F "#{pane_id}" 2>/dev/null | head -1)
    fi

    if [[ -z "$pane_id" ]]; then
        log_error "Cannot find pane for session: $session_id"
        return 1
    fi

    # Use ntm robot-send for delivery confirmation
    local send_result
    if send_result=$(ntm --robot-send --pane="$pane_id" --msg="$message" 2>&1); then
        local delivered
        delivered=$(echo "$send_result" | jq -r '.delivered // false' 2>/dev/null)
        if [[ "$delivered" == "true" ]]; then
            return 0
        fi
    fi

    # Fallback: direct tmux send
    log_verbose "Falling back to direct tmux send for $session_id"
    tmux send-keys -t "$session_id" "$message" Enter
    return $?
}

# Map ntm activity state to unified state
ntm_map_state() {
    local ntm_state="$1"
    case "${ntm_state^^}" in
        GENERATING) echo "generating" ;;
        WAITING)    echo "waiting" ;;
        THINKING)   echo "thinking" ;;
        STALLED)    echo "stalled" ;;
        ERROR)      echo "error" ;;
        IDLE)       echo "idle" ;;
        *)          echo "unknown" ;;
    esac
}

# ntm driver: Get current session state with enhanced activity detection
ntm_driver_get_session_state() {
    local session_id="$1"

    if ! tmux has-session -t "$session_id" 2>/dev/null; then
        cat <<EOF
{
  "session_id": "$session_id",
  "state": "dead",
  "driver": "ntm",
  "reason": "session not found"
}
EOF
        return 0
    fi

    local pane_id
    pane_id=$(ntm --robot-status 2>/dev/null | jq -r ".sessions[\"$session_id\"].panes[0] // empty" 2>/dev/null)
    if [[ -z "$pane_id" ]]; then
        pane_id=$(tmux list-panes -t "$session_id" -F "#{pane_id}" 2>/dev/null | head -1)
    fi

    local activity_json
    if activity_json=$(ntm --robot-activity="$pane_id" 2>/dev/null); then
        local ntm_state velocity confidence unified_state
        ntm_state=$(echo "$activity_json" | jq -r '.state // "UNKNOWN"')
        velocity=$(echo "$activity_json" | jq -r '.velocity // 0')
        confidence=$(echo "$activity_json" | jq -r '.confidence // 0')
        unified_state=$(ntm_map_state "$ntm_state")

        cat <<EOF
{
  "session_id": "$session_id",
  "pane_id": "$pane_id",
  "state": "$unified_state",
  "driver": "ntm",
  "ntm_state": "$ntm_state",
  "velocity": $velocity,
  "confidence": $confidence
}
EOF
    else
        cat <<EOF
{
  "session_id": "$session_id",
  "pane_id": "$pane_id",
  "state": "unknown",
  "driver": "ntm",
  "reason": "ntm activity query failed"
}
EOF
    fi
    return 0
}

# ntm driver: Stop a session
ntm_driver_stop_session() {
    local session_id="$1"
    if tmux has-session -t "$session_id" 2>/dev/null; then
        tmux kill-session -t "$session_id" 2>/dev/null
        return $?
    fi
    return 0
}

# ntm driver: Interrupt/pause a session
ntm_driver_interrupt_session() {
    local session_id="$1"
    if tmux has-session -t "$session_id" 2>/dev/null; then
        tmux send-keys -t "$session_id" C-c
        return $?
    fi
    return 1
}

# ntm driver: Stream events from session (polling-based)
# shellcheck disable=SC2034  # Variables used by implementation
ntm_driver_stream_events() {
    local session_id="$1" callback="$2"
    local poll_interval="${3:-2}"
    local last_state="" pane_id

    pane_id=$(ntm --robot-status 2>/dev/null | jq -r ".sessions[\"$session_id\"].panes[0] // empty" 2>/dev/null)

    while true; do
        if ! tmux has-session -t "$session_id" 2>/dev/null; then
            $callback "session_end" '{"reason": "session terminated"}'
            break
        fi

        local activity_json
        if activity_json=$(ntm --robot-activity="$pane_id" 2>/dev/null); then
            local current_state
            current_state=$(echo "$activity_json" | jq -r '.state // "UNKNOWN"')

            if [[ "$current_state" != "$last_state" ]]; then
                local unified_state
                unified_state=$(ntm_map_state "$current_state")
                $callback "state_change" "{\"state\": \"$unified_state\", \"ntm_state\": \"$current_state\"}"

                if [[ "$current_state" == "WAITING" ]]; then
                    $callback "waiting" "$activity_json"
                fi
                last_state="$current_state"
            fi
        fi

        local health_json
        if health_json=$(ntm --robot-health="$session_id" 2>/dev/null); then
            local alert_count
            alert_count=$(echo "$health_json" | jq '.alerts | length' 2>/dev/null || echo "0")
            if [[ "$alert_count" -gt 0 ]]; then
                $callback "health_alert" "$(echo "$health_json" | jq -c '.alerts')"
            fi
        fi

        sleep "$poll_interval"
    done
}

# ntm driver: List all sessions managed by ntm
ntm_driver_list_sessions() {
    local status_json
    if ! status_json=$(ntm --robot-status 2>/dev/null); then
        return 1
    fi
    echo "$status_json" | jq -r '.sessions | keys[]' 2>/dev/null
}

# ntm driver: Check if session is alive
ntm_driver_session_alive() {
    local session_id="$1"
    tmux has-session -t "$session_id" 2>/dev/null
    return $?
}

# Override stub functions when ntm driver is loaded
_enable_ntm_driver() {
    driver_start_session() { ntm_driver_start_session "$@"; }
    driver_send_to_session() { ntm_driver_send_to_session "$@"; }
    driver_get_session_state() { ntm_driver_get_session_state "$@"; }
    driver_stop_session() { ntm_driver_stop_session "$@"; }
    driver_interrupt_session() { ntm_driver_interrupt_session "$@"; }
    driver_stream_events() { ntm_driver_stream_events "$@"; }
    driver_list_sessions() { ntm_driver_list_sessions "$@"; }
    driver_session_alive() { ntm_driver_session_alive "$@"; }

    driver_capabilities() {
        cat <<EOF
{
  "name": "ntm",
  "parallel_sessions": true,
  "activity_detection": true,
  "health_monitoring": true,
  "question_routing": true,
  "velocity_based": true,
  "max_concurrent": 8
}
EOF
    }
}

#------------------------------------------------------------------------------
# DRIVER FUNCTION ROUTING
# Routes driver_* calls to the appropriate implementation based on LOADED_DRIVER
#------------------------------------------------------------------------------

# Override stub functions when local driver is loaded
_enable_local_driver() {
    driver_start_session() {
        local_driver_start_session "$@"
    }
    driver_send_to_session() {
        local_driver_send_to_session "$@"
    }
    driver_get_session_state() {
        local_driver_get_session_state "$@"
    }
    driver_stop_session() {
        local_driver_stop_session "$@"
    }
    driver_interrupt_session() {
        local_driver_interrupt_session "$@"
    }
    driver_stream_events() {
        local_driver_stream_events "$@"
    }
    driver_list_sessions() {
        local_driver_list_sessions "$@"
    }
    driver_session_alive() {
        local_driver_session_alive "$@"
    }

    # Update capabilities for local driver
    driver_capabilities() {
        cat <<EOF
{
  "name": "local",
  "parallel_sessions": true,
  "activity_detection": false,
  "health_monitoring": false,
  "question_routing": true,
  "max_concurrent": 4
}
EOF
    }
}

# Parse review-specific arguments
parse_review_args() {
    # Reset review-specific variables
    REVIEW_MODE="plan"           # plan or apply
    REVIEW_DRIVER="auto"         # auto, ntm, or local
    REVIEW_PARALLEL=4            # concurrent sessions
    REVIEW_DRY_RUN="false"       # discovery only
    # shellcheck disable=SC2034  # Used by later phases
    REVIEW_RESUME="${RESUME:-false}"  # use global --resume flag
    REVIEW_PUSH="false"          # allow pushing (with apply)
    REVIEW_PRIORITY="all"        # min priority threshold
    REVIEW_REPOS_PATTERN=""      # filter repos by pattern
    REVIEW_SKIP_DAYS=7           # skip recently reviewed
    REVIEW_MAX_REPOS=""          # cost budget
    REVIEW_MAX_RUNTIME=""        # time budget (minutes)
    REVIEW_MAX_QUESTIONS=""      # question budget

    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --plan)
                REVIEW_MODE="plan"
                ;;
            --apply)
                REVIEW_MODE="apply"
                ;;
            --mode=*)
                REVIEW_DRIVER="${arg#--mode=}"
                if [[ ! "$REVIEW_DRIVER" =~ ^(auto|ntm|local)$ ]]; then
                    log_error "Invalid --mode: $REVIEW_DRIVER (use auto, ntm, or local)"
                    exit 4
                fi
                ;;
            --parallel=*|-j=*)
                REVIEW_PARALLEL="${arg#*=}"
                if ! is_positive_int "$REVIEW_PARALLEL"; then
                    log_error "Invalid --parallel value: $REVIEW_PARALLEL"
                    exit 4
                fi
                ;;
            -j[0-9]*)
                REVIEW_PARALLEL="${arg#-j}"
                ;;
            --repos=*)
                REVIEW_REPOS_PATTERN="${arg#--repos=}"
                ;;
            --skip-days=*)
                REVIEW_SKIP_DAYS="${arg#--skip-days=}"
                if ! is_positive_int "$REVIEW_SKIP_DAYS"; then
                    log_error "Invalid --skip-days value: $REVIEW_SKIP_DAYS"
                    exit 4
                fi
                ;;
            --priority=*)
                REVIEW_PRIORITY="${arg#--priority=}"
                if [[ ! "$REVIEW_PRIORITY" =~ ^(all|critical|high|normal|low)$ ]]; then
                    log_error "Invalid --priority: $REVIEW_PRIORITY"
                    exit 4
                fi
                ;;
            --dry-run)
                REVIEW_DRY_RUN="true"
                ;;
            --push)
                REVIEW_PUSH="true"
                ;;
            --max-repos=*)
                REVIEW_MAX_REPOS="${arg#--max-repos=}"
                if ! is_positive_int "$REVIEW_MAX_REPOS"; then
                    log_error "Invalid --max-repos value: $REVIEW_MAX_REPOS"
                    exit 4
                fi
                ;;
            --max-runtime=*)
                REVIEW_MAX_RUNTIME="${arg#--max-runtime=}"
                if ! is_positive_int "$REVIEW_MAX_RUNTIME"; then
                    log_error "Invalid --max-runtime value: $REVIEW_MAX_RUNTIME"
                    exit 4
                fi
                ;;
            --max-questions=*)
                REVIEW_MAX_QUESTIONS="${arg#--max-questions=}"
                if ! is_positive_int "$REVIEW_MAX_QUESTIONS"; then
                    log_error "Invalid --max-questions value: $REVIEW_MAX_QUESTIONS"
                    exit 4
                fi
                ;;
            -*)
                log_error "Unknown review option: $arg"
                exit 4
                ;;
            *)
                # Positional arguments could be repo patterns
                if [[ -z "$REVIEW_REPOS_PATTERN" ]]; then
                    REVIEW_REPOS_PATTERN="$arg"
                else
                    REVIEW_REPOS_PATTERN="$REVIEW_REPOS_PATTERN $arg"
                fi
                ;;
        esac
    done
}

#------------------------------------------------------------------------------
# STATE PERSISTENCE FUNCTIONS
# Atomic JSON operations with flock-based locking
#------------------------------------------------------------------------------

# File descriptor for state lock (separate from review session lock)
STATE_LOCK_FD=201

# Get path to review state directory
get_review_state_dir() {
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/review"
}

# Acquire exclusive lock on state files
# Returns: 0 on success, 1 on failure
acquire_state_lock() {
    local state_dir
    state_dir=$(get_review_state_dir)
    ensure_dir "$state_dir"
    local lock_file="$state_dir/state.lock"

    # Open fd for locking
    eval "exec $STATE_LOCK_FD>\"$lock_file\""

    # Get exclusive lock (blocking)
    if ! flock -x "$STATE_LOCK_FD" 2>/dev/null; then
        log_error "Failed to acquire state lock"
        return 1
    fi
    return 0
}

# Release state lock
release_state_lock() {
    flock -u "$STATE_LOCK_FD" 2>/dev/null || true
}

# Execute a function while holding the state lock
# Args: function_name [args...]
with_state_lock() {
    acquire_state_lock || return 1
    "$@"
    local rc=$?
    release_state_lock
    return $rc
}

# Write JSON content atomically to a file
# Args: file_path, content
# Returns: 0 on success, 1 if JSON invalid or write failed
write_json_atomic() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp.$$"

    # Ensure parent directory exists
    ensure_dir "$(dirname "$file")"

    # Write to temp file
    if ! echo "$content" > "$tmp_file" 2>/dev/null; then
        log_error "Failed to write temp file: $tmp_file"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    # Validate JSON before committing (if jq is available)
    if command -v jq &>/dev/null; then
        if ! jq empty "$tmp_file" 2>/dev/null; then
            log_error "Invalid JSON, refusing to write: $file"
            rm -f "$tmp_file" 2>/dev/null || true
            return 1
        fi
    fi

    # Atomic move
    if ! mv "$tmp_file" "$file" 2>/dev/null; then
        log_error "Failed to atomically update: $file"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    return 0
}

# Read JSON state file with locking
# Args: file_path [default_content]
# Returns: file contents on stdout (or default if file doesn't exist)
read_state_json() {
    local file="$1"
    local default="${2:-{}}"

    acquire_state_lock || { echo "$default"; return 1; }

    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "$default"
    fi

    release_state_lock
}

# Get the review state file path
get_review_state_file() {
    echo "$(get_review_state_dir)/review-state.json"
}

# Get the questions queue file path
get_questions_file() {
    echo "$(get_review_state_dir)/review-questions.json"
}

# Get the checkpoint file path
get_checkpoint_file() {
    echo "$(get_review_state_dir)/review-checkpoint.json"
}

# Initialize empty review state if it doesn't exist
init_review_state() {
    local state_file
    state_file=$(get_review_state_file)

    if [[ ! -f "$state_file" ]]; then
        local initial_state='{"version":2,"repos":{},"items":{},"runs":{}}'
        with_state_lock write_json_atomic "$state_file" "$initial_state"
    fi
}

# Update review state with a jq filter
# Args: jq_filter
# Returns: 0 on success
update_review_state() {
    local updates="$1"
    local state_file
    state_file=$(get_review_state_file)

    acquire_state_lock || return 1

    local current
    if [[ -f "$state_file" ]]; then
        current=$(cat "$state_file")
    else
        current='{"version":2,"repos":{},"items":{},"runs":{}}'
    fi

    # Apply jq update if jq is available
    if command -v jq &>/dev/null; then
        local updated
        if ! updated=$(echo "$current" | jq "$updates" 2>/dev/null); then
            log_error "Failed to apply state update: $updates"
            release_state_lock
            return 1
        fi
        write_json_atomic "$state_file" "$updated"
    else
        # Without jq, we can't do complex updates
        log_warn "jq not available, state update skipped"
    fi

    release_state_lock
}

# Record outcome for a reviewed item (issue or PR)
# Args: repo_id, item_type (issue|pr), number, outcome, notes
record_item_outcome() {
    local repo_id="$1"
    local item_type="$2"
    local number="$3"
    local outcome="$4"
    local notes="${5:-}"

    local item_key="${repo_id}#${item_type}-${number}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Escape notes for JSON
    local escaped_notes
    escaped_notes=$(json_escape "$notes")

    update_review_state "
        .items[\"$item_key\"] = {
            \"type\": \"$item_type\",
            \"number\": $number,
            \"last_review\": \"$now\",
            \"outcome\": \"$outcome\",
            \"notes\": \"$escaped_notes\"
        }
    "
}

# Record outcome for a reviewed repository
# Args: repo_id, outcome, duration_seconds, issues_reviewed, prs_reviewed
record_repo_outcome() {
    local repo_id="$1"
    local outcome="$2"
    local duration="${3:-0}"
    local issues_reviewed="${4:-0}"
    local prs_reviewed="${5:-0}"

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local run_id="${REVIEW_RUN_ID:-unknown}"

    update_review_state "
        .repos[\"$repo_id\"] = (.repos[\"$repo_id\"] // {}) + {
            \"last_review\": \"$now\",
            \"last_review_run_id\": \"$run_id\",
            \"issues_reviewed\": $issues_reviewed,
            \"prs_reviewed\": $prs_reviewed,
            \"outcome\": \"$outcome\",
            \"duration_seconds\": $duration
        }
    "
}

# Record a completed review run
# Args: repos_processed, items_processed, questions_asked
record_review_run() {
    local repos_processed="${1:-0}"
    local items_processed="${2:-0}"
    local questions_asked="${3:-0}"

    local run_id="${REVIEW_RUN_ID:-unknown}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local mode="${REVIEW_MODE:-plan}"
    # shellcheck disable=SC2153  # REVIEW_START_TIME is intentionally uppercase
    local start_time="${REVIEW_START_TIME:-$now}"

    update_review_state "
        .runs[\"$run_id\"] = {
            \"started_at\": \"$start_time\",
            \"completed_at\": \"$now\",
            \"repos_processed\": $repos_processed,
            \"items_processed\": $items_processed,
            \"questions_asked\": $questions_asked,
            \"mode\": \"$mode\"
        }
    "
}

# Save a checkpoint for resume functionality
# Args: completed_repos (space-separated string), pending_repos (space-separated string)
# shellcheck disable=SC2178,SC2128  # Intentionally using space-separated strings
checkpoint_review_state() {
    local completed_repos="$1"
    local pending_repos="$2"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local run_id="${REVIEW_RUN_ID:-unknown}"
    local mode="${REVIEW_MODE:-plan}"

    # Convert space-separated to JSON arrays
    local completed_json pending_json
    if command -v jq &>/dev/null; then
        completed_json=$(echo "$completed_repos" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
        pending_json=$(echo "$pending_repos" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
    else
        # Simple fallback without jq
        completed_json="[]"
        pending_json="[]"
    fi

    # Count repos
    local completed_count pending_count
    completed_count=$(echo "$completed_repos" | wc -w | tr -d ' ')
    pending_count=$(echo "$pending_repos" | wc -w | tr -d ' ')
    local total=$((completed_count + pending_count))

    local checkpoint
    checkpoint=$(cat <<EOF
{
  "version": 1,
  "timestamp": "$now",
  "run_id": "$run_id",
  "mode": "$mode",
  "repos_total": $total,
  "repos_completed": $completed_count,
  "repos_pending": $pending_count,
  "completed_repos": $completed_json,
  "pending_repos": $pending_json
}
EOF
)

    with_state_lock write_json_atomic "$checkpoint_file" "$checkpoint"
}

# Load checkpoint for resume
# Returns: JSON checkpoint on stdout, or empty if no checkpoint
load_review_checkpoint() {
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    if [[ -f "$checkpoint_file" ]]; then
        cat "$checkpoint_file"
    else
        echo ""
    fi
}

# Clear checkpoint after successful completion
clear_review_checkpoint() {
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    rm -f "$checkpoint_file" 2>/dev/null || true
}

# Check if a repo was recently reviewed (within skip_days)
# Args: repo_id, skip_days
# Returns: 0 if recently reviewed, 1 if not
is_recently_reviewed() {
    local repo_id="$1"
    local skip_days="${2:-7}"

    local state_file
    state_file=$(get_review_state_file)

    if [[ ! -f "$state_file" ]] || ! command -v jq &>/dev/null; then
        return 1
    fi

    local last_review
    last_review=$(jq -r ".repos[\"$repo_id\"].last_review // \"\"" "$state_file" 2>/dev/null)

    if [[ -z "$last_review" || "$last_review" == "null" ]]; then
        return 1
    fi

    # Calculate cutoff date
    local cutoff
    if date --version 2>/dev/null | grep -q GNU; then
        cutoff=$(date -u -d "$skip_days days ago" +%Y-%m-%dT%H:%M:%SZ)
    else
        cutoff=$(date -u -v-${skip_days}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    fi

    if [[ -z "$cutoff" ]]; then
        return 1
    fi

    # Compare timestamps (lexicographic comparison works for ISO format)
    if [[ "$last_review" > "$cutoff" ]]; then
        return 0  # Recently reviewed
    fi

    return 1  # Not recently reviewed
}

# Clean up old review state data
# Args: max_age_days (default: 30)
cleanup_old_review_state() {
    local max_age_days="${1:-30}"
    local state_dir
    state_dir=$(get_review_state_dir)

    # Clean old worktrees if they exist
    local worktrees_dir="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/worktrees"
    if [[ -d "$worktrees_dir" ]]; then
        find "$worktrees_dir" -maxdepth 1 -type d -mtime "+$max_age_days" \
            -exec rm -rf {} \; 2>/dev/null || true
    fi

    # Prune old runs from state file (requires jq)
    if ! command -v jq &>/dev/null; then
        return 0
    fi

    local cutoff
    if date --version 2>/dev/null | grep -q GNU; then
        cutoff=$(date -u -d "$max_age_days days ago" +%Y-%m-%dT%H:%M:%SZ)
    else
        cutoff=$(date -u -v-${max_age_days}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    fi

    if [[ -z "$cutoff" ]]; then
        return 0
    fi

    update_review_state "
        .runs |= with_entries(select(.value.started_at > \"$cutoff\"))
    "
}

#------------------------------------------------------------------------------
# GRAPHQL BATCHED REPOSITORY DISCOVERY (bd-ff8h)
#
# Efficiently discovers open issues and PRs across all configured repos
# using GraphQL alias batching (up to 25 repos per API call).
#------------------------------------------------------------------------------

# Split repo IDs into chunks for batched GraphQL queries
# Args: chunk_size, repo_ids...
# Output: Each chunk on a separate line (repos within chunk are newline-separated)
chunk_repo_ids() {
    local chunk_size="$1"
    shift
    local repos=("$@")
    local count=0
    local chunk=""

    for repo in "${repos[@]}"; do
        chunk+="${repo}"$'\n'
        ((count++))
        if [[ $count -ge $chunk_size ]]; then
            printf '%s' "$chunk"
            chunk=""
            count=0
        fi
    done

    # Output remaining repos
    [[ -n "$chunk" ]] && printf '%s' "$chunk"
}

# Execute GraphQL query for a batch of repos
# Args: chunk (newline-separated repo IDs like owner/repo)
# Output: GraphQL JSON response
gh_api_graphql_repo_batch() {
    local chunk="$1"
    local q="query {"
    local i=0

    while IFS= read -r repo_id; do
        [[ -z "$repo_id" ]] && continue
        local owner="${repo_id%%/*}"
        local name="${repo_id#*/}"

        # Build aliased query for this repo
        q+=" repo${i}: repository(owner:\"${owner}\", name:\"${name}\") {"
        q+=" nameWithOwner isArchived isFork updatedAt"
        # Issues with metadata for scoring
        q+=" issues(states:OPEN, first:50, orderBy:{field:CREATED_AT, direction:DESC}) {"
        q+="   nodes { number title createdAt updatedAt"
        q+="     labels(first:10) { nodes { name } }"
        q+="   }"
        q+=" }"
        # PRs with metadata for scoring
        q+=" pullRequests(states:OPEN, first:20, orderBy:{field:CREATED_AT, direction:DESC}) {"
        q+="   nodes { number title createdAt updatedAt isDraft"
        q+="     labels(first:10) { nodes { name } }"
        q+="   }"
        q+=" }"
        q+=" }"
        ((i++))
    done <<< "$chunk"

    q+=" }"

    # Execute query via gh CLI
    gh api graphql -f query="$q" 2>/dev/null
}

# Parse GraphQL response into work items (TSV format)
# Args: json_response
# Output: TSV lines: repo_id\ttype\tnumber\ttitle\tlabels\tcreated_at\tupdated_at\tis_draft
parse_graphql_work_items() {
    local resp="$1"

    echo "$resp" | jq -r '
        .data | to_entries[] | select(.value != null) |
        select(.value.isArchived != true) |
        select(.value.isFork != true) |
        .value as $repo |
        (
            # Issues
            ($repo.issues.nodes // [])[] |
            [$repo.nameWithOwner, "issue", .number, .title,
             ([.labels.nodes[].name] | join(",")),
             .createdAt, .updatedAt, "false"] | @tsv
        ),
        (
            # PRs
            ($repo.pullRequests.nodes // [])[] |
            [$repo.nameWithOwner, "pr", .number, .title,
             ([.labels.nodes[].name] | join(",")),
             .createdAt, .updatedAt, (.isDraft | tostring)] | @tsv
        )
    ' 2>/dev/null
}

# Convert repo spec to owner/repo format (GitHub only)
# Args: repo_spec
# Output: owner/repo or empty if not GitHub
repo_spec_to_github_id() {
    local spec="$1"
    local url branch custom_name local_path repo_id

    # Parse spec to get repo_id
    if resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
        # Check if it's a GitHub repo
        if [[ "$url" =~ github\.com[/:] ]]; then
            echo "$repo_id"
        fi
    fi
}

# Discover work items from GitHub using GraphQL batching
# Args: result_array_name, priority_filter, max_repos
discover_work_items() {
    local -n _items_ref=$1
    # shellcheck disable=SC2034  # Used in bd-5jph (priority scoring)
    local priority_filter="$2"
    local max_repos="$3"

    _items_ref=()

    # Check for jq (required for parsing)
    if ! command -v jq &>/dev/null; then
        log_warn "jq is required for work item discovery"
        return 0
    fi

    # Check for gh CLI
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI is required for work item discovery"
        return 0
    fi

    # Load all configured repos
    local -a all_repos=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_repos+=("$line")
    done < <(get_all_repos)

    if [[ ${#all_repos[@]} -eq 0 ]]; then
        log_verbose "No configured repos"
        return 0
    fi

    # Convert to GitHub IDs (filter non-GitHub repos)
    local -a github_repos=()
    for spec in "${all_repos[@]}"; do
        local github_id
        github_id=$(repo_spec_to_github_id "$spec")
        if [[ -n "$github_id" ]]; then
            github_repos+=("$github_id")
        fi
    done

    if [[ ${#github_repos[@]} -eq 0 ]]; then
        log_verbose "No GitHub repos configured"
        return 0
    fi

    log_verbose "Querying ${#github_repos[@]} GitHub repo(s)"

    # Process in chunks of 25
    local chunk_size=25
    local all_work_items=""
    local chunk=""
    local count=0

    for repo in "${github_repos[@]}"; do
        chunk+="${repo}"$'\n'
        ((count++))

        if [[ $count -ge $chunk_size ]]; then
            # Execute batch query
            log_verbose "Querying batch of $count repos"
            local response
            if response=$(gh_api_graphql_repo_batch "$chunk"); then
                local items
                items=$(parse_graphql_work_items "$response")
                [[ -n "$items" ]] && all_work_items+="${items}"$'\n'
            else
                log_warn "GraphQL batch query failed"
            fi
            chunk=""
            count=0
        fi
    done

    # Process remaining repos
    if [[ -n "$chunk" ]]; then
        log_verbose "Querying final batch of $count repos"
        local response
        if response=$(gh_api_graphql_repo_batch "$chunk"); then
            local items
            items=$(parse_graphql_work_items "$response")
            [[ -n "$items" ]] && all_work_items+="${items}"$'\n'
        else
            log_warn "GraphQL batch query failed"
        fi
    fi

    # Parse work items into array (pipe-separated format)
    # Format: repo_id|type|number|title|labels|created_at|updated_at|is_draft
    while IFS=$'\t' read -r repo_id item_type number title labels created_at updated_at is_draft; do
        [[ -z "$repo_id" ]] && continue
        # Convert TSV to pipe-separated for easier parsing later
        _items_ref+=("${repo_id}|${item_type}|${number}|${title}|${labels}|${created_at}|${updated_at}|${is_draft}")
    done <<< "$all_work_items"

    # Apply max_repos limit if specified
    if [[ -n "$max_repos" ]] && [[ ${#_items_ref[@]} -gt $max_repos ]]; then
        _items_ref=("${_items_ref[@]:0:$max_repos}")
    fi

    log_verbose "Discovered ${#_items_ref[@]} work item(s)"
}

# Stub: Show discovery summary (will be enhanced in later phases)
show_discovery_summary() {
    local items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        log_info "No work items to review"
        return
    fi

    log_info "Found ${#items[@]} work item(s) to review"
    # Real implementation will show priority breakdown, repo counts, etc.
}

#------------------------------------------------------------------------------
# cmd_review: Review GitHub issues and PRs using Claude Code
#------------------------------------------------------------------------------
cmd_review() {
    # Parse review-specific arguments
    parse_review_args

    # Check prerequisites
    if ! check_review_prerequisites; then
        exit 3
    fi

    # Generate unique run ID
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$$"
    # shellcheck disable=SC2034  # Used by later phases and logging
    REVIEW_RUN_ID="$run_id"

    # Acquire global lock
    if ! acquire_review_lock; then
        log_error "Another review is running. Use --resume to continue or wait."
        exit 1
    fi

    # Ensure cleanup on exit
    # shellcheck disable=SC2064
    trap "release_review_lock" EXIT

    # Auto-detect driver if needed
    if [[ "$REVIEW_DRIVER" == "auto" ]]; then
        REVIEW_DRIVER=$(detect_review_driver)
        log_verbose "Auto-detected driver: $REVIEW_DRIVER"
    fi

    if [[ "$REVIEW_DRIVER" == "none" ]]; then
        log_error "No review driver available. Install tmux or ntm."
        exit 3
    fi

    # Discovery phase
    log_step "Scanning repositories for open issues and PRs..."
    local -a work_items
    discover_work_items work_items "$REVIEW_PRIORITY" "$REVIEW_MAX_REPOS"

    if [[ ${#work_items[@]} -eq 0 ]]; then
        log_success "No work items need review"
        return 0
    fi

    # Show summary
    show_discovery_summary "${work_items[@]}"

    # Dry run exit point
    if [[ "$REVIEW_DRY_RUN" == "true" ]]; then
        log_info "Dry run complete - no sessions started"
        return 0
    fi

    # TODO: Orchestration phases (implemented in later beads)
    # - Prepare worktrees
    # - Start Claude Code sessions
    # - Monitor and aggregate questions
    # - Apply approved changes

    log_warn "Review orchestration not yet implemented"
    log_info "Run ID: $run_id"
    log_info "Driver: $REVIEW_DRIVER"
    log_info "Mode: $REVIEW_MODE"
    log_info "Parallel: $REVIEW_PARALLEL"

    if [[ "$REVIEW_MODE" == "apply" ]]; then
        log_info "Apply mode: would execute approved plans"
        if [[ "$REVIEW_PUSH" == "true" ]]; then
            log_info "Push enabled: would push approved changes"
        fi
    fi

    return 0
}

#------------------------------------------------------------------------------
# validate_review_plan: Validate review plan JSON schema
#
# Args:
#   $1 - Path to review-plan.json file
#
# Returns:
#   0 if valid, 1 if invalid
#
# Outputs:
#   Validation message to stdout
#------------------------------------------------------------------------------
validate_review_plan() {
    local plan_file="$1"

    # Must exist
    if [[ ! -f "$plan_file" ]]; then
        echo "Plan file not found: $plan_file"
        return 1
    fi

    # Must be valid JSON
    if ! jq empty "$plan_file" 2>/dev/null; then
        echo "Invalid JSON syntax"
        return 1
    fi

    # Required top-level fields: schema_version, repo, items
    if ! jq -e '.schema_version and .repo and .items' "$plan_file" >/dev/null 2>&1; then
        echo "Missing required fields: schema_version, repo, or items"
        return 1
    fi

    # Schema version check
    local version
    version=$(jq -r '.schema_version' "$plan_file")
    if [[ "$version" != "1" ]]; then
        echo "Unsupported schema version: $version (expected: 1)"
        return 1
    fi

    # Items array validation
    local items_count
    items_count=$(jq '.items | length' "$plan_file")
    if [[ "$items_count" -lt 0 ]]; then
        echo "Invalid items array"
        return 1
    fi

    # Items must have required fields: type, number, decision
    if ! jq -e '.items | if length == 0 then true else all(.type and .number and .decision) end' "$plan_file" >/dev/null 2>&1; then
        echo "Items missing required fields: type, number, or decision"
        return 1
    fi

    # Validate item type values (must be "issue" or "pr")
    local invalid_types
    invalid_types=$(jq -r '.items[] | select(.type | IN("issue","pr") | not) | .type' "$plan_file" 2>/dev/null)
    if [[ -n "$invalid_types" ]]; then
        echo "Invalid item type values: $invalid_types (expected: issue or pr)"
        return 1
    fi

    # Validate decision values (must be fix, skip, needs-info, or closed)
    local invalid_decisions
    invalid_decisions=$(jq -r '.items[] | select(.decision | IN("fix","skip","needs-info","closed") | not) | .decision' "$plan_file" 2>/dev/null)
    if [[ -n "$invalid_decisions" ]]; then
        echo "Invalid decision values: $invalid_decisions (expected: fix, skip, needs-info, or closed)"
        return 1
    fi

    # Validate gh_actions if present
    if jq -e '.gh_actions' "$plan_file" >/dev/null 2>&1; then
        # gh_actions must have op and target fields
        if ! jq -e '.gh_actions | if length == 0 then true else all(.op and .target) end' "$plan_file" >/dev/null 2>&1; then
            echo "gh_actions missing required fields: op or target"
            return 1
        fi

        # Validate op values (must be comment, close, label, or merge)
        local invalid_ops
        invalid_ops=$(jq -r '.gh_actions[] | select(.op | IN("comment","close","label","merge") | not) | .op' "$plan_file" 2>/dev/null)
        if [[ -n "$invalid_ops" ]]; then
            echo "Invalid gh_action op values: $invalid_ops (expected: comment, close, label, or merge)"
            return 1
        fi

        # Validate target format (must be issue#N or pr#N)
        local invalid_targets
        invalid_targets=$(jq -r '.gh_actions[] | select(.target | test("^(issue|pr)#[0-9]+$") | not) | .target' "$plan_file" 2>/dev/null)
        if [[ -n "$invalid_targets" ]]; then
            echo "Invalid gh_action target format: $invalid_targets (expected: issue#N or pr#N)"
            return 1
        fi
    fi

    # Validate questions if present
    if jq -e '.questions' "$plan_file" >/dev/null 2>&1; then
        # Questions must have id, prompt, and answered fields
        if ! jq -e '.questions | if length == 0 then true else all(.id and .prompt and (.answered != null)) end' "$plan_file" >/dev/null 2>&1; then
            echo "Questions missing required fields: id, prompt, or answered"
            return 1
        fi
    fi

    echo "Valid"
    return 0
}

#------------------------------------------------------------------------------
# summarize_review_plan: Generate human-readable summary of review plan
#
# Args:
#   $1 - Path to review-plan.json file
#
# Returns:
#   0 on success, 1 on failure
#
# Outputs:
#   Summary to stdout
#------------------------------------------------------------------------------
summarize_review_plan() {
    local plan_file="$1"

    # Validate first
    local validation_result
    validation_result=$(validate_review_plan "$plan_file")
    if [[ "$validation_result" != "Valid" ]]; then
        echo "Cannot summarize invalid plan: $validation_result"
        return 1
    fi

    # Generate summary using jq
    jq -r '
        "Repository: \(.repo)",
        "Run ID: \(.run_id // "N/A")",
        "",
        "Items reviewed: \(.items | length)",
        "  - Fixed: \([.items[] | select(.decision == "fix")] | length)",
        "  - Skipped: \([.items[] | select(.decision == "skip")] | length)",
        "  - Needs info: \([.items[] | select(.decision == "needs-info")] | length)",
        "  - Closed: \([.items[] | select(.decision == "closed")] | length)",
        "",
        "By type:",
        "  - Issues: \([.items[] | select(.type == "issue")] | length)",
        "  - PRs: \([.items[] | select(.type == "pr")] | length)",
        "",
        "Git changes:",
        "  - Commits: \(.git.commits // [] | length)",
        "  - Tests: \(if .git.tests.ok == true then "PASS" elif .git.tests.ok == false then "FAIL" else "NOT RUN" end)",
        "",
        "gh_actions pending: \(.gh_actions // [] | length)",
        "Questions: \(.questions // [] | length) (\([.questions // [] | .[] | select(.answered == true)] | length) answered)"
    ' "$plan_file"
}

#------------------------------------------------------------------------------
# get_review_plan_json_summary: Generate JSON summary of review plan
#
# Args:
#   $1 - Path to review-plan.json file
#
# Returns:
#   0 on success, 1 on failure
#
# Outputs:
#   JSON summary to stdout
#------------------------------------------------------------------------------
get_review_plan_json_summary() {
    local plan_file="$1"

    # Validate first
    local validation_result
    validation_result=$(validate_review_plan "$plan_file")
    if [[ "$validation_result" != "Valid" ]]; then
        echo "{\"error\": \"Invalid plan: $(json_escape "$validation_result")\"}"
        return 1
    fi

    jq '{
        repo: .repo,
        run_id: (.run_id // null),
        worktree_path: (.worktree_path // null),
        summary: {
            total_items: (.items | length),
            by_decision: {
                fix: ([.items[] | select(.decision == "fix")] | length),
                skip: ([.items[] | select(.decision == "skip")] | length),
                needs_info: ([.items[] | select(.decision == "needs-info")] | length),
                closed: ([.items[] | select(.decision == "closed")] | length)
            },
            by_type: {
                issues: ([.items[] | select(.type == "issue")] | length),
                prs: ([.items[] | select(.type == "pr")] | length)
            }
        },
        git: {
            commits: (.git.commits // [] | length),
            tests_passed: (.git.tests.ok // null)
        },
        gh_actions_count: (.gh_actions // [] | length),
        questions: {
            total: (.questions // [] | length),
            answered: ([.questions // [] | .[] | select(.answered == true)] | length),
            pending: ([.questions // [] | .[] | select(.answered == false or .answered == null)] | length)
        },
        metadata: (.metadata // null)
    }' "$plan_file"
}

#==============================================================================
# SECTION 14: MAIN DISPATCH
#==============================================================================

main() {
    # Initialize
    ARGS=()
    parse_args "$@"
    check_gum
    resolve_config

    # Create results file for this run
    RESULTS_FILE=$(mktemp_file) || { log_error "Failed to create temp file"; exit 3; }
    RESULTS_LOCK_FILE="${RESULTS_FILE}.lock"

    # Dispatch to command
    case "$COMMAND" in
        sync)       cmd_sync ;;
        status)     cmd_status ;;
        init)       cmd_init ;;
        add)        cmd_add ;;
        remove)     cmd_remove ;;
        list)       cmd_list ;;
        doctor)     cmd_doctor ;;
        self-update) cmd_self_update ;;
        config)     cmd_config ;;
        prune)      cmd_prune ;;
        import)     cmd_import ;;
        review)     cmd_review ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 4
            ;;
    esac
}

#==============================================================================
# RUN MAIN
#==============================================================================

main "$@"
