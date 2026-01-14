#!/usr/bin/env bash
#
# E2E Test: ru agent-sweep workflow
#
# Coverage:
# - dry-run listing of dirty repos
# - json dry-run output
# - single repo success with ntm/tmux mocks
# - preflight rebase detection
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test framework (test_e2e_framework.sh sources test_framework.sh internally)
source "$SCRIPT_DIR/test_e2e_framework.sh"

create_dirty_repo() {
    local name="$1"
    local repo_dir="$RU_PROJECTS_DIR/$name"
    local remote_dir="$E2E_TEMP_DIR/remotes/$name.git"

    # Create bare remote first
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare >/dev/null 2>&1

    # Create the working repo
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    echo "initial" > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md >/dev/null 2>&1
    git -C "$repo_dir" commit -m "init" >/dev/null 2>&1

    # Set up remote and push
    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1 || \
        git -C "$repo_dir" push -u origin master >/dev/null 2>&1

    # Create dirty file (must match mock tmux plan output: modified.txt)
    echo "dirty" > "$repo_dir/modified.txt"

    echo "$repo_dir"
}

test_agent_sweep_dry_run_lists_repo() {
    local test_name="agent-sweep: dry-run lists dirty repo"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_exit 0 "agent-sweep --dry-run" "dry-run exits 0"
    e2e_assert_ru_stderr_contains "agent-sweep --dry-run" "testrepo" "dry-run lists repo"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_json_dry_run() {
    local test_name="agent-sweep: json dry-run output"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_json "agent-sweep --dry-run --json" ".mode" "dry-run" "json mode is dry-run"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_single_repo_success() {
    local test_name="agent-sweep: single repo succeeds with mocks"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_exit 0 "agent-sweep" "agent-sweep exits 0 with mock ntm"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_preflight_rebase_in_progress() {
    local test_name="agent-sweep: preflight detects rebase in progress"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    mkdir -p "$repo_dir/.git/rebase-apply"

    e2e_assert_ru_exit 2 "agent-sweep --json" "preflight failure returns exit 2"

    local preflight_file="$XDG_STATE_HOME/ru/agent-sweep/preflight_results.ndjson"
    assert_true "[[ -f \"$preflight_file\" ]]" "preflight results file exists"
    assert_true "grep -q 'rebase_in_progress' \"$preflight_file\"" "rebase_in_progress recorded"

    e2e_cleanup
    log_test_pass "$test_name"
}

# Run tests
setup_cleanup_trap
run_test test_agent_sweep_dry_run_lists_repo
run_test test_agent_sweep_json_dry_run
run_test test_agent_sweep_single_repo_success
run_test test_preflight_rebase_in_progress
print_results
exit "$(get_exit_code)"
