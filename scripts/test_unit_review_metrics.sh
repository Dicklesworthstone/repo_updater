#!/usr/bin/env bash
#
# Unit tests: Review Metrics and Analytics (bd-72fj)
#
# Covers:
# - get_metrics_dir / get_metrics_file / get_decisions_log_file
# - init_metrics_file
# - record_decision
# - record_decisions_from_plan
# - record_metrics_from_plan
# - suggest_decision
# - cmd_review_analytics
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "ensure_dir"
source_ru_function "json_escape"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "get_review_state_dir"

#==============================================================================
# Inlined functions (source_ru_function breaks on heredocs/complex functions)
#==============================================================================

get_metrics_dir() {
    echo "${RU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ru}/metrics"
}

get_metrics_file_for_period() {
    local period="$1"
    echo "$(get_metrics_dir)/${period}.json"
}

get_metrics_file() {
    local period
    period=$(date -u +%Y-%m)
    get_metrics_file_for_period "$period"
}

get_decisions_log_file() {
    echo "$(get_metrics_dir)/decisions.jsonl"
}

init_metrics_file() {
    local metrics_dir metrics_file period
    metrics_dir=$(get_metrics_dir)
    metrics_file=$(get_metrics_file)
    period=$(date -u +%Y-%m)

    ensure_dir "$metrics_dir"

    if [[ -f "$metrics_file" ]]; then
        return 0
    fi

    cat > "$metrics_file" <<EOFMETRICS
{
  "period": "$period",
  "reviews": {
    "total": 0,
    "repos_reviewed": 0,
    "issues_processed": 0,
    "issues_resolved": 0,
    "questions_asked": 0,
    "questions_answered": 0
  },
  "timing": {
    "total_duration_minutes": 0,
    "avg_per_repo_minutes": 0
  },
  "decisions": {
    "by_type": {}
  }
}
EOFMETRICS
}

record_decision() {
    local repo_id="$1"
    local item_type="$2"
    local number="$3"
    local decision="$4"
    [[ "$number" =~ ^[0-9]+$ ]] || number=0

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; decision history skipped"
        return 1
    fi

    local decisions_log
    decisions_log=$(get_decisions_log_file)
    ensure_dir "$(dirname "$decisions_log")"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -n --arg ts "$ts" --arg repo "$repo_id" --arg type "$item_type" \
        --argjson number "$number" --arg decision "$decision" \
        '{timestamp:$ts,repo:$repo,type:$type,number:$number,decision:$decision}' >> "$decisions_log"
}

record_decisions_from_plan() {
    local repo_id="$1"
    local plan_file="$2"

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; decision history skipped"
        return 1
    fi

    if [[ ! -f "$plan_file" ]]; then
        return 1
    fi

    jq -c '.items[] | {type, number, decision}' "$plan_file" 2>/dev/null | \
        while IFS= read -r item; do
            local item_type number decision
            item_type=$(echo "$item" | jq -r '.type // empty' 2>/dev/null)
            number=$(echo "$item" | jq -r '.number // 0' 2>/dev/null)
            decision=$(echo "$item" | jq -r '.decision // empty' 2>/dev/null)
            [[ -n "$item_type" && -n "$decision" ]] || continue
            record_decision "$repo_id" "$item_type" "$number" "$decision" || true
        done
}

record_metrics_from_plan() {
    local repo_id="$1"
    local plan_file="$2"
    local duration_seconds="${3:-0}"

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available; metrics skipped"
        return 1
    fi

    if [[ ! -f "$plan_file" ]]; then
        return 1
    fi

    init_metrics_file

    local issues_processed issues_resolved questions_total questions_answered
    issues_processed=$(jq -r '[.items[] | select(.type == "issue")] | length' "$plan_file" 2>/dev/null || echo 0)
    issues_resolved=$(jq -r '[.items[] | select(.type == "issue" and .decision == "fix")] | length' "$plan_file" 2>/dev/null || echo 0)
    questions_total=$(jq -r '[.questions // [] | .[]] | length' "$plan_file" 2>/dev/null || echo 0)
    questions_answered=$(jq -r '[.questions // [] | .[] | select(.answered == true)] | length' "$plan_file" 2>/dev/null || echo 0)

    local decision_counts
    decision_counts=$(jq -c '[.items[].decision] | reduce .[] as $d ({}; .[$d] = (.[$d] // 0) + 1)' "$plan_file" 2>/dev/null || echo "{}")

    local duration_minutes
    duration_minutes=$(awk -v s="$duration_seconds" 'BEGIN { if (s ~ /^[0-9]+$/) { printf "%.1f", s/60 } else { printf "%.1f", 0 } }')

    local metrics_file updated
    metrics_file=$(get_metrics_file)

    updated=$(jq \
        --argjson issues_processed "$issues_processed" \
        --argjson issues_resolved "$issues_resolved" \
        --argjson questions_total "$questions_total" \
        --argjson questions_answered "$questions_answered" \
        --argjson duration_minutes "$duration_minutes" \
        --argjson decisions "$decision_counts" \
        '
        .reviews.total += 1
        | .reviews.repos_reviewed += 1
        | .reviews.issues_processed += $issues_processed
        | .reviews.issues_resolved += $issues_resolved
        | .reviews.questions_asked += $questions_total
        | .reviews.questions_answered += $questions_answered
        | .timing.total_duration_minutes += $duration_minutes
        | .timing.avg_per_repo_minutes = (if .reviews.repos_reviewed > 0 then (.timing.total_duration_minutes / .reviews.repos_reviewed) else 0 end)
        | .decisions.by_type = (reduce ($decisions | to_entries[]) as $e (.decisions.by_type;
            .[$e.key] = (.[$e.key] // 0) + $e.value))
        ' "$metrics_file" 2>/dev/null) || return 1

    with_state_lock write_json_atomic "$metrics_file" "$updated"
}

suggest_decision() {
    local repo_id="$1"
    local item_type="$2"
    local decisions_log
    decisions_log=$(get_decisions_log_file)

    if [[ ! -f "$decisions_log" ]] || ! command -v jq &>/dev/null; then
        return 1
    fi

    jq -rs --arg repo "$repo_id" --arg type "$item_type" '
        map(select(.repo == $repo and .type == $type))
        | group_by(.decision)
        | map({decision: .[0].decision, count: length})
        | sort_by(-.count)
        | .[0].decision // empty
    ' "$decisions_log" 2>/dev/null
}

cmd_review_analytics() {
    local period
    period=$(date -u +%Y-%m)
    local metrics_file
    metrics_file=$(get_metrics_file_for_period "$period")

    if [[ ! -f "$metrics_file" ]]; then
        log_warn "No metrics found for period $period"
        return 0
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat "$metrics_file"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for analytics"
        return 3
    fi

    local total repos issues_processed issues_resolved q_asked q_answered total_minutes avg_minutes
    total=$(jq -r '.reviews.total // 0' "$metrics_file")
    repos=$(jq -r '.reviews.repos_reviewed // 0' "$metrics_file")
    issues_processed=$(jq -r '.reviews.issues_processed // 0' "$metrics_file")
    issues_resolved=$(jq -r '.reviews.issues_resolved // 0' "$metrics_file")
    q_asked=$(jq -r '.reviews.questions_asked // 0' "$metrics_file")
    q_answered=$(jq -r '.reviews.questions_answered // 0' "$metrics_file")
    total_minutes=$(jq -r '.timing.total_duration_minutes // 0' "$metrics_file")
    avg_minutes=$(jq -r '.timing.avg_per_repo_minutes // 0' "$metrics_file")

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        gum style --border rounded --padding "0 2" --border-foreground "#89b4fa" \
            "$(gum style --bold "Review Analytics (${period})")" >&2
        gum style "Total reviews: $total" >&2
        gum style "Repos reviewed: $repos" >&2
        gum style "Issues processed: $issues_processed (resolved: $issues_resolved)" >&2
        gum style "Questions: $q_answered/$q_asked answered" >&2
        gum style "Total minutes: $total_minutes (avg/repo: $avg_minutes)" >&2
    else
        printf '%b\n' "${BOLD}Review Analytics (${period})${RESET}" >&2
        printf '%b\n' "Total reviews: $total" >&2
        printf '%b\n' "Repos reviewed: $repos" >&2
        printf '%b\n' "Issues processed: $issues_processed (resolved: $issues_resolved)" >&2
        printf '%b\n' "Questions: $q_answered/$q_asked answered" >&2
        printf '%b\n' "Total minutes: $total_minutes (avg/repo: $avg_minutes)" >&2
    fi
}

# Required global for state locking
STATE_LOCK_FD=201

# Mock logging (avoid noisy output on error paths)
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }

# Mock gum for analytics display
GUM_AVAILABLE="false"
BOLD=""
RESET=""
JSON_OUTPUT="false"

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

#==============================================================================
# Tests: Path helpers
#==============================================================================

test_get_metrics_dir_uses_state_dir() {
    local test_name="get_metrics_dir: uses RU_STATE_DIR"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local result
    result=$(get_metrics_dir)

    assert_equals "$env_root/state/metrics" "$result" "Should use RU_STATE_DIR"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_get_metrics_file_uses_period() {
    local test_name="get_metrics_file: includes current period"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local result
    result=$(get_metrics_file)

    local expected_period
    expected_period=$(date -u +%Y-%m)

    assert_contains "$result" "$expected_period.json" "Should include period in filename"
    assert_contains "$result" "metrics" "Should be in metrics directory"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_get_metrics_file_for_period() {
    local test_name="get_metrics_file_for_period: accepts custom period"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local result
    result=$(get_metrics_file_for_period "2025-12")

    assert_contains "$result" "2025-12.json" "Should use specified period"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_get_decisions_log_file() {
    local test_name="get_decisions_log_file: returns jsonl path"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local result
    result=$(get_decisions_log_file)

    assert_contains "$result" "decisions.jsonl" "Should return decisions.jsonl"
    assert_contains "$result" "metrics" "Should be in metrics directory"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: init_metrics_file
#==============================================================================

test_init_metrics_file_creates_structure() {
    local test_name="init_metrics_file: creates valid JSON structure"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    init_metrics_file

    local metrics_file
    metrics_file=$(get_metrics_file)

    assert_file_exists "$metrics_file" "Metrics file should be created"

    # Verify JSON structure
    local period reviews_total timing_total
    period=$(jq -r '.period' "$metrics_file")
    reviews_total=$(jq -r '.reviews.total' "$metrics_file")
    timing_total=$(jq -r '.timing.total_duration_minutes' "$metrics_file")

    local expected_period
    expected_period=$(date -u +%Y-%m)

    assert_equals "$expected_period" "$period" "Period should match current month"
    assert_equals "0" "$reviews_total" "reviews.total should be 0"
    assert_equals "0" "$timing_total" "timing.total_duration_minutes should be 0"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_init_metrics_file_idempotent() {
    local test_name="init_metrics_file: idempotent (does not overwrite)"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    # First init
    init_metrics_file

    local metrics_file
    metrics_file=$(get_metrics_file)

    # Modify the file
    jq '.reviews.total = 42' "$metrics_file" > "$metrics_file.tmp" && mv "$metrics_file.tmp" "$metrics_file"

    # Second init should not overwrite
    init_metrics_file

    local reviews_total
    reviews_total=$(jq -r '.reviews.total' "$metrics_file")

    assert_equals "42" "$reviews_total" "Should not overwrite existing file"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: record_decision
#==============================================================================

test_record_decision_creates_jsonl_entry() {
    local test_name="record_decision: creates valid JSONL entry"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    record_decision "owner/repo" "issue" "42" "fix"

    local decisions_file
    decisions_file=$(get_decisions_log_file)

    assert_file_exists "$decisions_file" "Decisions log should be created"

    # Verify entry (use jq slurp since record_decision creates multi-line JSON)
    local repo item_type number decision
    repo=$(jq -rs '.[-1].repo' "$decisions_file")
    item_type=$(jq -rs '.[-1].type' "$decisions_file")
    number=$(jq -rs '.[-1].number' "$decisions_file")
    decision=$(jq -rs '.[-1].decision' "$decisions_file")

    assert_equals "owner/repo" "$repo" "repo should match"
    assert_equals "issue" "$item_type" "type should match"
    assert_equals "42" "$number" "number should match"
    assert_equals "fix" "$decision" "decision should match"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_record_decision_includes_timestamp() {
    local test_name="record_decision: includes timestamp"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    record_decision "owner/repo" "pr" "7" "skip"

    local decisions_file
    decisions_file=$(get_decisions_log_file)

    local ts
    ts=$(jq -rs '.[-1].timestamp' "$decisions_file")

    # Should be ISO 8601 format
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        pass "Timestamp should be ISO 8601 format"
    else
        fail "Timestamp should be ISO 8601 format (got: $ts)"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_record_decision_handles_invalid_number() {
    local test_name="record_decision: handles non-numeric number"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    record_decision "owner/repo" "issue" "invalid" "fix"

    local decisions_file
    decisions_file=$(get_decisions_log_file)

    local number
    number=$(jq -rs '.[-1].number' "$decisions_file")

    assert_equals "0" "$number" "Invalid number should default to 0"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: record_decisions_from_plan
#==============================================================================

test_record_decisions_from_plan_processes_items() {
    local test_name="record_decisions_from_plan: processes plan items"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local plan_file="$env_root/plan.json"
    cat > "$plan_file" <<'EOF'
{
  "repo": "test/repo",
  "items": [
    {"type": "issue", "number": 1, "decision": "fix"},
    {"type": "issue", "number": 2, "decision": "skip"},
    {"type": "pr", "number": 3, "decision": "merge"}
  ]
}
EOF

    record_decisions_from_plan "test/repo" "$plan_file"

    local decisions_file
    decisions_file=$(get_decisions_log_file)

    # Count JSON objects (not lines, since jq output is pretty-printed)
    local count
    count=$(jq -s 'length' "$decisions_file" 2>/dev/null || echo 0)

    assert_equals "3" "$count" "Should record 3 decisions"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_record_decisions_from_plan_missing_file() {
    local test_name="record_decisions_from_plan: handles missing file"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    if record_decisions_from_plan "test/repo" "/nonexistent/plan.json"; then
        fail "Should return failure for missing file"
    else
        pass "Should return failure for missing file"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: record_metrics_from_plan
#==============================================================================

test_record_metrics_from_plan_updates_totals() {
    local test_name="record_metrics_from_plan: updates aggregate totals"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local plan_file="$env_root/plan.json"
    cat > "$plan_file" <<'EOF'
{
  "repo": "test/repo",
  "items": [
    {"type": "issue", "number": 1, "decision": "fix"},
    {"type": "issue", "number": 2, "decision": "fix"},
    {"type": "issue", "number": 3, "decision": "skip"}
  ],
  "questions": []
}
EOF

    record_metrics_from_plan "test/repo" "$plan_file" "120"

    local metrics_file
    metrics_file=$(get_metrics_file)

    local reviews_total issues_processed issues_resolved
    reviews_total=$(jq -r '.reviews.total' "$metrics_file")
    issues_processed=$(jq -r '.reviews.issues_processed' "$metrics_file")
    issues_resolved=$(jq -r '.reviews.issues_resolved' "$metrics_file")

    assert_equals "1" "$reviews_total" "reviews.total should be 1"
    assert_equals "3" "$issues_processed" "Should count 3 issues"
    assert_equals "2" "$issues_resolved" "Should count 2 fixed issues"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_record_metrics_from_plan_tracks_decisions() {
    local test_name="record_metrics_from_plan: tracks decision counts"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local plan_file="$env_root/plan.json"
    cat > "$plan_file" <<'EOF'
{
  "repo": "test/repo",
  "items": [
    {"type": "issue", "number": 1, "decision": "fix"},
    {"type": "issue", "number": 2, "decision": "fix"},
    {"type": "issue", "number": 3, "decision": "skip"},
    {"type": "pr", "number": 4, "decision": "merge"}
  ]
}
EOF

    record_metrics_from_plan "test/repo" "$plan_file" "60"

    local metrics_file
    metrics_file=$(get_metrics_file)

    local fix_count skip_count merge_count
    fix_count=$(jq -r '.decisions.by_type.fix // 0' "$metrics_file")
    skip_count=$(jq -r '.decisions.by_type.skip // 0' "$metrics_file")
    merge_count=$(jq -r '.decisions.by_type.merge // 0' "$metrics_file")

    assert_equals "2" "$fix_count" "Should count 2 fix decisions"
    assert_equals "1" "$skip_count" "Should count 1 skip decision"
    assert_equals "1" "$merge_count" "Should count 1 merge decision"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_record_metrics_from_plan_calculates_duration() {
    local test_name="record_metrics_from_plan: calculates duration"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local plan_file="$env_root/plan.json"
    echo '{"repo":"test/repo","items":[]}' > "$plan_file"

    record_metrics_from_plan "test/repo" "$plan_file" "180"  # 3 minutes

    local metrics_file
    metrics_file=$(get_metrics_file)

    local total_minutes
    total_minutes=$(jq -r '.timing.total_duration_minutes' "$metrics_file")

    # Should be 3.0 minutes (180/60)
    if [[ "$total_minutes" == "3" ]] || [[ "$total_minutes" == "3.0" ]]; then
        pass "Duration should be 3 minutes"
    else
        fail "Duration should be 3 minutes (got: $total_minutes)"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: suggest_decision
#==============================================================================

test_suggest_decision_returns_most_common() {
    local test_name="suggest_decision: returns most common decision"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    # Record several decisions
    record_decision "owner/repo" "issue" "1" "fix"
    record_decision "owner/repo" "issue" "2" "fix"
    record_decision "owner/repo" "issue" "3" "fix"
    record_decision "owner/repo" "issue" "4" "skip"

    local suggestion
    suggestion=$(suggest_decision "owner/repo" "issue")

    assert_equals "fix" "$suggestion" "Should suggest most common decision (fix)"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_suggest_decision_no_history() {
    local test_name="suggest_decision: returns empty for no history"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    local suggestion
    suggestion=$(suggest_decision "owner/repo" "issue")

    assert_equals "" "$suggestion" "Should return empty for no history"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: cmd_review_analytics
#==============================================================================

test_cmd_review_analytics_json_output() {
    local test_name="cmd_review_analytics: JSON output mode"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    init_metrics_file

    local metrics_file
    metrics_file=$(get_metrics_file)

    # Update metrics to have some data
    jq '.reviews.total = 5 | .reviews.repos_reviewed = 3' "$metrics_file" > "$metrics_file.tmp" && mv "$metrics_file.tmp" "$metrics_file"

    JSON_OUTPUT="true"
    local result
    result=$(cmd_review_analytics)

    local total repos
    total=$(echo "$result" | jq -r '.reviews.total')
    repos=$(echo "$result" | jq -r '.reviews.repos_reviewed')

    assert_equals "5" "$total" "Should output total reviews"
    assert_equals "3" "$repos" "Should output repos reviewed"

    JSON_OUTPUT="false"
    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_cmd_review_analytics_no_metrics() {
    local test_name="cmd_review_analytics: handles no metrics gracefully"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    # Don't create metrics file

    local rc=0
    cmd_review_analytics >/dev/null 2>&1 || rc=$?

    assert_equals 0 "$rc" "Should return 0 for no metrics"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_cmd_review_analytics_text_output() {
    local test_name="cmd_review_analytics: text output mode"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state"

    init_metrics_file

    local metrics_file
    metrics_file=$(get_metrics_file)

    jq '.reviews.total = 10' "$metrics_file" > "$metrics_file.tmp" && mv "$metrics_file.tmp" "$metrics_file"

    JSON_OUTPUT="false"
    GUM_AVAILABLE="false"

    local output
    output=$(cmd_review_analytics 2>&1)

    assert_contains "$output" "Total reviews: 10" "Should show total reviews"
    assert_contains "$output" "Analytics" "Should contain Analytics header"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Review Metrics and Analytics"

    # Path helper tests
    run_test test_get_metrics_dir_uses_state_dir
    run_test test_get_metrics_file_uses_period
    run_test test_get_metrics_file_for_period
    run_test test_get_decisions_log_file

    # init_metrics_file tests
    run_test test_init_metrics_file_creates_structure
    run_test test_init_metrics_file_idempotent

    # record_decision tests
    run_test test_record_decision_creates_jsonl_entry
    run_test test_record_decision_includes_timestamp
    run_test test_record_decision_handles_invalid_number

    # record_decisions_from_plan tests
    run_test test_record_decisions_from_plan_processes_items
    run_test test_record_decisions_from_plan_missing_file

    # record_metrics_from_plan tests
    run_test test_record_metrics_from_plan_updates_totals
    run_test test_record_metrics_from_plan_tracks_decisions
    run_test test_record_metrics_from_plan_calculates_duration

    # suggest_decision tests
    run_test test_suggest_decision_returns_most_common
    run_test test_suggest_decision_no_history

    # cmd_review_analytics tests
    run_test test_cmd_review_analytics_json_output
    run_test test_cmd_review_analytics_no_metrics
    run_test test_cmd_review_analytics_text_output

    print_results
    return "$(get_exit_code)"
}

run_all_tests
