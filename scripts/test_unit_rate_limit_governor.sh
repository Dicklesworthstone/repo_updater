#!/usr/bin/env bash
#
# Unit tests: Rate-limit governor (bd-gptu)
#
# Tests:
# - get_target_parallelism
# - adjust_parallelism
# - can_start_new_session
# - governor_record_error
# - circuit breaker behavior
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Initialize GOVERNOR_STATE global (sourced functions expect it to exist)
declare -gA GOVERNOR_STATE=(
    [github_remaining]=5000
    [github_reset]=0
    [model_in_backoff]="false"
    [model_backoff_until]=0
    [effective_parallelism]=4
    [target_parallelism]=4
    [circuit_breaker_open]="false"
    [error_count_window]=0
    [window_start]=0
    [governor_pid]=0
)

source_ru_function "get_target_parallelism"
source_ru_function "adjust_parallelism"
source_ru_function "can_start_new_session"
source_ru_function "governor_record_error"
source_ru_function "governor_update"

# get_governor_status has a heredoc that doesn't source well - define inline
get_governor_status() {
    cat <<EOF
{
  "github_remaining": ${GOVERNOR_STATE[github_remaining]},
  "github_reset": ${GOVERNOR_STATE[github_reset]},
  "model_in_backoff": ${GOVERNOR_STATE[model_in_backoff]},
  "model_backoff_until": ${GOVERNOR_STATE[model_backoff_until]},
  "effective_parallelism": ${GOVERNOR_STATE[effective_parallelism]},
  "target_parallelism": ${GOVERNOR_STATE[target_parallelism]},
  "circuit_breaker_open": ${GOVERNOR_STATE[circuit_breaker_open]},
  "error_count": ${GOVERNOR_STATE[error_count_window]}
}
EOF
}

# Mock logging functions
log_verbose() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# Reset GOVERNOR_STATE for each test
reset_governor_state() {
    GOVERNOR_STATE=(
        [github_remaining]=5000
        [github_reset]=0
        [model_in_backoff]="false"
        [model_backoff_until]=0
        [effective_parallelism]=4
        [target_parallelism]=4
        [circuit_breaker_open]="false"
        [error_count_window]=0
        [window_start]=0
        [governor_pid]=0
    )
}

test_get_target_parallelism_default() {
    local test_name="get_target_parallelism: returns default 4"
    log_test_start "$test_name"

    unset REVIEW_PARALLEL
    local result
    result=$(get_target_parallelism)

    assert_equals "4" "$result" "default parallelism"

    log_test_pass "$test_name"
}

test_get_target_parallelism_override() {
    local test_name="get_target_parallelism: respects REVIEW_PARALLEL"
    log_test_start "$test_name"

    export REVIEW_PARALLEL=8
    local result
    result=$(get_target_parallelism)

    assert_equals "8" "$result" "overridden parallelism"
    unset REVIEW_PARALLEL

    log_test_pass "$test_name"
}

test_adjust_parallelism_normal() {
    local test_name="adjust_parallelism: normal conditions"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[github_remaining]=5000

    adjust_parallelism

    assert_equals "4" "${GOVERNOR_STATE[effective_parallelism]}" "normal effective parallelism"

    log_test_pass "$test_name"
}

test_adjust_parallelism_low_github() {
    local test_name="adjust_parallelism: reduces when GitHub low"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[github_remaining]=400

    adjust_parallelism

    assert_equals "1" "${GOVERNOR_STATE[effective_parallelism]}" "low GitHub => 1"

    log_test_pass "$test_name"
}

test_adjust_parallelism_medium_github() {
    local test_name="adjust_parallelism: halves when GitHub medium"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[github_remaining]=800

    adjust_parallelism

    assert_equals "2" "${GOVERNOR_STATE[effective_parallelism]}" "medium GitHub => halved"

    log_test_pass "$test_name"
}

test_adjust_parallelism_model_backoff() {
    local test_name="adjust_parallelism: reduces to 1 on model backoff"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[model_in_backoff]="true"

    adjust_parallelism

    assert_equals "1" "${GOVERNOR_STATE[effective_parallelism]}" "model backoff => 1"

    log_test_pass "$test_name"
}

test_can_start_session_allowed() {
    local test_name="can_start_new_session: allows when under capacity"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[effective_parallelism]=4

    can_start_new_session 2
    local rc=$?

    assert_equals "0" "$rc" "should allow (2 active, 4 capacity)"

    log_test_pass "$test_name"
}

test_can_start_session_at_capacity() {
    local test_name="can_start_new_session: blocks at capacity"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[effective_parallelism]=4

    can_start_new_session 4
    local rc=$?

    assert_equals "1" "$rc" "should block (at capacity)"

    log_test_pass "$test_name"
}

test_can_start_session_circuit_breaker() {
    local test_name="can_start_new_session: blocks when circuit breaker open"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[circuit_breaker_open]="true"

    can_start_new_session 0
    local rc=$?

    assert_equals "1" "$rc" "should block (circuit breaker open)"

    log_test_pass "$test_name"
}

test_can_start_session_model_backoff() {
    local test_name="can_start_new_session: blocks during model backoff"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[model_in_backoff]="true"

    can_start_new_session 0
    local rc=$?

    assert_equals "1" "$rc" "should block (model backoff)"

    log_test_pass "$test_name"
}

test_governor_record_error_increments() {
    local test_name="governor_record_error: increments error count"
    log_test_start "$test_name"

    reset_governor_state

    governor_record_error
    assert_equals "1" "${GOVERNOR_STATE[error_count_window]}" "first error"

    governor_record_error
    assert_equals "2" "${GOVERNOR_STATE[error_count_window]}" "second error"

    log_test_pass "$test_name"
}

test_circuit_breaker_triggers() {
    local test_name="circuit breaker: opens after 5 errors"
    log_test_start "$test_name"

    reset_governor_state
    local now
    now=$(date +%s)
    GOVERNOR_STATE[window_start]="$now"
    GOVERNOR_STATE[error_count_window]=5

    adjust_parallelism

    assert_equals "true" "${GOVERNOR_STATE[circuit_breaker_open]}" "circuit breaker should open"
    assert_equals "0" "${GOVERNOR_STATE[effective_parallelism]}" "parallelism should be 0"

    log_test_pass "$test_name"
}

test_get_governor_status_json() {
    local test_name="get_governor_status: returns valid JSON"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[github_remaining]=4000
    GOVERNOR_STATE[effective_parallelism]=3

    local status
    status=$(get_governor_status)

    # Check it's valid JSON with expected fields
    if command -v jq &>/dev/null; then
        local remaining effective
        remaining=$(echo "$status" | jq -r '.github_remaining' 2>/dev/null)
        effective=$(echo "$status" | jq -r '.effective_parallelism' 2>/dev/null)

        assert_equals "4000" "$remaining" "github_remaining in JSON"
        assert_equals "3" "$effective" "effective_parallelism in JSON"
    else
        assert_contains "$status" "github_remaining" "JSON contains github_remaining"
    fi

    log_test_pass "$test_name"
}

test_governor_update_syncs_state() {
    local test_name="governor_update: updates state synchronously"
    log_test_start "$test_name"

    reset_governor_state
    GOVERNOR_STATE[github_remaining]=800
    GOVERNOR_STATE[model_in_backoff]="false"

    # Mock update_github_rate_limit to not actually call API
    update_github_rate_limit() { :; }
    check_model_rate_limit() { :; }

    # governor_update should call adjust_parallelism
    governor_update

    # With github_remaining=800, effective should be halved (4/2=2)
    assert_equals "2" "${GOVERNOR_STATE[effective_parallelism]}" "governor_update adjusts parallelism"

    log_test_pass "$test_name"
}

run_test test_get_target_parallelism_default
run_test test_get_target_parallelism_override
run_test test_adjust_parallelism_normal
run_test test_adjust_parallelism_low_github
run_test test_adjust_parallelism_medium_github
run_test test_adjust_parallelism_model_backoff
run_test test_can_start_session_allowed
run_test test_can_start_session_at_capacity
run_test test_can_start_session_circuit_breaker
run_test test_can_start_session_model_backoff
run_test test_governor_record_error_increments
run_test test_circuit_breaker_triggers
run_test test_get_governor_status_json
run_test test_governor_update_syncs_state

print_results
exit $?
