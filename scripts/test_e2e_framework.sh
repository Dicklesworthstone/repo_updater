#!/usr/bin/env bash
#
# test_e2e_framework.sh - E2E test framework extending test_framework.sh
#
# Provides E2E-specific helpers for:
#   - Mock gh CLI creation
#   - GraphQL response generators
#   - E2E test environment setup
#   - Common E2E assertion patterns
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_e2e_framework.sh"
#
#   test_my_e2e_feature() {
#       e2e_setup  # Sets up isolated env with mock gh
#       # ... run tests ...
#       e2e_cleanup
#   }
#
#   run_test test_my_e2e_feature
#   print_results
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts
# shellcheck disable=SC1091  # Sourced files checked separately

set -uo pipefail

#==============================================================================
# Source Base Framework
#==============================================================================

E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_PROJECT_DIR="$(dirname "$E2E_SCRIPT_DIR")"
E2E_RU_SCRIPT="$E2E_PROJECT_DIR/ru"

# Source the base test framework
# shellcheck source=test_framework.sh
source "$E2E_SCRIPT_DIR/test_framework.sh"

#==============================================================================
# E2E Configuration
#==============================================================================

# E2E temp directory (managed separately from TF_TEMP_DIRS for clarity)
E2E_TEMP_DIR=""

# Original PATH (saved for restoration)
E2E_ORIGINAL_PATH="${PATH:-}"

# Mock bin directory (for gh, claude, etc.)
E2E_MOCK_BIN=""

# E2E log directory for detailed operation logs
E2E_LOG_DIR=""

#==============================================================================
# E2E Structured Logging
#==============================================================================
# Extends test_framework.sh logging with E2E-specific events

# Log E2E operation start
# Usage: e2e_log_operation "operation_name" "description"
e2e_log_operation() {
    local operation="$1"
    local description="${2:-}"
    local phase="${3:-execute}"

    log_debug "E2E [$phase]: $operation - $description"

    if is_json_mode; then
        _json_log "e2e_operation" \
            "operation" "$operation" \
            "phase" "$phase" \
            "description" "$description"
    fi
}

# Log E2E operation result
# Usage: e2e_log_result "operation_name" "pass|fail" [duration_ms] [details]
e2e_log_result() {
    local operation="$1"
    local result="$2"
    local duration_ms="${3:-0}"
    local details="${4:-}"

    if [[ "$result" == "pass" ]]; then
        log_debug "E2E PASS: $operation (${duration_ms}ms)"
    else
        log_warn "E2E FAIL: $operation (${duration_ms}ms) - $details"
    fi

    if is_json_mode; then
        local extra_args=()
        [[ -n "$details" ]] && extra_args+=("details" "$details")
        # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0-4.3 compatibility with set -u
        _json_log "e2e_result" \
            "operation" "$operation" \
            "result" "$result" \
            "duration_ms" "$duration_ms" \
            ${extra_args[@]+"${extra_args[@]}"}
    fi
}

# Log E2E command execution
# Usage: e2e_log_command "command" exit_code [stdout_file] [stderr_file]
e2e_log_command() {
    local cmd="$1"
    local exit_code="$2"
    local stdout_file="${3:-}"
    local stderr_file="${4:-}"

    log_debug "E2E CMD [exit=$exit_code]: $cmd"

    if is_json_mode; then
        local stdout_preview="" stderr_preview=""
        if [[ -f "$stdout_file" ]]; then
            stdout_preview=$(head -c 500 "$stdout_file" 2>/dev/null | tr '\n' ' ')
        fi
        if [[ -f "$stderr_file" ]]; then
            stderr_preview=$(head -c 500 "$stderr_file" 2>/dev/null | tr '\n' ' ')
        fi
        _json_log "e2e_command" \
            "command" "$cmd" \
            "exit_code" "$exit_code" \
            "stdout_preview" "$stdout_preview" \
            "stderr_preview" "$stderr_preview"
    fi
}

#==============================================================================
# E2E Environment Setup
#==============================================================================

# Set up E2E test environment with XDG paths and mock bin
# Usage: e2e_setup
# Creates:
#   $E2E_TEMP_DIR/config  -> XDG_CONFIG_HOME
#   $E2E_TEMP_DIR/state   -> XDG_STATE_HOME
#   $E2E_TEMP_DIR/cache   -> XDG_CACHE_HOME
#   $E2E_TEMP_DIR/home    -> HOME
#   $E2E_TEMP_DIR/projects -> RU_PROJECTS_DIR
#   $E2E_TEMP_DIR/mock_bin -> prepended to PATH
e2e_setup() {
    e2e_log_operation "setup" "Creating E2E test environment" "setup"

    E2E_TEMP_DIR=$(mktemp -d)
    TF_TEMP_DIRS+=("$E2E_TEMP_DIR")

    # Create directory structure
    mkdir -p "$E2E_TEMP_DIR/config/ru/repos.d"
    mkdir -p "$E2E_TEMP_DIR/state/ru/logs"
    mkdir -p "$E2E_TEMP_DIR/cache/ru"
    mkdir -p "$E2E_TEMP_DIR/home"
    mkdir -p "$E2E_TEMP_DIR/projects"
    mkdir -p "$E2E_TEMP_DIR/mock_bin"

    # Set up log directory for this test run (export for mock helpers)
    E2E_LOG_DIR="$E2E_TEMP_DIR/test_logs"
    export E2E_LOG_DIR
    mkdir -p "$E2E_LOG_DIR"

    # Export environment
    export XDG_CONFIG_HOME="$E2E_TEMP_DIR/config"
    export XDG_STATE_HOME="$E2E_TEMP_DIR/state"
    export XDG_CACHE_HOME="$E2E_TEMP_DIR/cache"
    export HOME="$E2E_TEMP_DIR/home"
    export RU_PROJECTS_DIR="$E2E_TEMP_DIR/projects"
    export RU_CONFIG_DIR="$E2E_TEMP_DIR/config/ru"
    export RU_LOG_DIR="$E2E_TEMP_DIR/state/ru/logs"
    export RU_PARALLEL=1  # Force sequential mode for predictable output

    # Set up mock bin in PATH
    E2E_MOCK_BIN="$E2E_TEMP_DIR/mock_bin"
    export PATH="$E2E_MOCK_BIN:$E2E_ORIGINAL_PATH"

    # Set git config for test environment
    export GIT_AUTHOR_NAME="Test User"
    export GIT_AUTHOR_EMAIL="test@test.com"
    export GIT_COMMITTER_NAME="Test User"
    export GIT_COMMITTER_EMAIL="test@test.com"

    e2e_log_result "setup" "pass" 0 "E2E_TEMP_DIR=$E2E_TEMP_DIR"
}

# Clean up E2E test environment
# Usage: e2e_cleanup
e2e_cleanup() {
    e2e_log_operation "cleanup" "Cleaning up E2E test environment" "cleanup"

    # Restore original PATH
    export PATH="$E2E_ORIGINAL_PATH"

    # Clear environment variables
    unset RU_PROJECTS_DIR RU_CONFIG_DIR RU_LOG_DIR
    unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

    # Temp dir cleanup handled by test_framework.sh trap
    E2E_TEMP_DIR=""
    E2E_MOCK_BIN=""
    unset E2E_LOG_DIR

    e2e_log_result "cleanup" "pass"
}

# Get the E2E temp directory
# Usage: local temp=$(e2e_get_temp_dir)
e2e_get_temp_dir() {
    echo "$E2E_TEMP_DIR"
}

# Get the E2E log directory
# Usage: local log_dir=$(e2e_get_log_dir)
e2e_get_log_dir() {
    echo "$E2E_LOG_DIR"
}

#==============================================================================
# Mock gh CLI
#==============================================================================

# Create a mock gh CLI script
# Usage: e2e_create_mock_gh auth_exit_code graphql_response
# Example:
#   e2e_create_mock_gh 0 "$(e2e_graphql_response_with_items)"
e2e_create_mock_gh() {
    local auth_exit_code="${1:-0}"
    local graphql_json="${2:-{}}"

    e2e_log_operation "create_mock_gh" "auth_exit=$auth_exit_code" "setup"

    # Use absolute path to bash for mock script
    local bash_path
    bash_path=$(type -P bash)

    cat > "$E2E_MOCK_BIN/gh" <<MOCK_EOF
#!${bash_path}
set -uo pipefail

cmd="\${1:-}"
sub="\${2:-}"

# Log the call if E2E_LOG_DIR is set
if [[ -n "\${E2E_LOG_DIR:-}" ]]; then
    echo "\$(date -Iseconds) gh \$*" >> "\$E2E_LOG_DIR/gh_calls.log"
fi

if [[ "\$cmd" == "auth" && "\$sub" == "status" ]]; then
    if [[ $auth_exit_code -ne 0 ]]; then
        echo "You are not logged into any GitHub hosts." >&2
    fi
    exit $auth_exit_code
fi

if [[ "\$cmd" == "api" && "\$sub" == "graphql" ]]; then
    cat <<'GRAPHQL_JSON'
$graphql_json
GRAPHQL_JSON
    exit 0
fi

# Default fallback for unhandled commands
echo "mock gh: unhandled args: \$*" >&2
exit 2
MOCK_EOF

    chmod +x "$E2E_MOCK_BIN/gh"
    e2e_log_result "create_mock_gh" "pass"
}

# Create mock gh with custom handler function
# Usage: e2e_create_mock_gh_custom handler_script
# handler_script receives all gh args and should echo response + exit appropriately
e2e_create_mock_gh_custom() {
    local handler_script="$1"

    e2e_log_operation "create_mock_gh_custom" "Custom handler" "setup"

    local bash_path
    bash_path=$(type -P bash)

    cat > "$E2E_MOCK_BIN/gh" <<MOCK_EOF
#!${bash_path}
set -uo pipefail

# Log the call
if [[ -n "\${E2E_LOG_DIR:-}" ]]; then
    echo "\$(date -Iseconds) gh \$*" >> "\$E2E_LOG_DIR/gh_calls.log"
fi

$handler_script
MOCK_EOF

    chmod +x "$E2E_MOCK_BIN/gh"
    e2e_log_result "create_mock_gh_custom" "pass"
}

#==============================================================================
# Mock ntm/tmux CLIs
#==============================================================================

# Create mock ntm/tmux scripts in the E2E mock bin
# Usage: e2e_create_mock_ntm [scenario]
# Scenario defaults to "ok" (see scripts/test_bin/ntm for options)
e2e_create_mock_ntm() {
    local scenario="${1:-ok}"

    e2e_log_operation "create_mock_ntm" "scenario=$scenario" "setup"

    local source_dir="$E2E_PROJECT_DIR/scripts/test_bin"
    local ntm_src="$source_dir/ntm"
    local tmux_src="$source_dir/tmux"

    if [[ ! -f "$ntm_src" || ! -f "$tmux_src" ]]; then
        e2e_log_result "create_mock_ntm" "fail" 0 "missing mock scripts"
        return 1
    fi

    cp "$ntm_src" "$E2E_MOCK_BIN/ntm"
    cp "$tmux_src" "$E2E_MOCK_BIN/tmux"
    chmod +x "$E2E_MOCK_BIN/ntm" "$E2E_MOCK_BIN/tmux"

    export NTM_MOCK_SCENARIO="$scenario"
    export NTM_MOCK_STATE_FILE="$E2E_TEMP_DIR/ntm_mock_state"
    export NTM_MOCK_LAST_PROMPT="$E2E_TEMP_DIR/ntm_mock_last_prompt"

    e2e_log_result "create_mock_ntm" "pass"
}

#==============================================================================
# GraphQL Response Generators
#==============================================================================

# Generate GraphQL response with issues and PRs
# Usage: local json=$(e2e_graphql_response_with_items [repo_count])
e2e_graphql_response_with_items() {
    local repo_count="${1:-1}"
    local response='{"data":{'
    local i

    for ((i=0; i<repo_count; i++)); do
        [[ $i -gt 0 ]] && response+=','
        response+="\"repo$i\":$(e2e_graphql_repo_with_items "owner/repo$i")"
    done

    response+='}}'
    echo "$response"
}

# Generate GraphQL response with empty results
# Usage: local json=$(e2e_graphql_response_empty [repo_count])
e2e_graphql_response_empty() {
    local repo_count="${1:-1}"
    local response='{"data":{'
    local i

    for ((i=0; i<repo_count; i++)); do
        [[ $i -gt 0 ]] && response+=','
        response+="\"repo$i\":$(e2e_graphql_repo_empty "owner/repo$i")"
    done

    response+='}}'
    echo "$response"
}

# Generate a single repo with issues/PRs
# Usage: local json=$(e2e_graphql_repo_with_items "owner/repo")
e2e_graphql_repo_with_items() {
    local repo_name="${1:-owner/repo}"
    cat <<REPO_JSON
{
  "nameWithOwner": "$repo_name",
  "isArchived": false,
  "isFork": false,
  "updatedAt": "2026-01-01T00:00:00Z",
  "issues": {
    "nodes": [
      {
        "number": 42,
        "title": "Test issue",
        "createdAt": "2025-12-01T00:00:00Z",
        "updatedAt": "2026-01-02T00:00:00Z",
        "labels": { "nodes": [ { "name": "bug" } ] }
      }
    ]
  },
  "pullRequests": {
    "nodes": [
      {
        "number": 7,
        "title": "Test PR",
        "createdAt": "2025-12-15T00:00:00Z",
        "updatedAt": "2026-01-03T00:00:00Z",
        "isDraft": false,
        "labels": { "nodes": [ { "name": "enhancement" } ] }
      }
    ]
  }
}
REPO_JSON
}

# Generate a single repo with empty issues/PRs
# Usage: local json=$(e2e_graphql_repo_empty "owner/repo")
e2e_graphql_repo_empty() {
    local repo_name="${1:-owner/repo}"
    cat <<REPO_JSON
{
  "nameWithOwner": "$repo_name",
  "isArchived": false,
  "isFork": false,
  "updatedAt": "2026-01-01T00:00:00Z",
  "issues": { "nodes": [] },
  "pullRequests": { "nodes": [] }
}
REPO_JSON
}

# Generate GraphQL error response
# Usage: local json=$(e2e_graphql_error "error message")
e2e_graphql_error() {
    local message="${1:-GraphQL error}"
    cat <<ERROR_JSON
{
  "errors": [
    {
      "message": "$message",
      "type": "ERROR"
    }
  ]
}
ERROR_JSON
}

#==============================================================================
# E2E Assertion Helpers
#==============================================================================

# Assert ru command exits with expected code
# Usage: e2e_assert_ru_exit expected_code "args" "message"
# Captures output to $E2E_LOG_DIR for debugging
e2e_assert_ru_exit() {
    local expected_code="$1"
    local ru_args="$2"
    local msg="$3"

    local stdout_file="$E2E_LOG_DIR/ru_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/ru_stderr.txt"
    local actual_code=0

    # Run ru with args (word-split intentionally for args)
    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" $ru_args >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    e2e_log_command "ru $ru_args" "$actual_code" "$stdout_file" "$stderr_file"

    if [[ "$expected_code" -eq "$actual_code" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "exit code $expected_code" "exit code $actual_code"
        # Show output on failure
        log_debug "STDOUT: $(cat "$stdout_file" 2>/dev/null)"
        log_debug "STDERR: $(cat "$stderr_file" 2>/dev/null)"
        return 1
    fi
}

# Assert ru JSON output matches jq filter
# Usage: e2e_assert_ru_json "args" ".filter" "expected" "message"
e2e_assert_ru_json() {
    local ru_args="$1"
    local jq_filter="$2"
    local expected="$3"
    local msg="$4"

    local stdout_file="$E2E_LOG_DIR/ru_stdout.json"
    local stderr_file="$E2E_LOG_DIR/ru_stderr.txt"
    local actual_code=0

    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" $ru_args >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    e2e_log_command "ru $ru_args" "$actual_code" "$stdout_file" "$stderr_file"

    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 0
    fi

    local actual
    actual=$(jq -r "$jq_filter" "$stdout_file" 2>/dev/null || echo "__JQ_ERROR__")

    if [[ "$actual" == "$expected" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "$expected" "$actual"
        return 1
    fi
}

# Assert ru stdout contains text
# Usage: e2e_assert_ru_stdout_contains "args" "pattern" "message"
e2e_assert_ru_stdout_contains() {
    local ru_args="$1"
    local pattern="$2"
    local msg="$3"

    local stdout_file="$E2E_LOG_DIR/ru_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/ru_stderr.txt"

    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" $ru_args >"$stdout_file" 2>"$stderr_file" || true

    if grep -q "$pattern" "$stdout_file"; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "stdout containing '$pattern'" "$(head -c 200 "$stdout_file")"
        return 1
    fi
}

# Assert ru stderr contains text
# Usage: e2e_assert_ru_stderr_contains "args" "pattern" "message"
e2e_assert_ru_stderr_contains() {
    local ru_args="$1"
    local pattern="$2"
    local msg="$3"

    local stdout_file="$E2E_LOG_DIR/ru_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/ru_stderr.txt"

    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" $ru_args >"$stdout_file" 2>"$stderr_file" || true

    if grep -q "$pattern" "$stderr_file"; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "stderr containing '$pattern'" "$(head -c 200 "$stderr_file")"
        return 1
    fi
}

#==============================================================================
# E2E Helper Functions
#==============================================================================

# Initialize ru config (runs ru init)
# Usage: e2e_init_ru [--example]
e2e_init_ru() {
    local args="${1:-}"
    e2e_log_operation "init_ru" "Initializing ru config" "setup"

    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" init $args >/dev/null 2>&1
    local result=$?

    e2e_log_result "init_ru" "$([[ $result -eq 0 ]] && echo "pass" || echo "fail")"
    return $result
}

# Add repo to ru config
# Usage: e2e_add_repo "owner/repo" [--private]
e2e_add_repo() {
    local repo="$1"
    local flags="${2:-}"

    e2e_log_operation "add_repo" "Adding $repo" "setup"

    # shellcheck disable=SC2086
    "$E2E_RU_SCRIPT" add "$repo" $flags >/dev/null 2>&1
    local result=$?

    e2e_log_result "add_repo" "$([[ $result -eq 0 ]] && echo "pass" || echo "fail")"
    return $result
}

# Create minimal PATH with only essential commands (for driver isolation tests)
# Usage: e2e_make_minimal_path_bin "$output_dir"
# Creates symlinks to essential commands, excluding tmux/ntm/claude
e2e_make_minimal_path_bin() {
    local out_dir="$1"

    mkdir -p "$out_dir"

    # Essential commands needed by ru during operation
    local -a cmds=(
        awk basename cat cut date dirname grep head jq kill ln mkdir mktemp rmdir sleep
        printf pwd rm sed sort tr uniq wc
    )

    local cmd bin
    for cmd in "${cmds[@]}"; do
        bin=$(type -P "$cmd" 2>/dev/null || echo "")
        [[ -n "$bin" ]] || continue
        ln -sf "$bin" "$out_dir/$cmd" 2>/dev/null || true
    done
}

# Save test artifacts on failure
# Usage: e2e_preserve_on_failure
# Call this in test teardown when test failed
e2e_preserve_on_failure() {
    if [[ $TF_ASSERTIONS_FAILED -gt 0 && -n "$E2E_TEMP_DIR" ]]; then
        preserve_failed_artifacts "$TF_CURRENT_TEST" "$E2E_TEMP_DIR"
    fi
}

#==============================================================================
# Backward Compatibility
#==============================================================================
# These functions match the old inline E2E framework signatures
# for easier migration of existing tests

# Legacy setup function (alias for e2e_setup)
setup_test_env() {
    e2e_setup
    # Also set legacy variable for compatibility
    # shellcheck disable=SC2034
    TEMP_DIR="$E2E_TEMP_DIR"
}

# Legacy cleanup function (alias for e2e_cleanup)
cleanup_test_env() {
    e2e_cleanup
}

# Legacy mock gh creation (alias)
create_mock_gh() {
    e2e_create_mock_gh "$@"
}

# Legacy graphql response (alias)
graphql_response_with_items() {
    e2e_graphql_repo_with_items "${1:-owner/repo}"
}

# Legacy graphql empty (alias)
graphql_response_empty() {
    e2e_graphql_repo_empty "${1:-owner/repo}"
}

#==============================================================================
# Exports
#==============================================================================

export E2E_SCRIPT_DIR E2E_PROJECT_DIR E2E_RU_SCRIPT
export -f e2e_setup e2e_cleanup e2e_get_temp_dir e2e_get_log_dir
export -f e2e_log_operation e2e_log_result e2e_log_command
export -f e2e_create_mock_gh e2e_create_mock_gh_custom
export -f e2e_create_mock_ntm
export -f e2e_graphql_response_with_items e2e_graphql_response_empty
export -f e2e_graphql_repo_with_items e2e_graphql_repo_empty e2e_graphql_error
export -f e2e_assert_ru_exit e2e_assert_ru_json
export -f e2e_assert_ru_stdout_contains e2e_assert_ru_stderr_contains
export -f e2e_init_ru e2e_add_repo e2e_make_minimal_path_bin
export -f e2e_preserve_on_failure
# Legacy exports for backward compatibility
export -f setup_test_env cleanup_test_env create_mock_gh
export -f graphql_response_with_items graphql_response_empty
