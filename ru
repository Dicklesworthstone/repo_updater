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

# Bash >= 4.0 is required (associative arrays). macOS ships Bash 3.2 by default.
if [[ -z "${BASH_VERSINFO[*]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
    printf 'ru: Bash >= 4.0 is required (found: %s)\n' "${BASH_VERSION:-unknown}" >&2

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
        printf 'ru: Install Bash 4.0+ from your package manager\n' >&2
    fi
    exit 3
fi

#==============================================================================
# SECTION 1: VERSION AND CONSTANTS
#==============================================================================

# Version: read from VERSION file, fallback to embedded
VERSION="1.2.1"
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

# Harden state directory paths against relative values
if [[ "$XDG_STATE_HOME" != /* ]]; then
    XDG_STATE_HOME="$HOME/$XDG_STATE_HOME"
fi
if [[ "$RU_STATE_DIR" != /* ]]; then
    RU_STATE_DIR="$HOME/$RU_STATE_DIR"
fi
RU_LOG_DIR="$RU_STATE_DIR/logs"

# Default configuration values
DEFAULT_PROJECTS_DIR="${RU_PROJECTS_DIR:-/data/projects}"
DEFAULT_LAYOUT="flat"           # flat | owner-repo | full
DEFAULT_UPDATE_STRATEGY="ff-only"  # ff-only | rebase | merge
DEFAULT_AUTOSTASH="false"
DEFAULT_PARALLEL="4"

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
OUTPUT_FORMAT=""  # text|json|toon (resolved after parse_args; env: RU_OUTPUT_FORMAT/TOON_DEFAULT_FORMAT)
SHOW_STATS="false"
QUIET="false"
VERBOSE="false"
DEBUG="false"
LOG_LEVEL=0  # 0=normal, 1=verbose, 2=debug
NON_INTERACTIVE="false"
DRY_RUN="false"
CLONE_ONLY="false"
PULL_ONLY="false"
FETCH_REMOTES="true"

# Results tracking (NDJSON temp file)
RESULTS_FILE=""
RESULTS_LOCK_DIR=""

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

# Optional TOON helpers (tru-backed). If missing, TOON output falls back to JSON.
# shellcheck disable=SC1090
source "${TOON_SH_PATH:-$HOME/.local/lib/toon.sh}" 2>/dev/null || true

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

_is_valid_var_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

_set_out_var() {
    local name="$1"
    local value="${2-}"

    _is_valid_var_name "$name" || return 1
    printf -v "$name" '%s' "$value"
}

_set_out_array() {
    local out_name="$1"
    shift

    _is_valid_var_name "$out_name" || return 1

    local -a tmp=("$@")
    # Use eval to assign into the caller scope.
    # Note: This works when called from the main script but NOT when the
    # caller has a local array variable (eval creates a new variable).
    # For functions using nameref (local -n), this is not needed.
    eval "$out_name=(\"\${tmp[@]}\")"
}

#------------------------------------------------------------------------------
# PORTABLE LOCKS (directory-based)
#
# We avoid hard-depending on external `flock` for cross-platform reliability.
# A lock is represented by an on-filesystem directory created via `mkdir`,
# which is atomic on POSIX filesystems.
#------------------------------------------------------------------------------

dir_lock_try_acquire() {
    local lock_dir="$1"
    mkdir "$lock_dir" 2>/dev/null
}

dir_lock_release() {
    local lock_dir="$1"
    rmdir "$lock_dir" 2>/dev/null || true
}

# Blocking acquire with timeout (seconds). Returns 0 if acquired.
dir_lock_acquire() {
    local lock_dir="$1"
    local timeout_secs="${2:-30}"
    local start now
    start=$(date +%s)

    while true; do
        if dir_lock_try_acquire "$lock_dir"; then
            return 0
        fi

        now=$(date +%s)
        if [[ "$timeout_secs" =~ ^[0-9]+$ ]] && (( now - start >= timeout_secs )); then
            return 1
        fi

        sleep 0.1
    done
}
# Ensure a directory exists
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

#------------------------------------------------------------------------------
# AGENT-SWEEP UTILITY FUNCTIONS
# Shared utilities used by agent-sweep command and related functions.
#------------------------------------------------------------------------------

# Check if repo has uncommitted changes (staged, unstaged, or untracked)
# Usage: has_uncommitted_changes /path/to/repo
# Returns: 0 if dirty (has changes), 1 if clean
has_uncommitted_changes() {
    local repo_path="${1:-}"
    [[ -z "$repo_path" ]] && return 1
    repo_is_dirty "$repo_path"
}

# Convert repo spec (owner/repo[@branch]) to local filesystem path
# Usage: repo_spec_to_path "owner/repo@branch"
# Outputs: path to stdout
repo_spec_to_path() {
    local repo_spec="${1:-}"
    [[ -z "$repo_spec" ]] && return 1

    # Use resolved config first, then env override, then default
    local projects_dir="${PROJECTS_DIR:-${RU_PROJECTS_DIR:-/data/projects}}"
    local layout="${LAYOUT:-flat}"

    # Prefer full repo spec resolution (handles custom names + layouts)
    local url branch custom_name path repo_id
    if resolve_repo_spec "$repo_spec" "$projects_dir" "$layout" \
        url branch custom_name path repo_id 2>/dev/null; then
        printf '%s\n' "$path"
        return 0
    fi

    return 1
}

# Load all repos from config files into an array
# Usage: load_all_repos array_name
# Populates the named array with repo specs
load_all_repos() {
    # shellcheck disable=SC2178  # repos_ref is a nameref to caller's array
    local -n repos_ref=$1
    repos_ref=()

    local config_dir="${RU_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ru}"
    local repos_d="${config_dir}/repos.d"

    # Load from each file in repos.d
    if [[ -d "$repos_d" ]]; then
        local file
        for file in "$repos_d"/*.txt; do
            [[ -f "$file" ]] || continue
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Skip comments and empty lines
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${line// }" ]] && continue
                repos_ref+=("$line")
            done < "$file"
        done
    fi
}

# Strip ANSI escape codes from input (useful for parsing pane output)
# Usage: echo "$text" | strip_ansi
strip_ansi() {
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Get file size in MB (for display/validation)
# Usage: get_file_size_mb /path/to/file
# Outputs: size in MB (one decimal place)
get_file_size_mb() {
    local file="${1:-}"
    [[ -z "$file" || ! -f "$file" ]] && { echo "0"; return; }

    local size_bytes
    # Try GNU stat first, fall back to BSD stat
    size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)

    # Use awk for portability (bc may not be available)
    awk "BEGIN { printf \"%.1f\", $size_bytes / 1048576 }"
}

# Check if value is a positive integer (>0)
agent_sweep_is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

# Set max file size in MB and keep bytes in sync
set_agent_sweep_max_file_mb() {
    local max_mb="${1:-}"
    if agent_sweep_is_positive_int "$max_mb"; then
        AGENT_SWEEP_MAX_FILE_MB="$max_mb"
        AGENT_SWEEP_MAX_FILE_SIZE=$((max_mb * 1024 * 1024))
        return 0
    fi
    return 1
}

# Set max file size in bytes and keep MB in sync (rounded up)
set_agent_sweep_max_file_bytes() {
    local max_bytes="${1:-}"
    if agent_sweep_is_positive_int "$max_bytes"; then
        AGENT_SWEEP_MAX_FILE_SIZE="$max_bytes"
        AGENT_SWEEP_MAX_FILE_MB=$(((max_bytes + 1048575) / 1048576))
        return 0
    fi
    return 1
}

# Apply max file size from config values (MB preferred, then bytes)
apply_agent_sweep_max_file_limit() {
    local raw_mb="${1:-}"
    local raw_bytes="${2:-}"

    if [[ -n "$raw_mb" && "$raw_mb" != "null" ]]; then
        set_agent_sweep_max_file_mb "$raw_mb" || true
        return 0
    fi

    if [[ -n "$raw_bytes" && "$raw_bytes" != "null" ]]; then
        set_agent_sweep_max_file_bytes "$raw_bytes" || true
    fi
}

# Apply CLI override for max file size (MB)
apply_agent_sweep_max_file_override() {
    local override="${AGENT_SWEEP_MAX_FILE_MB_OVERRIDE:-}"
    [[ -z "$override" ]] && return 0
    set_agent_sweep_max_file_mb "$override" || true
}

# Check if a file exceeds the max size (MB)
# Usage: is_file_too_large /path/to/file [max_mb]
# Returns: 0 if too large, 1 otherwise
is_file_too_large() {
    local file="${1:-}"
    local max_mb="${2:-${AGENT_SWEEP_MAX_FILE_MB:-0}}"
    [[ -z "$file" || ! -f "$file" ]] && return 1

    local max_bytes=""
    if agent_sweep_is_positive_int "$max_mb"; then
        max_bytes=$((max_mb * 1024 * 1024))
    elif agent_sweep_is_positive_int "${AGENT_SWEEP_MAX_FILE_SIZE:-0}"; then
        max_bytes="$AGENT_SWEEP_MAX_FILE_SIZE"
    else
        return 1
    fi
    local size_bytes
    size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    [[ "$size_bytes" -gt "$max_bytes" ]]
}

# Detect if a file is likely binary
# Returns: 0 if binary, 1 otherwise
is_binary_file() {
    local file="${1:-}"
    [[ -z "$file" || ! -f "$file" ]] && return 1

    if command -v file &>/dev/null; then
        local info
        info=$(file -b "$file" 2>/dev/null || echo "")
        if echo "$info" | grep -qiE '(text|script|json|xml|empty|ascii|utf-8|unicode)'; then
            return 1
        fi
        return 0
    fi

    # Fallback: detect NUL bytes
    if LC_ALL=C grep -q $'\x00' "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a binary file is explicitly allowed by patterns
# Usage: is_binary_allowed "path/to/file.bin"
# Returns: 0 if allowed, 1 otherwise
is_binary_allowed() {
    local file_path="${1:-}"
    [[ -z "$file_path" ]] && return 1

    file_path="${file_path#./}"
    file_path="${file_path%/}"
    local basename="${file_path##*/}"

    local -a patterns=("${AGENT_SWEEP_ALLOW_BINARY_PATTERNS_DEFAULT[@]}")
    if [[ -n "${AGENT_SWEEP_ALLOW_BINARY_PATTERNS:-}" ]]; then
        read -ra extra <<<"$AGENT_SWEEP_ALLOW_BINARY_PATTERNS"
        patterns+=("${extra[@]}")
    fi

    local pattern
    for pattern in "${patterns[@]}"; do
        # shellcheck disable=SC2254
        case "$file_path" in
            $pattern) return 0 ;;
        esac
        # shellcheck disable=SC2254
        case "$basename" in
            $pattern) return 0 ;;
        esac
    done

    return 1
}

# Check if array contains an element
# Usage: array_contains array_name "element"
# Returns: 0 if found, 1 if not found
array_contains() {
    local -n arr=$1
    local elem="$2"
    local item
    for item in "${arr[@]}"; do
        [[ "$item" == "$elem" ]] && return 0
    done
    return 1
}

# Extract repo name from path or spec
# Usage: get_repo_name "/path/to/repo" or "owner/repo@branch"
# Outputs: repo name to stdout
get_repo_name() {
    local input="${1:-}"
    [[ -z "$input" ]] && return 1
    # Handle both /path/to/repo and owner/repo formats
    # Strip @branch suffix if present
    basename "${input%%@*}"
}

#------------------------------------------------------------------------------
# PACKAGE MANAGER DETECTION
# Detect which package manager(s) a repository uses for dep-update feature.
#------------------------------------------------------------------------------

# Detect package managers in a repository by checking for manifest/lockfiles.
# Usage: detect_package_managers /path/to/repo
# Output: JSON to stdout with detected managers and trigger files
# Returns: 0 if any manager detected, 1 if none found
# Example output: {"managers":["npm","pip"],"files":{"npm":"package.json","pip":"requirements.txt"}}
detect_package_managers() {
    local repo_path="${1:-}"

    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        echo '{"managers":[],"files":{},"error":"Invalid or missing repo path"}'
        return 1
    fi

    local -a managers=()
    local -A files=()

    # npm/yarn/pnpm (Node.js)
    if [[ -f "$repo_path/package.json" ]]; then
        managers+=("npm")
        files["npm"]="package.json"
    elif [[ -f "$repo_path/package-lock.json" ]]; then
        managers+=("npm")
        files["npm"]="package-lock.json"
    elif [[ -f "$repo_path/yarn.lock" ]]; then
        managers+=("yarn")
        files["yarn"]="yarn.lock"
    elif [[ -f "$repo_path/pnpm-lock.yaml" ]]; then
        managers+=("pnpm")
        files["pnpm"]="pnpm-lock.yaml"
    fi

    # pip (Python)
    if [[ -f "$repo_path/pyproject.toml" ]]; then
        managers+=("pip")
        files["pip"]="pyproject.toml"
    elif [[ -f "$repo_path/requirements.txt" ]]; then
        managers+=("pip")
        files["pip"]="requirements.txt"
    elif [[ -f "$repo_path/setup.py" ]]; then
        managers+=("pip")
        files["pip"]="setup.py"
    elif [[ -f "$repo_path/Pipfile" ]]; then
        managers+=("pipenv")
        files["pipenv"]="Pipfile"
    fi

    # cargo (Rust)
    if [[ -f "$repo_path/Cargo.toml" ]]; then
        managers+=("cargo")
        files["cargo"]="Cargo.toml"
    fi

    # go modules (Go)
    if [[ -f "$repo_path/go.mod" ]]; then
        managers+=("go")
        files["go"]="go.mod"
    fi

    # composer (PHP)
    if [[ -f "$repo_path/composer.json" ]]; then
        managers+=("composer")
        files["composer"]="composer.json"
    fi

    # bundler (Ruby)
    if [[ -f "$repo_path/Gemfile" ]]; then
        managers+=("bundler")
        files["bundler"]="Gemfile"
    fi

    # maven (Java)
    if [[ -f "$repo_path/pom.xml" ]]; then
        managers+=("maven")
        files["maven"]="pom.xml"
    fi

    # gradle (Java/Kotlin)
    if [[ -f "$repo_path/build.gradle" ]] || [[ -f "$repo_path/build.gradle.kts" ]]; then
        managers+=("gradle")
        if [[ -f "$repo_path/build.gradle.kts" ]]; then
            files["gradle"]="build.gradle.kts"
        else
            files["gradle"]="build.gradle"
        fi
    fi

    # Build JSON output
    local json_managers json_files

    # Build managers array
    if [[ ${#managers[@]} -eq 0 ]]; then
        json_managers="[]"
    else
        json_managers=$(printf '%s\n' "${managers[@]}" | jq -R . | jq -s .)
    fi

    # Build files object
    if [[ ${#files[@]} -eq 0 ]]; then
        json_files="{}"
    else
        json_files="{"
        local first=true
        local mgr
        for mgr in "${!files[@]}"; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                json_files+=","
            fi
            # Escape values for JSON
            local escaped_mgr escaped_file
            escaped_mgr=$(printf '%s' "$mgr" | sed 's/"/\\"/g')
            escaped_file=$(printf '%s' "${files[$mgr]}" | sed 's/"/\\"/g')
            json_files+="\"$escaped_mgr\":\"$escaped_file\""
        done
        json_files+="}"
    fi

    printf '{"managers":%s,"files":%s}\n' "$json_managers" "$json_files"

    [[ ${#managers[@]} -gt 0 ]]
}

#------------------------------------------------------------------------------
# TEST RUNNER DETECTION
# Detect the appropriate test command for a repository
#------------------------------------------------------------------------------

# Detect the test command for a repository based on config files.
# Usage: detect_test_command /path/to/repo
# Output: Test command string to stdout (empty if none detected)
# Returns: 0 if test command found, 1 if none found
detect_test_command() {
    local repo_path="${1:-}"

    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        return 1
    fi

    # 1. Check package.json scripts.test (npm/node projects)
    if [[ -f "$repo_path/package.json" ]]; then
        local test_script
        test_script=$(jq -r '.scripts.test // empty' "$repo_path/package.json" 2>/dev/null)
        if [[ -n "$test_script" && "$test_script" != "null" ]]; then
            echo "npm test"
            return 0
        fi

        # Check for jest config
        if [[ -f "$repo_path/jest.config.js" || -f "$repo_path/jest.config.ts" || -f "$repo_path/jest.config.json" ]]; then
            echo "npx jest"
            return 0
        fi

        # Check for vitest
        if [[ -f "$repo_path/vitest.config.js" || -f "$repo_path/vitest.config.ts" ]]; then
            echo "npx vitest run"
            return 0
        fi
    fi

    # 2. Cargo (Rust)
    if [[ -f "$repo_path/Cargo.toml" ]]; then
        echo "cargo test"
        return 0
    fi

    # 3. Go modules
    if [[ -f "$repo_path/go.mod" ]]; then
        # Check if there are test files
        if find "$repo_path" -maxdepth 3 -name "*_test.go" -type f 2>/dev/null | head -1 | grep -q .; then
            echo "go test ./..."
            return 0
        fi
    fi

    # 4. Python - pytest
    if [[ -f "$repo_path/pytest.ini" || -f "$repo_path/conftest.py" || -f "$repo_path/pyproject.toml" ]]; then
        # Check for pytest in pyproject.toml
        if [[ -f "$repo_path/pyproject.toml" ]] && grep -q "pytest" "$repo_path/pyproject.toml" 2>/dev/null; then
            echo "pytest"
            return 0
        fi
        # Check for pytest.ini or conftest.py
        if [[ -f "$repo_path/pytest.ini" || -f "$repo_path/conftest.py" ]]; then
            echo "pytest"
            return 0
        fi
    fi

    # Check for test directory with python tests
    if [[ -d "$repo_path/tests" ]] && find "$repo_path/tests" -maxdepth 2 -name "test_*.py" -type f 2>/dev/null | head -1 | grep -q .; then
        echo "pytest"
        return 0
    fi

    # 5. Ruby - bundler/rake
    if [[ -f "$repo_path/Gemfile" ]]; then
        if grep -q "rspec" "$repo_path/Gemfile" 2>/dev/null; then
            echo "bundle exec rspec"
            return 0
        fi
        if [[ -f "$repo_path/Rakefile" ]] && grep -q "test" "$repo_path/Rakefile" 2>/dev/null; then
            echo "bundle exec rake test"
            return 0
        fi
    fi

    # 6. Maven (Java)
    if [[ -f "$repo_path/pom.xml" ]]; then
        echo "mvn test"
        return 0
    fi

    # 7. Gradle (Java/Kotlin)
    if [[ -f "$repo_path/build.gradle" || -f "$repo_path/build.gradle.kts" ]]; then
        if [[ -f "$repo_path/gradlew" ]]; then
            echo "./gradlew test"
        else
            echo "gradle test"
        fi
        return 0
    fi

    # 8. Makefile with test target (fallback)
    if [[ -f "$repo_path/Makefile" ]]; then
        if grep -qE "^test:" "$repo_path/Makefile" 2>/dev/null; then
            echo "make test"
            return 0
        fi
    fi

    # 9. PHP Composer
    if [[ -f "$repo_path/composer.json" ]]; then
        local test_script
        test_script=$(jq -r '.scripts.test // empty' "$repo_path/composer.json" 2>/dev/null)
        if [[ -n "$test_script" && "$test_script" != "null" ]]; then
            echo "composer test"
            return 0
        fi
        if [[ -f "$repo_path/phpunit.xml" || -f "$repo_path/phpunit.xml.dist" ]]; then
            echo "vendor/bin/phpunit"
            return 0
        fi
    fi

    # No test command detected
    return 1
}

#------------------------------------------------------------------------------
# DEPENDENCY VERSION CHECKING
# Check for outdated dependencies per package manager
#------------------------------------------------------------------------------

# Check for outdated dependencies in a repository.
# Usage: check_outdated_deps <repo_path> [manager]
# Output: JSON to stdout with outdated dependencies
# Returns: 0 if any outdated deps found, 1 if all current or error
# If manager is omitted, checks all detected managers
check_outdated_deps() {
    local repo_path="${1:-}"
    local specific_manager="${2:-}"

    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        echo '{"error":"Invalid or missing repo path","outdated":[]}'
        return 1
    fi

    # Get detected managers if not specified
    local -a managers=()
    if [[ -n "$specific_manager" ]]; then
        managers=("$specific_manager")
    else
        local detected
        detected=$(detect_package_managers "$repo_path")
        if [[ -n "$detected" ]]; then
            readarray -t managers < <(echo "$detected" | jq -r '.managers[]' 2>/dev/null)
        fi
    fi

    if [[ ${#managers[@]} -eq 0 ]]; then
        echo '{"managers":[],"outdated":[],"error":"No package managers detected"}'
        return 1
    fi

    local -a all_results=()
    local total_outdated=0

    for manager in "${managers[@]}"; do
        local result
        result=$(_check_outdated_for_manager "$repo_path" "$manager")
        if [[ -n "$result" ]]; then
            all_results+=("$result")
            local count
            count=$(echo "$result" | jq '.outdated | length' 2>/dev/null || echo 0)
            total_outdated=$((total_outdated + count))
        fi
    done

    # Combine results
    if [[ ${#all_results[@]} -eq 0 ]]; then
        echo '{"managers":[],"outdated":[]}'
        return 1
    fi

    # Build combined JSON
    printf '{"managers":%s,"results":[%s],"total_outdated":%d}\n' \
        "$(printf '%s\n' "${managers[@]}" | jq -R . | jq -s .)" \
        "$(IFS=,; echo "${all_results[*]}")" \
        "$total_outdated"

    [[ $total_outdated -gt 0 ]]
}

# Internal function to check outdated deps for a specific manager.
# Usage: _check_outdated_for_manager <repo_path> <manager>
_check_outdated_for_manager() {
    local repo_path="$1"
    local manager="$2"
    local output=""

    case "$manager" in
        npm|yarn|pnpm)
            # npm outdated --json returns non-zero if outdated packages exist
            output=$(cd "$repo_path" && npm outdated --json 2>/dev/null || true)
            if [[ -n "$output" && "$output" != "{}" ]]; then
                # Parse npm outdated JSON format: {"pkg": {"current": "x", "wanted": "y", "latest": "z"}}
                local json_array
                json_array=$(echo "$output" | jq -r 'to_entries | map({name: .key, current: .value.current, wanted: .value.wanted, latest: .value.latest, type: .value.type})' 2>/dev/null || echo "[]")
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        pip|pipenv)
            output=$(cd "$repo_path" && pip list --outdated --format=json 2>/dev/null || true)
            if [[ -n "$output" && "$output" != "[]" ]]; then
                # pip returns: [{"name": "pkg", "version": "current", "latest_version": "latest"}]
                local json_array
                json_array=$(echo "$output" | jq 'map({name: .name, current: .version, latest: .latest_version, type: .latest_filetype})' 2>/dev/null || echo "[]")
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        cargo)
            # cargo-outdated is an optional tool
            if ! command -v cargo-outdated &>/dev/null && ! cargo outdated --version &>/dev/null 2>&1; then
                printf '{"manager":"%s","outdated":[],"warning":"cargo-outdated not installed"}\n' "$manager"
                return
            fi
            output=$(cd "$repo_path" && cargo outdated --format json 2>/dev/null || true)
            if [[ -n "$output" ]]; then
                # cargo outdated returns: {"dependencies": [{"name": "pkg", "project": "cur", "latest": "x"}]}
                local json_array
                json_array=$(echo "$output" | jq '.dependencies | map({name: .name, current: .project, latest: .latest})' 2>/dev/null || echo "[]")
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        go)
            output=$(cd "$repo_path" && go list -m -u -json all 2>/dev/null || true)
            if [[ -n "$output" ]]; then
                # go list returns NDJSON, parse it
                local json_array
                json_array=$(echo "$output" | jq -s '[.[] | select(.Update != null) | {name: .Path, current: .Version, latest: .Update.Version}]' 2>/dev/null || echo "[]")
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        composer)
            output=$(cd "$repo_path" && composer outdated --format=json 2>/dev/null || true)
            if [[ -n "$output" ]]; then
                # composer returns: {"installed": [{"name": "pkg", "version": "cur", "latest": "x"}]}
                local json_array
                json_array=$(echo "$output" | jq '.installed // [] | map({name: .name, current: .version, latest: .latest})' 2>/dev/null || echo "[]")
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        bundler)
            output=$(cd "$repo_path" && bundle outdated --parseable 2>/dev/null || true)
            if [[ -n "$output" ]]; then
                # bundle outdated --parseable returns: pkg (newest x.y.z, installed a.b.c)
                # Build JSON array using jq for proper escaping
                local json_array="[]"
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    local name current latest
                    # Parse: "pkg (newest x.y.z, installed a.b.c, requested ~> m.n)"
                    name=$(echo "$line" | sed -E 's/^([^ ]+) .*/\1/')
                    latest=$(echo "$line" | sed -E 's/.*newest ([^,)]+).*/\1/')
                    current=$(echo "$line" | sed -E 's/.*installed ([^,)]+).*/\1/')
                    if [[ -n "$name" && -n "$current" && -n "$latest" ]]; then
                        json_array=$(echo "$json_array" | jq --arg n "$name" --arg c "$current" --arg l "$latest" \
                            '. + [{name: $n, current: $c, latest: $l}]')
                    fi
                done <<< "$output"
                printf '{"manager":"%s","outdated":%s}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        maven)
            # Maven versions plugin requires specific setup
            output=$(cd "$repo_path" && mvn versions:display-dependency-updates -DprocessDependencyManagement=false -q 2>/dev/null || true)
            if [[ -n "$output" ]]; then
                # Parse Maven output (text format) - this is a simplified version
                local json_array="[]"
                printf '{"manager":"%s","outdated":%s,"note":"Run mvn versions:display-dependency-updates for details"}\n' "$manager" "$json_array"
                return
            fi
            printf '{"manager":"%s","outdated":[]}\n' "$manager"
            ;;

        gradle)
            # Gradle requires plugins for version checking
            printf '{"manager":"%s","outdated":[],"note":"Use gradle-versions-plugin for dependency updates"}\n' "$manager"
            ;;

        *)
            printf '{"manager":"%s","outdated":[],"error":"Unsupported manager"}\n' "$manager"
            ;;
    esac
}

#------------------------------------------------------------------------------
# CHANGELOG FETCHER
# Fetch release notes/changelogs for package updates
#------------------------------------------------------------------------------

# Fetch changelog/release notes for a package between versions.
# Usage: fetch_changelog <package_name> <from_version> <to_version> [--manager=npm]
# Output: Markdown text to stdout with relevant changelog entries
# Returns: 0 if changelog found, 1 if not found
fetch_changelog() {
    local package_name=""
    local from_version=""
    local to_version=""
    local manager="npm"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manager=*)
                manager="${1#*=}"
                shift
                ;;
            -*)
                shift
                ;;
            *)
                if [[ -z "$package_name" ]]; then
                    package_name="$1"
                elif [[ -z "$from_version" ]]; then
                    from_version="$1"
                elif [[ -z "$to_version" ]]; then
                    to_version="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$package_name" || -z "$from_version" || -z "$to_version" ]]; then
        echo "# No changelog found"
        echo "Missing required arguments (package, from_version, to_version)"
        return 1
    fi

    # Try to get changelog based on manager
    local changelog=""
    case "$manager" in
        npm|yarn|pnpm)
            changelog=$(_fetch_npm_changelog "$package_name" "$from_version" "$to_version")
            ;;
        pip|pipenv)
            changelog=$(_fetch_pypi_changelog "$package_name" "$from_version" "$to_version")
            ;;
        cargo)
            changelog=$(_fetch_crates_changelog "$package_name" "$from_version" "$to_version")
            ;;
        go)
            changelog=$(_fetch_go_changelog "$package_name" "$from_version" "$to_version")
            ;;
        *)
            echo "# No changelog found"
            echo "Unsupported package manager: $manager"
            return 1
            ;;
    esac

    if [[ -n "$changelog" ]]; then
        echo "$changelog"
        return 0
    fi

    echo "# No changelog found"
    echo "Could not find changelog for $package_name ($from_version -> $to_version)"
    return 1
}

# Fetch changelog for npm package via GitHub releases.
# Usage: _fetch_npm_changelog <package> <from> <to>
_fetch_npm_changelog() {
    local package="$1"
    local from_version="$2"
    local to_version="$3"

    # Get package info from npm registry
    local npm_info
    npm_info=$(curl -sf "https://registry.npmjs.org/$package" 2>/dev/null)
    if [[ -z "$npm_info" ]]; then
        return 1
    fi

    # Extract repository URL
    local repo_url
    repo_url=$(echo "$npm_info" | jq -r '.repository.url // .repository // empty' 2>/dev/null)
    if [[ -z "$repo_url" ]]; then
        return 1
    fi

    # Convert to GitHub API URL
    local github_repo
    github_repo=$(_extract_github_repo "$repo_url")
    if [[ -z "$github_repo" ]]; then
        return 1
    fi

    # Fetch GitHub releases
    _fetch_github_releases "$github_repo" "$from_version" "$to_version"
}

# Fetch changelog for PyPI package via GitHub releases.
_fetch_pypi_changelog() {
    local package="$1"
    local from_version="$2"
    local to_version="$3"

    # Get package info from PyPI
    local pypi_info
    pypi_info=$(curl -sf "https://pypi.org/pypi/$package/json" 2>/dev/null)
    if [[ -z "$pypi_info" ]]; then
        return 1
    fi

    # Extract project URLs
    local repo_url
    repo_url=$(echo "$pypi_info" | jq -r '.info.project_urls.Repository // .info.project_urls.Source // .info.home_page // empty' 2>/dev/null)
    if [[ -z "$repo_url" ]]; then
        return 1
    fi

    local github_repo
    github_repo=$(_extract_github_repo "$repo_url")
    if [[ -z "$github_repo" ]]; then
        return 1
    fi

    _fetch_github_releases "$github_repo" "$from_version" "$to_version"
}

# Fetch changelog for crates.io package.
_fetch_crates_changelog() {
    local package="$1"
    local from_version="$2"
    local to_version="$3"

    # Get crate info
    local crate_info
    crate_info=$(curl -sf "https://crates.io/api/v1/crates/$package" 2>/dev/null)
    if [[ -z "$crate_info" ]]; then
        return 1
    fi

    local repo_url
    repo_url=$(echo "$crate_info" | jq -r '.crate.repository // empty' 2>/dev/null)
    if [[ -z "$repo_url" ]]; then
        return 1
    fi

    local github_repo
    github_repo=$(_extract_github_repo "$repo_url")
    if [[ -z "$github_repo" ]]; then
        return 1
    fi

    _fetch_github_releases "$github_repo" "$from_version" "$to_version"
}

# Fetch changelog for Go module (usually from GitHub).
_fetch_go_changelog() {
    local module="$1"
    local from_version="$2"
    local to_version="$3"

    # Go modules typically are GitHub repos
    local github_repo=""
    if [[ "$module" == github.com/* ]]; then
        github_repo="${module#github.com/}"
        # Take only owner/repo (first two path segments)
        github_repo=$(echo "$github_repo" | cut -d'/' -f1-2)
    else
        return 1
    fi

    _fetch_github_releases "$github_repo" "$from_version" "$to_version"
}

# Extract GitHub owner/repo from various URL formats.
_extract_github_repo() {
    local url="$1"

    # Handle various formats:
    # https://github.com/owner/repo
    # git+https://github.com/owner/repo.git
    # git://github.com/owner/repo.git
    # git@github.com:owner/repo.git
    # github:owner/repo

    local repo=""

    if [[ "$url" == *"github.com"* ]]; then
        # Extract owner/repo from URL
        repo=$(echo "$url" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|')
    elif [[ "$url" == github:* ]]; then
        repo="${url#github:}"
    fi

    if [[ -n "$repo" && "$repo" != "$url" ]]; then
        echo "$repo"
    fi
}

# Fetch GitHub releases between versions.
# Usage: _fetch_github_releases <owner/repo> <from_version> <to_version>
_fetch_github_releases() {
    local repo="$1"
    local from_version="$2"
    local to_version="$3"

    # Fetch recent releases from GitHub
    local releases
    releases=$(curl -sf "https://api.github.com/repos/$repo/releases?per_page=50" 2>/dev/null)
    if [[ -z "$releases" || "$releases" == "[]" ]]; then
        # Try tags if no releases
        return 1
    fi

    # Get recent releases and format as markdown
    # Note: Proper semantic version filtering is complex; we fetch recent releases
    # and let the AI agent determine which are relevant for the upgrade path
    local changelog=""
    changelog=$(echo "$releases" | jq -r '
        .[:10] | .[] |
        "## " + .tag_name + " (" + (.published_at // .created_at | split("T")[0]) + ")\n\n" + (.body // "No release notes") + "\n"
    ' 2>/dev/null)

    if [[ -n "$changelog" ]]; then
        echo "# Changelog for $repo"
        echo "## Versions: $from_version -> $to_version"
        echo ""
        echo "$changelog"
        return 0
    fi

    return 1
}

#------------------------------------------------------------------------------
# DIRTY REPO DETECTION
# Find repos with uncommitted changes (staged, unstaged, untracked)
#------------------------------------------------------------------------------

# Get list of repos with uncommitted changes.
# Usage: get_dirty_repos [--no-untracked] [--json]
# Output: Newline-separated repo paths to stdout (or JSON array with --json)
# Returns: 0 if any dirty repos found, 1 if all clean
# Example: get_dirty_repos --json → [{"path":"/data/projects/foo","status":"dirty"}]
get_dirty_repos() {
    local include_untracked="true"
    local json_output="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-untracked)
                include_untracked="false"
                shift
                ;;
            --json)
                json_output="true"
                shift
                ;;
            *)
                log_error "get_dirty_repos: Unknown option: $1"
                return 4
                ;;
        esac
    done

    local -a dirty_repos=()
    local spec url branch custom_name local_path repo_id

    # Iterate through all configured repos
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue

        # Resolve spec to get local path
        if ! resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
            log_warn "get_dirty_repos: Cannot resolve spec: $spec"
            continue
        fi

        # Skip if repo doesn't exist
        if [[ ! -d "$local_path" ]]; then
            log_debug "get_dirty_repos: Repo not cloned: $local_path"
            continue
        fi

        # Skip if not a git repo
        if [[ ! -d "$local_path/.git" ]]; then
            log_warn "get_dirty_repos: Not a git repo: $local_path"
            continue
        fi

        # Check for dirty status using git plumbing
        local status_output
        if [[ "$include_untracked" == "true" ]]; then
            # Include untracked files
            status_output=$(git -C "$local_path" status --porcelain 2>/dev/null)
        else
            # Exclude untracked files (only staged and unstaged changes)
            status_output=$(git -C "$local_path" status --porcelain --untracked-files=no 2>/dev/null)
        fi

        if [[ -n "$status_output" ]]; then
            dirty_repos+=("$local_path")
        fi
    done < <(get_all_repos)

    # Output results
    if [[ "$json_output" == "true" ]]; then
        if [[ ${#dirty_repos[@]} -eq 0 ]]; then
            echo "[]"
        else
            local json_array="["
            local first="true"
            for path in "${dirty_repos[@]}"; do
                if [[ "$first" == "true" ]]; then
                    first="false"
                else
                    json_array+=","
                fi
                local safe_path
                safe_path=$(json_escape "$path")
                json_array+="{\"path\":\"$safe_path\",\"status\":\"dirty\"}"
            done
            json_array+="]"
            echo "$json_array"
        fi
    else
        # Plain text output - one path per line
        for path in "${dirty_repos[@]}"; do
            printf '%s\n' "$path"
        done
    fi

    [[ ${#dirty_repos[@]} -gt 0 ]]
}

#------------------------------------------------------------------------------
# NTM SESSION SPAWNING
# Wrapper for spawning AI coding sessions via ntm (Named Tmux Manager)
#------------------------------------------------------------------------------

# Spawn an ntm session for AI-assisted operations on a repository.
# Usage: spawn_ai_session <repo_path> <prompt_file> [timeout_seconds] [--agent=claude|codex|gemini]
# Output: JSON status to stdout {"session":"name","status":"success|timeout|failed","duration_seconds":N}
# Returns: 0 on success, 1 on timeout, 2 on failure
spawn_ai_session() {
    local repo_path=""
    local prompt_file=""
    local timeout_seconds=600
    local agent_type="claude"
    local session_prefix="ru-ai"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent=*)
                agent_type="${1#*=}"
                shift
                ;;
            --timeout=*)
                timeout_seconds="${1#*=}"
                shift
                ;;
            --prefix=*)
                session_prefix="${1#*=}"
                shift
                ;;
            -*)
                log_error "spawn_ai_session: Unknown option: $1"
                return 2
                ;;
            *)
                if [[ -z "$repo_path" ]]; then
                    repo_path="$1"
                elif [[ -z "$prompt_file" ]]; then
                    prompt_file="$1"
                else
                    timeout_seconds="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$repo_path" ]]; then
        log_error "spawn_ai_session: repo_path is required"
        echo '{"session":"","status":"failed","error":"repo_path required"}'
        return 2
    fi

    if [[ ! -d "$repo_path" ]]; then
        log_error "spawn_ai_session: repo not found: $repo_path"
        echo '{"session":"","status":"failed","error":"repo not found"}'
        return 2
    fi

    if [[ -z "$prompt_file" ]]; then
        log_error "spawn_ai_session: prompt_file is required"
        echo '{"session":"","status":"failed","error":"prompt_file required"}'
        return 2
    fi

    if [[ ! -f "$prompt_file" ]]; then
        log_error "spawn_ai_session: prompt file not found: $prompt_file"
        echo '{"session":"","status":"failed","error":"prompt file not found"}'
        return 2
    fi

    # Check ntm availability
    if ! command -v ntm &>/dev/null; then
        log_error "spawn_ai_session: ntm not installed"
        echo '{"session":"","status":"failed","error":"ntm not installed"}'
        return 2
    fi

    # Generate unique session name from repo path
    local repo_name
    repo_name=$(basename "$repo_path")
    local timestamp
    timestamp=$(date +%s)
    local session_name="${session_prefix}-${repo_name}-${timestamp}"

    # Map agent type to ntm flags
    # agent_flag is for spawn (--cc=1), send_flag is for send (--cc)
    local agent_flag send_flag
    case "$agent_type" in
        claude|cc)  agent_flag="--cc=1"; send_flag="--cc" ;;
        codex|cod)  agent_flag="--cod=1"; send_flag="--cod" ;;
        gemini|gmi) agent_flag="--gmi=1"; send_flag="--gmi" ;;
        *)
            log_error "spawn_ai_session: Unknown agent type: $agent_type"
            echo '{"session":"","status":"failed","error":"unknown agent type"}'
            return 2
            ;;
    esac

    local start_time
    start_time=$(date +%s)

    # Spawn the session with initial prompt
    log_info "Spawning ntm session: $session_name"
    if ! ntm spawn "$session_name" $agent_flag --no-user 2>/dev/null; then
        log_error "spawn_ai_session: Failed to spawn session"
        echo '{"session":"'"$session_name"'","status":"failed","error":"spawn failed"}'
        return 2
    fi

    # Change to repo directory and send the prompt
    # Use tmux to cd first, then send the prompt file contents
    local pane_target="${session_name}:0.0"

    # CD to repo directory
    tmux send-keys -t "$pane_target" "cd $(printf '%q' "$repo_path")" Enter 2>/dev/null
    sleep 1

    # Send the prompt from file
    if ! ntm send "$session_name" $send_flag --file "$prompt_file" 2>/dev/null; then
        log_error "spawn_ai_session: Failed to send prompt"
        ntm kill "$session_name" --force 2>/dev/null
        echo '{"session":"'"$session_name"'","status":"failed","error":"send prompt failed"}'
        return 2
    fi

    # Wait for completion with timeout
    # Poll health status until agent shows as idle/completed or timeout
    local elapsed=0
    local poll_interval=10
    local status="running"

    log_info "Waiting for session completion (timeout: ${timeout_seconds}s)"

    while [[ $elapsed -lt $timeout_seconds ]]; do
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))

        # Check if session still exists
        if ! tmux has-session -t "$session_name" 2>/dev/null; then
            status="completed"
            break
        fi

        # Check agent health
        local health_output
        health_output=$(ntm health "$session_name" --json 2>/dev/null)

        if [[ -n "$health_output" ]]; then
            # Check if agent is idle (no recent activity)
            local activity
            activity=$(echo "$health_output" | jq -r '.panes[0].activity // "unknown"' 2>/dev/null)

            if [[ "$activity" == "idle" || "$activity" == "stale" ]]; then
                # Agent appears to be done - give it a moment then check again
                sleep 5
                health_output=$(ntm health "$session_name" --json 2>/dev/null)
                activity=$(echo "$health_output" | jq -r '.panes[0].activity // "unknown"' 2>/dev/null)

                if [[ "$activity" == "idle" || "$activity" == "stale" ]]; then
                    status="completed"
                    break
                fi
            fi
        fi

        log_debug "Session $session_name still running (${elapsed}s/${timeout_seconds}s)"
    done

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Clean up the session
    if tmux has-session -t "$session_name" 2>/dev/null; then
        ntm kill "$session_name" --force 2>/dev/null
    fi

    # Return results
    if [[ "$status" == "completed" ]]; then
        log_success "Session completed in ${duration}s"
        printf '{"session":"%s","status":"success","duration_seconds":%d}\n' "$session_name" "$duration"
        return 0
    else
        log_warn "Session timed out after ${duration}s"
        printf '{"session":"%s","status":"timeout","duration_seconds":%d}\n' "$session_name" "$duration"
        return 1
    fi
}

# Check if an ntm session is still running.
# Usage: is_session_active <session_name>
# Returns: 0 if active, 1 if not
is_session_active() {
    local session_name="$1"
    [[ -n "$session_name" ]] && tmux has-session -t "$session_name" 2>/dev/null
}

# Kill an ntm session forcefully.
# Usage: kill_ai_session <session_name>
# Returns: 0 on success, 1 on failure
kill_ai_session() {
    local session_name="$1"
    if [[ -z "$session_name" ]]; then
        log_error "kill_ai_session: session_name required"
        return 1
    fi

    if is_session_active "$session_name"; then
        ntm kill "$session_name" --force 2>/dev/null
        return $?
    fi
    return 0
}

#------------------------------------------------------------------------------
# AI-SYNC PROMPT TEMPLATES
# Two-phase prompts for intelligent repository sync via AI agents
#------------------------------------------------------------------------------

# Generate Phase 1 prompt for context acquisition.
# Usage: generate_aisync_prompt_phase1 <repo_path>
# Output: Prompt text to stdout
generate_aisync_prompt_phase1() {
    local repo_path="$1"
    local has_agents_md="false"
    local has_readme="false"

    [[ -f "$repo_path/AGENTS.md" ]] && has_agents_md="true"
    [[ -f "$repo_path/README.md" || -f "$repo_path/readme.md" ]] && has_readme="true"

    # Build dynamic prompt based on available documentation
    local prompt=""

    if [[ "$has_agents_md" == "true" && "$has_readme" == "true" ]]; then
        prompt="First read ALL of the AGENTS.md file and README.md file super carefully and understand ALL of both!
Then use your code investigation agent mode to fully understand the code, technical architecture, and purpose of the project."
    elif [[ "$has_agents_md" == "true" ]]; then
        prompt="First read ALL of the AGENTS.md file super carefully and understand everything in it!
Then use your code investigation agent mode to fully understand the code, technical architecture, and purpose of the project."
    elif [[ "$has_readme" == "true" ]]; then
        prompt="First read ALL of the README.md file super carefully and understand everything in it!
Then use your code investigation agent mode to fully understand the code, technical architecture, and purpose of the project."
    else
        prompt="Use your code investigation agent mode to fully understand the code, technical architecture, and purpose of this project.
Explore the directory structure, key files, and understand what this codebase does."
    fi

    printf '%s\n' "$prompt"
}

# Generate Phase 2 prompt for intelligent commit.
# Usage: generate_aisync_prompt_phase2 [--branch=NAME] [--remote=NAME] [--no-push]
# Output: Prompt text to stdout
generate_aisync_prompt_phase2() {
    local branch_name=""
    local remote_name="origin"
    local push_enabled="true"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch=*)
                branch_name="${1#*=}"
                shift
                ;;
            --remote=*)
                remote_name="${1#*=}"
                shift
                ;;
            --no-push)
                push_enabled="false"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local prompt="Now, based on your knowledge of the project, commit all changed files now in a series of logically connected groupings with super detailed commit messages for each"

    if [[ "$push_enabled" == "true" ]]; then
        prompt+=" and then push"
        if [[ -n "$branch_name" ]]; then
            prompt+=" to $remote_name/$branch_name"
        fi
    fi

    prompt+=".

Take your time to do it right. Don't edit the code at all. Don't commit obviously ephemeral files (like .pyc, node_modules, __pycache__, etc). Use ultrathink.

Guidelines:
- Group related changes into logical commits (e.g., 'fix: auth bug' separate from 'chore: update deps')
- Write detailed commit messages explaining WHY, not just what
- If there are staged vs unstaged changes, consider if they should be separate commits
- Skip any temporary or generated files
- Review each change before committing to ensure it makes sense"

    printf '%s\n' "$prompt"
}

# Write prompt to a temporary file for use with spawn_ai_session.
# Usage: write_prompt_to_file <prompt_text>
# Output: Path to temp file on stdout
# Returns: 0 on success, 1 on failure
write_prompt_to_file() {
    local prompt="$1"
    local temp_file

    temp_file=$(mktemp_file) || return 1
    printf '%s\n' "$prompt" > "$temp_file"
    echo "$temp_file"
}

# Generate combined two-phase prompt for single session (alternative approach).
# Usage: generate_aisync_prompt_combined <repo_path> [--no-push]
# Output: Combined prompt text to stdout
generate_aisync_prompt_combined() {
    local repo_path="$1"
    shift

    local phase1
    local phase2
    phase1=$(generate_aisync_prompt_phase1 "$repo_path")
    phase2=$(generate_aisync_prompt_phase2 "$@")

    printf '%s\n\n---\n\nOnce you have fully understood the project:\n\n%s\n' "$phase1" "$phase2"
}

#------------------------------------------------------------------------------
# DEP-UPDATE PROMPT TEMPLATES
# Two-phase prompts for AI-powered dependency updates
#------------------------------------------------------------------------------

# Generate Phase 1 prompt for dep-update: Analysis of outdated dependencies.
# Usage: generate_depupdate_prompt_phase1 <repo_path> <outdated_json> [changelog_text]
# Arguments:
#   repo_path     - Path to repository being updated
#   outdated_json - JSON output from check_outdated_deps()
#   changelog_text - Optional: Pre-fetched changelog content
# Output: Prompt text to stdout
generate_depupdate_prompt_phase1() {
    local repo_path="$1"
    local outdated_json="$2"
    local changelog_text="${3:-}"
    local repo_name
    repo_name=$(basename "$repo_path")

    local prompt
    prompt="You are a dependency update assistant analyzing the '$repo_name' project.

## Project Location
$repo_path

## Your Task - ANALYSIS ONLY

Review the outdated dependencies below and create an update plan. Do NOT make any changes yet.

## Outdated Dependencies

$outdated_json

## Changelogs & Release Notes

${changelog_text:-No changelogs provided. Check package documentation for breaking changes.}

## Analysis Steps

1. **Review Each Dependency**: For each outdated package:
   - Note the current version vs latest version
   - Check if it's a major/minor/patch update
   - Review changelog for breaking changes

2. **Identify Breaking Changes**: Look for:
   - API changes that require code modifications
   - Deprecated features being removed
   - New required configuration
   - Peer dependency conflicts

3. **Create Migration Plan**: For each dependency:
   - List specific code changes needed (if any)
   - Note the order of updates (dependencies first)
   - Flag any risky updates that need extra testing

4. **Risk Assessment**:
   - LOW: Patch updates, no breaking changes
   - MEDIUM: Minor updates with deprecation warnings
   - HIGH: Major updates with breaking changes

Output your analysis in markdown format with sections for each dependency."

    printf '%s\n' "$prompt"
}

# Generate Phase 2 prompt for dep-update: Update, test, and fix loop.
# Usage: generate_depupdate_prompt_phase2 <repo_path> <test_command> [--max-attempts=N]
# Arguments:
#   repo_path    - Path to repository being updated
#   test_command - Command to run tests (e.g., "npm test")
#   --max-attempts=N - Maximum fix attempts per dependency (default: 3)
# Output: Prompt text to stdout
generate_depupdate_prompt_phase2() {
    local repo_path="$1"
    local test_command="$2"
    shift 2

    local max_attempts=3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-attempts=*)
                max_attempts="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local prompt
    prompt="## Your Task - UPDATE DEPENDENCIES

Now implement the migration plan. For each dependency:

### Update Loop (repeat for each dependency)

1. **Update the dependency version**
   - Edit the manifest file (package.json, Cargo.toml, etc.)
   - Run the package manager's install/update command

2. **Make code changes** (if needed from your analysis)
   - Update import statements
   - Fix deprecated API usage
   - Add any new required configuration

3. **Run tests**
   \`\`\`bash
   ${test_command:-echo 'No test command detected - check manually'}
   \`\`\`

4. **If tests fail** (max $max_attempts attempts per dependency):
   - Read the error messages carefully
   - Fix the issues in the code
   - Re-run tests
   - If still failing after $max_attempts attempts, revert this dependency and note it as blocked

5. **Commit the change**
   - One commit per dependency (or logical group)
   - Format: \"chore(deps): update <package> from <old> to <new>\"
   - Include any code changes in the same commit

### Important Guidelines

- **Order matters**: Update dependencies before dependents
- **Atomic commits**: Each dependency update should be a single working commit
- **Don't break the build**: If an update can't be fixed, revert it
- **Document blockers**: Note any dependencies that couldn't be updated and why

### After All Updates

1. Run the full test suite one more time
2. Check for any peer dependency warnings
3. Summarize what was updated and what was blocked"

    printf '%s\n' "$prompt"
}

# Generate combined dep-update prompt for single session.
# Usage: generate_depupdate_prompt_combined <repo_path> <outdated_json> <test_command> [options]
# Options:
#   --changelog=TEXT   Pre-fetched changelog content
#   --max-attempts=N   Max fix attempts per dep (default: 3)
# Output: Combined prompt text to stdout
generate_depupdate_prompt_combined() {
    local repo_path="$1"
    local outdated_json="$2"
    local test_command="$3"
    shift 3

    local changelog_text=""
    local max_attempts=3

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --changelog=*)
                changelog_text="${1#*=}"
                shift
                ;;
            --max-attempts=*)
                max_attempts="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local phase1
    local phase2
    phase1=$(generate_depupdate_prompt_phase1 "$repo_path" "$outdated_json" "$changelog_text")
    phase2=$(generate_depupdate_prompt_phase2 "$repo_path" "$test_command" "--max-attempts=$max_attempts")

    printf '%s\n\n---\n\nOnce you have completed your analysis:\n\n%s\n' "$phase1" "$phase2"
}

#------------------------------------------------------------------------------
# AI-SYNC SUBCOMMAND
# Automatically sync dirty repos using AI-powered commits via ntm
#------------------------------------------------------------------------------

# cmd_ai_sync - Main entry point for ai-sync subcommand
# Usage: ru ai-sync [OPTIONS]
#   --dry-run       Show which repos would be processed
#   --include=PAT   Only process repos matching pattern
#   --exclude=PAT   Skip repos matching pattern
#   --sequential    Process one at a time (default)
#   --timeout=SEC   Per-repo timeout (default: 600)
#   --no-push       Commit but don't push
#   --agent=TYPE    Agent type: claude (default), codex, gemini
cmd_ai_sync() {
    local dry_run="false"
    local include_pattern=""
    local exclude_pattern=""
    local timeout_seconds=600
    local no_push="false"
    local agent_type="claude"
    local include_untracked="true"

    # Parse command arguments from ARGS array
    local arg
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            -h|--help)
                _ai_sync_help
                return 0
                ;;
            --dry-run)
                dry_run="true"
                ;;
            --include=*)
                include_pattern="${arg#*=}"
                ;;
            --exclude=*)
                exclude_pattern="${arg#*=}"
                ;;
            --timeout=*)
                timeout_seconds="${arg#*=}"
                ;;
            --no-push)
                no_push="true"
                ;;
            --agent=*)
                agent_type="${arg#*=}"
                ;;
            --no-untracked)
                include_untracked="false"
                ;;
            --sequential)
                # Default behavior, ignored
                ;;
            *)
                log_error "ai-sync: Unknown option: $arg"
                _ai_sync_help
                return 4
                ;;
        esac
    done

    # Check dependencies
    if ! command -v ntm &>/dev/null; then
        log_error "ai-sync requires ntm (Named Tmux Manager) to be installed"
        log_error "Install from: https://github.com/Dicklesworthstone/ntm"
        return 3
    fi

    if ! command -v claude &>/dev/null && [[ "$agent_type" == "claude" ]]; then
        log_error "ai-sync with Claude requires claude-code to be installed"
        log_error "Install from: https://github.com/anthropics/claude-code"
        return 3
    fi

    # Get dirty repos
    log_info "Scanning for repositories with uncommitted changes..."
    local dirty_repos_output
    local dirty_args=""
    [[ "$include_untracked" == "false" ]] && dirty_args="--no-untracked"

    dirty_repos_output=$(get_dirty_repos $dirty_args)
    if [[ -z "$dirty_repos_output" ]]; then
        log_success "All repositories are clean - nothing to sync"
        return 0
    fi

    # Convert to array
    local -a dirty_repos=()
    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue

        # Apply include filter
        if [[ -n "$include_pattern" ]]; then
            if [[ ! "$repo_path" == *"$include_pattern"* ]]; then
                log_debug "Skipping (not matching include): $repo_path"
                continue
            fi
        fi

        # Apply exclude filter
        if [[ -n "$exclude_pattern" ]]; then
            if [[ "$repo_path" == *"$exclude_pattern"* ]]; then
                log_debug "Skipping (matching exclude): $repo_path"
                continue
            fi
        fi

        dirty_repos+=("$repo_path")
    done <<< "$dirty_repos_output"

    if [[ ${#dirty_repos[@]} -eq 0 ]]; then
        log_success "No dirty repositories match the filters"
        return 0
    fi

    log_info "Found ${#dirty_repos[@]} dirty repository(s)"

    # Dry run mode - just list
    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run - would process these repositories:"
        for repo_path in "${dirty_repos[@]}"; do
            local repo_name
            repo_name=$(basename "$repo_path")
            printf '  %s (%s)\n' "$repo_name" "$repo_path" >&2
        done

        if [[ "$JSON_OUTPUT" == "true" ]]; then
            local json_array="["
            local first="true"
            for repo_path in "${dirty_repos[@]}"; do
                [[ "$first" == "true" ]] && first="false" || json_array+=","
                local safe_path
                safe_path=$(json_escape "$repo_path")
                json_array+="{\"path\":\"$safe_path\",\"status\":\"pending\"}"
            done
            json_array+="]"
            echo "$json_array"
        fi
        return 0
    fi

    # Process each dirty repo
    local succeeded=0
    local failed=0
    local -a results=()

    for repo_path in "${dirty_repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")

        log_info "Processing: $repo_name"

        # Generate the combined prompt for this repo
        local prompt_args=""
        [[ "$no_push" == "true" ]] && prompt_args="--no-push"
        local prompt
        prompt=$(generate_aisync_prompt_combined "$repo_path" $prompt_args)

        # Write prompt to temp file
        local prompt_file
        prompt_file=$(write_prompt_to_file "$prompt")
        if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
            log_error "Failed to create prompt file for $repo_name"
            ((failed++))
            results+=("{\"repo\":\"$(json_escape "$repo_path")\",\"status\":\"failed\",\"error\":\"prompt file creation\"}")
            continue
        fi

        # Spawn AI session and wait
        local session_result
        session_result=$(spawn_ai_session "$repo_path" "$prompt_file" --timeout="$timeout_seconds" --agent="$agent_type")
        local exit_code=$?

        # Clean up prompt file
        rm -f "$prompt_file" 2>/dev/null

        # Parse result
        local status
        status=$(echo "$session_result" | jq -r '.status // "unknown"' 2>/dev/null)

        if [[ "$status" == "success" ]]; then
            log_success "Completed: $repo_name"
            ((succeeded++))
            results+=("$session_result")
        else
            log_error "Failed: $repo_name ($status)"
            ((failed++))
            results+=("$session_result")
        fi
    done

    # Print summary
    local total=$((succeeded + failed))
    log_info "AI-Sync complete: $succeeded/$total repositories processed successfully"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local json_results="["
        local first="true"
        for result in "${results[@]}"; do
            [[ "$first" == "true" ]] && first="false" || json_results+=","
            json_results+="$result"
        done
        json_results+="]"
        printf '{"total":%d,"succeeded":%d,"failed":%d,"repos":%s}\n' "$total" "$succeeded" "$failed" "$json_results"
    fi

    # Exit code based on results
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Print ai-sync help
_ai_sync_help() {
    cat >&2 <<'EOF'
Usage: ru ai-sync [OPTIONS]

Automatically commit uncommitted changes across repositories using AI.

Options:
  --dry-run       Show which repos would be processed (no changes)
  --include=PAT   Only process repos with paths matching pattern
  --exclude=PAT   Skip repos with paths matching pattern
  --timeout=SEC   Per-repo timeout in seconds (default: 600)
  --no-push       Commit changes but don't push to remote
  --agent=TYPE    Agent type: claude (default), codex, gemini
  --no-untracked  Ignore untracked files when detecting dirty repos

The AI agent will:
1. Read AGENTS.md and README.md to understand each project
2. Review all changes and group them logically
3. Create detailed commit messages explaining the changes
4. Push to the remote (unless --no-push specified)

Examples:
  ru ai-sync                        # Process all dirty repos
  ru ai-sync --dry-run              # Show what would be processed
  ru ai-sync --include=my-project   # Only process matching repos
  ru ai-sync --timeout=1200         # Allow 20 minutes per repo
  ru ai-sync --no-push              # Commit but don't push

Exit Codes:
  0  All repos processed successfully
  1  Some repos failed
  3  Missing dependencies (ntm, claude-code)
  4  Invalid arguments
EOF
}

#------------------------------------------------------------------------------
# DEP-UPDATE SUBCOMMAND
# Update dependencies across repos using AI-powered analysis and testing
#------------------------------------------------------------------------------

# cmd_dep_update - Main entry point for dep-update subcommand
# Usage: ru dep-update [OPTIONS]
#   --dry-run           Show what would be updated (no changes)
#   --manager=NAME      Only update deps for specific manager
#   --include=PAT       Only update deps matching pattern
#   --exclude=PAT       Skip deps matching pattern
#   --major             Include major version updates (default: skip)
#   --test-cmd=CMD      Custom test command (overrides detection)
#   --max-fix-attempts=N  Max iterations for test/fix loop (default: 5)
#   --no-push           Commit but don't push
#   --repo=PATH         Single repo mode (default: all repos)
#   --agent=TYPE        Agent type: claude (default), codex, gemini
cmd_dep_update() {
    local dry_run="false"
    local manager_filter=""
    local include_pattern=""
    local exclude_pattern=""
    local include_major="false"
    local custom_test_cmd=""
    local max_fix_attempts=5
    local no_push="false"
    local single_repo=""
    local agent_type="claude"
    local timeout_seconds=900

    # Parse command arguments from ARGS array
    local arg
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            -h|--help)
                _dep_update_help
                return 0
                ;;
            --dry-run)
                dry_run="true"
                ;;
            --manager=*)
                manager_filter="${arg#*=}"
                ;;
            --include=*)
                include_pattern="${arg#*=}"
                ;;
            --exclude=*)
                exclude_pattern="${arg#*=}"
                ;;
            --major)
                include_major="true"
                ;;
            --test-cmd=*)
                custom_test_cmd="${arg#*=}"
                ;;
            --max-fix-attempts=*)
                max_fix_attempts="${arg#*=}"
                ;;
            --no-push)
                no_push="true"
                ;;
            --repo=*)
                single_repo="${arg#*=}"
                ;;
            --agent=*)
                agent_type="${arg#*=}"
                ;;
            --timeout=*)
                timeout_seconds="${arg#*=}"
                ;;
            *)
                log_error "dep-update: Unknown option: $arg"
                _dep_update_help
                return 4
                ;;
        esac
    done

    # Check dependencies
    if ! command -v ntm &>/dev/null; then
        log_error "dep-update requires ntm (Named Tmux Manager)"
        log_error "Install from: https://github.com/Dicklesworthstone/ntm"
        return 3
    fi

    case "$agent_type" in
        claude)
            if ! command -v claude &>/dev/null; then
                log_error "dep-update requires claude-code for agent type 'claude'"
                log_error "Install from: https://github.com/anthropics/claude-code"
                return 3
            fi
            ;;
        codex)
            if ! command -v codex &>/dev/null; then
                log_error "dep-update requires codex for agent type 'codex'"
                return 3
            fi
            ;;
        gemini)
            if ! command -v gemini &>/dev/null; then
                log_error "dep-update requires gemini CLI for agent type 'gemini'"
                return 3
            fi
            ;;
        *)
            log_error "Unknown agent type: $agent_type (supported: claude, codex, gemini)"
            return 4
            ;;
    esac

    # Build list of repos to process
    local -a repos_to_process=()
    if [[ -n "$single_repo" ]]; then
        if [[ ! -d "$single_repo" ]]; then
            log_error "Repository not found: $single_repo"
            return 4
        fi
        repos_to_process+=("$single_repo")
    else
        # Get all configured repos
        local repo_list
        repo_list=$(_list_local_repos 2>/dev/null) || repo_list=""
        if [[ -z "$repo_list" ]]; then
            log_warn "No repositories configured. Run 'ru add <repo>' first."
            return 0
        fi
        while IFS= read -r repo; do
            [[ -n "$repo" && -d "$repo" ]] && repos_to_process+=("$repo")
        done <<< "$repo_list"
    fi

    if [[ ${#repos_to_process[@]} -eq 0 ]]; then
        log_info "No repositories to process"
        return 0
    fi

    # Process each repo
    local processed=0
    local updated=0
    local failed=0
    local skipped=0
    local -a results=()

    for repo_path in "${repos_to_process[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")

        # Detect package managers in this repo
        local managers_json
        managers_json=$(detect_package_managers "$repo_path")
        local managers_array
        managers_array=$(echo "$managers_json" | jq -r '.managers // []' 2>/dev/null)
        if [[ -z "$managers_array" || "$managers_array" == "[]" ]]; then
            log_debug "No package managers found in $repo_name, skipping"
            ((skipped++))
            continue
        fi

        # Filter by manager if specified
        if [[ -n "$manager_filter" ]]; then
            if ! echo "$managers_json" | jq -e ".managers[] | select(. == \"$manager_filter\")" &>/dev/null; then
                log_debug "Repo $repo_name does not use manager '$manager_filter', skipping"
                ((skipped++))
                continue
            fi
        fi

        # Check for outdated dependencies
        local outdated_json
        outdated_json=$(check_outdated_deps "$repo_path" "$manager_filter")
        local total_outdated
        total_outdated=$(echo "$outdated_json" | jq -r '.total_outdated // 0')

        if [[ "$total_outdated" -eq 0 ]]; then
            log_debug "No outdated dependencies in $repo_name"
            ((skipped++))
            continue
        fi

        # Filter by include/exclude patterns (on package names)
        if [[ -n "$include_pattern" || -n "$exclude_pattern" ]]; then
            outdated_json=$(_filter_outdated_deps "$outdated_json" "$include_pattern" "$exclude_pattern")
            total_outdated=$(echo "$outdated_json" | jq -r '.total_outdated // 0')
            if [[ "$total_outdated" -eq 0 ]]; then
                log_debug "No matching dependencies after filtering in $repo_name"
                ((skipped++))
                continue
            fi
        fi

        # Filter out major updates unless --major specified
        if [[ "$include_major" != "true" ]]; then
            outdated_json=$(_filter_major_updates "$outdated_json")
            total_outdated=$(echo "$outdated_json" | jq -r '.total_outdated // 0')
            if [[ "$total_outdated" -eq 0 ]]; then
                log_debug "No non-major updates in $repo_name (use --major to include)"
                ((skipped++))
                continue
            fi
        fi

        ((processed++))
        log_info "Processing $repo_name: $total_outdated outdated dependencies"

        if [[ "$dry_run" == "true" ]]; then
            echo "Would update $total_outdated deps in: $repo_path"
            echo "$outdated_json" | jq -r '
                .results // [] | .[] |
                "\(.manager):" as $mgr |
                .outdated // [] | .[] |
                "  \($mgr) \(.name): \(.current) -> \(.latest)"
            ' 2>/dev/null || true
            continue
        fi

        # Fetch changelogs for outdated deps
        log_info "Fetching changelogs for $repo_name..."
        local changelog_text=""
        changelog_text=$(_fetch_changelogs_for_outdated "$outdated_json")

        # Detect or use custom test command
        local test_cmd
        if [[ -n "$custom_test_cmd" ]]; then
            test_cmd="$custom_test_cmd"
        else
            test_cmd=$(detect_test_command "$repo_path")
        fi
        if [[ -z "$test_cmd" ]]; then
            log_warn "No test command detected for $repo_name, tests will be skipped"
            test_cmd="echo 'No tests configured'"
        fi

        # Generate the combined prompt
        local prompt
        prompt=$(generate_depupdate_prompt_combined \
            "$repo_path" \
            "$outdated_json" \
            "$test_cmd" \
            "--changelog=$changelog_text" \
            "--max-attempts=$max_fix_attempts")

        # Write prompt to temp file
        local prompt_file
        prompt_file=$(write_prompt_to_file "$prompt")
        if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
            log_error "Failed to create prompt file for $repo_name"
            ((failed++))
            continue
        fi

        # Spawn AI session
        log_info "Spawning AI session for $repo_name..."
        local session_result
        session_result=$(spawn_ai_session "$repo_path" "$prompt_file" \
            "--timeout=$timeout_seconds" \
            "--agent=$agent_type" \
            "--prefix=dep-update")

        # Clean up prompt file
        rm -f "$prompt_file" 2>/dev/null

        # Parse result
        local status
        status=$(echo "$session_result" | jq -r '.status // "unknown"')

        case "$status" in
            completed|idle)
                log_success "Successfully updated dependencies in $repo_name"
                ((updated++))
                results+=("$(jq -n --arg repo "$repo_path" --argjson deps "$total_outdated" \
                    '{repo: $repo, status: "success", deps_updated: $deps}')")

                # Push if not --no-push
                if [[ "$no_push" != "true" ]]; then
                    log_info "Pushing changes for $repo_name..."
                    if ! git -C "$repo_path" push 2>/dev/null; then
                        log_warn "Failed to push $repo_name (changes are committed locally)"
                    fi
                fi
                ;;
            timeout)
                log_warn "Timeout while updating $repo_name"
                ((failed++))
                results+=("$(jq -n --arg repo "$repo_path" '{repo: $repo, status: "timeout"}')")
                ;;
            error|*)
                local error_msg
                error_msg=$(echo "$session_result" | jq -r '.error // "Unknown error"')
                log_error "Failed to update $repo_name: $error_msg"
                ((failed++))
                results+=("$(jq -n --arg repo "$repo_path" --arg err "$error_msg" \
                    '{repo: $repo, status: "error", error: $err}')")
                ;;
        esac
    done

    # Print summary
    echo ""
    log_info "=== dep-update Summary ==="
    log_info "Processed: $processed repos"
    log_info "Updated:   $updated repos"
    log_info "Failed:    $failed repos"
    log_info "Skipped:   $skipped repos (no outdated deps or filtered out)"

    # JSON output if requested
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local results_json
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
        jq -n \
            --argjson results "$results_json" \
            --arg processed "$processed" \
            --arg updated "$updated" \
            --arg failed "$failed" \
            --arg skipped "$skipped" \
            '{processed: ($processed|tonumber), updated: ($updated|tonumber), failed: ($failed|tonumber), skipped: ($skipped|tonumber), results: $results}'
    fi

    # Exit code based on results
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Filter outdated deps JSON by include/exclude patterns.
# Usage: _filter_outdated_deps <outdated_json> <include_pattern> <exclude_pattern>
# Returns: Filtered JSON with recalculated total_outdated
_filter_outdated_deps() {
    local json="$1"
    local include_pat="$2"
    local exclude_pat="$3"

    # Use jq to filter packages in the results array
    local filtered
    filtered=$(echo "$json" | jq --arg inc "$include_pat" --arg exc "$exclude_pat" '
        .results = (.results // [] | map(
            .outdated = (.outdated // [] | map(
                select(
                    (if $inc != "" then (.name | test($inc)) else true end) and
                    (if $exc != "" then (.name | test($exc) | not) else true end)
                )
            ))
        )) |
        .total_outdated = ([.results[].outdated | length] | add // 0)
    ' 2>/dev/null) || filtered="$json"

    echo "$filtered"
}

# Filter out major version updates from outdated deps JSON.
# Usage: _filter_major_updates <outdated_json>
# Returns: Filtered JSON without major updates
_filter_major_updates() {
    local json="$1"

    # Filter out packages where major version differs
    local filtered
    filtered=$(echo "$json" | jq '
        def is_major_update:
            (.current // "0") as $curr |
            (.latest // "0") as $lat |
            ($curr | split(".")[0] // "0") as $curr_major |
            ($lat | split(".")[0] // "0") as $lat_major |
            $curr_major != $lat_major;

        .results = (.results // [] | map(
            .outdated = (.outdated // [] | map(select(is_major_update | not)))
        )) |
        .total_outdated = ([.results[].outdated | length] | add // 0)
    ' 2>/dev/null) || filtered="$json"

    echo "$filtered"
}

# Fetch changelogs for all outdated packages.
# Usage: _fetch_changelogs_for_outdated <outdated_json>
# Returns: Combined changelog text
_fetch_changelogs_for_outdated() {
    local json="$1"
    local changelog_text=""
    local max_changelogs=10
    local count=0

    # Extract package info and fetch changelogs
    local packages
    packages=$(echo "$json" | jq -r '
        .results // [] | .[] |
        .manager as $mgr |
        .outdated // [] | .[] |
        "\($mgr)|\(.name)|\(.current)|\(.latest)"
    ' 2>/dev/null)

    while IFS='|' read -r manager name current latest; do
        [[ -z "$name" ]] && continue
        ((count >= max_changelogs)) && break

        log_debug "Fetching changelog for $name ($current -> $latest)..."
        local changelog
        changelog=$(fetch_changelog "$name" "$current" "$latest" "--manager=$manager" 2>/dev/null) || changelog=""

        if [[ -n "$changelog" ]]; then
            changelog_text+="
### $name ($current -> $latest)
$changelog
"
            ((count++))
        fi
    done <<< "$packages"

    if [[ -z "$changelog_text" ]]; then
        changelog_text="No changelogs could be fetched. Check package documentation manually."
    fi

    echo "$changelog_text"
}

# Print dep-update help
_dep_update_help() {
    cat >&2 <<'EOF'
Usage: ru dep-update [OPTIONS]

Update dependencies across repositories using AI-powered analysis.

Options:
  --dry-run             Show what would be updated (no changes)
  --manager=NAME        Only update deps for specific manager (npm, pip, cargo, etc.)
  --include=PATTERN     Only update deps matching regex pattern
  --exclude=PATTERN     Skip deps matching regex pattern
  --major               Include major version updates (default: skip major)
  --test-cmd=CMD        Custom test command (overrides auto-detection)
  --max-fix-attempts=N  Max fix iterations per dependency (default: 5)
  --no-push             Commit changes but don't push to remote
  --repo=PATH           Process single repo only (default: all repos)
  --agent=TYPE          Agent type: claude (default), codex, gemini
  --timeout=SEC         Per-repo timeout in seconds (default: 900)

The AI agent will:
1. Analyze outdated dependencies and changelogs for breaking changes
2. Create a migration plan based on risk assessment
3. Update each dependency one at a time
4. Run tests after each update and fix failures
5. Commit each successful update with descriptive message
6. Roll back and report any dependencies that can't be updated

Examples:
  ru dep-update                          # Update all deps in all repos
  ru dep-update --dry-run                # Show what would be updated
  ru dep-update --repo=./my-project      # Update single repo
  ru dep-update --manager=npm            # Only npm packages
  ru dep-update --major                  # Include major version updates
  ru dep-update --include='react|vue'    # Only update matching packages
  ru dep-update --exclude='typescript'   # Skip matching packages

Exit Codes:
  0  All updates successful
  1  Some dependencies failed to update
  3  Missing dependencies (ntm, claude-code)
  4  Invalid arguments
EOF
}

#------------------------------------------------------------------------------
# AGENT-SWEEP PER-REPO CONFIGURATION
# Load per-repository agent-sweep configuration from .ru-agent.yml/.json
#------------------------------------------------------------------------------

# Default agent-sweep per-repo config values
declare -g AGENT_SWEEP_ENABLED="true"
declare -g AGENT_SWEEP_MAX_FILE_MB="10"
declare -g AGENT_SWEEP_MAX_FILE_SIZE="10485760"
declare -g AGENT_SWEEP_MAX_FILE_MB_OVERRIDE=""
declare -ga AGENT_SWEEP_SKIP_PHASES=()
declare -g AGENT_SWEEP_EXTRA_CONTEXT=""
declare -g AGENT_SWEEP_PRE_HOOK=""
declare -g AGENT_SWEEP_POST_HOOK=""
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()
declare -a AGENT_SWEEP_ALLOW_BINARY_PATTERNS_DEFAULT=(
    "*.png"
    "*.jpg"
    "*.jpeg"
    "*.gif"
    "*.ico"
    "*.woff"
    "*.woff2"
)

#------------------------------------------------------------------------------
# AGENT-SWEEP PHASE PROMPTS
# Default prompts for each phase of the agent-sweep workflow.
# Each phase produces structured JSON output between markers.
#------------------------------------------------------------------------------

# Phase 1: Understanding - analyze the codebase and changes
# Output markers: RU_UNDERSTANDING_JSON_BEGIN / RU_UNDERSTANDING_JSON_END
read -r -d '' AGENT_SWEEP_PHASE1_PROMPT_DEFAULT << 'EOF_PHASE1'
First read AGENTS.md (if present) and README.md (if present) carefully.
If a file is missing, explicitly note that and continue.
Then use your investigation mode to understand the codebase architecture,
entrypoints, conventions, and what the current changes appear to be.
At the end, output a short structured summary as JSON between:
RU_UNDERSTANDING_JSON_BEGIN
{ "summary": "...", "conventions": [...], "risks": [...], "notes": [...] }
RU_UNDERSTANDING_JSON_END
EOF_PHASE1

# Phase 2: Commit Plan - plan the commits without executing
# Output markers: RU_COMMIT_PLAN_JSON_BEGIN / RU_COMMIT_PLAN_JSON_END
read -r -d '' AGENT_SWEEP_PHASE2_PROMPT_DEFAULT << 'EOF_PHASE2'
Now, based on your knowledge of the project, DO NOT run git commands.
Instead, produce a COMMIT PLAN as JSON between these markers:
RU_COMMIT_PLAN_JSON_BEGIN
{ ... }
RU_COMMIT_PLAN_JSON_END

Rules:
- Do not edit any code or files.
- Do not include ephemeral/ignored files (.pyc, node_modules, __pycache__, etc.).
- Group changes into logically connected commits.
- For each commit, include:
  - "files": explicit list of paths to stage
  - "message": full commit message (subject + body)
- Include "push": true/false
- Include "excluded_files": list of files excluded and why
Use ultrathink.

Expected schema:
{
  "commits": [
    {"files": ["path/a", "path/b"], "message": "feat(x): summary\n\nBody..."},
    {"files": ["path/c"], "message": "fix(y): summary\n\nBody..."}
  ],
  "push": true,
  "excluded_files": [
    {"path": "__pycache__/foo.pyc", "reason": "bytecode cache"}
  ],
  "assumptions": ["No breaking changes detected"],
  "risks": ["Large diff in core module"]
}
EOF_PHASE2

# Phase 3: Release Plan - plan any release actions without executing
# Output markers: RU_RELEASE_PLAN_JSON_BEGIN / RU_RELEASE_PLAN_JSON_END
read -r -d '' AGENT_SWEEP_PHASE3_PROMPT_DEFAULT << 'EOF_PHASE3'
If a release is warranted based on the changes, DO NOT execute release commands.
Produce a RELEASE PLAN as JSON between:
RU_RELEASE_PLAN_JSON_BEGIN
{ ... }
RU_RELEASE_PLAN_JSON_END

Include:
- "version": proposed version (or null if no release needed)
- "tag": proposed tag (or null)
- "changelog_entry": text to add to CHANGELOG
- "version_files": files to update with new version
- "checks": actions to verify before release (tests/CI)
Use ultrathink.

Expected schema:
{
  "version": "1.2.0",
  "tag": "v1.2.0",
  "changelog_entry": "## v1.2.0 (2026-01-06)\n\n### Added\n- ...",
  "version_files": [
    {"path": "VERSION", "old": "1.1.0", "new": "1.2.0"}
  ],
  "checks": ["tests", "lint"]
}
EOF_PHASE3

# Effective phase prompts (may be overridden by env vars or per-repo files)
declare -g AGENT_SWEEP_PHASE1_PROMPT="${AGENT_SWEEP_PHASE1_PROMPT:-$AGENT_SWEEP_PHASE1_PROMPT_DEFAULT}"
declare -g AGENT_SWEEP_PHASE2_PROMPT="${AGENT_SWEEP_PHASE2_PROMPT:-$AGENT_SWEEP_PHASE2_PROMPT_DEFAULT}"
declare -g AGENT_SWEEP_PHASE3_PROMPT="${AGENT_SWEEP_PHASE3_PROMPT:-$AGENT_SWEEP_PHASE3_PROMPT_DEFAULT}"

# Get the effective prompt for a given phase, with override precedence:
# 1. Per-repo file: $repo_path/.ru/phase{1,2,3}-prompt.txt (highest priority)
# 2. Environment variable: AGENT_SWEEP_PHASE{1,2,3}_PROMPT
# 3. Default prompt (lowest priority)
# Usage: get_effective_phase_prompt <phase_number> [repo_path]
# Args:
#   phase_number: 1, 2, or 3
#   repo_path: optional path to repo for per-repo overrides
# Returns: The effective prompt text
get_effective_phase_prompt() {
    local phase="${1:-}"
    local repo_path="${2:-}"

    # Validate phase number
    case "$phase" in
        1|2|3) ;;
        *)
            echo "Invalid phase: $phase. Must be 1, 2, or 3." >&2
            return 1
            ;;
    esac

    # Check for per-repo prompt file first (highest priority)
    if [[ -n "$repo_path" && -d "$repo_path" ]]; then
        local prompt_file="$repo_path/.ru/phase${phase}-prompt.txt"
        if [[ -f "$prompt_file" ]]; then
            cat "$prompt_file"
            return 0
        fi
    fi

    # Return the effective prompt (env var override or default)
    case "$phase" in
        1) echo "$AGENT_SWEEP_PHASE1_PROMPT" ;;
        2) echo "$AGENT_SWEEP_PHASE2_PROMPT" ;;
        3) echo "$AGENT_SWEEP_PHASE3_PROMPT" ;;
    esac
}

#------------------------------------------------------------------------------
# AGENT-SWEEP PLAN EXTRACTION
# Functions to extract structured JSON plans from agent pane output.
#------------------------------------------------------------------------------

# Validate JSON structure
# Reads JSON from stdin and validates it
# Returns: 0 if valid JSON, 1 otherwise
json_validate() {
    if command -v jq &>/dev/null; then
        jq empty 2>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    else
        # Best effort: check content starts with { and ends with }
        # Note: bash regex '.' doesn't match newlines, so we compress first
        local content
        content=$(cat)
        # Remove all whitespace to get a single-line representation
        local compressed
        compressed=$(printf '%s' "$content" | tr -d '\n\r\t ')
        # Check first and last characters are braces
        [[ "${compressed:0:1}" == "{" && "${compressed: -1}" == "}" ]]
    fi
}

# Extract JSON between markers from pane output
# Usage: extract_plan_json "$pane_output" "COMMIT_PLAN"
# Args:
#   $1: pane_output - raw output from agent pane
#   $2: marker_name - one of: UNDERSTANDING, COMMIT_PLAN, RELEASE_PLAN
# Returns: JSON string on stdout, or empty if not found
# Exit: 0 if valid JSON extracted, 1 if not found or invalid
extract_plan_json() {
    local pane_output="$1"
    local marker="${2:-}"

    [[ -z "$marker" ]] && return 1

    local begin_marker="RU_${marker}_JSON_BEGIN"
    local end_marker="RU_${marker}_JSON_END"

    # Strip ANSI escape codes before processing
    local clean_output
    clean_output=$(echo "$pane_output" | sed 's/\x1b\[[0-9;]*m//g')

    # Extract content between markers (excluding the marker lines)
    local json
    json=$(echo "$clean_output" | sed -n "/${begin_marker}/,/${end_marker}/p" | \
           sed "1d;\$d")

    # Check if we got anything
    if [[ -z "$json" ]]; then
        return 1  # Markers not found
    fi

    # Validate it's valid JSON
    if echo "$json" | json_validate; then
        echo "$json"
        return 0
    else
        # Log warning but don't fail - preserve raw output for debugging
        log_warn "Extracted content between ${begin_marker}...${end_marker} is not valid JSON"
        return 1
    fi
}

# Capture output from a tmux pane
# Usage: capture_pane_output "session_name" [lines]
# Args:
#   $1: session - tmux session name
#   $2: lines - number of lines to capture (default: 10000)
# Returns: pane content on stdout
# Exit: 0 on success, 1 on failure
capture_pane_output() {
    local session="$1"
    local lines="${2:-10000}"

    [[ -z "$session" ]] && return 1

    # Check if session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log_warn "Session '$session' not found"
        return 1
    fi

    # Capture pane output (pane 1 is the agent pane in our layout)
    # -p: print to stdout, -S: start line (negative = from scrollback)
    tmux capture-pane -t "${session}:0.1" -p -S -"$lines" 2>/dev/null
}

# Extract all plans from pane output
# Usage: extract_all_plans "$pane_output" "$artifacts_dir"
# Args:
#   $1: pane_output - raw output from agent pane
#   $2: artifacts_dir - directory to save extracted plans
# Returns: 0 if at least one plan extracted, 1 if none found
extract_all_plans() {
    local pane_output="$1"
    local artifacts_dir="$2"
    local found=0

    [[ -z "$pane_output" || -z "$artifacts_dir" ]] && return 1

    ensure_dir "$artifacts_dir"

    # Try to extract each plan type
    local plan_json

    # Understanding plan (Phase 1)
    if plan_json=$(extract_plan_json "$pane_output" "UNDERSTANDING"); then
        echo "$plan_json" > "$artifacts_dir/understanding.json"
        found=1
    fi

    # Commit plan (Phase 2)
    if plan_json=$(extract_plan_json "$pane_output" "COMMIT_PLAN"); then
        echo "$plan_json" > "$artifacts_dir/commit_plan.json"
        found=1
    fi

    # Release plan (Phase 3)
    if plan_json=$(extract_plan_json "$pane_output" "RELEASE_PLAN"); then
        echo "$plan_json" > "$artifacts_dir/release_plan.json"
        found=1
    fi

    [[ $found -eq 1 ]] && return 0
    return 1
}

#------------------------------------------------------------------------------
# AGENT-SWEEP COMMIT PLAN VALIDATION
#
# Validate commit plan JSON for safety and guardrails.
# Sets VALIDATION_ERROR (fatal) and VALIDATION_WARNINGS (non-fatal).
#------------------------------------------------------------------------------

# Validate commit plan before execution.
# Args: $1=commit_plan_json, $2=repo_path
# Returns: 0=valid, 1=blocked
validate_commit_plan() {
    local plan_json="$1"
    local repo_path="$2"

    VALIDATION_ERROR=""
    VALIDATION_WARNINGS=()

    if [[ -z "$plan_json" ]]; then
        VALIDATION_ERROR="Commit plan is empty"
        return 1
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        VALIDATION_ERROR="Invalid repo path for commit plan validation"
        return 1
    fi

    if ! echo "$plan_json" | json_validate; then
        VALIDATION_ERROR="Invalid JSON structure in commit plan"
        return 1
    fi

    local commits_json push_flag
    commits_json=$(json_get_field "$plan_json" "commits" || echo "")
    push_flag=$(json_get_field "$plan_json" "push" || echo "")

    if [[ -z "$commits_json" || "$commits_json" == "null" ]]; then
        VALIDATION_ERROR="Missing or empty commits array in plan"
        return 1
    fi

    local commit_count=0

    if command -v jq &>/dev/null; then
        if ! echo "$commits_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
            VALIDATION_ERROR="Missing or empty commits array in plan"
            return 1
        fi

        while IFS= read -r commit_json; do
            ((commit_count++))

            if ! echo "$commit_json" | jq -e '.message | type == "string" and (gsub("^\\s+|\\s+$";"") | length > 0)' >/dev/null 2>&1; then
                VALIDATION_ERROR="Commit $commit_count has no message"
                return 1
            fi

            if ! echo "$commit_json" | jq -e '.files | type == "array" and length > 0 and all(.[]; type == "string" and (gsub("^\\s+|\\s+$";"") | length > 0))' >/dev/null 2>&1; then
                VALIDATION_ERROR="Commit $commit_count has no files"
                return 1
            fi

            local -a files=()
            mapfile -t files < <(echo "$commit_json" | jq -r '.files[] | gsub("^\\s+|\\s+$";"")' 2>/dev/null)
            if [[ ${#files[@]} -eq 0 ]]; then
                VALIDATION_ERROR="Commit $commit_count has no files"
                return 1
            fi

            local file
            for file in "${files[@]}"; do
                [[ -z "$file" ]] && continue
                local normalized
                normalized="${file#./}"
                case "$normalized" in
                    ""|".")
                        VALIDATION_ERROR="Commit $commit_count has empty file path"
                        return 1
                        ;;
                    /*)
                        VALIDATION_ERROR="Commit $commit_count has absolute file path: $file"
                        return 1
                        ;;
                    ../*|*/../*|*/..|..)
                        VALIDATION_ERROR="Commit $commit_count has unsafe path: $file"
                        return 1
                        ;;
                esac
                file="$normalized"

                if is_file_denied "$file"; then
                    VALIDATION_ERROR="Denied file in commit $commit_count: $file"
                    return 1
                fi

                if [[ ! -e "$repo_path/$file" ]]; then
                    VALIDATION_WARNINGS+=("File not found: $file (will be skipped)")
                    continue
                fi

                if [[ -f "$repo_path/$file" ]]; then
                    if is_file_too_large "$repo_path/$file"; then
                        local size_mb
                        size_mb=$(get_file_size_mb "$repo_path/$file")
                        VALIDATION_ERROR="File too large: $file (${size_mb}MB > ${AGENT_SWEEP_MAX_FILE_MB}MB limit)"
                        return 1
                    fi

                    if is_binary_file "$repo_path/$file"; then
                        if ! is_binary_allowed "$file"; then
                            VALIDATION_ERROR="Binary file not allowed: $file"
                            return 1
                        fi
                        VALIDATION_WARNINGS+=("Binary file included: $file (explicitly allowed)")
                    fi
                fi
            done
        done < <(echo "$commits_json" | jq -c '.[]' 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        local parsed_lines
        parsed_lines=$(PLAN_JSON="$plan_json" python3 - <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("PLAN_JSON", ""))
except Exception:
    print("ERROR\tInvalid JSON structure in commit plan")
    sys.exit(2)

commits = data.get("commits")
if not isinstance(commits, list) or len(commits) == 0:
    print("ERROR\tMissing or empty commits array in plan")
    sys.exit(2)

print(f"COUNT\t{len(commits)}")
for idx, commit in enumerate(commits, 1):
    files = commit.get("files")
    message = commit.get("message", "")
    if not isinstance(files, list) or len(files) == 0:
        print(f"ERROR\tCommit {idx} has no files")
        sys.exit(2)
    if not isinstance(message, str) or not message.strip():
        print(f"ERROR\tCommit {idx} has no message")
        sys.exit(2)
    if not all(isinstance(f, str) and f.strip() for f in files):
        print(f"ERROR\tCommit {idx} has invalid files")
        sys.exit(2)
    for f in files:
        f = f.strip()
        print(f"FILE\t{idx}\t{f}")
PY
)
        local parse_status=$?
        if [[ $parse_status -ne 0 ]]; then
            local err_line
            err_line=$(echo "$parsed_lines" | head -n1)
            VALIDATION_ERROR="${err_line#ERROR	}"
            [[ -z "$VALIDATION_ERROR" ]] && VALIDATION_ERROR="Invalid commit plan"
            return 1
        fi

        local line
        while IFS=$'\t' read -r kind idx file; do
            case "$kind" in
                COUNT)
                    commit_count="$idx"
                    ;;
                FILE)
                    [[ -z "$file" ]] && continue
                    local normalized
                    normalized="${file#./}"
                    case "$normalized" in
                        ""|".")
                            VALIDATION_ERROR="Commit $idx has empty file path"
                            return 1
                            ;;
                        /*)
                            VALIDATION_ERROR="Commit $idx has absolute file path: $file"
                            return 1
                            ;;
                        ../*|*/../*|*/..|..)
                            VALIDATION_ERROR="Commit $idx has unsafe path: $file"
                            return 1
                            ;;
                    esac
                    file="$normalized"

                    if is_file_denied "$file"; then
                        VALIDATION_ERROR="Denied file in commit $idx: $file"
                        return 1
                    fi

                    if [[ ! -e "$repo_path/$file" ]]; then
                        VALIDATION_WARNINGS+=("File not found: $file (will be skipped)")
                        continue
                    fi

                    if [[ -f "$repo_path/$file" ]]; then
                        if is_file_too_large "$repo_path/$file"; then
                            local size_mb
                            size_mb=$(get_file_size_mb "$repo_path/$file")
                            VALIDATION_ERROR="File too large: $file (${size_mb}MB > ${AGENT_SWEEP_MAX_FILE_MB}MB limit)"
                            return 1
                        fi

                        if is_binary_file "$repo_path/$file"; then
                            if ! is_binary_allowed "$file"; then
                                VALIDATION_ERROR="Binary file not allowed: $file"
                                return 1
                            fi
                            VALIDATION_WARNINGS+=("Binary file included: $file (explicitly allowed)")
                        fi
                    fi
                    ;;
            esac
        done <<<"$parsed_lines"
    else
        VALIDATION_ERROR="Commit plan validation requires jq or python3"
        return 1
    fi

    local max_commits="${AGENT_SWEEP_MAX_COMMITS:-50}"
    if is_positive_int "$max_commits" && [[ "$commit_count" -gt "$max_commits" ]]; then
        VALIDATION_ERROR="Too many commits in plan: $commit_count (max $max_commits)"
        return 1
    fi

    local secret_mode="${AGENT_SWEEP_SECRET_SCAN:-warn}"
    if [[ "$secret_mode" != "none" ]]; then
        local secret_result secret_exit
        secret_result=$(run_secret_scan "$repo_path")
        secret_exit=$?
        if [[ $secret_exit -ne 0 ]]; then
            local findings="Secrets detected in changes"
            if command -v jq &>/dev/null; then
                local joined
                joined=$(echo "$secret_result" | jq -r '.findings[]?' 2>/dev/null | paste -sd ';' -)
                [[ -n "$joined" ]] && findings="$joined"
            else
                local raw_findings
                raw_findings=$(json_get_field "$secret_result" "findings" || echo "")
                [[ -n "$raw_findings" ]] && findings="$raw_findings"
            fi

            if [[ "$secret_mode" == "block" && $secret_exit -eq 1 ]]; then
                VALIDATION_ERROR="Secrets detected: $findings"
                return 1
            fi
            VALIDATION_WARNINGS+=("Secret scan warning: $findings")
        fi
    fi

    local warn
    # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 empty array safety
    for warn in ${VALIDATION_WARNINGS[@]+"${VALIDATION_WARNINGS[@]}"}; do
        log_warn "  ⚠ $warn"
    done

    log_verbose "Commit plan validated: $commit_count commits, push=$push_flag"
    return 0
}

#------------------------------------------------------------------------------
# AGENT-SWEEP COMMIT PLAN EXECUTION
#
# Execute a validated commit plan with deterministic git operations.
#------------------------------------------------------------------------------

# Stage files and create a commit.
# Args: $1=repo_path, $2=commit_index, $3=message, $4...=files
# Returns: 0=success, 1=failure
commit_plan_stage_and_commit() {
    local repo_path="$1"
    local commit_index="$2"
    local message="$3"
    shift 3
    # shellcheck disable=SC2190  # False positive: -a is indexed array, not -A associative
    local -a files=("$@")

    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        log_error "Invalid repo path for commit execution"
        return 1
    fi
    if [[ -z "$message" ]]; then
        log_error "Commit $commit_index has empty message"
        return 1
    fi

    local staged_any=false
    local file output exit_code

    for file in "${files[@]}"; do
        [[ -z "$file" ]] && continue

        if [[ -d "$repo_path/$file" ]]; then
            log_error "Commit $commit_index includes directory path: $file"
            return 1
        fi

        if [[ -e "$repo_path/$file" ]]; then
            if output=$(git -C "$repo_path" add -A -- "$file" 2>&1); then
                staged_any=true
            else
                exit_code=$?
                log_error "Failed to stage $file for commit $commit_index: $output"
                return "$exit_code"
            fi
            continue
        fi

        if git -C "$repo_path" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
            if output=$(git -C "$repo_path" add -A -- "$file" 2>&1); then
                staged_any=true
            else
                exit_code=$?
                log_error "Failed to stage deletion for $file in commit $commit_index: $output"
                return "$exit_code"
            fi
            continue
        fi

        log_warn "File not found, skipping: $file"
    done

    if [[ "$staged_any" != "true" ]]; then
        log_error "No files staged for commit $commit_index"
        return 1
    fi

    if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
        log_error "No staged changes for commit $commit_index"
        return 1
    fi

    local commit_output commit_exit
    if commit_output=$(git -C "$repo_path" commit -m "$message" 2>&1); then
        commit_exit=0
    else
        commit_exit=$?
    fi

    if [[ $commit_exit -ne 0 ]]; then
        log_error "Commit $commit_index failed: $commit_output"
        return "$commit_exit"
    fi

    log_verbose "Created commit $commit_index: ${message%%$'\n'*}"
    return 0
}

# Execute commit plan after validation.
# Args: $1=commit_plan_json, $2=repo_path
# Returns: 0=success, 1=failure
execute_commit_plan() {
    local plan_json="$1"
    local repo_path="$2"

    if [[ -z "$plan_json" ]]; then
        log_error "Commit plan is empty"
        return 1
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        log_error "Invalid repo path for commit plan execution"
        return 1
    fi

    local exec_mode="${AGENT_SWEEP_EXECUTION_MODE:-agent}"
    if [[ "$exec_mode" == "plan" ]]; then
        capture_plan_json "$repo_path" "commit" "$plan_json" || true
        log_info "Plan mode enabled; skipping commit execution"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required to execute commit plans"
        return 1
    fi

    if ! validate_commit_plan "$plan_json" "$repo_path"; then
        log_error "Commit plan validation failed: ${VALIDATION_ERROR:-unknown error}"
        return 1
    fi

    local push_flag
    push_flag=$(json_get_field "$plan_json" "push" || echo "")
    [[ -z "$push_flag" || "$push_flag" == "null" ]] && push_flag="false"

    local commit_index=0
    local commit_json
    while IFS= read -r commit_json; do
        ((commit_index++))

        local message
        message=$(echo "$commit_json" | jq -r '.message // empty' 2>/dev/null)
        if [[ -z "$message" ]]; then
            log_error "Commit $commit_index has no message"
            return 1
        fi

        local -a files=()
        mapfile -t files < <(echo "$commit_json" | jq -r '.files[] | gsub("^\\s+|\\s+$";"")' 2>/dev/null)
        if [[ ${#files[@]} -eq 0 ]]; then
            log_error "Commit $commit_index has no files"
            return 1
        fi

        log_info "Applying commit $commit_index..."
        if ! commit_plan_stage_and_commit "$repo_path" "$commit_index" "$message" "${files[@]}"; then
            return 1
        fi
    done < <(echo "$plan_json" | jq -c '.commits[]' 2>/dev/null)

    if [[ $commit_index -eq 0 ]]; then
        log_error "No commits to apply from plan"
        return 1
    fi

    if [[ "$push_flag" == "true" ]]; then
        local output exit_code
        if output=$(git -C "$repo_path" push 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi

        if [[ $exit_code -ne 0 ]]; then
            log_error "Push failed: $output"
            return "$exit_code"
        fi
        log_info "Pushed to remote"
    fi

    return 0
}

#------------------------------------------------------------------------------
# AGENT-SWEEP RELEASE PLAN VALIDATION
#
# Validate release plan JSON for safety and guardrails.
# Sets VALIDATION_ERROR (fatal) and VALIDATION_WARNINGS (non-fatal).
#------------------------------------------------------------------------------

# Validate release plan before execution.
# Args: $1=release_plan_json, $2=repo_path
# Returns: 0=valid, 1=blocked
# Side effects: Sets VALIDATION_ERROR on failure, VALIDATION_WARNINGS array
validate_release_plan() {
    local plan_json="$1"
    local repo_path="$2"

    VALIDATION_ERROR=""
    VALIDATION_WARNINGS=()

    if [[ -z "$plan_json" ]]; then
        VALIDATION_ERROR="Release plan is empty"
        return 1
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        VALIDATION_ERROR="Invalid repo path for release plan validation"
        return 1
    fi

    if ! echo "$plan_json" | json_validate; then
        VALIDATION_ERROR="Invalid JSON structure in release plan"
        return 1
    fi

    # Extract required fields
    local version tag_name title body files_json
    version=$(json_get_field "$plan_json" "version" || echo "")
    tag_name=$(json_get_field "$plan_json" "tag_name" || echo "")
    title=$(json_get_field "$plan_json" "title" || echo "")
    body=$(json_get_field "$plan_json" "body" || echo "")
    files_json=$(json_get_field "$plan_json" "files" || echo "")

    # 1. Validate version format (semver: vX.Y.Z or X.Y.Z)
    if [[ -z "$version" || "$version" == "null" ]]; then
        VALIDATION_ERROR="Missing version in release plan"
        return 1
    fi
    if ! [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$ ]]; then
        VALIDATION_ERROR="Invalid version format: $version (expected semver like v1.2.3 or 1.2.3)"
        return 1
    fi

    # 2. Validate tag_name
    if [[ -z "$tag_name" || "$tag_name" == "null" ]]; then
        # Default to version if tag_name not provided
        tag_name="$version"
    fi
    # Align with execute_release_plan behavior: prefix v if version has v
    if [[ "$version" == v* && "$tag_name" != v* ]]; then
        tag_name="v$tag_name"
    fi
    # Check tag doesn't already exist
    if git -C "$repo_path" rev-parse "refs/tags/$tag_name" >/dev/null 2>&1; then
        VALIDATION_ERROR="Tag already exists: $tag_name"
        return 1
    fi
    # Validate tag name characters (no shell metacharacters)
    if [[ "$tag_name" =~ [\;\&\|\$\`\(\)\{\}\<\>\'\"\!\#\*\?\\] ]]; then
        VALIDATION_ERROR="Tag name contains unsafe characters: $tag_name"
        return 1
    fi

    # 3. Validate title length
    if [[ -n "$title" && "$title" != "null" ]]; then
        local title_len=${#title}
        if [[ $title_len -gt 200 ]]; then
            VALIDATION_ERROR="Release title too long: $title_len chars (max 200)"
            return 1
        fi
        # Check for shell metacharacters
        if [[ "$title" =~ [\;\&\|\$\`] ]]; then
            VALIDATION_ERROR="Release title contains unsafe shell characters"
            return 1
        fi
    fi

    # 4. Validate body length
    if [[ -n "$body" && "$body" != "null" ]]; then
        local body_len=${#body}
        if [[ $body_len -gt 10000 ]]; then
            VALIDATION_ERROR="Release body too long: $body_len chars (max 10000)"
            return 1
        fi
    fi

    # 5. Validate files array (release assets)
    if [[ -n "$files_json" && "$files_json" != "null" && "$files_json" != "[]" ]]; then
        if ! command -v jq &>/dev/null; then
            VALIDATION_WARNINGS+=("jq not available, skipping release files validation")
        else
            if ! echo "$files_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
                VALIDATION_ERROR="Release files must be an array"
                return 1
            fi

            local -a files=()
            mapfile -t files < <(echo "$files_json" | jq -r '.[]' 2>/dev/null)

            local file
            for file in "${files[@]}"; do
                [[ -z "$file" ]] && continue

                # Normalize path
                local normalized="${file#./}"
                case "$normalized" in
                    ""|".")
                        VALIDATION_ERROR="Release files contains empty path"
                        return 1
                        ;;
                    /*)
                        VALIDATION_ERROR="Release files contains absolute path: $file"
                        return 1
                        ;;
                    ../*|*/../*|*/..|..)
                        VALIDATION_ERROR="Release files contains unsafe path: $file"
                        return 1
                        ;;
                esac

                # Check against denylist
                if is_file_denied "$normalized"; then
                    VALIDATION_ERROR="Denied file in release assets: $normalized"
                    return 1
                fi

                # Verify file exists
                if [[ ! -f "$repo_path/$normalized" ]]; then
                    VALIDATION_WARNINGS+=("Release asset not found: $normalized")
                fi
            done
        fi
    fi

    # 6. Validate changelog if specified
    local changelog
    changelog=$(json_get_field "$plan_json" "changelog" || echo "")
    if [[ -n "$changelog" && "$changelog" != "null" ]]; then
        if [[ ! -f "$repo_path/$changelog" ]]; then
            VALIDATION_WARNINGS+=("Changelog file not found: $changelog")
        else
            # Check if changelog mentions the version
            local version_pattern="${version#v}"  # Remove leading v for matching
            if ! grep -qE "(^#+.*${version_pattern}|^## \\[?${version_pattern})" "$repo_path/$changelog" 2>/dev/null; then
                VALIDATION_WARNINGS+=("Changelog may not contain version $version header")
            fi
        fi
    fi

    return 0
}

# Execute release plan after validation.
# Args: $1=release_plan_json, $2=repo_path
# Returns: 0=success, 1=failure
# Side effects: Creates git tag, pushes to remote, creates GitHub release
execute_release_plan() {
    local plan_json="$1"
    local repo_path="$2"

    if [[ -z "$plan_json" ]]; then
        log_error "Release plan is empty"
        return 1
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        log_error "Invalid repo path for release plan execution"
        return 1
    fi

    # Check execution mode
    local exec_mode="${AGENT_SWEEP_EXECUTION_MODE:-agent}"
    if [[ "$exec_mode" == "plan" ]]; then
        capture_plan_json "$repo_path" "release" "$plan_json" || true
        log_info "Plan mode enabled; skipping release execution"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required to execute release plans"
        return 1
    fi

    # Validate the plan first
    if ! validate_release_plan "$plan_json" "$repo_path"; then
        log_error "Release plan validation failed: ${VALIDATION_ERROR:-unknown error}"
        return 1
    fi

    # Log any warnings
    local warning
    # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 empty array safety
    for warning in ${VALIDATION_WARNINGS[@]+"${VALIDATION_WARNINGS[@]}"}; do
        log_warn "$warning"
    done

    # Extract fields
    local version tag_name title body
    version=$(echo "$plan_json" | jq -r '.version // empty' 2>/dev/null)
    tag_name=$(echo "$plan_json" | jq -r '.tag_name // empty' 2>/dev/null)
    title=$(echo "$plan_json" | jq -r '.title // empty' 2>/dev/null)
    body=$(echo "$plan_json" | jq -r '.body // empty' 2>/dev/null)

    # Default tag_name to version if not specified
    [[ -z "$tag_name" ]] && tag_name="$version"
    # Ensure tag starts with v if version does
    [[ "$version" == v* && "$tag_name" != v* ]] && tag_name="v$tag_name"

    # Default title to tag_name if not specified
    [[ -z "$title" ]] && title="Release $tag_name"

    # Check release strategy
    local strategy
    strategy=$(get_release_strategy "$repo_path")
    case "$strategy" in
        never)
            log_info "Release strategy is 'never', skipping release for $repo_path"
            return 0
            ;;
        tag-only)
            log_info "Release strategy is 'tag-only', will create tag but no GitHub release"
            ;;
    esac

    # Step 1: Create git tag locally
    log_info "Creating tag: $tag_name"
    local tag_output tag_exit
    if tag_output=$(git -C "$repo_path" tag -a "$tag_name" -m "$title" 2>&1); then
        tag_exit=0
    else
        tag_exit=$?
    fi

    if [[ $tag_exit -ne 0 ]]; then
        log_error "Failed to create tag: $tag_output"
        return 1
    fi

    # Step 2: Push tag to origin
    log_info "Pushing tag to origin..."
    local push_output push_exit
    if push_output=$(git -C "$repo_path" push origin "$tag_name" 2>&1); then
        push_exit=0
    else
        push_exit=$?
    fi

    if [[ $push_exit -ne 0 ]]; then
        log_error "Failed to push tag: $push_output"
        # Cleanup: delete local tag
        git -C "$repo_path" tag -d "$tag_name" 2>/dev/null || true
        return 1
    fi

    # If tag-only strategy, we're done
    if [[ "$strategy" == "tag-only" ]]; then
        log_info "Tag $tag_name created and pushed successfully"
        return 0
    fi

    # Step 3: Check gh CLI availability
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not available, cannot create GitHub release"
        log_info "Tag $tag_name created and pushed, but GitHub release skipped"
        return 0
    fi

    # Step 4: Create GitHub release
    log_info "Creating GitHub release..."
    local -a gh_args=("release" "create" "$tag_name")
    gh_args+=("--title" "$title")

    if [[ -n "$body" ]]; then
        gh_args+=("--notes" "$body")
    else
        gh_args+=("--generate-notes")
    fi

    # Add release assets
    local -a files=()
    local files_json
    files_json=$(echo "$plan_json" | jq -c '.files // []' 2>/dev/null || echo "[]")
    if [[ "$files_json" != "[]" ]]; then
        mapfile -t files < <(echo "$files_json" | jq -r '.[]' 2>/dev/null)
        for file in "${files[@]}"; do
            [[ -z "$file" ]] && continue
            local asset_path="$repo_path/${file#./}"
            if [[ -f "$asset_path" ]]; then
                gh_args+=("$asset_path")
            else
                log_warn "Release asset not found, skipping: $file"
            fi
        done
    fi

    # Execute gh release create
    local gh_output gh_exit
    if gh_output=$(cd "$repo_path" && gh "${gh_args[@]}" 2>&1); then
        gh_exit=0
    else
        gh_exit=$?
    fi

    if [[ $gh_exit -ne 0 ]]; then
        log_error "Failed to create GitHub release: $gh_output"
        # Note: We don't delete the tag here since it's already pushed
        # The user can retry or manually create the release
        return 1
    fi

    # Extract release URL from output
    local release_url
    release_url=$(echo "$gh_output" | grep -oE 'https://github.com/[^[:space:]]+' | head -1)
    if [[ -n "$release_url" ]]; then
        log_info "Release created: $release_url"
    else
        log_info "Release $tag_name created successfully"
    fi

    return 0
}

#------------------------------------------------------------------------------
# AGENT-SWEEP RELEASE WORKFLOW DETECTION
#
# Determine if a repository should have release automation (Phase 3).
#------------------------------------------------------------------------------

# Check if repo has release workflow configured.
# Checks in order: per-repo config, user config, gh API, workflow files.
# Usage: has_release_workflow /path/to/repo
# Returns: 0 if release workflow detected, 1 otherwise
has_release_workflow() {
    local repo_path="${1:-}"
    [[ -z "$repo_path" || ! -d "$repo_path" ]] && return 1

    local workflows_dir="$repo_path/.github/workflows"

    # 1. Check explicit per-repo config first (highest priority)
    local repo_config="$repo_path/.ru/agent-sweep.conf"
    if [[ -f "$repo_config" ]]; then
        local AGENT_SWEEP_RELEASE_STRATEGY=""
        # shellcheck disable=SC1090
        source "$repo_config" 2>/dev/null
        case "${AGENT_SWEEP_RELEASE_STRATEGY:-}" in
            never) return 1 ;;
            tag-only|gh-release|auto) return 0 ;;
        esac
    fi

    # 2. Check user-level per-repo config
    local repo_name
    repo_name=$(basename "$repo_path")
    local user_config="${RU_CONFIG_DIR:-$HOME/.config/ru}/agent-sweep.d/${repo_name}.conf"
    if [[ -f "$user_config" ]]; then
        local AGENT_SWEEP_RELEASE_STRATEGY=""
        # shellcheck disable=SC1090
        source "$user_config" 2>/dev/null
        case "${AGENT_SWEEP_RELEASE_STRATEGY:-}" in
            never) return 1 ;;
            tag-only|gh-release|auto) return 0 ;;
        esac
    fi

    # 3. Use gh API if available (checks remote for release workflows)
    if command -v gh &>/dev/null; then
        local remote_url
        remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null)
        if [[ -n "$remote_url" ]]; then
            # Extract owner/repo from URL
            local repo_spec
            repo_spec=$(echo "$remote_url" | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#')
            if [[ -n "$repo_spec" ]]; then
                # Check for release-related workflows
                if gh workflow list -R "$repo_spec" 2>/dev/null | grep -qiE "release|deploy|publish"; then
                    return 0
                fi
            fi
        fi
    fi

    # 4. Fallback: check local workflow files for release patterns
    [[ -d "$workflows_dir" ]] || return 1

    # Look for release-related triggers or jobs in workflow files
    if compgen -G "$workflows_dir/*.yml" >/dev/null 2>&1 || \
       compgen -G "$workflows_dir/*.yaml" >/dev/null 2>&1; then
        # Check for common release patterns
        if grep -riqE "(on:[[:space:]]*release|tags:|workflow_dispatch:|create:[[:space:]]*tags)" \
           "$workflows_dir"/*.yml "$workflows_dir"/*.yaml 2>/dev/null; then
            return 0
        fi
        # Check for release job names
        if grep -riqE "(release|publish|deploy)" \
           "$workflows_dir"/*.yml "$workflows_dir"/*.yaml 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Get the release strategy for a repo.
# Returns: "never", "auto", "tag-only", or "gh-release"
get_release_strategy() {
    local repo_path="${1:-}"
    [[ -z "$repo_path" || ! -d "$repo_path" ]] && { echo "never"; return; }

    # Check per-repo config
    local repo_config="$repo_path/.ru/agent-sweep.conf"
    if [[ -f "$repo_config" ]]; then
        local AGENT_SWEEP_RELEASE_STRATEGY=""
        # shellcheck disable=SC1090
        source "$repo_config" 2>/dev/null
        if [[ -n "$AGENT_SWEEP_RELEASE_STRATEGY" ]]; then
            echo "$AGENT_SWEEP_RELEASE_STRATEGY"
            return
        fi
    fi

    # Check user config
    local repo_name
    repo_name=$(basename "$repo_path")
    local user_config="${RU_CONFIG_DIR:-$HOME/.config/ru}/agent-sweep.d/${repo_name}.conf"
    if [[ -f "$user_config" ]]; then
        local AGENT_SWEEP_RELEASE_STRATEGY=""
        # shellcheck disable=SC1090
        source "$user_config" 2>/dev/null
        if [[ -n "$AGENT_SWEEP_RELEASE_STRATEGY" ]]; then
            echo "$AGENT_SWEEP_RELEASE_STRATEGY"
            return
        fi
    fi

    # Default: auto if has release workflow, never otherwise
    if has_release_workflow "$repo_path"; then
        echo "auto"
    else
        echo "never"
    fi
}

# Load per-repo agent-sweep configuration.
# Usage: load_repo_agent_config /path/to/repo
# Returns: 0 on success (uses defaults if no config found), 1 on invalid args
# Side effects: Sets AGENT_SWEEP_* globals based on config file
load_repo_agent_config() {
    local repo_path="${1:-}"
    [[ -z "$repo_path" || ! -d "$repo_path" ]] && return 1

    # Reset to defaults before loading
    AGENT_SWEEP_ENABLED="true"
    AGENT_SWEEP_MAX_FILE_MB="10"
    set_agent_sweep_max_file_mb "$AGENT_SWEEP_MAX_FILE_MB"
    AGENT_SWEEP_SKIP_PHASES=()
    AGENT_SWEEP_EXTRA_CONTEXT=""
    AGENT_SWEEP_PRE_HOOK=""
    AGENT_SWEEP_POST_HOOK=""
    AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()

    # Find config file (YAML preferred, then JSON)
    local config_file=""
    for cfg in "$repo_path/.ru-agent.yml" "$repo_path/.ru-agent.yaml" "$repo_path/.ru-agent.json"; do
        [[ -f "$cfg" ]] && { config_file="$cfg"; break; }
    done
    if [[ -z "$config_file" ]]; then
        apply_agent_sweep_max_file_override
        return 0  # No config = use defaults + CLI override
    fi

    # Parse config with layered fallbacks: yq > python3 > jq (JSON only)
    local is_yaml=false
    [[ "$config_file" == *.yml || "$config_file" == *.yaml ]] && is_yaml=true

    # Helper: normalize truthy/falsy values to "true"/"false"
    _normalize_bool() {
        case "${1,,}" in  # ${1,,} lowercases the value (Bash 4.0+)
            true|yes|1|on) echo "true" ;;
            false|no|0|off|"") echo "false" ;;
            *) echo "true" ;;  # Default to true for unknown values
        esac
    }

    # shellcheck disable=SC2034  # AGENT_SWEEP_* vars are used by other functions
    if $is_yaml && command -v yq &>/dev/null; then
        # yq for YAML (preferred)
        local raw_enabled
        raw_enabled=$(yq -r '.agent_sweep.enabled // "true"' "$config_file" 2>/dev/null || echo "true")
        AGENT_SWEEP_ENABLED=$(_normalize_bool "$raw_enabled")
        local raw_max_mb raw_max_bytes
        raw_max_mb=$(yq -r '.agent_sweep.max_file_mb // ""' "$config_file" 2>/dev/null || echo "")
        raw_max_bytes=$(yq -r '.agent_sweep.max_file_size // ""' "$config_file" 2>/dev/null || echo "")
        apply_agent_sweep_max_file_limit "$raw_max_mb" "$raw_max_bytes"
        AGENT_SWEEP_EXTRA_CONTEXT=$(yq -r '.agent_sweep.extra_context // ""' "$config_file" 2>/dev/null || echo "")
        AGENT_SWEEP_PRE_HOOK=$(yq -r '.agent_sweep.pre_hook // ""' "$config_file" 2>/dev/null || echo "")
        AGENT_SWEEP_POST_HOOK=$(yq -r '.agent_sweep.post_hook // ""' "$config_file" 2>/dev/null || echo "")
        # Use direct array element extraction (each element on separate line)
        mapfile -t AGENT_SWEEP_SKIP_PHASES < <(yq -r '.agent_sweep.skip_phases // [] | .[]' "$config_file" 2>/dev/null)
        mapfile -t AGENT_SWEEP_DENYLIST_EXTRA_LOCAL < <(yq -r '.agent_sweep.denylist_extra // [] | .[]' "$config_file" 2>/dev/null)
    elif $is_yaml && command -v python3 &>/dev/null; then
        # python3 fallback for YAML
        local py_output
        py_output=$(python3 -c "
import sys, yaml, json
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
    cfg = data.get('agent_sweep', {})
    print(json.dumps({
        'enabled': str(cfg.get('enabled', True)).lower(),
        'max_file_mb': cfg.get('max_file_mb', None),
        'max_file_size': cfg.get('max_file_size', 5242880),
        'extra_context': cfg.get('extra_context', ''),
        'pre_hook': cfg.get('pre_hook', ''),
        'post_hook': cfg.get('post_hook', ''),
        'skip_phases': cfg.get('skip_phases', []),
        'denylist_extra': cfg.get('denylist_extra', [])
    }))
except Exception as e:
    print('{\"error\": \"' + str(e) + '\"}', file=sys.stderr)
    sys.exit(1)
" "$config_file" 2>/dev/null)
        if [[ $? -eq 0 && -n "$py_output" ]]; then
            local raw_enabled
            raw_enabled=$(json_get_field "$py_output" "enabled" || echo "true")
            AGENT_SWEEP_ENABLED=$(_normalize_bool "$raw_enabled")
            local raw_max_mb raw_max_bytes
            raw_max_mb=$(json_get_field "$py_output" "max_file_mb" || echo "")
            raw_max_bytes=$(json_get_field "$py_output" "max_file_size" || echo "")
            apply_agent_sweep_max_file_limit "$raw_max_mb" "$raw_max_bytes"
            AGENT_SWEEP_EXTRA_CONTEXT=$(json_get_field "$py_output" "extra_context" || echo "")
            AGENT_SWEEP_PRE_HOOK=$(json_get_field "$py_output" "pre_hook" || echo "")
            AGENT_SWEEP_POST_HOOK=$(json_get_field "$py_output" "post_hook" || echo "")
            local skip_arr deny_arr
            skip_arr=$(echo "$py_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('skip_phases',[])))" 2>/dev/null)
            deny_arr=$(echo "$py_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('denylist_extra',[])))" 2>/dev/null)
            [[ -n "$skip_arr" ]] && mapfile -t AGENT_SWEEP_SKIP_PHASES <<< "$skip_arr"
            [[ -n "$deny_arr" ]] && mapfile -t AGENT_SWEEP_DENYLIST_EXTRA_LOCAL <<< "$deny_arr"
        fi
    elif ! $is_yaml && command -v jq &>/dev/null; then
        # jq for JSON
        local raw_enabled
        raw_enabled=$(jq -r '.agent_sweep.enabled // true' "$config_file" 2>/dev/null || echo "true")
        AGENT_SWEEP_ENABLED=$(_normalize_bool "$raw_enabled")
        local raw_max_mb raw_max_bytes
        raw_max_mb=$(jq -r '.agent_sweep.max_file_mb // empty' "$config_file" 2>/dev/null || echo "")
        raw_max_bytes=$(jq -r '.agent_sweep.max_file_size // empty' "$config_file" 2>/dev/null || echo "")
        apply_agent_sweep_max_file_limit "$raw_max_mb" "$raw_max_bytes"
        AGENT_SWEEP_EXTRA_CONTEXT=$(jq -r '.agent_sweep.extra_context // ""' "$config_file" 2>/dev/null || echo "")
        AGENT_SWEEP_PRE_HOOK=$(jq -r '.agent_sweep.pre_hook // ""' "$config_file" 2>/dev/null || echo "")
        AGENT_SWEEP_POST_HOOK=$(jq -r '.agent_sweep.post_hook // ""' "$config_file" 2>/dev/null || echo "")
        mapfile -t AGENT_SWEEP_SKIP_PHASES < <(jq -r '.agent_sweep.skip_phases // [] | .[]' "$config_file" 2>/dev/null)
        mapfile -t AGENT_SWEEP_DENYLIST_EXTRA_LOCAL < <(jq -r '.agent_sweep.denylist_extra // [] | .[]' "$config_file" 2>/dev/null)
    elif ! $is_yaml && command -v python3 &>/dev/null; then
        # python3 fallback for JSON
        local py_output
        py_output=$(python3 -c "
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    cfg = data.get('agent_sweep', {})
    print(json.dumps({
        'enabled': str(cfg.get('enabled', True)).lower(),
        'max_file_mb': cfg.get('max_file_mb', None),
        'max_file_size': cfg.get('max_file_size', 5242880),
        'extra_context': cfg.get('extra_context', ''),
        'pre_hook': cfg.get('pre_hook', ''),
        'post_hook': cfg.get('post_hook', ''),
        'skip_phases': cfg.get('skip_phases', []),
        'denylist_extra': cfg.get('denylist_extra', [])
    }))
except Exception as e:
    print('{\"error\": \"' + str(e) + '\"}', file=sys.stderr)
    sys.exit(1)
" "$config_file" 2>/dev/null)
        if [[ $? -eq 0 && -n "$py_output" ]]; then
            local raw_enabled
            raw_enabled=$(json_get_field "$py_output" "enabled" || echo "true")
            AGENT_SWEEP_ENABLED=$(_normalize_bool "$raw_enabled")
            local raw_max_mb raw_max_bytes
            raw_max_mb=$(json_get_field "$py_output" "max_file_mb" || echo "")
            raw_max_bytes=$(json_get_field "$py_output" "max_file_size" || echo "")
            apply_agent_sweep_max_file_limit "$raw_max_mb" "$raw_max_bytes"
            AGENT_SWEEP_EXTRA_CONTEXT=$(json_get_field "$py_output" "extra_context" || echo "")
            AGENT_SWEEP_PRE_HOOK=$(json_get_field "$py_output" "pre_hook" || echo "")
            AGENT_SWEEP_POST_HOOK=$(json_get_field "$py_output" "post_hook" || echo "")
            local skip_arr deny_arr
            skip_arr=$(echo "$py_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('skip_phases',[])))" 2>/dev/null)
            deny_arr=$(echo "$py_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('denylist_extra',[])))" 2>/dev/null)
            [[ -n "$skip_arr" ]] && mapfile -t AGENT_SWEEP_SKIP_PHASES <<< "$skip_arr"
            [[ -n "$deny_arr" ]] && mapfile -t AGENT_SWEEP_DENYLIST_EXTRA_LOCAL <<< "$deny_arr"
        fi
    fi
    # Apply CLI override (if provided)
    apply_agent_sweep_max_file_override
    # If no parser available, stay with defaults (already set)
    return 0
}

# Check if a phase should be skipped based on per-repo config.
# Usage: should_skip_phase "phase_name"
# Returns: 0 if phase should be skipped, 1 otherwise
should_skip_phase() {
    local phase="${1:-}"
    [[ -z "$phase" ]] && return 1
    local p
    # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 empty array safety
    for p in ${AGENT_SWEEP_SKIP_PHASES[@]+"${AGENT_SWEEP_SKIP_PHASES[@]}"}; do
        [[ "$p" == "$phase" ]] && return 0
    done
    return 1
}

# Get combined denylist (global + per-repo local additions).
# Outputs: newline-separated list of patterns
get_combined_denylist() {
    # Output global denylist patterns (if any)
    if [[ ${#AGENT_SWEEP_DENYLIST_PATTERNS[@]} -gt 0 ]]; then
        printf '%s\n' "${AGENT_SWEEP_DENYLIST_PATTERNS[@]}"
    fi
    # Append local additions (if any)
    if [[ ${#AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]} -gt 0 ]]; then
        printf '%s\n' "${AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]}"
    fi
}

#------------------------------------------------------------------------------
# AGENT-SWEEP RESULT TRACKING
# Functions for tracking per-repo results during sweep execution.
#------------------------------------------------------------------------------

# Global result tracking state (initialized by setup_agent_sweep_results)
declare -g AGENT_SWEEP_STATE_DIR=""
declare -g AGENT_SWEEP_LOG_FILE=""
declare -g AGENT_SWEEP_REPO_LOG_DIR=""
declare -g AGENT_SWEEP_INSTANCE_LOCK_DIR=""
declare -g AGENT_SWEEP_INSTANCE_LOCK_BASE=""
declare -g RUN_ID=""
declare -g RUN_START_TIME=""
declare -g RUN_ARTIFACTS_DIR=""
declare -g SWEEP_SUCCESS_COUNT=0
declare -g SWEEP_FAIL_COUNT=0
declare -g SWEEP_SKIP_COUNT=0
declare -ga COMPLETED_REPOS=()
declare -g SWEEP_LAST_SESSION_NAME=""

# Initialize agent-sweep results tracking
# Sets up state directory, run ID, and results file
setup_agent_sweep_results() {
    local state_base="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}"
    AGENT_SWEEP_STATE_DIR="${state_base}/agent-sweep"
    ensure_dir "$AGENT_SWEEP_STATE_DIR"
    ensure_dir "${AGENT_SWEEP_STATE_DIR}/locks"

    RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
    export RUN_START_TIME
    RUN_START_TIME=$(date +%s)

    # Create run directory for artifacts
    RUN_ARTIFACTS_DIR="${AGENT_SWEEP_STATE_DIR}/runs/${RUN_ID}"
    ensure_dir "$RUN_ARTIFACTS_DIR"

    # Set up log files (if verbose/debug mode)
    local log_date_dir
    log_date_dir="${state_base}/logs/$(date +%Y-%m-%d)"
    ensure_dir "$log_date_dir"
    AGENT_SWEEP_LOG_FILE="${log_date_dir}/agent_sweep.log"
    AGENT_SWEEP_REPO_LOG_DIR="${log_date_dir}/repos"
    ensure_dir "$AGENT_SWEEP_REPO_LOG_DIR"

    # Log session start
    if [[ $LOG_LEVEL -ge 1 || "$VERBOSE" == "true" ]]; then
        log_verbose "Agent-sweep session starting: run_id=$RUN_ID"
        log_verbose "Log file: $AGENT_SWEEP_LOG_FILE"
    fi

    # Set up results file (used by existing write_result function)
    export RESULTS_FILE="${AGENT_SWEEP_STATE_DIR}/results.ndjson"
    export RESULTS_LOCK_DIR="${AGENT_SWEEP_STATE_DIR}/locks/results.lock"

    # Write header record
    local header_ts
    header_ts=$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"run_id\":\"$RUN_ID\",\"started_at\":\"$header_ts\",\"type\":\"header\"}" > "$RESULTS_FILE"

    # Reset counts
    SWEEP_SUCCESS_COUNT=0
    SWEEP_FAIL_COUNT=0
    SWEEP_SKIP_COUNT=0
    COMPLETED_REPOS=()
}

# Aggregate results from NDJSON file for summary reporting
# Usage: get_results_summary [results_file]
# Outputs: JSON summary to stdout
get_results_summary() {
    local results_file="${1:-${RESULTS_FILE:-}}"
    [[ -z "$results_file" || ! -f "$results_file" ]] && {
        echo '{"total":0,"succeeded":0,"failed":0,"skipped":0}'
        return
    }

    if command -v jq &>/dev/null; then
        jq -s '
            [.[] | select(.type == "result" or .type == "summary" or .type == null)] |
            {
                total: length,
                succeeded: [.[] | select(.status == "success")] | length,
                failed: [.[] | select(.status | . == "failed" or . == "error")] | length,
                skipped: [.[] | select(.status | . == "skipped" or . == "preflight")] | length,
                repos: [.[] | {repo, status, duration}]
            }
        ' < "$results_file" 2>/dev/null || echo '{"total":0,"succeeded":0,"failed":0,"skipped":0}'
    else
        # Fallback: derive counts from results file when possible
        local summary_lines
        summary_lines=$(grep -c '"type":"summary"' "$results_file" 2>/dev/null || echo "0")

        local success=0 failed=0 skipped=0 total=0
        if [[ "$summary_lines" =~ ^[0-9]+$ ]] && (( summary_lines > 0 )); then
            success=$(grep -c '"type":"summary".*"status":"success"' "$results_file" 2>/dev/null || echo "0")
            failed=$(grep -c '"type":"summary".*"status":"failed"' "$results_file" 2>/dev/null || echo "0")
            local error_count
            error_count=$(grep -c '"type":"summary".*"status":"error"' "$results_file" 2>/dev/null || echo "0")
            failed=$((failed + error_count))
            skipped=$(grep -c '"type":"summary".*"status":"skipped"' "$results_file" 2>/dev/null || echo "0")
            total=$((success + failed + skipped))
        else
            # Fall back to tracked counts if summary lines are unavailable
            success=${SWEEP_SUCCESS_COUNT:-0}
            failed=${SWEEP_FAIL_COUNT:-0}
            skipped=${SWEEP_SKIP_COUNT:-0}
            total=$((success + failed + skipped))
        fi

        echo "{\"total\":$total,\"succeeded\":$success,\"failed\":$failed,\"skipped\":$skipped}"
    fi
}

# Mark a repo as completed for resume tracking
# Usage: mark_repo_completed repo_spec
mark_repo_completed() {
    local repo_spec="${1:-}"
    [[ -z "$repo_spec" ]] && return 1
    COMPLETED_REPOS+=("$repo_spec")

    # Update status based on most recent operation
    case "${2:-success}" in
        success) ((SWEEP_SUCCESS_COUNT++)) ;;
        failed|error) ((SWEEP_FAIL_COUNT++)) ;;
        skipped|preflight) ((SWEEP_SKIP_COUNT++)) ;;
    esac
}

# Check if a repo was already completed in agent-sweep (for resume)
# Usage: is_sweep_repo_completed repo_spec
is_sweep_repo_completed() {
    local repo_spec="${1:-}"
    array_contains COMPLETED_REPOS "$repo_spec"
}

# Filter out completed repos from an array (for agent-sweep resume)
# Usage: filter_sweep_completed_repos array_name
filter_sweep_completed_repos() {
    local -n arr_ref=$1
    local filtered=()
    local repo
    for repo in "${arr_ref[@]}"; do
        is_sweep_repo_completed "$repo" || filtered+=("$repo")
    done
    arr_ref=("${filtered[@]}")
}

#------------------------------------------------------------------------------
# AGENT-SWEEP ARTIFACT CAPTURE
# Functions for capturing debugging artifacts (git state, pane output, etc.)
# Artifacts are stored under: $RUN_ARTIFACTS_DIR/<repo_name>/
#------------------------------------------------------------------------------

# Set up artifact directory for a specific repo.
# Usage: setup_repo_artifact_dir repo_path
# Returns: Path to repo artifact directory (creates if needed)
# Sets: CURRENT_REPO_ARTIFACT_DIR global
declare -g CURRENT_REPO_ARTIFACT_DIR=""

setup_repo_artifact_dir() {
    local repo_path="${1:-}"
    [[ -z "$repo_path" ]] && return 1
    [[ -z "$RUN_ARTIFACTS_DIR" ]] && {
        log_warn "setup_repo_artifact_dir: RUN_ARTIFACTS_DIR not set"
        return 1
    }

    # Derive repo name from path (last component)
    local repo_name
    repo_name=$(basename "$repo_path")

    CURRENT_REPO_ARTIFACT_DIR="${RUN_ARTIFACTS_DIR}/${repo_name}"
    ensure_dir "$CURRENT_REPO_ARTIFACT_DIR"
    echo "$CURRENT_REPO_ARTIFACT_DIR"
}

# Capture git state to a file for debugging.
# Usage: capture_git_state repo_path output_file
# Captures: status, recent log, branch info, HEAD, stash
capture_git_state() {
    local repo_path="${1:-}"
    local output_file="${2:-}"

    [[ -z "$repo_path" || ! -d "$repo_path" ]] && return 1
    [[ -z "$output_file" ]] && return 1

    {
        echo "=== Captured at: $(date -Iseconds 2>/dev/null || date) ==="
        echo ""
        echo "=== git status ==="
        git -C "$repo_path" status 2>&1
        echo ""
        echo "=== git log -5 --oneline ==="
        git -C "$repo_path" log -5 --oneline 2>&1 || echo "(no commits)"
        echo ""
        echo "=== git branch -vv ==="
        git -C "$repo_path" branch -vv 2>&1
        echo ""
        echo "=== HEAD ==="
        git -C "$repo_path" rev-parse HEAD 2>&1 || echo "(no HEAD)"
        echo ""
        echo "=== git stash list ==="
        git -C "$repo_path" stash list 2>&1 || echo "(no stash)"
        echo ""
        echo "=== git diff --stat ==="
        git -C "$repo_path" diff --stat 2>&1 || echo "(no diff)"
    } > "$output_file" 2>&1
}

# Capture last N lines from tmux pane to file.
# Usage: capture_pane_tail session_name output_file [lines]
# Args:
#   session_name: tmux session name
#   output_file: where to write captured output
#   lines: number of lines to capture (default 400)
capture_pane_tail() {
    local session="${1:-}"
    local output_file="${2:-}"
    local lines="${3:-400}"

    [[ -z "$session" || -z "$output_file" ]] && return 1

    # Capture pane content - pane 1 is typically the agent workspace
    # Use negative -S value to scroll back from current position
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux capture-pane -t "${session}:0.1" -p -S -"$lines" > "$output_file" 2>/dev/null || {
            # Fallback: try pane 0 if pane 1 doesn't exist
            tmux capture-pane -t "${session}:0.0" -p -S -"$lines" > "$output_file" 2>/dev/null || true
        }
    else
        echo "(session not found: $session)" > "$output_file"
    fi
}

# Capture spawn response JSON to artifact file.
# Usage: capture_spawn_response repo_path spawn_json
capture_spawn_response() {
    local repo_path="${1:-}"
    local spawn_json="${2:-}"

    [[ -z "$repo_path" || -z "$spawn_json" ]] && return 1

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$repo_path") || return 1
    echo "$spawn_json" > "${artifact_dir}/spawn.json"
}

# Capture plan JSON (commit or release) to artifact file.
# Usage: capture_plan_json repo_path plan_type plan_json
# Args:
#   plan_type: "commit" or "release"
capture_plan_json() {
    local repo_path="${1:-}"
    local plan_type="${2:-}"
    local plan_json="${3:-}"

    [[ -z "$repo_path" || -z "$plan_type" || -z "$plan_json" ]] && return 1
    [[ "$plan_type" != "commit" && "$plan_type" != "release" ]] && return 1

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$repo_path") || return 1
    echo "$plan_json" > "${artifact_dir}/${plan_type}_plan.json"
}

# Append activity snapshot to NDJSON log.
# Usage: log_activity_snapshot repo_path phase status [extra_json]
log_activity_snapshot() {
    local repo_path="${1:-}"
    local phase="${2:-}"
    local status="${3:-}"
    local extra_json="${4:-}"

    [[ -z "$repo_path" ]] && return 1

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$repo_path") || return 1

    local ts
    ts=$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build JSON - phase/status are controlled strings (no special chars expected)
    local json="{\"ts\":\"$ts\",\"phase\":\"$phase\",\"status\":\"$status\""
    [[ -n "$extra_json" ]] && json="${json},${extra_json}"
    json="${json}}"

    echo "$json" >> "${artifact_dir}/activity.ndjson"
}

# Capture full artifact set before killing session.
# Usage: capture_final_artifacts repo_path session_name
# Should be called BEFORE ntm_kill_session
capture_final_artifacts() {
    local repo_path="${1:-}"
    local session_name="${2:-}"

    [[ -z "$repo_path" ]] && return 1

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$repo_path") || return 1

    # Capture pane output before session is killed (CRITICAL)
    if [[ -n "$session_name" ]]; then
        capture_pane_tail "$session_name" "${artifact_dir}/pane_tail.txt" 400
    fi

    # Capture final git state
    capture_git_state "$repo_path" "${artifact_dir}/git_after.txt"

    # Log final activity
    log_activity_snapshot "$repo_path" "complete" "captured"
}

#------------------------------------------------------------------------------
# AGENT-SWEEP STATE PERSISTENCE
#
# Save/load/cleanup state for --resume and --restart functionality.
# State file: ${AGENT_SWEEP_STATE_DIR}/state.json
#------------------------------------------------------------------------------

# Additional state tracking (global)
declare -g SWEEP_WITH_RELEASE="false"
declare -g SWEEP_CURRENT_REPO=""
declare -g SWEEP_CURRENT_PHASE=0

# Save agent-sweep state for resume capability.
# Args: $1 = status (in_progress|completed|interrupted)
# Uses atomic write (temp + mv) for safety.
save_agent_sweep_state() {
    local status="${1:-in_progress}"

    # Guard: require state dir to be initialized
    if [[ -z "$AGENT_SWEEP_STATE_DIR" ]]; then
        log_verbose "save_agent_sweep_state: state dir not initialized, skipping"
        return 1
    fi

    local state_file="${AGENT_SWEEP_STATE_DIR}/state.json"
    local tmp_file="${state_file}.tmp.$$"
    local completed_json
    local completed_file="${AGENT_SWEEP_STATE_DIR}/completed_repos.txt"

    # Merge completed repos from file (parallel workers) into memory
    if [[ -s "$completed_file" ]]; then
        if [[ ${#COMPLETED_REPOS[@]} -eq 0 ]]; then
            mapfile -t COMPLETED_REPOS < "$completed_file"
        else
            local repo
            while IFS= read -r repo; do
                [[ -z "$repo" ]] && continue
                if ! array_contains COMPLETED_REPOS "$repo"; then
                    COMPLETED_REPOS+=("$repo")
                fi
            done < "$completed_file"
        fi
    fi

    # Build JSON arrays for repos
    if command -v jq &>/dev/null; then
        # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 empty array safety
        completed_json=$(printf '%s\n' ${COMPLETED_REPOS[@]+"${COMPLETED_REPOS[@]}"} 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
    elif command -v python3 &>/dev/null; then
        completed_json=$(python3 -c "
import json, sys
repos = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(repos))
" <<<"$(printf '%s\n' ${COMPLETED_REPOS[@]+"${COMPLETED_REPOS[@]}"} 2>/dev/null)" 2>/dev/null || echo '[]')
    else
        # Fallback: manual JSON array construction
        local first=true item
        completed_json="["
        # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 empty array safety
        for item in ${COMPLETED_REPOS[@]+"${COMPLETED_REPOS[@]}"}; do
            $first || completed_json+=","
            completed_json+="\"$(json_escape "$item")\""
            first=false
        done
        completed_json+="]"
    fi

    # Ensure valid JSON booleans/numbers (prevent empty values)
    local with_release_json="${SWEEP_WITH_RELEASE:-false}"
    [[ "$with_release_json" != "true" ]] && with_release_json="false"
    local current_phase="${SWEEP_CURRENT_PHASE:-0}"
    local success_count="${SWEEP_SUCCESS_COUNT:-0}"
    local fail_count="${SWEEP_FAIL_COUNT:-0}"
    local skip_count="${SWEEP_SKIP_COUNT:-0}"

    # Escape string values for JSON safety
    local run_id_escaped current_repo_escaped
    run_id_escaped=$(json_escape "$RUN_ID")
    current_repo_escaped=$(json_escape "$SWEEP_CURRENT_REPO")

    # Write state atomically
    cat > "$tmp_file" <<EOF
{
  "run_id": "$run_id_escaped",
  "status": "$status",
  "started_at": "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "with_release": $with_release_json,
  "repos_completed": $completed_json,
  "current_repo": "$current_repo_escaped",
  "current_phase": $current_phase,
  "success_count": $success_count,
  "fail_count": $fail_count,
  "skip_count": $skip_count
}
EOF

    mv "$tmp_file" "$state_file"
    log_verbose "Saved agent-sweep state: $status"
}

# Load agent-sweep state from previous run.
# Returns 0 if state loaded successfully, 1 if no state or invalid.
# Populates: RUN_ID, COMPLETED_REPOS[], SWEEP_* globals
load_agent_sweep_state() {
    # Guard: require state dir to be initialized
    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 1

    local state_file="${AGENT_SWEEP_STATE_DIR}/state.json"
    [[ ! -f "$state_file" ]] && return 1

    local state_json
    state_json=$(cat "$state_file" 2>/dev/null) || return 1
    [[ -z "$state_json" ]] && return 1

    # Extract fields
    local saved_run_id saved_status
    saved_run_id=$(json_get_field "$state_json" "run_id")
    saved_status=$(json_get_field "$state_json" "status")

    # Validate required fields
    if [[ -z "$saved_run_id" ]]; then
        log_verbose "State file missing run_id, cannot resume"
        return 1
    fi

    # Only resume in_progress or interrupted states
    if [[ "$saved_status" != "in_progress" && "$saved_status" != "interrupted" ]]; then
        log_verbose "Previous run was '$saved_status', not resumable"
        return 1
    fi

    # Restore state with defaults for empty/missing values
    RUN_ID="$saved_run_id"
    local val
    val=$(json_get_field "$state_json" "with_release")
    SWEEP_WITH_RELEASE="${val:-false}"
    SWEEP_CURRENT_REPO=$(json_get_field "$state_json" "current_repo")
    val=$(json_get_field "$state_json" "current_phase")
    SWEEP_CURRENT_PHASE="${val:-0}"
    val=$(json_get_field "$state_json" "success_count")
    SWEEP_SUCCESS_COUNT="${val:-0}"
    val=$(json_get_field "$state_json" "fail_count")
    SWEEP_FAIL_COUNT="${val:-0}"
    val=$(json_get_field "$state_json" "skip_count")
    SWEEP_SKIP_COUNT="${val:-0}"

    # Load completed repos array
    COMPLETED_REPOS=()
    local completed_json
    completed_json=$(json_get_field "$state_json" "repos_completed")
    if [[ -n "$completed_json" ]]; then
        if command -v jq &>/dev/null; then
            while IFS= read -r repo; do
                [[ -n "$repo" ]] && COMPLETED_REPOS+=("$repo")
            done < <(echo "$completed_json" | jq -r '.[]' 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            while IFS= read -r repo; do
                [[ -n "$repo" ]] && COMPLETED_REPOS+=("$repo")
            done < <(python3 -c "import json,sys; [print(r) for r in json.loads(sys.stdin.read())]" <<<"$completed_json" 2>/dev/null)
        else
            log_warn "Cannot parse completed repos: neither jq nor python3 available"
            log_warn "Resume may re-process already completed repositories"
        fi
    fi

    # Merge any completed repos recorded by parallel workers
    local completed_file="${AGENT_SWEEP_STATE_DIR}/completed_repos.txt"
    if [[ -s "$completed_file" ]]; then
        local repo
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            if ! array_contains COMPLETED_REPOS "$repo"; then
                COMPLETED_REPOS+=("$repo")
            fi
        done < "$completed_file"
    fi

    log_info "Resuming run $RUN_ID: ${#COMPLETED_REPOS[@]} repos already completed"
    return 0
}

# Remove agent-sweep state file (for --restart or clean completion).
cleanup_agent_sweep_state() {
    # Guard: require state dir to be initialized
    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 0

    local state_file="${AGENT_SWEEP_STATE_DIR}/state.json"
    rm -f "$state_file"
    log_verbose "Cleaned up agent-sweep state"
}

#------------------------------------------------------------------------------
# AGENT-SWEEP RATE LIMIT BACKOFF
#
# Coordinate global pause across all parallel workers when rate limited.
# Uses exponential backoff with jitter to avoid thundering herd.
#------------------------------------------------------------------------------

# Trigger global rate limit backoff.
# All workers will pause until pause_until timestamp.
# Args:
#   $1: reason - description of why backoff triggered
#   $2: current_delay - initial delay in seconds (default: 30)
# Behavior:
#   - Uses exponential backoff (doubles on repeated triggers)
#   - Adds ±25% jitter to prevent thundering herd
#   - Caps at 10 minutes max delay
agent_sweep_backoff_trigger() {
    local reason="${1:-rate_limited}"
    local current_delay="${2:-30}"
    local max_delay=600  # 10 minutes cap

    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 1

    local backoff_state_file="${AGENT_SWEEP_STATE_DIR}/backoff.state"
    local backoff_lock="${AGENT_SWEEP_STATE_DIR}/locks/backoff.lock"

    # Try to acquire lock with 10 second timeout
    if dir_lock_acquire "$backoff_lock" 10; then
        local now pause_until new_delay

        # Check if already in backoff and extend with exponential increase
        if [[ -f "$backoff_state_file" ]]; then
            local current_pause
            current_pause=$(json_get_field "$(cat "$backoff_state_file")" "pause_until" 2>/dev/null || echo 0)
            now=$(date +%s)
            if [[ "$current_pause" -gt "$now" ]]; then
                # Already paused, double the delay (exponential backoff)
                new_delay=$((current_delay * 2))
                [[ "$new_delay" -gt "$max_delay" ]] && new_delay=$max_delay
            else
                new_delay=$current_delay
            fi
        else
            new_delay=$current_delay
        fi

        # Add jitter (±25%) to prevent thundering herd
        # RANDOM is 0-32767, scale to ±25% of delay
        local max_jitter=$((new_delay / 4))
        local jitter=0
        if [[ $max_jitter -gt 0 ]]; then
            jitter=$(( (RANDOM % (2 * max_jitter + 1)) - max_jitter ))
        fi
        new_delay=$((new_delay + jitter))
        [[ "$new_delay" -lt 5 ]] && new_delay=5  # Minimum 5 seconds

        pause_until=$(($(date +%s) + new_delay))

        # Write state atomically
        local escaped_reason
        escaped_reason=$(json_escape "$reason")
        echo "{\"reason\":\"$escaped_reason\",\"pause_until\":$pause_until,\"delay\":$new_delay}" > "$backoff_state_file"

        log_warn "Rate limit detected ($reason), global pause for ${new_delay}s"
        dir_lock_release "$backoff_lock"
        return 0
    else
        log_warn "Could not acquire backoff lock"
        return 1
    fi
}

# Wait if global backoff is active.
# Should be called before starting work on a repo.
# Returns: 0 after wait completes or no wait needed, 1 on error
agent_sweep_backoff_wait_if_needed() {
    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 0

    local backoff_state_file="${AGENT_SWEEP_STATE_DIR}/backoff.state"

    [[ ! -f "$backoff_state_file" ]] && return 0

    local pause_until now
    pause_until=$(json_get_field "$(cat "$backoff_state_file")" "pause_until" 2>/dev/null || echo 0)
    now=$(date +%s)

    if [[ "$pause_until" -gt "$now" ]]; then
        local wait_secs=$((pause_until - now))
        log_warn "Global backoff active, waiting ${wait_secs}s..."
        sleep "$wait_secs"
    fi
    return 0
}

# Clear backoff state (call on successful completion).
agent_sweep_backoff_clear() {
    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 0

    local backoff_state_file="${AGENT_SWEEP_STATE_DIR}/backoff.state"
    rm -f "$backoff_state_file"
    log_verbose "Cleared rate limit backoff state"
}

# Check if currently in backoff (non-blocking check).
# Returns: 0 if in backoff, 1 if not
agent_sweep_backoff_active() {
    [[ -z "$AGENT_SWEEP_STATE_DIR" ]] && return 1

    local backoff_state_file="${AGENT_SWEEP_STATE_DIR}/backoff.state"
    [[ ! -f "$backoff_state_file" ]] && return 1

    local pause_until now
    pause_until=$(json_get_field "$(cat "$backoff_state_file")" "pause_until" 2>/dev/null || echo 0)
    now=$(date +%s)

    [[ "$pause_until" -gt "$now" ]]
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

#------------------------------------------------------------------------------
# PORTABLE JSON PARSING
#
# Provides json_get_field(), json_is_success(), and json_escape() with layered
# fallbacks: jq → python3 → perl (JSON::PP) → minimal sed (fragile, flat only).
# This enables ntm robot mode parsing on systems without jq installed.
#------------------------------------------------------------------------------

# Extract a field value from a JSON object.
# Usage: json_get_field "$json_string" "field_name"
# Returns: The field value on stdout. For nested objects, returns JSON string.
# Fallback order: jq > python3 > perl+JSON::PP > sed (flat strings only)
json_get_field() {
    local json="${1:-}"
    local field="${2:-}"

    [[ -z "$json" || -z "$field" ]] && return 1

    # Best: jq (most reliable, handles all JSON types correctly)
    if command -v jq &>/dev/null; then
        # Note: Can't use `// empty` as it treats false as falsy
        jq -r --arg f "$field" '
            if has($f) then
                .[$f] | if type == "null" then empty
                        elif type == "boolean" then (if . then "true" else "false" end)
                        else .
                        end
            else empty end
        ' <<<"$json" 2>/dev/null
        return 0
    fi

    # Fallback: python3 (widely available, handles complex JSON)
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    val = data.get(sys.argv[1], '')
    if isinstance(val, (dict, list)):
        print(json.dumps(val))
    elif val is True:
        print('true')
    elif val is False:
        print('false')
    elif val is None:
        pass  # empty output
    else:
        print(val)
except:
    pass
" "$field" <<<"$json" 2>/dev/null
        return 0
    fi

    # Fallback: perl with JSON::PP (often available on Linux)
    if command -v perl &>/dev/null && perl -MJSON::PP -e1 2>/dev/null; then
        perl -MJSON::PP -e '
            my $field = shift;
            local $/; my $json = <STDIN>;
            my $data = eval { decode_json($json) };
            exit 0 unless defined $data && ref($data) eq "HASH";
            my $val = $data->{$field};
            if (!defined $val) { exit 0; }
            if (ref($val)) { print encode_json($val); }
            elsif (JSON::PP::is_bool($val)) { print $val ? "true" : "false"; }
            else { print $val; }
        ' "$field" <<<"$json" 2>/dev/null
        return 0
    fi

    # Last resort: minimal sed (ONLY works for simple flat string values!)
    # WARNING: This is fragile and won't handle nested objects, arrays,
    # escaped quotes, or boolean/numeric types correctly. Use with caution.
    local result
    result=$(sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"([^"\\]*(\\.[^"\\]*)*)".*/\1/p' <<<"$json" | head -n1)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    # Try simple arrays first: extract ["item1","item2"] as-is (bd-kgg5)
    # This must come before unquoted values to avoid partial array matching
    result=$(sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*(\[[^]]*\]).*/\1/p' <<<"$json" | head -n1)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    # Try unquoted values (numbers, booleans)
    # Note: [^],}] puts ] first in negated class for correct literal matching
    result=$(sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*([^],}]+).*/\1/p' <<<"$json" | head -n1 | tr -d '[:space:]')
    [[ -n "$result" ]] && printf '%s\n' "$result"
    return 0
}

# Check if JSON has "success": true
# Usage: if json_is_success "$json_string"; then echo "success"; fi
# Returns: 0 if success:true, 1 otherwise
json_is_success() {
    local json="${1:-}"
    local success_val
    success_val=$(json_get_field "$json" "success")
    [[ "$success_val" == "true" ]]
}

# Escape a string for safe embedding in JSON.
# Usage: escaped=$(json_escape "$raw_string")
# Handles: backslash, double-quote, newline, tab, carriage return, backspace, form feed
json_escape() {
    local str="${1:-}"
    # Order matters: escape backslashes first, then other chars
    str="${str//\\/\\\\}"      # \ -> \\
    str="${str//\"/\\\"}"      # " -> \"
    str="${str//$'\n'/\\n}"    # newline -> \n
    str="${str//$'\t'/\\t}"    # tab -> \t
    str="${str//$'\r'/\\r}"    # carriage return -> \r
    str="${str//$'\b'/\\b}"    # backspace -> \b
    str="${str//$'\f'/\\f}"    # form feed -> \f
    printf '%s' "$str"
}

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

        # Multiple processes may append concurrently (parallel sync); guard writes.
        if [[ -n "${RESULTS_LOCK_DIR:-}" ]]; then
            if dir_lock_acquire "$RESULTS_LOCK_DIR" 30; then
                printf '%s' "$line" >> "$RESULTS_FILE"
                dir_lock_release "$RESULTS_LOCK_DIR"
            else
                # Best-effort fallback: write without lock if the lock can't be acquired.
                # Log warning to stderr (visible to user) so they know there may be data issues.
                log_warn "Could not acquire results lock after 30s, writing without lock (may cause data issues)"
                printf '%s' "$line" >> "$RESULTS_FILE"
            fi
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
    [[ $LOG_LEVEL -lt 1 && "$VERBOSE" != "true" ]] && return
    printf '%b\n' "${DIM}[VERBOSE] $*${RESET}" >&2
    _log_to_file "VERBOSE" "$*"
}

log_debug() {
    [[ $LOG_LEVEL -lt 2 && "$DEBUG" != "true" ]] && return
    printf '%b\n' "${DIM}[DEBUG] $*${RESET}" >&2
    _log_to_file "DEBUG" "$*"
}

# Write log message to file (if file logging is enabled)
_log_to_file() {
    local level="$1" msg="$2"
    [[ -z "$AGENT_SWEEP_LOG_FILE" ]] && return
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$AGENT_SWEEP_LOG_FILE" 2>/dev/null
}

# Redact sensitive data from log messages
redact_sensitive() {
    local msg="$1"
    # Redact common secret patterns
    msg="${msg//sk-[a-zA-Z0-9_-]*/sk-***REDACTED***}"
    msg="${msg//ghp_[a-zA-Z0-9]*/ghp_***REDACTED***}"
    msg="${msg//gho_[a-zA-Z0-9]*/gho_***REDACTED***}"
    msg="${msg//AKIA[A-Z0-9]*/AKIA***REDACTED***}"
    msg="${msg//password=[^[:space:]]*/password=***REDACTED***}"
    msg="${msg//api_key=[^[:space:]]*/api_key=***REDACTED***}"
    msg="${msg//token=[^[:space:]]*/token=***REDACTED***}"
    echo "$msg"
}

# Resolve structured output format.
# Precedence: CLI (--format/--json) > RU_OUTPUT_FORMAT > TOON_DEFAULT_FORMAT > text
resolve_output_format() {
    local fmt="${OUTPUT_FORMAT:-}"

    if [[ -z "$fmt" ]]; then
        if [[ -n "${RU_OUTPUT_FORMAT:-}" ]]; then
            fmt="$RU_OUTPUT_FORMAT"
        elif [[ -n "${TOON_DEFAULT_FORMAT:-}" ]]; then
            fmt="$TOON_DEFAULT_FORMAT"
        else
            fmt="text"
        fi
    fi

    fmt="${fmt,,}"

    case "$fmt" in
        ""|text)
            OUTPUT_FORMAT="text"
            JSON_OUTPUT="false"
            ;;
        json)
            OUTPUT_FORMAT="json"
            JSON_OUTPUT="true"
            ;;
        toon)
            OUTPUT_FORMAT="toon"
            JSON_OUTPUT="true"
            ;;
        *)
            log_error "Invalid --format: $fmt (expected text|json|toon)"
            exit 4
            ;;
    esac

    if [[ "$SHOW_STATS" == "true" ]]; then
        export TOON_STATS=1
    fi
}

emit_structured() {
    # Args:
    #   $1: JSON string
    local json_str="${1:-}"

    if [[ "$OUTPUT_FORMAT" != "toon" ]]; then
        printf '%s\n' "$json_str"
        return 0
    fi

    if ! declare -f toon_encode >/dev/null 2>&1; then
        log_warn "toon.sh not available; falling back to JSON"
        printf '%s\n' "$json_str"
        return 0
    fi

    if ! toon_available >/dev/null 2>&1; then
        log_warn "tru not available; falling back to JSON"
        printf '%s\n' "$json_str"
        return 0
    fi

    local toon_out
    if toon_out="$(printf '%s' "$json_str" | toon_encode)"; then
        printf '%s\n' "$toon_out"
        return 0
    fi

    log_warn "TOON encode failed; falling back to JSON"
    printf '%s\n' "$json_str"
    return 0
}

# Output JSON to stdout (only in --json mode)
output_json() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        printf '%s\n' "$1"
    fi
}

#------------------------------------------------------------------------------
# AGENT-SWEEP ERROR FORMATTING
#
# User-friendly, actionable error messages for agent-sweep failures.
# These functions produce consistent, helpful messages with fix suggestions.
#------------------------------------------------------------------------------

# Format a structured error message with reason and fix suggestion.
# Args:
#   $1: category - brief error category (e.g., "Cannot run agent-sweep on owner/repo")
#   $2: reason - why the error occurred
#   $3: fix - optional multiline fix suggestion
# All output goes to stderr
format_agent_sweep_error() {
    local category="${1:-Unknown error}"
    local reason="${2:-}"
    local fix="${3:-}"

    echo "" >&2
    printf '%b\n' "${RED}ERROR:${RESET} $category" >&2
    if [[ -n "$reason" ]]; then
        printf '%b\n' "  ${DIM}Reason:${RESET} $reason" >&2
    fi
    if [[ -n "$fix" ]]; then
        echo "" >&2
        printf '%b\n' "  ${CYAN}To fix:${RESET}" >&2
        echo "$fix" | sed 's/^/    /' >&2
    fi
    echo "" >&2
}

# Format a warning message (non-fatal but needs attention)
format_agent_sweep_warning() {
    local category="${1:-Warning}"
    local message="${2:-}"
    local options="${3:-}"

    echo "" >&2
    printf '%b\n' "${YELLOW}WARNING:${RESET} $category" >&2
    if [[ -n "$message" ]]; then
        printf '%b\n' "  $message" >&2
    fi
    if [[ -n "$options" ]]; then
        echo "" >&2
        printf '%b\n' "  ${CYAN}Options:${RESET}" >&2
        echo "$options" | sed 's/^/    /' >&2
    fi
    echo "" >&2
}

# Preflight failure error
error_preflight_uncommitted() {
    local repo_path="$1"
    format_agent_sweep_error \
        "Cannot run agent-sweep on $(basename "$repo_path")" \
        "Repository has uncommitted changes" \
        "cd $repo_path
git stash       # Save changes temporarily
ru agent-sweep  # Run sweep
git stash pop   # Restore changes"
}

error_preflight_conflicts() {
    local repo_path="$1"
    format_agent_sweep_error \
        "Cannot run agent-sweep on $(basename "$repo_path")" \
        "Repository has unresolved merge conflicts" \
        "cd $repo_path
git status      # See conflicting files
# Resolve conflicts manually, then:
git add .
git commit"
}

error_preflight_detached() {
    local repo_path="$1"
    format_agent_sweep_error \
        "Cannot run agent-sweep on $(basename "$repo_path")" \
        "Repository is in detached HEAD state" \
        "cd $repo_path
git checkout main    # Or your default branch
ru agent-sweep"
}

# NTM errors
error_ntm_not_found() {
    format_agent_sweep_error \
        "ntm (Named Tmux Manager) not found" \
        "agent-sweep requires ntm to spawn and manage AI agent sessions" \
        "Install ntm from: https://github.com/dicklesworthstone/ntm
Or check your PATH"
}

error_ntm_spawn_failed() {
    local reason="$1"
    format_agent_sweep_error \
        "Failed to start AI agent session" \
        "$reason" \
        "Ensure ANTHROPIC_API_KEY or OPENAI_API_KEY is set
Run: ntm doctor
Check: ntm list (to see running sessions)"
}

error_ntm_no_api_key() {
    format_agent_sweep_error \
        "No API key configured for AI agent" \
        "ntm requires an API key to communicate with AI providers" \
        "Set one of:
  export ANTHROPIC_API_KEY=sk-...
  export OPENAI_API_KEY=sk-..."
}

# Agent timeout/failure
warning_agent_timeout() {
    local repo_name="$1"
    local phase="$2"
    local timeout_secs="$3"
    format_agent_sweep_warning \
        "Agent timed out during Phase $phase for $repo_name" \
        "The agent did not complete within $timeout_secs seconds." \
        "--timeout $((timeout_secs * 2))    # Increase timeout
--retry          # Retry failed repos
--skip $repo_name  # Skip this repo"
}

warning_agent_error() {
    local repo_name="$1"
    local error="$2"
    format_agent_sweep_warning \
        "Agent reported error for $repo_name" \
        "$error" \
        "--retry          # Retry failed repos
--verbose        # See detailed output"
}

# Validation failures
error_validation_denylist() {
    local repo_name="$1"
    local file="$2"
    format_agent_sweep_error \
        "Commit plan validation failed for $repo_name" \
        "File matches denylist: $file" \
        "The agent proposed a file that violates security rules.
This file will not be committed.
Edit .ru/agent-sweep.conf to allow if needed."
}

error_validation_size() {
    local repo_name="$1"
    local file="$2"
    local size="$3"
    local limit="$4"
    format_agent_sweep_error \
        "Commit plan validation failed for $repo_name" \
        "File exceeds size limit: $file (${size}MB > ${limit}MB)" \
        "Use --max-file-mb=$size to increase limit
Or exclude this file from the commit plan."
}

error_validation_secrets() {
    local repo_name="$1"
    local details="$2"
    format_agent_sweep_error \
        "Secrets detected in changes for $repo_name" \
        "$details" \
        "Remove secrets before committing.
Use --secret-scan=off to disable (not recommended).
Check: gitleaks detect --source=$repo_name"
}

# Rate limit
warning_rate_limit() {
    local wait_secs="$1"
    format_agent_sweep_warning \
        "API rate limit reached" \
        "Backing off for $wait_secs seconds before retry..." \
        "Progress will resume automatically.
Press Ctrl+C to interrupt (state will be saved)."
}

# Resume/restart hints
info_resume_available() {
    echo "" >&2
    printf '%b\n' "${BLUE}ℹ${RESET} Interrupted sweep can be resumed:" >&2
    printf '%b\n' "    ru agent-sweep --resume" >&2
    printf '%b\n' "  Or start fresh:" >&2
    printf '%b\n' "    ru agent-sweep --restart" >&2
    echo "" >&2
}

#------------------------------------------------------------------------------
# AGENT-SWEEP PROGRESS DISPLAY
#
# Real-time progress display for agent-sweep operations.
# Supports interactive (TTY with spinners/bars) and non-interactive modes.
#------------------------------------------------------------------------------

# Global progress tracking state
declare -g PROGRESS_TOTAL=0
declare -g PROGRESS_CURRENT=0
declare -g PROGRESS_SUCCEEDED=0
declare -g PROGRESS_FAILED=0
declare -g PROGRESS_SKIPPED=0
declare -g PROGRESS_START_EPOCH=0
declare -g PROGRESS_REPO_START_EPOCH=0
declare -g PROGRESS_CURRENT_REPO=""
declare -g PROGRESS_CURRENT_PHASE=""
declare -g PROGRESS_IS_INTERACTIVE=false
declare -g PROGRESS_PHASE_HISTORY=()

# Phase names for display
declare -gA PROGRESS_PHASE_NAMES=(
    [1]="Understanding codebase"
    [2]="Generating commit plan"
    [3]="Release workflow (optional)"
    [preflight]="Running preflight checks"
    [spawn]="Starting agent session"
    [wait]="Waiting for completion"
    [validate]="Validating plan"
    [apply]="Applying changes"
)

# Initialize progress tracking for agent-sweep.
# Args: $1 = total repo count
progress_init() {
    local total="${1:-0}"

    PROGRESS_TOTAL=$total
    PROGRESS_CURRENT=0
    PROGRESS_SUCCEEDED=0
    PROGRESS_FAILED=0
    PROGRESS_SKIPPED=0
    PROGRESS_START_EPOCH=$(date +%s)
    PROGRESS_CURRENT_REPO=""
    PROGRESS_CURRENT_PHASE=""
    PROGRESS_PHASE_HISTORY=()

    # Detect interactive mode
    if [[ -t 2 && "${QUIET:-false}" != "true" && "${AGENT_SWEEP_JSON_OUTPUT:-false}" != "true" ]]; then
        PROGRESS_IS_INTERACTIVE=true
    else
        PROGRESS_IS_INTERACTIVE=false
    fi

    if [[ "$PROGRESS_IS_INTERACTIVE" == "true" ]]; then
        _progress_show_header "$total"
    else
        log_info "Starting agent-sweep: $total repositories"
    fi
}

# Show initial header (interactive mode)
_progress_show_header() {
    local total="$1"
    echo "" >&2
    if [[ "${GUM_AVAILABLE:-false}" == "true" ]]; then
        gum style --border rounded --padding "0 2" --border-foreground "#89b4fa" \
            "$(gum style --bold "Agent Sweep")" \
            "Processing $total repositories" >&2
    else
        # Build content line with dynamic padding
        local content="Processing $total repositories"
        local box_width=38
        local content_len=${#content}
        local total_padding=$((box_width - content_len))
        # Clamp to 0 if content exceeds box width (defensive)
        [[ $total_padding -lt 0 ]] && total_padding=0
        local left_pad=$((total_padding / 2))
        local right_pad=$((total_padding - left_pad))
        local left_spaces right_spaces
        printf -v left_spaces '%*s' "$left_pad" ''
        printf -v right_spaces '%*s' "$right_pad" ''

        printf '%b\n' "${CYAN}╭──────────────────────────────────────╮${RESET}" >&2
        printf '%b\n' "${CYAN}│${RESET}          ${BOLD}Agent Sweep${RESET}              ${CYAN}│${RESET}" >&2
        printf '%b\n' "${CYAN}│${RESET}${left_spaces}${content}${right_spaces}${CYAN}│${RESET}" >&2
        printf '%b\n' "${CYAN}╰──────────────────────────────────────╯${RESET}" >&2
    fi
    echo "" >&2
}

# Start processing a new repository.
# Args: $1 = repo name/spec
progress_start_repo() {
    local repo_name="${1:-unknown}"

    ((PROGRESS_CURRENT++))
    # shellcheck disable=SC2034  # Tracking state for external introspection
    PROGRESS_CURRENT_REPO="$repo_name"
    PROGRESS_CURRENT_PHASE="preflight"
    PROGRESS_REPO_START_EPOCH=$(date +%s)
    PROGRESS_PHASE_HISTORY=()

    SWEEP_CURRENT_REPO="$repo_name"

    if [[ "$PROGRESS_IS_INTERACTIVE" == "true" ]]; then
        _progress_show_repo_start "$repo_name"
    else
        log_step "[$PROGRESS_CURRENT/$PROGRESS_TOTAL] Processing: $repo_name"
    fi
}

# Show repo start (interactive mode)
_progress_show_repo_start() {
    local repo_name="$1"

    echo "" >&2
    if [[ "${GUM_AVAILABLE:-false}" == "true" ]]; then
        printf '%b\n' "$(gum style --foreground "#89b4fa" --bold "[$PROGRESS_CURRENT/$PROGRESS_TOTAL]") $repo_name" >&2
    else
        printf '%b\n' "${CYAN}[$PROGRESS_CURRENT/$PROGRESS_TOTAL]${RESET} ${BOLD}$repo_name${RESET}" >&2
    fi

    _progress_show_bar
}

# Update current phase.
# Args: $1 = phase identifier (1, 2, 3, preflight, spawn, wait, validate, apply)
progress_update_phase() {
    local phase="${1:-}"
    local phase_name="${PROGRESS_PHASE_NAMES[$phase]:-$phase}"

    # Record previous phase in history
    if [[ -n "$PROGRESS_CURRENT_PHASE" ]]; then
        PROGRESS_PHASE_HISTORY+=("$PROGRESS_CURRENT_PHASE")
    fi

    PROGRESS_CURRENT_PHASE="$phase"
    SWEEP_CURRENT_PHASE="$phase"

    if [[ "$PROGRESS_IS_INTERACTIVE" == "true" ]]; then
        _progress_show_phase "$phase_name"
    else
        log_verbose "  Phase: $phase_name"
    fi
}

# Show phase update (interactive mode)
_progress_show_phase() {
    local phase_name="$1"

    if [[ "${GUM_AVAILABLE:-false}" == "true" ]]; then
        printf '%b\n' "  └─ $(gum style --foreground '#a6e3a1' "$phase_name") ⏳" >&2
    else
        printf '%b\n' "  └─ ${GREEN}$phase_name${RESET} ⏳" >&2
    fi
}

# Complete current repository with status.
# Args: $1 = status (success, failed, skipped)
#       $2 = optional detail message
progress_complete_repo() {
    local status="${1:-success}"
    local detail="${2:-}"
    local duration=$(($(date +%s) - PROGRESS_REPO_START_EPOCH))
    local duration_str
    duration_str=$(format_duration "$duration")

    case "$status" in
        success) ((PROGRESS_SUCCEEDED++)) ;;
        failed|error) ((PROGRESS_FAILED++)) ;;
        skipped|preflight) ((PROGRESS_SKIPPED++)) ;;
    esac

    if [[ "$PROGRESS_IS_INTERACTIVE" == "true" ]]; then
        _progress_show_repo_complete "$status" "$duration_str" "$detail"
    else
        case "$status" in
            success) log_success "  Completed in $duration_str" ;;
            failed|error) log_error "  Failed: ${detail:-unknown error}" ;;
            skipped|preflight) log_warn "  Skipped: ${detail:-preflight check failed}" ;;
        esac
    fi
}

# Show repo completion (interactive mode)
_progress_show_repo_complete() {
    local status="$1"
    local duration="$2"
    local detail="$3"

    local status_icon status_color
    case "$status" in
        success) status_icon="✓"; status_color="${GREEN}" ;;
        failed|error) status_icon="✗"; status_color="${RED}" ;;
        skipped|preflight) status_icon="⊘"; status_color="${YELLOW}" ;;
        *) status_icon="?"; status_color="${DIM}" ;;
    esac

    printf '%b\n' "  └─ ${status_color}${status_icon}${RESET} Completed in $duration" >&2

    if [[ -n "$detail" && "$status" != "success" ]]; then
        printf '%b\n' "     ${DIM}$detail${RESET}" >&2
    fi
}

# Render progress bar to stderr.
_progress_show_bar() {
    local pct=0
    [[ $PROGRESS_TOTAL -gt 0 ]] && pct=$((PROGRESS_CURRENT * 100 / PROGRESS_TOTAL))

    # Calculate elapsed time and estimate
    local elapsed=$(($(date +%s) - PROGRESS_START_EPOCH))
    local eta_str=""
    if [[ $PROGRESS_CURRENT -gt 1 && $pct -gt 0 && $pct -lt 100 ]]; then
        local per_repo=$((elapsed / (PROGRESS_CURRENT - 1)))
        local remaining=$(( (PROGRESS_TOTAL - PROGRESS_CURRENT + 1) * per_repo ))
        eta_str=" (~$(format_duration $remaining) remaining)"
    fi

    local bar_width=30
    local filled=$((pct * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')
    printf '%b\n' "  ${DIM}$bar${RESET} $pct%%$eta_str" >&2
}

# Show final summary (called at end of sweep).
# Uses existing print_agent_sweep_summary() for detailed output.
progress_summary() {
    local total_duration=$(($(date +%s) - PROGRESS_START_EPOCH))
    local duration_str
    duration_str=$(format_duration "$total_duration")

    if [[ "$PROGRESS_IS_INTERACTIVE" != "true" ]]; then
        local s="$PROGRESS_SUCCEEDED"
        local f="$PROGRESS_FAILED"
        local k="$PROGRESS_SKIPPED"

        # In parallel mode, parent counters are not updated; derive from results file if available.
        if (( s + f + k == 0 )) && [[ -n "${RESULTS_FILE:-}" && -f "$RESULTS_FILE" ]]; then
            if command -v jq &>/dev/null; then
                s=$(jq -r 'select(.type=="summary" and .status=="success") | .repo' "$RESULTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
                f=$(jq -r 'select(.type=="summary" and .status=="failed") | .repo' "$RESULTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
                k=$(jq -r 'select(.type=="summary" and .status=="skipped") | .repo' "$RESULTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
            else
                s=$(grep -c '"type":"summary".*"status":"success"' "$RESULTS_FILE" 2>/dev/null || echo 0)
                f=$(grep -c '"type":"summary".*"status":"failed"' "$RESULTS_FILE" 2>/dev/null || echo 0)
                k=$(grep -c '"type":"summary".*"status":"skipped"' "$RESULTS_FILE" 2>/dev/null || echo 0)
            fi
        fi

        log_info "Agent-sweep complete: $s succeeded, $f failed, $k skipped"
        log_info "Total time: $duration_str"
    fi

    # Detailed summary handled by print_agent_sweep_summary()
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
    --format FMT         Output format: text|json|toon (env: RU_OUTPUT_FORMAT, TOON_DEFAULT_FORMAT)
    --json               Output JSON to stdout (alias for --format json)
    --stats              Show JSON vs TOON token stats on stderr (or set TOON_STATS=1)
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
    --parallel N, -j N   Sync N repos concurrently (default: 4)
    --resume             Resume an interrupted sync from where it left off
    --restart            Discard interrupted sync state and start fresh
    --timeout SECONDS    Network timeout for slow operations (default: 30)

STATUS OPTIONS:
    --fetch              Fetch remotes first (default)
    --no-fetch           Skip fetch, use cached state

INIT OPTIONS:
    --example            Include example repositories in initial config

ADD OPTIONS:
    --private            Add to private.txt instead of public.txt
    --from-cwd           Detect repo from current working directory

LIST OPTIONS:
    --paths              Show local paths instead of URLs
    --public             Show only repos from public.txt
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
    --status             Show review lock/checkpoint status and exit
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
    ru import my_repos.txt  Import repos from file (auto-detects visibility)
    ru review --dry-run  Discover issues/PRs without starting reviews
    ru review --status   Show review lock/checkpoint status
    ru review            Start AI-assisted review of issues/PRs
    ru review --apply    Execute approved changes from plan
    ru review --basic    Answer queued review questions
    ru review --analytics Show review analytics dashboard

CONFIGURATION:
    Config:  ~/.config/ru/config
    Repos:   ~/.config/ru/repos.d/public.txt (and private.txt)
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

# Show stylish quick menu when ru is run with no arguments
# Uses gum for beautiful output with ANSI fallback
show_quick_menu() {
    # Note: check_gum may not have been called yet, so check directly
    local has_gum="false"
    command -v gum &>/dev/null && has_gum="true"

    if [[ "$has_gum" == "true" ]]; then
        # ══════════════════════════════════════════════════════════════════════
        # GUM-STYLED OUTPUT
        # ══════════════════════════════════════════════════════════════════════
        printf '\n' >&2

        # Header banner with double border
        gum style \
            --border double \
            --border-foreground 212 \
            --padding "0 2" \
            --margin "0 0" \
            --bold \
            "🔄 ru v${VERSION}" \
            "Repo Updater" >&2

        printf '\n' >&2

        # Commands section header
        gum style --foreground 214 --bold "COMMANDS" >&2
        printf '\n' >&2

        # Core workflow commands
        gum style --foreground 39 --bold "  Core Workflow" >&2
        gum style "    $(gum style --foreground 82 'sync')           Clone missing repos and pull updates" >&2
        gum style "    $(gum style --foreground 82 'status')         Show repository status (read-only)" >&2
        gum style "    $(gum style --foreground 82 'review')         AI-assisted review of issues and PRs" >&2
        printf '\n' >&2

        # Repository management
        gum style --foreground 39 --bold "  Repository Management" >&2
        gum style "    $(gum style --foreground 82 'add') <repo>      Add a repository to your list" >&2
        gum style "    $(gum style --foreground 82 'remove') <repo>   Remove a repository from your list" >&2
        gum style "    $(gum style --foreground 82 'list')           Show configured repositories" >&2
        gum style "    $(gum style --foreground 212 --bold 'import') <file>   $(gum style --foreground 212 'Import repos from file (auto-detects visibility)')" >&2
        printf '\n' >&2

        # Setup & maintenance
        gum style --foreground 39 --bold "  Setup & Maintenance" >&2
        gum style "    $(gum style --foreground 82 'init')           Initialize configuration directory" >&2
        gum style "    $(gum style --foreground 82 'config')         Show or set configuration values" >&2
        gum style "    $(gum style --foreground 82 'doctor')         Run system diagnostics" >&2
        gum style "    $(gum style --foreground 82 'prune')          Find and manage orphan repositories" >&2
        gum style "    $(gum style --foreground 82 'self-update')    Update ru to the latest version" >&2
        printf '\n' >&2

        # Quick examples
        gum style --foreground 214 --bold "QUICK START" >&2
        printf '\n' >&2
        gum style --faint "  # First time setup" >&2
        gum style --foreground 82 "  ru init" >&2
        printf '\n' >&2
        gum style --faint "  # Add and sync repos" >&2
        gum style --foreground 82 "  ru add owner/repo" >&2
        gum style --foreground 82 "  ru sync" >&2
        printf '\n' >&2
        gum style --faint "  # Import repos from a file" >&2
        gum style --foreground 212 "  ru import my_repos.txt" >&2
        printf '\n' >&2

        # Footer
        gum style --faint "  Run 'ru --help' for full documentation" >&2
        gum style --faint "  https://github.com/Dicklesworthstone/repo_updater" >&2
        printf '\n' >&2
    else
        # ══════════════════════════════════════════════════════════════════════
        # ANSI FALLBACK OUTPUT
        # ══════════════════════════════════════════════════════════════════════
        printf '\n' >&2

        # Header banner with box drawing
        printf '%b\n' "${BOLD}${MAGENTA}╔════════════════════════════════════════════╗${RESET}" >&2
        printf '%b\n' "${BOLD}${MAGENTA}║${RESET}  ${BOLD}🔄 ru${RESET} v${VERSION}                              ${BOLD}${MAGENTA}║${RESET}" >&2
        printf '%b\n' "${BOLD}${MAGENTA}║${RESET}  ${DIM}Repo Updater${RESET}                              ${BOLD}${MAGENTA}║${RESET}" >&2
        printf '%b\n' "${BOLD}${MAGENTA}╚════════════════════════════════════════════╝${RESET}" >&2
        printf '\n' >&2

        # Commands section header
        printf '%b\n' "${BOLD}${YELLOW}COMMANDS${RESET}" >&2
        printf '\n' >&2

        # Core workflow commands
        printf '%b\n' "  ${BOLD}${CYAN}Core Workflow${RESET}" >&2
        printf '%b\n' "    ${GREEN}sync${RESET}           Clone missing repos and pull updates" >&2
        printf '%b\n' "    ${GREEN}status${RESET}         Show repository status (read-only)" >&2
        printf '%b\n' "    ${GREEN}review${RESET}         AI-assisted review of issues and PRs" >&2
        printf '\n' >&2

        # Repository management
        printf '%b\n' "  ${BOLD}${CYAN}Repository Management${RESET}" >&2
        printf '%b\n' "    ${GREEN}add${RESET} <repo>      Add a repository to your list" >&2
        printf '%b\n' "    ${GREEN}remove${RESET} <repo>   Remove a repository from your list" >&2
        printf '%b\n' "    ${GREEN}list${RESET}           Show configured repositories" >&2
        printf '%b\n' "    ${BOLD}${MAGENTA}import${RESET} <file>   ${MAGENTA}Import repos from file (auto-detects visibility)${RESET}" >&2
        printf '\n' >&2

        # Setup & maintenance
        printf '%b\n' "  ${BOLD}${CYAN}Setup & Maintenance${RESET}" >&2
        printf '%b\n' "    ${GREEN}init${RESET}           Initialize configuration directory" >&2
        printf '%b\n' "    ${GREEN}config${RESET}         Show or set configuration values" >&2
        printf '%b\n' "    ${GREEN}doctor${RESET}         Run system diagnostics" >&2
        printf '%b\n' "    ${GREEN}prune${RESET}          Find and manage orphan repositories" >&2
        printf '%b\n' "    ${GREEN}self-update${RESET}    Update ru to the latest version" >&2
        printf '\n' >&2

        # Quick examples
        printf '%b\n' "${BOLD}${YELLOW}QUICK START${RESET}" >&2
        printf '\n' >&2
        printf '%b\n' "  ${DIM}# First time setup${RESET}" >&2
        printf '%b\n' "  ${GREEN}ru init${RESET}" >&2
        printf '\n' >&2
        printf '%b\n' "  ${DIM}# Add and sync repos${RESET}" >&2
        printf '%b\n' "  ${GREEN}ru add owner/repo${RESET}" >&2
        printf '%b\n' "  ${GREEN}ru sync${RESET}" >&2
        printf '\n' >&2
        printf '%b\n' "  ${DIM}# Import repos from a file${RESET}" >&2
        printf '%b\n' "  ${MAGENTA}ru import my_repos.txt${RESET}" >&2
        printf '\n' >&2

        # Footer
        printf '%b\n' "  ${DIM}Run 'ru --help' for full documentation${RESET}" >&2
        printf '%b\n' "  ${DIM}https://github.com/Dicklesworthstone/repo_updater${RESET}" >&2
        printf '\n' >&2
    fi
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
    PROJECTS_DIR=$(expand_tilde "$PROJECTS_DIR")
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

    # Create public.txt for public repositories
    local public_file="$repos_dir/public.txt"
    if [[ ! -f "$public_file" ]]; then
        cat > "$public_file" << 'EOF'
# Public repositories
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
        log_verbose "Created repos file: $public_file"
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
        if ! can_prompt; then
            [[ "$default" == "true" ]]
            return $?
        fi

        # ANSI fallback
        local yn
        if [[ "$default" == "true" ]]; then
            printf '%s ' "$prompt [Y/n]" >&2
            IFS= read -r yn
            case "${yn,,}" in
                n|no) return 1 ;;
                *) return 0 ;;
            esac
        else
            printf '%s ' "$prompt [y/N]" >&2
            IFS= read -r yn
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

# Check that a candidate absolute path is safely under a base directory (lexical).
# This is used to guard any rm -rf operations that use paths sourced from state files.
# Notes:
# - We intentionally do NOT resolve symlinks (rm -rf on a symlink removes the link, not the target).
# - We reject paths containing dot segments to prevent traversal tricks.
_is_path_under_base() {
    local path="$1"
    local base="$2"

    [[ -n "$path" && -n "$base" ]] || return 1

    # Require absolute paths (macOS/Linux support); refuse to operate on relative paths.
    [[ "$path" == /* && "$base" == /* ]] || return 1

    # Normalize trailing slashes
    base="${base%/}"
    path="${path%/}"

    # Refuse empty/base root
    [[ -n "$base" && "$base" != "/" ]] || return 1
    [[ -n "$path" && "$path" != "/" ]] || return 1

    # Refuse path traversal/dot segments
    case "$path" in
        *"/./"*|*"/../"*|*"/."|*"/..") return 1 ;;
    esac
    case "$base" in
        *"/./"*|*"/../"*|*"/."|*"/..") return 1 ;;
    esac

    [[ "$path" == "$base" || "$path" == "$base/"* ]]
}

# Parse all GitHub URL formats and extract components
# Supports: https://github.com/owner/repo, git@github.com:owner/repo.git,
#           github.com/owner/repo, owner/repo (assumes github.com)
# Args: url host_var owner_var repo_var (variable names)
parse_repo_url() {
    local url="$1"
    local host_var="$2"
    local owner_var="$3"
    local repo_var="$4"

    # Use _out_ prefix to avoid shadowing caller's output variable names.
    # Without this, if caller passes "host" as host_var, `local host=""` shadows
    # it and `printf -v host` sets the local instead of caller's variable.
    local _out_host="" _out_owner="" _out_repo=""

    # Normalize: strip .git suffix and trailing slashes
    url="${url%.git}"
    url="${url%/}"

    local matched="false"

    # SSH scp-like format: git@host:owner/repo (repo must not contain /)
    if [[ "$url" =~ ^git@([^:]+):([^/]+)/([^/]+)$ ]]; then
        _out_host="${BASH_REMATCH[1]}"
        _out_owner="${BASH_REMATCH[2]}"
        _out_repo="${BASH_REMATCH[3]}"
        matched="true"
    # SSH URL format: ssh://git@host/owner/repo (optional user part)
    elif [[ "$url" =~ ^ssh://([^@/]+@)?([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _out_host="${BASH_REMATCH[2]}"
        _out_owner="${BASH_REMATCH[3]}"
        _out_repo="${BASH_REMATCH[4]}"
        matched="true"
    # HTTPS format: https://host/owner/repo (optional user@ for auth)
    elif [[ "$url" =~ ^https?://([^@/]+@)?([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _out_host="${BASH_REMATCH[2]}"
        _out_owner="${BASH_REMATCH[3]}"
        _out_repo="${BASH_REMATCH[4]}"
        matched="true"
    # Host/owner/repo format (no protocol): github.com/owner/repo
    elif [[ "$url" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _out_host="${BASH_REMATCH[1]}"
        _out_owner="${BASH_REMATCH[2]}"
        _out_repo="${BASH_REMATCH[3]}"
        matched="true"
    # Shorthand: owner/repo (assumes github.com)
    elif [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
        _out_host="github.com"
        _out_owner="${BASH_REMATCH[1]}"
        _out_repo="${BASH_REMATCH[2]}"
        matched="true"
    fi

    # Validate parsed components for path safety
    if [[ "$matched" == "true" ]]; then
        # Strip optional :port from host (avoid filesystem-unfriendly ':' in full layout)
        _out_host="${_out_host%%:*}"
        if ! _is_safe_path_segment "$_out_owner" || ! _is_safe_path_segment "$_out_repo"; then
            return 1
        fi
        _set_out_var "$host_var" "$_out_host" || return 1
        _set_out_var "$owner_var" "$_out_owner" || return 1
        _set_out_var "$repo_var" "$_out_repo" || return 1
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
# Args: spec url_var branch_var local_name_var (variable names)
parse_repo_spec() {
    local spec="$1"
    local url_var="$2"
    local branch_var="$3"
    local local_name_var="$4"

    # Use _out_ prefix to avoid shadowing caller's output variable names.
    local _out_url="" _out_branch="" _out_local_name=""

    # Extract 'as <name>' if present (must be last)
    if [[ "$spec" =~ ^(.+)[[:space:]]+as[[:space:]]+([^[:space:]]+)$ ]]; then
        spec="${BASH_REMATCH[1]}"
        # Trim trailing whitespace from spec (greedy .+ may capture trailing spaces)
        spec="${spec%"${spec##*[![:space:]]}"}"
        _out_local_name="${BASH_REMATCH[2]}"
    else
        _out_local_name=""
    fi

    # Default: no branch
    _out_url="$spec"
    _out_branch=""

    # Extract '@branch' by splitting on the LAST '@' and only accepting it if the
    # left side is a valid repo URL. This avoids mis-parsing ssh://git@host/... forms
    # while still supporting branch names with / like feature/foo
    if [[ "$spec" == *"@"* ]]; then
        local maybe_url maybe_branch _tmp_host _tmp_owner _tmp_repo
        maybe_url="${spec%@*}"
        maybe_branch="${spec##*@}"
        # Only accept as branch if: left side parses as URL, branch is non-empty and has no spaces
        if [[ -n "$maybe_url" && -n "$maybe_branch" && "$maybe_branch" != *[[:space:]]* ]]; then
            if parse_repo_url "$maybe_url" _tmp_host _tmp_owner _tmp_repo; then
                _out_url="$maybe_url"
                _out_branch="$maybe_branch"
            fi
        fi
    fi

    _set_out_var "$url_var" "$_out_url" || return 1
    _set_out_var "$branch_var" "$_out_branch" || return 1
    _set_out_var "$local_name_var" "$_out_local_name" || return 1
}

# Resolve a repo spec into validated parts and a local path
# This is the central function for parsing and validating repo specifications.
# Args: spec projects_dir layout url_var branch_var custom_var path_var repo_id_var (variable names)
# repo_id is canonical for reporting (host/owner/repo, or owner/repo for github.com)
# Returns: 0 on success, 1 on invalid spec
resolve_repo_spec() {
    local spec="$1"
    local projects_dir="$2"
    local layout="$3"
    local url_var="$4"
    local branch_var="$5"
    local custom_var="$6"
    local path_var="$7"
    local repo_id_var="$8"

    # Use unique prefixes to avoid shadowing caller variables and
    # avoid conflicts with variables used in parse_repo_spec and parse_repo_url
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
    # Use _rrs_ prefix to avoid shadowing caller's output variable names
    local _rrs_path=""
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

    # Build canonical repo ID for display/reporting
    local _rrs_repo_id=""
    if [[ "$spec_host" == "github.com" ]]; then
        _rrs_repo_id="${spec_owner}/${spec_repo}"
    else
        _rrs_repo_id="${spec_host}/${spec_owner}/${spec_repo}"
    fi

    _set_out_var "$url_var" "$spec_url" || return 1
    _set_out_var "$branch_var" "$spec_branch" || return 1
    _set_out_var "$custom_var" "$spec_custom" || return 1
    _set_out_var "$path_var" "$_rrs_path" || return 1
    _set_out_var "$repo_id_var" "$_rrs_repo_id" || return 1

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
        printf '%s' "$all_repos" | dedupe_repos
    fi
}

# Find the configured repo spec for a repo_id (preserves branch pins/custom names)
# Args: repo_id (owner/repo or host/owner/repo)
# Output: matching repo spec on stdout
find_repo_spec_for_repo_id() {
    local target_repo_id="$1"
    [[ -z "$target_repo_id" ]] && return 1

    local spec url branch custom_name path repo_id
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        if resolve_repo_spec "$spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name path repo_id; then
            if [[ "$repo_id" == "$target_repo_id" ]]; then
                printf '%s\n' "$spec"
                return 0
            fi
        fi
    done < <(get_all_repos)

    return 1
}

# Attempt to detect latest release version without the GitHub API (avoids rate limits/proxies).
# Returns:
#   0 with version on stdout - success
#   1 - no releases exist (redirect resolves to /releases)
#   2 - request failed
get_latest_release_from_redirect() {
    local latest_url="https://github.com/$RU_REPO_OWNER/$RU_REPO_NAME/releases/latest"
    local effective_url=""

    if command -v curl &>/dev/null; then
        if ! effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null); then
            return 2
        fi
    elif command -v wget &>/dev/null; then
        effective_url=$(
            wget -qS --spider --max-redirect=0 "$latest_url" 2>&1 \
                | awk '/^  Location: /{print $2}' \
                | tail -1 \
                | tr -d '\r'
        )
        if [[ -z "$effective_url" ]]; then
            return 2
        fi
    else
        return 2
    fi

    if [[ "$effective_url" != *"/tag/"* ]]; then
        return 1
    fi

    local tag="${effective_url##*/tag/}"
    tag="${tag%%\?*}"
    local version="${tag#v}"
    [[ -n "$version" ]] || return 2
    printf '%s\n' "$version"
}

append_query_param() {
    local url="$1"
    local key="$2"
    local value="$3"

    local sep='?'
    [[ "$url" == *\?* ]] && sep='&'
    printf '%s%s%s=%s' "$url" "$sep" "$key" "$value"
}

cache_bust_url() {
    local url="$1"
    if [[ "${RU_CACHE_BUST:-1}" != "1" ]]; then
        printf '%s' "$url"
        return 0
    fi
    append_query_param "$url" "ru_cb" "${RU_CACHE_BUST_TOKEN:-$(date +%s)}"
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

# Check if repo has uncommitted changes (staged, unstaged, or untracked)
# Returns: 0 if dirty, 1 if clean or not a git repo
repo_is_dirty() {
    local repo_path="$1"
    [[ -z "$repo_path" ]] && return 1
    if ! is_git_repo "$repo_path"; then
        return 1
    fi

    if ! git -C "$repo_path" diff --quiet -- 2>/dev/null; then
        return 0
    fi
    if ! git -C "$repo_path" diff --cached --quiet -- 2>/dev/null; then
        return 0
    fi
    if [[ -n "$(git -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        return 0
    fi

    return 1
}

# Check if repo has changes excluding .ru artifacts
# Returns: 0 if dirty (excluding .ru), 1 if clean or not a git repo
repo_is_dirty_excluding_ru() {
    local repo_path="$1"
    [[ -z "$repo_path" ]] && return 1
    if ! is_git_repo "$repo_path"; then
        return 1
    fi

    local changed
    changed=$(git -C "$repo_path" diff --name-only 2>/dev/null | grep -vE '^\.(ru)(/|$)' || true)
    [[ -n "$changed" ]] && return 0
    changed=$(git -C "$repo_path" diff --cached --name-only 2>/dev/null | grep -vE '^\.(ru)(/|$)' || true)
    [[ -n "$changed" ]] && return 0
    changed=$(git -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.(ru)(/|$)' || true)
    [[ -n "$changed" ]] && return 0

    return 1
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

    # Check dirty status using plumbing (no status parsing)
    local dirty="false"
    if repo_is_dirty "$repo_path"; then
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
    local ahead=0 behind=0 output
    # shellcheck disable=SC1083  # @{u} is valid git syntax for upstream tracking branch
    if ! output=$(git -C "$repo_path" rev-list --left-right --count HEAD...@{u} 2>/dev/null); then
        # If rev-list fails (e.g. unrelated histories), use -1 to indicate unknown
        # (must be numeric for JSON output compatibility, ? would break printf %d)
        echo "STATUS=diverged AHEAD=-1 BEHIND=-1 DIRTY=$dirty BRANCH=$branch"
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
    local completed_name="$2"
    local pending_name="$3"

    _is_valid_var_name "$completed_name" || return 1
    _is_valid_var_name "$pending_name" || return 1

    # Use _arr_ prefix to avoid shadowing caller's variable names.
    # If caller passes "completed" as completed_name, `local completed=()` would
    # shadow it and eval would expand the empty local instead of caller's array.
    # Note: We check array length first because "${arr[@]}" creates one empty
    # element when arr is empty (the quotes preserve an empty expansion).
    local -a _arr_completed=()
    local -a _arr_pending=()
    local _len
    eval "_len=\${#${completed_name}[@]}"
    [[ $_len -gt 0 ]] && eval "_arr_completed=(\"\${${completed_name}[@]}\")"
    eval "_len=\${#${pending_name}[@]}"
    [[ $_len -gt 0 ]] && eval "_arr_pending=(\"\${${pending_name}[@]}\")"

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
    if [[ ${#_arr_completed[@]} -gt 0 ]]; then
        for item in "${_arr_completed[@]}"; do
            [[ -n "$completed_json" ]] && completed_json+=","
            completed_json+="\"$(json_escape "$item")\""
        done
    fi

    # Build pending array JSON (handle empty array with set -u)
    local pending_json=""
    if [[ ${#_arr_pending[@]} -gt 0 ]]; then
        for item in "${_arr_pending[@]}"; do
            [[ -n "$pending_json" ]] && pending_json+=","
            pending_json+="\"$(json_escape "$item")\""
        done
    fi

    # Write JSON to temp file (uses hex escapes for braces to avoid breaking
    # awk-based function extraction in test files that count brace depth)
    local _ob=$'\x7b' _cb=$'\x7d'  # { and } as hex escapes
    (
        echo "${_ob}"
        echo "  \"run_id\": \"$run_id\","
        echo "  \"status\": \"$status\","
        echo "  \"config_hash\": \"$config_hash\","
        echo "  \"results_file\": \"${RESULTS_FILE:-}\","
        echo "  \"completed\": [$completed_json],"
        echo "  \"pending\": [$pending_json]"
        echo "${_cb}"
    ) > "$tmp_file"

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
        if [[ "$status" == "no_upstream" ]]; then
            write_result "$repo_label" "pull" "no_upstream" "0" "" "$local_path"
            echo "CONFLICT:no_upstream:$repo_label"
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
    local repos_name="$1"
    local parallel_count=$2

    _is_valid_var_name "$repos_name" || return 1
    local -a repos=()
    eval "repos=(\"\${${repos_name}[@]-}\")"

    # Validate parallel count
    if [[ ! "$parallel_count" =~ ^[0-9]+$ ]] || [[ "$parallel_count" -lt 1 ]]; then
        log_error "Invalid parallel count: $parallel_count (must be >= 1)"
        return 4
    fi

    local total=${#repos[@]}
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
    local work_queue results_file lock_base progress_file
    work_queue=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    results_file=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    lock_base=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    progress_file=$(mktemp_file) || { log_error "Failed to create temp file"; return 3; }
    local queue_lock_dir="${lock_base}.queue.lock"
    local results_lock_dir="${lock_base}.results.lock"
    local progress_lock_dir="${lock_base}.progress.lock"

    # Write repos to work queue
    printf '%s\n' "${repos[@]}" > "$work_queue"

    # Initialize progress counter
    printf '0\n' > "$progress_file"

    # Launch workers
    local worker_pids=()
    for ((i=0; i<parallel_count; i++)); do
        (
            while true; do
                # Atomically get next repo from queue
                local repo_spec
                if dir_lock_acquire "$queue_lock_dir" 60; then
                    repo_spec=$(head -1 "$work_queue" 2>/dev/null)
                    if [[ -n "$repo_spec" ]]; then
                        # Remove from queue (portable)
                        tail -n +2 "$work_queue" > "${work_queue}.tmp" 2>/dev/null
                        mv "${work_queue}.tmp" "$work_queue" 2>/dev/null
                    fi
                    dir_lock_release "$queue_lock_dir"
                else
                    repo_spec=""
                fi

                # Exit if no more work
                [[ -z "$repo_spec" ]] && break

                # Process the repo
                local result
                result=$(process_single_repo_worker "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
                    "$UPDATE_STRATEGY" "$AUTOSTASH" "$CLONE_ONLY" "$PULL_ONLY" "$FETCH_REMOTES")

                # Append result atomically
                if dir_lock_acquire "$results_lock_dir" 60; then
                    printf '%s\n' "$result" >> "$results_file"
                    dir_lock_release "$results_lock_dir"
                else
                    # Best-effort fallback: warn and write without lock
                    printf '\n⚠ Warning: Could not acquire results lock, writing without lock\n' >&2
                    printf '%s\n' "$result" >> "$results_file"
                fi

                # Update progress atomically
                if dir_lock_acquire "$progress_lock_dir" 60; then
                    local current
                    current=$(cat "$progress_file")
                    echo $((current + 1)) > "$progress_file"
                    printf '\r→ Progress: %d/%d' "$((current + 1))" "$total" >&2
                    dir_lock_release "$progress_lock_dir"
                fi
            done
        ) &
        worker_pids+=($!)
    done

    # Wait for all workers
    for pid in "${worker_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    printf '\n' >&2  # New line after progress

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

    # Cleanup temp files and lock directories
    rm -f "$work_queue" "${work_queue}.tmp" "$results_file" "$lock_base" "$progress_file" 2>/dev/null
    rmdir "$queue_lock_dir" "$results_lock_dir" "$progress_lock_dir" 2>/dev/null || true

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

    # Remove temp files and lock directories
    if [[ -n "${RESULTS_FILE:-}" && -f "$RESULTS_FILE" ]]; then
        rm -f "$RESULTS_FILE"
    fi
    if [[ -n "${RESULTS_LOCK_DIR:-}" && -d "$RESULTS_LOCK_DIR" ]]; then
        rmdir "$RESULTS_LOCK_DIR" 2>/dev/null || true
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
                # Pass help to command-specific handlers if a command with its own help is set
                if [[ "$COMMAND" == "dep-update" || "$COMMAND" == "ai-sync" ]]; then
                    ARGS+=("$1")
                    shift
                    continue
                fi
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --json)
                JSON_OUTPUT="true"
                OUTPUT_FORMAT="json"
                # Also pass to subcommands that handle --json internally
                if [[ "$COMMAND" == "agent-sweep" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                fi
                shift
                ;;
            --format)
                if [[ $# -lt 2 ]]; then
                    log_error "--format requires an argument: text|json|toon"
                    exit 4
                fi
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --stats)
                SHOW_STATS="true"
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
                if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" || "$COMMAND" == "ai-sync" || "$COMMAND" == "dep-update" ]]; then
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
                if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    RESUME="true"
                fi
                shift
                ;;
            --restart)
                if [[ "$COMMAND" == "agent-sweep" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    RESTART="true"
                fi
                shift
                ;;
            --timeout)
                if [[ $# -lt 2 ]]; then
                    log_error "--timeout requires a value in seconds"
                    exit 4
                fi
                if [[ "$COMMAND" == "agent-sweep" || "$COMMAND" == "ai-sync" || "$COMMAND" == "dep-update" ]]; then
                    ARGS+=("--timeout=$2")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("--timeout=$2")
                else
                    GIT_TIMEOUT="$2"
                fi
                shift 2
                ;;
            --timeout=*)
                if [[ "$COMMAND" == "agent-sweep" || "$COMMAND" == "ai-sync" || "$COMMAND" == "dep-update" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    GIT_TIMEOUT="${1#--timeout=}"
                fi
                shift
                ;;
            --repo=*|--manager=*|--include=*|--exclude=*|--test-cmd=*|--max-fix-attempts=*|--agent=*)
                if [[ "$COMMAND" == "ai-sync" || "$COMMAND" == "dep-update" ]]; then
                    ARGS+=("$1")
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                shift
                ;;
            --major|--no-push|--no-untracked)
                if [[ "$COMMAND" == "ai-sync" || "$COMMAND" == "dep-update" ]]; then
                    ARGS+=("$1")
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                shift
                ;;
            --parallel)
                if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" ]]; then
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
                if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" ]]; then
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
            sync|status|init|add|remove|list|doctor|self-update|config|prune|import|review|agent-sweep|ai-sync|dep-update)
                COMMAND="$1"
                shift
                ;;
            --paths|--print|--set=*|--check|--archive|--delete|--private|--public|--from-cwd|--review)
                # Subcommand-specific options - pass through to ARGS
                ARGS+=("$1")
                shift
                ;;
            --plan|--apply|--push|--analytics|--basic|--status|--mode=*|--repos=*|--skip-days=*|--priority=*|--max-repos=*|--max-runtime=*|--max-questions=*|--invalidate-cache=*|--auto-answer=*)
                if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" ]]; then
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
            --max-file-mb=*)
                if [[ "$COMMAND" == "agent-sweep" ]]; then
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
            --phase1-timeout=*|--phase2-timeout=*|--phase3-timeout=*|--with-release|--keep-sessions|--keep-sessions-on-fail|--attach-on-fail|--execution-mode=*|--secret-scan=*)
                # agent-sweep specific options
                if [[ "$COMMAND" == "agent-sweep" ]]; then
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
    if [[ "$COMMAND" == "review" || "$COMMAND" == "agent-sweep" ]]; then
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
                    --restart) RESTART="true" ;;
                    --json)    ;; # Already set JSON_OUTPUT at first pass
                    --timeout=*) GIT_TIMEOUT="${opt#--timeout=}" ;;
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

# Load aggregate_results into global counters without eval.
# Sets: CLONED UPDATED CURRENT SKIPPED FAILED CONFLICTS SYSTEM_ERRORS
load_aggregate_results_globals() {
    CLONED=0 UPDATED=0 CURRENT=0 SKIPPED=0 FAILED=0 CONFLICTS=0 SYSTEM_ERRORS=0

    local kv key val
    for kv in $(aggregate_results); do
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ "$val" =~ ^[0-9]+$ ]] || val=0

        case "$key" in
            CLONED|UPDATED|CURRENT|SKIPPED|FAILED|CONFLICTS|SYSTEM_ERRORS)
                printf -v "$key" '%s' "$val"
                ;;
        esac
    done
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
                printf '%b\n' "     ${GREEN}a)${RESET} Use ru with --autostash (${GREEN}recommended${RESET}):" >&2
                printf '%b\n' "        ${CYAN}ru sync --autostash${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}b)${RESET} Stash and pull manually:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git stash && git pull && git stash pop${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${GREEN}c)${RESET} Commit your changes:" >&2
                printf '%b\n' "        ${CYAN}cd \"$path\" && git add . && git commit -m \"WIP\"${RESET}" >&2
                echo "" >&2
                printf '%b\n' "     ${RED}d)${RESET} Discard local changes (${RED}DESTRUCTIVE${RESET}):" >&2
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
        load_aggregate_results_globals
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
        log_info "  echo 'owner/repo' >> $RU_CONFIG_DIR/repos.d/public.txt  # Edit file directly"
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
    # Parallel mode uses portable directory locks (no external deps).

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
            if [[ "$status" == "no_upstream" ]]; then
                log_warn "No upstream: $repo_label"
                ((conflicts++))
                write_result "$repo_label" "pull" "no_upstream" "0" "" "$local_path"
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
    load_aggregate_results_globals

    # Print summary using the new reporting functions
    print_summary "$CLONED" "$UPDATED" "$CURRENT" "$SKIPPED" "$CONFLICTS" "$FAILED" "$duration"

    # Print conflict resolution help if there are issues
    print_conflict_help

    # Output JSON report if --json flag is set
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local json_report
        json_report="$(generate_json_report "$CLONED" "$UPDATED" "$CURRENT" "$SKIPPED" "$CONFLICTS" "$FAILED" "$duration")"
        emit_structured "$json_report"
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

    # Load all repos from config (reads from all *.txt files in repos.d/)
    local repos=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && repos+=("$line")
    done < <(get_all_repos)

    local total=${#repos[@]}

    # Check for configured repos
    if [[ "$total" -eq 0 ]]; then
        log_info "No repositories configured."
        log_info "Add repos with: ru add owner/repo"
        exit 0
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local status_json
        status_json="$(
            echo "["
            local first="true"
            for repo_spec in "${repos[@]}"; do
                local url branch custom_name local_path repo_id
                if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                    continue
                fi
                local status="missing" ahead=0 behind=0 dirty="false" mismatch="false" branch_name=""
                if [[ -d "$local_path" ]] && is_git_repo "$local_path"; then
                    local status_info
                    status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
                    status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
                    ahead=$(echo "$status_info" | sed 's/.*AHEAD=\([^ ]*\).*/\1/')
                    behind=$(echo "$status_info" | sed 's/.*BEHIND=\([^ ]*\).*/\1/')
                    dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')
                    branch_name=$(echo "$status_info" | sed 's/.*BRANCH=\([^ ]*\).*/\1/')
                    # Check for remote URL mismatch
                    if check_remote_mismatch "$local_path" "$url"; then
                        mismatch="true"
                    fi
                elif [[ -d "$local_path" ]]; then
                    status="not_git"
                fi
                [[ "$first" == "true" ]] || echo ","
                first="false"
                # Escape path for JSON safety (may contain special characters)
                local safe_path safe_branch
                safe_path=$(json_escape "$local_path")
                safe_branch=$(json_escape "$branch_name")
                printf '{"repo":"%s","path":"%s","status":"%s","branch":"%s","ahead":%d,"behind":%d,"dirty":%s,"mismatch":%s}' \
                    "$repo_id" "$safe_path" "$status" "$safe_branch" "$ahead" "$behind" "$dirty" "$mismatch"
            done
            echo "]"
        )"

        emit_structured "$status_json"
    else
        # Human-readable output
        log_info "Repository Status ($total repos)"
        [[ "$FETCH_REMOTES" == "true" ]] && log_info "Fetching remotes for accurate status..."
        echo "" >&2

        # First pass: compute max repo_id length for proper column width
        local max_repo_len=10
        for repo_spec in "${repos[@]}"; do
            local url branch custom_name local_path repo_id
            if resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                [[ ${#repo_id} -gt $max_repo_len ]] && max_repo_len=${#repo_id}
            fi
        done

        # Print header with dynamic width (no truncation)
        printf "%-${max_repo_len}s  %-12s %-15s %s\n" "Repository" "Status" "Branch" "Ahead/Behind" >&2
        printf "%-${max_repo_len}s  %-12s %-15s %s\n" "$(printf '%*s' "$max_repo_len" '' | tr ' ' '-')" "------------" "---------------" "------------" >&2

        for repo_spec in "${repos[@]}"; do
            local url branch custom_name local_path repo_id
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                continue
            fi
            local status="missing" ahead=0 behind=0 dirty="false" mismatch="false" branch_name="" status_display
            if [[ -d "$local_path" ]] && is_git_repo "$local_path"; then
                local status_info
                status_info=$(get_repo_status "$local_path" "$FETCH_REMOTES")
                status=$(echo "$status_info" | sed 's/.*STATUS=\([^ ]*\).*/\1/')
                ahead=$(echo "$status_info" | sed 's/.*AHEAD=\([^ ]*\).*/\1/')
                behind=$(echo "$status_info" | sed 's/.*BEHIND=\([^ ]*\).*/\1/')
                dirty=$(echo "$status_info" | sed 's/.*DIRTY=\([^ ]*\).*/\1/')
                branch_name=$(echo "$status_info" | sed 's/.*BRANCH=\([^ ]*\).*/\1/')
                # Check for remote URL mismatch
                if check_remote_mismatch "$local_path" "$url"; then
                    mismatch="true"
                fi
            elif [[ -d "$local_path" ]]; then
                status="not_git"
            fi
            # If there's a mismatch, override status display
            if [[ "$mismatch" == "true" ]]; then
                status_display="${RED}mismatch${RESET}"
            else
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
            fi
            [[ "$dirty" == "true" ]] && status_display="${status_display}${YELLOW}*${RESET}"
            printf "%-${max_repo_len}s  %-12b %-15s %d/%d\n" "$repo_id" "$status_display" "$branch_name" "$ahead" "$behind" >&2
        done
        echo "" >&2
        log_info "Legend: * = uncommitted changes, mismatch = remote URL differs from config"
    fi
}

cmd_init() {
    log_step "Initializing ru configuration..."

    local created
    created=$(ensure_config_exists)

    if [[ "$created" == "true" ]]; then
        log_success "Created configuration directory: $RU_CONFIG_DIR"
        log_success "Created repos file: $RU_CONFIG_DIR/repos.d/public.txt"
        log_success "Created config file: $RU_CONFIG_DIR/config"

        # Handle --example flag: copy example repos to public.txt
        if [[ "$INIT_EXAMPLE" == "true" ]]; then
            local example_file="$SCRIPT_DIR/examples/public.txt"
            local public_file="$RU_CONFIG_DIR/repos.d/public.txt"
            if [[ -f "$example_file" ]]; then
                # Overwrite the template public.txt with example content
                cp "$example_file" "$public_file"
                log_success "Added example repos from $example_file"
            else
                log_warn "Example file not found: $example_file"
            fi
        fi

        echo "" >&2
        log_info "Next steps:"
        log_info "  1. Add repos:  ru add owner/repo"
        log_info "  2. Sync:       ru sync"
        log_info "  3. Or edit:    $RU_CONFIG_DIR/repos.d/public.txt"
    else
        log_info "Configuration already exists at: $RU_CONFIG_DIR"
        log_info "  Config:  $RU_CONFIG_DIR/config"
        log_info "  Repos:   $RU_CONFIG_DIR/repos.d/public.txt"
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
        repos_file="$RU_CONFIG_DIR/repos.d/public.txt"
    fi

    for repo in "${repo_args[@]}"; do
        # Parse the repo spec to extract URL (ignoring branch/custom name for dupe check)
        # shellcheck disable=SC2034  # spec_branch/spec_name set by parse_repo_spec, intentionally unused
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
            # shellcheck disable=SC2034  # existing_branch/existing_name set by parse_repo_spec, intentionally unused
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
            other_file="$RU_CONFIG_DIR/repos.d/public.txt"
            other_label="public"
        else
            other_file="$RU_CONFIG_DIR/repos.d/private.txt"
            other_label="private"
        fi

        if [[ -f "$other_file" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                # shellcheck disable=SC2034  # existing_branch, existing_name set by parse_repo_spec but only URL used
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

    local public_file="$repos_dir/public.txt"
    local private_file="$repos_dir/private.txt"

    # Initialize files if needed
    [[ ! -f "$public_file" ]] && touch "$public_file"
    [[ ! -f "$private_file" ]] && touch "$private_file"

    # Load existing repos into associative array for fast deduplication
    local -A existing_repos
    for f in "$public_file" "$private_file"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            # shellcheck disable=SC2034 # Variables set by parse_repo_spec
            local ex_url ex_branch ex_name ex_host ex_owner ex_repo
            parse_repo_spec "$line" ex_url ex_branch ex_name
            if parse_repo_url "$ex_url" ex_host ex_owner ex_repo; then
                # Store canonical ID: host/owner/repo
                existing_repos["${ex_host}/${ex_owner}/${ex_repo}"]=1
            fi
        done < "$f"
    done

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
            ((skipped_error++))
            error_repos+=("$input_file|file not found")
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

            # Parse the repo spec to get base URL and metadata
            # shellcheck disable=SC2034 # Variables set by parse_repo_spec
            local spec_url spec_branch spec_name
            parse_repo_spec "$line" spec_url spec_branch spec_name

            # Parse the URL
            local host="" owner="" repo=""
            if ! parse_repo_url "$spec_url" host owner repo 2>/dev/null; then
                ((skipped_invalid++))
                invalid_repos+=("$line")
                continue
            fi

            # Normalize to canonical form (preserve branch/custom name)
            local normalized output_spec
            normalized=$(normalize_url "$spec_url")
            output_spec="$normalized"
            [[ -n "$spec_branch" ]] && output_spec+="@$spec_branch"
            [[ -n "$spec_name" ]] && output_spec+=" as $spec_name"

            # Check for duplicates using canonical ID
            local canonical_id="${host}/${owner}/${repo}"
            if [[ -n "${existing_repos[$canonical_id]:-}" ]]; then
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
                    printf '%s\n' "$output_spec" >> "$private_file"
                fi
                ((imported_private++))
            else
                if [[ "$DRY_RUN" != "true" ]]; then
                    printf '%s\n' "$output_spec" >> "$public_file"
                fi
                ((imported_public++))
            fi

            # Prevent duplicates within the same import run
            existing_repos["$canonical_id"]=1

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
        # Normalize the repo URL for matching (accept @branch / "as name")
        # shellcheck disable=SC2034  # spec_branch/spec_name set by parse_repo_spec, intentionally unused
        local spec_url spec_branch spec_name
        parse_repo_spec "$repo" spec_url spec_branch spec_name

        local host owner repo_name
        if ! parse_repo_url "$spec_url" host owner repo_name; then
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
                # shellcheck disable=SC2034  # line_branch and line_custom_name are set by parse_repo_spec but unused here
                local line_url line_branch line_custom_name
                parse_repo_spec "$line" line_url line_branch line_custom_name

                # shellcheck disable=SC2034  # line_host is set by parse_repo_url but unused here
                local line_host line_owner line_repo
                local should_remove="false"
                if parse_repo_url "$line_url" line_host line_owner line_repo; then
                    # Match if host, owner, and repo name are exactly the same
                    if [[ "$line_host" == "$host" && "$line_owner" == "$owner" && "$line_repo" == "$repo_name" ]]; then
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
        # Only repos from public.txt
        local public_file="$RU_CONFIG_DIR/repos.d/public.txt"
        if [[ -f "$public_file" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && repos+=("$line")
            done < <(load_repo_list "$public_file")
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

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local list_json
        list_json="$(
            echo "["
            local first="true"
            for repo_spec in "${repos[@]}"; do
                local url branch custom_name local_path repo_id
                if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" url branch custom_name local_path repo_id; then
                    continue
                fi

                [[ "$first" == "true" ]] || echo ","
                first="false"

                local safe_url safe_path
                safe_url=$(json_escape "$url")
                safe_path=$(json_escape "$local_path")
                printf '{"repo":"%s","url":"%s","path":"%s"}' "$repo_id" "$safe_url" "$safe_path"
            done
            echo "]"
        )"

        emit_structured "$list_json"
        return 0
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

    # Check ntm (optional, for ai-sync and dep-update)
    if command -v ntm &>/dev/null; then
        local ntm_version
        ntm_version=$(ntm --version 2>/dev/null | head -1 || echo "unknown")
        printf '%b\n' "${GREEN}[OK]${RESET} ntm: $ntm_version" >&2
    else
        printf '%b\n' "${DIM}[  ]${RESET} ntm: not installed (optional, for ai-sync/dep-update)" >&2
    fi

    # Check claude-code (optional, for ai-sync and dep-update)
    if command -v claude &>/dev/null; then
        local claude_ver
        claude_ver=$(claude --version 2>/dev/null | head -1 || echo "unknown")
        printf '%b\n' "${GREEN}[OK]${RESET} claude-code: $claude_ver" >&2
    else
        printf '%b\n' "${DIM}[  ]${RESET} claude-code: not installed (optional, for ai-sync/dep-update)" >&2
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

        local tmux_available="false"
        local ntm_available="false"

        if command -v tmux &>/dev/null; then
            local tmux_version
            tmux_version=$(tmux -V 2>/dev/null | head -1 || echo "unknown")
            printf '%b\n' "${GREEN}[OK]${RESET} tmux: $tmux_version" >&2
            tmux_available="true"
        else
            printf '%b\n' "${YELLOW}[??]${RESET} tmux: not installed (required for local driver)" >&2
        fi

        if command -v ntm &>/dev/null; then
            if ntm --help 2>&1 | grep -q "robot"; then
                printf '%b\n' "${GREEN}[OK]${RESET} ntm: robot mode available" >&2
                ntm_available="true"
            else
                printf '%b\n' "${YELLOW}[??]${RESET} ntm: installed but robot mode unavailable" >&2
            fi
        else
            printf '%b\n' "${DIM}[  ]${RESET} ntm: not installed (optional)" >&2
        fi

        if [[ "$tmux_available" != "true" && "$ntm_available" != "true" ]]; then
            printf '%b\n' "${RED}[!!]${RESET} review driver: no tmux or ntm available" >&2
            ((review_issues++))
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

    # Detect latest release without GitHub API (avoids rate limits / proxy interference)
    local latest_version=""
    latest_version=$(get_latest_release_from_redirect)
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 1 ]]; then
            log_info "No releases found on GitHub"
            log_info "You may be running a development version"
            exit 0
        fi
        log_error "Failed to determine latest release version"
        exit 3
    fi
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
    # Clean up on exit, but preserve global cleanup behavior.
    # Expand temp_dir now so the EXIT trap doesn't lose the local variable.
    # shellcheck disable=SC2064  # Intentional early expansion of temp_dir
    trap "rm -rf -- \"$temp_dir\"; cleanup" EXIT

    # Download URLs
    local release_base="https://github.com/$RU_REPO_OWNER/$RU_REPO_NAME/releases/download/v$latest_version"
    local script_url checksum_url
    script_url=$(cache_bust_url "$release_base/ru")
    checksum_url=$(cache_bust_url "$release_base/checksums.txt")

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
    log_info "Repos file:  $RU_CONFIG_DIR/repos.d/public.txt (and private.txt)"

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
            # Avoid hanging in non-TTY contexts (pipes/CI). For unattended deletion,
            # require explicit --non-interactive.
            if [[ ! -t 0 ]]; then
                log_error "Cannot prompt for prune deletion confirmation (stdin is not a TTY)"
                log_info "Re-run with --non-interactive to proceed without prompts."
                exit 3
            fi

            log_warn "This will permanently delete ${#orphans[@]} repository(s)!"
            echo "" >&2
            for path in "${orphans[@]}"; do
                echo "  $path" >&2
            done
            echo "" >&2

            local confirm=""
            if [[ "$GUM_AVAILABLE" == "true" && -t 1 ]]; then
                if ! gum confirm "Delete these repositories?"; then
                    log_info "Aborted"
                    return 0
                fi
            else
                printf "%s" "Type 'delete' to confirm: " >&2
                IFS= read -r confirm
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

    # Portable locking is built in; no external `flock` required.

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

    # Portable locking is built in; no external `flock` required.

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
    local info_file lock_file lock_dir
    info_file=$(get_review_lock_info_file)
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"

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
        dir_lock_release "$lock_dir"
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
        dir_lock_release "$lock_dir"
        return 0  # Lock is stale
    fi

    return 1  # Lock is valid
}

# Acquire review lock (prevents concurrent reviews)
# Uses a portable directory lock + JSON info file for metadata
acquire_review_lock() {
    local lock_file info_file
    lock_file=$(get_review_lock_file)
    info_file=$(get_review_lock_info_file)
    ensure_dir "$(dirname "$lock_file")"
    local lock_dir="${lock_file}.d"

    # Check for stale locks first and clean up if needed
    check_stale_lock

    # Try non-blocking lock
    if ! dir_lock_try_acquire "$lock_dir"; then
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
        return 1
    fi

    # Lock acquired - write info file with JSON metadata
    local run_id="${REVIEW_RUN_ID:-$$}"
    local mode="${REVIEW_MODE:-plan}"

    printf '{"run_id":"%s","started_at":"%s","pid":%s,"mode":"%s"}\n' \
        "$run_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$mode" > "$info_file"

    return 0
}

# Release review lock and clean up info file
release_review_lock() {
    local lock_file info_file
    lock_file=$(get_review_lock_file)
    info_file=$(get_review_lock_info_file)
    local lock_dir="${lock_file}.d"

    # Remove info file
    rm -f "$info_file"
    dir_lock_release "$lock_dir"
}

#------------------------------------------------------------------------------
# FILE DENYLIST ENFORCEMENT (Security Guardrails)
#
# Prevents committing sensitive or ephemeral files during agent-sweep,
# regardless of agent output. Default patterns cover common secrets,
# credentials, and build artifacts.
#------------------------------------------------------------------------------

# Default denylist patterns (can be extended via AGENT_SWEEP_DENYLIST_EXTRA)
# Patterns support glob-style matching via bash's fnmatch
declare -a AGENT_SWEEP_DENYLIST_PATTERNS=(
    # Secrets and credentials
    ".env"
    ".env.*"
    "*.pem"
    "*.key"
    "id_rsa"
    "id_rsa.*"
    "*.p12"
    "*.pfx"
    "credentials.json"
    "secrets.json"
    "*.secret"
    "*.secrets"
    ".netrc"
    ".npmrc"            # May contain auth tokens
    ".pypirc"           # May contain auth tokens

    # Build artifacts and dependencies (large/ephemeral)
    "node_modules"
    "node_modules/*"
    "__pycache__"
    "__pycache__/*"
    "*.pyc"
    "*.pyo"
    "dist"
    "dist/*"
    "build"
    "build/*"
    ".next"
    ".next/*"
    "target"            # Rust/Maven
    "target/*"
    "vendor"            # Go/PHP
    "vendor/*"

    # Logs and temporary files
    "*.log"
    "*.tmp"
    "*.temp"
    "*.swp"
    "*.swo"
    "*~"
    ".DS_Store"
    "Thumbs.db"

    # IDE and editor files
    ".idea"
    ".idea/*"
    ".vscode"
    ".vscode/*"
    "*.iml"
)

# Check if a file path matches any denylist pattern
# Args: $1=file_path (relative path)
# Returns: 0=denied (file should be blocked), 1=allowed
# Note: Checks basename against exact matches and full path against glob patterns
is_file_denied() {
    local file_path="$1"
    local basename pattern

    # Normalize: remove leading ./ and trailing /
    file_path="${file_path#./}"
    file_path="${file_path%/}"

    # Get the basename for simple comparisons
    basename="${file_path##*/}"

    # Also check for any extra patterns from environment
    local -a all_patterns=("${AGENT_SWEEP_DENYLIST_PATTERNS[@]}")
    if [[ ${#AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]} -gt 0 ]]; then
        all_patterns+=("${AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]}")
    fi
    if [[ -n "${AGENT_SWEEP_DENYLIST_EXTRA:-}" ]]; then
        # Split space-separated extra patterns
        read -ra extra <<<"$AGENT_SWEEP_DENYLIST_EXTRA"
        all_patterns+=("${extra[@]}")
    fi

    for pattern in "${all_patterns[@]}"; do
        # Try matching against full path first (for directory patterns like "node_modules/*")
        # shellcheck disable=SC2254  # Pattern is intentionally a glob
        case "$file_path" in
            $pattern) return 0 ;;  # Denied
        esac

        # Also match against just the basename (for patterns like ".env")
        # shellcheck disable=SC2254
        case "$basename" in
            $pattern) return 0 ;;  # Denied
        esac

        # Special handling for directory matching (pattern without trailing /*)
        # If pattern is "node_modules", match "node_modules/anything"
        case "$pattern" in
            */\*) ;;  # Already has /*, skip
            *)
                # Check if file is inside a denied directory (at any nesting level)
                # This handles both "node_modules/pkg" and "frontend/node_modules/pkg"
                # shellcheck disable=SC2254
                case "$file_path" in
                    $pattern/*) return 0 ;;       # Prefix match: node_modules/...
                    */$pattern/*) return 0 ;;     # Nested match: .../node_modules/...
                esac
                ;;
        esac
    done

    return 1  # Allowed
}

# Filter a list of files through the denylist
# Args: file paths on stdin (one per line)
# Output: allowed file paths to stdout, denied files logged to stderr
# Returns: 0 if all allowed, 1 if any were denied
filter_files_denylist() {
    local file denied_count=0

    while IFS= read -r file || [[ -n "$file" ]]; do
        [[ -z "$file" ]] && continue
        if is_file_denied "$file"; then
            log_warn "Blocked by denylist: $file"
            ((denied_count++))
        else
            printf '%s\n' "$file"
        fi
    done

    [[ $denied_count -eq 0 ]]
}

# Get all denylist patterns as newline-separated list
# Useful for displaying to users or for external tools
get_denylist_patterns() {
    printf '%s\n' "${AGENT_SWEEP_DENYLIST_PATTERNS[@]}"
    if [[ ${#AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]} -gt 0 ]]; then
        printf '%s\n' "${AGENT_SWEEP_DENYLIST_EXTRA_LOCAL[@]}"
    fi
    if [[ -n "${AGENT_SWEEP_DENYLIST_EXTRA:-}" ]]; then
        # shellcheck disable=SC2086  # Intentional word splitting for space-separated patterns
        printf '%s\n' $AGENT_SWEEP_DENYLIST_EXTRA
    fi
}

# Detect which review driver to use
detect_review_driver() {
    # Prefer ntm when robot mode is available and healthy
    if declare -F ntm_check_available >/dev/null 2>&1; then
        if ntm_check_available; then
            echo "ntm"
            return
        fi
    elif command -v ntm &>/dev/null; then
        if ntm --robot-status &>/dev/null; then
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

    # Build claude command with stream-json output (shell-escaped args)
    local -a claude_args=(claude -p "$prompt" --output-format stream-json)
    local claude_cmd=""
    printf -v claude_cmd '%q ' "${claude_args[@]}"
    claude_cmd="${claude_cmd% }"

    # Create tmux session running claude
    if ! tmux new-session -d -s "$session_name" -c "$wt_path" \
        "exec bash -c \"$claude_cmd 2>&1 | tee \\\"$log_file\\\" > \\\"$event_pipe\\\"\""; then
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
#   $2 - event_type output variable name
#   $3 - event_data output variable name
# Returns:
#   0 if valid JSON, 1 if invalid
parse_stream_json_event() {
    local line="$1"
    local event_type_var="$2"
    local event_data_var="$3"

    # Use _pse_ prefix to avoid shadowing caller's output variable names
    local _pse_event_type="" _pse_event_data=""

    # Validate JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
        _pse_event_type="invalid"
        _pse_event_data="$line"
        _set_out_var "$event_type_var" "$_pse_event_type" || return 1
        _set_out_var "$event_data_var" "$_pse_event_data" || return 1
        return 1
    fi

    _pse_event_type=$(echo "$line" | jq -r '.type // "unknown"')

    case "$_pse_event_type" in
        system)
            local _pse_subtype
            _pse_subtype=$(echo "$line" | jq -r '.subtype // ""')
            if [[ "$_pse_subtype" == "init" ]]; then
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

    _set_out_var "$event_type_var" "$_pse_event_type" || return 1
    _set_out_var "$event_data_var" "$_pse_event_data" || return 1
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
    echo "$output" | grep -E '^[[:space:]]*[a-z]\)|^[[:space:]]*[0-9]+\.|^[[:space:]]*-[[:space:]]+[A-Z]' | head -5
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
# SESSION MONITORING & COMPLETION DETECTION (bd-eycs)
# Monitor active Claude Code sessions, detect states with hysteresis,
# handle errors, stalls, and completion
#------------------------------------------------------------------------------

# Session state history for hysteresis (session_id -> comma-separated states)
declare -gA SESSION_STATE_HISTORY=()

# Stall counters per session for recovery escalation
declare -gA SESSION_STALL_COUNTS=()

# Error patterns that indicate session failure
# shellcheck disable=SC2034  # Array used by session_has_error
SESSION_ERROR_PATTERNS=(
    "rate.limit"
    "429"
    "quota.exceeded"
    "panic:"
    "SIGSEGV"
    "killed"
    "unauthorized"
    "invalid.*key"
    "connection refused"
    "timed out"
    "context.*exceeded"
    "token.*limit"
)

# Resolve the best available log file for a session
# Args:
#   $1 - Session ID
# Outputs:
#   Path to session log file (stdout)
# Returns:
#   0 if found, 1 otherwise
get_session_log_path() {
    local session_id="$1"

    # Prefer worktree-local logs (local/ntm drivers)
    local wt_path log_file
    wt_path=$(get_worktree_for_session "$session_id" 2>/dev/null || true)
    if [[ -n "$wt_path" ]]; then
        log_file="$wt_path/.ru/session.log"
        [[ -f "$log_file" ]] && { echo "$log_file"; return 0; }
    fi

    # Legacy fallback (if a pipe log is still used elsewhere)
    log_file="${RU_STATE_DIR:-/tmp}/pipes/${session_id}.pipe.log"
    [[ -f "$log_file" ]] && { echo "$log_file"; return 0; }

    return 1
}

# Calculate output velocity (characters per second) for a session
# Args:
#   $1 - Session ID
#   $2 - Window in seconds (default: 5)
# Outputs:
#   Velocity as integer (chars/sec)
calculate_output_velocity() {
    local session_id="$1"
    local window="${2:-5}"
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)

    if [[ -z "$pipe_log" || ! -f "$pipe_log" ]]; then
        echo "0"
        return 0
    fi

    local now file_size prev_size_file prev_size
    now=$(date +%s)

    # Store previous size for velocity calculation
    prev_size_file="${RU_STATE_DIR:-/tmp}/pipes/${session_id}.prev_size"
    ensure_dir "$(dirname "$prev_size_file")"

    if [[ -f "$prev_size_file" ]]; then
        prev_size=$(cat "$prev_size_file" 2>/dev/null || echo "0")
    else
        prev_size=0
    fi

    file_size=$(stat -c%s "$pipe_log" 2>/dev/null || stat -f%z "$pipe_log" 2>/dev/null || echo "0")

    # Save current size for next call
    echo "$file_size" > "$prev_size_file"

    # Calculate chars added in the window
    local chars_added=$((file_size - prev_size))
    if [[ $chars_added -lt 0 ]]; then
        chars_added=0
    fi

    # Velocity = chars / window (guard against division by zero)
    if [[ $window -le 0 ]]; then
        echo "0"
        return 0
    fi
    local velocity=$((chars_added / window))
    echo "$velocity"
}

# Get last output timestamp for a session
# Args:
#   $1 - Session ID
# Outputs:
#   Unix timestamp of last output
get_last_output_time() {
    local session_id="$1"
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)

    if [[ -z "$pipe_log" || ! -f "$pipe_log" ]]; then
        echo "0"
        return 0
    fi

    # Get file modification time
    local mtime
    mtime=$(stat -c%Y "$pipe_log" 2>/dev/null || stat -f%m "$pipe_log" 2>/dev/null || echo "0")
    echo "$mtime"
}

# Check if session output contains thinking indicators
# Args:
#   $1 - Session ID
# Returns:
#   0 if thinking indicators present, 1 otherwise
has_thinking_indicators() {
    local session_id="$1"
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)

    if [[ -z "$pipe_log" || ! -f "$pipe_log" ]]; then
        return 1
    fi

    # Check last 1000 chars for thinking patterns
    if tail -c 1000 "$pipe_log" 2>/dev/null | grep -qE '(thinking|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|\.{3,}|\.\.\.)'; then
        return 0
    fi

    return 1
}

# Check if session is at an input prompt (Claude waiting for input)
# Args:
#   $1 - Session ID
# Returns:
#   0 if at prompt, 1 otherwise
is_at_prompt() {
    local session_id="$1"

    # Use driver to get session state
    local state_json
    state_json=$(driver_get_session_state "$session_id" 2>/dev/null)

    if [[ -z "$state_json" ]]; then
        return 1
    fi

    # Check if state indicates waiting
    local state
    state=$(echo "$state_json" | jq -r '.state // "unknown"' 2>/dev/null)

    case "$state" in
        waiting|idle|prompt)
            return 0
            ;;
    esac

    # Also check log for prompt patterns
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)
    if [[ -n "$pipe_log" && -f "$pipe_log" ]]; then
        # Look for Claude Code prompt patterns in last 500 chars
        if tail -c 500 "$pipe_log" 2>/dev/null | grep -qE '(^>|claude>|❯|➜|\$\s*$)'; then
            return 0
        fi
    fi

    return 1
}

# Check if session has received a result event (completion)
# Args:
#   $1 - Session ID
# Returns:
#   0 if result event found, 1 otherwise
session_has_result() {
    local session_id="$1"
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)

    if [[ -z "$pipe_log" || ! -f "$pipe_log" ]]; then
        return 1
    fi

    # Check for result event in stream-json output
    if grep -q '"type":"result"' "$pipe_log" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Check if session has error patterns in output
# Args:
#   $1 - Session ID
# Returns:
#   0 if error found, 1 otherwise
# Outputs:
#   Error pattern to stderr if found
session_has_error() {
    local session_id="$1"
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)

    if [[ -z "$pipe_log" || ! -f "$pipe_log" ]]; then
        return 1
    fi

    local pattern
    for pattern in "${SESSION_ERROR_PATTERNS[@]}"; do
        if grep -qiE "$pattern" "$pipe_log" 2>/dev/null; then
            echo "$pattern" >&2
            return 0
        fi
    done

    return 1
}

# Detect raw session state without hysteresis
# Args:
#   $1 - Session ID
# Outputs:
#   State string: generating|waiting|thinking|stalled|error|complete
detect_session_state_raw() {
    local session_id="$1"

    # Check for completion first (highest priority)
    if session_has_result "$session_id"; then
        echo "complete"
        return 0
    fi

    # Check for error patterns (high priority)
    local error_pattern
    if error_pattern=$(session_has_error "$session_id" 2>/dev/null); then
        echo "error"
        return 0
    fi

    # Consult driver state for waiting/complete/error when available
    local state_json driver_state
    state_json=$(driver_get_session_state "$session_id" 2>/dev/null || echo "")
    if [[ -n "$state_json" ]]; then
        if command -v jq &>/dev/null; then
            driver_state=$(echo "$state_json" | jq -r '.state // empty' 2>/dev/null)
        else
            driver_state=$(echo "$state_json" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
        case "$driver_state" in
            error)
                echo "error"
                return 0
                ;;
            complete|dead)
                echo "complete"
                return 0
                ;;
            waiting|idle)
                echo "waiting"
                return 0
                ;;
            stalled)
                echo "stalled"
                return 0
                ;;
        esac

        # If we have no log visibility, fall back to driver hints.
        local log_path=""
        log_path=$(get_session_log_path "$session_id" 2>/dev/null || true)
        if [[ -z "$log_path" && -n "$driver_state" ]]; then
            case "$driver_state" in
                generating|thinking)
                    echo "$driver_state"
                    return 0
                    ;;
            esac
        fi
    fi

    # Calculate output velocity
    local velocity
    velocity=$(calculate_output_velocity "$session_id" 5)

    # Check for waiting state
    if is_at_prompt "$session_id"; then
        if [[ "$velocity" -lt 1 ]]; then
            echo "waiting"
            return 0
        fi
    fi

    # Check for thinking indicators
    if has_thinking_indicators "$session_id"; then
        echo "thinking"
        return 0
    fi

    # Check for stall (no output but not at prompt)
    local last_output_time now
    last_output_time=$(get_last_output_time "$session_id")
    now=$(date +%s)
    if [[ $((now - last_output_time)) -gt 30 ]]; then
        echo "stalled"
        return 0
    fi

    # Active generation
    if [[ "$velocity" -gt 10 ]]; then
        echo "generating"
    else
        echo "thinking"
    fi
}

# Apply hysteresis to prevent state flapping
# Args:
#   $1 - Session ID
#   $2 - New raw state
#   $3 - Current confirmed state (optional, default: generating)
#   $4 - Output variable name (optional, for avoiding subshell)
# Outputs:
#   Confirmed state after hysteresis (via stdout or named variable)
apply_state_hysteresis() {
    local session_id="$1"
    local new_state="$2"
    local current_state="${3:-generating}"
    local out_var="${4:-}"

    # Append to history (comma-separated string)
    local history="${SESSION_STATE_HISTORY[$session_id]:-}"
    history="${history:+$history,}$new_state"

    # Keep last 5 samples using awk
    history=$(echo "$history" | awk -F',' '{for(i=NF-4>1?NF-4:1;i<=NF;i++) printf "%s%s",$i,(i<NF?",":"")}')
    SESSION_STATE_HISTORY["$session_id"]="$history"

    # Determine required consecutive samples for each state
    local required
    case "$new_state" in
        error|complete) required=1 ;;
        generating|thinking) required=2 ;;
        waiting) required=3 ;;
        stalled) required=5 ;;
        *) required=2 ;;
    esac

    # Count consecutive matching samples from end
    local consecutive
    consecutive=$(echo "$history" | awk -F',' -v state="$new_state" '
        { c=0; for(i=NF;i>=1;i--) if($i==state) c++; else break; print c }
    ')

    local result
    if [[ "$consecutive" -ge "$required" ]]; then
        result="$new_state"
    else
        # Return current confirmed state
        result="$current_state"
    fi

    # Output result via named variable or stdout
    if [[ -n "$out_var" ]]; then
        _set_out_var "$out_var" "$result"
    else
        echo "$result"
    fi
}

# Handle a session that is waiting for input
# Args:
#   $1 - Session ID
# Returns:
#   0 on success
handle_waiting_session() {
    local session_id="$1"

    # Get wait reason
    local pipe_log
    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)
    local recent_output=""
    if [[ -n "$pipe_log" && -f "$pipe_log" ]]; then
        recent_output=$(tail -c 2000 "$pipe_log" 2>/dev/null || true)
    fi

    local wait_info
    wait_info=$(detect_wait_reason "$session_id" "" "$recent_output")

    # Log the waiting state
    log_verbose "Session $session_id waiting: $(echo "$wait_info" | jq -r '.reason // "unknown"')"

    # Queue question if it's an ask_user_question
    local reason
    reason=$(echo "$wait_info" | jq -r '.reason // "unknown"')

    if [[ "$reason" == "ask_user_question" ]]; then
        # Extract and queue the question
        local question_data
        question_data=$(echo "$wait_info" | jq -c '.context // {}')
        queue_question "$session_id" "$question_data" 2>/dev/null || true
    fi

    return 0
}

# Handle a stalled session with escalating recovery
# Args:
#   $1 - Session ID
# Returns:
#   0 on success
handle_stalled_session() {
    local session_id="$1"

    local stall_count="${SESSION_STALL_COUNTS[$session_id]:-0}"
    ((stall_count++))
    SESSION_STALL_COUNTS["$session_id"]=$stall_count

    log_warn "Session $session_id stalled (attempt $stall_count)"

    if [[ $stall_count -le 2 ]]; then
        # Soft restart: send Ctrl+C
        driver_interrupt_session "$session_id" 2>/dev/null || true
        sleep 5
    elif [[ $stall_count -le 4 ]]; then
        # Try /compact to reduce context
        driver_send_to_session "$session_id" "/compact" 2>/dev/null || true
        sleep 10
    else
        # Hard restart - stop and restart session
        log_error "Session $session_id persistently stalled, stopping"
        driver_stop_session "$session_id" 2>/dev/null || true
        SESSION_STALL_COUNTS["$session_id"]=0

        # Signal that session needs restart
        return 1
    fi

    return 0
}

# Handle a session that encountered an error
# Args:
#   $1 - Session ID
#   $2 - Error pattern (optional)
# Returns:
#   0 on success
handle_session_error() {
    local session_id="$1"
    local error_pattern="${2:-unknown}"

    log_error "Session $session_id error: $error_pattern"

    # Check for rate limit errors specifically
    if [[ "$error_pattern" =~ (429|rate.limit|quota) ]]; then
        # Notify governor about rate limit
        if declare -p GOVERNOR_STATE &>/dev/null 2>&1; then
            governor_record_error 2>/dev/null || true
        fi
    fi

    # Record session error outcome
    record_session_outcome "$session_id" "error" "$error_pattern" 2>/dev/null || true

    # Stop the errored session
    driver_stop_session "$session_id" 2>/dev/null || true

    return 0
}

# Handle a completed session
# Args:
#   $1 - Session ID
# Returns:
#   0 on success
handle_session_complete() {
    local session_id="$1"

    # Get worktree path for this session
    local wt_path
    wt_path=$(get_worktree_for_session "$session_id" 2>/dev/null || echo "")

    local outcome="unknown"
    local items_count=0

    if [[ -n "$wt_path" ]] && [[ -d "$wt_path" ]]; then
        local plan_file="$wt_path/.ru/review-plan.json"

        if [[ -f "$plan_file" ]]; then
            if validate_review_plan "$plan_file" 2>/dev/null; then
                items_count=$(jq '.items | length' "$plan_file" 2>/dev/null || echo "0")
                log_info "Session $session_id completed: $items_count items reviewed"
                outcome="success"
            else
                log_warn "Session $session_id produced invalid plan"
                outcome="invalid_plan"
            fi
        else
            log_warn "Session $session_id completed without plan artifact"
            outcome="no_plan"
        fi
    else
        log_warn "Session $session_id completed but worktree not found"
        outcome="no_worktree"
    fi

    # Record outcome
    record_session_outcome "$session_id" "$outcome" "$items_count" 2>/dev/null || true

    # Clear stall counter
    unset "SESSION_STALL_COUNTS[$session_id]"
    unset "SESSION_STATE_HISTORY[$session_id]"

    return 0
}

# Record session outcome (stub - integrates with checkpoint system)
# Args:
#   $1 - Session ID
#   $2 - Outcome (success|error|invalid_plan|no_plan|no_worktree)
#   $3 - Details (items count or error pattern)
record_session_outcome() {
    local session_id="$1"
    local outcome="$2"
    local details="${3:-}"

    # Get repo ID from session mapping if available
    local repo_id
    repo_id=$(get_repo_for_session "$session_id" 2>/dev/null || echo "$session_id")

    log_debug "Session $session_id ($repo_id) outcome: $outcome ($details)"

    # If checkpoint system is available, record via that
    if type -t record_repo_outcome &>/dev/null; then
        record_repo_outcome "$repo_id" "$outcome" "0" "${details:-0}" "0" 2>/dev/null || true
    fi

    return 0
}

# Get repo ID for a session (stub - integrates with worktree mapping)
# Args:
#   $1 - Session ID
# Outputs:
#   Repo ID (owner/repo format) or empty if not found
# Returns:
#   0 if found, 1 if not found
get_repo_for_session() {
    local session_id="$1"

    # Use review state to map session -> repo
    local state_file
    state_file=$(get_review_state_file 2>/dev/null || echo "")
    if [[ -n "$state_file" && -f "$state_file" ]] && command -v jq &>/dev/null; then
        local repo_id
        repo_id=$(jq -r --arg sid "$session_id" \
            '.repos | to_entries[] | select(.value.session_id == $sid) | .key' \
            "$state_file" 2>/dev/null | head -1)
        if [[ -n "$repo_id" ]]; then
            echo "$repo_id"
            return 0
        fi
    fi

    # Not found - return empty
    return 1
}

# Get worktree path for a session
# Args:
#   $1 - Session ID
# Outputs:
#   Worktree path
get_worktree_for_session() {
    local session_id="$1"

    local repo_id
    repo_id=$(get_repo_for_session "$session_id" 2>/dev/null || true)
    if [[ -n "$repo_id" ]]; then
        local wt_path=""
        if get_worktree_path "$repo_id" wt_path 2>/dev/null; then
            if [[ -n "$wt_path" ]]; then
                echo "$wt_path"
                return 0
            fi
        fi
    fi

    echo ""
}

# Main session monitoring loop
# Args:
#   $1 - Lock file path (loop exits when removed)
#   $2 - Poll interval in seconds (default: 2)
# Returns:
#   0 when lock removed, 1 on error
monitor_sessions() {
    local lock_file="$1"
    local poll_interval="${2:-2}"

    declare -A sessions=()  # session_id -> confirmed_state
    declare -A repo_sessions=()  # repo_id -> session_id

    log_verbose "Starting session monitor (poll=${poll_interval}s)"

    while [[ -f "$lock_file" ]]; do
        # Get list of active sessions
        local session_list
        session_list=$(driver_list_sessions 2>/dev/null || echo "")

        # Process each active session
        local session_id
        while IFS= read -r session_id; do
            [[ -z "$session_id" ]] && continue

            local repo_id_for_session=""
            repo_id_for_session=$(get_repo_for_session "$session_id" 2>/dev/null || true)
            if [[ -n "$repo_id_for_session" && "$repo_id_for_session" != "$session_id" ]]; then
                repo_sessions["$repo_id_for_session"]="$session_id"
            fi

            # Initialize if new session
            if [[ -z "${sessions[$session_id]:-}" ]]; then
                sessions["$session_id"]="generating"
                log_debug "Monitoring new session: $session_id"
            fi

            # Detect raw state
            local raw_state
            raw_state=$(detect_session_state_raw "$session_id")

            # Apply hysteresis
            local confirmed_state
            confirmed_state=$(apply_state_hysteresis "$session_id" "$raw_state" "${sessions[$session_id]}")

            log_debug "Session $session_id: raw=$raw_state confirmed=$confirmed_state"

            # Handle state transitions
            case "$confirmed_state" in
                waiting)
                    handle_waiting_session "$session_id"
                    ;;
                stalled)
                    handle_stalled_session "$session_id"
                    ;;
                error)
                    handle_session_error "$session_id"
                    [[ -n "$repo_id_for_session" && "$repo_id_for_session" != "$session_id" ]] && unset "repo_sessions[$repo_id_for_session]"
                    unset "sessions[$session_id]"
                    ;;
                complete)
                    handle_session_complete "$session_id"
                    [[ -n "$repo_id_for_session" && "$repo_id_for_session" != "$session_id" ]] && unset "repo_sessions[$repo_id_for_session]"
                    unset "sessions[$session_id]"
                    ;;
            esac

            sessions["$session_id"]="$confirmed_state"
        done <<< "$session_list"

        # Start new sessions if governor allows
        if declare -f governor_update &>/dev/null; then
            governor_update
        fi

        # Rebuild pending repos from state and start sessions
        local -a pending_repos=()
        local -A repo_items=()
        if has_pending_repos 2>/dev/null && get_pending_repos_from_state pending_repos 2>/dev/null; then
            local active_count="${#sessions[@]}"
            if [[ ${#repo_sessions[@]} -gt $active_count ]]; then
                active_count="${#repo_sessions[@]}"
            fi
            while can_start_new_session "$active_count" 2>/dev/null && [[ ${#pending_repos[@]} -gt 0 ]]; do
                if start_next_queued_session repo_sessions pending_repos repo_items 2>/dev/null; then
                    active_count=$((active_count + 1))
                else
                    break
                fi
            done
        fi

        sleep "$poll_interval"
    done

    log_verbose "Session monitor stopped (lock removed)"
    return 0
}

# Check if there are pending repos to process (stub)
# Returns:
#   0 if pending repos exist, 1 otherwise
has_pending_repos() {
    # Check review state for pending repos
    if [[ -n "${RU_STATE_DIR:-}" ]]; then
        local state_file
        state_file=$(get_review_state_file 2>/dev/null || echo "")
        if [[ -f "$state_file" ]]; then
            local pending
            pending=$(jq '[.repos | to_entries[] | select(.value.status == "pending")] | length' "$state_file" 2>/dev/null || echo "0")
            [[ "$pending" -gt 0 ]] && return 0
        fi
    fi
    return 1
}

# Get pending repos from state file into an array
# Args:
#   $1 - Name of array variable to populate
# Returns:
#   0 on success, 1 if no state file or error
get_pending_repos_from_state() {
    local -n _out_arr=$1

    _out_arr=()

    if [[ -z "${RU_STATE_DIR:-}" ]]; then
        return 1
    fi

    local state_file
    state_file=$(get_review_state_file 2>/dev/null || echo "")
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    local repo_list
    repo_list=$(jq -r '.repos | to_entries[] | select(.value.status == "pending") | .key' "$state_file" 2>/dev/null || echo "")

    local repo
    while IFS= read -r repo; do
        [[ -n "$repo" ]] && _out_arr+=("$repo")
    done <<< "$repo_list"

    return 0
}

# Start the next queued session from pending repos
# Args:
#   $1 - Reference to sessions associative array
#   $2 - Reference to pending repos array
#   $3 - Reference to repo_items associative array (repo_id -> newline-separated work items)
# Returns:
#   0 on success, 1 if no session started
start_next_queued_session() {
    if [[ -z "${1:-}" || -z "${2:-}" ]]; then
        log_error "start_next_queued_session: missing arguments"
        return 1
    fi

    local -n _sessions_ref="$1"
    local -n _pending_ref="$2"
    local items_ref_name="${3:-}"
    local -A _empty_items=()
    # If caller doesn't provide a repo_items map, use an empty map.
    if [[ -n "$items_ref_name" ]]; then
        local -n _repo_items_ref="$items_ref_name"
    else
        local -n _repo_items_ref="_empty_items"
    fi

    # Try to start the next viable repo; skip failures without stalling the queue.
    while [[ ${#_pending_ref[@]} -gt 0 ]]; do
        # Get next repo from pending list
        local repo_id="${_pending_ref[0]}"
        _pending_ref=("${_pending_ref[@]:1}")  # Remove first element

        # Get worktree path for this repo
        local wt_path=""
        if ! get_worktree_path "$repo_id" wt_path 2>/dev/null || [[ -z "$wt_path" ]]; then
            log_warn "No worktree found for $repo_id, marking error"
            update_review_state ".repos[\"$repo_id\"].status = \"error\""
            continue
        fi

        # Generate session ID
        local session_id="ru-review-${REVIEW_RUN_ID:-$$}-${repo_id//\//-}"

        # Build review prompt for this repo
        # shellcheck disable=SC2190  # False positive: _repo_items_ref is a nameref to associative array
        local items_blob="${_repo_items_ref[$repo_id]:-}"
        local -a repo_items=()
        if [[ -n "$items_blob" ]]; then
            while IFS= read -r line; do
                # shellcheck disable=SC2190  # False positive: repo_items is indexed array, not associative
                [[ -n "$line" ]] && repo_items+=("$line")
            done <<< "$items_blob"
        fi

        local items_json="[]"
        if [[ ${#repo_items[@]} -gt 0 ]]; then
            items_json=$(build_review_items_json "${repo_items[@]}")
        fi

        local prompt
        prompt=$(generate_review_prompt "$repo_id" "$wt_path" "${REVIEW_RUN_ID:-unknown}" "$items_json")

        # Load and start driver
        if [[ -z "${REVIEW_DRIVER_LOADED:-}" ]]; then
            if ! load_review_driver "${REVIEW_DRIVER:-local}"; then
                log_error "Failed to load review driver for $repo_id"
                update_review_state ".repos[\"$repo_id\"].status = \"error\""
                return 1
            fi
            REVIEW_DRIVER_LOADED=1
        fi

        # Start session via driver
        if ! driver_start_session "$wt_path" "$session_id" "$prompt"; then
            log_error "Failed to start session for $repo_id"
            update_review_state ".repos[\"$repo_id\"].status = \"error\""
            continue
        fi

        # Track session
        _sessions_ref["$repo_id"]="$session_id"
        update_review_state ".repos[\"$repo_id\"].status = \"in_progress\" | .repos[\"$repo_id\"].session_id = \"$session_id\""

        log_info "Started session for $repo_id (${#_sessions_ref[@]} active)"
        return 0
    done

    return 1
}

#------------------------------------------------------------------------------
# Cost Budget Management (bd-l05s)
# Enforce limits on repos, runtime, and questions during review
#------------------------------------------------------------------------------

# Cost budget state (initialized in run_review_orchestration)
declare -g COST_BUDGET_REPOS_PROCESSED=0
declare -g COST_BUDGET_QUESTIONS_ASKED=0
declare -g COST_BUDGET_START_TIME=0

# Check if cost budget allows continuing
# Uses REVIEW_MAX_REPOS, REVIEW_MAX_RUNTIME, REVIEW_MAX_QUESTIONS
# Returns:
#   0 if within budget, 1 if budget exceeded
check_cost_budget() {
    # Check repo limit
    if [[ -n "${REVIEW_MAX_REPOS:-}" && "${REVIEW_MAX_REPOS:-0}" -gt 0 ]]; then
        if [[ $COST_BUDGET_REPOS_PROCESSED -ge $REVIEW_MAX_REPOS ]]; then
            log_warn "Cost budget: max repos ($REVIEW_MAX_REPOS) reached"
            return 1
        fi
    fi

    # Check runtime limit (in minutes)
    if [[ -n "${REVIEW_MAX_RUNTIME:-}" && "${REVIEW_MAX_RUNTIME:-0}" -gt 0 ]]; then
        local now elapsed_minutes
        now=$(date +%s)
        elapsed_minutes=$(( (now - COST_BUDGET_START_TIME) / 60 ))
        if [[ $elapsed_minutes -ge $REVIEW_MAX_RUNTIME ]]; then
            log_warn "Cost budget: max runtime (${REVIEW_MAX_RUNTIME}m) reached"
            return 1
        fi
    fi

    # Check questions limit
    if [[ -n "${REVIEW_MAX_QUESTIONS:-}" && "${REVIEW_MAX_QUESTIONS:-0}" -gt 0 ]]; then
        if [[ $COST_BUDGET_QUESTIONS_ASKED -ge $REVIEW_MAX_QUESTIONS ]]; then
            log_warn "Cost budget: max questions ($REVIEW_MAX_QUESTIONS) reached"
            return 1
        fi
    fi

    return 0
}

# Increment cost budget counters
increment_repos_processed() {
    ((COST_BUDGET_REPOS_PROCESSED++))
}

increment_questions_asked() {
    ((COST_BUDGET_QUESTIONS_ASKED++))
}

#------------------------------------------------------------------------------
# Pre-fetching Strategy (bd-l05s)
# Warm caches for upcoming repos while reviewing current ones
#------------------------------------------------------------------------------

# Pre-fetch data for next N repos to minimize wait times
# Args:
#   $1 - Current index in repos array
#   $2+ - Full repos array
prefetch_next_repos() {
    local current_index="$1"
    shift
    local -a repos=("$@")
    local prefetch_count=2

    local i
    for ((i=1; i<=prefetch_count; i++)); do
        local next_index=$((current_index + i))
        if [[ $next_index -lt ${#repos[@]} ]]; then
            local next_repo="${repos[next_index]}"

            # Background prefetch
            (
                # Pre-fetch GitHub activity data (if function exists)
                if declare -f get_repo_activity_cached &>/dev/null; then
                    get_repo_activity_cached "$next_repo" >/dev/null 2>&1 || true
                fi

                # Warm git fetch
                local local_path=""
                local url branch custom_name repo_id
                if resolve_repo_spec "$next_repo" "${PROJECTS_DIR:-}" "${LAYOUT:-flat}" \
                        url branch custom_name local_path repo_id 2>/dev/null; then
                    if [[ -d "$local_path" ]]; then
                        git -C "$local_path" fetch --quiet 2>/dev/null || true
                    fi
                fi

                log_debug "Pre-fetched data for $next_repo"
            ) &
        fi
    done
}

#------------------------------------------------------------------------------
# Main Review Orchestration Loop (bd-l05s)
# Ties together worktrees, sessions, monitoring, and questions
#------------------------------------------------------------------------------

# Run the main orchestration loop for review sessions
# Args:
#   $1+ - Work items array (repo_id|type|number|...)
# Returns:
#   0 on success
run_review_orchestration() {
    local -a work_items=("$@")

    # Initialize tracking
    declare -A active_sessions=()  # repo_id -> session_id
    declare -A session_states=()   # session_id -> confirmed_state
    declare -A question_counted=()  # session_id -> 1 if question already counted
    local -a pending_repos=()
    local -a completed_repos=()
    local poll_interval=2

    # Extract unique repos from work items and group items per repo
    declare -A seen_repos=()
    declare -A repo_items=()
    local item repo_id
    for item in "${work_items[@]}"; do
        IFS='|' read -r repo_id _ <<< "$item"
        if [[ -n "$repo_id" && -z "${seen_repos[$repo_id]:-}" ]]; then
            seen_repos["$repo_id"]=1
            pending_repos+=("$repo_id")
        fi
        if [[ -n "$repo_id" ]]; then
            if [[ -n "${repo_items[$repo_id]:-}" ]]; then
                repo_items["$repo_id"]+=$'\n'"$item"
            else
                repo_items["$repo_id"]="$item"
            fi
        fi
    done

    # Initialize cost budget
    COST_BUDGET_START_TIME=$(date +%s)
    COST_BUDGET_REPOS_PROCESSED=0
    COST_BUDGET_QUESTIONS_ASKED=0

    # Initialize review state
    init_review_state
    for repo_id in "${pending_repos[@]}"; do
        update_review_state ".repos[\"$repo_id\"] = {\"status\": \"pending\", \"started_at\": null}"
    done

    log_info "Starting orchestration for ${#pending_repos[@]} repos (driver: ${REVIEW_DRIVER:-local}, parallel: ${REVIEW_PARALLEL:-1})"

    # Load driver
    load_review_driver "${REVIEW_DRIVER:-local}" || return 3
    REVIEW_DRIVER_LOADED=1

    # Prepare worktrees for all repos
    log_step "Preparing isolated worktrees..."
    if ! prepare_review_worktrees "${work_items[@]}"; then
        log_error "Failed to prepare worktrees"
        return 1
    fi

    # Main orchestration loop
    local lock_file="${RU_STATE_DIR:-/tmp}/review-${REVIEW_RUN_ID:-$$}.lock"
    touch "$lock_file"

    while [[ ${#pending_repos[@]} -gt 0 || ${#active_sessions[@]} -gt 0 ]]; do
        # Refresh governor state to honor rate limits before starting sessions.
        if declare -f governor_update &>/dev/null; then
            governor_update
        fi

        # Check cost budget before starting new sessions
        if ! check_cost_budget; then
            log_warn "Cost budget exceeded, stopping new sessions"
            pending_repos=()  # Don't start any more
        fi

        # Pre-fetch next repos while we have active sessions
        # Note: Always pass 0 as index since pending_repos shrinks (first element removed)
        # as repos are started, so we always want to prefetch from the front of the queue
        if [[ ${#active_sessions[@]} -gt 0 && ${#pending_repos[@]} -gt 0 ]]; then
            prefetch_next_repos 0 "${pending_repos[@]}"
        fi

        # Start new sessions if capacity allows
        while can_start_new_session "${#active_sessions[@]}" && [[ ${#pending_repos[@]} -gt 0 ]]; do
            if start_next_queued_session active_sessions pending_repos repo_items; then
                increment_repos_processed
            else
                break
            fi
        done

        # Monitor active sessions
        for repo_id in "${!active_sessions[@]}"; do
            local session_id="${active_sessions[$repo_id]}"
            local raw_state confirmed_state prev_state

            raw_state=$(detect_session_state_raw "$session_id" 2>/dev/null || echo "generating")
            prev_state="${session_states[$session_id]:-generating}"
            confirmed_state=$(apply_state_hysteresis "$session_id" "$raw_state" "$prev_state")
            session_states["$session_id"]="$confirmed_state"

            # Clear question counter when leaving waiting state (allows counting new questions)
            if [[ "$prev_state" == "waiting" && "$confirmed_state" != "waiting" ]]; then
                unset "question_counted[$session_id]"
            fi

            log_debug "Session $session_id: state=$confirmed_state"

            case "$confirmed_state" in
                waiting)
                    # Get session output for wait reason detection
                    local pipe_log wait_info reason recent_output=""
                    pipe_log=$(get_session_log_path "$session_id" 2>/dev/null || true)
                    if [[ -n "$pipe_log" && -f "$pipe_log" ]]; then
                        recent_output=$(tail -c 2000 "$pipe_log" 2>/dev/null || true)
                    fi
                    wait_info=$(detect_wait_reason "$session_id" "" "$recent_output")
                    reason=$(echo "$wait_info" | jq -r '.reason // "unknown"' 2>/dev/null)
                    [[ -z "$reason" ]] && reason="unknown"
                    if [[ "$reason" == "ask_user_question" || "$reason" == "agent_question_text" ]]; then
                        # Only count question once (not every poll cycle)
                        if [[ -z "${question_counted[$session_id]:-}" ]]; then
                            increment_questions_asked
                            question_counted["$session_id"]=1
                        fi
                        if ! check_cost_budget; then
                            log_warn "Question budget reached, auto-skipping"
                            driver_send_to_session "$session_id" "Skip this question and continue" 2>/dev/null || true
                        else
                            handle_waiting_session "$session_id"
                        fi
                    else
                        handle_waiting_session "$session_id"
                    fi
                    ;;
                complete)
                    completed_repos+=("$repo_id")
                    unset "active_sessions[$repo_id]"
                    update_review_state ".repos[\"$repo_id\"].status = \"completed\""
                    handle_session_complete "$session_id"
                    log_info "Session completed for $repo_id"
                    ;;
                error)
                    governor_record_error "session_error" "$session_id" 2>/dev/null || true
                    handle_session_error "$session_id"
                    unset "active_sessions[$repo_id]"
                    update_review_state ".repos[\"$repo_id\"].status = \"error\""
                    ;;
                stalled)
                    handle_stalled_session "$session_id"
                    ;;
            esac
        done

        # Process question queue (TUI) if we have pending questions
        if declare -f has_pending_questions &>/dev/null && has_pending_questions 2>/dev/null; then
            if declare -f render_question_tui &>/dev/null; then
                render_question_tui
                if declare -f process_user_answers &>/dev/null; then
                    process_user_answers
                fi
            fi
        fi

        sleep "$poll_interval"
    done

    rm -f "$lock_file"
    log_success "Orchestration complete: ${#completed_repos[@]} repos processed"

    # Update digest caches from completed worktrees
    update_repo_digests_from_worktrees || true

    return 0
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

    # Reject newline-separated commands to prevent chaining via line breaks.
    if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
        # Pre-escape newlines for valid JSON (jq 1.8+ may not escape in output)
        local escaped_cmd="${cmd//$'\n'/\\n}"
        escaped_cmd="${escaped_cmd//$'\r'/\\r}"
        jq -n \
            --arg cmd "$escaped_cmd" \
            --arg status "needs_approval" \
            --arg reason "Command contains newline separators" \
            '{command: $cmd, status: $status, reason: $reason}'
        return 2
    fi

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

    # Security: Check for shell metacharacters that enable command chaining/injection
    # These could bypass base_cmd checks by executing additional commands
    # Characters: ; | & ` $( ) && || (newlines handled above)
    if [[ "$cmd" =~ [\;\|\&\`] ]] || [[ "$cmd" =~ \$\( ]] || [[ "$cmd" =~ \&\& ]] || [[ "$cmd" =~ \|\| ]]; then
        jq -n \
            --arg cmd "$cmd" \
            --arg base "$base_cmd" \
            --arg status "needs_approval" \
            --arg reason "Command contains shell metacharacters (;|&\`\$()) that could enable command chaining" \
            '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
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

# Check if ntm is available and functional with distinct error codes.
# Returns:
#   0 - ntm available and functional
#   1 - ntm not installed
#   2 - ntm installed but robot mode not working
# Usage in cmd_agent_sweep:
#   ntm_check_available
#   ntm_status=$?
#   if [[ $ntm_status -eq 1 ]]; then log_error "Install ntm first"; return 3
#   elif [[ $ntm_status -eq 2 ]]; then log_error "ntm robot mode broken"; return 3
#   fi
ntm_check_available() {
    if ! command -v ntm &>/dev/null; then
        return 1  # Not installed
    fi
    # Verify robot mode works (fast, side-effect-free check)
    if ! ntm --robot-status &>/dev/null; then
        return 2  # Installed but not functional
    fi
    return 0  # Available and functional
}

# Backward-compatible wrapper: returns 0 if available, 1 otherwise
ntm_is_available() {
    ntm_check_available
    [[ $? -eq 0 ]]
}

# Sanitize a string for use as tmux session name
# Replaces non-alphanumeric chars with underscore, collapses multiple underscores
sanitize_session_name() {
    local name="${1:-}"
    # Replace non-alphanumeric with underscore, collapse multiple underscores
    name="${name//[^a-zA-Z0-9]/_}"
    # Remove leading/trailing underscores and collapse multiples
    echo "$name" | sed 's/__*/_/g; s/^_//; s/_$//'
}

# Spawn a Claude Code session for a repository via ntm robot mode.
# Usage: ntm_spawn_session session_name workdir [timeout_seconds]
# Returns: JSON response on stdout
# Exit codes:
#   0 - Session created successfully
#   1 - Error (check error_code in JSON output)
ntm_spawn_session() {
    local session="${1:-}"
    local workdir="${2:-}"
    local timeout="${3:-60}"
    local output

    [[ -z "$session" ]] && { echo '{"success":false,"error":"session name required"}'; return 1; }
    [[ -z "$workdir" ]] && { echo '{"success":false,"error":"workdir required"}'; return 1; }
    [[ ! -d "$workdir" ]] && { echo '{"success":false,"error":"workdir does not exist"}'; return 1; }

    # Spawn with wait-for-ready using robot mode
    if output=$(ntm --robot-spawn="$session" \
        --spawn-cc=1 \
        --spawn-wait \
        --spawn-dir="$workdir" \
        --ready-timeout="${timeout}s" 2>&1); then
        echo "$output"
        return 0
    else
        local exit_code=$?
        # Output may contain JSON error details
        if [[ -n "$output" ]]; then
            echo "$output"
        else
            echo "{\"success\":false,\"error\":\"spawn failed\",\"exit_code\":$exit_code}"
        fi
        return $exit_code
    fi
}

# Send a prompt to a Claude Code session, handling large prompts via chunking.
# Usage: ntm_send_prompt session prompt
# Returns: JSON response on stdout
# Prompts >4KB are automatically chunked to avoid tmux SendKeys limits.
ntm_send_prompt() {
    local session="${1:-}"
    local prompt="${2:-}"
    local output

    [[ -z "$session" ]] && { echo '{"success":false,"error":"session name required"}'; return 1; }
    [[ -z "$prompt" ]] && { echo '{"success":false,"error":"prompt required"}'; return 1; }

    # Check prompt size - tmux has ~4KB practical limit per SendKeys call
    if [[ ${#prompt} -gt 4000 ]]; then
        log_warn "Prompt is ${#prompt} chars (>4KB), sending in chunks"
        ntm_send_prompt_chunked "$session" "$prompt"
        return $?
    fi

    if output=$(ntm --robot-send="$session" \
        --msg="$prompt" \
        --type=claude 2>&1); then
        echo "$output"
        return 0
    else
        local exit_code=$?
        if [[ -n "$output" ]]; then
            echo "$output"
        else
            echo "{\"success\":false,\"error\":\"send failed\",\"exit_code\":$exit_code}"
        fi
        return $exit_code
    fi
}

# Send a large prompt in chunks to avoid tmux SendKeys limits.
# Internal helper for ntm_send_prompt.
ntm_send_prompt_chunked() {
    local session="${1:-}"
    local prompt="${2:-}"
    local chunk_size=3500  # Leave buffer below 4KB limit
    local offset=0
    local length=${#prompt}

    while [[ $offset -lt $length ]]; do
        local chunk="${prompt:$offset:$chunk_size}"
        if ! ntm --robot-send="$session" --msg="$chunk" --type=claude &>/dev/null; then
            echo "{\"success\":false,\"error\":\"chunk send failed at offset $offset\"}"
            return 1
        fi
        ((offset += chunk_size))
        # Small delay between chunks to let terminal process
        sleep 0.1
    done

    echo '{"success":true,"chunked":true}'
    return 0
}

# Wait for Claude Code agent to complete work and return to idle state.
# Usage: ntm_wait_completion session [timeout_seconds]
# Returns: JSON response on stdout
# Exit codes:
#   0 - Condition met (agent idle)
#   1 - Timeout exceeded
#   2 - Error (check error_code in JSON)
#   3 - Agent error detected
ntm_wait_completion() {
    local session="${1:-}"
    local timeout="${2:-300}"
    local output exit_code

    [[ -z "$session" ]] && { echo '{"success":false,"error":"session name required"}'; return 1; }

    # Use --transition to ensure we wait for a full processing cycle:
    # agent must leave WAITING (start processing) and return to WAITING (finish)
    output=$(ntm --robot-wait="$session" \
        --condition=idle \
        --wait-timeout="${timeout}s" \
        --exit-on-error \
        --transition 2>&1)
    exit_code=$?

    if [[ -n "$output" ]]; then
        echo "$output"
    else
        # Generate minimal JSON response if ntm didn't
        if [[ $exit_code -eq 0 ]]; then
            echo '{"success":true,"condition":"idle"}'
        else
            echo "{\"success\":false,\"error\":\"wait failed\",\"exit_code\":$exit_code}"
        fi
    fi
    return $exit_code
}

# Kill an ntm session. Idempotent - safe to call on non-existent sessions.
# Usage: ntm_kill_session session_name
# Returns: always 0 (cleanup should never fail the main workflow)
ntm_kill_session() {
    local session="${1:-}"
    [[ -z "$session" ]] && return 0
    # -f flag prevents confirmation prompt
    ntm kill "$session" -f 2>/dev/null || true
    return 0
}

# Send Ctrl+C interrupt to agent panes in an ntm session.
# Used to stop long-running agent work before sending new prompts.
# Usage: ntm_interrupt_session session_name
# Returns: 0 on success, 1 on failure
ntm_interrupt_session() {
    local session="${1:-}"
    [[ -z "$session" ]] && return 1
    ntm --robot-interrupt="$session" 2>/dev/null || return 1
    return 0
}

# Cleanup all agent-sweep sessions owned by this process.
# Respects AGENT_SWEEP_KEEP_SESSIONS for debugging.
# Usage: cleanup_agent_sweep_sessions
cleanup_agent_sweep_sessions() {
    [[ "${AGENT_SWEEP_KEEP_SESSIONS:-false}" == "true" ]] && return 0

    local sessions session
    # Find sessions matching our naming pattern with our PID
    sessions=$(ntm --robot-status 2>/dev/null | \
        grep -oE '"name":"ru_sweep_[^"]*"' | cut -d'"' -f4) || true

    # Disable glob expansion for safe iteration over session names
    set -f
    for session in $sessions; do
        # Only kill sessions from this PID (pattern: ru_sweep_*_$$)
        if [[ "$session" == *"_$$"* ]] || [[ "$session" == *"_$$_"* ]]; then
            ntm_kill_session "$session"
        fi
    done
    set +f
}

# Release agent-sweep instance lock (if held).
# Uses AGENT_SWEEP_INSTANCE_LOCK_DIR/BASE set by cmd_agent_sweep.
release_agent_sweep_instance_lock() {
    local lock_dir="${AGENT_SWEEP_INSTANCE_LOCK_DIR:-}"
    local lock_base="${AGENT_SWEEP_INSTANCE_LOCK_BASE:-}"

    [[ -z "$lock_dir" ]] && return 0

    if [[ -n "$lock_base" ]] && _is_path_under_base "$lock_dir" "$lock_base"; then
        rm -f "$lock_dir/pid" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
    else
        log_warn "Refusing to release unsafe agent-sweep lock dir: $lock_dir"
    fi
}

# Set up trap handlers for graceful agent-sweep shutdown.
# Call early in cmd_agent_sweep() after initial setup.
setup_agent_sweep_traps() {
    trap 'agent_sweep_handle_interrupt' INT TERM
    trap 'agent_sweep_handle_exit' EXIT
}

# Handle interrupt (Ctrl+C or TERM signal) during agent-sweep.
# Saves state for resume and cleans up sessions.
agent_sweep_handle_interrupt() {
    echo "" >&2  # Newline after ^C
    log_warn "Agent-sweep interrupted! Saving state for resume..."
    save_agent_sweep_state "interrupted"
    cleanup_agent_sweep_sessions
    exit 5  # Exit code 5 = signal/interrupt
}

# Handle normal exit from agent-sweep.
# Cleans up sessions unless --keep-sessions or --keep-sessions-on-fail.
agent_sweep_handle_exit() {
    local exit_code=$?

    # On failure, optionally keep sessions for debugging
    if [[ $exit_code -ne 0 ]] && [[ "${AGENT_SWEEP_KEEP_SESSIONS_ON_FAIL:-false}" == "true" ]]; then
        log_info "Keeping sessions for debugging (--keep-sessions-on-fail)"
        release_agent_sweep_instance_lock
        return
    fi

    # On success, mark state as completed
    if [[ $exit_code -eq 0 ]]; then
        save_agent_sweep_state "completed"
        cleanup_agent_sweep_state  # Clean up state file on success
    fi

    cleanup_agent_sweep_sessions
    release_agent_sweep_instance_lock
}

# Map ntm error codes to ru exit codes.
# Args: $1 = ntm error code string
# Returns: ru exit code (0-5) on stdout
#
# ru exit codes:
#   0 = success
#   1 = partial failure (some repos failed)
#   2 = complete failure (all operations failed)
#   3 = system/environment error
#   4 = bad arguments/usage
#   5 = signal/interrupt
map_ntm_error_to_exit_code() {
    local ntm_error="${1:-}"

    case "$ntm_error" in
        # Retry-able conditions -> partial failure
        TIMEOUT)             echo 1 ;;
        RESOURCE_BUSY)       echo 1 ;;
        RATE_LIMITED)        echo 1 ;;

        # System/environment errors
        SESSION_NOT_FOUND)   echo 3 ;;
        PANE_NOT_FOUND)      echo 3 ;;
        INTERNAL_ERROR)      echo 3 ;;
        PERMISSION_DENIED)   echo 3 ;;
        DEPENDENCY_MISSING)  echo 3 ;;

        # Bad arguments/usage
        INVALID_FLAG)        echo 4 ;;
        INVALID_ARGS)        echo 4 ;;
        NOT_IMPLEMENTED)     echo 4 ;;

        # Default: partial failure (conservative)
        *)                   echo 1 ;;
    esac
}

# Get real-time activity state for an ntm session.
# Usage: ntm_get_activity session_name
# Output: JSON with agent states, velocity, health, rate_limited flag
# Use to poll during wait for progress or detect rate limiting
ntm_get_activity() {
    local session="${1:-}"
    [[ -z "$session" ]] && {
        echo '{"success":false,"error":"session name required"}'
        return 1
    }
    ntm --robot-activity="$session" 2>/dev/null
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
    # shellcheck disable=SC2120  # Called with varying args via dispatch
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
    local state_dir="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}"
    local -a log_dirs=()
    local today
    today=$(date +%Y-%m-%d)
    log_dirs+=("$state_dir/logs/$today")

    local yesterday=""
    if yesterday=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null); then
        :
    elif yesterday=$(date -v -1d +%Y-%m-%d 2>/dev/null); then
        :
    fi
    if [[ -n "$yesterday" && "$yesterday" != "$today" ]]; then
        log_dirs+=("$state_dir/logs/$yesterday")
    fi

    # Look for 429 responses in recent log files (last 5 minutes)
    local recent_429s=0
    local now
    now=$(date +%s)
    local five_min_ago=$((now - 300))
    local backoff_until="${GOVERNOR_STATE[model_backoff_until]:-0}"

    # Clear expired backoff even if no logs are found.
    if [[ "${GOVERNOR_STATE[model_in_backoff]}" == "true" ]]; then
        [[ "$backoff_until" =~ ^[0-9]+$ ]] || backoff_until=0
        if [[ "$now" -ge "$backoff_until" ]]; then
            GOVERNOR_STATE[model_in_backoff]="false"
            log_info "Model rate limit backoff expired, resuming normal operation"
        fi
    fi

    local -a log_files=()
    local log_dir
    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            while IFS= read -r log_file; do
                [[ -n "$log_file" ]] && log_files+=("$log_file")
            done < <(find "$log_dir" -name "*.log" -type f 2>/dev/null)
        fi
    done

    # Also scan review session logs in active worktrees (if available)
    local run_id="${REVIEW_RUN_ID:-}"
    if [[ -n "$run_id" ]]; then
        local worktrees_dir="$state_dir/worktrees/$run_id"
        if [[ -d "$worktrees_dir" ]]; then
            while IFS= read -r log_file; do
                [[ -n "$log_file" ]] && log_files+=("$log_file")
            done < <(find "$worktrees_dir" -path "*/.ru/session.log" -type f 2>/dev/null)
        fi
    fi

    if [[ ${#log_files[@]} -eq 0 ]]; then
        return 0
    fi

    # Find log files modified in last 5 minutes and grep for rate limit patterns
    local log_file
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            local mtime
            mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$five_min_ago" ]]; then
                if grep -qiE 'rate[ .]limit|429|overloaded' "$log_file" 2>/dev/null; then
                    ((recent_429s++))
                fi
            fi
        fi
    done

    if [[ "$recent_429s" -gt 0 ]]; then
        backoff_until=$((now + 60))
        GOVERNOR_STATE[model_in_backoff]="true"
        GOVERNOR_STATE[model_backoff_until]="$backoff_until"
        log_warn "Model rate limit detected ($recent_429s hits), backing off until $(date -d "@$backoff_until" +%H:%M:%S 2>/dev/null || date -r "$backoff_until" +%H:%M:%S 2>/dev/null || echo 'soon')"
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
# Args: current_active_count (number of currently active sessions)
# Returns: 0 if allowed, 1 if not
can_start_new_session() {
    local active_count="${1:-0}"

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
    [[ "$active_count" =~ ^[0-9]+$ ]] || active_count=0
    [[ "$effective" =~ ^[0-9]+$ ]] || effective=1
    if [[ "$active_count" -ge "$effective" ]]; then
        log_verbose "Cannot start session: at capacity ($active_count >= $effective)"
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
    local now
    now=$(date +%s)
    local last_update="${GOVERNOR_STATE[last_update]:-0}"
    [[ "$last_update" =~ ^[0-9]+$ ]] || last_update=0

    # Throttle expensive rate limit checks (default: every 30s).
    if (( now - last_update >= 30 )); then
        update_github_rate_limit
        check_model_rate_limit
        GOVERNOR_STATE[last_update]="$now"
    fi
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
    if ! with_state_lock write_json_atomic "$questions_file" "$payload"; then
        log_warn "Failed to write questions queue"
        return 1
    fi
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
    if ! with_state_lock write_json_atomic "$questions_file" "$updated"; then
        log_warn "Failed to update question in queue"
        return 1
    fi
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

    if ! can_prompt; then
        echo ""
        return 1
    fi

    exit_alt_screen
    printf '%s' "$prompt" >&2
    IFS= read -r input
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
    printf 'Choose [1-%d]: ' "${#options[@]}" >&2
    IFS= read -r choice
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
        with_state_lock write_json_atomic "$questions_file" "$updated" || return 1
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

# Print wrapped text with a fixed indent
print_wrapped_block() {
    local indent="$1"
    local width="$2"
    local text="$3"

    [[ -z "$text" ]] && return 0

    while IFS= read -r line; do
        printf '%s%s\n' "$indent" "$line"
    done < <(wrap_text "$text" "$width")
}

# Show a patch summary for the worktree
show_patch_summary() {
    local wt_path="$1"
    local cols="$2"
    local plan_file="${3:-}"

    local width=$((cols - 6))
    [[ $width -lt 20 ]] && width=20

    printf '\n  %sPATCH SUMMARY%s\n' "${DASH_BOLD}" "${DASH_RESET}"

    if [[ -z "$wt_path" || ! -d "$wt_path/.git" ]]; then
        printf '  %sNo worktree available%s\n' "${DASH_DIM}" "${DASH_RESET}"
        return 0
    fi

    local diffstat shortstat
    diffstat=$(git -C "$wt_path" diff --stat --no-color 2>/dev/null || echo "")
    shortstat=$(git -C "$wt_path" diff --shortstat --no-color 2>/dev/null || echo "")

    if [[ -z "$diffstat" ]]; then
        printf '  %sNo uncommitted changes%s\n' "${DASH_DIM}" "${DASH_RESET}"
    else
        printf '  Changed files:\n'
        while IFS= read -r line; do
            printf '    %s\n' "$(truncate_string "$line" "$width")"
        done <<< "$(echo "$diffstat" | head -n 6)"

        if [[ -n "$shortstat" ]]; then
            printf '  Diff: %s\n' "$shortstat"
        fi
    fi

    if [[ -n "$plan_file" && -f "$plan_file" ]] && command -v jq &>/dev/null; then
        local tests_ran tests_ok gates_ok gates_warn tests_status
        tests_ran=$(jq -r '.git.tests.ran // null' "$plan_file" 2>/dev/null)
        tests_ok=$(jq -r '.git.tests.ok // null' "$plan_file" 2>/dev/null)
        gates_ok=$(jq -r '.git.quality_gates_ok // null' "$plan_file" 2>/dev/null)
        gates_warn=$(jq -r '.git.quality_gates_warning // null' "$plan_file" 2>/dev/null)

        if [[ "$tests_ran" == "true" ]]; then
            tests_status=$([[ "$tests_ok" == "true" ]] && echo "PASS" || echo "FAIL")
        elif [[ "$tests_ran" == "false" ]]; then
            tests_status="NOT RUN"
        else
            tests_status="UNKNOWN"
        fi

        printf '  Tests: %s\n' "$tests_status"
        if [[ "$gates_ok" == "true" ]]; then
            printf '  Quality gates: OK\n'
        elif [[ "$gates_warn" == "true" ]]; then
            printf '  Quality gates: WARNING\n'
        elif [[ "$gates_ok" == "false" ]]; then
            printf '  Quality gates: FAIL\n'
        fi
    fi
}

# View raw session output (tail of session log)
view_session_output() {
    local log_file="$1"

    local cols rows term_size max_lines
    term_size=$(get_terminal_size)
    read -r cols rows <<< "$term_size"
    max_lines=$((rows - 6))
    [[ $max_lines -lt 5 ]] && max_lines=5

    clear_screen
    printf '%sSession Output%s\n\n' "${DASH_BOLD}" "${DASH_RESET}"

    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        printf '%sNo session log available.%s\n' "${DASH_DIM}" "${DASH_RESET}"
    else
        tail -n "$max_lines" "$log_file"
    fi

    printf '\nPress any key to return...\n'
    read_keypress
}

# Drill-down view for a single question
open_drilldown() {
    local question_json="$1"

    local repo_id session_id question_id prompt recommended
    repo_id=$(echo "$question_json" | jq -r '.repo // "unknown"' 2>/dev/null)
    session_id=$(question_get_session_id "$question_json")
    question_id=$(question_get_id "$question_json")
    prompt=$(question_get_prompt "$question_json")
    recommended=$(question_get_recommended "$question_json")

    local wt_path=""
    if [[ -n "$repo_id" ]]; then
        get_worktree_path "$repo_id" wt_path 2>/dev/null || wt_path=""
    fi

    local log_file=""
    local plan_file=""
    if [[ -n "$wt_path" ]]; then
        log_file="$wt_path/.ru/session.log"
        [[ -f "$log_file" ]] || log_file=""
        plan_file="$wt_path/.ru/review-plan.json"
        [[ -f "$plan_file" ]] || plan_file=""
    fi

    while true; do
        local cols rows term_size width
        term_size=$(get_terminal_size)
        read -r cols rows <<< "$term_size"
        width=$((cols - 4))
        [[ $width -lt 20 ]] && width=20

        local number item_type priority title context repo_url
        number=$(echo "$question_json" | jq -r '.number // empty' 2>/dev/null)
        item_type=$(echo "$question_json" | jq -r '.type // "issue"' 2>/dev/null)
        priority=$(echo "$question_json" | jq -r '.priority // "NORMAL"' 2>/dev/null)
        title=$(echo "$question_json" | jq -r '.title // .item_title // .context.title // empty' 2>/dev/null)
        repo_url=$(echo "$question_json" | jq -r '.repo_url // .url // empty' 2>/dev/null)
        context=$(echo "$question_json" | jq -r '
            if .context == null then ""
            elif (.context | type) == "string" then .context
            else (.context | tostring)
            end
        ' 2>/dev/null)

        clear_screen
        printf '%s%s%s\n' "${DASH_BOLD}" " ${repo_id} - Session Detail [ESC]" "${DASH_RESET}"
        draw_hline "$cols"

        printf '  Repository: %s\n' "${repo_url:-$repo_id}"
        printf '  Session ID: %s\n' "${session_id:-unknown}"
        [[ -n "$wt_path" ]] && printf '  Worktree: %s\n' "$wt_path"
        printf '  Priority: %s\n' "$priority"

        if [[ -n "$number" || -n "$title" ]]; then
            printf '\n  %s%s%s\n' "${DASH_BOLD}" "$(truncate_string "${item_type^^} #${number:-?}: ${title:-No title}" "$width")" "${DASH_RESET}"
        fi

        if [[ -n "$prompt" ]]; then
            printf '\n  %sQUESTION%s\n' "${DASH_BOLD}" "${DASH_RESET}"
            print_wrapped_block "  " "$width" "$prompt"
        fi

        if [[ -n "$context" ]]; then
            printf '\n  %sCONTEXT%s\n' "${DASH_BOLD}" "${DASH_RESET}"
            print_wrapped_block "  " "$width" "$context"
        fi

        local -a options=()
        mapfile -t options < <(question_get_options_lines "$question_json")
        if [[ ${#options[@]} -gt 0 ]]; then
            printf '\n  %sOPTIONS%s\n' "${DASH_BOLD}" "${DASH_RESET}"
            [[ -n "${options[0]:-}" ]] && printf '  A: %s\n' "$(truncate_string "${options[0]}" "$width")"
            [[ -n "${options[1]:-}" ]] && printf '  B: %s\n' "$(truncate_string "${options[1]}" "$width")"
            if [[ ${#options[@]} -gt 2 ]]; then
                printf '  C: %s\n' "$(truncate_string "${options[2]}" "$width")"
            else
                printf '  C: Skip\n'
            fi
        elif [[ -n "$recommended" ]]; then
            printf '\n  %sRECOMMENDED%s\n' "${DASH_BOLD}" "${DASH_RESET}"
            print_wrapped_block "  " "$width" "$recommended"
            printf '  C: Skip\n'
        else
            printf '\n  %sACTIONS%s\n' "${DASH_BOLD}" "${DASH_RESET}"
            printf '  C: Skip\n'
        fi

        local c_label="Skip"
        if [[ -n "${options[2]:-}" ]]; then
            c_label="Option 3"
        fi

        show_patch_summary "$wt_path" "$cols" "$plan_file"

        printf '\n  [a] Quick fix  [b] Alt fix  [c] %s  [v] View session  [ESC] Back\n' "$c_label"

        local key
        key=$(read_keypress)
        case "$key" in
            $'\x1b'|q) return 0 ;;
            a|b)
                local answer=""
                if [[ "$key" == "a" ]]; then
                    answer="${options[0]:-}"
                    [[ -z "$answer" ]] && answer="$recommended"
                else
                    answer="${options[1]:-}"
                fi

                if [[ -z "$answer" ]]; then
                    continue
                fi

                [[ -n "$session_id" ]] && driver_send_to_session "$session_id" "$answer" || true
                [[ -n "$question_id" ]] && mark_question_answered "$question_id" "$answer" || true
                return 0
                ;;
            c)
                if [[ -n "${options[2]:-}" ]]; then
                    local answer="${options[2]}"
                    [[ -n "$session_id" ]] && driver_send_to_session "$session_id" "$answer" || true
                    [[ -n "$question_id" ]] && mark_question_answered "$question_id" "$answer" || true
                else
                    [[ -n "$question_id" ]] && mark_question_skipped "$question_id" || true
                fi
                return 0
                ;;
            v)
                view_session_output "$log_file"
                ;;
            *) ;;
        esac
    done
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

# Wrap text to a given width (preserves words when possible)
wrap_text() {
    local text="$1"
    local width="$2"

    [[ -z "$text" ]] && return 0
    [[ -z "$width" || "$width" -le 0 ]] && { echo "$text"; return 0; }

    if command -v fold &>/dev/null; then
        echo "$text" | fold -s -w "$width"
    else
        echo "$text"
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
    local completed_count="$2"
    local issues="$3"
    local prs="$4"
    local commits="$5"

    printf '\n  %s' "${DASH_DIM}"
    draw_hline $((cols - 4))
    printf '%s\n' "${DASH_RESET}"

    printf '  %sSUMMARY%s\n' "${DASH_BOLD}" "${DASH_RESET}"
    printf '  Completed: %s%d%s | Issues: %d | PRs: %d | Commits: %d\n' \
        "${DASH_GREEN}" "$completed_count" "${DASH_RESET}" "$issues" "$prs" "$commits"
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
    local completed_count issues prs commits progress_current progress_total
    completed_count=$(echo "$stats_json" | jq -r '.completed // 0' 2>/dev/null) || completed_count=0
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
    render_summary_panel "$cols" "$completed_count" "$issues" "$prs" "$commits"
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
                    if [[ -n "$filtered_questions" ]]; then
                        local question_json
                        question_json=$(get_question_at_index "$filtered_questions" "$idx")
                        if [[ -n "$question_json" ]]; then
                            open_drilldown "$question_json"
                            DASHBOARD_STATE[refresh_needed]="true"
                        fi
                    fi
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

    if ! can_prompt; then
        echo ""
        return 1
    fi

    if [[ ${#options[@]} -eq 0 ]]; then
        local answer
        printf 'Answer: ' >&2
        IFS= read -r answer
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
    printf 'Choose [1-%d]: ' "${#options[@]}" >&2
    IFS= read -r choice
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

# Parse review-specific arguments
parse_review_args() {
    # Reset review-specific variables
    REVIEW_MODE="plan"           # plan or apply
    REVIEW_DRIVER="auto"         # auto, ntm, or local
    REVIEW_PARALLEL=4            # concurrent sessions
    REVIEW_DRY_RUN="false"       # discovery only
    REVIEW_STATUS="false"        # status only, no discovery/sessions
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
                if ! is_positive_int "$REVIEW_PARALLEL"; then
                    log_error "Invalid -j value: $REVIEW_PARALLEL"
                    exit 4
                fi
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
            --status)
                REVIEW_STATUS="true"
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
            --json|--verbose|--quiet|-q|--non-interactive)
                # Global options already processed by parse_args - ignore here
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
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/skipped-questions-${REVIEW_RUN_ID:-unknown}.jsonl"
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
# Atomic JSON operations with portable locking
#------------------------------------------------------------------------------

STATE_LOCK_DIR=""
STATE_LOCK_INFO_FILE=""

# Get path to review state directory
get_review_state_dir() {
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/review"
}

# Acquire exclusive lock on state files
# Returns: 0 on success, 1 on failure
acquire_state_lock() {
    local state_dir
    state_dir=$(get_review_state_dir)

    if ! ensure_dir "$state_dir"; then
        log_error "Failed to create state directory: $state_dir"
        return 1
    fi
    STATE_LOCK_DIR="$state_dir/state.lock.d"
    STATE_LOCK_INFO_FILE="$state_dir/state.lock.info"

    # If a stale lock exists (crashed process), clean it up.
    if [[ -d "$STATE_LOCK_DIR" && -f "$STATE_LOCK_INFO_FILE" ]]; then
        local lock_pid
        lock_pid=$(jq -r '.pid // empty' "$STATE_LOCK_INFO_FILE" 2>/dev/null)
        if [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
            rm -f "$STATE_LOCK_INFO_FILE" 2>/dev/null || true
            dir_lock_release "$STATE_LOCK_DIR"
        elif ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$STATE_LOCK_INFO_FILE" 2>/dev/null || true
            dir_lock_release "$STATE_LOCK_DIR"
        fi
    fi

    if ! dir_lock_acquire "$STATE_LOCK_DIR" 60; then
        log_error "Failed to acquire state lock"
        return 1
    fi

    printf '{"pid":%s,"started_at":"%s"}\n' \
        "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_LOCK_INFO_FILE"
    return 0
}

# Release state lock
release_state_lock() {
    rm -f "$STATE_LOCK_INFO_FILE" 2>/dev/null || true
    dir_lock_release "$STATE_LOCK_DIR"
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
        if ! with_state_lock write_json_atomic "$state_file" "$initial_state"; then
            log_warn "Failed to initialize review state"
            return 1
        fi
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
        if ! write_json_atomic "$state_file" "$updated"; then
            release_state_lock
            return 1
        fi
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
        completed_json=$(echo "$completed_repos" | tr ' ' '\n' | { grep -v '^$' || true; } | jq -R . | jq -s . 2>/dev/null || echo '[]')
        pending_json=$(echo "$pending_repos" | tr ' ' '\n' | { grep -v '^$' || true; } | jq -R . | jq -s . 2>/dev/null || echo '[]')
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

    if ! with_state_lock write_json_atomic "$checkpoint_file" "$checkpoint"; then
        log_warn "Failed to save review checkpoint"
        return 1
    fi
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

    # Use epoch-based comparison for portability across date implementations
    # (works with GNU coreutils, BSD date, and uutils coreutils)
    local now_epoch cutoff_epoch last_review_epoch
    now_epoch=$(date +%s 2>/dev/null)
    if [[ -z "$now_epoch" ]]; then
        return 1
    fi
    cutoff_epoch=$((now_epoch - skip_days * 24 * 60 * 60))

    # Convert last_review ISO timestamp to epoch
    # Try date -d (GNU/uutils) first, then date -j -f (BSD)
    if last_review_epoch=$(date -d "$last_review" +%s 2>/dev/null); then
        : # success
    elif last_review_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_review" +%s 2>/dev/null); then
        : # BSD success
    else
        # Fallback: lexicographic comparison with calculated cutoff timestamp
        local cutoff
        cutoff=$(date -u --date="@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        if [[ -z "$cutoff" ]]; then
            return 1
        fi
        if [[ "$last_review" > "$cutoff" ]]; then
            return 0
        fi
        return 1
    fi

    # Compare epochs
    if [[ "$last_review_epoch" -ge "$cutoff_epoch" ]]; then
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
        if _is_path_under_base "$worktrees_dir" "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}"; then
            find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+$max_age_days" \
                -exec rm -rf {} \; 2>/dev/null || true
        else
            log_warn "Skipping worktree cleanup: unsafe path $worktrees_dir"
        fi
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
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/repo-digests"
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
        log_info "No cached digest for $repo_id - agent will create fresh"
        return 0
    fi

    if ! cp "$digest_cache" "$digest_file" 2>/dev/null; then
        log_warn "Failed to copy digest cache for $repo_id"
        return 1
    fi

    local delta_appended="false"
    if [[ -f "$meta_cache" ]] && command -v jq &>/dev/null; then
        local last_commit current_commit
        last_commit=$(jq -r '.last_commit // empty' "$meta_cache" 2>/dev/null)
        current_commit=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")

        if [[ -n "$last_commit" && -n "$current_commit" && "$last_commit" != "$current_commit" ]]; then
            local changes files commit_count
            changes=$(git -C "$wt_path" log --oneline "${last_commit}..${current_commit}" 2>/dev/null | head -20 || true)
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
                delta_appended="true"
            fi

            commit_count=$(git -C "$wt_path" rev-list --count "${last_commit}..${current_commit}" 2>/dev/null || echo "")
            [[ -n "$commit_count" ]] && log_debug "Digest delta: $commit_count commits since last review"
        fi
    fi

    if [[ "$delta_appended" == "true" ]]; then
        log_info "Loaded cached digest for $repo_id (with delta)"
    else
        log_info "Loaded cached digest for $repo_id (no changes)"
    fi
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
    printf '{\n  "repo": "%s",\n  "last_commit": "%s",\n  "last_review_at": "%s",\n  "digest_version": %s,\n  "digest_size": %s,\n  "run_id": "%s"\n}\n' \
        "$repo_id" \
        "$current_commit" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "1" \
        "$digest_size" \
        "${REVIEW_RUN_ID:-unknown}" > "$meta_file"

    log_info "Updated digest cache for $repo_id"
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
        wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].worktree_path // ""' "$mapping_file")
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

    if ! with_state_lock write_json_atomic "$metrics_file" "$updated"; then
        log_warn "Failed to write metrics file"
        return 1
    fi
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
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/worktrees/${REVIEW_RUN_ID:-unknown}"
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

    if repo_is_dirty "$repo_path"; then
        log_error "Repository has uncommitted changes: $repo_path"
        log_error "Please commit or stash changes before running review"
        return 1
    fi

    return 0
}

# Record worktree mapping to JSON file
# Args: repo_id, worktree_path, branch_name, base_ref
record_worktree_mapping() {
    local repo_id="$1"
    local wt_path="$2"
    local wt_branch="$3"
    local base_ref="${4:-}"

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    ensure_dir "$worktrees_dir"

    local mapping_file="$worktrees_dir/mapping.json"
    local lock_dir="${mapping_file}.lock.d"

    # Add mapping atomically (requires jq)
    if command -v jq &>/dev/null; then
        if ! dir_lock_acquire "$lock_dir" 30; then
            log_error "Failed to acquire worktree mapping lock"
            return 1
        fi

        # Initialize if doesn't exist
        [[ ! -f "$mapping_file" ]] && echo '{}' > "$mapping_file"

        local tmp_file="${mapping_file}.tmp.$$"
        [[ -z "$base_ref" ]] && base_ref="HEAD"

        if jq --arg repo "$repo_id" \
              --arg path "$wt_path" \
              --arg branch "$wt_branch" \
              --arg base "$base_ref" \
              --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '.[$repo] = {"worktree_path": $path, "branch": $branch, "base_ref": $base, "created_at": $created}' \
              "$mapping_file" > "$tmp_file"; then
            if mv "$tmp_file" "$mapping_file"; then
                dir_lock_release "$lock_dir"
            else
                log_error "Failed to write worktree mapping file: $mapping_file"
                rm -f "$tmp_file"
                dir_lock_release "$lock_dir"
                return 1
            fi
        else
            log_error "Failed to update worktree mapping for $repo_id"
            rm -f "$tmp_file"
            dir_lock_release "$lock_dir"
            return 1
        fi
    else
        log_warn "jq not available, worktree mapping not recorded"
    fi
}

# Get worktree path for a repo
# Args: repo_id, path output variable name
# Returns: 0 if found, 1 if not found
get_worktree_path() {
    local repo_id="$1"
    local path_var="$2"

    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    local mapping_file="$worktrees_dir/mapping.json"

    if [[ ! -f "$mapping_file" ]]; then
        _set_out_var "$path_var" "" || return 1
        return 1
    fi

    if command -v jq &>/dev/null; then
        # Use _gwp_ prefix to avoid shadowing caller's output variable name
        local _gwp_path
        _gwp_path=$(jq -r --arg repo "$repo_id" '.[$repo].worktree_path // ""' "$mapping_file")
        _set_out_var "$path_var" "$_gwp_path" || return 1
        [[ -n "$_gwp_path" ]] && return 0
    fi

    return 1
}

# Get worktree mapping from work item info
# Args: work_item (pipe-separated), repo_id output variable name, worktree_path output variable name
get_worktree_mapping() {
    local work_item="$1"
    local repo_id_var="$2"
    local wt_path_var="$3"

    # Extract repo_id from work item (first field before |)
    # Use _gwm_ prefix to avoid shadowing caller's output variable names.
    local _gwm_repo_id="${work_item%%|*}"
    _set_out_var "$repo_id_var" "$_gwm_repo_id" || return 1

    get_worktree_path "$_gwm_repo_id" "$wt_path_var"
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
        local repo_spec
        repo_spec="${item%%|*}"

        # Preserve branch pins/custom names from config when possible.
        local config_spec=""
        if declare -F find_repo_spec_for_repo_id >/dev/null; then
            if config_spec=$(find_repo_spec_for_repo_id "$repo_spec" 2>/dev/null); then
                repo_spec="$config_spec"
            fi
        fi

        # Resolve repo spec to get local path
        # shellcheck disable=SC2034  # resolved_repo_id used by resolve_repo_spec
        local url branch custom_name local_path resolved_repo_id
        if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
                url branch custom_name local_path resolved_repo_id 2>/dev/null; then
            log_warn "Could not resolve repo: $repo_spec"
            ((failed++))
            continue
        fi

        local repo_id="$resolved_repo_id"
        [[ -z "$repo_id" ]] && repo_id="$repo_spec"

        # Skip if already processed (dedupe by resolved repo id)
        [[ -n "${seen_repos[$repo_id]:-}" ]] && continue
        seen_repos["$repo_id"]=1

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
        log_debug "Creating worktree for $repo_id at $wt_path"

        # Fetch latest from remote (quiet, ignore failures)
        git -C "$local_path" fetch --quiet 2>/dev/null || true

        # Determine base reference (respect branch pins)
        local base_ref="${branch:-HEAD}"
        local base_ref_create="$base_ref"
        local is_pinned="false"
        [[ -n "$branch" ]] && is_pinned="true"

        if [[ "$is_pinned" == "true" ]]; then
            # Ensure a local branch exists for apply/merge later (push requires a local branch).
            if ! git -C "$local_path" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
                if git -C "$local_path" rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
                    if ! git -C "$local_path" branch --track "$base_ref" "origin/$base_ref" >/dev/null 2>&1; then
                        log_error "Failed to create local tracking branch $base_ref for $repo_id"
                        ((failed++))
                        continue
                    fi
                fi
            fi

            # Prefer the local branch if available; otherwise fall back to remote ref.
            if git -C "$local_path" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
                base_ref_create="$base_ref"
            elif git -C "$local_path" rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
                base_ref_create="origin/$base_ref"
            fi
        fi

        log_debug "Using base ref: $base_ref (pinned: $is_pinned)"

        # Check if worktree already exists
        if [[ -d "$wt_path" ]]; then
            log_warn "Worktree already exists, reusing: $wt_path"
        else
            # Create worktree with new branch
            if ! git -C "$local_path" worktree add -b "$wt_branch" "$wt_path" "$base_ref_create" >/dev/null 2>&1; then
                # Branch may already exist from previous run, try without -b
                if ! git -C "$local_path" worktree add "$wt_path" "$base_ref_create" >/dev/null 2>&1; then
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
        if ! record_worktree_mapping "$repo_id" "$wt_path" "$wt_branch" "$base_ref"; then
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

    # Guard against traversal/malformed run ids (this affects filesystem deletion paths).
    if ! _is_safe_path_segment "$run_id"; then
        log_error "Unsafe review run ID: $run_id"
        return 1
    fi

    local worktrees_root="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/worktrees"
    local base="${worktrees_root}/$run_id"

    [[ ! -d "$base" ]] && return 0

    local mapping_file="$base/mapping.json"
    local removed=0

    if [[ -f "$mapping_file" ]] && command -v jq &>/dev/null; then
        # Remove each worktree properly
        while IFS= read -r repo_id; do
            [[ -z "$repo_id" ]] && continue

            local wt_path wt_branch
            wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].worktree_path // ""' "$mapping_file")
            wt_branch=$(jq -r --arg repo "$repo_id" '.[$repo].branch // ""' "$mapping_file")

            if [[ -d "$wt_path" ]]; then
                # Safety: never delete paths outside the run directory, even if mapping.json is corrupt.
                if ! _is_path_under_base "$wt_path" "$base"; then
                    log_error "Refusing to remove worktree outside run dir: $wt_path"
                    continue
                fi

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
    if _is_path_under_base "$base" "$worktrees_root"; then
        rm -rf "$base"
    else
        log_error "Refusing to remove unsafe worktrees base: $base"
        return 1
    fi

    log_info "Cleanup: $removed worktrees removed"
    return 0
}

# List all worktrees for a run
# Args: run_id (optional)
# Output: JSON array of worktree info
list_review_worktrees() {
    local run_id="${1:-${REVIEW_RUN_ID:-}}"
    local base="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/worktrees/$run_id"
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
    local state_file
    state_file=$(get_review_state_file 2>/dev/null || echo "")
    local skip_days="${REVIEW_SKIP_DAYS:-7}"

    [[ -z "$state_file" || ! -f "$state_file" ]] && return 1

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
                local parsed_items
                parsed_items=$(parse_graphql_work_items "$response")
                [[ -n "$parsed_items" ]] && all_work_items+="${parsed_items}"$'\n'
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
            local parsed_items
            parsed_items=$(parse_graphql_work_items "$response")
            [[ -n "$parsed_items" ]] && all_work_items+="${parsed_items}"$'\n'
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
        printf '%s\n' "[$level]"
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
        CRITICAL) printf '%b\n' "${BOLD}${RED}[CRITICAL]${RESET}" ;;
        HIGH)     printf '%b\n' "${ORANGE}[HIGH]${RESET}" ;;
        NORMAL)   printf '%b\n' "${YELLOW}[NORMAL]${RESET}" ;;
        LOW)      printf '%b\n' "${GRAY}[LOW]${RESET}" ;;
        *)        printf '%s\n' "[$level]" ;;
    esac
}

# Show discovery summary using ANSI formatting
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_ansi() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local items_name="$9"

    _is_valid_var_name "$items_name" || return 1
    local -a _ds_items=()
    eval "_ds_items=(\"\${${items_name}[@]-}\")"

    local BOLD="\033[1m"
    local RED="\033[31m"
    local ORANGE="\033[33m"
    local YELLOW="\033[93m"
    local GRAY="\033[90m"
    local CYAN="\033[36m"
    local RESET="\033[0m"

    printf '\n' >&2
    printf '%b\n' "${BOLD}━━━ Discovery Summary ━━━${RESET}" >&2
    printf '\n' >&2
    printf '%b\n' "Total work items: ${BOLD}$total${RESET}" >&2
    printf '%b\n' "  Issues: ${CYAN}$issues${RESET} | PRs: ${CYAN}$prs${RESET}" >&2
    printf '\n' >&2
    printf '%b\n' "${BOLD}By priority:${RESET}" >&2
    [[ $critical -gt 0 ]] && printf '%b\n' "  ${RED}CRITICAL: $critical${RESET}" >&2
    [[ $high -gt 0 ]] && printf '%b\n' "  ${ORANGE}HIGH: $high${RESET}" >&2
    [[ $normal -gt 0 ]] && printf '%b\n' "  ${YELLOW}NORMAL: $normal${RESET}" >&2
    [[ $low -gt 0 ]] && printf '%b\n' "  ${GRAY}LOW: $low${RESET}" >&2
    printf '\n' >&2

    if [[ ${#_ds_items[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_ds_items[@]} ]] && display_count=${#_ds_items[@]}

        printf '%b\n' "${BOLD}Top $display_count items to review:${RESET}" >&2
        local i=0
        for item in "${_ds_items[@]:0:$display_count}"; do
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

            printf '%b\n' "  $i. $badge ${CYAN}${repo_id}${RESET}#${number}: $short_title" >&2
        done
        printf '\n' >&2
    fi
}

# Show discovery summary using gum (if available)
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_gum() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local items_name="$9"

    _is_valid_var_name "$items_name" || return 1
    local -a _ds_items=()
    eval "_ds_items=(\"\${${items_name}[@]-}\")"

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
    printf '\n' >&2

    if [[ ${#_ds_items[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_ds_items[@]} ]] && display_count=${#_ds_items[@]}

        gum style --bold "Top $display_count items to review:" >&2
        local i=0
        for item in "${_ds_items[@]:0:$display_count}"; do
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

            printf '  %d. ' "$i" >&2
            printf '%s' "$(gum style --foreground "$badge_color" "[$level]")" >&2
            printf ' %s#%s: %s\n' "$repo_id" "$number" "$short_title" >&2
        done
        printf '\n' >&2
    fi
}

# Show discovery summary as JSON (for automation)
# Args: total issues prs critical high normal low max_display items_array_ref
show_discovery_summary_json() {
    local total="$1" issues="$2" prs="$3"
    local critical="$4" high="$5" normal="$6" low="$7"
    local max_display="$8"
    local items_name="$9"

    _is_valid_var_name "$items_name" || return 1
    local -a _ds_items=()
    eval "_ds_items=(\"\${${items_name}[@]-}\")"

    local items_json="[]"

    if [[ ${#_ds_items[@]} -gt 0 ]]; then
        local display_count=$max_display
        [[ $display_count -gt ${#_ds_items[@]} ]] && display_count=${#_ds_items[@]}

        local item_list=""
        for item in "${_ds_items[@]:0:$display_count}"; do
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
# cmd_review_status: Report review lock + checkpoint status (read-only)
#
# Outputs:
#   - Human summary to stderr (default)
#   - JSON to stdout when --json is set
#
# Returns:
#   0 always (best-effort)
#------------------------------------------------------------------------------
cmd_review_status() {
    local lock_file info_file checkpoint_file state_file
    lock_file=$(get_review_lock_file)
    info_file=$(get_review_lock_info_file)
    checkpoint_file=$(get_checkpoint_file)
    state_file=$(get_review_state_file)

    ensure_dir "$(dirname "$lock_file")"

    local lock_supported="true"
    local lock_held="unknown"
    local lock_dir="${lock_file}.d"
    if [[ -d "$lock_dir" ]]; then
        lock_held="true"
    else
        lock_held="false"
    fi

    local lock_held_json="null"
    if [[ "$lock_held" == "true" || "$lock_held" == "false" ]]; then
        lock_held_json="$lock_held"
    fi

    local info_exists="false"
    local info_run_id="" info_started_at="" info_pid="" info_mode=""
    local pid_alive="unknown"

    if [[ -f "$info_file" ]]; then
        info_exists="true"
        if command -v jq &>/dev/null; then
            info_run_id=$(jq -r '.run_id // ""' "$info_file" 2>/dev/null || echo "")
            info_started_at=$(jq -r '.started_at // ""' "$info_file" 2>/dev/null || echo "")
            info_pid=$(jq -r '.pid // ""' "$info_file" 2>/dev/null || echo "")
            info_mode=$(jq -r '.mode // ""' "$info_file" 2>/dev/null || echo "")
        fi
        if [[ "$info_pid" =~ ^[0-9]+$ ]]; then
            if kill -0 "$info_pid" 2>/dev/null; then
                pid_alive="true"
            else
                pid_alive="false"
            fi
        fi
    fi

    local pid_alive_json="null"
    if [[ "$pid_alive" == "true" || "$pid_alive" == "false" ]]; then
        pid_alive_json="$pid_alive"
    fi

    local checkpoint_exists="false"
    local checkpoint_run_id="" checkpoint_mode="" checkpoint_hash=""
    local checkpoint_total="" checkpoint_completed="" checkpoint_pending="" checkpoint_questions=""
    if [[ -f "$checkpoint_file" ]]; then
        checkpoint_exists="true"
        if command -v jq &>/dev/null; then
            checkpoint_run_id=$(jq -r '.run_id // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_mode=$(jq -r '.mode // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_hash=$(jq -r '.config_hash // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_total=$(jq -r '.repos_total // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_completed=$(jq -r '.repos_completed // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_pending=$(jq -r '.repos_pending // ""' "$checkpoint_file" 2>/dev/null || echo "")
            checkpoint_questions=$(jq -r '.questions_pending // ""' "$checkpoint_file" 2>/dev/null || echo "")
        fi
    fi

    local checkpoint_total_json="null"
    local checkpoint_completed_json="null"
    local checkpoint_pending_json="null"
    local checkpoint_questions_json="null"
    [[ "$checkpoint_total" =~ ^[0-9]+$ ]] && checkpoint_total_json="$checkpoint_total"
    [[ "$checkpoint_completed" =~ ^[0-9]+$ ]] && checkpoint_completed_json="$checkpoint_completed"
    [[ "$checkpoint_pending" =~ ^[0-9]+$ ]] && checkpoint_pending_json="$checkpoint_pending"
    [[ "$checkpoint_questions" =~ ^[0-9]+$ ]] && checkpoint_questions_json="$checkpoint_questions"

    local state_exists="false"
    [[ -f "$state_file" ]] && state_exists="true"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        printf '{'
        printf '"command":"review","mode":"status","timestamp":"%s",' "$ts"
        printf '"lock":{"supported":%s,"held":%s,"info_file_exists":%s,' \
            "$lock_supported" "$lock_held_json" "$info_exists"
        printf '"info":{"run_id":"%s","started_at":"%s","pid":"%s","pid_alive":%s,"mode":"%s"}},' \
            "$(json_escape "$info_run_id")" "$(json_escape "$info_started_at")" "$(json_escape "$info_pid")" "$pid_alive_json" "$(json_escape "$info_mode")"
        printf '"checkpoint":{"exists":%s,"run_id":"%s","mode":"%s","config_hash":"%s","repos_total":%s,"repos_completed":%s,"repos_pending":%s,"questions_pending":%s},' \
            "$checkpoint_exists" "$(json_escape "$checkpoint_run_id")" "$(json_escape "$checkpoint_mode")" "$(json_escape "$checkpoint_hash")" \
            "$checkpoint_total_json" "$checkpoint_completed_json" "$checkpoint_pending_json" "$checkpoint_questions_json"
        printf '"state":{"exists":%s}}' "$state_exists"
        printf '\n'
        return 0
    fi

    log_step "Review status"

    case "$lock_held" in
        true) log_info "Review lock: held" ;;
        false) log_info "Review lock: free" ;;
        *) log_info "Review lock: unknown" ;;
    esac

    if [[ "$info_exists" == "true" ]]; then
        if command -v jq &>/dev/null; then
            [[ -n "$info_run_id" ]] && log_info "  Run ID:  $info_run_id"
            [[ -n "$info_started_at" ]] && log_info "  Started: $info_started_at"
            [[ -n "$info_pid" ]] && log_info "  PID:     $info_pid (alive: $pid_alive)"
            [[ -n "$info_mode" ]] && log_info "  Mode:    $info_mode"
        else
            log_info "Lock info (raw):"
            sed 's/^/  /' "$info_file" >&2 || true
        fi
    else
        log_info "Lock info: none"
    fi

    if [[ "$checkpoint_exists" == "true" ]]; then
        if command -v jq &>/dev/null; then
            log_info "Checkpoint: present"
            [[ -n "$checkpoint_run_id" ]] && log_info "  Run ID:           $checkpoint_run_id"
            [[ -n "$checkpoint_mode" ]] && log_info "  Mode:             $checkpoint_mode"
            [[ -n "$checkpoint_hash" ]] && log_info "  Config hash:       $checkpoint_hash"
            [[ "$checkpoint_total_json" != "null" ]] && log_info "  Repos total:       $checkpoint_total_json"
            [[ "$checkpoint_completed_json" != "null" ]] && log_info "  Repos completed:   $checkpoint_completed_json"
            [[ "$checkpoint_pending_json" != "null" ]] && log_info "  Repos pending:     $checkpoint_pending_json"
            [[ "$checkpoint_questions_json" != "null" ]] && log_info "  Questions pending: $checkpoint_questions_json"
        else
            log_info "Checkpoint present (jq not installed)"
        fi
    else
        log_info "Checkpoint: none"
    fi

    if [[ "$state_exists" == "true" ]]; then
        log_info "Review state: present"
    else
        log_info "Review state: none"
    fi

    return 0
}

#------------------------------------------------------------------------------
# cmd_review: Review GitHub issues and PRs using Claude Code
#------------------------------------------------------------------------------
cmd_review() {
    local review_start_epoch
    review_start_epoch=$(date +%s)

    # Parse review-specific arguments
    parse_review_args

    if [[ "$REVIEW_STATUS" == "true" ]]; then
        cmd_review_status
        return $?
    fi

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
            # Use IFS+read to safely split without glob expansion
            local -a tokens
            IFS=' ' read -ra tokens <<< "$REVIEW_INVALIDATE_CACHE"
            local token
            for token in "${tokens[@]}"; do
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

    # Dry-run discovery should not require a session driver (tmux/ntm).
    if [[ "$REVIEW_DRY_RUN" != "true" ]]; then
        # Auto-detect driver if needed
        if [[ "$REVIEW_DRIVER" == "auto" ]]; then
            REVIEW_DRIVER=$(detect_review_driver)
            log_verbose "Auto-detected driver: $REVIEW_DRIVER"
        fi

        if [[ "$REVIEW_DRIVER" == "none" ]]; then
            log_error "No review driver available. Install tmux or ntm."
            exit 3
        fi
    else
        [[ "$REVIEW_DRIVER" == "auto" ]] && REVIEW_DRIVER="none"
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

    # Run main orchestration loop (bd-l05s)
    log_info "Run ID: $run_id"
    log_info "Driver: $REVIEW_DRIVER"
    log_info "Mode: $REVIEW_MODE"
    log_info "Parallel: $REVIEW_PARALLEL"

    local orchestration_code=0
    if ! run_review_orchestration "${work_items[@]}"; then
        orchestration_code=$?
        log_error "Orchestration failed with code $orchestration_code"
    fi

    # Handle non-interactive mode questions summary
    if [[ "$REVIEW_NON_INTERACTIVE" == "true" ]]; then
        summarize_non_interactive_questions
    fi

    # Clear checkpoint on success
    if [[ "$orchestration_code" -eq 0 ]]; then
        clear_review_checkpoint
    fi

    # Build completion JSON if requested
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        build_review_completion_json "$run_id" "$REVIEW_MODE" "$review_start_epoch" "$orchestration_code" "${work_items[@]}"
    fi

    finalize_review_exit "$orchestration_code"
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

    local base="${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/worktrees"
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
        wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].worktree_path // ""' "$mapping_file" 2>/dev/null || echo "")
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
        if repo_is_dirty_excluding_ru "$wt_path"; then
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

    if repo_is_dirty "$main_repo"; then
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

    local push_output
    if ! push_output=$(git -C "$main_repo" push 2>&1); then
        log_error "Push failed for $repo_id: $push_output"
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
    "We don't allow PRs or outside contributions to this project as a matter of policy; here is the policy disclosed to users:" \
    "" \
    "> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other \"stakeholders,\" which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via \`gh\` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity." \
    "" \
    'But I want you to now use the `gh` utility to review all open issues and PRs and to independently read and review each of these carefully; without trusting or relying on any of the user reports being correct, or their suggested/proposed changes or "fixes" being correct, I want you to do your own totally separate and independent verification and validation. You can use the stuff from users as possible inspiration, but everything has to come from your own mind and/or official documentation and the actual code and empirical, independent evidence. Note that MANY of these are likely out of date because I made tons of fixes and changes already; it'\''s important to look at the dates and subsequent commits. Use ultrathink. After you have reviewed things carefully and taken actions in response (including implementing possible fixes or new features), you can respond on my behalf using `gh`.' \
    "" \
    'Just a reminder: we do NOT accept ANY PRs. You can look at them to see if they contain good ideas but even then you must check with me first before integrating even ideas because they could take the project into another direction I don'\''t like or introduce scope creep. Use ultrathink.' \
    "" \
    "WORK ITEMS TO REVIEW:"

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

    # Run tests with timeout (portable: use gtimeout on macOS if available)
    local timeout_cmd="timeout"
    if ! command -v timeout &>/dev/null; then
        if command -v gtimeout &>/dev/null; then
            timeout_cmd="gtimeout"
        else
            timeout_cmd=""
            log_verbose "No timeout command available; running tests without timeout"
        fi
    fi

    if [[ -n "$timeout_cmd" ]]; then
        if output=$(cd "$project_dir" && "$timeout_cmd" "$timeout" bash -c "$test_cmd" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if output=$(cd "$project_dir" && bash -c "$test_cmd" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Summarize output (last 10 lines or key metrics)
    local output_summary
    output_summary=$(printf '%s\n' "$output" | tail -10 | tr '\n' ' ' | cut -c1-200)

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
    output_summary=$(printf '%s\n' "$output" | head -20 | tr '\n' ' ' | cut -c1-300)

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
# run_secret_scan: Scan for secrets in project changes (bd-0ghe)
#
# Uses layered fallback approach:
#   1. gitleaks (if installed) - comprehensive scanner
#   2. detect-secrets (if installed) - alternative scanner
#   3. heuristic regex patterns (fallback) - best effort
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
    local scanner_ran=false

    # Layer 1: Use gitleaks if available
    if command -v gitleaks &>/dev/null; then
        log_verbose "Scanning for secrets with gitleaks"
        scanner_ran=true
        local gl_output
        if ! gl_output=$(gitleaks detect --source "$project_dir" --no-git 2>&1); then
            exit_code=1
            # Include first line of gitleaks output in findings
            local gl_summary
            gl_summary=$(echo "$gl_output" | head -3 | tr '\n' ' ')
            findings+=("gitleaks: ${gl_summary:-detected potential secrets}")
        fi
    # Layer 2: Use detect-secrets if available (requires jq to parse output)
    elif command -v detect-secrets &>/dev/null && command -v jq &>/dev/null; then
        log_verbose "Scanning for secrets with detect-secrets"
        local ds_output ds_count
        if ds_output=$(detect-secrets scan "$project_dir" 2>/dev/null); then
            ds_count=$(echo "$ds_output" | jq '.results | length' 2>/dev/null || echo "")
            if [[ "$ds_count" =~ ^[0-9]+$ ]]; then
                scanner_ran=true
                if [[ "$ds_count" -gt 0 ]]; then
                    exit_code=1
                    findings+=("detect-secrets: found $ds_count potential secrets")
                fi
            fi
        fi
        # If detect-secrets failed or produced invalid output, scanner_ran stays false
        if [[ "$scanner_ran" != "true" ]]; then
            log_verbose "detect-secrets scan failed, falling back to regex patterns"
        fi
    fi

    # Layer 3: Regex fallback - used when no external scanner succeeded
    if [[ "$scanner_ran" != "true" ]]; then
        # Log why detect-secrets was skipped if it's installed but jq is missing
        if command -v detect-secrets &>/dev/null && ! command -v jq &>/dev/null; then
            log_verbose "Skipping detect-secrets (requires jq to parse output)"
        fi
        # Layer 3: Regex fallback with comprehensive patterns
        log_verbose "Scanning for secrets with regex patterns"
        local patterns=(
            # Private keys
            '-----BEGIN.*PRIVATE KEY-----'
            '-----BEGIN RSA PRIVATE KEY-----'
            '-----BEGIN EC PRIVATE KEY-----'
            '-----BEGIN OPENSSH PRIVATE KEY-----'
            # AWS (exact format)
            'AKIA[0-9A-Z]{16}'
            'ASIA[0-9A-Z]{16}'
            'AWS_SECRET_ACCESS_KEY'
            'AWS_ACCESS_KEY'
            # GitHub tokens
            'ghp_[a-zA-Z0-9]{36}'
            'gho_[a-zA-Z0-9]{36}'
            'ghs_[a-zA-Z0-9]{36}'
            # Slack
            'xox[baprs]-[0-9a-zA-Z-]{10,}'
            # OpenAI/Anthropic
            'sk-[a-zA-Z0-9]{48}'
            'sk-ant-[a-zA-Z0-9-]{40,}'
            # Google
            'AIza[0-9A-Za-z_-]{35}'
            # Stripe
            'sk_live_[0-9a-zA-Z]{24}'
            # Generic patterns
            'password[[:space:]]*[:=]'
            'api.?key[[:space:]]*[:=]'
            'secret[[:space:]]*[:=]'
            'token[[:space:]]*[:=]'
        )

        local diff_output
        if [[ "$scope" == "staged" ]]; then
            diff_output=$(git -C "$project_dir" diff --no-color --cached 2>/dev/null || true)
        else
            if git -C "$project_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
                diff_output=$(git -C "$project_dir" diff --no-color HEAD 2>/dev/null || true)
            else
                diff_output=$(git -C "$project_dir" diff --no-color 2>/dev/null || true)
            fi
        fi

        for pattern in "${patterns[@]}"; do
            # Use -e to explicitly pass pattern (handles patterns starting with -)
            # Use case-insensitive matching to catch PASSWORD=, Password=, etc.
            if echo "$diff_output" | grep -qiE -e "$pattern"; then
                exit_code=2  # Warning
                findings+=("Potential secret pattern: $pattern")
            fi
        done
    fi

    local findings_json="[]"
    if [[ ${#findings[@]} -gt 0 ]]; then
        if command -v jq &>/dev/null; then
            findings_json=$(printf '%s\n' "${findings[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
        else
            local first=true item
            findings_json="["
            for item in "${findings[@]}"; do
                $first || findings_json+=","
                findings_json+="\"$(json_escape "$item")\""
                first=false
            done
            findings_json+="]"
        fi
    fi

    # Determine which tool was actually used based on scanner_ran flag
    local tool_used="heuristic"
    if [[ "$scanner_ran" == "true" ]]; then
        # If scanner_ran is true, an external tool succeeded
        if command -v gitleaks &>/dev/null; then
            tool_used="gitleaks"
        else
            tool_used="detect-secrets"
        fi
    fi

    local ok_json="false"
    local warning_json="false"
    [[ $exit_code -eq 0 ]] && ok_json="true"
    [[ $exit_code -eq 2 ]] && warning_json="true"

    if command -v jq &>/dev/null; then
        jq -n \
            --argjson ran true \
            --argjson ok "$ok_json" \
            --argjson warning "$warning_json" \
            --argjson findings "$findings_json" \
            --arg tool "$tool_used" \
            '{
                ran: $ran,
                ok: $ok,
                warning: $warning,
                tool: $tool,
                findings: $findings
            }'
    else
        printf '{"ran":true,"ok":%s,"warning":%s,"tool":"%s","findings":%s}\n' \
            "$ok_json" "$warning_json" "$(json_escape "$tool_used")" "$findings_json"
    fi

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
    local type_var="$2"
    local number_var="$3"

    if [[ "$target" =~ ^(issue|pr)#[0-9]+$ ]]; then
        _set_out_var "$type_var" "${target%%#*}" || return 1
        _set_out_var "$number_var" "${target##*#}" || return 1
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
# SECTION 13.9: AGENT SWEEP PREFLIGHT CHECKS
#==============================================================================

# Repository preflight check for agent-sweep
# Validates that a repository is in a safe state before invoking an agent.
# Sets PREFLIGHT_SKIP_REASON on failure with machine-readable reason.
# Args: $1 = repo_path (absolute path to git repository)
# Returns: 0 if repo passes all checks, 1 if any check fails
# Outputs: PREFLIGHT_SKIP_REASON global variable (used by callers)
# shellcheck disable=SC2034  # PREFLIGHT_SKIP_REASON is read by callers
repo_preflight_check() {
    local repo_path="$1"
    PREFLIGHT_SKIP_REASON=""

    # Check 0: Path exists?
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        PREFLIGHT_SKIP_REASON="repo_path_not_found"
        return 1
    fi

    # Check 1: Is it a git repo?
    if ! git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
        PREFLIGHT_SKIP_REASON="not_a_git_repo"
        return 1
    fi

    # Check 2: Git email configured?
    if [[ -z "$(git -C "$repo_path" config user.email 2>/dev/null)" ]]; then
        PREFLIGHT_SKIP_REASON="git_email_not_configured"
        return 1
    fi

    # Check 3: Git name configured?
    if [[ -z "$(git -C "$repo_path" config user.name 2>/dev/null)" ]]; then
        PREFLIGHT_SKIP_REASON="git_name_not_configured"
        return 1
    fi

    # Check 4: Shallow clone? (some operations may fail)
    if [[ -f "$repo_path/.git/shallow" ]]; then
        PREFLIGHT_SKIP_REASON="shallow_clone"
        return 1
    fi

    # Check 5: Dirty submodules?
    if git -C "$repo_path" submodule status 2>/dev/null | grep -q '^+'; then
        PREFLIGHT_SKIP_REASON="dirty_submodules"
        return 1
    fi

    # Check 6: Rebase in progress?
    if [[ -d "$repo_path/.git/rebase-apply" ]] || [[ -d "$repo_path/.git/rebase-merge" ]]; then
        PREFLIGHT_SKIP_REASON="rebase_in_progress"
        return 1
    fi

    # Check 7: Merge in progress?
    if [[ -f "$repo_path/.git/MERGE_HEAD" ]]; then
        PREFLIGHT_SKIP_REASON="merge_in_progress"
        return 1
    fi

    # Check 8: Cherry-pick in progress?
    if [[ -f "$repo_path/.git/CHERRY_PICK_HEAD" ]]; then
        PREFLIGHT_SKIP_REASON="cherry_pick_in_progress"
        return 1
    fi

    # Check 9: Detached HEAD?
    local branch
    branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$branch" ]]; then
        PREFLIGHT_SKIP_REASON="detached_HEAD"
        return 1
    fi

    # Check 10: Has upstream? (only required if push strategy is not "none")
    local upstream
    upstream=$(git -C "$repo_path" rev-parse --abbrev-ref "@{u}" 2>/dev/null)
    if [[ -z "$upstream" ]] && [[ "${AGENT_SWEEP_PUSH_STRATEGY:-push}" != "none" ]]; then
        PREFLIGHT_SKIP_REASON="no_upstream_branch"
        return 1
    fi

    # Check 11: Diverged from upstream?
    if [[ -n "$upstream" ]]; then
        local ahead behind
        # shellcheck disable=SC1083  # @{u} is valid git syntax for upstream tracking branch
        read -r ahead behind < <(git -C "$repo_path" rev-list --left-right --count HEAD...@{u} 2>/dev/null)
        if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
            PREFLIGHT_SKIP_REASON="diverged_from_upstream"
            return 1
        fi
    fi

    # Check 12: Unmerged paths (merge conflicts)?
    if git -C "$repo_path" ls-files --unmerged 2>/dev/null | grep -q .; then
        PREFLIGHT_SKIP_REASON="unmerged_paths"
        return 1
    fi

    # Check 13: git diff --check clean? (whitespace errors, conflict markers)
    if ! git -C "$repo_path" diff --check &>/dev/null; then
        PREFLIGHT_SKIP_REASON="diff_check_failed"
        return 1
    fi

    # Check 14: Too many untracked files?
    local untracked_count
    untracked_count=$(git -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null | wc -l)
    if [[ "$untracked_count" -gt "${AGENT_SWEEP_MAX_UNTRACKED:-1000}" ]]; then
        PREFLIGHT_SKIP_REASON="too_many_untracked_files"
        return 1
    fi

    return 0
}

# Get human-readable explanation for a preflight skip reason
# Args: $1 = skip_reason (from PREFLIGHT_SKIP_REASON)
# Outputs: Human-readable message to stdout
preflight_skip_reason_message() {
    local reason="$1"
    case "$reason" in
        repo_path_not_found)        echo "Repository path not found" ;;
        not_a_git_repo)             echo "Not a git repository" ;;
        git_email_not_configured)   echo "Git user.email is not configured" ;;
        git_name_not_configured)    echo "Git user.name is not configured" ;;
        shallow_clone)              echo "Repository is a shallow clone" ;;
        dirty_submodules)           echo "Submodules have uncommitted changes" ;;
        rebase_in_progress)         echo "A rebase is in progress" ;;
        merge_in_progress)          echo "A merge is in progress" ;;
        cherry_pick_in_progress)    echo "A cherry-pick is in progress" ;;
        detached_HEAD)              echo "HEAD is detached (not on a branch)" ;;
        no_upstream_branch)         echo "No upstream tracking branch configured" ;;
        diverged_from_upstream)     echo "Branch has diverged from upstream" ;;
        unmerged_paths)             echo "Unmerged paths exist (merge conflicts)" ;;
        diff_check_failed)          echo "Diff check failed (whitespace or conflict markers)" ;;
        too_many_untracked_files)   echo "Too many untracked files" ;;
        *)                          echo "Unknown preflight issue: $reason" ;;
    esac
}

# Get suggested user action for a preflight skip reason
# Args: $1 = skip_reason (from PREFLIGHT_SKIP_REASON)
# Outputs: Suggested remediation command to stdout
preflight_skip_reason_action() {
    local reason="$1"
    case "$reason" in
        repo_path_not_found)        echo "Ensure the repo exists or run: ru sync" ;;
        not_a_git_repo)             echo "Verify the directory is a git repository" ;;
        git_email_not_configured)   echo "Run: git config user.email \"you@example.com\"" ;;
        git_name_not_configured)    echo "Run: git config user.name \"Your Name\"" ;;
        shallow_clone)              echo "Run: git fetch --unshallow" ;;
        dirty_submodules)           echo "Commit or discard submodule changes" ;;
        rebase_in_progress)         echo "Complete or abort the rebase: git rebase --continue OR git rebase --abort" ;;
        merge_in_progress)          echo "Complete or abort the merge: git merge --continue OR git merge --abort" ;;
        cherry_pick_in_progress)    echo "Complete or abort: git cherry-pick --continue OR git cherry-pick --abort" ;;
        detached_HEAD)              echo "Switch to a branch: git checkout <branch>" ;;
        no_upstream_branch)         echo "Set upstream: git branch --set-upstream-to=origin/<branch>" ;;
        diverged_from_upstream)     echo "Pull and rebase: git pull --rebase" ;;
        unmerged_paths)             echo "Resolve conflicts and run: git add <files>" ;;
        diff_check_failed)          echo "Fix whitespace issues or conflict markers in working tree" ;;
        too_many_untracked_files)   echo "Review .gitignore or clean untracked files: git clean -n" ;;
        *)                          echo "Investigate and fix the issue" ;;
    esac
}

# Run preflight checks on all repos upfront before spawning agents.
# Shows all problems at once for better UX (fail fast).
#
# Args: $1 = name of array variable containing repo specs (modified in place)
#
# Returns:
#   0 - At least one repo passed preflight
#   1 - All repos failed preflight (or empty input)
#
# Side effects:
#   - Modifies the input array to contain only repos that passed
#   - Writes preflight results to ${AGENT_SWEEP_STATE_DIR}/preflight_results.ndjson
#   - Sets PREFLIGHT_PASSED_COUNT and PREFLIGHT_FAILED_COUNT
#
# Usage:
#   local repos=(repo1 repo2 repo3)
#   run_parallel_preflight repos
#   # repos now contains only repos that passed preflight
run_parallel_preflight() {
    # shellcheck disable=SC2178  # repos_ref is a nameref to caller's array
    local -n repos_ref=$1
    local -a passed_repos=()
    local -a failed_repos=()
    local preflight_results_file="${AGENT_SWEEP_STATE_DIR}/preflight_results.ndjson"

    local total_count=${#repos_ref[@]}
    [[ $total_count -eq 0 ]] && return 1

    log_info "Running preflight checks on $total_count repositories..."

    # Initialize results file with header
    printf '{"type":"header","timestamp":"%s","total_repos":%d}\n' \
        "$(date -Iseconds)" "$total_count" > "$preflight_results_file"

    # Run preflight for each repo
    local repo_spec repo_path repo_name
    for repo_spec in "${repos_ref[@]}"; do
        repo_path=$(repo_spec_to_path "$repo_spec")
        repo_name=$(get_repo_name "$repo_spec")

        if repo_preflight_check "$repo_path"; then
            passed_repos+=("$repo_spec")
            printf '{"repo":"%s","path":"%s","status":"passed"}\n' \
                "$(json_escape "$repo_name")" "$(json_escape "$repo_path")" >> "$preflight_results_file"
            log_verbose "Preflight passed: $repo_name"
        else
            failed_repos+=("$repo_spec")
            local reason="${PREFLIGHT_SKIP_REASON:-unknown}"
            local message
            message=$(preflight_skip_reason_message "$reason")
            printf '{"repo":"%s","path":"%s","status":"failed","reason":"%s","message":"%s"}\n' \
                "$(json_escape "$repo_name")" "$(json_escape "$repo_path")" \
                "$(json_escape "$reason")" "$(json_escape "$message")" >> "$preflight_results_file"
            log_warn "Preflight failed: $repo_name - $message"
        fi
    done

    # Write summary to results file
    printf '{"type":"summary","passed":%d,"failed":%d}\n' \
        "${#passed_repos[@]}" "${#failed_repos[@]}" >> "$preflight_results_file"

    # Export counts for summary display (read by callers)
    # shellcheck disable=SC2034  # These are exported for callers to read
    PREFLIGHT_PASSED_COUNT=${#passed_repos[@]}
    # shellcheck disable=SC2034
    PREFLIGHT_FAILED_COUNT=${#failed_repos[@]}

    # Log summary
    if [[ ${#failed_repos[@]} -gt 0 ]]; then
        log_info "Preflight complete: ${#passed_repos[@]} passed, ${#failed_repos[@]} skipped"
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "Skipped repos:"
            for repo_spec in "${failed_repos[@]}"; do
                local name action
                name=$(get_repo_name "$repo_spec")
                # Re-run preflight to get the reason (cached in PREFLIGHT_SKIP_REASON)
                repo_preflight_check "$(repo_spec_to_path "$repo_spec")" 2>/dev/null || true
                action=$(preflight_skip_reason_action "${PREFLIGHT_SKIP_REASON:-unknown}")
                log_info "  - $name: $action"
            done
        fi
    else
        log_info "Preflight complete: all ${#passed_repos[@]} repositories passed"
    fi

    # Return passed repos via the reference
    repos_ref=("${passed_repos[@]}")

    # Return failure if all repos failed
    [[ ${#passed_repos[@]} -gt 0 ]]
}

#==============================================================================
# SECTION 13.10: AGENT SWEEP COMMAND
#==============================================================================

#------------------------------------------------------------------------------
# cmd_agent_sweep: Main entry point for agent-sweep command
#
# Orchestrates AI coding agents to process repositories with uncommitted changes.
# Uses ntm (Named Tmux Manager) to spawn and manage agent sessions.
#
# Returns:
#   0 - All repos processed successfully
#   1 - Some repos failed
#   2 - Conflicts or quality gate failures
#   3 - System/dependency error (ntm, tmux missing)
#   4 - Invalid arguments
#   5 - Interrupted (use --resume to continue)
#------------------------------------------------------------------------------
cmd_agent_sweep() {
    # Default configuration
    local with_release=false
    local parallel=1
    local repos_filter=""
    local dry_run=false
    local resume=false
    local restart=false
    local keep_sessions=false
    local keep_sessions_on_fail=false
    local attach_on_fail=false
    local execution_mode="agent"
    local secret_scan_mode="warn"
    local json_output=false
    local max_file_mb_override=""
    local phase1_timeout="${AGENT_SWEEP_PHASE1_TIMEOUT:-300}"
    local phase2_timeout="${AGENT_SWEEP_PHASE2_TIMEOUT:-600}"
    local phase3_timeout="${AGENT_SWEEP_PHASE3_TIMEOUT:-300}"

    # Parse agent-sweep specific arguments
    local arg
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --with-release) with_release=true ;;
            -j[0-9]*) parallel="${arg#-j}" ;;
            --parallel=*) parallel="${arg#--parallel=}" ;;
            --repos=*) repos_filter="${arg#--repos=}" ;;
            --dry-run) dry_run=true ;;
            --resume) resume=true ;;
            --restart) restart=true ;;
            --keep-sessions) keep_sessions=true ;;
            --keep-sessions-on-fail) keep_sessions_on_fail=true ;;
            --attach-on-fail) attach_on_fail=true ;;
            --execution-mode=*) execution_mode="${arg#--execution-mode=}" ;;
            --secret-scan=*) secret_scan_mode="${arg#--secret-scan=}" ;;
            --max-file-mb=*) max_file_mb_override="${arg#--max-file-mb=}" ;;
            --phase1-timeout=*) phase1_timeout="${arg#--phase1-timeout=}" ;;
            --phase2-timeout=*) phase2_timeout="${arg#--phase2-timeout=}" ;;
            --phase3-timeout=*) phase3_timeout="${arg#--phase3-timeout=}" ;;
            --json) json_output=true ;;
            --verbose|-v) VERBOSE=true; LOG_LEVEL=1 ;;
            --debug|-d) DEBUG=true; VERBOSE=true; LOG_LEVEL=2 ;;
        esac
    done

    # Validate parallel count
    if ! [[ "$parallel" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid parallel count: $parallel (must be positive integer)"
        return 4
    fi

    # Validate execution mode
    case "$execution_mode" in
        plan|apply|agent) ;;
        *) log_error "Invalid execution mode: $execution_mode"; return 4 ;;
    esac

    # Validate secret scan mode
    case "$secret_scan_mode" in
        none|warn|block) ;;
        *) log_error "Invalid secret-scan mode: $secret_scan_mode"; return 4 ;;
    esac

    # Validate max file size override
    if [[ -n "$max_file_mb_override" ]]; then
        if ! agent_sweep_is_positive_int "$max_file_mb_override"; then
            log_error "Invalid --max-file-mb: $max_file_mb_override (must be positive integer)"
            return 4
        fi
        AGENT_SWEEP_MAX_FILE_MB_OVERRIDE="$max_file_mb_override"
    fi

    # Resume and restart are mutually exclusive
    if [[ "$resume" == true && "$restart" == true ]]; then
        log_error "Cannot use --resume and --restart together"
        return 4
    fi

    # Ensure state directory exists
    local state_dir="${AGENT_SWEEP_STATE_DIR:-$RU_STATE_DIR/agent-sweep}"
    ensure_dir "$state_dir"

    # Concurrent instance lock
    local lock_dir="$state_dir/instance.lock"

    # Helper to release lock - only called within cmd_agent_sweep where state_dir is in scope
    # Note: The EXIT trap uses inline expansion instead of this function to avoid scope issues
    release_lock() {
        rm -f "$state_dir/instance.lock/pid" 2>/dev/null
        rmdir "$state_dir/instance.lock" 2>/dev/null || true
    }

    if ! mkdir "$lock_dir" 2>/dev/null; then
        local existing_pid
        existing_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
        log_error "Another agent-sweep is already running (PID: $existing_pid)"
        log_error "If stale, remove: $lock_dir"
        return 1
    fi
    echo $$ > "$lock_dir/pid"
    AGENT_SWEEP_INSTANCE_LOCK_DIR="$lock_dir"
    AGENT_SWEEP_INSTANCE_LOCK_BASE="$state_dir"
    # Use double quotes to expand lock_dir at trap definition time (not execution time)
    # shellcheck disable=SC2064
    trap "rm -f '$lock_dir/pid' 2>/dev/null; rmdir '$lock_dir' 2>/dev/null || true" EXIT
    log_debug "Acquired instance lock: $lock_dir (PID: $$)"

    # Check ntm availability
    log_verbose "Checking ntm availability..."
    if ! ntm_check_available; then
        log_error "ntm (Named Tmux Manager) is not available"
        release_lock
        return 3
    fi

    # Check tmux availability
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is required for agent-sweep"
        release_lock
        return 3
    fi
    log_debug "ntm and tmux availability confirmed"

    # Load all configured repos
    log_verbose "Loading configured repositories..."
    local -a repos=()
    load_all_repos repos
    log_debug "Loaded ${#repos[@]} configured repositories"

    if [[ ${#repos[@]} -eq 0 ]]; then
        log_error "No repositories configured. Run 'ru add' to add repositories."
        release_lock
        return 4
    fi

    # Filter to repos with uncommitted changes
    log_verbose "Filtering for repositories with uncommitted changes..."
    local -a dirty_repos=()
    local repo_spec repo_path
    for repo_spec in "${repos[@]}"; do
        repo_path=$(repo_spec_to_path "$repo_spec")
        if [[ -d "$repo_path" ]] && has_uncommitted_changes "$repo_path"; then
            if [[ -z "$repos_filter" ]] || [[ "$repo_spec" == *"$repos_filter"* ]]; then
                dirty_repos+=("$repo_spec")
                log_debug "Found dirty repo: $(get_repo_name "$repo_spec")"
            fi
        fi
    done
    log_verbose "Found ${#dirty_repos[@]} repositories with uncommitted changes"

    # Handle empty case
    if [[ ${#dirty_repos[@]} -eq 0 ]]; then
        if [[ "$json_output" == true ]]; then
            jq -n '{status:"success",message:"No repositories with uncommitted changes",repos_processed:0}'
        else
            log_success "No repositories with uncommitted changes found."
        fi
        release_lock
        return 0
    fi

    # Dry run mode
    if [[ "$dry_run" == true ]]; then
        if [[ "$json_output" == true ]]; then
            printf '%s\n' "${dirty_repos[@]}" | jq -R . | jq -s '{mode:"dry-run",repos:.}'
        else
            log_info "Dry run: ${#dirty_repos[@]} repositories with uncommitted changes:"
            for repo_spec in "${dirty_repos[@]}"; do
                log_info "  - $(get_repo_name "$repo_spec")"
            done
        fi
        release_lock
        return 0
    fi

    # Setup results tracking
    setup_agent_sweep_results

    # Handle resume/restart
    if [[ "$resume" == true ]] && load_agent_sweep_state; then
        log_info "Resuming previous agent-sweep run..."
        local -a remaining=()
        for repo_spec in "${dirty_repos[@]}"; do
            local is_done=false
            # Check if repo is in completed list (handle empty array safely)
            if [[ ${#COMPLETED_REPOS[@]} -gt 0 ]]; then
                for c in "${COMPLETED_REPOS[@]}"; do
                    [[ "$c" == "$repo_spec" ]] && is_done=true && break
                done
            fi
            [[ "$is_done" != true ]] && remaining+=("$repo_spec")
        done
        dirty_repos=("${remaining[@]}")
        log_info "Resuming with ${#dirty_repos[@]} remaining repositories"
    elif [[ "$restart" == true ]]; then
        log_info "Restarting agent-sweep (clearing previous state)..."
        cleanup_agent_sweep_state
    fi

    # If resuming, honor prior --with-release unless explicitly overridden
    if [[ "$resume" == true && "${SWEEP_WITH_RELEASE:-false}" == "true" ]]; then
        with_release="true"
    fi
    SWEEP_WITH_RELEASE="$with_release"

    if [[ ${#dirty_repos[@]} -eq 0 ]]; then
        log_success "All repositories already processed."
        release_lock
        return 0
    fi

    # Run preflight checks
    log_step "Running preflight checks..."
    if ! run_parallel_preflight dirty_repos; then
        if [[ ${#dirty_repos[@]} -eq 0 ]]; then
            log_error "All repositories failed preflight checks"
            release_lock
            return 2
        fi
    fi

    # Setup trap handlers
    setup_agent_sweep_traps

    # Export configuration
    export AGENT_SWEEP_WITH_RELEASE="$with_release"
    export AGENT_SWEEP_EXECUTION_MODE="$execution_mode"
    export AGENT_SWEEP_SECRET_SCAN="$secret_scan_mode"
    export AGENT_SWEEP_PHASE1_TIMEOUT="$phase1_timeout"
    export AGENT_SWEEP_PHASE2_TIMEOUT="$phase2_timeout"
    export AGENT_SWEEP_PHASE3_TIMEOUT="$phase3_timeout"
    export AGENT_SWEEP_JSON_OUTPUT="$json_output"
    export AGENT_SWEEP_MAX_FILE_MB_OVERRIDE="${AGENT_SWEEP_MAX_FILE_MB_OVERRIDE:-}"
    export AGENT_SWEEP_KEEP_SESSIONS="$keep_sessions"
    export AGENT_SWEEP_KEEP_SESSIONS_ON_FAIL="$keep_sessions_on_fail"

    # Process repositories
    local sweep_exit=0
    log_step "Processing ${#dirty_repos[@]} repositories..."

    if [[ $parallel -gt 1 ]]; then
        log_info "Running $parallel agents in parallel"
        run_parallel_agent_sweep dirty_repos "$parallel" || sweep_exit=$?
    else
        run_sequential_agent_sweep dirty_repos || sweep_exit=$?
    fi

    # Print summary
    print_agent_sweep_summary

    # Handle attach-on-fail
    if [[ "$attach_on_fail" == true && $sweep_exit -ne 0 ]]; then
        local failed_session
        failed_session=$(get_first_failed_session)
        [[ -n "$failed_session" ]] && tmux attach-session -t "$failed_session" 2>/dev/null || true
    fi

    # Cleanup
    if [[ "$keep_sessions" != true ]]; then
        if [[ "$keep_sessions_on_fail" != true || $sweep_exit -eq 0 ]]; then
            cleanup_agent_sweep_sessions
        fi
    fi

    release_lock
    return $sweep_exit
}

# Helper functions for agent-sweep (stubs for dependent beads)
run_sequential_agent_sweep() {
    # shellcheck disable=SC2178
    local -n repos_ref=$1
    local any_failed=false
    local rn total=${#repos_ref[@]}

    # Initialize progress display
    progress_init "$total"
    log_debug "Starting sequential sweep of $total repositories"

    for repo_spec in "${repos_ref[@]}"; do
        rn=$(get_repo_name "$repo_spec")

        # Start repo in progress display
        progress_start_repo "$rn"
        log_verbose "Starting workflow for $rn"

        local repo_start repo_duration
        repo_start=$(date +%s)
        if run_single_agent_workflow "$repo_spec"; then
            repo_duration=$(( $(date +%s) - repo_start ))
            record_repo_result "$repo_spec" "success" "" "$repo_duration"
            progress_complete_repo "success"
            log_debug "Workflow succeeded for $rn"
        else
            local exit_code=$?
            repo_duration=$(( $(date +%s) - repo_start ))
            if [[ $exit_code -eq 2 ]]; then
                record_repo_result "$repo_spec" "skipped" "skipped" "$repo_duration"
                progress_complete_repo "skipped" "skipped"
                log_debug "Workflow skipped for $rn"
            else
                record_repo_result "$repo_spec" "failed" "exit code $exit_code" "$repo_duration"
                progress_complete_repo "failed" "exit code $exit_code"
                log_debug "Workflow failed for $rn (exit code: $exit_code)"
                any_failed=true
            fi
        fi
    done

    # Show summary
    progress_summary
    log_debug "Sequential sweep complete: any_failed=$any_failed"
    [[ "$any_failed" != true ]]
}

run_parallel_agent_sweep() {
    # shellcheck disable=SC2178
    local -n repos_ref=$1
    local max_parallel="${2:-4}"
    local total=${#repos_ref[@]}

    # For small batches, just use sequential mode
    # Pass $1 (original array name) to avoid circular nameref
    if [[ $total -le 1 ]] || [[ "$max_parallel" -le 1 ]]; then
        run_sequential_agent_sweep "$1"
        return $?
    fi

    log_info "Starting parallel sweep: $total repos, max $max_parallel workers"
    progress_init "$total"

    # Create work queue and lock directory
    local work_queue lock_dir
    work_queue=$(mktemp_file) || { log_error "Failed to create work queue"; return 3; }
    lock_dir="${AGENT_SWEEP_STATE_DIR:-/tmp}/locks_$$"
    if ! mkdir -p "$lock_dir"; then
        log_error "Failed to create lock directory: $lock_dir"
        rm -f "$work_queue" 2>/dev/null || true
        return 3
    fi

    # Populate work queue
    printf '%s\n' "${repos_ref[@]}" > "$work_queue"

    # Track worker PIDs and results
    local -a worker_pids=()
    local any_failed=false

    # Spawn workers
    local i
    for ((i=0; i<max_parallel && i<total; i++)); do
        (
            local worker_id=$i
            local worker_failed=false
            log_debug "Worker $worker_id starting"

            while true; do
                # Check global backoff before claiming work
                agent_sweep_backoff_wait_if_needed || true

                # Atomic dequeue: acquire lock, read first line, remove it
                local repo_spec=""
                if dir_lock_acquire "${lock_dir}/queue.lock" 30 2>/dev/null; then
                    if [[ -s "$work_queue" ]]; then
                        repo_spec=$(head -n1 "$work_queue" 2>/dev/null || true)
                        if [[ -n "$repo_spec" ]]; then
                            tail -n +2 "$work_queue" > "${work_queue}.tmp" 2>/dev/null || true
                            mv "${work_queue}.tmp" "$work_queue" 2>/dev/null || true
                        fi
                    fi
                    dir_lock_release "${lock_dir}/queue.lock" 2>/dev/null || true
                fi

                # No more work
                [[ -z "$repo_spec" ]] && break

                # Process this repo
                local rn
                rn=$(get_repo_name "$repo_spec")
                progress_start_repo "$rn"
                log_debug "Worker $worker_id processing $rn"

                local repo_start repo_duration
                repo_start=$(date +%s)
                if run_single_agent_workflow "$repo_spec"; then
                    repo_duration=$(( $(date +%s) - repo_start ))
                    record_repo_result "$repo_spec" "success" "" "$repo_duration"
                    progress_complete_repo "success"
                else
                    local exit_code=$?
                    repo_duration=$(( $(date +%s) - repo_start ))
                    if [[ $exit_code -eq 2 ]]; then
                        record_repo_result "$repo_spec" "skipped" "skipped" "$repo_duration"
                        progress_complete_repo "skipped" "skipped"
                    else
                        record_repo_result "$repo_spec" "failed" "exit code $exit_code" "$repo_duration"
                        progress_complete_repo "failed" "exit code $exit_code"
                        worker_failed=true
                    fi
                fi
            done

            log_debug "Worker $worker_id finished"
            [[ "$worker_failed" != true ]]
        ) &
        worker_pids+=($!)
    done

    # Wait for all workers
    local pid
    for pid in "${worker_pids[@]}"; do
        if ! wait "$pid"; then
            any_failed=true
        fi
    done

    # Cleanup
    rm -f "$work_queue" "${work_queue}.tmp"
    rm -rf "$lock_dir"

    # Show summary
    progress_summary

    [[ "$any_failed" != true ]]
}

run_single_agent_workflow() {
    local repo_spec="$1"
    local rn rp start_time exec_mode with_release
    rn=$(get_repo_name "$repo_spec")
    rp=$(repo_spec_to_path "$repo_spec")
    start_time=$(date +%s)
    exec_mode="${AGENT_SWEEP_EXECUTION_MODE:-agent}"
    with_release="${AGENT_SWEEP_WITH_RELEASE:-false}"
    SWEEP_LAST_SESSION_NAME=""

    log_debug "run_single_agent_workflow: repo=$rn path=$rp"

    if [[ -z "$rp" || ! -d "$rp" ]]; then
        log_error "Repo path not found: $rp"
        write_result "$rn" "preflight" "failed" 0 "repo path not found" "$rp"
        return 1
    fi

    if ! load_repo_agent_config "$rp"; then
        log_error "Failed to load agent-sweep config for $rn"
        write_result "$rn" "config" "failed" 0 "config load failed" "$rp"
        return 1
    fi
    log_debug "Config loaded: AGENT_SWEEP_ENABLED=$AGENT_SWEEP_ENABLED"

    if [[ "$AGENT_SWEEP_ENABLED" != "true" ]]; then
        log_verbose "Skipping $rn (disabled in config)"
        write_result "$rn" "preflight" "skipped" 0 "disabled" "$rp"
        return 2
    fi

    progress_update_phase "preflight"
    if ! repo_preflight_check "$rp"; then
        local reason="${PREFLIGHT_SKIP_REASON:-unknown}"
        local message
        message=$(preflight_skip_reason_message "$reason")
        log_warn "Preflight failed for $rn: $message"
        write_result "$rn" "preflight" "skipped" 0 "$reason" "$rp"
        return 2
    fi

    local artifact_dir=""
    artifact_dir=$(setup_repo_artifact_dir "$rp" 2>/dev/null || true)
    if [[ -n "$artifact_dir" ]]; then
        capture_git_state "$rp" "${artifact_dir}/git_before.txt" || true
    fi

    # Optional pre-hook
    if [[ -n "$AGENT_SWEEP_PRE_HOOK" ]]; then
        local pre_output pre_exit
        if pre_output=$( (cd "$rp" && eval "$AGENT_SWEEP_PRE_HOOK") 2>&1); then
            pre_exit=0
        else
            pre_exit=$?
        fi
        [[ -n "$artifact_dir" ]] && printf '%s\n' "$pre_output" > "${artifact_dir}/pre_hook.log"
        if [[ $pre_exit -ne 0 ]]; then
            log_error "Pre-hook failed for $rn (exit $pre_exit): $pre_output"
            write_result "$rn" "pre_hook" "failed" 0 "pre-hook failed" "$rp"
            capture_final_artifacts "$rp" ""
            return 1
        fi
    fi

    # Backup ref before any changes
    git -C "$rp" update-ref -m "agent-sweep backup before run ${RUN_ID:-unknown}" \
        "refs/agent-sweep/pre-run-${RUN_ID:-unknown}" HEAD 2>/dev/null || true

    # Session cleanup helper (honor keep-sessions flags)
    _maybe_kill_session() {
        local session_name="$1"
        local failed="${2:-false}"
        [[ -z "$session_name" ]] && return 0
        if [[ "${AGENT_SWEEP_KEEP_SESSIONS:-false}" == "true" ]]; then
            return 0
        fi
        if [[ "$failed" == "true" && "${AGENT_SWEEP_KEEP_SESSIONS_ON_FAIL:-false}" == "true" ]]; then
            return 0
        fi
        ntm_kill_session "$session_name"
    }

    # Spawn session
    progress_update_phase "spawn"
    local session_name
    session_name="ru_sweep_$(sanitize_session_name "$rn")_$$"
    local spawn_result spawn_exit
    if spawn_result=$(ntm_spawn_session "$session_name" "$rp"); then
        spawn_exit=0
    else
        spawn_exit=$?
    fi
    [[ -n "$artifact_dir" ]] && capture_spawn_response "$rp" "$spawn_result" || true
    if [[ $spawn_exit -ne 0 ]]; then
        log_error "Session spawn failed for $rn: $spawn_result"
        write_result "$rn" "spawn" "failed" 0 "session spawn failed" "$rp"
        capture_final_artifacts "$rp" "$session_name"
        _maybe_kill_session "$session_name" "true"
        return 1
    fi
    SWEEP_LAST_SESSION_NAME="$session_name"
    write_result "$rn" "spawn" "ok" 0 "" "$rp"

    local pane_output=""
    local phase_start phase_duration

    # Phase 1: Understanding
    if ! should_skip_phase "phase1" && ! should_skip_phase "understanding"; then
        progress_update_phase 1
        local phase1_prompt
        phase1_prompt=$(get_effective_phase_prompt 1 "$rp")
        if [[ -n "$AGENT_SWEEP_EXTRA_CONTEXT" ]]; then
            phase1_prompt+=$'\n\nAdditional context:\n'"$AGENT_SWEEP_EXTRA_CONTEXT"
        fi

        phase_start=$(date +%s)
        log_activity_snapshot "$rp" "phase1" "start"
        if ! ntm_send_prompt "$session_name" "$phase1_prompt" >/dev/null 2>&1; then
            log_error "Failed to send Phase 1 prompt for $rn"
            write_result "$rn" "phase1" "failed" 0 "send prompt failed" "$rp"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        progress_update_phase "wait"
        if ! ntm_wait_completion "$session_name" "${AGENT_SWEEP_PHASE1_TIMEOUT:-300}" >/dev/null 2>&1; then
            phase_duration=$(( $(date +%s) - phase_start ))
            log_error "Phase 1 timed out for $rn"
            write_result "$rn" "phase1" "timeout" "$phase_duration" "" "$rp"
            log_activity_snapshot "$rp" "phase1" "timeout"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        phase_duration=$(( $(date +%s) - phase_start ))
        pane_output=$(capture_pane_output "$session_name" 10000 2>/dev/null || true)
        local understanding_json=""
        if understanding_json=$(extract_plan_json "$pane_output" "UNDERSTANDING"); then
            [[ -n "$artifact_dir" ]] && printf '%s\n' "$understanding_json" > "${artifact_dir}/understanding.json"
            write_result "$rn" "phase1" "ok" "$phase_duration" "" "$rp"
        else
            log_warn "Phase 1 understanding JSON not found for $rn"
            write_result "$rn" "phase1" "warning" "$phase_duration" "missing understanding json" "$rp"
        fi
        log_activity_snapshot "$rp" "phase1" "complete"
    else
        log_verbose "Skipping Phase 1 for $rn"
        write_result "$rn" "phase1" "skipped" 0 "" "$rp"
    fi

    # Phase 2: Commit plan
    if should_skip_phase "phase2" || should_skip_phase "commit"; then
        log_verbose "Skipping Phase 2 for $rn"
        write_result "$rn" "phase2" "skipped" 0 "" "$rp"
    else
        progress_update_phase 2
        local phase2_prompt
        phase2_prompt=$(get_effective_phase_prompt 2 "$rp")
        if [[ -n "$AGENT_SWEEP_EXTRA_CONTEXT" ]]; then
            phase2_prompt+=$'\n\nAdditional context:\n'"$AGENT_SWEEP_EXTRA_CONTEXT"
        fi

        phase_start=$(date +%s)
        log_activity_snapshot "$rp" "phase2" "start"
        if ! ntm_send_prompt "$session_name" "$phase2_prompt" >/dev/null 2>&1; then
            log_error "Failed to send Phase 2 prompt for $rn"
            write_result "$rn" "phase2" "failed" 0 "send prompt failed" "$rp"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        progress_update_phase "wait"
        if ! ntm_wait_completion "$session_name" "${AGENT_SWEEP_PHASE2_TIMEOUT:-600}" >/dev/null 2>&1; then
            phase_duration=$(( $(date +%s) - phase_start ))
            log_error "Phase 2 timed out for $rn"
            write_result "$rn" "phase2" "timeout" "$phase_duration" "" "$rp"
            log_activity_snapshot "$rp" "phase2" "timeout"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        phase_duration=$(( $(date +%s) - phase_start ))
        pane_output=$(capture_pane_output "$session_name" 10000 2>/dev/null || true)
        local commit_plan=""
        if ! commit_plan=$(extract_plan_json "$pane_output" "COMMIT_PLAN"); then
            log_error "Commit plan JSON not found for $rn"
            write_result "$rn" "phase2" "failed" "$phase_duration" "missing commit plan json" "$rp"
            log_activity_snapshot "$rp" "phase2" "failed"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        [[ -n "$artifact_dir" ]] && capture_plan_json "$rp" "commit" "$commit_plan" || true
        write_result "$rn" "phase2" "ok" "$phase_duration" "" "$rp"

        progress_update_phase "validate"
        if [[ "$exec_mode" == "plan" ]]; then
            if ! validate_commit_plan "$commit_plan" "$rp"; then
                log_error "Commit plan validation failed for $rn: ${VALIDATION_ERROR:-unknown}"
                write_result "$rn" "validation" "failed" 0 "${VALIDATION_ERROR:-validation failed}" "$rp"
                log_activity_snapshot "$rp" "phase2" "validation_failed"
                capture_final_artifacts "$rp" "$session_name"
                _maybe_kill_session "$session_name" "true"
                return 1
            fi
            write_result "$rn" "validation" "ok" 0 "" "$rp"
            log_info "Plan mode enabled; skipping commit execution for $rn"
        else
            progress_update_phase "apply"
            if ! execute_commit_plan "$commit_plan" "$rp"; then
                log_error "Commit execution failed for $rn"
                write_result "$rn" "execution" "failed" 0 "commit execution failed" "$rp"
                log_activity_snapshot "$rp" "phase2" "execution_failed"
                capture_final_artifacts "$rp" "$session_name"
                _maybe_kill_session "$session_name" "true"
                return 1
            fi
            write_result "$rn" "execution" "ok" 0 "" "$rp"
        fi
        log_activity_snapshot "$rp" "phase2" "complete"
    fi

    # Phase 3: Release (optional)
    local release_strategy
    release_strategy=$(get_release_strategy "$rp")
    if [[ "$with_release" == true && "$release_strategy" != "never" ]] && \
       ! should_skip_phase "phase3" && ! should_skip_phase "release"; then
        progress_update_phase 3
        local phase3_prompt
        phase3_prompt=$(get_effective_phase_prompt 3 "$rp")
        if [[ -n "$AGENT_SWEEP_EXTRA_CONTEXT" ]]; then
            phase3_prompt+=$'\n\nAdditional context:\n'"$AGENT_SWEEP_EXTRA_CONTEXT"
        fi

        phase_start=$(date +%s)
        log_activity_snapshot "$rp" "phase3" "start"
        if ! ntm_send_prompt "$session_name" "$phase3_prompt" >/dev/null 2>&1; then
            log_error "Failed to send Phase 3 prompt for $rn"
            write_result "$rn" "phase3" "failed" 0 "send prompt failed" "$rp"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        progress_update_phase "wait"
        if ! ntm_wait_completion "$session_name" "${AGENT_SWEEP_PHASE3_TIMEOUT:-300}" >/dev/null 2>&1; then
            phase_duration=$(( $(date +%s) - phase_start ))
            log_error "Phase 3 timed out for $rn"
            write_result "$rn" "phase3" "timeout" "$phase_duration" "" "$rp"
            log_activity_snapshot "$rp" "phase3" "timeout"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        phase_duration=$(( $(date +%s) - phase_start ))
        pane_output=$(capture_pane_output "$session_name" 10000 2>/dev/null || true)
        local release_plan=""
        if ! release_plan=$(extract_plan_json "$pane_output" "RELEASE_PLAN"); then
            log_error "Release plan JSON not found for $rn"
            write_result "$rn" "phase3" "failed" "$phase_duration" "missing release plan json" "$rp"
            log_activity_snapshot "$rp" "phase3" "failed"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi

        [[ -n "$artifact_dir" ]] && capture_plan_json "$rp" "release" "$release_plan" || true
        write_result "$rn" "phase3" "ok" "$phase_duration" "" "$rp"

        if [[ "$exec_mode" == "plan" ]]; then
            if ! validate_release_plan "$release_plan" "$rp"; then
                log_error "Release plan validation failed for $rn: ${VALIDATION_ERROR:-unknown}"
                write_result "$rn" "release" "failed" 0 "${VALIDATION_ERROR:-validation failed}" "$rp"
                log_activity_snapshot "$rp" "phase3" "validation_failed"
                capture_final_artifacts "$rp" "$session_name"
                _maybe_kill_session "$session_name" "true"
                return 1
            fi
            write_result "$rn" "release" "skipped" 0 "plan mode" "$rp"
        else
            if ! execute_release_plan "$release_plan" "$rp"; then
                log_error "Release execution failed for $rn"
                write_result "$rn" "release" "failed" 0 "release execution failed" "$rp"
                log_activity_snapshot "$rp" "phase3" "execution_failed"
                capture_final_artifacts "$rp" "$session_name"
                _maybe_kill_session "$session_name" "true"
                return 1
            fi
            write_result "$rn" "release" "ok" 0 "" "$rp"
        fi
        log_activity_snapshot "$rp" "phase3" "complete"
    else
        log_verbose "Skipping Phase 3 for $rn"
        write_result "$rn" "phase3" "skipped" 0 "" "$rp"
    fi

    # Optional post-hook
    if [[ -n "$AGENT_SWEEP_POST_HOOK" ]]; then
        local post_output post_exit
        if post_output=$( (cd "$rp" && eval "$AGENT_SWEEP_POST_HOOK") 2>&1); then
            post_exit=0
        else
            post_exit=$?
        fi
        [[ -n "$artifact_dir" ]] && printf '%s\n' "$post_output" > "${artifact_dir}/post_hook.log"
        if [[ $post_exit -ne 0 ]]; then
            log_error "Post-hook failed for $rn (exit $post_exit): $post_output"
            write_result "$rn" "post_hook" "failed" 0 "post-hook failed" "$rp"
            capture_final_artifacts "$rp" "$session_name"
            _maybe_kill_session "$session_name" "true"
            return 1
        fi
    fi

    capture_final_artifacts "$rp" "$session_name"
    _maybe_kill_session "$session_name"

    local duration=$(( $(date +%s) - start_time ))
    write_result "$rn" "agent-sweep" "success" "$duration" "" "$rp"
    return 0
}

get_first_failed_session() {
    local sf="${AGENT_SWEEP_STATE_DIR:-$RU_STATE_DIR/agent-sweep}/results.ndjson"
    if [[ ! -f "$sf" ]]; then
        return 0
    fi
    if command -v jq &>/dev/null; then
        jq -r 'select(.type=="summary" and .status=="failed") | .session // empty' "$sf" 2>/dev/null | head -1
    else
        grep '"type":"summary"' "$sf" | grep '"status":"failed"' | head -1 | sed -nE 's/.*"session":"([^"]*)".*/\1/p'
    fi
}

record_repo_result() {
    local repo_spec="$1"
    local st="$2"
    local detail="${3:-}"
    local duration="${4:-0}"
    local sf="${AGENT_SWEEP_STATE_DIR:-$RU_STATE_DIR/agent-sweep}/results.ndjson"
    local completed_file="${AGENT_SWEEP_STATE_DIR:-$RU_STATE_DIR/agent-sweep}/completed_repos.txt"
    local ts line

    [[ -z "$repo_spec" ]] && return 1

    # Ensure duration is numeric
    local duration_num="${duration:-0}"
    [[ "$duration_num" =~ ^[0-9]+$ ]] || duration_num=0

    ts=$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    local safe_repo safe_detail safe_session
    safe_repo=$(json_escape "$repo_spec")
    safe_detail=$(json_escape "$detail")
    safe_session=$(json_escape "${SWEEP_LAST_SESSION_NAME:-}")

    printf -v line '{"type":"summary","repo":"%s","status":"%s","detail":"%s","duration":%s,"session":"%s","timestamp":"%s"}\n' \
        "$safe_repo" "$st" "$safe_detail" "$duration_num" "$safe_session" "$ts"

    # Use results lock if available (parallel safety)
    if [[ -n "${RESULTS_LOCK_DIR:-}" ]] && dir_lock_acquire "$RESULTS_LOCK_DIR" 10 2>/dev/null; then
        printf '%s' "$line" >> "$sf"
        case "$st" in
            success|failed|skipped)
                echo "$repo_spec" >> "$completed_file"
                ;;
        esac
        dir_lock_release "$RESULTS_LOCK_DIR" 2>/dev/null || true
    else
        printf '%s' "$line" >> "$sf"
        case "$st" in
            success|failed|skipped)
                echo "$repo_spec" >> "$completed_file"
                ;;
        esac
    fi

    case "$st" in
        success|failed|skipped)
            mark_repo_completed "$repo_spec" "$st" || true
            ;;
    esac

    SWEEP_LAST_SESSION_NAME=""
}

print_agent_sweep_summary() {
    local sf="${AGENT_SWEEP_STATE_DIR:-$RU_STATE_DIR/agent-sweep}/results.ndjson"
    [[ ! -f "$sf" ]] && return

    # Calculate duration
    local end_time duration_seconds duration_str
    end_time=$(date +%s)
    duration_seconds=$((end_time - ${RUN_START_TIME:-$end_time}))
    duration_str=$(format_duration "$duration_seconds")

    # Count results
    local s=0 f=0 k=0
    if command -v jq &>/dev/null; then
        while IFS= read -r l; do
            local entry_type status
            entry_type=$(echo "$l" | jq -r '.type // empty' 2>/dev/null)
            [[ "$entry_type" != "summary" ]] && continue
            status=$(echo "$l" | jq -r '.status // empty' 2>/dev/null)
            case "$status" in
                success) ((s++)) ;; failed) ((f++)) ;; skipped) ((k++)) ;;
            esac
        done < "$sf"
    else
        s=$(grep -c '"type":"summary".*"status":"success"' "$sf" 2>/dev/null || echo 0)
        f=$(grep -c '"type":"summary".*"status":"failed"' "$sf" 2>/dev/null || echo 0)
        local error_count
        error_count=$(grep -c '"type":"summary".*"status":"error"' "$sf" 2>/dev/null || echo 0)
        f=$((f + error_count))
        k=$(grep -c '"type":"summary".*"status":"skipped"' "$sf" 2>/dev/null || echo 0)
    fi
    local t=$((s + f + k))

    if [[ "${AGENT_SWEEP_JSON_OUTPUT:-false}" == "true" ]]; then
        # JSON output with full details
        local timestamp repos_json
        timestamp=$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
        if command -v jq &>/dev/null; then
            repos_json=$(jq -s \
                '[.[] | select(.type=="summary") | {name:.repo,status:.status,duration:(.duration // 0),error:(.detail // ""),session:(.session // "")}]' \
                "$sf" 2>/dev/null || echo '[]')
            jq -n --arg ts "$timestamp" --arg rid "${RUN_ID:-unknown}" \
                --argjson dur "$duration_seconds" \
                --argjson t "$t" --argjson s "$s" --argjson f "$f" --argjson k "$k" \
                --argjson repos "$repos_json" \
                --arg art "${RUN_ARTIFACTS_DIR:-}" \
                '{timestamp:$ts,run_id:$rid,duration_seconds:$dur,summary:{total:$t,succeeded:$s,failed:$f,skipped:$k},artifacts_dir:$art,repos:$repos}'
        else
            repos_json="[]"
            printf '{"timestamp":"%s","run_id":"%s","duration_seconds":%s,"summary":{"total":%s,"succeeded":%s,"failed":%s,"skipped":%s},"artifacts_dir":"%s","repos":%s}' \
                "$timestamp" "$(json_escape "${RUN_ID:-unknown}")" "$duration_seconds" "$t" "$s" "$f" "$k" \
                "$(json_escape "${RUN_ARTIFACTS_DIR:-}")" "$repos_json"
        fi
    else
        # Human-readable box output (63 chars wide)
        {
            echo ""
            echo "╭─────────────────────────────────────────────────────────────╮"
            echo "│                   Agent Sweep Complete                       │"
            echo "│                                                             │"
            printf "│  Processed: %-48s │\n" "$t repos"
            printf "│  Succeeded: %-48s │\n" "$s"
            printf "│  Failed:    %-48s │\n" "$f"
            printf "│  Skipped:   %-48s │\n" "$k"
            printf "│  Total time: %-47s │\n" "$duration_str"
            echo "╰─────────────────────────────────────────────────────────────╯"
        } >&2

        # Show failed repos if any
        if (( f > 0 )); then
            echo >&2 ""
            echo >&2 "Failed repos:"
            jq -r 'select(.type=="summary" and .status == "failed") | "  • \(.repo): \(.detail // "unknown")"' "$sf" 2>/dev/null | head -10 >&2
        fi

        # Show artifacts location
        if [[ -n "${RUN_ARTIFACTS_DIR:-}" && -d "$RUN_ARTIFACTS_DIR" ]]; then
            echo >&2 ""
            echo >&2 "Artifacts: $RUN_ARTIFACTS_DIR"
        fi
    fi
}

#==============================================================================
# SECTION 14: MAIN DISPATCH
#==============================================================================

main() {
    # Show quick menu if run with no arguments
    if [[ $# -eq 0 ]]; then
        show_quick_menu
        exit 0
    fi

    # Initialize
    ARGS=()
    parse_args "$@"
    check_gum
    resolve_config
    resolve_output_format

    # Create results file for this run
    RESULTS_FILE=$(mktemp_file) || { log_error "Failed to create temp file"; exit 3; }
    RESULTS_LOCK_DIR="${RESULTS_FILE}.lock.d"

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
        agent-sweep) cmd_agent_sweep ;;
        ai-sync)    cmd_ai_sync ;;
        dep-update) cmd_dep_update ;;
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
