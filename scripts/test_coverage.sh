#!/usr/bin/env bash
#
# test_coverage.sh - Function coverage tracking for ru test suite
#
# Usage:
#   ./scripts/test_coverage.sh              # Generate text coverage report
#   ./scripts/test_coverage.sh --json       # Generate JSON coverage report
#   ./scripts/test_coverage.sh --threshold 50  # Fail if coverage < 50%
#   ./scripts/test_coverage.sh --html       # Generate HTML coverage report
#   ./scripts/test_coverage.sh --untested   # List only untested functions
#   ./scripts/test_coverage.sh --tested     # List only tested functions
#
# Features:
#   - Extracts function definitions from ru
#   - Parses source_ru_function calls from test_unit_*.sh files
#   - Groups coverage by function category (based on naming patterns)
#   - Supports threshold checks for CI (fail if below X%)
#   - HTML report with links to source lines
#
# Exit codes:
#   0 - Coverage check passed (or no threshold specified)
#   1 - Coverage below threshold
#   2 - Script error
#
# shellcheck disable=SC2034  # Variables used by formatting

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_FILE="$PROJECT_DIR/ru"

#==============================================================================
# Configuration
#==============================================================================

OUTPUT_FORMAT="text"
THRESHOLD=""
FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --html)
            OUTPUT_FORMAT="html"
            shift
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --untested)
            FILTER="untested"
            shift
            ;;
        --tested)
            FILTER="tested"
            shift
            ;;
        --help|-h)
            head -20 "$0" | tail -17 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

# Colors (disabled when not a terminal or JSON output)
if [[ -t 1 && "$OUTPUT_FORMAT" == "text" && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

#==============================================================================
# Function Extraction
#==============================================================================

# Extract all function definitions from ru
# Returns: function_name:line_number pairs
extract_functions() {
    grep -n '^[a-z_][a-z0-9_]*() *{' "$RU_FILE" | \
        sed 's/^\([0-9]*\):\([a-z_][a-z0-9_]*\)().*$/\2:\1/'
}

# Extract source_ru_function calls from test files
# Returns: unique function names being tested
extract_tested_functions() {
    grep -oh 'source_ru_function "[^"]*"' "$SCRIPT_DIR"/test_unit_*.sh 2>/dev/null | \
        sed 's/source_ru_function "\([^"]*\)"/\1/' | \
        sort -u
}

# Categorize a function based on its name
# Note: Order matters - more specific patterns must come before broader globs
# shellcheck disable=SC2221,SC2222  # Intentional: redundant patterns for readability
categorize_function() {
    local func="$1"
    case "$func" in
        cmd_*)              echo "commands" ;;
        local_driver_*)     echo "drivers/local" ;;
        ntm_driver_*)       echo "drivers/ntm" ;;
        driver_*)           echo "drivers/interface" ;;
        governor_*|get_target_parallelism|can_start_new_session|adjust_parallelism)
            echo "rate-limiting" ;;
        *_rate_limit*)      echo "rate-limiting" ;;
        log_*|show_*)       echo "output" ;;
        gum_*|check_gum|print_banner)
            echo "ui/gum" ;;
        dashboard_*|render_*|draw_*|move_cursor|enter_alt_screen|exit_alt_screen|clear_screen)
            echo "ui/dashboard" ;;
        *_question*|question_*|filter_questions*)
            echo "questions" ;;
        *_worktree*|worktree_exists)
            echo "worktree" ;;
        *_policy*|repo_allows_push|repo_requires_approval)
            echo "review/policy" ;;
        *_digest*)          echo "review/digest" ;;
        *review_state*|*_state_*|*checkpoint*|*_review_run|with_state_lock)
            echo "review/state" ;;
        *review_plan*)      echo "review/plan" ;;
        *_quality_gate*|run_test_gate|run_lint_gate|run_secret_scan|detect_test_command|detect_lint_command)
            echo "review/gates" ;;
        *gh_action*)        echo "gh-actions" ;;
        *_repo_*|parse_repo_*|resolve_repo_*|get_all_repos|dedupe_repos|detect_collisions|load_repo_list)
            echo "repo-spec" ;;
        *_sync*|do_clone|do_pull|do_fetch|process_single_repo_worker|run_parallel_sync)
            echo "sync" ;;
        *_graphql*|discover_work_items)
            echo "graphql" ;;
        *priority*|score_and_sort*|item_recently_reviewed|days_since_timestamp)
            echo "scoring" ;;
        *_config*|set_config_value|ensure_config_exists|resolve_config)
            echo "config" ;;
        json_escape|write_result|output_json|write_json_atomic|read_state_json)
            echo "json" ;;
        is_*|_is_*|can_*)   echo "predicates" ;;
        get_*|detect_*)     echo "getters" ;;
        ensure_*|setup_*|init_*|cleanup*)
            echo "lifecycle" ;;
        parse_*|extract_*|normalize_*)
            echo "parsing" ;;
        *)                  echo "misc" ;;
    esac
}

#==============================================================================
# Coverage Calculation
#==============================================================================

# Global arrays and stats for coverage tracking
declare -A CATEGORY_TOTAL=()
declare -A CATEGORY_TESTED=()
COVERAGE_TESTED=0
COVERAGE_TOTAL=0

calculate_coverage() {
    COVERAGE_TESTED=0
    COVERAGE_TOTAL=0

    # Reset category counters
    CATEGORY_TOTAL=()
    CATEGORY_TESTED=()

    for func_entry in "${ALL_FUNCTIONS[@]}"; do
        local func="${func_entry%%:*}"
        local category
        category=$(categorize_function "$func")

        ((COVERAGE_TOTAL++))
        CATEGORY_TOTAL[$category]=$(( ${CATEGORY_TOTAL[$category]:-0} + 1 ))

        # Check if function is tested
        if is_function_tested "$func"; then
            ((COVERAGE_TESTED++))
            CATEGORY_TESTED[$category]=$(( ${CATEGORY_TESTED[$category]:-0} + 1 ))
        fi
    done
}

# Helper: Check if a function is in the tested set
is_function_tested() {
    local func="$1"
    for tested_func in "${TESTED_FUNCTIONS[@]}"; do
        if [[ "$tested_func" == "$func" ]]; then
            return 0
        fi
    done
    return 1
}

#==============================================================================
# Output Formatting
#==============================================================================

print_text_report() {
    local tested="$1"
    local total="$2"
    local pct="$3"

    echo ""
    echo "=============================================="
    echo "${BOLD}ru Function Test Coverage${RESET}"
    echo "=============================================="
    echo ""

    # Overall stats
    printf "  ${BOLD}Overall:${RESET}  %d / %d functions tested (" "$tested" "$total"
    if [[ $pct -ge 80 ]]; then
        printf "${GREEN}%d%%${RESET}" "$pct"
    elif [[ $pct -ge 50 ]]; then
        printf "${YELLOW}%d%%${RESET}" "$pct"
    else
        printf "${RED}%d%%${RESET}" "$pct"
    fi
    echo ")"
    echo ""

    # Category breakdown
    echo "${BOLD}Coverage by Category:${RESET}"
    echo ""

    # Sort categories by name
    local sorted_cats
    sorted_cats=$(printf '%s\n' "${!CATEGORY_TOTAL[@]}" | sort)

    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        local cat_total="${CATEGORY_TOTAL[$cat]:-0}"
        local cat_tested="${CATEGORY_TESTED[$cat]:-0}"
        local cat_pct=0
        if [[ $cat_total -gt 0 ]]; then
            cat_pct=$((cat_tested * 100 / cat_total))
        fi

        # Format with color
        local bar=""
        local bar_len=$((cat_pct / 5))
        for ((i=0; i<20; i++)); do
            if [[ $i -lt $bar_len ]]; then
                bar+="█"
            else
                bar+="░"
            fi
        done

        local color="$RED"
        if [[ $cat_pct -ge 80 ]]; then
            color="$GREEN"
        elif [[ $cat_pct -ge 50 ]]; then
            color="$YELLOW"
        fi

        printf "  %-20s %s %s%3d%%${RESET} (%d/%d)\n" "$cat" "$bar" "$color" "$cat_pct" "$cat_tested" "$cat_total"
    done <<< "$sorted_cats"
    echo ""

    # List functions based on filter
    if [[ "$FILTER" == "untested" ]]; then
        echo "${BOLD}Untested Functions:${RESET}"
        echo ""
        for func_entry in "${ALL_FUNCTIONS[@]}"; do
            local func="${func_entry%%:*}"
            local line="${func_entry#*:}"
            if ! is_function_tested "$func"; then
                local cat
                cat=$(categorize_function "$func")
                printf "  ${DIM}%-20s${RESET} %s ${DIM}(ru:%d)${RESET}\n" "$cat" "$func" "$line"
            fi
        done
    elif [[ "$FILTER" == "tested" ]]; then
        echo "${BOLD}Tested Functions:${RESET}"
        echo ""
        for func_entry in "${ALL_FUNCTIONS[@]}"; do
            local func="${func_entry%%:*}"
            local line="${func_entry#*:}"
            if is_function_tested "$func"; then
                local cat
                cat=$(categorize_function "$func")
                printf "  ${GREEN}%-20s${RESET} %s ${DIM}(ru:%d)${RESET}\n" "$cat" "$func" "$line"
            fi
        done
    fi

    echo ""
    echo "=============================================="
}

print_json_report() {
    local tested="$1"
    local total="$2"
    local pct="$3"

    echo "{"
    echo "  \"summary\": {"
    echo "    \"total\": $total,"
    echo "    \"tested\": $tested,"
    echo "    \"untested\": $((total - tested)),"
    echo "    \"coverage_percent\": $pct"
    echo "  },"

    # Categories
    echo "  \"categories\": {"
    local first_cat=1
    for cat in "${!CATEGORY_TOTAL[@]}"; do
        local cat_total="${CATEGORY_TOTAL[$cat]:-0}"
        local cat_tested="${CATEGORY_TESTED[$cat]:-0}"
        local cat_pct=0
        if [[ $cat_total -gt 0 ]]; then
            cat_pct=$((cat_tested * 100 / cat_total))
        fi

        if [[ $first_cat -eq 0 ]]; then echo ","; fi
        first_cat=0
        printf "    \"%s\": {\"tested\": %d, \"total\": %d, \"percent\": %d}" \
            "$cat" "$cat_tested" "$cat_total" "$cat_pct"
    done
    echo ""
    echo "  },"

    # Functions list
    echo "  \"functions\": ["
    local first_func=1
    for func_entry in "${ALL_FUNCTIONS[@]}"; do
        local func="${func_entry%%:*}"
        local line="${func_entry#*:}"
        local func_tested="false"
        if is_function_tested "$func"; then
            func_tested="true"
        fi

        # Apply filter
        if [[ "$FILTER" == "untested" && "$func_tested" == "true" ]]; then continue; fi
        if [[ "$FILTER" == "tested" && "$func_tested" == "false" ]]; then continue; fi

        local cat
        cat=$(categorize_function "$func")

        if [[ $first_func -eq 0 ]]; then echo ","; fi
        first_func=0
        printf "    {\"name\": \"%s\", \"line\": %d, \"category\": \"%s\", \"tested\": %s}" \
            "$func" "$line" "$cat" "$func_tested"
    done
    echo ""
    echo "  ]"
    echo "}"
}

print_html_report() {
    local tested="$1"
    local total="$2"
    local pct="$3"

    cat <<HTML
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>ru Test Coverage Report</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .summary { display: flex; gap: 20px; margin: 20px 0; }
        .stat { background: #f8f9fa; padding: 20px; border-radius: 8px; text-align: center; flex: 1; }
        .stat-value { font-size: 36px; font-weight: bold; }
        .stat-label { color: #666; margin-top: 5px; }
        .green { color: #28a745; }
        .yellow { color: #ffc107; }
        .red { color: #dc3545; }
        .category { margin: 10px 0; }
        .category-name { width: 200px; display: inline-block; }
        .bar { display: inline-block; width: 200px; height: 20px; background: #eee; border-radius: 4px; overflow: hidden; }
        .bar-fill { height: 100%; }
        .bar-green { background: #28a745; }
        .bar-yellow { background: #ffc107; }
        .bar-red { background: #dc3545; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #f8f9fa; }
        .tested { color: #28a745; }
        .untested { color: #dc3545; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>ru Test Coverage Report</h1>

        <div class="summary">
            <div class="stat">
                <div class="stat-value">$total</div>
                <div class="stat-label">Total Functions</div>
            </div>
            <div class="stat">
                <div class="stat-value green">$tested</div>
                <div class="stat-label">Tested</div>
            </div>
            <div class="stat">
                <div class="stat-value red">$((total - tested))</div>
                <div class="stat-label">Untested</div>
            </div>
            <div class="stat">
HTML

    local color_class="red"
    if [[ $pct -ge 80 ]]; then color_class="green"
    elif [[ $pct -ge 50 ]]; then color_class="yellow"; fi

    cat <<HTML
                <div class="stat-value $color_class">$pct%</div>
                <div class="stat-label">Coverage</div>
            </div>
        </div>

        <h2>Coverage by Category</h2>
HTML

    for category in $(printf '%s\n' "${!CATEGORY_TOTAL[@]}" | sort); do
        local cat_total="${CATEGORY_TOTAL[$category]:-0}"
        local cat_tested="${CATEGORY_TESTED[$category]:-0}"
        local cat_pct=0
        if [[ $cat_total -gt 0 ]]; then
            cat_pct=$((cat_tested * 100 / cat_total))
        fi

        local bar_class="bar-red"
        if [[ $cat_pct -ge 80 ]]; then bar_class="bar-green"
        elif [[ $cat_pct -ge 50 ]]; then bar_class="bar-yellow"; fi

        cat <<HTML
        <div class="category">
            <span class="category-name">$category</span>
            <div class="bar"><div class="bar-fill $bar_class" style="width: ${cat_pct}%"></div></div>
            <span>$cat_pct% ($cat_tested/$cat_total)</span>
        </div>
HTML
    done

    cat <<HTML

        <h2>Functions</h2>
        <table>
            <thead>
                <tr>
                    <th>Function</th>
                    <th>Category</th>
                    <th>Line</th>
                    <th>Status</th>
                </tr>
            </thead>
            <tbody>
HTML

    for func_entry in "${ALL_FUNCTIONS[@]}"; do
        local func="${func_entry%%:*}"
        local line="${func_entry#*:}"
        local func_tested="false"
        if is_function_tested "$func"; then
            func_tested="true"
        fi

        # Apply filter
        if [[ "$FILTER" == "untested" && "$func_tested" == "true" ]]; then continue; fi
        if [[ "$FILTER" == "tested" && "$func_tested" == "false" ]]; then continue; fi

        local func_cat
        func_cat=$(categorize_function "$func")
        local status_class="untested"
        local status_text="Not Tested"
        if [[ "$func_tested" == "true" ]]; then
            status_class="tested"
            status_text="Tested"
        fi

        cat <<HTML
                <tr>
                    <td><code>$func</code></td>
                    <td>$func_cat</td>
                    <td><a href="ru#L$line">$line</a></td>
                    <td class="$status_class">$status_text</td>
                </tr>
HTML
    done

    cat <<HTML
            </tbody>
        </table>

        <p style="margin-top: 30px; color: #666; font-size: 12px;">
            Generated: $(date -Iseconds)
        </p>
    </div>
</body>
</html>
HTML
}

#==============================================================================
# Main
#==============================================================================

# Global arrays for function data
declare -a ALL_FUNCTIONS=()
declare -a TESTED_FUNCTIONS=()

main() {
    # Extract functions into global arrays
    mapfile -t ALL_FUNCTIONS < <(extract_functions)
    mapfile -t TESTED_FUNCTIONS < <(extract_tested_functions)

    if [[ ${#ALL_FUNCTIONS[@]} -eq 0 ]]; then
        echo "Error: No functions found in $RU_FILE" >&2
        exit 2
    fi

    # Calculate coverage (populates global CATEGORY_* and COVERAGE_* vars)
    calculate_coverage

    local tested="$COVERAGE_TESTED"
    local total="$COVERAGE_TOTAL"
    local pct=0
    if [[ $total -gt 0 ]]; then
        pct=$((tested * 100 / total))
    fi

    # Output report
    case "$OUTPUT_FORMAT" in
        text)
            print_text_report "$tested" "$total" "$pct"
            ;;
        json)
            print_json_report "$tested" "$total" "$pct"
            ;;
        html)
            print_html_report "$tested" "$total" "$pct"
            ;;
    esac

    # Check threshold
    if [[ -n "$THRESHOLD" ]]; then
        if [[ $pct -lt $THRESHOLD ]]; then
            if [[ "$OUTPUT_FORMAT" == "text" ]]; then
                echo "${RED}Coverage $pct% is below threshold of $THRESHOLD%${RESET}" >&2
            fi
            exit 1
        fi
    fi

    exit 0
}

main "$@"
