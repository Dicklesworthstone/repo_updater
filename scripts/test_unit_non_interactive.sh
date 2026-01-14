#!/usr/bin/env bash
#
# Unit tests: Non-interactive review behavior (bd-s3iy)
#
# Tests:
# - log_skipped_question (handles JSON and non-JSON inputs)
# - handle_question_non_interactive (auto/skip/fail + external_prompt behavior)
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
# shellcheck disable=SC2034  # Globals are referenced by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "ensure_dir"
source_ru_function "json_escape"
source_ru_function "get_skipped_questions_log_file"
source_ru_function "log_skipped_question"
source_ru_function "handle_question_non_interactive"

# Mock logging
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

# Mock driver send
SENT_TO_SESSION=""
driver_send_to_session() {
    local _session_id="$1"
    local message="$2"
    SENT_TO_SESSION="$message"
    return 0
}

test_log_skipped_question_wraps_non_json() {
    local test_name="log_skipped_question: wraps non-JSON input"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-nonjson"

    log_skipped_question "not json at all" "skip"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    assert_file_exists "$log_file" "log file should be created"

    local line
    line=$(tail -1 "$log_file")
    assert_equals "skip" "$(echo "$line" | jq -r '.reason')" "reason should be logged"
    assert_equals "not json at all" "$(echo "$line" | jq -r '.question.raw')" "raw input should be wrapped"

    log_test_pass "$test_name"
}

test_handle_question_non_interactive_auto_selects_recommended() {
    local test_name="handle_question_non_interactive: auto selects recommended"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-auto"
    REVIEW_NON_INTERACTIVE_POLICY="auto"

    SENT_TO_SESSION=""
    local question_info
    question_info=$(jq -n '{reason:"ask_user_question",context:{questions:[{recommended:"Quick fix"}]}}')

    assert_exit_code 0 "should succeed" handle_question_non_interactive "$question_info" "sess-1"

    assert_equals "Quick fix" "$SENT_TO_SESSION" "should send recommended answer"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    assert_file_not_exists "$log_file" "should not log when auto-selecting"

    log_test_pass "$test_name"
}

test_handle_question_non_interactive_auto_skips_without_recommended() {
    local test_name="handle_question_non_interactive: auto skips without recommended"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-auto-skip"
    REVIEW_NON_INTERACTIVE_POLICY="auto"

    SENT_TO_SESSION=""
    local question_info
    question_info=$(jq -n '{reason:"ask_user_question",context:{questions:[{prompt:"x"}]}}')

    assert_exit_code 0 "should succeed" handle_question_non_interactive "$question_info" "sess-2"

    assert_equals "skip" "$SENT_TO_SESSION" "should send skip when no recommended"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    assert_file_exists "$log_file" "log file should exist when skipping"
    assert_equals "1" "$(wc -l < "$log_file" | tr -d ' ')" "one entry logged"

    log_test_pass "$test_name"
}

test_handle_question_non_interactive_external_prompt_fails() {
    local test_name="handle_question_non_interactive: external_prompt fails"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-external"
    REVIEW_NON_INTERACTIVE_POLICY="auto"

    SENT_TO_SESSION=""
    local question_info
    question_info=$(jq -n '{reason:"external_prompt",context:"Password:"}')

    assert_exit_code 3 "external prompt should fail" handle_question_non_interactive "$question_info" "sess-3"

    assert_equals "" "$SENT_TO_SESSION" "should not send response"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    assert_file_exists "$log_file" "log file should exist on external prompt"
    assert_equals "external_prompt" "$(tail -1 "$log_file" | jq -r '.reason')" "log reason should be external_prompt"

    log_test_pass "$test_name"
}

test_handle_question_non_interactive_fail_policy_fails() {
    local test_name="handle_question_non_interactive: fail policy fails"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    export REVIEW_RUN_ID="run-fail"
    REVIEW_NON_INTERACTIVE_POLICY="fail"

    SENT_TO_SESSION=""
    local question_info
    question_info=$(jq -n '{reason:"agent_question_text",context:"Should I refactor?"}')

    assert_exit_code 3 "fail policy should fail" handle_question_non_interactive "$question_info" "sess-4"

    assert_equals "" "$SENT_TO_SESSION" "should not send response"

    local log_file
    log_file=$(get_skipped_questions_log_file)
    assert_file_exists "$log_file" "log file should exist on fail policy"
    assert_equals "fail" "$(tail -1 "$log_file" | jq -r '.reason')" "log reason should be fail"

    log_test_pass "$test_name"
}

run_test test_log_skipped_question_wraps_non_json
run_test test_handle_question_non_interactive_auto_selects_recommended
run_test test_handle_question_non_interactive_auto_skips_without_recommended
run_test test_handle_question_non_interactive_external_prompt_fails
run_test test_handle_question_non_interactive_fail_policy_fails

print_results
exit $?
