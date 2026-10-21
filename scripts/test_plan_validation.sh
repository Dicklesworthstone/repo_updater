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

# Load the real source-only API, including runtime defaults and helpers. ru's
# SCRIPT_DIR describes ru itself, so restore the test's own location afterward.
test_script_dir="$SCRIPT_DIR"
test_project_dir="$PROJECT_DIR"
# shellcheck source=../ru
source "$PROJECT_DIR/ru"
SCRIPT_DIR="$test_script_dir"
PROJECT_DIR="$test_project_dir"
# Initialize the extra denylist array (normally set by load_repo_agent_config)
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()

# Keep real error diagnostics: refusal tests assert the runtime's stderr.
# Other progress output is quiet in this focused function suite.
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

# Give the Python fallback a real executable PATH without jq. No command or
# scanner is mocked; linked tools retain their normal implementations.
create_python_only_path() {
    local parent_dir="$1" tool tool_path
    mkdir -p "$parent_dir/python-only-bin"
    for tool in python3 git stat file grep mktemp mkdir head paste cat awk sed bash tr dirname date env; do
        tool_path=$(type -P "$tool") || return 1
        ln -s "$tool_path" "$parent_dir/python-only-bin/$tool" || return 1
    done
    printf '%s\n' "$parent_dir/python-only-bin"
}

# Full CLI fixtures use only isolated configured repos and real tools. The PATH
# deliberately omits external secret scanners so block-mode cases exercise the
# actual heuristic scanner, rather than a stubbed external scanner response.
create_commit_sweep_cli_fixture() {
    local env_root="$1" tool tool_path
    local repo_path="$env_root/projects/repo"
    mkdir -p "$repo_path" "$env_root/config/ru/repos.d" "$env_root/cli-bin"
    mkdir -p "$env_root/state/ru" "$env_root/cache/ru"
    printf '%s\n' 'owner/repo' > "$env_root/config/ru/repos.d/public.txt"
    git -C "$repo_path" init --quiet
    git -C "$repo_path" config user.email "test@test.com"
    git -C "$repo_path" config user.name "Test User"
    printf 'initial content\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    git -C "$repo_path" commit -q -m 'CLI fixture baseline'
    git -C "$repo_path" checkout -q -b feature/bd-sweep-fixture
    for tool in bash git jq python3 stat file grep mktemp mkdir head paste cat awk sed tr dirname date env basename sort tail ln chmod cp mv rm find touch wc sleep timeout readlink uname; do
        tool_path=$(type -P "$tool") || return 1
        ln -s "$tool_path" "$env_root/cli-bin/$tool" || return 1
    done
    printf '%s\n' "$repo_path"
}

run_commit_sweep_cli_fixture() {
    local env_root="$1" log_name="$2"
    shift 2
    env PATH="$env_root/cli-bin" CI=true RU_CHECK_UPDATES=false \
        XDG_CONFIG_HOME="$env_root/config" XDG_STATE_HOME="$env_root/state" XDG_CACHE_HOME="$env_root/cache" \
        RU_CONFIG_DIR="$env_root/config/ru" RU_STATE_DIR="$env_root/state/ru" RU_CACHE_DIR="$env_root/cache/ru" \
        RU_PROJECTS_DIR="$env_root/projects" RU_LAYOUT=flat AGENT_SWEEP_EXECUTION_MODE=agent AGENT_SWEEP_SECRET_SCAN=block \
        RU_TEST_HOOK_MARKER="$env_root/hook-marker" \
        bash "$PROJECT_DIR/ru" commit-sweep --execute --json --non-interactive "$@" \
        > "$env_root/$log_name.stdout" 2> "$env_root/$log_name.stderr"
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

test_commit_preserves_unrelated_partial_staging() {
    local repo_path plan staged_blob peer_bytes
    repo_path=$(create_test_repo)
    printf 'base\n' > "$repo_path/peer.txt"
    git -C "$repo_path" add peer.txt
    git -C "$repo_path" commit -q -m 'Peer baseline'
    printf 'staged peer bytes\n' > "$repo_path/peer.txt"
    git -C "$repo_path" add peer.txt
    staged_blob=$(git -C "$repo_path" rev-parse :peer.txt)
    printf 'unstaged peer bytes\n' >> "$repo_path/peer.txt"
    peer_bytes=$(git hash-object "$repo_path/peer.txt")
    printf 'approved content\n' > "$repo_path/planned.txt"
    printf 'synthetic credential fixture\n' > "$repo_path/.env"
    assert_success "Fixture explicitly pre-stages a denied path" git -C "$repo_path" add -f .env
    plan='{"commits":[{"message":"Approved change","files":["planned.txt"]}],"push":false}'
    assert_success "Planned commit succeeds with unrelated partial staging" execute_commit_plan "$plan" "$repo_path"
    assert_equals planned.txt "$(git -C "$repo_path" diff-tree --no-commit-id --name-only -r HEAD)" "Only approved path enters commit"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Peer staged blob survives success"
    assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Peer worktree bytes survive success"
    assert_success "Pre-staged denied file remains in peer index" git -C "$repo_path" rev-parse :.env
    assert_fails "Pre-staged denied file is absent from new commit" git -C "$repo_path" cat-file -e HEAD:.env
}

test_commit_refusal_preserves_planned_partial_staging() {
    local repo_path plan index_path index_before head_before
    repo_path=$(create_test_repo)
    printf 'partially staged\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    printf 'unstaged follow-up\n' >> "$repo_path/README.md"
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    head_before=$(git -C "$repo_path" rev-parse HEAD)
    plan='{"commits":[{"message":"Conflicting staging","files":["README.md"]}],"push":false}'
    assert_fails "Conflicting planned partial staging requires operator decision" execute_commit_plan "$plan" "$repo_path"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Refusal preserves exact index bytes"
    assert_equals "$head_before" "$(git -C "$repo_path" rev-parse HEAD)" "Refusal creates no commit"
    assert_contains "$(cat "$repo_path/README.md")" 'unstaged follow-up' "Refusal preserves unstaged work"
}

test_commit_accepts_fully_staged_planned_paths_with_worktree_group() {
    local repo_path plan staged_blob peer_blob peer_bytes before
    repo_path=$(create_test_repo)
    printf 'fully selected staged content\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    staged_blob=$(git -C "$repo_path" rev-parse :README.md)
    printf 'selected worktree-only content\n' > "$repo_path/planned.txt"
    printf 'unrelated staged content\n' > "$repo_path/peer.txt"
    git -C "$repo_path" add peer.txt
    peer_blob=$(git -C "$repo_path" rev-parse :peer.txt)
    printf 'later unrelated work\n' >> "$repo_path/peer.txt"
    peer_bytes=$(git hash-object "$repo_path/peer.txt")
    before=$(git -C "$repo_path" rev-parse HEAD)
    plan='{"commits":[{"message":"Approved full staging and worktree group","files":["README.md","planned.txt"]}],"push":false}'
    assert_success "A fully staged selected path may share a group with a worktree-only path" execute_commit_plan "$plan" "$repo_path"
    assert_not_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Valid full-staging control creates an actual commit"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse HEAD:README.md)" "Selected fully staged content reaches the exact candidate"
    assert_equals 'selected worktree-only content' "$(git -C "$repo_path" show HEAD:planned.txt)" "The other selected path uses worktree content"
    assert_success "Both selected index entries are reconciled" git -C "$repo_path" diff --cached --quiet -- README.md planned.txt
    assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Full-staging positive preserves unrelated staged content"
    assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Full-staging positive preserves unrelated worktree bytes"
    assert_fails "Unselected staged path is absent from the candidate" git -C "$repo_path" cat-file -e HEAD:peer.txt
}

test_commit_preserves_unusual_names_and_deletions() {
    local repo_path plan name backup_path
    repo_path=$(create_test_repo)
    name=$' leading name\twith\nnewline.txt '
    printf 'literal path content\n' > "$repo_path/$name"
    backup_path="${repo_path%/*}/preserved-readme"
    mv "$repo_path/README.md" "$backup_path"
    plan=$(jq -n --arg file "$name" '{commits:[{message:"Literal names and deletion",files:[$file,"README.md"]}],push:false}')
    assert_success "Literal whitespace names and tracked deletion commit" execute_commit_plan "$plan" "$repo_path"
    assert_equals 'literal path content' "$(git -C "$repo_path" show "HEAD:$name")" "Candidate preserves complete unusual filename"
    assert_fails "Tracked deletion reaches the commit" git -C "$repo_path" cat-file -e HEAD:README.md
    assert_file_exists "$backup_path" "Deleted fixture bytes remain preserved outside checkout"
}

test_commit_rejects_hook_candidate_changes() {
    local repo_path plan hooks_dir head_before index_path index_before
    repo_path=$(create_test_repo)
    hooks_dir="${repo_path%/*}/project-hooks"
    mkdir "$hooks_dir"
    git -C "$repo_path" config core.hooksPath "$hooks_dir"
    cat > "$hooks_dir/pre-commit" <<'HOOK'
#!/usr/bin/env bash
printf 'unapproved hook content\n' > unplanned.txt
git add unplanned.txt
HOOK
    chmod +x "$hooks_dir/pre-commit"
    printf 'approved content\n' > "$repo_path/planned.txt"
    head_before=$(git -C "$repo_path" rev-parse HEAD)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    plan='{"commits":[{"message":"Guarded candidate","files":["planned.txt"]}],"push":false}'
    assert_fails "Hook-added unplanned content cannot enter any new commit" execute_commit_plan "$plan" "$repo_path"
    assert_equals "$head_before" "$(git -C "$repo_path" rev-parse HEAD)" "Hook refusal creates no commit"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Hook refusal preserves peer index bytes"
    assert_file_exists "$repo_path/unplanned.txt" "Hook-created work is preserved for inspection"
    cat > "$hooks_dir/pre-commit" <<'HOOK'
#!/usr/bin/env bash
printf 'hook was run\n' > hook-marker
HOOK
    assert_success "Normal unchanged-candidate project hook remains enabled" execute_commit_plan "$plan" "$repo_path"
    assert_file_exists "$repo_path/hook-marker" "Original project pre-commit hook actually ran"
    assert_equals planned.txt "$(git -C "$repo_path" diff-tree --no-commit-id --name-only -r HEAD)" "Permitted hook keeps exact planned commit"
}

test_commit_blocks_untracked_secret_candidate() {
    local repo_path plan before index_path index_before
    repo_path=$(create_test_repo)
    printf 'password = "synthetic-test-value"\n' > "$repo_path/planned.txt"
    before=$(git -C "$repo_path" rev-parse HEAD)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    plan='{"commits":[{"message":"Secret candidate","files":["planned.txt"]}],"push":false}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        assert_fails "Block mode detects an untracked candidate secret before commit" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Secret refusal creates no commit"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Secret refusal preserves exact peer index bytes"
        printf 'harmless replacement\n' > "$repo_path/planned.txt"
        assert_success "Paired clean candidate proceeds in block mode" execute_commit_plan "$plan" "$repo_path"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Heuristic block has both refusal and positive execution"
}

test_commit_blocks_unknown_scanner_outcomes() {
    local repo_path plan before scanner_code
    repo_path=$(create_test_repo)
    printf 'clean candidate\n' > "$repo_path/planned.txt"
    before=$(git -C "$repo_path" rev-parse HEAD)
    plan='{"commits":[{"message":"Scanner checked","files":["planned.txt"]}],"push":false}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        gitleaks() { return "$scanner_code"; }
        for scanner_code in 1 2 42 124 127; do
            assert_fails "Block mode stops scanner outcome $scanner_code" execute_commit_plan "$plan" "$repo_path"
            assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Unknown scanner outcome creates no commit"
        done
        scanner_code=0
        assert_success "Actual clean scanner success permits the candidate" execute_commit_plan "$plan" "$repo_path"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "External scanner failures and positive success retain real Git checks"
}

test_candidate_change_revokes_validation() {
    local repo_path plan before index_path index_before
    repo_path=$(create_test_repo)
    printf 'initial approved bytes\n' > "$repo_path/planned.txt"
    before=$(git -C "$repo_path" rev-parse HEAD)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    plan='{"commits":[{"message":"Immutable candidate","files":["planned.txt"]}],"push":false}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        gitleaks() { printf 'changed during scan\n' > "$repo_path/planned.txt"; return 0; }
        assert_fails "Scanner-time candidate change revokes validation" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Changed candidate creates no commit"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Changed candidate preserves exact original index"
        assert_equals 'changed during scan' "$(cat "$repo_path/planned.txt")" "Concurrent changed bytes remain preserved"
        gitleaks() { return 0; }
        assert_success "Fresh validation of stable changed bytes proceeds" execute_commit_plan "$plan" "$repo_path"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Changed-byte refusal has a fresh valid execution control"
}

test_commit_scans_removed_historical_secret_before_publication() {
    local repo_path remote_path base_sha plan
    repo_path=$(create_test_repo)
    remote_path="${repo_path%/*}/remote.git"
    git -C "$repo_path" branch -m main
    git init --bare -q "$remote_path"
    git -C "$repo_path" remote add origin "$remote_path"
    git -C "$repo_path" push -q -u origin main
    base_sha=$(git -C "$repo_path" rev-parse HEAD)
    printf 'password = "synthetic-old-secret"\n' > "$repo_path/config.txt"
    git -C "$repo_path" add config.txt
    git -C "$repo_path" commit -q -m 'Unpublished historical secret'
    printf 'clean current content\n' > "$repo_path/config.txt"
    plan='{"commits":[{"message":"Remove current secret","files":["config.txt"]}],"push":true}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        assert_fails "Secret absent from HEAD still blocks its unpublished historical commit" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$base_sha" "$(git -C "$remote_path" rev-parse main)" "Historical secret is never published"
        assert_equals 'clean current content' "$(git -C "$repo_path" show HEAD:config.txt)" "Valid local removal commit is preserved"
        assert_equals 2 "$(git -C "$repo_path" rev-list --count "$base_sha..HEAD")" "Failure preserves both unpublished commits for recovery"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Publication scans every unpublished commit"
}

test_commit_publication_targets_only_approved_branch() {
    local repo_path remote_path base_sha side_sha plan
    repo_path=$(create_test_repo)
    remote_path="${repo_path%/*}/remote.git"
    git -C "$repo_path" branch -m main
    git init --bare -q "$remote_path"
    git -C "$repo_path" remote add origin "$remote_path"
    git -C "$repo_path" push -q -u origin main
    base_sha=$(git -C "$repo_path" rev-parse HEAD)
    git -C "$repo_path" push -q origin "$base_sha:refs/heads/side"
    git -C "$repo_path" checkout -q -b side
    printf 'unrelated side work\n' > "$repo_path/side.txt"
    git -C "$repo_path" add side.txt
    git -C "$repo_path" commit -q -m 'Unrelated side commit'
    side_sha=$(git -C "$repo_path" rev-parse HEAD)
    git -C "$repo_path" checkout -q main
    git -C "$repo_path" config push.default matching
    git -C "$repo_path" config remote.origin.push refs/heads/side:refs/heads/side
    printf 'first approved candidate\n' > "$repo_path/planned.txt"
    plan='{"commits":[{"message":"Keep local","files":["planned.txt"]}],"push":false}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        assert_success "No-push plan commits locally" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$base_sha" "$(git -C "$remote_path" rev-parse main)" "No-push leaves the actual remote unchanged"
        printf 'second approved candidate\n' >> "$repo_path/planned.txt"
        plan='{"commits":[{"message":"Publish approved main","files":["planned.txt"]}],"push":true}'
        assert_success "Clean candidate publishes after scanning the full range" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$(git -C "$repo_path" rev-parse HEAD)" "$(git -C "$remote_path" rev-parse main)" "Remote receives exact validated HEAD"
        assert_equals "$base_sha" "$(git -C "$remote_path" rev-parse side)" "Matching/custom push cannot publish an unrelated branch"
        assert_equals "$side_sha" "$(git -C "$repo_path" rev-parse side)" "Unrelated local branch survives publication"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Publication preserves all unapproved refs"
}

test_publication_respects_push_remote_and_branch_selection() {
    local mode repo_path fixture_root remote selected_remote selected_ref base branch plan rc candidate
    local peer_blob peer_bytes before_head
    for mode in ordinary pushremote pushdefault topic-triangular topic-current topic-upstream topic-simple nothing invalid-remote; do
        repo_path=$(create_test_repo)
        fixture_root="${repo_path%/*}"
        git -C "$repo_path" branch -m main
        base=$(git -C "$repo_path" rev-parse HEAD)
        for remote in origin publish fork; do
            git clone --bare -q "$repo_path" "$fixture_root/$remote.git"
            git -C "$repo_path" remote add "$remote" "$fixture_root/$remote.git"
        done
        branch=main selected_remote=origin selected_ref=refs/heads/main
        if [[ "$mode" == topic-* ]]; then
            branch=topic selected_ref=refs/heads/topic
            git -C "$repo_path" checkout -qb topic
        fi
        git -C "$repo_path" config "branch.$branch.remote" origin
        git -C "$repo_path" config "branch.$branch.merge" refs/heads/main
        git -C "$repo_path" config push.default simple
        case "$mode" in
            pushremote)
                git -C "$repo_path" config remote.pushDefault publish
                git -C "$repo_path" config branch.main.pushRemote fork
                selected_remote=fork
                ;;
            pushdefault) git -C "$repo_path" config remote.pushDefault publish; selected_remote=publish ;;
            topic-triangular) git -C "$repo_path" config branch.topic.pushRemote fork; selected_remote=fork ;;
            topic-current) git -C "$repo_path" config push.default current ;;
            topic-upstream) git -C "$repo_path" config push.default upstream; selected_ref=refs/heads/main ;;
            topic-simple) selected_ref=refs/heads/main ;;
            nothing) git -C "$repo_path" config push.default nothing ;;
            invalid-remote) git -C "$repo_path" config branch.main.pushRemote not-configured ;;
        esac
        printf 'peer staged bytes\n' > "$repo_path/peer.txt"
        git -C "$repo_path" add peer.txt
        peer_blob=$(git -C "$repo_path" rev-parse :peer.txt)
        printf 'peer later unstaged bytes\n' >> "$repo_path/peer.txt"
        peer_bytes=$(git hash-object "$repo_path/peer.txt")
        printf 'selected candidate bytes\n' > "$repo_path/planned.txt"
        before_head=$(git -C "$repo_path" rev-parse HEAD)
        plan='{"commits":[{"message":"Configured publication","files":["planned.txt"]}],"push":true}'
        (
            export AGENT_SWEEP_SECRET_SCAN=block
            rc=0
            execute_commit_plan "$plan" "$repo_path" > "$fixture_root/publication.stdout" 2> "$fixture_root/publication.stderr" || rc=$?
            candidate=$(git -C "$repo_path" rev-parse HEAD)
            if [[ "$mode" == nothing || "$mode" == invalid-remote ]]; then
                assert_not_equals 0 "$rc" "Invalid publication configuration refuses before committing: $mode"
                assert_equals "$before_head" "$candidate" "Refused publication preserves the original HEAD: $mode"
            else
                assert_equals 0 "$rc" "Configured single-branch publication succeeds: $mode: $(cat "$fixture_root/publication.stderr")"
                assert_not_equals "$before_head" "$candidate" "Positive publication creates actual requested work: $mode"
                assert_equals "$candidate" "$(git -C "$fixture_root/$selected_remote.git" rev-parse "$selected_ref")" "Actual configured receiver and branch receive the candidate: $mode"
            fi
            for remote in origin publish fork; do
                if [[ "$remote" != "$selected_remote" || "$mode" == nothing || "$mode" == invalid-remote || "$selected_ref" != refs/heads/main ]]; then
                    assert_equals "$base" "$(git -C "$fixture_root/$remote.git" rev-parse refs/heads/main)" "Other receiver main remains unchanged: $mode/$remote"
                fi
            done
            assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Publication preserves peer staging: $mode"
            assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Publication preserves peer worktree bytes: $mode"
            exit "$(get_exit_code)"
        )
        assert_equals 0 "$?" "Publication configuration scenario has actual Git proof: $mode"
    done
}

test_publication_handles_duplicate_push_urls_once() {
    local repo_path remote_path base plan rc=0 hook_calls candidate
    repo_path=$(create_test_repo)
    remote_path="${repo_path%/*}/remote.git"
    hook_calls="${repo_path%/*}/push-hook-calls"
    git -C "$repo_path" branch -m main
    git clone --bare -q "$repo_path" "$remote_path"
    git -C "$repo_path" remote add origin "$remote_path"
    git -C "$repo_path" config branch.main.remote origin
    git -C "$repo_path" config branch.main.merge refs/heads/main
    git -C "$repo_path" config --add remote.origin.pushurl "$remote_path"
    git -C "$repo_path" config --add remote.origin.pushurl "$remote_path"
    base=$(git -C "$repo_path" rev-parse HEAD)
    printf 'duplicate destination candidate\n' > "$repo_path/planned.txt"
    cat > "$repo_path/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RU_TEST_PUSH_CALLS"
cat >/dev/null
HOOK
    chmod +x "$repo_path/.git/hooks/pre-push"
    plan='{"commits":[{"message":"One actual receiver","files":["planned.txt"]}],"push":true}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block RU_TEST_PUSH_CALLS="$hook_calls"
        execute_commit_plan "$plan" "$repo_path" || rc=$?
        candidate=$(git -C "$repo_path" rev-parse HEAD)
        assert_equals 0 "$rc" "Duplicate receiver entries do not report partial failure after publication"
        assert_not_equals "$base" "$candidate" "Actual candidate was created"
        assert_equals "$candidate" "$(git -C "$remote_path" rev-parse main)" "Actual receiver contains the candidate"
        assert_equals 1 "$(wc -l < "$hook_calls" | tr -d ' ')" "Original push hook observes exactly one publication"
        assert_equals 2 "$(git -C "$repo_path" config --get-all remote.origin.pushurl | wc -l | tr -d ' ')" "Original duplicate configuration remains intact"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Duplicate destination has real publication and hook evidence"
}

test_publication_scans_each_actual_push_receiver() {
    local mode env_root repo_path fetch_repo first_repo second_repo base clean_head
    local before_first peer_blob peer_bytes plan rc candidate
    for mode in secret clean multi-secret multi-clean rewrite-secret rewrite-clean pushrewrite-secret pushrewrite-clean; do
        env_root=$(create_test_env)
        repo_path=$(create_commit_sweep_cli_fixture "$env_root")
        fetch_repo="$env_root/fetch.git"
        first_repo="$env_root/first.git"
        second_repo="$env_root/second.git"
        git init --bare -q "$fetch_repo"
        git init --bare -q "$first_repo"
        git init --bare -q "$second_repo"
        git -C "$repo_path" remote add origin "$fetch_repo"
        git -C "$repo_path" push -q -u origin HEAD:refs/heads/main
        git -C "$repo_path" push -q "$first_repo" HEAD:refs/heads/main
        git -C "$repo_path" push -q "$second_repo" HEAD:refs/heads/main
        base=$(git -C "$repo_path" rev-parse HEAD)
        if [[ "$mode" == *secret ]]; then
            printf 'PASSWORD = "synthetic-not-a-credential"\n' > "$repo_path/history.txt"
        else
            printf 'harmless historical content\n' > "$repo_path/history.txt"
        fi
        git -C "$repo_path" add history.txt
        git -C "$repo_path" commit -qm 'Historical candidate'
        printf 'clean current content\n' > "$repo_path/history.txt"
        git -C "$repo_path" add history.txt
        git -C "$repo_path" commit -qm 'Clean final tree'
        clean_head=$(git -C "$repo_path" rev-parse HEAD)
        git -C "$repo_path" push -q "$fetch_repo" HEAD:refs/heads/main
        if [[ "$mode" == multi-* ]]; then
            git -C "$repo_path" push -q "$first_repo" HEAD:refs/heads/main
            git -C "$repo_path" config --add remote.origin.pushurl "$first_repo"
        fi
        case "$mode" in
            rewrite-*)
                git -C "$repo_path" config --add remote.origin.pushurl receiver://second.git
                git -C "$repo_path" config "url.$env_root/.insteadOf" receiver://
                git -C "$repo_path" config "url.$fetch_repo.insteadOf" "$second_repo"
                ;;
            pushrewrite-*)
                git -C "$repo_path" config "url.$second_repo.pushInsteadOf" "$fetch_repo"
                git -C "$repo_path" config "url.$fetch_repo.insteadOf" "$second_repo"
                ;;
            *) git -C "$repo_path" config --add remote.origin.pushurl "$second_repo" ;;
        esac
        before_first=$(git -C "$first_repo" rev-parse main)
        printf 'peer staged content\n' > "$repo_path/peer.txt"
        git -C "$repo_path" add peer.txt
        peer_blob=$(git -C "$repo_path" rev-parse :peer.txt)
        printf 'peer unstaged content\n' >> "$repo_path/peer.txt"
        peer_bytes=$(git hash-object "$repo_path/peer.txt")
        printf 'new clean planned content\n' > "$repo_path/planned.txt"
        plan='{"commits":[{"message":"Actual receiver range","files":["planned.txt"]}],"push":true}'
        (
            export PATH="$env_root/cli-bin" AGENT_SWEEP_SECRET_SCAN=block
            hash -r
            rc=0
            execute_commit_plan "$plan" "$repo_path" > "$env_root/executor.stdout" 2> "$env_root/executor.stderr" || rc=$?
            candidate=$(git -C "$repo_path" rev-parse HEAD)
            assert_not_equals "$clean_head" "$candidate" "Actual validated local candidate is retained"
            assert_equals "$clean_head" "$(git -C "$fetch_repo" rev-parse main)" "Publication never confuses the fetch-only repository with a receiver"
            if [[ "$mode" == *secret ]]; then
                assert_equals 1 "$rc" "Unpublished historical secret at a real receiver blocks publication"
                assert_equals "$base" "$(git -C "$second_repo" rev-parse main)" "Lagging receiver never receives the secret ancestor"
                assert_equals "$before_first" "$(git -C "$first_repo" rev-parse main)" "Every receiver is scanned before any receiver is changed"
            else
                assert_equals 0 "$rc" "Near-identical clean history publishes to real receivers"
                assert_equals "$candidate" "$(git -C "$second_repo" rev-parse main)" "Lagging receiver reaches the exact approved candidate"
                if [[ "$mode" == multi-* ]]; then
                    assert_equals "$candidate" "$(git -C "$first_repo" rev-parse main)" "Both actual push URLs receive the exact candidate"
                else
                    assert_equals "$base" "$(git -C "$first_repo" rev-parse main)" "Unconfigured receiver remains unchanged"
                fi
            fi
            assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Publication success and refusal preserve peer staged bytes"
            assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Publication success and refusal preserve peer worktree bytes"
            assert_fails "Unplanned peer path never enters the candidate" git -C "$repo_path" cat-file -e HEAD:peer.txt
            exit "$(get_exit_code)"
        )
        assert_equals 0 "$?" "Actual $mode receiver scenario passes its positive or refusal contract"
    done
}

test_publication_binds_advertised_tip_and_preserves_project_hook() {
    local mode env_root repo_path remote_path base clean_head plan rc candidate
    local peer_blob peer_bytes hook_args advertised_old
    for mode in rewind stable; do
        env_root=$(create_test_env)
        repo_path=$(create_commit_sweep_cli_fixture "$env_root")
        remote_path="$env_root/remote.git"
        git init --bare -q "$remote_path"
        git -C "$repo_path" remote add origin "$remote_path"
        git -C "$repo_path" push -q -u origin HEAD:refs/heads/main
        base=$(git -C "$repo_path" rev-parse HEAD)
        printf 'already published history\n' > "$repo_path/history.txt"
        git -C "$repo_path" add history.txt
        git -C "$repo_path" commit -qm 'Existing published history'
        clean_head=$(git -C "$repo_path" rev-parse HEAD)
        git -C "$repo_path" push -q origin HEAD:refs/heads/main
        cat > "$env_root/receive-pack" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail
remote_dir="$1"
if [[ -f "$remote_dir/rewind-request" ]]; then
    read -r older_tip observed_tip < "$remote_dir/rewind-request" || exit 1
    git --git-dir="$remote_dir" update-ref refs/heads/main "$older_tip" "$observed_tip" || exit 1
fi
printf '%s\n' 'configured receive-pack executed' > "$remote_dir/receive-marker"
exec git receive-pack "$@"
HOOK
        chmod +x "$env_root/receive-pack"
        git -C "$repo_path" config remote.origin.receivepack "$env_root/receive-pack"
        [[ "$mode" != rewind ]] || printf '%s %s\n' "$base" "$clean_head" > "$remote_path/rewind-request"
        cat > "$repo_path/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$@" > "$RU_TEST_PUSH_ARGS"
cat > "$RU_TEST_PUSH_INPUT"
HOOK
        chmod +x "$repo_path/.git/hooks/pre-push"
        printf 'peer staged content\n' > "$repo_path/peer.txt"
        git -C "$repo_path" add peer.txt
        peer_blob=$(git -C "$repo_path" rev-parse :peer.txt)
        printf 'peer unstaged content\n' >> "$repo_path/peer.txt"
        peer_bytes=$(git hash-object "$repo_path/peer.txt")
        printf 'approved new candidate\n' > "$repo_path/planned.txt"
        plan='{"commits":[{"message":"Bind actual advertised tip","files":["planned.txt"]}],"push":true}'
        (
            export PATH="$env_root/cli-bin" AGENT_SWEEP_SECRET_SCAN=block
            export RU_TEST_PUSH_ARGS="$env_root/hook.args" RU_TEST_PUSH_INPUT="$env_root/hook.stdin"
            hash -r
            rc=0
            execute_commit_plan "$plan" "$repo_path" > "$env_root/executor.stdout" 2> "$env_root/executor.stderr" || rc=$?
            candidate=$(git -C "$repo_path" rev-parse HEAD)
            assert_file_exists "$remote_path/receive-marker" "Real configured receive-pack ran before advertisement"
            hook_args=$(head -n 1 "$env_root/hook.args")
            assert_equals origin "$hook_args" "Original pre-push hook keeps the configured remote name"
            assert_equals "$remote_path" "$(tail -n 1 "$env_root/hook.args")" "Original pre-push hook sees the actual effective receiver URL"
            advertised_old=$(awk '{print $4}' "$env_root/hook.stdin")
            if [[ "$mode" == rewind ]]; then
                assert_equals 1 "$rc" "A different advertised base refuses publication before sending the candidate"
                assert_equals "$base" "$(git -C "$remote_path" rev-parse main)" "Receiver remains at the independently rewound tip"
                assert_equals "$base" "$advertised_old" "Original project hook receives actual advertised oldOID"
                assert_contains "$(cat "$env_root/executor.stderr")" 'advertised receiver differs' "Refusal names the changed scan boundary"
            else
                assert_equals 0 "$rc" "Stable advertised receiver permits the real push"
                assert_equals "$candidate" "$(git -C "$remote_path" rev-parse main)" "Stable receiver reaches the exact approved candidate"
                assert_equals "$clean_head" "$advertised_old" "Original project hook receives the inspected stable oldOID"
            fi
            assert_not_equals "$clean_head" "$candidate" "Validated local commit is retained on success and refusal"
            assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Publication guard preserves unrelated staged content"
            assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Publication guard preserves unrelated worktree bytes"
            exit "$(get_exit_code)"
        )
        assert_equals 0 "$?" "Actual $mode advertisement satisfies its refusal or positive contract"
    done
}

test_python_parser_preserves_literal_candidate_paths() {
    local repo_path name literal_name plan no_jq_path index_path index_before head_before
    repo_path=$(create_test_repo)
    name=$' leading\tname\nwith newline.txt '
    literal_name=':(glob)*.txt'
    printf 'whitespace path bytes\n' > "$repo_path/$name"
    printf 'literal pathspec bytes\n' > "$repo_path/$literal_name"
    printf 'unapproved wildcard match\n' > "$repo_path/innocent.txt"
    plan=$(jq -n --arg name "$name" --arg literal "$literal_name" '{commits:[{message:"Literal Python candidate",files:[$name,$literal]}],push:false}')
    no_jq_path=$(create_python_only_path "${repo_path%/*}")
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    head_before=$(git -C "$repo_path" rev-parse HEAD)
    (
        export PATH="$no_jq_path" AGENT_SWEEP_SECRET_SCAN=none
        hash -r
        assert_fails "Python fallback actually runs without jq on PATH" command -v jq
        assert_success "Python remains available" command -v python3
        assert_success "Python validation preserves tab/newline/trailing-space and literal-pathspec names" validate_commit_plan "$plan" "$repo_path"
        assert_equals 0 "${#VALIDATION_WARNINGS[@]}" "No unusual path was silently skipped or normalized"
        assert_success "Python candidate index materializes exact named paths" prepare_commit_plan_index "$plan" "$repo_path" "${repo_path%/*}/python-candidate-index"
        assert_equals 'whitespace path bytes' "$(GIT_INDEX_FILE="${repo_path%/*}/python-candidate-index" git -C "$repo_path" show ":$name")" "Full whitespace filename identifies the original blob"
        assert_equals 'literal pathspec bytes' "$(GIT_INDEX_FILE="${repo_path%/*}/python-candidate-index" git -C "$repo_path" show ":$literal_name")" "Pathspec magic remains a literal filename"
        assert_fails "Literal pathspec cannot admit an unplanned wildcard match" env GIT_INDEX_FILE="${repo_path%/*}/python-candidate-index" git -C "$repo_path" rev-parse :innocent.txt
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Python validation preserves exact original index bytes"
        assert_equals "$head_before" "$(git -C "$repo_path" rev-parse HEAD)" "Python validation never creates a commit"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Real Python fallback preserves exact candidate paths and peer state"
}

test_malformed_commit_plan_refusals_have_valid_controls() {
    local repo_path plan malformed head_before index_path index_before no_jq_path
    repo_path=$(create_test_repo)
    printf 'approved bytes\n' > "$repo_path/planned.txt"
    plan='{"commits":[{"message":"Valid schema control","files":["planned.txt"]}],"push":false}'
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    head_before=$(git -C "$repo_path" rev-parse HEAD)
    no_jq_path=$(create_python_only_path "${repo_path%/*}")
    local -a malformed_plans=(
        '{"commits":[{"message":"Invalid push","files":["planned.txt"]}],"push":"false"}'
        '{"commits":[{"message":"Invalid push","files":["planned.txt"]}],"push":0}'
        '{"commits":{"message":"Invalid commits","files":["planned.txt"]},"push":false}'
        '{"commits":["not an object"],"push":false}'
        '{"commits":[{"message":42,"files":["planned.txt"]}],"push":false}'
        '{"commits":[{"message":"Invalid files","files":[42]}],"push":false}'
        '{"commits":[{"message":"Invalid NUL path","files":["planned.txt\u0000other"]}],"push":false}'
    )
    for malformed in "${malformed_plans[@]}"; do
        assert_fails "Malformed schema must refuse execution before a commit" execute_commit_plan "$malformed" "$repo_path"
        assert_equals "$head_before" "$(git -C "$repo_path" rev-parse HEAD)" "Malformed schema preserves HEAD"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Malformed schema preserves exact index"
        assert_success "Near-identical valid schema remains accepted" validate_commit_plan "$plan" "$repo_path"
    done
    (
        export PATH="$no_jq_path" AGENT_SWEEP_SECRET_SCAN=none
        hash -r
        assert_fails "Python schema probe has no jq" command -v jq
        for malformed in "${malformed_plans[@]}"; do
            assert_fails "Python parser rejects the same malformed schema or NUL path" validate_commit_plan "$malformed" "$repo_path"
            assert_success "Python parser accepts the valid control" validate_commit_plan "$plan" "$repo_path"
            assert_equals "$head_before" "$(git -C "$repo_path" rev-parse HEAD)" "Python refusal preserves HEAD"
            assert_equals "$index_before" "$(git hash-object "$index_path")" "Python refusal preserves exact index"
        done
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Both available parsers enforce the same typed schema"
    assert_success "Valid control executes after every refusal" execute_commit_plan "$plan" "$repo_path"
    assert_equals 'approved bytes' "$(git -C "$repo_path" show HEAD:planned.txt)" "Permitted control commits the actual planned bytes"
}

test_size_binary_and_deny_policies_have_permitted_controls() {
    local repo_path plan before index_path index_before
    repo_path=$(create_test_repo)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    (
        export AGENT_SWEEP_MAX_FILE_MB=0 AGENT_SWEEP_MAX_FILE_SIZE=32 AGENT_SWEEP_SECRET_SCAN=none
        before=$(git -C "$repo_path" rev-parse HEAD)
        index_before=$(git hash-object "$index_path")
        printf '%033d' 0 > "$repo_path/payload.txt"
        plan='{"commits":[{"message":"Size boundary","files":["payload.txt"]}],"push":false}'
        assert_fails "33-byte candidate exceeds exact 32-byte policy" execute_commit_plan "$plan" "$repo_path"
        assert_contains "$VALIDATION_ERROR" 'too large' "Failure comes from actual size policy"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Oversize refusal preserves HEAD"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Oversize refusal preserves exact index"
        printf '%032d' 0 > "$repo_path/payload.txt"
        assert_success "Exact 32-byte boundary remains permitted" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$(git hash-object "$repo_path/payload.txt")" "$(git -C "$repo_path" rev-parse HEAD:payload.txt)" "Boundary commit contains exact approved blob"

        printf '\000\001\002\003' > "$repo_path/payload.bin"
        plan='{"commits":[{"message":"Binary policy","files":["payload.bin"]}],"push":false}'
        before=$(git -C "$repo_path" rev-parse HEAD)
        index_before=$(git hash-object "$index_path")
        export AGENT_SWEEP_ALLOW_BINARY_PATTERNS=''
        assert_fails "Non-allowed binary bytes must refuse execution" execute_commit_plan "$plan" "$repo_path"
        assert_contains "$VALIDATION_ERROR" 'Binary' "Failure comes from actual binary policy"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Binary refusal preserves HEAD"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Binary refusal preserves exact index"
        export AGENT_SWEEP_ALLOW_BINARY_PATTERNS='payload.bin'
        assert_success "Explicit binary allowance permits the same bytes" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$(git hash-object "$repo_path/payload.bin")" "$(git -C "$repo_path" rev-parse HEAD:payload.bin)" "Allowed binary reaches Git without byte substitution"

        printf 'harmless fixture\n' > "$repo_path/.env"
        printf 'harmless fixture\n' > "$repo_path/configuration.txt"
        plan='{"commits":[{"message":"Denied path","files":[".env"]}],"push":false}'
        before=$(git -C "$repo_path" rev-parse HEAD)
        index_before=$(git hash-object "$index_path")
        assert_fails "Denied filename refuses even harmless bytes" execute_commit_plan "$plan" "$repo_path"
        assert_contains "$VALIDATION_ERROR" 'Denied' "Failure comes from deny policy"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Denied-file refusal preserves HEAD"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Denied-file refusal preserves exact index"
        plan='{"commits":[{"message":"Permitted path","files":["configuration.txt"]}],"push":false}'
        assert_success "Permitted filename with identical bytes executes" execute_commit_plan "$plan" "$repo_path"
        assert_fails "Denied path stays absent from the commit" git -C "$repo_path" cat-file -e HEAD:.env
        assert_file_exists "$repo_path/.env" "Denied worktree bytes remain preserved"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Policies retain paired actual-Git positive and negative outcomes"
}

test_configured_byte_limit_is_exact_after_mb_rounding() {
    local repo_path index_path before index_before plan
    repo_path=$(create_test_repo)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    (
        export AGENT_SWEEP_SECRET_SCAN=none
        printf '%s\n' '{"agent_sweep":{"max_file_size":64}}' > "$repo_path/.ru-agent.json"
        assert_success "Real repository configuration loads the byte limit" load_repo_agent_config "$repo_path"
        assert_equals 64 "$AGENT_SWEEP_MAX_FILE_SIZE" "Exact byte limit is retained"
        assert_equals 1 "$AGENT_SWEEP_MAX_FILE_MB" "Display MB rounds up without changing the byte contract"
        printf '%065d' 0 > "$repo_path/payload.txt"
        before=$(git -C "$repo_path" rev-parse HEAD)
        index_before=$(git hash-object "$index_path")
        plan='{"commits":[{"message":"Exact byte policy","files":["payload.txt"]}],"push":false}'
        assert_fails "65 bytes cannot enter a 64-byte configured candidate" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Oversized candidate preserves HEAD"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Oversized candidate preserves exact index"
        printf '%064d' 0 > "$repo_path/payload.txt"
        assert_success "Exact 64-byte boundary still commits" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$(git hash-object "$repo_path/payload.txt")" "$(git -C "$repo_path" rev-parse HEAD:payload.txt)" "Boundary candidate retains exact bytes"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Real byte configuration has paired refusal and success"
}

test_commit_preserves_symlink_blobs_without_following_targets() {
    local repo_path plan
    repo_path=$(create_test_repo)
    mkdir "$repo_path/target-directory"
    printf 'unplanned target bytes\n' > "$repo_path/target-directory/file.txt"
    ln -s missing-target "$repo_path/dangling-link"
    ln -s target-directory "$repo_path/directory-link"
    plan='{"commits":[{"message":"Exact symlink candidate","files":["dangling-link","directory-link"]}],"push":false}'
    assert_success "Dangling and directory symlinks are valid exact Git candidates" execute_commit_plan "$plan" "$repo_path"
    assert_equals missing-target "$(git -C "$repo_path" show HEAD:dangling-link)" "Dangling link commits its raw target string"
    assert_equals target-directory "$(git -C "$repo_path" show HEAD:directory-link)" "Directory link commits its raw target string"
    assert_equals 120000 "$(git --literal-pathspecs -C "$repo_path" ls-files --stage -- dangling-link | cut -d ' ' -f1)" "Candidate retains Git symlink mode"
    assert_fails "Unplanned symlink target directory is absent from commit" git -C "$repo_path" cat-file -e HEAD:target-directory/file.txt
    assert_equals 'unplanned target bytes' "$(cat "$repo_path/target-directory/file.txt")" "Target worktree bytes remain preserved"
    assert_equals missing-target "$(readlink "$repo_path/dangling-link")" "Dangling worktree link survives"
}

test_active_merge_refusal_preserves_exact_peer_state() {
    local repo_path plan before index_path index_before merge_path merge_before control_repo
    repo_path=$(create_test_repo)
    git -C "$repo_path" branch -m main
    git -C "$repo_path" checkout -q -b other
    printf 'other branch content\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    git -C "$repo_path" commit -q -m 'Other branch'
    git -C "$repo_path" checkout -q main
    printf 'main branch content\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    git -C "$repo_path" commit -q -m 'Main branch'
    assert_fails "Real conflicting merge creates an active Git operation" git -C "$repo_path" merge --no-edit other
    merge_path=$(git -C "$repo_path" rev-parse --git-path MERGE_HEAD)
    [[ "$merge_path" == /* ]] || merge_path="$repo_path/$merge_path"
    assert_file_exists "$merge_path" "Real merge marker exists before candidate execution"
    merge_before=$(git hash-object "$merge_path")
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    before=$(git -C "$repo_path" rev-parse HEAD)
    printf 'approved bytes\n' > "$repo_path/planned.txt"
    plan='{"commits":[{"message":"Respect active merge","files":["planned.txt"]}],"push":false}'
    assert_fails "Candidate cannot commit during an existing merge" execute_commit_plan "$plan" "$repo_path"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Active-merge refusal preserves HEAD"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Active-merge refusal preserves exact unmerged index bytes"
    assert_equals "$merge_before" "$(git hash-object "$merge_path")" "Existing merge marker is preserved byte for byte"
    assert_file_exists "$repo_path/planned.txt" "Refusal preserves proposed work"

    # A fresh equivalent checkout supplies a positive control without aborting
    # or deleting the original operator's active merge state.
    control_repo=$(create_test_repo)
    printf 'approved bytes\n' > "$control_repo/planned.txt"
    assert_success "Same valid plan executes without an active merge" execute_commit_plan "$plan" "$control_repo"
    assert_equals 'approved bytes' "$(git -C "$control_repo" show HEAD:planned.txt)" "Positive control commits real planned content"
}

test_index_lock_refusal_preserves_exact_peer_state() {
    local repo_path plan before index_path index_before lock_before control_repo
    repo_path=$(create_test_repo)
    printf 'approved bytes\n' > "$repo_path/planned.txt"
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    printf 'existing operator lock\n' > "$index_path.lock"
    index_before=$(git hash-object "$index_path")
    lock_before=$(git hash-object "$index_path.lock")
    before=$(git -C "$repo_path" rev-parse HEAD)
    plan='{"commits":[{"message":"Respect index owner","files":["planned.txt"]}],"push":false}'
    assert_fails "Another operation's index lock refuses candidate commit" execute_commit_plan "$plan" "$repo_path"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Index-lock refusal preserves HEAD"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Index-lock refusal preserves exact original index bytes"
    assert_equals "$lock_before" "$(git hash-object "$index_path.lock")" "Existing lock survives byte for byte"
    assert_file_exists "$repo_path/planned.txt" "Index-lock refusal preserves worktree bytes"
    control_repo=$(create_test_repo)
    printf 'approved bytes\n' > "$control_repo/planned.txt"
    assert_success "Same plan commits with an available index" execute_commit_plan "$plan" "$control_repo"
    assert_equals 'approved bytes' "$(git -C "$control_repo" show HEAD:planned.txt)" "Unlocked control commits real planned content"
}

test_real_remote_push_failure_preserves_local_candidate() {
    local repo_path remote_path base_sha plan peer_blob peer_bytes rejected_sha
    repo_path=$(create_test_repo)
    remote_path="${repo_path%/*}/remote.git"
    git -C "$repo_path" branch -m main
    git init --bare -q "$remote_path"
    git -C "$repo_path" remote add origin "$remote_path"
    git -C "$repo_path" push -q -u origin main
    base_sha=$(git -C "$repo_path" rev-parse HEAD)
    cat > "$remote_path/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
printf 'actual receive rejected\n' > rejection-observed
printf 'fixture rejects this requested publication\n' >&2
exit 1
HOOK
    chmod +x "$remote_path/hooks/pre-receive"
    printf 'peer staged bytes\n' > "$repo_path/peer.txt"
    git -C "$repo_path" add peer.txt
    peer_blob=$(git -C "$repo_path" rev-parse :peer.txt)
    printf 'peer unstaged bytes\n' >> "$repo_path/peer.txt"
    peer_bytes=$(git hash-object "$repo_path/peer.txt")
    printf 'first approved candidate\n' > "$repo_path/planned.txt"
    plan='{"commits":[{"message":"Requested rejected push","files":["planned.txt"]}],"push":true}'
    (
        export AGENT_SWEEP_SECRET_SCAN=block
        assert_fails "Actual remote receive rejection reports requested push failure" execute_commit_plan "$plan" "$repo_path"
        assert_file_exists "$remote_path/rejection-observed" "Real Git invoked the remote receive hook"
        assert_equals "$base_sha" "$(git -C "$remote_path" rev-parse main)" "Rejected publication leaves actual remote unchanged"
        rejected_sha=$(git -C "$repo_path" rev-parse HEAD)
        assert_not_equals "$base_sha" "$rejected_sha" "Validated local candidate commit remains available after remote failure"
        assert_equals 'first approved candidate' "$(git -C "$repo_path" show HEAD:planned.txt)" "Local candidate retains exact approved bytes"
        assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Remote rejection preserves peer staged blob"
        assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Remote rejection preserves peer worktree bytes"
        assert_fails "Peer staged content never enters the rejected candidate" git -C "$repo_path" cat-file -e HEAD:peer.txt

        # Preserve the hook file while letting the real remote accept the next
        # requested push. Both unpublished candidates must be scanned.
        chmod -x "$remote_path/hooks/pre-receive"
        printf 'second approved candidate\n' >> "$repo_path/planned.txt"
        plan='{"commits":[{"message":"Requested successful push","files":["planned.txt"]}],"push":true}'
        assert_success "Paired real remote acceptance permits publication" execute_commit_plan "$plan" "$repo_path"
        assert_equals "$(git -C "$repo_path" rev-parse HEAD)" "$(git -C "$remote_path" rev-parse main)" "Permitted actual remote receives the exact candidate HEAD"
        assert_equals "$peer_blob" "$(git -C "$repo_path" rev-parse :peer.txt)" "Successful publication also preserves peer staging"
        assert_equals "$peer_bytes" "$(git hash-object "$repo_path/peer.txt")" "Successful publication also preserves peer worktree bytes"
        exit "$(get_exit_code)"
    )
    assert_equals 0 "$?" "Requested actual remote refusal and success have preserved local state"
}

test_index_source_commits_exact_staged_blob() {
    local repo_path plan staged_blob worktree_blob denied_blob denied_bytes
    repo_path=$(create_test_repo)
    printf 'approved staged bytes\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    staged_blob=$(git -C "$repo_path" rev-parse :README.md)
    printf 'unstaged operator work\n' >> "$repo_path/README.md"
    worktree_blob=$(git hash-object "$repo_path/README.md")
    printf 'DENIED_FIXTURE=staged\n' > "$repo_path/.env"
    git -C "$repo_path" add -f .env
    denied_blob=$(git -C "$repo_path" rev-parse :.env)
    printf 'DENIED_FIXTURE=unstaged\n' >> "$repo_path/.env"
    denied_bytes=$(git hash-object "$repo_path/.env")
    plan='{"commits":[{"message":"Explicit approved index content","files":["README.md"],"source":"index"}],"push":false}'
    assert_success "Explicit index source commits selected staged bytes despite later worktree edits" execute_commit_plan "$plan" "$repo_path"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse HEAD:README.md)" "Commit uses exact original staged blob"
    assert_equals "$worktree_blob" "$(git hash-object "$repo_path/README.md")" "Index-source execution preserves unstaged worktree bytes"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse :README.md)" "Planned index entry retains the selected blob"
    assert_equals "$denied_blob" "$(git -C "$repo_path" rev-parse :.env)" "Unrelated denied staged blob is untouched"
    assert_equals "$denied_bytes" "$(git hash-object "$repo_path/.env")" "Unrelated denied worktree bytes are untouched"
    assert_fails "Denied staged path is absent from the index-source commit" git -C "$repo_path" cat-file -e HEAD:.env
}

test_index_source_rejects_invalid_source_types() {
    local repo_path plan invalid_plan source before index_path index_before
    repo_path=$(create_test_repo)
    printf 'approved staged bytes\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    printf 'unstaged operator work\n' >> "$repo_path/README.md"
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    before=$(git -C "$repo_path" rev-parse HEAD)
    plan='{"commits":[{"message":"Valid index source","files":["README.md"],"source":"index"}],"push":false}'
    local -a invalid_sources=('"unknown"' 'false' '0' 'null' '[]' '{}')
    for source in "${invalid_sources[@]}"; do
        invalid_plan=$(jq -n --argjson source "$source" '{commits:[{message:"Invalid candidate source",files:["README.md"],source:$source}],push:false}')
        assert_fails "Unknown or non-string source is invalid before candidate execution" validate_commit_plan "$invalid_plan" "$repo_path"
        assert_contains "$VALIDATION_ERROR" 'source' "Refusal identifies the invalid source field"
        assert_equals "$index_before" "$(git hash-object "$index_path")" "Invalid source preserves exact original index bytes"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Invalid source preserves HEAD"
        assert_success "Near-identical valid index source remains accepted" validate_commit_plan "$plan" "$repo_path"
    done
    assert_success "Valid index-source control executes after all refusals" execute_commit_plan "$plan" "$repo_path"
    assert_equals 'approved staged bytes' "$(git -C "$repo_path" show HEAD:README.md)" "Valid source commits the staged content"
    assert_contains "$(cat "$repo_path/README.md")" 'unstaged operator work' "Valid source leaves later work untouched"
}

test_commit_sweep_cli_preserves_denied_peer_staging() {
    local env_root repo_path denied_blob denied_bytes before rc=0
    env_root=$(create_test_env)
    repo_path=$(create_commit_sweep_cli_fixture "$env_root")
    printf 'DENIED_FIXTURE=staged\n' > "$repo_path/.env"
    git -C "$repo_path" add -f .env
    denied_blob=$(git -C "$repo_path" rev-parse :.env)
    printf 'DENIED_FIXTURE=unstaged\n' >> "$repo_path/.env"
    denied_bytes=$(git hash-object "$repo_path/.env")
    printf 'legitimate source content\n' > "$repo_path/feature.rs"
    before=$(git -C "$repo_path" rev-parse HEAD)
    run_commit_sweep_cli_fixture "$env_root" 'ordinary-sweep' || rc=$?
    assert_equals 0 "$rc" "Full configured feature-branch CLI sweep succeeds: $(cat "$env_root/ordinary-sweep.stderr")"
    assert_equals 'commit-sweep' "$(jq -r '.command' "$env_root/ordinary-sweep.stdout")" "Actual CLI emits the command envelope"
    assert_equals 1 "$(jq -r '.data.summary.commits_succeeded' "$env_root/ordinary-sweep.stdout")" "CLI reports the actual single successful commit"
    assert_equals feature.rs "$(git -C "$repo_path" diff --name-only "$before" HEAD)" "Only the legitimate planned path is committed"
    assert_equals 'legitimate source content' "$(git -C "$repo_path" show HEAD:feature.rs)" "Actual CLI commits the selected worktree bytes"
    assert_equals "$denied_blob" "$(git -C "$repo_path" rev-parse :.env)" "Full CLI preserves denied peer index blob"
    assert_equals "$denied_bytes" "$(git hash-object "$repo_path/.env")" "Full CLI preserves exact denied worktree bytes"
    assert_fails "Full CLI keeps denied pre-staged path out of HEAD" git -C "$repo_path" cat-file -e HEAD:.env
}

test_commit_sweep_cli_respect_staging_selects_original_bytes() {
    local env_root repo_path staged_blob worktree_blob denied_blob denied_bytes rc=0
    env_root=$(create_test_env)
    repo_path=$(create_commit_sweep_cli_fixture "$env_root")
    printf 'selected staged content\n' > "$repo_path/README.md"
    git -C "$repo_path" add README.md
    staged_blob=$(git -C "$repo_path" rev-parse :README.md)
    printf 'later unstaged work\n' >> "$repo_path/README.md"
    worktree_blob=$(git hash-object "$repo_path/README.md")
    printf 'DENIED_FIXTURE=staged\n' > "$repo_path/.env"
    git -C "$repo_path" add -f .env
    denied_blob=$(git -C "$repo_path" rev-parse :.env)
    printf 'DENIED_FIXTURE=unstaged\n' >> "$repo_path/.env"
    denied_bytes=$(git hash-object "$repo_path/.env")
    run_commit_sweep_cli_fixture "$env_root" 'respect-sweep' --respect-staging || rc=$?
    assert_equals 0 "$rc" "Actual --respect-staging sweep succeeds: $(cat "$env_root/respect-sweep.stderr")"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse HEAD:README.md)" "Respect-staging commits exact staged bytes, not later worktree content"
    assert_equals "$worktree_blob" "$(git hash-object "$repo_path/README.md")" "Respect-staging preserves exact later unstaged bytes"
    assert_equals "$staged_blob" "$(git -C "$repo_path" rev-parse :README.md)" "Selected index blob remains coherent after commit"
    assert_equals "$denied_blob" "$(git -C "$repo_path" rev-parse :.env)" "Respect-staging preserves unrelated denied staging"
    assert_equals "$denied_bytes" "$(git hash-object "$repo_path/.env")" "Respect-staging preserves denied worktree bytes"
    assert_fails "Respect-staging never admits denied staged path" git -C "$repo_path" cat-file -e HEAD:.env
    assert_equals 1 "$(jq -r '.data.summary.commits_succeeded' "$env_root/respect-sweep.stdout")" "Respect-staging reports one actual selected commit"
}

test_commit_sweep_cli_preserves_all_unusual_names() {
    local env_root repo_path before rc=0 name
    env_root=$(create_test_env)
    repo_path=$(create_commit_sweep_cli_fixture "$env_root")
    local -a names=($'source with\nnewline.rs' 'source|with-pipe.rs' ':(glob)*.rs' 'ordinary.rs')
    for name in "${names[@]}"; do
        printf 'exact content for %s\n' "$name" > "$repo_path/$name"
    done
    before=$(git -C "$repo_path" rev-parse HEAD)
    run_commit_sweep_cli_fixture "$env_root" 'literal-sweep' || rc=$?
    assert_equals 0 "$rc" "Actual CLI commits all literal filenames: $(cat "$env_root/literal-sweep.stderr")"
    for name in "${names[@]}"; do
        assert_equals "$(git hash-object "$repo_path/$name")" "$(git -C "$repo_path" rev-parse "HEAD:$name")" "Literal filename retains its exact corresponding blob: $name"
    done
    assert_equals 4 "$(git -C "$repo_path" diff --name-only -z "$before" HEAD | python3 -c 'import sys; print(len([p for p in sys.stdin.buffer.read().split(b"\0") if p]))')" "All four intended paths reach HEAD without newline/pipe truncation"
    assert_equals 1 "$(git -C "$repo_path" rev-list --count "$before..HEAD")" "The complete source group is one actual commit"
}

test_commit_sweep_cli_runs_project_hook_and_refuses_hook_changes() {
    local env_root repo_path hook_path before index_path index_before rc=0
    env_root=$(create_test_env)
    repo_path=$(create_commit_sweep_cli_fixture "$env_root")
    hook_path="$repo_path/.git/hooks/pre-commit"
    cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
printf 'original project hook ran\n' > "$RU_TEST_HOOK_MARKER"
HOOK
    chmod +x "$hook_path"
    printf 'initial approved content\n' > "$repo_path/feature.rs"
    run_commit_sweep_cli_fixture "$env_root" 'hook-positive' || rc=$?
    assert_equals 0 "$rc" "Actual CLI respects a normal original project hook: $(cat "$env_root/hook-positive.stderr")"
    assert_file_exists "$env_root/hook-marker" "Original project pre-commit hook actually executed"
    assert_equals 'initial approved content' "$(git -C "$repo_path" show HEAD:feature.rs)" "Normal hook permits the selected candidate"

    cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
printf 'hook-created unapproved content\n' > unplanned.rs
git add unplanned.rs
HOOK
    printf 'follow-up approved content\n' >> "$repo_path/feature.rs"
    before=$(git -C "$repo_path" rev-parse HEAD)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    rc=0
    run_commit_sweep_cli_fixture "$env_root" 'hook-refusal' || rc=$?
    assert_equals 1 "$rc" "Actual CLI refuses a hook-added unplanned candidate"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Hook refusal creates no partial CLI commit"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Hook refusal preserves exact original index bytes"
    assert_file_exists "$repo_path/unplanned.rs" "Hook-created worktree bytes survive for operator recovery"
    assert_contains "$(cat "$repo_path/feature.rs")" 'follow-up approved content' "Approved worktree edits survive refusal"
    assert_equals 0 "$(jq -r '.data.summary.commits_succeeded' "$env_root/hook-refusal.stdout")" "Refused hook candidate is never counted as success"
}

test_commit_sweep_cli_blocks_heuristic_secret_then_allows_clean_control() {
    local env_root repo_path before index_path index_before rc=0
    env_root=$(create_test_env)
    repo_path=$(create_commit_sweep_cli_fixture "$env_root")
    printf 'password = "synthetic-cli-fixture"\n' > "$repo_path/feature.rs"
    before=$(git -C "$repo_path" rev-parse HEAD)
    index_path=$(git -C "$repo_path" rev-parse --git-path index)
    [[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
    index_before=$(git hash-object "$index_path")
    run_commit_sweep_cli_fixture "$env_root" 'secret-refusal' || rc=$?
    assert_equals 1 "$rc" "Actual heuristic block mode refuses untracked synthetic secret"
    assert_contains "$(cat "$env_root/secret-refusal.stderr")" 'Secret scan did not pass' "CLI refusal comes from the real heuristic scanner"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Secret refusal preserves HEAD"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Secret refusal preserves exact original index bytes"
    assert_file_exists "$repo_path/feature.rs" "Refused secret fixture bytes remain present"
    printf 'harmless clean control\n' > "$repo_path/feature.rs"
    rc=0
    run_commit_sweep_cli_fixture "$env_root" 'secret-positive' || rc=$?
    assert_equals 0 "$rc" "Near-identical clean CLI candidate passes the same actual heuristic gate: $(cat "$env_root/secret-positive.stderr")"
    assert_equals 'harmless clean control' "$(git -C "$repo_path" show HEAD:feature.rs)" "Clean positive commits the exact replacement bytes"
    assert_equals 1 "$(jq -r '.data.summary.commits_succeeded' "$env_root/secret-positive.stdout")" "Permitted clean candidate is counted as actual success"

    # A clean worktree replacement must not hide secret bytes explicitly
    # selected from the index by --respect-staging.
    printf 'password = "synthetic-staged-fixture"\n' > "$repo_path/feature.rs"
    git -C "$repo_path" add feature.rs
    printf 'harmless worktree shadow\n' > "$repo_path/feature.rs"
    before=$(git -C "$repo_path" rev-parse HEAD)
    index_before=$(git hash-object "$index_path")
    rc=0
    run_commit_sweep_cli_fixture "$env_root" 'staged-secret-refusal' --respect-staging || rc=$?
    assert_equals 1 "$rc" "Respect-staging scans selected secret index bytes despite a harmless worktree"
    assert_contains "$(cat "$env_root/staged-secret-refusal.stderr")" 'Secret scan did not pass' "Selected index bytes reach the actual heuristic scanner"
    assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "Selected-index secret refusal preserves HEAD"
    assert_equals "$index_before" "$(git hash-object "$index_path")" "Selected-index secret refusal preserves exact index bytes"
    assert_equals 'harmless worktree shadow' "$(cat "$repo_path/feature.rs")" "Selected-index refusal preserves different worktree bytes"
    printf 'harmless staged replacement\n' > "$repo_path/feature.rs"
    git -C "$repo_path" add feature.rs
    printf 'new unstaged operator work\n' >> "$repo_path/feature.rs"
    rc=0
    run_commit_sweep_cli_fixture "$env_root" 'staged-secret-positive' --respect-staging || rc=$?
    assert_equals 0 "$rc" "Near-identical clean staged candidate passes the same real gate: $(cat "$env_root/staged-secret-positive.stderr")"
    assert_equals 'harmless staged replacement' "$(git -C "$repo_path" show HEAD:feature.rs)" "Clean staged positive commits only selected index bytes"
    assert_contains "$(cat "$repo_path/feature.rs")" 'new unstaged operator work' "Clean staged positive also preserves later worktree edits"
}

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

    # A planned changelog_entry adds that header, so the warning would be false.
    validate_release_plan '{"version": "v1.0.0", "tag_name": "v1.0.0", "changelog": "CHANGELOG.md", "changelog_entry": "## v1.0.0\n\n- First"}' "$repo_path"
    assert_equals 0 "${#VALIDATION_WARNINGS[@]}" "A planned changelog entry is not reported as missing"
}

test_release_plan_tag_field_must_name_version() {
    log_test_start "validate_release_plan: the prompt's tag field is used and must name the version"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    assert_success "A documented tag field naming the version is accepted" \
        validate_release_plan '{"version": "1.2.0", "tag": "v1.2.0"}' "$repo_path"
    assert_fails "A tag naming another version is rejected" \
        validate_release_plan '{"version": "1.2.0", "tag": "v9.9.9"}' "$repo_path"
    assert_contains "$VALIDATION_ERROR" "does not name version" "Error names the disagreement"
    assert_fails "tag and tag_name must agree" \
        validate_release_plan '{"version": "1.2.0", "tag": "v1.2.0", "tag_name": "1.2.0"}' "$repo_path"
    git -C "$repo_path" tag v1.2.0
    assert_fails "An existing tag given in the tag field is rejected" \
        validate_release_plan '{"version": "1.2.0", "tag": "v1.2.0"}' "$repo_path"
    assert_contains "$VALIDATION_ERROR" "already exists" "Error mentions the existing tag"
}

test_release_plan_null_version_declines_release() {
    log_test_start "validate_release_plan: a null version declines a release unless release fields are set"

    require_jq_or_skip || return 0

    local repo_path
    repo_path=$(create_test_repo)

    assert_success "A plan declining a release is valid" \
        validate_release_plan '{"version": null, "tag": null, "version_files": [], "checks": []}' "$repo_path"
    assert_equals true "$RELEASE_PLAN_NO_RELEASE" "The declined release is reported"
    assert_fails "Version files without a version are rejected" \
        validate_release_plan '{"version": null, "version_files": [{"path": "README.md", "old": "1", "new": "2"}]}' "$repo_path"
    assert_contains "$VALIDATION_ERROR" "version" "Error mentions the version"
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
run_test test_commit_preserves_unrelated_partial_staging
run_test test_commit_refusal_preserves_planned_partial_staging
run_test test_commit_accepts_fully_staged_planned_paths_with_worktree_group
run_test test_commit_preserves_unusual_names_and_deletions
run_test test_commit_rejects_hook_candidate_changes
run_test test_commit_blocks_untracked_secret_candidate
run_test test_commit_blocks_unknown_scanner_outcomes
run_test test_candidate_change_revokes_validation
run_test test_commit_scans_removed_historical_secret_before_publication
run_test test_commit_publication_targets_only_approved_branch
run_test test_publication_respects_push_remote_and_branch_selection
run_test test_publication_handles_duplicate_push_urls_once
run_test test_publication_scans_each_actual_push_receiver
run_test test_publication_binds_advertised_tip_and_preserves_project_hook
run_test test_python_parser_preserves_literal_candidate_paths
run_test test_malformed_commit_plan_refusals_have_valid_controls
run_test test_size_binary_and_deny_policies_have_permitted_controls
run_test test_configured_byte_limit_is_exact_after_mb_rounding
run_test test_commit_preserves_symlink_blobs_without_following_targets
run_test test_active_merge_refusal_preserves_exact_peer_state
run_test test_index_lock_refusal_preserves_exact_peer_state
run_test test_real_remote_push_failure_preserves_local_candidate
run_test test_index_source_commits_exact_staged_blob
run_test test_index_source_rejects_invalid_source_types
run_test test_commit_sweep_cli_preserves_denied_peer_staging
run_test test_commit_sweep_cli_respect_staging_selects_original_bytes
run_test test_commit_sweep_cli_preserves_all_unusual_names
run_test test_commit_sweep_cli_runs_project_hook_and_refuses_hook_changes
run_test test_commit_sweep_cli_blocks_heuristic_secret_then_allows_clean_control

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
run_test test_release_plan_tag_field_must_name_version
run_test test_release_plan_null_version_declines_release

print_results
exit "$(get_exit_code)"
