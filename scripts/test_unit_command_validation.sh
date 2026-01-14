#!/usr/bin/env bash
#
# Unit tests: Command Validation and Blocking (bd-hmw8)
# Tests for validate_agent_command, is_command_safe, is_command_blocked
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

# Mock log functions for testing
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

#==============================================================================
# Command Validation Functions (from ru script)
#==============================================================================

SAFE_BASH_COMMANDS=(
    git grep rg find fd ls cat head tail less more bat
    make cmake ninja npm yarn pnpm cargo go pip python python3 pytest
    shellcheck eslint prettier tsc mypy ruff jq yq sed awk sort uniq wc diff
    pwd which whereis whoami date tr cut paste tar
)

APPROVAL_REQUIRED_COMMANDS=(
    rm mv cp mkdir rmdir touch curl wget http
    docker podman kubectl helm kill pkill killall
    "git push" "git push --force" "npm publish" "yarn publish"
)

BLOCKED_COMMANDS=(
    sudo su doas eval exec source chmod chown chgrp
    bash sh zsh fish dash shutdown reboot halt poweroff
    dd mkfs fdisk nc netcat ncat
)

GH_READ_COMMANDS=(
    "gh issue view" "gh issue list" "gh pr view" "gh pr list"
    "gh pr checks" "gh pr diff" "gh repo view" "gh api" "gh auth status"
)

GH_WRITE_COMMANDS=(
    "gh issue create" "gh issue close" "gh issue reopen"
    "gh issue comment" "gh issue edit" "gh pr create" "gh pr close"
    "gh pr merge" "gh pr review" "gh pr comment" "gh pr edit"
)

validate_agent_command() {
    local raw_cmd="$1"
    local mode="${2:-execute}"

    # Normalize whitespace to single spaces
    local cmd
    cmd=$(echo "$raw_cmd" | xargs)

    # Reject newline-separated commands to prevent chaining via line breaks.
    if [[ "$raw_cmd" == *$'\n'* || "$raw_cmd" == *$'\r'* ]]; then
        # Pre-escape newlines for valid JSON (jq 1.8+ may not escape in output)
        local escaped_cmd="${raw_cmd//$'\n'/\\n}"
        escaped_cmd="${escaped_cmd//$'\r'/\\r}"
        jq -n --arg cmd "$escaped_cmd" --arg status "needs_approval" \
            --arg reason "Command contains newline separators" \
            '{command: $cmd, status: $status, reason: $reason}'
        return 2
    fi

    # Extract the base command (first word)
    local base_cmd="${cmd%% *}"

    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        if [[ "$base_cmd" == "$blocked" ]]; then
            jq -n --arg cmd "$cmd" --arg base "$base_cmd" --arg status "blocked" \
                --arg reason "Command '$base_cmd' is blocked for security" \
                '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
            return 1
        fi
    done

    if [[ "$base_cmd" == "gh" ]]; then
        local gh_pattern
        for gh_pattern in "${GH_READ_COMMANDS[@]}"; do
            if [[ "$cmd" == "$gh_pattern"* ]]; then
                jq -n --arg cmd "$cmd" --arg status "allowed" \
                    --arg reason "gh read operation" \
                    '{command: $cmd, status: $status, reason: $reason}'
                return 0
            fi
        done

        for gh_pattern in "${GH_WRITE_COMMANDS[@]}"; do
            if [[ "$cmd" == "$gh_pattern"* ]]; then
                if [[ "$mode" == "plan" ]]; then
                    jq -n --arg cmd "$cmd" --arg status "blocked" \
                        --arg reason "gh write operations blocked in Plan mode" \
                        '{command: $cmd, status: $status, reason: $reason}'
                    return 1
                else
                    jq -n --arg cmd "$cmd" --arg status "needs_approval" \
                        --arg reason "gh write operation requires confirmation" \
                        '{command: $cmd, status: $status, reason: $reason}'
                    return 2
                fi
            fi
        done

        jq -n --arg cmd "$cmd" --arg status "allowed" \
            --arg reason "gh command (unknown subcommand)" \
            '{command: $cmd, status: $status, reason: $reason}'
        return 0
    fi

    # Special check for git push variants (security bypass prevention)
    if [[ "$base_cmd" == "git" ]]; then
        # Check for 'push' token anywhere in the command
        # This covers: git push, git -C path push, git push --force, etc.
        if [[ " $cmd " == *" push "* ]]; then
            jq -n \
                --arg cmd "$cmd" \
                --arg base "$base_cmd" \
                --arg status "needs_approval" \
                --arg reason "git push operation requires confirmation" \
                '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
            return 2
        fi
    fi

    local approval_cmd
    for approval_cmd in "${APPROVAL_REQUIRED_COMMANDS[@]}"; do
        if [[ "$approval_cmd" == *" "* ]]; then
            if [[ "$cmd" == "$approval_cmd"* ]]; then
                jq -n --arg cmd "$cmd" --arg status "needs_approval" \
                    --arg reason "Operation '$approval_cmd' requires confirmation" \
                    '{command: $cmd, status: $status, reason: $reason}'
                return 2
            fi
        else
            if [[ "$base_cmd" == "$approval_cmd" ]]; then
                jq -n --arg cmd "$cmd" --arg base "$base_cmd" --arg status "needs_approval" \
                    --arg reason "Command '$base_cmd' requires confirmation" \
                    '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
                return 2
            fi
        fi
    done

    local safe_cmd
    for safe_cmd in "${SAFE_BASH_COMMANDS[@]}"; do
        if [[ "$base_cmd" == "$safe_cmd" ]]; then
            jq -n --arg cmd "$cmd" --arg status "allowed" \
                --arg reason "Safe command" \
                '{command: $cmd, status: $status, reason: $reason}'
            return 0
        fi
    done

    jq -n --arg cmd "$cmd" --arg base "$base_cmd" --arg status "needs_approval" \
        --arg reason "Unknown command '$base_cmd' requires review" \
        '{command: $cmd, base_command: $base, status: $status, reason: $reason}'
    return 2
}

is_command_safe() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(echo "$cmd" | awk '{print $1}')

    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$blocked" ]] && return 1
    done

    local safe_cmd
    for safe_cmd in "${SAFE_BASH_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$safe_cmd" ]] && return 0
    done

    return 1
}

is_command_blocked() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(echo "$cmd" | awk '{print $1}')

    local blocked
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        [[ "$base_cmd" == "$blocked" ]] && return 0
    done

    return 1
}

#==============================================================================
# Tests: Safe Commands
#==============================================================================

test_safe_command_git() {
    local test_name="validate_agent_command: git is safe"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "git status")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exit code should be 0 (allowed)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "allowed" "$status" "Status should be 'allowed'"

    log_test_pass "$test_name"
}

test_safe_command_grep() {
    local test_name="validate_agent_command: grep is safe"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "grep -r 'pattern' .")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exit code should be 0 (allowed)"

    log_test_pass "$test_name"
}

test_safe_command_jq() {
    local test_name="validate_agent_command: jq is safe"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "jq '.key' file.json")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exit code should be 0 (allowed)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Blocked Commands
#==============================================================================

test_blocked_command_sudo() {
    local test_name="validate_agent_command: sudo is blocked"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "sudo apt install foo")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "blocked" "$status" "Status should be 'blocked'"

    log_test_pass "$test_name"
}

test_blocked_command_eval() {
    local test_name="validate_agent_command: eval is blocked"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "eval 'echo hello'")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    log_test_pass "$test_name"
}

test_blocked_command_chmod() {
    local test_name="validate_agent_command: chmod is blocked"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "chmod +x script.sh")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    log_test_pass "$test_name"
}

test_blocked_command_bash() {
    local test_name="validate_agent_command: bash is blocked"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "bash -c 'echo test'")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Approval Required Commands
#==============================================================================

test_approval_rm() {
    local test_name="validate_agent_command: rm needs approval"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "rm -rf node_modules")
    local exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "needs_approval" "$status" "Status should be 'needs_approval'"

    log_test_pass "$test_name"
}

test_approval_curl() {
    local test_name="validate_agent_command: curl needs approval"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "curl https://example.com")
    local exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"

    log_test_pass "$test_name"
}

test_approval_docker() {
    local test_name="validate_agent_command: docker needs approval"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "docker run alpine")
    local exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: gh Command Special Handling
#==============================================================================

test_gh_read_allowed() {
    local test_name="validate_agent_command: gh issue list is allowed"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "gh issue list --limit 10")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exit code should be 0 (allowed)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "allowed" "$status" "Status should be 'allowed'"

    log_test_pass "$test_name"
}

test_gh_write_approval_execute_mode() {
    local test_name="validate_agent_command: gh issue close needs approval in execute mode"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "gh issue close 123" "execute")
    local exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "needs_approval" "$status" "Status should be 'needs_approval'"

    log_test_pass "$test_name"
}

test_gh_write_blocked_plan_mode() {
    local test_name="validate_agent_command: gh issue close is blocked in plan mode"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "gh issue close 123" "plan")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "blocked" "$status" "Status should be 'blocked'"

    log_test_pass "$test_name"
}

test_gh_pr_merge_plan_mode() {
    local test_name="validate_agent_command: gh pr merge is blocked in plan mode"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "gh pr merge 42 --squash" "plan")
    local exit_code=$?

    assert_equals "1" "$exit_code" "Exit code should be 1 (blocked)"

    log_test_pass "$test_name"
}

test_git_push_bypass_variants() {
    local test_name="validate_agent_command: git push variants need approval"
    log_test_start "$test_name"

    # Test git  push (two spaces)
    local result
    result=$(validate_agent_command "git  push")
    local exit_code=$?
    assert_equals "2" "$exit_code" "git  push should need approval"
    
    # Test git -C . push
    result=$(validate_agent_command "git -C . push")
    exit_code=$?
    assert_equals "2" "$exit_code" "git -C . push should need approval"

    # Test git push --force
    result=$(validate_agent_command "git push --force")
    exit_code=$?
    assert_equals "2" "$exit_code" "git push --force should need approval"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Unknown Commands
#==============================================================================

test_unknown_command() {
    local test_name="validate_agent_command: unknown command needs approval"
    log_test_start "$test_name"

    local result
    result=$(validate_agent_command "someunknowntool --option")
    local exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"

    local status
    status=$(echo "$result" | jq -r '.status')
    assert_equals "needs_approval" "$status" "Status should be 'needs_approval'"

    log_test_pass "$test_name"
}

test_multiline_command_needs_approval() {
    local test_name="validate_agent_command: newline separators need approval"
    log_test_start "$test_name"

    local result exit_code status
    result=$(validate_agent_command $'git status\nrm -rf /')
    exit_code=$?

    assert_equals "2" "$exit_code" "Exit code should be 2 (needs approval)"
    status=$(echo "$result" | jq -r '.status')
    assert_equals "needs_approval" "$status" "Status should be 'needs_approval'"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Helper Functions
#==============================================================================

test_is_command_safe_git() {
    local test_name="is_command_safe: returns 0 for git"
    log_test_start "$test_name"

    if is_command_safe "git status"; then
        pass "git should be safe"
    else
        fail "git should be safe"
    fi

    log_test_pass "$test_name"
}

test_is_command_safe_sudo() {
    local test_name="is_command_safe: returns 1 for sudo"
    log_test_start "$test_name"

    if is_command_safe "sudo apt update"; then
        fail "sudo should not be safe"
    else
        pass "sudo should not be safe"
    fi

    log_test_pass "$test_name"
}

test_is_command_blocked_eval() {
    local test_name="is_command_blocked: returns 0 for eval"
    log_test_start "$test_name"

    if is_command_blocked "eval 'test'"; then
        pass "eval should be blocked"
    else
        fail "eval should be blocked"
    fi

    log_test_pass "$test_name"
}

test_is_command_blocked_ls() {
    local test_name="is_command_blocked: returns 1 for ls"
    log_test_start "$test_name"

    if is_command_blocked "ls -la"; then
        fail "ls should not be blocked"
    else
        pass "ls should not be blocked"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Command Validation and Blocking"

    # Safe command tests
    run_test test_safe_command_git
    run_test test_safe_command_grep
    run_test test_safe_command_jq

    # Blocked command tests
    run_test test_blocked_command_sudo
    run_test test_blocked_command_eval
    run_test test_blocked_command_chmod
    run_test test_blocked_command_bash

    # Approval required tests
    run_test test_approval_rm
    run_test test_approval_curl
    run_test test_approval_docker

    # gh command tests
    run_test test_gh_read_allowed
    run_test test_gh_write_approval_execute_mode
    run_test test_gh_write_blocked_plan_mode
    run_test test_gh_pr_merge_plan_mode
    run_test test_git_push_bypass_variants

    # Unknown command tests
    run_test test_unknown_command
    run_test test_multiline_command_needs_approval

    # Helper function tests
    run_test test_is_command_safe_git
    run_test test_is_command_safe_sudo
    run_test test_is_command_blocked_eval
    run_test test_is_command_blocked_ls

    print_results
    return "$(get_exit_code)"
}

run_all_tests
