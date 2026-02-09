#!/usr/bin/env bash
#
# test_e2e_fork_sync.sh - E2E tests for ru fork-sync command
#
# Tests fork synchronization with upstream remotes.
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

# Create a simulated fork setup: origin (bare) + upstream (bare) + local clone
# Args: $1=repo_name
# Sets: UPSTREAM_DIR, ORIGIN_DIR, LOCAL_DIR in caller
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

add_upstream_commit() {
    local upstream_dir="$1"
    local msg="$2"
    local tmp_clone="$E2E_TEMP_DIR/tmp_upstream_${RANDOM}"
    git clone "$upstream_dir" "$tmp_clone" --quiet 2>/dev/null
    echo "$msg" >> "$tmp_clone/README.md"
    git -C "$tmp_clone" add README.md
    git -C "$tmp_clone" commit -m "$msg" --quiet
    git -C "$tmp_clone" push origin main --quiet 2>/dev/null
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

test_ff_only_sync_succeeds() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "ffrepo"

    # Add upstream commits
    add_upstream_commit "$UPSTREAM_DIR" "upstream change"

    init_fork_config "test_owner/ffrepo"

    # Verify we're behind before sync
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null
    local before_rev
    before_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync exits 0"
    assert_contains "$output" "synced" "Reports sync success"

    # Verify HEAD advanced
    local after_rev
    after_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)
    if [[ "$before_rev" != "$after_rev" ]]; then
        pass "HEAD advanced after sync"
    else
        fail "HEAD should have advanced after sync"
    fi

    e2e_cleanup
}

test_diverged_skipped_ff_only() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "divergerepo"

    add_upstream_commit "$UPSTREAM_DIR" "upstream diverge"
    add_local_commit "$LOCAL_DIR" "local diverge"
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null

    init_fork_config "test_owner/divergerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --no-fetch 2>&1) || exit_code=$?

    # Should skip diverged repos with ff-only
    assert_contains "$output" "diverged" "Notes diverged state"
    assert_contains "$output" "0 synced" "Summary shows 0 synced"

    e2e_cleanup
}

test_rebase_sync() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "rebaserepo"

    add_upstream_commit "$UPSTREAM_DIR" "upstream for rebase"
    add_local_commit "$LOCAL_DIR" "local for rebase"
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null

    init_fork_config "test_owner/rebaserepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --rebase --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync --rebase exits 0"
    assert_contains "$output" "synced via rebase" "Reports rebase sync success"

    e2e_cleanup
}

test_dry_run_no_changes() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "dryrepo"

    add_upstream_commit "$UPSTREAM_DIR" "upstream dry"

    init_fork_config "test_owner/dryrepo"

    local before_rev
    before_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --dry-run 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync --dry-run exits 0"
    assert_contains "$output" "dry-run" "Shows dry-run indicator"
    assert_contains "$output" "Dry run" "Shows dry-run header"

    local after_rev
    after_rev=$(git -C "$LOCAL_DIR" rev-parse HEAD)
    assert_equals "$before_rev" "$after_rev" "HEAD unchanged after dry-run"

    e2e_cleanup
}

test_repos_filter() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "targetrepo"
    add_upstream_commit "$UPSTREAM_DIR" "target upstream"

    local UPSTREAM_DIR2 ORIGIN_DIR2 LOCAL_DIR2
    setup_fork_env "skippedrep"
    add_upstream_commit "$UPSTREAM_DIR" "skipped upstream"

    rm -rf "$XDG_CONFIG_HOME/ru"
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1
    echo "target_owner/targetrepo" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "skip_owner/skippedrep" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --repos='target_owner/*' 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync with --repos filter exits 0"
    assert_contains "$output" "targetrepo" "Shows filtered repo"

    e2e_cleanup
}

test_already_synced_skipped() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "syncedrepo"

    init_fork_config "test_owner/syncedrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync exits 0 for already synced"
    assert_contains "$output" "0 synced" "Summary shows 0 synced (already up to date)"

    e2e_cleanup
}

test_dirty_working_tree_skipped() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "dirtyrepo"

    add_upstream_commit "$UPSTREAM_DIR" "upstream for dirty"

    # Make working tree dirty
    echo "uncommitted" > "$LOCAL_DIR/dirty.txt"

    init_fork_config "test_owner/dirtyrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync 2>&1) || exit_code=$?

    assert_contains "$output" "uncommitted changes" "Notes dirty working tree"
    assert_contains "$output" "0 synced" "Does not sync dirty repo"

    e2e_cleanup
}

test_merge_sync() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "mergerepo"

    add_upstream_commit "$UPSTREAM_DIR" "upstream for merge"
    add_local_commit "$LOCAL_DIR" "local for merge"
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null

    init_fork_config "test_owner/mergerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-sync --merge --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync --merge exits 0"
    assert_contains "$output" "synced via merge" "Reports merge sync success"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru fork-sync"

run_test test_ff_only_sync_succeeds
run_test test_diverged_skipped_ff_only
run_test test_rebase_sync
run_test test_dry_run_no_changes
run_test test_repos_filter
run_test test_already_synced_skipped
run_test test_dirty_working_tree_skipped
run_test test_merge_sync

print_results
exit "$(get_exit_code)"
