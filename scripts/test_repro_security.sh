#!/usr/bin/env bash
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Arrays consumed by validate_agent_command
set -uo pipefail

source ./scripts/test_framework.sh

# Source the function to test
source_ru_function "validate_agent_command"
source_ru_function "json_escape"

# Mock constants needed by validate_agent_command
SAFE_BASH_COMMANDS=(ls git grep)
BLOCKED_COMMANDS=(sudo eval)
APPROVAL_REQUIRED_COMMANDS=(rm curl)
GH_READ_COMMANDS=("gh issue list")
GH_WRITE_COMMANDS=("gh issue close")

# Helper to extract status from JSON output
get_status() {
    echo "$1" | jq -r '.status'
}

test_command_chaining_bypass() {
    local cmd="ls -la ; echo pwned"
    local output
    output=$(validate_agent_command "$cmd")
    local status
    status=$(get_status "$output")

    # Current behavior: returns "allowed" because base_cmd is "ls"
    if [[ "$status" == "allowed" ]]; then
        echo "VULNERABILITY CONFIRMED: '$cmd' was allowed"
        return 1  # We want this to fail (demonstrating the bug)
    else
        echo "SAFE: '$cmd' was $status"
        return 0
    fi
}

test_pipe_bypass() {
    local cmd="ls | rm -rf /"
    local output
    output=$(validate_agent_command "$cmd")
    local status
    status=$(get_status "$output")

    if [[ "$status" == "allowed" ]]; then
        echo "VULNERABILITY CONFIRMED: '$cmd' was allowed"
        return 1
    else
        echo "SAFE: '$cmd' was $status"
        return 0
    fi
}

run_test test_command_chaining_bypass
run_test test_pipe_bypass
print_results
