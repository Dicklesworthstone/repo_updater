#!/usr/bin/env bash
#
# Unit tests: Git worktree preparation (bd-zlws)
# (ensure_clean_or_fail, record_worktree_mapping, get_worktree_path, etc.)
#
# Tests worktree creation and management for isolated reviews.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source helper functions from ru
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "is_git_repo"
source_ru_function "ensure_dir"
source_ru_function "get_worktrees_dir"
source_ru_function "ensure_clean_or_fail"
source_ru_function "record_worktree_mapping"
source_ru_function "get_worktree_path"
source_ru_function "get_worktree_mapping"
source_ru_function "list_review_worktrees"
source_ru_function "worktree_exists"

# Mock log functions for testing
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_worktree_test() {
    # Create temp directories
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    export PROJECTS_DIR="$TEST_DIR/projects"
    export LAYOUT="flat"
    REVIEW_RUN_ID="test-run-$(date +%s)"
    export REVIEW_RUN_ID
    mkdir -p "$RU_STATE_DIR" "$PROJECTS_DIR"
}

create_test_repo() {
    local name="${1:-test-repo}"
    local repo_dir="$PROJECTS_DIR/$name"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init --quiet
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"
    echo "test content" > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md
    git -C "$repo_dir" commit -m "Initial commit" --quiet
    echo "$repo_dir"
}

#==============================================================================
# Tests: ensure_clean_or_fail
#==============================================================================

test_ensure_clean_clean_repo() {
    setup_worktree_test
    local repo_dir
    repo_dir=$(create_test_repo "clean-repo")

    # Clean repo should pass
    ensure_clean_or_fail "$repo_dir" 2>/dev/null
    assert_exit_code 0 "Clean repo should pass ensure_clean_or_fail" true
}

test_ensure_clean_dirty_repo() {
    setup_worktree_test
    local repo_dir
    repo_dir=$(create_test_repo "dirty-repo")

    # Make it dirty
    echo "uncommitted" > "$repo_dir/dirty.txt"

    # Dirty repo should fail
    assert_fails "Dirty repo should fail ensure_clean_or_fail" ensure_clean_or_fail "$repo_dir"
}

test_ensure_clean_not_git_repo() {
    setup_worktree_test
    local not_git="$TEST_DIR/not-a-repo"
    mkdir -p "$not_git"

    # Non-git directory should fail
    assert_fails "Non-git directory should fail ensure_clean_or_fail" ensure_clean_or_fail "$not_git"
}

#==============================================================================
# Tests: get_worktrees_dir
#==============================================================================

test_get_worktrees_dir_format() {
    setup_worktree_test

    local dir
    dir=$(get_worktrees_dir)

    # Should include state dir
    assert_contains "$dir" "$RU_STATE_DIR" "Worktrees dir should include state dir"

    # Should include run ID
    assert_contains "$dir" "$REVIEW_RUN_ID" "Worktrees dir should include run ID"
}

#==============================================================================
# Tests: record_worktree_mapping / get_worktree_path
#==============================================================================

test_record_and_get_worktree_mapping() {
    setup_worktree_test

    # Record a mapping
    record_worktree_mapping "owner/repo" "/path/to/worktree" "ru/review/test/owner-repo" 2>/dev/null

    # Verify mapping file exists
    local mapping_file
    mapping_file="$(get_worktrees_dir)/mapping.json"
    assert_file_exists "$mapping_file" "Mapping file should be created"

    # Retrieve the mapping
    local wt_path=""
    if get_worktree_path "owner/repo" wt_path 2>/dev/null; then
        assert_equals "/path/to/worktree" "$wt_path" "Should retrieve correct worktree path"
    else
        fail "get_worktree_path should succeed for recorded repo"
    fi
}

test_record_multiple_mappings() {
    setup_worktree_test

    # Record multiple mappings
    record_worktree_mapping "owner/repo1" "/path/to/wt1" "branch1" 2>/dev/null
    record_worktree_mapping "owner/repo2" "/path/to/wt2" "branch2" 2>/dev/null
    record_worktree_mapping "other/repo3" "/path/to/wt3" "branch3" 2>/dev/null

    # Verify all can be retrieved
    local wt1="" wt2="" wt3=""
    get_worktree_path "owner/repo1" wt1 2>/dev/null
    get_worktree_path "owner/repo2" wt2 2>/dev/null
    get_worktree_path "other/repo3" wt3 2>/dev/null

    assert_equals "/path/to/wt1" "$wt1" "First repo path correct"
    assert_equals "/path/to/wt2" "$wt2" "Second repo path correct"
    assert_equals "/path/to/wt3" "$wt3" "Third repo path correct"
}

test_get_worktree_path_not_found() {
    setup_worktree_test

    local wt_path=""
    assert_fails "Nonexistent repo should return failure" get_worktree_path "nonexistent/repo" wt_path
}

#==============================================================================
# Tests: get_worktree_mapping (from work item)
#==============================================================================

test_get_worktree_mapping_from_item() {
    setup_worktree_test

    # Record a mapping
    record_worktree_mapping "owner/repo" "/path/to/wt" "branch" 2>/dev/null

    # Get mapping using work item format
    local repo_id="" wt_path=""
    get_worktree_mapping "owner/repo|issue|123|Title|labels|2025-01-01|2025-01-02|false" repo_id wt_path

    assert_equals "owner/repo" "$repo_id" "Should extract repo_id from work item"
    assert_equals "/path/to/wt" "$wt_path" "Should get correct worktree path"
}

#==============================================================================
# Tests: list_review_worktrees
#==============================================================================

test_list_review_worktrees_empty() {
    setup_worktree_test

    local result
    result=$(list_review_worktrees 2>/dev/null)

    assert_equals "{}" "$result" "Empty worktrees should return empty JSON object"
}

test_list_review_worktrees_with_entries() {
    setup_worktree_test

    # Record some mappings
    record_worktree_mapping "owner/repo1" "/path/to/wt1" "branch1" 2>/dev/null
    record_worktree_mapping "owner/repo2" "/path/to/wt2" "branch2" 2>/dev/null

    local result
    result=$(list_review_worktrees 2>/dev/null)

    # Should contain both repos
    assert_contains "$result" "owner/repo1" "List should contain first repo"
    assert_contains "$result" "owner/repo2" "List should contain second repo"
}

#==============================================================================
# Tests: worktree_exists
#==============================================================================

test_worktree_exists_not_found() {
    setup_worktree_test

    assert_fails "Nonexistent worktree should return false" worktree_exists "nonexistent/repo"
}

test_worktree_exists_recorded_but_no_dir() {
    setup_worktree_test

    # Record a mapping to a path that doesn't exist
    record_worktree_mapping "owner/repo" "/nonexistent/path" "branch" 2>/dev/null

    assert_fails "Recorded but non-existent worktree should return false" worktree_exists "owner/repo"
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "Running worktree unit tests..."
echo ""

# ensure_clean_or_fail tests
run_test test_ensure_clean_clean_repo
run_test test_ensure_clean_dirty_repo
run_test test_ensure_clean_not_git_repo

# get_worktrees_dir tests
run_test test_get_worktrees_dir_format

# record/get worktree mapping tests
run_test test_record_and_get_worktree_mapping
run_test test_record_multiple_mappings
run_test test_get_worktree_path_not_found

# get_worktree_mapping (work item) tests
run_test test_get_worktree_mapping_from_item

# list_review_worktrees tests
run_test test_list_review_worktrees_empty
run_test test_list_review_worktrees_with_entries

# worktree_exists tests
run_test test_worktree_exists_not_found
run_test test_worktree_exists_recorded_but_no_dir

# Print results
print_results
