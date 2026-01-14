#!/usr/bin/env bash
#
# Unit tests: Session Monitoring & Completion Detection (bd-eycs)
#
# Tests session state detection, hysteresis, wait reason detection,
# error patterns, plan validation, and stall recovery.
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
source_ru_function "get_worktree_for_session"
source_ru_function "get_session_log_path"
source_ru_function "calculate_output_velocity"
source_ru_function "get_last_output_time"
source_ru_function "has_thinking_indicators"
source_ru_function "is_at_prompt"
source_ru_function "session_has_result"
source_ru_function "session_has_error"
source_ru_function "detect_session_state_raw"
source_ru_function "apply_state_hysteresis"
source_ru_function "handle_stalled_session"

# Inline the SESSION_ERROR_PATTERNS array since it can't be sourced via function extraction
SESSION_ERROR_PATTERNS=(
    "rate.limit"
    "429"
    "quota.exceeded"
    "panic:"
    "SIGSEGV"
    "killed"
    "unauthorized"
    "invalid.*key"
    "connection refused"
    "timed out"
    "context.*exceeded"
    "token.*limit"
)

# Initialize associative arrays for hysteresis tracking
declare -gA SESSION_STATE_HISTORY=()
declare -gA SESSION_STALL_COUNTS=()

# Mock log functions
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

# Mock driver functions for testing
driver_get_session_state() {
    local session_id="$1"
    echo '{"session_id":"'"$session_id"'","state":"generating"}'
}

driver_interrupt_session() { return 0; }
driver_send_to_session() { return 0; }
driver_stop_session() { return 0; }

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_session_test() {
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    mkdir -p "$RU_STATE_DIR/pipes"
    SESSION_STATE_HISTORY=()
    SESSION_STALL_COUNTS=()
}

create_pipe_log() {
    local session_id="$1"
    local content="$2"
    local pipe_log="$RU_STATE_DIR/pipes/${session_id}.pipe.log"
    echo "$content" > "$pipe_log"
}

#==============================================================================
# Tests: State Detection
#==============================================================================

test_state_detection_generating() {
    local test_name="detect_session_state_raw: high velocity -> generating"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-gen-$$"

    # Create a large pipe log to simulate high velocity
    local large_content
    large_content=$(head -c 10000 /dev/zero | tr '\0' 'x')
    create_pipe_log "$session_id" "$large_content"

    # Touch file to make it recent
    touch "$RU_STATE_DIR/pipes/${session_id}.pipe.log"

    # Initialize prev_size to simulate velocity
    echo "0" > "$RU_STATE_DIR/pipes/${session_id}.prev_size"

    local state
    state=$(detect_session_state_raw "$session_id")

    # Could be generating or thinking depending on velocity calculation
    if [[ "$state" == "generating" || "$state" == "thinking" ]]; then
        pass "Active session detected as: $state"
    else
        fail "Expected generating/thinking but got: $state"
    fi

    log_test_pass "$test_name"
}

test_state_detection_waiting() {
    local test_name="detect_session_state_raw: at prompt + low velocity -> waiting"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-wait-$$"

    # Create pipe log with prompt pattern
    create_pipe_log "$session_id" "Some output\nclaude> "

    # Make it recent
    touch "$RU_STATE_DIR/pipes/${session_id}.pipe.log"

    # Set prev_size to current size (zero velocity)
    local size
    size=$(stat -c%s "$RU_STATE_DIR/pipes/${session_id}.pipe.log" 2>/dev/null || \
           stat -f%z "$RU_STATE_DIR/pipes/${session_id}.pipe.log")
    echo "$size" > "$RU_STATE_DIR/pipes/${session_id}.prev_size"

    # Override driver to return waiting state
    driver_get_session_state() {
        echo '{"state":"waiting"}'
    }

    local state
    state=$(detect_session_state_raw "$session_id")

    assert_equals "waiting" "$state" "Should detect waiting state"

    log_test_pass "$test_name"
}

test_state_detection_stalled() {
    local test_name="detect_session_state_raw: no output > 30s -> stalled"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-stall-$$"

    # Create pipe log
    create_pipe_log "$session_id" "Some old output"

    # Make the file old (more than 30 seconds ago)
    touch -d "1 minute ago" "$RU_STATE_DIR/pipes/${session_id}.pipe.log" 2>/dev/null || \
        touch -t "$(date -v-1M +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 minute ago' +%Y%m%d%H%M.%S)" \
        "$RU_STATE_DIR/pipes/${session_id}.pipe.log" 2>/dev/null || true

    # Restore default driver
    driver_get_session_state() {
        echo '{"state":"generating"}'
    }

    local state
    state=$(detect_session_state_raw "$session_id")

    assert_equals "stalled" "$state" "Should detect stalled state"

    log_test_pass "$test_name"
}

test_state_detection_complete() {
    local test_name="detect_session_state_raw: result event -> complete"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-complete-$$"

    # Create pipe log with result event
    create_pipe_log "$session_id" '{"type":"message"}
{"type":"result","success":true}'

    local state
    state=$(detect_session_state_raw "$session_id")

    assert_equals "complete" "$state" "Should detect complete state"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Hysteresis
#==============================================================================

test_hysteresis_prevents_flapping() {
    local test_name="apply_state_hysteresis: 3+ samples needed for waiting"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-hyst-$$"
    SESSION_STATE_HISTORY=()

    # Test with 0 samples in history + 1 new = 1 consecutive - should not trigger
    SESSION_STATE_HISTORY["$session_id"]=""
    local state1
    state1=$(apply_state_hysteresis "$session_id" "waiting" "generating")
    assert_equals "generating" "$state1" "1 sample should not trigger"

    # Test with 1 sample in history + 1 new = 2 consecutive - still not enough
    SESSION_STATE_HISTORY["$session_id"]="waiting"
    local state2
    state2=$(apply_state_hysteresis "$session_id" "waiting" "generating")
    assert_equals "generating" "$state2" "2 samples should not trigger"

    # Test with 2 samples in history + 1 new = 3 consecutive - should trigger
    SESSION_STATE_HISTORY["$session_id"]="waiting,waiting"
    local state3
    state3=$(apply_state_hysteresis "$session_id" "waiting" "generating")
    assert_equals "waiting" "$state3" "3 consecutive samples should trigger"

    log_test_pass "$test_name"
}

test_hysteresis_immediate_error() {
    local test_name="apply_state_hysteresis: error triggers immediately"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-err-$$"
    SESSION_STATE_HISTORY=()

    # Error should trigger on first sample
    local state
    state=$(apply_state_hysteresis "$session_id" "error" "generating")
    assert_equals "error" "$state" "Error should trigger immediately"

    log_test_pass "$test_name"
}

test_hysteresis_immediate_complete() {
    local test_name="apply_state_hysteresis: complete triggers immediately"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-cmp-$$"
    SESSION_STATE_HISTORY=()

    # Complete should trigger on first sample
    local state
    state=$(apply_state_hysteresis "$session_id" "complete" "generating")
    assert_equals "complete" "$state" "Complete should trigger immediately"

    log_test_pass "$test_name"
}

test_hysteresis_stalled_requires_five() {
    local test_name="apply_state_hysteresis: stalled requires 5 samples"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-st5-$$"
    SESSION_STATE_HISTORY=()
    local state

    # Test with 1-4 consecutive stalled samples - should not trigger
    SESSION_STATE_HISTORY["$session_id"]="stalled"
    state=$(apply_state_hysteresis "$session_id" "stalled" "generating")
    assert_equals "generating" "$state" "2 samples should not trigger stalled"

    SESSION_STATE_HISTORY["$session_id"]="stalled,stalled"
    state=$(apply_state_hysteresis "$session_id" "stalled" "generating")
    assert_equals "generating" "$state" "3 samples should not trigger stalled"

    SESSION_STATE_HISTORY["$session_id"]="stalled,stalled,stalled"
    state=$(apply_state_hysteresis "$session_id" "stalled" "generating")
    assert_equals "generating" "$state" "4 samples should not trigger stalled"

    # Test with 4 consecutive stalled samples + 1 new = 5, should trigger
    SESSION_STATE_HISTORY["$session_id"]="stalled,stalled,stalled,stalled"
    state=$(apply_state_hysteresis "$session_id" "stalled" "generating")
    assert_equals "stalled" "$state" "5 consecutive samples should trigger stalled"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Error Pattern Detection
#==============================================================================

test_error_pattern_rate_limit() {
    local test_name="session_has_error: detects rate limit (429)"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-429-$$"

    # Create pipe log with rate limit error
    create_pipe_log "$session_id" "Processing...
Error: 429 Too Many Requests
Backing off..."

    if session_has_error "$session_id"; then
        pass "Detected rate limit error"
    else
        fail "Should detect rate limit error"
    fi

    log_test_pass "$test_name"
}

test_error_pattern_context() {
    local test_name="session_has_error: detects context exceeded"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-ctx-$$"

    # Create pipe log with context exceeded error
    create_pipe_log "$session_id" "Running...
Error: context length exceeded
Token limit reached"

    if session_has_error "$session_id"; then
        pass "Detected context exceeded error"
    else
        fail "Should detect context exceeded error"
    fi

    log_test_pass "$test_name"
}

test_error_pattern_no_error() {
    local test_name="session_has_error: returns false for clean output"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-clean-$$"

    # Create pipe log with clean output
    create_pipe_log "$session_id" "Processing...
All good!
Done."

    if session_has_error "$session_id"; then
        fail "Should not detect error in clean output"
    else
        pass "Correctly returns false for clean output"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Completion Detection
#==============================================================================

test_result_event_detection() {
    local test_name="session_has_result: detects result event"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-res-$$"

    # Create pipe log with result event
    create_pipe_log "$session_id" '{"type":"init"}
{"type":"message","content":"test"}
{"type":"result","success":true}'

    if session_has_result "$session_id"; then
        pass "Detected result event"
    else
        fail "Should detect result event"
    fi

    log_test_pass "$test_name"
}

test_result_event_missing() {
    local test_name="session_has_result: returns false when no result"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-nores-$$"

    # Create pipe log without result event
    create_pipe_log "$session_id" '{"type":"init"}
{"type":"message","content":"test"}
{"type":"message","content":"more"}'

    if session_has_result "$session_id"; then
        fail "Should not detect result when none exists"
    else
        pass "Correctly returns false when no result"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Stall Recovery
#==============================================================================

test_stall_recovery_escalation() {
    local test_name="handle_stalled_session: escalates recovery attempts"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-stall-esc-$$"
    SESSION_STALL_COUNTS=()

    # First two calls - should increment and use soft restart
    handle_stalled_session "$session_id"
    assert_equals "1" "${SESSION_STALL_COUNTS[$session_id]}" "First stall count"

    handle_stalled_session "$session_id"
    assert_equals "2" "${SESSION_STALL_COUNTS[$session_id]}" "Second stall count"

    # Calls 3-4 should try /compact
    handle_stalled_session "$session_id"
    assert_equals "3" "${SESSION_STALL_COUNTS[$session_id]}" "Third stall count"

    handle_stalled_session "$session_id"
    assert_equals "4" "${SESSION_STALL_COUNTS[$session_id]}" "Fourth stall count"

    # Fifth call should reset counter (hard restart)
    handle_stalled_session "$session_id"
    assert_equals "0" "${SESSION_STALL_COUNTS[$session_id]}" "Counter should reset after hard restart"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Velocity Calculation
#==============================================================================

test_velocity_calculation() {
    local test_name="calculate_output_velocity: measures chars per second"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-vel-$$"

    # Create initial state (empty prev_size)
    create_pipe_log "$session_id" "initial content"

    # First call establishes baseline
    local vel1
    vel1=$(calculate_output_velocity "$session_id" 5)

    # Add more content
    echo "more content here" >> "$RU_STATE_DIR/pipes/${session_id}.pipe.log"

    # Second call should measure velocity
    local vel2
    vel2=$(calculate_output_velocity "$session_id" 5)

    # Velocity should be >= 0
    if [[ "$vel2" =~ ^[0-9]+$ ]]; then
        pass "Velocity calculation returned valid number: $vel2"
    else
        fail "Velocity should be a number, got: $vel2"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Thinking Indicators
#==============================================================================

test_thinking_indicators_present() {
    local test_name="has_thinking_indicators: detects spinner"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-think-$$"

    # Create pipe log with spinner
    create_pipe_log "$session_id" "Processing ⠋ thinking..."

    if has_thinking_indicators "$session_id"; then
        pass "Detected thinking indicators"
    else
        fail "Should detect thinking indicators"
    fi

    log_test_pass "$test_name"
}

test_thinking_indicators_absent() {
    local test_name="has_thinking_indicators: returns false when absent"
    log_test_start "$test_name"
    setup_session_test

    local session_id="test-nothink-$$"

    # Create pipe log without thinking indicators
    create_pipe_log "$session_id" "Just regular output here"

    if has_thinking_indicators "$session_id"; then
        fail "Should not detect thinking indicators"
    else
        pass "Correctly returns false when no indicators"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "Running session monitor unit tests..."
echo ""

# State detection tests
run_test test_state_detection_generating
run_test test_state_detection_waiting
run_test test_state_detection_stalled
run_test test_state_detection_complete

# Hysteresis tests
run_test test_hysteresis_prevents_flapping
run_test test_hysteresis_immediate_error
run_test test_hysteresis_immediate_complete
run_test test_hysteresis_stalled_requires_five

# Error pattern tests
run_test test_error_pattern_rate_limit
run_test test_error_pattern_context
run_test test_error_pattern_no_error

# Completion detection tests
run_test test_result_event_detection
run_test test_result_event_missing

# Stall recovery test
run_test test_stall_recovery_escalation

# Velocity calculation test
run_test test_velocity_calculation

# Thinking indicators tests
run_test test_thinking_indicators_present
run_test test_thinking_indicators_absent

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
