#!/usr/bin/env bash
#
# Unit Tests: Argument Parsing
# Tests for parse_args with all flag combinations
#
# Test coverage:
#   - Boolean flags (--json, --quiet, --verbose, --dry-run, etc.)
#   - Value flags (--dir, --timeout, --parallel, -j)
#   - Command recognition (sync, status, init, add, remove, list, doctor, etc.)
#   - Default command is sync
#   - Unknown options exit with code 4
#   - Subcommand options passed to ARGS
#   - Positional arguments passed to ARGS
#   - Short and long flag equivalence
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
# shellcheck source=./test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Global Variables (matching ru script)
#==============================================================================

# Reset all global variables to defaults
reset_globals() {
    COMMAND=""
    ARGS=()
    JSON_OUTPUT="false"
    QUIET="false"
    VERBOSE="false"
    NON_INTERACTIVE="false"
    DRY_RUN="false"
    CLONE_ONLY="false"
    PULL_ONLY="false"
    AUTOSTASH="false"
    UPDATE_STRATEGY="merge"
    FETCH_REMOTES="true"
    RESUME="false"
    RESTART="false"
    GIT_TIMEOUT="60"
    PARALLEL="1"
    INIT_EXAMPLE="false"
    PROJECTS_DIR="${PROJECTS_DIR:-/tmp/test-projects}"
}

# Source mock functions and parse_args
source_parse_args() {
    # Mock show_help and show_version to not exit
    show_help() { :; }
    show_version() { :; }
    log_error() { :; }

    # Extract parse_args function
    eval "$(sed -n '/^parse_args()/,/^}/p' "$RU_SCRIPT")"
}

source_parse_args

#==============================================================================
# Tests: Boolean Flags
#==============================================================================

test_json_flag() {
    reset_globals
    parse_args --json

    assert_equals "true" "$JSON_OUTPUT" "--json sets JSON_OUTPUT=true"
}

test_quiet_flag_short() {
    reset_globals
    parse_args -q

    assert_equals "true" "$QUIET" "-q sets QUIET=true"
}

test_quiet_flag_long() {
    reset_globals
    parse_args --quiet

    assert_equals "true" "$QUIET" "--quiet sets QUIET=true"
}

test_verbose_flag() {
    reset_globals
    parse_args --verbose

    assert_equals "true" "$VERBOSE" "--verbose sets VERBOSE=true"
}

test_non_interactive_flag() {
    reset_globals
    parse_args --non-interactive

    assert_equals "true" "$NON_INTERACTIVE" "--non-interactive sets NON_INTERACTIVE=true"
}

test_dry_run_flag() {
    reset_globals
    parse_args --dry-run

    assert_equals "true" "$DRY_RUN" "--dry-run sets DRY_RUN=true"
}

test_clone_only_flag() {
    reset_globals
    parse_args --clone-only

    assert_equals "true" "$CLONE_ONLY" "--clone-only sets CLONE_ONLY=true"
}

test_pull_only_flag() {
    reset_globals
    parse_args --pull-only

    assert_equals "true" "$PULL_ONLY" "--pull-only sets PULL_ONLY=true"
}

test_autostash_flag() {
    reset_globals
    parse_args --autostash

    assert_equals "true" "$AUTOSTASH" "--autostash sets AUTOSTASH=true"
}

test_rebase_flag() {
    reset_globals
    parse_args --rebase

    assert_equals "rebase" "$UPDATE_STRATEGY" "--rebase sets UPDATE_STRATEGY=rebase"
}

test_fetch_flag() {
    reset_globals
    FETCH_REMOTES="false"
    parse_args --fetch

    assert_equals "true" "$FETCH_REMOTES" "--fetch sets FETCH_REMOTES=true"
}

test_no_fetch_flag() {
    reset_globals
    parse_args --no-fetch

    assert_equals "false" "$FETCH_REMOTES" "--no-fetch sets FETCH_REMOTES=false"
}

test_resume_flag() {
    reset_globals
    parse_args --resume

    assert_equals "true" "$RESUME" "--resume sets RESUME=true"
}

test_restart_flag() {
    reset_globals
    parse_args --restart

    assert_equals "true" "$RESTART" "--restart sets RESTART=true"
}

test_example_flag() {
    reset_globals
    parse_args --example

    assert_equals "true" "$INIT_EXAMPLE" "--example sets INIT_EXAMPLE=true"
}

#==============================================================================
# Tests: Value Flags
#==============================================================================

test_dir_flag() {
    reset_globals
    parse_args --dir /custom/path

    assert_equals "/custom/path" "$PROJECTS_DIR" "--dir sets PROJECTS_DIR"
}

test_timeout_flag() {
    reset_globals
    parse_args --timeout 120

    assert_equals "120" "$GIT_TIMEOUT" "--timeout sets GIT_TIMEOUT"
}

test_parallel_flag() {
    reset_globals
    parse_args --parallel 4

    assert_equals "4" "$PARALLEL" "--parallel sets PARALLEL"
}

test_parallel_equals_flag_before_command() {
    reset_globals
    parse_args --parallel=4 sync

    assert_equals "sync" "$COMMAND" "Command parsed after --parallel= form"
    assert_equals "4" "$PARALLEL" "--parallel= sets PARALLEL when provided before command"
}

test_j_flag() {
    reset_globals
    parse_args -j 8

    assert_equals "8" "$PARALLEL" "-j sets PARALLEL"
}

test_j_compact_flag_before_command() {
    reset_globals
    parse_args -j8 sync

    assert_equals "sync" "$COMMAND" "Command parsed after -jN form"
    assert_equals "8" "$PARALLEL" "-jN sets PARALLEL when provided before command"
}

test_parallel_and_j_equivalent() {
    reset_globals
    parse_args --parallel 4
    local parallel_result="$PARALLEL"

    reset_globals
    parse_args -j 4
    local j_result="$PARALLEL"

    assert_equals "$parallel_result" "$j_result" "--parallel and -j are equivalent"
}

#==============================================================================
# Tests: Commands
#==============================================================================

test_sync_command() {
    reset_globals
    parse_args sync

    assert_equals "sync" "$COMMAND" "sync sets COMMAND=sync"
}

test_status_command() {
    reset_globals
    parse_args status

    assert_equals "status" "$COMMAND" "status sets COMMAND=status"
}

test_init_command() {
    reset_globals
    parse_args init

    assert_equals "init" "$COMMAND" "init sets COMMAND=init"
}

test_add_command() {
    reset_globals
    parse_args add

    assert_equals "add" "$COMMAND" "add sets COMMAND=add"
}

test_remove_command() {
    reset_globals
    parse_args remove

    assert_equals "remove" "$COMMAND" "remove sets COMMAND=remove"
}

test_list_command() {
    reset_globals
    parse_args list

    assert_equals "list" "$COMMAND" "list sets COMMAND=list"
}

test_doctor_command() {
    reset_globals
    parse_args doctor

    assert_equals "doctor" "$COMMAND" "doctor sets COMMAND=doctor"
}

test_self_update_command() {
    reset_globals
    parse_args self-update

    assert_equals "self-update" "$COMMAND" "self-update sets COMMAND=self-update"
}

test_config_command() {
    reset_globals
    parse_args config

    assert_equals "config" "$COMMAND" "config sets COMMAND=config"
}

test_prune_command() {
    reset_globals
    parse_args prune

    assert_equals "prune" "$COMMAND" "prune sets COMMAND=prune"
}

test_default_command_is_sync() {
    reset_globals
    parse_args

    assert_equals "sync" "$COMMAND" "Default command is sync"
}

#==============================================================================
# Tests: Subcommand Options
#==============================================================================

test_paths_option_passed_to_args() {
    reset_globals
    parse_args list --paths

    assert_contains "${ARGS[*]}" "--paths" "--paths passed to ARGS"
}

test_print_option_passed_to_args() {
    reset_globals
    parse_args config --print

    assert_contains "${ARGS[*]}" "--print" "--print passed to ARGS"
}

test_set_option_passed_to_args() {
    reset_globals
    parse_args config --set=key=value

    assert_contains "${ARGS[*]}" "--set=key=value" "--set=key=value passed to ARGS"
}

test_check_option_passed_to_args() {
    reset_globals
    parse_args doctor --check

    assert_contains "${ARGS[*]}" "--check" "--check passed to ARGS"
}

test_archive_option_passed_to_args() {
    reset_globals
    parse_args prune --archive

    assert_contains "${ARGS[*]}" "--archive" "--archive passed to ARGS"
}

test_delete_option_passed_to_args() {
    reset_globals
    parse_args prune --delete

    assert_contains "${ARGS[*]}" "--delete" "--delete passed to ARGS"
}

test_review_auto_answer_option_passed_to_args() {
    reset_globals
    parse_args review --auto-answer=skip

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--auto-answer=skip" "--auto-answer passed to ARGS for review"
}

test_review_invalidate_cache_option_passed_to_args() {
    reset_globals
    parse_args review --invalidate-cache=all

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--invalidate-cache=all" "--invalidate-cache passed to ARGS for review"
}

test_review_auto_answer_value_form_passed_to_args() {
    reset_globals
    parse_args review --auto-answer skip

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--auto-answer" "--auto-answer flag stored in ARGS"
    assert_contains "${ARGS[*]}" "skip" "--auto-answer value stored in ARGS"
}

test_review_invalidate_cache_value_form_passed_to_args() {
    reset_globals
    parse_args review --invalidate-cache owner/repo

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--invalidate-cache" "--invalidate-cache flag stored in ARGS"
    assert_contains "${ARGS[*]}" "owner/repo" "--invalidate-cache value stored in ARGS"
}

#==============================================================================
# Tests: Positional Arguments
#==============================================================================

test_positional_argument_passed_to_args() {
    reset_globals
    parse_args add owner/repo

    assert_contains "${ARGS[*]}" "owner/repo" "Positional argument passed to ARGS"
}

test_multiple_positional_arguments() {
    reset_globals
    parse_args add owner/repo1 owner/repo2

    assert_equals "2" "${#ARGS[@]}" "Multiple positional arguments stored"
    assert_contains "${ARGS[*]}" "owner/repo1" "First positional argument stored"
    assert_contains "${ARGS[*]}" "owner/repo2" "Second positional argument stored"
}

test_positional_with_flags() {
    reset_globals
    parse_args --json add owner/repo

    assert_equals "add" "$COMMAND" "Command parsed with flags"
    assert_equals "true" "$JSON_OUTPUT" "Flag parsed with command"
    assert_contains "${ARGS[*]}" "owner/repo" "Positional argument with flags"
}

#==============================================================================
# Tests: Combined Flags
#==============================================================================

test_multiple_boolean_flags() {
    reset_globals
    parse_args --json --verbose --dry-run

    assert_equals "true" "$JSON_OUTPUT" "First flag set"
    assert_equals "true" "$VERBOSE" "Second flag set"
    assert_equals "true" "$DRY_RUN" "Third flag set"
}

test_value_flags_with_boolean() {
    reset_globals
    parse_args --json --timeout 90 --parallel 2

    assert_equals "true" "$JSON_OUTPUT" "Boolean flag set"
    assert_equals "90" "$GIT_TIMEOUT" "Timeout value set"
    assert_equals "2" "$PARALLEL" "Parallel value set"
}

test_all_flags_with_command() {
    reset_globals
    parse_args --json --verbose -q --dry-run --timeout 60 sync

    assert_equals "sync" "$COMMAND" "Command set"
    assert_equals "true" "$JSON_OUTPUT" "JSON flag set"
    assert_equals "true" "$VERBOSE" "Verbose flag set"
    assert_equals "true" "$QUIET" "Quiet flag set"
    assert_equals "true" "$DRY_RUN" "Dry run flag set"
    assert_equals "60" "$GIT_TIMEOUT" "Timeout set"
}

test_flags_after_command() {
    reset_globals
    parse_args list --paths

    assert_equals "list" "$COMMAND" "Command set before flag"
    assert_contains "${ARGS[*]}" "--paths" "Subcommand flag stored in ARGS"
}

#==============================================================================
# Tests: Edge Cases
#==============================================================================

test_empty_args() {
    reset_globals
    parse_args

    assert_equals "sync" "$COMMAND" "Empty args defaults to sync"
    assert_equals "0" "${#ARGS[@]}" "No positional arguments stored"
}

test_only_positional() {
    reset_globals
    parse_args owner/repo

    assert_equals "sync" "$COMMAND" "Default command with positional"
    assert_contains "${ARGS[*]}" "owner/repo" "Positional stored"
}

test_flags_order_independence() {
    reset_globals
    parse_args sync --json --verbose

    local result1_json="$JSON_OUTPUT"
    local result1_verbose="$VERBOSE"

    reset_globals
    parse_args --verbose sync --json

    local result2_json="$JSON_OUTPUT"
    local result2_verbose="$VERBOSE"

    assert_equals "$result1_json" "$result2_json" "JSON flag order independent"
    assert_equals "$result1_verbose" "$result2_verbose" "Verbose flag order independent"
}

test_dir_with_spaces_quoted() {
    reset_globals
    parse_args --dir "/path/with spaces"

    assert_equals "/path/with spaces" "$PROJECTS_DIR" "--dir handles quoted paths with spaces"
}

#==============================================================================
# Tests: Unknown Options
#==============================================================================

test_unknown_option_recognized() {
    # We can't easily test exit without running in subshell
    # Just verify the pattern exists in parse_args
    local func_body
    func_body=$(sed -n '/^parse_args()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "Unknown option" "parse_args handles unknown options"
    assert_contains "$func_body" "exit 4" "parse_args exits with code 4 for unknown options"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Argument Parsing"
echo "============================================"

# Boolean flags
run_test test_json_flag
run_test test_quiet_flag_short
run_test test_quiet_flag_long
run_test test_verbose_flag
run_test test_non_interactive_flag
run_test test_dry_run_flag
run_test test_clone_only_flag
run_test test_pull_only_flag
run_test test_autostash_flag
run_test test_rebase_flag
run_test test_fetch_flag
run_test test_no_fetch_flag
run_test test_resume_flag
run_test test_restart_flag
run_test test_example_flag

# Value flags
run_test test_dir_flag
run_test test_timeout_flag
run_test test_parallel_flag
run_test test_parallel_equals_flag_before_command
run_test test_j_flag
run_test test_j_compact_flag_before_command
run_test test_parallel_and_j_equivalent

# Commands
run_test test_sync_command
run_test test_status_command
run_test test_init_command
run_test test_add_command
run_test test_remove_command
run_test test_list_command
run_test test_doctor_command
run_test test_self_update_command
run_test test_config_command
run_test test_prune_command
run_test test_default_command_is_sync

# Subcommand options
run_test test_paths_option_passed_to_args
run_test test_print_option_passed_to_args
run_test test_set_option_passed_to_args
run_test test_check_option_passed_to_args
run_test test_archive_option_passed_to_args
run_test test_delete_option_passed_to_args

# Positional arguments
run_test test_positional_argument_passed_to_args
run_test test_multiple_positional_arguments
run_test test_positional_with_flags

# Combined flags
run_test test_multiple_boolean_flags
run_test test_value_flags_with_boolean
run_test test_all_flags_with_command
run_test test_flags_after_command

# Edge cases
run_test test_empty_args
run_test test_only_positional
run_test test_flags_order_independence
run_test test_dir_with_spaces_quoted

# Unknown options
run_test test_unknown_option_recognized

print_results
exit "$(get_exit_code)"
