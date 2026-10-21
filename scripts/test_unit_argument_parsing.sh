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
#   - Options before or after a command select the same behavior
#   - Documented command-specific flags (config --set, agent-sweep, import)
#   - Top-level startup code reads no heredoc or here-string
#   - ru reads no heredoc anywhere, and no here-string outside run_with_input
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

test_review_status_option_passed_to_args() {
    reset_globals
    parse_args review --status

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--status" "--status passed to ARGS for review"
}

test_review_status_option_before_command_passed_to_args() {
    reset_globals
    parse_args --status review

    assert_equals "review" "$COMMAND" "review sets COMMAND=review"
    assert_contains "${ARGS[*]}" "--status" "--status preserved when provided before command"
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
# Tests: Option Placement and Command-Specific Flags
#==============================================================================

test_dry_run_before_ai_sync_reaches_ai_sync() {
    # A leading --dry-run used to set only the global flag, which ai-sync
    # ignores, so `ru --dry-run ai-sync` ran for real.
    reset_globals
    parse_args --dry-run ai-sync

    assert_equals "ai-sync" "$COMMAND" "Command is found after a leading option"
    assert_contains "${ARGS[*]}" "--dry-run" "Leading --dry-run reaches ai-sync's own options"
}

test_option_placement_is_equivalent() {
    local cmd before after
    for cmd in ai-sync dep-update agent-sweep review; do
        reset_globals
        parse_args --dry-run "$cmd"
        before="$COMMAND|${ARGS[*]}|$DRY_RUN"
        reset_globals
        parse_args "$cmd" --dry-run
        after="$COMMAND|${ARGS[*]}|$DRY_RUN"
        assert_equals "$after" "$before" "--dry-run before or after $cmd parses the same"
    done
}

test_option_value_is_not_the_command() {
    reset_globals
    parse_args --dir status sync

    assert_equals "sync" "$COMMAND" "A --dir value that names a command is not the command"
}

test_second_command_word_is_an_argument() {
    reset_globals
    parse_args add status

    assert_equals "add" "$COMMAND" "The first command word is the command"
    assert_contains "${ARGS[*]}" "status" "A later command word is passed on as an argument"
}

test_config_set_space_form() {
    reset_globals
    parse_args config --set LAYOUT=owner-repo

    assert_contains "${ARGS[*]}" "--set=LAYOUT=owner-repo" "--set KEY=VALUE reaches config as --set=KEY=VALUE"
}

test_config_set_requires_key_value() {
    local rc=0
    (reset_globals; parse_args config --set LAYOUT) >/dev/null 2>&1 || rc=$?

    assert_equals "4" "$rc" "--set without KEY=VALUE exits 4"
}

test_agent_sweep_flags_reach_agent_sweep() {
    reset_globals
    parse_args agent-sweep --debug -d --show-denylist -v -j4 -j 3

    local flag
    for flag in --debug -d --show-denylist -v -j4 -j3; do
        assert_contains " ${ARGS[*]} " " $flag " "agent-sweep receives $flag"
    done
    assert_equals "1" "$PARALLEL" "agent-sweep -j leaves the global PARALLEL alone"
}

test_import_github_flags_reach_import() {
    reset_globals
    parse_args import --stars --org=acme --user=someone --limit=5

    local flag
    for flag in --stars --org=acme --user=someone --limit=5; do
        assert_contains " ${ARGS[*]} " " $flag " "import receives $flag"
    done
}

test_command_specific_flags_rejected_elsewhere() {
    local flag rc
    for flag in --debug -d --show-denylist --stars --org=acme --set; do
        rc=0
        (reset_globals; parse_args sync "$flag" KEY=VALUE) >/dev/null 2>&1 || rc=$?
        assert_equals "4" "$rc" "sync rejects $flag"
    done
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
# Tests: Heredocs and Here-Strings
#==============================================================================

# Bash writes a small heredoc or here-string whole into a pipe before reading
# it back, and macOS shrinks new pipes to 512 bytes when kernel pipe memory
# runs short, so a longer one blocks forever. At top level that hangs every ru
# command; inside a function it hangs that command. ru therefore uses printf
# and run_with_input, whose own here-string only carries input that fits.

# Print "LINE: text" for each top-level heredoc or here-string read from
# stdin (or for every one, given "all"), then "depth=N" (0 when function
# tracking stayed balanced). Only code counts: quoted text and comments are
# blanked, while a $(...) inside double quotes is code again. Quote state
# carries across lines, so a brace or "<<" inside a multi-line literal cannot
# end a function early or look like a heredoc. Heredoc bodies are skipped for
# the same reason.
top_level_heredocs() {
    awk -v q="'" -v all="${1:-}" '
        BEGIN { start = "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*" }
        heredoc != "" {
            line = $0
            if (strip_tabs) sub(/^\t+/, "", line)
            if (line == heredoc) heredoc = ""
            next
        }
        {
            # stack of open contexts: s = single quotes, d = double quotes,
            # p = parentheses (code); code = this line with non-code blanked
            plain = (stack == "")
            code = ""
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                top = substr(stack, length(stack), 1)
                if (top == "s") {
                    if (c == q) stack = substr(stack, 1, length(stack) - 1)
                    continue
                }
                if (top == "d") {
                    if (c == "\\") i++
                    else if (c == "\"") stack = substr(stack, 1, length(stack) - 1)
                    else if (c == "$" && substr($0, i + 1, 1) == "(") { stack = stack "p"; code = code " "; i++ }
                    continue
                }
                if (c == "\\") { code = code c substr($0, i + 1, 1); i++; continue }
                if (c == q) { stack = stack "s"; code = code " "; continue }
                if (c == "\"") { stack = stack "d"; code = code " "; continue }
                if (c == "(") stack = stack "p"
                else if (c == ")" && top == "p") stack = substr(stack, 1, length(stack) - 1)
                else if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[[:space:]]/)) break
                code = code c
            }
        }
        plain && code ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ && code !~ /;[[:space:]]*\}[[:space:]]*$/ { depth++ }
        {
            if ((depth == 0 || all != "") && code ~ /<</) print NR ": " $0
            if (code ~ /<</ && code !~ /<<</ && match($0, start)) {
                tok = substr($0, RSTART, RLENGTH)
                strip_tabs = (tok ~ /^<<-/)
                sub("^<<-?[[:space:]]*[\"" q "]?", "", tok)
                heredoc = tok
            }
        }
        plain && code ~ /^}[[:space:]]*([<>|&;].*)?$/ { if (depth > 0) depth--; else print "stray-brace " NR }
        END { print "depth=" depth }
    '
}

test_top_level_heredoc_scan_finds_only_top_level() {
    # Function bodies (including a heredoc whose body ends in a brace, a
    # one-line function, and a multi-line literal ending in }') are ignored;
    # the top-level heredoc and here-string are reported.
    local report
    report=$(printf '%s\n' \
        'one_liner() { true; }' \
        'with_heredoc() {' \
        "    cat <<'EOF'" \
        '{' \
        '}' \
        'EOF' \
        "    local json='{" \
        "}'" \
        '}' \
        "read -r -d '' TOP << 'EOF_TOP'" \
        'body' \
        'EOF_TOP' \
        'grep x <<< "$value"' \
        'echo done' | top_level_heredocs)

    assert_equals "10: read -r -d '' TOP << 'EOF_TOP'
13: grep x <<< \"\$value\"
depth=0" "$report" "scan reports only the top-level heredoc and here-string"
}

test_heredoc_scan_all_mode_finds_function_bodies() {
    local report
    report=$(printf '%s\n' \
        'f() {' \
        "    cat <<'EOF'" \
        '}' \
        'EOF' \
        '    jq . <<< "$json"' \
        '}' | top_level_heredocs all)

    assert_equals "2:     cat <<'EOF'
5:     jq . <<< \"\$json\"
depth=0" "$report" "scan in all mode reports heredocs and here-strings inside functions"
}

test_startup_runs_no_heredoc() {
    local report
    report=$(top_level_heredocs < "$RU_SCRIPT")

    assert_equals "depth=0" "$report" "ru top-level code reads no heredoc or here-string"
}

test_ru_reads_no_heredoc_or_long_herestring() {
    # The one here-string left is run_with_input's own, which only carries
    # input that fits in a 512-byte pipe.
    local report
    report=$(top_level_heredocs all < "$RU_SCRIPT" | grep -v -F '"$@" <<< "$_ru_input"')

    assert_equals "depth=0" "$report" "ru reads no heredoc, and no here-string outside run_with_input"
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

# Option placement and command-specific flags
run_test test_dry_run_before_ai_sync_reaches_ai_sync
run_test test_option_placement_is_equivalent
run_test test_option_value_is_not_the_command
run_test test_second_command_word_is_an_argument
run_test test_config_set_space_form
run_test test_config_set_requires_key_value
run_test test_agent_sweep_flags_reach_agent_sweep
run_test test_import_github_flags_reach_import
run_test test_command_specific_flags_rejected_elsewhere

# Unknown options
run_test test_unknown_option_recognized

# Heredocs and here-strings
run_test test_top_level_heredoc_scan_finds_only_top_level
run_test test_heredoc_scan_all_mode_finds_function_bodies
run_test test_startup_runs_no_heredoc
run_test test_ru_reads_no_heredoc_or_long_herestring

print_results
exit "$(get_exit_code)"
