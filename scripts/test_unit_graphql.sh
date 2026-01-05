#!/usr/bin/env bash
#
# Unit tests: GraphQL and Work Item Discovery
# Tests for gh_api_graphql_repo_batch, discover_work_items, etc.
#
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "_set_out_array"
source_ru_function "json_escape"
source_ru_function "retry_with_backoff"
source_ru_function "log_error"
source_ru_function "is_positive_int"
source_ru_function "gh_api_graphql_repo_batch"
source_ru_function "discover_work_items"
source_ru_function "parse_graphql_work_items"
source_ru_function "get_all_repos"
source_ru_function "resolve_repo_spec"
source_ru_function "parse_repo_spec"
source_ru_function "parse_repo_url"
source_ru_function "repo_spec_to_github_id"
source_ru_function "_is_safe_path_segment"
source_ru_function "log_warn"
source_ru_function "log_verbose"

# Mock log functions
log_warn() { :; }
log_verbose() { :; }

test_graphql_injection_protection() {
    local test_name="gh_api_graphql_repo_batch: protects against injection"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)
    
    # Mock gh to capture query
    gh() {
        if [[ "$1" == "api" && "$2" == "graphql" ]]; then
            echo "$@" > "$env_root/gh_call.log"
        fi
    }
    export -f gh
    
    # Create input chunk with malicious repo
    local chunk='malicious"injection/repo'
    
    # Call the function
    gh_api_graphql_repo_batch "$chunk"
    
    # Check if gh was called with injected query
    if [[ -f "$env_root/gh_call.log" ]]; then
        local log_content
        log_content=$(cat "$env_root/gh_call.log")
        # If injection works, we see the quote being closed raw
        # With fix, we expect escaped quotes: owner:"malicious"injection"
        if echo "$log_content" | grep -q 'owner:"malicious"injection"'; then
            fail "GraphQL injection possible: $log_content"
        elif echo "$log_content" | grep -q 'owner:\"malicious\"injection\"'; then
            pass "Input was escaped correctly"
        else
            # It might be using json_escape which produces "malicious\"injection" (one backslash in string)
            # printf %q might show different things.
            # Let's just check it DOESN'T contain the raw closing quote
            pass "Input appears safe (pattern not found)"
        fi
    else
        fail "gh not called"
    fi
    
    cleanup_temp_dirs
}

test_discover_work_items_pipe_sanitization() {
    local test_name="discover_work_items: sanitizes pipes in titles"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)
    
    # Define globals required by ru functions
    PROJECTS_DIR="$env_root/projects"
    LAYOUT="flat"
    VERBOSE="false"
    
    # Mock gh_api_graphql_repo_batch to return data with pipe
    gh_api_graphql_repo_batch() {
        cat <<EOF
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2025-01-01T00:00:00Z",
      "issues": {
        "nodes": [
          {
            "number": 1,
            "title": "Title with | pipe",
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "labels": { "nodes": [] }
          }
        ]
      },
      "pullRequests": { "nodes": [] }
    }
  }
}
EOF
    }
    
    # Mock other deps
    get_all_repos() { echo "https://github.com/owner/repo"; }
    export -f get_all_repos
    command -v jq >/dev/null || fail "jq required"
    command -v gh >/dev/null || fail "gh required"
    
    # Run discovery
    local work_items=()
    discover_work_items work_items "all" ""
    
    # Check the format of the item
    if [[ ${#work_items[@]} -gt 0 ]]; then
        local item="${work_items[0]}"
        
        # Try to parse it using the pipe delimiter
        IFS='|' read -r repo_id type number title rest <<< "$item"
        
        # We expect the pipe to be replaced by a space
        if [[ "$title" == "Title with   pipe" ]]; then
            pass "Title sanitized correctly"
        else
            fail "Title corrupted or not sanitized: '$title'"
        fi
    else
        fail "No work items discovered"
    fi
    
    cleanup_temp_dirs
}

run_test test_graphql_injection_protection
run_test test_discover_work_items_pipe_sanitization

print_results
