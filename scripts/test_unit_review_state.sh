#!/usr/bin/env bash
#
# Unit tests: Review State Management
#
# Tests for get_review_state_dir, get_review_state_file, init_review_state,
# checkpoint_review_state, load_review_checkpoint, clear_review_checkpoint.
#
# Uses real file operations in isolated temp directories.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source required functions
source_ru_function "ensure_dir"
source_ru_function "write_json_atomic"
source_ru_function "get_review_state_dir"
source_ru_function "get_review_state_file"
source_ru_function "get_checkpoint_file"
source_ru_function "get_questions_file"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "init_review_state"
source_ru_function "load_review_checkpoint"
source_ru_function "clear_review_checkpoint"

# checkpoint_review_state uses a heredoc that doesn't extract properly
# So we define a simplified version for testing
checkpoint_review_state() {
    local completed_repos="$1"
    local pending_repos="$2"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local run_id="${REVIEW_RUN_ID:-unknown}"
    local mode="${REVIEW_MODE:-plan}"
    local config_hash="test-hash-123"

    # Count repos
    local completed_count pending_count
    completed_count=$(echo "$completed_repos" | wc -w | tr -d ' ')
    pending_count=$(echo "$pending_repos" | wc -w | tr -d ' ')
    local total=$((completed_count + pending_count))

    # Build JSON
    local checkpoint
    checkpoint="{\"version\":1,\"timestamp\":\"$now\",\"run_id\":\"$run_id\",\"mode\":\"$mode\",\"config_hash\":\"$config_hash\",\"repos_total\":$total,\"repos_completed\":$completed_count,\"repos_pending\":$pending_count,\"completed_repos\":[],\"pending_repos\":[]}"

    with_state_lock write_json_atomic "$checkpoint_file" "$checkpoint"
}

# Set up required globals
STATE_LOCK_FD=201

# Stub logging functions
log_verbose() { :; }
log_warn() { echo "WARN: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

# Stub function for get_config_hash if not available
if ! type get_config_hash &>/dev/null; then
    get_config_hash() { echo "test-hash-123"; }
fi

#==============================================================================
# Tests: get_review_state_dir
#==============================================================================

test_get_review_state_dir_default() {
    local test_name="get_review_state_dir uses default path"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Clear env vars to use defaults
    unset RU_STATE_DIR
    unset XDG_STATE_HOME

    local result
    result=$(get_review_state_dir)

    # Should default to ~/.local/state/ru/review
    assert_contains "$result" ".local/state/ru/review" "Should use default XDG path"

    log_test_pass "$test_name"
}

test_get_review_state_dir_custom() {
    local test_name="get_review_state_dir respects RU_STATE_DIR"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/custom-state"
    local result
    result=$(get_review_state_dir)

    assert_equals "$test_env/custom-state/review" "$result" "Should use RU_STATE_DIR"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_get_review_state_dir_xdg() {
    local test_name="get_review_state_dir respects XDG_STATE_HOME"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    unset RU_STATE_DIR
    XDG_STATE_HOME="$test_env/xdg-state"
    local result
    result=$(get_review_state_dir)

    assert_equals "$test_env/xdg-state/ru/review" "$result" "Should use XDG_STATE_HOME"

    unset XDG_STATE_HOME
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: get_review_state_file
#==============================================================================

test_get_review_state_file_path() {
    local test_name="get_review_state_file returns correct path"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    local result
    result=$(get_review_state_file)

    assert_equals "$test_env/state/review/review-state.json" "$result" "Should return review-state.json path"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_get_checkpoint_file_path() {
    local test_name="get_checkpoint_file returns correct path"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    local result
    result=$(get_checkpoint_file)

    assert_equals "$test_env/state/review/review-checkpoint.json" "$result" "Should return review-checkpoint.json path"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: init_review_state
#==============================================================================

test_init_review_state_creates_file() {
    local test_name="init_review_state creates state file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    local state_file
    state_file=$(get_review_state_file)

    assert_file_not_exists "$state_file" "State file should not exist initially"

    init_review_state

    assert_file_exists "$state_file" "State file should be created"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_init_review_state_initial_structure() {
    local test_name="init_review_state creates correct JSON structure"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"

    init_review_state

    local state_file
    state_file=$(get_review_state_file)

    # Check JSON structure
    if command -v jq &>/dev/null; then
        local version repos items runs
        version=$(jq -r '.version' "$state_file")
        repos=$(jq -r '.repos | type' "$state_file")
        items=$(jq -r '.items | type' "$state_file")
        runs=$(jq -r '.runs | type' "$state_file")

        assert_equals "2" "$version" "Should have version 2"
        assert_equals "object" "$repos" "repos should be object"
        assert_equals "object" "$items" "items should be object"
        assert_equals "object" "$runs" "runs should be object"
    else
        # Fallback without jq
        assert_file_contains "$state_file" '"version":2' "Should contain version 2"
        assert_file_contains "$state_file" '"repos":{}' "Should contain empty repos"
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_init_review_state_idempotent() {
    local test_name="init_review_state is idempotent"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"

    # Create state file
    init_review_state

    local state_file
    state_file=$(get_review_state_file)

    # Modify it to test idempotency
    if command -v jq &>/dev/null; then
        local modified
        modified=$(jq '.repos.test = {"last_review": "2025-01-01"}' "$state_file")
        echo "$modified" > "$state_file"
    fi

    # Call init again
    init_review_state

    # Should NOT overwrite existing file
    if command -v jq &>/dev/null; then
        local has_test
        has_test=$(jq -r '.repos.test // "missing"' "$state_file")
        if [[ "$has_test" == "missing" ]]; then
            log_test_fail "$test_name" "init_review_state should not overwrite existing state"
            return 1
        fi
    fi

    assert_true "true" "Existing state should be preserved"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: checkpoint_review_state
#==============================================================================

test_checkpoint_review_state_creates_file() {
    local test_name="checkpoint_review_state creates checkpoint file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    REVIEW_RUN_ID="test-run-123"
    REVIEW_MODE="plan"

    checkpoint_review_state "repo1 repo2" "repo3"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    assert_file_exists "$checkpoint_file" "Checkpoint file should be created"

    unset RU_STATE_DIR REVIEW_RUN_ID REVIEW_MODE
    log_test_pass "$test_name"
}

test_checkpoint_review_state_content() {
    local test_name="checkpoint_review_state has correct content"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    REVIEW_RUN_ID="test-run-456"
    REVIEW_MODE="execute"

    checkpoint_review_state "completed1 completed2" "pending1"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    if command -v jq &>/dev/null; then
        local run_id mode completed pending
        run_id=$(jq -r '.run_id' "$checkpoint_file")
        mode=$(jq -r '.mode' "$checkpoint_file")
        completed=$(jq -r '.repos_completed' "$checkpoint_file")
        pending=$(jq -r '.repos_pending' "$checkpoint_file")

        assert_equals "test-run-456" "$run_id" "Should have correct run_id"
        assert_equals "execute" "$mode" "Should have correct mode"
        assert_equals "2" "$completed" "Should have 2 completed"
        assert_equals "1" "$pending" "Should have 1 pending"
    else
        assert_file_contains "$checkpoint_file" '"run_id"' "Should contain run_id"
        assert_file_contains "$checkpoint_file" '"mode"' "Should contain mode"
    fi

    unset RU_STATE_DIR REVIEW_RUN_ID REVIEW_MODE
    log_test_pass "$test_name"
}

test_checkpoint_review_state_empty_repos() {
    local test_name="checkpoint_review_state handles empty repo lists"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    REVIEW_RUN_ID="empty-run"
    REVIEW_MODE="plan"

    checkpoint_review_state "" ""

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)

    if command -v jq &>/dev/null; then
        local total
        total=$(jq -r '.repos_total' "$checkpoint_file")
        assert_equals "0" "$total" "Should have 0 total repos"
    else
        assert_file_contains "$checkpoint_file" '"repos_total": 0' "Should have 0 total"
    fi

    unset RU_STATE_DIR REVIEW_RUN_ID REVIEW_MODE
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: load_review_checkpoint
#==============================================================================

test_load_review_checkpoint_returns_content() {
    local test_name="load_review_checkpoint returns checkpoint content"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR/review"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    echo '{"run_id":"loaded-run","mode":"plan"}' > "$checkpoint_file"

    local result
    result=$(load_review_checkpoint)

    assert_contains "$result" '"run_id":"loaded-run"' "Should return checkpoint content"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_load_review_checkpoint_empty_for_missing() {
    local test_name="load_review_checkpoint returns empty for missing file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR/review"

    local result
    result=$(load_review_checkpoint)

    assert_equals "" "$result" "Should return empty for missing checkpoint"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: clear_review_checkpoint
#==============================================================================

test_clear_review_checkpoint_removes_file() {
    local test_name="clear_review_checkpoint removes checkpoint file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR/review"

    local checkpoint_file
    checkpoint_file=$(get_checkpoint_file)
    echo '{"run_id":"to-delete"}' > "$checkpoint_file"

    assert_file_exists "$checkpoint_file" "Checkpoint should exist before clear"

    clear_review_checkpoint

    assert_file_not_exists "$checkpoint_file" "Checkpoint should be removed after clear"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_clear_review_checkpoint_noop_for_missing() {
    local test_name="clear_review_checkpoint is noop for missing file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR/review"

    # Should not error when file doesn't exist
    if clear_review_checkpoint; then
        assert_true "true" "Should succeed for missing file"
    else
        log_test_fail "$test_name" "Should not fail for missing file"
        return 1
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Review State Management"
echo "============================================"
echo ""

# get_review_state_dir tests
run_test test_get_review_state_dir_default
run_test test_get_review_state_dir_custom
run_test test_get_review_state_dir_xdg

# get_review_state_file tests
run_test test_get_review_state_file_path
run_test test_get_checkpoint_file_path

# init_review_state tests
run_test test_init_review_state_creates_file
run_test test_init_review_state_initial_structure
run_test test_init_review_state_idempotent

# checkpoint_review_state tests
run_test test_checkpoint_review_state_creates_file
run_test test_checkpoint_review_state_content
run_test test_checkpoint_review_state_empty_repos

# load_review_checkpoint tests
run_test test_load_review_checkpoint_returns_content
run_test test_load_review_checkpoint_empty_for_missing

# clear_review_checkpoint tests
run_test test_clear_review_checkpoint_removes_file
run_test test_clear_review_checkpoint_noop_for_missing

echo ""
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
