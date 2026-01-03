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
#   3 - Dependency error (gh missing, auth failed)
#   4 - Invalid arguments (bad CLI options, missing config)
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

# XDG Base Directory defaults
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# ru-specific directories
RU_CONFIG_DIR="${RU_CONFIG_DIR:-$XDG_CONFIG_HOME/ru}"
RU_STATE_DIR="${RU_STATE_HOME:-$XDG_STATE_HOME/ru}"
RU_CACHE_DIR="${RU_CACHE_HOME:-$XDG_CACHE_HOME/ru}"
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

# Colors (disabled if not a terminal or NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
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

# Gum availability
GUM_AVAILABLE="false"

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

# Write a result to the NDJSON results file
write_result() {
    local repo_name="$1"
    local action="$2"
    local status="$3"
    local duration="${4:-}"
    local message="${5:-}"

    if [[ -n "$RESULTS_FILE" ]]; then
        printf '{"repo":"%s","action":"%s","status":"%s","duration":%s,"message":"%s","timestamp":"%s"}\n' \
            "$repo_name" "$action" "$status" "${duration:-0}" "$message" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$RESULTS_FILE"
    fi
}

# Generate per-repo log file path
# Organizes logs by date and sanitizes repo names for filesystem safety
get_repo_log_path() {
    local repo_name="$1"
    local date_dir
    date_dir=$(date +%Y-%m-%d)

    # Sanitize repo name: replace / with _ for filesystem safety
    local safe_name="${repo_name//\//_}"

    # Ensure log directory exists
    local log_dir="$RU_LOG_DIR/$date_dir/repos"
    ensure_dir "$log_dir"

    echo "$log_dir/${safe_name}.log"
}

# Get the main run log path for today
get_run_log_path() {
    local date_dir
    date_dir=$(date +%Y-%m-%d)

    local log_dir="$RU_LOG_DIR/$date_dir"
    ensure_dir "$log_dir"

    echo "$log_dir/run.log"
}

# Update the 'latest' symlink to point to today's log directory
update_latest_symlink() {
    local date_dir
    date_dir=$(date +%Y-%m-%d)

    local latest_link="$RU_LOG_DIR/latest"
    local target="$RU_LOG_DIR/$date_dir"

    # Remove old symlink if it exists
    if [[ -L "$latest_link" ]]; then
        rm -f "$latest_link"
    fi

    # Create new symlink
    ln -sf "$target" "$latest_link"
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

# Generate per-repo log file path
# Args: repo_name (e.g., "owner/repo" or "github.com/owner/repo")
# Returns: Full path to the log file (e.g., ~/.local/state/ru/logs/2026-01-03/repos/owner_repo.log)
get_repo_log_path() {
    local repo_name="$1"
    local date_dir
    date_dir=$(date +%Y-%m-%d)

    # Replace / with _ for filesystem safety
    local safe_name="${repo_name//\//_}"

    # Ensure log directory exists
    local log_dir="${RU_LOG_DIR}/${date_dir}/repos"
    ensure_dir "$log_dir"

    echo "${log_dir}/${safe_name}.log"
}

# Get the run log path for today's run
get_run_log_path() {
    local date_dir
    date_dir=$(date +%Y-%m-%d)

    local log_dir="${RU_LOG_DIR}/${date_dir}"
    ensure_dir "$log_dir"

    echo "${log_dir}/run.log"
}

# Update the 'latest' symlink to point to today's log directory
update_latest_symlink() {
    local date_dir
    date_dir=$(date +%Y-%m-%d)
    local latest_link="${RU_LOG_DIR}/latest"

    # Remove old symlink if it exists
    if [[ -L "$latest_link" ]]; then
        rm -f "$latest_link"
    fi

    # Create new symlink
    ln -s "${RU_LOG_DIR}/${date_dir}" "$latest_link" 2>/dev/null || true
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
    list            Show configured repositories
    doctor          Run system diagnostics
    self-update     Update ru to the latest version
    config          Show or set configuration values

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

STATUS OPTIONS:
    --fetch              Fetch remotes first (default)
    --no-fetch           Skip fetch, use cached state

EXAMPLES:
    ru sync              Sync all configured repos
    ru sync --dry-run    Preview sync without changes
    ru status            Show status of all repos
    ru add owner/repo    Add a repository
    ru doctor            Check system configuration

CONFIGURATION:
    Config:  ~/.config/ru/config
    Repos:   ~/.config/ru/repos.d/repos.txt
    Logs:    ~/.local/state/ru/logs/

EXIT CODES:
    0  Success
    1  Partial failure (some repos failed)
    2  Conflicts exist (need manual resolution)
    3  Dependency error (gh missing, auth failed)
    4  Invalid arguments

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
        sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
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
        _prs_local_name="${BASH_REMATCH[2]}"
    else
        _prs_local_name=""
    fi

    # Extract '@branch' if present
    if [[ "$spec" =~ ^(.+)@([^@[:space:]]+)$ ]]; then
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

# Clone repository using gh
do_clone() {
    local url="$1"
    local target_dir="$2"
    local repo_name="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clone: $url -> $target_dir"
        write_result "$repo_name" "clone" "dry_run" "0" ""
        return 0
    fi

    local clone_target
    clone_target=$(url_to_clone_target "$url")

    local start_time
    start_time=$(date +%s)

    # Create parent directory if needed
    mkdir -p "$(dirname "$target_dir")"

    local output
    if output=$(gh repo clone "$clone_target" "$target_dir" -- --quiet 2>&1); then
        local duration=$(($(date +%s) - start_time))
        log_success "Cloned: $repo_name (${duration}s)"
        write_result "$repo_name" "clone" "ok" "$duration" ""
        return 0
    else
        local exit_code=$?
        log_error "Failed to clone: $repo_name"
        log_verbose "  $output"
        write_result "$repo_name" "clone" "failed" "0" "$output"
        return $exit_code
    fi
}

# Pull updates with strategy support
# Strategies: ff-only (safe default), rebase, merge
do_pull() {
    local repo_path="$1"
    local repo_name="$2"
    local strategy="${3:-ff-only}"
    local autostash="${4:-false}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would pull: $repo_name (strategy: $strategy)"
        write_result "$repo_name" "pull" "dry_run" "0" ""
        return 0
    fi

    local start_time
    start_time=$(date +%s)

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
            write_result "$repo_name" "pull" "current" "$duration" ""
        else
            log_success "Updated: $repo_name (${duration}s)"
            write_result "$repo_name" "pull" "updated" "$duration" ""
        fi
        return 0
    else
        local exit_code=$?
        local reason="failed"

        # Categorize the failure
        if [[ "$output" =~ (divergent|cannot\ be\ fast-forwarded) ]]; then
            reason="diverged"
            log_warn "Diverged: $repo_name (needs manual merge or --rebase)"
        elif [[ "$output" =~ (conflict|CONFLICT) ]]; then
            reason="conflict"
            log_error "Merge conflict: $repo_name"
        else
            log_error "Pull failed: $repo_name"
        fi

        log_verbose "  $output"
        write_result "$repo_name" "pull" "$reason" "0" "$output"
        return $exit_code
    fi
}

# Fetch remote without merging (for status checks)
do_fetch() {
    local repo_path="$1"
    git -C "$repo_path" fetch --quiet 2>/dev/null
}

#==============================================================================
# SECTION 11: REPO LIST MANAGEMENT
#==============================================================================

# Parse a repo spec line: owner/repo, owner/repo@branch, owner/repo as custom-name
# Returns: URL BRANCH CUSTOM_NAME (space-separated, BRANCH/CUSTOM_NAME may be empty)
parse_repo_spec() {
    local spec="$1"
    local url="" branch="" custom_name=""

    # Strip leading/trailing whitespace
    spec=$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Check for "as custom-name" syntax
    if [[ "$spec" =~ ^(.+)[[:space:]]+as[[:space:]]+(.+)$ ]]; then
        spec="${BASH_REMATCH[1]}"
        custom_name="${BASH_REMATCH[2]}"
    fi

    # Check for @branch syntax
    if [[ "$spec" =~ ^(.+)@([^@/]+)$ ]]; then
        url="${BASH_REMATCH[1]}"
        branch="${BASH_REMATCH[2]}"
    else
        url="$spec"
    fi

    echo "$url" "$branch" "$custom_name"
}

# Load repos from a list file, skipping comments and blank lines
# Returns array of "url|branch|custom_name|local_path" entries
load_repo_list() {
    local list_file="$1"
    local repos=()

    if [[ ! -f "$list_file" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse the spec
        local url branch custom_name
        read -r url branch custom_name < <(parse_repo_spec "$line")

        # Skip invalid URLs
        if [[ -z "$url" ]]; then
            continue
        fi

        # Determine local path
        local local_path
        if [[ -n "$custom_name" ]]; then
            local_path="${PROJECTS_DIR}/${custom_name}"
        else
            local_path=$(url_to_local_path "$url")
        fi

        # Skip if path resolution failed
        if [[ -z "$local_path" ]]; then
            log_warn "Skipping invalid repo spec: $line"
            continue
        fi

        repos+=("${url}|${branch}|${custom_name}|${local_path}")
    done < "$list_file"

    # Return repos as newline-separated output
    printf '%s\n' "${repos[@]}"
}

# Get all repos from all list files, deduplicated by local path
get_all_repos() {
    local repos_dir="$RU_CONFIG_DIR/repos.d"
    local -A seen_paths
    local all_repos=()

    # Find all .txt files in repos.d
    if [[ -d "$repos_dir" ]]; then
        for list_file in "$repos_dir"/*.txt; do
            [[ -f "$list_file" ]] || continue

            while IFS= read -r repo_entry; do
                [[ -z "$repo_entry" ]] && continue

                # Extract local path (4th field)
                local local_path
                local_path=$(echo "$repo_entry" | cut -d'|' -f4)

                # Deduplicate by path
                if [[ -z "${seen_paths[$local_path]:-}" ]]; then
                    seen_paths[$local_path]=1
                    all_repos+=("$repo_entry")
                else
                    log_verbose "Skipping duplicate: $local_path"
                fi
            done < <(load_repo_list "$list_file")
        done
    fi

    printf '%s\n' "${all_repos[@]}"
}

# Detect path collisions (different repos mapping to same path)
detect_collisions() {
    local -A path_to_repo
    local collisions=()

    while IFS= read -r repo_entry; do
        [[ -z "$repo_entry" ]] && continue

        local url local_path
        url=$(echo "$repo_entry" | cut -d'|' -f1)
        local_path=$(echo "$repo_entry" | cut -d'|' -f4)

        if [[ -n "${path_to_repo[$local_path]:-}" ]]; then
            local existing="${path_to_repo[$local_path]}"
            if [[ "$existing" != "$url" ]]; then
                collisions+=("$local_path: $existing vs $url")
            fi
        else
            path_to_repo[$local_path]="$url"
        fi
    done < <(get_all_repos)

    if [[ ${#collisions[@]} -gt 0 ]]; then
        log_warn "Path collisions detected:"
        for collision in "${collisions[@]}"; do
            log_warn "  $collision"
        done
        return 1
    fi

    return 0
}

#==============================================================================
# SECTION 12: EXIT TRAP AND CLEANUP
#==============================================================================

cleanup() {
    # Remove temp files
    if [[ -n "${RESULTS_FILE:-}" && -f "$RESULTS_FILE" ]]; then
        rm -f "$RESULTS_FILE"
    fi
}

# Set up trap for cleanup
trap cleanup EXIT

#==============================================================================
# SECTION 13: ARGUMENT PARSING
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
            sync|status|init|add|list|doctor|self-update|config)
                COMMAND="$1"
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
# SECTION 14: COMMAND STUBS (to be implemented)
#==============================================================================

cmd_sync() {
    # Auto-init on first run
    if [[ ! -d "$RU_CONFIG_DIR" ]]; then
        log_info "First run detected. Initializing configuration..."
        ensure_config_exists >/dev/null
        log_success "Created configuration at: $RU_CONFIG_DIR"
        echo "" >&2
    fi

    # Ensure projects directory exists
    ensure_dir "$PROJECTS_DIR"

    # Update latest symlink for logs
    update_latest_symlink

    # Check for positional arguments (ad-hoc repos)
    if [[ ${#ARGS[@]} -gt 0 ]]; then
        # User passed repo URLs directly - sync them ad-hoc
        log_step "Syncing ${#ARGS[@]} repo(s)..."
        local url path repo_name
        for url in "${ARGS[@]}"; do
            path=$(url_to_local_path "$url" "$PROJECTS_DIR" "$LAYOUT")
            repo_name=$(basename "$path")

            if [[ -d "$path" ]]; then
                # Exists - pull updates
                if ! is_git_repo "$path"; then
                    log_warn "Not a git repo: $path"
                    write_result "$repo_name" "skip" "not_git" "0" ""
                    continue
                fi
                do_pull "$path" "$repo_name" "$UPDATE_STRATEGY" "$AUTOSTASH"
            else
                # Missing - clone
                do_clone "$url" "$path" "$repo_name"
            fi
        done
        exit 0
    fi

    # No arguments - check for configured repos
    local repos_file="$RU_CONFIG_DIR/repos.d/repos.txt"
    if [[ ! -f "$repos_file" ]] || [[ ! -s "$repos_file" ]] || ! grep -qv '^\s*#\|^\s*$' "$repos_file" 2>/dev/null; then
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
    local cloned=0 updated=0 skipped=0 failed=0 conflicts=0

    log_info "Syncing $total repositories..."
    echo "" >&2

    for repo_entry in "${repos[@]}"; do
        ((current++))

        # Parse entry: url|branch|custom_name|local_path
        local url branch custom_name local_path repo_name
        IFS='|' read -r url branch custom_name local_path <<< "$repo_entry"
        repo_name=$(basename "$local_path")

        log_step "[$current/$total] $repo_name"

        # Check if repo exists locally
        if [[ ! -d "$local_path" ]]; then
            if [[ "$PULL_ONLY" == "true" ]]; then
                log_verbose "  Skipping clone (--pull-only)"
                ((skipped++))
                continue
            fi

            if do_clone "$url" "$local_path" "$repo_name"; then
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
                write_result "$repo_name" "skip" "not_git" "0" ""
                continue
            fi

            if check_remote_mismatch "$local_path" "$url"; then
                log_warn "Remote mismatch: $repo_name"
                ((conflicts++))
                write_result "$repo_name" "pull" "mismatch" "0" ""
                continue
            fi

            local status_info dirty status
            status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
            status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
            dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')

            if [[ "$dirty" == "true" && "$AUTOSTASH" != "true" ]]; then
                log_warn "Dirty: $repo_name (uncommitted changes)"
                ((conflicts++))
                write_result "$repo_name" "pull" "dirty" "0" ""
                continue
            fi

            if [[ "$status" == "current" ]]; then
                log_info "Current: $repo_name"
                ((skipped++))
                write_result "$repo_name" "pull" "current" "0" ""
                continue
            fi

            if [[ "$status" == "diverged" ]]; then
                log_warn "Diverged: $repo_name"
                ((conflicts++))
                write_result "$repo_name" "pull" "diverged" "0" ""
                continue
            fi

            if do_pull "$local_path" "$repo_name" "$UPDATE_STRATEGY" "$AUTOSTASH"; then
                ((updated++))
            else
                ((failed++))
            fi
        fi
    done

    echo "" >&2

    log_info "Sync complete:"
    [[ $cloned -gt 0 ]] && log_success "  Cloned:    $cloned"
    [[ $updated -gt 0 ]] && log_success "  Updated:   $updated"
    [[ $skipped -gt 0 ]] && log_info "  Current:   $skipped"
    [[ $conflicts -gt 0 ]] && log_warn "  Conflicts: $conflicts"
    [[ $failed -gt 0 ]] && log_error "  Failed:    $failed"

    if [[ $failed -gt 0 ]]; then
        exit 1
    elif [[ $conflicts -gt 0 ]]; then
        exit 2
    fi
}

cmd_status() {
    log_info "status command not yet implemented"
    exit 0
}

cmd_init() {
    log_step "Initializing ru configuration..."

    local created
    created=$(ensure_config_exists)

    if [[ "$created" == "true" ]]; then
        log_success "Created configuration directory: $RU_CONFIG_DIR"
        log_success "Created repos file: $RU_CONFIG_DIR/repos.d/repos.txt"
        log_success "Created config file: $RU_CONFIG_DIR/config"
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
    log_info "add command not yet implemented"
    exit 0
}

cmd_list() {
    log_info "list command not yet implemented"
    exit 0
}

cmd_doctor() {
    log_info "doctor command not yet implemented"
    exit 0
}

cmd_self_update() {
    log_info "self-update command not yet implemented"
    exit 0
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

#==============================================================================
# SECTION 15: MAIN DISPATCH
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
        list)       cmd_list ;;
        doctor)     cmd_doctor ;;
        self-update) cmd_self_update ;;
        config)     cmd_config ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 4
            ;;
    esac
}

# Run main
main "$@"
