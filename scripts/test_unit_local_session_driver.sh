#!/usr/bin/env bash
#
# Unit tests: Local session driver (bd-ctzj)
#
# Tests local tmux driver with real tmux sessions.
#
# Functions tested:
# - local_driver_session_alive(): Check session status
# - local_driver_stop_session(): Stop session
# - local_driver_list_sessions(): List all sessions
# - local_driver_get_session_state(): Get session state
# - local_driver_send_to_session(): Send keys to session
# - local_driver_interrupt_session(): Send Ctrl-C
#
# Note: local_driver_start_session is tested separately as it requires
# the full claude command setup. These tests use simple tmux sessions.
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Skip all tests if tmux is unavailable
if ! command -v tmux &>/dev/null; then
    echo "SKIP: tmux not available, skipping local session driver tests"
    exit 0
fi

# Source required functions from ru
# Note: Functions with heredocs don't source well, so define them inline below
source_ru_function "local_driver_session_alive"
source_ru_function "local_driver_stop_session"
source_ru_function "local_driver_list_sessions"
source_ru_function "local_driver_send_to_session"
source_ru_function "local_driver_interrupt_session"

# Define local_driver_get_session_state inline (has heredocs that break source_ru_function)
local_driver_get_session_state() {
    local session_id="$1"

    # Check if tmux session exists
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

    # Check if process is running in the session
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

    # Check if child process (claude) is running
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

# Test session prefix - unique per test run to avoid conflicts
TEST_SESSION_PREFIX="ru-test-$$"

# Stubs for logging
log_error() { echo "ERROR: $*" >&2; }
log_verbose() { :; }

# Helper: Create a simple test tmux session
# Args: session_name [command]
create_test_session() {
    local session_name="$1"
    local command="${2:-sleep 300}"

    tmux new-session -d -s "$session_name" "$command" 2>/dev/null
}

# Helper: Kill test session if exists
cleanup_test_session() {
    local session_name="$1"
    tmux kill-session -t "$session_name" 2>/dev/null || true
}

# Cleanup function for test suite - kill all test sessions
cleanup_all_test_sessions() {
    local sessions
    sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TEST_SESSION_PREFIX}" || true)
    for session in $sessions; do
        tmux kill-session -t "$session" 2>/dev/null || true
    done
}

# Ensure cleanup on exit
trap cleanup_all_test_sessions EXIT

#==============================================================================
# Tests: local_driver_session_alive
#==============================================================================

test_session_alive_returns_true_for_existing() {
    local test_name="local_driver_session_alive: returns 0 for existing session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-alive-1"
    cleanup_test_session "$session"

    create_test_session "$session"

    if local_driver_session_alive "$session"; then
        pass "returns 0 for existing session"
    else
        fail "returns 0 for existing session" "expected 0" "$?"
    fi

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

test_session_alive_returns_false_for_nonexistent() {
    local test_name="local_driver_session_alive: returns 1 for nonexistent session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-nonexistent"
    cleanup_test_session "$session"  # Ensure it doesn't exist

    if local_driver_session_alive "$session"; then
        fail "returns 1 for nonexistent session" "expected 1" "0"
    else
        pass "returns 1 for nonexistent session"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: local_driver_stop_session
#==============================================================================

test_stop_session_kills_existing() {
    local test_name="local_driver_stop_session: kills existing session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-stop-1"
    cleanup_test_session "$session"

    create_test_session "$session"

    # Verify session exists
    assert_true "tmux has-session -t '$session' 2>/dev/null" "session exists before stop"

    # Stop the session
    local_driver_stop_session "$session"

    # Verify session is gone
    if tmux has-session -t "$session" 2>/dev/null; then
        fail "session stopped" "session should not exist" "session still exists"
    else
        pass "session stopped"
    fi

    log_test_pass "$test_name"
}

test_stop_session_handles_nonexistent() {
    local test_name="local_driver_stop_session: handles nonexistent gracefully"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-stop-nonexistent"
    cleanup_test_session "$session"  # Ensure it doesn't exist

    # Should not error
    local_driver_stop_session "$session"
    local rc=$?

    assert_equals "0" "$rc" "returns 0 for nonexistent session"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: local_driver_list_sessions
#==============================================================================

test_list_sessions_finds_ru_prefixed() {
    local test_name="local_driver_list_sessions: finds ru- prefixed sessions"
    log_test_start "$test_name"

    # Create sessions with ru- prefix
    local session1="ru-${TEST_SESSION_PREFIX}-list-1"
    local session2="ru-${TEST_SESSION_PREFIX}-list-2"
    cleanup_test_session "$session1"
    cleanup_test_session "$session2"

    create_test_session "$session1"
    create_test_session "$session2"

    local sessions
    sessions=$(local_driver_list_sessions)

    assert_contains "$sessions" "$session1" "lists first session"
    assert_contains "$sessions" "$session2" "lists second session"

    cleanup_test_session "$session1"
    cleanup_test_session "$session2"
    log_test_pass "$test_name"
}

test_list_sessions_excludes_non_ru_prefixed() {
    local test_name="local_driver_list_sessions: excludes non-ru sessions"
    log_test_start "$test_name"

    # Create session without ru- prefix (use "test-" prefix instead)
    local session="test-$$-noru"
    cleanup_test_session "$session"

    create_test_session "$session"

    local sessions
    sessions=$(local_driver_list_sessions)

    if echo "$sessions" | grep -q "$session"; then
        fail "excludes non-ru session" "should not contain $session" "found $session"
    else
        pass "excludes non-ru session"
    fi

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: local_driver_get_session_state
#==============================================================================

test_get_state_dead_for_nonexistent() {
    local test_name="local_driver_get_session_state: returns dead for nonexistent"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-state-nonexistent"
    cleanup_test_session "$session"

    local state
    state=$(local_driver_get_session_state "$session")

    local state_value
    state_value=$(echo "$state" | jq -r '.state' 2>/dev/null)

    assert_equals "dead" "$state_value" "state is dead for nonexistent session"

    log_test_pass "$test_name"
}

test_get_state_for_running_session() {
    local test_name="local_driver_get_session_state: returns state for running session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-state-running"
    cleanup_test_session "$session"

    # Create session with a long-running process
    create_test_session "$session" "sleep 300"

    # Give tmux a moment to start the process
    sleep 0.2

    local state
    state=$(local_driver_get_session_state "$session")

    local state_value session_id
    state_value=$(echo "$state" | jq -r '.state' 2>/dev/null)
    session_id=$(echo "$state" | jq -r '.session_id' 2>/dev/null)

    assert_equals "$session" "$session_id" "session_id matches"
    # State should be either "generating" (process running) or "complete" (process done)
    # For our sleep command, it should be "generating"
    if [[ "$state_value" == "generating" || "$state_value" == "complete" ]]; then
        pass "state is valid"
    else
        fail "state is valid" "generating or complete" "$state_value"
    fi

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: local_driver_send_to_session
#==============================================================================

test_send_to_session_returns_error_for_nonexistent() {
    local test_name="local_driver_send_to_session: errors on nonexistent session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-send-nonexistent"
    cleanup_test_session "$session"

    local rc=0
    local_driver_send_to_session "$session" "test message" 2>/dev/null || rc=$?

    assert_equals "1" "$rc" "returns 1 for nonexistent session"

    log_test_pass "$test_name"
}

test_send_to_session_sends_to_existing() {
    local test_name="local_driver_send_to_session: sends to existing session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-send-existing"
    cleanup_test_session "$session"

    # Create session with cat to capture input
    create_test_session "$session" "cat"
    sleep 0.2

    local rc=0
    local_driver_send_to_session "$session" "test message" || rc=$?

    assert_equals "0" "$rc" "returns 0 for existing session"

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: local_driver_interrupt_session
#==============================================================================

test_interrupt_session_returns_error_for_nonexistent() {
    local test_name="local_driver_interrupt_session: errors on nonexistent session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-interrupt-nonexistent"
    cleanup_test_session "$session"

    local rc=0
    local_driver_interrupt_session "$session" 2>/dev/null || rc=$?

    assert_equals "1" "$rc" "returns 1 for nonexistent session"

    log_test_pass "$test_name"
}

test_interrupt_session_sends_ctrl_c() {
    local test_name="local_driver_interrupt_session: sends Ctrl-C to running session"
    log_test_start "$test_name"

    local session="${TEST_SESSION_PREFIX}-interrupt-running"
    cleanup_test_session "$session"

    # Create session with sleep command
    create_test_session "$session" "sleep 300"
    sleep 0.2

    local rc=0
    local_driver_interrupt_session "$session" || rc=$?

    assert_equals "0" "$rc" "returns 0 for existing session"

    cleanup_test_session "$session"
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "Unit Tests: Local Session Driver"

# local_driver_session_alive tests
run_test test_session_alive_returns_true_for_existing
run_test test_session_alive_returns_false_for_nonexistent

# local_driver_stop_session tests
run_test test_stop_session_kills_existing
run_test test_stop_session_handles_nonexistent

# local_driver_list_sessions tests
run_test test_list_sessions_finds_ru_prefixed
run_test test_list_sessions_excludes_non_ru_prefixed

# local_driver_get_session_state tests
run_test test_get_state_dead_for_nonexistent
run_test test_get_state_for_running_session

# local_driver_send_to_session tests
run_test test_send_to_session_returns_error_for_nonexistent
run_test test_send_to_session_sends_to_existing

# local_driver_interrupt_session tests
run_test test_interrupt_session_returns_error_for_nonexistent
run_test test_interrupt_session_sends_ctrl_c

print_results
exit "$(get_exit_code)"
