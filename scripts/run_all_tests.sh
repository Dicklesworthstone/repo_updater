#!/usr/bin/env bash
#
# run_all_tests.sh - Master test runner for ru CLI test suite
#
# Usage:
#   ./scripts/run_all_tests.sh              # Run all tests with human-readable output
#   ./scripts/run_all_tests.sh --tap        # Run with TAP output for CI
#   ./scripts/run_all_tests.sh --parallel   # Run tests in parallel (faster)
#   ./scripts/run_all_tests.sh --list       # List test files without running
#   ./scripts/run_all_tests.sh test_e2e_*   # Run only matching test files
#
# Features:
#   - Auto-discovers test_*.sh scripts in scripts/
#   - Aggregated summary report with pass/fail counts
#   - TAP output mode for CI integration (prove, tap-junit)
#   - Parallel execution mode for faster runs
#   - Individual test timing
#   - Exit code reflects overall test status
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more test files had failures
#   2 - No test files found
#
# shellcheck disable=SC2034  # Variables used by formatting

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#==============================================================================
# Configuration
#==============================================================================

# Parse options
TAP_MODE="false"
PARALLEL_MODE="false"
LIST_ONLY="false"
FILTER_PATTERN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tap)
            TAP_MODE="true"
            export TF_TAP_MODE="true"
            shift
            ;;
        --parallel|-j)
            PARALLEL_MODE="true"
            shift
            ;;
        --list)
            LIST_ONLY="true"
            shift
            ;;
        --help|-h)
            head -24 "$0" | tail -21 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            FILTER_PATTERN="$1"
            shift
            ;;
    esac
done

# Colors (disabled in TAP mode or when not a terminal)
if [[ -t 1 && "$TAP_MODE" != "true" && -z "${NO_COLOR:-}" ]]; then
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
# Test Discovery
#==============================================================================

discover_tests() {
    local tests=()

    # Prefer git-tracked tests for determinism (avoids executing untracked local artifacts).
    local project_dir
    project_dir="$(dirname "$SCRIPT_DIR")"

    if git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            local full_path="$project_dir/$file"
            local basename
            basename=$(basename "$file")

            # Skip the framework file
            if [[ "$basename" == "test_framework.sh" ]]; then
                continue
            fi

            # Apply filter if provided
            if [[ -n "$FILTER_PATTERN" ]] && [[ "$basename" != *"$FILTER_PATTERN"* ]]; then
                continue
            fi

            # Skip non-executable tracked tests (warn so it doesn't silently disappear)
            if [[ ! -x "$full_path" ]]; then
                echo "WARN: Skipping non-executable test: $file (run: chmod +x $file)" >&2
                continue
            fi

            tests+=("$full_path")
        done < <(git -C "$project_dir" ls-files -z -- 'scripts/test_*.sh')
    else
        # Fallback for non-git distributions (e.g., tarball installs)
        while IFS= read -r -d '' file; do
            local basename
            basename=$(basename "$file")

            if [[ "$basename" == "test_framework.sh" ]]; then
                continue
            fi
            if [[ -n "$FILTER_PATTERN" ]] && [[ "$basename" != *"$FILTER_PATTERN"* ]]; then
                continue
            fi
            if [[ ! -x "$file" ]]; then
                echo "WARN: Skipping non-executable test: $file" >&2
                continue
            fi
            tests+=("$file")
        done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.sh' -type f -print0 | sort -z)
    fi

    printf '%s\n' "${tests[@]}"
}

#==============================================================================
# Test Execution
#==============================================================================

run_single_test() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .sh)

    local start_time end_time duration
    start_time=$(date +%s)

    local output exit_code
    if output=$("$test_file" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Return result as: exit_code|duration|test_name|output
    printf '%d|%d|%s|%s' "$exit_code" "$duration" "$test_name" "$output"
}

#==============================================================================
# Output Formatting
#==============================================================================

print_header() {
    if [[ "$TAP_MODE" == "true" ]]; then
        echo "TAP version 13"
    else
        echo ""
        echo "=============================================="
        echo "${BOLD}ru Test Suite${RESET}"
        echo "=============================================="
        echo ""
    fi
}

print_test_result() {
    local test_num="$1"
    local exit_code="$2"
    local duration="$3"
    local test_name="$4"
    local output="$5"

    if [[ "$TAP_MODE" == "true" ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            echo "ok $test_num - $test_name (${duration}s)"
        else
            echo "not ok $test_num - $test_name (${duration}s)"
            # Print output as TAP diagnostics (indent with #)
            printf '%s\n' "$output" | head -20 | while IFS= read -r line; do
                echo "# $line"
            done
        fi
    else
        if [[ "$exit_code" -eq 0 ]]; then
            printf "  ${GREEN}PASS${RESET} %s (%ds)\n" "$test_name" "$duration"
        else
            printf "  ${RED}FAIL${RESET} %s (%ds, exit code %d)\n" "$test_name" "$duration" "$exit_code"
            # Show first few lines of output for failures
            printf '%s\n' "$output" | head -10 | while IFS= read -r line; do
                echo "    $line"
            done
            echo ""
        fi
    fi
}

print_summary() {
    local total="$1"
    local passed="$2"
    local failed="$3"
    local total_time="$4"

    if [[ "$TAP_MODE" == "true" ]]; then
        echo "1..$total"
        echo "# Tests: $passed passed, $failed failed"
        echo "# Total time: ${total_time}s"
    else
        echo ""
        echo "=============================================="
        echo "${BOLD}Summary${RESET}"
        echo "=============================================="
        printf "  Total:   %d test files\n" "$total"
        printf "  ${GREEN}Passed:${RESET}  %d\n" "$passed"
        if [[ "$failed" -gt 0 ]]; then
            printf "  ${RED}Failed:${RESET}  %d\n" "$failed"
        else
            printf "  Failed:  %d\n" "$failed"
        fi
        printf "  Time:    %ds\n" "$total_time"
        echo "=============================================="
        echo ""

        if [[ "$failed" -eq 0 ]]; then
            echo "${GREEN}${BOLD}All tests passed!${RESET}"
        else
            echo "${RED}${BOLD}$failed test file(s) had failures${RESET}"
        fi
        echo ""
    fi
}

#==============================================================================
# Main
#==============================================================================

main() {
    # Discover tests
    local tests
    mapfile -t tests < <(discover_tests)

    if [[ ${#tests[@]} -eq 0 ]]; then
        if [[ "$TAP_MODE" == "true" ]]; then
            echo "1..0 # SKIP No test files found"
        else
            echo "${RED}Error: No test files found${RESET}" >&2
            if [[ -n "$FILTER_PATTERN" ]]; then
                echo "Filter pattern: $FILTER_PATTERN" >&2
            fi
        fi
        exit 2
    fi

    # List only mode
    if [[ "$LIST_ONLY" == "true" ]]; then
        printf '%s\n' "${tests[@]}"
        exit 0
    fi

    print_header

    if [[ "$TAP_MODE" != "true" ]]; then
        echo "Running ${#tests[@]} test file(s)..."
        echo ""
    fi

    local total_passed=0
    local total_failed=0
    local total_start_time
    total_start_time=$(date +%s)
    local test_num=0

    if [[ "$PARALLEL_MODE" == "true" ]]; then
        # Parallel execution using background jobs
        local pids=()
        local tmpdir
        tmpdir=$(mktemp -d)

        for test_file in "${tests[@]}"; do
            ((test_num++))
            local result_file="$tmpdir/result_$test_num"
            (
                run_single_test "$test_file" > "$result_file"
            ) &
            pids+=($!)
        done

        # Wait for all jobs and collect results
        test_num=0
        for pid in "${pids[@]}"; do
            ((test_num++))
            wait "$pid" 2>/dev/null || true
            local result_file="$tmpdir/result_$test_num"
            if [[ -f "$result_file" ]]; then
                local result
                result=$(cat "$result_file")
                IFS='|' read -r exit_code duration test_name output <<< "$result"
                print_test_result "$test_num" "$exit_code" "$duration" "$test_name" "$output"
                if [[ "$exit_code" -eq 0 ]]; then
                    ((total_passed++))
                else
                    ((total_failed++))
                fi
            fi
        done

        rm -rf "$tmpdir"
    else
        # Sequential execution
        for test_file in "${tests[@]}"; do
            ((test_num++))
            local result
            result=$(run_single_test "$test_file")
            IFS='|' read -r exit_code duration test_name output <<< "$result"
            print_test_result "$test_num" "$exit_code" "$duration" "$test_name" "$output"
            if [[ "$exit_code" -eq 0 ]]; then
                ((total_passed++))
            else
                ((total_failed++))
            fi
        done
    fi

    local total_end_time
    total_end_time=$(date +%s)
    local total_time=$((total_end_time - total_start_time))

    print_summary "${#tests[@]}" "$total_passed" "$total_failed" "$total_time"

    # Exit with failure if any tests failed
    if [[ "$total_failed" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
