#!/usr/bin/env bash
#
# E2E Test: Rate-limit governor
#
# Validates governor lifecycle and high-level behavior:
#   1. Background loop exits when lock file removed
#   2. Model backoff triggers on 429 and clears after expiry
#   3. Circuit breaker opens on error burst and closes after window
#
# shellcheck disable=SC2034  # Variables used by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (test isolation + assertions)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Minimal stubs + helpers
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

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

source_ru_function "update_github_rate_limit"
source_ru_function "check_model_rate_limit"
source_ru_function "adjust_parallelism"
source_ru_function "governor_record_error"
source_ru_function "governor_update"
source_ru_function "start_rate_limit_governor"

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_governor_lifecycle() {
    log_test_start "governor: background loop stops on lock removal"
    e2e_setup
    reset_governor_state

    # Mock gh api rate_limit so update_github_rate_limit is safe if called
    e2e_create_mock_gh_custom '
if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
  cat <<JSON
{"resources":{"core":{"remaining":4000,"reset":1704067200}}}
JSON
  exit 0
fi
exit 0
'

    local lock_file="$E2E_TEMP_DIR/review.lock"
    : > "$lock_file"

    start_rate_limit_governor "$lock_file" 1 &
    local pid=$!

    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        pass "governor loop running"
    else
        fail "governor loop not running"
    fi

    rm -f "$lock_file"
    wait "$pid" 2>/dev/null || true

    if kill -0 "$pid" 2>/dev/null; then
        fail "governor loop did not stop"
    else
        pass "governor loop stopped after lock removal"
    fi

    e2e_cleanup
    log_test_pass "governor: background loop stops on lock removal"
}

test_model_rate_limit_recovery() {
    log_test_start "governor: model backoff recovery"
    e2e_setup
    reset_governor_state

    export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"

    echo "Error: 429 Too Many Requests" > "$log_dir/session.log"
    touch "$log_dir/session.log"

    check_model_rate_limit
    assert_equals "true" "${GOVERNOR_STATE[model_in_backoff]}" "backoff enabled"

    # Simulate time passing and clear log contents
    : > "$log_dir/session.log"
    GOVERNOR_STATE[model_backoff_until]="$(( $(date +%s) - 1 ))"
    check_model_rate_limit

    assert_equals "false" "${GOVERNOR_STATE[model_in_backoff]}" "backoff cleared after expiry"

    e2e_cleanup
    unset RU_STATE_DIR
    log_test_pass "governor: model backoff recovery"
}

test_circuit_breaker_protection() {
    log_test_start "governor: circuit breaker open/close"
    e2e_setup
    reset_governor_state

    local now
    now=$(date +%s)
    GOVERNOR_STATE[window_start]="$now"
    GOVERNOR_STATE[error_count_window]=0

    local i
    for ((i=0; i<5; i++)); do
        governor_record_error
    done
    adjust_parallelism

    assert_equals "true" "${GOVERNOR_STATE[circuit_breaker_open]}" "circuit breaker opened"
    assert_equals "0" "${GOVERNOR_STATE[effective_parallelism]}" "parallelism paused"

    GOVERNOR_STATE[window_start]="$((now - 400))"
    GOVERNOR_STATE[error_count_window]=0
    adjust_parallelism

    assert_equals "false" "${GOVERNOR_STATE[circuit_breaker_open]}" "circuit breaker closed"

    e2e_cleanup
    log_test_pass "governor: circuit breaker open/close"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

run_test test_governor_lifecycle
run_test test_model_rate_limit_recovery
run_test test_circuit_breaker_protection

print_results
exit "$(get_exit_code)"
