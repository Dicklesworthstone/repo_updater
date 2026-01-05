#!/usr/bin/env bash
#
# Unit tests for URL and repo spec parsing functions
# Tests: parse_repo_url, normalize_url, url_to_local_path, parse_repo_spec
#
# Covers:
#   - Standard URL formats (HTTPS, SSH, shorthand)
#   - Edge cases (empty strings, special chars, very long paths)
#   - Invalid URLs (malformed, missing components)
#   - parse_repo_spec with branch pinning and custom names
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Environment Setup
#==============================================================================

# Minimal log functions
log_error() { :; }
log_verbose() { :; }
log_warn() { :; }

# Default values for path functions
PROJECTS_DIR="/tmp/projects"
LAYOUT="flat"

# Extract functions using awk with brace counting
extract_function() {
    local func_name="$1"
    local file="$2"
    awk -v fn="$func_name" '
        $0 ~ "^"fn"\\(\\)" {
            printing=1
            depth=0
        }
        printing {
            print
            for(i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if(c == "{") depth++
                if(c == "}") depth--
            }
            if(depth == 0 && /}/) exit
        }
    ' "$file"
}

source <(extract_function "_is_valid_var_name" "$PROJECT_DIR/ru")
source <(extract_function "_set_out_var" "$PROJECT_DIR/ru")
source <(extract_function "_is_safe_path_segment" "$PROJECT_DIR/ru")
source <(extract_function "_is_valid_var_name" "$PROJECT_DIR/ru")
source <(extract_function "_set_out_var" "$PROJECT_DIR/ru")
source <(extract_function "parse_repo_url" "$PROJECT_DIR/ru")
source <(extract_function "normalize_url" "$PROJECT_DIR/ru")
source <(extract_function "url_to_local_path" "$PROJECT_DIR/ru")
source <(extract_function "url_to_clone_target" "$PROJECT_DIR/ru")
source <(extract_function "parse_repo_spec" "$PROJECT_DIR/ru")

#==============================================================================
# Test Helpers
#==============================================================================

# Helper to test parse_repo_url
assert_parse_url() {
    local url="$1"
    local expected_host="$2"
    local expected_owner="$3"
    local expected_repo="$4"
    local msg="$5"

    local host="" owner="" repo=""
    if parse_repo_url "$url" host owner repo; then
        assert_equals "$expected_host" "$host" "$msg (host)"
        assert_equals "$expected_owner" "$owner" "$msg (owner)"
        assert_equals "$expected_repo" "$repo" "$msg (repo)"
    else
        _tf_fail "$msg (parse failed)" "$expected_host/$expected_owner/$expected_repo" "parse error"
    fi
}

# Helper to test parse_repo_url failure
assert_parse_url_fails() {
    local url="$1"
    local msg="$2"

    local host="" owner="" repo=""
    if parse_repo_url "$url" host owner repo 2>/dev/null; then
        _tf_fail "$msg" "parse error" "$host/$owner/$repo"
    else
        _tf_pass "$msg"
    fi
}

# Helper to test parse_repo_spec
assert_parse_spec() {
    local spec="$1"
    local expected_url="$2"
    local expected_branch="$3"
    local expected_name="$4"
    local msg="$5"

    local url="" branch="" local_name=""
    parse_repo_spec "$spec" url branch local_name

    assert_equals "$expected_url" "$url" "$msg (url)"
    assert_equals "$expected_branch" "$branch" "$msg (branch)"
    assert_equals "$expected_name" "$local_name" "$msg (local_name)"
}

#==============================================================================
# Tests: parse_repo_url - Standard Formats
#==============================================================================

test_parse_url_https_basic() {
    assert_parse_url "https://github.com/owner/repo" \
        "github.com" "owner" "repo" \
        "HTTPS basic URL"
}

test_parse_url_https_with_git_suffix() {
    assert_parse_url "https://github.com/owner/repo.git" \
        "github.com" "owner" "repo" \
        "HTTPS URL with .git suffix"
}

test_parse_url_https_trailing_slash() {
    assert_parse_url "https://github.com/owner/repo/" \
        "github.com" "owner" "repo" \
        "HTTPS URL with trailing slash"
}

test_parse_url_https_mixed_case() {
    assert_parse_url "https://github.com/Dicklesworthstone/repo_updater" \
        "github.com" "Dicklesworthstone" "repo_updater" \
        "HTTPS URL with mixed case owner"
}

test_parse_url_ssh_basic() {
    assert_parse_url "git@github.com:owner/repo.git" \
        "github.com" "owner" "repo" \
        "SSH basic URL"
}

test_parse_url_ssh_without_git_suffix() {
    assert_parse_url "git@github.com:owner/repo" \
        "github.com" "owner" "repo" \
        "SSH URL without .git suffix"
}

test_parse_url_ssh_same_owner_repo() {
    assert_parse_url "git@github.com:cli/cli.git" \
        "github.com" "cli" "cli" \
        "SSH URL with same owner and repo name"
}

test_parse_url_shorthand() {
    assert_parse_url "owner/repo" \
        "github.com" "owner" "repo" \
        "Shorthand owner/repo format"
}

test_parse_url_shorthand_with_underscores() {
    assert_parse_url "charmbracelet/gum" \
        "github.com" "charmbracelet" "gum" \
        "Shorthand with standard names"
}

test_parse_url_host_prefix() {
    assert_parse_url "github.com/owner/repo" \
        "github.com" "owner" "repo" \
        "Host-prefixed URL without protocol"
}

#==============================================================================
# Tests: parse_repo_url - Other Git Hosts
#==============================================================================

test_parse_url_gitlab_https() {
    assert_parse_url "https://gitlab.com/owner/repo" \
        "gitlab.com" "owner" "repo" \
        "GitLab HTTPS URL"
}

test_parse_url_gitlab_ssh() {
    assert_parse_url "git@gitlab.com:owner/repo.git" \
        "gitlab.com" "owner" "repo" \
        "GitLab SSH URL"
}

test_parse_url_bitbucket_https() {
    assert_parse_url "https://bitbucket.org/owner/repo" \
        "bitbucket.org" "owner" "repo" \
        "Bitbucket HTTPS URL"
}

test_parse_url_custom_host() {
    assert_parse_url "https://git.example.com/owner/repo" \
        "git.example.com" "owner" "repo" \
        "Custom git host HTTPS URL"
}

#==============================================================================
# Tests: parse_repo_url - Edge Cases
#==============================================================================

test_parse_url_hyphenated_names() {
    assert_parse_url "my-org/my-repo" \
        "github.com" "my-org" "my-repo" \
        "Hyphenated owner and repo names"
}

test_parse_url_numeric_names() {
    assert_parse_url "user123/repo456" \
        "github.com" "user123" "repo456" \
        "Numeric owner and repo names"
}

test_parse_url_underscore_names() {
    assert_parse_url "org_name/repo_name" \
        "github.com" "org_name" "repo_name" \
        "Underscore in owner and repo names"
}

test_parse_url_dot_in_repo() {
    assert_parse_url "owner/repo.js" \
        "github.com" "owner" "repo.js" \
        "Dot in repo name (not .git suffix)"
}

test_parse_url_single_char_names() {
    assert_parse_url "a/b" \
        "github.com" "a" "b" \
        "Single character owner and repo"
}

test_parse_url_long_names() {
    local long_owner="verylongorganizationnamethatexceedstypicalexpectations"
    local long_repo="arepositorynamethatisequallylongandexceedsnormalconventions"
    assert_parse_url "$long_owner/$long_repo" \
        "github.com" "$long_owner" "$long_repo" \
        "Very long owner and repo names"
}

#==============================================================================
# Tests: parse_repo_url - Invalid/Malformed URLs
#==============================================================================

test_parse_url_empty_string() {
    assert_parse_url_fails "" \
        "Empty string should fail"
}

test_parse_url_only_slash() {
    assert_parse_url_fails "/" \
        "Single slash should fail"
}

test_parse_url_missing_repo() {
    assert_parse_url_fails "owner/" \
        "Missing repo name should fail"
}

test_parse_url_missing_owner() {
    assert_parse_url_fails "/repo" \
        "Missing owner should fail"
}

test_parse_url_triple_slash() {
    # Note: parse_repo_url treats owner/mid/repo as host/owner/repo format
    # This is valid - github.com/owner/repo works, so does owner/mid/repo
    assert_parse_url "owner/mid/repo" \
        "owner" "mid" "repo" \
        "Triple component path parsed as host/owner/repo"
}

test_parse_url_just_host() {
    assert_parse_url_fails "github.com" \
        "Just hostname should fail"
}

test_parse_url_whitespace() {
    assert_parse_url_fails "  " \
        "Whitespace only should fail"
}

#==============================================================================
# Tests: parse_repo_spec - Branch Pinning
#==============================================================================

test_parse_spec_basic() {
    assert_parse_spec "owner/repo" \
        "owner/repo" "" "" \
        "Basic spec without branch or name"
}

test_parse_spec_with_branch() {
    assert_parse_spec "owner/repo@develop" \
        "owner/repo" "develop" "" \
        "Spec with branch pinning"
}

test_parse_spec_with_main_branch() {
    assert_parse_spec "owner/repo@main" \
        "owner/repo" "main" "" \
        "Spec with main branch"
}

test_parse_spec_with_version_tag() {
    assert_parse_spec "owner/repo@v2.0.1" \
        "owner/repo" "v2.0.1" "" \
        "Spec with version tag"
}

test_parse_spec_with_feature_branch_simple() {
    # Note: The regex excludes / in branch names to avoid matching SSH URLs
    # So feature/something won't be matched as a branch
    assert_parse_spec "owner/repo@fix-123" \
        "owner/repo" "fix-123" "" \
        "Spec with hyphenated branch name"
}

#==============================================================================
# Tests: parse_repo_spec - Custom Names
#==============================================================================

test_parse_spec_with_custom_name() {
    assert_parse_spec "owner/repo as myname" \
        "owner/repo" "" "myname" \
        "Spec with custom local name"
}

test_parse_spec_with_hyphenated_name() {
    assert_parse_spec "owner/repo as my-custom-name" \
        "owner/repo" "" "my-custom-name" \
        "Spec with hyphenated custom name"
}

test_parse_spec_with_underscored_name() {
    assert_parse_spec "owner/repo as my_custom_name" \
        "owner/repo" "" "my_custom_name" \
        "Spec with underscored custom name"
}

#==============================================================================
# Tests: parse_repo_spec - Combined Branch and Name
#==============================================================================

test_parse_spec_branch_and_name() {
    assert_parse_spec "owner/repo@develop as dev-repo" \
        "owner/repo" "develop" "dev-repo" \
        "Spec with both branch and custom name"
}

test_parse_spec_main_branch_and_name() {
    assert_parse_spec "charmbracelet/gum@main as gum-stable" \
        "charmbracelet/gum" "main" "gum-stable" \
        "Real-world combined spec"
}

test_parse_spec_version_and_name() {
    assert_parse_spec "cli/cli@v2 as github-cli-v2" \
        "cli/cli" "v2" "github-cli-v2" \
        "Version tag with custom name"
}

#==============================================================================
# Tests: parse_repo_spec - SSH URLs (regression test for fixed bug)
#==============================================================================

test_parse_spec_ssh_url_not_confused_with_branch() {
    # This is a regression test for the bug fixed by TurquoiseMeadow
    # The @ in git@github.com should NOT be treated as branch separator
    assert_parse_spec "git@github.com:owner/repo.git" \
        "git@github.com:owner/repo.git" "" "" \
        "SSH URL @ not confused with branch separator"
}

test_parse_spec_ssh_url_with_custom_name() {
    assert_parse_spec "git@github.com:owner/repo.git as myrepo" \
        "git@github.com:owner/repo.git" "" "myrepo" \
        "SSH URL with custom name"
}

test_parse_spec_https_url_full() {
    assert_parse_spec "https://github.com/owner/repo" \
        "https://github.com/owner/repo" "" "" \
        "Full HTTPS URL as spec"
}

test_parse_spec_https_url_with_branch() {
    assert_parse_spec "https://github.com/owner/repo@develop" \
        "https://github.com/owner/repo" "develop" "" \
        "Full HTTPS URL with branch"
}

#==============================================================================
# Tests: parse_repo_spec - Edge Cases
#==============================================================================

test_parse_spec_extra_spaces() {
    # Extra spaces around 'as' should be trimmed from the URL portion
    assert_parse_spec "owner/repo   as   myname" \
        "owner/repo" "" "myname" \
        "Spec with extra spaces around 'as' (trailing spaces trimmed)"
}

test_parse_spec_case_sensitive_as() {
    # 'as' keyword should be lowercase only
    assert_parse_spec "owner/repo AS myname" \
        "owner/repo AS myname" "" "" \
        "Uppercase AS not recognized as keyword"
}

test_parse_spec_as_in_repo_name() {
    # Edge case: repo name contains 'as' but shouldn't match
    assert_parse_spec "owner/as-repo" \
        "owner/as-repo" "" "" \
        "Repo name containing 'as' not confused"
}

test_parse_spec_branch_with_at_symbol() {
    # @ in the middle of a spec without proper separation
    assert_parse_spec "owner/repo@feat" \
        "owner/repo" "feat" "" \
        "Simple branch with @"
}

#==============================================================================
# Test Helpers: normalize_url
#==============================================================================

assert_normalize_url() {
    local input="$1"
    local expected="$2"
    local msg="$3"

    local result
    if result=$(normalize_url "$input" 2>/dev/null); then
        assert_equals "$expected" "$result" "$msg"
    else
        if [[ -z "$expected" ]]; then
            _tf_pass "$msg (expected failure)"
        else
            _tf_fail "$msg" "$expected" "normalize failed"
        fi
    fi
}

assert_normalize_url_fails() {
    local input="$1"
    local msg="$2"

    local result
    if result=$(normalize_url "$input" 2>/dev/null) && [[ -n "$result" ]]; then
        _tf_fail "$msg" "empty/error" "$result"
    else
        _tf_pass "$msg"
    fi
}

#==============================================================================
# Test Helpers: url_to_local_path
#==============================================================================

assert_url_to_path() {
    local url="$1"
    local projects_dir="$2"
    local layout="$3"
    local expected="$4"
    local msg="$5"

    local result
    if result=$(url_to_local_path "$url" "$projects_dir" "$layout" 2>/dev/null); then
        assert_equals "$expected" "$result" "$msg"
    else
        _tf_fail "$msg" "$expected" "path conversion failed"
    fi
}

#==============================================================================
# Test Helpers: url_to_clone_target
#==============================================================================

assert_clone_target() {
    local url="$1"
    local expected="$2"
    local msg="$3"

    local result
    if result=$(url_to_clone_target "$url" 2>/dev/null); then
        assert_equals "$expected" "$result" "$msg"
    else
        if [[ -z "$expected" ]]; then
            _tf_pass "$msg (expected failure)"
        else
            _tf_fail "$msg" "$expected" "clone target failed"
        fi
    fi
}

#==============================================================================
# Tests: normalize_url - Standard Formats
#==============================================================================

test_normalize_url_https() {
    assert_normalize_url "https://github.com/owner/repo" \
        "https://github.com/owner/repo" \
        "HTTPS URL normalizes to itself"
}

test_normalize_url_https_with_git_suffix() {
    assert_normalize_url "https://github.com/owner/repo.git" \
        "https://github.com/owner/repo" \
        "HTTPS URL with .git suffix strips suffix"
}

test_normalize_url_ssh() {
    assert_normalize_url "git@github.com:owner/repo.git" \
        "https://github.com/owner/repo" \
        "SSH URL normalizes to HTTPS"
}

test_normalize_url_ssh_without_suffix() {
    assert_normalize_url "git@github.com:owner/repo" \
        "https://github.com/owner/repo" \
        "SSH URL without .git normalizes to HTTPS"
}

test_normalize_url_shorthand() {
    assert_normalize_url "owner/repo" \
        "https://github.com/owner/repo" \
        "Shorthand normalizes to HTTPS GitHub URL"
}

test_normalize_url_host_prefix() {
    assert_normalize_url "github.com/owner/repo" \
        "https://github.com/owner/repo" \
        "Host prefix normalizes to full HTTPS"
}

test_normalize_url_gitlab() {
    assert_normalize_url "git@gitlab.com:owner/repo.git" \
        "https://gitlab.com/owner/repo" \
        "GitLab SSH normalizes to GitLab HTTPS"
}

test_normalize_url_bitbucket() {
    assert_normalize_url "https://bitbucket.org/owner/repo" \
        "https://bitbucket.org/owner/repo" \
        "Bitbucket URL normalizes correctly"
}

test_normalize_url_trailing_slash() {
    assert_normalize_url "https://github.com/owner/repo/" \
        "https://github.com/owner/repo" \
        "Trailing slash is removed"
}

#==============================================================================
# Tests: normalize_url - Edge Cases
#==============================================================================

test_normalize_url_empty() {
    assert_normalize_url_fails "" \
        "Empty string returns empty"
}

test_normalize_url_invalid() {
    assert_normalize_url_fails "not-a-url" \
        "Invalid URL returns empty"
}

test_normalize_url_just_host() {
    assert_normalize_url_fails "github.com" \
        "Just host returns empty"
}

#==============================================================================
# Tests: url_to_local_path - Flat Layout
#==============================================================================

test_url_to_path_flat_https() {
    assert_url_to_path "https://github.com/owner/repo" \
        "/data/projects" "flat" \
        "/data/projects/repo" \
        "Flat layout: HTTPS URL"
}

test_url_to_path_flat_shorthand() {
    assert_url_to_path "owner/repo" \
        "/data/projects" "flat" \
        "/data/projects/repo" \
        "Flat layout: shorthand"
}

test_url_to_path_flat_ssh() {
    assert_url_to_path "git@github.com:owner/repo.git" \
        "/data/projects" "flat" \
        "/data/projects/repo" \
        "Flat layout: SSH URL"
}

test_url_to_path_flat_different_dir() {
    assert_url_to_path "owner/repo" \
        "/home/user/code" "flat" \
        "/home/user/code/repo" \
        "Flat layout: custom projects dir"
}

#==============================================================================
# Tests: url_to_local_path - Owner-Repo Layout
#==============================================================================

test_url_to_path_owner_repo_https() {
    assert_url_to_path "https://github.com/Dicklesworthstone/repo_updater" \
        "/data/projects" "owner-repo" \
        "/data/projects/Dicklesworthstone/repo_updater" \
        "Owner-repo layout: HTTPS URL"
}

test_url_to_path_owner_repo_shorthand() {
    assert_url_to_path "owner/repo" \
        "/data/projects" "owner-repo" \
        "/data/projects/owner/repo" \
        "Owner-repo layout: shorthand"
}

test_url_to_path_owner_repo_ssh() {
    assert_url_to_path "git@github.com:cli/cli.git" \
        "/data/projects" "owner-repo" \
        "/data/projects/cli/cli" \
        "Owner-repo layout: SSH URL same name"
}

#==============================================================================
# Tests: url_to_local_path - Full Layout
#==============================================================================

test_url_to_path_full_github() {
    assert_url_to_path "https://github.com/owner/repo" \
        "/data/projects" "full" \
        "/data/projects/github.com/owner/repo" \
        "Full layout: GitHub URL"
}

test_url_to_path_full_gitlab() {
    assert_url_to_path "https://gitlab.com/owner/repo" \
        "/data/projects" "full" \
        "/data/projects/gitlab.com/owner/repo" \
        "Full layout: GitLab URL"
}

test_url_to_path_full_shorthand() {
    assert_url_to_path "owner/repo" \
        "/data/projects" "full" \
        "/data/projects/github.com/owner/repo" \
        "Full layout: shorthand defaults to github.com"
}

test_url_to_path_full_custom_host() {
    assert_url_to_path "https://git.example.com/owner/repo" \
        "/data/projects" "full" \
        "/data/projects/git.example.com/owner/repo" \
        "Full layout: custom git host"
}

#==============================================================================
# Tests: url_to_clone_target
#==============================================================================

test_clone_target_https() {
    assert_clone_target "https://github.com/owner/repo" \
        "owner/repo" \
        "Clone target from HTTPS URL"
}

test_clone_target_https_with_suffix() {
    assert_clone_target "https://github.com/owner/repo.git" \
        "owner/repo" \
        "Clone target from HTTPS URL with .git"
}

test_clone_target_ssh() {
    assert_clone_target "git@github.com:owner/repo.git" \
        "owner/repo" \
        "Clone target from SSH URL"
}

test_clone_target_shorthand() {
    assert_clone_target "owner/repo" \
        "owner/repo" \
        "Clone target from shorthand"
}

test_clone_target_mixed_case() {
    assert_clone_target "Dicklesworthstone/repo_updater" \
        "Dicklesworthstone/repo_updater" \
        "Clone target preserves case"
}

test_clone_target_gitlab() {
    # Note: gh clone doesn't work with non-GitHub, but the function returns owner/repo
    assert_clone_target "https://gitlab.com/owner/repo" \
        "owner/repo" \
        "Clone target from GitLab URL"
}

test_clone_target_same_name() {
    assert_clone_target "cli/cli" \
        "cli/cli" \
        "Clone target with same owner and repo"
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: URL and Repo Spec Parsing"
echo "============================================"

# parse_repo_url - Standard Formats
run_test test_parse_url_https_basic
run_test test_parse_url_https_with_git_suffix
run_test test_parse_url_https_trailing_slash
run_test test_parse_url_https_mixed_case
run_test test_parse_url_ssh_basic
run_test test_parse_url_ssh_without_git_suffix
run_test test_parse_url_ssh_same_owner_repo
run_test test_parse_url_shorthand
run_test test_parse_url_shorthand_with_underscores
run_test test_parse_url_host_prefix

# parse_repo_url - Other Git Hosts
run_test test_parse_url_gitlab_https
run_test test_parse_url_gitlab_ssh
run_test test_parse_url_bitbucket_https
run_test test_parse_url_custom_host

# parse_repo_url - Edge Cases
run_test test_parse_url_hyphenated_names
run_test test_parse_url_numeric_names
run_test test_parse_url_underscore_names
run_test test_parse_url_dot_in_repo
run_test test_parse_url_single_char_names
run_test test_parse_url_long_names

# parse_repo_url - Invalid/Malformed URLs
run_test test_parse_url_empty_string
run_test test_parse_url_only_slash
run_test test_parse_url_missing_repo
run_test test_parse_url_missing_owner
run_test test_parse_url_triple_slash
run_test test_parse_url_just_host
run_test test_parse_url_whitespace

# parse_repo_spec - Branch Pinning
run_test test_parse_spec_basic
run_test test_parse_spec_with_branch
run_test test_parse_spec_with_main_branch
run_test test_parse_spec_with_version_tag
run_test test_parse_spec_with_feature_branch_simple

# parse_repo_spec - Custom Names
run_test test_parse_spec_with_custom_name
run_test test_parse_spec_with_hyphenated_name
run_test test_parse_spec_with_underscored_name

# parse_repo_spec - Combined Branch and Name
run_test test_parse_spec_branch_and_name
run_test test_parse_spec_main_branch_and_name
run_test test_parse_spec_version_and_name

# parse_repo_spec - SSH URLs (regression tests)
run_test test_parse_spec_ssh_url_not_confused_with_branch
run_test test_parse_spec_ssh_url_with_custom_name
run_test test_parse_spec_https_url_full
run_test test_parse_spec_https_url_with_branch

# parse_repo_spec - Edge Cases
run_test test_parse_spec_extra_spaces
run_test test_parse_spec_case_sensitive_as
run_test test_parse_spec_as_in_repo_name
run_test test_parse_spec_branch_with_at_symbol

# normalize_url - Standard Formats
run_test test_normalize_url_https
run_test test_normalize_url_https_with_git_suffix
run_test test_normalize_url_ssh
run_test test_normalize_url_ssh_without_suffix
run_test test_normalize_url_shorthand
run_test test_normalize_url_host_prefix
run_test test_normalize_url_gitlab
run_test test_normalize_url_bitbucket
run_test test_normalize_url_trailing_slash

# normalize_url - Edge Cases
run_test test_normalize_url_empty
run_test test_normalize_url_invalid
run_test test_normalize_url_just_host

# url_to_local_path - Flat Layout
run_test test_url_to_path_flat_https
run_test test_url_to_path_flat_shorthand
run_test test_url_to_path_flat_ssh
run_test test_url_to_path_flat_different_dir

# url_to_local_path - Owner-Repo Layout
run_test test_url_to_path_owner_repo_https
run_test test_url_to_path_owner_repo_shorthand
run_test test_url_to_path_owner_repo_ssh

# url_to_local_path - Full Layout
run_test test_url_to_path_full_github
run_test test_url_to_path_full_gitlab
run_test test_url_to_path_full_shorthand
run_test test_url_to_path_full_custom_host

# url_to_clone_target
run_test test_clone_target_https
run_test test_clone_target_https_with_suffix
run_test test_clone_target_ssh
run_test test_clone_target_shorthand
run_test test_clone_target_mixed_case
run_test test_clone_target_gitlab
run_test test_clone_target_same_name

# Print results
print_results
exit $?
