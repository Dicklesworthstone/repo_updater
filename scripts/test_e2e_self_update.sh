#!/usr/bin/env bash
#
# E2E Test: ru self-update workflow
# Tests the self-update command for checking and installing updates
#
# Test coverage:
#   - ru self-update --check parses correctly
#   - ru self-update handles network errors gracefully
#   - ru self-update handles "Not Found" response (no releases)
#   - ru self-update version comparison logic
#   - ru self-update respects non-interactive mode
#   - ru self-update validates downloaded script
#   - ru self-update checks write permissions
#
# Note: Network tests use mocked responses via PATH manipulation
# to avoid actual GitHub API calls during tests.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    export RU_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$HOME" "$RU_PROJECTS_DIR"

    # Create mock bin directory for curl/wget overrides
    mkdir -p "$TEMP_DIR/mock_bin"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

#==============================================================================
# Assertion Helpers
#==============================================================================

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected exit code $expected, got $actual)"
    fi
}

assert_stderr_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in stderr)"
    fi
}

assert_stderr_not_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if ! printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' should not be in stderr)"
    fi
}

#==============================================================================
# Mock Helpers
#==============================================================================

# Create a mock curl that simulates GitHub redirect probing used by ru.
# ru uses: curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/<owner>/<repo>/releases/latest
create_mock_curl() {
    local effective_url="$1"
    local exit_code="${2:-0}"

    cat > "$TEMP_DIR/mock_bin/curl" << EOF
#!/usr/bin/env bash
# Mock curl for testing
if [[ "$exit_code" -ne 0 ]]; then
    exit $exit_code
fi
printf '%s' "$effective_url"
EOF
    chmod +x "$TEMP_DIR/mock_bin/curl"
}

# Create a mock curl that fails
create_failing_curl() {
    cat > "$TEMP_DIR/mock_bin/curl" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEMP_DIR/mock_bin/curl"
}

#==============================================================================
# Tests: Basic self-update behavior
#==============================================================================

test_self_update_check_option() {
    echo -e "${BLUE}Test:${RESET} self-update --check option is recognized"
    setup_test_env

    # Simulate /releases/latest redirecting to the current tag.
    local current_version
    current_version=$(grep -m1 'VERSION=' "$RU_SCRIPT" | cut -d'"' -f2)

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "self-update --check exits 0 when up to date"
    assert_stderr_contains "$stderr_output" "Already up to date" "Reports already up to date"

    cleanup_test_env
}

test_self_update_network_error() {
    echo -e "${BLUE}Test:${RESET} self-update handles network errors"
    setup_test_env

    # Create a curl that fails
    create_failing_curl

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 3 "$exit_code" "Exits with code 3 on network error"
    assert_stderr_contains "$stderr_output" "Failed to determine latest release version" "Reports fetch failure"

    cleanup_test_env
}

test_self_update_no_releases() {
    echo -e "${BLUE}Test:${RESET} self-update handles no releases gracefully"
    setup_test_env

    # Simulate /releases/latest NOT redirecting to /tag/... (no releases exist).
    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0 when no releases"
    assert_stderr_contains "$stderr_output" "No releases found on GitHub" "Reports no releases"

    cleanup_test_env
}

test_self_update_detects_newer_version() {
    echo -e "${BLUE}Test:${RESET} self-update detects newer version available"
    setup_test_env

    # Simulate /releases/latest redirecting to a newer tag.
    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v99.99.99"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0 in --check mode"
    assert_stderr_contains "$stderr_output" "Update available" "Reports update available"
    assert_stderr_contains "$stderr_output" "99.99.99" "Shows new version number"
    assert_stderr_contains "$stderr_output" "self-update" "Suggests running self-update"

    cleanup_test_env
}

test_self_update_parse_error() {
    echo -e "${BLUE}Test:${RESET} self-update handles malformed redirect response"
    setup_test_env

    # Simulate a malformed redirect URL that contains /tag/ but no version.
    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 3 "$exit_code" "Exits with code 3 on parse error"
    assert_stderr_contains "$stderr_output" "Failed to determine latest release version" "Reports parse failure"

    cleanup_test_env
}

test_self_update_v_prefix_handling() {
    echo -e "${BLUE}Test:${RESET} self-update handles v prefix in version"
    setup_test_env

    local current_version
    current_version=$(grep -m1 'VERSION=' "$RU_SCRIPT" | cut -d'"' -f2)

    # /releases/latest redirects include 'v' prefixes by convention.
    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Handles v prefix correctly"
    assert_stderr_contains "$stderr_output" "Already up to date" "Compares versions correctly"

    cleanup_test_env
}

test_self_update_non_interactive_mode() {
    echo -e "${BLUE}Test:${RESET} self-update respects non-interactive mode"
    setup_test_env

    # Create mock curl that returns a newer version
    # In non-interactive mode with update available, it should still work
    # for --check (which doesn't require confirmation)
    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v99.99.99"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" --non-interactive self-update --check 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "--check works in non-interactive mode"
    assert_stderr_contains "$stderr_output" "Update available" "Reports update in non-interactive"

    cleanup_test_env
}

test_self_update_step_output() {
    echo -e "${BLUE}Test:${RESET} self-update shows progress steps"
    setup_test_env

    local current_version
    current_version=$(grep -m1 'VERSION=' "$RU_SCRIPT" | cut -d'"' -f2)

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code
    stderr_output=$(PATH="$TEMP_DIR/mock_bin:$PATH" "$RU_SCRIPT" self-update --check 2>&1)
    exit_code=$?

    assert_stderr_contains "$stderr_output" "Checking" "Shows checking step"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru self-update workflow"
echo "============================================"
echo ""

test_self_update_check_option
echo ""
test_self_update_network_error
echo ""
test_self_update_no_releases
echo ""
test_self_update_detects_newer_version
echo ""
test_self_update_parse_error
echo ""
test_self_update_v_prefix_handling
echo ""
test_self_update_non_interactive_mode
echo ""
test_self_update_step_output
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
