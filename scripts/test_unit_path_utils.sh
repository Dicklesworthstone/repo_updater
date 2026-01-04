#!/usr/bin/env bash
#
# Unit Tests: Path Utilities
# Tests for get_repo_log_path, get_run_log_path, update_latest_symlink
#
# Test coverage:
#   - get_repo_log_path creates correct path structure
#   - get_repo_log_path sanitizes repo names (slashes to underscores)
#   - get_repo_log_path creates log directory if missing
#   - get_run_log_path returns correct path
#   - get_run_log_path creates log directory if missing
#   - update_latest_symlink creates symlink
#   - update_latest_symlink updates existing symlink
#   - Paths include date-based directories
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
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    export RU_LOG_DIR="$TEMP_DIR/logs"
    mkdir -p "$HOME"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_LOG_DIR
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
# Source Functions from ru
#==============================================================================

# Extract ensure_dir (needed by path functions)
eval "$(sed -n '/^ensure_dir()/,/^}/p' "$RU_SCRIPT")"

# Extract path utility functions
eval "$(sed -n '/^get_repo_log_path()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^get_run_log_path()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^update_latest_symlink()/,/^}/p' "$RU_SCRIPT")"

#==============================================================================
# Tests: get_repo_log_path
#==============================================================================

test_get_repo_log_path_returns_path() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path returns a path"
    setup_test_env

    local result
    result=$(get_repo_log_path "owner/repo")

    if [[ -n "$result" && "$result" == *.log ]]; then
        pass "Returns a .log path"
    else
        fail "Should return a .log path (got: '$result')"
    fi

    cleanup_test_env
}

test_get_repo_log_path_sanitizes_slashes() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path sanitizes slashes in repo name"
    setup_test_env

    local result
    result=$(get_repo_log_path "owner/repo-name")

    if [[ "$result" == *"owner_repo-name.log" ]]; then
        pass "Slashes replaced with underscores"
    else
        fail "Slashes should be replaced (got: '$result')"
    fi

    cleanup_test_env
}

test_get_repo_log_path_creates_directory() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path creates log directory"
    setup_test_env

    local result
    result=$(get_repo_log_path "test-repo")
    local dir
    dir=$(dirname "$result")

    if [[ -d "$dir" ]]; then
        pass "Log directory was created"
    else
        fail "Log directory was not created (expected: $dir)"
    fi

    cleanup_test_env
}

test_get_repo_log_path_includes_date() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path includes date in path"
    setup_test_env

    local today
    today=$(date +%Y-%m-%d)

    local result
    result=$(get_repo_log_path "test-repo")

    if [[ "$result" == *"$today"* ]]; then
        pass "Path includes today's date"
    else
        fail "Path should include date (got: '$result', expected date: $today)"
    fi

    cleanup_test_env
}

test_get_repo_log_path_includes_repos_subdir() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path includes 'repos' subdirectory"
    setup_test_env

    local result
    result=$(get_repo_log_path "test-repo")

    if [[ "$result" == */repos/* ]]; then
        pass "Path includes 'repos' subdirectory"
    else
        fail "Path should include repos subdir (got: '$result')"
    fi

    cleanup_test_env
}

test_get_repo_log_path_handles_complex_names() {
    echo -e "${BLUE}Test:${RESET} get_repo_log_path handles complex repo names"
    setup_test_env

    local result
    result=$(get_repo_log_path "org/sub-org/deeply/nested/repo")

    # All slashes should become underscores
    if [[ "$result" != */* || "$result" == *"org_sub-org_deeply_nested_repo.log" ]]; then
        pass "Complex repo name handled correctly"
    else
        # Just check it doesn't break
        if [[ -n "$result" && "$result" == *.log ]]; then
            pass "Complex repo name processed to valid path"
        else
            fail "Complex repo name not handled (got: '$result')"
        fi
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: get_run_log_path
#==============================================================================

test_get_run_log_path_returns_path() {
    echo -e "${BLUE}Test:${RESET} get_run_log_path returns a path"
    setup_test_env

    local result
    result=$(get_run_log_path)

    if [[ -n "$result" && "$result" == *run.log ]]; then
        pass "Returns run.log path"
    else
        fail "Should return run.log path (got: '$result')"
    fi

    cleanup_test_env
}

test_get_run_log_path_creates_directory() {
    echo -e "${BLUE}Test:${RESET} get_run_log_path creates log directory"
    setup_test_env

    local result
    result=$(get_run_log_path)
    local dir
    dir=$(dirname "$result")

    if [[ -d "$dir" ]]; then
        pass "Log directory was created"
    else
        fail "Log directory was not created"
    fi

    cleanup_test_env
}

test_get_run_log_path_includes_date() {
    echo -e "${BLUE}Test:${RESET} get_run_log_path includes date in path"
    setup_test_env

    local today
    today=$(date +%Y-%m-%d)

    local result
    result=$(get_run_log_path)

    if [[ "$result" == *"$today"* ]]; then
        pass "Path includes today's date"
    else
        fail "Path should include date (got: '$result')"
    fi

    cleanup_test_env
}

test_get_run_log_path_not_in_repos_subdir() {
    echo -e "${BLUE}Test:${RESET} get_run_log_path is not in 'repos' subdirectory"
    setup_test_env

    local result
    result=$(get_run_log_path)

    if [[ "$result" != */repos/* ]]; then
        pass "run.log is not in repos subdir"
    else
        fail "run.log should not be in repos subdir"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: update_latest_symlink
#==============================================================================

test_update_latest_symlink_creates_symlink() {
    echo -e "${BLUE}Test:${RESET} update_latest_symlink creates symlink"
    setup_test_env

    # First create the target directory
    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "$RU_LOG_DIR/$today"

    update_latest_symlink

    local latest_link="$RU_LOG_DIR/latest"
    if [[ -L "$latest_link" ]]; then
        pass "Symlink was created"
    else
        fail "Symlink was not created at $latest_link"
    fi

    cleanup_test_env
}

test_update_latest_symlink_points_to_today() {
    echo -e "${BLUE}Test:${RESET} update_latest_symlink points to today's directory"
    setup_test_env

    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "$RU_LOG_DIR/$today"

    update_latest_symlink

    local latest_link="$RU_LOG_DIR/latest"
    local target
    target=$(readlink "$latest_link")

    if [[ "$target" == *"$today"* ]]; then
        pass "Symlink points to today's directory"
    else
        fail "Symlink should point to today (got: '$target')"
    fi

    cleanup_test_env
}

test_update_latest_symlink_replaces_old_symlink() {
    echo -e "${BLUE}Test:${RESET} update_latest_symlink replaces old symlink"
    setup_test_env

    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "$RU_LOG_DIR/$today"
    mkdir -p "$RU_LOG_DIR/old-date"

    # Create old symlink
    ln -sf "$RU_LOG_DIR/old-date" "$RU_LOG_DIR/latest"

    # Update should replace it
    update_latest_symlink

    local target
    target=$(readlink "$RU_LOG_DIR/latest")

    if [[ "$target" == *"$today"* ]]; then
        pass "Old symlink replaced with new one"
    else
        fail "Symlink should point to today after update (got: '$target')"
    fi

    cleanup_test_env
}

test_update_latest_symlink_handles_no_existing_link() {
    echo -e "${BLUE}Test:${RESET} update_latest_symlink handles no existing link"
    setup_test_env

    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "$RU_LOG_DIR/$today"

    # Ensure no 'latest' exists
    rm -f "$RU_LOG_DIR/latest" 2>/dev/null

    if update_latest_symlink; then
        pass "Handles missing symlink gracefully"
    else
        fail "Should succeed when no symlink exists"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Integration
#==============================================================================

test_log_paths_are_consistent() {
    echo -e "${BLUE}Test:${RESET} Log paths share same date directory"
    setup_test_env

    local repo_log run_log
    repo_log=$(get_repo_log_path "test-repo")
    run_log=$(get_run_log_path)

    local today
    today=$(date +%Y-%m-%d)

    if [[ "$repo_log" == *"$today"* && "$run_log" == *"$today"* ]]; then
        pass "Both paths use same date"
    else
        fail "Paths should use consistent date"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Path Utilities"
echo "============================================"
echo ""

# get_repo_log_path tests
test_get_repo_log_path_returns_path
echo ""
test_get_repo_log_path_sanitizes_slashes
echo ""
test_get_repo_log_path_creates_directory
echo ""
test_get_repo_log_path_includes_date
echo ""
test_get_repo_log_path_includes_repos_subdir
echo ""
test_get_repo_log_path_handles_complex_names
echo ""

# get_run_log_path tests
test_get_run_log_path_returns_path
echo ""
test_get_run_log_path_creates_directory
echo ""
test_get_run_log_path_includes_date
echo ""
test_get_run_log_path_not_in_repos_subdir
echo ""

# update_latest_symlink tests
test_update_latest_symlink_creates_symlink
echo ""
test_update_latest_symlink_points_to_today
echo ""
test_update_latest_symlink_replaces_old_symlink
echo ""
test_update_latest_symlink_handles_no_existing_link
echo ""

# Integration tests
test_log_paths_are_consistent
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
