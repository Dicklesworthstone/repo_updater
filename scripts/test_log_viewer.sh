#!/usr/bin/env bash
#
# test_log_viewer.sh - View and filter test JSON logs
#
# Usage:
#   ./test_log_viewer.sh [options] [log_file]
#
# Options:
#   --filter-event TYPE    Show only events of type (test_start, assertion, etc.)
#   --filter-result RESULT Show only pass/fail/skip results
#   --filter-test NAME     Show only events for specific test
#   --summary              Show only summary statistics
#   --failed               Show only failed assertions/tests
#   --json                 Output filtered results as JSON
#   --help                 Show this help
#
# Examples:
#   ./test_log_viewer.sh test.jsonl --failed
#   ./test_log_viewer.sh test.jsonl --filter-event assertion
#   TF_JSON_MODE=true ./test.sh 2>&1 | ./test_log_viewer.sh --summary
#
# shellcheck disable=SC2034

set -uo pipefail

#==============================================================================
# Argument Parsing
#==============================================================================

FILTER_EVENT=""
FILTER_RESULT=""
FILTER_TEST=""
SHOW_SUMMARY=false
SHOW_FAILED=false
OUTPUT_JSON=false
INPUT_FILE=""

print_help() {
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter-event)
            FILTER_EVENT="$2"
            shift 2
            ;;
        --filter-result)
            FILTER_RESULT="$2"
            shift 2
            ;;
        --filter-test)
            FILTER_TEST="$2"
            shift 2
            ;;
        --summary)
            SHOW_SUMMARY=true
            shift
            ;;
        --failed)
            SHOW_FAILED=true
            shift
            ;;
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        *)
            INPUT_FILE="$1"
            shift
            ;;
    esac
done

#==============================================================================
# Color Output
#==============================================================================

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

#==============================================================================
# Filter Functions
#==============================================================================

# Build jq filter from options
build_jq_filter() {
    local filter="."

    if [[ -n "$FILTER_EVENT" ]]; then
        filter="$filter | select(.event == \"$FILTER_EVENT\")"
    fi

    if [[ -n "$FILTER_RESULT" ]]; then
        filter="$filter | select(.result == \"$FILTER_RESULT\")"
    fi

    if [[ -n "$FILTER_TEST" ]]; then
        filter="$filter | select(.test_name == \"$FILTER_TEST\")"
    fi

    if [[ "$SHOW_FAILED" == "true" ]]; then
        filter="$filter | select(.result == \"fail\")"
    fi

    echo "$filter"
}

# Format a single log entry for human display
format_entry() {
    local line="$1"

    local event timestamp test_name result message
    event=$(echo "$line" | jq -r '.event // "unknown"')
    timestamp=$(echo "$line" | jq -r '.timestamp // ""')
    test_name=$(echo "$line" | jq -r '.test_name // ""')
    result=$(echo "$line" | jq -r '.result // ""')
    message=$(echo "$line" | jq -r '.message // ""')

    local time_short=""
    if [[ -n "$timestamp" ]]; then
        time_short=$(echo "$timestamp" | sed 's/.*T\([0-9:]*\).*/\1/')
    fi

    local color=""
    case "$result" in
        pass) color="$GREEN" ;;
        fail) color="$RED" ;;
        skip) color="$YELLOW" ;;
    esac

    case "$event" in
        test_start)
            printf "%s %s[START]%s %s\n" "$time_short" "$BOLD" "$RESET" "$test_name"
            ;;
        test_result)
            local duration_ms
            duration_ms=$(echo "$line" | jq -r '.duration_ms // 0')
            printf "%s %s[%s]%s %s (%dms)\n" "$time_short" "$color" "${result^^}" "$RESET" "$test_name" "$duration_ms"
            ;;
        assertion)
            printf "  %s%s%s: %s\n" "$color" "${result^^}" "$RESET" "$message"
            ;;
        e2e_operation)
            local operation phase
            operation=$(echo "$line" | jq -r '.operation // ""')
            phase=$(echo "$line" | jq -r '.phase // ""')
            printf "  %s[%s/%s]%s %s\n" "$BLUE" "$phase" "$operation" "$RESET" "$(echo "$line" | jq -r '.description // ""')"
            ;;
        e2e_result)
            local operation
            operation=$(echo "$line" | jq -r '.operation // ""')
            printf "  %s[%s]%s %s\n" "$color" "${result^^}" "$RESET" "$operation"
            ;;
        suite_start)
            printf "\n%s=== Suite: %s ===%s\n" "$BOLD" "$(echo "$line" | jq -r '.suite_name // ""')" "$RESET"
            ;;
        suite_end)
            local passed failed skipped
            passed=$(echo "$line" | jq -r '.tests_passed // 0')
            failed=$(echo "$line" | jq -r '.tests_failed // 0')
            skipped=$(echo "$line" | jq -r '.tests_skipped // 0')
            printf "\n%s=== Results: %s%d passed%s, %s%d failed%s, %s%d skipped%s ===%s\n" \
                "$BOLD" "$GREEN" "$passed" "$RESET" "$RED" "$failed" "$RESET" "$YELLOW" "$skipped" "$RESET" "$RESET"
            ;;
        *)
            if [[ "$OUTPUT_JSON" == "true" ]]; then
                echo "$line"
            fi
            ;;
    esac
}

# Generate summary statistics
generate_summary() {
    local input="$1"

    local total_tests passed_tests failed_tests skipped_tests
    local total_assertions passed_assertions failed_assertions

    total_tests=$(echo "$input" | jq -s '[.[] | select(.event == "test_result")] | length')
    passed_tests=$(echo "$input" | jq -s '[.[] | select(.event == "test_result" and .result == "pass")] | length')
    failed_tests=$(echo "$input" | jq -s '[.[] | select(.event == "test_result" and .result == "fail")] | length')
    skipped_tests=$(echo "$input" | jq -s '[.[] | select(.event == "test_result" and .result == "skip")] | length')

    total_assertions=$(echo "$input" | jq -s '[.[] | select(.event == "assertion")] | length')
    passed_assertions=$(echo "$input" | jq -s '[.[] | select(.event == "assertion" and .result == "pass")] | length')
    failed_assertions=$(echo "$input" | jq -s '[.[] | select(.event == "assertion" and .result == "fail")] | length')

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        jq -n \
            --argjson total_tests "$total_tests" \
            --argjson passed_tests "$passed_tests" \
            --argjson failed_tests "$failed_tests" \
            --argjson skipped_tests "$skipped_tests" \
            --argjson total_assertions "$total_assertions" \
            --argjson passed_assertions "$passed_assertions" \
            --argjson failed_assertions "$failed_assertions" \
            '{
                tests: { total: $total_tests, passed: $passed_tests, failed: $failed_tests, skipped: $skipped_tests },
                assertions: { total: $total_assertions, passed: $passed_assertions, failed: $failed_assertions }
            }'
    else
        printf "\n%sTest Log Summary%s\n" "$BOLD" "$RESET"
        printf "================\n"
        printf "Tests:      %s%d passed%s, %s%d failed%s, %s%d skipped%s (total: %d)\n" \
            "$GREEN" "$passed_tests" "$RESET" \
            "$RED" "$failed_tests" "$RESET" \
            "$YELLOW" "$skipped_tests" "$RESET" \
            "$total_tests"
        printf "Assertions: %s%d passed%s, %s%d failed%s (total: %d)\n" \
            "$GREEN" "$passed_assertions" "$RESET" \
            "$RED" "$failed_assertions" "$RESET" \
            "$total_assertions"

        if [[ "$failed_tests" -gt 0 ]]; then
            printf "\n%sFailed Tests:%s\n" "$RED" "$RESET"
            echo "$input" | jq -r 'select(.event == "test_result" and .result == "fail") | "  - \(.test_name)"'
        fi
    fi
}

#==============================================================================
# Main
#==============================================================================

# Read input (file or stdin)
if [[ -n "$INPUT_FILE" && -f "$INPUT_FILE" ]]; then
    input=$(cat "$INPUT_FILE")
elif [[ ! -t 0 ]]; then
    # Read from stdin, extract JSON lines
    input=$(grep -E '^\{' || true)
else
    # No input and no stdin: behave like a normal CLI and show help.
    # This also allows the script to exist in the test suite without failing discovery.
    if [[ -z "$INPUT_FILE" ]]; then
        print_help >&2
        exit 0
    fi
    echo "Error: Input file not found: $INPUT_FILE" >&2
    print_help >&2
    exit 1
fi

# Check if we have valid JSON input
if ! echo "$input" | head -1 | jq empty 2>/dev/null; then
    echo "Error: Input doesn't contain valid JSON" >&2
    exit 1
fi

# Apply filter
jq_filter=$(build_jq_filter)
filtered=$(echo "$input" | jq -c "$jq_filter" 2>/dev/null || echo "$input")

# Output
if [[ "$SHOW_SUMMARY" == "true" ]]; then
    generate_summary "$filtered"
elif [[ "$OUTPUT_JSON" == "true" ]]; then
    echo "$filtered"
else
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        format_entry "$line"
    done <<< "$filtered"
fi
