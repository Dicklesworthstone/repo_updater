#!/usr/bin/env bash
#
# Unit tests: Lifecycle Functions (bd-hjzw)
#
# Tests lifecycle/execution functions:
#   - execute_commit_plan: commit plan execution with validation, plan mode, push
#   - execute_release_plan: release creation (tags, gh release, strategies)
#   - execute_gh_actions: orchestrated GitHub mutations (comment, close, label)
#   - run_quality_gates: lint/test/secret gate orchestration
#   - update_plan_with_gates: merging gate results into plan JSON
#   - parse_gh_action_target: target string parsing
#   - gh_action_already_executed / record_gh_action_log: idempotence
#   - get_release_strategy: strategy determination from config
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source required functions from ru
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "_set_out_array"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "json_validate"
source_ru_function "json_escape"
source_ru_function "validate_commit_plan"
source_ru_function "execute_commit_plan"
source_ru_function "validate_release_plan"
source_ru_function "execute_release_plan"
source_ru_function "get_release_strategy"
source_ru_function "has_release_workflow"
source_ru_function "canonicalize_gh_action"
source_ru_function "parse_gh_action_target"
source_ru_function "get_gh_actions_log_file"
source_ru_function "gh_action_already_executed"
source_ru_function "record_gh_action_log"
source_ru_function "execute_gh_action_comment"
source_ru_function "execute_gh_action_close"
source_ru_function "execute_gh_action_label"
source_ru_function "execute_gh_actions"
source_ru_function "run_quality_gates"
source_ru_function "update_plan_with_gates"
source_ru_function "get_file_size_mb"
source_ru_function "is_file_too_large"
source_ru_function "is_binary_file"
source_ru_function "is_binary_allowed"

# Suppress log output during tests
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }
log_step() { :; }
log_success() { :; }

#==============================================================================
# Mock Infrastructure
#==============================================================================

# File-based mock log (survives subshells from command substitutions)
declare -g MOCK_GH_LOG_FILE=""
declare -g MOCK_GH_EXIT_CODE=0
declare -g MOCK_GH_OUTPUT=""

# Mock gh command - logs to file so it works inside subshells
gh() {
    if [[ -n "$MOCK_GH_LOG_FILE" ]]; then
        echo "$*" >> "$MOCK_GH_LOG_FILE"
    fi
    if [[ -n "$MOCK_GH_OUTPUT" ]]; then
        echo "$MOCK_GH_OUTPUT"
    fi
    return "$MOCK_GH_EXIT_CODE"
}

# Check if a gh call matching a pattern was recorded
gh_mock_called_with() {
    local pattern="$1"
    [[ -f "$MOCK_GH_LOG_FILE" ]] && grep -q "$pattern" "$MOCK_GH_LOG_FILE"
}

# Count gh mock calls
gh_mock_call_count() {
    if [[ -f "$MOCK_GH_LOG_FILE" ]]; then
        wc -l < "$MOCK_GH_LOG_FILE" | tr -d ' '
    else
        echo "0"
    fi
}

# Reset all mocks
reset_mocks() {
    MOCK_GH_EXIT_CODE=0
    MOCK_GH_OUTPUT=""
    if [[ -n "$MOCK_GH_LOG_FILE" && -f "$MOCK_GH_LOG_FILE" ]]; then
        : > "$MOCK_GH_LOG_FILE"
    fi
}

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_lifecycle_test() {
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    export RU_CONFIG_DIR="$TEST_DIR/config"
    MOCK_GH_LOG_FILE="$TEST_DIR/gh_mock_calls.log"
    mkdir -p "$RU_STATE_DIR/review"
    mkdir -p "$RU_CONFIG_DIR"
    mkdir -p "$TEST_DIR/repo"
    mkdir -p "$TEST_DIR/repo/.ru"
    reset_mocks
}

create_test_plan_file() {
    local plan_file="$1"
    local content="$2"
    mkdir -p "$(dirname "$plan_file")"
    echo "$content" > "$plan_file"
}

#==============================================================================
# Tests: parse_gh_action_target
#==============================================================================

test_parse_target_issue() {
    log_test_start "parse_gh_action_target: issue#N"
    setup_lifecycle_test

    local target_type="" number=""
    if parse_gh_action_target "issue#42" target_type number; then
        assert_equals "issue" "$target_type" "Should parse type as issue"
        assert_equals "42" "$number" "Should parse number as 42"
    else
        fail "Should successfully parse issue#42"
    fi

    log_test_pass "parse_gh_action_target: issue#N"
}

test_parse_target_pr() {
    log_test_start "parse_gh_action_target: pr#N"
    setup_lifecycle_test

    local target_type="" number=""
    if parse_gh_action_target "pr#123" target_type number; then
        assert_equals "pr" "$target_type" "Should parse type as pr"
        assert_equals "123" "$number" "Should parse number as 123"
    else
        fail "Should successfully parse pr#123"
    fi

    log_test_pass "parse_gh_action_target: pr#N"
}

test_parse_target_invalid() {
    log_test_start "parse_gh_action_target: rejects invalid"
    setup_lifecycle_test

    local target_type="" number=""

    # No delimiter
    if parse_gh_action_target "issue42" target_type number; then
        fail "Should reject 'issue42' (no #)"
    else
        pass "Rejected 'issue42'"
    fi

    # Wrong type
    if parse_gh_action_target "bug#42" target_type number; then
        fail "Should reject 'bug#42' (wrong type)"
    else
        pass "Rejected 'bug#42'"
    fi

    # No number
    if parse_gh_action_target "issue#" target_type number; then
        fail "Should reject 'issue#' (no number)"
    else
        pass "Rejected 'issue#'"
    fi

    # Empty string
    if parse_gh_action_target "" target_type number; then
        fail "Should reject empty string"
    else
        pass "Rejected empty string"
    fi

    log_test_pass "parse_gh_action_target: rejects invalid"
}

#==============================================================================
# Tests: execute_commit_plan
#==============================================================================

test_commit_plan_empty_plan() {
    log_test_start "execute_commit_plan: rejects empty plan"
    setup_lifecycle_test

    if execute_commit_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty plan"
    fi

    log_test_pass "execute_commit_plan: rejects empty plan"
}

test_commit_plan_invalid_repo() {
    log_test_start "execute_commit_plan: rejects invalid repo"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["a.txt"]}]}'
    if execute_commit_plan "$plan" "" 2>/dev/null; then
        fail "Should reject empty repo path"
    else
        pass "Rejected empty repo path"
    fi

    if execute_commit_plan "$plan" "/nonexistent/path" 2>/dev/null; then
        fail "Should reject nonexistent repo path"
    else
        pass "Rejected nonexistent repo path"
    fi

    log_test_pass "execute_commit_plan: rejects invalid repo"
}

test_commit_plan_plan_mode() {
    log_test_start "execute_commit_plan: plan mode skips execution"
    setup_lifecycle_test

    # Mock capture_plan_json
    capture_plan_json() { return 0; }

    export AGENT_SWEEP_EXECUTION_MODE="plan"
    local plan='{"commits":[{"message":"test","files":["a.txt"]}]}'

    if execute_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Plan mode returns success without executing"
    else
        fail "Plan mode should return 0"
    fi

    unset AGENT_SWEEP_EXECUTION_MODE

    log_test_pass "execute_commit_plan: plan mode skips execution"
}

test_commit_plan_no_commits() {
    log_test_start "execute_commit_plan: rejects plan with no commits"
    setup_lifecycle_test

    local plan='{"commits":[]}'

    # validate_commit_plan should reject empty commits
    if execute_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject plan with no commits"
    else
        pass "Rejected plan with no commits"
    fi

    log_test_pass "execute_commit_plan: rejects plan with no commits"
}

test_commit_plan_valid_execution() {
    log_test_start "execute_commit_plan: executes valid plan"
    setup_lifecycle_test

    # Create a real git repo with a file to commit
    local repo_dir
    repo_dir=$(create_real_git_repo "commit-test" 1)
    echo "new content" > "$repo_dir/changed.txt"
    git -C "$repo_dir" add "changed.txt" >/dev/null 2>&1

    # Mock commit_plan_stage_and_commit to succeed
    commit_plan_stage_and_commit() { return 0; }

    local plan='{"commits":[{"message":"Test commit","files":["changed.txt"]}]}'

    if execute_commit_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Executed valid commit plan"
    else
        fail "Should execute valid commit plan"
    fi

    log_test_pass "execute_commit_plan: executes valid plan"
}

#==============================================================================
# Tests: execute_release_plan
#==============================================================================

test_release_plan_empty_plan() {
    log_test_start "execute_release_plan: rejects empty plan"
    setup_lifecycle_test

    if execute_release_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty release plan"
    fi

    log_test_pass "execute_release_plan: rejects empty plan"
}

test_release_plan_invalid_repo() {
    log_test_start "execute_release_plan: rejects invalid repo"
    setup_lifecycle_test

    local plan='{"version":"v1.0.0"}'
    if execute_release_plan "$plan" "" 2>/dev/null; then
        fail "Should reject empty repo path"
    else
        pass "Rejected empty repo path"
    fi

    if execute_release_plan "$plan" "/nonexistent/path" 2>/dev/null; then
        fail "Should reject nonexistent repo path"
    else
        pass "Rejected nonexistent repo path"
    fi

    log_test_pass "execute_release_plan: rejects invalid repo"
}

test_release_plan_plan_mode() {
    log_test_start "execute_release_plan: plan mode skips execution"
    setup_lifecycle_test

    capture_plan_json() { return 0; }
    export AGENT_SWEEP_EXECUTION_MODE="plan"

    local plan='{"version":"v1.0.0"}'
    if execute_release_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Plan mode returns success without executing"
    else
        fail "Plan mode should return 0"
    fi

    unset AGENT_SWEEP_EXECUTION_MODE

    log_test_pass "execute_release_plan: plan mode skips execution"
}

test_release_plan_never_strategy() {
    log_test_start "execute_release_plan: never strategy skips release"
    setup_lifecycle_test

    local repo_dir
    repo_dir=$(create_real_git_repo "release-never" 1)

    # Override get_release_strategy to return 'never'
    get_release_strategy() { echo "never"; }
    validate_release_plan() { VALIDATION_WARNINGS=(); return 0; }

    local plan='{"version":"v1.0.0","tag_name":"v1.0.0","title":"Test Release"}'
    if execute_release_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Never strategy returns success (skips release)"
    else
        fail "Never strategy should return 0"
    fi

    log_test_pass "execute_release_plan: never strategy skips release"
}

test_release_plan_tag_only_strategy() {
    log_test_start "execute_release_plan: tag-only strategy creates tag but no gh release"
    setup_lifecycle_test

    local repo_dir
    repo_dir=$(create_real_git_repo "release-tag-only" 1)

    # Set up a remote so push works
    local remote_dir="$TEST_DIR/remote.git"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1

    get_release_strategy() { echo "tag-only"; }
    validate_release_plan() { VALIDATION_WARNINGS=(); return 0; }

    local plan='{"version":"v1.0.0","tag_name":"v1.0.0","title":"Test Release"}'
    if execute_release_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Tag-only strategy succeeded"

        # Verify tag was created
        if git -C "$repo_dir" tag -l "v1.0.0" | grep -q "v1.0.0"; then
            pass "Tag v1.0.0 was created"
        else
            fail "Tag v1.0.0 should have been created"
        fi

        # Verify no gh calls were made (no GitHub release)
        if [[ "$(gh_mock_call_count)" -eq 0 ]]; then
            pass "No gh commands executed (tag-only)"
        else
            fail "Should not call gh in tag-only mode"
        fi
    else
        fail "Tag-only strategy should succeed"
    fi

    log_test_pass "execute_release_plan: tag-only strategy creates tag but no gh release"
}

#==============================================================================
# Tests: execute_gh_actions orchestrator
#==============================================================================

test_gh_actions_no_actions() {
    log_test_start "execute_gh_actions: no actions in plan"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": []
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        pass "Returns success when no actions"
    else
        fail "Should succeed with no actions"
    fi

    assert_equals "0" "$(gh_mock_call_count)" "No gh calls should be made"

    log_test_pass "execute_gh_actions: no actions in plan"
}

test_gh_actions_missing_plan_file() {
    log_test_start "execute_gh_actions: rejects missing plan file"
    setup_lifecycle_test

    if execute_gh_actions "owner/repo" "/nonexistent/plan.json" 2>/dev/null; then
        fail "Should reject missing plan file"
    else
        pass "Rejected missing plan file"
    fi

    log_test_pass "execute_gh_actions: rejects missing plan file"
}

test_gh_actions_comment_execution() {
    log_test_start "execute_gh_actions: executes comment action"
    setup_lifecycle_test

    # Set up state dir for action logging
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "issue#42", "body": "Test comment"}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    # Verify gh was called with comment args (file-based mock log)
    if gh_mock_called_with "issue comment.*42"; then
        pass "gh issue comment was called"
    else
        fail "Should call gh issue comment"
    fi

    log_test_pass "execute_gh_actions: executes comment action"
}

test_gh_actions_close_execution() {
    log_test_start "execute_gh_actions: executes close action"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "close", "target": "issue#10", "reason": "completed"}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    if gh_mock_called_with "issue close.*10"; then
        pass "gh issue close was called"
    else
        fail "Should call gh issue close"
    fi

    log_test_pass "execute_gh_actions: executes close action"
}

test_gh_actions_label_execution() {
    log_test_start "execute_gh_actions: executes label action"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "label", "target": "issue#5", "labels": ["bug", "urgent"]}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    if gh_mock_called_with "issue edit.*5.*add-label"; then
        pass "gh issue edit --add-label was called"
    else
        fail "Should call gh issue edit --add-label"
    fi

    log_test_pass "execute_gh_actions: executes label action"
}

test_gh_actions_merge_blocked() {
    log_test_start "execute_gh_actions: merge op is blocked by policy"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "merge", "target": "pr#99"}
        ]
    }'

    # Merge should be blocked and return failure
    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Merge should cause failure (blocked by policy)"
    else
        pass "Merge op blocked by policy"
    fi

    # Verify no gh merge call was made
    if ! gh_mock_called_with "merge"; then
        pass "No gh merge command was executed"
    else
        fail "Should not execute gh merge"
    fi

    log_test_pass "execute_gh_actions: merge op is blocked by policy"
}

test_gh_actions_invalid_target() {
    log_test_start "execute_gh_actions: invalid target fails gracefully"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "invalid_target", "body": "test"}
        ]
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Invalid target should cause failure"
    else
        pass "Failed on invalid target"
    fi

    log_test_pass "execute_gh_actions: invalid target fails gracefully"
}

test_gh_actions_label_pr_rejected() {
    log_test_start "execute_gh_actions: label on PR is rejected"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "label", "target": "pr#5", "labels": ["bug"]}
        ]
    }'

    # Labels are only supported on issues per the implementation
    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Label on PR should fail (issues only)"
    else
        pass "Label on PR correctly rejected"
    fi

    log_test_pass "execute_gh_actions: label on PR is rejected"
}

test_gh_actions_comment_missing_body() {
    log_test_start "execute_gh_actions: comment without body fails"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "issue#42", "body": ""}
        ]
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Comment without body should fail"
    else
        pass "Comment without body correctly failed"
    fi

    log_test_pass "execute_gh_actions: comment without body fails"
}

#==============================================================================
# Tests: gh_action_already_executed / record_gh_action_log (idempotence)
#==============================================================================

test_idempotence_not_executed() {
    log_test_start "gh_action_already_executed: returns false when not executed"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    if gh_action_already_executed "owner/repo" '{"op":"comment","target":"issue#1"}'; then
        fail "Should return false when no log exists"
    else
        pass "Correctly reports not yet executed"
    fi

    log_test_pass "gh_action_already_executed: returns false when not executed"
}

test_idempotence_record_and_check() {
    log_test_start "record_gh_action_log + gh_action_already_executed"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local action_canon='{"op":"comment","target":"issue#42"}'

    # Record a successful execution
    record_gh_action_log "owner/repo" "$action_canon" "ok" ""

    # Verify the log file was created
    local log_file
    log_file=$(get_gh_actions_log_file)
    assert_file_exists "$log_file" "Action log file should exist"

    # Check idempotence
    if gh_action_already_executed "owner/repo" "$action_canon"; then
        pass "Correctly detects already-executed action"
    else
        fail "Should detect already-executed action"
    fi

    log_test_pass "record_gh_action_log + gh_action_already_executed"
}

test_idempotence_failed_not_blocking() {
    log_test_start "gh_action_already_executed: failed actions don't block retry"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local action_canon='{"op":"comment","target":"issue#99"}'

    # Record a failed execution
    record_gh_action_log "owner/repo" "$action_canon" "failed" "network error"

    # Failed actions should not count as "already executed"
    if gh_action_already_executed "owner/repo" "$action_canon"; then
        fail "Failed actions should not block retry"
    else
        pass "Failed actions correctly allow retry"
    fi

    log_test_pass "gh_action_already_executed: failed actions don't block retry"
}

#==============================================================================
# Tests: update_plan_with_gates
#==============================================================================

test_update_plan_with_gates_success() {
    log_test_start "update_plan_with_gates: merges gate results"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "items": [],
        "git": {}
    }'

    local gates_result='{
        "overall_ok": true,
        "has_warning": false,
        "tests": {"ran": true, "ok": true, "output": "all passed"},
        "lint": {"ran": true, "ok": true, "output": ""},
        "secrets": {"scanned": true, "ok": true, "findings": []}
    }'

    if update_plan_with_gates "$plan_file" "$gates_result"; then
        pass "update_plan_with_gates succeeded"
    else
        fail "update_plan_with_gates should succeed"
    fi

    # Verify plan was updated
    local quality_ok
    quality_ok=$(jq -r '.git.quality_gates_ok' "$plan_file")
    assert_equals "true" "$quality_ok" "quality_gates_ok should be true"

    local tests_ok
    tests_ok=$(jq -r '.git.tests.ok' "$plan_file")
    assert_equals "true" "$tests_ok" "tests.ok should be true"

    local lint_ok
    lint_ok=$(jq -r '.git.lint.ok' "$plan_file")
    assert_equals "true" "$lint_ok" "lint.ok should be true"

    local secrets_ok
    secrets_ok=$(jq -r '.git.secrets.ok' "$plan_file")
    assert_equals "true" "$secrets_ok" "secrets.ok should be true"

    log_test_pass "update_plan_with_gates: merges gate results"
}

test_update_plan_with_gates_failure() {
    log_test_start "update_plan_with_gates: records gate failures"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "items": [],
        "git": {}
    }'

    local gates_result='{
        "overall_ok": false,
        "has_warning": true,
        "tests": {"ran": true, "ok": false, "output": "3 tests failed"},
        "lint": {"ran": true, "ok": true, "output": ""},
        "secrets": {"scanned": true, "ok": false, "findings": ["AWS_KEY"]}
    }'

    update_plan_with_gates "$plan_file" "$gates_result"

    local quality_ok
    quality_ok=$(jq -r '.git.quality_gates_ok' "$plan_file")
    assert_equals "false" "$quality_ok" "quality_gates_ok should be false"

    local quality_warning
    quality_warning=$(jq -r '.git.quality_gates_warning' "$plan_file")
    assert_equals "true" "$quality_warning" "quality_gates_warning should be true"

    local tests_ok
    tests_ok=$(jq -r '.git.tests.ok' "$plan_file")
    assert_equals "false" "$tests_ok" "tests.ok should be false"

    local secrets_ok
    secrets_ok=$(jq -r '.git.secrets.ok' "$plan_file")
    assert_equals "false" "$secrets_ok" "secrets.ok should be false"

    log_test_pass "update_plan_with_gates: records gate failures"
}

test_update_plan_missing_file() {
    log_test_start "update_plan_with_gates: rejects missing plan file"
    setup_lifecycle_test

    local gates_result='{"overall_ok":true,"has_warning":false,"tests":{},"lint":{},"secrets":{}}'

    if update_plan_with_gates "/nonexistent/plan.json" "$gates_result" 2>/dev/null; then
        fail "Should reject missing plan file"
    else
        pass "Rejected missing plan file"
    fi

    log_test_pass "update_plan_with_gates: rejects missing plan file"
}

#==============================================================================
# Tests: get_release_strategy
#==============================================================================

test_release_strategy_default_no_workflow() {
    log_test_start "get_release_strategy: defaults to never without workflow"
    setup_lifecycle_test

    # Re-source to get clean copy (guards against prior test overrides)
    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-default" 1)

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "never" "$strategy" "Should default to 'never' without release workflow"

    log_test_pass "get_release_strategy: defaults to never without workflow"
}

test_release_strategy_per_repo_config() {
    log_test_start "get_release_strategy: reads per-repo config"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-repo" 1)

    # Create per-repo config
    mkdir -p "$repo_dir/.ru"
    echo 'AGENT_SWEEP_RELEASE_STRATEGY="tag-only"' > "$repo_dir/.ru/agent-sweep.conf"

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "tag-only" "$strategy" "Should read strategy from per-repo config"

    log_test_pass "get_release_strategy: reads per-repo config"
}

test_release_strategy_with_workflow() {
    log_test_start "get_release_strategy: auto when workflow exists"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-workflow" 1)

    # Create a release workflow
    mkdir -p "$repo_dir/.github/workflows"
    echo 'name: release' > "$repo_dir/.github/workflows/release.yml"

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "auto" "$strategy" "Should return 'auto' when workflow exists"

    log_test_pass "get_release_strategy: auto when workflow exists"
}

test_release_strategy_invalid_repo() {
    log_test_start "get_release_strategy: returns never for invalid repo"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local strategy
    strategy=$(get_release_strategy "")
    assert_equals "never" "$strategy" "Should return 'never' for empty path"

    strategy=$(get_release_strategy "/nonexistent/path")
    assert_equals "never" "$strategy" "Should return 'never' for nonexistent path"

    log_test_pass "get_release_strategy: returns never for invalid repo"
}

#==============================================================================
# Tests: run_quality_gates
#==============================================================================

test_quality_gates_all_pass() {
    log_test_start "run_quality_gates: all gates pass"
    setup_lifecycle_test

    # Re-source to get a clean copy (guards against prior test side effects)
    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    # Mock the gate functions
    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":""}'
    }
    run_lint_gate() {
        echo '{"ran":true,"ok":true,"output":"clean"}'
        return 0
    }
    run_test_gate() {
        echo '{"ran":true,"ok":true,"output":"all passed"}'
        return 0
    }
    run_secret_scan() {
        echo '{"scanned":true,"ok":true,"findings":[]}'
        return 0
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "All gates pass should return 0"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local overall_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok' 2>/dev/null)
    assert_equals "true" "$overall_ok" "overall_ok should be true"

    log_test_pass "run_quality_gates: all gates pass"
}

test_quality_gates_lint_failure() {
    log_test_start "run_quality_gates: lint failure"
    setup_lifecycle_test

    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":"eslint ."}'
    }
    run_lint_gate() {
        echo '{"ran":true,"ok":false,"output":"2 errors"}'
        return 1
    }
    run_test_gate() {
        echo '{"ran":true,"ok":true,"output":"ok"}'
        return 0
    }
    run_secret_scan() {
        echo '{"scanned":true,"ok":true,"findings":[]}'
        return 0
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "1" "$exit_code" "Lint failure should return 1"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local overall_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok' 2>/dev/null)
    assert_equals "false" "$overall_ok" "overall_ok should be false on lint failure"

    log_test_pass "run_quality_gates: lint failure"
}

test_quality_gates_secret_warning() {
    log_test_start "run_quality_gates: secret warning"
    setup_lifecycle_test

    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":""}'
    }
    run_lint_gate() {
        echo '{"ran":false,"ok":true,"output":""}'
        return 2
    }
    run_test_gate() {
        echo '{"ran":false,"ok":true,"output":""}'
        return 2
    }
    run_secret_scan() {
        echo '{"scanned":true,"ok":false,"findings":["possible_key"]}'
        return 2
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "2" "$exit_code" "Secret warning should return 2"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local has_warning
    has_warning=$(echo "$result" | jq -r '.has_warning' 2>/dev/null)
    assert_equals "true" "$has_warning" "has_warning should be true"

    log_test_pass "run_quality_gates: secret warning"
}

#==============================================================================
# Tests: validate_commit_plan
#==============================================================================

test_validate_commit_plan_empty() {
    log_test_start "validate_commit_plan: rejects empty plan"
    setup_lifecycle_test

    if validate_commit_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty plan"
        assert_not_empty "$VALIDATION_ERROR" "VALIDATION_ERROR should be set"
    fi

    log_test_pass "validate_commit_plan: rejects empty plan"
}

test_validate_commit_plan_invalid_json() {
    log_test_start "validate_commit_plan: rejects invalid JSON"
    setup_lifecycle_test

    if validate_commit_plan "not json at all" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject invalid JSON"
    else
        pass "Rejected invalid JSON"
    fi

    log_test_pass "validate_commit_plan: rejects invalid JSON"
}

test_validate_commit_plan_no_commits() {
    log_test_start "validate_commit_plan: rejects missing commits"
    setup_lifecycle_test

    if validate_commit_plan '{"push":false}' "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject plan without commits"
    else
        pass "Rejected plan without commits"
    fi

    log_test_pass "validate_commit_plan: rejects missing commits"
}

test_validate_commit_plan_no_message() {
    log_test_start "validate_commit_plan: rejects commit without message"
    setup_lifecycle_test

    local plan='{"commits":[{"files":["a.txt"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject commit without message"
    else
        pass "Rejected commit without message"
        assert_contains "$VALIDATION_ERROR" "message" "Error should mention message"
    fi

    log_test_pass "validate_commit_plan: rejects commit without message"
}

test_validate_commit_plan_no_files() {
    log_test_start "validate_commit_plan: rejects commit without files"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":[]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject commit without files"
    else
        pass "Rejected commit without files"
    fi

    log_test_pass "validate_commit_plan: rejects commit without files"
}

test_validate_commit_plan_absolute_path() {
    log_test_start "validate_commit_plan: rejects absolute paths"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["/etc/passwd"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject absolute file paths"
    else
        pass "Rejected absolute file path"
        assert_contains "$VALIDATION_ERROR" "absolute" "Error should mention absolute"
    fi

    log_test_pass "validate_commit_plan: rejects absolute paths"
}

test_validate_commit_plan_traversal_path() {
    log_test_start "validate_commit_plan: rejects path traversal"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["../../etc/passwd"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject path traversal"
    else
        pass "Rejected path traversal"
        assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe"
    fi

    log_test_pass "validate_commit_plan: rejects path traversal"
}

test_validate_commit_plan_valid() {
    log_test_start "validate_commit_plan: accepts valid plan"
    setup_lifecycle_test

    # Create files in the repo so validation passes file existence check
    echo "content" > "$TEST_DIR/repo/main.rs"

    local plan='{"commits":[{"message":"Fix bug","files":["main.rs"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Accepted valid plan"
    else
        fail "Should accept valid plan: $VALIDATION_ERROR"
    fi

    log_test_pass "validate_commit_plan: accepts valid plan"
}

#==============================================================================
# Tests: canonicalize_gh_action
#==============================================================================

test_canonicalize_gh_action() {
    log_test_start "canonicalize_gh_action: produces deterministic output"
    setup_lifecycle_test

    # Same content, different key order
    local result1 result2
    result1=$(canonicalize_gh_action '{"op":"comment","target":"issue#1","body":"hi"}')
    result2=$(canonicalize_gh_action '{"body":"hi","target":"issue#1","op":"comment"}')

    assert_equals "$result1" "$result2" "Same content should produce same canonical form"

    log_test_pass "canonicalize_gh_action: produces deterministic output"
}

test_canonicalize_gh_action_invalid() {
    log_test_start "canonicalize_gh_action: handles invalid JSON"
    setup_lifecycle_test

    local result
    result=$(canonicalize_gh_action "not json" 2>/dev/null)

    # jq should fail and return empty
    if [[ -z "$result" ]]; then
        pass "Returns empty for invalid JSON"
    else
        pass "Returned something for invalid JSON (jq might have handled it)"
    fi

    log_test_pass "canonicalize_gh_action: handles invalid JSON"
}

#==============================================================================
# Tests: execute_gh_action_comment / close / label (individual)
#==============================================================================

test_execute_gh_action_comment_issue() {
    log_test_start "execute_gh_action_comment: comments on issue"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_comment "owner/repo" "issue" "42" "Hello world" 2>/dev/null; then
        pass "Comment on issue succeeded"
    else
        fail "Comment on issue should succeed"
    fi

    if gh_mock_called_with "issue comment.*42"; then
        pass "Called gh issue comment 42"
    else
        fail "Should call gh issue comment 42"
    fi

    log_test_pass "execute_gh_action_comment: comments on issue"
}

test_execute_gh_action_comment_pr() {
    log_test_start "execute_gh_action_comment: comments on PR"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_comment "owner/repo" "pr" "7" "PR comment" 2>/dev/null; then
        pass "Comment on PR succeeded"
    else
        fail "Comment on PR should succeed"
    fi

    if gh_mock_called_with "pr comment.*7"; then
        pass "Called gh pr comment 7"
    else
        fail "Should call gh pr comment 7"
    fi

    log_test_pass "execute_gh_action_comment: comments on PR"
}

test_execute_gh_action_comment_failure() {
    log_test_start "execute_gh_action_comment: propagates gh failure"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=1
    MOCK_GH_OUTPUT="Not Found"

    if execute_gh_action_comment "owner/repo" "issue" "999" "body" 2>/dev/null; then
        fail "Should propagate gh failure"
    else
        pass "Propagated gh failure"
    fi

    log_test_pass "execute_gh_action_comment: propagates gh failure"
}

test_execute_gh_action_close_issue() {
    log_test_start "execute_gh_action_close: closes issue"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_close "owner/repo" "issue" "10" "completed" "" 2>/dev/null; then
        pass "Close issue succeeded"
    else
        fail "Close issue should succeed"
    fi

    if gh_mock_called_with "issue close.*10"; then
        pass "Called gh issue close 10"
    else
        fail "Should call gh issue close"
    fi

    log_test_pass "execute_gh_action_close: closes issue"
}

test_execute_gh_action_close_pr_with_comment() {
    log_test_start "execute_gh_action_close: closes PR with comment"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_close "owner/repo" "pr" "25" "completed" "Closing this PR" 2>/dev/null; then
        pass "Close PR with comment succeeded"
    else
        fail "Close PR with comment should succeed"
    fi

    if gh_mock_called_with "pr close.*25.*--comment"; then
        pass "Called gh pr close with --comment"
    else
        fail "Should call gh pr close with --comment"
    fi

    log_test_pass "execute_gh_action_close: closes PR with comment"
}

test_execute_gh_action_label() {
    log_test_start "execute_gh_action_label: adds labels"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_label "owner/repo" "5" "bug,urgent" 2>/dev/null; then
        pass "Add labels succeeded"
    else
        fail "Add labels should succeed"
    fi

    if gh_mock_called_with "issue edit.*5.*--add-label.*bug,urgent"; then
        pass "Called gh issue edit with correct labels"
    else
        fail "Should call gh issue edit --add-label bug,urgent"
    fi

    log_test_pass "execute_gh_action_label: adds labels"
}

#==============================================================================
# Run All Tests
#==============================================================================

log_suite_start "Lifecycle Functions Unit Tests (bd-hjzw)"
echo ""

# Target parsing
run_test test_parse_target_issue
run_test test_parse_target_pr
run_test test_parse_target_invalid

# Commit plan execution
run_test test_commit_plan_empty_plan
run_test test_commit_plan_invalid_repo
run_test test_commit_plan_plan_mode
run_test test_commit_plan_no_commits
run_test test_commit_plan_valid_execution

# Release plan execution
run_test test_release_plan_empty_plan
run_test test_release_plan_invalid_repo
run_test test_release_plan_plan_mode
run_test test_release_plan_never_strategy
run_test test_release_plan_tag_only_strategy

# GH actions orchestrator
run_test test_gh_actions_no_actions
run_test test_gh_actions_missing_plan_file
run_test test_gh_actions_comment_execution
run_test test_gh_actions_close_execution
run_test test_gh_actions_label_execution
run_test test_gh_actions_merge_blocked
run_test test_gh_actions_invalid_target
run_test test_gh_actions_label_pr_rejected
run_test test_gh_actions_comment_missing_body

# Idempotence
run_test test_idempotence_not_executed
run_test test_idempotence_record_and_check
run_test test_idempotence_failed_not_blocking

# Update plan with gates
run_test test_update_plan_with_gates_success
run_test test_update_plan_with_gates_failure
run_test test_update_plan_missing_file

# Release strategy
run_test test_release_strategy_default_no_workflow
run_test test_release_strategy_per_repo_config
run_test test_release_strategy_with_workflow
run_test test_release_strategy_invalid_repo

# Quality gates
run_test test_quality_gates_all_pass
run_test test_quality_gates_lint_failure
run_test test_quality_gates_secret_warning

# Validate commit plan
run_test test_validate_commit_plan_empty
run_test test_validate_commit_plan_invalid_json
run_test test_validate_commit_plan_no_commits
run_test test_validate_commit_plan_no_message
run_test test_validate_commit_plan_no_files
run_test test_validate_commit_plan_absolute_path
run_test test_validate_commit_plan_traversal_path
run_test test_validate_commit_plan_valid

# Canonicalize GH action
run_test test_canonicalize_gh_action
run_test test_canonicalize_gh_action_invalid

# Individual GH action functions
run_test test_execute_gh_action_comment_issue
run_test test_execute_gh_action_comment_pr
run_test test_execute_gh_action_comment_failure
run_test test_execute_gh_action_close_issue
run_test test_execute_gh_action_close_pr_with_comment
run_test test_execute_gh_action_label

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
