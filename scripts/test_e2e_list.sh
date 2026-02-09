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
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Helpers
#==============================================================================

setup_initialized_env() {
    e2e_setup
    mkdir -p "$RU_PROJECTS_DIR"
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
}

assert_line_count() {
    local output="$1"
    local expected="$2"
    local msg="$3"
    local actual
    actual=$(printf '%s\n' "$output" | grep -c -v '^$' || true)
    assert_equals "$expected" "$actual" "$msg"
}

#==============================================================================
# Tests: Uninitialized/Empty States
#==============================================================================

test_list_uninitialized() {
    e2e_setup
    # Remove pre-created config to simulate uninitialized state
    rm -rf "$XDG_CONFIG_HOME/ru"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" list 2>&1 >/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0 for uninitialized"
    assert_contains "$stderr_output" "No configuration found" "Shows no config message"

    e2e_cleanup
}

test_list_empty_repos_file() {
    setup_initialized_env

    # Clear the repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "# Empty repos file" > "$repos_file"

    local stderr_output exit_code=0
    stderr_output=$("$E2E_RU_SCRIPT" list 2>&1 >/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0 for empty repos"
    assert_contains "$stderr_output" "No repositories configured" "Shows no repos message"

    e2e_cleanup
}

#==============================================================================
# Tests: Basic List Functionality
#==============================================================================

test_list_single_repo() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add owner/repo >/dev/null 2>&1

    local stdout_output stderr_output exit_code=0
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null) || exit_code=$?
    stderr_output=$("$E2E_RU_SCRIPT" list 2>&1 >/dev/null)

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stdout_output" "owner/repo" "Stdout contains repo URL"
    assert_contains "$stderr_output" "(1)" "Stderr shows count of 1"

    e2e_cleanup
}

test_list_multiple_repos() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add cli/cli charmbracelet/gum koalaman/shellcheck >/dev/null 2>&1

    local stdout_output stderr_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$E2E_RU_SCRIPT" list 2>&1 >/dev/null)

    assert_contains "$stdout_output" "cli/cli" "Shows cli/cli"
    assert_contains "$stdout_output" "charmbracelet/gum" "Shows charmbracelet/gum"
    assert_contains "$stdout_output" "koalaman/shellcheck" "Shows koalaman/shellcheck"
    assert_contains "$stderr_output" "(3)" "Stderr shows count of 3"
    assert_line_count "$stdout_output" 3 "Output has 3 lines"

    e2e_cleanup
}

#==============================================================================
# Tests: --paths Mode
#==============================================================================

test_list_paths_mode_flat_layout() {
    setup_initialized_env
    export RU_LAYOUT="flat"

    "$E2E_RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list --paths 2>/dev/null)

    assert_contains "$stdout_output" "myrepo" "Path contains repo name"
    assert_contains "$stdout_output" "$RU_PROJECTS_DIR" "Path includes projects dir"

    unset RU_LAYOUT
    e2e_cleanup
}

test_list_paths_mode_owner_repo_layout() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    "$E2E_RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list --paths 2>/dev/null)

    assert_contains "$stdout_output" "owner/myrepo" "Path contains owner/repo"
    assert_contains "$stdout_output" "$RU_PROJECTS_DIR" "Path includes projects dir"

    unset RU_LAYOUT
    e2e_cleanup
}

test_list_paths_mode_full_layout() {
    setup_initialized_env
    export RU_LAYOUT="full"

    "$E2E_RU_SCRIPT" add owner/myrepo >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list --paths 2>/dev/null)

    assert_contains "$stdout_output" "github.com" "Path contains github.com"
    assert_contains "$stdout_output" "owner/myrepo" "Path contains owner/repo"

    unset RU_LAYOUT
    e2e_cleanup
}

#==============================================================================
# Tests: Repo Spec Variations
#==============================================================================

test_list_with_branch_spec() {
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/repo@develop" >> "$repos_file"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)

    assert_contains "$stdout_output" "owner/repo" "Shows repo URL (without branch in output)"

    e2e_cleanup
}

test_list_with_custom_name() {
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)

    assert_contains "$stdout_output" "owner/long-repository-name" "Shows original repo URL"

    e2e_cleanup
}

test_list_paths_with_custom_name() {
    setup_initialized_env
    export RU_LAYOUT="flat"

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list --paths 2>/dev/null)

    assert_contains "$stdout_output" "shortname" "Path uses custom name"

    unset RU_LAYOUT
    e2e_cleanup
}

#==============================================================================
# Tests: URL Format Variations
#==============================================================================

test_list_https_url() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add "https://github.com/owner/repo" >/dev/null 2>&1

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)

    assert_contains "$stdout_output" "https://github.com/owner/repo" "Shows HTTPS URL"

    e2e_cleanup
}

test_list_mixed_url_formats() {
    setup_initialized_env

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat >> "$repos_file" <<'EOF'
owner1/repo1
https://github.com/owner2/repo2
git@github.com:owner3/repo3.git
EOF

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)

    assert_contains "$stdout_output" "owner1/repo1" "Shows shorthand format"
    assert_contains "$stdout_output" "https://github.com/owner2/repo2" "Shows HTTPS format"
    assert_contains "$stdout_output" "git@github.com:owner3/repo3.git" "Shows SSH format"
    assert_line_count "$stdout_output" 3 "Output has 3 lines for 3 repos"

    e2e_cleanup
}

#==============================================================================
# Tests: Multiple repos.d Files
#==============================================================================

test_list_multiple_repos_d_files() {
    setup_initialized_env

    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"

    echo "owner1/repo1" > "$repos_dir/public.txt"
    echo "owner2/repo2" > "$repos_dir/private.txt"
    echo "owner3/repo3" > "$repos_dir/work.txt"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)

    assert_contains "$stdout_output" "owner1/repo1" "Shows repo from public.txt"
    assert_contains "$stdout_output" "owner2/repo2" "Shows repo from private.txt"
    assert_contains "$stdout_output" "owner3/repo3" "Shows repo from work.txt"

    e2e_cleanup
}

#==============================================================================
# Tests: Stream Separation
#==============================================================================

test_list_stream_separation() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add owner/repo >/dev/null 2>&1

    local stdout_output stderr_output
    stdout_output=$("$E2E_RU_SCRIPT" list 2>/dev/null)
    stderr_output=$("$E2E_RU_SCRIPT" list 2>&1 >/dev/null)

    assert_contains "$stdout_output" "owner/repo" "Stdout has repo URL"
    assert_not_contains "$stdout_output" "Configured" "Stdout does not have info messages"
    assert_contains "$stderr_output" "Configured repositories" "Stderr has info message"

    e2e_cleanup
}

test_list_stdout_pipeable() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add owner/repo1 owner/repo2 owner/repo3 >/dev/null 2>&1

    local count
    count=$("$E2E_RU_SCRIPT" list 2>/dev/null | wc -l | tr -d ' ')

    assert_equals "3" "$count" "Stdout is cleanly pipeable (3 lines)"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_list_uninitialized
run_test test_list_empty_repos_file
run_test test_list_single_repo
run_test test_list_multiple_repos
run_test test_list_paths_mode_flat_layout
run_test test_list_paths_mode_owner_repo_layout
run_test test_list_paths_mode_full_layout
run_test test_list_with_branch_spec
run_test test_list_with_custom_name
run_test test_list_paths_with_custom_name
run_test test_list_https_url
run_test test_list_mixed_url_formats
run_test test_list_multiple_repos_d_files
run_test test_list_stream_separation
run_test test_list_stdout_pipeable

print_results
