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

# Resolve a user-provided path that should be absolute.
# - Accepts absolute paths ("/...") and simple "~" / "~/" forms.
# - Rejects relative paths to avoid writing into the current working directory.
resolve_abs_or_tilde_path_or_default() {
    local candidate="${1:-}"
    local default_path="${2:-}"

    if [[ -n "$candidate" ]] && [[ "$candidate" == /* ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ -n "$candidate" ]] && [[ "${candidate:0:1}" == "~" ]] && { [[ "${#candidate}" -eq 1 ]] || [[ "${candidate:1:1}" == "/" ]]; }; then
        printf '%s\n' "$HOME/${candidate:2}"
        return 0
    fi

    printf '%s\n' "$default_path"
}

# XDG Base Directory defaults
XDG_CONFIG_HOME="$(resolve_abs_or_tilde_path_or_default "${XDG_CONFIG_HOME:-}" "$HOME/.config")"
XDG_STATE_HOME="$(resolve_abs_or_tilde_path_or_default "${XDG_STATE_HOME:-}" "$HOME/.local/state")"
XDG_CACHE_HOME="$(resolve_abs_or_tilde_path_or_default "${XDG_CACHE_HOME:-}" "$HOME/.cache")"

# ru-specific directories (can be overridden via env vars)
RU_CONFIG_DIR="$(resolve_abs_or_tilde_path_or_default "${RU_CONFIG_DIR:-}" "$XDG_CONFIG_HOME/ru")"
RU_STATE_DIR="$(resolve_abs_or_tilde_path_or_default "${RU_STATE_DIR:-}" "$XDG_STATE_HOME/ru")"
RU_CACHE_DIR="$(resolve_abs_or_tilde_path_or_default "${RU_CACHE_DIR:-}" "$XDG_CACHE_HOME/ru")"
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

# Retry a command with exponential backoff (+/-25% jitter).
# Usage: retry_with_backoff [--capture=all|--capture=stdout] MAX_ATTEMPTS BASE_DELAY_SECONDS -- cmd arg...
# - Logs retries to stderr (via log_warn), returns final exit code.
# - Prints the command output to stdout (capture mode controls stderr handling).
retry_with_backoff() {
    local capture_mode="all"
    while [[ "${1:-}" == --* ]]; do
        case "${1:-}" in
            --capture=all) capture_mode="all" ;;
            --capture=stdout) capture_mode="stdout" ;;
            --) shift; break ;;
            *) log_error "retry_with_backoff: unknown option: ${1:-}"; return 4 ;;
        esac
        shift
    done

    if [[ $# -lt 3 ]]; then
        log_error "retry_with_backoff: usage: retry_with_backoff [--capture=all|--capture=stdout] MAX_ATTEMPTS BASE_DELAY_SECONDS -- cmd arg..."
        return 4
    fi

    local max_attempts="${1:-}"
    local base_delay="${2:-}"
    shift 2

    [[ "${1:-}" == "--" ]] && shift

    if ! is_positive_int "$max_attempts"; then
        log_error "retry_with_backoff: MAX_ATTEMPTS must be a positive integer (got: ${max_attempts:-})"
        return 4
    fi
    if [[ -z "${base_delay:-}" ]] || [[ ! "$base_delay" =~ ^[0-9]+$ ]]; then
        log_error "retry_with_backoff: BASE_DELAY_SECONDS must be an integer >= 0 (got: ${base_delay:-})"
        return 4
    fi
    if [[ $# -lt 1 ]]; then
        log_error "retry_with_backoff: missing command"
        return 4
    fi

    local attempt=1
    local output=""
    local exit_code=0

    while (( attempt <= max_attempts )); do
        if [[ "$capture_mode" == "stdout" ]]; then
            if output=$("$@" 2>/dev/null); then
                printf '%s' "$output"
                return 0
            fi
            exit_code=$?
        else
            if output=$("$@" 2>&1); then
                printf '%s' "$output"
                return 0
            fi
            exit_code=$?
        fi

        if (( attempt >= max_attempts )); then
            printf '%s' "$output"
            return "$exit_code"
        fi

        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        local max_jitter=$(( delay / 4 ))
        local jitter=0
        if (( max_jitter > 0 )); then
            jitter=$(( (RANDOM % (2 * max_jitter + 1)) - max_jitter ))
        fi

        local sleep_for=$(( delay + jitter ))
        (( sleep_for < 0 )) && sleep_for=0

        local short_msg="${output%%$'\n'*}"
        log_warn "Retry $attempt/${max_attempts} failed (exit $exit_code). Sleeping ${sleep_for}s. ${short_msg}"
        sleep "$sleep_for"
        ((attempt++))
    done

    # Unreachable, but keep explicit.
    printf '%s' "$output"
    return "$exit_code"
}

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

DOCTOR OPTIONS:
    --review             Include review command prerequisites

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
    --analytics          Show review metrics dashboard and exit
    --basic              Use basic question TUI (gum/ANSI) and exit
    --mode=MODE          Driver: auto, ntm, or local (default: auto)
    --parallel=N, -jN    Concurrent review sessions (default: 4)
    --repos=PATTERN      Filter repos by pattern
    --priority=LEVEL     Min priority: all, critical, high, normal, low
    --skip-days=N        Skip repos reviewed within N days (default: 7)
    --dry-run            Discovery only, don't start sessions
    --resume             Resume interrupted review from checkpoint
    --push               Allow pushing changes (with --apply)
    --auto-answer=POLICY Auto-answer policy in non-interactive mode (auto|skip|fail)
    --invalidate-cache=R Invalidate digest cache for repo(s) (use "all" for all)
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
    ru doctor --review   Check system and review prerequisites
    ru prune --archive   Archive orphan repos
    ru import repos.txt  Import repos from file (auto-detects visibility)
    ru review --dry-run  Discover issues/PRs without starting reviews
    ru review            Start AI-assisted review of issues/PRs
    ru review --apply    Execute approved changes from plan
    ru review --basic    Answer queued review questions
    ru review --analytics Show review analytics dashboard

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
        local line file_value=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "${key}="* ]] || continue
            # Last matching key wins
            file_value="${line#*=}"
        done < "$config_file"

        if [[ -n "$file_value" ]]; then
            # Strip CRLF
            file_value="${file_value%$'\r'}"

            # Strip only matching *surrounding* quotes (preserve internal quotes)
            if [[ ${#file_value} -ge 2 ]]; then
                local first="${file_value:0:1}"
                local last="${file_value: -1}"
                if [[ "$first" == "$last" && ( "$first" == '"' || "$first" == "'" ) ]]; then
                    file_value="${file_value:1:${#file_value}-2}"
                fi
            fi

            if [[ -n "$file_value" ]]; then
                echo "$file_value"
                return
            fi
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
    if ! output=$(git -C "$repo_path" rev-list --left-right --count HEAD...@{u} 2>/dev/null); then
        # If rev-list fails (e.g. unrelated histories), assume diverged
        echo "STATUS=diverged AHEAD=? BEHIND=? DIRTY=$dirty BRANCH=$branch"
        return 0
    fi
    read -r ahead behind <<< "$output"

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
    local -a pending_review_args=()
    local -a pending_global_args=()

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
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
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
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
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
                elif [[ -z "$COMMAND" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "--parallel requires a number"
                        exit 4
                    fi
                    pending_global_args+=("--parallel=$2")
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
            --parallel=*)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    PARALLEL="${1#--parallel=}"
                fi
                shift
                ;;
            -j)
                if [[ "$COMMAND" == "review" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "-j requires a number"
                        exit 4
                    fi
                    ARGS+=("-j$2")
                    shift 2
                elif [[ -z "$COMMAND" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "-j requires a number"
                        exit 4
                    fi
                    pending_global_args+=("-j$2")
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
            -j[0-9]*)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    PARALLEL="${1#-j}"
                fi
                shift
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
            --plan|--apply|--push|--analytics|--basic|--mode=*|--repos=*|--skip-days=*|--priority=*|--max-repos=*|--max-runtime=*|--max-questions=*|--invalidate-cache=*|--auto-answer=*)
                if [[ "$COMMAND" == "review" ]]; then
                    ARGS+=("$1")
                    shift
                elif [[ -z "$COMMAND" ]]; then
                    pending_review_args+=("$1")
                    shift
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                ;;
            --mode|--repos|--skip-days|--priority|--max-repos|--max-runtime|--max-questions|--invalidate-cache|--auto-answer)
                if [[ "$COMMAND" == "review" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "$1 requires a value"
                        exit 4
                    fi
                    ARGS+=("$1=$2")
                    shift 2
                elif [[ -z "$COMMAND" ]]; then
                    if [[ $# -lt 2 ]]; then
                        log_error "$1 requires a value"
                        exit 4
                    fi
                    pending_review_args+=("$1=$2")
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

    # Apply any pending args that appeared before the command
    if [[ "$COMMAND" == "review" ]]; then
        [[ ${#pending_review_args[@]} -gt 0 ]] && ARGS+=("${pending_review_args[@]}")
        [[ ${#pending_global_args[@]} -gt 0 ]] && ARGS+=("${pending_global_args[@]}")
    else
        if [[ ${#pending_review_args[@]} -gt 0 ]]; then
            log_error "Unknown option: ${pending_review_args[0]}"
            show_help
            exit 4
        fi
        if [[ ${#pending_global_args[@]} -gt 0 ]]; then
            local opt
            for opt in "${pending_global_args[@]}"; do
                case "$opt" in
                    --dry-run) DRY_RUN="true" ;;
                    --resume)  RESUME="true" ;;
                    --parallel=*) PARALLEL="${opt#--parallel=}" ;;
                    -j*) PARALLEL="${opt#-j}" ;;
                esac
            done
        fi
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

    if [[ "$force_public" == "true" && "$force_private" == "true" ]]; then
        log_error "--public and --private are mutually exclusive"
        exit 4
    fi

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
    local review_flag="auto"

    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --review) review_flag="true" ;;
        esac
    done

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

    local run_review_checks="false"
    if [[ "$review_flag" == "true" ]]; then
        run_review_checks="true"
    else
        local review_state_dir review_state_file review_policy_dir review_templates_dir
        review_state_dir=$(get_review_state_dir)
        review_state_file=$(get_review_state_file)
        review_policy_dir=$(get_review_policy_dir)
        review_templates_dir=$(get_review_templates_dir)

        if [[ -f "$review_state_file" ]]; then
            run_review_checks="true"
        elif [[ -d "$review_state_dir" ]]; then
            if compgen -G "$review_state_dir/*" >/dev/null; then
                run_review_checks="true"
            fi
        fi

        if [[ "$run_review_checks" != "true" ]]; then
            if [[ -d "$review_policy_dir" || -d "$review_templates_dir" ]]; then
                run_review_checks="true"
            fi
        fi
    fi

    if [[ "$run_review_checks" == "true" ]]; then
        echo "" >&2
        log_info "Review Prerequisites"
        echo "────────────────────────────────────────" >&2

        local review_issues=0

        if command -v claude &>/dev/null; then
            local claude_version claude_help
            claude_version=$(claude --version 2>/dev/null | head -1 || echo "unknown")
            printf '%b\n' "${GREEN}[OK]${RESET} claude: $claude_version" >&2
            if claude_help=$(claude --help 2>&1); then
                if echo "$claude_help" | grep -q "stream-json"; then
                    printf '%b\n' "${GREEN}[OK]${RESET} claude: stream-json supported" >&2
                else
                    printf '%b\n' "${RED}[!!]${RESET} claude: stream-json not supported" >&2
                    printf '%b\n' "${DIM}      Update: npm update -g @anthropic-ai/claude-code${RESET}" >&2
                    ((review_issues++))
                fi
            else
                printf '%b\n' "${YELLOW}[??]${RESET} claude: could not check stream-json support" >&2
            fi
        else
            printf '%b\n' "${RED}[!!]${RESET} claude: not installed (required for review)" >&2
            printf '%b\n' "${DIM}      Install: npm install -g @anthropic-ai/claude-code${RESET}" >&2
            ((review_issues++))
        fi

        if command -v jq &>/dev/null; then
            local jq_version
            jq_version=$(jq --version 2>/dev/null | head -1 || echo "unknown")
            printf '%b\n' "${GREEN}[OK]${RESET} jq: $jq_version" >&2
        else
            printf '%b\n' "${RED}[!!]${RESET} jq: not installed (required for review)" >&2
            printf '%b\n' "${DIM}      Install: brew install jq OR sudo apt install jq${RESET}" >&2
            ((review_issues++))
        fi

        if command -v tmux &>/dev/null; then
            local tmux_version
            tmux_version=$(tmux -V 2>/dev/null | head -1 || echo "unknown")
            printf '%b\n' "${GREEN}[OK]${RESET} tmux: $tmux_version" >&2
        else
            printf '%b\n' "${YELLOW}[??]${RESET} tmux: not installed (required for local driver)" >&2
        fi

        if command -v ntm &>/dev/null; then
            if ntm --robot-status &>/dev/null; then
                printf '%b\n' "${GREEN}[OK]${RESET} ntm: robot mode available" >&2
            else
                printf '%b\n' "${YELLOW}[??]${RESET} ntm: installed but robot mode unavailable" >&2
            fi
        else
            printf '%b\n' "${DIM}[  ]${RESET} ntm: not installed (optional)" >&2
        fi

        if command -v gh &>/dev/null && gh auth status &>/dev/null; then
            local remaining reset reset_time
            remaining=$(gh api rate_limit --jq ".resources.core.remaining" 2>/dev/null || echo "")
            reset=$(gh api rate_limit --jq ".resources.core.reset" 2>/dev/null || echo "")
            if [[ -n "$remaining" && "$remaining" =~ ^[0-9]+$ ]]; then
                if [[ "$remaining" -lt 100 ]]; then
                    reset_time=$(date -d "@$reset" 2>/dev/null || date -r "$reset" 2>/dev/null || echo "$reset")
                    printf '%b\n' "${YELLOW}[??]${RESET} gh rate limit: $remaining remaining (resets $reset_time)" >&2
                else
                    printf '%b\n' "${GREEN}[OK]${RESET} gh rate limit: $remaining remaining" >&2
                fi
            else
                printf '%b\n' "${YELLOW}[??]${RESET} gh rate limit: unavailable" >&2
            fi
        else
            printf '%b\n' "${DIM}[  ]${RESET} gh rate limit: unavailable (gh not authenticated)" >&2
        fi

        local review_state_dir
        review_state_dir=$(get_review_state_dir)
        if [[ -d "$review_state_dir" ]]; then
            if [[ -w "$review_state_dir" ]]; then
                printf '%b\n' "${GREEN}[OK]${RESET} review state: $review_state_dir" >&2
            else
                printf '%b\n' "${RED}[!!]${RESET} review state: not writable ($review_state_dir)" >&2
                ((review_issues++))
            fi
        else
            printf '%b\n' "${DIM}[  ]${RESET} review state: $review_state_dir (will be created)" >&2
        fi

        if [[ $review_issues -gt 0 ]]; then
            issues=$((issues + review_issues))
        fi
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

    # Check for jq (required for JSON processing)
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for review command"
        log_info "Install jq:"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_info "  brew install jq"
        else
            log_info "  sudo apt install jq   # Debian/Ubuntu"
        fi
        has_errors=true
    fi

    # Check for Claude Code (claude command)
    if ! command -v claude &>/dev/null; then
        log_warn "Claude Code CLI not found. Review sessions will not work."
        log_warn "Install: npm install -g @anthropic-ai/claude-code"
        # Not a hard error - might be doing discovery only
    fi

    [[ "$has_errors" == "true" ]] && return 1
    return 0
}

# Get path to review lock file
get_review_lock_file() {
    echo "${RU_STATE_DIR}/review.lock"
}

# Get path to review lock info file (JSON metadata)
get_review_lock_info_file() {
    echo "${RU_STATE_DIR}/review.lock.info"
}

# Check for and clean up stale locks from crashed processes
# Returns 0 if lock was stale (and cleaned up), 1 if lock is valid or doesn't exist
check_stale_lock() {
    local info_file
    info_file=$(get_review_lock_info_file)

    if [[ ! -f "$info_file" ]]; then
        return 1  # No info file, can't determine staleness
    fi

    # Parse PID from info file
    local lock_pid
    lock_pid=$(jq -r '.pid // empty' "$info_file" 2>/dev/null)

    if [[ -z "$lock_pid" ]]; then
        # Corrupt info file, treat as stale
        log_warn "Found corrupt lock info file, cleaning up"
        rm -f "$info_file"
        return 0
    fi

    # Check if the process still exists
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        # Process is dead, lock is stale
        local run_id started_at
        run_id=$(jq -r '.run_id // "unknown"' "$info_file" 2>/dev/null)
        started_at=$(jq -r '.started_at // "unknown"' "$info_file" 2>/dev/null)
        log_warn "Found stale lock from dead process $lock_pid (run_id: $run_id, started: $started_at)"
        rm -f "$info_file"
        return 0  # Lock is stale
    fi

    return 1  # Lock is valid
}

# Acquire review lock (prevents concurrent reviews)
# Uses flock for atomic lock acquisition and JSON info file for metadata
acquire_review_lock() {
    local lock_file info_file
    lock_file=$(get_review_lock_file)
    info_file=$(get_review_lock_info_file)
    ensure_dir "$(dirname "$lock_file")"

    # Check for stale locks first and clean up if needed
    check_stale_lock

    # Open fd 9 for locking (survives subshell)
    exec 9>"$lock_file"

    # Try non-blocking lock
    if ! flock -n 9 2>/dev/null; then
        # Lock held by another process - read info
        if [[ -f "$info_file" ]]; then
            local holder_run_id holder_started holder_pid holder_mode
            holder_run_id=$(jq -r '.run_id // "unknown"' "$info_file" 2>/dev/null)
            holder_started=$(jq -r '.started_at // "unknown"' "$info_file" 2>/dev/null)
            holder_pid=$(jq -r '.pid // "unknown"' "$info_file" 2>/dev/null)
            holder_mode=$(jq -r '.mode // "unknown"' "$info_file" 2>/dev/null)

            log_error "Another review session is active"
            log_error "  Run ID:  $holder_run_id"
            log_error "  Started: $holder_started"
            log_error "  PID:     $holder_pid"
            log_error "  Mode:    $holder_mode"
        else
            log_error "Another review is running (no info available)"
        fi
        log_info "Use 'ru review --status' to check, or wait for completion"
        exec 9>&-
        return 1
    fi

    # Lock acquired - write info file with JSON metadata
    local run_id="${REVIEW_RUN_ID:-$$}"
    local mode="${REVIEW_MODE:-plan}"

    cat > "$info_file" << EOF
{
  "run_id": "$run_id",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pid": $$,
  "mode": "$mode"
}
EOF

    return 0
}

# Release review lock and clean up info file
release_review_lock() {
    local lock_file info_file
    lock_file=$(get_review_lock_file)
    info_file=$(get_review_lock_info_file)

    # Remove info file
    rm -f "$info_file"

    # Release the flock (closing fd 9)
    exec 9>&- 2>/dev/null || true
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

#------------------------------------------------------------------------------
# Wait Reason Detection (bd-4ps0)
# Classify why Claude is waiting for input: AskUserQuestion, text question, or
# external prompt (git, ssh, auth)
#------------------------------------------------------------------------------

# Detect external prompts (git, ssh, auth, etc.)
# Args:
#   $1 - Terminal output to check
# Outputs:
#   Matched pattern if found
# Returns:
#   0 if external prompt found, 1 otherwise
detect_external_prompt() {
    local output="$1"

    local -a patterns=(
        'CONFLICT.*Merge conflict'
        'Please enter.*commit message'
        'Enter passphrase'
        'Password:'
        '\(yes/no\)'
        '\(yes/no/\[fingerprint\]\)'
        'error: cannot pull with rebase'
        'Username for'
        'gh auth login'
        'fatal: could not read'
        'Permission denied'
        'Are you sure you want to continue connecting'
        'Host key verification failed'
        'Authentication failed'
        'Error: authentication required'
        'npm login'
        'Enter OTP'
        'Two-factor authentication'
    )

    for pattern in "${patterns[@]}"; do
        if echo "$output" | grep -qE "$pattern"; then
            echo "$pattern"
            return 0
        fi
    done

    return 1
}

# Classify risk level of external prompt
# Args:
#   $1 - Matched pattern from detect_external_prompt
# Outputs:
#   Risk level: high, medium, or low
classify_external_prompt_risk() {
    local prompt="$1"

    local lower
    lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    # High risk: credentials, auth, security
    if echo "$lower" | grep -qE 'password|passphrase|credential|auth|token|otp|two-factor|permission denied|authentication'; then
        echo "high"
        return
    fi

    # Medium risk: merge conflicts, host verification
    if echo "$lower" | grep -qE 'conflict|merge|rebase|overwrite|delete|host key|fingerprint|yes/no'; then
        echo "medium"
        return
    fi

    # Low risk: informational prompts
    echo "low"
}

# Extract question context from text output
# Args:
#   $1 - Text output containing question
# Outputs:
#   Lines around the question for context
extract_question_from_text() {
    local output="$1"

    # Get lines around question pattern
    local question_line
    question_line=$(echo "$output" | grep -niE 'Should I|Do you want|Would you|Which.*\?|What.*\?|How should' | tail -1)

    if [[ -n "$question_line" ]]; then
        local line_num="${question_line%%:*}"
        # Get 5 lines before and 2 after for context
        local start=$((line_num - 5))
        [[ $start -lt 1 ]] && start=1
        local end=$((line_num + 2))
        echo "$output" | sed -n "${start},${end}p"
    else
        echo "$output" | tail -10
    fi
}

# Extract inline options from text (e.g., "a) option", "1. option")
# Args:
#   $1 - Text output to parse
# Outputs:
#   Extracted options (newline-separated)
extract_inline_options() {
    local output="$1"

    # Look for patterns like "a) ...", "1. ...", "- Option A"
    echo "$output" | grep -E '^\s*[a-z]\)|^\s*[0-9]+\.|^\s*-\s+[A-Z]' | head -5
}

# Detect wait reason and classify it
# Priority: AskUserQuestion > external_prompt > agent_question_text
# Args:
#   $1 - Session ID
#   $2 - Event data from stream-json (optional)
#   $3 - Terminal output (optional)
# Outputs:
#   JSON object with: reason, context, options, risk_level
detect_wait_reason() {
    local session_id="$1"
    local event_data="${2:-}"
    local output="${3:-}"

    local reason="unknown"
    local context=""
    local options=""
    local risk_level="low"

    # Priority 1: Check for AskUserQuestion in event stream
    if [[ -n "$event_data" ]] && detect_ask_user_question "$event_data"; then
        reason="ask_user_question"
        context=$(extract_question_info "$event_data")
        format_wait_info "$reason" "$context" "" "low"
        return 0
    fi

    # Priority 2: Check for external prompts
    local ext_prompt
    if [[ -n "$output" ]]; then
        if ext_prompt=$(detect_external_prompt "$output"); then
            reason="external_prompt"
            context="$ext_prompt"
            risk_level=$(classify_external_prompt_risk "$ext_prompt")
            format_wait_info "$reason" "$context" "" "$risk_level"
            return 0
        fi

        # Priority 3: Check for agent text question
        if detect_text_question "$output"; then
            reason="agent_question_text"
            context=$(extract_question_from_text "$output")
            options=$(extract_inline_options "$output")
            format_wait_info "$reason" "$context" "$options" "low"
            return 0
        fi
    fi

    # Fallback: unknown
    if [[ -n "$output" ]]; then
        context=$(echo "$output" | tail -10)
    fi
    format_wait_info "$reason" "$context" "" "$risk_level"
    return 0
}

# Format wait info as JSON for TUI consumption
# Args:
#   $1 - Wait reason
#   $2 - Context (text or JSON depending on reason)
#   $3 - Options (newline-separated list, optional)
#   $4 - Risk level
# Outputs:
#   JSON object suitable for TUI rendering
format_wait_info() {
    local reason="$1"
    local context="$2"
    local options="${3:-}"
    local risk_level="${4:-low}"

    # If context is already JSON (from extract_question_info), embed it
    if echo "$context" | jq empty 2>/dev/null; then
        jq -n \
            --arg reason "$reason" \
            --argjson context "$context" \
            --arg options "$options" \
            --arg risk "$risk_level" \
            '{
                reason: $reason,
                context: $context,
                options: ($options | split("\n") | map(select(. != ""))),
                risk_level: $risk,
                detected_at: (now | todate)
            }'
    else
        # Context is plain text
        jq -n \
            --arg reason "$reason" \
            --arg context "$context" \
            --arg options "$options" \
            --arg risk "$risk_level" \
            '{
                reason: $reason,
                context: $context,
                options: ($options | split("\n") | map(select(. != ""))),
                risk_level: $risk,
                detected_at: (now | todate)
            }'
    fi
}

#------------------------------------------------------------------------------
# COMMAND VALIDATION AND BLOCKING (bd-hmw8)
# Security: Validate commands before execution in agent sessions
#------------------------------------------------------------------------------

# Command categories for agent execution validation
# shellcheck disable=SC2034  # These arrays are used by validate_agent_command
SAFE_BASH_COMMANDS=(
    # Version control
    git
    # Search and find
    grep rg find fd
    # File viewing
    ls cat head tail less more bat
    # Build tools
    make cmake ninja
    # Package managers (read operations)
    npm yarn pnpm cargo go pip python python3 pytest
    # Linting
    shellcheck eslint prettier tsc mypy ruff
    # Data processing
    jq yq sed awk sort uniq wc diff
    # System info
    pwd which whereis whoami date
    # Text processing
    tr cut paste
    # Archive (read)
    tar
)

APPROVAL_REQUIRED_COMMANDS=(
    # File operations
    rm mv cp mkdir rmdir touch
    # Network
    curl wget http
    # Containers
    docker podman kubectl helm
    # Process management
    kill pkill killall
    # Git operations that modify remote
    "git push" "git push --force"
    # NPM publish
    "npm publish" "yarn publish"
)

BLOCKED_COMMANDS=(
    # Privilege escalation
    sudo su doas
    # Dangerous execution
    eval exec source
    # Permission changes
    chmod chown chgrp
    # Direct shell spawning
    bash sh zsh fish dash
    # System control
    shutdown reboot halt poweroff
    # Disk operations
    dd mkfs fdisk
    # Network dangerous
    nc netcat ncat
)

# Special gh command patterns
# Read operations - always allowed
GH_READ_COMMANDS=(
    "gh issue view"
    "gh issue list"
    "gh pr view"
    "gh pr list"
    "gh pr checks"
    "gh pr diff"
    "gh repo view"
    "gh api"
    "gh auth status"
)

# Write operations - blocked in Plan mode, need approval otherwise
GH_WRITE_COMMANDS=(
    "gh issue create"
    "gh issue close"
    "gh issue reopen"
    "gh issue comment"
    "gh issue edit"
    "gh pr create"
    "gh pr close"
    "gh pr merge"
    "gh pr review"
    "gh pr comment"
    "gh pr edit"
)

# Validate a command for agent execution
# Args:
#   $1 - Command string to validate
#   $2 - Mode (optional): "plan" or "execute" (default: "execute")
# Returns:
#   0 = allowed
#   1 = blocked
#   2 = needs approval
# Outputs:
#   JSON with validation result
validate_agent_command() {
    local raw_cmd="$1"
    local mode="${2:-execute}"

    # Trim leading/trailing whitespace (preserve internal whitespace/quoting as-is)
    local cmd="$raw_cmd"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"

    # Extract the base command (first token)
    local base_cmd="${cmd%%[[:space:]]*}"
    if [[ -z "$base_cmd" ]]; then
        jq -n \
            --arg cmd "$cmd" \
            --arg status "needs_approval" \
            --arg reason "Empty command" \
            '{command: $cmd, status: $status, reason: $reason}'
        return 2
    fi

    # Check blocked commands first (highest priority)
    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        if [[ "$base_cmd" == "$blocked" ]]; then
            jq -n \
                --arg cmd "$cmd" \
                --arg base "$base_cmd" \
                --arg status "blocked" \
                --arg reason "Command '$base_cmd' is blocked for security" \
                '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
            return 1
        fi
    done

    # Check for gh commands (special handling)
    if [[ "$base_cmd" == "gh" ]]; then
        # Check read commands - always allowed
        local gh_pattern
        for gh_pattern in "${GH_READ_COMMANDS[@]}"; do
            if [[ "$cmd" == "$gh_pattern"* ]]; then
                jq -n \
                    --arg cmd "$cmd" \
                    --arg status "allowed" \
                    --arg reason "gh read operation" \
                    '{command: $cmd, status: $status, reason: $reason}'
                return 0
            fi
        done

        # Check write commands - blocked in plan mode, approval in execute mode
        for gh_pattern in "${GH_WRITE_COMMANDS[@]}"; do
            if [[ "$cmd" == "$gh_pattern"* ]]; then
                if [[ "$mode" == "plan" ]]; then
                    jq -n \
                        --arg cmd "$cmd" \
                        --arg status "blocked" \
                        --arg reason "gh write operations blocked in Plan mode" \
                        '{command: $cmd, status: $status, reason: $reason}'
                    return 1
                else
                    jq -n \
                        --arg cmd "$cmd" \
                        --arg status "needs_approval" \
                        --arg reason "gh write operation requires confirmation" \
                        '{command: $cmd, status: $status, reason: $reason}'
                    return 2
                fi
            fi
        done

        # Unknown gh command - allow with warning
        jq -n \
            --arg cmd "$cmd" \
            --arg status "allowed" \
            --arg reason "gh command (unknown subcommand)" \
            '{command: $cmd, status: $status, reason: $reason}'
        return 0
    fi

    # Special check for git push variants (security bypass prevention)
    if [[ "$base_cmd" == "git" ]]; then
        # Check for 'push' token anywhere in the command.
        # Covers: git push, git -C path push, git push --force, etc.
        if [[ "$cmd" =~ (^|[[:space:]])push($|[[:space:]]) ]]; then
            jq -n \
                --arg cmd "$cmd" \
                --arg base "$base_cmd" \
                --arg status "needs_approval" \
                --arg reason "git push operation requires confirmation" \
                '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
            return 2
        fi
    fi

    # Check approval-required commands
    local approval_cmd
    for approval_cmd in "${APPROVAL_REQUIRED_COMMANDS[@]}"; do
        # Check if it's a multi-word pattern or single command
        if [[ "$approval_cmd" == *" "* ]]; then
            # Multi-word pattern - match prefix
            if [[ "$cmd" == "$approval_cmd"* ]]; then
                jq -n \
                    --arg cmd "$cmd" \
                    --arg status "needs_approval" \
                    --arg reason "Operation '$approval_cmd' requires confirmation" \
                    '{command: $cmd, status: $status, reason: $reason}'
                return 2
            fi
        else
            # Single command
            if [[ "$base_cmd" == "$approval_cmd" ]]; then
                jq -n \
                    --arg cmd "$cmd" \
                    --arg base "$base_cmd" \
                    --arg status "needs_approval" \
                    --arg reason "Command '$base_cmd' requires confirmation" \
                    '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
                return 2
            fi
        fi
    done

    # Check safe commands
    local safe_cmd
    for safe_cmd in "${SAFE_BASH_COMMANDS[@]}"; do
        if [[ "$base_cmd" == "$safe_cmd" ]]; then
            jq -n \
                --arg cmd "$cmd" \
                --arg status "allowed" \
                --arg reason "Safe command" \
                '{command: $cmd, status: $status, reason: $reason}'
            return 0
        fi
    done

    # Unknown command - needs approval for safety
    jq -n \
        --arg cmd "$cmd" \
        --arg base "$base_cmd" \
        --arg status "needs_approval" \
        --arg reason "Unknown command '$base_cmd' requires review" \
        '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
    return 2
}

# Quick check if command is safe (no JSON output)
# Args:
#   $1 - Command string
# Returns:
#   0 if safe, 1 otherwise
is_command_safe() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(echo "$cmd" | awk '{print $1}')

    # Check blocked first
    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$blocked" ]] && return 1
    done

    # Check if in safe list
    local safe_cmd
    for safe_cmd in "${SAFE_BASH_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$safe_cmd" ]] && return 0
    done

    return 1
}

# Check if command is explicitly blocked
# Args:
#   $1 - Command string
# Returns:
#   0 if blocked, 1 if not blocked
is_command_blocked() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(echo "$cmd" | awk '{print $1}')

    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$blocked" ]] && return 0
    done

    return 1
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
    if ! ntm --robot-status &>/dev/null; then
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

#------------------------------------------------------------------------------
# RATE-LIMIT GOVERNOR (bd-gptu)
# Dynamically adjust parallelism based on real rate limit data
#------------------------------------------------------------------------------

# Governor state (global for background loop access)
declare -gA GOVERNOR_STATE=(
    [github_remaining]=5000
    [github_reset]=0
    [model_in_backoff]="false"
    [model_backoff_until]=0
    [effective_parallelism]=4
    [target_parallelism]=4
    [circuit_breaker_open]="false"
    [error_count_window]=0
    [window_start]=0
    [governor_pid]=0
)

# Get the target parallelism from config (default 4)
get_target_parallelism() {
    echo "${REVIEW_PARALLEL:-4}"
}

# Update GitHub rate limit from API
# Queries: gh api rate_limit
# Sets: GOVERNOR_STATE[github_remaining], GOVERNOR_STATE[github_reset]
update_github_rate_limit() {
    if ! command -v gh &>/dev/null; then
        return 0
    fi

    local rate_info
    if ! rate_info=$(retry_with_backoff --capture=stdout 3 1 -- gh api rate_limit); then
        log_verbose "GitHub rate_limit query failed (ignored): ${rate_info}"
        return 0
    fi

    if command -v jq &>/dev/null && [[ -n "$rate_info" ]]; then
        local remaining reset_epoch
        remaining=$(echo "$rate_info" | jq -r '.resources.core.remaining // 5000' 2>/dev/null)
        reset_epoch=$(echo "$rate_info" | jq -r '.resources.core.reset // 0' 2>/dev/null)

        GOVERNOR_STATE[github_remaining]="${remaining:-5000}"
        GOVERNOR_STATE[github_reset]="${reset_epoch:-0}"

        if [[ "$remaining" -lt 500 ]]; then
            log_warn "GitHub API rate limit low: $remaining remaining"
        fi
    fi
}

# Check for model rate limits in session logs
# Scans recent logs for 429/rate limit patterns
# Sets: GOVERNOR_STATE[model_in_backoff], GOVERNOR_STATE[model_backoff_until]
check_model_rate_limit() {
    local state_dir="$RU_STATE_DIR"
    local log_dir
    log_dir="$state_dir/logs/$(date +%Y-%m-%d)"

    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi

    # Look for 429 responses in recent log files (last 5 minutes)
    local recent_429s=0
    local now
    now=$(date +%s)
    local five_min_ago=$((now - 300))

    # Find log files modified in last 5 minutes and grep for rate limit patterns
    while IFS= read -r log_file; do
        if [[ -f "$log_file" ]]; then
            local mtime
            mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$five_min_ago" ]]; then
                if grep -qiE 'rate[ .]limit|429|overloaded' "$log_file" 2>/dev/null; then
                    ((recent_429s++))
                fi
            fi
        fi
    done < <(find "$log_dir" -name "*.log" -type f 2>/dev/null)

    if [[ "$recent_429s" -gt 0 ]]; then
        local backoff_until=$((now + 60))
        GOVERNOR_STATE[model_in_backoff]="true"
        GOVERNOR_STATE[model_backoff_until]="$backoff_until"
        log_warn "Model rate limit detected ($recent_429s hits), backing off until $(date -d "@$backoff_until" +%H:%M:%S 2>/dev/null || date -r "$backoff_until" +%H:%M:%S 2>/dev/null || echo 'soon')"
    else
        # Check if backoff period has expired
        if [[ "${GOVERNOR_STATE[model_in_backoff]}" == "true" ]]; then
            if [[ "$now" -ge "${GOVERNOR_STATE[model_backoff_until]}" ]]; then
                GOVERNOR_STATE[model_in_backoff]="false"
                log_info "Model rate limit backoff expired, resuming normal operation"
            fi
        fi
    fi
}

# Record an error for circuit breaker tracking
# Args: error_type (optional, for future categorization)
governor_record_error() {
    local now
    now=$(date +%s)

    # Reset window if older than 5 minutes
    local window_start="${GOVERNOR_STATE[window_start]}"
    if [[ "$window_start" -eq 0 ]] || [[ $((now - window_start)) -gt 300 ]]; then
        GOVERNOR_STATE[window_start]="$now"
        GOVERNOR_STATE[error_count_window]=1
    else
        GOVERNOR_STATE[error_count_window]=$((GOVERNOR_STATE[error_count_window] + 1))
    fi
}

# Adjust parallelism based on current rate limit state
# Sets: GOVERNOR_STATE[effective_parallelism]
adjust_parallelism() {
    local target
    target=$(get_target_parallelism)
    GOVERNOR_STATE[target_parallelism]="$target"

    local effective="$target"
    local now
    now=$(date +%s)

    # Reduce if GitHub rate limit is low
    local github_remaining="${GOVERNOR_STATE[github_remaining]}"
    # Validate github_remaining is a non-negative integer; default to 5000 if not
    if ! [[ "$github_remaining" =~ ^[0-9]+$ ]]; then
        github_remaining=5000
    fi
    if [[ "$github_remaining" -lt 500 ]]; then
        effective=1
        log_verbose "Parallelism reduced to 1 (GitHub remaining: $github_remaining)"
    elif [[ "$github_remaining" -lt 1000 ]]; then
        effective=$((target / 2))
        [[ "$effective" -lt 1 ]] && effective=1
        log_verbose "Parallelism halved to $effective (GitHub remaining: $github_remaining)"
    fi

    # Reduce to 1 if model is in backoff
    if [[ "${GOVERNOR_STATE[model_in_backoff]}" == "true" ]]; then
        effective=1
        log_verbose "Parallelism reduced to 1 (model backoff active)"
    fi

    # Circuit breaker check
    local error_count="${GOVERNOR_STATE[error_count_window]}"
    local window_start="${GOVERNOR_STATE[window_start]}"
    # Validate integers; default to safe values if corrupted
    [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
    [[ "$window_start" =~ ^[0-9]+$ ]] || window_start=0
    if [[ "$error_count" -ge 5 ]] && [[ $((now - window_start)) -le 300 ]]; then
        GOVERNOR_STATE[circuit_breaker_open]="true"
        effective=0
        log_error "Circuit breaker OPEN: $error_count errors in last 5 minutes - pausing all sessions"
    elif [[ "${GOVERNOR_STATE[circuit_breaker_open]}" == "true" ]]; then
        # Try half-open after 60 seconds with no new errors
        if [[ "$error_count" -lt 5 ]] || [[ $((now - window_start)) -gt 300 ]]; then
            GOVERNOR_STATE[circuit_breaker_open]="false"
            GOVERNOR_STATE[error_count_window]=0
            log_info "Circuit breaker CLOSED: resuming normal operation"
        else
            effective=0
        fi
    fi

    GOVERNOR_STATE[effective_parallelism]="$effective"
}

# Check if we can start a new session based on governor state
# Args: current_active_sessions
# Returns: 0 if allowed, 1 if not
can_start_new_session() {
    local active_sessions="${1:-0}"

    # Circuit breaker open = no new sessions
    if [[ "${GOVERNOR_STATE[circuit_breaker_open]}" == "true" ]]; then
        log_verbose "Cannot start session: circuit breaker open"
        return 1
    fi

    # Model in backoff = no new sessions
    if [[ "${GOVERNOR_STATE[model_in_backoff]}" == "true" ]]; then
        log_verbose "Cannot start session: model in backoff"
        return 1
    fi

    # Check effective parallelism
    local effective="${GOVERNOR_STATE[effective_parallelism]}"
    # Validate integers; default to conservative values if corrupted
    [[ "$active_sessions" =~ ^[0-9]+$ ]] || active_sessions=0
    [[ "$effective" =~ ^[0-9]+$ ]] || effective=1
    if [[ "$active_sessions" -ge "$effective" ]]; then
        log_verbose "Cannot start session: at capacity ($active_sessions >= $effective)"
        return 1
    fi

    return 0
}

# Get governor status as JSON for TUI display
get_governor_status() {
    cat <<EOF
{
  "github_remaining": ${GOVERNOR_STATE[github_remaining]},
  "github_reset": ${GOVERNOR_STATE[github_reset]},
  "model_in_backoff": ${GOVERNOR_STATE[model_in_backoff]},
  "model_backoff_until": ${GOVERNOR_STATE[model_backoff_until]},
  "effective_parallelism": ${GOVERNOR_STATE[effective_parallelism]},
  "target_parallelism": ${GOVERNOR_STATE[target_parallelism]},
  "circuit_breaker_open": ${GOVERNOR_STATE[circuit_breaker_open]},
  "error_count": ${GOVERNOR_STATE[error_count_window]}
}
EOF
}

# Background loop that continuously monitors and adjusts rate limits
# Args: lock_file (optional, stops when lock is released)
start_rate_limit_governor() {
    local lock_file="${1:-}"
    local interval="${2:-30}"

    log_verbose "Starting rate-limit governor (interval: ${interval}s)"

    while true; do
        # Check if we should stop (lock file removed or parent process gone)
        if [[ -n "$lock_file" ]] && [[ ! -f "$lock_file" ]]; then
            log_verbose "Governor stopping: lock file removed"
            break
        fi

        # Update rate limits
        update_github_rate_limit
        check_model_rate_limit

        # Adjust parallelism based on current state
        adjust_parallelism

        # Log status periodically
        log_verbose "Governor status: effective_parallelism=${GOVERNOR_STATE[effective_parallelism]}, github_remaining=${GOVERNOR_STATE[github_remaining]}, model_backoff=${GOVERNOR_STATE[model_in_backoff]}"

        sleep "$interval"
    done
}

# Synchronous governor update - call before starting new sessions
# This is the RECOMMENDED approach as it updates GOVERNOR_STATE in the current process.
# Updates rate limits and adjusts parallelism in one call.
governor_update() {
    update_github_rate_limit
    check_model_rate_limit
    adjust_parallelism
}

# Start governor in background (DEPRECATED - see warning below)
# WARNING: Background subshell cannot update parent GOVERNOR_STATE!
# The background loop only provides logging; actual state updates require
# calling governor_update() synchronously before each session start.
# Args: lock_file (governor stops when this file is removed)
# Sets: GOVERNOR_STATE[governor_pid]
start_governor_background() {
    local lock_file="${1:-}"

    log_warn "start_governor_background: Background governor only logs status; call governor_update() for actual state updates"

    # Create lock file if path provided
    if [[ -n "$lock_file" ]]; then
        touch "$lock_file"
    fi

    start_rate_limit_governor "$lock_file" 30 &
    GOVERNOR_STATE[governor_pid]=$!
    log_verbose "Governor started in background (PID: ${GOVERNOR_STATE[governor_pid]})"
}

# Stop background governor
stop_governor_background() {
    local pid="${GOVERNOR_STATE[governor_pid]}"
    if [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        log_verbose "Governor stopped (PID: $pid)"
    fi
    GOVERNOR_STATE[governor_pid]=0
}

#------------------------------------------------------------------------------
# DASHBOARD VIEW FOR NTM MODE (bd-9j92)
# Full-screen TUI showing pending questions, active sessions, and summary stats
#------------------------------------------------------------------------------

# Dashboard state (global for event loop access)
declare -gA DASHBOARD_STATE=(
    [selected_index]=0
    [expanded_question]=""
    [scroll_offset]=0
    [panel_focus]="questions"
    [filter_query]=""
    [paused]="false"
    [refresh_needed]="true"
    [last_refresh]=0
    [running]="true"
)

# Dashboard color definitions
# shellcheck disable=SC2034  # Some colors reserved for future use
DASH_BOLD=$'\033[1m'
DASH_DIM=$'\033[2m'
DASH_RESET=$'\033[0m'
DASH_RED=$'\033[31m'
DASH_GREEN=$'\033[32m'
DASH_YELLOW=$'\033[33m'
# shellcheck disable=SC2034
DASH_BLUE=$'\033[34m'
DASH_CYAN=$'\033[36m'
DASH_BG_BLUE=$'\033[44m'
DASH_BG_GRAY=$'\033[100m'
DASHBOARD_OLD_STTY=""

# Get terminal dimensions
# Outputs: cols rows (space-separated) to stdout
get_terminal_size() {
    local cols rows
    if command -v tput &>/dev/null; then
        cols=$(tput cols 2>/dev/null) || cols=80
        rows=$(tput lines 2>/dev/null) || rows=24
    else
        cols=80
        rows=24
    fi
    echo "$cols $rows"
}

#------------------------------------------------------------------------------
# QUESTION QUEUE HELPERS (bd-fi65 / bd-80pt)
#------------------------------------------------------------------------------

normalize_questions_json() {
    local input="$1"

    if ! command -v jq &>/dev/null; then
        echo "[]"
        return 0
    fi

    if ! echo "$input" | jq empty >/dev/null 2>&1; then
        echo "[]"
        return 0
    fi

    local json_type
    json_type=$(echo "$input" | jq -r 'type' 2>/dev/null || echo "")
    if [[ "$json_type" == "array" ]]; then
        echo "$input"
    else
        echo "$input" | jq -c '.questions // []' 2>/dev/null || echo "[]"
    fi
}

load_questions_queue() {
    local questions_file
    questions_file=$(get_questions_file)

    if [[ ! -f "$questions_file" ]]; then
        echo "[]"
        return 0
    fi

    local content
    content=$(cat "$questions_file" 2>/dev/null || echo "")
    normalize_questions_json "$content"
}

write_questions_queue() {
    local questions_json="$1"
    local questions_file
    questions_file=$(get_questions_file)

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; cannot update questions queue"
        return 1
    fi

    local payload
    payload=$(jq -n --argjson questions "$questions_json" '{version:1, questions:$questions}')
    with_state_lock write_json_atomic "$questions_file" "$payload"
}

update_question_in_queue() {
    local question_id="$1"
    local update_filter="$2"
    shift 2
    local questions_file
    questions_file=$(get_questions_file)

    if [[ -z "$question_id" ]]; then
        log_warn "Cannot update question with empty id"
        return 1
    fi

    if [[ ! -f "$questions_file" ]]; then
        log_warn "Questions queue not found: $questions_file"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; cannot update questions queue"
        return 1
    fi

    local current updated
    current=$(cat "$questions_file" 2>/dev/null || echo "{}")
    if ! echo "$current" | jq empty >/dev/null 2>&1; then
        log_warn "Questions queue is invalid JSON"
        return 1
    fi

    updated=$(echo "$current" | jq --arg qid "$question_id" "$@" "$update_filter" 2>/dev/null) || return 1
    with_state_lock write_json_atomic "$questions_file" "$updated"
}

mark_question_answered() {
    local question_id="$1"
    local answer="$2"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    update_question_in_queue "$question_id" '
        if type=="array" then
            map(if .id == $qid then . + {status:"answered", answered_at:$now, answer:$answer} else . end)
        else
            .questions |= map(if .id == $qid then . + {status:"answered", answered_at:$now, answer:$answer} else . end)
        end
    ' --arg now "$now" --arg answer "$answer"
}

mark_question_skipped() {
    local question_id="$1"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    update_question_in_queue "$question_id" '
        if type=="array" then
            map(if .id == $qid then . + {status:"skipped", skipped_at:$now} else . end)
        else
            .questions |= map(if .id == $qid then . + {status:"skipped", skipped_at:$now} else . end)
        end
    ' --arg now "$now"
}

mark_question_snoozed() {
    local question_id="$1"
    local snooze_until="$2"

    update_question_in_queue "$question_id" '
        if type=="array" then
            map(if .id == $qid then . + {status:"snoozed", snooze_until:$snooze_until} else . end)
        else
            .questions |= map(if .id == $qid then . + {status:"snoozed", snooze_until:$snooze_until} else . end)
        end
    ' --arg snooze_until "$snooze_until"
}

filter_questions_json() {
    local questions_json="$1"
    local query="${DASHBOARD_STATE[filter_query]:-}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if ! command -v jq &>/dev/null; then
        echo "$questions_json"
        return 0
    fi

    echo "$questions_json" | jq -c --arg now "$now" --arg query "$query" '
        (if type=="array" then . else .questions // [] end)
        | map(select(
            (.status // "pending") == "pending"
            or ((.status // "") == "snoozed" and (.snooze_until // "") <= $now)
        ))
        | if $query != "" then
            map(select(
                ((.repo // "") | test($query; "i"))
                or ((.context // "" | tostring) | test($query; "i"))
                or ((.prompt // "") | test($query; "i"))
            ))
          else .
          end
    ' 2>/dev/null || echo "[]"
}

get_question_at_index() {
    local questions_json="$1"
    local index="$2"

    if ! command -v jq &>/dev/null; then
        echo ""
        return 1
    fi

    echo "$questions_json" | jq -c ".[$index] // empty" 2>/dev/null
}

date_add_days() {
    local days="$1"
    if date --version 2>/dev/null | grep -q GNU; then
        date -u -d "$days days" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -v+"${days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

dashboard_prompt_line() {
    local prompt="$1"
    local input=""

    exit_alt_screen
    read -r -p "$prompt" input
    enter_alt_screen
    DASHBOARD_STATE[refresh_needed]="true"
    echo "$input"
}

dashboard_prompt_choice() {
    local prompt="$1"
    shift
    local -a options=("$@")

    if [[ "${#options[@]}" -eq 0 ]]; then
        echo ""
        return 1
    fi

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        exit_alt_screen
        local chosen
        chosen=$(gum choose --cursor="> " --header "$prompt" "${options[@]}" 2>/dev/null || true)
        enter_alt_screen
        DASHBOARD_STATE[refresh_needed]="true"
        echo "$chosen"
        [[ -n "$chosen" ]]
        return $?
    fi

    exit_alt_screen
    printf '%s\n' "$prompt" >&2
    local i=1
    local opt
    for opt in "${options[@]}"; do
        printf '  %d) %s\n' "$i" "$opt" >&2
        ((i++))
    done
    local choice=""
    read -r -p "Choose [1-${#options[@]}]: " choice
    enter_alt_screen
    DASHBOARD_STATE[refresh_needed]="true"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#options[@]}" ]]; then
        echo "${options[$((choice - 1))]}"
        return 0
    fi
    echo ""
    return 1
}

get_review_templates_dir() {
    echo "${RU_CONFIG_DIR:-$HOME/.config/ru}/review-templates.d"
}

pick_review_template() {
    local templates_dir
    templates_dir=$(get_review_templates_dir)

    if [[ ! -d "$templates_dir" ]]; then
        log_warn "No templates directory found: $templates_dir"
        return 1
    fi

    local -a templates=()
    local file
    for file in "$templates_dir"/*; do
        [[ -f "$file" ]] || continue
        templates+=("$(basename "$file")")
    done

    if [[ ${#templates[@]} -eq 0 ]]; then
        log_warn "No templates found in $templates_dir"
        return 1
    fi

    local selected
    selected=$(dashboard_prompt_choice "Select a template" "${templates[@]}")
    [[ -z "$selected" ]] && return 1

    cat "$templates_dir/$selected"
}

render_help_overlay() {
    clear_screen
    printf '%s%sHelp%s\n\n' "$DASH_BOLD" "$DASH_CYAN" "$DASH_RESET"
    printf 'Navigation: j/k or arrows, Tab switch panel, / search\n'
    printf 'Quick: [1-9] answer, Enter expand, d drill, s skip, S skip all\n'
    printf 'Actions: z snooze, t template, a apply, b bulk apply safe\n'
    printf 'Control: p pause, r resume, h help, q quit, Esc cancel\n'
    printf '\nPress any key to return...\n'
    read_keypress
    DASHBOARD_STATE[refresh_needed]="true"
}

question_get_id() {
    local question_json="$1"
    echo "$question_json" | jq -r '.id // .questions[0].id // .context.questions[0].id // .tool_use_id // empty' 2>/dev/null
}

question_get_session_id() {
    local question_json="$1"
    echo "$question_json" | jq -r '.session_id // .context.session_id // empty' 2>/dev/null
}

question_get_prompt() {
    local question_json="$1"
    echo "$question_json" | jq -r '
        if .prompt then .prompt
        elif (.questions[0].prompt) then .questions[0].prompt
        elif (.context.questions[0].prompt) then .context.questions[0].prompt
        elif .context then (.context | tostring)
        else ""
        end
    ' 2>/dev/null
}

question_get_recommended() {
    local question_json="$1"
    echo "$question_json" | jq -r '.recommended // .questions[0].recommended // .context.questions[0].recommended // empty' 2>/dev/null
}

question_get_options_lines() {
    local question_json="$1"
    echo "$question_json" | jq -r '
        (.options // .questions[0].options // .context.questions[0].options // []) | .[] |
        if type=="object" and has("label") then .label else . end
    ' 2>/dev/null
}

dashboard_answer_question() {
    local questions_json="$1"
    local index="$2"

    local question_json
    question_json=$(get_question_at_index "$questions_json" "$index")
    [[ -z "$question_json" ]] && return 1

    local question_id session_id prompt recommended
    question_id=$(question_get_id "$question_json")
    session_id=$(question_get_session_id "$question_json")
    prompt=$(question_get_prompt "$question_json")
    recommended=$(question_get_recommended "$question_json")

    local -a options=()
    mapfile -t options < <(question_get_options_lines "$question_json")

    local answer=""
    if [[ ${#options[@]} -gt 0 ]]; then
        local choice_prompt="Answer: ${prompt:-Choose an option}"
        answer=$(dashboard_prompt_choice "$choice_prompt" "${options[@]}")
        if [[ -z "$answer" && -n "$recommended" ]]; then
            answer="$recommended"
        fi
    else
        local choice_prompt="Answer: ${prompt:-Enter response}"
        answer=$(dashboard_prompt_line "$choice_prompt ")
    fi

    if [[ -z "$answer" ]]; then
        log_warn "No answer selected"
        return 1
    fi

    if [[ -n "$session_id" ]]; then
        driver_send_to_session "$session_id" "$answer" || true
    else
        log_warn "Question missing session_id; answer not delivered"
    fi

    if [[ -n "$question_id" ]]; then
        mark_question_answered "$question_id" "$answer" || true
    fi
}

dashboard_skip_question() {
    local questions_json="$1"
    local index="$2"

    local question_json
    question_json=$(get_question_at_index "$questions_json" "$index")
    [[ -z "$question_json" ]] && return 1

    local question_id
    question_id=$(question_get_id "$question_json")
    if [[ -n "$question_id" ]]; then
        mark_question_skipped "$question_id" || true
    fi
}

dashboard_skip_all_questions() {
    local questions_file
    questions_file=$(get_questions_file)

    if [[ ! -f "$questions_file" ]] || ! command -v jq &>/dev/null; then
        return 0
    fi

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local current updated
    current=$(cat "$questions_file" 2>/dev/null || echo "{}")
    updated=$(echo "$current" | jq --arg now "$now" '
        if type=="array" then
            map(if (.status // "pending") == "pending" then . + {status:"skipped", skipped_at:$now} else . end)
        else
            .questions |= map(if (.status // "pending") == "pending" then . + {status:"skipped", skipped_at:$now} else . end)
        end
    ' 2>/dev/null || echo "")

    if [[ -n "$updated" ]]; then
        with_state_lock write_json_atomic "$questions_file" "$updated"
    fi
}

dashboard_snooze_question() {
    local questions_json="$1"
    local index="$2"

    local question_json
    question_json=$(get_question_at_index "$questions_json" "$index")
    [[ -z "$question_json" ]] && return 1

    local question_id
    question_id=$(question_get_id "$question_json")
    [[ -z "$question_id" ]] && return 1

    local choice
    choice=$(dashboard_prompt_choice "Snooze duration" "1 day" "7 days" "30 days" "Cancel")
    case "$choice" in
        "1 day") mark_question_snoozed "$question_id" "$(date_add_days 1)" ;;
        "7 days") mark_question_snoozed "$question_id" "$(date_add_days 7)" ;;
        "30 days") mark_question_snoozed "$question_id" "$(date_add_days 30)" ;;
        *) ;;
    esac
}

dashboard_apply_template() {
    local questions_json="$1"
    local index="$2"

    local question_json
    question_json=$(get_question_at_index "$questions_json" "$index")
    [[ -z "$question_json" ]] && return 1

    local session_id
    session_id=$(question_get_session_id "$question_json")
    [[ -z "$session_id" ]] && return 1

    local template_text
    template_text=$(pick_review_template || true)
    [[ -z "$template_text" ]] && return 1

    driver_send_to_session "$session_id" "$template_text" || true
}

# Enter alternate screen buffer
enter_alt_screen() {
    printf '\033[?1049h'  # Enter alternate screen
    printf '\033[?25l'    # Hide cursor

    if [[ -t 0 ]]; then
        DASHBOARD_OLD_STTY=$(stty -g 2>/dev/null || true)
        stty -echo -icanon min 0 time 1 2>/dev/null || true
    fi
}

# Exit alternate screen buffer
exit_alt_screen() {
    printf '\033[?25h'    # Show cursor
    printf '\033[?1049l'  # Exit alternate screen

    if [[ -t 0 ]]; then
        if [[ -n "${DASHBOARD_OLD_STTY:-}" ]]; then
            stty "$DASHBOARD_OLD_STTY" 2>/dev/null || true
        else
            stty echo icanon 2>/dev/null || true
        fi
    fi
}

# Clear screen and move cursor to top-left
clear_screen() {
    printf '\033[2J\033[H'
}

# Move cursor to position
move_cursor() {
    local row="$1"
    local col="$2"
    printf '\033[%d;%dH' "$row" "$col"
}

# Draw a horizontal line
draw_hline() {
    local width="$1"
    local char="${2:-─}"
    printf '%*s' "$width" '' | tr ' ' "$char"
}

# Truncate string to fit width with ellipsis
truncate_string() {
    local str="$1"
    local max_width="$2"

    # Guard against invalid width
    if [[ $max_width -lt 4 ]]; then
        echo "${str:0:$max_width}"
        return
    fi

    if [[ ${#str} -gt $max_width ]]; then
        echo "${str:0:$((max_width - 3))}..."
    else
        echo "$str"
    fi
}

# Format duration from seconds
format_duration() {
    local seconds="$1"
    local mins=$((seconds / 60))
    local secs=$((seconds % 60))
    printf '%dm %02ds' "$mins" "$secs"
}

# Render dashboard header
# Args: $1=cols, $2=run_id, $3=progress_current, $4=progress_total, $5=start_time
render_header() {
    local cols="$1"
    local run_id="$2"
    local current="$3"
    local total="$4"
    local start_time="$5"

    local now
    now=$(date +%s)
    local runtime=$((now - start_time))

    # Top border
    printf '%s%s' "${DASH_BG_BLUE}${DASH_BOLD}" "${DASH_RESET}"
    printf '%s' "${DASH_BG_BLUE}"

    # Title and stats
    local title="ru review"
    local stats
    stats=$(printf 'Progress: %d/%d  Runtime: %s' "$current" "$total" "$(format_duration "$runtime")")
    local padding=$((cols - ${#title} - ${#stats} - 4))
    if [[ $padding -lt 0 ]]; then padding=0; fi

    printf '  %s%s%*s%s  ' "${DASH_BOLD}${title}${DASH_RESET}${DASH_BG_BLUE}" "" "$padding" "" "$stats"
    printf '%s\n' "${DASH_RESET}"

    # Border line
    printf '%s' "${DASH_DIM}"
    draw_hline "$cols"
    printf '%s\n' "${DASH_RESET}"
}

# Render a single question entry
# Args: $1=index, $2=selected, $3=expanded, $4=question_json, $5=cols
render_question_entry() {
    local index="$1"
    local selected="$2"
    local expanded="$3"
    local question_json="$4"
    local cols="$5"

    local repo number item_type priority context
    repo=$(echo "$question_json" | jq -r '.repo // "unknown"')
    number=$(echo "$question_json" | jq -r '.number // 0')
    item_type=$(echo "$question_json" | jq -r '.type // "issue"')
    priority=$(echo "$question_json" | jq -r '.priority // "NORMAL"')
    context=$(echo "$question_json" | jq -r '
        if .prompt then .prompt
        elif (.questions[0].prompt) then .questions[0].prompt
        elif (.context.questions[0].prompt) then .context.questions[0].prompt
        elif .context then (.context | tostring)
        else ""
        end
    ' 2>/dev/null | head -1)

    # Priority colors
    local priority_color="$DASH_RESET"
    case "$priority" in
        CRITICAL) priority_color="$DASH_RED" ;;
        HIGH)     priority_color="$DASH_YELLOW" ;;
        NORMAL)   priority_color="$DASH_GREEN" ;;
        LOW)      priority_color="$DASH_DIM" ;;
    esac

    # Selection indicator
    local indicator="○"
    if [[ "$selected" == "true" ]]; then
        indicator="●"
        printf '%s' "$DASH_BG_GRAY"
    fi

    # Format type tag
    local type_tag
    if [[ "$item_type" == "pr" ]]; then
        type_tag="PR #$number"
    else
        type_tag="Issue #$number"
    fi

    # Main line
    local main_line
    main_line=$(printf '  [%d] %s %-18s %-12s Priority: %s%s%s' \
        "$index" "$indicator" \
        "$(truncate_string "$repo" 18)" \
        "$type_tag" \
        "$priority_color" "$priority" "$DASH_RESET")
    printf '%s\n' "$(truncate_string "$main_line" "$cols")"

    if [[ "$selected" == "true" ]]; then
        printf '%s' "$DASH_RESET"
    fi

    # Context line (if selected or expanded)
    if [[ "$expanded" == "true" || "$selected" == "true" ]]; then
        local context_display
        context_display=$(truncate_string "$context" $((cols - 10)))
        printf '      %sContext: %s%s\n' "$DASH_DIM" "$context_display" "$DASH_RESET"

        # Options (if available)
        local options
        options=$(echo "$question_json" | jq -r '
            (.options // .questions[0].options // .context.questions[0].options // []) | .[] |
            if type=="object" and has("label") then .label else . end
        ' 2>/dev/null)
        if [[ -n "$options" ]]; then
            local opt_line="      > "
            local opt_index=0
            while IFS= read -r opt; do
                [[ -z "$opt" ]] && continue
                local letter
                letter=$(printf '%c' $((97 + opt_index)))  # a, b, c...
                opt_line+="${letter}) ${opt}  "
                ((opt_index++))
            done <<< "$options"
            printf '%s\n' "$(truncate_string "$opt_line" "$cols")"
        fi
    fi
}

# Render questions panel
# Args: $1=cols, $2=max_rows, $3=questions_json_array
render_questions_panel() {
    local cols="$1"
    local max_rows="$2"
    local questions_json="$3"

    local count
    count=$(echo "$questions_json" | jq 'length' 2>/dev/null) || count=0
    [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0
    local selected_idx="${DASHBOARD_STATE[selected_index]}"

    # Panel header
    printf '\n  %sPENDING QUESTIONS (%d)%s\n' "${DASH_BOLD}" "$count" "${DASH_RESET}"
    printf '  %s' "${DASH_DIM}"
    draw_hline $((cols - 4))
    printf '%s\n' "${DASH_RESET}"

    if [[ "$count" -eq 0 ]]; then
        printf '  %sNo pending questions%s\n' "${DASH_DIM}" "${DASH_RESET}"
        return
    fi

    # Render visible questions
    local visible_rows=$((max_rows - 4))
    local scroll_offset="${DASHBOARD_STATE[scroll_offset]}"
    if [[ "$scroll_offset" -ge "$count" ]]; then
        scroll_offset=0
        DASHBOARD_STATE[scroll_offset]=0
    fi
    local end_idx=$((scroll_offset + visible_rows))
    [[ $end_idx -gt $count ]] && end_idx=$count

    local i
    for ((i = scroll_offset; i < end_idx; i++)); do
        local question
        question=$(echo "$questions_json" | jq ".[$i]" 2>/dev/null) || continue
        [[ -z "$question" || "$question" == "null" ]] && continue
        local is_selected="false"
        local is_expanded="false"
        [[ $i -eq $selected_idx ]] && is_selected="true"
        [[ "${DASHBOARD_STATE[expanded_question]}" == "$i" ]] && is_expanded="true"
        render_question_entry "$((i + 1))" "$is_selected" "$is_expanded" "$question" "$cols"
    done

    # Scroll indicator
    if [[ $count -gt $visible_rows ]]; then
        printf '  %s[%d more below]%s\n' "${DASH_DIM}" "$((count - end_idx))" "${DASH_RESET}"
    fi
}

# Render sessions panel
# Args: $1=cols, $2=sessions_json_array
render_sessions_panel() {
    local cols="$1"
    local sessions_json="$2"

    local count
    count=$(echo "$sessions_json" | jq 'length' 2>/dev/null) || count=0
    [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0

    # Panel header
    printf '\n  %sACTIVE SESSIONS%s\n' "${DASH_BOLD}" "${DASH_RESET}"
    printf '  %s' "${DASH_DIM}"
    draw_hline $((cols - 4))
    printf '%s\n' "${DASH_RESET}"

    if [[ "$count" -eq 0 ]]; then
        printf '  %sNo active sessions%s\n' "${DASH_DIM}" "${DASH_RESET}"
        return
    fi

    # Table header
    printf '  %s%-20s %-14s %-10s %-10s%s\n' \
        "${DASH_DIM}" "Repo" "State" "Progress" "Health" "${DASH_RESET}"

    # Render sessions
    echo "$sessions_json" | jq -r '.[] | "\(.repo // "unknown")\t\(.state // "unknown")\t\(.progress // "0/0")\t\(.health // "Unknown")"' 2>/dev/null | \
    while IFS=$'\t' read -r repo state progress health; do
        [[ -z "$repo" ]] && continue
        # State colors
        local state_color="$DASH_RESET"
        case "$state" in
            GENERATING) state_color="$DASH_GREEN" ;;
            THINKING)   state_color="$DASH_CYAN" ;;
            WAITING)    state_color="$DASH_YELLOW" ;;
            IDLE)       state_color="$DASH_DIM" ;;
        esac

        # Health colors
        local health_color="$DASH_GREEN"
        [[ "$health" == "Degraded" ]] && health_color="$DASH_YELLOW"
        [[ "$health" == "Unhealthy" ]] && health_color="$DASH_RED"

        printf '  %-20s %s%-14s%s %-10s %s%-10s%s\n' \
            "$(truncate_string "$repo" 20)" \
            "$state_color" "$state" "$DASH_RESET" \
            "$progress" \
            "$health_color" "$health" "$DASH_RESET"
    done
}

# Render summary panel
# Args: $1=cols, $2=completed, $3=issues, $4=prs, $5=commits
render_summary_panel() {
    local cols="$1"
    local completed="$2"
    local issues="$3"
    local prs="$4"
    local commits="$5"

    printf '\n  %s' "${DASH_DIM}"
    draw_hline $((cols - 4))
    printf '%s\n' "${DASH_RESET}"

    printf '  %sSUMMARY%s\n' "${DASH_BOLD}" "${DASH_RESET}"
    printf '  Completed: %s%d%s | Issues: %d | PRs: %d | Commits: %d\n' \
        "${DASH_GREEN}" "$completed" "${DASH_RESET}" "$issues" "$prs" "$commits"
}

# Render footer with keyboard shortcuts
# Args: $1=cols
render_footer() {
    local cols="$1"

    printf '\n%s' "${DASH_DIM}"
    draw_hline "$cols"
    printf '\n'

    local shortcuts="[1-9] Answer [Enter] Expand [d] Drill [s] Skip [S] Skip all [z] Snooze [t] Template [/] Search [h] Help [q] Quit"
    printf ' %s%s\n' "$shortcuts" "${DASH_RESET}"
}

# Main dashboard render function
# Args: $1=run_id, $2=start_time, $3=questions_json, $4=sessions_json, $5=stats_json
render_dashboard() {
    local run_id="$1"
    local start_time="$2"
    local questions_json="$3"
    local sessions_json="$4"
    local stats_json="$5"

    local cols rows term_size
    term_size=$(get_terminal_size)
    read -r cols rows <<< "$term_size"

    # Parse stats with fallbacks
    local completed issues prs commits progress_current progress_total
    completed=$(echo "$stats_json" | jq -r '.completed // 0' 2>/dev/null) || completed=0
    issues=$(echo "$stats_json" | jq -r '.issues // 0' 2>/dev/null) || issues=0
    prs=$(echo "$stats_json" | jq -r '.prs // 0' 2>/dev/null) || prs=0
    commits=$(echo "$stats_json" | jq -r '.commits // 0' 2>/dev/null) || commits=0
    progress_current=$(echo "$stats_json" | jq -r '.current // 0' 2>/dev/null) || progress_current=0
    progress_total=$(echo "$stats_json" | jq -r '.total // 0' 2>/dev/null) || progress_total=0

    clear_screen

    # Render components
    render_header "$cols" "$run_id" "$progress_current" "$progress_total" "$start_time"

    # Calculate available space for questions panel
    local questions_rows=$((rows - 18))  # Reserve space for other panels
    [[ $questions_rows -lt 5 ]] && questions_rows=5

    render_questions_panel "$cols" "$questions_rows" "$questions_json"
    render_sessions_panel "$cols" "$sessions_json"
    render_summary_panel "$cols" "$completed" "$issues" "$prs" "$commits"
    render_footer "$cols"
}

# Handle single keypress
# Args: $1=key, $2=questions_count
# Returns: action to take (answer:N, expand, drill, skip, apply, quit, none)
handle_dashboard_keypress() {
    local key="$1"
    local questions_count="$2"
    local selected="${DASHBOARD_STATE[selected_index]}"

    case "$key" in
        # Number keys for quick answer
        [1-9])
            local idx=$((key - 1))
            if [[ $idx -lt $questions_count ]]; then
                echo "answer:$idx"
            fi
            ;;

        # Navigation
        j|$'\x1b[B')  # j or down arrow
            if [[ $((selected + 1)) -lt $questions_count ]]; then
                DASHBOARD_STATE[selected_index]=$((selected + 1))
            fi
            echo "refresh"
            ;;
        k|$'\x1b[A')  # k or up arrow
            if [[ $selected -gt 0 ]]; then
                DASHBOARD_STATE[selected_index]=$((selected - 1))
            fi
            echo "refresh"
            ;;
        $'\t'|$'\x1b[C'|$'\x1b[D')  # tab or left/right arrows
            case "${DASHBOARD_STATE[panel_focus]}" in
                questions) DASHBOARD_STATE[panel_focus]="sessions" ;;
                sessions) DASHBOARD_STATE[panel_focus]="summary" ;;
                *) DASHBOARD_STATE[panel_focus]="questions" ;;
            esac
            echo "refresh"
            ;;

        # Expand/collapse
        $'\x0a'|$'\x0d')  # Enter
            if [[ "${DASHBOARD_STATE[expanded_question]}" == "$selected" ]]; then
                DASHBOARD_STATE[expanded_question]=""
            else
                DASHBOARD_STATE[expanded_question]="$selected"
            fi
            echo "refresh"
            ;;

        # Actions
        d) echo "drill:$selected" ;;
        s) echo "skip:$selected" ;;
        S) echo "skip_all" ;;
        z) echo "snooze:$selected" ;;
        t) echo "template:$selected" ;;
        a) echo "apply" ;;
        b) echo "bulk_apply" ;;
        p) echo "pause" ;;
        r) echo "resume" ;;
        q) echo "quit" ;;
        h) echo "help" ;;
        '/') echo "search" ;;
        $'\x1b') echo "cancel" ;;

        # Ignore other keys
        *) echo "none" ;;
    esac
}

# Read a keypress (handles escape sequences for arrow keys)
read_keypress() {
    local timeout_seconds="${1:-}"
    local key seq

    if [[ -n "$timeout_seconds" ]]; then
        IFS= read -rsn1 -t "$timeout_seconds" key 2>/dev/null || return 1
    else
        IFS= read -rsn1 key 2>/dev/null || return 1
    fi

    # Check for escape sequence
    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.1 seq 2>/dev/null || true
        key+="$seq"
    fi

    echo "$key"
}

# Main dashboard event loop
# Args: $1=run_id, $2=start_time
# Global: Uses DASHBOARD_STATE, reads from question queue
run_dashboard() {
    local run_id="$1"
    local start_time="$2"
    local interrupted="false"

    # Dashboard requires jq for JSON parsing
    if ! command -v jq &>/dev/null; then
        log_error "Dashboard requires 'jq' for JSON parsing. Please install jq."
        return 3
    fi

    # Save/override traps while dashboard is active
    local old_trap_int old_trap_term old_trap_winch
    old_trap_int=$(trap -p INT || true)
    old_trap_term=$(trap -p TERM || true)
    old_trap_winch=$(trap -p SIGWINCH || true)

    # Set up terminal
    enter_alt_screen

    # Handle interrupts: restore terminal and bubble up after cleanup
    trap 'interrupted="true"; DASHBOARD_STATE[running]="false"' INT TERM

    # Handle resize
    trap 'DASHBOARD_STATE[refresh_needed]="true"' SIGWINCH

    DASHBOARD_STATE[running]="true"
    DASHBOARD_STATE[last_refresh]=0

    while [[ "${DASHBOARD_STATE[running]}" == "true" ]]; do
        local now
        now=$(date +%s)

        # Check if refresh needed (every 5 seconds or on demand)
        if [[ "${DASHBOARD_STATE[refresh_needed]}" == "true" ]] || \
           [[ $((now - DASHBOARD_STATE[last_refresh])) -ge 5 ]]; then

            # Get current state (these would be populated by the orchestrator)
            local questions_json="${DASHBOARD_QUESTIONS:-[]}"
            local sessions_json="${DASHBOARD_SESSIONS:-[]}"
            local stats_json="${DASHBOARD_STATS:-{\"completed\":0,\"issues\":0,\"prs\":0,\"commits\":0,\"current\":0,\"total\":0}}"

            local filtered_questions
            filtered_questions=$(filter_questions_json "$questions_json")
            render_dashboard "$run_id" "$start_time" "$filtered_questions" "$sessions_json" "$stats_json"

            DASHBOARD_STATE[refresh_needed]="false"
            DASHBOARD_STATE[last_refresh]="$now"
        fi

        # Wait for keypress with timeout (for periodic refresh)
        local key
        if key=$(read_keypress 1); then
            local questions_count=0
            local filtered_questions=""
            if command -v jq &>/dev/null; then
                filtered_questions=$(filter_questions_json "${DASHBOARD_QUESTIONS:-[]}")
                questions_count=$(echo "$filtered_questions" | jq 'length' 2>/dev/null || echo 0)
            fi
            if [[ "$questions_count" -le 0 ]]; then
                DASHBOARD_STATE[selected_index]=0
            elif [[ "${DASHBOARD_STATE[selected_index]}" -ge "$questions_count" ]]; then
                DASHBOARD_STATE[selected_index]=$((questions_count - 1))
            fi

            local action
            action=$(handle_dashboard_keypress "$key" "$questions_count")

            case "$action" in
                answer:*)
                    local idx="${action#answer:}"
                    if [[ -n "$filtered_questions" ]]; then
                        dashboard_answer_question "$filtered_questions" "$idx"
                    fi
                    ;;
                drill:*)
                    local idx="${action#drill:}"
                    # TODO: Open drill-down view (bd-7of4)
                    log_verbose "Drill into question $idx"
                    ;;
                skip:*)
                    local idx="${action#skip:}"
                    if [[ -n "$filtered_questions" ]]; then
                        dashboard_skip_question "$filtered_questions" "$idx"
                    fi
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
                skip_all)
                    dashboard_skip_all_questions
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
                snooze:*)
                    local idx="${action#snooze:}"
                    if [[ -n "$filtered_questions" ]]; then
                        dashboard_snooze_question "$filtered_questions" "$idx"
                    fi
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
                template:*)
                    local idx="${action#template:}"
                    if [[ -n "$filtered_questions" ]]; then
                        dashboard_apply_template "$filtered_questions" "$idx"
                    fi
                    ;;
                apply)
                    # TODO: Apply approved changes
                    log_verbose "Apply changes requested"
                    ;;
                bulk_apply)
                    log_verbose "Bulk apply safe requested"
                    ;;
                pause)
                    DASHBOARD_STATE[paused]="true"
                    log_verbose "Dashboard paused"
                    ;;
                resume)
                    DASHBOARD_STATE[paused]="false"
                    log_verbose "Dashboard resumed"
                    ;;
                quit)
                    DASHBOARD_STATE[running]="false"
                    ;;
                refresh)
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
                help)
                    render_help_overlay
                    ;;
                search)
                    local query
                    query=$(dashboard_prompt_line "Search: ")
                    DASHBOARD_STATE[filter_query]="$query"
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
                cancel)
                    DASHBOARD_STATE[filter_query]=""
                    DASHBOARD_STATE[refresh_needed]="true"
                    ;;
            esac
        fi
    done

    exit_alt_screen

    # Restore previous traps
    trap - INT TERM SIGWINCH
    [[ -n "$old_trap_int" ]] && eval "$old_trap_int"
    [[ -n "$old_trap_term" ]] && eval "$old_trap_term"
    [[ -n "$old_trap_winch" ]] && eval "$old_trap_winch"

    if [[ "$interrupted" == "true" ]]; then
        return 130
    fi
}

# Initialize dashboard with data
# Args: $1=questions_json, $2=sessions_json, $3=stats_json
init_dashboard_data() {
    DASHBOARD_QUESTIONS="$1"
    DASHBOARD_SESSIONS="$2"
    DASHBOARD_STATS="$3"
}

# Update dashboard questions
update_dashboard_questions() {
    DASHBOARD_QUESTIONS="$1"
    DASHBOARD_STATE[refresh_needed]="true"
}

# Update dashboard sessions
update_dashboard_sessions() {
    DASHBOARD_SESSIONS="$1"
    DASHBOARD_STATE[refresh_needed]="true"
}

# Update dashboard stats
update_dashboard_stats() {
    DASHBOARD_STATS="$1"
    DASHBOARD_STATE[refresh_needed]="true"
}

#------------------------------------------------------------------------------
# BASIC MODE TUI (bd-fi65)
# Simple question loop with gum/ANSI fallbacks
#------------------------------------------------------------------------------

show_question_basic_mode() {
    local question_json="$1"

    local repo prompt priority
    repo=$(echo "$question_json" | jq -r '.repo // "unknown"' 2>/dev/null)
    prompt=$(question_get_prompt "$question_json")
    priority=$(echo "$question_json" | jq -r '.priority // "NORMAL"' 2>/dev/null)

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        gum style --border rounded --padding "1 2" --border-foreground "#fab387" \
            "Question from: $repo" >&2
        gum style --bold "$prompt" >&2
        gum style "Priority: $priority" >&2
    else
        printf '%b\n' "${BOLD}Question from: ${repo}${RESET}" >&2
        printf '%b\n' "${CYAN}${prompt}${RESET}" >&2
        printf '%b\n' "Priority: $priority" >&2
    fi
}

basic_mode_choose_answer() {
    local question_json="$1"
    local -a options=()
    mapfile -t options < <(question_get_options_lines "$question_json")

    if [[ ${#options[@]} -eq 0 ]]; then
        local answer
        read -r -p "Answer: " answer
        echo "$answer"
        return 0
    fi

    options+=("Skip")

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        gum choose --cursor="> " --header "Choose an option" "${options[@]}"
        return $?
    fi

    local i=1
    local opt
    for opt in "${options[@]}"; do
        printf '  %d) %s\n' "$i" "$opt" >&2
        ((i++))
    done
    local choice=""
    read -r -p "Choose [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#options[@]}" ]]; then
        echo "${options[$((choice - 1))]}"
        return 0
    fi
    echo ""
    return 1
}

basic_mode_loop() {
    if ! command -v jq &>/dev/null; then
        log_error "Basic mode requires jq for question parsing"
        return 3
    fi

    local questions_json
    questions_json=$(load_questions_queue)
    local filtered
    filtered=$(filter_questions_json "$questions_json")
    local count
    count=$(echo "$filtered" | jq 'length' 2>/dev/null || echo 0)

    if [[ -z "$count" || "$count" -eq 0 ]]; then
        log_info "No pending questions"
        return 0
    fi

    local i
    for ((i = 0; i < count; i++)); do
        local question_json
        question_json=$(get_question_at_index "$filtered" "$i")
        [[ -z "$question_json" ]] && continue

        show_question_basic_mode "$question_json"
        local answer
        answer=$(basic_mode_choose_answer "$question_json")
        if [[ -z "$answer" ]]; then
            log_warn "No answer selected"
            continue
        fi

        if [[ "$answer" == "Skip" ]]; then
            local question_id
            question_id=$(question_get_id "$question_json")
            [[ -n "$question_id" ]] && mark_question_skipped "$question_id" || true
            continue
        fi

        local session_id
        session_id=$(question_get_session_id "$question_json")
        if [[ -n "$session_id" ]]; then
            gum_spin "Sending answer..." driver_send_to_session "$session_id" "$answer" || true
        fi

        local question_id
        question_id=$(question_get_id "$question_json")
        [[ -n "$question_id" ]] && mark_question_answered "$question_id" "$answer" || true
    done
}

#------------------------------------------------------------------------------
# REVIEW POLICY CONFIGURATION (bd-cutq)
# Per-repo customization of review behavior via configuration files
#------------------------------------------------------------------------------

# Get path to review policies directory
get_review_policy_dir() {
    echo "${RU_CONFIG_DIR}/review-policies.d"
}

# Load policy for a specific repo, merging defaults with overrides
# Args: $1 = repo_id (owner/repo format)
# Outputs: Sourced policy variables to stdout as KEY=VALUE pairs
load_policy_for_repo() {
    local repo_id="$1"
    local policy_dir
    policy_dir=$(get_review_policy_dir)

    # Initialize with hardcoded defaults
    local -A policy=(
        [REVIEW_TEST_CMD]=""
        [REVIEW_TEST_TIMEOUT]="300"
        [REVIEW_LINT_CMD]=""
        [REVIEW_LINT_REQUIRED]="false"
        [REVIEW_SECRET_SCAN]="true"
        [REVIEW_SECRET_PATTERNS]=""
        [REVIEW_ALLOW_PUSH]="true"
        [REVIEW_REQUIRE_APPROVAL]="false"
        [REVIEW_BASE_PRIORITY]="0"
        [REVIEW_LABELS_BOOST]=""
        [REVIEW_MAX_ITEMS]="20"
        [REVIEW_SKIP_PRS]="false"
        [REVIEW_DEEP_MODE]="false"
    )

    # 1. Load _default.conf if exists
    local default_policy="${policy_dir}/_default.conf"
    if [[ -f "$default_policy" ]]; then
        # shellcheck disable=SC1090
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            key=$(echo "$key" | xargs)  # Trim whitespace
            value=$(echo "$value" | xargs | sed 's/^["'"'"']//;s/["'"'"']$//')
            [[ -n "$key" ]] && policy["$key"]="$value"
        done < <(grep -E '^[[:space:]]*REVIEW_' "$default_policy" 2>/dev/null)
    fi

    # 2. Find and load repo-specific policy (exact match or glob)
    local safe_repo_id="${repo_id//\//_}"  # owner/repo -> owner_repo
    local repo_policy="${policy_dir}/${safe_repo_id}.conf"

    if [[ -f "$repo_policy" ]]; then
        # Exact match found
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs | sed 's/^["'"'"']//;s/["'"'"']$//')
            [[ -n "$key" ]] && policy["$key"]="$value"
        done < <(grep -E '^[[:space:]]*REVIEW_' "$repo_policy" 2>/dev/null)
    else
        # Try glob patterns (e.g., myorg_*.conf)
        local owner="${repo_id%%/*}"
        local glob_pattern="${policy_dir}/${owner}_*.conf"
        # shellcheck disable=SC2086
        for glob_file in $glob_pattern; do
            if [[ -f "$glob_file" && "$glob_file" != *"_*.conf" ]]; then
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" == \#* ]] && continue
                    key=$(echo "$key" | xargs)
                    value=$(echo "$value" | xargs | sed 's/^["'"'"']//;s/["'"'"']$//')
                    [[ -n "$key" ]] && policy["$key"]="$value"
                done < <(grep -E '^[[:space:]]*REVIEW_' "$glob_file" 2>/dev/null)
                break  # Use first matching glob
            fi
        done
    fi

    # Output as JSON for easy consumption
    jq -n \
        --arg test_cmd "${policy[REVIEW_TEST_CMD]}" \
        --arg test_timeout "${policy[REVIEW_TEST_TIMEOUT]}" \
        --arg lint_cmd "${policy[REVIEW_LINT_CMD]}" \
        --arg lint_required "${policy[REVIEW_LINT_REQUIRED]}" \
        --arg secret_scan "${policy[REVIEW_SECRET_SCAN]}" \
        --arg secret_patterns "${policy[REVIEW_SECRET_PATTERNS]}" \
        --arg allow_push "${policy[REVIEW_ALLOW_PUSH]}" \
        --arg require_approval "${policy[REVIEW_REQUIRE_APPROVAL]}" \
        --arg base_priority "${policy[REVIEW_BASE_PRIORITY]}" \
        --arg labels_boost "${policy[REVIEW_LABELS_BOOST]}" \
        --arg max_items "${policy[REVIEW_MAX_ITEMS]}" \
        --arg skip_prs "${policy[REVIEW_SKIP_PRS]}" \
        --arg deep_mode "${policy[REVIEW_DEEP_MODE]}" \
        '{
            test_cmd: $test_cmd,
            test_timeout: ($test_timeout | tonumber),
            lint_cmd: $lint_cmd,
            lint_required: ($lint_required == "true"),
            secret_scan: ($secret_scan == "true"),
            secret_patterns: $secret_patterns,
            allow_push: ($allow_push == "true"),
            require_approval: ($require_approval == "true"),
            base_priority: ($base_priority | tonumber),
            labels_boost: $labels_boost,
            max_items: ($max_items | tonumber),
            skip_prs: ($skip_prs == "true"),
            deep_mode: ($deep_mode == "true")
        }'
}

# Apply priority boost from policy to a work item score
# Args: $1 = repo_id, $2 = current_score, $3 = labels (comma-separated)
# Outputs: New score
apply_policy_priority_boost() {
    local repo_id="$1"
    local current_score="$2"
    local labels="$3"

    local policy
    policy=$(load_policy_for_repo "$repo_id")

    # Get base priority boost
    local base_boost
    base_boost=$(echo "$policy" | jq -r '.base_priority // 0')
    current_score=$((current_score + base_boost))

    # Get label boosts (format: "label1:30,label2:20")
    local labels_boost
    labels_boost=$(echo "$policy" | jq -r '.labels_boost // ""')

    if [[ -n "$labels_boost" && -n "$labels" ]]; then
        # Parse label boosts
        IFS=',' read -ra boost_pairs <<< "$labels_boost"
        for pair in "${boost_pairs[@]}"; do
            local label="${pair%%:*}"
            local boost="${pair#*:}"
            # Check if this label is in the item's labels
            if [[ ",$labels," == *",$label,"* ]]; then
                current_score=$((current_score + boost))
            fi
        done
    fi

    echo "$current_score"
}

# Validate a policy file for syntax and value errors
# Args: $1 = path to policy file
# Returns: 0 if valid, 1 if invalid (with error message to stderr)
validate_policy_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "Policy file not found: $file"
        return 1
    fi

    # Check bash syntax (the file should be sourceable)
    if ! bash -n "$file" 2>/dev/null; then
        log_error "Syntax error in policy file: $file"
        return 1
    fi

    # Check for valid variable assignments
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Check for REVIEW_ variable assignments
        if [[ "$line" =~ ^[[:space:]]*REVIEW_ ]]; then
            # Validate it's a proper assignment
            if ! [[ "$line" =~ ^[[:space:]]*REVIEW_[A-Z_]+=.* ]]; then
                log_error "Invalid assignment at line $line_num in $file: $line"
                return 1
            fi

            # Extract key and value for validation
            local key value
            key=$(echo "$line" | sed 's/=.*//' | xargs)
            value=$(echo "$line" | sed 's/^[^=]*=//' | xargs | sed 's/^["'"'"']//;s/["'"'"']$//')

            # Validate numeric fields
            case "$key" in
                REVIEW_TEST_TIMEOUT|REVIEW_BASE_PRIORITY|REVIEW_MAX_ITEMS)
                    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
                        log_error "$key must be numeric at line $line_num in $file"
                        return 1
                    fi
                    ;;
                REVIEW_LINT_REQUIRED|REVIEW_SECRET_SCAN|REVIEW_ALLOW_PUSH|REVIEW_REQUIRE_APPROVAL|REVIEW_SKIP_PRS|REVIEW_DEEP_MODE)
                    if ! [[ "$value" =~ ^(true|false)$ ]]; then
                        log_error "$key must be true or false at line $line_num in $file"
                        return 1
                    fi
                    ;;
            esac
        fi
    done < "$file"

    return 0
}

# Initialize review policies directory with example configuration
init_review_policies() {
    local policy_dir
    policy_dir=$(get_review_policy_dir)

    if [[ ! -d "$policy_dir" ]]; then
        mkdir -p "$policy_dir"
        log_info "Created review policies directory: $policy_dir"
    fi

    # Create example default policy if no config exists
    local default_policy="${policy_dir}/_default.conf"
    local example_policy="${policy_dir}/_default.conf.example"

    if [[ ! -f "$default_policy" && ! -f "$example_policy" ]]; then
        cat > "$example_policy" << 'POLICY_EOF'
# Default Review Policy (rename to _default.conf to activate)
# These settings apply to all repos unless overridden by a repo-specific policy.
#
# To override for a specific repo, create a file named after the repo:
#   owner_reponame.conf (e.g., myorg_backend.conf)
#
# For organization-wide settings, use glob patterns:
#   myorg_*.conf (matches all repos in myorg)

# Test Configuration
# Auto-detect test command if empty (looks for Makefile, package.json, etc.)
REVIEW_TEST_CMD=""
REVIEW_TEST_TIMEOUT=300

# Lint Configuration
REVIEW_LINT_CMD=""
REVIEW_LINT_REQUIRED=false

# Secret Scanning
# Scan for secrets before allowing push
REVIEW_SECRET_SCAN=true
# Additional patterns to detect (regex, pipe-separated)
REVIEW_SECRET_PATTERNS=""

# Push Policy
# Allow pushing changes (false = never push for this repo)
REVIEW_ALLOW_PUSH=true
# Always ask before pushing (even with --apply)
REVIEW_REQUIRE_APPROVAL=false

# Priority Configuration
# Base priority boost for all items from this repo
REVIEW_BASE_PRIORITY=0
# Label-based priority boosts (format: "label:boost,label:boost")
# Example: "urgent:30,security:40,bug:20"
REVIEW_LABELS_BOOST=""

# Review Behavior
# Maximum items to review per session
REVIEW_MAX_ITEMS=20
# Skip pull requests (only review issues)
REVIEW_SKIP_PRS=false
# Deep mode (comprehensive review, slower)
REVIEW_DEEP_MODE=false
# Non-interactive review behavior
REVIEW_NON_INTERACTIVE=false
# auto|skip|fail
REVIEW_NON_INTERACTIVE_POLICY="auto"
POLICY_EOF
        log_info "Created example policy file: $example_policy"
        log_info "Rename to _default.conf to activate default policies"
    fi
}

# Get policy value for a repo
# Args: $1 = repo_id, $2 = policy_key
# Outputs: The value for that key
get_policy_value() {
    local repo_id="$1"
    local key="$2"

    local policy
    policy=$(load_policy_for_repo "$repo_id")
    echo "$policy" | jq -r ".$key // empty"
}

# Check if a repo allows push based on policy
# Args: $1 = repo_id
# Returns: 0 if push allowed, 1 if not
repo_allows_push() {
    local repo_id="$1"
    local policy
    policy=$(load_policy_for_repo "$repo_id")
    local allow_push
    allow_push=$(echo "$policy" | jq -r '.allow_push // true')
    [[ "$allow_push" == "true" ]]
}

# Check if a repo requires approval before push
# Args: $1 = repo_id
# Returns: 0 if approval required, 1 if not
repo_requires_approval() {
    local repo_id="$1"
    local policy
    policy=$(load_policy_for_repo "$repo_id")
    local require_approval
    require_approval=$(echo "$policy" | jq -r '.require_approval // false')
    [[ "$require_approval" == "true" ]]
}

# Parse review-specific arguments
parse_review_args() {
    # Reset review-specific variables
    REVIEW_MODE="plan"           # plan or apply
    REVIEW_DRIVER="auto"         # auto, ntm, or local
    REVIEW_PARALLEL=4            # concurrent sessions
    REVIEW_DRY_RUN="false"       # discovery only
    REVIEW_ANALYTICS="false"     # show analytics dashboard
    REVIEW_BASIC_TUI="false"     # basic gum/ANSI TUI for questions
    # shellcheck disable=SC2034  # Used by later phases
    REVIEW_RESUME="${RESUME:-false}"  # use global --resume flag
    REVIEW_PUSH="false"          # allow pushing (with apply)
    REVIEW_PRIORITY="all"        # min priority threshold
    REVIEW_REPOS_PATTERN=""      # filter repos by pattern
    REVIEW_SKIP_DAYS=7           # skip recently reviewed
    REVIEW_MAX_REPOS=""          # cost budget
    REVIEW_MAX_RUNTIME=""        # time budget (minutes)
    REVIEW_MAX_QUESTIONS=""      # question budget
    REVIEW_INVALIDATE_CACHE=""   # repo ids to invalidate digest cache
    REVIEW_NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
    REVIEW_NON_INTERACTIVE_POLICY="auto"

    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --plan)
                REVIEW_MODE="plan"
                ;;
            --apply)
                REVIEW_MODE="apply"
                ;;
            --analytics)
                REVIEW_ANALYTICS="true"
                ;;
            --basic)
                REVIEW_BASIC_TUI="true"
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
            --resume)
                # shellcheck disable=SC2034  # Used by later phases
                REVIEW_RESUME="true"
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
            --auto-answer=*)
                REVIEW_NON_INTERACTIVE_POLICY="${arg#--auto-answer=}"
                if [[ ! "$REVIEW_NON_INTERACTIVE_POLICY" =~ ^(auto|skip|fail)$ ]]; then
                    log_error "Invalid --auto-answer policy: $REVIEW_NON_INTERACTIVE_POLICY (use auto, skip, or fail)"
                    exit 4
                fi
                ;;
            --invalidate-cache=*)
                REVIEW_INVALIDATE_CACHE="${arg#--invalidate-cache=}"
                REVIEW_INVALIDATE_CACHE="${REVIEW_INVALIDATE_CACHE//,/ }"
                if [[ -z "$REVIEW_INVALIDATE_CACHE" ]]; then
                    log_error "Invalid --invalidate-cache value"
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
# NON-INTERACTIVE MODE (bd-s3iy)
#------------------------------------------------------------------------------

get_skipped_questions_log_file() {
    printf '%s\n' "${RU_STATE_DIR}/skipped-questions-${REVIEW_RUN_ID:-unknown}.jsonl"
}

check_interactive_capability() {
    if [[ ! -t 0 ]]; then
        if [[ "$REVIEW_NON_INTERACTIVE" != "true" ]]; then
            log_warn "No TTY detected, enabling non-interactive review mode"
            REVIEW_NON_INTERACTIVE="true"
        fi
    fi
}

log_skipped_question() {
    local question_info="$1"
    local reason="${2:-skipped}"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    ensure_dir "$(dirname "$log_file")"

    if command -v jq &>/dev/null; then
        local question_json="$question_info"
        if ! echo "$question_info" | jq empty >/dev/null 2>&1; then
            question_json=$(jq -n --arg raw "$question_info" '{raw:$raw}')
        fi

        jq -nc \
            --arg run_id "${REVIEW_RUN_ID:-unknown}" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg reason "$reason" \
            --argjson question "$question_json" \
            '{run_id:$run_id,timestamp:$timestamp,reason:$reason,question:$question}' >> "$log_file"
    else
        local escaped
        escaped=$(json_escape "$question_info")
        printf '{"run_id":"%s","timestamp":"%s","reason":"%s","question_raw":"%s"}\n' \
            "${REVIEW_RUN_ID:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" "$escaped" >> "$log_file"
    fi
}

handle_question_non_interactive() {
    local question_info="$1"
    local session_id="$2"

    local reason recommended
    reason=$(echo "$question_info" | jq -r '.reason // ""' 2>/dev/null || echo "")
    recommended=$(echo "$question_info" | jq -r '.recommended // .context.questions[0].recommended // ""' 2>/dev/null || echo "")

    # External prompts always require a human (credentials, conflicts, etc.)
    if [[ "$reason" == "external_prompt" ]]; then
        log_error "[non-interactive] External prompt requires human input; failing"
        log_skipped_question "$question_info" "external_prompt"
        return 3
    fi

    case "$REVIEW_NON_INTERACTIVE_POLICY" in
        fail)
            log_error "[non-interactive] Question requires human input; failing"
            log_skipped_question "$question_info" "fail"
            return 3
            ;;
        skip)
            log_warn "[non-interactive] Skipping question"
            log_skipped_question "$question_info" "skip"
            driver_send_to_session "$session_id" "skip"
            return 0
            ;;
        auto)
            if [[ "$reason" == "ask_user_question" && -n "$recommended" ]]; then
                log_info "[non-interactive] Auto-selecting: $recommended"
                driver_send_to_session "$session_id" "$recommended"
                return 0
            fi
            log_warn "[non-interactive] No recommended option, skipping"
            log_skipped_question "$question_info" "skip"
            driver_send_to_session "$session_id" "skip"
            return 0
            ;;
        *)
            log_error "[non-interactive] Invalid policy: $REVIEW_NON_INTERACTIVE_POLICY"
            log_skipped_question "$question_info" "fail"
            return 3
            ;;
    esac
}

summarize_non_interactive_questions() {
    local log_file
    log_file=$(get_skipped_questions_log_file)

    if [[ -f "$log_file" ]]; then
        # JSONL format: one entry per line, so wc -l counts entries
        local count
        count=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ') || count=0
        if [[ "$count" -gt 0 ]]; then
            log_warn "Review completed with $count skipped question(s)"
            log_info "Skipped questions logged to: $log_file"
        fi
    fi
}

#------------------------------------------------------------------------------
# STATE PERSISTENCE FUNCTIONS
# Atomic JSON operations with flock-based locking
#------------------------------------------------------------------------------

# File descriptor for state lock (separate from review session lock)
STATE_LOCK_FD=""

# Get path to review state directory
get_review_state_dir() {
    printf '%s\n' "${RU_STATE_DIR}/review"
}

# Acquire exclusive lock on state files
# Returns: 0 on success, 1 on failure
acquire_state_lock() {
    local state_dir
    state_dir=$(get_review_state_dir)
    if ! command -v flock &>/dev/null; then
        log_error "flock is required for state locking"
        return 1
    fi

    if ! ensure_dir "$state_dir"; then
        log_error "Failed to create state directory: $state_dir"
        return 1
    fi
    local lock_file="$state_dir/state.lock"

    # Open fd for locking (avoid eval; quoting is sufficient)
    if ! exec {STATE_LOCK_FD}>"$lock_file"; then
        log_error "Failed to open state lock file: $lock_file"
        return 1
    fi
 

    # Get exclusive lock (blocking)
    if ! flock -x "$STATE_LOCK_FD" 2>/dev/null; then
        log_error "Failed to acquire state lock"
        return 1
    fi
    return 0
}

# Release state lock
release_state_lock() {
    if [[ -n "${STATE_LOCK_FD:-}" ]]; then
        flock -u "$STATE_LOCK_FD" 2>/dev/null || true
        exec {STATE_LOCK_FD}>&- 2>/dev/null || true
        STATE_LOCK_FD=""
    fi
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
    if ! printf '%s' "$content" > "$tmp_file" 2>/dev/null; then
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
    local config_hash
    config_hash=$(get_config_hash)

    local questions_pending=0
    local questions_file
    questions_file=$(get_questions_file)
    if [[ -f "$questions_file" ]] && command -v jq &>/dev/null; then
        questions_pending=$(jq -r 'if type=="array" then length elif has("questions") then (.questions | length) else 0 end' \
            "$questions_file" 2>/dev/null || echo 0)
    fi

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
  "config_hash": "$config_hash",
  "repos_total": $total,
  "repos_completed": $completed_count,
  "repos_pending": $pending_count,
  "questions_pending": $questions_pending,
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
    local worktrees_dir="$RU_STATE_DIR/worktrees"
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
# REPO DIGEST CACHE (bd-5v2n)
#
# Cache repo digests between review runs to avoid repeated "understand codebase".
#------------------------------------------------------------------------------

# Get digest cache directory
get_digest_cache_dir() {
    printf '%s\n' "$RU_STATE_DIR/repo-digests"
}

# Load cached digest into a worktree and append delta since last review
# Args: repo_id, worktree_path
prepare_repo_digest_for_worktree() {
    local repo_id="$1"
    local wt_path="$2"

    local cache_dir digest_cache meta_cache digest_file
    cache_dir=$(get_digest_cache_dir)
    digest_cache="$cache_dir/${repo_id//\//_}.md"
    meta_cache="$cache_dir/${repo_id//\//_}.meta.json"
    digest_file="$wt_path/.ru/repo-digest.md"

    if [[ ! -f "$digest_cache" ]]; then
        log_verbose "No cached digest for $repo_id"
        return 0
    fi

    if ! cp "$digest_cache" "$digest_file" 2>/dev/null; then
        log_warn "Failed to copy digest cache for $repo_id"
        return 1
    fi

    if [[ -f "$meta_cache" ]] && command -v jq &>/dev/null; then
        local last_commit current_commit
        last_commit=$(jq -r '.last_commit // empty' "$meta_cache" 2>/dev/null)
        current_commit=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")

        if [[ -n "$last_commit" && -n "$current_commit" && "$last_commit" != "$current_commit" ]]; then
            local changes files
            changes=$(git -C "$wt_path" log --oneline "${last_commit}..${current_commit}" 2>/dev/null || true)
            if [[ -n "$changes" ]]; then
                files=$(git -C "$wt_path" diff --name-only "${last_commit}..${current_commit}" 2>/dev/null | head -20 || true)
                {
                    printf '\n'
                    printf '%s\n' '## Changes Since Last Review'
                    printf '%s\n' '```'
                    printf '%s\n' "$changes"
                    printf '%s\n' '```'
                    printf '\n'
                    printf '%s\n' '**Files Changed:**'
                    printf '%s\n' "$files"
                } >> "$digest_file"
            fi
        fi
    fi

    log_verbose "Loaded cached digest for $repo_id"
    return 0
}

# Update digest cache from a worktree after successful review
# Args: worktree_path, repo_id
update_digest_cache() {
    local wt_path="$1"
    local repo_id="$2"

    local digest_file="$wt_path/.ru/repo-digest.md"
    if [[ ! -f "$digest_file" ]]; then
        log_warn "No digest found for $repo_id at $digest_file"
        return 1
    fi

    local cache_dir
    cache_dir=$(get_digest_cache_dir)
    ensure_dir "$cache_dir"

    local cache_file="$cache_dir/${repo_id//\//_}.md"
    if ! cp "$digest_file" "$cache_file" 2>/dev/null; then
        log_warn "Failed to update digest cache for $repo_id"
        return 1
    fi

    local current_commit digest_size
    current_commit=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")
    digest_size=$(wc -c < "$digest_file" 2>/dev/null || echo 0)

    local meta_file="$cache_dir/${repo_id//\//_}.meta.json"
    cat > "$meta_file" <<EOF
{
  "last_commit": "$current_commit",
  "last_update": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_id": "${REVIEW_RUN_ID:-unknown}",
  "digest_size": $digest_size
}
EOF

    log_verbose "Updated digest cache for $repo_id"
    return 0
}

# Archive a digest cache entry (non-destructive invalidation)
# Args: repo_id, reason (optional)
invalidate_digest_cache() {
    local repo_id="$1"
    local reason="${2:-manual}"

    local cache_dir digest_cache meta_cache
    cache_dir=$(get_digest_cache_dir)
    digest_cache="$cache_dir/${repo_id//\//_}.md"
    meta_cache="$cache_dir/${repo_id//\//_}.meta.json"

    if [[ ! -f "$digest_cache" && ! -f "$meta_cache" ]]; then
        log_verbose "No digest cache to invalidate for $repo_id"
        return 0
    fi

    local archive_dir ts base
    archive_dir="$cache_dir/archived"
    ensure_dir "$archive_dir"
    ts="$(date -u +%Y%m%d-%H%M%S).$$.$RANDOM"
    base="${repo_id//\//_}"

    [[ -f "$digest_cache" ]] && mv "$digest_cache" "$archive_dir/${base}.${ts}.md" 2>/dev/null || true
    [[ -f "$meta_cache" ]] && mv "$meta_cache" "$archive_dir/${base}.${ts}.meta.json" 2>/dev/null || true

    log_info "Invalidated digest cache for $repo_id ($reason)"
}

# Archive digests older than max_age_days (non-destructive cleanup)
# Args: max_age_days (default: 90)
archive_old_digests() {
    local max_age_days="${1:-90}"
    local cache_dir
    cache_dir=$(get_digest_cache_dir)

    [[ -d "$cache_dir" ]] || return 0

    local archive_dir
    archive_dir="$cache_dir/archived"
    ensure_dir "$archive_dir"

    find "$cache_dir" -maxdepth 1 -name "*.meta.json" -mtime "+$max_age_days" -print0 2>/dev/null | \
        while IFS= read -r -d '' meta_file; do
            local base base_name ts digest_file
            base="${meta_file%.meta.json}"
            base_name=$(basename "$base")
            digest_file="${base}.md"
            ts="$(date -u +%Y%m%d-%H%M%S).$$.$RANDOM"

            [[ -f "$digest_file" ]] && mv "$digest_file" "$archive_dir/${base_name}.${ts}.md" 2>/dev/null || true
            [[ -f "$meta_file" ]] && mv "$meta_file" "$archive_dir/${base_name}.${ts}.meta.json" 2>/dev/null || true
        done
}

# Update digest caches for all worktrees in the current review run
update_repo_digests_from_worktrees() {
    local worktrees_dir mapping_file
    worktrees_dir=$(get_worktrees_dir)
    mapping_file="$worktrees_dir/mapping.json"

    if [[ ! -f "$mapping_file" ]]; then
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available, digest cache update skipped"
        return 0
    fi

    local repo_id wt_path
    while IFS= read -r repo_id; do
        [[ -z "$repo_id" ]] && continue
        wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].path // ""' "$mapping_file")
        [[ -n "$wt_path" ]] && update_digest_cache "$wt_path" "$repo_id"
    done < <(jq -r 'keys[]' "$mapping_file" 2>/dev/null)
}

#------------------------------------------------------------------------------
# REVIEW METRICS & ANALYTICS (bd-mzcq)
# Collect monthly metrics and decision history for review runs.
#------------------------------------------------------------------------------

get_metrics_dir() {
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/metrics"
}

get_metrics_file_for_period() {
    local period="$1"
    echo "$(get_metrics_dir)/${period}.json"
}

get_metrics_file() {
    local period
    period=$(date -u +%Y-%m)
    get_metrics_file_for_period "$period"
}

get_decisions_log_file() {
    echo "$(get_metrics_dir)/decisions.jsonl"
}

record_decision() {
    local repo_id="$1"
    local item_type="$2"
    local number="$3"
    local decision="$4"
    [[ "$number" =~ ^[0-9]+$ ]] || number=0

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; decision history skipped"
        return 1
    fi

    local decisions_log
    decisions_log=$(get_decisions_log_file)
    ensure_dir "$(dirname "$decisions_log")"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -n --arg ts "$ts" --arg repo "$repo_id" --arg type "$item_type" \
        --argjson number "$number" --arg decision "$decision" \
        '{timestamp:$ts,repo:$repo,type:$type,number:$number,decision:$decision}' >> "$decisions_log"
}

init_metrics_file() {
    local metrics_dir metrics_file period
    metrics_dir=$(get_metrics_dir)
    metrics_file=$(get_metrics_file)
    period=$(date -u +%Y-%m)

    ensure_dir "$metrics_dir"

    if [[ -f "$metrics_file" ]]; then
        return 0
    fi

    cat > "$metrics_file" <<EOF
{
  "period": "$period",
  "reviews": {
    "total": 0,
    "repos_reviewed": 0,
    "issues_processed": 0,
    "issues_resolved": 0,
    "questions_asked": 0,
    "questions_answered": 0
  },
  "timing": {
    "total_duration_minutes": 0,
    "avg_per_repo_minutes": 0
  },
  "decisions": {
    "by_type": {}
  }
}
EOF
}

record_decisions_from_plan() {
    local repo_id="$1"
    local plan_file="$2"

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; decision history skipped"
        return 1
    fi

    if [[ ! -f "$plan_file" ]]; then
        return 1
    fi

    jq -c '.items[] | {type, number, decision}' "$plan_file" 2>/dev/null | \
        while IFS= read -r item; do
            local item_type number decision
            item_type=$(echo "$item" | jq -r '.type // empty' 2>/dev/null)
            number=$(echo "$item" | jq -r '.number // 0' 2>/dev/null)
            decision=$(echo "$item" | jq -r '.decision // empty' 2>/dev/null)
            [[ -n "$item_type" && -n "$decision" ]] || continue
            record_decision "$repo_id" "$item_type" "$number" "$decision" || true
        done
}

record_metrics_from_plan() {
    local repo_id="$1"
    local plan_file="$2"
    local duration_seconds="${3:-0}"

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; metrics skipped"
        return 1
    fi

    if [[ ! -f "$plan_file" ]]; then
        return 1
    fi

    init_metrics_file

    local issues_processed issues_resolved questions_total questions_answered
    issues_processed=$(jq -r '[.items[] | select(.type == "issue")] | length' "$plan_file" 2>/dev/null || echo 0)
    issues_resolved=$(jq -r '[.items[] | select(.type == "issue" and .decision == "fix")] | length' "$plan_file" 2>/dev/null || echo 0)
    questions_total=$(jq -r '[.questions // [] | .[]] | length' "$plan_file" 2>/dev/null || echo 0)
    questions_answered=$(jq -r '[.questions // [] | .[] | select(.answered == true)] | length' "$plan_file" 2>/dev/null || echo 0)

    local decision_counts
    decision_counts=$(jq -c '[.items[].decision] | reduce .[] as $d ({}; .[$d] = (.[$d] // 0) + 1)' "$plan_file" 2>/dev/null || echo "{}")

    local duration_minutes
    duration_minutes=$(awk -v s="$duration_seconds" 'BEGIN { if (s ~ /^[0-9]+$/) { printf "%.1f", s/60 } else { printf "%.1f", 0 } }')

    local metrics_file updated
    metrics_file=$(get_metrics_file)

    updated=$(jq \
        --argjson issues_processed "$issues_processed" \
        --argjson issues_resolved "$issues_resolved" \
        --argjson questions_total "$questions_total" \
        --argjson questions_answered "$questions_answered" \
        --argjson duration_minutes "$duration_minutes" \
        --argjson decisions "$decision_counts" \
        '
        .reviews.total += 1
        | .reviews.repos_reviewed += 1
        | .reviews.issues_processed += $issues_processed
        | .reviews.issues_resolved += $issues_resolved
        | .reviews.questions_asked += $questions_total
        | .reviews.questions_answered += $questions_answered
        | .timing.total_duration_minutes += $duration_minutes
        | .timing.avg_per_repo_minutes = (if .reviews.repos_reviewed > 0 then (.timing.total_duration_minutes / .reviews.repos_reviewed) else 0 end)
        | .decisions.by_type = (reduce ($decisions | to_entries[]) as $e (.decisions.by_type;
            .[$e.key] = (.[$e.key] // 0) + $e.value))
        ' "$metrics_file" 2>/dev/null) || return 1

    with_state_lock write_json_atomic "$metrics_file" "$updated"
}

suggest_decision() {
    local repo_id="$1"
    local item_type="$2"
    local decisions_log
    decisions_log=$(get_decisions_log_file)

    if [[ ! -f "$decisions_log" ]] || ! command -v jq &>/dev/null; then
        return 1
    fi

    jq -s --arg repo "$repo_id" --arg type "$item_type" '
        map(select(.repo == $repo and .type == $type))
        | group_by(.decision)
        | map({decision: .[0].decision, count: length})
        | sort_by(-.count)
        | .[0].decision // empty
    ' "$decisions_log" 2>/dev/null
}

cmd_review_analytics() {
    local period
    period=$(date -u +%Y-%m)
    local metrics_file
    metrics_file=$(get_metrics_file_for_period "$period")

    if [[ ! -f "$metrics_file" ]]; then
        log_warn "No metrics found for period $period"
        return 0
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat "$metrics_file"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for analytics"
        return 3
    fi

    local total repos issues_processed issues_resolved q_asked q_answered total_minutes avg_minutes
    total=$(jq -r '.reviews.total // 0' "$metrics_file")
    repos=$(jq -r '.reviews.repos_reviewed // 0' "$metrics_file")
    issues_processed=$(jq -r '.reviews.issues_processed // 0' "$metrics_file")
    issues_resolved=$(jq -r '.reviews.issues_resolved // 0' "$metrics_file")
    q_asked=$(jq -r '.reviews.questions_asked // 0' "$metrics_file")
    q_answered=$(jq -r '.reviews.questions_answered // 0' "$metrics_file")
    total_minutes=$(jq -r '.timing.total_duration_minutes // 0' "$metrics_file")
    avg_minutes=$(jq -r '.timing.avg_per_repo_minutes // 0' "$metrics_file")

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        gum style --border rounded --padding "0 2" --border-foreground "#89b4fa" \
            "$(gum style --bold "Review Analytics (${period})")" >&2
        gum style "Total reviews: $total" >&2
        gum style "Repos reviewed: $repos" >&2
        gum style "Issues processed: $issues_processed (resolved: $issues_resolved)" >&2
        gum style "Questions: $q_answered/$q_asked answered" >&2
        gum style "Total minutes: $total_minutes (avg/repo: $avg_minutes)" >&2
    else
        printf '%b\n' "${BOLD}Review Analytics (${period})${RESET}" >&2
        printf '%b\n' "Total reviews: $total" >&2
        printf '%b\n' "Repos reviewed: $repos" >&2
        printf '%b\n' "Issues processed: $issues_processed (resolved: $issues_resolved)" >&2
        printf '%b\n' "Questions: $q_answered/$q_asked answered" >&2
        printf '%b\n' "Total minutes: $total_minutes (avg/repo: $avg_minutes)" >&2
    fi

    local decisions_log
    decisions_log=$(get_decisions_log_file)
    if [[ -f "$decisions_log" ]]; then
        local top_repos
        top_repos=$(jq -s '
            group_by(.repo)
            | map({repo: .[0].repo, count: length})
            | sort_by(-.count)
            | .[0:5]
        ' "$decisions_log" 2>/dev/null)

        if [[ -n "$top_repos" && "$top_repos" != "null" ]]; then
            printf '\n%b\n' "${BOLD}Top repos by activity:${RESET}" >&2
            echo "$top_repos" | jq -r '.[] | "  \(.repo): \(.count)"' >&2
        fi
    fi
}

#------------------------------------------------------------------------------
# GIT WORKTREE PREPARATION (bd-zlws)
#
# Creates isolated git worktrees for each repo being reviewed, so AI agents
# can make changes without affecting the main working directory.
#------------------------------------------------------------------------------

# Get the worktrees directory for current review run
get_worktrees_dir() {
    printf '%s\n' "${RU_STATE_DIR}/worktrees/${REVIEW_RUN_ID:-unknown}"
}

# Check if a repository is clean (no uncommitted changes)
# Args: repo_path
# Returns: 0 if clean, 1 if dirty or not a git repo
ensure_clean_or_fail() {
    local repo_path="$1"

    if ! is_git_repo "$repo_path"; then
        log_error "$repo_path is not a git repository"
        return 1
    fi

    local status
    status=$(git -C "$repo_path" status --porcelain 2>/dev/null)

    if [[ -n "$status" ]]; then
        log_error "Repository has uncommitted changes: $repo_path"
        log_error "Please commit or stash changes before running review"
        return 1
    fi

    return 0
}

# Record worktree mapping to JSON file
# Args: repo_id, worktree_path, branch_name
record_worktree_mapping() {
    local repo_id="$1"
    local wt_path="$2"
    local wt_branch="$3"

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    ensure_dir "$worktrees_dir"

    local mapping_file="$worktrees_dir/mapping.json"

    # Initialize if doesn't exist
    [[ ! -f "$mapping_file" ]] && echo '{}' > "$mapping_file"

    # Add mapping atomically (requires jq)
    if command -v jq &>/dev/null; then
        local tmp_file="${mapping_file}.tmp.$$"
        if jq --arg repo "$repo_id" \
              --arg path "$wt_path" \
              --arg branch "$wt_branch" \
              --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '.[$repo] = {"path": $path, "branch": $branch, "created_at": $created}' \
              "$mapping_file" > "$tmp_file"; then
            mv "$tmp_file" "$mapping_file"
        else
            log_error "Failed to update worktree mapping for $repo_id"
            rm -f "$tmp_file"
            return 1
        fi
    else
        log_warn "jq not available, worktree mapping not recorded"
    fi
}

# Get worktree path for a repo
# Args: repo_id, nameref for path output
# Returns: 0 if found, 1 if not found
get_worktree_path() {
    local repo_id="$1"
    local -n _wt_path_ref=$2

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    local mapping_file="$worktrees_dir/mapping.json"

    if [[ ! -f "$mapping_file" ]]; then
        _wt_path_ref=""
        return 1
    fi

    if command -v jq &>/dev/null; then
        _wt_path_ref=$(jq -r --arg repo "$repo_id" '.[$repo].path // ""' "$mapping_file")
        [[ -n "$_wt_path_ref" ]] && return 0
    fi

    return 1
}

# Get worktree mapping from work item info
# Args: work_item (pipe-separated), nameref for repo_id, nameref for worktree_path
get_worktree_mapping() {
    local work_item="$1"
    local -n _repo_id_ref=$2
    local -n _wt_path_out=$3

    # Extract repo_id from work item (first field before |)
    _repo_id_ref="${work_item%%|*}"

    get_worktree_path "$_repo_id_ref" _wt_path_out
}

# Prepare worktrees for review
# Args: work_items array (pipe-separated format: repo_id|type|number|...)
# Sets: REVIEW_WORKTREES associative array mapping repo_id -> worktree_path
prepare_review_worktrees() {
    local -a items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        log_verbose "No work items to prepare worktrees for"
        return 0
    fi

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    ensure_dir "$worktrees_dir"

    # Track unique repos (multiple issues/PRs may be in same repo)
    local -A seen_repos=()
    local prepared=0
    local skipped=0
    local failed=0

    for item in "${items[@]}"; do
        local repo_id
        repo_id="${item%%|*}"

        # Skip if already processed
        [[ -n "${seen_repos[$repo_id]:-}" ]] && continue
        seen_repos["$repo_id"]=1

        # Resolve repo spec to get local path
        # shellcheck disable=SC2034  # resolved_repo_id used by resolve_repo_spec
        local url branch custom_name local_path resolved_repo_id
        if ! resolve_repo_spec "$repo_id" "$PROJECTS_DIR" "$LAYOUT" \
                url branch custom_name local_path resolved_repo_id 2>/dev/null; then
            log_warn "Could not resolve repo: $repo_id"
            ((failed++))
            continue
        fi

        # Check if repo exists locally
        if [[ ! -d "$local_path" ]]; then
            log_warn "Repo not cloned locally, skipping: $repo_id ($local_path)"
            ((skipped++))
            continue
        fi

        # Verify it's a git repo
        if ! is_git_repo "$local_path"; then
            log_warn "Not a git repository, skipping: $local_path"
            ((skipped++))
            continue
        fi

        # CRITICAL: Refuse to run on dirty trees
        if ! ensure_clean_or_fail "$local_path"; then
            ((failed++))
            continue
        fi

        # Create worktree path (sanitize repo_id for filesystem)
        local safe_repo_id="${repo_id//\//_}"
        local wt_path="$worktrees_dir/$safe_repo_id"
        local wt_branch="ru/review/${REVIEW_RUN_ID:-unknown}/${repo_id//\//-}"

        # Fetch latest from remote (quiet, ignore failures)
        git -C "$local_path" fetch --quiet 2>/dev/null || true

        # Determine base reference (respect branch pins)
        local base_ref="${branch:-HEAD}"

        # Check if worktree already exists
        if [[ -d "$wt_path" ]]; then
            log_warn "Worktree already exists, reusing: $wt_path"
        else
            # Create worktree with new branch
            if ! git -C "$local_path" worktree add -b "$wt_branch" "$wt_path" "$base_ref" >/dev/null 2>&1; then
                # Branch may already exist from previous run, try without -b
                if ! git -C "$local_path" worktree add "$wt_path" "$base_ref" >/dev/null 2>&1; then
                    log_error "Failed to create worktree for $repo_id"
                    ((failed++))
                    continue
                fi
            fi
        fi

        # Create .ru directory for artifacts
        ensure_dir "$wt_path/.ru"

        # Load cached digest (if available) and append delta info
        prepare_repo_digest_for_worktree "$repo_id" "$wt_path" || true

        # Record mapping for later phases
        if ! record_worktree_mapping "$repo_id" "$wt_path" "$wt_branch"; then
            log_warn "Worktree created but mapping failed for $repo_id"
            # Continue anyway - worktree is usable, just not tracked
        fi

        log_verbose "Created worktree: $repo_id → $wt_path"
        ((prepared++))
    done

    log_info "Worktrees: $prepared prepared, $skipped skipped, $failed failed"

    [[ $failed -gt 0 ]] && return 1
    return 0
}

# Clean up review worktrees
# Args: run_id (optional, defaults to REVIEW_RUN_ID)
cleanup_review_worktrees() {
    local run_id="${1:-${REVIEW_RUN_ID:-}}"

    if [[ -z "$run_id" ]]; then
        log_error "No run ID specified for cleanup"
        return 1
    fi

    local base="${RU_STATE_DIR}/worktrees/$run_id"

    [[ ! -d "$base" ]] && return 0

    local mapping_file="$base/mapping.json"
    local removed=0

    if [[ -f "$mapping_file" ]] && command -v jq &>/dev/null; then
        # Remove each worktree properly
        while IFS= read -r repo_id; do
            [[ -z "$repo_id" ]] && continue

            local wt_path wt_branch
            wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].path // ""' "$mapping_file")
            wt_branch=$(jq -r --arg repo "$repo_id" '.[$repo].branch // ""' "$mapping_file")

            if [[ -d "$wt_path" ]]; then
                # Try to find main repo from worktree
                local main_repo
                main_repo=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's/\.git$//')

                if [[ -n "$main_repo" ]] && [[ -d "$main_repo" ]]; then
                    # Use git worktree remove for clean removal
                    if git -C "$main_repo" worktree remove --force "$wt_path" 2>/dev/null; then
                        log_verbose "Removed worktree: $wt_path"
                        ((removed++))

                        # Also try to delete the branch
                        if [[ -n "$wt_branch" ]]; then
                            git -C "$main_repo" branch -D "$wt_branch" 2>/dev/null || true
                        fi
                    else
                        # Fall back to direct removal
                        rm -rf "$wt_path"
                        log_verbose "Force removed worktree: $wt_path"
                        ((removed++))
                    fi
                else
                    # Can't find main repo, just remove directory
                    rm -rf "$wt_path"
                    log_verbose "Removed orphan worktree: $wt_path"
                    ((removed++))
                fi
            fi
        done < <(jq -r 'keys[]' "$mapping_file" 2>/dev/null)
    fi

    # Remove the run directory
    rm -rf "$base"

    log_info "Cleanup: $removed worktrees removed"
    return 0
}

# List all worktrees for a run
# Args: run_id (optional)
# Output: JSON array of worktree info
list_review_worktrees() {
    local run_id="${1:-${REVIEW_RUN_ID:-}}"
    local base="${RU_STATE_DIR}/worktrees/$run_id"
    local mapping_file="$base/mapping.json"

    if [[ -f "$mapping_file" ]]; then
        cat "$mapping_file"
    else
        echo '{}'
    fi
}

# Check if a worktree exists and is valid
# Args: repo_id
# Returns: 0 if valid, 1 if not
worktree_exists() {
    local repo_id="$1"
    local wt_path

    if get_worktree_path "$repo_id" wt_path; then
        [[ -d "$wt_path" ]] && [[ -d "$wt_path/.git" || -f "$wt_path/.git" ]]
        return $?
    fi

    return 1
}

#------------------------------------------------------------------------------
# GRAPHQL BATCHED REPOSITORY DISCOVERY (bd-ff8h)
#
# Efficiently discovers open issues and PRs across all configured repos
# using GraphQL alias batching (up to 25 repos per API call).
#------------------------------------------------------------------------------

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
        local safe_owner safe_name
        safe_owner=$(json_escape "$owner")
        safe_name=$(json_escape "$name")

        # Build aliased query for this repo
        q+=" repo${i}: repository(owner:\"${safe_owner}\", name:\"${safe_name}\") {"
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
    retry_with_backoff --capture=stdout 3 1 -- gh api graphql -f query="$q"
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

#------------------------------------------------------------------------------
# WORK ITEM PRIORITY SCORING (bd-5jph)
# Calculate priority scores for issues/PRs to enable intelligent work ordering
#------------------------------------------------------------------------------

# Calculate days since a timestamp
# Works on both Linux and macOS
# Args: ISO8601 timestamp
# Output: integer days
days_since_timestamp() {
    local ts="$1"
    local now
    now=$(date +%s)

    local then_ts
    # Try GNU date first (Linux)
    if then_ts=$(date -d "$ts" +%s 2>/dev/null); then
        :
    # Try BSD date (macOS)
    elif then_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null); then
        :
    # Try with timezone offset format
    elif then_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${ts/Z/+0000}" +%s 2>/dev/null); then
        :
    else
        # Fallback: return 0 days if parsing fails
        echo "0"
        return
    fi

    echo $(( (now - then_ts) / 86400 ))
}

# Check if an item was recently reviewed
# Args: item_key (format: owner/repo#type-number)
# Returns: 0 if recently reviewed, 1 if not
item_recently_reviewed() {
    local item_key="$1"
    local state_file="$RU_STATE_DIR/review-state.json"
    local skip_days="${REVIEW_SKIP_DAYS:-7}"

    [[ ! -f "$state_file" ]] && return 1

    local last_review
    last_review=$(jq -r --arg key "$item_key" '.items[$key].last_review // ""' "$state_file" 2>/dev/null)

    [[ -z "$last_review" ]] && return 1

    local days_since
    days_since=$(days_since_timestamp "$last_review")

    [[ $days_since -lt $skip_days ]]
}

# Calculate priority score for a work item (0-200+ scale)
# Args: type labels created_at updated_at is_draft repo_id number
# Output: integer score
calculate_item_priority_score() {
    local item_type="$1"
    local labels="$2"
    local created_at="$3"
    local updated_at="$4"
    local is_draft="$5"
    local repo_id="$6"
    local number="$7"

    local score=0

    # Component 1: Type Importance (0-20 points)
    if [[ "$item_type" == "pr" ]]; then
        score=$((score + 20))
        # Draft PRs get penalized
        [[ "$is_draft" == "true" ]] && score=$((score - 15))
    else
        # Issues get base score
        score=$((score + 10))
    fi

    # Component 2: Label-Based Priority (0-50 points)
    if echo "$labels" | grep -qiE 'security|critical'; then
        score=$((score + 50))
    elif echo "$labels" | grep -qiE 'bug|urgent'; then
        score=$((score + 30))
    elif echo "$labels" | grep -qiE 'enhancement|feature'; then
        score=$((score + 10))
    fi

    # Component 3: Age Factor
    local age_days
    age_days=$(days_since_timestamp "$created_at")

    # Bug/security items: older = more urgent
    if echo "$labels" | grep -qiE 'bug|security|critical'; then
        if [[ $age_days -gt 60 ]]; then
            score=$((score + 50))
        elif [[ $age_days -gt 30 ]]; then
            score=$((score + 30))
        elif [[ $age_days -gt 14 ]]; then
            score=$((score + 15))
        fi
    else
        # Feature requests: very old ones may be stale
        if [[ $age_days -gt 180 ]]; then
            score=$((score - 10))
        fi
    fi

    # Component 4: Recency Bonus (0-15 points)
    local updated_days
    updated_days=$(days_since_timestamp "$updated_at")
    if [[ $updated_days -lt 3 ]]; then
        score=$((score + 15))
    elif [[ $updated_days -lt 7 ]]; then
        score=$((score + 10))
    fi

    # Component 5: Staleness Penalty (-20 points)
    local item_key="${repo_id}#${item_type}-${number}"
    if item_recently_reviewed "$item_key"; then
        score=$((score - 20))
    fi

    # Ensure non-negative
    [[ $score -lt 0 ]] && score=0

    echo "$score"
}

# Map numeric score to priority level
# Args: score
# Output: CRITICAL, HIGH, NORMAL, or LOW
get_priority_level() {
    local score="$1"
    if [[ $score -ge 150 ]]; then
        echo "CRITICAL"
    elif [[ $score -ge 100 ]]; then
        echo "HIGH"
    elif [[ $score -ge 50 ]]; then
        echo "NORMAL"
    else
        echo "LOW"
    fi
}

# Check if priority level passes threshold filter
# Args: level threshold
# Returns: 0 if passes, 1 if filtered out
passes_priority_threshold() {
    local level="$1"
    local threshold="$2"

    case "$threshold" in
        all)
            return 0
            ;;
        normal)
            [[ "$level" != "LOW" ]]
            ;;
        high)
            [[ "$level" == "HIGH" || "$level" == "CRITICAL" ]]
            ;;
        critical)
            [[ "$level" == "CRITICAL" ]]
            ;;
        *)
            return 0  # Default: pass through
            ;;
    esac
}

# Score and sort work items by priority
# Args: TSV input (from parse_graphql_work_items)
# Output: TSV with score prepended, sorted by score descending
score_and_sort_work_items() {
    local tsv_input="$1"
    local threshold="${2:-all}"

    while IFS=$'\t' read -r repo_id item_type number title labels created_at updated_at is_draft; do
        [[ -z "$repo_id" ]] && continue

        local score
        score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")

        local level
        level=$(get_priority_level "$score")

        # Apply threshold filter
        if passes_priority_threshold "$level" "$threshold"; then
            printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$score" "$level" "$repo_id" "$item_type" "$number" "$title" "$labels" "$created_at" "$updated_at" "$is_draft"
        fi
    done <<< "$tsv_input" | sort -t$'\t' -k1 -rn
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
        # If repo_id matches owner/repo (2 parts), it's implicitly GitHub (from resolve_repo_spec logic)
        # If it matches github.com/owner/repo, it's explicit
        if [[ "$repo_id" =~ ^([^/]+)/([^/]+)$ ]]; then
             echo "$repo_id"
        elif [[ "$repo_id" =~ ^github\.com/([^/]+)/([^/]+)$ ]]; then
             echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
    fi
}

# Discover work items from GitHub using GraphQL batching
# Args: result_array_name, priority_filter, max_repos, allowed_repo_ids(optional)
discover_work_items() {
    local -n _items_ref=$1
    # shellcheck disable=SC2034  # Used in bd-5jph (priority scoring)
    local priority_filter="$2"
    local max_repos="$3"
    local allowed_repos="${4:-}"

    local -A allowed_repo_map=()
    if [[ -n "$allowed_repos" ]]; then
        local allowed_repo
        for allowed_repo in $allowed_repos; do
            allowed_repo_map["$allowed_repo"]=1
        done
    fi

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
            if [[ ${#allowed_repo_map[@]} -gt 0 && -z "${allowed_repo_map[$github_id]:-}" ]]; then
                continue
            fi
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
        # Sanitize fields that might contain pipes
        title="${title//|/ }"
        labels="${labels//|/ }"
        # Convert TSV to pipe-separated for easier parsing later
        _items_ref+=("${repo_id}|${item_type}|${number}|${title}|${labels}|${created_at}|${updated_at}|${is_draft}")
    done <<< "$all_work_items"

    # Apply max_repos limit if specified
    if [[ -n "$max_repos" ]] && [[ ${#_items_ref[@]} -gt $max_repos ]]; then
        _items_ref=("${_items_ref[@]:0:$max_repos}")
    fi

    log_verbose "Discovered ${#_items_ref[@]} work item(s)"
}

#------------------------------------------------------------------------------
# DISCOVERY SUMMARY DISPLAY (bd-73ys)
# Format and display discovered work items in a user-friendly summary
#------------------------------------------------------------------------------

# Format a priority level with color (ANSI or plain)
# Args: level (CRITICAL/HIGH/NORMAL/LOW)
# Output: Formatted string
format_priority_badge() {
    local level="$1"
    local use_color="${2:-true}"

    if [[ "$use_color" != "true" ]]; then
        echo "[$level]"
        return
    fi

    # ANSI color codes
    local RED="\033[31m"
    local ORANGE="\033[33m"
    local YELLOW="\033[93m"
    local GRAY="\033[90m"
    local RESET="\033[0m"
    local BOLD="\033[1m"

    case "$level" in
        CRITICAL) echo -e "${BOLD}${RED}[CRITICAL]${RESET}" ;;
        HIGH)     echo -e "${ORANGE}[HIGH]${RESET}" ;;
        NORMAL)   echo -e "${YELLOW}[NORMAL]${RESET}" ;;
        LOW)      echo -e "${GRAY}[LOW]${RESET}" ;;
        *)        echo "[$level]" ;;
    esac
}

# Show discovery summary using ANSI formatting
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_ansi() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local -n _items_ansi=$9

    local BOLD="\033[1m"
    local RED="\033[31m"
    local ORANGE="\033[33m"
    local YELLOW="\033[93m"
    local GRAY="\033[90m"
    local CYAN="\033[36m"
    local RESET="\033[0m"

    echo "" >&2
    echo -e "${BOLD}━━━ Discovery Summary ━━━${RESET}" >&2
    echo "" >&2
    echo -e "Total work items: ${BOLD}$total${RESET}" >&2
    echo -e "  Issues: ${CYAN}$issues${RESET} | PRs: ${CYAN}$prs${RESET}" >&2
    echo "" >&2
    echo -e "${BOLD}By priority:${RESET}" >&2
    [[ $critical -gt 0 ]] && echo -e "  ${RED}CRITICAL: $critical${RESET}" >&2
    [[ $high -gt 0 ]] && echo -e "  ${ORANGE}HIGH: $high${RESET}" >&2
    [[ $normal -gt 0 ]] && echo -e "  ${YELLOW}NORMAL: $normal${RESET}" >&2
    [[ $low -gt 0 ]] && echo -e "  ${GRAY}LOW: $low${RESET}" >&2
    echo "" >&2

    if [[ ${#_items_ansi[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_items_ansi[@]} ]] && display_count=${#_items_ansi[@]}

        echo -e "${BOLD}Top $display_count items to review:${RESET}" >&2
        local i=0
        for item in "${_items_ansi[@]:0:$display_count}"; do
            ((i++))
            IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"

            # Calculate score and level for display
            local score level
            score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
            level=$(get_priority_level "$score")
            local badge
            badge=$(format_priority_badge "$level" "true")

            # Truncate title if too long
            local short_title="${title:0:45}"
            [[ ${#title} -gt 45 ]] && short_title="${short_title}..."

            echo -e "  $i. $badge ${CYAN}${repo_id}${RESET}#${number}: $short_title" >&2
        done
        echo "" >&2
    fi
}

# Show discovery summary using gum (if available)
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_gum() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local -n _items_gum=$9

    # Header
    gum style --border rounded --padding "0 2" --border-foreground "#fab387" \
        "$(gum style --bold 'Discovery Summary')" >&2

    echo "" >&2
    gum style "Total work items: $total" >&2
    gum style "  Issues: $issues | PRs: $prs" >&2
    echo "" >&2

    # Priority breakdown with colors
    gum style --bold "By priority:" >&2
    [[ $critical -gt 0 ]] && gum style --foreground "#f38ba8" "  CRITICAL: $critical" >&2
    [[ $high -gt 0 ]] && gum style --foreground "#fab387" "  HIGH: $high" >&2
    [[ $normal -gt 0 ]] && gum style --foreground "#f9e2af" "  NORMAL: $normal" >&2
    [[ $low -gt 0 ]] && gum style --foreground "#6c7086" "  LOW: $low" >&2
    echo "" >&2

    if [[ ${#_items_gum[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_items_gum[@]} ]] && display_count=${#_items_gum[@]}

        gum style --bold "Top $display_count items to review:" >&2
        local i=0
        for item in "${_items_gum[@]:0:$display_count}"; do
            ((i++))
            IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"

            local score level badge_color
            score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
            level=$(get_priority_level "$score")

            case "$level" in
                CRITICAL) badge_color="#f38ba8" ;;
                HIGH) badge_color="#fab387" ;;
                NORMAL) badge_color="#f9e2af" ;;
                *) badge_color="#6c7086" ;;
            esac

            local short_title="${title:0:45}"
            [[ ${#title} -gt 45 ]] && short_title="${short_title}..."

            echo -n "  $i. " >&2
            gum style --foreground "$badge_color" --inline "[$level]" >&2
            echo " ${repo_id}#${number}: $short_title" >&2
        done
        echo "" >&2
    fi
}

# Show discovery summary as JSON (for automation)
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_json() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local -n _items_json=$9

    local items_json="[]"

    if [[ ${#_items_json[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_items_json[@]} ]] && display_count=${#_items_json[@]}

        local item_list=""
        for item in "${_items_json[@]:0:$display_count}"; do
            IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"

            local score level
            score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
            level=$(get_priority_level "$score")

            # Escape title for JSON (use --arg to avoid trailing newline from echo)
            local escaped_title
            escaped_title=$(jq -n --arg t "$title" '$t')

            [[ -n "$item_list" ]] && item_list+=","
            item_list+="{\"repo\":\"$repo_id\",\"type\":\"$item_type\",\"number\":$number,\"title\":$escaped_title,\"score\":$score,\"level\":\"$level\"}"
        done
        items_json="[$item_list]"
    fi

    cat <<EOF
{
  "total": $total,
  "by_type": {"issues": $issues, "prs": $prs},
  "by_priority": {"critical": $critical, "high": $high, "normal": $normal, "low": $low},
  "top_items": $items_json
}
EOF
}

# Main discovery summary function
# Args: work_items (pipe-separated strings)
show_discovery_summary() {
    local items=("$@")
    local max_display="${REVIEW_PARALLEL:-5}"

    if [[ ${#items[@]} -eq 0 ]]; then
        log_info "No work items to review"
        return
    fi

    # Count totals and priority breakdown
    local total=${#items[@]}
    local critical=0 high=0 normal=0 low=0
    local issues=0 prs=0

    for item in "${items[@]}"; do
        IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"

        # Count by type
        case "$item_type" in
            issue) ((issues++)) ;;
            pr) ((prs++)) ;;
        esac

        # Calculate score and count by priority level
        local score level
        score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
        level=$(get_priority_level "$score")

        case "$level" in
            CRITICAL) ((critical++)) ;;
            HIGH) ((high++)) ;;
            NORMAL) ((normal++)) ;;
            LOW) ((low++)) ;;
        esac
    done

    # Display based on output mode
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        show_discovery_summary_json "$total" "$issues" "$prs" "$critical" "$high" "$normal" "$low" "$max_display" items
    elif [[ "$GUM_AVAILABLE" == "true" ]] && [[ -t 2 ]]; then
        show_discovery_summary_gum "$total" "$issues" "$prs" "$critical" "$high" "$normal" "$low" "$max_display" items
    else
        show_discovery_summary_ansi "$total" "$issues" "$prs" "$critical" "$high" "$normal" "$low" "$max_display" items
    fi
}

#------------------------------------------------------------------------------
# REVIEW JSON OUTPUT HELPERS (bd-xcj6)
#------------------------------------------------------------------------------

# Count configured GitHub repos (for discovery summary)
count_github_repos() {
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local github_id
        github_id=$(repo_spec_to_github_id "$line")
        [[ -n "$github_id" ]] && ((count++))
    done < <(get_all_repos)
    echo "$count"
}

# Build JSON array of items
# Args: work_items (pipe-separated strings)
build_review_items_json() {
    local items=("$@")
    local item_list=""

    for item in "${items[@]}"; do
        IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"
        [[ -z "$repo_id" ]] && continue

        local score level number_json labels_json
        score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
        level=$(get_priority_level "$score")

        number_json="$number"
        [[ "$number_json" =~ ^[0-9]+$ ]] || number_json=0

        labels_json="[]"
        if [[ -n "$labels" ]]; then
            labels_json=$(printf '%s\n' "$labels" | tr ',' '\n' | jq -R . | jq -s .)
        fi

        local item_json
        item_json=$(jq -n \
            --arg repo "$repo_id" \
            --arg type "$item_type" \
            --argjson number "$number_json" \
            --arg title "$title" \
            --arg priority "$level" \
            --argjson score "$score" \
            --argjson labels "$labels_json" \
            --arg created_at "$created_at" \
            --arg updated_at "$updated_at" \
            '{repo:$repo,type:$type,number:$number,title:$title,priority:$priority,score:$score,labels:$labels,created_at:$created_at,updated_at:$updated_at}')

        [[ -n "$item_list" ]] && item_list+=","
        item_list+="$item_json"
    done

    echo "[${item_list}]"
}

# Build discovery summary JSON
# Args: repos_scanned, work_items (pipe-separated strings)
build_review_summary_json() {
    local repos_scanned="$1"
    shift
    local items=("$@")

    local issues=0 prs=0 critical=0 high=0 normal=0 low=0
    local -A unique_repos=()

    for item in "${items[@]}"; do
        IFS="|" read -r repo_id item_type number title labels created_at updated_at is_draft <<< "$item"
        [[ -z "$repo_id" ]] && continue
        unique_repos["$repo_id"]=1

        case "$item_type" in
            issue) ((issues++)) ;;
            pr) ((prs++)) ;;
        esac

        local score level
        score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft" "$repo_id" "$number")
        level=$(get_priority_level "$score")

        case "$level" in
            CRITICAL) ((critical++)) ;;
            HIGH) ((high++)) ;;
            NORMAL) ((normal++)) ;;
            LOW) ((low++)) ;;
        esac
    done

    local items_found=${#items[@]}
    local repos_found=${#unique_repos[@]}
    local repos_scanned_num="$repos_scanned"
    [[ "$repos_scanned_num" =~ ^[0-9]+$ ]] || repos_scanned_num="$repos_found"
    if [[ "$repos_scanned_num" -eq 0 ]]; then
        repos_scanned_num="$repos_found"
    fi

    jq -n \
        --argjson repos_scanned "$repos_scanned_num" \
        --argjson items_found "$items_found" \
        --argjson critical "$critical" \
        --argjson high "$high" \
        --argjson normal "$normal" \
        --argjson low "$low" \
        --argjson issues "$issues" \
        --argjson prs "$prs" \
        '{repos_scanned:$repos_scanned,items_found:$items_found,by_priority:{critical:$critical,high:$high,normal:$normal,low:$low},by_type:{issues:$issues,prs:$prs}}'
}

# Build discovery JSON output
# Args: run_id, repos_scanned, work_items (pipe-separated strings)
build_review_discovery_json() {
    local run_id="$1"
    local repos_scanned="$2"
    shift 2
    local items=("$@")

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local summary_json
    summary_json=$(build_review_summary_json "$repos_scanned" "${items[@]}")

    local items_json
    items_json=$(build_review_items_json "${items[@]}")

    jq -n \
        --arg command "review" \
        --arg mode "discovery" \
        --arg run_id "$run_id" \
        --arg timestamp "$timestamp" \
        --argjson summary "$summary_json" \
        --argjson items "$items_json" \
        '{command:$command,mode:$mode,run_id:$run_id,timestamp:$timestamp,summary:$summary,items:$items}'
}

# Build completion JSON output
# Args: run_id, mode, start_epoch, exit_code, work_items...
build_review_completion_json() {
    local run_id="$1"
    local mode="$2"
    local start_epoch="$3"
    local exit_code="$4"
    shift 4
    local items=("$@")

    local end_epoch duration_seconds
    end_epoch=$(date +%s)
    duration_seconds=0
    if [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
        duration_seconds=$((end_epoch - start_epoch))
    fi

    local -A unique_repos=()
    local item
    for item in "${items[@]}"; do
        IFS="|" read -r repo_id _ _ _ _ _ _ _ <<< "$item"
        [[ -n "$repo_id" ]] && unique_repos["$repo_id"]=1
    done

    local repos_reviewed=${#unique_repos[@]}
    local items_processed=${#items[@]}

    local summary_json
    summary_json=$(jq -n \
        --argjson repos_reviewed "$repos_reviewed" \
        --argjson items_processed "$items_processed" \
        --argjson items_fixed 0 \
        --argjson items_skipped 0 \
        --argjson items_needs_info 0 \
        --argjson commits_created 0 \
        --argjson questions_asked 0 \
        --argjson duration_seconds "$duration_seconds" \
        '{repos_reviewed:$repos_reviewed,items_processed:$items_processed,items_fixed:$items_fixed,items_skipped:$items_skipped,items_needs_info:$items_needs_info,commits_created:$commits_created,questions_asked:$questions_asked,duration_seconds:$duration_seconds}')

    jq -n \
        --arg command "review" \
        --arg mode "$mode" \
        --arg run_id "$run_id" \
        --arg status "complete" \
        --argjson exit_code "$exit_code" \
        --argjson summary "$summary_json" \
        '{command:$command,mode:$mode,run_id:$run_id,status:$status,exit_code:$exit_code,summary:$summary,repos:{}}'
}

#------------------------------------------------------------------------------
# REVIEW EXIT CODES + ERROR CLASSIFICATION (bd-jen3)
#
# Review uses ru's standard exit codes:
#   0 success
#   1 partial failure
#   2 conflicts / manual intervention required
#   3 dependency/system error
#   4 invalid arguments
#   5 interrupted (resume supported by checkpoint bead)
#------------------------------------------------------------------------------

classify_review_error() {
    local error_type="${1:-}"
    local context="${2:-}"

    case "$error_type" in
        session_failed|rate_limited|network_error)
            echo "partial"
            ;;
        merge_conflict|quality_gate_failed|tests_failed)
            echo "conflict"
            ;;
        missing_dependency|auth_failed|no_driver)
            echo "system"
            ;;
        invalid_flag|bad_mode|conflicting_options)
            echo "invalid"
            ;;
        interrupted|timeout|max_runtime|max_questions)
            echo "interrupted"
            ;;
        *)
            # Default to "partial" because review can often continue on other repos.
            echo "unknown"
            ;;
    esac
}

review_exit_code_for_classification() {
    local classification="${1:-unknown}"
    case "$classification" in
        partial) echo 1 ;;
        conflict) echo 2 ;;
        system) echo 3 ;;
        invalid) echo 4 ;;
        interrupted) echo 5 ;;
        *) echo 1 ;;
    esac
}

review_exit_code_for_error() {
    local error_type="${1:-}"
    local context="${2:-}"

    local classification
    classification=$(classify_review_error "$error_type" "$context")
    review_exit_code_for_classification "$classification"
}

aggregate_exit_code() {
    local max_code=0
    local code
    for code in "$@"; do
        [[ "$code" =~ ^[0-9]+$ ]] || continue
        (( code > max_code )) && max_code="$code"
    done
    echo "$max_code"
}

finalize_review_exit() {
    local exit_code="$1"

    case "$exit_code" in
        0) log_success "Review completed successfully" ;;
        1) log_warn "Review completed with partial failures" ;;
        2) log_error "Review blocked by conflicts - manual resolution needed" ;;
        3) log_error "Review failed due to system/dependency error" ;;
        4) log_error "Invalid arguments" ;;
        5) log_warn "Review interrupted - use --resume to continue" ;;
        *) log_error "Review failed (unknown exit code: $exit_code)" ;;
    esac

    exit "$exit_code"
}

#------------------------------------------------------------------------------
# cmd_review: Review GitHub issues and PRs using Claude Code
#------------------------------------------------------------------------------
cmd_review() {
    local review_start_epoch
    review_start_epoch=$(date +%s)

    # Parse review-specific arguments
    parse_review_args

    if [[ "$REVIEW_ANALYTICS" == "true" ]]; then
        cmd_review_analytics
        return $?
    fi

    if [[ "$REVIEW_BASIC_TUI" == "true" ]]; then
        if [[ "$REVIEW_DRIVER" == "auto" ]]; then
            REVIEW_DRIVER=$(detect_review_driver)
        fi
        if [[ "$REVIEW_DRIVER" == "none" ]]; then
            log_error "No review driver available. Install tmux or ntm."
            return 3
        fi
        load_review_driver "$REVIEW_DRIVER" || return 3
        basic_mode_loop
        return $?
    fi

    # Check prerequisites
    if ! check_review_prerequisites; then
        exit 3
    fi

    check_interactive_capability

    local resume_pending_repos=""
    local resume_run_id=""
    local repos_scanned=0

    if [[ "$REVIEW_RESUME" == "true" ]]; then
        local checkpoint
        checkpoint=$(load_review_checkpoint)

        if [[ -z "$checkpoint" ]]; then
            log_warn "No review checkpoint found; starting fresh"
        else
            resume_run_id=$(echo "$checkpoint" | jq -r '.run_id // empty' 2>/dev/null)
            local checkpoint_mode checkpoint_hash pending_count
            checkpoint_mode=$(echo "$checkpoint" | jq -r '.mode // empty' 2>/dev/null)
            checkpoint_hash=$(echo "$checkpoint" | jq -r '.config_hash // empty' 2>/dev/null)
            pending_count=$(echo "$checkpoint" | jq -r '.repos_pending // 0' 2>/dev/null || echo 0)

            if [[ -n "$checkpoint_mode" && "$REVIEW_MODE" != "$checkpoint_mode" ]]; then
                log_warn "Checkpoint mode '$checkpoint_mode' overrides requested mode '$REVIEW_MODE'"
                REVIEW_MODE="$checkpoint_mode"
            fi

            if [[ -n "$checkpoint_hash" ]]; then
                local current_hash
                current_hash=$(get_config_hash)
                if [[ "$current_hash" != "$checkpoint_hash" ]]; then
                    log_warn "Repository list has changed since checkpoint"
                fi
            fi

            resume_pending_repos=$(echo "$checkpoint" | jq -r '.pending_repos[]?' 2>/dev/null | tr '\n' ' ')
            resume_pending_repos="${resume_pending_repos%" "}"
            if [[ -n "$resume_pending_repos" ]]; then
                repos_scanned=$(echo "$resume_pending_repos" | wc -w | tr -d ' ')
                log_info "Resuming review with $pending_count pending repo(s)"
            else
                log_warn "Checkpoint contains no pending repos; starting fresh"
            fi
        fi
    fi

    # Generate unique run ID
    local run_id
    if [[ -n "$resume_run_id" ]]; then
        run_id="$resume_run_id"
    elif [[ "$REVIEW_MODE" == "apply" ]]; then
        if ! run_id=$(resolve_review_apply_run_id); then
            exit 4
        fi
    else
        run_id="$(date +%Y%m%d-%H%M%S)-$$"
    fi
    # shellcheck disable=SC2034  # Used by later phases and logging
    REVIEW_RUN_ID="$run_id"

    archive_old_digests 90

    if [[ -n "$REVIEW_INVALIDATE_CACHE" ]]; then
        local -a invalidate_repos=()
        if [[ "$REVIEW_INVALIDATE_CACHE" == "all" ]]; then
            while IFS= read -r spec; do
                [[ -z "$spec" ]] && continue
                # shellcheck disable=SC2034  # resolved_repo_id used by resolve_repo_spec
                local url branch custom_name local_path resolved_repo_id
                if resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" \
                        url branch custom_name local_path resolved_repo_id 2>/dev/null; then
                    invalidate_repos+=("$resolved_repo_id")
                fi
            done < <(get_all_repos)
        else
            local token
            for token in $REVIEW_INVALIDATE_CACHE; do
                invalidate_repos+=("$token")
            done
        fi

        local repo_id
        for repo_id in "${invalidate_repos[@]}"; do
            invalidate_digest_cache "$repo_id" "user-request"
        done
    fi

    # Acquire global lock
    if ! acquire_review_lock; then
        log_error "Another review is running. Use --resume to continue or wait."
        exit 1
    fi

    # Set up cleanup trap for lock release
    # shellcheck disable=SC2064
    cleanup_review() {
        log_verbose "Cleaning up review session..."
        release_review_lock
        cleanup
    }
    trap cleanup_review EXIT

    # Handle interrupts gracefully
    trap 'echo "" >&2; log_warn "Review interrupted - use --resume to continue"; exit 5' INT TERM

    # Apply mode does not require discovery or a driver.
    if [[ "$REVIEW_MODE" == "apply" ]]; then
        local apply_code=0
        cmd_review_apply
        apply_code=$?
        if [[ "$apply_code" -eq 0 ]]; then
            clear_review_checkpoint
        fi
        finalize_review_exit "$apply_code"
    fi

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
    discover_work_items work_items "$REVIEW_PRIORITY" "$REVIEW_MAX_REPOS" "$resume_pending_repos"

    if [[ $repos_scanned -eq 0 ]]; then
        repos_scanned=$(count_github_repos)
    fi

    if [[ ${#work_items[@]} -eq 0 ]]; then
        log_success "No work items need review"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            build_review_discovery_json "$run_id" "$repos_scanned" "${work_items[@]}"
        fi
        if [[ "$REVIEW_DRY_RUN" != "true" ]]; then
            clear_review_checkpoint
        fi
        return 0
    fi

    # Show summary
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local saved_json_output="$JSON_OUTPUT"
        JSON_OUTPUT="false"
        show_discovery_summary "${work_items[@]}"
        JSON_OUTPUT="$saved_json_output"
    else
        show_discovery_summary "${work_items[@]}"
    fi

    if [[ "$JSON_OUTPUT" == "true" && "$REVIEW_DRY_RUN" == "true" ]]; then
        build_review_discovery_json "$run_id" "$repos_scanned" "${work_items[@]}"
    fi

    # Dry run exit point
    if [[ "$REVIEW_DRY_RUN" == "true" ]]; then
        log_info "Dry run complete - no sessions started"
        return 0
    fi

    # Initialize checkpoint for resume (completed empty, pending from work items)
    local pending_repos_list=""
    local -A pending_seen=()
    for item in "${work_items[@]}"; do
        local repo_id=""
        IFS="|" read -r repo_id _ _ _ _ _ _ _ <<< "$item"
        if [[ -n "$repo_id" && -z "${pending_seen[$repo_id]:-}" ]]; then
            pending_seen["$repo_id"]=1
            pending_repos_list+="${repo_id} "
        fi
    done
    pending_repos_list="${pending_repos_list%" "}"
    checkpoint_review_state "" "$pending_repos_list"

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

    if [[ "$REVIEW_NON_INTERACTIVE" == "true" ]]; then
        summarize_non_interactive_questions
    fi

    update_repo_digests_from_worktrees || true
    clear_review_checkpoint
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        build_review_completion_json "$run_id" "$REVIEW_MODE" "$review_start_epoch" "0" "${work_items[@]}"
    fi
    return 0
}

#------------------------------------------------------------------------------
# resolve_review_apply_run_id: Determine which review run to apply
#
# If --resume is set, uses the checkpoint run_id.
# Otherwise, selects the most recently modified directory under $RU_STATE_DIR/worktrees.
#
# Outputs:
#   Run ID to stdout
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
resolve_review_apply_run_id() {
    local run_id=""

    if [[ "${REVIEW_RESUME:-false}" == "true" ]]; then
        local checkpoint
        checkpoint=$(load_review_checkpoint)
        if [[ -z "$checkpoint" ]]; then
            log_error "No review checkpoint found (cannot --resume apply)"
            return 1
        fi

        run_id=$(echo "$checkpoint" | jq -r '.run_id // ""' 2>/dev/null || echo "")
        if [[ -z "$run_id" || "$run_id" == "null" ]]; then
            log_error "Checkpoint missing run_id (cannot --resume apply)"
            return 1
        fi

        echo "$run_id"
        return 0
    fi

    local base="${RU_STATE_DIR}/worktrees"
    if [[ ! -d "$base" ]]; then
        log_error "No review worktrees directory found: $base"
        return 1
    fi

    local best_run_id=""
    local best_mtime=0

    local dir
    for dir in "$base"/*; do
        [[ -d "$dir" ]] || continue

        local mtime
        if stat --version 2>/dev/null | grep -q GNU; then
            mtime=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
        else
            mtime=$(stat -f %m "$dir" 2>/dev/null || echo 0)
        fi
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0

        if (( mtime > best_mtime )); then
            best_mtime="$mtime"
            best_run_id="${dir##*/}"
        fi
    done

    run_id="$best_run_id"

    if [[ -z "$run_id" ]]; then
        log_error "No review worktrees found under: $base"
        return 1
    fi

    echo "$run_id"
    return 0
}

#------------------------------------------------------------------------------
# cmd_review_apply: Apply approved review plans for a run
#
# Uses the per-run worktree mapping file to locate worktrees and plan artifacts.
#
# Returns:
#   Review exit code (0-5)
#------------------------------------------------------------------------------
cmd_review_apply() {
    local run_id="${REVIEW_RUN_ID:-}"
    if [[ -z "$run_id" ]]; then
        log_error "No run ID available for apply"
        return 4
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for review --apply"
        return 3
    fi

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    local mapping_file="$worktrees_dir/mapping.json"

    if [[ ! -f "$mapping_file" ]]; then
        log_error "No worktree mapping found for run: $run_id"
        log_error "Expected: $mapping_file"
        return 4
    fi

    log_step "Applying review plans for run: $run_id"

    local -a codes=()
    local repo_id
    while IFS= read -r repo_id; do
        [[ -n "$repo_id" ]] || continue

        local wt_path
        wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].path // ""' "$mapping_file" 2>/dev/null || echo "")
        if [[ -z "$wt_path" || ! -d "$wt_path" ]]; then
            log_error "Missing or invalid worktree path for $repo_id (mapping.json)"
            codes+=("2")
            continue
        fi

        local code=0
        apply_review_plan_for_repo "$repo_id" "$wt_path"
        code=$?
        codes+=("$code")
    done < <(jq -r 'keys[]' "$mapping_file" 2>/dev/null)

    local overall
    overall=$(aggregate_exit_code "${codes[@]}")
    return "$overall"
}

#------------------------------------------------------------------------------
# get_main_repo_path_from_worktree: Resolve the main repo path from a worktree path
#
# Args:
#   $1 - worktree path
# Outputs:
#   Main repo path to stdout
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
get_main_repo_path_from_worktree() {
    local wt_path="$1"

    local common_dir
    common_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    common_dir="${common_dir%/}"

    if [[ "$common_dir" == */.git ]]; then
        echo "${common_dir%/.git}"
        return 0
    fi

    echo "$common_dir"
    return 0
}

#------------------------------------------------------------------------------
# archive_review_plan: Copy the plan artifact to review state for audit
#
# Args:
#   $1 - repo_id
#   $2 - plan_file
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
archive_review_plan() {
    local repo_id="$1"
    local plan_file="$2"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Cannot archive missing plan file: $plan_file"
        return 1
    fi

    local state_dir
    state_dir=$(get_review_state_dir)
    local run_id="${REVIEW_RUN_ID:-unknown}"

    local out_dir="$state_dir/applied-plans/$run_id"
    ensure_dir "$out_dir"

    local safe_repo="${repo_id//\//_}"
    local dest="$out_dir/${safe_repo}.json"
    if [[ -f "$dest" ]]; then
        dest="$out_dir/${safe_repo}-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
    fi

    if ! cp "$plan_file" "$dest" 2>/dev/null; then
        log_error "Failed to archive plan to: $dest"
        return 1
    fi

    log_verbose "Archived plan: $dest"
    return 0
}

#------------------------------------------------------------------------------
# verify_push_safe: Refuse push/merge unless plan indicates it's safe
#
# Args:
#   $1 - repo_id
#   $2 - plan_file
#   $3 - Optional: worktree path (for dirty check)
#
# Returns:
#   0 if safe, 1 otherwise
#------------------------------------------------------------------------------
verify_push_safe() {
    local repo_id="$1"
    local plan_file="$2"
    local wt_path="${3:-}"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found for $repo_id: $plan_file"
        return 1
    fi

    local quality_ok tests_ok warning
    quality_ok=$(jq -r '.git.quality_gates_ok // false' "$plan_file" 2>/dev/null || echo "false")
    tests_ok=$(jq -r '.git.tests.ok // false' "$plan_file" 2>/dev/null || echo "false")
    warning=$(jq -r '.git.quality_gates_warning // false' "$plan_file" 2>/dev/null || echo "false")

    if [[ "$quality_ok" != "true" || "$tests_ok" != "true" ]]; then
        log_error "Quality gates did not pass for $repo_id (refusing to push)"
        return 1
    fi

    if [[ "$warning" == "true" ]]; then
        log_error "Quality gates reported warnings for $repo_id (refusing to push)"
        return 1
    fi

    local unanswered
    unanswered=$(jq -r '[.questions // [] | .[] | select(.answered != true)] | length' "$plan_file" 2>/dev/null || echo "0")
    if [[ "$unanswered" =~ ^[0-9]+$ ]] && [[ "$unanswered" -gt 0 ]]; then
        log_error "$unanswered unanswered question(s) for $repo_id (refusing to push)"
        return 1
    fi

    if [[ -n "$wt_path" && -d "$wt_path" ]]; then
        local wt_status
        wt_status=$(git -C "$wt_path" status --porcelain 2>/dev/null || true)
        # Ignore ru-managed artifacts stored under .ru/
        if [[ -n "$wt_status" ]]; then
            wt_status=$(echo "$wt_status" | grep -vE '^\?\? \.ru(/|$)' 2>/dev/null || true)
        fi

        if [[ -n "$wt_status" ]]; then
            log_error "Worktree has uncommitted changes for $repo_id (refusing to push)"
            return 1
        fi
    fi

    return 0
}

#------------------------------------------------------------------------------
# record_review_push: Record a successful push in review state
#
# Args:
#   $1 - repo_id
#   $2 - branch (base branch pushed)
#   $3 - commit sha (HEAD after push)
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
record_review_push() {
    local repo_id="$1"
    local branch="$2"
    local commit_sha="$3"

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    init_review_state

    update_review_state "
        .repos[\"$repo_id\"] = (.repos[\"$repo_id\"] // {}) + {
            \"last_push\": \"$now\",
            \"last_push_branch\": \"$branch\",
            \"last_push_commit\": \"$commit_sha\"
        }
    "
}

#------------------------------------------------------------------------------
# push_worktree_changes: Fast-forward merge worktree branch into base and push
#
# Args:
#   $1 - repo_id
#   $2 - worktree path
#
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
push_worktree_changes() {
    local repo_id="$1"
    local wt_path="$2"
    local plan_file="$wt_path/.ru/review-plan.json"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found: $plan_file"
        return 1
    fi

    local validation
    validation=$(validate_review_plan "$plan_file")
    if [[ "$validation" != "Valid" ]]; then
        log_error "Invalid plan for $repo_id: $validation"
        return 1
    fi

    local wt_branch base_ref
    wt_branch=$(jq -r '.git.branch // ""' "$plan_file" 2>/dev/null || echo "")
    base_ref=$(jq -r '.git.base_ref // ""' "$plan_file" 2>/dev/null || echo "")

    if [[ -z "$wt_branch" ]]; then
        wt_branch=$(git -C "$wt_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
    fi

    if [[ -z "$wt_branch" ]]; then
        log_error "Cannot determine worktree branch for $repo_id"
        return 1
    fi

    if [[ -z "$base_ref" ]]; then
        log_error "Plan missing git.base_ref for $repo_id (cannot merge)"
        return 1
    fi

    if ! git check-ref-format --branch "$wt_branch" >/dev/null 2>&1; then
        log_error "Invalid worktree branch name in plan: $wt_branch"
        return 1
    fi

    if ! git check-ref-format --branch "$base_ref" >/dev/null 2>&1; then
        log_error "Invalid base_ref in plan: $base_ref"
        return 1
    fi

    local main_repo
    if ! main_repo=$(get_main_repo_path_from_worktree "$wt_path"); then
        log_error "Failed to resolve main repo path from worktree: $wt_path"
        return 1
    fi

    if [[ -n "$(git -C "$main_repo" status --porcelain 2>/dev/null)" ]]; then
        log_error "Main repo has uncommitted changes: $main_repo"
        return 1
    fi

    log_step "Merging changes for $repo_id into $base_ref"

    git -C "$main_repo" fetch --quiet 2>/dev/null || true

    local original_branch
    original_branch=$(git -C "$main_repo" symbolic-ref --short HEAD 2>/dev/null || echo "")

    if ! git -C "$main_repo" checkout --quiet "$base_ref" 2>/dev/null; then
        log_error "Failed to checkout base ref $base_ref in $main_repo"
        return 1
    fi

    local safe_repo tmp_ref
    safe_repo="${repo_id//\//_}"
    tmp_ref="refs/ru/tmp/worktree-${safe_repo}-$$"

    if ! git -C "$main_repo" fetch --quiet "$wt_path" "+refs/heads/$wt_branch:$tmp_ref" 2>/dev/null; then
        log_error "Failed to fetch worktree branch $wt_branch from $wt_path"
        [[ -n "$original_branch" ]] && git -C "$main_repo" checkout --quiet "$original_branch" 2>/dev/null || true
        return 1
    fi

    if ! git -C "$main_repo" merge --ff-only --quiet "$tmp_ref" 2>/dev/null; then
        log_error "Cannot fast-forward merge for $repo_id (manual resolution needed)"
        git -C "$main_repo" update-ref -d "$tmp_ref" 2>/dev/null || true
        [[ -n "$original_branch" ]] && git -C "$main_repo" checkout --quiet "$original_branch" 2>/dev/null || true
        return 1
    fi

    if ! git -C "$main_repo" push 2>/dev/null; then
        log_error "Push failed for $repo_id"
        git -C "$main_repo" update-ref -d "$tmp_ref" 2>/dev/null || true
        [[ -n "$original_branch" ]] && git -C "$main_repo" checkout --quiet "$original_branch" 2>/dev/null || true
        return 1
    fi

    git -C "$main_repo" update-ref -d "$tmp_ref" 2>/dev/null || true

    local head_sha
    head_sha=$(git -C "$main_repo" rev-parse HEAD 2>/dev/null || echo "")
    record_review_push "$repo_id" "$base_ref" "$head_sha" || true
    archive_review_plan "$repo_id" "$plan_file" || true

    log_success "Pushed changes for $repo_id"

    if [[ -n "$original_branch" && "$original_branch" != "$base_ref" ]]; then
        git -C "$main_repo" checkout --quiet "$original_branch" 2>/dev/null || true
    fi

    return 0
}

#------------------------------------------------------------------------------
# apply_review_plan_for_repo: Apply a single repo's review plan from its worktree
#
# Returns:
#   Review exit code (0-5) for this repo
#------------------------------------------------------------------------------
apply_review_plan_for_repo() {
    local repo_id="$1"
    local wt_path="$2"
    local plan_file="$wt_path/.ru/review-plan.json"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Missing review plan for $repo_id: $plan_file"
        return "$(review_exit_code_for_error invalid_flag)"
    fi

    local validation
    validation=$(validate_review_plan "$plan_file")
    if [[ "$validation" != "Valid" ]]; then
        log_error "Invalid review plan for $repo_id: $validation"
        return "$(review_exit_code_for_error invalid_flag)"
    fi

    local commits_count
    commits_count=$(jq -r '.git.commits // [] | length' "$plan_file" 2>/dev/null || echo "0")
    [[ "$commits_count" =~ ^[0-9]+$ ]] || commits_count=0

    local gates_json gates_rc
    gates_json=$(run_quality_gates "$wt_path" "$plan_file")
    gates_rc=$?
    update_plan_with_gates "$plan_file" "$gates_json" || true

    if [[ $gates_rc -ne 0 ]]; then
        return "$(review_exit_code_for_error quality_gate_failed)"
    fi

    local pushed=false
    if [[ "$commits_count" -gt 0 ]]; then
        if [[ "${REVIEW_PUSH:-false}" != "true" ]]; then
            log_info "Push disabled (use --push) - skipping merge/push for $repo_id"
        elif ! repo_allows_push "$repo_id"; then
            log_warn "Push not allowed by policy for $repo_id - skipping merge/push"
        else
            if ! verify_push_safe "$repo_id" "$plan_file" "$wt_path"; then
                return "$(review_exit_code_for_error quality_gate_failed)"
            fi

            if ! push_worktree_changes "$repo_id" "$wt_path"; then
                return "$(review_exit_code_for_error merge_conflict)"
            fi
            pushed=true
        fi
    fi

    local actions_count
    actions_count=$(jq -r '.gh_actions // [] | length' "$plan_file" 2>/dev/null || echo "0")
    [[ "$actions_count" =~ ^[0-9]+$ ]] || actions_count=0

    if [[ "$actions_count" -gt 0 ]]; then
        if [[ "$commits_count" -gt 0 && "$pushed" != "true" ]]; then
            log_warn "Skipping gh_actions for $repo_id (code changes not pushed)"
        else
            if ! execute_gh_actions "$repo_id" "$plan_file"; then
                return "$(review_exit_code_for_error session_failed)"
            fi
        fi
    fi

    local duration_seconds
    duration_seconds=$(jq -r '.metadata.duration_seconds // 0' "$plan_file" 2>/dev/null || echo 0)
    record_decisions_from_plan "$repo_id" "$plan_file" || true
    record_metrics_from_plan "$repo_id" "$plan_file" "$duration_seconds" || true

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
# SECTION 13.8: PROMPT GENERATION
#==============================================================================

# Generate the "digest" prompt (writes/updates .ru/repo-digest.md)
generate_digest_prompt() {
  cat <<'EOF'
First read ALL of AGENTS.md and README.md carefully.

If a prior digest exists at `.ru/repo-digest.md`, read it first, then update it based on changes since the last review:
  - inspect `git log` since the last digest timestamp
  - inspect changed files and any new architecture decisions

If no digest exists, create a comprehensive digest covering:
  - project purpose and architecture
  - key files/modules and their roles
  - conventions, quality gates, and how to run tests

Write the updated digest to `.ru/repo-digest.md`.
EOF
}

# Generate the "review work items" prompt (must write .ru/review-plan.json)
# Args: repo_name worktree_path run_id work_items_json
generate_review_prompt() {
  local repo_name="$1"
  local worktree_path="$2"
  local run_id="$3"
  local work_items_json="$4"

  # NOTE: Avoid unquoted heredocs here so any backticks/$() inside $work_items_json
  # cannot trigger command substitution during prompt generation.
  printf '%s\n' \
    "POLICY: We don't allow PRs or outside contributions. Feel free to submit issues and PRs to illustrate fixes, but they will not be merged directly. The agent reviews and independently decides whether and how to address submissions. Bug reports are welcome." \
    "" \
    'TASK: Review the following work items using `gh` READ operations only:'

  printf '%s\n' "$work_items_json"

  printf '%s\n' \
    "" \
    "For each item:" \
    '1) Read the issue/PR independently via `gh issue view` or `gh pr view`.' \
    "2) Verify claims independently; do not trust reports blindly." \
    "3) Check dates against recent commits (issues/PRs may be stale)." \
    "4) If actionable: create local commits with focused fixes." \
    '5) If unclear: ask the maintainer using the `AskUserQuestion` tool.' \
    "" \
    "CRITICAL RESTRICTIONS (PLAN MODE):" \
    '- DO NOT run any `gh` mutation commands (comment/close/label/merge/etc).' \
    "- DO NOT push any changes." \
    "- Prefer minimal, reviewable commits; avoid broad refactors unless justified." \
    "" \
    "REQUIRED OUTPUT (contract):" \
    '- You MUST write `.ru/review-plan.json` as strictly valid JSON.' \
    "- It MUST conform to schema v1." \
    "- Set:" \
    "  - schema_version: 1" \
    "  - run_id: \"$run_id\"" \
    "  - repo: \"$repo_name\"" \
    "  - worktree_path: \"$worktree_path\"" \
    "  - metadata.model: your model id" \
    "  - metadata.driver: \"ntm\" or \"local\"" \
    "" \
    "If you ask any maintainer questions:" \
    '- Use `AskUserQuestion` with 2–4 options (label+description), multiSelect=false.' \
    '- Mirror those into `.ru/review-plan.json` under `questions[]` with answered=false until answered.'
}

#==============================================================================
# SECTION 13.6: REVIEW POLICY CONFIGURATION
#==============================================================================

# Default policy directory (used by functions below)
# shellcheck disable=SC2034
REVIEW_POLICY_DIR=""

#------------------------------------------------------------------------------
# get_review_policy_dir: Get the review policies directory path
#
# Returns:
#   0 always
#
# Outputs:
#   Path to review-policies.d directory
#------------------------------------------------------------------------------
get_review_policy_dir() {
    echo "${RU_CONFIG_DIR:-$HOME/.config/ru}/review-policies.d"
}

#------------------------------------------------------------------------------
# init_review_policies: Initialize the review policies directory with examples
#
# Args:
#   $1 - Optional: "quiet" to suppress output
#
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
init_review_policies() {
    local quiet="${1:-}"
    local policy_dir
    policy_dir=$(get_review_policy_dir)

    if [[ -d "$policy_dir" ]]; then
        [[ "$quiet" != "quiet" ]] && log_info "Policy directory already exists: $policy_dir"
        return 0
    fi

    if ! mkdir -p "$policy_dir"; then
        log_error "Failed to create policy directory: $policy_dir"
        return 1
    fi

    # Create example policy file
    cat > "$policy_dir/_default.example" << 'EOF'
# Default Review Policy Configuration
# Copy to _default (no extension) to activate
# Or create repo-specific files: github.com_owner_repo

# Priority boost applied to all reviews for repos matching this policy
# BASE_PRIORITY=0

# Label-based priority boosts (comma-separated key=value pairs)
# LABEL_PRIORITY_BOOST="security=2,bug=1,documentation=-1"

# Whether to allow auto-push after successful review
# REVIEW_ALLOW_PUSH=false

# Whether to require explicit approval before merging
# REVIEW_REQUIRE_APPROVAL=true

# Maximum parallel agent sessions for this repo
# MAX_PARALLEL_AGENTS=4

# Patterns for files that should skip automated review
# SKIP_PATTERNS="*.generated.go,vendor/*"

# Custom test command (overrides auto-detection)
# TEST_COMMAND=""

# Custom lint command (overrides auto-detection)
# LINT_COMMAND=""
EOF

    [[ "$quiet" != "quiet" ]] && log_info "Created policy directory with example: $policy_dir"
    return 0
}

#------------------------------------------------------------------------------
# validate_policy_file: Validate a policy file's syntax and values
#
# Args:
#   $1 - Path to policy file
#
# Returns:
#   0 if valid, 1 if invalid
#
# Outputs:
#   Error messages to stderr, "Valid" to stdout on success
#------------------------------------------------------------------------------
validate_policy_file() {
    local policy_file="$1"
    local errors=()
    local line_num=0

    if [[ ! -f "$policy_file" ]]; then
        echo "File not found: $policy_file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Must be KEY=VALUE format
        if [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            errors+=("Line $line_num: Invalid format (expected KEY=VALUE): $line")
            continue
        fi

        local key="${line%%=*}"
        local value="${line#*=}"

        # Validate specific keys
        case "$key" in
            BASE_PRIORITY)
                if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
                    errors+=("Line $line_num: BASE_PRIORITY must be an integer: $value")
                fi
                ;;
            REVIEW_ALLOW_PUSH|REVIEW_REQUIRE_APPROVAL)
                if [[ ! "$value" =~ ^(true|false)$ ]]; then
                    errors+=("Line $line_num: $key must be true or false: $value")
                fi
                ;;
            MAX_PARALLEL_AGENTS)
                if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
                    errors+=("Line $line_num: MAX_PARALLEL_AGENTS must be a positive integer: $value")
                fi
                ;;
            LABEL_PRIORITY_BOOST)
                # Validate comma-separated key=value pairs
                if [[ -n "$value" && ! "$value" =~ ^[a-zA-Z0-9_-]+=-?[0-9]+(,[a-zA-Z0-9_-]+=-?[0-9]+)*$ ]]; then
                    errors+=("Line $line_num: LABEL_PRIORITY_BOOST format: label1=N,label2=M")
                fi
                ;;
            SKIP_PATTERNS|TEST_COMMAND|LINT_COMMAND)
                # These accept any string value
                ;;
            *)
                errors+=("Line $line_num: Unknown policy key: $key")
                ;;
        esac
    done < "$policy_file"

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "$err" >&2
        done
        return 1
    fi

    echo "Valid"
    return 0
}

#------------------------------------------------------------------------------
# load_policy_for_repo: Load and merge policies for a specific repository
#
# Merges in order: _default -> glob patterns -> exact repo match
# Later values override earlier ones.
#
# Args:
#   $1 - Repository identifier (e.g., "github.com/owner/repo" or "owner/repo")
#
# Returns:
#   0 on success (even if no policies found), 1 on error
#
# Outputs:
#   JSON object with merged policy values
#------------------------------------------------------------------------------
load_policy_for_repo() {
    local repo_id="$1"
    local policy_dir
    policy_dir=$(get_review_policy_dir)

    # Initialize default values
    local base_priority=0
    local label_priority_boost=""
    local allow_push="false"
    local require_approval="true"
    local max_parallel=4
    local skip_patterns=""
    local test_command=""
    local lint_command=""
    local policies_loaded=()

    # Helper to load a policy file
    load_policy() {
        local file="$1"
        [[ ! -f "$file" ]] && return

        # Skip example files
        [[ "$file" == *.example ]] && return

        policies_loaded+=("$(basename "$file")")

        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] && continue

            local key="${line%%=*}"
            local value="${line#*=}"
            # Strip surrounding quotes if present
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            case "$key" in
                BASE_PRIORITY) base_priority="$value" ;;
                LABEL_PRIORITY_BOOST) label_priority_boost="$value" ;;
                REVIEW_ALLOW_PUSH) allow_push="$value" ;;
                REVIEW_REQUIRE_APPROVAL) require_approval="$value" ;;
                MAX_PARALLEL_AGENTS) max_parallel="$value" ;;
                SKIP_PATTERNS) skip_patterns="$value" ;;
                TEST_COMMAND) test_command="$value" ;;
                LINT_COMMAND) lint_command="$value" ;;
            esac
        done < "$file"
    }

    # Normalize repo_id: github.com/owner/repo -> github.com_owner_repo
    local repo_file_name
    repo_file_name=$(echo "$repo_id" | tr '/' '_' | tr ':' '_')

    # 1. Load default policy
    load_policy "$policy_dir/_default"

    # 2. Load glob-pattern policies (files starting with * or containing *)
    if [[ -d "$policy_dir" ]]; then
        local pattern_file
        for pattern_file in "$policy_dir"/*; do
            [[ ! -f "$pattern_file" ]] && continue
            local basename
            basename=$(basename "$pattern_file")
            # Skip _default and exact matches
            [[ "$basename" == "_default" ]] && continue
            [[ "$basename" == "$repo_file_name" ]] && continue
            [[ "$basename" == *.example ]] && continue

            # Check if it's a glob pattern that matches
            # shellcheck disable=SC2053
            if [[ "$repo_file_name" == $basename ]]; then
                load_policy "$pattern_file"
            fi
        done
    fi

    # 3. Load exact repo match
    load_policy "$policy_dir/$repo_file_name"

    # Output as JSON
    jq -n \
        --arg base_priority "$base_priority" \
        --arg label_boost "$label_priority_boost" \
        --arg allow_push "$allow_push" \
        --arg require_approval "$require_approval" \
        --arg max_parallel "$max_parallel" \
        --arg skip_patterns "$skip_patterns" \
        --arg test_cmd "$test_command" \
        --arg lint_cmd "$lint_command" \
        --arg policies_loaded "$(IFS=,; echo "${policies_loaded[*]}")" \
        '{
            base_priority: ($base_priority | tonumber),
            label_priority_boost: $label_boost,
            allow_push: ($allow_push == "true"),
            require_approval: ($require_approval == "true"),
            max_parallel_agents: ($max_parallel | tonumber),
            skip_patterns: $skip_patterns,
            test_command: $test_cmd,
            lint_command: $lint_cmd,
            policies_loaded: ($policies_loaded | split(",") | map(select(. != "")))
        }'
}

#------------------------------------------------------------------------------
# get_policy_value: Get a single policy value for a repository
#
# Args:
#   $1 - Repository identifier
#   $2 - Policy key (e.g., "base_priority", "allow_push")
#
# Returns:
#   0 on success, 1 if key not found
#
# Outputs:
#   The policy value
#------------------------------------------------------------------------------
get_policy_value() {
    local repo_id="$1"
    local key="$2"
    local policy_json

    policy_json=$(load_policy_for_repo "$repo_id")

    local value
    value=$(echo "$policy_json" | jq -r ".$key // empty")

    if [[ -z "$value" ]]; then
        return 1
    fi

    echo "$value"
    return 0
}

#------------------------------------------------------------------------------
# repo_allows_push: Check if a repository allows auto-push
#
# Args:
#   $1 - Repository identifier
#
# Returns:
#   0 if push allowed, 1 if not
#------------------------------------------------------------------------------
repo_allows_push() {
    local repo_id="$1"
    local value
    value=$(get_policy_value "$repo_id" "allow_push")
    [[ "$value" == "true" ]]
}

#------------------------------------------------------------------------------
# repo_requires_approval: Check if a repository requires approval before merge
#
# Args:
#   $1 - Repository identifier
#
# Returns:
#   0 if approval required, 1 if not
#------------------------------------------------------------------------------
repo_requires_approval() {
    local repo_id="$1"
    local value
    value=$(get_policy_value "$repo_id" "require_approval")
    [[ "$value" == "true" ]]
}

#------------------------------------------------------------------------------
# apply_policy_priority_boost: Apply priority boost based on policy and labels
#
# Args:
#   $1 - Repository identifier
#   $2 - Current priority (0-4)
#   $3 - Comma-separated list of labels (optional)
#
# Returns:
#   0 always
#
# Outputs:
#   Adjusted priority (clamped to 0-4)
#------------------------------------------------------------------------------
apply_policy_priority_boost() {
    local repo_id="$1"
    local current_priority="${2:-2}"
    local labels="${3:-}"

    local policy_json
    policy_json=$(load_policy_for_repo "$repo_id")

    # Get base priority boost
    local base_boost
    base_boost=$(echo "$policy_json" | jq -r '.base_priority // 0')

    # Get label priority boosts
    local label_boost_str
    label_boost_str=$(echo "$policy_json" | jq -r '.label_priority_boost // ""')

    # Calculate total boost
    local total_boost=$base_boost

    if [[ -n "$label_boost_str" && -n "$labels" ]]; then
        # Parse label boosts into associative array
        local -A label_boosts
        IFS=',' read -ra boost_pairs <<< "$label_boost_str"
        for pair in "${boost_pairs[@]}"; do
            local label="${pair%%=*}"
            local boost="${pair#*=}"
            label_boosts["$label"]="$boost"
        done

        # Apply boosts for matching labels
        IFS=',' read -ra label_array <<< "$labels"
        for label in "${label_array[@]}"; do
            label=$(echo "$label" | tr -d ' ')
            if [[ -n "${label_boosts[$label]:-}" ]]; then
                ((total_boost += label_boosts[$label]))
            fi
        done
    fi

    # Calculate new priority and clamp to 0-4
    local new_priority=$((current_priority - total_boost))
    ((new_priority < 0)) && new_priority=0
    ((new_priority > 4)) && new_priority=4

    echo "$new_priority"
}

#==============================================================================
# SECTION 13.7: QUALITY GATES FRAMEWORK
#==============================================================================

#------------------------------------------------------------------------------
# detect_test_command: Auto-detect the test command for a project
#
# Args:
#   $1 - Project directory path
#
# Returns:
#   0 if command detected, 1 if no test framework found
#
# Outputs:
#   Test command to stdout
#------------------------------------------------------------------------------
detect_test_command() {
    local project_dir="$1"

    # Check Makefile for test target
    if [[ -f "$project_dir/Makefile" ]] && grep -q "^test:" "$project_dir/Makefile" 2>/dev/null; then
        echo "make test"
        return 0
    fi

    # Check for package.json (npm/node)
    if [[ -f "$project_dir/package.json" ]]; then
        if jq -e '.scripts.test' "$project_dir/package.json" >/dev/null 2>&1; then
            echo "npm test"
            return 0
        fi
    fi

    # Check for Cargo.toml (Rust)
    if [[ -f "$project_dir/Cargo.toml" ]]; then
        echo "cargo test"
        return 0
    fi

    # Check for Python projects
    if [[ -f "$project_dir/pyproject.toml" ]] || [[ -f "$project_dir/setup.py" ]]; then
        if [[ -d "$project_dir/tests" ]] || [[ -d "$project_dir/test" ]]; then
            echo "pytest"
            return 0
        fi
    fi

    # Check for Go projects
    if [[ -f "$project_dir/go.mod" ]]; then
        echo "go test ./..."
        return 0
    fi

    # Check for shell test scripts
    if [[ -x "$project_dir/scripts/run_all_tests.sh" ]]; then
        echo "./scripts/run_all_tests.sh"
        return 0
    fi

    return 1
}

#------------------------------------------------------------------------------
# detect_lint_command: Auto-detect the lint command for a project
#
# Args:
#   $1 - Project directory path
#
# Returns:
#   0 if command detected, 1 if no linter found
#
# Outputs:
#   Lint command to stdout
#------------------------------------------------------------------------------
detect_lint_command() {
    local project_dir="$1"

    # Check for package.json lint script
    if [[ -f "$project_dir/package.json" ]]; then
        if jq -e '.scripts.lint' "$project_dir/package.json" >/dev/null 2>&1; then
            echo "npm run lint"
            return 0
        fi
    fi

    # Check for shell scripts (use shellcheck)
    if command -v shellcheck &>/dev/null; then
        local shell_scripts
        shell_scripts=$(find "$project_dir" -maxdepth 2 -name "*.sh" -type f 2>/dev/null | head -1)
        if [[ -n "$shell_scripts" ]]; then
            echo "shellcheck -S warning \$(find . -name '*.sh' -type f)"
            return 0
        fi
    fi

    # Check for Python (ruff or flake8)
    if [[ -f "$project_dir/pyproject.toml" ]] || [[ -f "$project_dir/setup.py" ]]; then
        if command -v ruff &>/dev/null; then
            echo "ruff check ."
            return 0
        elif command -v flake8 &>/dev/null; then
            echo "flake8 ."
            return 0
        fi
    fi

    # Check for Go
    if [[ -f "$project_dir/go.mod" ]]; then
        echo "go vet ./..."
        return 0
    fi

    return 1
}

#------------------------------------------------------------------------------
# run_test_gate: Run tests for a project
#
# Args:
#   $1 - Project directory path
#   $2 - Optional: Test command override
#   $3 - Optional: Timeout in seconds (default: 300)
#
# Returns:
#   0 on success, 1 on failure, 2 if no tests found
#
# Outputs:
#   JSON result object to stdout
#------------------------------------------------------------------------------
run_test_gate() {
    local project_dir="$1"
    local test_cmd="${2:-}"
    local timeout="${3:-300}"
    local start_time
    local exit_code=0
    local output=""

    start_time=$(date +%s)

    # Auto-detect if not provided
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_command "$project_dir") || {
            jq -n '{ran: false, ok: null, reason: "no_tests_found"}'
            return 2
        }
    fi

    log_verbose "Running tests: $test_cmd"

    # Run tests with timeout
    if output=$(cd "$project_dir" && timeout "$timeout" bash -c "$test_cmd" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Summarize output (last 10 lines or key metrics)
    local output_summary
    output_summary=$(echo "$output" | tail -10 | tr '\n' ' ' | cut -c1-200)

    jq -n \
        --argjson ran true \
        --argjson ok "$([ $exit_code -eq 0 ] && echo true || echo false)" \
        --arg command "$test_cmd" \
        --arg output_summary "$output_summary" \
        --argjson duration_seconds "$duration" \
        --argjson exit_code "$exit_code" \
        '{
            ran: $ran,
            ok: $ok,
            command: $command,
            output_summary: $output_summary,
            duration_seconds: $duration_seconds,
            exit_code: $exit_code
        }'

    return $exit_code
}

#------------------------------------------------------------------------------
# run_lint_gate: Run linting for a project
#
# Args:
#   $1 - Project directory path
#   $2 - Optional: Lint command override
#
# Returns:
#   0 on success, 1 on failure, 2 if no linter found
#
# Outputs:
#   JSON result object to stdout
#------------------------------------------------------------------------------
run_lint_gate() {
    local project_dir="$1"
    local lint_cmd="${2:-}"
    local exit_code=0
    local output=""

    # Auto-detect if not provided
    if [[ -z "$lint_cmd" ]]; then
        lint_cmd=$(detect_lint_command "$project_dir") || {
            jq -n '{ran: false, ok: null, reason: "no_linter_found"}'
            return 2
        }
    fi

    log_verbose "Running lint: $lint_cmd"

    # Run linter
    if output=$(cd "$project_dir" && bash -c "$lint_cmd" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    local output_summary
    output_summary=$(echo "$output" | head -20 | tr '\n' ' ' | cut -c1-300)

    jq -n \
        --argjson ran true \
        --argjson ok "$([ $exit_code -eq 0 ] && echo true || echo false)" \
        --arg command "$lint_cmd" \
        --arg output_summary "$output_summary" \
        --argjson exit_code "$exit_code" \
        '{
            ran: $ran,
            ok: $ok,
            command: $command,
            output_summary: $output_summary,
            exit_code: $exit_code
        }'

    return $exit_code
}

#------------------------------------------------------------------------------
# run_secret_scan: Scan for secrets in project changes
#
# Args:
#   $1 - Project directory path
#   $2 - Optional: "staged" to scan only staged changes
#
# Returns:
#   0 on success (no secrets), 1 on failure (secrets found), 2 on warning
#
# Outputs:
#   JSON result object to stdout
#------------------------------------------------------------------------------
run_secret_scan() {
    local project_dir="$1"
    local scope="${2:-all}"
    local findings=()
    local exit_code=0

    # Use gitleaks if available
    if command -v gitleaks &>/dev/null; then
        log_verbose "Scanning for secrets with gitleaks"
        local gl_output
        if ! gl_output=$(gitleaks detect --source "$project_dir" --no-git 2>&1); then
            exit_code=1
            # Include first line of gitleaks output in findings
            local gl_summary
            gl_summary=$(echo "$gl_output" | head -3 | tr '\n' ' ')
            findings+=("gitleaks: ${gl_summary:-detected potential secrets}")
        fi
    else
        # Regex fallback
        log_verbose "Scanning for secrets with regex patterns"
        local patterns=(
            'password\s*[:=]'
            'api.?key\s*[:=]'
            'secret\s*[:=]'
            'token\s*[:=]'
            'AWS_ACCESS_KEY'
            'AWS_SECRET_ACCESS_KEY'
            'PRIVATE_KEY'
            'BEGIN RSA PRIVATE KEY'
            'BEGIN OPENSSH PRIVATE KEY'
        )

        local diff_output
        if [[ "$scope" == "staged" ]]; then
            diff_output=$(git -C "$project_dir" diff --cached 2>/dev/null || true)
        else
            diff_output=$(git -C "$project_dir" diff HEAD~1..HEAD 2>/dev/null || true)
        fi

        for pattern in "${patterns[@]}"; do
            if echo "$diff_output" | grep -qiE "$pattern"; then
                exit_code=2  # Warning
                findings+=("Potential secret pattern: $pattern")
            fi
        done
    fi

    local findings_json="[]"
    if [[ ${#findings[@]} -gt 0 ]]; then
        findings_json=$(printf '%s\n' "${findings[@]}" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson ran true \
        --argjson ok "$([ $exit_code -eq 0 ] && echo true || echo false)" \
        --argjson warning "$([ $exit_code -eq 2 ] && echo true || echo false)" \
        --argjson findings "$findings_json" \
        --arg tool "$(command -v gitleaks &>/dev/null && echo gitleaks || echo regex)" \
        '{
            ran: $ran,
            ok: $ok,
            warning: $warning,
            tool: $tool,
            findings: $findings
        }'

    return $exit_code
}

#------------------------------------------------------------------------------
# run_quality_gates: Run all quality gates for a project
#
# Args:
#   $1 - Project directory path (worktree)
#   $2 - Path to review-plan.json file
#
# Returns:
#   0 on success, 1 on test/lint failure, 2 on secret warning
#
# Outputs:
#   Combined JSON result to stdout
#------------------------------------------------------------------------------
run_quality_gates() {
    local wt_path="$1"
    local plan_file="$2"
    local repo_id=""
    local overall_ok=true
    local has_warning=false

    # Get repo ID from plan
    if [[ -f "$plan_file" ]]; then
        repo_id=$(jq -r '.repo // ""' "$plan_file")
    fi

    # Load policy for this repo
    local policy_json
    policy_json=$(load_policy_for_repo "$repo_id")

    local test_cmd lint_cmd
    test_cmd=$(echo "$policy_json" | jq -r '.test_command // ""')
    lint_cmd=$(echo "$policy_json" | jq -r '.lint_command // ""')

    # Run lint gate
    log_info "Running quality gates..."
    local lint_result
    lint_result=$(run_lint_gate "$wt_path" "$lint_cmd")
    local lint_exit=$?

    if [[ $lint_exit -eq 1 ]]; then
        overall_ok=false
        log_error "Lint gate failed"
    elif [[ $lint_exit -eq 2 ]]; then
        log_verbose "No linter configured"
    else
        log_info "Lint gate passed"
    fi

    # Run test gate
    local test_result
    test_result=$(run_test_gate "$wt_path" "$test_cmd")
    local test_exit=$?

    if [[ $test_exit -eq 1 ]]; then
        overall_ok=false
        log_error "Test gate failed"
    elif [[ $test_exit -eq 2 ]]; then
        log_verbose "No tests configured"
    else
        log_info "Test gate passed"
    fi

    # Run secret scan
    local secret_result
    secret_result=$(run_secret_scan "$wt_path")
    local secret_exit=$?

    if [[ $secret_exit -eq 1 ]]; then
        overall_ok=false
        log_error "Secret scan failed - secrets detected"
    elif [[ $secret_exit -eq 2 ]]; then
        has_warning=true
        log_warn "Secret scan warning - potential secrets detected"
    else
        log_info "Secret scan passed"
    fi

    # Combine results
    jq -n \
        --argjson tests "$test_result" \
        --argjson lint "$lint_result" \
        --argjson secrets "$secret_result" \
        --argjson overall_ok "$overall_ok" \
        --argjson has_warning "$has_warning" \
        '{
            overall_ok: $overall_ok,
            has_warning: $has_warning,
            tests: $tests,
            lint: $lint,
            secrets: $secrets
        }'

    if [[ "$overall_ok" == "false" ]]; then
        return 1
    elif [[ "$has_warning" == "true" ]]; then
        return 2
    fi
    return 0
}

#------------------------------------------------------------------------------
# update_plan_with_gates: Update review plan with quality gate results
#
# Args:
#   $1 - Path to review-plan.json file
#   $2 - Quality gates result JSON
#
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
update_plan_with_gates() {
    local plan_file="$1"
    local gates_result="$2"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found: $plan_file"
        return 1
    fi

    # Merge gates result into plan's git section
    local updated_plan
    updated_plan=$(jq --argjson gates "$gates_result" '
        .git = (.git // {}) |
        .git.tests = $gates.tests |
        .git.lint = $gates.lint |
        .git.secrets = $gates.secrets |
        .git.quality_gates_ok = $gates.overall_ok |
        .git.quality_gates_warning = $gates.has_warning
    ' "$plan_file")

    echo "$updated_plan" > "$plan_file"
    return 0
}

#------------------------------------------------------------------------------
# execute_gh_actions: Execute GitHub mutations from review-plan.json (bd-vcr9)
#
# Supports:
# - comment (issue/pr)
# - close (issue/pr)
# - label (issue only)
#
# Notes:
# - merge is intentionally not supported by policy (skipped with warning)
# - idempotence: actions with status "ok" are not re-executed (JSONL audit log)
#------------------------------------------------------------------------------

get_gh_actions_log_file() {
    echo "$(get_review_state_dir)/gh-actions.jsonl"
}

canonicalize_gh_action() {
    local action_json="$1"
    echo "$action_json" | jq -cS '.' 2>/dev/null
}

gh_action_already_executed() {
    local repo_id="$1"
    local action_canon="$2"
    local log_file
    log_file=$(get_gh_actions_log_file)

    [[ -f "$log_file" ]] || return 1
    command -v jq &>/dev/null || return 1

    jq -e -s \
        --arg repo "$repo_id" \
        --arg action "$action_canon" \
        'any(.[]; .repo == $repo and .action == $action and .status == "ok")' \
        "$log_file" >/dev/null 2>&1
}

record_gh_action_log() {
    local repo_id="$1"
    local action_canon="$2"
    local status="$3"          # ok|failed|skipped|blocked
    local message="${4:-}"

    local state_dir
    state_dir=$(get_review_state_dir)
    ensure_dir "$state_dir"

    local log_file
    log_file=$(get_gh_actions_log_file)

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Append a single JSON object per line (JSONL)
    jq -nc \
        --arg ts "$now" \
        --arg repo "$repo_id" \
        --arg action "$action_canon" \
        --arg status "$status" \
        --arg message "$message" \
        '{ts:$ts, repo:$repo, action:$action, status:$status, message:$message}' \
        >> "$log_file"
}

parse_gh_action_target() {
    local target="$1"
    local -n _type_ref=$2
    local -n _number_ref=$3

    if [[ "$target" =~ ^(issue|pr)#[0-9]+$ ]]; then
        _type_ref="${target%%#*}"
        _number_ref="${target##*#}"
        return 0
    fi

    return 1
}

execute_gh_action_comment() {
    local repo_id="$1"
    local target_type="$2"
    local number="$3"
    local body="$4"

    local output exit_code
    if [[ "$target_type" == "issue" ]]; then
        if output=$(printf '%s' "$body" | gh issue comment "$number" -R "$repo_id" --body-file - 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if output=$(printf '%s' "$body" | gh pr comment "$number" -R "$repo_id" --body-file - 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "gh comment failed for $repo_id $target_type#$number: $output"
        return "$exit_code"
    fi

    return 0
}

execute_gh_action_close() {
    local repo_id="$1"
    local target_type="$2"
    local number="$3"
    local reason="$4"
    local comment="${5:-}"

    local output exit_code
    if [[ "$target_type" == "issue" ]]; then
        if output=$(gh issue close "$number" -R "$repo_id" --reason "$reason" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        # gh pr close uses --comment (optional)
        if [[ -n "$comment" ]]; then
            if output=$(gh pr close "$number" -R "$repo_id" --comment "$comment" 2>&1); then
                exit_code=0
            else
                exit_code=$?
            fi
        else
            if output=$(gh pr close "$number" -R "$repo_id" 2>&1); then
                exit_code=0
            else
                exit_code=$?
            fi
        fi
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "gh close failed for $repo_id $target_type#$number: $output"
        return "$exit_code"
    fi

    return 0
}

execute_gh_action_label() {
    local repo_id="$1"
    local number="$2"
    local labels_csv="$3"

    local output exit_code
    if output=$(gh issue edit "$number" -R "$repo_id" --add-label "$labels_csv" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "gh label failed for $repo_id issue#$number: $output"
        return "$exit_code"
    fi

    return 0
}

execute_gh_actions() {
    local repo_id="$1"
    local plan_file="$2"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found: $plan_file"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required to execute gh_actions"
        return 1
    fi

    if ! command -v gh &>/dev/null; then
        log_error "gh CLI is required to execute gh_actions"
        return 1
    fi

    local actions_count
    if ! actions_count=$(jq '.gh_actions // [] | length' "$plan_file" 2>/dev/null); then
        log_warn "Failed to read gh_actions from plan: $plan_file"
        return 1
    fi

    if [[ "$actions_count" -eq 0 ]]; then
        log_verbose "No gh_actions in plan"
        return 0
    fi

    local any_failed=false

    while IFS= read -r action_json; do
        [[ -n "$action_json" ]] || continue

        local action_canon
        action_canon=$(canonicalize_gh_action "$action_json")
        if [[ -z "$action_canon" ]]; then
            log_warn "Skipping invalid gh_action JSON"
            continue
        fi

        # Parse operation and target
        local op target
        op=$(echo "$action_json" | jq -r '.op // ""')
        target=$(echo "$action_json" | jq -r '.target // ""')

        local target_type number
        if ! parse_gh_action_target "$target" target_type number; then
            record_gh_action_log "$repo_id" "$action_canon" "failed" "Invalid target: $target"
            log_error "Invalid gh_action target: $target"
            any_failed=true
            continue
        fi

        # Idempotence: skip actions already recorded as successful
        if gh_action_already_executed "$repo_id" "$action_canon"; then
            record_gh_action_log "$repo_id" "$action_canon" "skipped" "Already executed"
            log_verbose "Skipping already executed gh_action: $op $target"
            continue
        fi

        case "$op" in
            comment)
                local body
                body=$(echo "$action_json" | jq -r '.body // ""')
                if [[ -z "$body" ]]; then
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "Missing body for comment"
                    log_error "gh_action comment missing body: $target"
                    any_failed=true
                    continue
                fi

                log_step "Commenting on $repo_id $target"
                if execute_gh_action_comment "$repo_id" "$target_type" "$number" "$body"; then
                    record_gh_action_log "$repo_id" "$action_canon" "ok" ""
                else
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "gh comment failed"
                    any_failed=true
                fi
                ;;

            close)
                local reason comment
                reason=$(echo "$action_json" | jq -r '.reason // "completed"')
                comment=$(echo "$action_json" | jq -r '.comment // ""')
                if [[ -z "$comment" ]] && [[ "$target_type" == "pr" ]]; then
                    comment="Closing: $reason"
                fi

                log_step "Closing $repo_id $target"
                if execute_gh_action_close "$repo_id" "$target_type" "$number" "$reason" "$comment"; then
                    record_gh_action_log "$repo_id" "$action_canon" "ok" ""
                else
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "gh close failed"
                    any_failed=true
                fi
                ;;

            label)
                if [[ "$target_type" != "issue" ]]; then
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "Labels supported only for issues"
                    log_error "gh_action label unsupported target: $target"
                    any_failed=true
                    continue
                fi

                local labels_csv
                labels_csv=$(echo "$action_json" | jq -r '.labels // [] | map(tostring) | join(",")')
                if [[ -z "$labels_csv" || "$labels_csv" == "null" ]]; then
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "Missing labels"
                    log_error "gh_action label missing labels: $target"
                    any_failed=true
                    continue
                fi

                log_step "Adding labels to $repo_id $target: $labels_csv"
                if execute_gh_action_label "$repo_id" "$number" "$labels_csv"; then
                    record_gh_action_log "$repo_id" "$action_canon" "ok" ""
                else
                    record_gh_action_log "$repo_id" "$action_canon" "failed" "gh label failed"
                    any_failed=true
                fi
                ;;

            merge)
                record_gh_action_log "$repo_id" "$action_canon" "blocked" "merge not supported by policy"
                log_warn "Skipping gh_action merge for $repo_id $target (policy blocked)"
                any_failed=true
                ;;

            *)
                record_gh_action_log "$repo_id" "$action_canon" "failed" "Unknown op: $op"
                log_warn "Unknown gh_action op: $op"
                any_failed=true
                ;;
        esac
    done < <(jq -c '.gh_actions[]?' "$plan_file" 2>/dev/null)

    if [[ "$any_failed" == "true" ]]; then
        return 1
    fi
    return 0
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
