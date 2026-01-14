#!/usr/bin/env bash
#
# Unit tests: Repo list management functions
#
# Tests for load_repo_list, parse_repo_spec, dedupe_repos, detect_collisions.
# Uses the test framework for assertions and isolation.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source the functions we need to test
source_ru_function "_is_safe_path_segment"
source_ru_function "load_repo_list"
source_ru_function "parse_repo_spec"
source_ru_function "parse_repo_url"
source_ru_function "resolve_repo_spec"
source_ru_function "url_to_local_path"
source_ru_function "dedupe_repos"
source_ru_function "detect_collisions"

# Stub logging functions for testing
log_verbose() { :; }
log_warn() { echo "WARN: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

#==============================================================================
# Tests: load_repo_list
#==============================================================================

test_load_repo_list_basic() {
    local test_name="load_repo_list reads basic file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local list_file="$test_env/repos.txt"
    cat > "$list_file" << 'EOF'
owner/repo1
owner/repo2
owner/repo3
EOF

    local result
    result=$(load_repo_list "$list_file")

    assert_contains "$result" "owner/repo1" "Should contain repo1"
    assert_contains "$result" "owner/repo2" "Should contain repo2"
    assert_contains "$result" "owner/repo3" "Should contain repo3"

    log_test_pass "$test_name"
}

test_load_repo_list_skips_comments() {
    local test_name="load_repo_list skips comment lines"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local list_file="$test_env/repos.txt"
    cat > "$list_file" << 'EOF'
# This is a comment
owner/repo1
  # Indented comment
owner/repo2
EOF

    local result
    result=$(load_repo_list "$list_file")

    assert_contains "$result" "owner/repo1" "Should contain repo1"
    assert_contains "$result" "owner/repo2" "Should contain repo2"
    assert_not_contains "$result" "#" "Should not contain comments"

    log_test_pass "$test_name"
}

test_load_repo_list_skips_empty_lines() {
    local test_name="load_repo_list skips empty lines"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local list_file="$test_env/repos.txt"
    cat > "$list_file" << 'EOF'
owner/repo1

owner/repo2

EOF

    local result
    result=$(load_repo_list "$list_file")
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    assert_equals "2" "$line_count" "Should have 2 lines (no empty lines)"

    log_test_pass "$test_name"
}

test_load_repo_list_trims_whitespace() {
    local test_name="load_repo_list trims whitespace"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local list_file="$test_env/repos.txt"
    cat > "$list_file" << 'EOF'
  owner/repo1
	owner/repo2
   owner/repo3
EOF

    local result
    result=$(load_repo_list "$list_file")

    # Check exact matches (no leading/trailing whitespace)
    local first_line
    first_line=$(echo "$result" | head -1)
    assert_equals "owner/repo1" "$first_line" "First line should be trimmed"

    log_test_pass "$test_name"
}

test_load_repo_list_nonexistent_file() {
    local test_name="load_repo_list handles nonexistent file gracefully"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local result
    result=$(load_repo_list "$test_env/nonexistent.txt")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 for nonexistent file"
    assert_equals "" "$result" "Should return empty string"

    log_test_pass "$test_name"
}

test_load_repo_list_with_branch_and_name() {
    local test_name="load_repo_list preserves branch and name syntax"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local list_file="$test_env/repos.txt"
    cat > "$list_file" << 'EOF'
owner/repo@develop
owner/other as myname
owner/full@main as custom
EOF

    local result
    result=$(load_repo_list "$list_file")

    assert_contains "$result" "owner/repo@develop" "Should preserve @branch syntax"
    assert_contains "$result" "owner/other as myname" "Should preserve 'as name' syntax"
    assert_contains "$result" "owner/full@main as custom" "Should preserve combined syntax"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: parse_repo_spec
#==============================================================================

test_parse_repo_spec_basic() {
    local test_name="parse_repo_spec parses basic owner/repo"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "owner/repo" url branch local_name

    assert_equals "owner/repo" "$url" "URL should be owner/repo"
    assert_equals "" "$branch" "Branch should be empty"
    assert_equals "" "$local_name" "Local name should be empty"

    log_test_pass "$test_name"
}

test_parse_repo_spec_with_branch() {
    local test_name="parse_repo_spec parses @branch"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "owner/repo@develop" url branch local_name

    assert_equals "owner/repo" "$url" "URL should be owner/repo"
    assert_equals "develop" "$branch" "Branch should be develop"
    assert_equals "" "$local_name" "Local name should be empty"

    log_test_pass "$test_name"
}

test_parse_repo_spec_with_local_name() {
    local test_name="parse_repo_spec parses 'as name'"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "owner/repo as myname" url branch local_name

    assert_equals "owner/repo" "$url" "URL should be owner/repo"
    assert_equals "" "$branch" "Branch should be empty"
    assert_equals "myname" "$local_name" "Local name should be myname"

    log_test_pass "$test_name"
}

test_parse_repo_spec_combined() {
    local test_name="parse_repo_spec parses @branch as name"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "owner/repo@main as custom" url branch local_name

    assert_equals "owner/repo" "$url" "URL should be owner/repo"
    assert_equals "main" "$branch" "Branch should be main"
    assert_equals "custom" "$local_name" "Local name should be custom"

    log_test_pass "$test_name"
}

test_parse_repo_spec_https_url() {
    local test_name="parse_repo_spec handles HTTPS URLs"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "https://github.com/owner/repo" url branch local_name

    assert_equals "https://github.com/owner/repo" "$url" "URL should be preserved"
    assert_equals "" "$branch" "Branch should be empty"
    assert_equals "" "$local_name" "Local name should be empty"

    log_test_pass "$test_name"
}

test_parse_repo_spec_ssh_url() {
    local test_name="parse_repo_spec handles SSH URLs (no branch confusion)"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "git@github.com:owner/repo" url branch local_name

    # The @ in SSH URLs should NOT be confused with branch syntax
    assert_equals "git@github.com:owner/repo" "$url" "URL should be preserved"
    assert_equals "" "$branch" "Branch should be empty (not github.com:owner/repo)"

    log_test_pass "$test_name"
}

test_parse_repo_spec_https_with_branch() {
    local test_name="parse_repo_spec handles HTTPS URL with branch"
    log_test_start "$test_name"

    local url branch local_name
    parse_repo_spec "https://github.com/owner/repo@feature" url branch local_name

    assert_equals "https://github.com/owner/repo" "$url" "URL should be HTTPS URL"
    assert_equals "feature" "$branch" "Branch should be feature"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: dedupe_repos
#==============================================================================

test_dedupe_repos_removes_duplicates() {
    local test_name="dedupe_repos removes duplicate paths"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Set required globals
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local input result
    input=$(cat << 'EOF'
owner/repo
owner/repo
owner/repo
EOF
)
    result=$(echo "$input" | dedupe_repos)
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    assert_equals "1" "$line_count" "Should have only 1 line after dedup"
    assert_contains "$result" "owner/repo" "Should contain owner/repo"

    log_test_pass "$test_name"
}

test_dedupe_repos_keeps_different_repos() {
    local test_name="dedupe_repos keeps different repos"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local input result
    input=$(cat << 'EOF'
owner/repo1
owner/repo2
other/repo3
EOF
)
    result=$(echo "$input" | dedupe_repos)
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    assert_equals "3" "$line_count" "Should have 3 unique repos"

    log_test_pass "$test_name"
}

test_dedupe_repos_first_wins() {
    local test_name="dedupe_repos first occurrence wins"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local input result
    input=$(cat << 'EOF'
owner/repo@main
owner/repo@develop
EOF
)
    result=$(echo "$input" | dedupe_repos)

    assert_contains "$result" "owner/repo@main" "First occurrence (main branch) should win"
    assert_not_contains "$result" "develop" "Second occurrence should be dropped"

    log_test_pass "$test_name"
}

test_dedupe_repos_custom_names_differ() {
    local test_name="dedupe_repos respects custom names (different paths)"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local input result
    input=$(cat << 'EOF'
owner/repo as name1
owner/repo as name2
EOF
)
    result=$(echo "$input" | dedupe_repos)
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    # Custom names create different paths, so both should be kept
    assert_equals "2" "$line_count" "Both should be kept (different paths)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: detect_collisions
#==============================================================================

test_detect_collisions_no_collision() {
    local test_name="detect_collisions returns 0 when no collisions"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local input
    input=$(cat << 'EOF'
owner/repo1
owner/repo2
other/repo3
EOF
)
    if echo "$input" | detect_collisions 2>/dev/null; then
        assert_true "true" "Should return 0 when no collisions"
    else
        log_test_fail "$test_name" "Unexpected failure - no collisions should exist"
        return 1
    fi

    log_test_pass "$test_name"
}

test_detect_collisions_same_repo_no_collision() {
    local test_name="detect_collisions ignores same repo duplicates"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    # Same repo twice is not a collision (will be deduped)
    local input
    input=$(cat << 'EOF'
owner/repo
owner/repo
EOF
)
    if echo "$input" | detect_collisions 2>/dev/null; then
        assert_true "true" "Same repo is not a collision"
    else
        log_test_fail "$test_name" "Same repo should not be a collision"
        return 1
    fi

    log_test_pass "$test_name"
}

test_detect_collisions_flat_layout_collision() {
    local test_name="detect_collisions detects flat layout collisions"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    # In flat layout, different owners with same repo name collide
    local input
    input=$(cat << 'EOF'
owner1/myrepo
owner2/myrepo
EOF
)
    local stderr_output
    if stderr_output=$(echo "$input" | detect_collisions 2>&1); then
        log_test_fail "$test_name" "Should detect collision in flat layout"
        return 1
    else
        assert_contains "$stderr_output" "Collision" "Should report collision"
        assert_true "true" "Collision detected as expected"
    fi

    log_test_pass "$test_name"
}

test_detect_collisions_owner_repo_layout_no_collision() {
    local test_name="detect_collisions no collision with owner-repo layout"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="owner-repo"

    # In owner-repo layout, different owners don't collide
    local input
    input=$(cat << 'EOF'
owner1/myrepo
owner2/myrepo
EOF
)
    if echo "$input" | detect_collisions 2>/dev/null; then
        assert_true "true" "No collision in owner-repo layout"
    else
        log_test_fail "$test_name" "Should not detect collision in owner-repo layout"
        return 1
    fi

    log_test_pass "$test_name"
}

test_detect_collisions_custom_name_collision() {
    local test_name="detect_collisions detects custom name collisions"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    # Different repos with same custom name collide
    local input
    input=$(cat << 'EOF'
owner/repo1 as myname
owner/repo2 as myname
EOF
)
    local stderr_output
    if stderr_output=$(echo "$input" | detect_collisions 2>&1); then
        log_test_fail "$test_name" "Should detect collision with same custom name"
        return 1
    else
        assert_contains "$stderr_output" "Collision" "Should report collision"
        assert_true "true" "Collision detected as expected"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Repo list management"
echo "============================================"
echo ""

# load_repo_list tests
run_test test_load_repo_list_basic
run_test test_load_repo_list_skips_comments
run_test test_load_repo_list_skips_empty_lines
run_test test_load_repo_list_trims_whitespace
run_test test_load_repo_list_nonexistent_file
run_test test_load_repo_list_with_branch_and_name

# parse_repo_spec tests
run_test test_parse_repo_spec_basic
run_test test_parse_repo_spec_with_branch
run_test test_parse_repo_spec_with_local_name
run_test test_parse_repo_spec_combined
run_test test_parse_repo_spec_https_url
run_test test_parse_repo_spec_ssh_url
run_test test_parse_repo_spec_https_with_branch

# dedupe_repos tests
run_test test_dedupe_repos_removes_duplicates
run_test test_dedupe_repos_keeps_different_repos
run_test test_dedupe_repos_first_wins
run_test test_dedupe_repos_custom_names_differ

# detect_collisions tests
run_test test_detect_collisions_no_collision
run_test test_detect_collisions_same_repo_no_collision
run_test test_detect_collisions_flat_layout_collision
run_test test_detect_collisions_owner_repo_layout_no_collision
run_test test_detect_collisions_custom_name_collision

echo ""
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
