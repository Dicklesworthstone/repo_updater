#!/usr/bin/env bash
#
# Unit tests: Review exit codes and error classification (bd-jen3)
#
# Tests:
# - classify_review_error
# - review_exit_code_for_classification
# - review_exit_code_for_error
# - aggregate_exit_code
# - finalize_review_exit (in subshell)
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "classify_review_error"
source_ru_function "review_exit_code_for_classification"
source_ru_function "review_exit_code_for_error"
source_ru_function "aggregate_exit_code"
source_ru_function "finalize_review_exit"

# Mock logging functions used by finalize_review_exit
log_success() { echo "SUCCESS:$*" >&2; }
log_warn() { echo "WARN:$*" >&2; }
log_error() { echo "ERROR:$*" >&2; }

test_classify_review_error_mapping() {
    local test_name="classify_review_error: maps error types"
    log_test_start "$test_name"

    assert_equals "partial" "$(classify_review_error session_failed)" "session_failed => partial"
    assert_equals "conflict" "$(classify_review_error merge_conflict)" "merge_conflict => conflict"
    assert_equals "system" "$(classify_review_error missing_dependency)" "missing_dependency => system"
    assert_equals "invalid" "$(classify_review_error invalid_flag)" "invalid_flag => invalid"
    assert_equals "interrupted" "$(classify_review_error interrupted)" "interrupted => interrupted"
    assert_equals "unknown" "$(classify_review_error some_new_error_type)" "unknown error => unknown"

    log_test_pass "$test_name"
}

test_review_exit_code_for_classification_mapping() {
    local test_name="review_exit_code_for_classification: maps categories"
    log_test_start "$test_name"

    assert_equals "1" "$(review_exit_code_for_classification partial)" "partial => 1"
    assert_equals "2" "$(review_exit_code_for_classification conflict)" "conflict => 2"
    assert_equals "3" "$(review_exit_code_for_classification system)" "system => 3"
    assert_equals "4" "$(review_exit_code_for_classification invalid)" "invalid => 4"
    assert_equals "5" "$(review_exit_code_for_classification interrupted)" "interrupted => 5"
    assert_equals "1" "$(review_exit_code_for_classification unknown)" "unknown => 1"

    log_test_pass "$test_name"
}

test_review_exit_code_for_error_mapping() {
    local test_name="review_exit_code_for_error: maps error types to exit codes"
    log_test_start "$test_name"

    assert_equals "1" "$(review_exit_code_for_error rate_limited)" "rate_limited => 1"
    assert_equals "2" "$(review_exit_code_for_error tests_failed)" "tests_failed => 2"
    assert_equals "3" "$(review_exit_code_for_error no_driver)" "no_driver => 3"
    assert_equals "4" "$(review_exit_code_for_error bad_mode)" "bad_mode => 4"
    assert_equals "5" "$(review_exit_code_for_error max_questions)" "max_questions => 5"
    assert_equals "1" "$(review_exit_code_for_error unknown_new)" "unknown => 1"

    log_test_pass "$test_name"
}

test_aggregate_exit_code_rules() {
    local test_name="aggregate_exit_code: highest code wins"
    log_test_start "$test_name"

    assert_equals "0" "$(aggregate_exit_code)" "empty => 0"
    assert_equals "2" "$(aggregate_exit_code 0 1 2 1)" "max => 2"
    assert_equals "5" "$(aggregate_exit_code 1 2 5 0)" "interrupted dominates"
    assert_equals "3" "$(aggregate_exit_code 0 x 3 y)" "ignores non-numeric"

    log_test_pass "$test_name"
}

test_finalize_review_exit_messages() {
    local test_name="finalize_review_exit: exits with message"
    log_test_start "$test_name"

    local output rc

    output=$( ( finalize_review_exit 0 ) 2>&1 )
    rc=$?
    assert_equals "0" "$rc" "exit 0"
    assert_contains "$output" "SUCCESS:Review completed successfully" "success message"

    output=$( ( finalize_review_exit 2 ) 2>&1 )
    rc=$?
    assert_equals "2" "$rc" "exit 2"
    assert_contains "$output" "ERROR:Review blocked by conflicts" "conflict message"

    output=$( ( finalize_review_exit 5 ) 2>&1 )
    rc=$?
    assert_equals "5" "$rc" "exit 5"
    assert_contains "$output" "WARN:Review interrupted" "interrupted message"

    log_test_pass "$test_name"
}

run_test test_classify_review_error_mapping
run_test test_review_exit_code_for_classification_mapping
run_test test_review_exit_code_for_error_mapping
run_test test_aggregate_exit_code_rules
run_test test_finalize_review_exit_messages

print_results
exit "$(get_exit_code)"
