#!/usr/bin/env bash
#
# E2E Test: ru list workflow
# Tests listing configured repositories with various options and formats
#
# Test coverage:
#   - ru list shows configured repos on stdout
#   - ru list shows count on stderr
#   - ru list handles uninitialized config
#   - ru list handles empty repos file
#   - ru list --paths shows local paths instead of URLs
#   - ru list respects LAYOUT setting (flat, owner-repo, full)
#   - ru list handles branch specs (owner/repo@branch)
#   - ru list handles custom names (owner/repo as custom-name)
#   - ru list handles multiple URL formats
#   - ru list handles repos.d with multiple files
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
    mkdir -p "$HOME"
    mkdir -p "$RU_PROJECTS_DIR"
}

setup_initialized_env() {
    setup_test_env
    # Initialize config
    "$RU_SCRIPT" init >/dev/null 2>&1
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR RU_LAYOUT
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

assert_stdout_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in stdout)"
    fi
}

assert_stdout_not_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if ! printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' should not be in stdout)"
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

assert_line_count() {
    local output="$1"
    local expected="$2"
    local msg="$3"
    local actual
    # Count non-empty lines
    actual=$(printf '%s\n' "$output" | grep -c -v '^$' || true)
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected $expected lines, got $actual)"
    fi
}

#==============================================================================
# Tests: Uninitialized/Empty States
#==============================================================================

test_list_uninitialized() {
    echo -e "${BLUE}Test:${RESET} ru list handles uninitialized config"
    setup_test_env
    # Don't initialize - config dir doesn't exist

    local stderr_output
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0 for uninitialized"
    assert_stderr_contains "$stderr_output" "No configuration found" "Shows no config message"

    cleanup_test_env
}

test_list_empty_repos_file() {
    echo -e "${BLUE}Test:${RESET} ru list handles empty repos file"
    setup_initialized_env

    # Clear the repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "# Empty repos file" > "$repos_file"

    local stderr_output
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0 for empty repos"
    assert_stderr_contains "$stderr_output" "No repositories configured" "Shows no repos message"

    cleanup_test_env
}

#==============================================================================
# Tests: Basic List Functionality
#==============================================================================

test_list_single_repo() {
    echo -e "${BLUE}Test:${RESET} ru list shows single repo"
    setup_initialized_env

    "$RU_SCRIPT" add owner/repo >/dev/null 2>&1

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Exits with code 0"
    assert_stdout_contains "$stdout_output" "owner/repo" "Stdout contains repo URL"
    assert_stderr_contains "$stderr_output" "(1)" "Stderr shows count of 1"

    cleanup_test_env
}

test_list_multiple_repos() {
    echo -e "${BLUE}Test:${RESET} ru list shows multiple repos"
    setup_initialized_env

    "$RU_SCRIPT" add cli/cli charmbracelet/gum koalaman/shellcheck >/dev/null 2>&1

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)

    assert_stdout_contains "$stdout_output" "cli/cli" "Shows cli/cli"
    assert_stdout_contains "$stdout_output" "charmbracelet/gum" "Shows charmbracelet/gum"
    assert_stdout_contains "$stdout_output" "koalaman/shellcheck" "Shows koalaman/shellcheck"
    assert_stderr_contains "$stderr_output" "(3)" "Stderr shows count of 3"
    assert_line_count "$stdout_output" 3 "Output has 3 lines"

    cleanup_test_env
}

#==============================================================================
# Tests: --paths Mode
#==============================================================================

test_list_paths_mode_flat_layout() {
    echo -e "${BLUE}Test:${RESET} ru list --paths shows paths with flat layout"
    setup_initialized_env
    export RU_LAYOUT="flat"

    "$RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list --paths 2>/dev/null)

    # In flat layout, path should end with just the repo name
    assert_stdout_contains "$stdout_output" "myrepo" "Path contains repo name"
    assert_stdout_contains "$stdout_output" "$RU_PROJECTS_DIR" "Path includes projects dir"

    cleanup_test_env
}

test_list_paths_mode_owner_repo_layout() {
    echo -e "${BLUE}Test:${RESET} ru list --paths shows paths with owner-repo layout"
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    "$RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list --paths 2>/dev/null)

    # In owner-repo layout, path should contain owner/repo
    assert_stdout_contains "$stdout_output" "owner/myrepo" "Path contains owner/repo"
    assert_stdout_contains "$stdout_output" "$RU_PROJECTS_DIR" "Path includes projects dir"

    cleanup_test_env
}

test_list_paths_mode_full_layout() {
    echo -e "${BLUE}Test:${RESET} ru list --paths shows paths with full layout"
    setup_initialized_env
    export RU_LAYOUT="full"

    "$RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list --paths 2>/dev/null)

    # In full layout, path should contain github.com/owner/repo
    assert_stdout_contains "$stdout_output" "github.com" "Path contains github.com"
    assert_stdout_contains "$stdout_output" "owner/myrepo" "Path contains owner/repo"

    cleanup_test_env
}

#==============================================================================
# Tests: Repo Spec Variations
#==============================================================================

test_list_with_branch_spec() {
    echo -e "${BLUE}Test:${RESET} ru list handles branch specs (owner/repo@branch)"
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/repo@develop" >> "$repos_file"

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)

    assert_stdout_contains "$stdout_output" "owner/repo" "Shows repo URL (without branch in output)"

    cleanup_test_env
}

test_list_with_custom_name() {
    echo -e "${BLUE}Test:${RESET} ru list handles custom names (owner/repo as name)"
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)

    assert_stdout_contains "$stdout_output" "owner/long-repository-name" "Shows original repo URL"

    cleanup_test_env
}

test_list_paths_with_custom_name() {
    echo -e "${BLUE}Test:${RESET} ru list --paths uses custom name for path"
    setup_initialized_env
    export RU_LAYOUT="flat"

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list --paths 2>/dev/null)

    # Custom name should be used in path
    assert_stdout_contains "$stdout_output" "shortname" "Path uses custom name"

    cleanup_test_env
}

#==============================================================================
# Tests: URL Format Variations
#==============================================================================

test_list_https_url() {
    echo -e "${BLUE}Test:${RESET} ru list handles HTTPS URLs"
    setup_initialized_env

    "$RU_SCRIPT" add "https://github.com/owner/repo" >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)

    assert_stdout_contains "$stdout_output" "https://github.com/owner/repo" "Shows HTTPS URL"

    cleanup_test_env
}

test_list_mixed_url_formats() {
    echo -e "${BLUE}Test:${RESET} ru list handles mixed URL formats"
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat >> "$repos_file" <<'EOF'
owner1/repo1
https://github.com/owner2/repo2
git@github.com:owner3/repo3.git
EOF

    local stdout_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)

    assert_stdout_contains "$stdout_output" "owner1/repo1" "Shows shorthand format"
    assert_stdout_contains "$stdout_output" "https://github.com/owner2/repo2" "Shows HTTPS format"
    assert_stdout_contains "$stdout_output" "git@github.com:owner3/repo3.git" "Shows SSH format"
    assert_line_count "$stdout_output" 3 "Output has 3 lines for 3 repos"

    cleanup_test_env
}

#==============================================================================
# Tests: Multiple repos.d Files
#==============================================================================

test_list_multiple_repos_d_files() {
    echo -e "${BLUE}Test:${RESET} ru list aggregates from multiple repos.d files"
    setup_initialized_env

    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"

    # Create multiple repo files
    echo "owner1/repo1" > "$repos_dir/public.txt"
    echo "owner2/repo2" > "$repos_dir/private.txt"
    echo "owner3/repo3" > "$repos_dir/work.txt"

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)

    assert_stdout_contains "$stdout_output" "owner1/repo1" "Shows repo from public.txt"
    assert_stdout_contains "$stdout_output" "owner2/repo2" "Shows repo from private.txt"
    assert_stdout_contains "$stdout_output" "owner3/repo3" "Shows repo from work.txt"

    cleanup_test_env
}

#==============================================================================
# Tests: Stream Separation
#==============================================================================

test_list_stream_separation() {
    echo -e "${BLUE}Test:${RESET} ru list separates stdout and stderr correctly"
    setup_initialized_env

    "$RU_SCRIPT" add owner/repo >/dev/null 2>&1

    local stdout_output stderr_output
    stdout_output=$("$RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$RU_SCRIPT" list 2>&1 >/dev/null)

    # Stdout should have repo URLs only
    assert_stdout_contains "$stdout_output" "owner/repo" "Stdout has repo URL"
    assert_stdout_not_contains "$stdout_output" "Configured" "Stdout does not have info messages"

    # Stderr should have the info message
    assert_stderr_contains "$stderr_output" "Configured repositories" "Stderr has info message"

    cleanup_test_env
}

test_list_stdout_pipeable() {
    echo -e "${BLUE}Test:${RESET} ru list stdout is pipeable for scripting"
    setup_initialized_env

    "$RU_SCRIPT" add owner/repo1 owner/repo2 owner/repo3 >/dev/null 2>&1

    local count
    count=$("$RU_SCRIPT" list 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count" -eq 3 ]]; then
        pass "Stdout is cleanly pipeable (3 lines)"
    else
        fail "Stdout pipe count mismatch (expected 3, got $count)"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru list workflow"
echo "============================================"
echo ""

# Uninitialized/Empty states
test_list_uninitialized
echo ""
test_list_empty_repos_file
echo ""

# Basic list functionality
test_list_single_repo
echo ""
test_list_multiple_repos
echo ""

# --paths mode with different layouts
test_list_paths_mode_flat_layout
echo ""
test_list_paths_mode_owner_repo_layout
echo ""
test_list_paths_mode_full_layout
echo ""

# Repo spec variations
test_list_with_branch_spec
echo ""
test_list_with_custom_name
echo ""
test_list_paths_with_custom_name
echo ""

# URL format variations
test_list_https_url
echo ""
test_list_mixed_url_formats
echo ""

# Multiple repos.d files
test_list_multiple_repos_d_files
echo ""

# Stream separation
test_list_stream_separation
echo ""
test_list_stdout_pipeable
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
