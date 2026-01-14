#!/usr/bin/env bash
#
# E2E Test: ru add/remove workflow
# Tests adding and removing repositories from the config
#
# Test coverage:
#   - ru add adds repos to public.txt
#   - ru add validates repo format
#   - ru add detects duplicates
#   - ru add supports multiple repos at once
#   - ru list shows configured repos
#   - ru list --paths shows local paths
#   - ru remove removes repos from public.txt
#   - ru remove matches by owner/repo (not substring)
#   - ru remove handles not-found gracefully
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
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"
    # Initialize config
    "$RU_SCRIPT" init >/dev/null 2>&1
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

assert_file_not_contains() {
    local path="$1"
    local pattern="$2"
    local msg="$3"
    if [[ -f "$path" ]] && ! grep -q "$pattern" "$path"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' should not be in $path)"
    fi
}

#==============================================================================
# Tests: ru add
#==============================================================================

test_add_single_repo() {
    echo "Test: ru add adds a single repo"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    local output
    output=$("$RU_SCRIPT" add owner/repo 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru add exits with code 0"
    assert_output_contains "$output" "Added" "Output confirms repo added"
    assert_file_contains "$repos_file" "owner/repo" "public.txt contains the repo"

    cleanup_test_env
}

test_add_multiple_repos() {
    echo "Test: ru add adds multiple repos at once"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$RU_SCRIPT" add cli/cli charmbracelet/gum koalaman/shellcheck 2>&1

    assert_file_contains "$repos_file" "cli/cli" "public.txt contains cli/cli"
    assert_file_contains "$repos_file" "charmbracelet/gum" "public.txt contains charmbracelet/gum"
    assert_file_contains "$repos_file" "koalaman/shellcheck" "public.txt contains koalaman/shellcheck"

    cleanup_test_env
}

test_add_duplicate_repo() {
    echo "Test: ru add detects duplicate repos"
    setup_test_env

    "$RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$RU_SCRIPT" add owner/repo 2>&1)

    assert_output_contains "$output" "Already configured" "Duplicate is detected"

    cleanup_test_env
}

test_add_invalid_format() {
    echo "Test: ru add rejects invalid repo format"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" add "invalid-format" 2>&1)

    assert_output_contains "$output" "Invalid" "Invalid format is rejected"

    cleanup_test_env
}

test_add_https_url() {
    echo "Test: ru add accepts HTTPS URL format"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$RU_SCRIPT" add "https://github.com/owner/repo" 2>&1

    assert_file_contains "$repos_file" "https://github.com/owner/repo" "HTTPS URL is added"

    cleanup_test_env
}

test_add_no_args() {
    echo "Test: ru add with no args shows usage"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" add 2>&1)
    local exit_code=$?

    assert_exit_code 4 "$exit_code" "ru add with no args exits with code 4"
    assert_output_contains "$output" "Usage" "Shows usage message"

    cleanup_test_env
}

#==============================================================================
# Tests: ru list
#==============================================================================

test_list_shows_repos() {
    echo "Test: ru list shows configured repos"
    setup_test_env

    "$RU_SCRIPT" add owner/repo1 owner/repo2 2>&1

    local output
    output=$("$RU_SCRIPT" list 2>&1)

    assert_output_contains "$output" "owner/repo1" "list shows repo1"
    assert_output_contains "$output" "owner/repo2" "list shows repo2"

    cleanup_test_env
}

test_list_empty() {
    echo "Test: ru list handles empty config"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" list 2>&1)

    assert_output_contains "$output" "No repositories configured" "Empty list message shown"

    cleanup_test_env
}

test_list_paths_mode() {
    echo "Test: ru list --paths shows local paths"
    setup_test_env

    "$RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$RU_SCRIPT" list --paths 2>&1)

    # Should show a path containing the repo name
    assert_output_contains "$output" "repo" "Path output contains repo name"

    cleanup_test_env
}

#==============================================================================
# Tests: ru remove
#==============================================================================

test_remove_single_repo() {
    echo "Test: ru remove removes a repo"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$RU_SCRIPT" remove owner/repo 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru remove exits with code 0"
    assert_output_contains "$output" "Removed" "Output confirms repo removed"
    assert_file_not_contains "$repos_file" "^owner/repo$" "public.txt no longer contains the repo"

    cleanup_test_env
}

test_remove_not_found() {
    echo "Test: ru remove handles not-found gracefully"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" remove nonexistent/repo 2>&1)
    local exit_code=$?

    assert_exit_code 1 "$exit_code" "ru remove exits with code 1 for not found"
    assert_output_contains "$output" "Not found" "Not found message shown"

    cleanup_test_env
}

test_remove_no_substring_match() {
    echo "Test: ru remove matches exactly (not substring)"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    # Add two repos with similar names
    "$RU_SCRIPT" add owner/repo owner/repo-extra 2>&1

    # Remove only owner/repo
    "$RU_SCRIPT" remove owner/repo 2>&1

    # owner/repo-extra should still be present
    assert_file_contains "$repos_file" "owner/repo-extra" "repo-extra still present after removing repo"

    cleanup_test_env
}

test_remove_no_args() {
    echo "Test: ru remove with no args shows usage"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" remove 2>&1)
    local exit_code=$?

    assert_exit_code 4 "$exit_code" "ru remove with no args exits with code 4"
    assert_output_contains "$output" "Usage" "Shows usage message"

    cleanup_test_env
}

test_remove_preserves_comments() {
    echo "Test: ru remove preserves comments in public.txt"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$RU_SCRIPT" add owner/repo 2>&1

    # Add a comment manually
    echo "# My custom comment" >> "$repos_file"

    "$RU_SCRIPT" remove owner/repo 2>&1

    assert_file_contains "$repos_file" "My custom comment" "Comments are preserved"

    cleanup_test_env
}

#==============================================================================
# Tests: Private repos (--private flag)
#==============================================================================

test_add_private_repo() {
    echo "Test: ru add --private adds to private.txt"
    setup_test_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    local output
    output=$("$RU_SCRIPT" add --private secret/repo 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru add --private exits with code 0"
    assert_output_contains "$output" "Added" "Output confirms repo added"
    assert_output_contains "$output" "private" "Output mentions private"
    assert_file_not_contains "$repos_file" "secret/repo" "public.txt does NOT contain the private repo"

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        pass "private.txt contains the private repo"
    else
        fail "private.txt should contain secret/repo"
    fi

    cleanup_test_env
}

test_list_public_filter() {
    echo "Test: ru list --public shows only public repos"
    setup_test_env

    "$RU_SCRIPT" add public/repo1 public/repo2 2>&1
    "$RU_SCRIPT" add --private private/repo 2>&1

    local output
    output=$("$RU_SCRIPT" list --public 2>&1)

    assert_output_contains "$output" "public/repo1" "Shows public repo1"
    assert_output_contains "$output" "public/repo2" "Shows public repo2"
    if printf '%s\n' "$output" | grep -q "private/repo"; then
        fail "list --public should not show private repo"
    else
        pass "list --public excludes private repo"
    fi

    cleanup_test_env
}

test_list_private_filter() {
    echo "Test: ru list --private shows only private repos"
    setup_test_env

    "$RU_SCRIPT" add public/repo 2>&1
    "$RU_SCRIPT" add --private private/repo1 private/repo2 2>&1

    local output
    output=$("$RU_SCRIPT" list --private 2>&1)

    assert_output_contains "$output" "private/repo1" "Shows private repo1"
    assert_output_contains "$output" "private/repo2" "Shows private repo2"
    if printf '%s\n' "$output" | grep -q "public/repo"; then
        fail "list --private should not show public repo"
    else
        pass "list --private excludes public repo"
    fi

    cleanup_test_env
}

test_remove_from_private() {
    echo "Test: ru remove can remove from private.txt"
    setup_test_env

    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    "$RU_SCRIPT" add --private secret/repo 2>&1

    local output
    output=$("$RU_SCRIPT" remove secret/repo 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "ru remove exits with code 0 for private repo"
    assert_output_contains "$output" "Removed" "Output confirms repo removed"
    assert_output_contains "$output" "private" "Output mentions it was from private"

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        fail "private.txt should no longer contain secret/repo"
    else
        pass "secret/repo removed from private.txt"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru add/remove workflow"
echo "============================================"
echo ""

# ru add tests
test_add_single_repo
echo ""
test_add_multiple_repos
echo ""
test_add_duplicate_repo
echo ""
test_add_invalid_format
echo ""
test_add_https_url
echo ""
test_add_no_args
echo ""

# ru list tests
test_list_shows_repos
echo ""
test_list_empty
echo ""
test_list_paths_mode
echo ""

# ru remove tests
test_remove_single_repo
echo ""
test_remove_not_found
echo ""
test_remove_no_substring_match
echo ""
test_remove_no_args
echo ""
test_remove_preserves_comments
echo ""

# Private repo tests
test_add_private_repo
echo ""
test_list_public_filter
echo ""
test_list_private_filter
echo ""
test_remove_from_private
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
