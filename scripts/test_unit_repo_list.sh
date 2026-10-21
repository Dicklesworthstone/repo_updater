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
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "_is_safe_path_segment"
source_ru_function "_is_safe_group_path"
source_ru_function "load_repo_list"
source_ru_function "parse_repo_spec"
source_ru_function "parse_repo_url"
source_ru_function "resolve_repo_spec"
source_ru_function "url_to_local_path"
source_ru_function "dedupe_repos"
source_ru_function "detect_collisions"
source_ru_function "get_all_repos"

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

    local list_file="$test_env/public.txt"
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

    local list_file="$test_env/public.txt"
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

    local list_file="$test_env/public.txt"
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

    local list_file="$test_env/public.txt"
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

    local list_file="$test_env/public.txt"
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
# Tests: repo groups ('in <group>', GH #16)
#==============================================================================

test_parse_repo_spec_group() {
    local test_name="parse_repo_spec parses 'in <group>' in either order with 'as'"
    log_test_start "$test_name"

    local url branch local_name group
    parse_repo_spec "owner/repo in illo" url branch local_name group
    assert_equals "owner/repo" "$url" "URL without modifiers"
    assert_equals "illo" "$group" "Group parsed"
    assert_equals "" "$local_name" "No local name"

    parse_repo_spec "owner/repo@develop in clients/acme as web" url branch local_name group
    assert_equals "owner/repo" "$url" "URL with branch, group, name"
    assert_equals "develop" "$branch" "Branch kept"
    assert_equals "clients/acme" "$group" "Nested group parsed"
    assert_equals "web" "$local_name" "Name parsed after group"

    parse_repo_spec "owner/repo as web in illo" url branch local_name group
    assert_equals "owner/repo" "$url" "URL with name before group"
    assert_equals "illo" "$group" "Group parsed after name"
    assert_equals "web" "$local_name" "Name parsed before group"

    # Legacy 4-argument callers still get a clean URL
    parse_repo_spec "git@github.com:owner/repo.git in illo" url branch local_name
    assert_equals "git@github.com:owner/repo.git" "$url" "SSH URL with group, 4-arg call"
    assert_equals "" "$branch" "SSH '@' is not a branch"

    log_test_pass "$test_name"
}

test_resolve_repo_spec_group_all_layouts() {
    local test_name="resolve_repo_spec puts the group after the layout prefix"
    log_test_start "$test_name"

    local url branch custom path repo_id group
    resolve_repo_spec "tmchow/illo-website in illo" "/p" "flat" url branch custom path repo_id group
    assert_equals "/p/illo/illo-website" "$path" "flat layout"
    assert_equals "illo" "$group" "group output var"
    assert_equals "tmchow/illo-website" "$repo_id" "repo_id unaffected by group"

    resolve_repo_spec "tmchow/illo-website in illo" "/p" "owner-repo" url branch custom path repo_id
    assert_equals "/p/tmchow/illo/illo-website" "$path" "owner-repo layout"

    resolve_repo_spec "tmchow/illo-website in illo" "/p" "full" url branch custom path repo_id
    assert_equals "/p/github.com/tmchow/illo/illo-website" "$path" "full layout"

    resolve_repo_spec "tmchow/illo-characters@dev in illo as characters" "/p" "owner-repo" url branch custom path repo_id
    assert_equals "/p/tmchow/illo/characters" "$path" "'as' renames only the leaf inside a group"
    assert_equals "dev" "$branch" "branch kept with group"

    resolve_repo_spec "tmchow/x in clients/acme" "/p" "flat" url branch custom path repo_id
    assert_equals "/p/clients/acme/x" "$path" "nested group"

    # Without a group, 'as' keeps its legacy meaning (replaces the layout path)
    resolve_repo_spec "tmchow/x as y" "/p" "owner-repo" url branch custom path repo_id
    assert_equals "/p/y" "$path" "legacy 'as' unchanged"

    log_test_pass "$test_name"
}

test_resolve_repo_spec_rejects_unsafe_groups() {
    local test_name="resolve_repo_spec rejects unsafe group paths"
    log_test_start "$test_name"

    local url branch custom path repo_id bad
    for bad in ".." "a/../b" "/abs" "a/" "a//b" "-x" "a/-x" "." "a/./b"; do
        if resolve_repo_spec "owner/repo in $bad" "/p" "flat" url branch custom path repo_id; then
            fail "group '$bad' should be rejected (got $path)"
        else
            pass "group '$bad' rejected"
        fi
    done

    if resolve_repo_spec "owner/repo in illo as a/b" "/p" "flat" url branch custom path repo_id; then
        fail "multi-segment 'as' should still be rejected inside a group"
    else
        pass "multi-segment 'as' rejected inside a group"
    fi

    # A repeated modifier must not leak into the repo name as 'repo in a'
    local dup
    for dup in "owner/repo in a in b" "owner/repo as x as y" "owner/repo in a as x in b"; do
        if resolve_repo_spec "$dup" "/p" "flat" url branch custom path repo_id; then
            fail "'$dup' should be rejected (got $path)"
        else
            pass "'$dup' rejected"
        fi
    done

    log_test_pass "$test_name"
}

test_dedupe_repos_same_repo_in_two_groups() {
    local test_name="dedupe_repos keeps one copy of a repo listed plain and grouped"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    PROJECTS_DIR="$test_env/projects"
    LAYOUT="owner-repo"

    local input result warnings
    input=$(cat << 'EOF'
tmchow/illo-website
tmchow/illo-website in illo
tmchow/illo-skill in illo
tmchow/illo-skill in illo as skill-v2
EOF
)
    result=$(echo "$input" | dedupe_repos 2>"$test_env/err")
    warnings=$(cat "$test_env/err")

    assert_contains "$result" "tmchow/illo-website" "first listing kept"
    assert_not_contains "$result" "tmchow/illo-website in illo" "grouped duplicate dropped"
    assert_contains "$warnings" "tmchow/illo-website in illo" "duplicate is reported"
    assert_contains "$result" "tmchow/illo-skill in illo" "grouped repo kept"
    assert_contains "$result" "tmchow/illo-skill in illo as skill-v2" "distinct 'as' name still allowed"

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
# Tests: get_all_repos
#==============================================================================

test_get_all_repos_empty_when_no_dir() {
    local test_name="get_all_repos returns empty when repos.d doesn't exist"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Set RU_CONFIG_DIR to a directory without repos.d
    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    local result
    result=$(get_all_repos)

    assert_equals "" "$result" "Should return empty when repos.d doesn't exist"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_empty_when_no_txt_files() {
    local test_name="get_all_repos returns empty when repos.d has no .txt files"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    # Create repos.d but with no .txt files
    mkdir -p "$RU_CONFIG_DIR/repos.d"
    echo "owner/repo" > "$RU_CONFIG_DIR/repos.d/ignored.md"

    local result
    result=$(get_all_repos)

    assert_equals "" "$result" "Should return empty when no .txt files"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_loads_single_file() {
    local test_name="get_all_repos loads from single .txt file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    mkdir -p "$RU_CONFIG_DIR/repos.d"
    cat > "$RU_CONFIG_DIR/repos.d/public.txt" << 'EOF'
owner/repo1
owner/repo2
EOF

    local result
    result=$(get_all_repos)

    assert_contains "$result" "owner/repo1" "Should contain repo1"
    assert_contains "$result" "owner/repo2" "Should contain repo2"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_loads_multiple_files() {
    local test_name="get_all_repos loads from multiple .txt files"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    mkdir -p "$RU_CONFIG_DIR/repos.d"

    # Create multiple list files
    echo "owner/repo1" > "$RU_CONFIG_DIR/repos.d/public.txt"
    echo "owner/repo2" > "$RU_CONFIG_DIR/repos.d/private.txt"
    echo "owner/repo3" > "$RU_CONFIG_DIR/repos.d/work.txt"

    local result
    result=$(get_all_repos)

    assert_contains "$result" "owner/repo1" "Should contain repo1 from public.txt"
    assert_contains "$result" "owner/repo2" "Should contain repo2 from private.txt"
    assert_contains "$result" "owner/repo3" "Should contain repo3 from work.txt"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_deduplicates() {
    local test_name="get_all_repos deduplicates across files"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    mkdir -p "$RU_CONFIG_DIR/repos.d"

    # Same repo in multiple files
    echo "owner/repo" > "$RU_CONFIG_DIR/repos.d/file1.txt"
    echo "owner/repo" > "$RU_CONFIG_DIR/repos.d/file2.txt"

    local result
    result=$(get_all_repos)
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    assert_equals "1" "$line_count" "Should deduplicate to 1 repo"
    assert_contains "$result" "owner/repo" "Should contain owner/repo"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_ignores_non_txt() {
    local test_name="get_all_repos ignores non-.txt files"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_CONFIG_DIR="$test_env/config"
    PROJECTS_DIR="$test_env/projects"
    LAYOUT="flat"

    mkdir -p "$RU_CONFIG_DIR/repos.d"

    # Mix of .txt and other files
    echo "owner/wanted" > "$RU_CONFIG_DIR/repos.d/public.txt"
    echo "owner/ignored1" > "$RU_CONFIG_DIR/repos.d/repos.md"
    echo "owner/ignored2" > "$RU_CONFIG_DIR/repos.d/public.txt.bak"

    local result
    result=$(get_all_repos)

    assert_contains "$result" "owner/wanted" "Should contain repo from .txt"
    assert_not_contains "$result" "ignored1" "Should not contain repo from .md"
    assert_not_contains "$result" "ignored2" "Should not contain repo from .txt.bak"

    unset RU_CONFIG_DIR
    log_test_pass "$test_name"
}

test_get_all_repos_rejects_partial_list_failure() {
    local test_name="get_all_repos rejects a failing list without partial output"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)
    local RU_CONFIG_DIR="$test_env/config" PROJECTS_DIR="$test_env/projects" LAYOUT="flat"
    mkdir -p "$RU_CONFIG_DIR/repos.d"
    printf '%s\n' 'owner/valid' > "$RU_CONFIG_DIR/repos.d/a-public.txt"
    printf '%s\n' 'owner/private' > "$RU_CONFIG_DIR/repos.d/z-private.txt"

    local result rc
    result=$(
        # A producer may emit bytes before its I/O fails. Neither that partial
        # list nor the earlier complete list may escape as a complete config.
        load_repo_list() {
            if [[ "$1" == */z-private.txt ]]; then
                printf '%s\n' 'owner/partial'
                return 42
            fi
            printf '%s\n' 'owner/valid'
        }
        get_all_repos
    )
    rc=$?
    assert_equals "1" "$rc" "A failed list read must fail the complete load"
    assert_equals "" "$result" "A failed complete load must not expose partial repositories"
    log_test_pass "$test_name"
}

test_configured_commands_reject_list_failure() {
    local test_name="configured commands reject a failed configuration load"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)
    local command_name result rc
    for command_name in cmd_sync cmd_status get_dirty_repos cmd_ai_sync cmd_dep_update cmd_fork_status cmd_fork_sync cmd_fork_clean cmd_commit_sweep cmd_list count_github_repos get_config_hash; do
        # Redirect a group: on `result=$(...) 2> file` bash expands the command
        # substitution before applying the redirection, so nothing is captured.
        { result=$(
            source_ru_function "get_dirty_repos"
            source_ru_function "$command_name"
            source_ru_function "_fork_parse_args"
            RU_CONFIG_DIR="$test_env"
            PROJECTS_DIR="$test_env/projects"
            JSON_OUTPUT=false
            ARGS=()
            get_all_repos() { printf '%s\n' 'controlled repository-list read failure' >&2; return 42; }
            ensure_dir() { :; }
            log_info() { :; }
            ntm() { return 98; }
            claude() { return 98; }
            "$command_name"
        ); } 2> "$test_env/$command_name.stderr"
        rc=$?
        assert_equals "3" "$rc" "$command_name must report a configuration error"
        assert_equals "" "$result" "$command_name must not output a successful empty result"
        assert_contains "$(cat "$test_env/$command_name.stderr")" "controlled repository-list read failure" "$command_name must reach the failing list reader"
        assert_not_contains "$(cat "$test_env/$command_name.stderr")" "command not found" "$command_name must not depend on missing test helpers"
    done
    log_test_pass "$test_name"
}

test_get_all_repos_rejects_unavailable_list_paths() {
    local test_name="get_all_repos rejects unavailable list paths"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)
    local RU_CONFIG_DIR="$test_env/config" PROJECTS_DIR="$test_env/projects" LAYOUT="flat"
    mkdir -p "$RU_CONFIG_DIR/repos.d"
    printf '%s\n' 'owner/valid' > "$RU_CONFIG_DIR/repos.d/a-public.txt"
    ln -s "$test_env/missing-list.txt" "$RU_CONFIG_DIR/repos.d/z-private.txt"
    local result rc
    result=$(get_all_repos)
    rc=$?
    assert_equals "1" "$rc" "A broken list symlink must fail the complete load"
    assert_equals "" "$result" "The readable list must not escape as a complete configuration"

    RU_CONFIG_DIR="$test_env/wrong-kind"
    mkdir -p "$RU_CONFIG_DIR"
    printf '%s\n' 'not a directory' > "$RU_CONFIG_DIR/repos.d"
    result=$(get_all_repos)
    rc=$?
    assert_equals "1" "$rc" "An existing non-directory repos.d must not be reported as missing"
    assert_equals "" "$result" "An invalid list path must not yield repositories"

    RU_CONFIG_DIR="$test_env/nonregular-list"
    mkdir -p "$RU_CONFIG_DIR/repos.d/public.txt"
    result=$(get_all_repos)
    rc=$?
    assert_equals "1" "$rc" "An existing directory named as a list must not be silently skipped"
    assert_equals "" "$result" "A nonregular list must not yield a partial configuration"
    log_test_pass "$test_name"
}

test_checkpoints_preserve_state_on_list_failure() {
    local test_name="checkpoints preserve prior state when configuration cannot be read"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)
    # Not "state_file": save_sync_state declares its own local of that name,
    # which would shadow this one inside the stubs it calls.
    local fixture_checkpoint="$test_env/checkpoint.json"
    printf '%s\n' '{"run_id":"original","pending":["owner/repo"]}' > "$fixture_checkpoint"
    local original result rc checkpoint_command
    original=$(cat "$fixture_checkpoint")
    for checkpoint_command in save_sync_state checkpoint_review_state; do
        result=$(
            source_ru_function "$checkpoint_command"
            get_all_repos() { return 42; }
            source_ru_function "get_config_hash"
            get_sync_state_file() { printf '%s\n' "$fixture_checkpoint"; }
            get_checkpoint_file() { printf '%s\n' "$fixture_checkpoint"; }
            ensure_dir() { :; }
            local -a completed=() pending=()
            if [[ "$checkpoint_command" == save_sync_state ]]; then
                save_sync_state in_progress completed pending
            else
                checkpoint_review_state '' owner/repo
            fi
        )
        rc=$?
        assert_equals "3" "$rc" "$checkpoint_command must reject incomplete configuration"
        assert_equals "" "$result" "$checkpoint_command must not output a successful result"
        assert_equals "$original" "$(cat "$fixture_checkpoint")" "$checkpoint_command must preserve the prior checkpoint"
    done
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
run_test test_parse_repo_spec_group
run_test test_resolve_repo_spec_group_all_layouts
run_test test_resolve_repo_spec_rejects_unsafe_groups
run_test test_dedupe_repos_same_repo_in_two_groups

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

# get_all_repos tests
run_test test_get_all_repos_empty_when_no_dir
run_test test_get_all_repos_empty_when_no_txt_files
run_test test_get_all_repos_loads_single_file
run_test test_get_all_repos_loads_multiple_files
run_test test_get_all_repos_deduplicates
run_test test_get_all_repos_ignores_non_txt
run_test test_get_all_repos_rejects_partial_list_failure
run_test test_configured_commands_reject_list_failure
run_test test_get_all_repos_rejects_unavailable_list_paths
run_test test_checkpoints_preserve_state_on_list_failure

echo ""
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
