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
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test-Specific Helpers
#==============================================================================

setup_initialized_env() {
    e2e_setup
    export RU_LAYOUT="flat"
    # Clear env vars that might interfere
    unset RU_AUTOSTASH RU_UPDATE_STRATEGY
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
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
    setup_initialized_env

    # Add a configured repo (don't clone)
    "$E2E_RU_SCRIPT" add owner/configured-repo >/dev/null 2>&1

    # Create orphan repos
    create_orphan_repo "orphan1"
    create_orphan_repo "orphan2"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 2 orphan" "Reports 2 orphans"
    assert_contains "$stderr_output" "orphan1" "Lists orphan1"
    assert_contains "$stderr_output" "orphan2" "Lists orphan2"
    assert_contains "$stderr_output" "Use --archive" "Shows usage hint"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_no_orphans() {
    setup_initialized_env

    # Add a repo and create its directory
    "$E2E_RU_SCRIPT" add owner/myrepo >/dev/null 2>&1
    create_orphan_repo "myrepo"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Reports no orphans"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_empty_projects_dir() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Reports no orphans"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_nonexistent_projects_dir() {
    setup_initialized_env

    rm -rf "$RU_PROJECTS_DIR"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "does not exist" "Reports missing directory"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Archive Mode
#==============================================================================

test_prune_archive_mode() {
    setup_initialized_env

    create_orphan_repo "orphan-to-archive"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Archived" "Reports archiving"
    assert_contains "$stderr_output" "orphan-to-archive" "Mentions orphan name"
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

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Delete Mode
#==============================================================================

test_prune_delete_noninteractive() {
    setup_initialized_env

    create_orphan_repo "orphan-to-delete"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" --non-interactive prune --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Deleted" "Reports deletion"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-to-delete" "Orphan removed"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Error Handling
#==============================================================================

test_prune_conflicting_options() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4 for invalid args"
    assert_contains "$stderr_output" "Cannot use both" "Shows error message"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_unknown_option() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --invalid 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4 for unknown option"
    assert_contains "$stderr_output" "Unknown option" "Shows error message"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Layout Modes
#==============================================================================

test_prune_owner_repo_layout() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    "$E2E_RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at owner-repo depth
    mkdir -p "$RU_PROJECTS_DIR/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_contains "$stderr_output" "orphan-owner/orphan-repo" "Shows full path"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_full_layout() {
    setup_initialized_env
    export RU_LAYOUT="full"

    "$E2E_RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at full depth
    mkdir -p "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_contains "$stderr_output" "github.com" "Shows host in path"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Custom Names
#==============================================================================

test_prune_respects_custom_names() {
    setup_initialized_env

    # Add repo with custom name
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    # Create directory with custom name
    create_orphan_repo "shortname"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Custom name directory not marked as orphan"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_prune_json_output() {
    setup_initialized_env

    create_orphan_repo "orphan-json"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" --json prune 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stdout_output" '"path"' "JSON output contains path field"
    assert_contains "$stdout_output" "orphan-json" "JSON output contains orphan path"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Multiple Orphans
#==============================================================================

test_prune_archive_multiple() {
    setup_initialized_env

    create_orphan_repo "orphan-a"
    create_orphan_repo "orphan-b"
    create_orphan_repo "orphan-c"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Archived 3" "Reports 3 archived"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-a" "orphan-a removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-b" "orphan-b removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-c" "orphan-c removed"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "ru prune workflow"

# Basic detection
run_test test_prune_detects_orphans
run_test test_prune_no_orphans
run_test test_prune_empty_projects_dir
run_test test_prune_nonexistent_projects_dir

# Archive mode
run_test test_prune_archive_mode
run_test test_prune_archive_multiple

# Delete mode
run_test test_prune_delete_noninteractive

# Error handling
run_test test_prune_conflicting_options
run_test test_prune_unknown_option

# Layout modes
run_test test_prune_owner_repo_layout
run_test test_prune_full_layout

# Custom names
run_test test_prune_respects_custom_names

# JSON output
run_test test_prune_json_output

print_results
