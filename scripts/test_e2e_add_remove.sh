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
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Tests: ru add
#==============================================================================

test_add_single_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    # Initialize config
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add owner/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru add exits with code 0"
    assert_contains "$output" "Added" "Output confirms repo added"
    assert_file_contains "$repos_file" "owner/repo" "public.txt contains the repo"

    e2e_cleanup
}

test_add_multiple_repos() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add cli/cli charmbracelet/gum koalaman/shellcheck 2>&1

    assert_file_contains "$repos_file" "cli/cli" "public.txt contains cli/cli"
    assert_file_contains "$repos_file" "charmbracelet/gum" "public.txt contains charmbracelet/gum"
    assert_file_contains "$repos_file" "koalaman/shellcheck" "public.txt contains koalaman/shellcheck"

    e2e_cleanup
}

test_add_duplicate_repo() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" add owner/repo 2>&1)

    assert_contains "$output" "Already configured" "Duplicate is detected"

    e2e_cleanup
}

test_add_invalid_format() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" add "invalid-format" 2>&1)

    assert_contains "$output" "Invalid" "Invalid format is rejected"

    e2e_cleanup
}

test_add_https_url() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add "https://github.com/owner/repo" 2>&1

    assert_file_contains "$repos_file" "https://github.com/owner/repo" "HTTPS URL is added"

    e2e_cleanup
}

test_add_no_args() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add 2>&1) || exit_code=$?

    assert_equals "4" "$exit_code" "ru add with no args exits with code 4"
    assert_contains "$output" "Usage" "Shows usage message"

    e2e_cleanup
}

#==============================================================================
# Tests: ru list
#==============================================================================

test_list_shows_repos() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo1 owner/repo2 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list 2>&1)

    assert_contains "$output" "owner/repo1" "list shows repo1"
    assert_contains "$output" "owner/repo2" "list shows repo2"

    e2e_cleanup
}

test_list_empty() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list 2>&1)

    assert_contains "$output" "No repositories configured" "Empty list message shown"

    e2e_cleanup
}

test_list_paths_mode() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --paths 2>&1)

    # Should show a path containing the repo name
    assert_contains "$output" "repo" "Path output contains repo name"

    e2e_cleanup
}

#==============================================================================
# Tests: ru remove
#==============================================================================

test_remove_single_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove owner/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru remove exits with code 0"
    assert_contains "$output" "Removed" "Output confirms repo removed"
    if [[ -f "$repos_file" ]] && ! grep -q "^owner/repo$" "$repos_file"; then
        pass "public.txt no longer contains the repo"
    else
        fail "public.txt no longer contains the repo"
    fi

    e2e_cleanup
}

test_remove_not_found() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove nonexistent/repo 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "ru remove exits with code 1 for not found"
    assert_contains "$output" "Not found" "Not found message shown"

    e2e_cleanup
}

test_remove_no_substring_match() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    # Add two repos with similar names
    "$E2E_RU_SCRIPT" add owner/repo owner/repo-extra 2>&1

    # Remove only owner/repo
    "$E2E_RU_SCRIPT" remove owner/repo 2>&1

    # owner/repo-extra should still be present
    assert_file_contains "$repos_file" "owner/repo-extra" "repo-extra still present after removing repo"

    e2e_cleanup
}

test_remove_no_args() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove 2>&1) || exit_code=$?

    assert_equals "4" "$exit_code" "ru remove with no args exits with code 4"
    assert_contains "$output" "Usage" "Shows usage message"

    e2e_cleanup
}

test_remove_preserves_comments() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    # Add a comment manually
    echo "# My custom comment" >> "$repos_file"

    "$E2E_RU_SCRIPT" remove owner/repo 2>&1

    assert_file_contains "$repos_file" "My custom comment" "Comments are preserved"

    e2e_cleanup
}

#==============================================================================
# Tests: Private repos (--private flag)
#==============================================================================

test_add_private_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add --private secret/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru add --private exits with code 0"
    assert_contains "$output" "Added" "Output confirms repo added"
    assert_contains "$output" "private" "Output mentions private"
    if [[ -f "$repos_file" ]] && ! grep -q "secret/repo" "$repos_file"; then
        pass "public.txt does NOT contain the private repo"
    else
        fail "public.txt does NOT contain the private repo"
    fi

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        pass "private.txt contains the private repo"
    else
        fail "private.txt should contain secret/repo"
    fi

    e2e_cleanup
}

test_list_public_filter() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add public/repo1 public/repo2 2>&1
    "$E2E_RU_SCRIPT" add --private private/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --public 2>&1)

    assert_contains "$output" "public/repo1" "Shows public repo1"
    assert_contains "$output" "public/repo2" "Shows public repo2"
    assert_not_contains "$output" "private/repo" "list --public excludes private repo"

    e2e_cleanup
}

test_list_private_filter() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add public/repo 2>&1
    "$E2E_RU_SCRIPT" add --private private/repo1 private/repo2 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --private 2>&1)

    assert_contains "$output" "private/repo1" "Shows private repo1"
    assert_contains "$output" "private/repo2" "Shows private repo2"
    assert_not_contains "$output" "public/repo" "list --private excludes public repo"

    e2e_cleanup
}

test_remove_from_private() {
    e2e_setup

    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add --private secret/repo 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove secret/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru remove exits with code 0 for private repo"
    assert_contains "$output" "Removed" "Output confirms repo removed"
    assert_contains "$output" "private" "Output mentions it was from private"

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        fail "private.txt should no longer contain secret/repo"
    else
        pass "secret/repo removed from private.txt"
    fi

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_add_single_repo
run_test test_add_multiple_repos
run_test test_add_duplicate_repo
run_test test_add_invalid_format
run_test test_add_https_url
run_test test_add_no_args
run_test test_list_shows_repos
run_test test_list_empty
run_test test_list_paths_mode
run_test test_remove_single_repo
run_test test_remove_not_found
run_test test_remove_no_substring_match
run_test test_remove_no_args
run_test test_remove_preserves_comments
run_test test_add_private_repo
run_test test_list_public_filter
run_test test_list_private_filter
run_test test_remove_from_private

print_results
