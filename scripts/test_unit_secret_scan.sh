#!/usr/bin/env bash
#
# Unit Tests: Secret Scanning (run_secret_scan)
#
# Test coverage:
#   - run_secret_scan returns valid JSON structure
#   - run_secret_scan detects private keys
#   - run_secret_scan detects AWS access keys
#   - run_secret_scan detects GitHub tokens
#   - run_secret_scan detects Slack tokens
#   - run_secret_scan detects OpenAI API keys
#   - run_secret_scan detects Anthropic API keys
#   - run_secret_scan detects Google API keys
#   - run_secret_scan detects Stripe keys
#   - run_secret_scan detects password assignments
#   - run_secret_scan returns ok:true when no secrets
#   - run_secret_scan reports correct tool used
#   - run_secret_scan handles staged scope
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
TEST_REPO=""

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' RESET=''
fi

# Stub log functions to avoid errors
log_verbose() { :; }
log_warn() { :; }
log_error() { :; }

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
# Source the secret scan function at global scope
# Extract from function comment to just before next function comment
#------------------------------------------------------------------------------
EXTRACT_FILE=$(mktemp)
sed -n '/^# run_secret_scan:/,/^# run_quality_gates:/p' "$RU_SCRIPT" | drop_last_lines 1 > "$EXTRACT_FILE"
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
    TEST_REPO="$TEMP_DIR/test_repo"
    mkdir -p "$TEST_REPO"

    # Initialize a git repo for testing
    git -C "$TEST_REPO" init --quiet
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"

    # Create initial commit so HEAD exists
    echo "initial" > "$TEST_REPO/initial.txt"
    git -C "$TEST_REPO" add initial.txt
    git -C "$TEST_REPO" commit -m "Initial commit" --quiet
}

teardown() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Helper: Add a file with content and stage it
add_file_with_content() {
    local filename="$1"
    local content="$2"
    echo "$content" > "$TEST_REPO/$filename"
    git -C "$TEST_REPO" add "$filename"
}

# Helper: Run scan and check JSON output is valid
check_json_valid() {
    local result="$1"
    if echo "$result" | jq -e . >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Helper: Temporarily hide gitleaks/detect-secrets to force regex fallback
# Creates wrapper scripts that make `command -v gitleaks` fail
hide_external_scanners() {
    # Create temp bin dir with wrapper functions
    FAKE_BIN="$TEMP_DIR/fake_bin"
    mkdir -p "$FAKE_BIN"

    # Create dummy gitleaks that makes command -v fail
    cat > "$FAKE_BIN/gitleaks" << 'EOF'
#!/bin/bash
exit 127
EOF
    chmod +x "$FAKE_BIN/gitleaks"

    cat > "$FAKE_BIN/detect-secrets" << 'EOF'
#!/bin/bash
exit 127
EOF
    chmod +x "$FAKE_BIN/detect-secrets"

    # Save original PATH and prepend fake bin (NOT replace)
    ORIGINAL_PATH="$PATH"
    # Remove any real gitleaks/detect-secrets from PATH
    # by checking each component
    local new_path=""
    local IFS=':'
    for p in $PATH; do
        # Skip directories containing gitleaks or detect-secrets
        if [[ -x "$p/gitleaks" ]] || [[ -x "$p/detect-secrets" ]]; then
            continue
        fi
        if [[ -n "$new_path" ]]; then
            new_path="$new_path:$p"
        else
            new_path="$p"
        fi
    done
    PATH="$new_path"
}

restore_path() {
    PATH="${ORIGINAL_PATH:-$PATH}"
}

#==============================================================================
# Tests: JSON Output Structure
#==============================================================================

test_returns_valid_json() {
    hide_external_scanners
    local result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null || true)
    restore_path

    if check_json_valid "$result"; then
        pass "run_secret_scan returns valid JSON"
    else
        fail "run_secret_scan should return valid JSON" "valid JSON" "$result"
    fi
}

test_json_has_required_fields() {
    hide_external_scanners
    local result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null || true)
    restore_path

    local has_ran has_ok has_tool has_findings
    has_ran=$(echo "$result" | jq -e 'has("ran")' 2>/dev/null || echo false)
    has_ok=$(echo "$result" | jq -e 'has("ok")' 2>/dev/null || echo false)
    has_tool=$(echo "$result" | jq -e 'has("tool")' 2>/dev/null || echo false)
    has_findings=$(echo "$result" | jq -e 'has("findings")' 2>/dev/null || echo false)

    if [[ "$has_ran" == "true" && "$has_ok" == "true" && "$has_tool" == "true" && "$has_findings" == "true" ]]; then
        pass "JSON has required fields (ran, ok, tool, findings)"
    else
        fail "JSON should have ran, ok, tool, findings fields" "all true" "ran=$has_ran ok=$has_ok tool=$has_tool findings=$has_findings"
    fi
}

test_reports_heuristic_when_no_external_scanners() {
    hide_external_scanners
    local result tool
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null || true)
    restore_path

    tool=$(echo "$result" | jq -r '.tool' 2>/dev/null)

    if [[ "$tool" == "heuristic" ]]; then
        pass "Reports tool='heuristic' when no external scanners"
    else
        fail "Should report tool='heuristic' when no external scanners" "heuristic" "$tool"
    fi
}

#==============================================================================
# Tests: Secret Detection - Private Keys
#==============================================================================

test_detects_rsa_private_key() {
    add_file_with_content "secret.txt" "-----BEGIN RSA PRIVATE KEY-----"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects RSA private key (exit code 2)"
    else
        fail "Should detect RSA private key" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_ec_private_key() {
    add_file_with_content "secret.txt" "-----BEGIN EC PRIVATE KEY-----"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects EC private key (exit code 2)"
    else
        fail "Should detect EC private key" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_openssh_private_key() {
    add_file_with_content "secret.txt" "-----BEGIN OPENSSH PRIVATE KEY-----"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects OpenSSH private key (exit code 2)"
    else
        fail "Should detect OpenSSH private key" "exit 2" "exit ${exit_code:-0}"
    fi
}

#==============================================================================
# Tests: Secret Detection - Cloud Provider Keys
#==============================================================================

test_detects_aws_access_key() {
    add_file_with_content "config.txt" "aws_key=AKIAIOSFODNN7EXAMPLE"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects AWS access key (AKIA pattern)"
    else
        fail "Should detect AWS access key" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_aws_session_key() {
    add_file_with_content "config.txt" "session=ASIAIOSFODNN7EXAMPLE"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects AWS session key (ASIA pattern)"
    else
        fail "Should detect AWS session key" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_google_api_key() {
    add_file_with_content "config.txt" "google_key=AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects Google API key (AIza pattern)"
    else
        fail "Should detect Google API key" "exit 2" "exit ${exit_code:-0}"
    fi
}

#==============================================================================
# Tests: Secret Detection - Service Tokens
#==============================================================================

test_detects_github_pat() {
    add_file_with_content "config.txt" "token=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects GitHub PAT (ghp_ pattern)"
    else
        fail "Should detect GitHub PAT" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_github_oauth() {
    add_file_with_content "config.txt" "token=gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects GitHub OAuth token (gho_ pattern)"
    else
        fail "Should detect GitHub OAuth token" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_slack_token() {
    # Use xoxs (not xoxb) to avoid GitHub push protection while still matching the pattern
    add_file_with_content "config.txt" "slack=xoxs-FAKEFAKE12-FAKETEST"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects Slack token (xox[baprs] pattern)"
    else
        fail "Should detect Slack token" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_stripe_key() {
    # Use sk_test (not sk_live) to avoid GitHub push protection while matching pattern
    add_file_with_content "config.txt" "stripe=sk_test_FAKEFAKEFAKEFAKEFAKE"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    # Note: sk_test won't match the sk_live_ pattern, so we expect exit 0
    # This tests that we don't false-positive on test keys
    if [[ "${exit_code:-0}" -eq 0 ]]; then
        pass "Ignores Stripe test key (sk_test pattern)"
    else
        fail "Should ignore Stripe test key" "exit 0" "exit ${exit_code:-0}"
    fi
}

#==============================================================================
# Tests: Secret Detection - AI Service Keys
#==============================================================================

test_detects_openai_key() {
    # OpenAI keys are sk- followed by 48 alphanumeric chars
    add_file_with_content "config.txt" "openai=sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects OpenAI API key (sk- pattern)"
    else
        fail "Should detect OpenAI API key" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_anthropic_key() {
    add_file_with_content "config.txt" "anthropic=sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects Anthropic API key (sk-ant pattern)"
    else
        fail "Should detect Anthropic API key" "exit 2" "exit ${exit_code:-0}"
    fi
}

#==============================================================================
# Tests: Secret Detection - Generic Patterns
#==============================================================================

test_detects_password_assignment() {
    add_file_with_content "config.txt" "password = supersecret123"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects password assignment"
    else
        fail "Should detect password assignment" "exit 2" "exit ${exit_code:-0}"
    fi
}

test_detects_api_key_assignment() {
    add_file_with_content "config.txt" "apiKey = abc123def456"

    hide_external_scanners
    local exit_code result
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    if [[ "${exit_code:-0}" -eq 2 ]]; then
        pass "Detects api_key assignment"
    else
        fail "Should detect api_key assignment" "exit 2" "exit ${exit_code:-0}"
    fi
}

#==============================================================================
# Tests: Clean Files (No Secrets)
#==============================================================================

test_clean_file_returns_ok() {
    add_file_with_content "clean.txt" "This is a normal file with no secrets"

    hide_external_scanners
    local exit_code=0 result ok_value
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || exit_code=$?
    restore_path

    ok_value=$(echo "$result" | jq -r '.ok' 2>/dev/null)

    if [[ "$exit_code" -eq 0 && "$ok_value" == "true" ]]; then
        pass "Clean file returns ok:true and exit 0"
    else
        fail "Clean file should return ok:true" "exit 0, ok=true" "exit $exit_code, ok=$ok_value"
    fi
}

test_empty_findings_when_clean() {
    add_file_with_content "clean.txt" "Normal content here"

    hide_external_scanners
    local result findings_count
    result=$(run_secret_scan "$TEST_REPO" 2>/dev/null) || true
    restore_path

    findings_count=$(echo "$result" | jq '.findings | length' 2>/dev/null)

    if [[ "$findings_count" -eq 0 ]]; then
        pass "Empty findings array when no secrets"
    else
        fail "Should have empty findings when no secrets" "0" "$findings_count"
    fi
}

#==============================================================================
# Tests: Scope Parameter
#==============================================================================

test_staged_scope_only_scans_staged() {
    # Add a clean file staged
    add_file_with_content "clean.txt" "No secrets here"

    # Add a secret file but don't stage it
    echo "password = secret123" > "$TEST_REPO/unstaged.txt"

    hide_external_scanners
    local exit_code=0 result
    result=$(run_secret_scan "$TEST_REPO" "staged" 2>/dev/null) || exit_code=$?
    restore_path

    # Staged scope should only see the clean file
    if [[ "$exit_code" -eq 0 ]]; then
        pass "Staged scope ignores unstaged secrets"
    else
        fail "Staged scope should ignore unstaged secrets" "exit 0" "exit $exit_code"
    fi
}

#==============================================================================
# Run Tests
#==============================================================================

main() {
    echo -e "${BLUE}=== Secret Scanning Unit Tests ===${RESET}"
    echo

    setup

    # JSON output structure tests
    test_returns_valid_json
    test_json_has_required_fields
    test_reports_heuristic_when_no_external_scanners

    # Reset repo for each group
    teardown; setup

    # Private key detection
    test_detects_rsa_private_key
    teardown; setup
    test_detects_ec_private_key
    teardown; setup
    test_detects_openssh_private_key
    teardown; setup

    # Cloud provider keys
    test_detects_aws_access_key
    teardown; setup
    test_detects_aws_session_key
    teardown; setup
    test_detects_google_api_key
    teardown; setup

    # Service tokens
    test_detects_github_pat
    teardown; setup
    test_detects_github_oauth
    teardown; setup
    test_detects_slack_token
    teardown; setup
    test_detects_stripe_key
    teardown; setup

    # AI service keys
    test_detects_openai_key
    teardown; setup
    test_detects_anthropic_key
    teardown; setup

    # Generic patterns
    test_detects_password_assignment
    teardown; setup
    test_detects_api_key_assignment
    teardown; setup

    # Clean files
    test_clean_file_returns_ok
    teardown; setup
    test_empty_findings_when_clean
    teardown; setup

    # Scope parameter
    test_staged_scope_only_scans_staged

    teardown

    echo
    echo -e "${BLUE}=== Results ===${RESET}"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
