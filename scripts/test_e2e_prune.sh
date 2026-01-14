#!/usr/bin/env bash
#
# E2E Test: ru prune workflow
# Tests detection and management of orphan repositories
#
# Test coverage:
#   - ru prune detects orphan repos (dry run by default)
#   - ru prune shows no orphans when all are configured
#   - ru prune --archive moves orphans to archive directory
#   - ru prune --delete removes orphans (with confirmation)
#   - ru prune --delete --non-interactive skips confirmation
#   - ru prune handles empty projects directory
#   - ru prune handles different layout modes
#   - ru prune respects custom names
#   - ru prune with conflicting options shows error
#   - ru prune handles JSON output
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
    export RU_LAYOUT="flat"
    mkdir -p "$HOME"
    mkdir -p "$RU_PROJECTS_DIR"
    # Clear any RU_ env vars that might interfere
    unset RU_AUTOSTASH RU_PARALLEL RU_UPDATE_STRATEGY
}

setup_initialized_env() {
    setup_test_env
    "$RU_SCRIPT" init >/dev/null 2>&1
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR RU_LAYOUT
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

assert_dir_exists() {
    local path="$1"
    local msg="$2"
    if [[ -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory not found: $path)"
    fi
}

assert_dir_not_exists() {
    local path="$1"
    local msg="$2"
    if [[ ! -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory should not exist: $path)"
    fi
}

# Create an orphan git repo
create_orphan_repo() {
    local name="$1"
    local path="$RU_PROJECTS_DIR/$name"
    mkdir -p "$path"
    git -C "$path" init --quiet 2>/dev/null
}

#==============================================================================
# Tests: Basic Prune Detection
#==============================================================================

test_prune_detects_orphans() {
    echo -e "${BLUE}Test:${RESET} ru prune detects orphan repositories"
    setup_initialized_env

    # Add a configured repo (don't clone)
    "$RU_SCRIPT" add owner/configured-repo >/dev/null 2>&1

    # Create orphan repos
    create_orphan_repo "orphan1"
    create_orphan_repo "orphan2"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Found 2 orphan" "Reports 2 orphans"
    assert_stderr_contains "$stderr_output" "orphan1" "Lists orphan1"
    assert_stderr_contains "$stderr_output" "orphan2" "Lists orphan2"
    assert_stderr_contains "$stderr_output" "Use --archive" "Shows usage hint"

    cleanup_test_env
}

test_prune_no_orphans() {
    echo -e "${BLUE}Test:${RESET} ru prune shows no orphans when all are configured"
    setup_initialized_env

    # Add a repo and create its directory
    "$RU_SCRIPT" add owner/myrepo >/dev/null 2>&1
    create_orphan_repo "myrepo"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "No orphan" "Reports no orphans"

    cleanup_test_env
}

test_prune_empty_projects_dir() {
    echo -e "${BLUE}Test:${RESET} ru prune handles empty projects directory"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "No orphan" "Reports no orphans"

    cleanup_test_env
}

test_prune_nonexistent_projects_dir() {
    echo -e "${BLUE}Test:${RESET} ru prune handles nonexistent projects directory"
    setup_initialized_env

    rm -rf "$RU_PROJECTS_DIR"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "does not exist" "Reports missing directory"

    cleanup_test_env
}

#==============================================================================
# Tests: Archive Mode
#==============================================================================

test_prune_archive_mode() {
    echo -e "${BLUE}Test:${RESET} ru prune --archive moves orphans to archive"
    setup_initialized_env

    create_orphan_repo "orphan-to-archive"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Archived" "Reports archiving"
    assert_stderr_contains "$stderr_output" "orphan-to-archive" "Mentions orphan name"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-to-archive" "Orphan removed from projects"
    assert_dir_exists "$XDG_STATE_HOME/ru/archived" "Archive directory created"

    # Verify archive contains the repo with timestamp
    local archived_count=0
    # Use find instead of ls | grep to handle non-alphanumeric filenames safely
    archived_count=$(/usr/bin/find "$XDG_STATE_HOME/ru/archived" -maxdepth 1 -type d -name "orphan-to-archive*" 2>/dev/null | wc -l)
    if [[ "$archived_count" -eq 1 ]]; then
        pass "Orphan archived with timestamp"
    else
        fail "Orphan not found in archive (found $archived_count)"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Delete Mode
#==============================================================================

test_prune_delete_noninteractive() {
    echo -e "${BLUE}Test:${RESET} ru prune --delete with --non-interactive"
    setup_initialized_env

    create_orphan_repo "orphan-to-delete"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" --non-interactive prune --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Deleted" "Reports deletion"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-to-delete" "Orphan removed"

    cleanup_test_env
}

#==============================================================================
# Tests: Error Handling
#==============================================================================

test_prune_conflicting_options() {
    echo -e "${BLUE}Test:${RESET} ru prune rejects conflicting --archive and --delete"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune --archive --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 4 "$exit_code" "Exits with code 4 for invalid args"
    assert_stderr_contains "$stderr_output" "Cannot use both" "Shows error message"

    cleanup_test_env
}

test_prune_unknown_option() {
    echo -e "${BLUE}Test:${RESET} ru prune rejects unknown options"
    setup_initialized_env

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune --invalid 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 4 "$exit_code" "Exits with code 4 for unknown option"
    assert_stderr_contains "$stderr_output" "Unknown option" "Shows error message"

    cleanup_test_env
}

#==============================================================================
# Tests: Layout Modes
#==============================================================================

test_prune_owner_repo_layout() {
    echo -e "${BLUE}Test:${RESET} ru prune works with owner-repo layout"
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    "$RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at owner-repo depth
    mkdir -p "$RU_PROJECTS_DIR/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_stderr_contains "$stderr_output" "orphan-owner/orphan-repo" "Shows full path"

    cleanup_test_env
}

test_prune_full_layout() {
    echo -e "${BLUE}Test:${RESET} ru prune works with full layout"
    setup_initialized_env
    export RU_LAYOUT="full"

    "$RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at full depth
    mkdir -p "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_stderr_contains "$stderr_output" "github.com" "Shows host in path"

    cleanup_test_env
}

#==============================================================================
# Tests: Custom Names
#==============================================================================

test_prune_respects_custom_names() {
    echo -e "${BLUE}Test:${RESET} ru prune respects custom names in config"
    setup_initialized_env

    # Add repo with custom name
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    # Create directory with custom name
    create_orphan_repo "shortname"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "No orphan" "Custom name directory not marked as orphan"

    cleanup_test_env
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_prune_json_output() {
    echo -e "${BLUE}Test:${RESET} ru prune --json outputs JSON"
    setup_initialized_env

    create_orphan_repo "orphan-json"

    local stdout_output
    stdout_output=$("$RU_SCRIPT" --json prune 2>/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    if printf '%s\n' "$stdout_output" | grep -q '"path"'; then
        pass "JSON output contains path field"
    else
        fail "JSON output should contain path field"
    fi
    if printf '%s\n' "$stdout_output" | grep -q 'orphan-json'; then
        pass "JSON output contains orphan path"
    else
        fail "JSON output should contain orphan path"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Multiple Orphans
#==============================================================================

test_prune_archive_multiple() {
    echo -e "${BLUE}Test:${RESET} ru prune --archive handles multiple orphans"
    setup_initialized_env

    create_orphan_repo "orphan-a"
    create_orphan_repo "orphan-b"
    create_orphan_repo "orphan-c"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stderr_contains "$stderr_output" "Archived 3" "Reports 3 archived"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-a" "orphan-a removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-b" "orphan-b removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-c" "orphan-c removed"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru prune workflow"
echo "============================================"
echo ""

# Basic detection
test_prune_detects_orphans
echo ""
test_prune_no_orphans
echo ""
test_prune_empty_projects_dir
echo ""
test_prune_nonexistent_projects_dir
echo ""

# Archive mode
test_prune_archive_mode
echo ""
test_prune_archive_multiple
echo ""

# Delete mode
test_prune_delete_noninteractive
echo ""

# Error handling
test_prune_conflicting_options
echo ""
test_prune_unknown_option
echo ""

# Layout modes
test_prune_owner_repo_layout
echo ""
test_prune_full_layout
echo ""

# Custom names
test_prune_respects_custom_names
echo ""

# JSON output
test_prune_json_output
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
