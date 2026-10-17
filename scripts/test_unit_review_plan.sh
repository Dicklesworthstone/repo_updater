#!/usr/bin/env bash
#
# Unit tests: Review plan validation
# (validate_review_plan, summarize_review_plan, get_review_plan_json_summary)
#
# Tests the review plan artifact schema validation and summary generation.
# JSON fixture coverage only: physical Git identity, approval and publication
# are verified separately by the apply workflow tests.
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
  "run_id": "run-minimal",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [],
  "metadata": {
    "started_at": "2025-01-04T10:30:00Z",
    "completed_at": "2025-01-04T10:45:00Z",
    "model": "claude-sonnet-4",
    "driver": "local"
  }
}
EOF
}

# Each malformed candidate differs from a valid control by the named field(s).
# These are runtime JSON fixtures, not edits to checked-in source files.
assert_plan_schema_pair() {
    local invalid_filter="$1" valid_filter="$2" case_name="$3"
    local test_env
    test_env=$(create_test_env)
    local source_plan="$test_env/source.json"
    local candidate="$test_env/candidate.json"
    local result rc=0 fixture_rc=0
    create_valid_plan "$source_plan"

    jq "$valid_filter" "$source_plan" > "$candidate" || fixture_rc=$?
    assert_equals "0" "$fixture_rc" "$case_name: valid fixture was generated"
    result=$(validate_review_plan "$candidate") || rc=$?
    assert_equals "0" "$rc" "$case_name: valid control accepted ($result)"
    assert_equals "Valid" "$result" "$case_name: valid control reports Valid"

    fixture_rc=0
    jq "$invalid_filter" "$source_plan" > "$candidate" || fixture_rc=$?
    assert_equals "0" "$fixture_rc" "$case_name: malformed fixture was generated"
    rc=0
    result=$(validate_review_plan "$candidate") || rc=$?
    assert_equals "1" "$rc" "$case_name: malformed candidate rejected ($result)"
    assert_not_equals "Valid" "$result" "$case_name: refusal is explicit"
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
    create_minimal_valid_plan "$test_env/source.json"
    jq 'del(.schema_version)' "$test_env/source.json" > "$plan_file"

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
    create_minimal_valid_plan "$test_env/source.json"
    jq '.schema_version = 99' "$test_env/source.json" > "$plan_file"

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
  "run_id": "run-missing-item-fields",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [{"type": "issue"}],
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"claude-sonnet-4","driver":"local"}
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
  "run_id": "run-invalid-item-type",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [{"type": "bug", "number": 1, "title": "Fix auth", "priority": "high", "decision": "fix"}],
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"claude-sonnet-4","driver":"local"}
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
  "run_id": "run-invalid-decision",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [{"type": "issue", "number": 1, "title": "Fix auth", "priority": "high", "decision": "maybe"}],
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"claude-sonnet-4","driver":"local"}
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
  "run_id": "run-invalid-action-op",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [],
  "gh_actions": [{"op": "delete", "target": "issue#1"}],
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"claude-sonnet-4","driver":"local"}
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
  "run_id": "run-invalid-action-target",
  "repo": "owner/repo",
  "worktree_path": "/tmp/test-worktree",
  "items": [],
  "gh_actions": [{"op": "comment", "target": "bug42", "body": "Fix auth"}],
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"claude-sonnet-4","driver":"local"}
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

test_validate_plan_rejects_legacy_minimal() {
    local test_name="validate_review_plan: legacy minimal shape lacks original required identity"
    log_test_start "$test_name"
    local test_env result rc=0
    test_env=$(create_test_env)
    local plan_file="$test_env/plan.json"

    echo '{"schema_version":1,"repo":"wrong/repo","items":[]}' > "$plan_file"
    result=$(validate_review_plan "$plan_file") || rc=$?
    assert_equals "1" "$rc" "Missing original identity and metadata must reject"
    assert_not_equals "Valid" "$result" "Legacy minimal shape must not report Valid"

    # Schema validation accepts any well-formed owner/repo. Physical ownership
    # is an apply-phase check, not a hard-coded schema restriction.
    create_minimal_valid_plan "$test_env/source.json"
    jq '.repo = "wrong/repo"' "$test_env/source.json" > "$plan_file"
    rc=0
    result=$(validate_review_plan "$plan_file") || rc=$?
    assert_equals "0" "$rc" "Same repo with original required fields is structurally valid"
    assert_equals "Valid" "$result" "Complete minimal shape must report Valid"
    log_test_pass "$test_name"
}

test_validate_plan_top_level_shapes() {
    local test_name="validate_review_plan: original required fields have exact types"
    log_test_start "$test_name"
    assert_plan_schema_pair 'empty' '.' "Empty JSON file"
    assert_plan_schema_pair '., .' '.' "Multiple JSON documents"
    assert_plan_schema_pair '[.]' '.' "Top-level array"
    assert_plan_schema_pair '.schema_version = "1"' '.schema_version = 1' "String schema version"
    assert_plan_schema_pair '.schema_version = 1.5' '.schema_version = 1' "Fractional schema version"
    assert_plan_schema_pair 'del(.run_id)' '.' "Missing run identity"
    assert_plan_schema_pair '.run_id = ""' '.' "Empty run identity"
    assert_plan_schema_pair '.run_id = 123' '.' "Non-string run identity"
    assert_plan_schema_pair '.repo = "owner"' '.repo = "owner/repo"' "Repo shorthand requires owner and repo"
    assert_plan_schema_pair '.repo = "owner/repo/extra"' '.repo = "owner/repo"' "Repo shorthand rejects extra segment"
    assert_plan_schema_pair '.worktree_path = "relative/worktree"' '.worktree_path = "/tmp/test-worktree"' "Relative worktree path"
    assert_plan_schema_pair '.worktree_path = ""' '.' "Empty worktree path"
    assert_plan_schema_pair 'del(.worktree_path)' '.' "Missing worktree path"
    assert_plan_schema_pair '.items = {}' '.items = []' "Items object instead of array"
    assert_plan_schema_pair 'del(.metadata)' '.' "Missing metadata"
    assert_plan_schema_pair '.metadata = []' '.' "Metadata array instead of object"
    assert_plan_schema_pair '.questions = {}' '.questions = []' "Questions object instead of array"
    assert_plan_schema_pair '.gh_actions = {}' '.gh_actions = []' "Actions object instead of array"
    assert_plan_schema_pair '.git = []' '.git = {}' "Git array instead of object"
    log_test_pass "$test_name"
}

test_validate_plan_item_types_and_numbers() {
    local test_name="validate_review_plan: item numbers are positive integers and fields are required"
    log_test_start "$test_name"
    assert_plan_schema_pair '.items[0] = "issue"' '.' "Non-object item"
    assert_plan_schema_pair '.items[0].number = "42"' '.items[0].number = 42' "String item number"
    assert_plan_schema_pair '.items[0].number = 42.5' '.items[0].number = 42' "Fractional item number"
    assert_plan_schema_pair '.items[0].number = 0' '.items[0].number = 1' "Zero item number"
    assert_plan_schema_pair '.items[0].number = -42' '.items[0].number = 42' "Negative item number"
    assert_plan_schema_pair '.items[0].number = true' '.items[0].number = 42' "Boolean item number"
    assert_plan_schema_pair 'del(.items[0].title)' '.' "Missing item title"
    assert_plan_schema_pair '.items[0].title = ""' '.' "Empty item title"
    assert_plan_schema_pair 'del(.items[0].priority)' '.' "Missing item priority"
    assert_plan_schema_pair '.items[0].priority = ""' '.' "Empty item priority"
    assert_plan_schema_pair '.items[0].priority = 10' '.' "Non-string item priority"
    assert_plan_schema_pair '.items[0].lines_changed = -0.5' '.items[0].lines_changed = -5' "Net line count accepts negative integers"
    log_test_pass "$test_name"
}

test_validate_plan_metadata_fields() {
    local test_name="validate_review_plan: metadata contains timestamps, model and driver"
    log_test_start "$test_name"
    assert_plan_schema_pair 'del(.metadata.started_at)' '.' "Missing start timestamp"
    assert_plan_schema_pair '.metadata.completed_at = ""' '.' "Empty completion timestamp"
    assert_plan_schema_pair '.metadata.model = ""' '.' "Empty model"
    assert_plan_schema_pair '.metadata.driver = "unknown"' '.metadata.driver = "ntm"' "Unknown driver"
    assert_plan_schema_pair '.metadata.duration_seconds = -1' '.metadata.duration_seconds = 0' "Negative duration"
    assert_plan_schema_pair '.metadata.duration_seconds = 0.5' '.metadata.duration_seconds = 1' "Fractional duration"
    assert_plan_schema_pair '.metadata.duration_seconds = "900"' '.metadata.duration_seconds = 900' "String duration"
    log_test_pass "$test_name"
}

test_validate_plan_question_fields() {
    local test_name="validate_review_plan: questions preserve typed answers and unique identities"
    log_test_start "$test_name"
    assert_plan_schema_pair '.questions[0].answered = "true"' '.questions[0].answered = true' "String answered flag"
    assert_plan_schema_pair '.questions[0].answered = 0' '.questions[0].answered = false' "Numeric answered flag"
    assert_plan_schema_pair 'del(.questions[0].answered)' '.questions[0].answered = false' "Missing answered flag"
    assert_plan_schema_pair 'del(.questions[0].answer)' '.' "Answered question lacks answer"
    assert_plan_schema_pair '.questions[0].answer = ""' '.' "Answered question has empty answer"
    assert_plan_schema_pair 'del(.questions[0].answered_at)' '.' "Answered question lacks timestamp"
    assert_plan_schema_pair '.questions[0].answered_at = ""' '.' "Answered question has empty timestamp"
    assert_plan_schema_pair '.questions[0].id = ""' '.' "Empty question identity"
    assert_plan_schema_pair '.questions[0].prompt = ""' '.' "Empty question prompt"
    assert_plan_schema_pair '.questions += [.questions[0]]' '.questions += [(.questions[0] | .id = "q2")]' "Duplicate question identity"
    assert_plan_schema_pair '.questions[0].answered = true | del(.questions[0].answer,.questions[0].answered_at)' '.questions[0].answered = false | del(.questions[0].answer,.questions[0].answered_at)' "Only unanswered questions may omit answers"
    assert_plan_schema_pair '.questions[0] |= (.answered=false | .answer={bad:"object"})' '.questions[0] |= (.answered=false | .answer="pending")' "Present unanswered answer still requires string type"
    assert_plan_schema_pair '.questions[0] |= (.answered=false | .answered_at=0)' '.questions[0] |= (.answered=false | .answered_at="")' "Present unanswered timestamp still requires string type"
    log_test_pass "$test_name"
}

test_validate_plan_action_payloads() {
    local test_name="validate_review_plan: GitHub actions require positive targets and typed payloads"
    log_test_start "$test_name"
    assert_plan_schema_pair '.gh_actions[0] = "comment"' '.' "Non-object action"
    assert_plan_schema_pair '.gh_actions[0].target = "issue#0"' '.gh_actions[0].target = "issue#1"' "Zero target number"
    assert_plan_schema_pair '.gh_actions[0].target = "issue#-1"' '.gh_actions[0].target = "issue#1"' "Negative target number"
    assert_plan_schema_pair '.gh_actions[0].target = "pr#1.5"' '.gh_actions[0].target = "pr#15"' "Fractional target number"
    assert_plan_schema_pair '.gh_actions[0].target = 42' '.gh_actions[0].target = "issue#42"' "Non-string target"
    assert_plan_schema_pair 'del(.gh_actions[0].body)' '.' "Comment lacks body"
    assert_plan_schema_pair '.gh_actions[0].body = ""' '.' "Empty comment body"
    assert_plan_schema_pair '.gh_actions[0].body = {}' '.' "Non-string comment body"
    assert_plan_schema_pair 'del(.gh_actions[1].reason)' '.' "Close lacks reason"
    assert_plan_schema_pair '.gh_actions[1].reason = ""' '.' "Empty close reason"
    assert_plan_schema_pair '.gh_actions[1].reason = "invented_reason"' '.gh_actions[1].reason = "not_planned"' "Unsupported close reason is refused before actions; documented not_planned remains valid"
    assert_plan_schema_pair '.gh_actions[1] = {op:"close",target:"pr#15",reason:{bad:"object"}}' '.gh_actions[1] = {op:"close",target:"pr#15",reason:"Outside contribution declined: adds an unwanted dependency"}' "PR close reason remains descriptive text"
    assert_plan_schema_pair '.gh_actions = [{op:"label",target:"issue#42",labels:[]}]' '.gh_actions = [{op:"label",target:"issue#42",labels:["bug"]}]' "Empty label array"
    assert_plan_schema_pair '.gh_actions = [{op:"label",target:"issue#42",labels:[""]}]' '.gh_actions = [{op:"label",target:"issue#42",labels:["bug"]}]' "Empty label value"
    assert_plan_schema_pair '.gh_actions = [{op:"label",target:"issue#42",labels:[42]}]' '.gh_actions = [{op:"label",target:"issue#42",labels:["bug"]}]' "Non-string label value"
    assert_plan_schema_pair '.gh_actions = [{op:"label",target:"issue#42",labels:"bug"}]' '.gh_actions = [{op:"label",target:"issue#42",labels:["bug"]}]' "Non-array labels"
    assert_plan_schema_pair '.gh_actions = [{op:"label",target:"pr#42",labels:[42]}]' '.gh_actions = [{op:"label",target:"pr#42",labels:["bug"]}]' "PR label action requires typed labels"
    # Merge is a known schema operation; apply policy independently forbids it.
    assert_plan_schema_pair '.gh_actions = [{op:"delete",target:"pr#15"}]' '.gh_actions = [{op:"merge",target:"pr#15"}]' "Known merge representation remains structurally valid"
    log_test_pass "$test_name"
}

test_validate_plan_git_summary_fields() {
    local test_name="validate_review_plan: Git summary commits retain object structure"
    log_test_start "$test_name"
    assert_plan_schema_pair '.git.commits = {}' '.git.commits = []' "Non-array commits"
    assert_plan_schema_pair '.git.commits = ["abc123"]' '.git.commits = [{sha:"abc123"}]' "String commit instead of object"
    assert_plan_schema_pair '.git.commits = [{sha:""}]' '.git.commits = [{sha:"abc123"}]' "Empty commit SHA"
    assert_plan_schema_pair '.git.commits = [{sha:123}]' '.git.commits = [{sha:"abc123"}]' "Non-string commit SHA"
    assert_plan_schema_pair '.git.branch = []' '.git.branch = "ru/review/run-123/owner-repo"' "Non-string branch"
    assert_plan_schema_pair '.git.base_ref = 1' '.git.base_ref = "main"' "Non-string base ref"
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
    run_test test_validate_plan_rejects_legacy_minimal
    run_test test_validate_plan_top_level_shapes
    run_test test_validate_plan_item_types_and_numbers
    run_test test_validate_plan_metadata_fields
    run_test test_validate_plan_question_fields
    run_test test_validate_plan_action_payloads
    run_test test_validate_plan_git_summary_fields

    # summarize_review_plan tests
    run_test test_summarize_invalid_plan
    run_test test_summarize_valid_plan

    # get_review_plan_json_summary tests
    run_test test_json_summary_valid_plan

    print_results
    return "$(get_exit_code)"
}

run_all_tests
