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
source_ru_function "_is_safe_path_segment"
source_ru_function "_is_path_under_base"
source_ru_function "is_git_repo"
source_ru_function "repo_is_dirty"
source_ru_function "ensure_dir"
source_ru_function "get_worktrees_dir"
source_ru_function "ensure_clean_or_fail"
source_ru_function "record_worktree_mapping"
source_ru_function "get_worktree_path"
source_ru_function "get_worktree_mapping"
source_ru_function "list_review_worktrees"
source_ru_function "worktree_exists"
source_ru_function "get_main_repo_path_from_worktree"
source_ru_function "cleanup_review_worktrees"
source_ru_function "get_digest_cache_dir"
source_ru_function "prepare_repo_digest_for_worktree"
source_ru_function "update_digest_cache"

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
    assert_exit_code 0 "Clean repo should pass ensure_clean_or_fail" \
        ensure_clean_or_fail "$repo_dir"
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
    record_worktree_mapping "owner/repo" "/path/to/worktree" "ru/review/test/owner-repo" "main" 2>/dev/null

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

    if command -v jq &>/dev/null; then
        local mapped_path="" mapped_base=""
        mapped_path=$(jq -r '."owner/repo".worktree_path // ""' "$mapping_file")
        mapped_base=$(jq -r '."owner/repo".base_ref // ""' "$mapping_file")
        assert_equals "/path/to/worktree" "$mapped_path" "Mapping should store worktree_path"
        assert_equals "main" "$mapped_base" "Mapping should store base_ref"
    fi
}

test_record_multiple_mappings() {
    setup_worktree_test

    # Record multiple mappings
    record_worktree_mapping "owner/repo1" "/path/to/wt1" "branch1" "main" 2>/dev/null
    record_worktree_mapping "owner/repo2" "/path/to/wt2" "branch2" "main" 2>/dev/null
    record_worktree_mapping "other/repo3" "/path/to/wt3" "branch3" "main" 2>/dev/null

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
    record_worktree_mapping "owner/repo" "/path/to/wt" "branch" "main" 2>/dev/null

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
    record_worktree_mapping "owner/repo1" "/path/to/wt1" "branch1" "main" 2>/dev/null
    record_worktree_mapping "owner/repo2" "/path/to/wt2" "branch2" "main" 2>/dev/null

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
    record_worktree_mapping "owner/repo" "/nonexistent/path" "branch" "main" 2>/dev/null

    assert_fails "Recorded but non-existent worktree should return false" worktree_exists "owner/repo"
}

#==============================================================================
# Tests: get_main_repo_path_from_worktree
#==============================================================================

test_get_main_repo_path_from_worktree_actual_worktree() {
    local test_name="get_main_repo_path_from_worktree: returns main repo from worktree"
    log_test_start "$test_name"
    setup_worktree_test

    # Create main repo
    local main_repo
    main_repo=$(create_test_repo "main-repo")

    # Create a worktree
    local worktree_dir="$TEST_DIR/worktrees/feature-branch"
    mkdir -p "$(dirname "$worktree_dir")"
    git -C "$main_repo" worktree add "$worktree_dir" -b feature-branch 2>/dev/null

    # Get main repo from worktree
    local result
    result=$(get_main_repo_path_from_worktree "$worktree_dir")

    assert_equals "$main_repo" "$result" "Should return main repo path from worktree"

    # Cleanup worktree
    git -C "$main_repo" worktree remove "$worktree_dir" 2>/dev/null || true

    log_test_pass "$test_name"
}

test_get_main_repo_path_from_worktree_main_repo() {
    local test_name="get_main_repo_path_from_worktree: returns self from main repo"
    log_test_start "$test_name"
    setup_worktree_test

    # Create main repo
    local main_repo
    main_repo=$(create_test_repo "standalone-repo")

    # Get main repo from itself (not a worktree)
    local result
    result=$(get_main_repo_path_from_worktree "$main_repo")

    assert_equals "$main_repo" "$result" "Should return repo path when called on main repo"

    log_test_pass "$test_name"
}

test_get_main_repo_path_from_worktree_not_git() {
    local test_name="get_main_repo_path_from_worktree: fails for non-git directory"
    log_test_start "$test_name"
    setup_worktree_test

    local not_git="$TEST_DIR/not-a-git-repo"
    mkdir -p "$not_git"

    assert_fails "Should fail for non-git directory" get_main_repo_path_from_worktree "$not_git"

    log_test_pass "$test_name"
}

test_get_main_repo_path_from_worktree_multiple_worktrees() {
    local test_name="get_main_repo_path_from_worktree: works with multiple worktrees"
    log_test_start "$test_name"
    setup_worktree_test

    # Create main repo
    local main_repo
    main_repo=$(create_test_repo "multi-wt-repo")

    # Create multiple worktrees
    local wt1="$TEST_DIR/worktrees/wt1"
    local wt2="$TEST_DIR/worktrees/wt2"
    mkdir -p "$(dirname "$wt1")"
    git -C "$main_repo" worktree add "$wt1" -b branch1 2>/dev/null
    git -C "$main_repo" worktree add "$wt2" -b branch2 2>/dev/null

    # Both worktrees should point to same main repo
    local result1 result2
    result1=$(get_main_repo_path_from_worktree "$wt1")
    result2=$(get_main_repo_path_from_worktree "$wt2")

    assert_equals "$main_repo" "$result1" "First worktree should return main repo"
    assert_equals "$main_repo" "$result2" "Second worktree should return main repo"

    # Cleanup
    git -C "$main_repo" worktree remove "$wt1" 2>/dev/null || true
    git -C "$main_repo" worktree remove "$wt2" 2>/dev/null || true

    log_test_pass "$test_name"
}

test_cleanup_review_worktrees_refuses_outside_mapping_paths() {
    local test_name="cleanup_review_worktrees: refuses to rm -rf outside base when mapping.json is corrupt"
    log_test_start "$test_name"
    setup_worktree_test

    local base
    base=$(get_worktrees_dir)
    mkdir -p "$base"

    local outside="$TEST_DIR/outside-target"
    mkdir -p "$outside"

    # Seed a corrupt mapping.json that points outside the run directory.
    cat > "$base/mapping.json" <<EOF
{"owner/repo":{"worktree_path":"$outside","branch":"branch","base_ref":"main","created_at":"2026-01-01T00:00:00Z"}}
EOF

    cleanup_review_worktrees "$REVIEW_RUN_ID" 2>/dev/null || true

    assert_dir_exists "$outside" "Should not delete directories outside the run base"
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Digest Cache Functions (bd-ai1z)
#==============================================================================

test_digest_cache_copy() {
    local test_name="prepare_repo_digest_for_worktree: copies cached digest to worktree"
    log_test_start "$test_name"
    setup_worktree_test

    local main_repo
    main_repo=$(create_test_repo "digest-copy-repo")
    local wt_dir="$TEST_DIR/worktrees/digest-copy-wt"
    mkdir -p "$(dirname "$wt_dir")"
    git -C "$main_repo" worktree add "$wt_dir" -b test-branch 2>/dev/null
    mkdir -p "$wt_dir/.ru"

    local cache_dir
    cache_dir=$(get_digest_cache_dir)
    mkdir -p "$cache_dir"
    echo "# Cached Digest for owner/digest-copy-repo" > "$cache_dir/owner_digest-copy-repo.md"

    local current_sha
    current_sha=$(git -C "$wt_dir" rev-parse HEAD)
    printf '{"last_commit": "%s", "last_review_at": "2025-01-01T00:00:00Z", "digest_version": 1}\n' "$current_sha" \
        > "$cache_dir/owner_digest-copy-repo.meta.json"

    prepare_repo_digest_for_worktree "owner/digest-copy-repo" "$wt_dir" 2>/dev/null

    assert_file_exists "$wt_dir/.ru/repo-digest.md" "Digest should be copied to worktree"
    assert_file_contains "$wt_dir/.ru/repo-digest.md" "Cached Digest" "Digest content should match"

    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || true
    log_test_pass "$test_name"
}

test_digest_delta_computation() {
    local test_name="prepare_repo_digest_for_worktree: appends delta when commits differ"
    log_test_start "$test_name"
    setup_worktree_test

    local main_repo
    main_repo=$(create_test_repo "delta-repo")
    local old_sha
    old_sha=$(git -C "$main_repo" rev-parse HEAD)

    echo "new content" > "$main_repo/new-file.txt"
    git -C "$main_repo" add new-file.txt
    git -C "$main_repo" commit -m "First new commit" --quiet
    echo "more content" >> "$main_repo/new-file.txt"
    git -C "$main_repo" add new-file.txt
    git -C "$main_repo" commit -m "Second new commit" --quiet

    local wt_dir="$TEST_DIR/worktrees/delta-wt"
    mkdir -p "$(dirname "$wt_dir")"
    git -C "$main_repo" worktree add "$wt_dir" -b delta-branch 2>/dev/null
    mkdir -p "$wt_dir/.ru"

    local cache_dir
    cache_dir=$(get_digest_cache_dir)
    mkdir -p "$cache_dir"
    echo "# Cached Digest" > "$cache_dir/owner_delta-repo.md"
    printf '{"last_commit": "%s", "last_review_at": "2025-01-01T00:00:00Z", "digest_version": 1}\n' "$old_sha" \
        > "$cache_dir/owner_delta-repo.meta.json"

    prepare_repo_digest_for_worktree "owner/delta-repo" "$wt_dir" 2>/dev/null

    assert_file_contains "$wt_dir/.ru/repo-digest.md" "Changes Since Last Review" \
        "Delta section should be appended"
    assert_file_contains "$wt_dir/.ru/repo-digest.md" "new commit" \
        "Delta should contain commit messages"

    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || true
    log_test_pass "$test_name"
}

test_digest_cache_update() {
    local test_name="update_digest_cache: saves digest and metadata to cache"
    log_test_start "$test_name"
    setup_worktree_test

    local main_repo
    main_repo=$(create_test_repo "cache-update-repo")
    local wt_dir="$TEST_DIR/worktrees/cache-update-wt"
    mkdir -p "$(dirname "$wt_dir")"
    git -C "$main_repo" worktree add "$wt_dir" -b cache-branch 2>/dev/null
    mkdir -p "$wt_dir/.ru"

    echo "# New Digest Created by Agent" > "$wt_dir/.ru/repo-digest.md"
    echo "Key patterns: async, factory" >> "$wt_dir/.ru/repo-digest.md"

    update_digest_cache "$wt_dir" "owner/cache-update-repo" 2>/dev/null

    local cache_dir
    cache_dir=$(get_digest_cache_dir)

    assert_file_exists "$cache_dir/owner_cache-update-repo.md" "Cache file should exist"
    assert_file_exists "$cache_dir/owner_cache-update-repo.meta.json" "Meta file should exist"
    assert_file_contains "$cache_dir/owner_cache-update-repo.md" "New Digest Created" \
        "Cache should contain agent's digest"

    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || true
    log_test_pass "$test_name"
}

test_digest_metadata_schema() {
    local test_name="update_digest_cache: creates valid metadata JSON with required fields"
    log_test_start "$test_name"
    setup_worktree_test

    local main_repo
    main_repo=$(create_test_repo "meta-schema-repo")
    local wt_dir="$TEST_DIR/worktrees/meta-schema-wt"
    mkdir -p "$(dirname "$wt_dir")"
    git -C "$main_repo" worktree add "$wt_dir" -b meta-branch 2>/dev/null
    mkdir -p "$wt_dir/.ru"

    echo "# Test Digest" > "$wt_dir/.ru/repo-digest.md"
    update_digest_cache "$wt_dir" "owner/meta-schema-repo" 2>/dev/null

    local cache_dir
    cache_dir=$(get_digest_cache_dir)
    local meta_file="$cache_dir/owner_meta-schema-repo.meta.json"

    if command -v jq &>/dev/null; then
        if jq empty "$meta_file" 2>/dev/null; then
            pass "Metadata is valid JSON"
        else
            fail "Metadata is not valid JSON"
        fi
        local last_commit last_review_at digest_version repo_id
        last_commit=$(jq -r '.last_commit' "$meta_file" 2>/dev/null)
        last_review_at=$(jq -r '.last_review_at' "$meta_file" 2>/dev/null)
        digest_version=$(jq -r '.digest_version' "$meta_file" 2>/dev/null)
        repo_id=$(jq -r '.repo' "$meta_file" 2>/dev/null)
        assert_not_empty "$last_commit" "Metadata should have last_commit"
        assert_not_empty "$last_review_at" "Metadata should have last_review_at"
        assert_equals "1" "$digest_version" "Metadata should have digest_version 1"
        assert_equals "owner/meta-schema-repo" "$repo_id" "Metadata should have repo id"
        if [[ "$last_commit" =~ ^[0-9a-f]{40}$ ]]; then
            pass "last_commit is valid SHA"
        else
            fail "last_commit is not a valid SHA: $last_commit"
        fi
    else
        skip_test "jq not available for JSON validation"
    fi

    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || true
    log_test_pass "$test_name"
}

test_digest_cache_no_cache_exists() {
    local test_name="prepare_repo_digest_for_worktree: returns success when no cache exists"
    log_test_start "$test_name"
    setup_worktree_test

    local main_repo
    main_repo=$(create_test_repo "no-cache-repo")
    local wt_dir="$TEST_DIR/worktrees/no-cache-wt"
    mkdir -p "$(dirname "$wt_dir")"
    git -C "$main_repo" worktree add "$wt_dir" -b no-cache-branch 2>/dev/null
    mkdir -p "$wt_dir/.ru"

    assert_exit_code 0 "Should succeed when no cache exists" \
        prepare_repo_digest_for_worktree "owner/no-cache-repo" "$wt_dir"

    if [[ -f "$wt_dir/.ru/repo-digest.md" ]]; then
        fail "Digest file should not exist when no cache available"
    else
        pass "No digest file created when no cache available"
    fi

    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || true
    log_test_pass "$test_name"
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

# get_main_repo_path_from_worktree tests
run_test test_get_main_repo_path_from_worktree_actual_worktree
run_test test_get_main_repo_path_from_worktree_main_repo
run_test test_get_main_repo_path_from_worktree_not_git
run_test test_get_main_repo_path_from_worktree_multiple_worktrees
run_test test_cleanup_review_worktrees_refuses_outside_mapping_paths

# Digest cache tests (bd-ai1z)
run_test test_digest_cache_copy
run_test test_digest_delta_computation
run_test test_digest_cache_update
run_test test_digest_metadata_schema
run_test test_digest_cache_no_cache_exists

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
