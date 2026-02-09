#!/usr/bin/env bash
#
# test_e2e_fork_status.sh - E2E tests for ru fork-status command
#
# Tests fork sync status reporting against upstream remotes.
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
# Outputs: sets UPSTREAM_DIR, ORIGIN_DIR, LOCAL_DIR in caller
setup_fork_env() {
    local repo_name="$1"

    UPSTREAM_DIR="$E2E_TEMP_DIR/remotes/${repo_name}_upstream.git"
    ORIGIN_DIR="$E2E_TEMP_DIR/remotes/${repo_name}_origin.git"
    LOCAL_DIR="$RU_PROJECTS_DIR/${repo_name}"

    # Create upstream bare repo with initial commit on 'main' branch
    git init --bare --initial-branch=main "$UPSTREAM_DIR" --quiet
    local tmp_clone="$E2E_TEMP_DIR/tmp_clone_${repo_name}"
    git clone "$UPSTREAM_DIR" "$tmp_clone" --quiet 2>/dev/null
    git -C "$tmp_clone" checkout -b main --quiet 2>/dev/null || true
    echo "initial" > "$tmp_clone/README.md"
    git -C "$tmp_clone" add README.md
    git -C "$tmp_clone" commit -m "Initial commit" --quiet
    git -C "$tmp_clone" push origin main --quiet 2>/dev/null

    # Create origin bare repo (fork) by cloning upstream
    git clone --bare "$UPSTREAM_DIR" "$ORIGIN_DIR" --quiet 2>/dev/null

    # Clone from origin and add upstream remote
    git clone "$ORIGIN_DIR" "$LOCAL_DIR" --quiet 2>/dev/null
    git -C "$LOCAL_DIR" remote add upstream "$UPSTREAM_DIR"
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null

    # Set upstream HEAD ref so get_upstream_default_branch works
    git -C "$LOCAL_DIR" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/main 2>/dev/null || true
}

# Initialize ru config with a repo
# Args: $1=repo_spec
init_fork_config() {
    local repo_spec="$1"
    rm -rf "$XDG_CONFIG_HOME/ru"
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1
    echo "$repo_spec" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
}

# Add commits to upstream
# Args: $1=upstream_dir $2=message
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

# Add local commits to the fork
# Args: $1=local_dir $2=message
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

test_no_upstream_skips() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    # Create a repo without upstream remote
    local bare="$E2E_TEMP_DIR/remotes/nofork.git"
    git init --bare --initial-branch=main "$bare" --quiet
    local clone="$RU_PROJECTS_DIR/nofork"
    git clone "$bare" "$clone" --quiet 2>/dev/null
    git -C "$clone" checkout -b main --quiet 2>/dev/null || true
    echo "data" > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit -m "init" --quiet

    init_fork_config "test_owner/nofork"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0 when no forks found"
    assert_contains "$output" "0 checked" "Reports 0 repos checked"

    e2e_cleanup
}

test_synced_state() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "syncrepo"
    init_fork_config "test_owner/syncrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0 for synced repo"
    assert_contains "$output" "synced" "Reports synced status"
    assert_contains "$output" "1 synced" "Summary shows 1 synced"

    e2e_cleanup
}

test_behind_upstream() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "behindrepo"

    # Add commits to upstream
    add_upstream_commit "$UPSTREAM_DIR" "upstream change 1"
    add_upstream_commit "$UPSTREAM_DIR" "upstream change 2"

    init_fork_config "test_owner/behindrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0"
    assert_contains "$output" "behind" "Reports behind status"
    assert_contains "$output" "1 behind" "Summary shows 1 behind"

    e2e_cleanup
}

test_ahead_of_upstream() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "aheadrepo"

    # Add local commits
    add_local_commit "$LOCAL_DIR" "local change 1"

    init_fork_config "test_owner/aheadrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0"
    assert_contains "$output" "ahead" "Reports ahead status"
    assert_contains "$output" "polluted" "Detects pollution"
    assert_contains "$output" "1 polluted" "Summary shows 1 polluted"

    e2e_cleanup
}

test_diverged_state() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "divergerepo"

    # Add upstream commits
    add_upstream_commit "$UPSTREAM_DIR" "upstream diverge"

    # Add local commits
    add_local_commit "$LOCAL_DIR" "local diverge"

    # Fetch to see both sides
    git -C "$LOCAL_DIR" fetch upstream --quiet 2>/dev/null

    init_fork_config "test_owner/divergerepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0"
    assert_contains "$output" "diverged" "Reports diverged status"
    assert_contains "$output" "1 diverged" "Summary shows 1 diverged"

    e2e_cleanup
}

test_pollution_detection() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "polluterepo"

    # Add local commits directly on main (this is "pollution")
    add_local_commit "$LOCAL_DIR" "accidental commit on main"

    init_fork_config "test_owner/polluterepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status exits 0"
    assert_contains "$output" "polluted" "Detects main branch pollution"

    e2e_cleanup
}

test_dry_run() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "dryrunrepo"

    init_fork_config "test_owner/dryrunrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --dry-run --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status --dry-run exits 0"
    # Dry-run for fork-status behaves the same since it's read-only
    assert_contains "$output" "Fork Status" "Shows fork status header"

    e2e_cleanup
}

test_repos_filter() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "matchrepo"
    local UPSTREAM_DIR2 ORIGIN_DIR2 LOCAL_DIR2
    setup_fork_env "nomatchrepo"

    init_fork_config "match_owner/matchrepo"
    echo "other_owner/nomatchrepo" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --repos='match_owner/*' --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status with --repos filter exits 0"
    assert_contains "$output" "matchrepo" "Shows matching repo"

    e2e_cleanup
}

test_json_output() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    local UPSTREAM_DIR ORIGIN_DIR LOCAL_DIR
    setup_fork_env "jsonrepo"

    add_upstream_commit "$UPSTREAM_DIR" "json test commit"

    init_fork_config "test_owner/jsonrepo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --json 2>/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "fork-status --json exits 0"
    assert_contains "$output" '"command": "fork-status"' "JSON has correct command field"
    assert_contains "$output" '"repo":"test_owner/jsonrepo"' "JSON has repo field"
    assert_contains "$output" '"behind"' "JSON has behind field"

    e2e_cleanup
}

test_verbose_no_upstream() {
    e2e_setup
    mkdir -p "$E2E_TEMP_DIR/remotes"

    # Create repo without upstream
    local bare="$E2E_TEMP_DIR/remotes/plain.git"
    git init --bare --initial-branch=main "$bare" --quiet
    local clone="$RU_PROJECTS_DIR/plain"
    git clone "$bare" "$clone" --quiet 2>/dev/null
    git -C "$clone" checkout -b main --quiet 2>/dev/null || true
    echo "data" > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit -m "init" --quiet

    init_fork_config "test_owner/plain"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" fork-status --verbose --no-fetch 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "verbose fork-status exits 0"
    assert_contains "$output" "no upstream" "Verbose shows no upstream note"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru fork-status"

run_test test_no_upstream_skips
run_test test_synced_state
run_test test_behind_upstream
run_test test_ahead_of_upstream
run_test test_diverged_state
run_test test_pollution_detection
run_test test_dry_run
run_test test_repos_filter
run_test test_json_output
run_test test_verbose_no_upstream

print_results
exit "$(get_exit_code)"
