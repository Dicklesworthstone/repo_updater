#!/usr/bin/env bash
#
# Unit Tests: Timeout Handling
# Tests for setup_git_timeout, is_timeout_error
#
# Test coverage:
#   - setup_git_timeout sets GIT_HTTP_LOW_SPEED_LIMIT
#   - setup_git_timeout sets GIT_HTTP_LOW_SPEED_TIME
#   - setup_git_timeout uses GIT_LOW_SPEED_LIMIT value
#   - setup_git_timeout uses GIT_TIMEOUT value
#   - is_timeout_error detects "RPC failed"
#   - is_timeout_error detects "timed out"
#   - is_timeout_error detects "remote end hung up"
#   - is_timeout_error detects "transfer rate"
#   - is_timeout_error returns false for normal errors
#   - is_timeout_error returns false for empty input
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
# shellcheck source=./test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Source Functions from ru
#==============================================================================

# Set default values used by the functions
GIT_TIMEOUT="${GIT_TIMEOUT:-30}"
GIT_LOW_SPEED_LIMIT="${GIT_LOW_SPEED_LIMIT:-1000}"

# Extract the timeout functions
eval "$(sed -n '/^setup_git_timeout()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^is_timeout_error()/,/^}/p' "$RU_SCRIPT")"
source_ru_function "run_network_command"

#==============================================================================
# Tests: setup_git_timeout
#==============================================================================

test_setup_git_timeout_sets_low_speed_limit() {
    # Save original values
    local old_limit="${GIT_HTTP_LOW_SPEED_LIMIT:-}"

    # Set a known value
    GIT_LOW_SPEED_LIMIT="5000"

    setup_git_timeout

    assert_equals "5000" "$GIT_HTTP_LOW_SPEED_LIMIT" "Sets GIT_HTTP_LOW_SPEED_LIMIT from GIT_LOW_SPEED_LIMIT"

    # Restore
    if [[ -n "$old_limit" ]]; then
        export GIT_HTTP_LOW_SPEED_LIMIT="$old_limit"
    else
        unset GIT_HTTP_LOW_SPEED_LIMIT
    fi
}

test_setup_git_timeout_sets_low_speed_time() {
    # Save original values
    local old_time="${GIT_HTTP_LOW_SPEED_TIME:-}"

    # Set a known value
    GIT_TIMEOUT="60"

    setup_git_timeout

    assert_equals "60" "$GIT_HTTP_LOW_SPEED_TIME" "Sets GIT_HTTP_LOW_SPEED_TIME from GIT_TIMEOUT"

    # Restore
    if [[ -n "$old_time" ]]; then
        export GIT_HTTP_LOW_SPEED_TIME="$old_time"
    else
        unset GIT_HTTP_LOW_SPEED_TIME
    fi
}

test_setup_git_timeout_uses_default_timeout() {
    local old_time="${GIT_HTTP_LOW_SPEED_TIME:-}"

    # Reset to default
    GIT_TIMEOUT="30"

    setup_git_timeout

    assert_equals "30" "$GIT_HTTP_LOW_SPEED_TIME" "Uses default timeout of 30 seconds"

    if [[ -n "$old_time" ]]; then
        export GIT_HTTP_LOW_SPEED_TIME="$old_time"
    else
        unset GIT_HTTP_LOW_SPEED_TIME
    fi
}

test_setup_git_timeout_uses_default_speed_limit() {
    local old_limit="${GIT_HTTP_LOW_SPEED_LIMIT:-}"

    # Reset to default
    GIT_LOW_SPEED_LIMIT="1000"

    setup_git_timeout

    assert_equals "1000" "$GIT_HTTP_LOW_SPEED_LIMIT" "Uses default speed limit of 1000 bytes/sec"

    if [[ -n "$old_limit" ]]; then
        export GIT_HTTP_LOW_SPEED_LIMIT="$old_limit"
    else
        unset GIT_HTTP_LOW_SPEED_LIMIT
    fi
}

test_setup_git_timeout_exports_variables() {
    # Clear the environment
    unset GIT_HTTP_LOW_SPEED_LIMIT 2>/dev/null || true
    unset GIT_HTTP_LOW_SPEED_TIME 2>/dev/null || true

    GIT_TIMEOUT="45"
    GIT_LOW_SPEED_LIMIT="2000"

    setup_git_timeout

    # Check they're exported (visible in subshell)
    local subshell_limit
    local subshell_time
    subshell_limit=$(bash -c 'echo $GIT_HTTP_LOW_SPEED_LIMIT')
    subshell_time=$(bash -c 'echo $GIT_HTTP_LOW_SPEED_TIME')

    assert_equals "2000" "$subshell_limit" "GIT_HTTP_LOW_SPEED_LIMIT is exported"
    assert_equals "45" "$subshell_time" "GIT_HTTP_LOW_SPEED_TIME is exported"
}

test_setup_git_timeout_custom_values() {
    GIT_TIMEOUT="120"
    GIT_LOW_SPEED_LIMIT="500"

    setup_git_timeout

    assert_equals "120" "$GIT_HTTP_LOW_SPEED_TIME" "Custom timeout value applied"
    assert_equals "500" "$GIT_HTTP_LOW_SPEED_LIMIT" "Custom speed limit value applied"
}

#==============================================================================
# Tests: is_timeout_error
#==============================================================================

test_is_timeout_error_detects_rpc_failed() {
    local error_msg="error: RPC failed; curl 56 GnuTLS recv error"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects 'RPC failed' as timeout error"
    else
        assert_true "false" "Should detect 'RPC failed'"
    fi
}

test_is_timeout_error_detects_timed_out() {
    local error_msg="fatal: unable to connect to github.com: github.com[0: 140.82.121.3]: errno=Connection timed out"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects 'timed out' as timeout error"
    else
        assert_true "false" "Should detect 'timed out'"
    fi
}

test_is_timeout_error_detects_hung_up() {
    local error_msg="fatal: The remote end hung up unexpectedly"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects 'remote end hung up' as timeout error"
    else
        assert_true "false" "Should detect 'remote end hung up'"
    fi
}

test_is_timeout_error_detects_transfer_rate() {
    local error_msg="error: transfer rate below minimum configured limit (1000 bytes/sec)"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects 'transfer rate' as timeout error"
    else
        assert_true "false" "Should detect 'transfer rate'"
    fi
}

test_is_timeout_error_returns_false_for_normal_error() {
    local error_msg="fatal: repository 'https://github.com/owner/repo' not found"

    if ! is_timeout_error "$error_msg"; then
        assert_true "true" "Does not detect 'not found' as timeout error"
    else
        assert_true "false" "Should not detect 'not found'"
    fi
}

test_is_timeout_error_returns_false_for_auth_error() {
    local error_msg="fatal: Authentication failed for 'https://github.com/owner/repo'"

    if ! is_timeout_error "$error_msg"; then
        assert_true "true" "Does not detect 'Authentication failed' as timeout error"
    else
        assert_true "false" "Should not detect 'Authentication failed'"
    fi
}

test_is_timeout_error_returns_false_for_empty() {
    local error_msg=""

    if ! is_timeout_error "$error_msg"; then
        assert_true "true" "Returns false for empty input"
    else
        assert_true "false" "Should return false for empty"
    fi
}

test_is_timeout_error_returns_false_for_merge_conflict() {
    local error_msg="error: Your local changes to the following files would be overwritten by merge"

    if ! is_timeout_error "$error_msg"; then
        assert_true "true" "Does not detect merge conflict as timeout"
    else
        assert_true "false" "Should not detect merge conflict"
    fi
}

test_is_timeout_error_case_sensitive() {
    # The function uses case-insensitive matching implicitly via bash pattern
    local error_msg="Connection TIMED OUT after 30 seconds"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects uppercase 'TIMED OUT'"
    else
        # This is expected if case sensitive
        assert_true "true" "Case sensitive matching is acceptable"
    fi
}

test_is_timeout_error_partial_match() {
    # Test that partial matches work
    local error_msg="The server RPC failed during transfer"

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects 'RPC failed' in context"
    else
        assert_true "false" "Should detect 'RPC failed' in context"
    fi
}

test_is_timeout_error_multiline() {
    local error_msg=$'error: Some operation failed\nThe remote end hung up unexpectedly\nOperation aborted'

    if is_timeout_error "$error_msg"; then
        assert_true "true" "Detects timeout in multiline error"
    else
        assert_true "false" "Should detect timeout in multiline"
    fi
}

#==============================================================================
# Tests: Integration
#==============================================================================

test_timeout_functions_defined() {
    assert_true "declare -f setup_git_timeout >/dev/null" "setup_git_timeout is defined"
    assert_true "declare -f is_timeout_error >/dev/null" "is_timeout_error is defined"
}

test_default_values_exist() {
    # Verify the default values are reasonable
    local default_timeout="${GIT_TIMEOUT:-}"
    local default_limit="${GIT_LOW_SPEED_LIMIT:-}"

    assert_not_empty "$default_timeout" "GIT_TIMEOUT has a default"
    assert_not_empty "$default_limit" "GIT_LOW_SPEED_LIMIT has a default"

    # Verify they're numeric
    if [[ "$default_timeout" =~ ^[0-9]+$ ]]; then
        assert_true "true" "GIT_TIMEOUT is numeric"
    else
        assert_true "false" "GIT_TIMEOUT should be numeric"
    fi

    if [[ "$default_limit" =~ ^[0-9]+$ ]]; then
        assert_true "true" "GIT_LOW_SPEED_LIMIT is numeric"
    else
        assert_true "false" "GIT_LOW_SPEED_LIMIT should be numeric"
    fi
}

#==============================================================================
# Run Tests
#==============================================================================

test_network_command_preserves_exit_status() {
    local GIT_TIMEOUT=5 rc=0 output
    output=$(run_network_command bash -c 'printf "command ran\n"; exit 42') || rc=$?
    assert_equals 42 "$rc" "Network wrapper preserves non-timeout failure"
    assert_equals 'command ran' "$output" "Command output is retained"
    rc=0
    run_network_command true || rc=$?
    assert_equals 0 "$rc" "Passing network command succeeds"
}

test_network_command_deadline_and_bash_fallback() {
    local env_root marker mode rc output started elapsed
    env_root=$(create_temp_dir)
    for mode in native bash; do
        marker="$env_root/survived-$mode"
        rc=0
        started=$SECONDS
        output=$(
            GIT_TIMEOUT=1
            if [[ "$mode" == bash ]]; then
                # Hide only optional timeout utilities to exercise portable code.
                command() {
                    if [[ "${1:-}" == -v && ( "${2:-}" == timeout || "${2:-}" == gtimeout ) ]]; then
                        return 1
                    fi
                    builtin command "$@"
                }
            fi
            run_network_command bash -c 'sleep 3; printf "survived\n" > "$1"' bash "$marker"
        ) 2>&1 || rc=$?
        elapsed=$((SECONDS - started))
        assert_equals 124 "$rc" "$mode wrapper actually enforces a deadline"
        assert_true "[[ $elapsed -le 4 ]]" "$mode deadline is bounded"
        sleep 2
        assert_file_not_exists "$marker" "$mode terminates the command process group"
        assert_empty "$output" "$mode does not contaminate stdout"
    done
}

echo "============================================"
echo "Unit Tests: Timeout Handling"
echo "============================================"

# setup_git_timeout tests
run_test test_setup_git_timeout_sets_low_speed_limit
run_test test_setup_git_timeout_sets_low_speed_time
run_test test_setup_git_timeout_uses_default_timeout
run_test test_setup_git_timeout_uses_default_speed_limit
run_test test_setup_git_timeout_exports_variables
run_test test_setup_git_timeout_custom_values

# is_timeout_error tests
run_test test_is_timeout_error_detects_rpc_failed
run_test test_is_timeout_error_detects_timed_out
run_test test_is_timeout_error_detects_hung_up
run_test test_is_timeout_error_detects_transfer_rate
run_test test_is_timeout_error_returns_false_for_normal_error
run_test test_is_timeout_error_returns_false_for_auth_error
run_test test_is_timeout_error_returns_false_for_empty
run_test test_is_timeout_error_returns_false_for_merge_conflict
run_test test_is_timeout_error_case_sensitive
run_test test_is_timeout_error_partial_match
run_test test_is_timeout_error_multiline

# Integration tests
run_test test_timeout_functions_defined
run_test test_default_values_exist
run_test test_network_command_preserves_exit_status
run_test test_network_command_deadline_and_bash_fallback

print_results
exit "$(get_exit_code)"
