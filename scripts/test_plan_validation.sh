#!/usr/bin/env bash
#
# Unit Tests: Plan Validation and Execution (bd-rwja)
#
# Test coverage:
#   - Commit plan validation: valid plans, denied files, malformed JSON,
#     shell injection attempts, path traversal
#   - Commit plan execution: successful commits, multi-commit plans
#   - Release plan validation: valid plans, duplicate tags, invalid versions,
#     length limits, changelog validation
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Source required functions from ru
#==============================================================================

# Source the denylist arrays
# shellcheck disable=SC1090
eval "$(sed -n '/^declare -a AGENT_SWEEP_DENYLIST_PATTERNS=/,/^)/p' "$PROJECT_DIR/ru")"
# Initialize the extra denylist array (normally set by load_repo_agent_config)
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()

# Source validation and execution functions
source_ru_function "validate_commit_plan"
source_ru_function "execute_commit_plan"
source_ru_function "commit_plan_stage_and_commit"
source_ru_function "validate_release_plan"
source_ru_function "execute_release_plan"
source_ru_function "get_release_strategy"
source_ru_function "has_release_workflow"

# Source helper functions
source_ru_function "json_validate"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "is_file_denied"
source_ru_function "is_file_too_large"
source_ru_function "is_binary_file"
source_ru_function "is_binary_allowed"
source_ru_function "is_positive_int"
source_ru_function "agent_sweep_is_positive_int"
source_ru_function "run_secret_scan"
source_ru_function "get_file_size_mb"
source_ru_function "capture_plan_json"

# Mock logging to keep test output clean
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

# Mock capture_plan_json for execution mode tests
capture_plan_json() { return 0; }

#==============================================================================
# Helper: Skip test if jq not available
#==============================================================================

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

#==============================================================================
# Helper: Create test git repository
#==============================================================================

create_test_repo() {
    local temp_dir
    temp_dir=$(create_temp_dir)
    local repo_path="$temp_dir/test_repo"
    mkdir -p "$repo_path"

    git -C "$repo_path" init --quiet
    git -C "$repo_path" config user.email "test@test.com"
    git -C "$repo_path" config user.name "Test User"

    echo "initial content" > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    git -C "$repo_path" commit -m "Initial commit" --quiet

    echo "$repo_path"
}

#==============================================================================
# COMMIT PLAN VALIDATION TESTS
#==============================================================================

test_commit_plan_valid_minimal() {
    log_test_start "validate_commit_plan: accepts minimal valid plan"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Create a test file
    echo "test content" > "$repo_path/test.txt"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add test file",
            "files": ["test.txt"]
        }
    ],
    "push": false
}
EOF
)

    assert_success "Valid minimal plan should pass validation" \
        validate_commit_plan "$plan" "$repo_path"
}

test_commit_plan_valid_multiple_commits() {
    log_test_start "validate_commit_plan: accepts plan with multiple commits"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Create test files
    echo "file1" > "$repo_path/file1.txt"
    echo "file2" > "$repo_path/file2.txt"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add file1",
            "files": ["file1.txt"]
        },
        {
            "message": "Add file2",
            "files": ["file2.txt"]
        }
    ],
    "push": true
}
EOF
)

    assert_success "Plan with multiple commits should pass" \
        validate_commit_plan "$plan" "$repo_path"
}

test_commit_plan_rejects_empty() {
    log_test_start "validate_commit_plan: rejects empty plan"

    local repo_path
    repo_path=$(create_test_repo)

    assert_fails "Empty plan should be rejected" \
        validate_commit_plan "" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "empty" "Error should mention empty"
}

test_commit_plan_rejects_invalid_json() {
    log_test_start "validate_commit_plan: rejects invalid JSON"

    local repo_path
    repo_path=$(create_test_repo)

    assert_fails "Invalid JSON should be rejected" \
        validate_commit_plan "{not valid json}" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "Invalid JSON" "Error should mention invalid JSON"
}

test_commit_plan_rejects_missing_commits() {
    log_test_start "validate_commit_plan: rejects plan with missing commits array"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    assert_fails "Plan without commits should be rejected" \
        validate_commit_plan '{"push": true}' "$repo_path"

    assert_contains "$VALIDATION_ERROR" "commits" "Error should mention commits"
}

test_commit_plan_rejects_empty_commits() {
    log_test_start "validate_commit_plan: rejects plan with empty commits array"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    assert_fails "Plan with empty commits should be rejected" \
        validate_commit_plan '{"commits": [], "push": false}' "$repo_path"

    assert_contains "$VALIDATION_ERROR" "commits" "Error should mention commits"
}

test_commit_plan_rejects_missing_message() {
    log_test_start "validate_commit_plan: rejects commit without message"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "test" > "$repo_path/test.txt"

    assert_fails "Commit without message should be rejected" \
        validate_commit_plan '{"commits": [{"files": ["test.txt"]}], "push": false}' "$repo_path"

    assert_contains "$VALIDATION_ERROR" "message" "Error should mention message"
}

test_commit_plan_rejects_missing_files() {
    log_test_start "validate_commit_plan: rejects commit without files"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    assert_fails "Commit without files should be rejected" \
        validate_commit_plan '{"commits": [{"message": "Test"}], "push": false}' "$repo_path"

    assert_contains "$VALIDATION_ERROR" "files" "Error should mention files"
}

test_commit_plan_rejects_denied_env_file() {
    log_test_start "validate_commit_plan: rejects .env file"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "SECRET=value" > "$repo_path/.env"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add env file",
            "files": [".env"]
        }
    ],
    "push": false
}
EOF
)

    assert_fails "Plan with .env should be rejected" \
        validate_commit_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "Denied" "Error should mention denied file"
}

test_commit_plan_rejects_denied_key_file() {
    log_test_start "validate_commit_plan: rejects private key files"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "fake key" > "$repo_path/id_rsa"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add key file",
            "files": ["id_rsa"]
        }
    ],
    "push": false
}
EOF
)

    assert_fails "Plan with id_rsa should be rejected" \
        validate_commit_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "Denied" "Error should mention denied file"
}

test_commit_plan_rejects_path_traversal() {
    log_test_start "validate_commit_plan: rejects path traversal attempts"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Path traversal",
            "files": ["../../../etc/passwd"]
        }
    ],
    "push": false
}
EOF
)

    assert_fails "Path traversal should be rejected" \
        validate_commit_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe path"
}

test_commit_plan_rejects_absolute_path() {
    log_test_start "validate_commit_plan: rejects absolute paths"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Absolute path",
            "files": ["/etc/passwd"]
        }
    ],
    "push": false
}
EOF
)

    assert_fails "Absolute path should be rejected" \
        validate_commit_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "absolute" "Error should mention absolute path"
}

#==============================================================================
# COMMIT PLAN EXECUTION TESTS
#==============================================================================

test_commit_execution_single_file() {
    log_test_start "execute_commit_plan: creates commit with single file"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "new content" > "$repo_path/newfile.txt"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add newfile",
            "files": ["newfile.txt"]
        }
    ],
    "push": false
}
EOF
)

    assert_success "Single file commit should succeed" \
        execute_commit_plan "$plan" "$repo_path"

    # Verify commit was created
    local commit_msg
    commit_msg=$(git -C "$repo_path" log -1 --format='%s')
    assert_equals "Add newfile" "$commit_msg" "Commit message should match"
}

test_commit_execution_multiple_commits() {
    log_test_start "execute_commit_plan: creates multiple commits in order"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "file a" > "$repo_path/a.txt"
    echo "file b" > "$repo_path/b.txt"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "First commit",
            "files": ["a.txt"]
        },
        {
            "message": "Second commit",
            "files": ["b.txt"]
        }
    ],
    "push": false
}
EOF
)

    assert_success "Multiple commits should succeed" \
        execute_commit_plan "$plan" "$repo_path"

    # Verify both commits exist in order
    local latest_msg second_msg
    latest_msg=$(git -C "$repo_path" log -1 --format='%s')
    second_msg=$(git -C "$repo_path" log -1 --skip=1 --format='%s')

    assert_equals "Second commit" "$latest_msg" "Latest commit should be second"
    assert_equals "First commit" "$second_msg" "Previous commit should be first"
}

test_commit_execution_file_modification() {
    log_test_start "execute_commit_plan: handles file modifications"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Modify existing file
    echo "updated content" > "$repo_path/README.md"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Update README",
            "files": ["README.md"]
        }
    ],
    "push": false
}
EOF
)

    assert_success "File modification commit should succeed" \
        execute_commit_plan "$plan" "$repo_path"

    local commit_msg
    commit_msg=$(git -C "$repo_path" log -1 --format='%s')
    assert_equals "Update README" "$commit_msg" "Commit message should match"
}

test_commit_execution_validates_first() {
    log_test_start "execute_commit_plan: validates before executing"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Plan with denied file should fail validation
    echo "secret" > "$repo_path/.env"

    local plan
    plan=$(cat <<'EOF'
{
    "commits": [
        {
            "message": "Add env",
            "files": [".env"]
        }
    ],
    "push": false
}
EOF
)

    assert_fails "Execute should fail for denied file" \
        execute_commit_plan "$plan" "$repo_path"
}

#==============================================================================
# RELEASE PLAN VALIDATION TESTS
#==============================================================================

test_release_plan_valid_minimal() {
    log_test_start "validate_release_plan: accepts minimal valid plan"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan
    plan=$(cat <<'EOF'
{
    "version": "v1.0.0",
    "tag_name": "v1.0.0",
    "title": "Release v1.0.0"
}
EOF
)

    assert_success "Valid minimal release plan should pass" \
        validate_release_plan "$plan" "$repo_path"
}

test_release_plan_valid_semver_without_v() {
    log_test_start "validate_release_plan: accepts semver without v prefix"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "1.2.3", "tag_name": "1.2.3"}'

    assert_success "Semver without v should pass" \
        validate_release_plan "$plan" "$repo_path"
}

test_release_plan_valid_prerelease() {
    log_test_start "validate_release_plan: accepts prerelease versions"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "v2.0.0-beta.1", "tag_name": "v2.0.0-beta.1"}'

    assert_success "Prerelease version should pass" \
        validate_release_plan "$plan" "$repo_path"
}

test_release_plan_rejects_invalid_version() {
    log_test_start "validate_release_plan: rejects invalid version format"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "not-semver", "tag_name": "not-semver"}'

    assert_fails "Invalid version should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "version" "Error should mention version"
}

test_release_plan_rejects_missing_version() {
    log_test_start "validate_release_plan: rejects missing version"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"tag_name": "v1.0.0"}'

    assert_fails "Missing version should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "version" "Error should mention version"
}

test_release_plan_rejects_existing_tag() {
    log_test_start "validate_release_plan: rejects existing tag"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Create an existing tag
    git -C "$repo_path" tag "v1.0.0"

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0"}'

    assert_fails "Existing tag should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "already exists" "Error should mention tag exists"
}

test_release_plan_rejects_long_title() {
    log_test_start "validate_release_plan: rejects title over 200 chars"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Generate a title > 200 chars
    local long_title
    long_title=$(printf 'A%.0s' {1..250})

    local plan
    plan=$(jq -n --arg title "$long_title" '{version: "v1.0.0", tag_name: "v1.0.0", title: $title}')

    assert_fails "Long title should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "title" "Error should mention title"
}

test_release_plan_rejects_long_body() {
    log_test_start "validate_release_plan: rejects body over 10000 chars"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Generate a body > 10000 chars
    local long_body
    long_body=$(printf 'B%.0s' {1..10500})

    local plan
    plan=$(jq -n --arg body "$long_body" '{version: "v1.0.0", tag_name: "v1.0.0", body: $body}')

    assert_fails "Long body should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "body" "Error should mention body"
}

test_release_plan_rejects_shell_metachar_in_tag() {
    log_test_start "validate_release_plan: rejects shell metacharacters in tag_name"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0;rm -rf /"}'

    assert_fails "Shell metachar in tag should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe"
}

test_release_plan_rejects_shell_metachar_in_title() {
    log_test_start "validate_release_plan: rejects shell metacharacters in title"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0", "title": "Release; echo pwned"}'

    assert_fails "Shell metachar in title should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe"
}

test_release_plan_rejects_denied_assets() {
    log_test_start "validate_release_plan: rejects denied files in assets"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    echo "key" > "$repo_path/id_rsa"

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0", "files": ["id_rsa"]}'

    assert_fails "Denied asset file should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "Denied" "Error should mention denied"
}

test_release_plan_rejects_path_traversal_in_assets() {
    log_test_start "validate_release_plan: rejects path traversal in assets"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0", "files": ["../../etc/passwd"]}'

    assert_fails "Path traversal in assets should be rejected" \
        validate_release_plan "$plan" "$repo_path"

    assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe"
}

test_release_plan_changelog_warning() {
    log_test_start "validate_release_plan: warns about missing changelog entry"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    # Create changelog without version entry
    echo "# Changelog" > "$repo_path/CHANGELOG.md"
    echo "## v0.9.0" >> "$repo_path/CHANGELOG.md"

    local plan='{"version": "v1.0.0", "tag_name": "v1.0.0", "changelog": "CHANGELOG.md"}'

    # Should pass but with warning
    validate_release_plan "$plan" "$repo_path"

    # Check warnings array
    local has_warning=false
    for warn in "${VALIDATION_WARNINGS[@]:-}"; do
        if [[ "$warn" == *"version"* ]]; then
            has_warning=true
            break
        fi
    done

    assert_true "[[ \$has_warning == true ]]" "Should warn about missing version in changelog"
}

#==============================================================================
# Run tests
#==============================================================================

setup_cleanup_trap

# Commit plan validation tests
run_test test_commit_plan_valid_minimal
run_test test_commit_plan_valid_multiple_commits
run_test test_commit_plan_rejects_empty
run_test test_commit_plan_rejects_invalid_json
run_test test_commit_plan_rejects_missing_commits
run_test test_commit_plan_rejects_empty_commits
run_test test_commit_plan_rejects_missing_message
run_test test_commit_plan_rejects_missing_files
run_test test_commit_plan_rejects_denied_env_file
run_test test_commit_plan_rejects_denied_key_file
run_test test_commit_plan_rejects_path_traversal
run_test test_commit_plan_rejects_absolute_path

# Commit plan execution tests
run_test test_commit_execution_single_file
run_test test_commit_execution_multiple_commits
run_test test_commit_execution_file_modification
run_test test_commit_execution_validates_first

# Release plan validation tests
run_test test_release_plan_valid_minimal
run_test test_release_plan_valid_semver_without_v
run_test test_release_plan_valid_prerelease
run_test test_release_plan_rejects_invalid_version
run_test test_release_plan_rejects_missing_version
run_test test_release_plan_rejects_existing_tag
run_test test_release_plan_rejects_long_title
run_test test_release_plan_rejects_long_body
run_test test_release_plan_rejects_shell_metachar_in_tag
run_test test_release_plan_rejects_shell_metachar_in_title
run_test test_release_plan_rejects_denied_assets
run_test test_release_plan_rejects_path_traversal_in_assets
run_test test_release_plan_changelog_warning

print_results
exit "$(get_exit_code)"
