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

run_test test_execute_gh_actions_happy_path_and_idempotent
run_test test_execute_gh_actions_continues_on_failure
run_test test_execute_gh_actions_runs_commands
run_test test_execute_gh_actions_handles_errors

print_results
exit $?
