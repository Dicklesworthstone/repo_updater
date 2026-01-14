#!/usr/bin/env bash
#
# E2E Test: ru init workflow
# Tests first-run configuration creation and idempotency
#
# Test coverage:
#   - Creates ~/.config/ru/ directory structure
#   - Creates config file with default values
#   - Creates repos.d/public.txt with template
#   - Subsequent runs detect existing config (idempotent)
#   - Works on fresh system (no prior config)
#
# shellcheck disable=SC2034  # Variables used by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (provides test isolation, assertions, logging)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Tests
#==============================================================================

test_init_creates_config_dir() {
    log_test_start "ru init creates config directory on fresh system"
    e2e_setup

    local config_dir="$XDG_CONFIG_HOME/ru"

    # Verify no config exists (framework creates parent dirs but not ru/)
    if [[ -d "$config_dir" ]]; then
        # Framework creates $XDG_CONFIG_HOME/ru/repos.d, so remove for fresh test
        rm -rf "$config_dir"
    fi

    # Run init
    local exit_code=0
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1 || exit_code=$?

    assert_equals "0" "$exit_code" "ru init exits with code 0"
    assert_dir_exists "$config_dir" "Config directory created"

    e2e_cleanup
    log_test_pass "ru init creates config directory on fresh system"
}

test_init_creates_repos_dir() {
    log_test_start "ru init creates repos.d directory"
    e2e_setup

    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"
    rm -rf "$XDG_CONFIG_HOME/ru"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    assert_dir_exists "$repos_dir" "repos.d directory created"

    e2e_cleanup
    log_test_pass "ru init creates repos.d directory"
}

test_init_creates_config_file() {
    log_test_start "ru init creates config file with defaults"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"
    local config_file="$XDG_CONFIG_HOME/ru/config"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    assert_file_exists "$config_file" "Config file created"
    assert_file_contains "$config_file" "PROJECTS_DIR=" "Config contains PROJECTS_DIR"
    assert_file_contains "$config_file" "LAYOUT=" "Config contains LAYOUT"
    assert_file_contains "$config_file" "UPDATE_STRATEGY=" "Config contains UPDATE_STRATEGY"
    assert_file_contains "$config_file" "AUTOSTASH=" "Config contains AUTOSTASH"

    e2e_cleanup
    log_test_pass "ru init creates config file with defaults"
}

test_init_creates_repos_file() {
    log_test_start "ru init creates public.txt template"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    assert_file_exists "$repos_file" "public.txt file created"
    assert_file_contains "$repos_file" "owner/repo" "public.txt contains format examples"
    assert_file_contains "$repos_file" "@branch" "public.txt documents branch pinning"

    e2e_cleanup
    log_test_pass "ru init creates public.txt template"
}

test_init_idempotent() {
    log_test_start "ru init is idempotent (detects existing config)"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"
    local config_dir="$XDG_CONFIG_HOME/ru"

    # First init
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    # Add a marker to config to verify it's not overwritten
    echo "# MARKER: Original config" >> "$config_dir/config"

    # Second init
    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" init 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Second init exits with code 0"
    assert_contains "$output" "already exists" "Second init detects existing config"
    assert_file_contains "$config_dir/config" "MARKER: Original config" "Config file not overwritten"

    e2e_cleanup
    log_test_pass "ru init is idempotent (detects existing config)"
}

test_init_creates_state_dirs() {
    log_test_start "ru init creates state directories"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"
    local state_dir="$XDG_STATE_HOME/ru"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    assert_dir_exists "$state_dir" "State directory created"

    e2e_cleanup
    log_test_pass "ru init creates state directories"
}

test_init_output_shows_next_steps() {
    log_test_start "ru init shows helpful next steps"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"

    local output
    output=$("$E2E_RU_SCRIPT" init 2>&1)

    assert_contains "$output" "ru add" "Output mentions ru add"
    assert_contains "$output" "ru sync" "Output mentions ru sync"

    e2e_cleanup
    log_test_pass "ru init shows helpful next steps"
}

test_init_respects_xdg_config_home() {
    log_test_start "ru init respects XDG_CONFIG_HOME"
    e2e_setup

    # Set custom XDG path (different from what e2e_setup creates)
    # Unset RU_CONFIG_DIR to test XDG_CONFIG_HOME behavior
    local custom_config="$E2E_TEMP_DIR/custom_config"
    mkdir -p "$custom_config"
    unset RU_CONFIG_DIR
    export XDG_CONFIG_HOME="$custom_config"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    assert_dir_exists "$custom_config/ru" "Uses custom XDG_CONFIG_HOME"

    e2e_cleanup
    log_test_pass "ru init respects XDG_CONFIG_HOME"
}

test_init_example_flag() {
    log_test_start "ru init --example adds sample repos"
    e2e_setup

    rm -rf "$XDG_CONFIG_HOME/ru"
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    # Run init with --example flag
    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" init --example 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru init --example exits with code 0"
    assert_file_exists "$repos_file" "public.txt file created with --example"

    # Verify example repos are present (from examples/public.txt)
    assert_file_contains "$repos_file" "charmbracelet/gum" "public.txt contains charmbracelet/gum"
    assert_file_contains "$repos_file" "cli/cli" "public.txt contains cli/cli"
    assert_file_contains "$repos_file" "koalaman/shellcheck" "public.txt contains koalaman/shellcheck"
    assert_contains "$output" "Added example repos" "Output confirms example repos added"

    e2e_cleanup
    log_test_pass "ru init --example adds sample repos"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru init workflow"

run_test test_init_creates_config_dir
run_test test_init_creates_repos_dir
run_test test_init_creates_config_file
run_test test_init_creates_repos_file
run_test test_init_idempotent
run_test test_init_creates_state_dirs
run_test test_init_output_shows_next_steps
run_test test_init_respects_xdg_config_home
run_test test_init_example_flag

print_results
exit "$(get_exit_code)"
