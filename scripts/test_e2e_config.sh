#!/usr/bin/env bash
#
# E2E Test: ru config workflow
# Tests configuration display, setting values, and persistence
#
# Test coverage:
#   - ru config shows resolved configuration values
#   - ru config --print shows config file contents
#   - ru config --set KEY=VALUE sets a value
#   - ru config --set with invalid format shows error
#   - Set values persist across ru invocations
#   - Environment variables override config file
#   - Config priority: CLI > env > file > defaults
#   - Handles uninitialized config gracefully
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    export RU_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$HOME"
    mkdir -p "$RU_PROJECTS_DIR"
    # Clear any RU_ env vars that might interfere
    unset RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL
}

setup_initialized_env() {
    setup_test_env
    # Initialize config
    "$RU_SCRIPT" init >/dev/null 2>&1
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

#==============================================================================
# Assertion Helpers
#==============================================================================

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected exit code $expected, got $actual)"
    fi
}

assert_stderr_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in stderr)"
    fi
}

assert_stderr_not_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if ! printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' should not be in stderr)"
    fi
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local msg="$3"
    if [[ -f "$path" ]] && grep -q "$pattern" "$path"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $path)"
    fi
}

#==============================================================================
# Tests: Basic Config Display
#==============================================================================

test_config_shows_resolved_values() {
    echo -e "${BLUE}Test:${RESET} ru config shows resolved configuration values"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "PROJECTS_DIR=" "Shows PROJECTS_DIR"
    assert_stderr_contains "$stderr_output" "LAYOUT=" "Shows LAYOUT"
    assert_stderr_contains "$stderr_output" "UPDATE_STRATEGY=" "Shows UPDATE_STRATEGY"
    assert_stderr_contains "$stderr_output" "AUTOSTASH=" "Shows AUTOSTASH"
    assert_stderr_contains "$stderr_output" "PARALLEL=" "Shows PARALLEL"
    assert_stderr_contains "$stderr_output" "Configuration (resolved)" "Shows header"

    cleanup_test_env
}

test_config_shows_default_values() {
    echo -e "${BLUE}Test:${RESET} ru config shows default values for new install"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    # Check defaults
    assert_stderr_contains "$stderr_output" "LAYOUT=flat" "Default LAYOUT is flat"
    assert_stderr_contains "$stderr_output" "UPDATE_STRATEGY=ff-only" "Default UPDATE_STRATEGY is ff-only"
    assert_stderr_contains "$stderr_output" "AUTOSTASH=false" "Default AUTOSTASH is false"
    assert_stderr_contains "$stderr_output" "PARALLEL=1" "Default PARALLEL is 1"

    cleanup_test_env
}

test_config_shows_paths() {
    echo -e "${BLUE}Test:${RESET} ru config shows config and repos file paths"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "Config file:" "Shows config file path"
    assert_stderr_contains "$stderr_output" "Repos file:" "Shows repos file path"

    cleanup_test_env
}

#==============================================================================
# Tests: --print Mode
#==============================================================================

test_config_print_shows_file_contents() {
    echo -e "${BLUE}Test:${RESET} ru config --print shows config file contents"
    setup_initialized_env

    # First, set a value so the config file has content
    "$RU_SCRIPT" config --set=LAYOUT=owner-repo >/dev/null 2>&1

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config --print 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Config file contents" "Shows 'Config file contents' label"
    assert_stderr_contains "$stderr_output" "LAYOUT=owner-repo" "Shows LAYOUT setting from file"

    cleanup_test_env
}

test_config_print_with_empty_file() {
    echo -e "${BLUE}Test:${RESET} ru config --print with empty config file"
    setup_initialized_env

    # Create empty config file
    mkdir -p "$XDG_CONFIG_HOME/ru"
    touch "$XDG_CONFIG_HOME/ru/config"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config --print 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    # Should still show resolved values (defaults)
    assert_stderr_contains "$stderr_output" "LAYOUT=flat" "Shows default LAYOUT"

    cleanup_test_env
}

#==============================================================================
# Tests: --set Mode
#==============================================================================

test_config_set_layout() {
    echo -e "${BLUE}Test:${RESET} ru config --set=LAYOUT=owner-repo sets layout"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config --set=LAYOUT=owner-repo 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Set LAYOUT=owner-repo" "Shows success message"

    # Verify persistence
    assert_file_contains "$XDG_CONFIG_HOME/ru/config" "LAYOUT=owner-repo" "Config file contains LAYOUT"

    cleanup_test_env
}

test_config_set_autostash() {
    echo -e "${BLUE}Test:${RESET} ru config --set=AUTOSTASH=true sets autostash"
    setup_initialized_env

    "$RU_SCRIPT" config --set=AUTOSTASH=true >/dev/null 2>&1

    # Verify it shows in config
    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "AUTOSTASH=true" "AUTOSTASH shows as true"

    cleanup_test_env
}

test_config_set_projects_dir() {
    echo -e "${BLUE}Test:${RESET} ru config --set=PROJECTS_DIR=/custom/path sets projects dir"
    setup_initialized_env

    "$RU_SCRIPT" config --set=PROJECTS_DIR=/custom/path >/dev/null 2>&1

    # Unset env var so file value is used
    unset RU_PROJECTS_DIR

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "PROJECTS_DIR=/custom/path" "PROJECTS_DIR shows custom path"

    cleanup_test_env
}

test_config_set_invalid_format() {
    echo -e "${BLUE}Test:${RESET} ru config --set with invalid format shows error"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config --set=INVALID 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 4 "$exit_code" "Exits with code 4 for invalid args"
    assert_stderr_contains "$stderr_output" "Invalid format" "Shows error message"

    cleanup_test_env
}

test_config_set_empty_value() {
    echo -e "${BLUE}Test:${RESET} ru config --set=KEY= with empty value"
    setup_initialized_env

    "$RU_SCRIPT" config --set=LAYOUT= >/dev/null 2>&1
    local exit_code=$?

    # Should succeed - empty value is valid
    assert_exit_code 0 "$exit_code" "Exits with code 0 for empty value"

    cleanup_test_env
}

#==============================================================================
# Tests: Value Persistence
#==============================================================================

test_config_values_persist() {
    echo -e "${BLUE}Test:${RESET} Config values persist across ru invocations"
    setup_initialized_env

    # Set multiple values
    "$RU_SCRIPT" config --set=LAYOUT=full >/dev/null 2>&1
    "$RU_SCRIPT" config --set=UPDATE_STRATEGY=rebase >/dev/null 2>&1
    "$RU_SCRIPT" config --set=PARALLEL=4 >/dev/null 2>&1

    # Read them back
    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "LAYOUT=full" "LAYOUT persisted"
    assert_stderr_contains "$stderr_output" "UPDATE_STRATEGY=rebase" "UPDATE_STRATEGY persisted"
    assert_stderr_contains "$stderr_output" "PARALLEL=4" "PARALLEL persisted"

    cleanup_test_env
}

test_config_update_existing_value() {
    echo -e "${BLUE}Test:${RESET} Setting a value updates existing value"
    setup_initialized_env

    # Set initial value
    "$RU_SCRIPT" config --set=LAYOUT=flat >/dev/null 2>&1
    # Update it
    "$RU_SCRIPT" config --set=LAYOUT=owner-repo >/dev/null 2>&1

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "LAYOUT=owner-repo" "LAYOUT updated to new value"
    assert_stderr_not_contains "$stderr_output" "LAYOUT=flat" "Old LAYOUT value not shown"

    cleanup_test_env
}

#==============================================================================
# Tests: Environment Variable Override
#==============================================================================

test_config_env_overrides_file() {
    echo -e "${BLUE}Test:${RESET} Environment variables override config file"
    setup_initialized_env

    # Set in config file
    "$RU_SCRIPT" config --set=LAYOUT=flat >/dev/null 2>&1

    # Override with environment
    export RU_LAYOUT="owner-repo"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "LAYOUT=owner-repo" "Env var overrides file value"

    unset RU_LAYOUT
    cleanup_test_env
}

test_config_env_projects_dir() {
    echo -e "${BLUE}Test:${RESET} RU_PROJECTS_DIR environment variable works"
    setup_initialized_env

    export RU_PROJECTS_DIR="/env/projects"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    assert_stderr_contains "$stderr_output" "PROJECTS_DIR=/env/projects" "RU_PROJECTS_DIR env var works"

    cleanup_test_env
}

#==============================================================================
# Tests: Uninitialized Config
#==============================================================================

test_config_uninitialized_shows_defaults() {
    echo -e "${BLUE}Test:${RESET} ru config on uninitialized system shows defaults"
    setup_test_env
    # Don't initialize - config dir doesn't exist

    local stderr_output
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)
    local exit_code=$?

    # Should show default values even without config dir
    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "LAYOUT=flat" "Shows default LAYOUT"

    cleanup_test_env
}

#==============================================================================
# Tests: Stream Separation
#==============================================================================

test_config_output_to_stderr() {
    echo -e "${BLUE}Test:${RESET} ru config outputs to stderr (stdout is empty)"
    setup_initialized_env

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" config 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" config 2>&1 >/dev/null)

    if [[ -z "$stdout_output" ]]; then
        pass "Stdout is empty"
    else
        fail "Stdout should be empty (got: $stdout_output)"
    fi

    assert_stderr_contains "$stderr_output" "Configuration" "Config output goes to stderr"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru config workflow"
echo "============================================"
echo ""

# Basic config display
test_config_shows_resolved_values
echo ""
test_config_shows_default_values
echo ""
test_config_shows_paths
echo ""

# --print mode
test_config_print_shows_file_contents
echo ""
test_config_print_with_empty_file
echo ""

# --set mode
test_config_set_layout
echo ""
test_config_set_autostash
echo ""
test_config_set_projects_dir
echo ""
test_config_set_invalid_format
echo ""
test_config_set_empty_value
echo ""

# Persistence
test_config_values_persist
echo ""
test_config_update_existing_value
echo ""

# Environment override
test_config_env_overrides_file
echo ""
test_config_env_projects_dir
echo ""

# Uninitialized
test_config_uninitialized_shows_defaults
echo ""

# Stream separation
test_config_output_to_stderr
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
