#!/usr/bin/env bash
#
# test_framework.sh - Assertion library and test utilities for ru
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"
#
#   test_my_feature() {
#       assert_equals "expected" "$actual" "Values should match"
#       assert_exit_code 0 some_command "Command should succeed"
#   }
#
#   run_test test_my_feature
#   print_results
#
# Features:
#   - Comprehensive assertion library
#   - Pass/fail counters with descriptive messages
#   - Test isolation helpers (temp dirs, cleanup traps)
#   - Sources cleanly from other test scripts
#
# shellcheck disable=SC2034  # Variables are used by sourcing scripts

set -uo pipefail

#==============================================================================
# Configuration
#==============================================================================

# Colors (respects NO_COLOR environment variable)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly TF_RED=$'\033[0;31m'
    readonly TF_GREEN=$'\033[0;32m'
    readonly TF_YELLOW=$'\033[0;33m'
    readonly TF_BLUE=$'\033[0;34m'
    readonly TF_BOLD=$'\033[1m'
    readonly TF_RESET=$'\033[0m'
else
    readonly TF_RED=''
    readonly TF_GREEN=''
    readonly TF_YELLOW=''
    readonly TF_BLUE=''
    readonly TF_BOLD=''
    readonly TF_RESET=''
fi

# Test counters
TF_TESTS_PASSED=0
TF_TESTS_FAILED=0
TF_TESTS_SKIPPED=0
TF_ASSERTIONS_PASSED=0
TF_ASSERTIONS_FAILED=0
TF_CURRENT_TEST=""
TF_TEST_WAS_SKIPPED="false"  # Flag for skip_test to communicate with run_test

# Temp directory management
TF_TEMP_DIRS=()

#==============================================================================
# Structured Logging
#==============================================================================

# Log levels (lower = more verbose)
readonly TF_LOG_DEBUG=0
readonly TF_LOG_INFO=1
readonly TF_LOG_WARN=2
readonly TF_LOG_ERROR=3
readonly TF_LOG_NONE=4

# Current log level (default: INFO)
TF_LOG_LEVEL="${TF_LOG_LEVEL:-1}"

# Optional log file (set to enable file logging)
TF_LOG_FILE="${TF_LOG_FILE:-}"

# Test start time (for duration tracking)
TF_TEST_START_TIME=""

# Get ISO-8601 timestamp
_tf_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get elapsed time since test start (in ms)
# Note: On macOS/BSD, nanoseconds aren't supported, so we fall back to seconds
_tf_elapsed_ms() {
    if [[ -n "$TF_TEST_START_TIME" ]]; then
        local now
        now=$(date +%s%N 2>/dev/null)
        # Check if nanoseconds are supported (macOS returns literal %N)
        if [[ "$now" =~ %N$ || -z "$now" ]]; then
            # Fall back to seconds-based timing
            local now_sec end_sec
            now_sec=$(date +%s)
            # TF_TEST_START_TIME might be in nanoseconds or seconds format
            if [[ ${#TF_TEST_START_TIME} -gt 12 ]]; then
                # Nanoseconds format - extract seconds part
                end_sec=${TF_TEST_START_TIME:0:10}
            else
                end_sec=$TF_TEST_START_TIME
            fi
            echo $(( (now_sec - end_sec) * 1000 ))
        elif [[ "$TF_TEST_START_TIME" != "0" ]]; then
            echo $(( (now - TF_TEST_START_TIME) / 1000000 ))
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Internal log function
# Usage: _tf_log level prefix message
_tf_log() {
    local level="$1"
    local prefix="$2"
    local msg="$3"
    local color="${4:-}"

    # Check log level
    if [[ "$level" -lt "$TF_LOG_LEVEL" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(_tf_timestamp)
    local formatted_msg="[$timestamp] $prefix: $msg"

    # Write to stderr with optional color
    if [[ -n "$color" ]]; then
        echo "${color}${formatted_msg}${TF_RESET}" >&2
    else
        echo "$formatted_msg" >&2
    fi

    # Write to log file if configured
    if [[ -n "$TF_LOG_FILE" ]]; then
        echo "$formatted_msg" >> "$TF_LOG_FILE"
    fi
}

# Log a debug message
log_debug() {
    _tf_log "$TF_LOG_DEBUG" "DEBUG" "$1" "$TF_BLUE"
}

# Log an info message
log_info() {
    _tf_log "$TF_LOG_INFO" "INFO" "$1"
}

# Log a warning message
log_warn() {
    _tf_log "$TF_LOG_WARN" "WARN" "$1" "$TF_YELLOW"
}

# Log an error message
log_error() {
    _tf_log "$TF_LOG_ERROR" "ERROR" "$1" "$TF_RED"
}

# Log test start - called at beginning of each test
# Usage: log_test_start "test_name"
log_test_start() {
    local test_name="$1"
    # Try nanoseconds first, fall back to seconds (for macOS)
    TF_TEST_START_TIME=$(date +%s%N 2>/dev/null)
    if [[ "$TF_TEST_START_TIME" =~ %N$ || -z "$TF_TEST_START_TIME" ]]; then
        TF_TEST_START_TIME=$(date +%s)
    fi
    _tf_log "$TF_LOG_INFO" "TEST" "Starting: $test_name" "$TF_BOLD"
}

# Log test pass - called when test succeeds
# Usage: log_test_pass "test_name"
log_test_pass() {
    local test_name="$1"
    local elapsed
    elapsed=$(_tf_elapsed_ms)
    _tf_log "$TF_LOG_INFO" "PASS" "$test_name (${elapsed}ms)" "$TF_GREEN"
    TF_TEST_START_TIME=""
}

# Log test fail - called when test fails
# Usage: log_test_fail "test_name" "reason"
log_test_fail() {
    local test_name="$1"
    local reason="${2:-}"
    local elapsed
    elapsed=$(_tf_elapsed_ms)
    if [[ -n "$reason" ]]; then
        _tf_log "$TF_LOG_ERROR" "FAIL" "$test_name (${elapsed}ms): $reason" "$TF_RED"
    else
        _tf_log "$TF_LOG_ERROR" "FAIL" "$test_name (${elapsed}ms)" "$TF_RED"
    fi
    TF_TEST_START_TIME=""
}

# Log test skip - called when test is skipped
# Usage: log_test_skip "test_name" "reason"
log_test_skip() {
    local test_name="$1"
    local reason="${2:-}"
    if [[ -n "$reason" ]]; then
        _tf_log "$TF_LOG_WARN" "SKIP" "$test_name: $reason" "$TF_YELLOW"
    else
        _tf_log "$TF_LOG_WARN" "SKIP" "$test_name" "$TF_YELLOW"
    fi
}

# Log suite start - called at beginning of test suite
# Usage: log_suite_start "Suite Name"
log_suite_start() {
    local suite_name="$1"
    if ! is_tap_mode; then
        echo ""
        echo "${TF_BOLD}============================================${TF_RESET}"
        echo "${TF_BOLD}Test Suite: $suite_name${TF_RESET}"
        echo "${TF_BOLD}============================================${TF_RESET}"
    else
        tap_diag "Test Suite: $suite_name"
    fi
}

# Initialize log file
# Usage: init_log_file "/path/to/log"
init_log_file() {
    TF_LOG_FILE="$1"
    local log_dir
    log_dir=$(dirname "$TF_LOG_FILE")
    mkdir -p "$log_dir"
    echo "# Test log started at $(_tf_timestamp)" > "$TF_LOG_FILE"
}

# Set log level
# Usage: set_log_level debug|info|warn|error|none
set_log_level() {
    case "${1,,}" in
        debug) TF_LOG_LEVEL=$TF_LOG_DEBUG ;;
        info)  TF_LOG_LEVEL=$TF_LOG_INFO ;;
        warn)  TF_LOG_LEVEL=$TF_LOG_WARN ;;
        error) TF_LOG_LEVEL=$TF_LOG_ERROR ;;
        none)  TF_LOG_LEVEL=$TF_LOG_NONE ;;
        *)     log_warn "Unknown log level: $1" ;;
    esac
}

#==============================================================================
# TAP (Test Anything Protocol) Output
#==============================================================================
# TAP format enables integration with prove, tap-junit, GitHub Actions, etc.
# See: https://testanything.org/

# TAP mode toggle (set via enable_tap_output or TF_TAP_MODE env var)
TF_TAP_MODE="${TF_TAP_MODE:-false}"

# TAP test counter (for numbering test lines)
TF_TAP_TEST_NUM=0

# TAP planned test count (for 1..N header)
TF_TAP_PLAN_COUNT=0

# Enable TAP output mode
# Usage: enable_tap_output
enable_tap_output() {
    TF_TAP_MODE="true"
    TF_TAP_TEST_NUM=0
}

# Disable TAP output mode (back to human-readable)
# Usage: disable_tap_output
disable_tap_output() {
    TF_TAP_MODE="false"
}

# Check if TAP mode is enabled
# Usage: if is_tap_mode; then ...; fi
is_tap_mode() {
    [[ "$TF_TAP_MODE" == "true" ]]
}

# Output TAP plan header
# Usage: tap_plan 5    # Outputs: 1..5
# Call this BEFORE running tests to declare expected test count
tap_plan() {
    local count="$1"
    TF_TAP_PLAN_COUNT="$count"
    if is_tap_mode; then
        echo "1..$count"
    fi
}

# Output TAP version header (optional, TAP 13+)
# Usage: tap_version
tap_version() {
    if is_tap_mode; then
        echo "TAP version 13"
    fi
}

# Output TAP diagnostic comment
# Usage: tap_diag "Some diagnostic message"
tap_diag() {
    local msg="$1"
    if is_tap_mode; then
        echo "# $msg"
    fi
}

# Output TAP ok line (internal use - called by run_test)
# Usage: _tap_ok test_name [directive]
_tap_ok() {
    local test_name="$1"
    local directive="${2:-}"
    ((TF_TAP_TEST_NUM++))
    if [[ -n "$directive" ]]; then
        echo "ok $TF_TAP_TEST_NUM - $test_name # $directive"
    else
        echo "ok $TF_TAP_TEST_NUM - $test_name"
    fi
}

# Output TAP not ok line (internal use - called by run_test)
# Usage: _tap_not_ok test_name [reason]
_tap_not_ok() {
    local test_name="$1"
    local reason="${2:-}"
    ((TF_TAP_TEST_NUM++))
    echo "not ok $TF_TAP_TEST_NUM - $test_name"
    if [[ -n "$reason" ]]; then
        echo "# $reason"
    fi
}

# Output TAP skip line
# Usage: _tap_skip test_name reason
_tap_skip() {
    local test_name="$1"
    local reason="${2:-}"
    ((TF_TAP_TEST_NUM++))
    if [[ -n "$reason" ]]; then
        echo "ok $TF_TAP_TEST_NUM - $test_name # SKIP $reason"
    else
        echo "ok $TF_TAP_TEST_NUM - $test_name # SKIP"
    fi
}

# Output TAP todo line (test expected to fail)
# Usage: _tap_todo test_name reason
_tap_todo() {
    local test_name="$1"
    local reason="${2:-}"
    ((TF_TAP_TEST_NUM++))
    echo "not ok $TF_TAP_TEST_NUM - $test_name # TODO $reason"
}

# Print TAP summary (called by print_results when in TAP mode)
_tap_summary() {
    tap_diag ""
    tap_diag "Tests: $TF_TESTS_PASSED passed, $TF_TESTS_FAILED failed, $TF_TESTS_SKIPPED skipped"
    tap_diag "Assertions: $TF_ASSERTIONS_PASSED passed, $TF_ASSERTIONS_FAILED failed"
    if [[ $TF_TAP_PLAN_COUNT -gt 0 && $TF_TAP_TEST_NUM -ne $TF_TAP_PLAN_COUNT ]]; then
        tap_diag "WARNING: Planned $TF_TAP_PLAN_COUNT tests but ran $TF_TAP_TEST_NUM"
    fi
}

#==============================================================================
# JSON Logging (Machine-Readable Output)
#==============================================================================
# Structured JSON logging for automated test result aggregation.
# Enable with TF_JSON_LOG_FILE or enable_json_output.
# JSON lines format (one JSON object per line) for easy parsing with jq.

# JSON log file path (set to enable JSON logging)
TF_JSON_LOG_FILE="${TF_JSON_LOG_FILE:-}"

# JSON mode toggle
TF_JSON_MODE="${TF_JSON_MODE:-false}"

# Current test context for JSON output
TF_JSON_SUITE_NAME=""
TF_JSON_TEST_CONTEXT="{}"

# Enable JSON output mode
# Usage: enable_json_output ["/path/to/log.jsonl"]
enable_json_output() {
    TF_JSON_MODE="true"
    if [[ -n "${1:-}" ]]; then
        TF_JSON_LOG_FILE="$1"
        local log_dir
        log_dir=$(dirname "$TF_JSON_LOG_FILE")
        mkdir -p "$log_dir"
    fi
}

# Disable JSON output mode
disable_json_output() {
    TF_JSON_MODE="false"
}

# Check if JSON mode is enabled
is_json_mode() {
    [[ "$TF_JSON_MODE" == "true" || -n "$TF_JSON_LOG_FILE" ]]
}

# Escape string for JSON (handles quotes, backslashes, newlines, tabs)
# Usage: escaped=$(_json_escape "string with \"quotes\"")
_json_escape() {
    local s="$1"
    # Escape backslashes first, then other special chars
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Get microsecond-precision timestamp (falls back to millisecond/second)
_json_timestamp_us() {
    local ts
    ts=$(date +%s%N 2>/dev/null)
    if [[ "$ts" =~ %N$ || -z "$ts" ]]; then
        # Fall back to seconds with fake microseconds
        ts=$(date +%s)000000
    fi
    echo "$ts"
}

# Calculate elapsed time in microseconds
# Usage: elapsed=$(_json_elapsed_us "$start_time_us")
_json_elapsed_us() {
    local start="$1"
    local now
    now=$(_json_timestamp_us)
    if [[ ${#start} -gt 12 && ${#now} -gt 12 ]]; then
        # Nanoseconds - convert to microseconds
        echo $(( (now - start) / 1000 ))
    else
        # Seconds - convert to microseconds
        echo $(( (now - start) * 1000000 ))
    fi
}

# Get current git state for environment snapshot
_json_git_state() {
    local git_info="{}"
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        local branch commit dirty
        branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
        branch=$(_json_escape "$branch")
        commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        dirty="false"
        if ! git diff --quiet 2>/dev/null; then
            dirty="true"
        fi
        git_info="{\"branch\":\"$branch\",\"commit\":\"$commit\",\"dirty\":$dirty}"
    fi
    echo "$git_info"
}

# Get environment snapshot (selected env vars)
_json_env_snapshot() {
    local env_vars=""
    local vars_to_capture=(
        "RU_PROJECTS_DIR" "RU_CONFIG_DIR" "RU_LOG_DIR"
        "XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME"
        "TF_LOG_LEVEL" "TF_TAP_MODE" "TF_JSON_MODE"
    )
    for var in "${vars_to_capture[@]}"; do
        local val="${!var:-}"
        if [[ -n "$val" ]]; then
            val=$(_json_escape "$val")
            if [[ -n "$env_vars" ]]; then
                env_vars+=","
            fi
            env_vars+="\"$var\":\"$val\""
        fi
    done
    echo "{$env_vars}"
}

# Get simple stack trace (function call chain)
_json_stack_trace() {
    local trace=""
    local i
    for ((i=2; i<${#FUNCNAME[@]}; i++)); do
        local func="${FUNCNAME[$i]:-main}"
        local line="${BASH_LINENO[$((i-1))]:-0}"
        local src="${BASH_SOURCE[$i]:-unknown}"
        src=$(basename "$src")
        if [[ -n "$trace" ]]; then
            trace+=","
        fi
        trace+="{\"function\":\"$func\",\"line\":$line,\"file\":\"$src\"}"
    done
    echo "[$trace]"
}

# Write a JSON log entry
# Usage: _json_log "event_type" "key1" "val1" "key2" "val2" ...
_json_log() {
    if ! is_json_mode; then
        return 0
    fi

    local event_type="$1"
    shift

    local timestamp
    timestamp=$(_tf_timestamp)
    local json="{\"timestamp\":\"$timestamp\",\"event\":\"$event_type\""

    # Add test context if available
    if [[ -n "$TF_CURRENT_TEST" ]]; then
        json+=",\"test_name\":\"$TF_CURRENT_TEST\""
    fi
    if [[ -n "$TF_JSON_SUITE_NAME" ]]; then
        json+=",\"suite_name\":\"$TF_JSON_SUITE_NAME\""
    fi
    # Add custom test context if set (not empty object)
    if [[ -n "$TF_JSON_TEST_CONTEXT" && "$TF_JSON_TEST_CONTEXT" != "{}" ]]; then
        json+=",\"context\":$TF_JSON_TEST_CONTEXT"
    fi

    # Add key-value pairs
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2

        # Detect type: number, boolean, or string
        if [[ "$val" =~ ^-?[0-9]+$ ]]; then
            json+=",\"$key\":$val"
        elif [[ "$val" == "true" || "$val" == "false" ]]; then
            json+=",\"$key\":$val"
        elif [[ "$val" == "null" ]]; then
            json+=",\"$key\":null"
        elif [[ "$val" =~ ^\{.*\}$ || "$val" =~ ^\[.*\]$ ]]; then
            # Raw JSON object/array
            json+=",\"$key\":$val"
        else
            val=$(_json_escape "$val")
            json+=",\"$key\":\"$val\""
        fi
    done

    json+="}"

    # Write to JSON log file
    if [[ -n "$TF_JSON_LOG_FILE" ]]; then
        echo "$json" >> "$TF_JSON_LOG_FILE"
    fi

    # Also write to stdout if JSON mode is primary output
    if [[ "$TF_JSON_MODE" == "true" ]]; then
        echo "$json"
    fi
}

# Log test suite start (JSON)
# Usage: log_suite_json "Suite Name"
log_suite_json() {
    local suite_name="$1"
    TF_JSON_SUITE_NAME="$suite_name"
    local git_state env_snapshot
    git_state=$(_json_git_state)
    env_snapshot=$(_json_env_snapshot)
    # Note: suite_name is also added by _json_log when TF_JSON_SUITE_NAME is set
    _json_log "suite_start" \
        "git" "$git_state" \
        "environment" "$env_snapshot"
}

# Log test suite end (JSON)
# Usage: log_suite_end_json
log_suite_end_json() {
    _json_log "suite_end" \
        "tests_passed" "$TF_TESTS_PASSED" \
        "tests_failed" "$TF_TESTS_FAILED" \
        "tests_skipped" "$TF_TESTS_SKIPPED" \
        "assertions_passed" "$TF_ASSERTIONS_PASSED" \
        "assertions_failed" "$TF_ASSERTIONS_FAILED"
    TF_JSON_SUITE_NAME=""
}

# Log test start (JSON)
# Usage: log_test_start_json
# Note: test_name is automatically included via TF_CURRENT_TEST in _json_log
log_test_start_json() {
    _json_log "test_start" \
        "phase" "execute"
}

# Log test result (JSON)
# Usage: log_test_result_json "pass|fail|skip" duration_ms ["reason"]
log_test_result_json() {
    local result="$1"
    local duration_ms="$2"
    local reason="${3:-}"

    local extra_args=()
    if [[ -n "$reason" ]]; then
        extra_args+=("reason" "$reason")
    fi
    if [[ "$result" == "fail" ]]; then
        extra_args+=("stack_trace" "$(_json_stack_trace)")
    fi

    # Use ${arr[@]+"${arr[@]}"} pattern for Bash 4.0 compatibility with set -u
    _json_log "test_result" \
        "result" "$result" \
        "duration_ms" "$duration_ms" \
        ${extra_args[@]+"${extra_args[@]}"}
}

# Log assertion result (JSON)
# Usage: log_assertion_json "pass|fail" "message" ["expected"] ["actual"]
log_assertion_json() {
    local result="$1"
    local msg="$2"
    local expected="${3:-}"
    local actual="${4:-}"

    local extra_args=("message" "$msg")
    if [[ -n "$expected" ]]; then
        extra_args+=("expected" "$expected")
    fi
    if [[ -n "$actual" ]]; then
        extra_args+=("actual" "$actual")
    fi
    if [[ "$result" == "fail" ]]; then
        extra_args+=("stack_trace" "$(_json_stack_trace)")
    fi

    _json_log "assertion" \
        "result" "$result" \
        "${extra_args[@]}"
}

# Set custom test context (arbitrary key-value pairs for current test)
# Usage: set_test_context "key1" "val1" "key2" "val2"
set_test_context() {
    local ctx="{"
    local first=true
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2
        val=$(_json_escape "$val")
        if [[ "$first" == "true" ]]; then
            first=false
        else
            ctx+=","
        fi
        ctx+="\"$key\":\"$val\""
    done
    ctx+="}"
    TF_JSON_TEST_CONTEXT="$ctx"
}

# Clear test context
clear_test_context() {
    TF_JSON_TEST_CONTEXT="{}"
}

# Log a custom event with context
# Usage: log_event_json "event_name" "key1" "val1" ...
log_event_json() {
    local event_name="$1"
    shift
    _json_log "$event_name" "$@"
}

#==============================================================================
# Portable Utilities
#==============================================================================

# drop_last_lines - Remove the last N lines from input (portable alternative to head -n -N)
# BSD/macOS head doesn't support negative line counts, so we calculate the positive count.
# Usage: command | drop_last_lines 2  # Remove last 2 lines
drop_last_lines() {
    local n="${1:-1}"
    if [[ "$n" -lt 1 ]]; then
        cat
        return
    fi
    # Calculate total lines and use head with positive count
    local input
    input=$(cat)
    local total
    total=$(printf '%s\n' "$input" | wc -l | tr -d ' ')
    local keep=$((total - n))
    if [[ "$keep" -lt 1 ]]; then
        return 0  # Nothing to output
    fi
    printf '%s\n' "$input" | head -n "$keep"
}

#==============================================================================
# Core Assertion Functions
#==============================================================================

# Record a passing assertion
# Usage: _tf_pass "message"
_tf_pass() {
    local msg="$1"
    ((TF_ASSERTIONS_PASSED++))
    echo "${TF_GREEN}PASS${TF_RESET}: $msg"
    # JSON logging
    log_assertion_json "pass" "$msg"
}

# Convenience alias for _tf_pass (used in simple if/else test patterns)
# Usage: pass "message"
pass() {
    _tf_pass "$1"
}

# Convenience alias for _tf_fail (used in simple if/else test patterns)
# Usage: fail "message"
fail() {
    _tf_fail "$1"
}

# Record a failing assertion
# Usage: _tf_fail "message" ["expected"] ["actual"]
_tf_fail() {
    local msg="$1"
    local expected="${2:-}"
    local actual="${3:-}"
    ((TF_ASSERTIONS_FAILED++))
    echo "${TF_RED}FAIL${TF_RESET}: $msg"
    if [[ -n "$expected" ]]; then
        echo "       Expected: ${TF_BLUE}$expected${TF_RESET}"
    fi
    if [[ -n "$actual" ]]; then
        echo "       Actual:   ${TF_YELLOW}$actual${TF_RESET}"
    fi
    # JSON logging
    log_assertion_json "fail" "$msg" "$expected" "$actual"
}

# Assert two values are equal
# Usage: assert_equals "expected" "actual" "message"
assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "$expected" "$actual"
        return 1
    fi
}

# Assert two values are not equal
# Usage: assert_not_equals "unexpected" "actual" "message"
assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local msg="${3:-Values should not be equal}"

    if [[ "$unexpected" != "$actual" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "not '$unexpected'" "$actual"
        return 1
    fi
}

# Assert string contains substring
# Usage: assert_contains "haystack" "needle" "message"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "string containing '$needle'" "$haystack"
        return 1
    fi
}

# Assert string does not contain substring
# Usage: assert_not_contains "haystack" "needle" "message"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "string not containing '$needle'" "$haystack"
        return 1
    fi
}

# Assert command exits with expected code
# Usage: assert_exit_code expected_code message command [args...]
assert_exit_code() {
    local expected_code="$1"
    local msg="$2"
    shift 2

    # Run command and capture exit code
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?

    if [[ "$expected_code" -eq "$actual_code" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "exit code $expected_code" "exit code $actual_code"
        return 1
    fi
}

# Assert command succeeds (exit code 0)
# Usage: assert_success message command [args...]
assert_success() {
    local msg="$1"
    shift

    local exit_code=0
    "$@" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "exit code 0" "exit code $exit_code"
        return 1
    fi
}

# Assert command fails (non-zero exit code)
# Usage: assert_fails message command [args...]
assert_fails() {
    local msg="$1"
    shift

    local exit_code=0
    "$@" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "non-zero exit code" "exit code 0"
        return 1
    fi
}

# Assert file exists
# Usage: assert_file_exists "path" "message"
assert_file_exists() {
    local path="$1"
    local msg="${2:-File should exist: $path}"

    if [[ -f "$path" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "file exists" "file not found: $path"
        return 1
    fi
}

# Assert file does not exist
# Usage: assert_file_not_exists "path" "message"
assert_file_not_exists() {
    local path="$1"
    local msg="${2:-File should not exist: $path}"

    if [[ ! -f "$path" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "file does not exist" "file found: $path"
        return 1
    fi
}

# Assert directory exists
# Usage: assert_dir_exists "path" "message"
assert_dir_exists() {
    local path="$1"
    local msg="${2:-Directory should exist: $path}"

    if [[ -d "$path" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "directory exists" "directory not found: $path"
        return 1
    fi
}

# Assert directory does not exist
# Usage: assert_dir_not_exists "path" "message"
assert_dir_not_exists() {
    local path="$1"
    local msg="${2:-Directory should not exist: $path}"

    if [[ ! -d "$path" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "directory does not exist" "directory found: $path"
        return 1
    fi
}

# Assert value is not empty
# Usage: assert_not_empty "value" "message"
assert_not_empty() {
    local value="$1"
    local msg="${2:-Value should not be empty}"

    if [[ -n "$value" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "non-empty value" "(empty)"
        return 1
    fi
}

# Assert value is empty
# Usage: assert_empty "value" "message"
assert_empty() {
    local value="$1"
    local msg="${2:-Value should be empty}"

    if [[ -z "$value" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "(empty)" "$value"
        return 1
    fi
}

# Assert condition is true
# Usage: assert_true condition "message"
# Example: assert_true "[[ $x -gt 5 ]]" "X should be greater than 5"
assert_true() {
    local condition="$1"
    local msg="${2:-Condition should be true}"

    if eval "$condition"; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "condition true" "condition false: $condition"
        return 1
    fi
}

# Assert condition is false
# Usage: assert_false condition "message"
assert_false() {
    local condition="$1"
    local msg="${2:-Condition should be false}"

    if ! eval "$condition"; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "condition false" "condition true: $condition"
        return 1
    fi
}

# Assert string matches regex
# Usage: assert_matches "string" "pattern" "message"
assert_matches() {
    local string="$1"
    local pattern="$2"
    local msg="${3:-String should match pattern}"

    if [[ "$string" =~ $pattern ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "string matching /$pattern/" "$string"
        return 1
    fi
}

# Assert file contains text
# Usage: assert_file_contains "path" "text" "message"
assert_file_contains() {
    local path="$1"
    local text="$2"
    local msg="${3:-File should contain text}"

    if [[ ! -f "$path" ]]; then
        _tf_fail "$msg" "file containing '$text'" "file not found: $path"
        return 1
    fi

    if grep -q "$text" "$path"; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "file containing '$text'" "text not found in $path"
        return 1
    fi
}

#==============================================================================
# Test Isolation Helpers
#==============================================================================

# Current test environment root (set by create_test_env)
TF_TEST_ENV_ROOT=""

# Create a temporary directory for test isolation
# Usage: local temp_dir=$(create_temp_dir)
create_temp_dir() {
    local temp_dir
    temp_dir=$(mktemp -d)
    TF_TEMP_DIRS+=("$temp_dir")
    echo "$temp_dir"
}

# Clean up all temporary directories
cleanup_temp_dirs() {
    # Guard against empty array with set -u
    if [[ ${#TF_TEMP_DIRS[@]} -gt 0 ]]; then
        for dir in "${TF_TEMP_DIRS[@]}"; do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir"
            fi
        done
    fi
    TF_TEMP_DIRS=()
    TF_TEST_ENV_ROOT=""
}

# Set up cleanup trap
setup_cleanup_trap() {
    trap cleanup_temp_dirs EXIT
}

# Create a complete isolated test environment with XDG paths and git config
# Usage: local env_root=$(create_test_env)
# Sets up:
#   - $env_root/config (XDG_CONFIG_HOME)
#   - $env_root/state (XDG_STATE_HOME)
#   - $env_root/cache (XDG_CACHE_HOME)
#   - $env_root/projects (PROJECTS_DIR)
#   - Git config for test user
create_test_env() {
    local env_root
    env_root=$(create_temp_dir)
    TF_TEST_ENV_ROOT="$env_root"

    # Create XDG-compliant directory structure
    mkdir -p "$env_root/config/ru/repos.d"
    mkdir -p "$env_root/state/ru/logs"
    mkdir -p "$env_root/cache/ru"
    mkdir -p "$env_root/projects"

    # Set environment variables for ru
    export XDG_CONFIG_HOME="$env_root/config"
    export XDG_STATE_HOME="$env_root/state"
    export XDG_CACHE_HOME="$env_root/cache"
    export RU_PROJECTS_DIR="$env_root/projects"
    export RU_CONFIG_DIR="$env_root/config/ru"
    export RU_LOG_DIR="$env_root/state/ru/logs"

    # Set git config for test environment
    export GIT_AUTHOR_NAME="Test User"
    export GIT_AUTHOR_EMAIL="test@test.com"
    export GIT_COMMITTER_NAME="Test User"
    export GIT_COMMITTER_EMAIL="test@test.com"

    echo "$env_root"
}

# Get the current test environment root
get_test_env_root() {
    echo "$TF_TEST_ENV_ROOT"
}

# Reset environment to known state (clears all RU_* vars)
reset_test_env() {
    # Clear any test-related environment variables
    unset RU_PROJECTS_DIR RU_CONFIG_DIR RU_LOG_DIR
    unset RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH
    unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    cleanup_temp_dirs
}

#==============================================================================
# Test Runner
#==============================================================================

# Run a single test function
# Usage: run_test test_function_name
run_test() {
    local test_name="$1"
    local failed_before=$TF_ASSERTIONS_FAILED
    local test_start_us elapsed_us elapsed_ms

    TF_CURRENT_TEST="$test_name"
    TF_TEST_WAS_SKIPPED="false"  # Reset skip flag
    test_start_us=$(_json_timestamp_us)

    if ! is_tap_mode; then
        echo ""
        echo "${TF_BOLD}Running: $test_name${TF_RESET}"
        echo "----------------------------------------"
    fi

    # JSON: log test start (test_name comes from TF_CURRENT_TEST)
    log_test_start_json

    # Run the test
    if "$test_name"; then
        # Check if test was skipped (skip_test was called)
        if [[ "$TF_TEST_WAS_SKIPPED" == "true" ]]; then
            # Skip already handled by skip_test - don't double-count
            :
        elif [[ $TF_ASSERTIONS_FAILED -eq $failed_before ]]; then
            elapsed_us=$(_json_elapsed_us "$test_start_us")
            elapsed_ms=$((elapsed_us / 1000))
            ((TF_TESTS_PASSED++))
            if is_tap_mode; then
                _tap_ok "$test_name"
            else
                echo "${TF_GREEN}TEST PASSED${TF_RESET}: $test_name"
            fi
            # JSON: log test pass
            log_test_result_json "pass" "$elapsed_ms"
        else
            elapsed_us=$(_json_elapsed_us "$test_start_us")
            elapsed_ms=$((elapsed_us / 1000))
            ((TF_TESTS_FAILED++))
            if is_tap_mode; then
                _tap_not_ok "$test_name" "assertions failed"
            else
                echo "${TF_RED}TEST FAILED${TF_RESET}: $test_name"
            fi
            # JSON: log test fail
            log_test_result_json "fail" "$elapsed_ms" "assertions failed"
        fi
    else
        elapsed_us=$(_json_elapsed_us "$test_start_us")
        elapsed_ms=$((elapsed_us / 1000))
        ((TF_TESTS_FAILED++))
        if is_tap_mode; then
            _tap_not_ok "$test_name" "non-zero exit"
        else
            echo "${TF_RED}TEST FAILED${TF_RESET}: $test_name (non-zero exit)"
        fi
        # JSON: log test fail
        log_test_result_json "fail" "$elapsed_ms" "non-zero exit"
    fi

    TF_CURRENT_TEST=""
    TF_TEST_WAS_SKIPPED="false"
    clear_test_context
}

# Skip a test
# Usage: skip_test "reason"
skip_test() {
    local reason="${1:-}"
    ((TF_TESTS_SKIPPED++))
    TF_TEST_WAS_SKIPPED="true"  # Signal to run_test that test was skipped
    if is_tap_mode; then
        _tap_skip "$TF_CURRENT_TEST" "$reason"
    else
        echo "${TF_YELLOW}SKIP${TF_RESET}: $TF_CURRENT_TEST${reason:+ ($reason)}"
    fi
    # JSON: log test skip
    log_test_result_json "skip" "0" "$reason"
    return 0
}

# Require gh authentication for a test.
# Usage: require_gh_auth || return 0
# Env: TF_SKIP_GH_AUTH=1|true|yes to force skip
require_gh_auth() {
    local skip_flag="${TF_SKIP_GH_AUTH:-}"
    case "${skip_flag,,}" in
        1|true|yes)
            skip_test "TF_SKIP_GH_AUTH set"
            return 1
            ;;
    esac

    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 1
    fi

    if ! gh auth status &>/dev/null; then
        skip_test "gh not authenticated"
        return 1
    fi

    return 0
}

# Print test results summary
print_results() {
    if is_tap_mode; then
        _tap_summary
    else
        echo ""
        echo "============================================"
        echo "${TF_BOLD}Test Results${TF_RESET}"
        echo "============================================"
        echo "Tests:      ${TF_GREEN}$TF_TESTS_PASSED passed${TF_RESET}, ${TF_RED}$TF_TESTS_FAILED failed${TF_RESET}, ${TF_YELLOW}$TF_TESTS_SKIPPED skipped${TF_RESET}"
        echo "Assertions: ${TF_GREEN}$TF_ASSERTIONS_PASSED passed${TF_RESET}, ${TF_RED}$TF_ASSERTIONS_FAILED failed${TF_RESET}"
        echo "============================================"
    fi

    if [[ $TF_TESTS_FAILED -gt 0 || $TF_ASSERTIONS_FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Get exit code based on test results
get_exit_code() {
    if [[ $TF_TESTS_FAILED -gt 0 || $TF_ASSERTIONS_FAILED -gt 0 ]]; then
        echo 1
    else
        echo 0
    fi
}

#==============================================================================
# Parallel Test Execution
#==============================================================================
# Run multiple tests in parallel with proper isolation.
# Uses namespaced temp directories and aggregates results.

# Run tests in parallel
# Usage: run_parallel_tests [--jobs N] test_func1 test_func2 ...
# Returns aggregated results in TF_TESTS_PASSED/FAILED/SKIPPED
run_parallel_tests() {
    local max_jobs=""
    local tests=()

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --jobs|-j)
                max_jobs="$2"
                shift 2
                ;;
            -j[0-9]*)
                max_jobs="${1#-j}"
                shift
                ;;
            *)
                tests+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#tests[@]} -eq 0 ]]; then
        log_warn "run_parallel_tests: No tests provided"
        return 0
    fi

    # Default to 4 jobs or nproc
    max_jobs="${max_jobs:-$(nproc 2>/dev/null || echo 4)}"

    local tmpdir
    tmpdir=$(mktemp -d "/tmp/tf-parallel-XXXXXX")
    TF_TEMP_DIRS+=("$tmpdir")

    local pids=()
    local running_jobs=0
    local test_num=0

    log_info "Running ${#tests[@]} tests in parallel (max $max_jobs jobs)..."

    # Cleanup trap for interrupt handling
    # shellcheck disable=SC2317  # Function is invoked via trap
    _tf_parallel_cleanup() {
        log_warn "Parallel execution interrupted - cleaning up..."
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        rm -rf "$tmpdir"
    }
    trap _tf_parallel_cleanup INT TERM

    # Launch tests with throttling
    for test_name in "${tests[@]}"; do
        ((test_num++))
        local result_file="$tmpdir/result_$test_num"
        local test_tmpdir="$tmpdir/test_$test_num"

        # Wait if we've hit the job limit
        # Note: wait -n requires Bash 4.3+; use polling fallback for 4.0-4.2
        while [[ $running_jobs -ge $max_jobs ]]; do
            if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
                wait -n 2>/dev/null || true
            else
                # Fallback: brief sleep then recount (less efficient but compatible)
                sleep 0.1
            fi
            running_jobs=$(jobs -r | wc -l)
        done

        # Run test in subshell with isolated env
        # shellcheck disable=SC2030  # Variable modifications intentionally local to subshell
        (
            # Set up isolated temp directory for this test
            TF_TEMP_DIRS=()
            TF_CURRENT_TEST="$test_name"
            mkdir -p "$test_tmpdir"
            cd "$test_tmpdir" || exit 1

            # Reset counters for this test
            local passed_before=$TF_ASSERTIONS_PASSED
            local failed_before=$TF_ASSERTIONS_FAILED
            local test_result="pass"
            local exit_code=0

            # Run the test function
            if ! "$test_name"; then
                test_result="fail"
                exit_code=1
            elif [[ $TF_ASSERTIONS_FAILED -gt $failed_before ]]; then
                test_result="fail"
                exit_code=1
            fi

            # Write result to file
            printf '%s|%d|%d|%d|%d\n' \
                "$test_result" \
                "$exit_code" \
                "$((TF_ASSERTIONS_PASSED - passed_before))" \
                "$((TF_ASSERTIONS_FAILED - failed_before))" \
                0 > "$result_file"

            exit "$exit_code"
        ) &
        pids+=($!)
        ((running_jobs++))
    done

    # Wait for all jobs
    local any_failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            any_failed=1
        fi
    done

    # Reset trap to default
    trap - INT TERM

    # Aggregate results
    local total_passed=0 total_failed=0 total_assertions_passed=0 total_assertions_failed=0
    test_num=0
    for test_name in "${tests[@]}"; do
        ((test_num++))
        local result_file="$tmpdir/result_$test_num"
        if [[ -f "$result_file" ]]; then
            local result exit_code assertions_passed assertions_failed skipped
            IFS='|' read -r result exit_code assertions_passed assertions_failed skipped < "$result_file"
            if [[ "$result" == "pass" ]]; then
                ((total_passed++))
                echo "${TF_GREEN}PASS${TF_RESET}: $test_name (parallel)"
            else
                ((total_failed++))
                echo "${TF_RED}FAIL${TF_RESET}: $test_name (parallel)"
            fi
            ((total_assertions_passed += assertions_passed))
            ((total_assertions_failed += assertions_failed))
        else
            ((total_failed++))
            echo "${TF_RED}FAIL${TF_RESET}: $test_name (no result file)"
        fi
    done

    # Update global counters
    ((TF_TESTS_PASSED += total_passed))
    ((TF_TESTS_FAILED += total_failed))
    ((TF_ASSERTIONS_PASSED += total_assertions_passed))
    ((TF_ASSERTIONS_FAILED += total_assertions_failed))

    log_info "Parallel execution complete: $total_passed passed, $total_failed failed"

    # Cleanup temp dir
    rm -rf "$tmpdir"

    return $any_failed
}

#==============================================================================
# Utility Functions for ru Tests
#==============================================================================

# Get the project directory (parent of scripts/)
get_project_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

# Source a function from ru script by name
# Usage: source_ru_function "function_name"
# Note: Uses eval instead of source <(...) because process substitution
# breaks nameref bindings in Bash (namerefs don't work correctly when
# functions are sourced from a subshell).
source_ru_function() {
    local func_name="$1"
    local project_dir
    project_dir=$(get_project_dir)

    # Many ru functions rely on portable directory-lock helpers.
    # Load them once up front so unit tests don't need to manually list them.
    if [[ -z "${TF_RU_LOCKS_LOADED:-}" ]]; then
        local lock_body
        lock_body=$(sed -n '/^dir_lock_try_acquire()/,/^}/p' "$project_dir/ru")
        eval "$lock_body"
        lock_body=$(sed -n '/^dir_lock_release()/,/^}/p' "$project_dir/ru")
        eval "$lock_body"
        lock_body=$(sed -n '/^dir_lock_acquire()/,/^}/p' "$project_dir/ru")
        eval "$lock_body"
        TF_RU_LOCKS_LOADED="true"
    fi

    # Extract and eval the function (eval preserves nameref bindings)
    local func_body
    func_body=$(sed -n "/^${func_name}()/,/^}/p" "$project_dir/ru")
    eval "$func_body"
}

# Create a mock git repository (basic - just init)
# Usage: local repo_dir=$(create_mock_repo "name")
create_mock_repo() {
    local name="${1:-test-repo}"
    local temp_dir
    temp_dir=$(create_temp_dir)
    local repo_dir="$temp_dir/$name"

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    echo "$repo_dir"
}

# Create a bare "remote" repository
# Usage: local remote_dir=$(create_bare_repo "name")
create_bare_repo() {
    local name="${1:-test-remote}"
    local temp_dir
    temp_dir=$(create_temp_dir)
    local repo_dir="$temp_dir/$name.git"

    mkdir -p "$repo_dir"
    git init --bare "$repo_dir" >/dev/null 2>&1
    git -C "$repo_dir" symbolic-ref HEAD refs/heads/main

    echo "$repo_dir"
}

#==============================================================================
# Enhanced Test Isolation (Real Filesystem Operations)
#==============================================================================
# These functions create real git repos, worktrees, and fixtures for testing
# without mocks. Supports test-namespaced directories and failed artifact
# preservation for post-mortem debugging.

# Directory for preserving failed test artifacts
TF_FAILED_ARTIFACTS_DIR="${TF_FAILED_ARTIFACTS_DIR:-/tmp/ru-test-failures}"
TF_PRESERVE_FAILED="true"  # Set to false to disable artifact preservation

# Create a real git repository with actual commits
# Usage: local repo_dir=$(create_real_git_repo "name" [num_commits] [branch])
# Creates a repo with the specified number of commits (default 3)
# Returns the repo directory path
create_real_git_repo() {
    local name="${1:-test-repo}"
    local num_commits="${2:-3}"
    local branch="${3:-main}"
    local temp_dir repo_dir

    # Use test-namespaced directory if available
    if [[ -n "$TF_CURRENT_TEST" ]]; then
        temp_dir=$(create_namespaced_temp_dir "$TF_CURRENT_TEST")
    else
        temp_dir=$(create_temp_dir)
    fi
    repo_dir="$temp_dir/$name"

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -b "$branch" >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    # Create real commits
    local i
    for ((i=1; i<=num_commits; i++)); do
        echo "Content for commit $i" > "$repo_dir/file_$i.txt"
        git -C "$repo_dir" add "file_$i.txt" >/dev/null 2>&1
        git -C "$repo_dir" commit -m "Commit $i: Add file_$i.txt" >/dev/null 2>&1
    done

    echo "$repo_dir"
}

# Create a real git repository with a remote (upstream)
# Usage: local repo_info=$(create_real_git_repo_with_remote "name" [num_commits])
# Returns: "repo_dir|remote_dir" (pipe-separated)
create_real_git_repo_with_remote() {
    local name="${1:-test-repo}"
    local num_commits="${2:-3}"
    local temp_dir repo_dir remote_dir

    if [[ -n "$TF_CURRENT_TEST" ]]; then
        temp_dir=$(create_namespaced_temp_dir "$TF_CURRENT_TEST")
    else
        temp_dir=$(create_temp_dir)
    fi

    # Create bare remote first
    remote_dir="$temp_dir/${name}-remote.git"
    mkdir -p "$remote_dir"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    # Create local repo
    repo_dir="$temp_dir/$name"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -b main >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    # Create commits
    local i
    for ((i=1; i<=num_commits; i++)); do
        echo "Content for commit $i" > "$repo_dir/file_$i.txt"
        git -C "$repo_dir" add "file_$i.txt" >/dev/null 2>&1
        git -C "$repo_dir" commit -m "Commit $i" >/dev/null 2>&1
    done

    # Set up remote and push
    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1

    echo "$repo_dir|$remote_dir"
}

# Create a real git worktree from an existing repo
# Usage: local worktree_dir=$(create_real_worktree "$repo_dir" "branch_name" ["worktree_name"])
# Creates a new branch and worktree for it
create_real_worktree() {
    local repo_dir="$1"
    local branch_name="$2"
    local worktree_name="${3:-$branch_name}"
    local worktree_dir

    # Get parent directory of repo
    local parent_dir
    parent_dir=$(dirname "$repo_dir")
    worktree_dir="$parent_dir/worktree-$worktree_name"

    # Create branch and worktree
    git -C "$repo_dir" branch "$branch_name" >/dev/null 2>&1
    git -C "$repo_dir" worktree add "$worktree_dir" "$branch_name" >/dev/null 2>&1

    echo "$worktree_dir"
}

# Create GitHub API test fixtures for offline testing
# Usage: create_github_test_fixture "$fixture_dir" "type" [options]
# Types: repo_info, releases, graphql_repos
# Writes JSON fixtures to the specified directory
create_github_test_fixture() {
    local fixture_dir="$1"
    local fixture_type="$2"
    shift 2

    mkdir -p "$fixture_dir"

    case "$fixture_type" in
        repo_info)
            local owner="${1:-testowner}"
            local repo="${2:-testrepo}"
            cat > "$fixture_dir/repo_${owner}_${repo}.json" << FIXTURE_EOF
{
  "id": 123456789,
  "name": "$repo",
  "full_name": "$owner/$repo",
  "private": false,
  "owner": {"login": "$owner", "id": 1234},
  "html_url": "https://github.com/$owner/$repo",
  "clone_url": "https://github.com/$owner/$repo.git",
  "ssh_url": "git@github.com:$owner/$repo.git",
  "default_branch": "main",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-06-15T12:00:00Z"
}
FIXTURE_EOF
            echo "$fixture_dir/repo_${owner}_${repo}.json"
            ;;
        releases)
            local owner="${1:-testowner}"
            local repo="${2:-testrepo}"
            local version="${3:-1.0.0}"
            cat > "$fixture_dir/releases_${owner}_${repo}.json" << FIXTURE_EOF
[
  {
    "id": 987654321,
    "tag_name": "v$version",
    "name": "Release $version",
    "draft": false,
    "prerelease": false,
    "created_at": "2024-06-01T00:00:00Z",
    "published_at": "2024-06-01T00:00:00Z",
    "assets": [
      {
        "name": "${repo}-${version}.tar.gz",
        "browser_download_url": "https://github.com/$owner/$repo/releases/download/v$version/${repo}-${version}.tar.gz"
      }
    ]
  }
]
FIXTURE_EOF
            echo "$fixture_dir/releases_${owner}_${repo}.json"
            ;;
        graphql_repos)
            # GraphQL batch response for multiple repos
            local repos_json="${1:-[]}"
            cat > "$fixture_dir/graphql_batch.json" << FIXTURE_EOF
{
  "data": {
    "viewer": {
      "repositories": {
        "nodes": $repos_json,
        "pageInfo": {"hasNextPage": false, "endCursor": null}
      }
    }
  }
}
FIXTURE_EOF
            echo "$fixture_dir/graphql_batch.json"
            ;;
        *)
            log_error "Unknown fixture type: $fixture_type"
            return 1
            ;;
    esac
}

# Create a namespaced temp directory using test name
# Usage: local temp_dir=$(create_namespaced_temp_dir "test_name")
# Creates: /tmp/ru-test-<test_name>-XXXXXX for easier debugging
create_namespaced_temp_dir() {
    local test_name="${1:-unknown}"
    # Sanitize test name for filesystem (replace non-alphanum with -)
    local safe_name
    safe_name=$(echo "$test_name" | tr -c '[:alnum:]_-' '-')
    local temp_dir
    temp_dir=$(mktemp -d "/tmp/ru-test-${safe_name}-XXXXXX")
    TF_TEMP_DIRS+=("$temp_dir")
    echo "$temp_dir"
}

# Preserve test artifacts on failure for post-mortem debugging
# Usage: preserve_failed_artifacts "$test_name" "$artifact_dir"
# Copies artifacts to TF_FAILED_ARTIFACTS_DIR/<test_name>-<timestamp>/
preserve_failed_artifacts() {
    local test_name="$1"
    local artifact_dir="$2"

    if [[ "$TF_PRESERVE_FAILED" != "true" ]]; then
        return 0
    fi

    if [[ ! -d "$artifact_dir" ]]; then
        log_warn "Artifact directory does not exist: $artifact_dir"
        return 1
    fi

    local timestamp safe_name dest_dir
    timestamp=$(date +%Y%m%d_%H%M%S)
    safe_name=$(echo "$test_name" | tr -c '[:alnum:]_-' '-')
    dest_dir="$TF_FAILED_ARTIFACTS_DIR/${safe_name}_${timestamp}"

    mkdir -p "$dest_dir"
    cp -r "$artifact_dir"/* "$dest_dir/" 2>/dev/null || true

    log_info "Preserved failed test artifacts to: $dest_dir"
    echo "$dest_dir"
}

# Mark current test as failed and preserve its artifacts
# Usage: mark_test_failed_with_artifacts "$artifact_dir"
# Call this in test teardown when a test fails
mark_test_failed_with_artifacts() {
    local artifact_dir="${1:-$TF_TEST_ENV_ROOT}"

    if [[ -n "$TF_CURRENT_TEST" && -n "$artifact_dir" ]]; then
        preserve_failed_artifacts "$TF_CURRENT_TEST" "$artifact_dir"
    fi
}

# List preserved failure artifacts
# Usage: list_failed_artifacts
list_failed_artifacts() {
    if [[ -d "$TF_FAILED_ARTIFACTS_DIR" ]]; then
        echo "Failed test artifacts in $TF_FAILED_ARTIFACTS_DIR:"
        ls -la "$TF_FAILED_ARTIFACTS_DIR" 2>/dev/null || echo "  (none)"
    else
        echo "No failed artifacts directory found"
    fi
}

# Clean old failure artifacts (older than N days)
# Usage: cleanup_old_artifacts [days]
cleanup_old_artifacts() {
    local days="${1:-7}"
    if [[ -d "$TF_FAILED_ARTIFACTS_DIR" ]]; then
        find "$TF_FAILED_ARTIFACTS_DIR" -type d -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
        log_info "Cleaned artifacts older than $days days"
    fi
}

#==============================================================================
# Initialization
#==============================================================================

# Set up cleanup trap by default
setup_cleanup_trap

# Export functions for use in subshells
export -f assert_equals assert_not_equals assert_contains assert_not_contains
export -f assert_exit_code assert_success assert_fails
export -f assert_file_exists assert_file_not_exists
export -f assert_dir_exists assert_dir_not_exists
export -f assert_not_empty assert_empty
export -f assert_true assert_false assert_matches assert_file_contains
export -f _tf_pass _tf_fail _tf_log _tf_timestamp _tf_elapsed_ms pass fail
export -f log_debug log_info log_warn log_error
export -f log_test_start log_test_pass log_test_fail log_test_skip log_suite_start
export -f init_log_file set_log_level
export -f create_temp_dir cleanup_temp_dirs reset_test_env create_test_env get_test_env_root setup_cleanup_trap
export -f run_test skip_test require_gh_auth print_results get_exit_code run_parallel_tests
export -f enable_tap_output disable_tap_output is_tap_mode tap_plan tap_version tap_diag
export -f _tap_ok _tap_not_ok _tap_skip _tap_todo _tap_summary
export -f get_project_dir source_ru_function
export -f create_mock_repo create_bare_repo
# JSON logging exports
export -f enable_json_output disable_json_output is_json_mode
export -f _json_escape _json_timestamp_us _json_elapsed_us
export -f _json_git_state _json_env_snapshot _json_stack_trace _json_log
export -f log_suite_json log_suite_end_json
export -f log_test_start_json log_test_result_json log_assertion_json
export -f set_test_context clear_test_context log_event_json
# Enhanced test isolation exports
export -f create_real_git_repo create_real_git_repo_with_remote create_real_worktree
export -f create_github_test_fixture create_namespaced_temp_dir
export -f preserve_failed_artifacts mark_test_failed_with_artifacts
export -f list_failed_artifacts cleanup_old_artifacts
