#!/usr/bin/env bash
#
# Unit Tests: File Denylist Enforcement
# Tests for is_file_denied, filter_files_denylist, get_denylist_patterns
#
# Test coverage:
#   - is_file_denied blocks .env files
#   - is_file_denied blocks .env.* patterns
#   - is_file_denied blocks *.pem files
#   - is_file_denied blocks *.key files
#   - is_file_denied blocks id_rsa files
#   - is_file_denied blocks credentials.json
#   - is_file_denied blocks node_modules directories
#   - is_file_denied blocks __pycache__ directories
#   - is_file_denied blocks *.log files
#   - is_file_denied blocks IDE directories (.idea, .vscode)
#   - is_file_denied allows normal source files
#   - is_file_denied handles paths with leading ./
#   - is_file_denied handles nested paths
#   - is_file_denied respects AGENT_SWEEP_DENYLIST_EXTRA
#   - filter_files_denylist filters stdin correctly
#   - get_denylist_patterns returns all patterns
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
TEMP_DIR=""

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' RESET=''
fi

# Stub log_warn to avoid errors
log_warn() { :; }

# Initialize required global arrays before sourcing extracted code
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()

# Portable alternative to head -n -N (BSD/macOS doesn't support negative counts)
drop_last_lines() {
    local n="${1:-1}"
    local input total keep
    input=$(cat)
    total=$(printf '%s\n' "$input" | wc -l | tr -d ' ')
    keep=$((total - n))
    [[ "$keep" -lt 1 ]] && return 0
    printf '%s\n' "$input" | head -n "$keep"
}

#------------------------------------------------------------------------------
# Source the denylist functions at global scope (declare -a creates local vars in functions)
# Extract from the array declaration to just before detect_review_driver
#------------------------------------------------------------------------------
EXTRACT_FILE=$(mktemp)
sed -n '/^declare -a AGENT_SWEEP_DENYLIST_PATTERNS/,/^# Detect which review driver/p' "$RU_SCRIPT" | drop_last_lines 2 > "$EXTRACT_FILE"
# shellcheck disable=SC1090
source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"
#------------------------------------------------------------------------------

pass() {
    ((TESTS_PASSED++))
    echo -e "${GREEN}✓${RESET} $1"
}

fail() {
    ((TESTS_FAILED++))
    echo -e "${RED}✗${RESET} $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got:      $3"
    fi
}

setup() {
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR" || exit 1
}

teardown() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

#==============================================================================
# Tests: is_file_denied - Secrets and credentials
#==============================================================================

test_denies_env_file() {
    if is_file_denied ".env"; then
        pass "is_file_denied blocks .env"
    else
        fail "is_file_denied should block .env"
    fi
}

test_denies_env_variants() {
    local file
    for file in ".env.local" ".env.production" ".env.development"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_pem_files() {
    local file
    for file in "server.pem" "cert.pem" "private.pem"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_key_files() {
    local file
    for file in "server.key" "private.key" "api.key"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_id_rsa() {
    local file
    for file in "id_rsa" "id_rsa.pub" "id_rsa.bak"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_credentials_json() {
    if is_file_denied "credentials.json"; then
        pass "is_file_denied blocks credentials.json"
    else
        fail "is_file_denied should block credentials.json"
    fi
}

test_denies_secrets_json() {
    if is_file_denied "secrets.json"; then
        pass "is_file_denied blocks secrets.json"
    else
        fail "is_file_denied should block secrets.json"
    fi
}

#==============================================================================
# Tests: is_file_denied - Build artifacts
#==============================================================================

test_denies_node_modules() {
    if is_file_denied "node_modules"; then
        pass "is_file_denied blocks node_modules"
    else
        fail "is_file_denied should block node_modules"
    fi
}

test_denies_node_modules_files() {
    if is_file_denied "node_modules/lodash/index.js"; then
        pass "is_file_denied blocks node_modules/lodash/index.js"
    else
        fail "is_file_denied should block files inside node_modules"
    fi
}

test_denies_pycache() {
    if is_file_denied "__pycache__"; then
        pass "is_file_denied blocks __pycache__"
    else
        fail "is_file_denied should block __pycache__"
    fi
}

test_denies_pyc_files() {
    if is_file_denied "module.pyc"; then
        pass "is_file_denied blocks module.pyc"
    else
        fail "is_file_denied should block .pyc files"
    fi
}

test_denies_dist_directory() {
    if is_file_denied "dist/bundle.js"; then
        pass "is_file_denied blocks dist/bundle.js"
    else
        fail "is_file_denied should block files inside dist/"
    fi
}

test_denies_build_directory() {
    if is_file_denied "build/output.js"; then
        pass "is_file_denied blocks build/output.js"
    else
        fail "is_file_denied should block files inside build/"
    fi
}

#==============================================================================
# Tests: is_file_denied - Logs and temp files
#==============================================================================

test_denies_log_files() {
    local file
    for file in "debug.log" "error.log" "npm-debug.log"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_temp_files() {
    local file
    for file in "data.tmp" "cache.temp"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_swap_files() {
    local file
    for file in "file.swp" "file.swo" "backup~"; do
        if is_file_denied "$file"; then
            pass "is_file_denied blocks $file"
        else
            fail "is_file_denied should block $file"
        fi
    done
}

test_denies_ds_store() {
    if is_file_denied ".DS_Store"; then
        pass "is_file_denied blocks .DS_Store"
    else
        fail "is_file_denied should block .DS_Store"
    fi
}

#==============================================================================
# Tests: is_file_denied - IDE files
#==============================================================================

test_denies_idea_directory() {
    if is_file_denied ".idea/workspace.xml"; then
        pass "is_file_denied blocks .idea/workspace.xml"
    else
        fail "is_file_denied should block files inside .idea/"
    fi
}

test_denies_vscode_directory() {
    if is_file_denied ".vscode/settings.json"; then
        pass "is_file_denied blocks .vscode/settings.json"
    else
        fail "is_file_denied should block files inside .vscode/"
    fi
}

#==============================================================================
# Tests: is_file_denied - Allowed files
#==============================================================================

test_allows_normal_source() {
    local file
    for file in "main.py" "app.js" "lib.rs" "server.go" "README.md"; do
        if ! is_file_denied "$file"; then
            pass "is_file_denied allows $file"
        else
            fail "is_file_denied should allow $file"
        fi
    done
}

test_allows_src_directory() {
    if ! is_file_denied "src/main.py"; then
        pass "is_file_denied allows src/main.py"
    else
        fail "is_file_denied should allow src/main.py"
    fi
}

test_allows_config_files() {
    local file
    for file in "config.json" "settings.yaml" "package.json" "Cargo.toml"; do
        if ! is_file_denied "$file"; then
            pass "is_file_denied allows $file"
        else
            fail "is_file_denied should allow $file"
        fi
    done
}

#==============================================================================
# Tests: is_file_denied - Path normalization
#==============================================================================

test_handles_leading_dot_slash() {
    if is_file_denied "./.env"; then
        pass "is_file_denied blocks ./.env (strips ./)"
    else
        fail "is_file_denied should strip leading ./ and block .env"
    fi
}

test_handles_nested_paths() {
    if is_file_denied "app/config/.env"; then
        pass "is_file_denied blocks app/config/.env"
    else
        fail "is_file_denied should block .env in nested paths"
    fi
}

#==============================================================================
# Tests: AGENT_SWEEP_DENYLIST_EXTRA
#==============================================================================

test_respects_extra_patterns() {
    export AGENT_SWEEP_DENYLIST_EXTRA="*.custom custom_secret.txt"

    if is_file_denied "file.custom"; then
        pass "is_file_denied respects AGENT_SWEEP_DENYLIST_EXTRA (*.custom)"
    else
        fail "is_file_denied should respect AGENT_SWEEP_DENYLIST_EXTRA"
    fi

    if is_file_denied "custom_secret.txt"; then
        pass "is_file_denied respects AGENT_SWEEP_DENYLIST_EXTRA (custom_secret.txt)"
    else
        fail "is_file_denied should respect AGENT_SWEEP_DENYLIST_EXTRA"
    fi

    unset AGENT_SWEEP_DENYLIST_EXTRA
}

#==============================================================================
# Tests: filter_files_denylist
#==============================================================================

test_filter_files_denylist() {
    local input output

    input=$(printf '%s\n' "main.py" ".env" "app.js" "node_modules/x.js" "README.md")
    output=$(echo "$input" | filter_files_denylist 2>/dev/null)

    if [[ "$output" == $'main.py\napp.js\nREADME.md' ]]; then
        pass "filter_files_denylist filters correctly"
    else
        fail "filter_files_denylist should filter .env and node_modules" "main.py app.js README.md" "$output"
    fi
}

test_filter_returns_code_on_deny() {
    local input
    input=$(printf '%s\n' ".env" "secrets.json")

    if ! echo "$input" | filter_files_denylist >/dev/null 2>&1; then
        pass "filter_files_denylist returns non-zero when files denied"
    else
        fail "filter_files_denylist should return non-zero when files denied"
    fi
}

#==============================================================================
# Tests: get_denylist_patterns
#==============================================================================

test_get_denylist_patterns_returns_all() {
    local patterns count
    patterns=$(get_denylist_patterns)
    count=$(echo "$patterns" | wc -l)

    if [[ $count -ge 30 ]]; then
        pass "get_denylist_patterns returns $count patterns"
    else
        fail "get_denylist_patterns should return many patterns" ">= 30" "$count"
    fi
}

test_get_denylist_patterns_includes_env() {
    local patterns
    patterns=$(get_denylist_patterns)

    if echo "$patterns" | grep -q "^\.env$"; then
        pass "get_denylist_patterns includes .env"
    else
        fail "get_denylist_patterns should include .env"
    fi
}

#==============================================================================
# Run Tests
#==============================================================================

main() {
    echo -e "${BLUE}=== File Denylist Unit Tests ===${RESET}"
    echo

    setup

    # Secrets and credentials
    test_denies_env_file
    test_denies_env_variants
    test_denies_pem_files
    test_denies_key_files
    test_denies_id_rsa
    test_denies_credentials_json
    test_denies_secrets_json

    # Build artifacts
    test_denies_node_modules
    test_denies_node_modules_files
    test_denies_pycache
    test_denies_pyc_files
    test_denies_dist_directory
    test_denies_build_directory

    # Logs and temp files
    test_denies_log_files
    test_denies_temp_files
    test_denies_swap_files
    test_denies_ds_store

    # IDE files
    test_denies_idea_directory
    test_denies_vscode_directory

    # Allowed files
    test_allows_normal_source
    test_allows_src_directory
    test_allows_config_files

    # Path normalization
    test_handles_leading_dot_slash
    test_handles_nested_paths

    # Extra patterns
    test_respects_extra_patterns

    # Filter function
    test_filter_files_denylist
    test_filter_returns_code_on_deny

    # get_denylist_patterns
    test_get_denylist_patterns_returns_all
    test_get_denylist_patterns_includes_env

    teardown

    echo
    echo -e "${BLUE}=== Results ===${RESET}"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
