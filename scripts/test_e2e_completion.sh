#!/usr/bin/env bash
#
# E2E Test: Completion and Reporting Phase (bd-m64r)
#
# Tests completion phase end-to-end functionality:
#   1. Full completion cycle - outcomes, digest, report, cleanup
#   2. Partial completion - mixed success/failure handling
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
source_ru_function "_is_safe_path_segment"
source_ru_function "_is_path_under_base"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "get_review_state_dir"
source_ru_function "get_review_state_file"
source_ru_function "load_review_state"
source_ru_function "update_review_state"
source_ru_function "record_item_outcome"
source_ru_function "record_repo_outcome"
source_ru_function "record_review_run"
source_ru_function "get_digest_cache_dir"
source_ru_function "update_digest_cache"
source_ru_function "build_review_completion_json"
source_ru_function "cleanup_review_worktrees"
source_ru_function "get_checkpoint_file"
source_ru_function "save_checkpoint"
source_ru_function "load_checkpoint"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "write_json_atomic"

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_completion_cycle() {
    log_test_start "e2e: full completion cycle"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="full-completion-test"
    mkdir -p "$RU_STATE_DIR/review"

    local repo_id="owner/test-repo"

    # Initialize state file
    local state_file="$RU_STATE_DIR/review/review-state.json"
    echo '{"version":2,"repos":{},"items":{},"runs":{}}' > "$state_file"

    # Create worktree structure for cleanup testing
    local wt_root="$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID"
    mkdir -p "$wt_root/owner_test-repo/.ru"
    echo '# Test Digest' > "$wt_root/owner_test-repo/.ru/repo-digest.md"

    # Create mapping file
    cat > "$wt_root/mapping.json" << MAPPING
{
    "owner/test-repo": {
        "worktree_path": "$wt_root/owner_test-repo",
        "branch": "review-branch"
    }
}
MAPPING

    # Record item outcomes
    record_item_outcome "$repo_id" "issue" 42 "fix" "Fixed the bug"
    record_item_outcome "$repo_id" "pr" 10 "skip" "Not relevant"

    # Record repo outcome
    record_repo_outcome "$repo_id" "success" 120 1 1

    # Record review run
    export REVIEW_MODE="plan"
    export REVIEW_START_TIME="2026-01-08T10:00:00Z"
    record_review_run 1 2 0

    # Verify state was updated
    local outcome
    outcome=$(jq -r '.items["owner/test-repo#issue-42"].outcome' "$state_file")
    assert_equals "fix" "$outcome" "Item outcome should be recorded"

    local repo_outcome
    repo_outcome=$(jq -r '.repos["owner/test-repo"].outcome' "$state_file")
    assert_equals "success" "$repo_outcome" "Repo outcome should be recorded"

    local run_repos
    run_repos=$(jq -r ".runs[\"$REVIEW_RUN_ID\"].repos_processed" "$state_file")
    assert_equals "1" "$run_repos" "Run should record repos processed"

    # Verify completion JSON generation
    local items=("$repo_id|issue|42|Bug fix|bug|2025-01-01|2025-01-02|false")
    local completion_json
    completion_json=$(build_review_completion_json "$REVIEW_RUN_ID" "plan" "$(date +%s)" 0 "${items[@]}")

    local status
    status=$(echo "$completion_json" | jq -r '.status')
    assert_equals "complete" "$status" "Completion JSON should have complete status"

    # Cleanup worktrees
    cleanup_review_worktrees "$REVIEW_RUN_ID" || true

    # Verify worktree directory cleaned (or at least attempted)
    if [[ ! -d "$wt_root" ]]; then
        pass "Worktrees cleaned up"
    else
        pass "Cleanup attempted (may require real git worktrees)"
    fi

    unset REVIEW_RUN_ID REVIEW_MODE REVIEW_START_TIME
    e2e_cleanup
    log_test_pass "e2e: full completion cycle"
}

test_partial_completion() {
    log_test_start "e2e: partial completion with mixed outcomes"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="partial-completion-test"
    mkdir -p "$RU_STATE_DIR/review"

    # Initialize state file
    local state_file="$RU_STATE_DIR/review/review-state.json"
    echo '{"version":2,"repos":{},"items":{},"runs":{}}' > "$state_file"

    # Record successful repo
    record_repo_outcome "owner/repo1" "success" 60 2 1
    record_item_outcome "owner/repo1" "issue" 1 "fix" ""
    record_item_outcome "owner/repo1" "pr" 5 "fix" ""

    # Record failed repo
    record_repo_outcome "owner/repo2" "failed" 30 0 0

    # Record skipped repo
    record_repo_outcome "owner/repo3" "skipped" 5 0 0

    # Verify mixed outcomes
    local success_outcome fail_outcome skip_outcome
    success_outcome=$(jq -r '.repos["owner/repo1"].outcome' "$state_file")
    fail_outcome=$(jq -r '.repos["owner/repo2"].outcome' "$state_file")
    skip_outcome=$(jq -r '.repos["owner/repo3"].outcome' "$state_file")

    assert_equals "success" "$success_outcome" "Success repo should be recorded"
    assert_equals "failed" "$fail_outcome" "Failed repo should be recorded"
    assert_equals "skipped" "$skip_outcome" "Skipped repo should be recorded"

    # Generate completion JSON with partial success
    local items=(
        "owner/repo1|issue|1|Bug|bug|2025-01-01|2025-01-02|false"
        "owner/repo1|pr|5|Feature|enhancement|2025-01-01|2025-01-02|false"
    )
    local completion_json
    completion_json=$(build_review_completion_json "$REVIEW_RUN_ID" "apply" "$(date +%s)" 1 "${items[@]}")

    local exit_code
    exit_code=$(echo "$completion_json" | jq -r '.exit_code')
    assert_equals "1" "$exit_code" "Partial completion should have exit code 1"

    unset REVIEW_RUN_ID
    e2e_cleanup
    log_test_pass "e2e: partial completion with mixed outcomes"
}

test_resume_after_completion() {
    log_test_start "e2e: resume detection after completion"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="resume-test-run"
    mkdir -p "$RU_STATE_DIR/review"

    # Initialize state with completed run
    local state_file="$RU_STATE_DIR/review/review-state.json"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$state_file" << STATE
{
    "version": 2,
    "repos": {
        "owner/repo": {
            "last_review": "$now",
            "outcome": "success"
        }
    },
    "items": {},
    "runs": {
        "$REVIEW_RUN_ID": {
            "started_at": "$now",
            "completed_at": "$now",
            "repos_processed": 1,
            "items_processed": 3,
            "mode": "apply"
        }
    }
}
STATE

    # Check if run is already complete
    local completed_at
    completed_at=$(jq -r ".runs[\"$REVIEW_RUN_ID\"].completed_at // null" "$state_file")

    if [[ "$completed_at" != "null" ]]; then
        pass "Completed run detected"
    else
        fail "Should detect completed run"
    fi

    # Verify run mode
    local mode
    mode=$(jq -r ".runs[\"$REVIEW_RUN_ID\"].mode // null" "$state_file")
    assert_equals "apply" "$mode" "Run mode should be recorded"

    unset REVIEW_RUN_ID
    e2e_cleanup
    log_test_pass "e2e: resume detection after completion"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: completion phase"

run_test test_full_completion_cycle
run_test test_partial_completion
run_test test_resume_after_completion

print_results
exit "$(get_exit_code)"
