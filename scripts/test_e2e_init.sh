#!/usr/bin/env bash
#
# E2E Test: ru init workflow
# Tests first-run configuration creation and idempotency
#
# Test coverage:
#   - Creates ~/.config/ru/ directory structure
#   - Creates config file with default values
#   - Creates repos.d/repos.txt with template
#   - Subsequent runs detect existing config (idempotent)
#   - Works on fresh system (no prior config)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
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
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    # Override XDG directories to isolate tests
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    # Also set HOME for fallback paths
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

skip() {
    echo -e "${YELLOW}SKIP${RESET}: $1"
}

#==============================================================================
# Assertion Helpers
#==============================================================================

assert_dir_exists() {
    local path="$1"
    local msg="$2"
    if [[ -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory not found: $path)"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $path)"
    fi
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local msg="$3"
    if [[ -f "$path" ]] && grep -q "$pattern" "$path"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $path)"
    fi
}

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

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in output)"
    fi
}

#==============================================================================
# Tests
#==============================================================================

test_init_creates_config_dir() {
    echo "Test: ru init creates config directory on fresh system"
    setup_test_env

    local config_dir="$XDG_CONFIG_HOME/ru"

    # Verify no config exists
    [[ ! -d "$config_dir" ]] || { fail "Config dir should not exist before init"; cleanup_test_env; return; }

    # Run init
    local output
    output=$("$RU_SCRIPT" init 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru init exits with code 0"
    assert_dir_exists "$config_dir" "Config directory created"

    cleanup_test_env
}

test_init_creates_repos_dir() {
    echo "Test: ru init creates repos.d directory"
    setup_test_env

    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"

    "$RU_SCRIPT" init 2>&1

    assert_dir_exists "$repos_dir" "repos.d directory created"

    cleanup_test_env
}

test_init_creates_config_file() {
    echo "Test: ru init creates config file with defaults"
    setup_test_env

    local config_file="$XDG_CONFIG_HOME/ru/config"

    "$RU_SCRIPT" init 2>&1

    assert_file_exists "$config_file" "Config file created"
    assert_file_contains "$config_file" "PROJECTS_DIR=" "Config contains PROJECTS_DIR"
    assert_file_contains "$config_file" "LAYOUT=" "Config contains LAYOUT"
    assert_file_contains "$config_file" "UPDATE_STRATEGY=" "Config contains UPDATE_STRATEGY"
    assert_file_contains "$config_file" "AUTOSTASH=" "Config contains AUTOSTASH"

    cleanup_test_env
}

test_init_creates_repos_file() {
    echo "Test: ru init creates repos.txt template"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/repos.txt"

    "$RU_SCRIPT" init 2>&1

    assert_file_exists "$repos_file" "repos.txt file created"
    assert_file_contains "$repos_file" "owner/repo" "repos.txt contains format examples"
    assert_file_contains "$repos_file" "@branch" "repos.txt documents branch pinning"

    cleanup_test_env
}

test_init_idempotent() {
    echo "Test: ru init is idempotent (detects existing config)"
    setup_test_env

    local config_dir="$XDG_CONFIG_HOME/ru"

    # First init
    "$RU_SCRIPT" init 2>&1

    # Add a marker to config to verify it's not overwritten
    echo "# MARKER: Original config" >> "$config_dir/config"

    # Second init
    local output
    output=$("$RU_SCRIPT" init 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Second init exits with code 0"
    assert_output_contains "$output" "already exists" "Second init detects existing config"
    assert_file_contains "$config_dir/config" "MARKER: Original config" "Config file not overwritten"

    cleanup_test_env
}

test_init_creates_state_dirs() {
    echo "Test: ru init creates state directories"
    setup_test_env

    local state_dir="$XDG_STATE_HOME/ru"

    "$RU_SCRIPT" init 2>&1

    assert_dir_exists "$state_dir" "State directory created"

    cleanup_test_env
}

test_init_output_shows_next_steps() {
    echo "Test: ru init shows helpful next steps"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" init 2>&1)

    assert_output_contains "$output" "ru add" "Output mentions ru add"
    assert_output_contains "$output" "ru sync" "Output mentions ru sync"

    cleanup_test_env
}

test_init_respects_xdg_config_home() {
    echo "Test: ru init respects XDG_CONFIG_HOME"
    setup_test_env

    # Set custom XDG path
    local custom_config="$TEMP_DIR/custom_config"
    export XDG_CONFIG_HOME="$custom_config"

    "$RU_SCRIPT" init 2>&1

    assert_dir_exists "$custom_config/ru" "Uses custom XDG_CONFIG_HOME"

    cleanup_test_env
}

test_init_example_flag() {
    echo "Test: ru init --example adds sample repos"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/repos.txt"

    # Run init with --example flag
    local output
    output=$("$RU_SCRIPT" init --example 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru init --example exits with code 0"
    assert_file_exists "$repos_file" "repos.txt file created with --example"

    # Verify example repos are present (from examples/public.txt)
    assert_file_contains "$repos_file" "charmbracelet/gum" "repos.txt contains charmbracelet/gum"
    assert_file_contains "$repos_file" "cli/cli" "repos.txt contains cli/cli"
    assert_file_contains "$repos_file" "koalaman/shellcheck" "repos.txt contains koalaman/shellcheck"
    assert_output_contains "$output" "Added example repos" "Output confirms example repos added"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru init workflow"
echo "============================================"
echo ""

test_init_creates_config_dir
echo ""

test_init_creates_repos_dir
echo ""

test_init_creates_config_file
echo ""

test_init_creates_repos_file
echo ""

test_init_idempotent
echo ""

test_init_creates_state_dirs
echo ""

test_init_output_shows_next_steps
echo ""

test_init_respects_xdg_config_home
echo ""

test_init_example_flag
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
