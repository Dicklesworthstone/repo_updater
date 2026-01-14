#!/usr/bin/env bash
#
# Tests: NTM Driver Functions Unit Tests (bd-m3a5)
#
# Tests for:
# - json_get_field(), json_is_success(), json_escape()
# - ntm_check_available()
# - has_uncommitted_changes()
# - is_file_denied()
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2123  # PATH modification is intentional for testing
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Source specific functions from ru
source_ru_function "json_get_field"
source_ru_function "json_is_success"
source_ru_function "json_escape"
source_ru_function "ntm_check_available"
source_ru_function "is_git_repo"
source_ru_function "repo_is_dirty"
source_ru_function "has_uncommitted_changes"
source_ru_function "is_file_denied"

# Define the denylist patterns (needed for is_file_denied tests)
# This matches the patterns in ru's AGENT_SWEEP_DENYLIST_PATTERNS array
declare -a AGENT_SWEEP_DENYLIST_PATTERNS=(
    # Secrets and credentials
    ".env"
    ".env.*"
    "*.pem"
    "*.key"
    "id_rsa"
    "id_rsa.*"
    "*.p12"
    "*.pfx"
    "credentials.json"
    "secrets.json"
    "*.secret"
    "*.secrets"
    ".netrc"
    ".npmrc"
    ".pypirc"
    # Build artifacts
    "node_modules"
    "node_modules/*"
    "__pycache__"
    "__pycache__/*"
    "*.pyc"
    "*.pyo"
)

# Initialize AGENT_SWEEP_DENYLIST_EXTRA_LOCAL (used by is_file_denied, normally loaded from config)
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()

#==============================================================================
# JSON Parsing Tests: json_get_field()
#==============================================================================

test_json_get_field_string() {
    log_test_start "json_get_field extracts string values"

    local json='{"name":"test","value":"hello world"}'
    local result

    result=$(json_get_field "$json" "name")
    assert_equals "test" "$result" "Extract simple string field"

    result=$(json_get_field "$json" "value")
    assert_equals "hello world" "$result" "Extract string with space"

    log_test_pass "json_get_field extracts string values"
}

test_json_get_field_number() {
    log_test_start "json_get_field extracts numeric values"

    local json='{"count":42,"rate":3.14}'
    local result

    result=$(json_get_field "$json" "count")
    assert_equals "42" "$result" "Extract integer"

    result=$(json_get_field "$json" "rate")
    assert_equals "3.14" "$result" "Extract float"

    log_test_pass "json_get_field extracts numeric values"
}

test_json_get_field_boolean() {
    log_test_start "json_get_field extracts boolean values"

    local json='{"success":true,"failed":false}'
    local result

    result=$(json_get_field "$json" "success")
    assert_equals "true" "$result" "Extract true boolean"

    result=$(json_get_field "$json" "failed")
    assert_equals "false" "$result" "Extract false boolean"

    log_test_pass "json_get_field extracts boolean values"
}

test_json_get_field_missing() {
    log_test_start "json_get_field returns empty for missing fields"

    local json='{"name":"test"}'
    local result

    result=$(json_get_field "$json" "nonexistent")
    assert_empty "$result" "Missing field returns empty"

    log_test_pass "json_get_field returns empty for missing fields"
}

test_json_get_field_null() {
    log_test_start "json_get_field handles null values"

    local json='{"name":null}'
    local result

    result=$(json_get_field "$json" "name")
    assert_empty "$result" "Null field returns empty"

    log_test_pass "json_get_field handles null values"
}

test_json_get_field_nested() {
    log_test_start "json_get_field returns JSON for nested objects"

    local json='{"data":{"nested":"value"},"list":[1,2,3]}'
    local result

    result=$(json_get_field "$json" "data")
    assert_contains "$result" "nested" "Nested object contains key"

    result=$(json_get_field "$json" "list")
    assert_contains "$result" "1" "Array contains element"

    log_test_pass "json_get_field returns JSON for nested objects"
}

test_json_get_field_special_chars() {
    log_test_start "json_get_field handles special characters"

    local json='{"msg":"hello\nworld","path":"C:\\Users"}'
    local result

    result=$(json_get_field "$json" "msg")
    assert_not_empty "$result" "Handles escaped newline"

    result=$(json_get_field "$json" "path")
    assert_not_empty "$result" "Handles backslash"

    log_test_pass "json_get_field handles special characters"
}

test_json_get_field_empty_input() {
    log_test_start "json_get_field handles empty input"

    local result

    # Empty JSON
    result=$(json_get_field "" "field")
    assert_empty "$result" "Empty JSON returns empty"

    # Empty field name
    result=$(json_get_field '{"a":"b"}' "")
    assert_empty "$result" "Empty field name returns empty"

    log_test_pass "json_get_field handles empty input"
}

#==============================================================================
# JSON Parsing Tests: json_is_success()
#==============================================================================

test_json_is_success_true() {
    log_test_start "json_is_success returns 0 for success:true"

    if json_is_success '{"success":true,"data":"test"}'; then
        pass "success:true returns 0"
    else
        fail "success:true should return 0"
    fi

    log_test_pass "json_is_success returns 0 for success:true"
}

test_json_is_success_false() {
    log_test_start "json_is_success returns 1 for success:false"

    if json_is_success '{"success":false,"error":"test"}'; then
        fail "success:false should return 1"
    else
        pass "success:false returns 1"
    fi

    log_test_pass "json_is_success returns 1 for success:false"
}

test_json_is_success_missing() {
    log_test_start "json_is_success returns 1 for missing success field"

    if json_is_success '{"data":"test"}'; then
        fail "missing success should return 1"
    else
        pass "missing success returns 1"
    fi

    log_test_pass "json_is_success returns 1 for missing success field"
}

#==============================================================================
# JSON Parsing Tests: json_escape()
#==============================================================================

test_json_escape_quotes() {
    log_test_start "json_escape escapes double quotes"

    local result
    result=$(json_escape 'say "hello"')
    assert_equals 'say \"hello\"' "$result" "Escape quotes"

    log_test_pass "json_escape escapes double quotes"
}

test_json_escape_backslash() {
    log_test_start "json_escape escapes backslashes"

    local result
    result=$(json_escape 'path\to\file')
    assert_equals 'path\\to\\file' "$result" "Escape backslashes"

    log_test_pass "json_escape escapes backslashes"
}

test_json_escape_newline() {
    log_test_start "json_escape escapes newlines"

    local result
    result=$(json_escape $'line1\nline2')
    assert_equals 'line1\nline2' "$result" "Escape newline"

    log_test_pass "json_escape escapes newlines"
}

test_json_escape_tab() {
    log_test_start "json_escape escapes tabs"

    local result
    result=$(json_escape $'col1\tcol2')
    assert_equals 'col1\tcol2' "$result" "Escape tab"

    log_test_pass "json_escape escapes tabs"
}

test_json_escape_combined() {
    log_test_start "json_escape handles multiple special chars"

    local result
    result=$(json_escape $'quote"\nbackslash\\')
    # Result should be: quote\"\nbackslash\\
    assert_contains "$result" '\"' "Contains escaped quote"
    assert_contains "$result" '\n' "Contains escaped newline"
    assert_contains "$result" '\\' "Contains escaped backslash"

    log_test_pass "json_escape handles multiple special chars"
}

test_json_escape_empty() {
    log_test_start "json_escape handles empty string"

    local result
    result=$(json_escape "")
    assert_empty "$result" "Empty input returns empty"

    log_test_pass "json_escape handles empty string"
}

#==============================================================================
# ntm_check_available Tests
#==============================================================================

test_ntm_check_available_not_installed() {
    log_test_start "ntm_check_available returns 1 when not installed"

    # Override PATH to ensure ntm is not found
    local old_path="$PATH"
    PATH="/nonexistent"

    ntm_check_available
    local exit_code=$?

    PATH="$old_path"

    assert_equals "1" "$exit_code" "Returns 1 when ntm not in PATH"

    log_test_pass "ntm_check_available returns 1 when not installed"
}

test_ntm_check_available_with_mock() {
    log_test_start "ntm_check_available returns 0 with mock ntm"

    local temp_bin
    temp_bin=$(create_temp_dir)

    # Create mock ntm that responds to --robot-status
    cat > "$temp_bin/ntm" << 'MOCK_EOF'
#!/usr/bin/env bash
case "$1" in
    --robot-status) echo '{"success":true}'; exit 0 ;;
    *) exit 1 ;;
esac
MOCK_EOF
    chmod +x "$temp_bin/ntm"

    local old_path="$PATH"
    PATH="$temp_bin:$PATH"

    ntm_check_available
    local exit_code=$?

    PATH="$old_path"

    assert_equals "0" "$exit_code" "Returns 0 with working mock ntm"

    log_test_pass "ntm_check_available returns 0 with mock ntm"
}

test_ntm_check_available_broken() {
    log_test_start "ntm_check_available returns 2 when ntm is broken"

    local temp_bin
    temp_bin=$(create_temp_dir)

    # Create mock ntm that fails on --robot-status
    cat > "$temp_bin/ntm" << 'MOCK_EOF'
#!/usr/bin/env bash
exit 1
MOCK_EOF
    chmod +x "$temp_bin/ntm"

    local old_path="$PATH"
    PATH="$temp_bin:$PATH"

    ntm_check_available
    local exit_code=$?

    PATH="$old_path"

    assert_equals "2" "$exit_code" "Returns 2 when ntm is broken"

    log_test_pass "ntm_check_available returns 2 when ntm is broken"
}

#==============================================================================
# has_uncommitted_changes Tests
#==============================================================================

test_has_uncommitted_changes_clean() {
    log_test_start "has_uncommitted_changes returns 1 for clean repo"

    local repo
    repo=$(create_temp_dir)

    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1

    if has_uncommitted_changes "$repo"; then
        fail "Clean repo should return 1 (no changes)"
    else
        pass "Clean repo returns 1"
    fi

    log_test_pass "has_uncommitted_changes returns 1 for clean repo"
}

test_has_uncommitted_changes_dirty() {
    log_test_start "has_uncommitted_changes returns 0 for dirty repo"

    local repo
    repo=$(create_temp_dir)

    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1

    # Make it dirty
    echo "more content" >> "$repo/file.txt"

    if has_uncommitted_changes "$repo"; then
        pass "Dirty repo returns 0"
    else
        fail "Dirty repo should return 0 (has changes)"
    fi

    log_test_pass "has_uncommitted_changes returns 0 for dirty repo"
}

test_has_uncommitted_changes_untracked() {
    log_test_start "has_uncommitted_changes returns 0 for untracked files"

    local repo
    repo=$(create_temp_dir)

    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1

    # Add untracked file
    echo "new content" > "$repo/newfile.txt"

    if has_uncommitted_changes "$repo"; then
        pass "Repo with untracked files returns 0"
    else
        fail "Repo with untracked files should return 0"
    fi

    log_test_pass "has_uncommitted_changes returns 0 for untracked files"
}

test_has_uncommitted_changes_staged() {
    log_test_start "has_uncommitted_changes returns 0 for staged changes"

    local repo
    repo=$(create_temp_dir)

    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1

    # Stage a change
    echo "staged content" >> "$repo/file.txt"
    git -C "$repo" add file.txt

    if has_uncommitted_changes "$repo"; then
        pass "Repo with staged changes returns 0"
    else
        fail "Repo with staged changes should return 0"
    fi

    log_test_pass "has_uncommitted_changes returns 0 for staged changes"
}

test_has_uncommitted_changes_empty_path() {
    log_test_start "has_uncommitted_changes returns 1 for empty path"

    if has_uncommitted_changes ""; then
        fail "Empty path should return 1"
    else
        pass "Empty path returns 1"
    fi

    log_test_pass "has_uncommitted_changes returns 1 for empty path"
}

#==============================================================================
# is_file_denied Tests
#==============================================================================

test_is_file_denied_env_file() {
    log_test_start "is_file_denied blocks .env files"

    if is_file_denied ".env"; then
        pass ".env is denied"
    else
        fail ".env should be denied"
    fi

    if is_file_denied ".env.local"; then
        pass ".env.local is denied"
    else
        fail ".env.local should be denied"
    fi

    log_test_pass "is_file_denied blocks .env files"
}

test_is_file_denied_keys() {
    log_test_start "is_file_denied blocks key files"

    if is_file_denied "server.pem"; then
        pass ".pem file is denied"
    else
        fail ".pem file should be denied"
    fi

    if is_file_denied "private.key"; then
        pass ".key file is denied"
    else
        fail ".key file should be denied"
    fi

    if is_file_denied "id_rsa"; then
        pass "id_rsa is denied"
    else
        fail "id_rsa should be denied"
    fi

    log_test_pass "is_file_denied blocks key files"
}

test_is_file_denied_credentials() {
    log_test_start "is_file_denied blocks credential files"

    if is_file_denied "credentials.json"; then
        pass "credentials.json is denied"
    else
        fail "credentials.json should be denied"
    fi

    if is_file_denied "secrets.json"; then
        pass "secrets.json is denied"
    else
        fail "secrets.json should be denied"
    fi

    log_test_pass "is_file_denied blocks credential files"
}

test_is_file_denied_node_modules() {
    log_test_start "is_file_denied blocks node_modules"

    if is_file_denied "node_modules"; then
        pass "node_modules is denied"
    else
        fail "node_modules should be denied"
    fi

    if is_file_denied "node_modules/package/index.js"; then
        pass "node_modules/* is denied"
    else
        fail "node_modules/* should be denied"
    fi

    log_test_pass "is_file_denied blocks node_modules"
}

test_is_file_denied_allowed_files() {
    log_test_start "is_file_denied allows normal files"

    if is_file_denied "src/main.py"; then
        fail "src/main.py should be allowed"
    else
        pass "src/main.py is allowed"
    fi

    if is_file_denied "README.md"; then
        fail "README.md should be allowed"
    else
        pass "README.md is allowed"
    fi

    if is_file_denied "package.json"; then
        fail "package.json should be allowed"
    else
        pass "package.json is allowed"
    fi

    log_test_pass "is_file_denied allows normal files"
}

test_is_file_denied_path_normalization() {
    log_test_start "is_file_denied normalizes paths"

    # Should strip leading ./
    if is_file_denied "./.env"; then
        pass "./.env is denied (normalized)"
    else
        fail "./.env should be denied after normalization"
    fi

    log_test_pass "is_file_denied normalizes paths"
}

test_is_file_denied_extra_patterns() {
    log_test_start "is_file_denied respects AGENT_SWEEP_DENYLIST_EXTRA"

    local old_extra="${AGENT_SWEEP_DENYLIST_EXTRA:-}"
    AGENT_SWEEP_DENYLIST_EXTRA="custom_secret.txt *.custom"

    if is_file_denied "custom_secret.txt"; then
        pass "Extra pattern custom_secret.txt is denied"
    else
        fail "Extra pattern custom_secret.txt should be denied"
    fi

    if is_file_denied "file.custom"; then
        pass "Extra glob *.custom is denied"
    else
        fail "Extra glob *.custom should be denied"
    fi

    AGENT_SWEEP_DENYLIST_EXTRA="$old_extra"

    log_test_pass "is_file_denied respects AGENT_SWEEP_DENYLIST_EXTRA"
}

#==============================================================================
# Run Tests
#==============================================================================

setup_cleanup_trap

# JSON parsing tests
run_test test_json_get_field_string
run_test test_json_get_field_number
run_test test_json_get_field_boolean
run_test test_json_get_field_missing
run_test test_json_get_field_null
run_test test_json_get_field_nested
run_test test_json_get_field_special_chars
run_test test_json_get_field_empty_input
run_test test_json_is_success_true
run_test test_json_is_success_false
run_test test_json_is_success_missing
run_test test_json_escape_quotes
run_test test_json_escape_backslash
run_test test_json_escape_newline
run_test test_json_escape_tab
run_test test_json_escape_combined
run_test test_json_escape_empty

# ntm_check_available tests
run_test test_ntm_check_available_not_installed
run_test test_ntm_check_available_with_mock
run_test test_ntm_check_available_broken

# has_uncommitted_changes tests
run_test test_has_uncommitted_changes_clean
run_test test_has_uncommitted_changes_dirty
run_test test_has_uncommitted_changes_untracked
run_test test_has_uncommitted_changes_staged
run_test test_has_uncommitted_changes_empty_path

# is_file_denied tests
run_test test_is_file_denied_env_file
run_test test_is_file_denied_keys
run_test test_is_file_denied_credentials
run_test test_is_file_denied_node_modules
run_test test_is_file_denied_allowed_files
run_test test_is_file_denied_path_normalization
run_test test_is_file_denied_extra_patterns

print_results
exit "$(get_exit_code)"
