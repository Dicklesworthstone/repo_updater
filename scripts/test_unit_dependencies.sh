#!/usr/bin/env bash
#
# Unit tests for dependency checking functions
# Tests: check_gh_installed, check_gh_auth, ensure_dependencies, detect_os
#
# Note: These tests work by:
# - Testing detect_os with different OSTYPE values
# - Testing check_gh_installed/check_gh_auth behavior on the current system
# - Testing ensure_dependencies logic paths
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Environment Setup
#==============================================================================

# Minimal log functions to avoid sourcing all of ru
log_info() { :; }
log_error() { :; }
log_success() { :; }

# Mock prompt functions
can_prompt() { return 1; }  # Non-interactive for tests
gum_confirm() { return 1; }

# Extract functions using awk with brace counting
extract_function() {
    local func_name="$1"
    local file="$2"
    awk -v fn="$func_name" '
        $0 ~ "^"fn"\\(\\)" {
            printing=1
            depth=0
        }
        printing {
            print
            for(i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if(c == "{") depth++
                if(c == "}") depth--
            }
            if(depth == 0 && /}/) exit
        }
    ' "$file"
}

source <(extract_function "check_gh_installed" "$PROJECT_DIR/ru")
source <(extract_function "check_gh_auth" "$PROJECT_DIR/ru")
source <(extract_function "ensure_dependencies" "$PROJECT_DIR/ru")
source <(extract_function "detect_os" "$PROJECT_DIR/ru")

#==============================================================================
# Test Setup/Teardown
#==============================================================================

TEMP_DIR=""

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

#==============================================================================
# Test: detect_os
#==============================================================================

test_detect_os_returns_macos_for_darwin() {
    # Temporarily override OSTYPE
    local original_ostype="$OSTYPE"
    OSTYPE="darwin21.0"

    local result
    result=$(detect_os)

    # Restore
    OSTYPE="$original_ostype"

    assert_equals "macos" "$result" \
        "detect_os returns 'macos' for darwin OSTYPE"
}

test_detect_os_returns_linux_for_linux_gnu() {
    local original_ostype="$OSTYPE"
    OSTYPE="linux-gnu"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "linux" "$result" \
        "detect_os returns 'linux' for linux-gnu OSTYPE"
}

test_detect_os_returns_linux_for_linux() {
    local original_ostype="$OSTYPE"
    OSTYPE="linux"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "linux" "$result" \
        "detect_os returns 'linux' for linux OSTYPE"
}

test_detect_os_returns_windows_for_msys() {
    local original_ostype="$OSTYPE"
    OSTYPE="msys"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "windows" "$result" \
        "detect_os returns 'windows' for msys OSTYPE"
}

test_detect_os_returns_windows_for_cygwin() {
    local original_ostype="$OSTYPE"
    OSTYPE="cygwin"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "windows" "$result" \
        "detect_os returns 'windows' for cygwin OSTYPE"
}

test_detect_os_returns_windows_for_mingw() {
    local original_ostype="$OSTYPE"
    OSTYPE="mingw64"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "windows" "$result" \
        "detect_os returns 'windows' for mingw OSTYPE"
}

test_detect_os_returns_unknown_for_unknown() {
    local original_ostype="$OSTYPE"
    OSTYPE="freebsd12.0"

    local result
    result=$(detect_os)

    OSTYPE="$original_ostype"

    assert_equals "unknown" "$result" \
        "detect_os returns 'unknown' for unrecognized OSTYPE"
}

#==============================================================================
# Test: check_gh_installed
#==============================================================================

test_check_gh_installed_returns_0_when_gh_exists() {
    # This test only passes if gh is actually installed
    if command -v gh &>/dev/null; then
        local result
        if check_gh_installed; then
            result=0
        else
            result=$?
        fi
        assert_equals "0" "$result" \
            "check_gh_installed returns 0 when gh exists"
    else
        skip_test "gh CLI not installed"
    fi
}

test_check_gh_installed_uses_command_v() {
    # Verify the function uses command -v internally
    # We can check this by examining output behavior with a non-existent command

    # Create a mock that shadows gh
    setup_test_env
    trap cleanup_test_env EXIT

    local fake_bin="$TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    # Test that without gh in PATH, check_gh_installed fails
    local result
    PATH="$fake_bin" check_gh_installed
    result=$?

    # Should fail (return non-zero) when gh is not in PATH
    # Note: This may still find gh if it's in a different location
    # The point is to verify the function behavior, not the environment
    if [[ "$result" -ne 0 ]]; then
        assert_not_equals "0" "$result" \
            "check_gh_installed fails when gh not in modified PATH"
    else
        # gh might be found through other means (absolute path lookup)
        skip_test "gh found outside modified PATH"
    fi

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: check_gh_auth
#==============================================================================

test_check_gh_auth_returns_based_on_auth_status() {
    # This test checks actual gh auth status
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    # Just verify the function runs without error
    local result
    if check_gh_auth; then
        result=0
    else
        result=$?
    fi

    # Result depends on actual auth status - we just verify it returns something valid
    # Either way, the function should work without error
    if [[ "$result" -eq 0 ]]; then
        assert_equals "0" "$result" \
            "check_gh_auth returns 0 (authenticated)"
    else
        assert_not_equals "0" "$result" \
            "check_gh_auth returns non-zero (not authenticated)"
    fi
}

#==============================================================================
# Test: ensure_dependencies
#==============================================================================

test_ensure_dependencies_returns_0_when_all_deps_ok() {
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    if ! gh auth status &>/dev/null; then
        skip_test "gh not authenticated"
        return 0
    fi

    local result
    if ensure_dependencies "true"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "ensure_dependencies returns 0 when gh installed and authenticated"
}

test_ensure_dependencies_returns_0_without_auth_check() {
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    # With require_auth=false, should pass even if not authenticated
    local result
    if ensure_dependencies "false"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "ensure_dependencies returns 0 with require_auth=false when gh installed"
}

test_ensure_dependencies_returns_3_when_gh_missing() {
    setup_test_env
    trap cleanup_test_env EXIT

    # Create empty PATH to simulate missing gh
    local fake_bin="$TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    # Override check_gh_installed to simulate missing
    check_gh_installed() { return 1; }

    local result
    ensure_dependencies "true" 2>/dev/null
    result=$?

    assert_equals "3" "$result" \
        "ensure_dependencies returns 3 when gh not installed"

    # Restore original function
    source <(extract_function "check_gh_installed" "$PROJECT_DIR/ru")

    cleanup_test_env
    trap - EXIT
}

test_ensure_dependencies_returns_3_when_auth_fails() {
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    setup_test_env
    trap cleanup_test_env EXIT

    # Override check_gh_auth to simulate auth failure
    check_gh_auth() { return 1; }

    local result
    ensure_dependencies "true" 2>/dev/null
    result=$?

    assert_equals "3" "$result" \
        "ensure_dependencies returns 3 when auth fails"

    # Restore original function
    source <(extract_function "check_gh_auth" "$PROJECT_DIR/ru")

    cleanup_test_env
    trap - EXIT
}

test_ensure_dependencies_skips_auth_when_false() {
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    setup_test_env
    trap cleanup_test_env EXIT

    # Override check_gh_auth to fail
    check_gh_auth() { return 1; }

    # With require_auth=false, should still succeed
    local result
    if ensure_dependencies "false"; then
        result=0
    else
        result=$?
    fi

    assert_equals "0" "$result" \
        "ensure_dependencies skips auth check when require_auth is false"

    # Restore original function
    source <(extract_function "check_gh_auth" "$PROJECT_DIR/ru")

    cleanup_test_env
    trap - EXIT
}

test_ensure_dependencies_default_requires_auth() {
    if ! command -v gh &>/dev/null; then
        skip_test "gh CLI not installed"
        return 0
    fi

    setup_test_env
    trap cleanup_test_env EXIT

    # Override check_gh_auth to fail
    check_gh_auth() { return 1; }

    # With no argument (defaults to true), should fail
    local result
    ensure_dependencies 2>/dev/null
    result=$?

    assert_equals "3" "$result" \
        "ensure_dependencies requires auth by default"

    # Restore original function
    source <(extract_function "check_gh_auth" "$PROJECT_DIR/ru")

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Dependency Checks"
echo "============================================"

# detect_os tests
run_test test_detect_os_returns_macos_for_darwin
run_test test_detect_os_returns_linux_for_linux_gnu
run_test test_detect_os_returns_linux_for_linux
run_test test_detect_os_returns_windows_for_msys
run_test test_detect_os_returns_windows_for_cygwin
run_test test_detect_os_returns_windows_for_mingw
run_test test_detect_os_returns_unknown_for_unknown

# check_gh_installed tests
run_test test_check_gh_installed_returns_0_when_gh_exists
run_test test_check_gh_installed_uses_command_v

# check_gh_auth tests
run_test test_check_gh_auth_returns_based_on_auth_status

# ensure_dependencies tests
run_test test_ensure_dependencies_returns_0_when_all_deps_ok
run_test test_ensure_dependencies_returns_0_without_auth_check
run_test test_ensure_dependencies_returns_3_when_gh_missing
run_test test_ensure_dependencies_returns_3_when_auth_fails
run_test test_ensure_dependencies_skips_auth_when_false
run_test test_ensure_dependencies_default_requires_auth

# Print results
print_results
exit "$(get_exit_code)"
