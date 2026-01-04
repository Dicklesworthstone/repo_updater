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
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
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

# Escape a string for JSON (handles quotes, backslashes, newlines)
json_escape() {
    local str="$1"
    # Escape backslashes first, then quotes, then newlines
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
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
        local safe_repo safe_message safe_path
        safe_repo=$(json_escape "$repo_name")
        safe_message=$(json_escape "$message")
        safe_path=$(json_escape "$local_path")
        printf '{"repo":"%s","path":"%s","action":"%s","status":"%s","duration":%s,"message":"%s","timestamp":"%s"}\n' \
            "$safe_repo" "$safe_path" "$action" "$status" "${duration:-0}" "$safe_message" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$RESULTS_FILE"
    fi
}

#==============================================================================
# SECTION 5: LOGGING FUNCTIONS
# Stream separation: stderr for humans, stdout for data
#==============================================================================

log_info() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${BLUE}ℹ${RESET} $*" >&2
}

log_success() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${GREEN}✓${RESET} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}⚠${RESET} $*" >&2
}

log_error() {
    echo -e "${RED}✗${RESET} $*" >&2
}

log_step() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${CYAN}→${RESET} $*" >&2
}

log_verbose() {
    [[ "$VERBOSE" != "true" ]] && return
    echo -e "${DIM}$*${RESET}" >&2
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

EXAMPLES:
    ru sync              Sync all configured repos
    ru sync --dry-run    Preview sync without changes
    ru status            Show status of all repos
    ru add owner/repo    Add a repository
    ru remove owner/repo Remove a repository
    ru doctor            Check system configuration
    ru prune             Find orphan repos not in config
    ru prune --archive   Archive orphan repos

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
        # Update existing key (use sed with different delimiter for paths with /)
        # macOS sed requires -i '' while GNU sed uses -i
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$config_file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
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
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&2
        echo -e "  ${BOLD}ru${RESET} v$VERSION - Repo Updater" >&2
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" >&2
    fi
}

# Show spinner during operation with fallback
gum_spin() {
    local title="$1"
    shift

    if [[ "$GUM_AVAILABLE" == "true" && "$QUIET" != "true" ]]; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        [[ "$QUIET" != "true" ]] && echo -e "${CYAN}→${RESET} $title" >&2
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

    # SSH format: git@host:owner/repo
    if [[ "$url" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
        return 0
    fi

    # HTTPS format: https://host/owner/repo
    if [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
        return 0
    fi

    # Host/owner/repo format (no protocol): github.com/owner/repo
    if [[ "$url" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
        return 0
    fi

    # Shorthand: owner/repo (assumes github.com)
    if [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
        _host="github.com"
        _owner="${BASH_REMATCH[1]}"
        _repo="${BASH_REMATCH[2]}"
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

    # Extract '@branch' if present
    # Branch names don't contain ':' or '/' - this avoids matching SSH URLs like git@github.com:...
    if [[ "$spec" =~ ^(.+)@([^@/:[:space:]]+)$ ]]; then
        _prs_url="${BASH_REMATCH[1]}"
        _prs_branch="${BASH_REMATCH[2]}"
    else
        _prs_url="$spec"
        _prs_branch=""
    fi
}

# Deduplicate repos by resolved local path
# Input: lines of repo specs (stdin)
# Output: unique repo specs by path (first occurrence wins)
dedupe_repos() {
    local -A seen_paths

    while IFS= read -r spec; do
        local url branch local_name
        parse_repo_spec "$spec" url branch local_name

        local path
        if [[ -n "$local_name" ]]; then
            path="${PROJECTS_DIR}/${local_name}"
        else
            path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
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
        local url branch local_name
        parse_repo_spec "$spec" url branch local_name

        local path
        if [[ -n "$local_name" ]]; then
            path="${PROJECTS_DIR}/${local_name}"
        else
            path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
        fi

        local repo_id
        if [[ -n "$local_name" ]]; then
            repo_id="${url} as ${local_name}"
        else
            repo_id="$url"
        fi

        if [[ -n "${path_to_repo[$path]:-}" && "${path_to_repo[$path]}" != "$repo_id" ]]; then
            log_warn "Collision detected:"
            log_warn "  Path: $path"
            log_warn "  Configured: ${path_to_repo[$path]} (will be synced)"
            log_warn "  Skipped:    $repo_id (same path)"
            log_warn "  To fix: Change layout to 'owner-repo' in config"
            ((collisions++))
        else
            path_to_repo[$path]="$repo_id"
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
check_remote_mismatch() {
    local repo_path="$1"
    local expected_url="$2"

    local actual_url
    actual_url=$(get_remote_url "$repo_path")
    if [[ -z "$actual_url" ]]; then
        return 1  # No remote
    fi

    # Normalize both URLs for comparison
    local expected_normalized actual_normalized
    expected_normalized=$(normalize_url "$expected_url")
    actual_normalized=$(normalize_url "$actual_url")

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
        echo "$input" | md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        # macOS uses 'md5' instead of 'md5sum'
        echo "$input" | md5
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
    run_id="${SYNC_RUN_ID:-$(date -Iseconds)}"
    local config_hash
    config_hash=$(get_config_hash)

    # Build completed array JSON (handle empty array with set -u)
    local completed_json=""
    if [[ ${#completed_ref[@]} -gt 0 ]]; then
        for item in "${completed_ref[@]}"; do
            [[ -n "$completed_json" ]] && completed_json+=","
            completed_json+="\"$item\""
        done
    fi

    # Build pending array JSON (handle empty array with set -u)
    local pending_json=""
    if [[ ${#pending_ref[@]} -gt 0 ]]; then
        for item in "${pending_ref[@]}"; do
            [[ -n "$pending_json" ]] && pending_json+=","
            pending_json+="\"$item\""
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

    # Parse the repo spec
    local url branch custom_name local_path repo_name
    parse_repo_spec "$repo_spec" url branch custom_name

    # Calculate local path based on custom name or URL
    if [[ -n "$custom_name" ]]; then
        local_path="${projects_dir}/${custom_name}"
    else
        local_path=$(url_to_local_path "$url" "$projects_dir" "$layout")
    fi
    repo_name=$(basename "$local_path")

    # Check if repo exists locally
    if [[ ! -d "$local_path" ]]; then
        if [[ "$pull_only" == "true" ]]; then
            echo "SKIP:skipped:$repo_name"
            return 0
        fi

        if do_clone "$url" "$local_path" "$repo_name" "$branch" >/dev/null 2>&1; then
            echo "OK:cloned:$repo_name"
        else
            echo "FAIL:failed:$repo_name"
        fi
    else
        if [[ "$clone_only" == "true" ]]; then
            echo "SKIP:skipped:$repo_name"
            return 0
        fi

        if ! is_git_repo "$local_path"; then
            echo "CONFLICT:not_git:$repo_name"
            return 0
        fi

        if check_remote_mismatch "$local_path" "$url"; then
            echo "CONFLICT:mismatch:$repo_name"
            return 0
        fi

        local status_info dirty status
        status_info=$(get_repo_status "$local_path" "$fetch_remotes")
        status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
        dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')

        if [[ "$dirty" == "true" && "$autostash" != "true" ]]; then
            echo "CONFLICT:dirty:$repo_name"
            return 0
        fi

        if [[ "$status" == "current" ]]; then
            echo "OK:current:$repo_name"
            return 0
        fi

        if [[ "$status" == "diverged" ]]; then
            echo "CONFLICT:diverged:$repo_name"
            return 0
        fi

        if do_pull "$local_path" "$repo_name" "$update_strategy" "$autostash" "$branch" >/dev/null 2>&1; then
            echo "OK:updated:$repo_name"
        else
            echo "FAIL:failed:$repo_name"
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
    work_queue=$(mktemp)
    results_file=$(mktemp)
    lock_file=$(mktemp)
    progress_file=$(mktemp)

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
                DRY_RUN="true"
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
                RESUME="true"
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
                if [[ $# -lt 2 ]]; then
                    log_error "--parallel requires a number of workers"
                    exit 4
                fi
                PARALLEL="$2"
                shift 2
                ;;
            -j)
                if [[ $# -lt 2 ]]; then
                    log_error "-j requires a number of workers"
                    exit 4
                fi
                PARALLEL="$2"
                shift 2
                ;;
            --example)
                INIT_EXAMPLE="true"
                shift
                ;;
            sync|status|init|add|remove|list|doctor|self-update|config|prune)
                COMMAND="$1"
                shift
                ;;
            --paths|--print|--set=*|--check|--archive|--delete|--private|--public|--from-cwd)
                # Subcommand-specific options - pass through to ARGS
                ARGS+=("$1")
                shift
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
    local cloned=0 updated=0 current=0 failed=0 conflicts=0 skipped=0

    if [[ ! -f "$RESULTS_FILE" ]] || [[ ! -s "$RESULTS_FILE" ]]; then
        echo "CLONED=0 UPDATED=0 CURRENT=0 FAILED=0 CONFLICTS=0 SKIPPED=0"
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
            failed|timeout)  ((failed++)) ;;
            diverged|dirty|conflict|mismatch|not_git) ((conflicts++)) ;;
            skipped)     ((skipped++)) ;;
            *)           ((skipped++)) ;;
        esac
    done < "$RESULTS_FILE"

    echo "CLONED=$cloned UPDATED=$updated CURRENT=$current FAILED=$failed CONFLICTS=$conflicts SKIPPED=$skipped"
}

# Print a beautiful summary box with gum or ANSI fallback
# Args: $1=cloned $2=updated $3=current $4=conflicts $5=failed $6=duration_seconds
print_summary() {
    local cloned="${1:-0}"
    local updated="${2:-0}"
    local current="${3:-0}"
    local conflicts="${4:-0}"
    local failed="${5:-0}"
    local duration="${6:-0}"
    local total=$((cloned + updated + current + conflicts + failed))

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
        [[ $conflicts -gt 0 ]] && summary_text+="  ⚠️  Conflicts:  $conflicts repos (need attention)\n"
        [[ $failed -gt 0 ]] && summary_text+="  ❌ Failed:     $failed repos\n"
        summary_text+="─────────────────────────────────────────\n"
        summary_text+="  Total: $total repos processed in $duration_str\n"

        echo -e "$summary_text" | gum style --border rounded --padding "0 1" --border-foreground 212 >&2
    else
        # ANSI fallback
        echo "" >&2
        echo -e "${BOLD}╭─────────────────────────────────────────────────────────────╮${RESET}" >&2
        echo -e "${BOLD}│                    📊 Sync Summary                          │${RESET}" >&2
        echo -e "${BOLD}├─────────────────────────────────────────────────────────────┤${RESET}" >&2
        [[ $cloned -gt 0 ]] && echo -e "${BOLD}│${RESET}  ${GREEN}✅${RESET} Cloned:     $cloned repos                                   ${BOLD}│${RESET}" >&2
        [[ $updated -gt 0 ]] && echo -e "${BOLD}│${RESET}  ${GREEN}✅${RESET} Updated:    $updated repos                                   ${BOLD}│${RESET}" >&2
        [[ $current -gt 0 ]] && echo -e "${BOLD}│${RESET}  ⏭️  Current:    $current repos (already up to date)           ${BOLD}│${RESET}" >&2
        [[ $conflicts -gt 0 ]] && echo -e "${BOLD}│${RESET}  ${YELLOW}⚠️${RESET}  Conflicts:  $conflicts repos (need attention)              ${BOLD}│${RESET}" >&2
        [[ $failed -gt 0 ]] && echo -e "${BOLD}│${RESET}  ${RED}❌${RESET} Failed:     $failed repos                                   ${BOLD}│${RESET}" >&2
        echo -e "${BOLD}├─────────────────────────────────────────────────────────────┤${RESET}" >&2
        echo -e "${BOLD}│${RESET}  Total: $total repos processed in $duration_str                      ${BOLD}│${RESET}" >&2
        echo -e "${BOLD}╰─────────────────────────────────────────────────────────────╯${RESET}" >&2
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
    echo -e "${BOLD}${YELLOW}Repositories Needing Attention${RESET}" >&2
    echo -e "─────────────────────────────────────────────────────────────" >&2
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
                echo -e "${BOLD}$num. $repo${RESET}" >&2
                echo -e "   Path:   $path" >&2
                echo -e "   Issue:  ${YELLOW}Dirty working tree${RESET} (uncommitted changes)" >&2
                echo "" >&2
                echo -e "   ${DIM}Resolution options:${RESET}" >&2
                echo -e "     ${GREEN}a)${RESET} Stash and pull:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git stash && git pull && git stash pop${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}b)${RESET} Commit your changes:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git add . && git commit -m \"WIP\"${RESET}" >&2
                echo "" >&2
                echo -e "     ${RED}c)${RESET} Discard local changes (${RED}DESTRUCTIVE${RESET}):" >&2
                echo -e "        ${CYAN}cd \"$path\" && git checkout . && git clean -fd${RESET}" >&2
                echo "" >&2
                ;;
            diverged)
                ((num++))
                echo -e "${BOLD}$num. $repo${RESET}" >&2
                echo -e "   Path:   $path" >&2
                echo -e "   Issue:  ${YELLOW}Diverged${RESET} (local and remote both have new commits)" >&2
                echo "" >&2
                echo -e "   ${DIM}Resolution options:${RESET}" >&2
                echo -e "     ${GREEN}a)${RESET} Rebase your changes:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git pull --rebase${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}b)${RESET} Merge (creates merge commit):" >&2
                echo -e "        ${CYAN}cd \"$path\" && git pull --no-ff${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}c)${RESET} Push your changes first (if intentional):" >&2
                echo -e "        ${CYAN}cd \"$path\" && git push${RESET}" >&2
                echo "" >&2
                ;;
            mismatch)
                ((num++))
                echo -e "${BOLD}$num. $repo${RESET}" >&2
                echo -e "   Path:   $path" >&2
                echo -e "   Issue:  ${RED}Remote mismatch${RESET} (different repo at this path)" >&2
                echo "" >&2
                echo -e "   ${DIM}Resolution options:${RESET}" >&2
                echo -e "     ${GREEN}a)${RESET} Check current remote:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git remote -v${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}b)${RESET} Update remote URL:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git remote set-url origin <correct-url>${RESET}" >&2
                echo "" >&2
                echo -e "     ${RED}c)${RESET} Remove and re-clone (${RED}DESTRUCTIVE${RESET}):" >&2
                echo -e "        ${CYAN}rm -rf \"$path\" && ru sync${RESET}" >&2
                echo "" >&2
                ;;
            not_git)
                ((num++))
                echo -e "${BOLD}$num. $repo${RESET}" >&2
                echo -e "   Path:   $path" >&2
                echo -e "   Issue:  ${RED}Not a git repository${RESET}" >&2
                echo "" >&2
                echo -e "   ${DIM}Resolution options:${RESET}" >&2
                echo -e "     ${GREEN}a)${RESET} Remove and re-clone:" >&2
                echo -e "        ${CYAN}rm -rf \"$path\" && ru sync${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}b)${RESET} Initialize as git repo:" >&2
                echo -e "        ${CYAN}cd \"$path\" && git init && git remote add origin <url>${RESET}" >&2
                echo "" >&2
                ;;
            failed|timeout)
                ((num++))
                echo -e "${BOLD}$num. $repo${RESET}" >&2
                echo -e "   Path:   $path" >&2
                echo -e "   Issue:  ${RED}Operation failed${RESET} (network/auth issue)" >&2
                echo "" >&2
                echo -e "   ${DIM}Resolution options:${RESET}" >&2
                echo -e "     ${GREEN}a)${RESET} Check network connectivity and retry:" >&2
                echo -e "        ${CYAN}ru sync $repo${RESET}" >&2
                echo "" >&2
                echo -e "     ${GREEN}b)${RESET} Check GitHub authentication:" >&2
                echo -e "        ${CYAN}gh auth status${RESET}" >&2
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
    local conflicts="${4:-0}"
    local failed="${5:-0}"
    local duration="${6:-0}"
    local total=$((cloned + updated + current + conflicts + failed))

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
    "conflicts": $conflicts,
    "failed": $failed
  },
  "repos": $repos_json
}
EOF
}

# Compute appropriate exit code based on results
# Args: $1=failed $2=conflicts
# Returns: exit code (0, 1, or 2)
compute_exit_code() {
    local failed="${1:-0}"
    local conflicts="${2:-0}"

    if [[ "$failed" -gt 0 ]]; then
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
        local repo_spec url branch custom_name path repo_name
        for repo_spec in "${ARGS[@]}"; do
            # Parse the repo spec (supports @branch and 'as name' syntax)
            parse_repo_spec "$repo_spec" url branch custom_name

            if [[ -n "$custom_name" ]]; then
                path="${PROJECTS_DIR}/${custom_name}"
            else
                path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            fi
            repo_name=$(basename "$path")

            if [[ -d "$path" ]]; then
                # Exists - pull updates
                if ! is_git_repo "$path"; then
                    log_warn "Not a git repo: $path"
                    write_result "$repo_name" "skip" "not_git" "0" "" "$path"
                    continue
                fi
                do_pull "$path" "$repo_name" "$UPDATE_STRATEGY" "$AUTOSTASH" "$branch"
            else
                # Missing - clone
                do_clone "$url" "$path" "$repo_name" "$branch"
            fi
        done
        exit 0
    fi

    # No arguments - check for configured repos
    local repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
    if [[ ! -f "$repos_file" ]] || [[ ! -s "$repos_file" ]] || ! grep -Eqv '^[[:space:]]*#|^[[:space:]]*$' "$repos_file" 2>/dev/null; then
        log_info "No repositories configured yet."
        echo "" >&2
        log_info "To add repos:"
        log_info "  ru add owner/repo              # Add to list"
        log_info "  ru sync owner/repo             # Sync directly (without adding)"
        log_info "  echo 'owner/repo' >> $repos_file  # Edit file directly"
        exit 0
    fi

    # Load all repos from config
    local repos=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && repos+=("$line")
    done < <(get_all_repos)

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

                # Filter out completed repos
                for repo_spec in "${repos[@]}"; do
                    local url branch custom_name local_path repo_name
                    parse_repo_spec "$repo_spec" url branch custom_name
                    if [[ -n "$custom_name" ]]; then
                        local_path="${PROJECTS_DIR}/${custom_name}"
                    else
                        local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
                    fi
                    repo_name=$(basename "$local_path")

                    if is_repo_completed "$repo_name"; then
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

    # Initialize pending repos array for state tracking
    local pending_names=()
    if [[ ${#pending_repos[@]} -gt 0 ]]; then
        for repo_spec in "${pending_repos[@]}"; do
            local url branch custom_name local_path repo_name
            parse_repo_spec "$repo_spec" url branch custom_name
            if [[ -n "$custom_name" ]]; then
                local_path="${PROJECTS_DIR}/${custom_name}"
            else
                local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            fi
            repo_name=$(basename "$local_path")
            pending_names+=("$repo_name")
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

        # Parse the repo spec
        local url branch custom_name local_path repo_name
        parse_repo_spec "$repo_spec" url branch custom_name

        # Calculate local path based on custom name or URL
        if [[ -n "$custom_name" ]]; then
            local_path="${PROJECTS_DIR}/${custom_name}"
        else
            local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
        fi
        repo_name=$(basename "$local_path")

        log_step "[$current/$pending_count] $repo_name"

        # Check if repo exists locally
        if [[ ! -d "$local_path" ]]; then
            if [[ "$PULL_ONLY" == "true" ]]; then
                log_verbose "  Skipping clone (--pull-only)"
                ((skipped++))
                continue
            fi

            if do_clone "$url" "$local_path" "$repo_name" "$branch"; then
                ((cloned++))
            else
                ((failed++))
            fi
        else
            if [[ "$CLONE_ONLY" == "true" ]]; then
                log_verbose "  Skipping pull (--clone-only)"
                ((skipped++))
                continue
            fi

            if ! is_git_repo "$local_path"; then
                log_warn "Not a git repo: $local_path"
                ((conflicts++))
                write_result "$repo_name" "skip" "not_git" "0" "" "$local_path"
                continue
            fi

            if check_remote_mismatch "$local_path" "$url"; then
                log_warn "Remote mismatch: $repo_name"
                ((conflicts++))
                write_result "$repo_name" "pull" "mismatch" "0" "" "$local_path"
                continue
            fi

            local status_info dirty status
            status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
            status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
            dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')

            if [[ "$dirty" == "true" && "$AUTOSTASH" != "true" ]]; then
                log_warn "Dirty: $repo_name (uncommitted changes)"
                ((conflicts++))
                write_result "$repo_name" "pull" "dirty" "0" "" "$local_path"
                continue
            fi

            if [[ "$status" == "current" ]]; then
                log_info "Current: $repo_name"
                ((skipped++))
                write_result "$repo_name" "pull" "current" "0" "" "$local_path"
                continue
            fi

            if [[ "$status" == "diverged" ]]; then
                log_warn "Diverged: $repo_name"
                ((conflicts++))
                write_result "$repo_name" "pull" "diverged" "0" "" "$local_path"
                continue
            fi

            if do_pull "$local_path" "$repo_name" "$UPDATE_STRATEGY" "$AUTOSTASH" "$branch"; then
                ((updated++))
            else
                ((failed++))
            fi
        fi

        # Update state: mark this repo as completed
        SYNC_COMPLETED+=("$repo_name")
        # Remove from pending_names (handle empty array with set -u)
        local new_pending=()
        if [[ ${#pending_names[@]} -gt 0 ]]; then
            for p in "${pending_names[@]}"; do
                [[ "$p" != "$repo_name" ]] && new_pending+=("$p")
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

    # Use current (skipped) count for display
    local current_count=$skipped

    # Print summary using the new reporting functions
    print_summary "$cloned" "$updated" "$current_count" "$conflicts" "$failed" "$duration"

    # Print conflict resolution help if there are issues
    print_conflict_help

    # Output JSON report if --json flag is set
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        generate_json_report "$cloned" "$updated" "$current_count" "$conflicts" "$failed" "$duration"
    fi

    # Compute and use appropriate exit code
    compute_exit_code "$failed" "$conflicts"
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
            local url branch custom_name local_path repo_name
            parse_repo_spec "$repo_spec" url branch custom_name
            if [[ -n "$custom_name" ]]; then
                local_path="${PROJECTS_DIR}/${custom_name}"
            else
                local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            fi
            repo_name=$(basename "$local_path")
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
                "$repo_name" "$safe_path" "$status" "$safe_branch" "$ahead" "$behind" "$dirty"
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
            local url branch custom_name local_path repo_name
            parse_repo_spec "$repo_spec" url branch custom_name
            if [[ -n "$custom_name" ]]; then
                local_path="${PROJECTS_DIR}/${custom_name}"
            else
                local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            fi
            repo_name=$(basename "$local_path")
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
            printf "%-30s %-12b %-15s %d/%d\n" "${repo_name:0:30}" "$status_display" "${branch_name:0:15}" "$ahead" "$behind" >&2
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
        local url branch custom_name local_path
        parse_repo_spec "$repo_spec" url branch custom_name

        if [[ "$show_paths" == "true" ]]; then
            if [[ -n "$custom_name" ]]; then
                local_path="${PROJECTS_DIR}/${custom_name}"
            else
                local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            fi
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
        echo -e "${GREEN}[OK]${RESET} git: $git_version" >&2
    else
        echo -e "${RED}[!!]${RESET} git: not installed" >&2
        ((issues++))
    fi

    # Check gh CLI
    if command -v gh &>/dev/null; then
        local gh_version gh_user
        gh_version=$(gh --version | head -1 | awk '{print $3}')
        if gh auth status &>/dev/null; then
            gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
            echo -e "${GREEN}[OK]${RESET} gh: $gh_version (authenticated as $gh_user)" >&2
        else
            echo -e "${YELLOW}[??]${RESET} gh: $gh_version (not authenticated)" >&2
            ((issues++))
        fi
    else
        echo -e "${YELLOW}[??]${RESET} gh: not installed (needed for private repos)" >&2
    fi

    # Check config directory
    if [[ -d "$RU_CONFIG_DIR" ]]; then
        echo -e "${GREEN}[OK]${RESET} Config: $RU_CONFIG_DIR" >&2
    else
        echo -e "${YELLOW}[??]${RESET} Config: not initialized (run: ru init)" >&2
    fi

    # Check repos configured
    local repo_count=0
    if [[ -d "$RU_CONFIG_DIR/repos.d" ]]; then
        while IFS= read -r _; do
            ((repo_count++))
        done < <(get_all_repos 2>/dev/null)
    fi
    if [[ $repo_count -gt 0 ]]; then
        echo -e "${GREEN}[OK]${RESET} Repos: $repo_count configured" >&2
    else
        echo -e "${YELLOW}[??]${RESET} Repos: none configured" >&2
    fi

    # Check projects directory
    if [[ -d "$PROJECTS_DIR" ]]; then
        if [[ -w "$PROJECTS_DIR" ]]; then
            echo -e "${GREEN}[OK]${RESET} Projects: $PROJECTS_DIR (writable)" >&2
        else
            echo -e "${RED}[!!]${RESET} Projects: $PROJECTS_DIR (not writable)" >&2
            ((issues++))
        fi
    else
        echo -e "${YELLOW}[??]${RESET} Projects: $PROJECTS_DIR (will be created)" >&2
    fi

    # Check gum (optional)
    if command -v gum &>/dev/null; then
        local gum_version
        gum_version=$(gum --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "${GREEN}[OK]${RESET} gum: $gum_version" >&2
    else
        echo -e "${DIM}[  ]${RESET} gum: not installed (optional, for prettier UI)" >&2
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
    temp_dir=$(mktemp -d)
    # Clean up on exit
    cleanup_temp() { rm -rf "$temp_dir"; }
    trap cleanup_temp EXIT

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

    # Get the path to the current script
    local script_path
    script_path=$(realpath "${BASH_SOURCE[0]}")

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
    configured_paths=$(mktemp)
    # shellcheck disable=SC2064  # Immediate expansion is intentional - path is already known
    trap "rm -f \"$configured_paths\"" RETURN

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        local url branch custom_name local_path
        parse_repo_spec "$spec" url branch custom_name
        if [[ -n "$custom_name" ]]; then
            local_path="${PROJECTS_DIR}/${custom_name}"
        else
            local_path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
        fi
        echo "$local_path"
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
    done < <(/usr/bin/find "$PROJECTS_DIR" -mindepth 2 -maxdepth "$depth_limit" -type d -name ".git" -exec dirname {} \; 2>/dev/null | sort)

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
    RESULTS_FILE=$(mktemp)

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
