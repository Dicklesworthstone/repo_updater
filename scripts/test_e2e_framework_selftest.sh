#!/usr/bin/env bash
#
# Self-test for test_e2e_framework.sh
# Verifies that the E2E framework functions work correctly
#
# shellcheck disable=SC2034  # Variables used by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (which sources test_framework.sh)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Tests: E2E Environment Setup
#==============================================================================

test_e2e_setup_creates_directories() {
    log_test_start "e2e_setup creates required directories"

    e2e_setup

    assert_dir_exists "$E2E_TEMP_DIR/config/ru/repos.d" "Config repos.d dir exists"
    assert_dir_exists "$E2E_TEMP_DIR/state/ru/logs" "State logs dir exists"
    assert_dir_exists "$E2E_TEMP_DIR/cache/ru" "Cache dir exists"
    assert_dir_exists "$E2E_TEMP_DIR/home" "Home dir exists"
    assert_dir_exists "$E2E_TEMP_DIR/projects" "Projects dir exists"
    assert_dir_exists "$E2E_MOCK_BIN" "Mock bin dir exists"

    e2e_cleanup
    log_test_pass "e2e_setup creates required directories"
}

test_e2e_setup_sets_environment() {
    log_test_start "e2e_setup sets environment variables"

    e2e_setup

    assert_not_empty "$XDG_CONFIG_HOME" "XDG_CONFIG_HOME is set"
    assert_not_empty "$XDG_STATE_HOME" "XDG_STATE_HOME is set"
    assert_not_empty "$RU_PROJECTS_DIR" "RU_PROJECTS_DIR is set"
    assert_contains "$PATH" "$E2E_MOCK_BIN" "PATH contains mock_bin"

    e2e_cleanup
    log_test_pass "e2e_setup sets environment variables"
}

test_e2e_cleanup_restores_path() {
    log_test_start "e2e_cleanup restores PATH"

    local original_path="$PATH"
    e2e_setup
    e2e_cleanup

    assert_equals "$original_path" "$PATH" "PATH is restored"

    log_test_pass "e2e_cleanup restores PATH"
}

#==============================================================================
# Tests: Mock gh
#==============================================================================

test_mock_gh_auth_success() {
    log_test_start "mock gh returns success for auth"

    e2e_setup
    e2e_create_mock_gh 0 "{}"

    local exit_code=0
    gh auth status >/dev/null 2>&1 || exit_code=$?

    assert_equals "0" "$exit_code" "gh auth status returns 0"

    e2e_cleanup
    log_test_pass "mock gh returns success for auth"
}

test_mock_gh_auth_failure() {
    log_test_start "mock gh returns failure for auth"

    e2e_setup
    e2e_create_mock_gh 1 "{}"

    local exit_code=0
    gh auth status >/dev/null 2>&1 || exit_code=$?

    assert_equals "1" "$exit_code" "gh auth status returns 1"

    e2e_cleanup
    log_test_pass "mock gh returns failure for auth"
}

test_mock_gh_graphql_response() {
    log_test_start "mock gh returns graphql response"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{"test":"value"}}'

    local response
    response=$(gh api graphql -f query='{}' 2>/dev/null)

    assert_contains "$response" '"test":"value"' "GraphQL response contains data"

    e2e_cleanup
    log_test_pass "mock gh returns graphql response"
}

#==============================================================================
# Tests: GraphQL Response Generators
#==============================================================================

test_graphql_response_with_items() {
    log_test_start "graphql response with items"

    local response
    response=$(e2e_graphql_response_with_items)

    # Check it's valid JSON
    if echo "$response" | jq empty 2>/dev/null; then
        pass "Response is valid JSON"
    else
        fail "Response is valid JSON"
    fi

    # Check structure
    local repo_name
    repo_name=$(echo "$response" | jq -r '.data.repo0.nameWithOwner' 2>/dev/null)
    assert_equals "owner/repo0" "$repo_name" "Contains repo name"

    local issue_count
    issue_count=$(echo "$response" | jq -r '.data.repo0.issues.nodes | length' 2>/dev/null)
    assert_equals "1" "$issue_count" "Contains 1 issue"

    log_test_pass "graphql response with items"
}

test_graphql_response_empty() {
    log_test_start "graphql response empty"

    local response
    response=$(e2e_graphql_response_empty)

    local issue_count
    issue_count=$(echo "$response" | jq -r '.data.repo0.issues.nodes | length' 2>/dev/null)
    assert_equals "0" "$issue_count" "Contains 0 issues"

    log_test_pass "graphql response empty"
}

test_graphql_error() {
    log_test_start "graphql error response"

    local response
    response=$(e2e_graphql_error "Test error message")

    local error_msg
    error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null)
    assert_equals "Test error message" "$error_msg" "Contains error message"

    log_test_pass "graphql error response"
}

#==============================================================================
# Tests: Legacy Compatibility
#==============================================================================

test_legacy_setup_test_env() {
    log_test_start "legacy setup_test_env works"

    setup_test_env

    assert_not_empty "$TEMP_DIR" "TEMP_DIR is set (legacy)"
    assert_dir_exists "$TEMP_DIR" "TEMP_DIR exists"

    cleanup_test_env
    log_test_pass "legacy setup_test_env works"
}

test_legacy_create_mock_gh() {
    log_test_start "legacy create_mock_gh works"

    setup_test_env
    create_mock_gh 0 '{"legacy":"test"}'

    local exit_code=0
    local response
    response=$(gh api graphql -f query='{}' 2>/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "Mock gh works"
    assert_contains "$response" "legacy" "Response contains data"

    cleanup_test_env
    log_test_pass "legacy create_mock_gh works"
}

#==============================================================================
# Tests: Logging
#==============================================================================

test_e2e_logging_functions() {
    log_test_start "E2E logging functions exist"

    # Just verify these functions exist and don't error
    e2e_setup
    e2e_log_operation "test_op" "test description" "execute"
    e2e_log_result "test_op" "pass" 100 "details"
    e2e_log_command "test cmd" 0
    e2e_cleanup

    pass "E2E logging functions work"
    log_test_pass "E2E logging functions exist"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Framework Self-Test"

run_test test_e2e_setup_creates_directories
run_test test_e2e_setup_sets_environment
run_test test_e2e_cleanup_restores_path
run_test test_mock_gh_auth_success
run_test test_mock_gh_auth_failure
run_test test_mock_gh_graphql_response
run_test test_graphql_response_with_items
run_test test_graphql_response_empty
run_test test_graphql_error
run_test test_legacy_setup_test_env
run_test test_legacy_create_mock_gh
run_test test_e2e_logging_functions

print_results
exit "$(get_exit_code)"
