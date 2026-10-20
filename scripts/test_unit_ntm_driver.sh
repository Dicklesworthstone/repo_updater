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
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Import the actual runtime through its advertised Bash source API.
NTM_TEST_SCRIPT_DIR="$SCRIPT_DIR"
NTM_TEST_PROJECT_DIR="$PROJECT_DIR"
# shellcheck source=../ru
source "$PROJECT_DIR/ru"
SCRIPT_DIR="$NTM_TEST_SCRIPT_DIR"
PROJECT_DIR="$NTM_TEST_PROJECT_DIR"

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

create_ai_work_fixture() {
    local env_root repo_path
    if [[ -n "${1:-}" ]]; then env_root=$(mktemp -d "$1/ai-work.XXXXXX") || return 1;
    else env_root=$(create_test_env) || return 1; fi
    repo_path="$env_root/repo"
    mkdir -p "$repo_path" "$env_root/artifacts" || return 1
    git -C "$repo_path" init -q -b main || return 1
    git -C "$repo_path" config user.name 'Test User' || return 1
    git -C "$repo_path" config user.email test@example.invalid || return 1
    printf 'baseline bytes\n' > "$repo_path/base.txt"
    git -C "$repo_path" add base.txt || return 1
    git -C "$repo_path" commit -qm Baseline || return 1
    printf '%s\n' "$repo_path"
}

test_ai_work_idle_without_commits_fails() {
    local repo_path before before_index result rc=0
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    before_index=$(git hash-object "$repo_path/.git/index")
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts") || rc=$?
    assert_equals 1 "$rc" "Idle with no Git work is a typed failure"
    assert_equals failed "$(jq -r '.status' <<< "$result")" "No-work status is never successful"
    assert_equals '[]' "$(jq -c '.commits' <<< "$result")" "No-work result records zero actual commits"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Inspection preserves original HEAD"
    assert_equals "$before_index" "$(git hash-object "$repo_path/.git/index")" "Inspection preserves exact original index"
}

test_ai_work_real_commits_have_revision_bound_result() {
    local repo_path before first second result name=$'new\nfile.txt'
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    printf 'actual logical change\n' > "$repo_path/$name"
    git --literal-pathspecs -C "$repo_path" add -- "$name"
    git -C "$repo_path" commit -qm 'Logical change'
    first=$(git -C "$repo_path" rev-parse HEAD)
    printf 'second actual change\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add base.txt
    git -C "$repo_path" commit -qm 'Second logical change'
    second=$(git -C "$repo_path" rev-parse HEAD)
    assert_success "Two real nonempty commits satisfy work validation" capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts"
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts")
    assert_equals success "$(jq -r '.status' <<< "$result")" "Result reports verified work success"
    assert_equals "$before" "$(jq -r '.before_head' <<< "$result")" "Result binds actual before revision"
    assert_equals "$second" "$(jq -r '.after_head' <<< "$result")" "Result binds actual after revision"
    assert_equals "$first" "$(jq -r '.commits[0]' <<< "$result")" "Result lists actual first full commit SHA"
    assert_equals "$second" "$(jq -r '.commits[1]' <<< "$result")" "Result lists actual second full commit SHA"
    assert_equals '[]' "$(jq -c '.remaining_paths' <<< "$result")" "Successful actual work is clean"
    assert_equals 'actual logical change' "$(git -C "$repo_path" show "HEAD:$name")" "Unusual filename remains in actual committed content"
}

# Real Git snapshots and commits; no provider response substitutes for content.
test_ai_requested_working_version_allows_partial_staging() {
    local repo_path before artifact requests result rc=0 name=$'nested/literal[*]\n'
    repo_path=$(create_ai_work_fixture) || return 1
    artifact="${repo_path%/*}/artifacts"
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'original staged intermediate\n' > "$repo_path/base.txt"
    git -C "$repo_path" add -- base.txt || return 1
    cp "$repo_path/.git/index" "${repo_path%/*}/original.index.raw" || return 1
    printf 'original complete working version\n' > "$repo_path/base.txt"
    mkdir -p "$repo_path/nested" || return 1
    printf 'literal trailing newline file bytes\n' > "$repo_path/$name"
    requests=$(capture_ai_requested_content "$repo_path" "$before" "$artifact") || return 1
    assert_success "Snapshot preserves the exact original partial index" cmp "${repo_path%/*}/original.index.raw" "$repo_path/.git/index"
    assert_success "Recovery copy retains the exact original index bytes" cmp "${repo_path%/*}/original.index.raw" "$artifact/before.index.raw"
    assert_success "Raw working recovery copy retains requested bytes" cmp "$repo_path/base.txt" "$artifact/before-files/base.txt"
    git --literal-pathspecs -C "$repo_path" add -- base.txt "$name" || return 1
    git -C "$repo_path" commit -qm 'One legitimate complete working-version commit' || return 1
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 0 "$rc" "One working-version commit satisfies a partially staged request"
    assert_equals 1 "$(jq '.commits | length' <<< "$result")" "No extra intermediate staged-version commit is required"
    assert_equals true "$(jq -r '.requested_content_verified' <<< "$result")" "Original working versions are actually verified"
    assert_equals '[]' "$(jq -c '.unpreserved_requests' <<< "$result")" "Every original requested version is found"
    assert_equals 'original complete working version' "$(git -C "$repo_path" show HEAD:base.txt)" "Actual candidate contains the requested working version"
    assert_success "Original staged version remains recoverable separately" env GIT_INDEX_FILE="$artifact/before.index.raw" git -C "$repo_path" show :base.txt
    assert_equals 2 "$(jq 'length' <<< "$requests")" "Nested literal path and tracked request are both captured"
    assert_success "Trailing-newline path is represented exactly" jq -e --arg path "$name" 'any(.[]; .path == $path)' <<< "$requests"
}

test_ai_requested_staged_deletion_is_captured_once() {
    local repo_path before artifact requests result rc=0 name=$'staged deletion[*]\n'
    repo_path=$(create_ai_work_fixture) || return 1
    artifact="${repo_path%/*}/artifacts"
    printf 'original staged deletion bytes\n' > "$repo_path/$name"
    git --literal-pathspecs -C "$repo_path" add -- "$name" || return 1
    git -C "$repo_path" commit -qm 'Staged deletion baseline' || return 1
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    mv "$repo_path/$name" "${repo_path%/*}/retained-deleted-file" || return 1
    git --literal-pathspecs -C "$repo_path" add -A -- "$name" || return 1
    cp "$repo_path/.git/index" "${repo_path%/*}/original.index.raw" || return 1
    requests=$(capture_ai_requested_content "$repo_path" "$before" "$artifact") || rc=$?
    assert_equals 0 "$rc" "Duplicated cached and working deletion paths are captured successfully"
    assert_equals 1 "$(jq 'length' <<< "$requests")" "One requested deletion is recorded once"
    assert_success "Literal deleted path and absence are recorded exactly" jq -e --arg path "$name" '.[0].path == $path and .[0].mode == "000000"' <<< "$requests"
    assert_success "Capture preserves the actual staged-deletion index" cmp "${repo_path%/*}/original.index.raw" "$repo_path/.git/index"
    assert_success "Recovery retains the exact original staged index" cmp "${repo_path%/*}/original.index.raw" "$artifact/before.index.raw"
    git -C "$repo_path" commit -qm 'Complete the original staged deletion' || return 1
    rc=0
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 0 "$rc" "A real committed staged deletion satisfies requested-work validation"
    assert_equals true "$(jq -r '.requested_content_verified' <<< "$result")" "Absence is verified in the actual final candidate"
    assert_equals 'original staged deletion bytes' "$(cat "${repo_path%/*}/retained-deleted-file")" "Original deleted bytes remain retained outside the fixture"
}

test_ai_requested_content_discard_fails_without_rollback() {
    local repo_path before after artifact requests result rc=0 index_after
    repo_path=$(create_ai_work_fixture) || return 1
    artifact="${repo_path%/*}/artifacts"
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'actual requested content to retain\n' > "$repo_path/base.txt"
    git -C "$repo_path" add -- base.txt || return 1
    requests=$(capture_ai_requested_content "$repo_path" "$before" "$artifact") || return 1
    git -C "$repo_path" show "$before:base.txt" > "$repo_path/base.txt" || return 1
    printf 'useful unrelated provider work\n' > "$repo_path/useful.txt"
    git -C "$repo_path" add -- base.txt useful.txt || return 1
    git -C "$repo_path" commit -qm 'Useful but incomplete requested work' || return 1
    after=$(git -C "$repo_path" rev-parse HEAD) || return 1
    cp "$repo_path/.git/index" "$artifact/provider.index.raw" || return 1
    index_after=$(git hash-object "$repo_path/.git/index") || return 1
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 1 "$rc" "Discarding requested bytes fails despite a nonempty clean commit"
    assert_equals failed "$(jq -r '.status' <<< "$result")" "Transport completion cannot substitute for requested content"
    assert_equals 'Original requested content is missing from the final candidate' "$(jq -r '.error' <<< "$result")" "Failure names the observed content loss"
    assert_equals base.txt "$(jq -r '.unpreserved_requests[0].path' <<< "$result")" "Failure identifies the original requested path"
    assert_equals '[]' "$(jq -c '.remaining_paths' <<< "$result")" "Clean final state is recorded honestly"
    assert_equals "$after" "$(jq -r '.commits[0]' <<< "$result")" "Useful actual provider commit remains in the result"
    assert_equals "$after" "$(git -C "$repo_path" rev-parse HEAD)" "Refusal never rolls back useful provider commits"
    assert_equals "$index_after" "$(git hash-object "$repo_path/.git/index")" "Inspection preserves the actual provider index"
    assert_equals 'useful unrelated provider work' "$(git -C "$repo_path" show HEAD:useful.txt)" "Useful new committed content remains intact"
    assert_equals 'actual requested content to retain' "$(cat "$artifact/before-files/base.txt")" "Raw discarded work remains available for recovery"
    assert_equals 'actual requested content to retain' "$(GIT_INDEX_FILE="$artifact/before.index.raw" git -C "$repo_path" show :base.txt)" "Original staged content remains separately recoverable"
}

test_ai_requested_final_rewrite_requires_edit_policy() {
    local repo_path before artifact requests result rc=0 first
    repo_path=$(create_ai_work_fixture) || return 1
    artifact="${repo_path%/*}/artifacts"
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'original requested working bytes\n' > "$repo_path/base.txt"
    requests=$(capture_ai_requested_content "$repo_path" "$before" "$artifact") || return 1
    git -C "$repo_path" add -- base.txt || return 1
    git -C "$repo_path" commit -qm 'Preserve the original requested change' || return 1
    first=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'further useful logical edit\n' > "$repo_path/base.txt"
    git -C "$repo_path" add -- base.txt || return 1
    git -C "$repo_path" commit -qm 'Further logical edit' || return 1
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 1 "$rc" "Historical original bytes do not satisfy ai-sync's unchanged final-work requirement"
    assert_equals false "$(jq -r '.requested_content_verified' <<< "$result")" "Preserve policy reports actual final-content failure"
    assert_equals "$first" "$(jq -r '.commits[0]' <<< "$result")" "Actual earlier preservation commit is recorded"
    assert_equals 2 "$(jq '.commits | length' <<< "$result")" "Both real logical commits remain accepted"
    assert_equals 'original requested working bytes' "$(git -C "$repo_path" show "$first:base.txt")" "Original bytes are reachable in actual candidate history"
    assert_equals 'further useful logical edit' "$(git -C "$repo_path" show HEAD:base.txt)" "Useful final changes need not equal the initial snapshot"
    rc=0
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" edit) || rc=$?
    assert_equals 0 "$rc" "An editing workflow can legitimately replace requested content"
    assert_equals edit "$(jq -r '.requested_content_policy' <<< "$result")" "Common result exposes the actual editing policy"
    assert_equals false "$(jq -r '.requested_content_verified' <<< "$result")" "Retained recovery snapshot is not presented as verified preservation"
}

test_ai_requested_deletion_rename_mode_and_symlink() {
    local repo_path before artifact requests result rc=0 name=$'new name[1]\n'
    repo_path=$(create_ai_work_fixture) || return 1
    artifact="${repo_path%/*}/artifacts"
    printf 'deletion baseline bytes\n' > "$repo_path/deleted.txt"
    printf 'rename baseline bytes\n' > "$repo_path/old.txt"
    printf '#!/usr/bin/env bash\nprintf executable\n' > "$repo_path/tool.sh"
    git -C "$repo_path" add -- deleted.txt old.txt tool.sh || return 1
    git -C "$repo_path" commit -qm 'Structural request baseline' || return 1
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    # Move outside the fixture to represent a requested deletion without
    # deleting any file; the original bytes remain separately retained.
    mv "$repo_path/deleted.txt" "${repo_path%/*}/retained-deleted.txt" || return 1
    mv "$repo_path/old.txt" "$repo_path/$name" || return 1
    chmod +x "$repo_path/tool.sh" || return 1
    ln -s missing-target "$repo_path/link" || return 1
    requests=$(capture_ai_requested_content "$repo_path" "$before" "$artifact") || return 1
    git --literal-pathspecs -C "$repo_path" add -A -- deleted.txt old.txt "$name" tool.sh link || return 1
    git -C "$repo_path" commit -qm 'Requested structural changes' || return 1
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 0 "$rc" "Original deletion, literal rename, executable mode and symlink are valid requested work"
    assert_equals 5 "$(jq 'length' <<< "$requests")" "Rename captures old-path deletion and new-path content separately"
    assert_success "Requested deletion is represented as absence" jq -e 'any(.[]; .path == "deleted.txt" and .mode == "000000")' <<< "$requests"
    assert_success "Executable bit is part of the exact requested version" jq -e 'any(.[]; .path == "tool.sh" and .mode == "100755")' <<< "$requests"
    assert_success "Symlink target and mode are part of the exact requested version" jq -e 'any(.[]; .path == "link" and .mode == "120000")' <<< "$requests"
    assert_equals 'deletion baseline bytes' "$(cat "${repo_path%/*}/retained-deleted.txt")" "Probe itself preserves deleted fixture bytes"
    assert_equals missing-target "$(git -C "$repo_path" show HEAD:link)" "Actual committed symlink target remains exact"
    assert_equals 'rename baseline bytes' "$(git -C "$repo_path" show "HEAD:$name")" "Actual literal rename content remains exact"
    cp "${repo_path%/*}/retained-deleted.txt" "$repo_path/deleted.txt" || return 1
    chmod -x "$repo_path/tool.sh" || return 1
    git -C "$repo_path" add -- deleted.txt tool.sh || return 1
    git -C "$repo_path" commit -qm 'Provider restores requested deletion and loses executable mode' || return 1
    rc=0
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$artifact" "$requests" preserve "$(cat "$artifact/requested.tree")") || rc=$?
    assert_equals 1 "$rc" "Restored deleted content and lost executable mode fail final preservation"
    assert_equals 2 "$(jq '.unpreserved_requests | length' <<< "$result")" "Failure names exactly the two changed final requests"
    assert_success "Deletion refusal identifies the restored path" jq -e 'any(.unpreserved_requests[]; .path == "deleted.txt")' <<< "$result"
    assert_success "Mode refusal identifies the altered executable" jq -e 'any(.unpreserved_requests[]; .path == "tool.sh")' <<< "$result"
}

# Controlled inspection-error injection changes only the final diff --quiet
# exit. Every repository, commit, index and content observation uses real Git.
test_ai_work_diff_inspection_error_preserves_real_state() {
    local repo_path env_root before after index_before content_before result rc=0
    repo_path=$(create_ai_work_fixture) || return 1
    env_root=${repo_path%/*}
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'actual nonempty inspection-control bytes\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add base.txt || return 1
    git -C "$repo_path" commit -qm 'Nonempty inspection control' || return 1
    after=$(git -C "$repo_path" rev-parse HEAD) || return 1
    index_before=$(git hash-object "$repo_path/.git/index") || return 1
    content_before=$(git hash-object "$repo_path/base.txt") || return 1
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$env_root/artifacts") || rc=$?
    printf '%s\n' "$result" > "$env_root/inspection-control.json"
    assert_equals 0 "$rc" "Real nonempty committed control satisfies work inspection"
    assert_equals success "$(jq -r '.status' <<< "$result")" "Real diff exit one confirms actual nonempty work"
    assert_equals "$after" "$(jq -r '.commits[0]' <<< "$result")" "Successful control records the actual full candidate SHA"
    assert_equals "$after" "$(git -C "$repo_path" rev-parse HEAD)" "Positive inspection preserves actual HEAD"
    assert_equals "$index_before" "$(git hash-object "$repo_path/.git/index")" "Positive inspection preserves exact index"
    assert_equals "$content_before" "$(git hash-object "$repo_path/base.txt")" "Positive inspection preserves actual content"
    (
        git() {
            if [[ "$#" == 6 && "$1" == -C && "$2" == "$repo_path" && "$3" == diff && "$4" == --quiet && "$5" == "$before" && "$6" == "$after" ]]; then
                printf 'Controlled diff --quiet inspection error: exit 128\n' >&2
                return 128
            fi
            command git "$@"
        }
        rc=0
        result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$env_root/artifacts" 2> "$env_root/inspection-error.stderr") || rc=$?
        cat "$env_root/inspection-error.stderr" >&2
        printf '%s\n' "$result" > "$env_root/inspection-error.json"
        assert_equals 1 "$rc" "Controlled diff exit 128 fails work inspection"
        assert_equals failed "$(jq -r '.status' <<< "$result")" "Inspection error cannot masquerade as nonempty work"
        assert_equals 'Git change comparison failed with exit 128' "$(jq -r '.error' <<< "$result")" "Result retains the actual comparison failure exit"
        assert_contains "$(cat "$env_root/inspection-error.stderr")" 'Controlled diff --quiet inspection error: exit 128' "Controlled failure was actually exercised and its diagnostic retained"
        assert_equals "$before" "$(jq -r '.before_head' <<< "$result")" "Inspection refusal retains actual original revision"
        assert_equals "$after" "$(jq -r '.after_head' <<< "$result")" "Inspection refusal retains actual candidate revision"
        assert_equals "$after" "$(jq -r '.commits[0]' <<< "$result")" "Inspection refusal preserves real commit inventory"
        assert_equals '[]' "$(jq -c '.remaining_paths' <<< "$result")" "Inspection refusal retains the actual clean-work observation"
        assert_equals "$after" "$(git -C "$repo_path" rev-parse HEAD)" "Inspection error preserves actual HEAD"
        assert_equals "$index_before" "$(git hash-object "$repo_path/.git/index")" "Inspection error preserves exact index"
        assert_equals "$content_before" "$(git hash-object "$repo_path/base.txt")" "Inspection error preserves actual file bytes"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Controlled inspection failure and real nonempty work control preserve Git state"
}

test_ai_work_empty_commits_are_incomplete() {
    local repo_path before result rc=0
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    git -C "$repo_path" commit --allow-empty -qm 'Empty completion claim'
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts") || rc=$?
    assert_equals 1 "$rc" "An empty commit cannot impersonate requested work"
    assert_equals 1 "$(jq '.commits | length' <<< "$result")" "Result retains the actual empty commit as evidence"
    assert_contains "$(jq -r '.error' <<< "$result")" 'no requested file changes' "Error identifies missing actual work"
}

test_ai_work_remaining_files_are_preserved_and_typed() {
    local repo_path before result rc=0 name=$'remaining\nfile.txt' file_hash index_hash
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    printf 'actual committed change\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add base.txt
    git -C "$repo_path" commit -qm 'Partial work'
    printf 'unfinished operator bytes\n' > "$repo_path/$name"
    file_hash=$(git hash-object "$repo_path/$name")
    index_hash=$(git hash-object "$repo_path/.git/index")
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts") || rc=$?
    assert_equals 1 "$rc" "Actual commits with remaining work report incomplete"
    assert_equals "$name" "$(jq -r '.remaining_paths[0]' <<< "$result")" "Structured remaining paths preserve a newline filename"
    assert_equals "$file_hash" "$(git hash-object "$repo_path/$name")" "Incomplete validation preserves remaining bytes"
    assert_equals "$index_hash" "$(git hash-object "$repo_path/.git/index")" "Incomplete validation preserves exact index bytes"
}

test_ai_work_branch_change_cannot_succeed() {
    local repo_path before result rc=0 after
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    git -C "$repo_path" checkout -qb changed
    printf 'actual changed-branch content\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add base.txt
    git -C "$repo_path" commit -qm 'Other branch'
    after=$(git -C "$repo_path" rev-parse HEAD)
    result=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts") || rc=$?
    assert_equals 1 "$rc" "Changed branch fails the requested repository identity"
    assert_contains "$(jq -r '.error' <<< "$result")" 'identity' "Identity failure is explicit"
    assert_equals "$after" "$(git -C "$repo_path" rev-parse HEAD)" "Identity refusal retains actual generated work"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse main)" "Original branch is preserved"
}

test_ai_session_result_schema_checks_actual_exit_and_publication() {
    local repo_path before work base malformed expression result
    repo_path=$(create_ai_work_fixture)
    before=$(git -C "$repo_path" rev-parse HEAD)
    printf 'actual result-validation work\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add base.txt
    git -C "$repo_path" commit -qm 'Result-validation work'
    work=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "${repo_path%/*}/artifacts")
    base=$(jq -cen --arg repo "$repo_path" --argjson work "$work" '{schema_version:1,repo:$repo,status:"success",exit_code:0,transport:{status:"idle",exit_code:0},work:$work,publication:{no_push:true,status:"not_requested"}}')
    assert_success "Actual clean committed work yields an accepted common result" validate_ai_session_result "$base" 0 "$repo_path"
    for expression in '.exit_code=1' '.status="idle"' '.work.status="failed"' '.work.commits=[]' '.work.remaining_paths=["unfinished"]' '.publication.no_push=false' '.publication.status="unverified"' '.transport.status="failed"' '.schema_version="1"' '.repo="/wrong/repo"' '.work.requested_content_verified=true' '.work.requested_content_policy="unknown"' '.work.unpreserved_requests=[{"path":"lost"}]'; do
        malformed=$(jq -c "$expression" <<< "$base")
        assert_fails "A changed completion contract is rejected: $expression" validate_ai_session_result "$malformed" 0 "$repo_path"
        assert_success "Unchanged actual-work control remains accepted" validate_ai_session_result "$base" 0 "$repo_path"
    done
    assert_fails "Real nonzero process exit cannot masquerade as successful result" validate_ai_session_result "$base" 1 "$repo_path"
    result=$(printf '%s\n%s\n' "$base" "$base")
    assert_fails "Two JSON objects cannot masquerade as one session result" validate_ai_session_result "$result" 0 "$repo_path"
    result=$(jq -c '.publication={no_push:false,status:"success"}' <<< "$base")
    assert_success "Verified requested publication has a positive schema control" validate_ai_session_result "$result" 0 "$repo_path"
}

create_controlled_ai_bin() {
    local mock_bin="$1"
    mkdir -p "$mock_bin" || return 1
    cp "$SCRIPT_DIR/test_bin/ntm" "$mock_bin/ntm" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_bin/codex"
    cat > "$mock_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
# Controlled tmux endpoint reports the actual controlled NTM session lifecycle.
set -uo pipefail
[[ "${1:-}" == has-session && "${2:-}" == -t ]] || exit 2
[[ -f "$NTM_MOCK_STATE_FILE" ]] || exit 1
session=$(head -n 1 "$NTM_MOCK_STATE_FILE")
[[ "${3#=}" == "$session" ]] || exit 1
if [[ -f "$NTM_MOCK_STATE_FILE.stopped" ]] && [[ "$(cat "$NTM_MOCK_STATE_FILE.stopped")" == "$session" ]]; then exit 1; fi
exit 0
TMUX
    chmod +x "$mock_bin/ntm" "$mock_bin/codex" "$mock_bin/tmux"
}

test_controlled_ai_transport_and_real_git_work_results() {
    local scenario repo_path env_root mock_bin result rc before after before_index
    for scenario in session_work ok session_dirty session_dead timeout malformed_wait partial_spawn; do
        repo_path=$(create_ai_work_fixture)
        env_root=${repo_path%/*}
        mock_bin="$env_root/mock-bin"
        create_controlled_ai_bin "$mock_bin" || return 1
        printf 'fixture requested work\n' > "$repo_path/planned.txt"
        printf 'Perform the fixture requested work\n' > "$env_root/prompt.txt"
        before=$(git -C "$repo_path" rev-parse HEAD)
        before_index=$(git hash-object "$repo_path/.git/index")
        (
            export PATH="$mock_bin:$PATH" NTM_MOCK_SCENARIO="$scenario" NTM_MOCK_REPO="$repo_path"
            export NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt"
            export NTM_MOCK_ARGS_LOG="$env_root/ntm.args" NTM_MOCK_ENV_LOG="$env_root/ntm.env"
            hash -r
            rc=0
            result=$(spawn_ai_session "$repo_path" "$env_root/prompt.txt" --agent=codex --timeout=5 --no-push) || rc=$?
            assert_success "Controlled external tool chatter leaves one parseable result" jq -e -s 'length == 1 and .[0].schema_version == 1' <<< "$result"
            assert_equals "$rc" "$(jq -r '.exit_code' <<< "$result")" "JSON result retains the actual exit code"
            assert_success "Every finished session result has the common typed contract" validate_ai_session_result "$result" "$rc" "$repo_path"
            assert_contains "$(cat "$env_root/ntm.args")" '--cod=1' "Runtime selects the requested provider"
            assert_contains "$(cat "$env_root/ntm.env")" "project_base=$env_root" "Spawn uses the actual physical repository parent"
            assert_contains "$(cat "$env_root/ntm.env")" 'git_allow_protocol=' "NTM caller receives the transport restriction"
            assert_contains "$(cat "$env_root/ntm.args")" '--pane-env GIT_ALLOW_PROTOCOL=' "Existing tmux-server panes receive the restriction explicitly"
            assert_equals not_requested "$(jq -r '.publication.status' <<< "$result")" "No-push does not invent requested publication"
            assert_file_exists "$(jq -r '.evidence_dir' <<< "$result")/spawn.stdout" "External spawn chatter is retained as an artifact"
            assert_file_exists "$(jq -r '.evidence_dir' <<< "$result")/prompt.txt" "Exact delivered work request is retained"
            after=$(git -C "$repo_path" rev-parse HEAD)
            if [[ "$scenario" == session_work ]]; then
                assert_equals 0 "$rc" "Verified actual commits and clean work report success"
                assert_equals success "$(jq -r '.work.status' <<< "$result")" "Git work success is separate from transport idle"
                assert_not_equals "$before" "$after" "Controlled provider endpoint creates an actual Git commit"
                assert_equals 'fixture requested work' "$(git -C "$repo_path" show HEAD:planned.txt)" "Actual selected content is committed"
                assert_equals confirmed "$(jq -r '.cleanup.status' <<< "$result")" "Successful control requires actual owned session absence"
            else
                assert_not_equals 0 "$rc" "No-work, crash, timeout, partial work and malformed transport are non-success"
                assert_not_equals success "$(jq -r '.status' <<< "$result")" "No failing outcome can report successful work"
                assert_file_exists "$repo_path/planned.txt" "Failure keeps requested fixture content available"
                if [[ "$scenario" == timeout ]]; then
                    assert_equals timeout "$(jq -r '.transport.status' <<< "$result")" "Actual readiness timeout remains a typed transport timeout"
                    assert_equals timeout "$(jq -r '.status' <<< "$result")" "Readiness timeout remains a typed overall timeout"
                fi
                if [[ "$scenario" == partial_spawn ]]; then
                    assert_equals 3 "$(jq -r '.transport.exit_code' <<< "$result")" "Partial spawn retains the controlled endpoint's actual nonzero exit"
                    assert_equals confirmed "$(jq -r '.cleanup.status' <<< "$result")" "Nonzero partial spawn still cleans up its provably owned session"
                    assert_equals "$(jq -r '.session' <<< "$result")" "$(cat "$env_root/ntm.state.stopped")" "Partial-spawn cleanup targets the exact actual unique session"
                    assert_equals "$before" "$after" "Failed partial spawn preserves the real original HEAD"
                    assert_equals "$before_index" "$(git hash-object "$repo_path/.git/index")" "Failed partial spawn preserves the exact real original index"
                    assert_contains "$(cat "$(jq -r '.evidence_dir' <<< "$result")/spawn.stdout")" 'partial session creation failed' "Partial-spawn failure evidence remains available"
                fi
            fi
            exit "$(get_exit_code)"
        )
        assert_equals 0 "$?" "Controlled $scenario endpoint with real Git matches its contract"
    done
}

# NTM and the provider command are controlled endpoints. Publication itself is
# a real Git push to a real bare receiver, including its actual server hook.
assert_ai_host_publication() {
    local mode="$1" repo_path env_root mock_bin before after result rc=0 evidence
    repo_path=$(create_ai_work_fixture) || return 1
    env_root=${repo_path%/*}
    mock_bin="$env_root/mock-bin"
    create_controlled_ai_bin "$mock_bin" || return 1
    git clone -q --bare "$repo_path" "$env_root/receiver.git" || return 1
    git -C "$repo_path" remote add origin "$env_root/receiver.git" || return 1
    cat > "$env_root/receiver.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail
git_dir=$(git rev-parse --absolute-git-dir) || exit 1
cat >> "$git_dir/received-updates"
if [[ "${NTM_MOCK_REJECT_PUSH:-false}" == true ]]; then
    printf 'Controlled receiver rejects requested publication\n' >&2
    exit 17
fi
HOOK
    chmod +x "$env_root/receiver.git/hooks/pre-receive" || return 1
    printf 'actual requested publication bytes\n' > "$repo_path/planned.txt"
    printf 'Commit the actual requested fixture work locally\n' > "$env_root/prompt.txt"
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    (
        export PATH="$mock_bin:$PATH" NTM_MOCK_SCENARIO=session_work NTM_MOCK_REPO="$repo_path"
        export NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt"
        export NTM_MOCK_ARGS_LOG="$env_root/ntm.args" GIT_TRACE="$env_root/git.trace"
        export AGENT_SWEEP_SECRET_SCAN=block
        if [[ "$mode" == rejected ]]; then export NTM_MOCK_REJECT_PUSH=true; fi
        local -a flags=(--push)
        [[ "$mode" != no-push ]] || flags=(--no-push)
        hash -r
        result=$(spawn_ai_session "$repo_path" "$env_root/prompt.txt" --agent=codex --timeout=10 "${flags[@]}") || rc=$?
        printf '%s\n' "$result" > "$env_root/result.json"
        printf '%s\n' "$rc" > "$env_root/result.exit"
        after=$(git -C "$repo_path" rev-parse HEAD)
        evidence=$(jq -r '.evidence_dir' <<< "$result")
        assert_success "Actual exit agrees with the common result contract" validate_ai_session_result "$result" "$rc" "$repo_path"
        assert_equals success "$(jq -r '.work.status' <<< "$result")" "Publication outcome does not erase verified local work"
        assert_equals "$after" "$(jq -r '.work.commits[0]' <<< "$result")" "Result names the actual full candidate SHA"
        assert_not_equals "$before" "$after" "Controlled provider endpoint made an actual nonempty commit"
        assert_equals 'actual requested publication bytes' "$(git -C "$repo_path" show HEAD:planned.txt)" "Actual candidate contains requested bytes"
        assert_success "Actual local candidate leaves no remaining staged work" git -C "$repo_path" diff --cached --quiet
        case "$mode" in
            success)
                assert_equals 0 "$rc" "Host-owned real Git publication succeeds"
                assert_equals success "$(jq -r '.publication.status' <<< "$result")" "Publication success has separate verified status"
                assert_equals "$after" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Actual receiver reaches the exact candidate"
                assert_file_exists "$env_root/receiver.git/received-updates" "Actual receiver hook observed publication"
                assert_file_exists "$evidence/publication.stdout" "Host publication output is retained"
                ;;
            rejected)
                assert_not_equals 0 "$rc" "Actual receiver refusal produces a nonzero session result"
                assert_equals failed "$(jq -r '.status' <<< "$result")" "Rejected publication cannot report overall success"
                assert_equals failed "$(jq -r '.publication.status' <<< "$result")" "Actual publication refusal is typed"
                assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Rejected receiver retains its actual original ref"
                assert_contains "$(cat "$evidence/publication.stderr")" 'Controlled receiver rejects' "Actual remote refusal diagnostic is retained"
                assert_file_exists "$env_root/receiver.git/received-updates" "Refusal exercised the real receiver hook"
                ;;
            no-push)
                assert_equals 0 "$rc" "Local verified work succeeds without requested publication"
                assert_equals true "$(jq -r '.publication.no_push' <<< "$result")" "No-push remains explicit in the common result"
                assert_equals not_requested "$(jq -r '.publication.status' <<< "$result")" "No host publication is requested"
                assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "No-push preserves the actual receiver ref"
                assert_file_not_exists "$env_root/receiver.git/received-updates" "No-push never enters the receiver hook"
                assert_not_contains "$(cat "$env_root/git.trace")" ' push ' "No-push causes zero host Git push invocations"
                assert_not_contains "$(cat "$env_root/git.trace")" ' ls-remote ' "No-push causes zero host receiver inspections"
                assert_not_contains "$(cat "$env_root/git.trace")" ' fetch ' "No-push causes zero host Git fetch invocations"
                ;;
        esac
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Actual $mode publication path satisfies its assertions"
}

test_ai_host_publication_success() { assert_ai_host_publication success; }
test_ai_host_publication_rejected() { assert_ai_host_publication rejected; }
test_ai_host_no_push_invokes_no_transport() { assert_ai_host_publication no-push; }

# Real test commands and real local Git receivers exercise the publication gate.
# Only the provider/NTM transport is controlled. An optional caller-owned root
# retains all fixtures without sourcing the stock framework or cleanup traps.
test_ai_project_tests_before_publication() {
    local retained_root="${1:-}" mode publication failed_scenarios=0
    for publication in push no-push; do
        for mode in success failed dirty changed-head changed-branch timeout; do
            (
                local repo_path env_root before result rc=0 evidence candidate command test_pid
                local timeout_seconds=12
                repo_path=$(create_ai_work_fixture "$retained_root") || exit 1
                env_root=${repo_path%/*}
                create_controlled_ai_bin "$env_root/mock-bin" || exit 1
                git clone -q --bare "$repo_path" "$env_root/receiver.git" || exit 1
                git -C "$repo_path" remote add origin "$env_root/receiver.git" || exit 1
                cat > "$env_root/receiver.git/hooks/pre-receive" <<'TEST_RECEIVER'
#!/usr/bin/env bash
set -uo pipefail
read -r old new ref || exit 1
printf '%s %s %s\n' "$old" "$new" "$ref" >> "$RU_TEST_GATE_ROOT/received-updates"
if [[ -f "$RU_TEST_GATE_ROOT/test.finished" ]]; then
    printf 'yes\n' > "$RU_TEST_GATE_ROOT/receiver-saw-tests"
else
    printf 'no\n' > "$RU_TEST_GATE_ROOT/receiver-saw-tests"
fi
TEST_RECEIVER
                chmod +x "$env_root/receiver.git/hooks/pre-receive" || exit 1
                cat > "$env_root/project-test.sh" <<'PROJECT_TEST'
#!/usr/bin/env bash
set -uo pipefail
cat "$RU_TEST_GATE_ROOT/expected.stdout"
cat "$RU_TEST_GATE_ROOT/expected.stderr" >&2
printf '%s\n' "$BASHPID" > "$RU_TEST_GATE_ROOT/test.pid"
git rev-parse HEAD > "$RU_TEST_GATE_ROOT/tested.head" || exit 21
[[ -f planned.txt && -f "$RU_TEST_GATE_ROOT/ntm.state.stopped" ]] || exit 22
case "$RU_TEST_GATE_MODE" in
    failed) exit 7 ;;
    dirty) printf 'test left changed bytes\n' >> planned.txt ;;
    changed-head)
        printf 'test committed new bytes\n' >> planned.txt
        git add -- planned.txt && git commit -qm 'Test changed validated candidate' || exit 23
        ;;
    changed-branch) git checkout -qb test-other || exit 24 ;;
    timeout)
        sleep 30 &
        printf '%s\n' "$!" > "$RU_TEST_GATE_ROOT/test-child.pid"
        wait "$!"
        ;;
esac
printf 'test completed\n' > "$RU_TEST_GATE_ROOT/test.finished"
PROJECT_TEST
                printf 'real project-test stdout\n%0500d\nlast stdout line\n' 0 > "$env_root/expected.stdout"
                printf 'real project-test stderr\n%0500d\nlast stderr line\n' 0 > "$env_root/expected.stderr"
                printf 'actual requested bytes for test gate\n' > "$repo_path/planned.txt"
                printf 'Commit the actual requested fixture work locally\n' > "$env_root/prompt.txt"
                before=$(git -C "$repo_path" rev-parse HEAD) || exit 1
                export PATH="$env_root/mock-bin:$PATH" NTM_MOCK_SCENARIO=session_work NTM_MOCK_REPO="$repo_path"
                export NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt"
                export NTM_MOCK_ARGS_LOG="$env_root/ntm.args" AGENT_SWEEP_SECRET_SCAN=block
                export RU_TEST_GATE_ROOT="$env_root" RU_TEST_GATE_MODE="$mode"
                [[ "$mode" != timeout ]] || timeout_seconds=5
                # Quote the generated path as shell syntax, including spaces.
                printf -v command 'bash %q' "$env_root/project-test.sh"
                hash -r
                result=$(spawn_ai_session "$repo_path" "$env_root/prompt.txt" --agent=codex \
                    "--timeout=$timeout_seconds" "--$publication" "--test-command=$command" \
                    2> "$env_root/session.stderr") || rc=$?
                cat "$env_root/session.stderr" >&2
                printf '%s\n' "$result" > "$env_root/session.json"
                printf '%s\n' "$rc" > "$env_root/session.exit"
                evidence=$(jq -r '.evidence_dir' <<< "$result")
                candidate=$(jq -r '.work.after_head' <<< "$result")
                assert_equals "$rc" "$(jq -r '.exit_code' <<< "$result")" "$publication/$mode retains actual session exit"
                assert_success "$publication/$mode has a consistent common contract" validate_ai_session_result "$result" "$rc" "$repo_path" "$command"
                assert_file_exists "$env_root/test.pid" "$publication/$mode executes the real test command"
                assert_equals "$candidate" "$(cat "$env_root/tested.head")" "$publication/$mode tests the pre-publication candidate"
                assert_success "$publication/$mode retains complete test stdout beyond the summary limit" cmp "$env_root/expected.stdout" "$evidence/test.stdout"
                assert_success "$publication/$mode retains complete test stderr beyond the summary limit" cmp "$env_root/expected.stderr" "$evidence/test.stderr"
                if [[ "$mode" == success ]]; then
                    assert_equals 0 "$rc" "$publication permits a passing stable real test"
                    assert_equals success "$(jq -r '.tests.status' <<< "$result")" "$publication test success is explicit"
                    assert_equals "$command" "$(jq -r '.tests.command' <<< "$result")" "$publication records the exact configured command"
                    assert_equals "$candidate" "$(jq -r '.tests.verified_head' <<< "$result")" "$publication binds passing tests to the exact candidate"
                    if [[ "$publication" == push ]]; then
                        assert_equals "$candidate" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Receiver gets the actual tested candidate"
                        assert_file_exists "$env_root/received-updates" "Real receiver hook verified test completion before push"
                        assert_equals yes "$(cat "$env_root/receiver-saw-tests")" "Real receiver observes completed tests before receiving candidate"
                    else
                        assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Passing no-push preserves the actual receiver"
                        assert_file_not_exists "$env_root/received-updates" "Passing no-push never enters receiver hook"
                    fi
                else
                    assert_not_equals 0 "$rc" "$publication/$mode blocks session success"
                    assert_not_equals success "$(jq -r '.status' <<< "$result")" "$publication/$mode never reports success"
                    assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "$publication/$mode preserves the real receiver"
                    assert_file_not_exists "$env_root/received-updates" "$publication/$mode never attempts publication"
                    case "$mode" in
                        failed) assert_equals 7 "$(jq -r '.tests.exit_code' <<< "$result")" "Actual test exit 7 survives the workflow" ;;
                        dirty)
                            assert_equals false "$(jq -r '.tests.work_unchanged' <<< "$result")" "Dirty test output is detected"
                            assert_contains "$(cat "$repo_path/planned.txt")" 'test left changed bytes' "Dirty test work is preserved"
                            ;;
                        changed-head|changed-branch)
                            assert_equals false "$(jq -r '.tests.work_unchanged' <<< "$result")" "$mode is detected even when Git is clean"
                            ;;
                        timeout)
                            assert_equals timeout "$(jq -r '.status' <<< "$result")" "Test command shares the original operation deadline"
                            assert_equals tests "$(jq -r '.deadline.phase' <<< "$result")" "Deadline retains the test phase"
                            test_pid=$(cat "$env_root/test.pid")
                            assert_success "Expired test process actually stopped" ai_deadline_process_stopped "$test_pid"
                            test_pid=$(cat "$env_root/test-child.pid")
                            assert_success "Expired test child actually stopped" ai_deadline_process_stopped "$test_pid"
                            assert_file_not_exists "$env_root/test.finished" "Delayed test cannot finish after timeout"
                            ;;
                    esac
                fi
                exit "$(get_exit_code)"
            ) || ((failed_scenarios+=1))
        done
    done
    [[ "$failed_scenarios" -eq 0 ]]
}

# Structural controls use actual Git work but deliberately altered reports;
# execution proof belongs to test_ai_project_tests_before_publication above.
test_ai_required_test_result_contract() {
    local retained_root="${1:-}" repo_path env_root before work base tested malformed expression result rc command
    repo_path=$(create_ai_work_fixture "$retained_root") || return 1
    env_root=${repo_path%/*}
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    printf 'actual work for test-result controls\n' >> "$repo_path/base.txt"
    git -C "$repo_path" add -- base.txt && git -C "$repo_path" commit -qm 'Test-result controls' || return 1
    work=$(capture_ai_session_work "$repo_path" "$before" refs/heads/main "$env_root/artifacts") || return 1
    base=$(jq -cn --arg repo "$repo_path" --argjson work "$work" \
        '{schema_version:1,repo:$repo,status:"success",exit_code:0,transport:{status:"idle"},
          work:$work,publication:{no_push:true,status:"not_requested"}}') || return 1
    command='printf configured-test'
    assert_success "Legacy session without requested tests remains compatible" validate_ai_session_result "$base" 0 "$repo_path"
    assert_fails "Expected command rejects a success record with no tests" validate_ai_session_result "$base" 0 "$repo_path" "$command"
    tested=$(jq -c --arg command "$command" '.tests={required:true,status:"success",command:$command,
        ran:true,ok:true,exit_code:0,work_unchanged:true,verified_head:.work.after_head}' <<< "$base") || return 1
    for expression in '.tests.required=false' '.tests.required="true"' '.tests.command="wrong command"' \
        '.tests.command="   "' '.tests.ran=false' '.tests.ran="true"' '.tests.ok=false' '.tests.exit_code=7' \
        '.tests.work_unchanged=false' '.tests.verified_head="different-candidate"' '.tests.status="incomplete"' '.tests=null'; do
        malformed=$(jq -c "$expression" <<< "$tested") || return 1
        assert_fails "Expected-command validation rejects $expression" validate_ai_session_result "$malformed" 0 "$repo_path" "$command"
        assert_success "Unaltered required-test contract remains accepted" validate_ai_session_result "$tested" 0 "$repo_path" "$command"
    done
    mkdir "$env_root/retained-gate" || return 1
    result=$(run_test_gate "$repo_path" 'printf stdout; printf stderr >&2; exit 7' 5 "$env_root/retained-gate"); rc=$?
    assert_equals 7 "$rc" "Retained gate preserves actual failing command exit"
    assert_equals true "$(jq -r '.ran' <<< "$result")" "Failing command actually ran"
    assert_equals false "$(jq -r '.ok' <<< "$result")" "Failing command cannot claim ok"
    assert_equals stdout "$(cat "$env_root/retained-gate/test.stdout")" "Failing command retains exact stdout"
    assert_equals stderr "$(cat "$env_root/retained-gate/test.stderr")" "Failing command retains exact stderr"
    printf -v command 'printf unexpected > %q' "$env_root/unexpected-run"
    result=$(run_test_gate "$repo_path" "$command" 5 "$env_root/retained-gate"); rc=$?
    assert_equals 2 "$rc" "Existing artifacts block execution"
    assert_equals false "$(jq -r '.ran' <<< "$result")" "Artifact collision never reports a run"
    assert_equals stdout "$(cat "$env_root/retained-gate/test.stdout")" "Collision preserves prior stdout"
    assert_file_not_exists "$env_root/unexpected-run" "Collision prevents command execution"
    result=$(run_test_gate "$repo_path" "$command" 5 "$env_root/missing-artifact-dir"); rc=$?
    assert_equals 2 "$rc" "Artifact open failure blocks execution"
    assert_equals false "$(jq -r '.ran' <<< "$result")" "Artifact open failure never reports a run"
    assert_file_not_exists "$env_root/unexpected-run" "Artifact open failure prevents command execution"
    result=$(run_test_gate "$repo_path" 'printf legacy-output' 5); rc=$?
    assert_equals 0 "$rc" "Legacy standalone gate still runs a real passing command"
    assert_equals true "$(jq -r '.ran and .ok and (.exit_code == 0)' <<< "$result")" "Legacy standalone gate retains its result contract"
}

# Each deadline probe uses real Git work and a real clock. Only the named NTM
# endpoint or actual Git hook is delayed; no fabricated completion envelope is
# used as proof that the work, publication, or owned-session cleanup finished.
ai_deadline_process_stopped() {
    local observed_state
    observed_state=$(ps -p "$1" -o stat=) || observed_state=""
    [[ -z "$observed_state" || "$observed_state" == Z* ]]
}

assert_ai_whole_deadline() {
    local stage="$1" delay="$2" expected="$3" repo_path env_root before after result evidence rc=0 started elapsed timeout=5
    [[ "$stage" != publication && "$stage" != inspection ]] || timeout=10
    repo_path=$(create_ai_work_fixture) || return 1
    env_root=${repo_path%/*}
    create_controlled_ai_bin "$env_root/mock-bin" || return 1
    printf 'deadline requested bytes\n' > "$repo_path/planned.txt"
    printf 'Commit the deadline fixture requested bytes\n' > "$env_root/prompt.txt"
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    if [[ "$stage" == publication ]]; then
        git clone -q --bare "$repo_path" "$env_root/receiver.git" || return 1
        git -C "$repo_path" remote add origin "$env_root/receiver.git" || return 1
        cat > "$env_root/receiver.git/hooks/pre-receive" <<'RECEIVER'
#!/usr/bin/env bash
set -uo pipefail
git_dir=$(git rev-parse --absolute-git-dir) || exit 1
cat >> "$git_dir/received-updates"
printf 'publication %s %s\n' "$BASHPID" "$NTM_MOCK_DELAY_SECONDS" >> "$NTM_MOCK_DELAY_LOG"
sleep "$NTM_MOCK_DELAY_SECONDS"
RECEIVER
        chmod +x "$env_root/receiver.git/hooks/pre-receive" || return 1
    elif [[ "$stage" == inspection ]]; then
        cat > "$env_root/fsmonitor" <<'FSMONITOR'
#!/usr/bin/env bash
# A real Git fsmonitor hook stalls actual candidate inspection after the commit.
set -uo pipefail
printf 'inspection %s %s\n' "$BASHPID" "$NTM_MOCK_DELAY_SECONDS" >> "$NTM_MOCK_DELAY_LOG"
sleep "$NTM_MOCK_DELAY_SECONDS"
printf 'deadline-fixture-token\0/\0'
FSMONITOR
        chmod +x "$env_root/fsmonitor" || return 1
    fi
    (
        export PATH="$env_root/mock-bin:$PATH" NTM_MOCK_SCENARIO=session_work NTM_MOCK_REPO="$repo_path"
        export NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt"
        export NTM_MOCK_ARGS_LOG="$env_root/ntm.args" NTM_MOCK_DELAY_LOG="$env_root/delay.log"
        export NTM_MOCK_DELAY_STAGE="$stage" NTM_MOCK_DELAY_SECONDS="$delay" AGENT_SWEEP_SECRET_SCAN=block
        if [[ "$stage" == readiness,send,transition && "$expected" == timeout ]]; then
            export NTM_MOCK_TRANSITION_DELAY_SECONDS=4.95
        fi
        [[ "$stage" != inspection ]] || export NTM_MOCK_FSMONITOR_HOOK="$env_root/fsmonitor"
        local -a publication_flags=(--no-push)
        [[ "$stage" != publication ]] || publication_flags=(--push)
        hash -r
        started=$(date +%s)
        result=$(spawn_ai_session "$repo_path" "$env_root/prompt.txt" --agent=codex --timeout="$timeout" "${publication_flags[@]}") || rc=$?
        elapsed=$(($(date +%s) - started))
        printf '%s\n' "$result" > "$env_root/result.json"
        printf '%s\n' "$rc" > "$env_root/result.exit"
        printf '%s\n' "$elapsed" > "$env_root/elapsed.seconds"
        evidence=$(jq -r '.evidence_dir' <<< "$result")
        after=$(git -c core.fsmonitor=false -C "$repo_path" rev-parse HEAD)
        assert_success "Delayed $stage result matches its actual process exit" validate_ai_session_result "$result" "$rc" "$repo_path"
        assert_equals "$before" "$(jq -r '.work.before_head' <<< "$result")" "Deadline result preserves captured original full Git identity"
        assert_equals refs/heads/main "$(jq -r '.work.before_ref' <<< "$result")" "Deadline result preserves the original actual branch"
        assert_file_exists "$evidence/prompt.txt" "Deadline preserves the exact delivered request artifact"
        assert_contains "$(cat "$evidence/prompt.txt")" 'deadline fixture requested bytes' "Preserved request includes the fixture request"
        assert_file_exists "$env_root/delay.log" "Named delay was actually entered"
        if [[ "$expected" == timeout ]]; then
            assert_equals 1 "$rc" "A whole-operation deadline returns nonzero"
            assert_equals timeout "$(jq -r '.status' <<< "$result")" "Deadline keeps typed overall timeout"
            assert_equals timeout "$(jq -r '.transport.status' <<< "$result")" "Deadline keeps typed transport timeout"
            assert_equals 124 "$(jq -r '.transport.exit_code' <<< "$result")" "Deadline retains the actual watchdog exit"
            assert_equals true "$(jq -r '.deadline.expired' <<< "$result")" "One operation deadline is recorded as expired"
            if [[ "$stage" == *,* ]]; then
                assert_equals transition "$(jq -r '.deadline.phase' <<< "$result")" "Aggregate delays exhaust the one budget during transition"
            else
                assert_equals "$stage" "$(jq -r '.deadline.phase' <<< "$result")" "Timeout names the actual interrupted stage"
            fi
            assert_equals failed "$(jq -r '.work.status' <<< "$result")" "Interrupted operation cannot claim completed work"
            assert_equals false "$(jq -r '.work.verified' <<< "$result")" "Interrupted work is explicitly unverified"
            assert_success "Operation deadline plus bounded cleanup and termination grace is honored" test "$elapsed" -le "$((timeout + 4))"
            local recorded_stage process_pid delayed_seconds
            while read -r recorded_stage process_pid delayed_seconds; do
                assert_success "Interrupted owned $recorded_stage process is no longer running" ai_deadline_process_stopped "$process_pid"
            done < "$env_root/delay.log"
            if [[ "$stage" == readiness,send,transition ]]; then
                assert_contains "$(cat "$env_root/delay.log")" 'readiness ' "Shared budget includes the actual readiness delay"
                assert_contains "$(cat "$env_root/delay.log")" 'send ' "Shared budget includes the actual send delay"
                assert_contains "$(cat "$env_root/delay.log")" 'transition ' "A transition delay shorter than five seconds still exhausts the shared five-second budget"
            fi
            if [[ "$stage" == stop ]]; then
                assert_equals timeout "$(jq -r '.cleanup.status' <<< "$result")" "Unfinished bounded cleanup remains uncertain"
                assert_equals 124 "$(jq -r '.cleanup.exit_code' <<< "$result")" "Cleanup retains its independent timeout exit"
                assert_contains "$(jq -r '.error' <<< "$result")" 'cleanup remains uncertain' "Result does not conceal cleanup uncertainty"
                assert_file_not_exists "$env_root/ntm.state.stopped" "Timed-out stop cannot create a false completed stop marker"
            else
                assert_equals confirmed "$(jq -r '.cleanup.status' <<< "$result")" "Only this owned session is stopped and its absence is confirmed"
                assert_equals "$(jq -r '.session' <<< "$result")" "$(cat "$env_root/ntm.state.stopped")" "Cleanup targeted the exact unique owned session"
            fi
            case "$stage" in
                inspection)
                    assert_equals "$after" "$(jq -r '.work.after_head' <<< "$result")" "Interrupted Git inspection keeps captured actual candidate identity"
                    assert_equals "$after" "$(jq -r '.work.commits[0]' <<< "$result")" "Interrupted Git inspection preserves actual captured commit inventory"
                    ;;
                publication)
                    assert_equals uncertain "$(jq -r '.publication.status' <<< "$result")" "An interrupted actual push preserves publication uncertainty"
                    assert_equals success "$(jq -r '.work.observed_status' <<< "$result")" "Prior verified local work observation remains available"
                    assert_equals "$after" "$(jq -r '.work.after_head' <<< "$result")" "Interrupted publication preserves the actual local candidate"
                    assert_file_exists "$env_root/receiver.git/received-updates" "Delayed real receiver hook was actually invoked"
                    assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Controlled receiver has not published the interrupted candidate"
                    ;;
            esac
        else
            assert_equals 0 "$rc" "Near-identical bounded $stage control succeeds"
            assert_equals success "$(jq -r '.status' <<< "$result")" "Completed bounded control has actual-work success"
            assert_equals false "$(jq -r '.deadline.expired' <<< "$result")" "Completed control did not exhaust the same budget"
            assert_equals confirmed "$(jq -r '.cleanup.status' <<< "$result")" "Completed control confirms owned session cleanup"
            assert_equals "$after" "$(jq -r '.work.after_head' <<< "$result")" "Completed control binds the real candidate identity"
            if [[ "$stage" == publication ]]; then
                assert_equals success "$(jq -r '.publication.status' <<< "$result")" "Bounded real publication succeeds"
                assert_equals "$after" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Real receiver contains the exact full candidate SHA"
            fi
        fi
        case "$stage" in
            tail|stop|inspection|publication)
                assert_not_equals "$before" "$after" "Late interruption retains the actual created commit"
                assert_equals 'deadline requested bytes' "$(git -c core.fsmonitor=false -C "$repo_path" show HEAD:planned.txt)" "Actual committed requested bytes remain intact"
                ;;
            *)
                if [[ "$expected" == timeout ]]; then
                    assert_equals "$before" "$after" "Early deadline preserves the original actual HEAD"
                    assert_equals 'deadline requested bytes' "$(cat "$repo_path/planned.txt")" "Early deadline preserves requested uncommitted bytes"
                else
                    assert_not_equals "$before" "$after" "Bounded control produces an actual commit"
                fi
                ;;
        esac
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Real Git $stage/$expected deadline discriminators pass"
}

test_ai_whole_deadline_transport_stages() {
    local stage
    for stage in spawn readiness send transition tail; do
        assert_ai_whole_deadline "$stage" 8 timeout
        assert_ai_whole_deadline "$stage" 0.05 success
    done
}

test_ai_whole_deadline_cleanup_uncertainty() {
    assert_ai_whole_deadline stop 8 timeout
    assert_ai_whole_deadline stop 0.05 success
}

test_ai_whole_deadline_real_git_inspection() {
    assert_ai_whole_deadline inspection 20 timeout
    assert_ai_whole_deadline inspection 0.05 success
}

test_ai_whole_deadline_real_host_publication() {
    assert_ai_whole_deadline publication 20 timeout
    assert_ai_whole_deadline publication 0.05 success
}

test_ai_whole_deadline_is_one_shared_budget() {
    assert_ai_whole_deadline readiness,send,transition 0.05 timeout
    assert_ai_whole_deadline readiness,send,transition 0.05 success
}

test_ai_whole_deadline_process_group_ownership() {
    local env_root rc=0 unrelated_pid deadline
    env_root=$(create_test_env) || return 1
    sleep 30 &
    unrelated_pid=$!
    deadline=$((SECONDS + 1))
    run_inherited_ai_deadline "$deadline" "$env_root/worker.stdout" "$env_root/worker.stderr" sleep 8 || rc=$?
    assert_equals 124 "$rc" "Inherited worker is terminated by its own deadline"
    assert_success "Deadline does not signal an unrelated caller-owned process" kill -0 "$unrelated_pid"
    kill -TERM "$unrelated_pid" || true
    wait "$unrelated_pid" || true
    rc=0
    run_inherited_ai_deadline "$SECONDS" "$env_root/expired.stdout" "$env_root/expired.stderr" touch "$env_root/should-not-start" || rc=$?
    assert_equals 124 "$rc" "Already expired operation cannot start a new worker"
    assert_file_not_exists "$env_root/should-not-start" "Expired budget prevents new workflow side effects"
    assert_success "Near-identical owned worker finishes within budget" run_inherited_ai_deadline "$((SECONDS + 3))" "$env_root/control.stdout" "$env_root/control.stderr" sleep 0.05
}

assert_ai_preflight_common_failure() {
    local mode="$1" repo_path env_root prompt expected_repo expected_error expected_agent=codex expected_exit=2
    local before index_before result rc=0 ordinary_path restricted_path tool parser expected_no_push=true expected_publication=not_requested control_timeout=5
    repo_path=$(create_ai_work_fixture) || return 1
    env_root=${repo_path%/*}
    create_controlled_ai_bin "$env_root/mock-bin" || return 1
    prompt="$env_root/"$'request "quote"\n\\file.txt'
    printf 'Perform the requested preflight fixture work\n' > "$prompt"
    printf 'actual preflight control bytes\n' > "$repo_path/planned.txt"
    expected_repo="$repo_path"
    ordinary_path="$env_root/mock-bin:$PATH"
    restricted_path="$env_root/restricted-bin"
    parser=$(command -v jq) || return 1
    local -a request=("$repo_path" "$prompt" --agent=codex --timeout=5 --no-push)
    case "$mode" in
        missing_repo)
            request=(--agent=codex --no-push); expected_repo=""; expected_error='repo_path required' ;;
        absent_repo)
            expected_repo="$env_root/"$'absent "repo"\n\\path'
            request=("$expected_repo" "$prompt" --agent=codex --no-push)
            expected_error="repo not found: $expected_repo" ;;
        missing_prompt)
            request=("$repo_path" --agent=codex --no-push); expected_error='prompt_file required' ;;
        absent_prompt)
            request=("$repo_path" "$env_root/"$'absent "prompt"\n\\file' --agent=codex --no-push)
            expected_error="prompt file not found: ${request[1]}" ;;
        invalid_timeout)
            request=("$repo_path" "$prompt" --agent=codex --timeout=0 --no-push)
            expected_exit=4; expected_error='invalid timeout' ;;
        invalid_timeout_push)
            request=("$repo_path" "$prompt" --agent=codex --push --timeout=0)
            expected_exit=4; expected_error='invalid timeout'; expected_no_push=false; expected_publication=blocked; control_timeout=10
            git clone -q --bare "$repo_path" "$env_root/receiver.git" || return 1
            git -C "$repo_path" remote add origin "$env_root/receiver.git" || return 1
            ;;
        invalid_agent)
            expected_agent=$'unknown "agent"\n\\name'
            request=("$repo_path" "$prompt" "--agent=$expected_agent" --no-push)
            expected_error="unknown agent type: $expected_agent" ;;
        unknown_option)
            request+=( $'--unknown="option"\n\\value' )
            expected_error="Unknown option: ${request[5]}" ;;
        unsupported_name)
            expected_repo="$env_root/repo--unsupported"
            git clone -q "$repo_path" "$expected_repo" || return 1
            request=("$expected_repo" "$prompt" --agent=codex --no-push)
            expected_exit=4; expected_error='unsupported NTM project name' ;;
        missing_jq|missing_tmux|missing_ntm|missing_provider|no_jq_escaped)
            mkdir -p "$restricted_path" || return 1
            for tool in jq mktemp; do
                if [[ "$tool" == jq && ( "$mode" == missing_jq || "$mode" == no_jq_escaped ) ]]; then continue; fi
                ln -s "$(command -v "$tool")" "$restricted_path/$tool" || return 1
            done
            for tool in ntm tmux codex; do
                if [[ "$mode" == missing_ntm && "$tool" == ntm ]] || [[ "$mode" == missing_tmux && "$tool" == tmux ]] || [[ "$mode" == missing_provider && "$tool" == codex ]]; then continue; fi
                ln -s "$env_root/mock-bin/$tool" "$restricted_path/$tool" || return 1
            done
            case "$mode" in
                missing_jq) expected_exit=3; expected_error='missing dependency: jq' ;;
                missing_tmux) expected_exit=3; expected_error='missing dependency: tmux' ;;
                missing_ntm) expected_error='ntm not installed' ;;
                missing_provider) expected_exit=3; expected_error='missing provider: codex' ;;
                no_jq_escaped)
                    expected_repo="$env_root/"$'absent "repo"\n\\path'
                    request=("$expected_repo" "$prompt" --agent=codex --no-push $'--unknown="option"\n\\value')
                    expected_error="Unknown option: ${request[4]}"
                    ;;
            esac
            ;;
    esac
    before=$(git -C "$repo_path" rev-parse HEAD) || return 1
    index_before=$(git hash-object "$repo_path/.git/index") || return 1
    (
        export PATH="$ordinary_path" NTM_MOCK_SCENARIO=session_work NTM_MOCK_REPO="$repo_path"
        export NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt" NTM_MOCK_ARGS_LOG="$env_root/ntm.args"
        case "$mode" in missing_jq|missing_tmux|missing_ntm|missing_provider|no_jq_escaped) export PATH="$restricted_path" ;; esac
        hash -r
        result=$(spawn_ai_session "${request[@]}" 2> "$env_root/preflight.stderr") || rc=$?
        export PATH="$ordinary_path"
        hash -r
        cat "$env_root/preflight.stderr" >&2
        printf '%s\n' "$result" > "$env_root/preflight.json"
        assert_equals "$expected_exit" "$rc" "Whole-function $mode preserves actual preflight exit"
        assert_success "Whole-function $mode emits one fully typed failure contract" "$parser" -e -s --argjson actual "$rc" --argjson no_push "$expected_no_push" --arg publication "$expected_publication" '
            length == 1 and (.[0] | .schema_version == 1 and .status == "failed" and .exit_code == $actual and
            .transport.status == "failed" and .transport.exit_code == $actual and .work.status == "failed" and .work.verified == false and
            (.work.commits | type == "array" and length == 0) and (.work.remaining_paths | type == "array" and length == 0) and
            .work.remaining_paths_verified == false and .publication.no_push == $no_push and .publication.status == $publication and
            .cleanup.status == "not_started" and .deadline.phase == "preflight" and (.duration_seconds | type == "number"))' <<< "$result"
        assert_equals "$expected_repo" "$("$parser" -r '.repo' <<< "$result")" "Common preflight result preserves escaped actual repo input or physical identity"
        assert_equals "$expected_error" "$("$parser" -r '.error' <<< "$result")" "Common preflight result preserves escaped exact failure reason"
        assert_equals "$expected_agent" "$("$parser" -r '.agent' <<< "$result")" "Common preflight result preserves the actual selected agent"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Preflight refusal preserves actual Git HEAD"
        assert_equals "$index_before" "$(git hash-object "$repo_path/.git/index")" "Preflight refusal preserves exact actual Git index"
        assert_file_not_exists "$env_root/ntm.args" "Preflight refusal never invokes the controlled NTM endpoint"
        rc=0
        local -a control_flags=(--no-push)
        [[ "$expected_no_push" != false ]] || control_flags=(--push)
        result=$(spawn_ai_session "$repo_path" "$prompt" --agent=codex --timeout="$control_timeout" "${control_flags[@]}") || rc=$?
        assert_equals 0 "$rc" "Paired full-function valid $mode control succeeds"
        assert_success "Paired valid control retains the actual common result contract" validate_ai_session_result "$result" "$rc" "$repo_path"
        assert_equals 'actual preflight control bytes' "$(git -C "$repo_path" show HEAD:planned.txt)" "Paired control performs real requested Git work"
        assert_equals confirmed "$("$parser" -r '.cleanup.status' <<< "$result")" "Paired control confirms its actual owned session absence"
        if [[ "$expected_no_push" == false ]]; then
            assert_equals success "$("$parser" -r '.publication.status' <<< "$result")" "Valid requested-publication control completes actual host publication"
            assert_equals "$(git -C "$repo_path" rev-parse HEAD)" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Valid control publishes the exact actual candidate to the real receiver"
        fi
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Whole-function $mode failure and actual Git success control pass"
}

test_ai_preflight_input_failures_common_contract() {
    local mode
    for mode in missing_repo absent_repo missing_prompt absent_prompt invalid_timeout invalid_timeout_push invalid_agent unknown_option unsupported_name; do
        assert_ai_preflight_common_failure "$mode"
    done
}

test_ai_preflight_dependency_failures_common_contract() {
    local mode
    for mode in missing_jq missing_tmux missing_ntm missing_provider; do
        assert_ai_preflight_common_failure "$mode"
    done
}

test_ai_preflight_no_jq_preserves_escaped_repo_and_error() {
    assert_ai_preflight_common_failure no_jq_escaped
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
run_test test_ai_work_idle_without_commits_fails
run_test test_ai_work_real_commits_have_revision_bound_result
run_test test_ai_requested_working_version_allows_partial_staging
run_test test_ai_requested_staged_deletion_is_captured_once
run_test test_ai_requested_content_discard_fails_without_rollback
run_test test_ai_requested_final_rewrite_requires_edit_policy
run_test test_ai_requested_deletion_rename_mode_and_symlink
run_test test_ai_work_diff_inspection_error_preserves_real_state
run_test test_ai_work_empty_commits_are_incomplete
run_test test_ai_work_remaining_files_are_preserved_and_typed
run_test test_ai_work_branch_change_cannot_succeed
run_test test_ai_session_result_schema_checks_actual_exit_and_publication
run_test test_controlled_ai_transport_and_real_git_work_results
run_test test_ai_host_publication_success
run_test test_ai_host_publication_rejected
run_test test_ai_host_no_push_invokes_no_transport
run_test test_ai_project_tests_before_publication
run_test test_ai_required_test_result_contract
run_test test_ai_whole_deadline_transport_stages
run_test test_ai_whole_deadline_cleanup_uncertainty
run_test test_ai_whole_deadline_real_git_inspection
run_test test_ai_whole_deadline_real_host_publication
run_test test_ai_whole_deadline_is_one_shared_budget
run_test test_ai_whole_deadline_process_group_ownership
run_test test_ai_preflight_input_failures_common_contract
run_test test_ai_preflight_dependency_failures_common_contract
run_test test_ai_preflight_no_jq_preserves_escaped_repo_and_error

print_results
exit "$(get_exit_code)"
