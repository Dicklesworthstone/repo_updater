#!/usr/bin/env bash
#
# Unit tests: gh_actions execution from review plan (bd-vcr9)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Helper functions required by parse_gh_action_target
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "get_review_state_dir"
source_ru_function "get_gh_actions_log_file"
source_ru_function "canonicalize_gh_action"
source_ru_function "gh_action_already_executed"
source_ru_function "record_gh_action_log"
source_ru_function "parse_gh_action_target"
source_ru_function "execute_gh_action_comment"
source_ru_function "execute_gh_action_close"
source_ru_function "execute_gh_action_label"
source_ru_function "execute_gh_actions"

# Mock logging functions used by execute_gh_actions
log_step() { :; }
log_warn() { :; }
log_error() { :; }
log_verbose() { :; }

_write_mock_gh() {
    local bin_dir="$1"
    local mode="${2:-ok}" # ok|fail_close

    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [[ -z "${GH_LOG:-}" ]]; then
  echo "GH_LOG not set" >&2
  exit 2
fi

echo "$*" >> "$GH_LOG"

case "${GH_FAIL_MODE:-}" in
  fail_close)
    if [[ "$1 $2" == "issue close" ]]; then
      echo "simulated failure" >&2
      exit 1
    fi
    ;;
esac

if [[ "$*" == *"--body-file -"* ]]; then
  body=$(cat)
  printf 'BODY:%s\n' "$body" >> "$GH_LOG"
fi
exit 0
EOF
    chmod +x "$bin_dir/gh"

    case "$mode" in
        ok) export GH_FAIL_MODE="" ;;
        fail_close) export GH_FAIL_MODE="fail_close" ;;
        *) export GH_FAIL_MODE="" ;;
    esac
}

test_execute_gh_actions_happy_path_and_idempotent() {
    local test_name="execute_gh_actions: executes actions and is idempotent"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    # Ensure state is isolated to this test env (avoid inheriting RU_STATE_DIR from outer environment)
    export RU_STATE_DIR="$env_root/state/ru"

    export GH_LOG="$env_root/gh.log"
    : > "$GH_LOG"

    local bin_dir="$env_root/bin"
    _write_mock_gh "$bin_dir" "ok"

    local old_path="$PATH"
    export PATH="$bin_dir:$PATH"

    local plan_file="$env_root/review-plan.json"
    cat > "$plan_file" <<'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "gh_actions": [
    {"op":"comment","target":"issue#42","body":"Hello\nWorld|X"},
    {"op":"close","target":"issue#42","reason":"completed"},
    {"op":"label","target":"issue#42","labels":["fixed-in-main","needs-review"]},
    {"op":"comment","target":"pr#15","body":"Thanks!"}
  ]
}
EOF

    assert_exit_code 0 "execute_gh_actions should succeed" execute_gh_actions "owner/repo" "$plan_file"

    assert_file_contains "$GH_LOG" "issue comment 42 -R owner/repo --body-file -" "issue comment should run"
    assert_file_contains "$GH_LOG" "BODY:Hello" "multiline body should be piped"
    assert_file_contains "$GH_LOG" "World|X" "body content should be preserved"
    assert_file_contains "$GH_LOG" "issue close 42 -R owner/repo --reason completed" "issue close should run"
    assert_file_contains "$GH_LOG" "issue edit 42 -R owner/repo --add-label fixed-in-main,needs-review" "labels should run"
    assert_file_contains "$GH_LOG" "pr comment 15 -R owner/repo --body-file -" "pr comment should run"
    assert_file_contains "$GH_LOG" "BODY:Thanks!" "pr comment body should be piped"

    local before_lines after_lines
    before_lines=$(wc -l < "$GH_LOG" | tr -d ' ')
    assert_exit_code 0 "second run should still succeed" execute_gh_actions "owner/repo" "$plan_file"
    after_lines=$(wc -l < "$GH_LOG" | tr -d ' ')
    assert_equals "$before_lines" "$after_lines" "second run should not re-execute gh commands"

    export PATH="$old_path"
    log_test_pass "$test_name"
}

test_execute_gh_actions_continues_on_failure() {
    local test_name="execute_gh_actions: continues after a failing action"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"

    export GH_LOG="$env_root/gh.log"
    : > "$GH_LOG"

    local bin_dir="$env_root/bin"
    _write_mock_gh "$bin_dir" "fail_close"

    local old_path="$PATH"
    export PATH="$bin_dir:$PATH"

    local plan_file="$env_root/review-plan.json"
    cat > "$plan_file" <<'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "gh_actions": [
    {"op":"comment","target":"issue#42","body":"First"},
    {"op":"close","target":"issue#42","reason":"completed"},
    {"op":"label","target":"issue#42","labels":["fixed-in-main"]},
    {"op":"comment","target":"pr#15","body":"Last"}
  ]
}
EOF

    assert_exit_code 1 "should return non-zero when any action fails" execute_gh_actions "owner/repo" "$plan_file"

    assert_file_contains "$GH_LOG" "issue comment 42 -R owner/repo --body-file -" "comment should run"
    assert_file_contains "$GH_LOG" "issue close 42 -R owner/repo --reason completed" "close attempted"
    assert_file_contains "$GH_LOG" "issue edit 42 -R owner/repo --add-label fixed-in-main" "label should still run"
    assert_file_contains "$GH_LOG" "pr comment 15 -R owner/repo --body-file -" "pr comment should still run"

    export PATH="$old_path"
    log_test_pass "$test_name"
}

test_execute_gh_actions_runs_commands() {
    local test_name="execute_gh_actions: runs commands from plan"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    export GH_LOG="$env_root/gh.log"
    : > "$GH_LOG"

    local bin_dir="$env_root/bin"
    _write_mock_gh "$bin_dir" "ok"

    local old_path="$PATH"
    export PATH="$bin_dir:$PATH"

    local plan_file="$env_root/plan.json"
    create_valid_plan_with_actions "$plan_file"

    # Run actions
    assert_exit_code 0 "execute_gh_actions should succeed" execute_gh_actions "owner/repo" "$plan_file"

    # Verify log file
    local log_file="$RU_STATE_DIR/review/gh-actions.jsonl"
    assert_file_exists "$log_file" "Actions log should be created"

    # Check for success entries
    if grep -q '"status":"ok"' "$log_file"; then
        pass "Log contains success status"
    else
        fail "Log missing success status"
    fi

    # Verify idempotence
    assert_exit_code 0 "second run should still succeed" execute_gh_actions "owner/repo" "$plan_file"
    if grep -q '"status":"skipped"' "$log_file"; then
        pass "Log contains skipped status on second run"
    else
        fail "Log missing skipped status"
    fi

    export PATH="$old_path"
    cleanup_temp_dirs
}

test_execute_gh_actions_handles_errors() {
    local test_name="execute_gh_actions: handles errors gracefully"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local plan_file="$env_root/plan.json"
    create_valid_plan_with_actions "$plan_file"

    # Mock gh failure
    gh() { return 1; }
    export -f gh

    assert_exit_code 1 "should return non-zero when any action fails" execute_gh_actions "owner/repo" "$plan_file"

    cleanup_temp_dirs
}

create_valid_plan_with_actions() {
    local plan_file="$1"
    cat > "$plan_file" <<'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "gh_actions": [
    {"op":"comment","target":"issue#42","body":"Hello"},
    {"op":"close","target":"issue#42","reason":"completed"},
    {"op":"label","target":"issue#42","labels":["fixed-in-main","needs-review"]},
    {"op":"comment","target":"pr#15","body":"Thanks!"}
  ]
}
EOF
}

#==============================================================================
# Tests: parse_gh_action_target
#==============================================================================

test_parse_gh_action_target_issue() {
    local test_name="parse_gh_action_target: parses issue#N"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "issue#42" target_type number; then
        assert_equals "issue" "$target_type" "Type should be 'issue'"
        assert_equals "42" "$number" "Number should be 42"
    else
        fail "Should successfully parse issue#42"
    fi

    log_test_pass "$test_name"
}

test_parse_gh_action_target_pr() {
    local test_name="parse_gh_action_target: parses pr#N"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "pr#7" target_type number; then
        assert_equals "pr" "$target_type" "Type should be 'pr'"
        assert_equals "7" "$number" "Number should be 7"
    else
        fail "Should successfully parse pr#7"
    fi

    log_test_pass "$test_name"
}

test_parse_gh_action_target_large_number() {
    local test_name="parse_gh_action_target: handles large numbers"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "issue#12345" target_type number; then
        assert_equals "12345" "$number" "Should handle large numbers"
    else
        fail "Should handle large issue numbers"
    fi

    log_test_pass "$test_name"
}

test_parse_gh_action_target_invalid_format() {
    local test_name="parse_gh_action_target: rejects invalid format"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "invalid" target_type number; then
        fail "Should reject invalid format"
    else
        pass "Invalid format correctly rejected"
    fi

    log_test_pass "$test_name"
}

test_parse_gh_action_target_invalid_type() {
    local test_name="parse_gh_action_target: rejects invalid type"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "bug#42" target_type number; then
        fail "Should reject invalid type (bug)"
    else
        pass "Invalid type correctly rejected"
    fi

    log_test_pass "$test_name"
}

test_parse_gh_action_target_non_numeric() {
    local test_name="parse_gh_action_target: rejects non-numeric"
    log_test_start "$test_name"

    local target_type="" number=""
    if parse_gh_action_target "issue#abc" target_type number; then
        fail "Should reject non-numeric"
    else
        pass "Non-numeric correctly rejected"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: record_gh_action_log
#==============================================================================

test_record_gh_action_log_creates_file() {
    local test_name="record_gh_action_log: creates log file"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    record_gh_action_log "owner/repo" '{"op":"comment"}' "ok" "Success"

    local log_file
    log_file=$(get_gh_actions_log_file)
    assert_file_exists "$log_file" "Log file should be created"

    log_test_pass "$test_name"
}

test_record_gh_action_log_jsonl_format() {
    local test_name="record_gh_action_log: writes valid JSONL"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    record_gh_action_log "owner/repo" '{"op":"comment"}' "ok" "Done"

    local log_file
    log_file=$(get_gh_actions_log_file)

    local parsed
    parsed=$(jq -r '.repo' "$log_file" 2>/dev/null)
    assert_equals "owner/repo" "$parsed" "Should be valid JSONL with repo field"

    log_test_pass "$test_name"
}

test_record_gh_action_log_appends() {
    local test_name="record_gh_action_log: appends to existing file"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    record_gh_action_log "repo1" '{"op":"comment"}' "ok" ""
    record_gh_action_log "repo2" '{"op":"close"}' "failed" "Error"

    local log_file
    log_file=$(get_gh_actions_log_file)

    local line_count
    line_count=$(wc -l < "$log_file" | tr -d ' ')
    assert_equals "2" "$line_count" "Should have 2 lines"

    log_test_pass "$test_name"
}

test_record_gh_action_log_has_timestamp() {
    local test_name="record_gh_action_log: includes timestamp"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    record_gh_action_log "owner/repo" '{"op":"label"}' "ok" ""

    local log_file
    log_file=$(get_gh_actions_log_file)

    local ts
    ts=$(jq -r '.ts' "$log_file")
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        pass "Timestamp has ISO8601 format"
    else
        fail "Timestamp format invalid: $ts"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: gh_action_already_executed
#==============================================================================

test_gh_action_already_executed_no_log() {
    local test_name="gh_action_already_executed: returns false when no log"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"
    mkdir -p "$RU_STATE_DIR/review"

    if gh_action_already_executed "owner/repo" '{"op":"comment"}'; then
        fail "Should return false when no log file"
    else
        pass "Correctly returns false when no log file"
    fi

    log_test_pass "$test_name"
}

test_gh_action_already_executed_not_found() {
    local test_name="gh_action_already_executed: returns false for new action"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    record_gh_action_log "owner/repo" '{"op":"close"}' "ok" ""

    if gh_action_already_executed "owner/repo" '{"op":"comment"}'; then
        fail "Should return false for action not in log"
    else
        pass "Correctly returns false for new action"
    fi

    log_test_pass "$test_name"
}

test_gh_action_already_executed_found() {
    local test_name="gh_action_already_executed: returns true for executed action"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local action='{"op":"comment","target":"issue#42"}'
    record_gh_action_log "owner/repo" "$action" "ok" ""

    if gh_action_already_executed "owner/repo" "$action"; then
        pass "Correctly found executed action"
    else
        fail "Should find previously executed action"
    fi

    log_test_pass "$test_name"
}

test_gh_action_already_executed_different_repo() {
    local test_name="gh_action_already_executed: distinguishes repos"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local action='{"op":"comment"}'
    record_gh_action_log "owner/repo1" "$action" "ok" ""

    if gh_action_already_executed "owner/repo2" "$action"; then
        fail "Should not find action from different repo"
    else
        pass "Correctly distinguishes repos"
    fi

    log_test_pass "$test_name"
}

test_gh_action_already_executed_ignores_failed() {
    local test_name="gh_action_already_executed: ignores failed status"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local action='{"op":"comment"}'
    record_gh_action_log "owner/repo" "$action" "failed" "Error"

    if gh_action_already_executed "owner/repo" "$action"; then
        fail "Should not consider failed actions as duplicates"
    else
        pass "Correctly ignores failed actions"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: canonicalize_gh_action
#==============================================================================

test_canonicalize_gh_action_sorts_keys() {
    local test_name="canonicalize_gh_action: sorts JSON keys"
    log_test_start "$test_name"

    local input='{"target":"issue#42","op":"comment","body":"test"}'
    local expected='{"body":"test","op":"comment","target":"issue#42"}'

    local result
    result=$(canonicalize_gh_action "$input")
    assert_equals "$expected" "$result" "Keys should be sorted"

    log_test_pass "$test_name"
}

test_canonicalize_gh_action_compact() {
    local test_name="canonicalize_gh_action: returns compact JSON"
    log_test_start "$test_name"

    local input='{
        "op": "close",
        "target": "pr#7"
    }'

    local result
    result=$(canonicalize_gh_action "$input")

    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')
    assert_equals "1" "$line_count" "Output should be single line"

    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

# execute_gh_actions tests
run_test test_execute_gh_actions_happy_path_and_idempotent
run_test test_execute_gh_actions_continues_on_failure
run_test test_execute_gh_actions_runs_commands
run_test test_execute_gh_actions_handles_errors

# parse_gh_action_target tests
run_test test_parse_gh_action_target_issue
run_test test_parse_gh_action_target_pr
run_test test_parse_gh_action_target_large_number
run_test test_parse_gh_action_target_invalid_format
run_test test_parse_gh_action_target_invalid_type
run_test test_parse_gh_action_target_non_numeric

# record_gh_action_log tests
run_test test_record_gh_action_log_creates_file
run_test test_record_gh_action_log_jsonl_format
run_test test_record_gh_action_log_appends
run_test test_record_gh_action_log_has_timestamp

# gh_action_already_executed tests
run_test test_gh_action_already_executed_no_log
run_test test_gh_action_already_executed_not_found
run_test test_gh_action_already_executed_found
run_test test_gh_action_already_executed_different_repo
run_test test_gh_action_already_executed_ignores_failed

# canonicalize_gh_action tests
run_test test_canonicalize_gh_action_sorts_keys
run_test test_canonicalize_gh_action_compact

print_results
exit "$(get_exit_code)"
