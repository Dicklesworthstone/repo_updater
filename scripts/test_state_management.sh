#!/usr/bin/env bash
#------------------------------------------------------------------------------
# test_state_management.sh
# Unit tests for agent-sweep state management and resume functions
#------------------------------------------------------------------------------
# Tests: setup_agent_sweep_results, save_agent_sweep_state, load_agent_sweep_state
#        cleanup_agent_sweep_state, mark_repo_completed, filter_sweep_completed_repos
#        is_sweep_repo_completed, get_results_summary
#        Artifact capture integration tests
#
# shellcheck disable=SC2034  # Variables used by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_ROOT/ru"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

# Stubs for logging functions (suppress output during tests)
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

# Stub for ensure_dir
ensure_dir() { mkdir -p "$1" 2>/dev/null; }

# Stub for dir_lock_acquire (for backoff tests)
dir_lock_acquire() { mkdir "$1" 2>/dev/null; }

# Stub for format_duration
format_duration() { echo "${1}s"; }

# Globals needed by extracted functions
VERBOSE=false
LOG_LEVEL=0

# Portable alternative to head -n -N (BSD/macOS doesn't support negative counts)
drop_last_lines() {
    local n="${1:-1}"
    local input total keep
    input=$(cat)
    total=$(printf '%s\n' "$input" | wc -l | tr -d ' ')
    keep=$((total - n))
    [[ "$keep" -lt 1 ]] && return 0
    printf '%s\n' "$input" | head -n "$keep"
}

#------------------------------------------------------------------------------
# Extract required functions from ru
# Note: Use sed line ranges for functions with heredocs to avoid parse issues
#------------------------------------------------------------------------------
EXTRACT_FILE=$(mktemp)

# Extract array_contains
awk '/^array_contains\(\) \{/,/^}/' "$RU_SCRIPT" > "$EXTRACT_FILE"

# Extract json functions
awk '/^json_get_field\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"
awk '/^json_escape\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"

# Extract result tracking globals
sed -n '/^# Global result tracking state/,/^# Initialize agent-sweep/p' "$RU_SCRIPT" | drop_last_lines 2 >> "$EXTRACT_FILE"

# Extract setup_agent_sweep_results function
awk '/^setup_agent_sweep_results\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"

# Extract get_results_summary function
awk '/^get_results_summary\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"

# Extract mark_repo_completed, is_sweep_repo_completed, filter_sweep_completed_repos
awk '/^mark_repo_completed\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"
awk '/^is_sweep_repo_completed\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"
awk '/^filter_sweep_completed_repos\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"

# Extract artifact capture section
sed -n '/^# AGENT-SWEEP ARTIFACT CAPTURE/,/^# AGENT-SWEEP STATE PERSISTENCE/p' "$RU_SCRIPT" | drop_last_lines 3 >> "$EXTRACT_FILE"

# Extract state persistence functions using line numbers (heredocs break awk /^}/ pattern)
# save_agent_sweep_state: 1296-1361, load_agent_sweep_state: 1366-1430, cleanup_agent_sweep_state: 1433-1440
# Use grep to find line numbers dynamically
SAVE_START=$(grep -n '^save_agent_sweep_state() {' "$RU_SCRIPT" | cut -d: -f1)
LOAD_START=$(grep -n '^load_agent_sweep_state() {' "$RU_SCRIPT" | cut -d: -f1)
CLEANUP_START=$(grep -n '^cleanup_agent_sweep_state() {' "$RU_SCRIPT" | cut -d: -f1)
BACKOFF_START=$(grep -n '^# AGENT-SWEEP RATE LIMIT BACKOFF' "$RU_SCRIPT" | head -1 | cut -d: -f1)

if [[ -n "$SAVE_START" && -n "$LOAD_START" ]]; then
    sed -n "${SAVE_START},$((LOAD_START - 1))p" "$RU_SCRIPT" >> "$EXTRACT_FILE"
fi
if [[ -n "$LOAD_START" && -n "$CLEANUP_START" ]]; then
    sed -n "${LOAD_START},$((CLEANUP_START - 1))p" "$RU_SCRIPT" >> "$EXTRACT_FILE"
fi
if [[ -n "$CLEANUP_START" && -n "$BACKOFF_START" ]]; then
    sed -n "${CLEANUP_START},$((BACKOFF_START - 1))p" "$RU_SCRIPT" >> "$EXTRACT_FILE"
fi

# shellcheck disable=SC1090
source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"

#------------------------------------------------------------------------------
# Test utilities
#------------------------------------------------------------------------------

setup_test_env() {
    TEST_TMP=$(mktemp -d)
    export XDG_STATE_HOME="$TEST_TMP/state"
    mkdir -p "$XDG_STATE_HOME"

    # Create test repo
    TEST_REPO="$TEST_TMP/test_repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init --quiet
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    echo "test" > "$TEST_REPO/file.txt"
    git -C "$TEST_REPO" add file.txt
    git -C "$TEST_REPO" commit -m "Initial commit" --quiet

    # Reset globals before each test
    RUN_ID=""
    RUN_ARTIFACTS_DIR=""
    AGENT_SWEEP_STATE_DIR=""
    COMPLETED_REPOS=()
    SWEEP_SUCCESS_COUNT=0
    SWEEP_FAIL_COUNT=0
    SWEEP_SKIP_COUNT=0
    SWEEP_WITH_RELEASE=false
    SWEEP_CURRENT_REPO=""
    SWEEP_CURRENT_PHASE=0
}

cleanup_test_env() {
    [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        [[ -n "$msg" ]] && echo "  Message:  $msg"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-}"

    if [[ -n "$value" ]]; then
        return 0
    else
        echo "  Value was empty"
        [[ -n "$msg" ]] && echo "  Message:  $msg"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    [[ -f "$file" ]] || {
        echo "  File not found: $file"
        return 1
    }
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"

    grep -q "$pattern" "$file" 2>/dev/null || {
        echo "  Pattern not found: '$pattern'"
        echo "  In file: $file"
        return 1
    }
}

assert_dir_exists() {
    local dir="$1"
    [[ -d "$dir" ]] || {
        echo "  Directory not found: $dir"
        return 1
    }
}

run_test() {
    local test_name="$1"
    local test_func="$2"

    ((TESTS_RUN++))
    printf "  %-55s " "$test_name"

    setup_test_env

    # Run test directly (not in subshell) to preserve globals
    # Redirect output to a temp file to capture errors
    local output_file
    output_file=$(mktemp)

    local test_passed=true
    if ! $test_func > "$output_file" 2>&1; then
        test_passed=false
    fi

    if $test_passed; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        if [[ -s "$output_file" ]]; then
            sed 's/^/    /' "$output_file"
        fi
        ((TESTS_FAILED++))
    fi

    rm -f "$output_file"
    cleanup_test_env
}

#------------------------------------------------------------------------------
# Tests for setup_agent_sweep_results
#------------------------------------------------------------------------------

test_setup_creates_state_dir() {
    setup_agent_sweep_results 2>/dev/null

    assert_dir_exists "$AGENT_SWEEP_STATE_DIR"
}

test_setup_creates_run_id() {
    setup_agent_sweep_results 2>/dev/null

    assert_not_empty "$RUN_ID"
}

test_setup_run_id_format() {
    setup_agent_sweep_results 2>/dev/null

    # Format: YYYYMMDD-HHMMSS-PID
    [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || {
        echo "  RUN_ID format invalid: $RUN_ID"
        return 1
    }
}

test_setup_creates_artifacts_dir() {
    setup_agent_sweep_results 2>/dev/null

    assert_dir_exists "$RUN_ARTIFACTS_DIR"
}

test_setup_creates_locks_dir() {
    setup_agent_sweep_results 2>/dev/null

    assert_dir_exists "${AGENT_SWEEP_STATE_DIR}/locks"
}

test_setup_creates_results_file() {
    setup_agent_sweep_results 2>/dev/null

    assert_file_exists "$RESULTS_FILE"
}

test_setup_results_file_has_header() {
    setup_agent_sweep_results 2>/dev/null

    assert_file_contains "$RESULTS_FILE" '"type":"header"'
}

test_setup_resets_counters() {
    # Pre-set counters to verify reset
    SWEEP_SUCCESS_COUNT=5
    SWEEP_FAIL_COUNT=3
    SWEEP_SKIP_COUNT=2

    setup_agent_sweep_results 2>/dev/null

    assert_equals "0" "$SWEEP_SUCCESS_COUNT" && \
    assert_equals "0" "$SWEEP_FAIL_COUNT" && \
    assert_equals "0" "$SWEEP_SKIP_COUNT"
}

test_setup_resets_completed_repos() {
    COMPLETED_REPOS=("repo1" "repo2")

    setup_agent_sweep_results 2>/dev/null

    assert_equals "0" "${#COMPLETED_REPOS[@]}"
}

#------------------------------------------------------------------------------
# Tests for save_agent_sweep_state
#------------------------------------------------------------------------------

test_save_state_creates_file() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    assert_file_exists "${AGENT_SWEEP_STATE_DIR}/state.json"
}

test_save_state_valid_json() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    local state_file="${AGENT_SWEEP_STATE_DIR}/state.json"
    if command -v jq &>/dev/null; then
        jq . "$state_file" >/dev/null 2>&1 || {
            echo "  Invalid JSON in state file"
            return 1
        }
    fi
}

test_save_state_contains_run_id() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" "\"run_id\":"
}

test_save_state_contains_status() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" "\"status\": \"in_progress\""
}

test_save_state_contains_started_at() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" "\"started_at\":"
}

test_save_state_contains_completed_repos() {
    setup_agent_sweep_results 2>/dev/null
    COMPLETED_REPOS=("org/repo1" "org/repo2")

    save_agent_sweep_state "in_progress"

    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" "repos_completed"
}

test_save_state_contains_counts() {
    setup_agent_sweep_results 2>/dev/null
    SWEEP_SUCCESS_COUNT=3
    SWEEP_FAIL_COUNT=1
    SWEEP_SKIP_COUNT=2

    save_agent_sweep_state "in_progress"

    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" '"success_count": 3' && \
    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" '"fail_count": 1' && \
    assert_file_contains "${AGENT_SWEEP_STATE_DIR}/state.json" '"skip_count": 2'
}

test_save_state_fails_without_init() {
    AGENT_SWEEP_STATE_DIR=""

    ! save_agent_sweep_state "in_progress" 2>/dev/null
}

test_save_state_atomic_write() {
    setup_agent_sweep_results 2>/dev/null

    # Verify no temp file left behind
    save_agent_sweep_state "in_progress"

    local tmp_files
    tmp_files=$(find "${AGENT_SWEEP_STATE_DIR}" -name "*.tmp.*" 2>/dev/null | wc -l)
    assert_equals "0" "$tmp_files" "No temp files should remain"
}

#------------------------------------------------------------------------------
# Tests for load_agent_sweep_state
#------------------------------------------------------------------------------

test_load_state_returns_false_no_file() {
    setup_agent_sweep_results 2>/dev/null

    ! load_agent_sweep_state 2>/dev/null
}

test_load_state_returns_false_no_init() {
    AGENT_SWEEP_STATE_DIR=""

    ! load_agent_sweep_state 2>/dev/null
}

test_load_state_restores_run_id() {
    setup_agent_sweep_results 2>/dev/null
    local original_run_id="$RUN_ID"

    save_agent_sweep_state "in_progress"

    # Reset and reload
    RUN_ID=""
    load_agent_sweep_state

    assert_equals "$original_run_id" "$RUN_ID"
}

test_load_state_restores_completed_repos() {
    setup_agent_sweep_results 2>/dev/null
    COMPLETED_REPOS=("org/repo1" "org/repo2")

    save_agent_sweep_state "in_progress"

    # Reset and reload
    COMPLETED_REPOS=()
    load_agent_sweep_state

    assert_equals "2" "${#COMPLETED_REPOS[@]}"
}

test_load_state_restores_counts() {
    setup_agent_sweep_results 2>/dev/null
    SWEEP_SUCCESS_COUNT=5
    SWEEP_FAIL_COUNT=2
    SWEEP_SKIP_COUNT=1

    save_agent_sweep_state "in_progress"

    # Reset and reload
    SWEEP_SUCCESS_COUNT=0
    SWEEP_FAIL_COUNT=0
    SWEEP_SKIP_COUNT=0
    load_agent_sweep_state

    assert_equals "5" "$SWEEP_SUCCESS_COUNT" && \
    assert_equals "2" "$SWEEP_FAIL_COUNT" && \
    assert_equals "1" "$SWEEP_SKIP_COUNT"
}

test_load_state_rejects_completed() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "completed"

    ! load_agent_sweep_state 2>/dev/null
}

test_load_state_accepts_interrupted() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "interrupted"

    load_agent_sweep_state
}

test_load_state_accepts_in_progress() {
    setup_agent_sweep_results 2>/dev/null

    save_agent_sweep_state "in_progress"

    load_agent_sweep_state
}

#------------------------------------------------------------------------------
# Tests for cleanup_agent_sweep_state
#------------------------------------------------------------------------------

test_cleanup_removes_state_file() {
    setup_agent_sweep_results 2>/dev/null
    save_agent_sweep_state "in_progress"

    cleanup_agent_sweep_state

    [[ ! -f "${AGENT_SWEEP_STATE_DIR}/state.json" ]]
}

test_cleanup_idempotent() {
    setup_agent_sweep_results 2>/dev/null

    # Should not fail even if no state file
    cleanup_agent_sweep_state
    cleanup_agent_sweep_state
}

test_cleanup_without_init() {
    AGENT_SWEEP_STATE_DIR=""

    # Should not fail
    cleanup_agent_sweep_state
}

#------------------------------------------------------------------------------
# Tests for mark_repo_completed
#------------------------------------------------------------------------------

test_mark_completed_adds_to_array() {
    COMPLETED_REPOS=()

    mark_repo_completed "org/repo1"

    assert_equals "1" "${#COMPLETED_REPOS[@]}"
}

test_mark_completed_multiple() {
    COMPLETED_REPOS=()

    mark_repo_completed "org/repo1"
    mark_repo_completed "org/repo2"
    mark_repo_completed "org/repo3"

    assert_equals "3" "${#COMPLETED_REPOS[@]}"
}

test_mark_completed_increments_success() {
    COMPLETED_REPOS=()
    SWEEP_SUCCESS_COUNT=0

    mark_repo_completed "org/repo1" "success"

    assert_equals "1" "$SWEEP_SUCCESS_COUNT"
}

test_mark_completed_increments_failed() {
    COMPLETED_REPOS=()
    SWEEP_FAIL_COUNT=0

    mark_repo_completed "org/repo1" "failed"

    assert_equals "1" "$SWEEP_FAIL_COUNT"
}

test_mark_completed_increments_skipped() {
    COMPLETED_REPOS=()
    SWEEP_SKIP_COUNT=0

    mark_repo_completed "org/repo1" "skipped"

    assert_equals "1" "$SWEEP_SKIP_COUNT"
}

test_mark_completed_defaults_success() {
    COMPLETED_REPOS=()
    SWEEP_SUCCESS_COUNT=0

    mark_repo_completed "org/repo1"

    assert_equals "1" "$SWEEP_SUCCESS_COUNT"
}

test_mark_completed_fails_empty() {
    ! mark_repo_completed ""
}

#------------------------------------------------------------------------------
# Tests for is_sweep_repo_completed
#------------------------------------------------------------------------------

test_is_completed_true() {
    COMPLETED_REPOS=("org/repo1" "org/repo2")

    is_sweep_repo_completed "org/repo1"
}

test_is_completed_false() {
    COMPLETED_REPOS=("org/repo1")

    ! is_sweep_repo_completed "org/repo2"
}

test_is_completed_empty_array() {
    COMPLETED_REPOS=()

    ! is_sweep_repo_completed "org/repo1"
}

#------------------------------------------------------------------------------
# Tests for filter_sweep_completed_repos
#------------------------------------------------------------------------------

test_filter_removes_completed() {
    COMPLETED_REPOS=("org/repo1" "org/repo3")
    local repos=("org/repo1" "org/repo2" "org/repo3" "org/repo4")

    filter_sweep_completed_repos repos

    assert_equals "2" "${#repos[@]}"
}

test_filter_preserves_uncompleted() {
    COMPLETED_REPOS=("org/repo1")
    local repos=("org/repo1" "org/repo2")

    filter_sweep_completed_repos repos

    [[ "${repos[0]}" == "org/repo2" ]]
}

test_filter_empty_completed() {
    COMPLETED_REPOS=()
    local repos=("org/repo1" "org/repo2")

    filter_sweep_completed_repos repos

    assert_equals "2" "${#repos[@]}"
}

test_filter_all_completed() {
    COMPLETED_REPOS=("org/repo1" "org/repo2")
    local repos=("org/repo1" "org/repo2")

    filter_sweep_completed_repos repos

    assert_equals "0" "${#repos[@]}"
}

#------------------------------------------------------------------------------
# Tests for artifact capture integration
#------------------------------------------------------------------------------

test_artifacts_dir_per_repo() {
    setup_agent_sweep_results 2>/dev/null

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    assert_dir_exists "$artifact_dir"
}

test_artifacts_git_before_captured() {
    setup_agent_sweep_results 2>/dev/null
    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    capture_git_state "$TEST_REPO" "${artifact_dir}/git_before.txt"

    assert_file_exists "${artifact_dir}/git_before.txt"
    assert_file_contains "${artifact_dir}/git_before.txt" "git status"
}

test_artifacts_git_after_captured() {
    setup_agent_sweep_results 2>/dev/null
    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    # Make a change
    echo "modified" >> "$TEST_REPO/file.txt"

    capture_git_state "$TEST_REPO" "${artifact_dir}/git_after.txt"

    assert_file_exists "${artifact_dir}/git_after.txt"
}

test_artifacts_activity_log() {
    setup_agent_sweep_results 2>/dev/null

    log_activity_snapshot "$TEST_REPO" "phase1" "started"
    log_activity_snapshot "$TEST_REPO" "phase1" "completed"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    assert_file_exists "${artifact_dir}/activity.ndjson"

    local lines
    lines=$(wc -l < "${artifact_dir}/activity.ndjson")
    assert_equals "2" "$lines"
}

test_artifacts_plan_json_captured() {
    setup_agent_sweep_results 2>/dev/null

    capture_plan_json "$TEST_REPO" "commit" '{"commits":[{"message":"test"}]}'

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    assert_file_exists "${artifact_dir}/commit_plan.json"
    assert_file_contains "${artifact_dir}/commit_plan.json" "commits"
}

#------------------------------------------------------------------------------
# Tests for resume workflow
#------------------------------------------------------------------------------

test_resume_workflow_full_cycle() {
    setup_agent_sweep_results 2>/dev/null
    local original_run_id="$RUN_ID"

    # Process some repos
    mark_repo_completed "org/repo1" "success"
    mark_repo_completed "org/repo2" "success"
    mark_repo_completed "org/repo3" "failed"

    # Simulate interruption - save state
    save_agent_sweep_state "interrupted"

    # "New session" - reset everything
    local saved_state_dir="$AGENT_SWEEP_STATE_DIR"
    RUN_ID=""
    COMPLETED_REPOS=()
    SWEEP_SUCCESS_COUNT=0
    SWEEP_FAIL_COUNT=0

    # Keep state dir for loading
    AGENT_SWEEP_STATE_DIR="$saved_state_dir"

    # Resume
    load_agent_sweep_state

    # Verify state restored
    assert_equals "$original_run_id" "$RUN_ID" "RUN_ID should be restored" && \
    assert_equals "3" "${#COMPLETED_REPOS[@]}" "Should have 3 completed repos" && \
    assert_equals "2" "$SWEEP_SUCCESS_COUNT" "Should have 2 successes" && \
    assert_equals "1" "$SWEEP_FAIL_COUNT" "Should have 1 failure"
}

test_resume_filters_pending_repos() {
    setup_agent_sweep_results 2>/dev/null

    # Mark some as completed
    COMPLETED_REPOS=("org/repo1" "org/repo3")
    save_agent_sweep_state "in_progress"

    # Simulate starting fresh with pending repos
    local pending_repos=("org/repo1" "org/repo2" "org/repo3" "org/repo4")

    # Load and filter
    COMPLETED_REPOS=()
    load_agent_sweep_state
    filter_sweep_completed_repos pending_repos

    # Should only have repo2 and repo4 left
    assert_equals "2" "${#pending_repos[@]}"
}

test_restart_clears_state() {
    setup_agent_sweep_results 2>/dev/null
    COMPLETED_REPOS=("org/repo1")
    save_agent_sweep_state "in_progress"

    # Restart clears state
    cleanup_agent_sweep_state

    # Load should fail now
    ! load_agent_sweep_state 2>/dev/null
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

echo ""
echo "=== State Management Unit Tests ==="
echo ""

echo "setup_agent_sweep_results:"
run_test "creates state directory" test_setup_creates_state_dir
run_test "creates RUN_ID" test_setup_creates_run_id
run_test "RUN_ID has correct format" test_setup_run_id_format
run_test "creates artifacts directory" test_setup_creates_artifacts_dir
run_test "creates locks directory" test_setup_creates_locks_dir
run_test "creates results file" test_setup_creates_results_file
run_test "results file has header" test_setup_results_file_has_header
run_test "resets counters" test_setup_resets_counters
run_test "resets completed repos array" test_setup_resets_completed_repos

echo ""
echo "save_agent_sweep_state:"
run_test "creates state file" test_save_state_creates_file
run_test "produces valid JSON" test_save_state_valid_json
run_test "contains run_id" test_save_state_contains_run_id
run_test "contains status" test_save_state_contains_status
run_test "contains started_at" test_save_state_contains_started_at
run_test "contains repos_completed" test_save_state_contains_completed_repos
run_test "contains counts" test_save_state_contains_counts
run_test "fails without initialization" test_save_state_fails_without_init
run_test "uses atomic write (no temp files left)" test_save_state_atomic_write

echo ""
echo "load_agent_sweep_state:"
run_test "returns false when no file" test_load_state_returns_false_no_file
run_test "returns false without init" test_load_state_returns_false_no_init
run_test "restores run_id" test_load_state_restores_run_id
run_test "restores completed repos" test_load_state_restores_completed_repos
run_test "restores counts" test_load_state_restores_counts
run_test "rejects 'completed' status" test_load_state_rejects_completed
run_test "accepts 'interrupted' status" test_load_state_accepts_interrupted
run_test "accepts 'in_progress' status" test_load_state_accepts_in_progress

echo ""
echo "cleanup_agent_sweep_state:"
run_test "removes state file" test_cleanup_removes_state_file
run_test "is idempotent" test_cleanup_idempotent
run_test "handles uninitialized state dir" test_cleanup_without_init

echo ""
echo "mark_repo_completed:"
run_test "adds repo to array" test_mark_completed_adds_to_array
run_test "tracks multiple repos" test_mark_completed_multiple
run_test "increments success count" test_mark_completed_increments_success
run_test "increments failed count" test_mark_completed_increments_failed
run_test "increments skipped count" test_mark_completed_increments_skipped
run_test "defaults to success" test_mark_completed_defaults_success
run_test "fails with empty arg" test_mark_completed_fails_empty

echo ""
echo "is_sweep_repo_completed:"
run_test "returns true for completed repo" test_is_completed_true
run_test "returns false for uncompleted repo" test_is_completed_false
run_test "handles empty array" test_is_completed_empty_array

echo ""
echo "filter_sweep_completed_repos:"
run_test "removes completed repos" test_filter_removes_completed
run_test "preserves uncompleted repos" test_filter_preserves_uncompleted
run_test "handles empty completed list" test_filter_empty_completed
run_test "handles all completed" test_filter_all_completed

echo ""
echo "Artifact capture integration:"
run_test "creates per-repo artifact directory" test_artifacts_dir_per_repo
run_test "captures git state before" test_artifacts_git_before_captured
run_test "captures git state after" test_artifacts_git_after_captured
run_test "logs activity snapshots" test_artifacts_activity_log
run_test "captures plan JSON" test_artifacts_plan_json_captured

echo ""
echo "Resume workflow:"
run_test "full resume cycle" test_resume_workflow_full_cycle
run_test "filters pending repos after resume" test_resume_filters_pending_repos
run_test "restart clears all state" test_restart_clears_state

echo ""
echo "=== Results ==="
echo -e "Total: $TESTS_RUN | ${GREEN}Passed: $TESTS_PASSED${NC} | ${RED}Failed: $TESTS_FAILED${NC}"
echo ""

[[ $TESTS_FAILED -eq 0 ]]
