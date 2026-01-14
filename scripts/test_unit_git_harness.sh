#!/usr/bin/env bash
#
# Unit Tests: Git Harness
# Tests for the local git repository harness (test_git_harness.sh)
#
# Test coverage:
#   - git_harness_setup creates temp directory structure
#   - git_harness_cleanup removes temp directories
#   - git_harness_create_repo creates basic repo
#   - git_harness_create_repo --ahead creates local commits
#   - git_harness_create_repo --behind creates remote commits
#   - git_harness_create_repo --diverged creates diverged state
#   - git_harness_create_repo --dirty creates uncommitted changes
#   - git_harness_create_repo --shallow creates shallow clone
#   - git_harness_create_repo --detached creates detached HEAD
#   - git_harness_create_repo --no-remote creates repo without remote
#   - git_harness_create_repo --branch uses custom branch name
#   - git_harness_add_commit adds local commit
#   - git_harness_add_commit_and_push adds and pushes commit
#   - git_harness_make_dirty adds uncommitted changes
#   - git_harness_make_staged adds staged changes
#   - git_harness_add_untracked adds untracked file
#   - git_harness_simulate_rebase creates rebase state
#   - git_harness_simulate_merge creates merge state
#   - git_harness_get_status returns correct status
#   - git_harness_is_dirty detects dirty state
#   - git_harness_is_shallow detects shallow clone
#   - git_harness_is_detached detects detached HEAD
#
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source the git harness
source "$SCRIPT_DIR/test_git_harness.sh"

#==============================================================================
# Tests: Setup and Cleanup
#==============================================================================

test_setup_creates_temp_dir() {
    log_test_start "git_harness_setup creates temp directory"

    git_harness_setup
    local temp_dir
    temp_dir=$(git_harness_get_temp_dir)

    assert_true "[[ -d \"$temp_dir\" ]]" "Temp directory exists"
    assert_true "[[ -d \"$temp_dir/remotes\" ]]" "Remotes directory exists"
    assert_true "[[ -d \"$temp_dir/repos\" ]]" "Repos directory exists"
    assert_true "[[ -d \"$temp_dir/dev\" ]]" "Dev directory exists"

    git_harness_cleanup
    log_test_pass "git_harness_setup creates temp directory"
}

test_cleanup_removes_temp_dir() {
    log_test_start "git_harness_cleanup removes temp directories"

    git_harness_setup
    local temp_dir
    temp_dir=$(git_harness_get_temp_dir)

    git_harness_cleanup

    assert_true "[[ ! -d \"$temp_dir\" ]]" "Temp directory removed after cleanup"

    log_test_pass "git_harness_cleanup removes temp directories"
}

#==============================================================================
# Tests: Basic Repo Creation
#==============================================================================

test_create_repo_basic() {
    log_test_start "git_harness_create_repo creates basic repo"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "basic")

    assert_true "[[ -d \"$repo/.git\" ]]" "Repo has .git directory"
    assert_true "git -C \"$repo\" rev-parse HEAD >/dev/null 2>&1" "Repo has commits"
    assert_true "git -C \"$repo\" remote | grep -q origin" "Repo has origin remote"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo creates basic repo"
}

test_create_repo_no_remote() {
    log_test_start "git_harness_create_repo --no-remote"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "noremote" --no-remote)

    assert_true "[[ -d \"$repo/.git\" ]]" "Repo has .git directory"
    assert_false "git -C \"$repo\" remote | grep -q origin" "Repo has no origin remote"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --no-remote"
}

test_create_repo_custom_branch() {
    log_test_start "git_harness_create_repo --branch"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "custombranch" --branch=develop)

    local current_branch
    current_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

    assert_equals "develop" "$current_branch" "Current branch is develop"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --branch"
}

#==============================================================================
# Tests: Repo States
#==============================================================================

test_create_repo_ahead() {
    log_test_start "git_harness_create_repo --ahead"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "ahead" --ahead=2)

    local ahead_count
    ahead_count=$(git -C "$repo" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")

    assert_equals "2" "$ahead_count" "Repo is 2 commits ahead"

    local status
    status=$(git_harness_get_status "$repo")
    assert_equals "ahead" "$status" "Status is ahead"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --ahead"
}

test_create_repo_behind() {
    log_test_start "git_harness_create_repo --behind"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "behind" --behind=3)

    local behind_count
    behind_count=$(git -C "$repo" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "0")

    assert_equals "3" "$behind_count" "Repo is 3 commits behind"

    local status
    status=$(git_harness_get_status "$repo")
    assert_equals "behind" "$status" "Status is behind"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --behind"
}

test_create_repo_diverged() {
    log_test_start "git_harness_create_repo --diverged"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "diverged" --diverged)

    local ahead_count behind_count
    ahead_count=$(git -C "$repo" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")
    behind_count=$(git -C "$repo" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "0")

    assert_true "[[ $ahead_count -gt 0 ]]" "Repo has commits ahead"
    assert_true "[[ $behind_count -gt 0 ]]" "Repo has commits behind"

    local status
    status=$(git_harness_get_status "$repo")
    assert_equals "diverged" "$status" "Status is diverged"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --diverged"
}

test_create_repo_dirty() {
    log_test_start "git_harness_create_repo --dirty"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "dirty" --dirty)

    assert_true "git_harness_is_dirty \"$repo\"" "Repo is dirty"
    assert_true "[[ -f \"$repo/dirty.txt\" ]]" "Dirty file exists"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --dirty"
}

test_create_repo_shallow() {
    log_test_start "git_harness_create_repo --shallow"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "shallow" --shallow=2)

    assert_true "git_harness_is_shallow \"$repo\"" "Repo is shallow"
    # Use git plumbing to verify shallow status (per AGENTS.md)
    assert_true "[[ \"\$(git -C \"$repo\" rev-parse --is-shallow-repository)\" == \"true\" ]]" "Git reports shallow repository"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --shallow"
}

test_create_repo_detached() {
    log_test_start "git_harness_create_repo --detached"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "detached" --detached)

    assert_true "git_harness_is_detached \"$repo\"" "HEAD is detached"
    assert_false "git -C \"$repo\" symbolic-ref -q HEAD >/dev/null 2>&1" "symbolic-ref fails for detached"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo --detached"
}

test_create_repo_combined_options() {
    log_test_start "git_harness_create_repo with combined options"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "combined" --ahead=1 --behind=2 --dirty)

    local ahead_count behind_count
    ahead_count=$(git -C "$repo" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")
    behind_count=$(git -C "$repo" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "0")

    assert_equals "1" "$ahead_count" "Repo is 1 commit ahead"
    assert_equals "2" "$behind_count" "Repo is 2 commits behind"
    assert_true "git_harness_is_dirty \"$repo\"" "Repo is dirty"

    git_harness_cleanup
    log_test_pass "git_harness_create_repo with combined options"
}

#==============================================================================
# Tests: Manipulation Functions
#==============================================================================

test_add_commit() {
    log_test_start "git_harness_add_commit"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "addcommit")

    local before_count after_count
    before_count=$(git -C "$repo" rev-list --count HEAD)

    git_harness_add_commit "$repo" "Test commit message"

    after_count=$(git -C "$repo" rev-list --count HEAD)

    assert_equals "$((before_count + 1))" "$after_count" "Commit count increased by 1"

    git_harness_cleanup
    log_test_pass "git_harness_add_commit"
}

test_add_commit_and_push() {
    log_test_start "git_harness_add_commit_and_push"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "pushcommit")

    git_harness_add_commit_and_push "$repo" "Pushed commit"

    local ahead_count
    ahead_count=$(git -C "$repo" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")

    assert_equals "0" "$ahead_count" "No commits ahead after push"

    git_harness_cleanup
    log_test_pass "git_harness_add_commit_and_push"
}

test_make_dirty() {
    log_test_start "git_harness_make_dirty"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "makedirty")

    assert_false "git_harness_is_dirty \"$repo\"" "Repo starts clean"

    git_harness_make_dirty "$repo"

    assert_true "git_harness_is_dirty \"$repo\"" "Repo is now dirty"

    git_harness_cleanup
    log_test_pass "git_harness_make_dirty"
}

test_make_staged() {
    log_test_start "git_harness_make_staged"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "makestaged")

    git_harness_make_staged "$repo"

    # Check for staged changes
    local staged
    staged=$(git -C "$repo" diff --cached --name-only)

    assert_true "[[ -n \"$staged\" ]]" "Has staged changes"

    git_harness_cleanup
    log_test_pass "git_harness_make_staged"
}

test_add_untracked() {
    log_test_start "git_harness_add_untracked"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "untracked")

    git_harness_add_untracked "$repo" "newfile.txt"

    local untracked
    untracked=$(git -C "$repo" ls-files --others --exclude-standard)

    assert_true "[[ \"$untracked\" == *\"newfile.txt\"* ]]" "Untracked file detected"

    git_harness_cleanup
    log_test_pass "git_harness_add_untracked"
}

test_simulate_rebase() {
    log_test_start "git_harness_simulate_rebase"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "rebase")

    git_harness_simulate_rebase "$repo"

    assert_true "[[ -d \"$repo/.git/rebase-apply\" ]]" "rebase-apply directory exists"

    git_harness_cleanup
    log_test_pass "git_harness_simulate_rebase"
}

test_simulate_merge() {
    log_test_start "git_harness_simulate_merge"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "merge")

    git_harness_simulate_merge "$repo"

    assert_true "[[ -f \"$repo/.git/MERGE_HEAD\" ]]" "MERGE_HEAD file exists"

    git_harness_cleanup
    log_test_pass "git_harness_simulate_merge"
}

#==============================================================================
# Tests: Query Functions
#==============================================================================

test_get_status_current() {
    log_test_start "git_harness_get_status returns current"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "statuscurrent")

    local status
    status=$(git_harness_get_status "$repo")

    assert_equals "current" "$status" "Status is current for synced repo"

    git_harness_cleanup
    log_test_pass "git_harness_get_status returns current"
}

test_is_dirty_false() {
    log_test_start "git_harness_is_dirty returns false for clean"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "clean")

    assert_false "git_harness_is_dirty \"$repo\"" "Clean repo should not be dirty"

    git_harness_cleanup
    log_test_pass "git_harness_is_dirty returns false for clean"
}

test_is_dirty_true() {
    log_test_start "git_harness_is_dirty returns true for dirty"

    git_harness_setup
    local repo
    repo=$(git_harness_create_repo "dirtychk" --dirty)

    assert_true "git_harness_is_dirty \"$repo\"" "Dirty repo detected"

    git_harness_cleanup
    log_test_pass "git_harness_is_dirty returns true for dirty"
}

#==============================================================================
# Tests: Edge Cases
#==============================================================================

test_multiple_repos() {
    log_test_start "Multiple repos in same harness session"

    git_harness_setup

    local repo1 repo2 repo3
    repo1=$(git_harness_create_repo "multi1" --ahead=1)
    repo2=$(git_harness_create_repo "multi2" --behind=1)
    repo3=$(git_harness_create_repo "multi3" --dirty)

    assert_equals "ahead" "$(git_harness_get_status "$repo1")" "Repo1 is ahead"
    assert_equals "behind" "$(git_harness_get_status "$repo2")" "Repo2 is behind"
    assert_true "git_harness_is_dirty \"$repo3\"" "Repo3 is dirty"

    git_harness_cleanup
    log_test_pass "Multiple repos in same harness session"
}

test_harness_reuse() {
    log_test_start "Harness can be reused after cleanup"

    git_harness_setup
    local repo1
    repo1=$(git_harness_create_repo "first")
    git_harness_cleanup

    git_harness_setup
    local repo2
    repo2=$(git_harness_create_repo "second")

    assert_true "[[ -d \"$repo2/.git\" ]]" "Second repo exists after reuse"

    git_harness_cleanup
    log_test_pass "Harness can be reused after cleanup"
}

#==============================================================================
# Run Tests
#==============================================================================

setup_cleanup_trap

# Setup/Cleanup tests
run_test test_setup_creates_temp_dir
run_test test_cleanup_removes_temp_dir

# Basic creation tests
run_test test_create_repo_basic
run_test test_create_repo_no_remote
run_test test_create_repo_custom_branch

# State tests
run_test test_create_repo_ahead
run_test test_create_repo_behind
run_test test_create_repo_diverged
run_test test_create_repo_dirty
run_test test_create_repo_shallow
run_test test_create_repo_detached
run_test test_create_repo_combined_options

# Manipulation tests
run_test test_add_commit
run_test test_add_commit_and_push
run_test test_make_dirty
run_test test_make_staged
run_test test_add_untracked
run_test test_simulate_rebase
run_test test_simulate_merge

# Query tests
run_test test_get_status_current
run_test test_is_dirty_false
run_test test_is_dirty_true

# Edge cases
run_test test_multiple_repos
run_test test_harness_reuse

print_results
exit "$(get_exit_code)"
