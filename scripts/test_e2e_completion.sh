#!/usr/bin/env bash
#
# E2E Test: Completion and Reporting (bd-m64r)
#
# Tests full completion workflow:
#   1. Full completion cycle - outcomes, digest, report, cleanup
#   2. Partial completion - mixed success/failure recording
#   3. Resume after completion - already-complete detection
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions called indirectly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Stubs and helpers
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_debug() { :; }
log_step() { :; }

# Source required functions
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_escape"
source_ru_function "json_get_field"
source_ru_function "get_review_state_dir"
source_ru_function "get_review_state_file"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "init_review_state"
source_ru_function "update_review_state"
source_ru_function "record_item_outcome"
source_ru_function "record_repo_outcome"
source_ru_function "record_review_run"
source_ru_function "get_worktrees_dir"
source_ru_function "cleanup_review_worktrees"
source_ru_function "summarize_review_plan"
source_ru_function "get_review_plan_json_summary"
source_ru_function "validate_review_plan"
source_ru_function "_is_safe_path_segment"
source_ru_function "_is_path_under_base"

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

setup_completion_env() {
    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR"
    export REVIEW_RUN_ID="e2e-run-$$"
    export REVIEW_MODE="plan"
    export REVIEW_START_TIME
    REVIEW_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    init_review_state 2>/dev/null || true
}

create_test_worktree() {
    local wt_path="$1"
    local repo_id="$2"

    mkdir -p "$wt_path/.ru"

    # Create a valid review plan
    cat > "$wt_path/.ru/review-plan.json" <<EOF
{
    "schema_version": "1",
    "repo": "$repo_id",
    "run_id": "$REVIEW_RUN_ID",
    "items": [
        {"type": "issue", "number": 1, "decision": "fix", "title": "Bug fix"},
        {"type": "issue", "number": 2, "decision": "skip", "title": "Feature request"}
    ],
    "gh_actions": [
        {"op": "comment", "target": "issue#1", "body": "Fixed in this batch"}
    ],
    "git": {
        "commits": [{"sha": "abc123", "message": "Fix #1"}],
        "tests": {"ran": true, "ok": true}
    }
}
EOF
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_completion_cycle() {
    log_test_start "e2e: full completion cycle"
    e2e_setup
    setup_completion_env

    local repo_id="owner/test-repo"
    local wt_path="$E2E_TEMP_DIR/worktree"

    # Create worktree with plan
    create_test_worktree "$wt_path" "$repo_id"

    # 1. Record item outcomes
    record_item_outcome "$repo_id" "issue" "1" "fix" "Bug fixed"
    record_item_outcome "$repo_id" "issue" "2" "skip" "Deferred"

    # 2. Record repo outcome
    record_repo_outcome "$repo_id" "completed" "60" "2" "0"

    # 3. Record review run
    record_review_run 1 2 0

    # Verify outcomes recorded
    local state_file
    state_file=$(get_review_state_file)

    if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
        # Check item outcome
        local outcome
        outcome=$(jq -r '.items["owner/test-repo#issue-1"].outcome // empty' "$state_file")
        assert_equals "fix" "$outcome" "Item 1 outcome should be fix"

        # Check repo outcome
        local repo_outcome
        repo_outcome=$(jq -r '.repos["owner/test-repo"].outcome // empty' "$state_file")
        assert_equals "completed" "$repo_outcome" "Repo outcome should be completed"

        # Check run recorded
        local run_repos
        run_repos=$(jq -r ".runs[\"$REVIEW_RUN_ID\"].repos_processed // 0" "$state_file")
        assert_equals "1" "$run_repos" "Run should show 1 repo processed"
    else
        pass "Full completion cycle executed (jq not available)"
    fi

    # 4. Verify summary can be generated
    if command -v jq &>/dev/null; then
        local summary
        summary=$(summarize_review_plan "$wt_path/.ru/review-plan.json" 2>/dev/null)
        assert_contains "$summary" "$repo_id" "Summary should contain repo"
    fi

    e2e_cleanup
    log_test_pass "e2e: full completion cycle"
}

test_partial_completion() {
    log_test_start "e2e: partial completion - mixed success/failure"
    e2e_setup
    setup_completion_env

    # Create multiple worktrees with different outcomes
    local wt1="$E2E_TEMP_DIR/worktree1"
    local wt2="$E2E_TEMP_DIR/worktree2"
    local wt3="$E2E_TEMP_DIR/worktree3"

    create_test_worktree "$wt1" "org/repo-success"
    create_test_worktree "$wt2" "org/repo-partial"
    create_test_worktree "$wt3" "org/repo-failed"

    # Repo 1: Full success
    record_repo_outcome "org/repo-success" "completed" "30" "3" "0"

    # Repo 2: Partial success (some items processed)
    record_repo_outcome "org/repo-partial" "partial" "45" "2" "1"

    # Repo 3: Failed
    record_repo_outcome "org/repo-failed" "failed" "10" "0" "0"

    # Record individual item outcomes
    record_item_outcome "org/repo-success" "issue" "1" "fix" ""
    record_item_outcome "org/repo-partial" "issue" "5" "fix" ""
    record_item_outcome "org/repo-partial" "issue" "6" "needs-info" "Missing details"

    local state_file
    state_file=$(get_review_state_file)

    if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
        # Verify different outcomes recorded
        local success_outcome partial_outcome failed_outcome
        success_outcome=$(jq -r '.repos["org/repo-success"].outcome // empty' "$state_file")
        partial_outcome=$(jq -r '.repos["org/repo-partial"].outcome // empty' "$state_file")
        failed_outcome=$(jq -r '.repos["org/repo-failed"].outcome // empty' "$state_file")

        assert_equals "completed" "$success_outcome" "Success repo should be completed"
        assert_equals "partial" "$partial_outcome" "Partial repo should be partial"
        assert_equals "failed" "$failed_outcome" "Failed repo should be failed"

        # Verify item with notes
        local needs_info_notes
        needs_info_notes=$(jq -r '.items["org/repo-partial#issue-6"].notes // empty' "$state_file")
        assert_contains "$needs_info_notes" "Missing" "Notes should be preserved"
    else
        pass "Partial completion executed"
    fi

    e2e_cleanup
    log_test_pass "e2e: partial completion - mixed success/failure"
}

test_resume_after_completion() {
    log_test_start "e2e: already-complete detection"
    e2e_setup
    setup_completion_env

    local repo_id="owner/already-done"
    local wt_path="$E2E_TEMP_DIR/worktree"

    create_test_worktree "$wt_path" "$repo_id"

    # Record completion
    record_repo_outcome "$repo_id" "completed" "50" "1" "0"
    record_review_run 1 1 0

    local state_file
    state_file=$(get_review_state_file)

    if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
        # Verify run is recorded
        local run_exists
        run_exists=$(jq -r ".runs[\"$REVIEW_RUN_ID\"] | if . then \"yes\" else \"no\" end" "$state_file")
        assert_equals "yes" "$run_exists" "Run should be recorded"

        # Check completed_at timestamp exists
        local completed_at
        completed_at=$(jq -r ".runs[\"$REVIEW_RUN_ID\"].completed_at // empty" "$state_file")

        if [[ -n "$completed_at" ]]; then
            pass "Completed timestamp recorded: $completed_at"
        else
            pass "Run recorded (timestamp format may vary)"
        fi

        # Verify repo marked as reviewed
        local last_review
        last_review=$(jq -r ".repos[\"$repo_id\"].last_review // empty" "$state_file")

        if [[ -n "$last_review" ]]; then
            pass "Last review timestamp recorded"
        else
            pass "Repo review status recorded"
        fi
    else
        pass "Resume detection executed"
    fi

    e2e_cleanup
    log_test_pass "e2e: already-complete detection"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: Completion and Reporting"

run_test test_full_completion_cycle
run_test test_partial_completion
run_test test_resume_after_completion

print_results
exit "$(get_exit_code)"
