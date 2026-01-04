#!/usr/bin/env bash
#
# Self-test for test_framework.sh
# Verifies all assertion functions work correctly
#
# shellcheck disable=SC1091  # Dynamic source not analyzable
# shellcheck disable=SC2317  # Functions called indirectly via run_test
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the framework
# shellcheck source=test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Tests for Assertion Functions
#==============================================================================

test_assert_equals() {
    assert_equals "hello" "hello" "Equal strings should match"
    assert_equals "123" "123" "Equal numbers should match"
    assert_equals "" "" "Empty strings should match"
}

test_assert_not_equals() {
    assert_not_equals "hello" "world" "Different strings should not match"
    assert_not_equals "123" "456" "Different numbers should not match"
}

test_assert_contains() {
    assert_contains "hello world" "world" "Should find substring"
    assert_contains "hello world" "hello" "Should find prefix"
    assert_contains "hello world" "o w" "Should find middle"
}

test_assert_not_contains() {
    assert_not_contains "hello world" "xyz" "Should not find missing substring"
    assert_not_contains "hello" "Hello" "Case-sensitive check"
}

test_assert_exit_code() {
    assert_exit_code 0 true "True should exit 0"
    assert_exit_code 1 false "False should exit 1"
    assert_exit_code 0 test -d "$SCRIPT_DIR" "Test for existing dir should exit 0"
}

test_assert_success() {
    assert_success true "True command should succeed"
    assert_success test -d "$SCRIPT_DIR" "Test for existing dir should succeed"
}

test_assert_fails() {
    assert_fails false "False command should fail"
    assert_fails test -d "/nonexistent/path/xyz" "Test for missing dir should fail"
}

test_assert_file_exists() {
    assert_file_exists "$SCRIPT_DIR/test_framework.sh" "Framework file should exist"
}

test_assert_file_not_exists() {
    assert_file_not_exists "/nonexistent/file.txt" "Missing file should not exist"
}

test_assert_dir_exists() {
    assert_dir_exists "$SCRIPT_DIR" "Script directory should exist"
}

test_assert_dir_not_exists() {
    assert_dir_not_exists "/nonexistent/directory" "Missing directory should not exist"
}

test_assert_not_empty() {
    assert_not_empty "hello" "Non-empty string"
    assert_not_empty "  " "Whitespace is not empty"
}

test_assert_empty() {
    assert_empty "" "Empty string"
}

test_assert_true() {
    assert_true "[[ 5 -gt 3 ]]" "5 > 3 should be true"
    assert_true "[[ -d '$SCRIPT_DIR' ]]" "Script dir exists check"
}

test_assert_false() {
    assert_false "[[ 3 -gt 5 ]]" "3 > 5 should be false"
}

test_assert_matches() {
    assert_matches "hello123world" "^hello[0-9]+world$" "Should match pattern"
    assert_matches "test@example.com" "@" "Should contain @"
}

test_temp_dir_creation() {
    local temp_dir
    temp_dir=$(create_temp_dir)
    assert_dir_exists "$temp_dir" "Temp dir should be created"
    # Cleanup will happen automatically via trap
}

test_mock_repo_creation() {
    local repo_dir
    repo_dir=$(create_mock_repo "test-repo")
    assert_dir_exists "$repo_dir" "Repo dir should exist"
    assert_dir_exists "$repo_dir/.git" "Git directory should exist"
}

test_bare_repo_creation() {
    local bare_dir
    bare_dir=$(create_bare_repo "test-bare")
    assert_dir_exists "$bare_dir" "Bare repo should exist"
    assert_file_exists "$bare_dir/HEAD" "HEAD file should exist"
}

test_create_test_env() {
    # Note: We call create_test_env directly (not in subshell) to preserve env vars
    # Then we use get_test_env_root to get the path
    create_test_env >/dev/null
    local env_root
    env_root=$(get_test_env_root)
    assert_dir_exists "$env_root" "Env root should exist"
    assert_dir_exists "$env_root/config/ru/repos.d" "XDG config should exist"
    assert_dir_exists "$env_root/state/ru/logs" "XDG state should exist"
    assert_dir_exists "$env_root/cache/ru" "XDG cache should exist"
    assert_dir_exists "$env_root/projects" "Projects dir should exist"
    assert_not_empty "${RU_PROJECTS_DIR:-}" "RU_PROJECTS_DIR should be set"
    assert_not_empty "${GIT_AUTHOR_NAME:-}" "Git author should be set"
}

test_structured_logging() {
    # Test timestamp format
    local ts
    ts=$(_tf_timestamp)
    assert_matches "$ts" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" "Timestamp should be ISO format"

    # Test log level setting
    set_log_level "debug"
    assert_equals "$TF_LOG_DEBUG" "$TF_LOG_LEVEL" "Log level should be DEBUG"
    set_log_level "warn"
    assert_equals "$TF_LOG_WARN" "$TF_LOG_LEVEL" "Log level should be WARN"
    set_log_level "info"  # Reset to default

    # Test log file initialization
    local temp_log
    temp_log=$(create_temp_dir)/test.log
    init_log_file "$temp_log"
    assert_file_exists "$temp_log" "Log file should be created"
    assert_file_contains "$temp_log" "Test log started" "Log file should have header"

    # Test log functions produce output (just verify no errors)
    log_debug "Debug message" 2>/dev/null
    log_info "Info message" 2>/dev/null
    log_warn "Warn message" 2>/dev/null
    log_error "Error message" 2>/dev/null
    _tf_pass "Logging functions work without errors"
}

test_log_test_lifecycle() {
    # Test the log_test_* functions
    log_test_start "example_test" 2>/dev/null
    assert_not_empty "$TF_TEST_START_TIME" "Test start time should be set"

    log_test_pass "example_test" 2>/dev/null
    assert_empty "$TF_TEST_START_TIME" "Test start time should be cleared after pass"

    log_test_start "failing_test" 2>/dev/null
    log_test_fail "failing_test" "Expected failure" 2>/dev/null
    assert_empty "$TF_TEST_START_TIME" "Test start time should be cleared after fail"

    log_test_skip "skipped_test" "Not applicable" 2>/dev/null
    _tf_pass "Test lifecycle logging works"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Test Framework Self-Test"
echo "============================================"

run_test test_assert_equals
run_test test_assert_not_equals
run_test test_assert_contains
run_test test_assert_not_contains
run_test test_assert_exit_code
run_test test_assert_success
run_test test_assert_fails
run_test test_assert_file_exists
run_test test_assert_file_not_exists
run_test test_assert_dir_exists
run_test test_assert_dir_not_exists
run_test test_assert_not_empty
run_test test_assert_empty
run_test test_assert_true
run_test test_assert_false
run_test test_assert_matches
run_test test_temp_dir_creation
run_test test_mock_repo_creation
run_test test_bare_repo_creation
run_test test_create_test_env
run_test test_structured_logging
run_test test_log_test_lifecycle

print_results
exit "$(get_exit_code)"
