#!/usr/bin/env bash
#
# E2E Test: Review checkpoint and resume system (bd-kfnp)
#
# Tests full checkpoint/resume workflow:
#   1. Full resume cycle (start, interrupt, resume, complete)
#   2. Resume with pending questions
#   3. No duplicate work for completed repos
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

# Source required functions
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "dir_lock_try_acquire"
source_ru_function "dir_lock_release"
source_ru_function "dir_lock_acquire"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "get_review_state_dir"
source_ru_function "get_review_state_file"
source_ru_function "get_checkpoint_file"
source_ru_function "get_questions_file"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "init_review_state"
source_ru_function "update_review_state"
source_ru_function "record_item_outcome"
source_ru_function "record_repo_outcome"
source_ru_function "load_review_checkpoint"
source_ru_function "clear_review_checkpoint"
source_ru_function "write_json_atomic"

#------------------------------------------------------------------------------
# Helper to write checkpoint
#------------------------------------------------------------------------------

write_checkpoint() {
    local checkpoint_file="$1"
    local run_id="$2"
    local completed="$3"
    local pending="$4"

    local dir
    dir=$(dirname "$checkpoint_file")
    mkdir -p "$dir"

    cat > "$checkpoint_file" <<EOF
{
  "version": 1,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_id": "$run_id",
  "mode": "plan",
  "repos_total": 3,
  "repos_completed": $(echo "$completed" | tr ',' '\n' | grep -c . || echo 0),
  "repos_pending": $(echo "$pending" | tr ',' '\n' | grep -c . || echo 0),
  "completed_repos": $(echo "$completed" | tr ',' '\n' | grep . | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]'),
  "pending_repos": $(echo "$pending" | tr ',' '\n' | grep . | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
}
EOF
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_resume_cycle() {
    log_test_start "checkpoint: full resume cycle"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-resume-$$"
    mkdir -p "$RU_STATE_DIR/review"

    # 1. Initialize state (simulating start of review)
    init_review_state

    # 2. Record some progress (simulating partial completion)
    record_repo_outcome "owner/repo1" "completed" "60" "2" "1"
    record_item_outcome "owner/repo1" "issue" "1" "fixed" "Applied fix"

    # 3. Create checkpoint (simulating interrupt)
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    write_checkpoint "$checkpoint_file" "$REVIEW_RUN_ID" "owner/repo1" "owner/repo2,owner/repo3"

    # 4. Verify checkpoint exists
    assert_file_exists "$checkpoint_file" "Checkpoint file should exist"

    # 5. Load checkpoint (simulating resume)
    local checkpoint
    checkpoint=$(load_review_checkpoint)
    assert_not_equals "" "$checkpoint" "Checkpoint should be loadable"

    # 6. Verify state preserves completed work
    local state_file
    state_file=$(get_review_state_file)
    if command -v jq &>/dev/null; then
        local outcome
        outcome=$(jq -r '.repos["owner/repo1"].outcome' "$state_file" 2>/dev/null)
        assert_equals "completed" "$outcome" "Completed repo should be preserved"

        local pending
        pending=$(echo "$checkpoint" | jq -r '.pending_repos | length' 2>/dev/null)
        assert_equals "2" "$pending" "Should have 2 pending repos"
    fi

    # 7. Clear checkpoint (simulating completion)
    clear_review_checkpoint

    if [[ -f "$checkpoint_file" ]]; then
        fail "Checkpoint should be cleared after completion"
    else
        pass "Checkpoint cleared successfully"
    fi

    e2e_cleanup
    log_test_pass "checkpoint: full resume cycle"
}

test_resume_with_questions() {
    log_test_start "checkpoint: resume with pending questions"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-questions-$$"
    mkdir -p "$RU_STATE_DIR/review"

    init_review_state

    # Create a questions queue file with pending questions
    local questions_file
    questions_file=$(get_questions_file)
    mkdir -p "$(dirname "$questions_file")"

    cat > "$questions_file" <<EOF
{
  "pending": [
    {"id": "q1", "repo": "owner/repo1", "question": "Should we update deps?"},
    {"id": "q2", "repo": "owner/repo2", "question": "Approve breaking change?"}
  ],
  "answered": []
}
EOF

    # Create checkpoint
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    write_checkpoint "$checkpoint_file" "$REVIEW_RUN_ID" "" "owner/repo1,owner/repo2"

    # Verify questions file exists
    assert_file_exists "$questions_file" "Questions file should exist"

    # Load checkpoint
    local checkpoint
    checkpoint=$(load_review_checkpoint)
    assert_not_equals "" "$checkpoint" "Checkpoint should be loadable"

    # Verify questions still pending
    if command -v jq &>/dev/null; then
        local pending_count
        pending_count=$(jq -r '.pending | length' "$questions_file" 2>/dev/null)
        assert_equals "2" "$pending_count" "Should have 2 pending questions"
    fi

    e2e_cleanup
    log_test_pass "checkpoint: resume with pending questions"
}

test_no_duplicate_work() {
    log_test_start "checkpoint: no duplicate work for completed repos"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-nodupe-$$"
    mkdir -p "$RU_STATE_DIR/review"

    init_review_state

    # Record multiple repo completions
    record_repo_outcome "owner/repo1" "completed" "60" "2" "1"
    record_repo_outcome "owner/repo2" "completed" "45" "1" "0"

    # Create checkpoint with repo3 as only pending
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    write_checkpoint "$checkpoint_file" "$REVIEW_RUN_ID" "owner/repo1,owner/repo2" "owner/repo3"

    # Verify state
    local state_file
    state_file=$(get_review_state_file)
    if command -v jq &>/dev/null; then
        # Both repos should be marked complete
        local repo1_outcome repo2_outcome
        repo1_outcome=$(jq -r '.repos["owner/repo1"].outcome' "$state_file" 2>/dev/null)
        repo2_outcome=$(jq -r '.repos["owner/repo2"].outcome' "$state_file" 2>/dev/null)

        assert_equals "completed" "$repo1_outcome" "Repo1 should be completed"
        assert_equals "completed" "$repo2_outcome" "Repo2 should be completed"
    fi

    # Load checkpoint and verify pending list
    local checkpoint
    checkpoint=$(load_review_checkpoint)

    if command -v jq &>/dev/null; then
        local pending_repos
        pending_repos=$(echo "$checkpoint" | jq -r '.pending_repos[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        assert_equals "owner/repo3" "$pending_repos" "Only repo3 should be pending"

        # Completed repos should not be in pending
        if echo "$checkpoint" | jq -e '.pending_repos[] | select(. == "owner/repo1")' &>/dev/null; then
            fail "Completed repo1 should not be in pending list"
        else
            pass "Completed repos not in pending list"
        fi
    fi

    e2e_cleanup
    log_test_pass "checkpoint: no duplicate work for completed repos"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: checkpoint and resume"

run_test test_full_resume_cycle
run_test test_resume_with_questions
run_test test_no_duplicate_work

print_results
exit "$(get_exit_code)"
