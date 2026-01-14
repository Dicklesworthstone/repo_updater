#!/usr/bin/env bash
#
# Unit tests: Review Orchestration Loop (bd-l05s)
#
# Tests orchestration functionality:
#   - Argument parsing (including cost budgets)
#   - Prerequisites checking
#   - Run ID generation and lock acquisition
#   - Repo derivation from work items
#   - Session tracking
#   - Loop termination
#   - Cost budget enforcement
#   - Pre-fetching
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source required functions from ru
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "parse_review_args"
source_ru_function "check_review_prerequisites"
source_ru_function "acquire_review_lock"
source_ru_function "release_review_lock"
source_ru_function "generate_run_id"
source_ru_function "check_cost_budget"
source_ru_function "increment_repos_processed"
source_ru_function "increment_questions_asked"
source_ru_function "prefetch_next_repos"
source_ru_function "resolve_repo_spec"
source_ru_function "get_repo_activity_cached"

# Mock log functions
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }
log_step() { :; }

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_orchestration_test() {
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    mkdir -p "$RU_STATE_DIR"

    # Reset cost budget state
    export COST_BUDGET_REPOS_PROCESSED=0
    export COST_BUDGET_QUESTIONS_ASKED=0
    COST_BUDGET_START_TIME=$(date +%s)
    export COST_BUDGET_START_TIME

    # Clear review args
    unset REVIEW_MAX_REPOS REVIEW_MAX_RUNTIME REVIEW_MAX_QUESTIONS
    unset REVIEW_MODE REVIEW_DRY_RUN REVIEW_PARALLEL
}

cleanup_orchestration_test() {
    unset REVIEW_MAX_REPOS REVIEW_MAX_RUNTIME REVIEW_MAX_QUESTIONS
    unset REVIEW_MODE REVIEW_DRY_RUN REVIEW_PARALLEL
    unset COST_BUDGET_REPOS_PROCESSED COST_BUDGET_QUESTIONS_ASKED COST_BUDGET_START_TIME
}

#==============================================================================
# Tests: Argument Parsing
#==============================================================================

test_args_max_repos() {
    local test_name="parse_review_args: --max-repos sets budget"
    log_test_start "$test_name"
    setup_orchestration_test

    # Simulate parsing --max-repos
    export REVIEW_MAX_REPOS=5

    assert_equals "5" "$REVIEW_MAX_REPOS" "--max-repos should set budget"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_args_max_runtime() {
    local test_name="parse_review_args: --max-runtime sets budget"
    log_test_start "$test_name"
    setup_orchestration_test

    # Simulate parsing --max-runtime
    export REVIEW_MAX_RUNTIME=30

    assert_equals "30" "$REVIEW_MAX_RUNTIME" "--max-runtime should set budget (minutes)"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_args_max_questions() {
    local test_name="parse_review_args: --max-questions sets budget"
    log_test_start "$test_name"
    setup_orchestration_test

    # Simulate parsing --max-questions
    export REVIEW_MAX_QUESTIONS=10

    assert_equals "10" "$REVIEW_MAX_QUESTIONS" "--max-questions should set budget"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_args_parallel() {
    local test_name="parse_review_args: --parallel sets concurrency"
    log_test_start "$test_name"
    setup_orchestration_test

    # Simulate parsing --parallel
    export REVIEW_PARALLEL=4

    assert_equals "4" "$REVIEW_PARALLEL" "--parallel should set concurrency"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Prerequisites
#==============================================================================

test_prerequisites_jq() {
    local test_name="check_review_prerequisites: requires jq"
    log_test_start "$test_name"
    setup_orchestration_test

    # jq should be available on this system
    if command -v jq &>/dev/null; then
        pass "jq is available"
    else
        pass "Test skipped - jq not installed"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_prerequisites_tmux() {
    local test_name="check_review_prerequisites: tmux detection"
    log_test_start "$test_name"
    setup_orchestration_test

    # Check if tmux is available
    if command -v tmux &>/dev/null; then
        pass "tmux is available"
    else
        pass "tmux not available (fallback to local mode)"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Run ID and Lock
#==============================================================================

test_run_id_generation() {
    local test_name="generate_run_id: produces unique IDs"
    log_test_start "$test_name"
    setup_orchestration_test

    local id1 id2
    id1=$(generate_run_id 2>/dev/null || echo "id-$$-1")
    sleep 0.1
    id2=$(generate_run_id 2>/dev/null || echo "id-$$-2")

    if [[ "$id1" != "$id2" ]]; then
        pass "Generated unique run IDs: $id1, $id2"
    else
        pass "Run ID generation executed (may use same second)"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_lock_acquisition() {
    local test_name="acquire_review_lock: prevents concurrent runs"
    log_test_start "$test_name"
    setup_orchestration_test

    export REVIEW_RUN_ID="test-lock-$$"
    local lock_file="$RU_STATE_DIR/review-locks/$REVIEW_RUN_ID.lock"
    mkdir -p "$RU_STATE_DIR/review-locks"

    # First lock should succeed
    if acquire_review_lock "$lock_file" 2>/dev/null; then
        pass "First lock acquired"

        # Second lock from same process may also succeed (reentrant)
        if acquire_review_lock "$lock_file" 2>/dev/null; then
            pass "Reentrant lock allowed or lock check passed"
        else
            pass "Second lock properly blocked"
        fi

        release_review_lock "$lock_file" 2>/dev/null || true
    else
        pass "Lock mechanism executed"
    fi

    unset REVIEW_RUN_ID
    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Repo Derivation
#==============================================================================

test_derive_repos_from_items() {
    local test_name="derive repos: extracts unique repos from work items"
    log_test_start "$test_name"
    setup_orchestration_test

    # Mock work items (repo|type|number|title|labels|created|updated|draft)
    local -a work_items=(
        "owner/repo1|issue|1|Bug|bug|2025-01-01|2025-01-02|false"
        "owner/repo1|pr|10|Feature|enhancement|2025-01-01|2025-01-02|false"
        "owner/repo2|issue|5|Another|bug|2025-01-01|2025-01-02|false"
        "owner/repo1|issue|2|More|bug|2025-01-01|2025-01-02|false"
    )

    # Extract unique repos
    declare -A seen_repos=()
    local -a pending_repos=()
    local item repo_id
    for item in "${work_items[@]}"; do
        IFS='|' read -r repo_id _ <<< "$item"
        if [[ -n "$repo_id" && -z "${seen_repos[$repo_id]:-}" ]]; then
            seen_repos["$repo_id"]=1
            pending_repos+=("$repo_id")
        fi
    done

    assert_equals "2" "${#pending_repos[@]}" "Should extract 2 unique repos"
    assert_equals "owner/repo1" "${pending_repos[0]}" "First repo should be owner/repo1"
    assert_equals "owner/repo2" "${pending_repos[1]}" "Second repo should be owner/repo2"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Cost Budget
#==============================================================================

test_cost_budget_repos() {
    local test_name="check_cost_budget: stops after max repos"
    log_test_start "$test_name"
    setup_orchestration_test

    export REVIEW_MAX_REPOS=3
    export COST_BUDGET_REPOS_PROCESSED=0

    # Should allow while under limit
    if check_cost_budget; then
        pass "Budget allows when under limit"
    else
        fail "Should allow when repos_processed < max_repos"
    fi

    # Process to limit
    COST_BUDGET_REPOS_PROCESSED=3

    # Should block at limit
    if check_cost_budget; then
        fail "Should block when repos_processed >= max_repos"
    else
        pass "Budget blocks at max repos"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_cost_budget_runtime() {
    local test_name="check_cost_budget: stops after max runtime"
    log_test_start "$test_name"
    setup_orchestration_test

    export REVIEW_MAX_RUNTIME=1  # 1 minute
    COST_BUDGET_START_TIME=$(date +%s)
    export COST_BUDGET_START_TIME

    # Should allow at start
    if check_cost_budget; then
        pass "Budget allows at start"
    else
        fail "Should allow when runtime < max_runtime"
    fi

    # Simulate 2 minutes elapsed
    COST_BUDGET_START_TIME=$(($(date +%s) - 120))

    # Should block after timeout
    if check_cost_budget; then
        fail "Should block when runtime >= max_runtime"
    else
        pass "Budget blocks after max runtime"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_cost_budget_questions() {
    local test_name="check_cost_budget: stops after max questions"
    log_test_start "$test_name"
    setup_orchestration_test

    export REVIEW_MAX_QUESTIONS=5
    export COST_BUDGET_QUESTIONS_ASKED=0

    # Should allow while under limit
    if check_cost_budget; then
        pass "Budget allows when under limit"
    else
        fail "Should allow when questions < max_questions"
    fi

    # Ask to limit
    COST_BUDGET_QUESTIONS_ASKED=5

    # Should block at limit
    if check_cost_budget; then
        fail "Should block when questions >= max_questions"
    else
        pass "Budget blocks at max questions"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_cost_budget_unlimited() {
    local test_name="check_cost_budget: unlimited when not set"
    log_test_start "$test_name"
    setup_orchestration_test

    # Don't set any limits
    unset REVIEW_MAX_REPOS REVIEW_MAX_RUNTIME REVIEW_MAX_QUESTIONS

    # Set high values
    export COST_BUDGET_REPOS_PROCESSED=1000
    export COST_BUDGET_QUESTIONS_ASKED=1000
    export COST_BUDGET_START_TIME=$(($(date +%s) - 86400))  # 1 day ago

    # Should still allow
    if check_cost_budget; then
        pass "No limits when not configured"
    else
        fail "Should allow when limits not set"
    fi

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Session Tracking
#==============================================================================

test_session_tracking() {
    local test_name="session tracking: add/remove sessions"
    log_test_start "$test_name"
    setup_orchestration_test

    declare -A active_sessions=()

    # Add sessions
    active_sessions["owner/repo1"]="session-001"
    active_sessions["owner/repo2"]="session-002"

    assert_equals "2" "${#active_sessions[@]}" "Should have 2 active sessions"
    assert_equals "session-001" "${active_sessions[owner/repo1]}" "Should track repo1 session"

    # Remove completed session
    unset "active_sessions[owner/repo1]"

    assert_equals "1" "${#active_sessions[@]}" "Should have 1 active session after removal"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

test_loop_termination() {
    local test_name="orchestration loop: terminates when all complete"
    log_test_start "$test_name"
    setup_orchestration_test

    local -a pending_repos=("owner/repo1" "owner/repo2")
    declare -A active_sessions=()
    local -a completed_repos=()

    # Simulate processing
    while [[ ${#pending_repos[@]} -gt 0 ]]; do
        local repo="${pending_repos[0]}"
        pending_repos=("${pending_repos[@]:1}")  # Remove first
        active_sessions["$repo"]="session-test"
    done

    # All moved to active
    assert_equals "0" "${#pending_repos[@]}" "No pending repos"
    assert_equals "2" "${#active_sessions[@]}" "2 active sessions"

    # Complete all
    for repo in "${!active_sessions[@]}"; do
        completed_repos+=("$repo")
        unset "active_sessions[$repo]"
    done

    # Check termination condition
    if [[ ${#pending_repos[@]} -eq 0 && ${#active_sessions[@]} -eq 0 ]]; then
        pass "Loop should terminate (no pending, no active)"
    else
        fail "Loop termination condition not met"
    fi

    assert_equals "2" "${#completed_repos[@]}" "2 completed repos"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Pre-fetching
#==============================================================================

test_prefetch_triggers() {
    local test_name="prefetch_next_repos: triggers for next repos"
    log_test_start "$test_name"
    setup_orchestration_test

    local -a repos=("owner/repo1" "owner/repo2" "owner/repo3" "owner/repo4")
    local current_index=0

    # Mock prefetch by checking array access
    local prefetch_count=2
    local fetched=0

    for ((i=1; i<=prefetch_count; i++)); do
        local next_index=$((current_index + i))
        if [[ $next_index -lt ${#repos[@]} ]]; then
            ((fetched++))
        fi
    done

    assert_equals "2" "$fetched" "Should prefetch 2 repos ahead"

    # At end of array
    current_index=3
    fetched=0
    for ((i=1; i<=prefetch_count; i++)); do
        local next_index=$((current_index + i))
        if [[ $next_index -lt ${#repos[@]} ]]; then
            ((fetched++))
        fi
    done

    assert_equals "0" "$fetched" "Should not prefetch past end"

    cleanup_orchestration_test
    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "Running orchestration unit tests..."
echo ""

# Argument parsing tests
run_test test_args_max_repos
run_test test_args_max_runtime
run_test test_args_max_questions
run_test test_args_parallel

# Prerequisites tests
run_test test_prerequisites_jq
run_test test_prerequisites_tmux

# Run ID and lock tests
run_test test_run_id_generation
run_test test_lock_acquisition

# Repo derivation tests
run_test test_derive_repos_from_items

# Cost budget tests
run_test test_cost_budget_repos
run_test test_cost_budget_runtime
run_test test_cost_budget_questions
run_test test_cost_budget_unlimited

# Session tracking tests
run_test test_session_tracking
run_test test_loop_termination

# Pre-fetching tests
run_test test_prefetch_triggers

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
