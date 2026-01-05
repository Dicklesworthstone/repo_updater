#!/usr/bin/env bash
#
# Unit tests: Review feature core functions (bd-obd9)
#
# Covers:
# - parse_graphql_work_items
# - calculate_item_priority_score
# - validate_review_plan
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # STATE_LOCK_FD used by sourced lock helpers
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "parse_graphql_work_items"
source_ru_function "calculate_item_priority_score"
source_ru_function "get_priority_level"
source_ru_function "passes_priority_threshold"
source_ru_function "score_and_sort_work_items"
source_ru_function "discover_work_items"
source_ru_function "validate_review_plan"
source_ru_function "summarize_review_plan"
source_ru_function "get_review_plan_json_summary"
source_ru_function "archive_review_plan"
source_ru_function "ensure_dir"
source_ru_function "json_escape"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "get_review_state_dir"

# Required global for state locking (normally set in ru)
STATE_LOCK_FD=201

# Mock logging (avoid noisy output on error paths)
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

require_flock_or_skip() {
    if ! command -v flock &>/dev/null; then
        skip_test "flock not installed"
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# parse_graphql_work_items
#------------------------------------------------------------------------------

test_parse_graphql_work_items_filters_archived_and_fork() {
    local test_name="parse_graphql_work_items: filters archived/fork"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local fixture="$PROJECT_DIR/test/fixtures/gh/graphql_batch.json"
    assert_file_exists "$fixture" "Fixture should exist"

    local output
    output=$(parse_graphql_work_items "$(cat "$fixture")")

    assert_contains "$output" $'octo/repo1\tissue\t42' "Includes issue from non-archived repo"
    assert_contains "$output" $'octo/repo1\tpr\t7' "Includes PR from non-archived repo"
    assert_contains "$output" $'octo/repo1\tpr\t8' "Includes draft PR"
    assert_contains "$output" $'\ttrue' "Draft PR should mark is_draft true"
    assert_not_contains "$output" "octo/archived" "Archived repo excluded"
    assert_not_contains "$output" "octo/forked" "Forked repo excluded"

    log_test_pass "$test_name"
}

test_parse_graphql_work_items_empty_response_returns_empty() {
    local test_name="parse_graphql_work_items: empty response"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local output
    output=$(parse_graphql_work_items '{"data":{}}')

    assert_equals "" "$output" "Empty response should produce no TSV lines"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# discover_work_items (offline / no network)
#------------------------------------------------------------------------------

test_discover_work_items_builds_items_from_fixture() {
    local test_name="discover_work_items: parses fixture into array"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local fixture="$PROJECT_DIR/test/fixtures/gh/graphql_batch.json"
    assert_file_exists "$fixture" "Fixture should exist"

    # Mock functions (outside subshell so discover_work_items can use them)
    gh() { :; }
    get_all_repos() { printf '%s\n' "octo/repo1"; }
    repo_spec_to_github_id() { printf '%s\n' "$1"; }
    gh_api_graphql_repo_batch() { cat "$fixture"; }

    local -a items=()
    discover_work_items items "all" "" ""

    # Build output string for assert_contains checks
    local output=""
    local item
    for item in "${items[@]}"; do
        output+="$item"$'\n'
    done

    assert_equals "3" "${#items[@]}" "Should discover 3 items from fixture"
    assert_contains "$output" "octo/repo1|issue|42|" "Includes issue 42"
    assert_contains "$output" "octo/repo1|pr|7|" "Includes PR 7"
    assert_contains "$output" "octo/repo1|pr|8|" "Includes draft PR 8"

    log_test_pass "$test_name"
}

test_discover_work_items_handles_empty_graphql_response() {
    local test_name="discover_work_items: empty GraphQL response yields empty array"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    # Mock functions (outside subshell so discover_work_items can use them)
    gh() { :; }
    get_all_repos() { printf '%s\n' "octo/repo1"; }
    repo_spec_to_github_id() { printf '%s\n' "$1"; }
    gh_api_graphql_repo_batch() { printf '%s\n' '{"data":{}}'; }

    local -a items=()
    discover_work_items items "all" "" ""

    assert_equals "0" "${#items[@]}" "Empty response should produce zero items"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# calculate_item_priority_score
#------------------------------------------------------------------------------

test_calculate_item_priority_score_components() {
    local test_name="calculate_item_priority_score: label/age/recency"
    log_test_start "$test_name"

    # Mock days_since_timestamp for deterministic scoring
    days_since_timestamp() {
        case "$1" in
            created) echo 40 ;;
            updated) echo 2 ;;
            *) echo 0 ;;
        esac
    }

    # No recent review
    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "pr" "bug" "created" "updated" "false" "octo/repo1" "42")

    # Expected: PR 20 + bug label 30 + age 30 + recency 15 = 95
    assert_equals "95" "$score" "Score should include all components"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_recent_review_penalty() {
    local test_name="calculate_item_priority_score: recent review penalty"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 10 ;;
            updated) echo 1 ;;
            *) echo 0 ;;
        esac
    }

    # Recently reviewed
    item_recently_reviewed() { return 0; }

    local score
    score=$(calculate_item_priority_score "issue" "bug" "created" "updated" "false" "octo/repo1" "7")

    # Base issue 10 + bug label 30 + recency 15 - staleness 20 = 35
    assert_equals "35" "$score" "Score should include recent-review penalty"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_draft_pr_penalty() {
    local test_name="calculate_item_priority_score: draft PR penalty"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 5 ;;
            updated) echo 1 ;;
            *) echo 0 ;;
        esac
    }

    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "pr" "enhancement" "created" "updated" "true" "octo/repo1" "99")

    # Draft PR: base 20 - draft penalty 15 + enhancement 10 + recency 15 = 30
    assert_equals "30" "$score" "Draft PR should be penalized 15 points"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_security_label() {
    local test_name="calculate_item_priority_score: security label boost"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 70 ;;  # Very old
            updated) echo 5 ;;
            *) echo 0 ;;
        esac
    }

    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "issue" "security" "created" "updated" "false" "octo/repo1" "100")

    # Issue 10 + security 50 + age>60 50 + recency 10 = 120
    assert_equals "120" "$score" "Security label should get +50 and old bug +50"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_very_old_bug() {
    local test_name="calculate_item_priority_score: very old bug bonus"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 65 ;;  # >60 days
            updated) echo 30 ;;  # No recency bonus
            *) echo 0 ;;
        esac
    }

    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "issue" "bug,help-wanted" "created" "updated" "false" "octo/repo1" "200")

    # Issue 10 + bug 30 + age>60 50 = 90
    assert_equals "90" "$score" "Very old bug (>60 days) should get +50 age bonus"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_stale_feature() {
    local test_name="calculate_item_priority_score: stale feature penalty"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 200 ;;  # >180 days
            updated) echo 100 ;;  # No recency bonus
            *) echo 0 ;;
        esac
    }

    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "issue" "enhancement" "created" "updated" "false" "octo/repo1" "300")

    # Issue 10 + enhancement 10 - staleness 10 = 10
    assert_equals "10" "$score" "Very old feature (>180 days) should get -10 staleness"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_clamps_to_zero() {
    local test_name="calculate_item_priority_score: clamps negative to zero"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 200 ;;  # Very old
            updated) echo 100 ;;  # No recency
            *) echo 0 ;;
        esac
    }

    # Recently reviewed - applies -20 penalty
    item_recently_reviewed() { return 0; }

    local score
    score=$(calculate_item_priority_score "pr" "" "created" "updated" "true" "octo/repo1" "400")

    # Draft PR: 20 - 15 (draft) - 20 (recent review) = -15 -> clamped to 0
    assert_equals "0" "$score" "Negative scores should clamp to 0"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Priority levels + threshold filtering
#------------------------------------------------------------------------------

test_get_priority_level_thresholds() {
    local test_name="get_priority_level: threshold mapping"
    log_test_start "$test_name"

    assert_equals "CRITICAL" "$(get_priority_level 150)" "150 should be CRITICAL"
    assert_equals "HIGH" "$(get_priority_level 120)" "120 should be HIGH"
    assert_equals "NORMAL" "$(get_priority_level 50)" "50 should be NORMAL"
    assert_equals "LOW" "$(get_priority_level 10)" "10 should be LOW"

    log_test_pass "$test_name"
}

test_passes_priority_thresholds() {
    local test_name="passes_priority_threshold: filters correctly"
    log_test_start "$test_name"

    assert_exit_code 0 "normal threshold allows HIGH" passes_priority_threshold "HIGH" "normal"
    assert_exit_code 1 "high threshold filters NORMAL" passes_priority_threshold "NORMAL" "high"
    assert_exit_code 0 "critical threshold allows CRITICAL" passes_priority_threshold "CRITICAL" "critical"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# score_and_sort_work_items
#------------------------------------------------------------------------------

test_score_and_sort_work_items_orders_and_filters() {
    local test_name="score_and_sort_work_items: order + threshold"
    log_test_start "$test_name"

    # Stub scoring to return deterministic values by issue number
    calculate_item_priority_score() {
        if [[ "$7" -eq 1 ]]; then
            echo 120
        else
            echo 20
        fi
    }

    local tsv_input
    tsv_input=$(
        cat <<'TSV_EOF'
octo/repo1	issue	1	First	enhancement	created	updated	false
octo/repo1	pr	2	Second	bug	created	updated	false
TSV_EOF
    )

    local output
    output=$(score_and_sort_work_items "$tsv_input" "high")

    assert_contains "$output" $'120\tHIGH\tocto/repo1\tissue\t1' "High item should remain"
    assert_not_contains "$output" $'\t2\tSecond' "Low item should be filtered"

    # Restore original scoring function for later tests
    source_ru_function "calculate_item_priority_score"

    log_test_pass "$test_name"
}

test_score_and_sort_draft_pr_ranked_lower() {
    local test_name="score_and_sort_work_items: draft PRs score lower"
    log_test_start "$test_name"

    # Use real scoring function with mocked helpers
    days_since_timestamp() { echo 5; }
    item_recently_reviewed() { return 1; }

    local tsv_input
    tsv_input=$(
        cat <<'TSV_EOF'
octo/repo1	pr	10	Ready PR	enhancement	created	updated	false
octo/repo1	pr	20	Draft PR	enhancement	created	updated	true
TSV_EOF
    )

    local output
    output=$(score_and_sort_work_items "$tsv_input" "all")

    # Ready PR should appear first (higher score)
    local first_line
    first_line=$(echo "$output" | head -1)
    assert_contains "$first_line" $'\tpr\t10\t' "Ready PR should be ranked first"

    log_test_pass "$test_name"
}

test_validate_review_plan_unanswered_questions_structurally_valid() {
    local test_name="validate_review_plan: unanswered questions structurally valid"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    local plan_file="$PROJECT_DIR/test/fixtures/plans/unanswered-questions.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")

    # Plan with unanswered questions should still be valid structurally
    # but the questions field should be present
    assert_equals "Valid" "$result" "Plan with unanswered questions is structurally valid"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# validate_review_plan
#------------------------------------------------------------------------------

test_validate_review_plan_accepts_valid() {
    local test_name="validate_review_plan: accepts valid plan"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    local plan_file="$PROJECT_DIR/test/fixtures/plans/valid-plan.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")
    assert_equals "Valid" "$result" "Valid plan should pass"

    log_test_pass "$test_name"
}

test_validate_review_plan_rejects_missing_fields() {
    local test_name="validate_review_plan: rejects missing fields"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    local plan_file="$PROJECT_DIR/test/fixtures/plans/missing-fields.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")

    assert_contains "$result" "Missing required fields" "Missing repo should be rejected"

    log_test_pass "$test_name"
}

test_validate_review_plan_rejects_invalid_decision() {
    local test_name="validate_review_plan: rejects invalid decision"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    local plan_file="$PROJECT_DIR/test/fixtures/plans/invalid-decision.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")

    assert_contains "$result" "Invalid decision values" "Invalid decision should be rejected"

    log_test_pass "$test_name"
}

test_validate_review_plan_rejects_invalid_gh_target() {
    local test_name="validate_review_plan: rejects invalid gh target"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    local plan_file="$PROJECT_DIR/test/fixtures/plans/invalid-gh-target.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")

    assert_contains "$result" "Invalid gh_action target format" "Invalid gh target should be rejected"

    log_test_pass "$test_name"
}

test_validate_review_plan_rejects_invalid_schema_version() {
    local test_name="validate_review_plan: rejects unsupported schema_version"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local plan_file="$PROJECT_DIR/test/fixtures/plans/invalid-schema-version.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")

    assert_contains "$result" "Unsupported schema version" "Invalid schema version should be rejected"

    log_test_pass "$test_name"
}

test_validate_review_plan_accepts_large_plan() {
    local test_name="validate_review_plan: accepts large plan"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local plan_file="$PROJECT_DIR/test/fixtures/plans/large-plan.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local result
    result=$(validate_review_plan "$plan_file")
    assert_equals "Valid" "$result" "Large plan should validate"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# summarize_review_plan + get_review_plan_json_summary
#------------------------------------------------------------------------------

test_summarize_review_plan_prints_counts() {
    local test_name="summarize_review_plan: prints totals"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local plan_file="$PROJECT_DIR/test/fixtures/plans/valid-plan.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local output rc=0
    output=$(summarize_review_plan "$plan_file") || rc=$?
    assert_equals "0" "$rc" "summarize_review_plan should succeed"

    assert_contains "$output" "Repository: octo/repo1" "Should include repo"
    assert_contains "$output" "Items reviewed: 2" "Should count items"
    assert_contains "$output" "gh_actions pending: 1" "Should count gh_actions"

    log_test_pass "$test_name"
}

test_get_review_plan_json_summary_is_parseable() {
    local test_name="get_review_plan_json_summary: parseable JSON"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local plan_file="$PROJECT_DIR/test/fixtures/plans/valid-plan.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local output rc=0
    output=$(get_review_plan_json_summary "$plan_file") || rc=$?
    assert_equals "0" "$rc" "get_review_plan_json_summary should succeed"

    assert_exit_code 0 "Summary JSON should parse" jq -e '.' <<<"$output"
    assert_equals "2" "$(jq -r '.summary.total_items' <<<"$output")" "Should include total_items"
    assert_equals "1" "$(jq -r '.gh_actions_count' <<<"$output")" "Should include gh_actions_count"

    log_test_pass "$test_name"
}

test_get_review_plan_json_summary_reports_error_for_invalid_plan() {
    local test_name="get_review_plan_json_summary: error object for invalid plan"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local plan_file="$PROJECT_DIR/test/fixtures/plans/missing-fields.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local output rc=0
    output=$(get_review_plan_json_summary "$plan_file") || rc=$?
    assert_equals "1" "$rc" "Invalid plan should return non-zero"

    assert_exit_code 0 "Error JSON should parse" jq -e '.' <<<"$output"
    assert_contains "$output" "\"error\"" "Should emit error field"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# archive_review_plan
#------------------------------------------------------------------------------

test_archive_review_plan_copies_into_state_dir() {
    local test_name="archive_review_plan: copies plan into review state"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-arch-1"

    local plan_file="$PROJECT_DIR/test/fixtures/plans/valid-plan.json"
    assert_file_exists "$plan_file" "Fixture should exist"

    local repo_id="octo/repo1"
    assert_exit_code 0 "archive_review_plan should succeed" archive_review_plan "$repo_id" "$plan_file"

    local state_dir
    state_dir=$(get_review_state_dir)
    local archived="$state_dir/applied-plans/$REVIEW_RUN_ID/octo_repo1.json"
    assert_file_exists "$archived" "Archived plan should exist"
    assert_equals "octo/repo1" "$(jq -r '.repo' "$archived")" "Archived plan should match content"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# State persistence: locking + atomic write
#------------------------------------------------------------------------------

test_write_json_atomic_with_lock() {
    local test_name="write_json_atomic: writes JSON under lock"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    require_flock_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local state_dir
    state_dir=$(get_review_state_dir)
    local out_file="$state_dir/test-state.json"

    local payload='{"ok":true,"count":3}'

    assert_exit_code 0 "write_json_atomic should succeed" with_state_lock write_json_atomic "$out_file" "$payload"
    assert_file_exists "$out_file" "State file should exist"
    assert_equals "true" "$(jq -r '.ok' "$out_file")" "JSON content should be written"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

run_test test_parse_graphql_work_items_filters_archived_and_fork
run_test test_parse_graphql_work_items_empty_response_returns_empty
run_test test_discover_work_items_builds_items_from_fixture
run_test test_discover_work_items_handles_empty_graphql_response
run_test test_calculate_item_priority_score_components
run_test test_calculate_item_priority_score_recent_review_penalty
run_test test_calculate_item_priority_score_draft_pr_penalty
run_test test_calculate_item_priority_score_security_label
run_test test_calculate_item_priority_score_very_old_bug
run_test test_calculate_item_priority_score_stale_feature
run_test test_calculate_item_priority_score_clamps_to_zero
run_test test_get_priority_level_thresholds
run_test test_passes_priority_thresholds
run_test test_score_and_sort_work_items_orders_and_filters
run_test test_score_and_sort_draft_pr_ranked_lower
run_test test_validate_review_plan_unanswered_questions_structurally_valid
run_test test_validate_review_plan_accepts_valid
run_test test_validate_review_plan_rejects_missing_fields
run_test test_validate_review_plan_rejects_invalid_decision
run_test test_validate_review_plan_rejects_invalid_gh_target
run_test test_validate_review_plan_rejects_invalid_schema_version
run_test test_validate_review_plan_accepts_large_plan
run_test test_summarize_review_plan_prints_counts
run_test test_get_review_plan_json_summary_is_parseable
run_test test_get_review_plan_json_summary_reports_error_for_invalid_plan
run_test test_archive_review_plan_copies_into_state_dir
run_test test_write_json_atomic_with_lock

print_results
exit $?
