#!/usr/bin/env bash
#
# Unit tests: Driver interface layer (bd-t3mp)
#
# Tests the unified driver interface that provides abstraction over
# different session drivers (local tmux, ntm).
#
# Functions tested:
# - detect_review_driver(): Auto-detect available driver
# - load_review_driver(): Load driver functions
# - driver_capabilities(): Query driver capabilities
# - driver_* unified interface: Verify local driver integration
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
# shellcheck disable=SC2120  # Wrapper functions pass "$@" even if not all callers use args

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Skip if tmux unavailable (needed for local driver)
if ! command -v tmux &>/dev/null; then
    echo "SKIP: tmux not available, skipping driver interface tests"
    exit 0
fi

# Source required functions from ru
source_ru_function "detect_review_driver"
source_ru_function "load_review_driver"

# Define _enable_local_driver inline (redefines driver_* functions)
# This is needed because the function redefines other functions which
# breaks when extracted with sed
_enable_local_driver() {
    driver_start_session() {
        local_driver_start_session "$@"
    }
    driver_send_to_session() {
        local_driver_send_to_session "$@"
    }
    driver_get_session_state() {
        local_driver_get_session_state "$@"
    }
    driver_stop_session() {
        local_driver_stop_session "$@"
    }
    driver_interrupt_session() {
        local_driver_interrupt_session "$@"
    }
    driver_stream_events() {
        local_driver_stream_events "$@"
    }
    driver_list_sessions() {
        local_driver_list_sessions "$@"
    }
    driver_session_alive() {
        local_driver_session_alive "$@"
    }

    # Update capabilities for local driver
    driver_capabilities() {
        cat <<EOF
{
  "name": "local",
  "parallel_sessions": true,
  "activity_detection": false,
  "health_monitoring": false,
  "question_routing": true,
  "max_concurrent": 4
}
EOF
    }
}

# Source local driver functions (needed by _enable_local_driver)
source_ru_function "local_driver_session_alive"
source_ru_function "local_driver_stop_session"
source_ru_function "local_driver_list_sessions"
source_ru_function "local_driver_send_to_session"
source_ru_function "local_driver_interrupt_session"

# Define local_driver_get_session_state inline (has heredocs)
local_driver_get_session_state() {
    local session_id="$1"

    if ! tmux has-session -t "$session_id" 2>/dev/null; then
        cat <<EOF
{
  "session_id": "$session_id",
  "state": "dead",
  "reason": "tmux session not found"
}
EOF
        return 0
    fi

    local pane_pid
    pane_pid=$(tmux list-panes -t "$session_id" -F "#{pane_pid}" 2>/dev/null | head -1)

    if [[ -z "$pane_pid" ]]; then
        cat <<EOF
{
  "session_id": "$session_id",
  "state": "unknown",
  "reason": "no pane found"
}
EOF
        return 0
    fi

    local children
    children=$(pgrep -P "$pane_pid" 2>/dev/null | wc -l)

    local state="generating"
    if [[ "$children" -eq 0 ]]; then
        state="complete"
    fi

    cat <<EOF
{
  "session_id": "$session_id",
  "state": "$state",
  "pane_pid": $pane_pid
}
EOF
    return 0
}

# Global for driver loading
LOADED_DRIVER=""

# Stubs for logging
log_error() { echo "ERROR: $*" >&2; }
log_verbose() { :; }

# Test session prefix
TEST_SESSION_PREFIX="ru-test-iface-$$"

# Helper: Create a simple test tmux session
create_test_session() {
    local session_name="$1"
    local command="${2:-sleep 300}"
    tmux new-session -d -s "$session_name" "$command" 2>/dev/null
}

# Helper: Kill test session
cleanup_test_session() {
    local session_name="$1"
    tmux kill-session -t "$session_name" 2>/dev/null || true
}

# Cleanup all test sessions on exit
cleanup_all_test_sessions() {
    local sessions
    sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TEST_SESSION_PREFIX}" || true)
    for session in $sessions; do
        tmux kill-session -t "$session" 2>/dev/null || true
    done
}

trap cleanup_all_test_sessions EXIT

#==============================================================================
# Tests: detect_review_driver
#==============================================================================

test_detect_driver_finds_local_when_tmux_available() {
    local test_name="detect_review_driver: returns 'local' when tmux available"
    log_test_start "$test_name"

    # tmux is available (we checked at top of script)
    local driver
    driver=$(detect_review_driver)

    # Should return either "ntm" or "local" - not "none"
    if [[ "$driver" == "local" || "$driver" == "ntm" ]]; then
        pass "detects available driver"
    else
        fail "detects available driver" "local or ntm" "$driver"
    fi

    log_test_pass "$test_name"
}

test_detect_driver_returns_none_without_tools() {
    local test_name="detect_review_driver: returns 'none' without tools"
    log_test_start "$test_name"

    # Save PATH and create empty PATH
    local old_path="$PATH"
    export PATH="/nonexistent"

    local driver
    driver=$(detect_review_driver)

    export PATH="$old_path"

    assert_equals "none" "$driver" "returns none without tmux or ntm"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: load_review_driver
#==============================================================================

test_load_driver_local_succeeds() {
    local test_name="load_review_driver: loads local driver successfully"
    log_test_start "$test_name"

    LOADED_DRIVER=""

    local rc=0
    load_review_driver "local" || rc=$?

    assert_equals "0" "$rc" "returns 0 for local driver"
    assert_equals "local" "$LOADED_DRIVER" "LOADED_DRIVER set to local"

    log_test_pass "$test_name"
}

test_load_driver_none_fails() {
    local test_name="load_review_driver: fails for 'none' driver"
    log_test_start "$test_name"

    local rc=0
    load_review_driver "none" 2>/dev/null || rc=$?

    assert_equals "1" "$rc" "returns 1 for none driver"

    log_test_pass "$test_name"
}

test_load_driver_unknown_fails() {
    local test_name="load_review_driver: fails for unknown driver"
    log_test_start "$test_name"

    local rc=0
    load_review_driver "unknown-driver" 2>/dev/null || rc=$?

    assert_equals "1" "$rc" "returns 1 for unknown driver"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: driver_capabilities
#==============================================================================

test_driver_capabilities_returns_json() {
    local test_name="driver_capabilities: returns valid JSON"
    log_test_start "$test_name"

    # Load local driver first
    load_review_driver "local"

    local caps
    caps=$(driver_capabilities)

    # Check it's valid JSON
    if echo "$caps" | jq empty 2>/dev/null; then
        pass "returns valid JSON"
    else
        fail "returns valid JSON" "valid JSON" "invalid JSON"
    fi

    log_test_pass "$test_name"
}

test_driver_capabilities_has_name() {
    local test_name="driver_capabilities: includes driver name"
    log_test_start "$test_name"

    load_review_driver "local"

    local caps
    caps=$(driver_capabilities)

    local name
    name=$(echo "$caps" | jq -r '.name' 2>/dev/null)

    assert_equals "local" "$name" "name is 'local'"

    log_test_pass "$test_name"
}

test_driver_capabilities_has_parallel_sessions() {
    local test_name="driver_capabilities: includes parallel_sessions"
    log_test_start "$test_name"

    load_review_driver "local"

    local caps
    caps=$(driver_capabilities)

    local parallel
    parallel=$(echo "$caps" | jq -r '.parallel_sessions' 2>/dev/null)

    assert_equals "true" "$parallel" "parallel_sessions is true"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Unified interface after loading local driver
#==============================================================================

test_unified_session_alive_works() {
    local test_name="driver_session_alive: works after loading local driver"
    log_test_start "$test_name"

    load_review_driver "local"

    local session="${TEST_SESSION_PREFIX}-alive"
    cleanup_test_session "$session"

    create_test_session "$session"

    if driver_session_alive "$session"; then
        pass "driver_session_alive returns true for existing"
    else
        fail "driver_session_alive returns true for existing" "0" "non-zero"
    fi

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

test_unified_stop_session_works() {
    local test_name="driver_stop_session: works after loading local driver"
    log_test_start "$test_name"

    load_review_driver "local"

    local session="${TEST_SESSION_PREFIX}-stop"
    cleanup_test_session "$session"

    create_test_session "$session"

    driver_stop_session "$session"

    if tmux has-session -t "$session" 2>/dev/null; then
        fail "driver_stop_session kills session" "no session" "session exists"
    else
        pass "driver_stop_session kills session"
    fi

    log_test_pass "$test_name"
}

test_unified_get_state_works() {
    local test_name="driver_get_session_state: works after loading local driver"
    log_test_start "$test_name"

    load_review_driver "local"

    local session="${TEST_SESSION_PREFIX}-state"
    cleanup_test_session "$session"

    # Test non-existent session
    local state
    state=$(driver_get_session_state "$session")

    local state_value
    state_value=$(echo "$state" | jq -r '.state' 2>/dev/null)

    assert_equals "dead" "$state_value" "returns dead for nonexistent"

    log_test_pass "$test_name"
}

test_unified_list_sessions_works() {
    local test_name="driver_list_sessions: works after loading local driver"
    log_test_start "$test_name"

    load_review_driver "local"

    local session="ru-${TEST_SESSION_PREFIX}-list"
    cleanup_test_session "$session"

    create_test_session "$session"

    local sessions
    sessions=$(driver_list_sessions)

    assert_contains "$sessions" "$session" "lists ru- prefixed session"

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

test_unified_send_to_session_works() {
    local test_name="driver_send_to_session: works after loading local driver"
    log_test_start "$test_name"

    load_review_driver "local"

    local session="${TEST_SESSION_PREFIX}-send"
    cleanup_test_session "$session"

    create_test_session "$session" "cat"
    sleep 0.2

    local rc=0
    driver_send_to_session "$session" "test" || rc=$?

    assert_equals "0" "$rc" "sends to existing session"

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "Unit Tests: Driver Interface Layer"

# detect_review_driver tests
run_test test_detect_driver_finds_local_when_tmux_available
run_test test_detect_driver_returns_none_without_tools

# load_review_driver tests
run_test test_load_driver_local_succeeds
run_test test_load_driver_none_fails
run_test test_load_driver_unknown_fails

# driver_capabilities tests
run_test test_driver_capabilities_returns_json
run_test test_driver_capabilities_has_name
run_test test_driver_capabilities_has_parallel_sessions

# Unified interface tests
run_test test_unified_session_alive_works
run_test test_unified_stop_session_works
run_test test_unified_get_state_works
run_test test_unified_list_sessions_works
run_test test_unified_send_to_session_works

print_results
exit "$(get_exit_code)"
