#!/usr/bin/env bash
#
# test_e2e_fork_clean.sh - E2E tests for ru fork-clean command
#
# Tests main branch pollution cleanup with rescue branch backup.
# Uses local bare repos as remotes (no network).
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test Helpers
#==============================================================================

setup_fork_env() {
    local repo_name="$1"

    UPSTREAM_DIR="$E2E_TEMP_DIR/remotes/${repo_name}_upstream.git"
    ORIGIN_DIR="$E2E_TEMP_DIR/remotes/${repo_name}_origin.git"
    LOCAL_DIR="$RU_PROJECTS_DIR/${repo_name}"

    git init --bare --initial-branch=main "$UPSTREAM_DIR" --quiet
    local tmp_clone="$E2E_TEMP_DIR/tmp_clone_${repo_name}"
    git clone "$UPSTREAM_DIR" "$tmp_clone" --quiet 2>/dev/null
    git -C "$tmp_clone" checkout -b main --quiet 2>/dev/null || true
    echo "initial" > "$tmp_clone/README.md"
    git -C "$tmp_clone" add README.md
    git -C "$tmp_clone" commit -m "Initial commit" --quiet
    git -C "$tmp_clone" push origin main --quiet 2>/dev/null

    git clone --bare "$UPSTREAM_DIR" "$ORIGIN_DIR" --quiet 2>/dev/null

    git clone "$ORIGIN_DIR" "$LOCAL_DIR" --quiet 2>/dev/null
    git -C "$LOCAL_DIR" remote add upstream "$UPSTREAM_DIR"
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null
    git -C "$LOCAL_DIR" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/main 2>/dev/null || true
}

init_fork_config() {
    local repo_spec="$1"
    rm -rf "$XDG_CONFIG_HOME/ru"
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1
    echo "$repo_spec" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
}

add_local_commit() {
    local local_dir="$1"
    local msg="$2"
    echo "$msg" >> "$local_dir/local_file.txt"
    git -C "$local_dir" add local_file.txt
    git -C "$local_dir" commit -m "$msg" --quiet
}

#==============================================================================
# Tests
#==============================================================================

test_creates_rescue_branch() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "rescuerepo"

    # Pollute main with local commits
    add_local_commit "$LOCAL_DIR" "pollution commit 1"
    add_local_commit "$LOCAL_DIR" "pollution commit 2"

    init_fork_config "test_owner/rescuerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean exits 0"
    assert_contains "$output" "rescue branch created" "Reports rescue branch creation"

    # Verify rescue branch exists
    local rescue_branches
    rescue_branches=$(git -C "$LOCAL_DIR" branch --list 'rescue/*' 2>/dev/null)
    if [[ -n "$rescue_branches" ]]; then
        pass "Rescue branch exists"
    else
        fail "Rescue branch should exist"
    fi

    e2e_cleanup
}

test_resets_main_to_upstream() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "resetrepo"

    add_local_commit "$LOCAL_DIR" "pollution"

    local upstream_rev
    upstream_rev=$(git -C "$LOCAL_DIR" rev-parse upstream/main)

    init_fork_config "test_owner/resetrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean exits 0"
    assert_contains "$output" "cleaned" "Reports clean success"

    # Verify main now matches upstream
    local current_rev
    current_rev=$(git -C "$LOCAL_DIR" rev-parse main)
    assert_equals "$upstream_rev" "$current_rev" "Main matches upstream after clean"

    e2e_cleanup
}

test_no_rescue_flag() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "norescuerepo"

    add_local_commit "$LOCAL_DIR" "pollution"

    init_fork_config "test_owner/norescuerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --no-rescue --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean --no-rescue exits 0"
    assert_contains "$output" "cleaned" "Reports clean success"

    # Verify no rescue branch exists
    local rescue_branches
    rescue_branches=$(git -C "$LOCAL_DIR" branch --list 'rescue/*' 2>/dev/null)
    if [[ -z "$rescue_branches" ]]; then
        pass "No rescue branch created with --no-rescue"
    else
        fail "Rescue branch should not exist with --no-rescue"
    fi

    e2e_cleanup
}

test_clean_repo_skipped() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "cleanrepo"

    # Don't add any local commits — repo is clean
    init_fork_config "test_owner/cleanrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean exits 0 for clean repo"
    assert_contains "$output" "0 cleaned" "Summary shows 0 cleaned"

    e2e_cleanup
}

test_dry_run_no_changes() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "dryrepo"

    add_local_commit "$LOCAL_DIR" "pollution"

    local before_rev
    before_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)

    init_fork_config "test_owner/dryrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --dry-run --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean --dry-run exits 0"
    assert_contains "$output" "dry-run" "Shows dry-run indicator"

    local after_rev
    after_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)
    assert_equals "$before_rev" "$after_rev" "HEAD unchanged after dry-run"

    # No rescue branch should exist
    local rescue_branches
    rescue_branches=$(git -C "$LOCAL_DIR" branch --list 'rescue/*' 2>/dev/null)
    if [[ -z "$rescue_branches" ]]; then
        pass "No rescue branch in dry-run mode"
    else
        fail "Rescue branch should not exist in dry-run"
    fi

    e2e_cleanup
}

test_reset_requires_force() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "forcerepo"

    add_local_commit "$LOCAL_DIR" "pollution"

    init_fork_config "test_owner/forcerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --reset --no-fetch 2>&1) || exit_code=$?

    assert_equals "4" "$exit_code" "fork-clean --reset without --force exits 4"
    assert_contains "$output" "requires --force" "Error mentions --force requirement"

    e2e_cleanup
}

test_reset_with_force() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "resetforcerepo"

    add_local_commit "$LOCAL_DIR" "pollution"

    local upstream_rev
    upstream_rev=$(git -C "$LOCAL_DIR" rev-parse upstream/main)

    init_fork_config "test_owner/resetforcerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --reset --force --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean --reset --force exits 0"
    assert_contains "$output" "cleaned" "Reports clean success"

    local current_rev
    current_rev=$(git -C "$LOCAL_DIR" rev-parse main)
    assert_equals "$upstream_rev" "$current_rev" "Main reset to upstream"

    e2e_cleanup
}

test_dirty_working_tree_skipped() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "dirtyrepo"

    add_local_commit "$LOCAL_DIR" "pollution"
    echo "uncommitted" > "$LOCAL_DIR/dirty.txt"

    init_fork_config "test_owner/dirtyrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-clean --no-fetch 2>&1) || exit_code=$?

    assert_contains "$output" "uncommitted changes" "Notes dirty working tree"
    assert_contains "$output" "0 cleaned" "Does not clean dirty repo"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru fork-clean"

run_test test_creates_rescue_branch
run_test test_resets_main_to_upstream
run_test test_no_rescue_flag
run_test test_clean_repo_skipped
run_test test_dry_run_no_changes
run_test test_reset_requires_force
run_test test_reset_with_force
run_test test_dirty_working_tree_skipped

print_results
exit "$(get_exit_code)"
