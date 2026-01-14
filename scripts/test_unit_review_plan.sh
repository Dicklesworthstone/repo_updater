#!/usr/bin/env bash
#
# Unit tests: Review plan validation
# (validate_review_plan, summarize_review_plan, get_review_plan_json_summary)
#
# Tests the review plan artifact schema validation and summary generation.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source helpers
source_ru_function "json_escape"
source_ru_function "validate_review_plan"
source_ru_function "summarize_review_plan"
source_ru_function "get_review_plan_json_summary"

# Mock log functions for testing
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

#==============================================================================
# Test Fixtures
#==============================================================================

create_valid_plan() {
    local plan_file="$1"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "run_id": "20250104-103000-12345",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [
    {
      "type": "issue",
      "number": 42,
      "title": "Authentication fails on Windows",
      "priority": "high",
      "decision": "fix",
      "notes": "Root cause: path separator in auth.py:234",
      "risk_level": "low",
      "files_changed": ["src/auth.py"],
      "lines_changed": 5
    },
    {
      "type": "pr",
      "number": 15,
      "title": "Add Redis caching",
      "priority": "normal",
      "decision": "skip",
      "notes": "Out of scope - adds external dependency"
    }
  ],
  "questions": [
    {
      "id": "q1",
      "prompt": "Should I refactor all path handling or just fix this case?",
      "options": [
        {"label": "Quick fix", "description": "Fix only auth.py (5 lines)"},
        {"label": "Full refactor", "description": "Modernize all paths (45 lines)"}
      ],
      "recommended": "Quick fix",
      "answered": true,
      "answer": "Quick fix",
      "answered_at": "2025-01-04T10:35:00Z"
    }
  ],
  "git": {
    "branch": "ru/review/20250104-103000-12345/owner-repo",
    "base_ref": "main",
    "commits": [
      {
        "sha": "abc123def456",
        "subject": "Fix Windows path handling in auth.py",
        "files": ["src/auth.py"],
        "insertions": 3,
        "deletions": 2
      }
    ],
    "tests": {
      "ran": true,
      "ok": true,
      "command": "make test",
      "output_summary": "12 tests passed",
      "duration_seconds": 45
    }
  },
  "gh_actions": [
    {
      "op": "comment",
      "target": "issue#42",
      "body": "Fixed in commit abc123."
    },
    {
      "op": "close",
      "target": "issue#42",
      "reason": "completed"
    }
  ],
  "metadata": {
    "started_at": "2025-01-04T10:30:00Z",
    "completed_at": "2025-01-04T10:45:00Z",
    "duration_seconds": 900,
    "model": "claude-sonnet-4",
    "driver": "local"
  }
}
EOF
}

create_minimal_valid_plan() {
    local plan_file="$1"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": []
}
EOF
}

#==============================================================================
# Tests: validate_review_plan
#==============================================================================

test_validate_plan_file_not_found() {
    local test_name="validate_review_plan: missing file returns error"
    log_test_start "$test_name"

    local result
    result=$(validate_review_plan "/nonexistent/path/plan.json")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "not found" "Should report file not found"

    log_test_pass "$test_name"
}

test_validate_plan_invalid_json() {
    local test_name="validate_review_plan: invalid JSON returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/invalid.json"
    echo "{ not valid json }" > "$plan_file"

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Invalid JSON" "Should report invalid JSON"

    log_test_pass "$test_name"
}

test_validate_plan_missing_schema_version() {
    local test_name="validate_review_plan: missing schema_version returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    echo '{"repo": "owner/repo", "items": []}' > "$plan_file"

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Missing required fields" "Should report missing fields"

    log_test_pass "$test_name"
}

test_validate_plan_wrong_schema_version() {
    local test_name="validate_review_plan: unsupported schema version returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    echo '{"schema_version": 99, "repo": "owner/repo", "items": []}' > "$plan_file"

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Unsupported schema version" "Should report unsupported version"

    log_test_pass "$test_name"
}

test_validate_plan_missing_item_fields() {
    local test_name="validate_review_plan: items missing required fields returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [{"type": "issue"}]
}
EOF

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Items missing required fields" "Should report missing item fields"

    log_test_pass "$test_name"
}

test_validate_plan_invalid_item_type() {
    local test_name="validate_review_plan: invalid item type returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [{"type": "bug", "number": 1, "decision": "fix"}]
}
EOF

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Invalid item type" "Should report invalid type"

    log_test_pass "$test_name"
}

test_validate_plan_invalid_decision() {
    local test_name="validate_review_plan: invalid decision returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [{"type": "issue", "number": 1, "decision": "maybe"}]
}
EOF

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Invalid decision" "Should report invalid decision"

    log_test_pass "$test_name"
}

test_validate_plan_invalid_gh_action_op() {
    local test_name="validate_review_plan: invalid gh_action op returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "gh_actions": [{"op": "delete", "target": "issue#1"}]
}
EOF

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Invalid gh_action op" "Should report invalid op"

    log_test_pass "$test_name"
}

test_validate_plan_invalid_gh_action_target() {
    local test_name="validate_review_plan: invalid gh_action target format returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    cat > "$plan_file" << 'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "gh_actions": [{"op": "comment", "target": "bug42"}]
}
EOF

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Invalid gh_action target" "Should report invalid target format"

    log_test_pass "$test_name"
}

test_validate_plan_valid_minimal() {
    local test_name="validate_review_plan: minimal valid plan passes"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    create_minimal_valid_plan "$plan_file"

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return zero exit code"
    assert_equals "Valid" "$result" "Should report Valid"

    log_test_pass "$test_name"
}

test_validate_plan_valid_full() {
    local test_name="validate_review_plan: full valid plan passes"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    create_valid_plan "$plan_file"

    local result
    result=$(validate_review_plan "$plan_file")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return zero exit code"
    assert_equals "Valid" "$result" "Should report Valid"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: summarize_review_plan
#==============================================================================

test_summarize_invalid_plan() {
    local test_name="summarize_review_plan: invalid plan returns error"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    echo '{}' > "$plan_file"

    local result
    result=$(summarize_review_plan "$plan_file")
    local exit_code=$?

    assert_not_equals 0 "$exit_code" "Should return non-zero exit code"
    assert_contains "$result" "Cannot summarize invalid plan" "Should report invalid plan"

    log_test_pass "$test_name"
}

test_summarize_valid_plan() {
    local test_name="summarize_review_plan: valid plan produces summary"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    create_valid_plan "$plan_file"

    local result
    result=$(summarize_review_plan "$plan_file")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return zero exit code"
    assert_contains "$result" "Repository: owner/repo" "Should include repository"
    assert_contains "$result" "Items reviewed: 2" "Should count items"
    assert_contains "$result" "Fixed: 1" "Should count fixed"
    assert_contains "$result" "Skipped: 1" "Should count skipped"
    assert_contains "$result" "Issues: 1" "Should count issues"
    assert_contains "$result" "PRs: 1" "Should count PRs"
    assert_contains "$result" "Commits: 1" "Should count commits"
    assert_contains "$result" "Tests: PASS" "Should show test status"
    assert_contains "$result" "gh_actions pending: 2" "Should count gh_actions"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: get_review_plan_json_summary
#==============================================================================

test_json_summary_valid_plan() {
    local test_name="get_review_plan_json_summary: valid plan produces JSON"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local plan_file="$test_env/plan.json"
    create_valid_plan "$plan_file"

    local result
    result=$(get_review_plan_json_summary "$plan_file")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return zero exit code"

    # Verify JSON is valid
    if ! echo "$result" | jq empty 2>/dev/null; then
        fail "Output should be valid JSON"
    fi

    # Check JSON content
    local repo total_items fix_count
    repo=$(echo "$result" | jq -r '.repo')
    total_items=$(echo "$result" | jq -r '.summary.total_items')
    fix_count=$(echo "$result" | jq -r '.summary.by_decision.fix')

    assert_equals "owner/repo" "$repo" "Should have correct repo"
    assert_equals "2" "$total_items" "Should have correct item count"
    assert_equals "1" "$fix_count" "Should have correct fix count"

    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Review Plan Validation"

    # validate_review_plan tests
    run_test test_validate_plan_file_not_found
    run_test test_validate_plan_invalid_json
    run_test test_validate_plan_missing_schema_version
    run_test test_validate_plan_wrong_schema_version
    run_test test_validate_plan_missing_item_fields
    run_test test_validate_plan_invalid_item_type
    run_test test_validate_plan_invalid_decision
    run_test test_validate_plan_invalid_gh_action_op
    run_test test_validate_plan_invalid_gh_action_target
    run_test test_validate_plan_valid_minimal
    run_test test_validate_plan_valid_full

    # summarize_review_plan tests
    run_test test_summarize_invalid_plan
    run_test test_summarize_valid_plan

    # get_review_plan_json_summary tests
    run_test test_json_summary_valid_plan

    print_results
    return "$(get_exit_code)"
}

run_all_tests
