#!/usr/bin/env bash
#------------------------------------------------------------------------------
# test_unit_artifact_capture.sh
# Unit tests for agent-sweep artifact capture functions
#------------------------------------------------------------------------------
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

# Stubs for logging functions
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

# Global vars required by extracted functions
VERBOSE=false
LOG_LEVEL=0

# Stub for ensure_dir
ensure_dir() { mkdir -p "$1" 2>/dev/null; }

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
#------------------------------------------------------------------------------
EXTRACT_FILE=$(mktemp)

# Extract result tracking globals
sed -n '/^# Global result tracking state/,/^# Initialize agent-sweep/p' "$RU_SCRIPT" | drop_last_lines 2 > "$EXTRACT_FILE"

# Extract setup_agent_sweep_results function
awk '/^setup_agent_sweep_results\(\) \{/,/^}/' "$RU_SCRIPT" >> "$EXTRACT_FILE"

# Extract artifact capture section (from ARTIFACT CAPTURE header to STATE PERSISTENCE header)
sed -n '/^# AGENT-SWEEP ARTIFACT CAPTURE/,/^# AGENT-SWEEP STATE PERSISTENCE/p' "$RU_SCRIPT" | drop_last_lines 3 >> "$EXTRACT_FILE"

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

    # Initialize sweep state (sets RUN_ARTIFACTS_DIR, etc.)
    setup_agent_sweep_results 2>/dev/null || true
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

run_test() {
    local test_name="$1"
    local test_func="$2"

    ((TESTS_RUN++))
    printf "  %-50s " "$test_name"

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
# Tests for setup_repo_artifact_dir
#------------------------------------------------------------------------------

test_setup_repo_artifact_dir_creates_dir() {
    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    [[ -d "$artifact_dir" ]] || {
        echo "Artifact dir not created"
        return 1
    }
}

test_setup_repo_artifact_dir_returns_path() {
    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")

    [[ "$artifact_dir" == *"/test_repo" ]] || {
        echo "Path doesn't end with repo name: $artifact_dir"
        return 1
    }
}

test_setup_repo_artifact_dir_sets_global() {
    setup_repo_artifact_dir "$TEST_REPO" >/dev/null

    [[ -n "$CURRENT_REPO_ARTIFACT_DIR" ]] || {
        echo "CURRENT_REPO_ARTIFACT_DIR not set"
        return 1
    }
}

test_setup_repo_artifact_dir_fails_empty() {
    ! setup_repo_artifact_dir "" 2>/dev/null
}

test_setup_repo_artifact_dir_requires_run_artifacts_dir() {
    RUN_ARTIFACTS_DIR=""
    ! setup_repo_artifact_dir "$TEST_REPO" 2>/dev/null
}

#------------------------------------------------------------------------------
# Tests for capture_git_state
#------------------------------------------------------------------------------

test_capture_git_state_creates_file() {
    local output_file="$TEST_TMP/git_state.txt"
    capture_git_state "$TEST_REPO" "$output_file"

    assert_file_exists "$output_file"
}

test_capture_git_state_contains_status() {
    local output_file="$TEST_TMP/git_state.txt"
    capture_git_state "$TEST_REPO" "$output_file"

    assert_file_contains "$output_file" "git status"
}

test_capture_git_state_contains_log() {
    local output_file="$TEST_TMP/git_state.txt"
    capture_git_state "$TEST_REPO" "$output_file"

    assert_file_contains "$output_file" "git log"
}

test_capture_git_state_contains_head() {
    local output_file="$TEST_TMP/git_state.txt"
    capture_git_state "$TEST_REPO" "$output_file"

    assert_file_contains "$output_file" "HEAD"
}

test_capture_git_state_contains_timestamp() {
    local output_file="$TEST_TMP/git_state.txt"
    capture_git_state "$TEST_REPO" "$output_file"

    assert_file_contains "$output_file" "Captured at:"
}

test_capture_git_state_fails_invalid_repo() {
    ! capture_git_state "/nonexistent" "$TEST_TMP/out.txt" 2>/dev/null
}

test_capture_git_state_fails_empty_output() {
    ! capture_git_state "$TEST_REPO" "" 2>/dev/null
}

#------------------------------------------------------------------------------
# Tests for capture_pane_tail
#------------------------------------------------------------------------------

test_capture_pane_tail_fails_empty_args() {
    ! capture_pane_tail "" "" 2>/dev/null
}

test_capture_pane_tail_fails_empty_session() {
    ! capture_pane_tail "" "$TEST_TMP/out.txt" 2>/dev/null
}

test_capture_pane_tail_writes_session_not_found() {
    local output_file="$TEST_TMP/pane.txt"
    capture_pane_tail "nonexistent_session_xyz" "$output_file" 2>/dev/null

    # Should write something indicating session not found
    assert_file_exists "$output_file"
    assert_file_contains "$output_file" "session not found"
}

#------------------------------------------------------------------------------
# Tests for capture_spawn_response
#------------------------------------------------------------------------------

test_capture_spawn_response_creates_file() {
    capture_spawn_response "$TEST_REPO" '{"success":true}'

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/spawn.json"
}

test_capture_spawn_response_writes_json() {
    capture_spawn_response "$TEST_REPO" '{"success":true,"session":"test"}'

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_contains "${artifact_dir}/spawn.json" "success"
}

test_capture_spawn_response_fails_empty() {
    ! capture_spawn_response "" "" 2>/dev/null
}

#------------------------------------------------------------------------------
# Tests for capture_plan_json
#------------------------------------------------------------------------------

test_capture_plan_json_commit() {
    capture_plan_json "$TEST_REPO" "commit" '{"commits":[]}'

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/commit_plan.json"
}

test_capture_plan_json_release() {
    capture_plan_json "$TEST_REPO" "release" '{"version":"1.0.0"}'

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/release_plan.json"
}

test_capture_plan_json_fails_invalid_type() {
    ! capture_plan_json "$TEST_REPO" "invalid" '{}' 2>/dev/null
}

test_capture_plan_json_fails_empty() {
    ! capture_plan_json "" "" "" 2>/dev/null
}

#------------------------------------------------------------------------------
# Tests for log_activity_snapshot
#------------------------------------------------------------------------------

test_log_activity_snapshot_creates_file() {
    log_activity_snapshot "$TEST_REPO" "phase1" "started"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/activity.ndjson"
}

test_log_activity_snapshot_appends() {
    log_activity_snapshot "$TEST_REPO" "phase1" "started"
    log_activity_snapshot "$TEST_REPO" "phase1" "completed"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    local count
    count=$(wc -l < "${artifact_dir}/activity.ndjson")

    [[ "$count" -eq 2 ]] || {
        echo "Expected 2 lines, got $count"
        return 1
    }
}

test_log_activity_snapshot_contains_ts() {
    log_activity_snapshot "$TEST_REPO" "phase1" "started"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_contains "${artifact_dir}/activity.ndjson" '"ts":'
}

test_log_activity_snapshot_contains_phase() {
    log_activity_snapshot "$TEST_REPO" "phase2" "running"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_contains "${artifact_dir}/activity.ndjson" '"phase":"phase2"'
}

test_log_activity_snapshot_contains_status() {
    log_activity_snapshot "$TEST_REPO" "phase1" "timeout"

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_contains "${artifact_dir}/activity.ndjson" '"status":"timeout"'
}

test_log_activity_snapshot_fails_empty() {
    ! log_activity_snapshot "" "" "" 2>/dev/null
}

#------------------------------------------------------------------------------
# Tests for capture_final_artifacts
#------------------------------------------------------------------------------

test_capture_final_artifacts_creates_git_after() {
    capture_final_artifacts "$TEST_REPO" ""

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/git_after.txt"
}

test_capture_final_artifacts_logs_activity() {
    capture_final_artifacts "$TEST_REPO" ""

    local artifact_dir
    artifact_dir=$(setup_repo_artifact_dir "$TEST_REPO")
    assert_file_exists "${artifact_dir}/activity.ndjson"
    assert_file_contains "${artifact_dir}/activity.ndjson" '"phase":"complete"'
}

test_capture_final_artifacts_fails_empty() {
    ! capture_final_artifacts "" "" 2>/dev/null
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

echo ""
echo "=== Artifact Capture Unit Tests ==="
echo ""

echo "setup_repo_artifact_dir:"
run_test "creates directory" test_setup_repo_artifact_dir_creates_dir
run_test "returns path with repo name" test_setup_repo_artifact_dir_returns_path
run_test "sets CURRENT_REPO_ARTIFACT_DIR" test_setup_repo_artifact_dir_sets_global
run_test "fails with empty path" test_setup_repo_artifact_dir_fails_empty
run_test "requires RUN_ARTIFACTS_DIR" test_setup_repo_artifact_dir_requires_run_artifacts_dir

echo ""
echo "capture_git_state:"
run_test "creates output file" test_capture_git_state_creates_file
run_test "contains git status" test_capture_git_state_contains_status
run_test "contains git log" test_capture_git_state_contains_log
run_test "contains HEAD" test_capture_git_state_contains_head
run_test "contains timestamp" test_capture_git_state_contains_timestamp
run_test "fails with invalid repo" test_capture_git_state_fails_invalid_repo
run_test "fails with empty output path" test_capture_git_state_fails_empty_output

echo ""
echo "capture_pane_tail:"
run_test "fails with empty args" test_capture_pane_tail_fails_empty_args
run_test "fails with empty session" test_capture_pane_tail_fails_empty_session
run_test "writes 'session not found' for missing session" test_capture_pane_tail_writes_session_not_found

echo ""
echo "capture_spawn_response:"
run_test "creates spawn.json" test_capture_spawn_response_creates_file
run_test "writes JSON content" test_capture_spawn_response_writes_json
run_test "fails with empty args" test_capture_spawn_response_fails_empty

echo ""
echo "capture_plan_json:"
run_test "creates commit_plan.json" test_capture_plan_json_commit
run_test "creates release_plan.json" test_capture_plan_json_release
run_test "fails with invalid type" test_capture_plan_json_fails_invalid_type
run_test "fails with empty args" test_capture_plan_json_fails_empty

echo ""
echo "log_activity_snapshot:"
run_test "creates activity.ndjson" test_log_activity_snapshot_creates_file
run_test "appends multiple entries" test_log_activity_snapshot_appends
run_test "contains timestamp" test_log_activity_snapshot_contains_ts
run_test "contains phase" test_log_activity_snapshot_contains_phase
run_test "contains status" test_log_activity_snapshot_contains_status
run_test "fails with empty args" test_log_activity_snapshot_fails_empty

echo ""
echo "capture_final_artifacts:"
run_test "creates git_after.txt" test_capture_final_artifacts_creates_git_after
run_test "logs activity snapshot" test_capture_final_artifacts_logs_activity
run_test "fails with empty repo" test_capture_final_artifacts_fails_empty

echo ""
echo "=== Results ==="
echo -e "Total: $TESTS_RUN | ${GREEN}Passed: $TESTS_PASSED${NC} | ${RED}Failed: $TESTS_FAILED${NC}"
echo ""

[[ $TESTS_FAILED -eq 0 ]]
