#!/usr/bin/env bash
#
# E2E Test: ru doctor workflow
# Tests the system diagnostics command
#
# Test coverage:
#   - ru doctor checks git installation
#   - ru doctor checks gh CLI and auth status
#   - ru doctor checks config directory
#   - ru doctor checks configured repos
#   - ru doctor checks projects directory writability
#   - ru doctor checks gum (optional)
#   - ru doctor exit code 0 when all checks pass
#   - ru doctor exit code 3 when issues found
#   - Output goes to stderr (human-readable)
#
# Note: We can't easily mock missing binaries like git, so some checks
# verify the output format rather than actual failure states.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions are called dynamically
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Helpers
#==============================================================================

setup_initialized_env() {
    e2e_setup
    mkdir -p "$RU_PROJECTS_DIR"
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
}

#==============================================================================
# Tests: Basic doctor functionality
#==============================================================================

test_doctor_runs_successfully() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)
    local exit_code=$?

    # Doctor may exit 0 or 3 depending on gh auth status
    if [[ "$exit_code" -eq 0 || "$exit_code" -eq 3 ]]; then
        pass "Exits with valid code ($exit_code)"
    else
        fail "Unexpected exit code $exit_code (expected 0 or 3)"
    fi
    assert_contains "$stderr_output" "System Check" "Shows System Check header"

    e2e_cleanup
}

test_doctor_checks_git() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "git:" "Checks git"
    if printf '%s\n' "$stderr_output" | grep -q "\[OK\].*git:"; then
        pass "Git check passes"
    else
        fail "Git check passes"
    fi

    e2e_cleanup
}

test_doctor_checks_gh() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "gh:" "Checks gh CLI"

    e2e_cleanup
}

test_doctor_checks_config() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "Config:" "Checks config directory"
    if printf '%s\n' "$stderr_output" | grep -q "\[OK\].*Config:"; then
        pass "Config check passes when initialized"
    else
        fail "Config check passes when initialized"
    fi

    e2e_cleanup
}

test_doctor_checks_repos() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add owner/repo1 owner/repo2 >/dev/null 2>&1

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "Repos:" "Checks repos"
    assert_contains "$stderr_output" "2 configured" "Shows correct repo count"

    e2e_cleanup
}

test_doctor_checks_projects_dir() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "Projects:" "Checks projects directory"

    e2e_cleanup
}

test_doctor_checks_gum() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "gum:" "Checks gum"

    e2e_cleanup
}

#==============================================================================
# Tests: Config states
#==============================================================================

test_doctor_uninitialized_config() {
    e2e_setup
    mkdir -p "$RU_PROJECTS_DIR"
    # Remove pre-created config to simulate uninitialized state
    rm -rf "$XDG_CONFIG_HOME/ru"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "not initialized" "Detects uninitialized config"
    assert_contains "$stderr_output" "ru init" "Suggests ru init"

    e2e_cleanup
}

test_doctor_no_repos_configured() {
    setup_initialized_env

    # Clear repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "# Empty" > "$repos_file"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "none configured" "Detects no repos configured"

    e2e_cleanup
}

#==============================================================================
# Tests: Projects directory states
#==============================================================================

test_doctor_projects_dir_missing() {
    setup_initialized_env

    # Remove projects directory
    rmdir "$RU_PROJECTS_DIR" 2>/dev/null || true

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "will be created" "Notes projects dir will be created"

    e2e_cleanup
}

test_doctor_projects_dir_writable() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    assert_contains "$stderr_output" "writable" "Checks writability"

    e2e_cleanup
}

#==============================================================================
# Tests: Exit codes
#==============================================================================

test_doctor_exit_codes() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)
    local exit_code=$?

    # Exit code 0 means all checks passed, 3 means issues found
    if [[ "$exit_code" -eq 0 ]]; then
        assert_contains "$stderr_output" "All checks passed" "Shows success message when exit 0"
    elif [[ "$exit_code" -eq 3 ]]; then
        assert_contains "$stderr_output" "issue" "Shows issue count when exit 3"
    else
        fail "Unexpected exit code $exit_code"
    fi

    pass "Exit code matches output message"

    e2e_cleanup
}

#==============================================================================
# Tests: Output format
#==============================================================================

test_doctor_output_to_stderr() {
    setup_initialized_env

    local stdout_output stderr_output
    stdout_output=$("$E2E_RU_SCRIPT" doctor 2>/dev/null)
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1 >/dev/null)

    # Stdout should be empty or minimal
    if [[ -z "$stdout_output" ]]; then
        pass "Stdout is empty (all output to stderr)"
    else
        fail "Stdout should be empty, got: $stdout_output"
    fi

    # Stderr should have content
    assert_not_empty "$stderr_output" "Stderr has diagnostic output"

    e2e_cleanup
}

test_doctor_uses_status_indicators() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" doctor 2>&1)

    if printf '%s\n' "$stderr_output" | grep -q "\[OK\]"; then
        pass "Uses [OK] indicator"
    else
        fail "Uses [OK] indicator"
    fi

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_doctor_runs_successfully
run_test test_doctor_checks_git
run_test test_doctor_checks_gh
run_test test_doctor_checks_config
run_test test_doctor_checks_repos
run_test test_doctor_checks_projects_dir
run_test test_doctor_checks_gum
run_test test_doctor_uninitialized_config
run_test test_doctor_no_repos_configured
run_test test_doctor_projects_dir_missing
run_test test_doctor_projects_dir_writable
run_test test_doctor_exit_codes
run_test test_doctor_output_to_stderr
run_test test_doctor_uses_status_indicators

print_results
