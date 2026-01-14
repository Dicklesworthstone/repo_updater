#!/usr/bin/env bash
#
# Unit tests for sync state management functions
# Tests: load_sync_state, save_sync_state, cleanup_sync_state, is_repo_completed
#
# These functions manage resume/restart functionality for interrupted syncs.
# Tests use real temporary directories - no mocks.
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
# shellcheck disable=SC2155  # Declare and assign separately - acceptable in tests
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Environment Setup
#==============================================================================

# Minimal environment needed for sync state functions
TEMP_DIR=""
RU_STATE_DIR=""
XDG_STATE_HOME=""

# Global state variables (populated by load_sync_state)
SYNC_RUN_ID=""
SYNC_STATUS=""
SYNC_CONFIG_HASH=""
SYNC_COMPLETED=()
SYNC_PENDING=()
RESULTS_FILE=""

# Stub functions needed by save_sync_state
ensure_dir() {
    [[ -n "$1" ]] && mkdir -p "$1"
}

get_config_hash() {
    echo "test-config-hash-$(date +%s)"
}

# Source the actual functions from ru using awk with brace counting
# (simple patterns break on functions with heredocs)
extract_function() {
    local func_name="$1"
    local file="$2"
    awk -v fn="$func_name" '
        $0 ~ "^"fn"\\(\\)" {
            printing=1
            depth=0
        }
        printing {
            print
            # Count braces (simple counting, ignores strings/comments)
            for(i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if(c == "{") depth++
                if(c == "}") depth--
            }
            if(depth == 0 && /}/) exit
        }
    ' "$file"
}

source <(extract_function "_is_valid_var_name" "$PROJECT_DIR/ru")
source <(extract_function "json_escape" "$PROJECT_DIR/ru")
source <(extract_function "get_sync_state_file" "$PROJECT_DIR/ru")
source <(extract_function "load_sync_state" "$PROJECT_DIR/ru")
source <(extract_function "save_sync_state" "$PROJECT_DIR/ru")
source <(extract_function "cleanup_sync_state" "$PROJECT_DIR/ru")
source <(extract_function "is_repo_completed" "$PROJECT_DIR/ru")

#==============================================================================
# Test Setup/Teardown
#==============================================================================

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    XDG_STATE_HOME="$TEMP_DIR/state"
    RU_STATE_DIR="$XDG_STATE_HOME/ru"
    mkdir -p "$RU_STATE_DIR"

    # Reset global state
    SYNC_RUN_ID=""
    SYNC_STATUS=""
    SYNC_CONFIG_HASH=""
    SYNC_COMPLETED=()
    SYNC_PENDING=()
    RESULTS_FILE=""
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

#==============================================================================
# Test: get_sync_state_file
#==============================================================================

test_get_sync_state_file_returns_correct_path() {
    setup_test_env
    trap cleanup_test_env EXIT

    local state_file
    state_file=$(get_sync_state_file)

    assert_equals "$RU_STATE_DIR/sync_state.json" "$state_file" \
        "get_sync_state_file returns correct path"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: load_sync_state
#==============================================================================

test_load_sync_state_returns_1_when_file_missing() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Ensure no state file exists
    rm -f "$RU_STATE_DIR/sync_state.json" 2>/dev/null || true

    local result
    if load_sync_state; then
        result=0
    else
        result=$?
    fi

    assert_equals "1" "$result" \
        "load_sync_state returns 1 when file missing"

    cleanup_test_env
    trap - EXIT
}

test_load_sync_state_parses_basic_fields() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a state file with basic fields
    cat > "$RU_STATE_DIR/sync_state.json" <<'EOF'
{
  "run_id": "2025-01-03T10:00:00+00:00",
  "status": "in_progress",
  "config_hash": "abc123hash",
  "results_file": "/tmp/results.ndjson",
  "completed": [],
  "pending": []
}
EOF

    load_sync_state

    assert_equals "2025-01-03T10:00:00+00:00" "$SYNC_RUN_ID" \
        "load_sync_state parses run_id"
    assert_equals "in_progress" "$SYNC_STATUS" \
        "load_sync_state parses status"
    assert_equals "abc123hash" "$SYNC_CONFIG_HASH" \
        "load_sync_state parses config_hash"

    cleanup_test_env
    trap - EXIT
}

test_load_sync_state_parses_completed_array() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a state file with completed repos
    cat > "$RU_STATE_DIR/sync_state.json" <<'EOF'
{
  "run_id": "test-run",
  "status": "in_progress",
  "config_hash": "xyz",
  "results_file": "",
  "completed": ["repo1", "repo2", "repo3"],
  "pending": []
}
EOF

    load_sync_state

    assert_equals "3" "${#SYNC_COMPLETED[@]}" \
        "load_sync_state parses 3 completed repos"
    assert_equals "repo1" "${SYNC_COMPLETED[0]}" \
        "First completed repo is repo1"
    assert_equals "repo2" "${SYNC_COMPLETED[1]}" \
        "Second completed repo is repo2"
    assert_equals "repo3" "${SYNC_COMPLETED[2]}" \
        "Third completed repo is repo3"

    cleanup_test_env
    trap - EXIT
}

test_load_sync_state_parses_pending_array() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a state file with pending repos
    cat > "$RU_STATE_DIR/sync_state.json" <<'EOF'
{
  "run_id": "test-run",
  "status": "in_progress",
  "config_hash": "xyz",
  "results_file": "",
  "completed": [],
  "pending": ["pending1", "pending2"]
}
EOF

    load_sync_state

    assert_equals "2" "${#SYNC_PENDING[@]}" \
        "load_sync_state parses 2 pending repos"
    assert_equals "pending1" "${SYNC_PENDING[0]}" \
        "First pending repo is pending1"
    assert_equals "pending2" "${SYNC_PENDING[1]}" \
        "Second pending repo is pending2"

    cleanup_test_env
    trap - EXIT
}

test_load_sync_state_handles_empty_arrays() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a state file with empty arrays
    cat > "$RU_STATE_DIR/sync_state.json" <<'EOF'
{
  "run_id": "test-run",
  "status": "completed",
  "config_hash": "xyz",
  "results_file": "",
  "completed": [],
  "pending": []
}
EOF

    load_sync_state

    assert_equals "0" "${#SYNC_COMPLETED[@]}" \
        "load_sync_state handles empty completed array"
    assert_equals "0" "${#SYNC_PENDING[@]}" \
        "load_sync_state handles empty pending array"

    cleanup_test_env
    trap - EXIT
}

test_load_sync_state_returns_0_on_success() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a valid state file
    cat > "$RU_STATE_DIR/sync_state.json" <<'EOF'
{
  "run_id": "test",
  "status": "test",
  "config_hash": "test",
  "completed": [],
  "pending": []
}
EOF

    local result
    if load_sync_state; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "load_sync_state returns 0 on success"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: save_sync_state
#==============================================================================

test_save_sync_state_creates_file() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Prepare arrays
    local -a completed=()
    local -a pending=()

    save_sync_state "in_progress" completed pending

    local state_file
    state_file=$(get_sync_state_file)

    assert_file_exists "$state_file" \
        "save_sync_state creates state file"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_writes_status() {
    setup_test_env
    trap cleanup_test_env EXIT

    local -a completed=()
    local -a pending=()

    save_sync_state "my_custom_status" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    assert_contains "$content" '"status": "my_custom_status"' \
        "save_sync_state writes status field"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_writes_completed_array() {
    setup_test_env
    trap cleanup_test_env EXIT

    local -a completed=("repo1" "repo2")
    local -a pending=()

    save_sync_state "in_progress" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    assert_contains "$content" '"repo1"' \
        "save_sync_state includes repo1 in completed"
    assert_contains "$content" '"repo2"' \
        "save_sync_state includes repo2 in completed"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_writes_pending_array() {
    setup_test_env
    trap cleanup_test_env EXIT

    local -a completed=()
    local -a pending=("pending1" "pending2" "pending3")

    save_sync_state "in_progress" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    assert_contains "$content" '"pending1"' \
        "save_sync_state includes pending1"
    assert_contains "$content" '"pending2"' \
        "save_sync_state includes pending2"
    assert_contains "$content" '"pending3"' \
        "save_sync_state includes pending3"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_handles_empty_arrays() {
    setup_test_env
    trap cleanup_test_env EXIT

    local -a completed=()
    local -a pending=()

    save_sync_state "in_progress" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    assert_contains "$content" '"completed": []' \
        "save_sync_state writes empty completed array"
    assert_contains "$content" '"pending": []' \
        "save_sync_state writes empty pending array"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_preserves_run_id() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Set a run_id before saving
    SYNC_RUN_ID="my-unique-run-id"

    local -a completed=()
    local -a pending=()

    save_sync_state "in_progress" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    assert_contains "$content" '"run_id": "my-unique-run-id"' \
        "save_sync_state preserves existing run_id"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_generates_run_id_if_missing() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Ensure no run_id is set
    SYNC_RUN_ID=""

    local -a completed=()
    local -a pending=()

    save_sync_state "in_progress" completed pending

    local state_file content
    state_file=$(get_sync_state_file)
    content=$(<"$state_file")

    # Should contain a generated run_id (ISO date format)
    assert_contains "$content" '"run_id":' \
        "save_sync_state generates run_id when missing"

    # SYNC_RUN_ID should be set after save
    assert_not_empty "$SYNC_RUN_ID" \
        "SYNC_RUN_ID is set after save"

    cleanup_test_env
    trap - EXIT
}

test_save_sync_state_roundtrip() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Save state
    SYNC_RUN_ID="roundtrip-test"
    local -a completed=("c1" "c2")
    local -a pending=("p1")

    save_sync_state "testing" completed pending

    # Reset and load
    SYNC_RUN_ID=""
    SYNC_STATUS=""
    SYNC_COMPLETED=()
    SYNC_PENDING=()

    load_sync_state

    assert_equals "roundtrip-test" "$SYNC_RUN_ID" \
        "Roundtrip preserves run_id"
    assert_equals "testing" "$SYNC_STATUS" \
        "Roundtrip preserves status"
    assert_equals "2" "${#SYNC_COMPLETED[@]}" \
        "Roundtrip preserves completed count"
    assert_equals "1" "${#SYNC_PENDING[@]}" \
        "Roundtrip preserves pending count"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: cleanup_sync_state
#==============================================================================

test_cleanup_sync_state_removes_file() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create a state file
    local -a completed=()
    local -a pending=()
    save_sync_state "in_progress" completed pending

    local state_file
    state_file=$(get_sync_state_file)

    # Verify file exists
    assert_file_exists "$state_file" \
        "State file exists before cleanup"

    # Clean up
    cleanup_sync_state

    # Verify file is gone
    assert_file_not_exists "$state_file" \
        "cleanup_sync_state removes state file"

    cleanup_test_env
    trap - EXIT
}

test_cleanup_sync_state_no_error_when_file_missing() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Ensure no state file
    rm -f "$RU_STATE_DIR/sync_state.json" 2>/dev/null || true

    # The function returns 1 when file is missing (due to [[ -f ]] && rm pattern)
    # but it should not cause script to exit under set -e or produce error messages
    local stderr_output
    stderr_output=$(cleanup_sync_state 2>&1)

    # No error output expected
    assert_equals "" "$stderr_output" \
        "cleanup_sync_state produces no error output when file missing"

    # State dir should still exist (not deleted accidentally)
    assert_dir_exists "$RU_STATE_DIR" \
        "cleanup_sync_state doesn't remove state directory"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: is_repo_completed
#==============================================================================

test_is_repo_completed_returns_0_when_found() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=("repo1" "repo2" "repo3")

    local result
    if is_repo_completed "repo2"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "is_repo_completed returns 0 when repo is in list"

    cleanup_test_env
    trap - EXIT
}

test_is_repo_completed_returns_1_when_not_found() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=("repo1" "repo2" "repo3")

    local result
    if is_repo_completed "repo4"; then
        result=0
    else
        result=$?
    fi

    assert_equals "1" "$result" \
        "is_repo_completed returns 1 when repo not in list"

    cleanup_test_env
    trap - EXIT
}

test_is_repo_completed_returns_1_when_list_empty() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=()

    local result
    if is_repo_completed "anyrepo"; then
        result=0
    else
        result=$?
    fi

    assert_equals "1" "$result" \
        "is_repo_completed returns 1 when list is empty"

    cleanup_test_env
    trap - EXIT
}

test_is_repo_completed_exact_match() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=("repo" "repo-extended")

    local result1 result2
    if is_repo_completed "repo"; then
        result1=0
    else
        result1=$?
    fi
    if is_repo_completed "rep"; then
        result2=0
    else
        result2=$?
    fi

    assert_equals "0" "$result1" \
        "is_repo_completed finds exact match 'repo'"
    assert_equals "1" "$result2" \
        "is_repo_completed doesn't match partial 'rep'"

    cleanup_test_env
    trap - EXIT
}

test_is_repo_completed_first_item() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=("first" "second" "third")

    local result
    if is_repo_completed "first"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "is_repo_completed finds first item"

    cleanup_test_env
    trap - EXIT
}

test_is_repo_completed_last_item() {
    setup_test_env
    trap cleanup_test_env EXIT

    SYNC_COMPLETED=("first" "second" "third")

    local result
    if is_repo_completed "third"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "is_repo_completed finds last item"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Sync State Management"
echo "============================================"

# get_sync_state_file
run_test test_get_sync_state_file_returns_correct_path

# load_sync_state
run_test test_load_sync_state_returns_1_when_file_missing
run_test test_load_sync_state_parses_basic_fields
run_test test_load_sync_state_parses_completed_array
run_test test_load_sync_state_parses_pending_array
run_test test_load_sync_state_handles_empty_arrays
run_test test_load_sync_state_returns_0_on_success

# save_sync_state
run_test test_save_sync_state_creates_file
run_test test_save_sync_state_writes_status
run_test test_save_sync_state_writes_completed_array
run_test test_save_sync_state_writes_pending_array
run_test test_save_sync_state_handles_empty_arrays
run_test test_save_sync_state_preserves_run_id
run_test test_save_sync_state_generates_run_id_if_missing
run_test test_save_sync_state_roundtrip

# cleanup_sync_state
run_test test_cleanup_sync_state_removes_file
run_test test_cleanup_sync_state_no_error_when_file_missing

# is_repo_completed
run_test test_is_repo_completed_returns_0_when_found
run_test test_is_repo_completed_returns_1_when_not_found
run_test test_is_repo_completed_returns_1_when_list_empty
run_test test_is_repo_completed_exact_match
run_test test_is_repo_completed_first_item
run_test test_is_repo_completed_last_item

# Print results
print_results
exit "$(get_exit_code)"
