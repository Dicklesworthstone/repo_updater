#!/usr/bin/env bash
#
# E2E Test: Session monitoring and completion detection (bd-eycs)
#
# Tests session monitoring functionality:
#   1. Full monitoring cycle - start, monitor, complete
#   2. Stall recovery (soft) - Ctrl+C recovery
#   3. Stall recovery (escalate) - /compact command
#   4. Rate limit detection - 429 error handling
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
source_ru_function "json_get_field"
source_ru_function "get_worktree_for_session"
source_ru_function "get_session_log_path"
source_ru_function "session_has_result"
source_ru_function "session_has_error"
source_ru_function "apply_state_hysteresis"
source_ru_function "handle_stalled_session"

# Stub functions for test environment
# These simplify tests by returning sensible defaults
calculate_output_velocity() { echo "15"; }  # Default high velocity
get_last_output_time() { echo $(($(date +%s) - 1)); }  # Recent activity
has_thinking_indicators() { return 1; }  # No thinking
is_at_prompt() { return 1; }  # Not at prompt

# Simplified detect_session_state_raw for E2E tests
# Focuses on result/error detection which is the core monitoring functionality
detect_session_state_raw() {
    local session_id="$1"
    local pipe_log="${RU_STATE_DIR:-/tmp}/pipes/${session_id}.pipe.log"

    # Check for completion first (highest priority)
    if session_has_result "$session_id"; then
        echo "complete"
        return
    fi

    # Check for error patterns
    if session_has_error "$session_id"; then
        echo "error"
        return
    fi

    # Default to generating (active state)
    echo "generating"
}

# Initialize associative arrays
declare -gA SESSION_STATE_HISTORY=()
declare -gA SESSION_STALL_COUNTS=()

SESSION_ERROR_PATTERNS=(
    "rate.limit"
    "429"
    "quota.exceeded"
    "context.*exceeded"
)

# Track commands sent to sessions (for verification)
declare -ga MOCK_COMMANDS_SENT=()

# Mock driver functions
driver_interrupt_session() {
    MOCK_COMMANDS_SENT+=("interrupt:$1")
    return 0
}

driver_send_to_session() {
    MOCK_COMMANDS_SENT+=("send:$1:$2")
    return 0
}

driver_stop_session() {
    MOCK_COMMANDS_SENT+=("stop:$1")
    return 0
}

# Helper to create a mock pipe log
create_pipe_log() {
    local session_id="$1"
    local content="$2"
    local pipe_dir="${RU_STATE_DIR}/pipes"
    mkdir -p "$pipe_dir"
    echo "$content" > "$pipe_dir/${session_id}.pipe.log"
}

# Helper to create a mock session log with timestamps
create_session_log_with_velocity() {
    local session_id="$1"
    local chars_per_sec="$2"
    local log_file="${RU_STATE_DIR}/sessions/${session_id}/output.log"
    mkdir -p "$(dirname "$log_file")"
    
    # Create log with recent timestamps
    local now
    now=$(date +%s)
    for i in 1 2 3 4 5; do
        local ts=$((now - 5 + i))
        local chars=$((chars_per_sec * i))
        printf 'Line %d with some content...\n' "$i" >> "$log_file"
    done
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_monitoring_cycle() {
    log_test_start "e2e: full session monitoring cycle"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR/pipes"
    SESSION_STATE_HISTORY=()

    local session_id="monitor-cycle-$$"

    # Phase 1: Session generating
    create_pipe_log "$session_id" "Processing request..."
    create_session_log_with_velocity "$session_id" 20

    local state
    state=$(detect_session_state_raw "$session_id")
    # State should be generating or thinking (high velocity)
    if [[ "$state" == "generating" || "$state" == "thinking" ]]; then
        pass "Active session detected correctly"
    else
        fail "Expected generating/thinking state, got: $state"
    fi

    # Phase 2: Session completes
    create_pipe_log "$session_id" '{"type":"result","text":"Done"}'

    state=$(detect_session_state_raw "$session_id")
    assert_equals "complete" "$state" "Completed session detected"

    # Phase 3: Verify hysteresis confirms complete immediately
    SESSION_STATE_HISTORY=()
    local confirmed
    confirmed=$(apply_state_hysteresis "$session_id" "complete" "generating")
    assert_equals "complete" "$confirmed" "Complete state confirmed immediately"

    e2e_cleanup
    log_test_pass "e2e: full session monitoring cycle"
}

test_stall_recovery_soft() {
    log_test_start "e2e: stall recovery sends Ctrl+C"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR/pipes"
    SESSION_STALL_COUNTS=()
    MOCK_COMMANDS_SENT=()

    local session_id="stall-soft-$$"

    # Simulate stall - first occurrence
    handle_stalled_session "$session_id"

    # Verify interrupt was sent (soft recovery)
    local found_interrupt=false
    for cmd in "${MOCK_COMMANDS_SENT[@]}"; do
        if [[ "$cmd" == "interrupt:$session_id" ]]; then
            found_interrupt=true
            break
        fi
    done

    if $found_interrupt; then
        pass "Soft recovery sent interrupt (Ctrl+C)"
    else
        fail "Expected interrupt command for soft recovery"
    fi

    # Verify stall count incremented
    assert_equals "1" "${SESSION_STALL_COUNTS[$session_id]:-0}" "Stall count should be 1"

    e2e_cleanup
    log_test_pass "e2e: stall recovery sends Ctrl+C"
}

test_stall_recovery_escalate() {
    log_test_start "e2e: stall recovery escalates to /compact"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR/pipes"
    SESSION_STALL_COUNTS=()
    MOCK_COMMANDS_SENT=()

    local session_id="stall-escalate-$$"

    # Simulate multiple stalls to trigger escalation (need 3+ stalls)
    handle_stalled_session "$session_id"  # 1st - sends interrupt
    handle_stalled_session "$session_id"  # 2nd - sends interrupt
    handle_stalled_session "$session_id"  # 3rd - should send /compact

    # Verify /compact was sent on 3rd stall
    local found_compact=false
    for cmd in "${MOCK_COMMANDS_SENT[@]}"; do
        if [[ "$cmd" == "send:$session_id:/compact" ]]; then
            found_compact=true
            break
        fi
    done

    if $found_compact; then
        pass "Escalated recovery sent /compact command"
    else
        fail "Expected /compact command after multiple stalls"
    fi

    e2e_cleanup
    log_test_pass "e2e: stall recovery escalates to /compact"
}

test_rate_limit_detection() {
    log_test_start "e2e: rate limit error detection"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR/pipes"

    local session_id="rate-limit-$$"

    # Create log with rate limit error
    create_pipe_log "$session_id" 'Processing...
Error: HTTP 429 Too Many Requests
Rate limit exceeded. Retrying in 60s...'

    # Verify error detected
    if session_has_error "$session_id"; then
        pass "Rate limit error detected (429)"
    else
        fail "Expected rate limit error to be detected"
    fi

    # Verify state detection shows error
    local state
    state=$(detect_session_state_raw "$session_id")
    assert_equals "error" "$state" "Error state detected for rate limit"

    e2e_cleanup
    log_test_pass "e2e: rate limit error detection"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: session monitoring"

run_test test_full_monitoring_cycle
run_test test_stall_recovery_soft
run_test test_stall_recovery_escalate
run_test test_rate_limit_detection

print_results
exit "$(get_exit_code)"
