#!/usr/bin/env bash
#
# Unit tests: Gum wrapper functions
# Tests: check_gum, gum_spin, gum_confirm, print_banner
#
# These tests focus on:
#   - check_gum properly detects gum availability
#   - Fallback behavior when GUM_AVAILABLE="false"
#   - QUIET mode handling for print_banner and gum_spin
#
# Note: gum_confirm requires interactive input, so we test the function
# structure but not actual user interaction in automated tests.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Environment Setup
#==============================================================================

# Source required functions from ru
source_ru_function "check_gum"
source_ru_function "gum_spin"
source_ru_function "gum_confirm"
source_ru_function "print_banner"

# We need the ANSI color variables for print_banner fallback
BOLD=$'\033[1m'
RESET=$'\033[0m'
CYAN=$'\033[0;36m'

# Read VERSION for print_banner
VERSION=$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo "dev")

#==============================================================================
# Tests: check_gum
#==============================================================================

test_check_gum_sets_true_when_gum_installed() {
    local test_name="check_gum: Sets GUM_AVAILABLE=true when gum is installed"
    log_test_start "$test_name"

    # Reset GUM_AVAILABLE
    GUM_AVAILABLE="false"

    # Only test if gum is actually installed
    if command -v gum &>/dev/null; then
        check_gum
        assert_equals "true" "$GUM_AVAILABLE" "GUM_AVAILABLE should be true"
    else
        skip_test "gum not installed - cannot verify positive detection"
        return 0
    fi

    log_test_pass "$test_name"
}

test_check_gum_leaves_false_when_gum_missing() {
    local test_name="check_gum: Leaves GUM_AVAILABLE unchanged when gum not in PATH"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Reset GUM_AVAILABLE
    GUM_AVAILABLE="false"

    # Create a PATH without gum
    local fake_bin="$test_env/bin"
    mkdir -p "$fake_bin"

    # Run check_gum with empty PATH (no gum)
    PATH="$fake_bin" check_gum

    # Should remain false since gum isn't in our restricted PATH
    assert_equals "false" "$GUM_AVAILABLE" "GUM_AVAILABLE should remain false"

    log_test_pass "$test_name"
}

test_check_gum_uses_command_v() {
    local test_name="check_gum: Uses command -v for detection (not which)"
    log_test_start "$test_name"

    # Verify the function exists and uses command -v
    local func_def
    func_def=$(type check_gum 2>/dev/null)

    assert_contains "$func_def" "command -v gum" "Should use 'command -v gum'"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: gum_spin
#==============================================================================

test_gum_spin_executes_command_in_fallback() {
    local test_name="gum_spin: Executes command in fallback mode"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Force fallback mode
    GUM_AVAILABLE="false"
    QUIET="false"

    # Create a marker file via gum_spin
    local marker="$test_env/marker.txt"
    gum_spin "Creating marker" touch "$marker" 2>/dev/null

    assert_file_exists "$marker" "Command should have been executed"

    log_test_pass "$test_name"
}

test_gum_spin_returns_command_exit_code() {
    local test_name="gum_spin: Returns command exit code"
    log_test_start "$test_name"

    GUM_AVAILABLE="false"
    QUIET="true"

    # Test success
    local result
    if gum_spin "Testing true" true 2>/dev/null; then
        result=0
    else
        result=$?
    fi
    assert_equals "0" "$result" "Should return 0 for successful command"

    # Test failure
    if gum_spin "Testing false" false 2>/dev/null; then
        result=0
    else
        result=$?
    fi
    assert_equals "1" "$result" "Should return 1 for failed command"

    log_test_pass "$test_name"
}

test_gum_spin_outputs_message_in_fallback() {
    local test_name="gum_spin: Outputs message in fallback mode"
    log_test_start "$test_name"

    GUM_AVAILABLE="false"
    QUIET="false"

    local output
    output=$(gum_spin "Processing items" true 2>&1)

    assert_contains "$output" "Processing items" "Should display the title"

    log_test_pass "$test_name"
}

test_gum_spin_quiet_mode_suppresses_output() {
    local test_name="gum_spin: QUIET mode suppresses message output"
    log_test_start "$test_name"

    GUM_AVAILABLE="false"
    QUIET="true"

    local output
    output=$(gum_spin "Should not appear" true 2>&1)

    assert_empty "$output" "Should suppress output in QUIET mode"

    log_test_pass "$test_name"
}

test_gum_spin_quiet_still_executes_command() {
    local test_name="gum_spin: QUIET mode still executes command"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    GUM_AVAILABLE="false"
    QUIET="true"

    local marker="$test_env/quiet_marker.txt"
    gum_spin "Creating" touch "$marker" 2>/dev/null

    assert_file_exists "$marker" "Command should still execute in QUIET mode"

    log_test_pass "$test_name"
}

test_gum_spin_with_complex_command() {
    local test_name="gum_spin: Handles commands with arguments"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    GUM_AVAILABLE="false"
    QUIET="true"

    # Command with multiple arguments
    local output_file="$test_env/output.txt"
    gum_spin "Writing" bash -c "echo 'hello world' > '$output_file'" 2>/dev/null

    assert_file_exists "$output_file" "Output file should exist"
    assert_file_contains "$output_file" "hello world" "Should contain expected content"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: gum_confirm (limited - requires interaction)
#==============================================================================

test_gum_confirm_function_exists() {
    local test_name="gum_confirm: Function exists and has expected structure"
    log_test_start "$test_name"

    local func_def
    func_def=$(type gum_confirm 2>/dev/null)

    assert_contains "$func_def" "GUM_AVAILABLE" "Should check GUM_AVAILABLE"
    assert_contains "$func_def" "IFS= read -r yn" "Should have fallback with read"

    log_test_pass "$test_name"
}

test_gum_confirm_has_default_parameter() {
    local test_name="gum_confirm: Has default parameter handling"
    log_test_start "$test_name"

    local func_def
    func_def=$(type gum_confirm 2>/dev/null)

    assert_contains "$func_def" 'default="${2:-false}"' "Should have default parameter"

    log_test_pass "$test_name"
}

test_gum_confirm_fallback_shows_yn_prompt() {
    local test_name="gum_confirm: Fallback shows [y/N] or [Y/n] based on default"
    log_test_start "$test_name"

    local func_def
    func_def=$(type gum_confirm 2>/dev/null)

    assert_contains "$func_def" '[Y/n]' "Should show [Y/n] for default true"
    assert_contains "$func_def" '[y/N]' "Should show [y/N] for default false"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: print_banner
#==============================================================================

test_print_banner_quiet_mode_no_output() {
    local test_name="print_banner: QUIET mode produces no output"
    log_test_start "$test_name"

    QUIET="true"
    GUM_AVAILABLE="false"

    local output
    output=$(print_banner 2>&1)

    assert_empty "$output" "Should produce no output in QUIET mode"

    log_test_pass "$test_name"
}

test_print_banner_fallback_shows_version() {
    local test_name="print_banner: Fallback mode shows version"
    log_test_start "$test_name"

    QUIET="false"
    GUM_AVAILABLE="false"

    local output
    output=$(print_banner 2>&1)

    assert_contains "$output" "$VERSION" "Should include version number"
    assert_contains "$output" "ru" "Should include 'ru'"

    log_test_pass "$test_name"
}

test_print_banner_fallback_shows_styled_output() {
    local test_name="print_banner: Fallback mode shows styled output"
    log_test_start "$test_name"

    QUIET="false"
    GUM_AVAILABLE="false"

    local output
    output=$(print_banner 2>&1)

    # Should have separator lines
    assert_contains "$output" "━" "Should have border characters"

    log_test_pass "$test_name"
}

test_print_banner_fallback_outputs_to_stderr() {
    local test_name="print_banner: Output goes to stderr"
    log_test_start "$test_name"

    QUIET="false"
    GUM_AVAILABLE="false"

    local stdout_output stderr_output
    stdout_output=$(print_banner 2>/dev/null)
    stderr_output=$(print_banner 2>&1 >/dev/null)

    assert_empty "$stdout_output" "stdout should be empty"
    assert_not_empty "$stderr_output" "stderr should have content"

    log_test_pass "$test_name"
}

test_print_banner_with_gum_check() {
    local test_name="print_banner: Uses gum style when available"
    log_test_start "$test_name"

    local func_def
    func_def=$(type print_banner 2>/dev/null)

    assert_contains "$func_def" 'gum style' "Should use gum style when available"
    assert_contains "$func_def" '--border rounded' "Should use rounded border"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Integration
#==============================================================================

test_gum_functions_respect_quiet_mode() {
    local test_name="Integration: Both gum_spin and print_banner respect QUIET"
    log_test_start "$test_name"

    QUIET="true"
    GUM_AVAILABLE="false"

    local spin_output banner_output
    spin_output=$(gum_spin "Test" true 2>&1)
    banner_output=$(print_banner 2>&1)

    assert_empty "$spin_output" "gum_spin should be quiet"
    assert_empty "$banner_output" "print_banner should be quiet"

    log_test_pass "$test_name"
}

test_gum_available_false_uses_fallback() {
    local test_name="Integration: GUM_AVAILABLE=false triggers fallback for all"
    log_test_start "$test_name"

    GUM_AVAILABLE="false"
    QUIET="false"

    # Check that outputs use ANSI fallback (contain escape sequences or plain text)
    local spin_output banner_output
    spin_output=$(gum_spin "Test spin" true 2>&1)
    banner_output=$(print_banner 2>&1)

    # Fallback uses → character for gum_spin
    assert_contains "$spin_output" "Test spin" "gum_spin should show title"
    assert_contains "$banner_output" "ru" "print_banner should show ru"

    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

# check_gum tests
run_test test_check_gum_sets_true_when_gum_installed
run_test test_check_gum_leaves_false_when_gum_missing
run_test test_check_gum_uses_command_v

# gum_spin tests
run_test test_gum_spin_executes_command_in_fallback
run_test test_gum_spin_returns_command_exit_code
run_test test_gum_spin_outputs_message_in_fallback
run_test test_gum_spin_quiet_mode_suppresses_output
run_test test_gum_spin_quiet_still_executes_command
run_test test_gum_spin_with_complex_command

# gum_confirm tests (limited due to interaction requirement)
run_test test_gum_confirm_function_exists
run_test test_gum_confirm_has_default_parameter
run_test test_gum_confirm_fallback_shows_yn_prompt

# print_banner tests
run_test test_print_banner_quiet_mode_no_output
run_test test_print_banner_fallback_shows_version
run_test test_print_banner_fallback_shows_styled_output
run_test test_print_banner_fallback_outputs_to_stderr
run_test test_print_banner_with_gum_check

# Integration tests
run_test test_gum_functions_respect_quiet_mode
run_test test_gum_available_false_uses_fallback

print_results
exit "$(get_exit_code)"
