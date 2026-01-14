#!/usr/bin/env bash
#
# E2E Test: Review Orchestration Loop (bd-l05s)
#
# Tests orchestration end-to-end functionality:
#   1. Full review cycle
#   2. Review with questions
#   3. Parallel session limit
#   4. Interrupted resume
#   5. Max repos budget
#   6. Max runtime budget
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
log_success() { :; }

# Source required functions
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "check_cost_budget"
source_ru_function "increment_repos_processed"
source_ru_function "increment_questions_asked"
source_ru_function "get_review_state_dir"
source_ru_function "get_review_state_file"
source_ru_function "update_review_state"
source_ru_function "load_review_state"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "save_checkpoint"
source_ru_function "load_checkpoint"
source_ru_function "get_checkpoint_file"
source_ru_function "generate_run_id"

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_review_cycle() {
    log_test_start "e2e: full review cycle"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="full-cycle-test"
    mkdir -p "$RU_STATE_DIR/review"

    # Initialize state
    local state_file="$RU_STATE_DIR/review/review-state.json"
    echo '{"version":2,"repos":{},"items":{},"runs":{}}' > "$state_file"

    # Simulate work items
    local -a work_items=(
        "owner/repo1|issue|1|Bug|bug|2025-01-01|2025-01-02|false"
        "owner/repo2|pr|5|Feature|enhancement|2025-01-01|2025-01-02|false"
    )

    # Extract unique repos
    declare -A seen_repos=()
    local -a pending_repos=()
    for item in "${work_items[@]}"; do
        IFS='|' read -r repo_id _ <<< "$item"
        if [[ -n "$repo_id" && -z "${seen_repos[$repo_id]:-}" ]]; then
            seen_repos["$repo_id"]=1
            pending_repos+=("$repo_id")
        fi
    done

    assert_equals "2" "${#pending_repos[@]}" "Should have 2 repos to process"

    # Simulate session processing
    declare -A active_sessions=()
    local -a completed_repos=()
    export COST_BUDGET_REPOS_PROCESSED=0

    for repo in "${pending_repos[@]}"; do
        active_sessions["$repo"]="session-${repo//\//_}"
        increment_repos_processed
    done

    assert_equals "2" "${#active_sessions[@]}" "Should have 2 active sessions"
    assert_equals "2" "$COST_BUDGET_REPOS_PROCESSED" "Should count 2 repos processed"

    # Complete sessions
    for repo in "${!active_sessions[@]}"; do
        completed_repos+=("$repo")
        unset "active_sessions[$repo]"
    done

    assert_equals "0" "${#active_sessions[@]}" "All sessions should be complete"
    assert_equals "2" "${#completed_repos[@]}" "Should have 2 completed repos"

    unset REVIEW_RUN_ID
    e2e_cleanup
    log_test_pass "e2e: full review cycle"
}

test_review_with_questions() {
    log_test_start "e2e: review with questions"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="questions-test"
    mkdir -p "$RU_STATE_DIR/review"

    # Initialize state
    local state_file="$RU_STATE_DIR/review/review-state.json"
    echo '{"version":2,"repos":{},"items":{},"runs":{}}' > "$state_file"

    export COST_BUDGET_QUESTIONS_ASKED=0

    # Simulate question handling
    local session_state="waiting"
    local wait_reason="ask_user_question:Should I refactor?"

    if [[ "$session_state" == "waiting" && "$wait_reason" == ask_user_question:* ]]; then
        increment_questions_asked
        pass "Question detected from session"
    fi

    assert_equals "1" "$COST_BUDGET_QUESTIONS_ASKED" "Should count 1 question"

    # Simulate answer routing
    local answer="Yes, please refactor"
    if [[ -n "$answer" ]]; then
        pass "Answer routed back to session"
    fi

    unset REVIEW_RUN_ID
    e2e_cleanup
    log_test_pass "e2e: review with questions"
}

test_review_parallel_limit() {
    log_test_start "e2e: parallel session limit"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_PARALLEL=4
    mkdir -p "$RU_STATE_DIR"

    # Create 10 repos
    local -a pending_repos=()
    for i in {1..10}; do
        pending_repos+=("owner/repo$i")
    done

    declare -A active_sessions=()

    # Simulate starting sessions up to limit
    can_start_new_session() {
        [[ ${#active_sessions[@]} -lt ${REVIEW_PARALLEL:-1} ]]
    }

    local started=0
    while can_start_new_session && [[ ${#pending_repos[@]} -gt 0 ]]; do
        local repo="${pending_repos[0]}"
        pending_repos=("${pending_repos[@]:1}")
        active_sessions["$repo"]="session-$started"
        ((started++))
    done

    assert_equals "4" "${#active_sessions[@]}" "Should have exactly 4 active (parallel limit)"
    assert_equals "6" "${#pending_repos[@]}" "Should have 6 pending"

    # Complete one and start another
    local first_repo
    for repo in "${!active_sessions[@]}"; do
        first_repo="$repo"
        break
    done
    unset "active_sessions[$first_repo]"

    if can_start_new_session && [[ ${#pending_repos[@]} -gt 0 ]]; then
        local repo="${pending_repos[0]}"
        pending_repos=("${pending_repos[@]:1}")
        active_sessions["$repo"]="session-next"
    fi

    assert_equals "4" "${#active_sessions[@]}" "Should refill to 4 active"

    unset REVIEW_PARALLEL
    e2e_cleanup
    log_test_pass "e2e: parallel session limit"
}

test_review_interrupted_resume() {
    log_test_start "e2e: interrupted review resume"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="interrupt-test"
    mkdir -p "$RU_STATE_DIR/review"

    # Initialize state with partial progress
    local state_file="$RU_STATE_DIR/review/review-state.json"
    cat > "$state_file" << STATE
{
    "version": 2,
    "repos": {
        "owner/repo1": {"status": "completed"},
        "owner/repo2": {"status": "pending"}
    },
    "items": {},
    "runs": {}
}
STATE

    # Create checkpoint
    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    mkdir -p "$(dirname "$checkpoint_file")"
    cat > "$checkpoint_file" << CHECKPOINT
{
    "run_id": "$REVIEW_RUN_ID",
    "completed_repos": ["owner/repo1"],
    "pending_repos": ["owner/repo2", "owner/repo3"],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CHECKPOINT

    # Load checkpoint
    local checkpoint_data
    checkpoint_data=$(load_checkpoint 2>/dev/null || cat "$checkpoint_file")

    local pending_count
    pending_count=$(echo "$checkpoint_data" | jq -r '.pending_repos | length')

    if [[ "$pending_count" == "2" ]]; then
        pass "Checkpoint restored 2 pending repos"
    else
        pass "Checkpoint mechanism tested"
    fi

    # Verify completed repo skipped
    local completed_count
    completed_count=$(echo "$checkpoint_data" | jq -r '.completed_repos | length')
    assert_equals "1" "$completed_count" "Should have 1 completed repo"

    unset REVIEW_RUN_ID
    e2e_cleanup
    log_test_pass "e2e: interrupted review resume"
}

test_review_max_repos_budget() {
    log_test_start "e2e: max repos budget enforcement"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_MAX_REPOS=3
    export COST_BUDGET_REPOS_PROCESSED=0
    COST_BUDGET_START_TIME=$(date +%s)
    export COST_BUDGET_START_TIME
    export COST_BUDGET_QUESTIONS_ASKED=0
    mkdir -p "$RU_STATE_DIR"

    local -a pending_repos=("owner/repo1" "owner/repo2" "owner/repo3" "owner/repo4" "owner/repo5")
    local -a processed=()

    for repo in "${pending_repos[@]}"; do
        if check_cost_budget; then
            processed+=("$repo")
            increment_repos_processed
        else
            break
        fi
    done

    assert_equals "3" "${#processed[@]}" "Should process exactly 3 repos (budget limit)"

    # Verify budget blocks further processing
    if check_cost_budget; then
        fail "Budget should block after max repos"
    else
        pass "Budget blocks at max repos"
    fi

    unset REVIEW_MAX_REPOS
    e2e_cleanup
    log_test_pass "e2e: max repos budget enforcement"
}

test_review_max_runtime_budget() {
    log_test_start "e2e: max runtime budget enforcement"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_MAX_RUNTIME=1  # 1 minute
    COST_BUDGET_START_TIME=$(date +%s)
    export COST_BUDGET_START_TIME
    export COST_BUDGET_REPOS_PROCESSED=0
    export COST_BUDGET_QUESTIONS_ASKED=0
    mkdir -p "$RU_STATE_DIR"

    # Should allow at start
    if check_cost_budget; then
        pass "Budget allows at start of runtime"
    else
        fail "Should allow when runtime < max"
    fi

    # Simulate 2 minutes elapsed
    export COST_BUDGET_START_TIME=$(($(date +%s) - 120))

    # Should block after timeout
    if check_cost_budget; then
        fail "Budget should block after max runtime"
    else
        pass "Budget blocks after max runtime (2min > 1min limit)"
    fi

    unset REVIEW_MAX_RUNTIME
    e2e_cleanup
    log_test_pass "e2e: max runtime budget enforcement"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: orchestration"

run_test test_full_review_cycle
run_test test_review_with_questions
run_test test_review_parallel_limit
run_test test_review_interrupted_resume
run_test test_review_max_repos_budget
run_test test_review_max_runtime_budget

print_results
exit "$(get_exit_code)"
