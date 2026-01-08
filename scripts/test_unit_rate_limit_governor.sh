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

    # Save original functions before mocking (they're global in bash!)
    local _orig_update_github_rate_limit _orig_check_model_rate_limit
    _orig_update_github_rate_limit=$(declare -f update_github_rate_limit)
    _orig_check_model_rate_limit=$(declare -f check_model_rate_limit)

    # Mock update_github_rate_limit to not actually call API
    update_github_rate_limit() { :; }
    check_model_rate_limit() { :; }

    # governor_update should call adjust_parallelism
    governor_update

    # With github_remaining=800, effective should be halved (4/2=2)
    assert_equals "2" "${GOVERNOR_STATE[effective_parallelism]}" "governor_update adjusts parallelism"

    # Restore original functions
    eval "$_orig_update_github_rate_limit"
    eval "$_orig_check_model_rate_limit"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: update_github_rate_limit (bd-0l0g)
#==============================================================================

# Source the actual function for testing
source_ru_function "update_github_rate_limit"

# Mock retry_with_backoff to return immediately
# Call format: retry_with_backoff --capture=stdout 3 1 -- gh api rate_limit
# Args: $1=--capture=stdout $2=retries $3=delay $4=-- $5+=command
retry_with_backoff() {
    shift  # --capture=stdout (one arg, not two)
    shift  # retries (3)
    shift  # delay (1)
    shift  # --
    "$@"   # command: gh api rate_limit
}

test_update_github_rate_limit_parses_response() {
    local test_name="update_github_rate_limit: parses API response"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    # Create mock gh in mock_bin
    local mock_bin="$test_env/mock_bin"
    mkdir -p "$mock_bin"
    local old_path="$PATH"
    export PATH="$mock_bin:$PATH"

    cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
    cat <<'JSON'
{
  "resources": {
    "core": {
      "limit": 5000,
      "remaining": 3500,
      "reset": 1704067200
    }
  }
}
JSON
    exit 0
fi
exit 1
MOCK_GH
    chmod +x "$mock_bin/gh"

    update_github_rate_limit

    PATH="$old_path"

    assert_equals "3500" "${GOVERNOR_STATE[github_remaining]}" "remaining parsed"
    assert_equals "1704067200" "${GOVERNOR_STATE[github_reset]}" "reset parsed"

    log_test_pass "$test_name"
}

test_update_github_rate_limit_handles_low_remaining() {
    local test_name="update_github_rate_limit: detects low remaining"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    local mock_bin="$test_env/mock_bin"
    mkdir -p "$mock_bin"
    local old_path="$PATH"
    export PATH="$mock_bin:$PATH"

    cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
    cat <<'JSON'
{
  "resources": {
    "core": {
      "limit": 5000,
      "remaining": 200,
      "reset": 1704067200
    }
  }
}
JSON
    exit 0
fi
exit 1
MOCK_GH
    chmod +x "$mock_bin/gh"

    update_github_rate_limit

    PATH="$old_path"

    assert_equals "200" "${GOVERNOR_STATE[github_remaining]}" "low remaining detected"

    log_test_pass "$test_name"
}

test_update_github_rate_limit_handles_no_gh() {
    local test_name="update_github_rate_limit: handles missing gh"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    # Create empty bin dir BEFORE changing PATH (so mkdir command works)
    mkdir -p "$test_env/empty_bin"

    # Set PATH to only include empty_bin so gh isn't found.
    # (command -v is a bash builtin, doesn't need anything in PATH)
    local old_path="$PATH"
    export PATH="$test_env/empty_bin"

    # Should not error, just return
    update_github_rate_limit
    local rc=$?

    PATH="$old_path"

    assert_equals "0" "$rc" "returns 0 when gh missing"
    # State should be unchanged (default 5000)
    assert_equals "5000" "${GOVERNOR_STATE[github_remaining]}" "state unchanged"

    log_test_pass "$test_name"
}

test_update_github_rate_limit_handles_api_failure() {
    local test_name="update_github_rate_limit: handles API failure"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    local mock_bin="$test_env/mock_bin"
    mkdir -p "$mock_bin"
    local old_path="$PATH"
    export PATH="$mock_bin:$PATH"

    cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
echo "API error" >&2
exit 1
MOCK_GH
    chmod +x "$mock_bin/gh"

    update_github_rate_limit
    local rc=$?

    PATH="$old_path"

    assert_equals "0" "$rc" "returns 0 on API failure"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: check_model_rate_limit (bd-0l0g)
#==============================================================================

source_ru_function "check_model_rate_limit"

test_check_model_rate_limit_detects_429_in_logs() {
    local test_name="check_model_rate_limit: detects 429 in recent logs"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"

    # Create a log file with 429 pattern
    echo "Error: 429 Too Many Requests" > "$log_dir/session.log"
    touch "$log_dir/session.log"  # Ensure recent mtime

    check_model_rate_limit

    assert_equals "true" "${GOVERNOR_STATE[model_in_backoff]}" "backoff enabled"
    assert_not_equals "0" "${GOVERNOR_STATE[model_backoff_until]}" "backoff_until set"

    log_test_pass "$test_name"
}

test_check_model_rate_limit_detects_rate_limit_pattern() {
    local test_name="check_model_rate_limit: detects 'rate limit' pattern"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"

    echo "API rate limit exceeded" > "$log_dir/session.log"
    touch "$log_dir/session.log"

    check_model_rate_limit

    assert_equals "true" "${GOVERNOR_STATE[model_in_backoff]}" "backoff enabled"

    log_test_pass "$test_name"
}

test_check_model_rate_limit_detects_overloaded() {
    local test_name="check_model_rate_limit: detects 'overloaded' pattern"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"

    echo "Service overloaded, please retry" > "$log_dir/session.log"
    touch "$log_dir/session.log"

    check_model_rate_limit

    assert_equals "true" "${GOVERNOR_STATE[model_in_backoff]}" "backoff enabled"

    log_test_pass "$test_name"
}

test_check_model_rate_limit_ignores_old_logs() {
    local test_name="check_model_rate_limit: ignores logs older than 5 minutes"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"

    echo "Error: 429 Too Many Requests" > "$log_dir/old_session.log"
    # Make it 10 minutes old
    touch -d "10 minutes ago" "$log_dir/old_session.log" 2>/dev/null || \
    touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)" "$log_dir/old_session.log" 2>/dev/null || true

    check_model_rate_limit

    # Should not trigger backoff from old logs
    assert_equals "false" "${GOVERNOR_STATE[model_in_backoff]}" "backoff not enabled"

    log_test_pass "$test_name"
}

test_check_model_rate_limit_clears_expired_backoff() {
    local test_name="check_model_rate_limit: clears expired backoff"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/state/ru"
    local log_dir
    log_dir="$RU_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$log_dir"
    # Create a benign log file (no 429 errors) so the function has something to scan
    echo "Normal operation log" > "$log_dir/clean.log"

    # Set backoff that has expired
    local now
    now=$(date +%s)
    GOVERNOR_STATE[model_in_backoff]="true"
    GOVERNOR_STATE[model_backoff_until]=$((now - 60))  # Expired 60 seconds ago

    # No recent 429s in logs (empty log dir)

    check_model_rate_limit

    assert_equals "false" "${GOVERNOR_STATE[model_in_backoff]}" "backoff cleared"

    log_test_pass "$test_name"
}

test_check_model_rate_limit_no_log_dir() {
    local test_name="check_model_rate_limit: handles missing log directory"
    log_test_start "$test_name"

    reset_governor_state
    local test_env
    test_env=$(create_test_env)

    export RU_STATE_DIR="$test_env/nonexistent"

    check_model_rate_limit
    local rc=$?

    assert_equals "0" "$rc" "returns 0 when log dir missing"
    assert_equals "false" "${GOVERNOR_STATE[model_in_backoff]}" "backoff not enabled"

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

# update_github_rate_limit tests (bd-0l0g)
run_test test_update_github_rate_limit_parses_response
run_test test_update_github_rate_limit_handles_low_remaining
run_test test_update_github_rate_limit_handles_no_gh
run_test test_update_github_rate_limit_handles_api_failure

# check_model_rate_limit tests (bd-0l0g)
run_test test_check_model_rate_limit_detects_429_in_logs
run_test test_check_model_rate_limit_detects_rate_limit_pattern
run_test test_check_model_rate_limit_detects_overloaded
run_test test_check_model_rate_limit_ignores_old_logs
run_test test_check_model_rate_limit_clears_expired_backoff
run_test test_check_model_rate_limit_no_log_dir

print_results
exit "$(get_exit_code)"
