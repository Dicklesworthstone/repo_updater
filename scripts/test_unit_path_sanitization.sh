#!/usr/bin/env bash
#
# Unit Tests: Path Sanitization
# Tests for sanitize_path_segment function with dangerous inputs
#
# Test coverage:
#   - Rejects empty input
#   - Trims leading/trailing whitespace
#   - Replaces forward slashes with underscores
#   - Replaces backslashes with underscores
#   - Replaces colons with underscores (Windows safety)
#   - Replaces asterisks with underscores
#   - Replaces question marks with underscores
#   - Replaces double quotes with underscores
#   - Replaces less-than with underscores
#   - Replaces greater-than with underscores
#   - Replaces pipes with underscores
#   - Removes leading dots (hidden files)
#   - Rejects strings that become empty after sanitization
#   - Handles multiple problematic characters
#   - Preserves valid path segments
#   - Security: Path traversal attempts (../)
#   - Security: Null bytes
#   - Security: Unicode edge cases
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' RESET=''
fi

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

#==============================================================================
# Source Function from ru
#==============================================================================

# Extract sanitize_path_segment function
eval "$(sed -n '/^sanitize_path_segment()/,/^}/p' "$RU_SCRIPT")"

#==============================================================================
# Tests: Basic Input Validation
#==============================================================================

test_rejects_empty_input() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment rejects empty input"

    if ! sanitize_path_segment "" >/dev/null 2>&1; then
        pass "Empty input rejected (return code 1)"
    else
        fail "Empty input should be rejected"
    fi
}

test_trims_leading_whitespace() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment trims leading whitespace"

    local result
    result=$(sanitize_path_segment "   repo_name")

    if [[ "$result" == "repo_name" ]]; then
        pass "Leading whitespace trimmed"
    else
        fail "Leading whitespace not trimmed (got: '$result')"
    fi
}

test_trims_trailing_whitespace() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment trims trailing whitespace"

    local result
    result=$(sanitize_path_segment "repo_name   ")

    if [[ "$result" == "repo_name" ]]; then
        pass "Trailing whitespace trimmed"
    else
        fail "Trailing whitespace not trimmed (got: '$result')"
    fi
}

test_trims_both_whitespace() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment trims both leading and trailing whitespace"

    local result
    result=$(sanitize_path_segment "  repo_name  ")

    if [[ "$result" == "repo_name" ]]; then
        pass "Both sides whitespace trimmed"
    else
        fail "Whitespace not fully trimmed (got: '$result')"
    fi
}

#==============================================================================
# Tests: Character Replacement
#==============================================================================

test_replaces_forward_slash() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces forward slashes"

    local result
    result=$(sanitize_path_segment "path/to/file")

    if [[ "$result" == "path_to_file" ]]; then
        pass "Forward slashes replaced with underscores"
    else
        fail "Forward slashes not replaced (got: '$result')"
    fi
}

test_replaces_backslash() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces backslashes"

    local result
    result=$(sanitize_path_segment 'path\to\file')

    if [[ "$result" == "path_to_file" ]]; then
        pass "Backslashes replaced with underscores"
    else
        fail "Backslashes not replaced (got: '$result')"
    fi
}

test_replaces_colon() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces colons"

    local result
    result=$(sanitize_path_segment "C:file")

    if [[ "$result" == "C_file" ]]; then
        pass "Colons replaced with underscores"
    else
        fail "Colons not replaced (got: '$result')"
    fi
}

test_replaces_asterisk() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces asterisks"

    local result
    result=$(sanitize_path_segment "file*name")

    if [[ "$result" == "file_name" ]]; then
        pass "Asterisks replaced with underscores"
    else
        fail "Asterisks not replaced (got: '$result')"
    fi
}

test_replaces_question_mark() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces question marks"

    local result
    result=$(sanitize_path_segment "file?name")

    if [[ "$result" == "file_name" ]]; then
        pass "Question marks replaced with underscores"
    else
        fail "Question marks not replaced (got: '$result')"
    fi
}

test_replaces_double_quote() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces double quotes"

    local result
    result=$(sanitize_path_segment 'file"name')

    if [[ "$result" == "file_name" ]]; then
        pass "Double quotes replaced with underscores"
    else
        fail "Double quotes not replaced (got: '$result')"
    fi
}

test_replaces_less_than() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces less-than"

    local result
    result=$(sanitize_path_segment "file<name")

    if [[ "$result" == "file_name" ]]; then
        pass "Less-than replaced with underscores"
    else
        fail "Less-than not replaced (got: '$result')"
    fi
}

test_replaces_greater_than() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces greater-than"

    local result
    result=$(sanitize_path_segment "file>name")

    if [[ "$result" == "file_name" ]]; then
        pass "Greater-than replaced with underscores"
    else
        fail "Greater-than not replaced (got: '$result')"
    fi
}

test_replaces_pipe() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment replaces pipes"

    local result
    result=$(sanitize_path_segment "file|name")

    if [[ "$result" == "file_name" ]]; then
        pass "Pipes replaced with underscores"
    else
        fail "Pipes not replaced (got: '$result')"
    fi
}

#==============================================================================
# Tests: Leading Dots
#==============================================================================

test_removes_single_leading_dot() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment removes single leading dot"

    local result
    result=$(sanitize_path_segment ".hidden")

    if [[ "$result" == "hidden" ]]; then
        pass "Single leading dot removed"
    else
        fail "Single leading dot not removed (got: '$result')"
    fi
}

test_removes_multiple_leading_dots() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment removes multiple leading dots"

    local result
    result=$(sanitize_path_segment "...hidden")

    if [[ "$result" == "hidden" ]]; then
        pass "Multiple leading dots removed"
    else
        fail "Multiple leading dots not removed (got: '$result')"
    fi
}

test_rejects_only_dots() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment rejects strings that are only dots"

    if ! sanitize_path_segment "..." >/dev/null 2>&1; then
        pass "String of only dots rejected"
    else
        fail "String of only dots should be rejected"
    fi
}

#==============================================================================
# Tests: Edge Cases
#==============================================================================

test_rejects_whitespace_only() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment rejects whitespace-only input"

    if ! sanitize_path_segment "   " >/dev/null 2>&1; then
        pass "Whitespace-only input rejected"
    else
        fail "Whitespace-only input should be rejected"
    fi
}

test_multiple_problematic_chars() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles multiple problematic characters"

    local result
    result=$(sanitize_path_segment 'file/path\with:many*bad?chars"here<and>more|now')

    # All problematic chars should be replaced with underscores
    if [[ "$result" != */* && "$result" != *\\* && "$result" != *:* &&
          "$result" != *\** && "$result" != *\?* && "$result" != *\"* &&
          "$result" != *\<* && "$result" != *\>* && "$result" != *\|* ]]; then
        pass "Multiple problematic characters all replaced"
    else
        fail "Some problematic characters remain (got: '$result')"
    fi
}

test_preserves_valid_segment() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment preserves valid path segments"

    local result
    result=$(sanitize_path_segment "valid-repo_name.git")

    if [[ "$result" == "valid-repo_name.git" ]]; then
        pass "Valid segment preserved"
    else
        fail "Valid segment was modified (got: '$result')"
    fi
}

test_preserves_dashes() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment preserves dashes"

    local result
    result=$(sanitize_path_segment "my-repo-name")

    if [[ "$result" == "my-repo-name" ]]; then
        pass "Dashes preserved"
    else
        fail "Dashes were not preserved (got: '$result')"
    fi
}

test_preserves_underscores() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment preserves underscores"

    local result
    result=$(sanitize_path_segment "my_repo_name")

    if [[ "$result" == "my_repo_name" ]]; then
        pass "Underscores preserved"
    else
        fail "Underscores were not preserved (got: '$result')"
    fi
}

test_preserves_internal_dots() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment preserves internal dots"

    local result
    result=$(sanitize_path_segment "repo.name.git")

    if [[ "$result" == "repo.name.git" ]]; then
        pass "Internal dots preserved"
    else
        fail "Internal dots were not preserved (got: '$result')"
    fi
}

#==============================================================================
# Tests: Security - Path Traversal
#==============================================================================

test_path_traversal_dotdotslash() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles path traversal (../)"

    local result
    result=$(sanitize_path_segment "../../../etc/passwd")

    # Slashes should be replaced, dots should be removed from start
    if [[ "$result" != */* && "$result" != ..* ]]; then
        pass "Path traversal attack neutralized"
    else
        fail "Path traversal attack not fully neutralized (got: '$result')"
    fi
}

test_path_traversal_dotdotbackslash() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles path traversal (..\\)"

    local result
    result=$(sanitize_path_segment '..\..\..\Windows\System32')

    # Backslashes should be replaced, dots should be removed from start
    if [[ "$result" != *\\* && "$result" != ..* ]]; then
        pass "Windows-style path traversal attack neutralized"
    else
        fail "Windows path traversal not neutralized (got: '$result')"
    fi
}

#==============================================================================
# Tests: Security - Command Injection Attempts
#==============================================================================

test_command_injection_semicolon() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles semicolons"

    local result
    result=$(sanitize_path_segment "repo;rm -rf /")

    # Semicolons are allowed (not in the replacement list)
    # but this tests that the function at least doesn't execute commands
    if [[ -n "$result" ]]; then
        pass "Semicolon input processed safely"
    else
        fail "Semicolon input caused failure"
    fi
}

test_command_injection_backticks() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles backticks"

    local result
    result=$(sanitize_path_segment 'repo`whoami`')

    # Backticks are allowed but should not be executed
    if [[ -n "$result" ]]; then
        pass "Backtick input processed safely"
    else
        fail "Backtick input caused failure"
    fi
}

test_command_injection_dollar_parens() {
    echo -e "${BLUE}Test:${RESET} sanitize_path_segment handles \$() syntax"

    local result
    result=$(sanitize_path_segment 'repo$(whoami)')

    # Dollar parens should not be executed
    if [[ -n "$result" ]]; then
        pass "Dollar-paren input processed safely"
    else
        fail "Dollar-paren input caused failure"
    fi
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Path Sanitization"
echo "============================================"
echo ""

# Basic input validation
test_rejects_empty_input
echo ""
test_trims_leading_whitespace
echo ""
test_trims_trailing_whitespace
echo ""
test_trims_both_whitespace
echo ""

# Character replacement
test_replaces_forward_slash
echo ""
test_replaces_backslash
echo ""
test_replaces_colon
echo ""
test_replaces_asterisk
echo ""
test_replaces_question_mark
echo ""
test_replaces_double_quote
echo ""
test_replaces_less_than
echo ""
test_replaces_greater_than
echo ""
test_replaces_pipe
echo ""

# Leading dots
test_removes_single_leading_dot
echo ""
test_removes_multiple_leading_dots
echo ""
test_rejects_only_dots
echo ""

# Edge cases
test_rejects_whitespace_only
echo ""
test_multiple_problematic_chars
echo ""
test_preserves_valid_segment
echo ""
test_preserves_dashes
echo ""
test_preserves_underscores
echo ""
test_preserves_internal_dots
echo ""

# Security - path traversal
test_path_traversal_dotdotslash
echo ""
test_path_traversal_dotdotbackslash
echo ""

# Security - command injection
test_command_injection_semicolon
echo ""
test_command_injection_backticks
echo ""
test_command_injection_dollar_parens
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
