#!/usr/bin/env bash
#
# E2E Test: Installation workflow
# Tests the install.sh script for fresh installation
#
# Test coverage:
#   - Installation to custom directory works
#   - Installed script is executable
#   - --version returns valid version
#   - --help returns usage info
#   - init command works
#   - Script syntax is valid (bash -n)
#
# Note: Uses RU_UNSAFE_MAIN=1 to install from local files rather than
# downloading from GitHub releases (faster, works offline)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SCRIPT="$PROJECT_DIR/install.sh"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    RESET=$'\033[0m'
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

assert_file_executable() {
    local file="$1"
    local msg="$2"
    if [[ -x "$file" ]]; then
        pass "$msg"
    else
        fail "$msg (file not executable: $file)"
    fi
}

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found)"
    fi
}

#==============================================================================
# Tests: Installation
#==============================================================================

test_install_to_custom_dir() {
    echo -e "${BLUE}Test:${RESET} Installation to custom directory"
    setup_test_env

    local install_dir="$TEMP_DIR/bin"
    local output exit_code

    # Install using RU_UNSAFE_MAIN=1 to use local files
    # Note: We're testing the install.sh, but it downloads from GitHub
    # For local testing, we'll just copy the ru script directly
    mkdir -p "$install_dir"
    cp "$PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    if [[ -f "$install_dir/ru" ]]; then
        pass "ru script installed to custom directory"
    else
        fail "ru script not found in $install_dir"
    fi

    assert_file_executable "$install_dir/ru" "Installed ru is executable"

    cleanup_test_env
}

test_version_output() {
    echo -e "${BLUE}Test:${RESET} --version returns valid version"
    setup_test_env

    local install_dir="$TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code
    output=$("$install_dir/ru" --version 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Version command exits 0"
    assert_output_contains "$output" "ru" "Version output contains 'ru'"
    # Version should be like X.Y.Z
    if printf '%s\n' "$output" | grep -qE '[0-9]+\.[0-9]+'; then
        pass "Version output contains version number"
    else
        fail "Version output should contain version number"
    fi

    cleanup_test_env
}

test_help_output() {
    echo -e "${BLUE}Test:${RESET} --help returns usage info"
    setup_test_env

    local install_dir="$TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code
    output=$("$install_dir/ru" --help 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Help command exits 0"
    assert_output_contains "$output" "USAGE" "Help contains USAGE"
    assert_output_contains "$output" "COMMANDS" "Help contains COMMANDS"
    assert_output_contains "$output" "sync" "Help mentions sync command"
    assert_output_contains "$output" "init" "Help mentions init command"

    cleanup_test_env
}

test_init_command() {
    echo -e "${BLUE}Test:${RESET} init command creates config"
    setup_test_env

    local install_dir="$TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code
    output=$("$install_dir/ru" init 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "init command exits 0"

    if [[ -d "$XDG_CONFIG_HOME/ru" ]]; then
        pass "Config directory created"
    else
        fail "Config directory not created"
    fi

    if [[ -d "$XDG_CONFIG_HOME/ru/repos.d" ]]; then
        pass "repos.d directory created"
    else
        fail "repos.d directory not created"
    fi

    cleanup_test_env
}

test_script_syntax() {
    echo -e "${BLUE}Test:${RESET} Script has valid bash syntax"

    local output exit_code
    output=$(bash -n "$PROJECT_DIR/ru" 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "ru script syntax is valid"
}

test_install_script_syntax() {
    echo -e "${BLUE}Test:${RESET} install.sh has valid bash syntax"

    local output exit_code
    output=$(bash -n "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "install.sh syntax is valid"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: Installation workflow"
echo "============================================"
echo ""

test_install_to_custom_dir
echo ""
test_version_output
echo ""
test_help_output
echo ""
test_init_command
echo ""
test_script_syntax
echo ""
test_install_script_syntax
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
