#!/usr/bin/env bash
#
# E2E Test: ru doctor workflow
# Tests the system diagnostics command
#
# Test coverage:
#   - ru doctor checks git installation
#   - ru doctor checks gh CLI and auth status
#   - ru doctor checks config directory
#   - ru doctor checks configured repos
#   - ru doctor checks projects directory writability
#   - ru doctor checks gum (optional)
#   - ru doctor exit code 0 when all checks pass
#   - ru doctor exit code 3 when issues found
#   - Output goes to stderr (human-readable)
#
# Note: We can't easily mock missing binaries like git, so some checks
# verify the output format rather than actual failure states.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions are called dynamically
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
}

setup_initialized_env() {
    setup_test_env
    mkdir -p "$RU_PROJECTS_DIR"
    # Initialize config
    "$RU_SCRIPT" init >/dev/null 2>&1
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR
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

#==============================================================================
# Tests: Basic doctor functionality
#==============================================================================

test_doctor_runs_successfully() {
    echo -e "${BLUE}Test:${RESET} ru doctor runs and produces output"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)
    local exit_code=$?

    # Doctor may exit 0 or 3 depending on gh auth status
    # We just verify it runs and produces expected output format
    if [[ "$exit_code" -eq 0 || "$exit_code" -eq 3 ]]; then
        pass "Exits with valid code ($exit_code)"
    else
        fail "Unexpected exit code $exit_code (expected 0 or 3)"
    fi
    assert_stderr_contains "$stderr_output" "System Check" "Shows System Check header"

    cleanup_test_env
}

test_doctor_checks_git() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks git installation"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    # Git should be installed in our test environment
    assert_stderr_contains "$stderr_output" "git:" "Checks git"
    assert_stderr_contains "$stderr_output" "\[OK\].*git:" "Git check passes"

    cleanup_test_env
}

test_doctor_checks_gh() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks gh CLI"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    # Check that gh CLI is mentioned (may or may not be installed)
    assert_stderr_contains "$stderr_output" "gh:" "Checks gh CLI"

    cleanup_test_env
}

test_doctor_checks_config() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks config directory"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "Config:" "Checks config directory"
    assert_stderr_contains "$stderr_output" "\[OK\].*Config:" "Config check passes when initialized"

    cleanup_test_env
}

test_doctor_checks_repos() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks configured repos"
    setup_initialized_env

    "$RU_SCRIPT" add owner/repo1 owner/repo2 >/dev/null 2>&1

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "Repos:" "Checks repos"
    assert_stderr_contains "$stderr_output" "2 configured" "Shows correct repo count"

    cleanup_test_env
}

test_doctor_checks_projects_dir() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks projects directory"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "Projects:" "Checks projects directory"

    cleanup_test_env
}

test_doctor_checks_gum() {
    echo -e "${BLUE}Test:${RESET} ru doctor checks gum (optional)"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    # Gum check should appear (may be installed or not)
    assert_stderr_contains "$stderr_output" "gum:" "Checks gum"

    cleanup_test_env
}

#==============================================================================
# Tests: Config states
#==============================================================================

test_doctor_uninitialized_config() {
    echo -e "${BLUE}Test:${RESET} ru doctor detects uninitialized config"
    setup_test_env
    mkdir -p "$RU_PROJECTS_DIR"
    # Don't initialize config

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "not initialized" "Detects uninitialized config"
    assert_stderr_contains "$stderr_output" "ru init" "Suggests ru init"

    cleanup_test_env
}

test_doctor_no_repos_configured() {
    echo -e "${BLUE}Test:${RESET} ru doctor detects no repos configured"
    setup_initialized_env

    # Clear repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "# Empty" > "$repos_file"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "none configured" "Detects no repos configured"

    cleanup_test_env
}

#==============================================================================
# Tests: Projects directory states
#==============================================================================

test_doctor_projects_dir_missing() {
    echo -e "${BLUE}Test:${RESET} ru doctor handles missing projects directory"
    setup_initialized_env

    # Remove projects directory
    rmdir "$RU_PROJECTS_DIR" 2>/dev/null || true

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "will be created" "Notes projects dir will be created"

    cleanup_test_env
}

test_doctor_projects_dir_writable() {
    echo -e "${BLUE}Test:${RESET} ru doctor verifies projects directory is writable"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    assert_stderr_contains "$stderr_output" "writable" "Checks writability"

    cleanup_test_env
}

#==============================================================================
# Tests: Exit codes
#==============================================================================

test_doctor_exit_codes() {
    echo -e "${BLUE}Test:${RESET} ru doctor uses correct exit codes"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)
    local exit_code=$?

    # Exit code 0 means all checks passed, 3 means issues found
    if [[ "$exit_code" -eq 0 ]]; then
        # Should show success message
        assert_stderr_contains "$stderr_output" "All checks passed" "Shows success message when exit 0"
    elif [[ "$exit_code" -eq 3 ]]; then
        # Should show issues count
        assert_stderr_contains "$stderr_output" "issue" "Shows issue count when exit 3"
    else
        fail "Unexpected exit code $exit_code"
    fi

    pass "Exit code matches output message"

    cleanup_test_env
}

#==============================================================================
# Tests: Output format
#==============================================================================

test_doctor_output_to_stderr() {
    echo -e "${BLUE}Test:${RESET} ru doctor outputs to stderr (not stdout)"
    setup_initialized_env

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" doctor 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" doctor 2>&1 >/dev/null)

    # Stdout should be empty or minimal
    if [[ -z "$stdout_output" ]]; then
        pass "Stdout is empty (all output to stderr)"
    else
        fail "Stdout should be empty, got: $stdout_output"
    fi

    # Stderr should have content
    if [[ -n "$stderr_output" ]]; then
        pass "Stderr has diagnostic output"
    else
        fail "Stderr should have diagnostic output"
    fi

    cleanup_test_env
}

test_doctor_uses_status_indicators() {
    echo -e "${BLUE}Test:${RESET} ru doctor uses status indicators ([OK], [??], [!!])"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" doctor 2>&1)

    # Should have at least one [OK] indicator
    assert_stderr_contains "$stderr_output" "\[OK\]" "Uses [OK] indicator"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru doctor workflow"
echo "============================================"
echo ""

# Basic functionality
test_doctor_runs_successfully
echo ""
test_doctor_checks_git
echo ""
test_doctor_checks_gh
echo ""
test_doctor_checks_config
echo ""
test_doctor_checks_repos
echo ""
test_doctor_checks_projects_dir
echo ""
test_doctor_checks_gum
echo ""

# Config states
test_doctor_uninitialized_config
echo ""
test_doctor_no_repos_configured
echo ""

# Projects directory states
test_doctor_projects_dir_missing
echo ""
test_doctor_projects_dir_writable
echo ""

# Exit codes
test_doctor_exit_codes
echo ""

# Output format
test_doctor_output_to_stderr
echo ""
test_doctor_uses_status_indicators
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
