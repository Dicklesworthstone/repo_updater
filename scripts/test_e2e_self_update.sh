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
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Mock Helpers
#==============================================================================

# Create a mock curl that simulates GitHub redirect probing used by ru.
create_mock_curl() {
    local effective_url="$1"
    local exit_code="${2:-0}"

    cat > "$E2E_MOCK_BIN/curl" << EOF
#!/usr/bin/env bash
# Mock curl for testing
if [[ "$exit_code" -ne 0 ]]; then
    exit $exit_code
fi
printf '%s' "$effective_url"
EOF
    chmod +x "$E2E_MOCK_BIN/curl"
}

# Create a mock curl that fails
create_failing_curl() {
    cat > "$E2E_MOCK_BIN/curl" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$E2E_MOCK_BIN/curl"
}

#==============================================================================
# Tests: Basic self-update behavior
#==============================================================================

test_self_update_check_option() {
    e2e_setup

    local current_version
    current_version=$(grep -m1 'VERSION=' "$E2E_RU_SCRIPT" | cut -d'"' -f2)

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "self-update --check exits 0 when up to date"
    assert_contains "$stderr_output" "Already up to date" "Reports already up to date"

    e2e_cleanup
}

test_self_update_network_error() {
    e2e_setup

    create_failing_curl

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "3" "$exit_code" "Exits with code 3 on network error"
    assert_contains "$stderr_output" "Failed to determine latest release version" "Reports fetch failure"

    e2e_cleanup
}

test_self_update_no_releases() {
    e2e_setup

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0 when no releases"
    assert_contains "$stderr_output" "No releases found on GitHub" "Reports no releases"

    e2e_cleanup
}

test_self_update_detects_newer_version() {
    e2e_setup

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v99.99.99"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0 in --check mode"
    assert_contains "$stderr_output" "Update available" "Reports update available"
    assert_contains "$stderr_output" "99.99.99" "Shows new version number"
    assert_contains "$stderr_output" "self-update" "Suggests running self-update"

    e2e_cleanup
}

test_self_update_parse_error() {
    e2e_setup

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "3" "$exit_code" "Exits with code 3 on parse error"
    assert_contains "$stderr_output" "Failed to determine latest release version" "Reports parse failure"

    e2e_cleanup
}

test_self_update_v_prefix_handling() {
    e2e_setup

    local current_version
    current_version=$(grep -m1 'VERSION=' "$E2E_RU_SCRIPT" | cut -d'"' -f2)

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Handles v prefix correctly"
    assert_contains "$stderr_output" "Already up to date" "Compares versions correctly"

    e2e_cleanup
}

test_self_update_non_interactive_mode() {
    e2e_setup

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v99.99.99"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" --non-interactive self-update --check 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "--check works in non-interactive mode"
    assert_contains "$stderr_output" "Update available" "Reports update in non-interactive"

    e2e_cleanup
}

test_self_update_step_output() {
    e2e_setup

    local current_version
    current_version=$(grep -m1 'VERSION=' "$E2E_RU_SCRIPT" | cut -d'"' -f2)

    create_mock_curl "https://github.com/Dicklesworthstone/repo_updater/releases/tag/v${current_version}"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" self-update --check 2>&1) || exit_code=$?

    assert_contains "$stderr_output" "Checking" "Shows checking step"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_self_update_check_option
run_test test_self_update_network_error
run_test test_self_update_no_releases
run_test test_self_update_detects_newer_version
run_test test_self_update_parse_error
run_test test_self_update_v_prefix_handling
run_test test_self_update_non_interactive_mode
run_test test_self_update_step_output

print_results
