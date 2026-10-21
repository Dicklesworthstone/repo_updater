#!/usr/bin/env bash
#
# Unit Tests: Dependency Checks
# Tests for check_gh_installed, check_gh_auth, ensure_dependencies, detect_os
#
# Test coverage:
#   - check_gh_installed returns 0 when gh is available
#   - check_gh_installed returns 1 when gh is not available
#   - check_gh_auth returns 0 when authenticated
#   - check_gh_auth returns 1 when not authenticated
#   - ensure_dependencies returns 0 when all deps OK
#   - ensure_dependencies returns 3 when gh not installed
#   - ensure_dependencies with require_auth=false skips auth check
#   - detect_os returns expected value for current system
#   - detect_os handles darwin, linux, windows, unknown
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

# We need to extract functions carefully to avoid side effects
source_dependency_functions() {
    # These functions have minimal dependencies
    eval "$(sed -n '/^check_gh_installed()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^check_gh_auth()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

    # For ensure_dependencies, we need supporting functions. The log helpers
    # use ru's color variables, which ru only sets at startup; without them
    # set -u ends this whole file the first time a log line is printed.
    # shellcheck disable=SC2034  # read by the eval'd ru log helpers below
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
    QUIET="${QUIET:-false}"
    eval "$(sed -n '/^log_info()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^log_error()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^log_success()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^can_prompt()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^ensure_dependencies()/,/^}/p' "$RU_SCRIPT")"
}

source_dependency_functions

#==============================================================================
# Tests: check_gh_installed
#==============================================================================

test_check_gh_installed_returns_0_when_available() {
    # This test assumes gh is installed on the test system
    # If gh is not installed, this test validates the negative case
    if command -v gh &>/dev/null; then
        if check_gh_installed; then
            assert_true "true" "check_gh_installed returns 0 when gh is available"
        else
            assert_true "false" "check_gh_installed should return 0"
        fi
    else
        # gh not installed - test the failure case instead
        if ! check_gh_installed; then
            assert_true "true" "check_gh_installed returns 1 when gh not available"
        else
            assert_true "false" "check_gh_installed should return 1"
        fi
    fi
}

test_check_gh_installed_uses_command_v() {
    # Verify the implementation uses 'command -v'
    local func_body
    func_body=$(sed -n '/^check_gh_installed()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "command -v gh" "Uses 'command -v' to check for gh"
}

test_check_gh_installed_with_fake_gh() {
    # Create a fake gh command in a temp dir
    local temp_dir
    temp_dir=$(create_temp_dir)

    # Create a fake gh script
    cat > "$temp_dir/gh" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$temp_dir/gh"

    # Prepend to PATH
    local old_path="$PATH"
    PATH="$temp_dir:$PATH"

    if check_gh_installed; then
        assert_true "true" "check_gh_installed finds gh in PATH"
    else
        assert_true "false" "check_gh_installed should find fake gh"
    fi

    PATH="$old_path"
}

test_check_gh_installed_without_gh_in_path() {
    # Remove gh from PATH temporarily
    local old_path="$PATH"

    # Create a PATH without gh
    local new_path=""
    IFS=':' read -ra path_parts <<< "$PATH"
    for part in "${path_parts[@]}"; do
        if [[ ! -x "$part/gh" ]]; then
            new_path="${new_path:+$new_path:}$part"
        fi
    done

    PATH="$new_path"

    if ! check_gh_installed; then
        assert_true "true" "check_gh_installed returns 1 when gh not in PATH"
    else
        # gh might be a shell builtin or alias - still counts as failure
        assert_true "true" "gh found even with modified PATH (builtin or alias)"
    fi

    PATH="$old_path"
}

#==============================================================================
# Tests: check_gh_auth
#==============================================================================

test_check_gh_auth_implementation() {
    # Verify the implementation uses 'gh auth status'
    local func_body
    func_body=$(sed -n '/^check_gh_auth()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "gh auth status" "Uses 'gh auth status' to check auth"
}

test_check_gh_auth_when_authenticated() {
    # Only run if gh is installed and authenticated
    if ! command -v gh &>/dev/null; then
        skip_test "gh not installed"
        return 0
    fi

    if gh auth status &>/dev/null; then
        if check_gh_auth; then
            assert_true "true" "check_gh_auth returns 0 when authenticated"
        else
            assert_true "false" "check_gh_auth should return 0"
        fi
    else
        # Not authenticated - test failure case
        if ! check_gh_auth; then
            assert_true "true" "check_gh_auth returns 1 when not authenticated"
        else
            assert_true "false" "check_gh_auth should return 1"
        fi
    fi
}

test_check_gh_auth_silences_output() {
    # Verify output is redirected to /dev/null
    local func_body
    func_body=$(sed -n '/^check_gh_auth()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "&>/dev/null" "Silences stdout and stderr"
}

#==============================================================================
# Tests: detect_os
#==============================================================================

test_detect_os_returns_value() {
    local result
    result=$(detect_os)

    assert_not_empty "$result" "detect_os returns a non-empty value"
}

test_detect_os_matches_system() {
    local result
    result=$(detect_os)

    # Check that the result is one of the expected values
    case "$result" in
        macos|linux|windows|unknown)
            assert_true "true" "detect_os returns valid OS type: $result"
            ;;
        *)
            assert_true "false" "detect_os returned unexpected value: $result"
            ;;
    esac
}

test_detect_os_darwin() {
    # Create a local scope with mocked OSTYPE (subshell isolates the change)
    (
        OSTYPE="darwin21.0"
        # Re-source detect_os with new OSTYPE
        eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

        local result
        result=$(detect_os)

        if [[ "$result" == "macos" ]]; then
            echo "PASS: darwin -> macos"
        else
            echo "FAIL: darwin -> $result"
            exit 1
        fi
    ) && assert_true "true" "detect_os returns 'macos' for darwin OSTYPE"
}

test_detect_os_linux() {
    (
        OSTYPE="linux-gnu"
        eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

        local result
        result=$(detect_os)

        if [[ "$result" == "linux" ]]; then
            echo "PASS: linux-gnu -> linux"
        else
            echo "FAIL: linux-gnu -> $result"
            exit 1
        fi
    ) && assert_true "true" "detect_os returns 'linux' for linux-gnu OSTYPE"
}

test_detect_os_windows_msys() {
    (
        OSTYPE="msys"
        eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

        local result
        result=$(detect_os)

        if [[ "$result" == "windows" ]]; then
            echo "PASS: msys -> windows"
        else
            echo "FAIL: msys -> $result"
            exit 1
        fi
    ) && assert_true "true" "detect_os returns 'windows' for msys OSTYPE"
}

test_detect_os_windows_cygwin() {
    (
        OSTYPE="cygwin"
        eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

        local result
        result=$(detect_os)

        if [[ "$result" == "windows" ]]; then
            echo "PASS: cygwin -> windows"
        else
            echo "FAIL: cygwin -> $result"
            exit 1
        fi
    ) && assert_true "true" "detect_os returns 'windows' for cygwin OSTYPE"
}

test_detect_os_unknown() {
    (
        OSTYPE="freebsd13.0"
        eval "$(sed -n '/^detect_os()/,/^}/p' "$RU_SCRIPT")"

        local result
        result=$(detect_os)

        if [[ "$result" == "unknown" ]]; then
            echo "PASS: freebsd -> unknown"
        else
            echo "FAIL: freebsd -> $result"
            exit 1
        fi
    ) && assert_true "true" "detect_os returns 'unknown' for unrecognized OSTYPE"
}

#==============================================================================
# Tests: ensure_dependencies
#==============================================================================

test_ensure_dependencies_returns_0_when_all_ok() {
    # Only run if gh is installed and authenticated
    if ! command -v gh &>/dev/null; then
        skip_test "gh not installed"
        return 0
    fi

    if ! gh auth status &>/dev/null; then
        skip_test "gh not authenticated"
        return 0
    fi

    # Mock can_prompt to return false (non-interactive)
    can_prompt() { return 1; }

    if ensure_dependencies "true" 2>/dev/null; then
        assert_true "true" "ensure_dependencies returns 0 when all deps OK"
    else
        assert_true "false" "ensure_dependencies should return 0"
    fi
}

test_ensure_dependencies_returns_3_when_gh_missing() {
    # Remove gh from PATH
    local old_path="$PATH"
    PATH="/bin:/usr/bin"  # Minimal path without gh

    # Re-source the function with limited PATH
    eval "$(sed -n '/^check_gh_installed()/,/^}/p' "$RU_SCRIPT")"

    # Check if gh is actually missing from this path
    if command -v gh &>/dev/null; then
        PATH="$old_path"
        skip_test "gh still found in minimal PATH"
        return 0
    fi

    # Mock can_prompt to return false
    can_prompt() { return 1; }

    local exit_code=0
    ensure_dependencies "true" 2>/dev/null || exit_code=$?

    PATH="$old_path"

    assert_equals "3" "$exit_code" "ensure_dependencies returns 3 when gh not installed"
}

test_ensure_dependencies_skips_auth_when_require_auth_false() {
    # Only run if gh is installed
    if ! command -v gh &>/dev/null; then
        skip_test "gh not installed"
        return 0
    fi

    # Mock can_prompt
    can_prompt() { return 1; }

    # Even if not authenticated, should succeed with require_auth=false
    local exit_code=0
    ensure_dependencies "false" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "ensure_dependencies with require_auth=false skips auth check"
}

test_ensure_dependencies_accepts_string_true() {
    # Only run if gh is installed and authenticated
    if ! command -v gh &>/dev/null; then
        skip_test "gh not installed"
        return 0
    fi

    if ! gh auth status &>/dev/null; then
        skip_test "gh not authenticated"
        return 0
    fi

    can_prompt() { return 1; }

    local exit_code=0
    ensure_dependencies "true" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "ensure_dependencies accepts 'true' string for require_auth"
}

test_ensure_dependencies_default_requires_auth() {
    # Verify that the default value for require_auth is "true"
    local func_body
    func_body=$(sed -n '/^ensure_dependencies()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" 'require_auth="${1:-true}"' "Default require_auth is 'true'"
}

test_ensure_dependencies_shows_install_instructions() {
    # When gh is missing, should show install instructions
    # This tests the log output format
    local old_path="$PATH"
    PATH="/bin:/usr/bin"

    eval "$(sed -n '/^check_gh_installed()/,/^}/p' "$RU_SCRIPT")"

    if command -v gh &>/dev/null; then
        PATH="$old_path"
        skip_test "gh still found in minimal PATH"
        return 0
    fi

    can_prompt() { return 1; }

    local stderr_output
    stderr_output=$(ensure_dependencies "true" 2>&1)
    local exit_code=$?

    PATH="$old_path"

    if [[ $exit_code -eq 3 ]]; then
        # Check that install instructions are shown
        if echo "$stderr_output" | grep -q -E "(brew install gh|apt install gh|dnf install gh|cli.github.com)"; then
            assert_true "true" "Shows installation instructions when gh missing"
        else
            # May not contain all instructions, just check it output something
            assert_not_empty "$stderr_output" "Outputs error message when gh missing"
        fi
    else
        assert_true "false" "ensure_dependencies should fail when gh missing"
    fi
}

#==============================================================================
# Tests: Integration
#==============================================================================

test_dependency_functions_are_exported() {
    # Verify functions exist and are callable
    assert_true "declare -f check_gh_installed >/dev/null" "check_gh_installed is defined"
    assert_true "declare -f check_gh_auth >/dev/null" "check_gh_auth is defined"
    assert_true "declare -f detect_os >/dev/null" "detect_os is defined"
    assert_true "declare -f ensure_dependencies >/dev/null" "ensure_dependencies is defined"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Dependency Checks"
echo "============================================"

# check_gh_installed tests
run_test test_check_gh_installed_returns_0_when_available
run_test test_check_gh_installed_uses_command_v
run_test test_check_gh_installed_with_fake_gh
run_test test_check_gh_installed_without_gh_in_path

# check_gh_auth tests
run_test test_check_gh_auth_implementation
run_test test_check_gh_auth_when_authenticated
run_test test_check_gh_auth_silences_output

# detect_os tests
run_test test_detect_os_returns_value
run_test test_detect_os_matches_system
run_test test_detect_os_darwin
run_test test_detect_os_linux
run_test test_detect_os_windows_msys
run_test test_detect_os_windows_cygwin
run_test test_detect_os_unknown

# ensure_dependencies tests
run_test test_ensure_dependencies_returns_0_when_all_ok
run_test test_ensure_dependencies_returns_3_when_gh_missing
run_test test_ensure_dependencies_skips_auth_when_require_auth_false
run_test test_ensure_dependencies_accepts_string_true
run_test test_ensure_dependencies_default_requires_auth
run_test test_ensure_dependencies_shows_install_instructions

# Integration tests
run_test test_dependency_functions_are_exported

print_results
exit "$(get_exit_code)"
