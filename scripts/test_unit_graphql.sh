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
source_ru_function "complete_graphql_work_items"
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
source_ru_function "score_and_sort_work_items"
source_ru_function "calculate_item_priority_score"
source_ru_function "get_priority_level"
source_ru_function "passes_priority_threshold"
source_ru_function "days_since_timestamp"
source_ru_function "item_recently_reviewed"
source_ru_function "get_review_state_file"
source_ru_function "get_review_state_dir"

# Mock log functions
log_warn() { :; }
log_verbose() { :; }

test_retry_preserves_process_outcomes() {
    log_test_start "retry_with_backoff: real exits and capture streams"
    local env_root mode expected output actual attempts
    env_root=$(create_test_env)
    for mode in all stdout; do
        for expected in 1 2 42 124 127; do
            attempts="$env_root/attempts-$mode-$expected"
            : > "$attempts"
            actual=0
            output=$(retry_with_backoff "--capture=$mode" 3 0 -- bash -c '
                printf "attempt\n" >> "$1"
                printf "command output\n"
                printf "command diagnostic\n" >&2
                exit "$2"
            ' _ "$attempts" "$expected" 2> "$env_root/stderr-$mode-$expected") || actual=$?
            assert_equals "$expected" "$actual" "Exhausted $mode retry preserves exit $expected"
            assert_equals 3 "$(wc -l < "$attempts" | tr -d ' ')" "All requested attempts execute"
            assert_contains "$output" 'command output' "Last command stdout is retained"
            if [[ "$mode" == stdout ]]; then
                assert_equals 'command output' "$output" "Structured stdout excludes human diagnostics"
                assert_contains "$(cat "$env_root/stderr-$mode-$expected")" 'command diagnostic' "stderr diagnostics remain visible"
            else
                assert_contains "$output" 'command diagnostic' "Combined capture retains stderr"
            fi
        done
        attempts="$env_root/recovered-$mode"
        : > "$attempts"
        actual=0
        output=$(retry_with_backoff "--capture=$mode" 3 0 -- bash -c '
            count=$(wc -l < "$1")
            printf "attempt\n" >> "$1"
            if [[ "$count" -eq 0 ]]; then exit 42; fi
            printf "recovered\n"
        ' _ "$attempts") || actual=$?
        assert_equals 0 "$actual" "Successful $mode retry recovers"
        assert_equals 2 "$(wc -l < "$attempts" | tr -d ' ')" "Recovery stops further retries"
        assert_equals recovered "$output" "Successful output is retained"
    done
}

test_graphql_injection_protection() {
    local test_name="gh_api_graphql_repo_batch: protects against injection"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)
    
    # Mock gh to capture query
    gh() {
        if [[ "$1" == "api" && "$2" == "graphql" ]]; then
            echo "$@" > "$env_root/gh_call.log"
            printf '%s\n' '{"data":{"repo0":{"nameWithOwner":"owner/repo","issues":{"nodes":[],"pageInfo":{"hasNextPage":false}},"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
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

test_graphql_completes_backlog_and_labels() {
    log_test_start "GraphQL: paginate 51 issues, 21 PRs and the eleventh label"
    local env_root initial response
    env_root=$(create_test_env)
    initial=$(jq -nc '
        def item($n): {number:$n,title:("Item " + ($n|tostring)),createdAt:"2000-01-01T00:00:00Z",
            updatedAt:"2000-01-01T00:00:00Z",isDraft:false,labels:{totalCount:0,nodes:[]}};
        {data:{repo0:{nameWithOwner:"owner/repo",isArchived:false,isFork:false,
            issues:{nodes:[range(1;51)|item(.)],pageInfo:{hasNextPage:true,endCursor:"issues-next"}},
            pullRequests:{nodes:[range(101;121)|item(.)],pageInfo:{hasNextPage:true,endCursor:"prs-next"}}}}} |
        .data.repo0.issues.nodes[0].labels = {totalCount:11,nodes:[range(1;11)|{name:("label"+tostring)}]}
    ')
    gh() {
        printf '%s\n' "$*" >> "$env_root/calls"
        if [[ "$*" == *'/labels?per_page=100'* ]]; then
            jq -nc '[[range(1;11)|{name:("label"+tostring)}] + [{name:"security"}]]'
        elif [[ "$*" == *'--paginate --slurp'* ]]; then
            local kind=issues number=51
            if [[ "$*" == *'pullRequests(states:'* ]]; then kind=pullRequests; number=121; fi
            jq -nc --arg kind "$kind" --argjson number "$number" '
                [{data:{repository:{($kind):{nodes:[{number:$number,title:"Old bug",createdAt:"2000-01-01T00:00:00Z",
                    updatedAt:"2000-01-01T00:00:00Z",isDraft:false,labels:{totalCount:0,nodes:[]}}],
                    pageInfo:{hasNextPage:false,endCursor:"done"}}}}}]
            '
        else
            printf '%s\n' "$initial"
        fi
    }
    response=$(gh_api_graphql_repo_batch owner/repo)
    assert_equals 0 "$?" "Complete discovery succeeds"
    assert_equals 51 "$(printf '%s\n' "$response" | jq '.data.repo0.issues.nodes | length')" "Issue 51 survives pagination"
    assert_equals 21 "$(printf '%s\n' "$response" | jq '.data.repo0.pullRequests.nodes | length')" "PR 21 survives pagination"
    assert_equals 11 "$(printf '%s\n' "$response" | jq '.data.repo0.issues.nodes[] | select(.number==1) | .labels.nodes | length')" "All eleven labels survive"
    assert_contains "$(parse_graphql_work_items "$response")" security "Security label beyond the first ten is discovered"
    assert_equals 4 "$(wc -l < "$env_root/calls" | tr -d ' ')" "One batched request plus only the three truncated connections"
    assert_contains "$(cat "$env_root/calls")" endCursor=issues-next "Issue pagination begins after the initial page"
    assert_contains "$(cat "$env_root/calls")" endCursor=prs-next "PR pagination begins after the initial page"
}

test_graphql_partial_errors_are_failures() {
    log_test_start "GraphQL: partial errors cannot become an empty complete backlog"
    gh() { printf '%s\n' '{"data":{"repo0":null},"errors":[{"message":"permission denied"}]}'; }
    local output rc=0
    output=$(gh_api_graphql_repo_batch owner/repo) || rc=$?
    assert_equals 1 "$rc" "A successful HTTP response with GraphQL errors still fails"
    assert_equals '' "$output" "No incomplete result is emitted"
    rc=0
    output=$(parse_graphql_work_items '{"data":{},"errors":[{"message":"rate limited"}]}') || rc=$?
    assert_equals 1 "$rc" "Parser also rejects partial errors when a caller supplies captured JSON"
    assert_equals '' "$output" "Parser cannot emit partial rows"
}

test_graphql_continuation_errors_are_failures() {
    log_test_start "GraphQL: an error on a later page cannot publish the first page as complete"
    gh() {
        if [[ "$*" == *'--paginate --slurp'* ]]; then
            printf '%s\n' '[{"data":{"repository":null},"errors":[{"message":"continuation denied"}]}]'
        else
            printf '%s\n' '{"data":{"repo0":{"nameWithOwner":"owner/repo","issues":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"next"}},"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
        fi
    }
    local output rc=0
    output=$(gh_api_graphql_repo_batch owner/repo) || rc=$?
    assert_equals 1 "$rc" "An unsuccessful continuation fails the entire batch"
    assert_equals '' "$output" "A partial first page is not emitted"
}

test_discovery_priority_budget_and_empty_labels() {
    log_test_start "Discovery: priority is applied before a repository budget; empty labels preserve fields"
    PROJECTS_DIR=/nonexistent/ru-controlled-projects
    LAYOUT=flat
    get_all_repos() { printf '%s\n' owner/first owner/second; }
    repo_spec_to_github_id() { printf '%s\n' "$1"; }
    item_recently_reviewed() { return 1; }
    gh_api_graphql_repo_batch() {
        jq -nc '
            def item($n;$title;$labels): {number:$n,title:$title,createdAt:"2000-01-01T00:00:00Z",
                updatedAt:"2000-01-01T00:00:00Z",isDraft:false,labels:{nodes:[$labels[]|{name:.}]}};
            {data:{repo0:{nameWithOwner:"owner/first",issues:{nodes:[item(1;"Feature";["enhancement"])]},pullRequests:{nodes:[]}},
                repo1:{nameWithOwner:"owner/second",issues:{nodes:[item(2;"Unlabelled";[]),item(3;"Critical";["critical"]),item(4;"Bug";["bug"])]},pullRequests:{nodes:[]}}}}
        '
    }
    local repo=caller-repo-sentinel
    local -a items=()
    discover_work_items items all 1
    assert_equals 0 "$?" "Successful complete discovery remains successful"
    assert_equals caller-repo-sentinel "$repo" "Discovery does not overwrite a caller's loop variable"
    assert_equals 3 "${#items[@]}" "A one-repository budget retains every item of the highest-priority repository"
    assert_contains "${items[*]}" 'owner/second|issue|2|Unlabelled||2000-01-01T00:00:00Z|2000-01-01T00:00:00Z|false' "Empty label field does not consume either timestamp or draft flag"
    assert_equals 'owner/second|issue|3|Critical|critical|2000-01-01T00:00:00Z|2000-01-01T00:00:00Z|false' "${items[0]}" "Critical item leads the selected repository"
    discover_work_items items critical ''
    assert_equals 1 "${#items[@]}" "Critical-only filtering reaches the real labelled issue"
    assert_contains "${items[0]}" '|3|Critical|' "The critical item is retained"
    gh_api_graphql_repo_batch() { return 42; }
    local rc=0
    discover_work_items items all '' || rc=$?
    assert_equals 1 "$rc" "Failed discovery is nonzero"
    assert_equals 0 "${#items[@]}" "Failure does not leak a previous successful result"
    get_all_repos() { return 42; }
    rc=0
    discover_work_items items all '' || rc=$?
    assert_equals 1 "$rc" "Failure to load configured repositories is not a successful empty review"
    assert_equals 0 "${#items[@]}" "Repository-load failure leaves no partial results"
}

run_test test_retry_preserves_process_outcomes
run_test test_graphql_injection_protection
run_test test_discover_work_items_pipe_sanitization
run_test test_graphql_completes_backlog_and_labels
run_test test_graphql_partial_errors_are_failures
run_test test_graphql_continuation_errors_are_failures
run_test test_discovery_priority_budget_and_empty_labels

print_results
