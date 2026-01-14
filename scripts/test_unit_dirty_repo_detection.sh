#!/usr/bin/env bash
# Unit tests for dirty repo detection functions
# Tests: get_dirty_repos
# Covers: staged changes, unstaged changes, untracked files, --no-untracked, --json output
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

# Temporary directory for test setup
TEST_TEMP=""
# Configuration directory
TEST_CONFIG_DIR=""
# Projects directory
TEST_PROJECTS_DIR=""

#------------------------------------------------------------------------------
# Test Setup/Teardown
#------------------------------------------------------------------------------
setup() {
    TEST_TEMP=$(mktemp -d)
    TEST_CONFIG_DIR="$TEST_TEMP/config"
    TEST_PROJECTS_DIR="$TEST_TEMP/projects"

    mkdir -p "$TEST_CONFIG_DIR/repos.d"
    mkdir -p "$TEST_PROJECTS_DIR"

    # Extract required functions from ru
    extract_functions
}

cleanup() {
    [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}

extract_functions() {
    local ru_path="$SCRIPT_DIR/../ru"

    # Copy test stubs (provides logging, json_escape, dedupe_repos, etc.)
    cp "$SCRIPT_DIR/test_stubs.sh" "$TEST_TEMP/test_env.sh"

    # Extract functions using awk
    awk '/^parse_repo_spec\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
    awk '/^parse_repo_url\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
    awk '/^resolve_repo_spec\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
    awk '/^load_repo_list\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
    awk '/^get_all_repos\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
    awk '/^get_dirty_repos\(\)/,/^}$/' "$ru_path" >> "$TEST_TEMP/test_env.sh"
}

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

# Create a git repo with a specific state
# Usage: create_test_repo <name> [state]
# States: clean, staged, unstaged, untracked, all_dirty
# Note: With LAYOUT=flat, repos are at $PROJECTS_DIR/<repo_name> (no owner prefix)
create_test_repo() {
    local name="$1"
    local state="${2:-clean}"
    # Extract just the repo name for flat layout (remove owner/ prefix if present)
    local repo_name="${name##*/}"
    local repo_path="$TEST_PROJECTS_DIR/$repo_name"

    mkdir -p "$repo_path"
    git -C "$repo_path" init -q
    git -C "$repo_path" config user.email "test@example.com"
    git -C "$repo_path" config user.name "Test User"

    # Create initial commit so we have a valid repo
    echo "initial" > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    git -C "$repo_path" commit -q -m "Initial commit"

    case "$state" in
        clean)
            # Already clean
            ;;
        staged)
            echo "staged content" > "$repo_path/staged.txt"
            git -C "$repo_path" add staged.txt
            ;;
        unstaged)
            echo "modified" >> "$repo_path/README.md"
            ;;
        untracked)
            echo "untracked" > "$repo_path/untracked.txt"
            ;;
        all_dirty)
            # Staged
            echo "staged content" > "$repo_path/staged.txt"
            git -C "$repo_path" add staged.txt
            # Unstaged
            echo "modified" >> "$repo_path/README.md"
            # Untracked
            echo "untracked" > "$repo_path/untracked.txt"
            ;;
    esac

    echo "$repo_path"
}

# Add a repo to the test config
# Usage: add_repo_to_config <github_spec>
add_repo_to_config() {
    local spec="$1"
    echo "$spec" >> "$TEST_CONFIG_DIR/repos.d/test.txt"
}

# Run get_dirty_repos with test environment
# Usage: run_dirty_repos [args...]
run_dirty_repos() {
    (
        source "$TEST_TEMP/test_env.sh"
        export RU_CONFIG_DIR="$TEST_CONFIG_DIR"
        export PROJECTS_DIR="$TEST_PROJECTS_DIR"
        export LAYOUT="flat"
        get_dirty_repos "$@"
    )
}

# Check if a path is in the output
# Usage: assert_path_in_output <path> <output>
assert_path_in_output() {
    local path="$1"
    local output="$2"
    if [[ "$output" == *"$path"* ]]; then
        return 0
    else
        echo "Expected '$path' to be in output: $output" >&2
        return 1
    fi
}

# Check if a path is NOT in the output
# Usage: assert_path_not_in_output <path> <output>
assert_path_not_in_output() {
    local path="$1"
    local output="$2"
    if [[ "$output" != *"$path"* ]]; then
        return 0
    else
        echo "Expected '$path' NOT to be in output: $output" >&2
        return 1
    fi
}

#------------------------------------------------------------------------------
# Tests: Basic Functionality
#------------------------------------------------------------------------------

test_empty_config() {
    # No repos configured
    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_equals "" "$result" "Empty config should return empty output"
}

test_clean_repo_not_dirty() {
    create_test_repo "test-owner/clean-repo" "clean" >/dev/null
    add_repo_to_config "https://github.com/test-owner/clean-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_path_not_in_output "clean-repo" "$result"
}

test_staged_changes_is_dirty() {
    create_test_repo "test-owner/staged-repo" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/staged-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_path_in_output "staged-repo" "$result"
}

test_unstaged_changes_is_dirty() {
    create_test_repo "test-owner/unstaged-repo" "unstaged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/unstaged-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_path_in_output "unstaged-repo" "$result"
}

test_untracked_files_is_dirty_by_default() {
    create_test_repo "test-owner/untracked-repo" "untracked" >/dev/null
    add_repo_to_config "https://github.com/test-owner/untracked-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_path_in_output "untracked-repo" "$result"
}

test_all_dirty_states() {
    create_test_repo "test-owner/all-dirty" "all_dirty" >/dev/null
    add_repo_to_config "https://github.com/test-owner/all-dirty"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    assert_path_in_output "all-dirty" "$result"
}

#------------------------------------------------------------------------------
# Tests: --no-untracked Flag
#------------------------------------------------------------------------------

test_no_untracked_excludes_untracked() {
    create_test_repo "test-owner/only-untracked" "untracked" >/dev/null
    add_repo_to_config "https://github.com/test-owner/only-untracked"

    local result
    result=$(run_dirty_repos --no-untracked 2>/dev/null) || true

    assert_path_not_in_output "only-untracked" "$result"
}

test_no_untracked_keeps_staged() {
    create_test_repo "test-owner/staged-test" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/staged-test"

    local result
    result=$(run_dirty_repos --no-untracked 2>/dev/null) || true

    assert_path_in_output "staged-test" "$result"
}

test_no_untracked_keeps_unstaged() {
    create_test_repo "test-owner/unstaged-test" "unstaged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/unstaged-test"

    local result
    result=$(run_dirty_repos --no-untracked 2>/dev/null) || true

    assert_path_in_output "unstaged-test" "$result"
}

#------------------------------------------------------------------------------
# Tests: --json Output
#------------------------------------------------------------------------------

test_json_empty_output() {
    local result
    result=$(run_dirty_repos --json 2>/dev/null) || true

    assert_equals "[]" "$result" "Empty result should be empty JSON array"
}

test_json_single_dirty() {
    create_test_repo "test-owner/json-dirty" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/json-dirty"

    local result
    result=$(run_dirty_repos --json 2>/dev/null) || true

    # Validate JSON structure
    echo "$result" | jq -e '.' > /dev/null 2>&1
    assert_equals 0 $? "Output should be valid JSON"

    # Check array length
    local count
    count=$(echo "$result" | jq -r 'length')
    assert_equals "1" "$count" "Should have exactly one dirty repo"

    # Check path contains repo name
    local path
    path=$(echo "$result" | jq -r '.[0].path')
    assert_contains "$path" "json-dirty" "Path should contain repo name"

    # Check status
    local status
    status=$(echo "$result" | jq -r '.[0].status')
    assert_equals "dirty" "$status" "Status should be 'dirty'"
}

test_json_multiple_dirty() {
    create_test_repo "test-owner/json-dirty1" "staged" >/dev/null
    create_test_repo "test-owner/json-dirty2" "unstaged" >/dev/null
    create_test_repo "test-owner/json-clean" "clean" >/dev/null

    add_repo_to_config "https://github.com/test-owner/json-dirty1"
    add_repo_to_config "https://github.com/test-owner/json-dirty2"
    add_repo_to_config "https://github.com/test-owner/json-clean"

    local result
    result=$(run_dirty_repos --json 2>/dev/null) || true

    # Should have 2 dirty repos (not the clean one)
    local count
    count=$(echo "$result" | jq -r 'length')
    assert_equals "2" "$count" "Should have exactly two dirty repos"
}

test_json_with_no_untracked() {
    create_test_repo "test-owner/json-untracked" "untracked" >/dev/null
    create_test_repo "test-owner/json-staged" "staged" >/dev/null

    add_repo_to_config "https://github.com/test-owner/json-untracked"
    add_repo_to_config "https://github.com/test-owner/json-staged"

    local result
    result=$(run_dirty_repos --json --no-untracked 2>/dev/null) || true

    # Should only have staged (untracked excluded)
    local count
    count=$(echo "$result" | jq -r 'length')
    assert_equals "1" "$count" "Should have exactly one dirty repo with --no-untracked"

    local path
    path=$(echo "$result" | jq -r '.[0].path')
    assert_contains "$path" "json-staged" "Only staged repo should be included"
}

#------------------------------------------------------------------------------
# Tests: Edge Cases
#------------------------------------------------------------------------------

test_nonexistent_repo_skipped() {
    # Add a repo to config that doesn't exist on disk
    add_repo_to_config "https://github.com/test-owner/nonexistent-repo"

    # Also add a real dirty repo
    create_test_repo "test-owner/real-repo" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/real-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    # Should not fail, just skip the nonexistent one
    assert_path_not_in_output "nonexistent-repo" "$result"
    assert_path_in_output "real-repo" "$result"
}

test_not_git_repo_skipped() {
    # Create a directory that's not a git repo (using flat layout path)
    local not_git="$TEST_PROJECTS_DIR/not-a-git-repo"
    mkdir -p "$not_git"
    echo "not a git repo" > "$not_git/file.txt"

    add_repo_to_config "https://github.com/test-owner/not-a-git-repo"

    # Also add a real dirty repo
    create_test_repo "test-owner/git-repo" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/git-repo"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    # Should not fail, just skip the non-git directory
    assert_path_not_in_output "not-a-git-repo" "$result"
    assert_path_in_output "git-repo" "$result"
}

test_unknown_option_returns_error() {
    local exit_code=0
    run_dirty_repos --unknown-flag 2>/dev/null || exit_code=$?

    assert_equals 4 "$exit_code" "Unknown option should return exit code 4"
}

#------------------------------------------------------------------------------
# Tests: Return Value
#------------------------------------------------------------------------------

test_return_true_when_dirty_found() {
    create_test_repo "test-owner/dirty" "staged" >/dev/null
    add_repo_to_config "https://github.com/test-owner/dirty"

    local exit_code=0
    run_dirty_repos >/dev/null 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should return 0 (true) when dirty repos found"
}

test_return_false_when_no_dirty() {
    create_test_repo "test-owner/clean" "clean" >/dev/null
    add_repo_to_config "https://github.com/test-owner/clean"

    local exit_code=0
    run_dirty_repos >/dev/null 2>&1 || exit_code=$?

    assert_equals 1 "$exit_code" "Should return 1 (false) when no dirty repos found"
}

test_return_false_for_empty_config() {
    local exit_code=0
    run_dirty_repos >/dev/null 2>&1 || exit_code=$?

    assert_equals 1 "$exit_code" "Should return 1 (false) for empty config"
}

#------------------------------------------------------------------------------
# Tests: Mixed Scenarios
#------------------------------------------------------------------------------

test_mixed_clean_and_dirty_repos() {
    create_test_repo "test-owner/mix-clean1" "clean" >/dev/null
    create_test_repo "test-owner/mix-dirty1" "staged" >/dev/null
    create_test_repo "test-owner/mix-clean2" "clean" >/dev/null
    create_test_repo "test-owner/mix-dirty2" "unstaged" >/dev/null
    create_test_repo "test-owner/mix-untracked" "untracked" >/dev/null

    add_repo_to_config "https://github.com/test-owner/mix-clean1"
    add_repo_to_config "https://github.com/test-owner/mix-dirty1"
    add_repo_to_config "https://github.com/test-owner/mix-clean2"
    add_repo_to_config "https://github.com/test-owner/mix-dirty2"
    add_repo_to_config "https://github.com/test-owner/mix-untracked"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    # Check dirty repos are included
    assert_path_in_output "mix-dirty1" "$result"
    assert_path_in_output "mix-dirty2" "$result"
    assert_path_in_output "mix-untracked" "$result"

    # Check clean repos are excluded
    assert_path_not_in_output "mix-clean1" "$result"
    assert_path_not_in_output "mix-clean2" "$result"
}

test_output_format_one_per_line() {
    create_test_repo "test-owner/line1" "staged" >/dev/null
    create_test_repo "test-owner/line2" "unstaged" >/dev/null

    add_repo_to_config "https://github.com/test-owner/line1"
    add_repo_to_config "https://github.com/test-owner/line2"

    local result
    result=$(run_dirty_repos 2>/dev/null) || true

    # Count lines
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    assert_equals "2" "$line_count" "Should have 2 lines for 2 dirty repos"
}

#------------------------------------------------------------------------------
# Main Test Runner
#------------------------------------------------------------------------------

# Run each test in isolation with fresh setup
run_isolated_test() {
    local test_name="$1"
    setup
    local result=0
    $test_name || result=$?
    cleanup
    return $result
}

# Collect all test functions
TESTS=(
    # Basic functionality
    test_empty_config
    test_clean_repo_not_dirty
    test_staged_changes_is_dirty
    test_unstaged_changes_is_dirty
    test_untracked_files_is_dirty_by_default
    test_all_dirty_states

    # --no-untracked flag
    test_no_untracked_excludes_untracked
    test_no_untracked_keeps_staged
    test_no_untracked_keeps_unstaged

    # --json output
    test_json_empty_output
    test_json_single_dirty
    test_json_multiple_dirty
    test_json_with_no_untracked

    # Edge cases
    test_nonexistent_repo_skipped
    test_not_git_repo_skipped
    test_unknown_option_returns_error

    # Return value
    test_return_true_when_dirty_found
    test_return_false_when_no_dirty
    test_return_false_for_empty_config

    # Mixed scenarios
    test_mixed_clean_and_dirty_repos
    test_output_format_one_per_line
)

main() {
    echo "Running dirty repo detection tests..."
    echo "========================================"

    local passed=0
    local failed=0
    local total=${#TESTS[@]}

    for test_name in "${TESTS[@]}"; do
        if run_isolated_test "$test_name"; then
            echo "PASS: $test_name"
            ((passed++)) || true
        else
            echo "FAIL: $test_name"
            ((failed++)) || true
        fi
    done

    echo "========================================"
    echo "Results: $passed/$total passed, $failed failed"

    [[ $failed -eq 0 ]]
}

main "$@"
