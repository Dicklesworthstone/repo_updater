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
_tf_elapsed_ms() {
    if [[ -n "$TF_TEST_START_TIME" ]]; then
        local now
        now=$(date +%s%N 2>/dev/null || echo "0")
        if [[ "$now" != "0" && "$TF_TEST_START_TIME" != "0" ]]; then
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
    TF_TEST_START_TIME=$(date +%s%N 2>/dev/null || echo "0")
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
# Core Assertion Functions
#==============================================================================

# Record a passing assertion
# Usage: _tf_pass "message"
_tf_pass() {
    local msg="$1"
    ((TF_ASSERTIONS_PASSED++))
    echo "${TF_GREEN}PASS${TF_RESET}: $msg"
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
# Usage: assert_exit_code expected_code command [args...] "message"
# Note: Message must be the LAST argument
assert_exit_code() {
    local expected_code="$1"
    shift

    # Extract message (last argument)
    local args=("$@")
    local msg="${args[-1]:-Command should exit with code $expected_code}"
    unset 'args[-1]'

    # Run command and capture exit code
    local actual_code=0
    "${args[@]}" >/dev/null 2>&1 || actual_code=$?

    if [[ "$expected_code" -eq "$actual_code" ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "exit code $expected_code" "exit code $actual_code"
        return 1
    fi
}

# Assert command succeeds (exit code 0)
# Usage: assert_success command [args...] "message"
assert_success() {
    local args=("$@")
    local msg="${args[-1]:-Command should succeed}"
    unset 'args[-1]'

    local exit_code=0
    "${args[@]}" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        _tf_pass "$msg"
        return 0
    else
        _tf_fail "$msg" "exit code 0" "exit code $exit_code"
        return 1
    fi
}

# Assert command fails (non-zero exit code)
# Usage: assert_fails command [args...] "message"
assert_fails() {
    local args=("$@")
    local msg="${args[-1]:-Command should fail}"
    unset 'args[-1]'

    local exit_code=0
    "${args[@]}" >/dev/null 2>&1 || exit_code=$?

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
    for dir in "${TF_TEMP_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
        fi
    done
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

    TF_CURRENT_TEST="$test_name"
    echo ""
    echo "${TF_BOLD}Running: $test_name${TF_RESET}"
    echo "----------------------------------------"

    # Run the test
    if "$test_name"; then
        if [[ $TF_ASSERTIONS_FAILED -eq $failed_before ]]; then
            ((TF_TESTS_PASSED++))
            echo "${TF_GREEN}TEST PASSED${TF_RESET}: $test_name"
        else
            ((TF_TESTS_FAILED++))
            echo "${TF_RED}TEST FAILED${TF_RESET}: $test_name"
        fi
    else
        ((TF_TESTS_FAILED++))
        echo "${TF_RED}TEST FAILED${TF_RESET}: $test_name (non-zero exit)"
    fi

    TF_CURRENT_TEST=""
}

# Skip a test
# Usage: skip_test "reason"
skip_test() {
    local reason="${1:-}"
    ((TF_TESTS_SKIPPED++))
    echo "${TF_YELLOW}SKIP${TF_RESET}: $TF_CURRENT_TEST${reason:+ ($reason)}"
    return 0
}

# Print test results summary
print_results() {
    echo ""
    echo "============================================"
    echo "${TF_BOLD}Test Results${TF_RESET}"
    echo "============================================"
    echo "Tests:      ${TF_GREEN}$TF_TESTS_PASSED passed${TF_RESET}, ${TF_RED}$TF_TESTS_FAILED failed${TF_RESET}, ${TF_YELLOW}$TF_TESTS_SKIPPED skipped${TF_RESET}"
    echo "Assertions: ${TF_GREEN}$TF_ASSERTIONS_PASSED passed${TF_RESET}, ${TF_RED}$TF_ASSERTIONS_FAILED failed${TF_RESET}"
    echo "============================================"

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
source_ru_function() {
    local func_name="$1"
    local project_dir
    project_dir=$(get_project_dir)

    # Extract and source the function
    # shellcheck disable=SC1090
    source <(sed -n "/^${func_name}()/,/^}/p" "$project_dir/ru")
}

# Create a mock git repository
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
export -f _tf_pass _tf_fail _tf_log _tf_timestamp _tf_elapsed_ms
export -f log_debug log_info log_warn log_error
export -f log_test_start log_test_pass log_test_fail log_test_skip
export -f init_log_file set_log_level
export -f create_temp_dir cleanup_temp_dirs reset_test_env create_test_env get_test_env_root
export -f run_test skip_test print_results get_exit_code
export -f get_project_dir source_ru_function
export -f create_mock_repo create_bare_repo
