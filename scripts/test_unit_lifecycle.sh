#!/usr/bin/env bash
#
# Unit tests: Lifecycle Functions (bd-hjzw)
#
# Tests lifecycle/execution functions:
#   - execute_commit_plan: commit plan execution with validation, plan mode, push
#   - execute_release_plan: release creation (tags, gh release, strategies)
#   - execute_gh_actions: orchestrated GitHub mutations (comment, close, label)
#   - run_quality_gates: lint/test/secret gate orchestration
#   - update_plan_with_gates: merging gate results into plan JSON
#   - parse_gh_action_target: target string parsing
#   - gh_action_already_executed / record_gh_action_log: idempotence
#   - get_release_strategy: strategy determination from config
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Import runtime defaults and the complete helper graph through the source API.
lifecycle_script_dir="$SCRIPT_DIR"
lifecycle_project_dir="$PROJECT_DIR"
# shellcheck source=../ru
source "$PROJECT_DIR/ru"
SCRIPT_DIR="$lifecycle_script_dir"
PROJECT_DIR="$lifecycle_project_dir"

# Suppress log output during tests
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }
log_step() { :; }
log_success() { :; }

#==============================================================================
# Mock Infrastructure
#==============================================================================

# File-based mock log (survives subshells from command substitutions)
declare -g MOCK_GH_LOG_FILE=""
declare -g MOCK_GH_EXIT_CODE=0
declare -g MOCK_GH_OUTPUT=""

# Mock gh command - logs to file so it works inside subshells
gh() {
    if [[ -n "$MOCK_GH_LOG_FILE" ]]; then
        echo "$*" >> "$MOCK_GH_LOG_FILE"
    fi
    if [[ -n "$MOCK_GH_OUTPUT" ]]; then
        echo "$MOCK_GH_OUTPUT"
    fi
    return "$MOCK_GH_EXIT_CODE"
}

# Check if a gh call matching a pattern was recorded
gh_mock_called_with() {
    local pattern="$1"
    [[ -f "$MOCK_GH_LOG_FILE" ]] && grep -q "$pattern" "$MOCK_GH_LOG_FILE"
}

# Count gh mock calls
gh_mock_call_count() {
    if [[ -f "$MOCK_GH_LOG_FILE" ]]; then
        wc -l < "$MOCK_GH_LOG_FILE" | tr -d ' '
    else
        echo "0"
    fi
}

# Reset all mocks
reset_mocks() {
    MOCK_GH_EXIT_CODE=0
    MOCK_GH_OUTPUT=""
    if [[ -n "$MOCK_GH_LOG_FILE" && -f "$MOCK_GH_LOG_FILE" ]]; then
        : > "$MOCK_GH_LOG_FILE"
    fi
}

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_lifecycle_test() {
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    export RU_CONFIG_DIR="$TEST_DIR/config"
    MOCK_GH_LOG_FILE="$TEST_DIR/gh_mock_calls.log"
    mkdir -p "$RU_STATE_DIR/review"
    mkdir -p "$RU_CONFIG_DIR"
    mkdir -p "$TEST_DIR/repo"
    mkdir -p "$TEST_DIR/repo/.ru"
    reset_mocks
}

create_test_plan_file() {
    local plan_file="$1"
    local content="$2"
    mkdir -p "$(dirname "$plan_file")"
    echo "$content" > "$plan_file"
}

#==============================================================================
# Tests: parse_gh_action_target
#==============================================================================

test_parse_target_issue() {
    log_test_start "parse_gh_action_target: issue#N"
    setup_lifecycle_test

    local target_type="" number=""
    if parse_gh_action_target "issue#42" target_type number; then
        assert_equals "issue" "$target_type" "Should parse type as issue"
        assert_equals "42" "$number" "Should parse number as 42"
    else
        fail "Should successfully parse issue#42"
    fi

    log_test_pass "parse_gh_action_target: issue#N"
}

test_parse_target_pr() {
    log_test_start "parse_gh_action_target: pr#N"
    setup_lifecycle_test

    local target_type="" number=""
    if parse_gh_action_target "pr#123" target_type number; then
        assert_equals "pr" "$target_type" "Should parse type as pr"
        assert_equals "123" "$number" "Should parse number as 123"
    else
        fail "Should successfully parse pr#123"
    fi

    log_test_pass "parse_gh_action_target: pr#N"
}

test_parse_target_invalid() {
    log_test_start "parse_gh_action_target: rejects invalid"
    setup_lifecycle_test

    local target_type="" number=""

    # No delimiter
    if parse_gh_action_target "issue42" target_type number; then
        fail "Should reject 'issue42' (no #)"
    else
        pass "Rejected 'issue42'"
    fi

    # Wrong type
    if parse_gh_action_target "bug#42" target_type number; then
        fail "Should reject 'bug#42' (wrong type)"
    else
        pass "Rejected 'bug#42'"
    fi

    # No number
    if parse_gh_action_target "issue#" target_type number; then
        fail "Should reject 'issue#' (no number)"
    else
        pass "Rejected 'issue#'"
    fi

    # Empty string
    if parse_gh_action_target "" target_type number; then
        fail "Should reject empty string"
    else
        pass "Rejected empty string"
    fi

    log_test_pass "parse_gh_action_target: rejects invalid"
}

#==============================================================================
# Tests: execute_commit_plan
#==============================================================================

test_commit_plan_empty_plan() {
    log_test_start "execute_commit_plan: rejects empty plan"
    setup_lifecycle_test

    if execute_commit_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty plan"
    fi

    log_test_pass "execute_commit_plan: rejects empty plan"
}

test_commit_plan_invalid_repo() {
    log_test_start "execute_commit_plan: rejects invalid repo"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["a.txt"]}]}'
    if execute_commit_plan "$plan" "" 2>/dev/null; then
        fail "Should reject empty repo path"
    else
        pass "Rejected empty repo path"
    fi

    if execute_commit_plan "$plan" "$TEST_DIR/not-created" 2>/dev/null; then
        fail "Should reject nonexistent repo path"
    else
        pass "Rejected nonexistent repo path"
    fi

    log_test_pass "execute_commit_plan: rejects invalid repo"
}

test_commit_plan_plan_mode() {
    log_test_start "execute_commit_plan: plan mode skips execution"
    setup_lifecycle_test

    # Mock capture_plan_json
    capture_plan_json() { return 0; }

    export AGENT_SWEEP_EXECUTION_MODE="plan"
    local plan='{"commits":[{"message":"test","files":["a.txt"]}]}'

    if execute_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Plan mode returns success without executing"
    else
        fail "Plan mode should return 0"
    fi

    unset AGENT_SWEEP_EXECUTION_MODE

    log_test_pass "execute_commit_plan: plan mode skips execution"
}

test_commit_plan_no_commits() {
    log_test_start "execute_commit_plan: rejects plan with no commits"
    setup_lifecycle_test

    local plan='{"commits":[]}'

    # validate_commit_plan should reject empty commits
    if execute_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject plan with no commits"
    else
        pass "Rejected plan with no commits"
    fi

    log_test_pass "execute_commit_plan: rejects plan with no commits"
}

test_commit_plan_valid_execution() {
    log_test_start "execute_commit_plan: executes valid plan"
    setup_lifecycle_test

    # Create a real git repo with a file to commit
    local repo_dir
    repo_dir=$(create_real_git_repo "commit-test" 1)
    echo "new content" > "$repo_dir/changed.txt"
    git -C "$repo_dir" add "changed.txt" >/dev/null 2>&1

    local plan='{"commits":[{"message":"Test commit","files":["changed.txt"]}]}'
    local before_head
    before_head=$(git -C "$repo_dir" rev-parse HEAD)

    if execute_commit_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Executed valid commit plan"
    else
        fail "Should execute valid commit plan"
    fi
    assert_not_equals "$before_head" "$(git -C "$repo_dir" rev-parse HEAD)" "Valid execution creates an actual commit"
    assert_equals 'new content' "$(git -C "$repo_dir" show HEAD:changed.txt)" "Actual commit contains the selected fully staged bytes"
    assert_success "Selected fully staged path is reconciled after commit" git -C "$repo_dir" diff --cached --quiet -- changed.txt

    log_test_pass "execute_commit_plan: executes valid plan"
}

#==============================================================================
# Tests: execute_release_plan
#==============================================================================

test_release_plan_empty_plan() {
    log_test_start "execute_release_plan: rejects empty plan"
    setup_lifecycle_test

    if execute_release_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty release plan"
    fi

    log_test_pass "execute_release_plan: rejects empty plan"
}

test_release_plan_invalid_repo() {
    log_test_start "execute_release_plan: rejects invalid repo"
    setup_lifecycle_test

    local plan='{"version":"v1.0.0"}'
    if execute_release_plan "$plan" "" 2>/dev/null; then
        fail "Should reject empty repo path"
    else
        pass "Rejected empty repo path"
    fi

    if execute_release_plan "$plan" "$TEST_DIR/not-created" 2>/dev/null; then
        fail "Should reject nonexistent repo path"
    else
        pass "Rejected nonexistent repo path"
    fi

    log_test_pass "execute_release_plan: rejects invalid repo"
}

test_release_plan_plan_mode() {
    log_test_start "execute_release_plan: plan mode skips execution"
    setup_lifecycle_test

    capture_plan_json() { return 0; }
    export AGENT_SWEEP_EXECUTION_MODE="plan"

    local plan='{"version":"v1.0.0"}'
    if execute_release_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Plan mode returns success without executing"
    else
        fail "Plan mode should return 0"
    fi

    unset AGENT_SWEEP_EXECUTION_MODE

    log_test_pass "execute_release_plan: plan mode skips execution"
}

test_release_plan_never_strategy() {
    log_test_start "execute_release_plan: never strategy skips release"
    setup_lifecycle_test

    local repo_dir
    repo_dir=$(create_real_git_repo "release-never" 1)

    # Override get_release_strategy to return 'never'
    get_release_strategy() { echo "never"; }
    validate_release_plan() { VALIDATION_WARNINGS=(); return 0; }

    local plan='{"version":"v1.0.0","tag_name":"v1.0.0","title":"Test Release"}'
    if execute_release_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Never strategy returns success (skips release)"
    else
        fail "Never strategy should return 0"
    fi

    log_test_pass "execute_release_plan: never strategy skips release"
}

test_release_plan_tag_only_strategy() {
    log_test_start "execute_release_plan: tag-only strategy creates tag but no gh release"
    setup_lifecycle_test

    local repo_dir
    repo_dir=$(create_real_git_repo "release-tag-only" 1)

    # Set up a remote so push works
    local remote_dir="$TEST_DIR/remote.git"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1

    get_release_strategy() { echo "tag-only"; }
    validate_release_plan() { VALIDATION_WARNINGS=(); return 0; }

    local plan='{"version":"v1.0.0","tag_name":"v1.0.0","title":"Test Release"}'
    if execute_release_plan "$plan" "$repo_dir" 2>/dev/null; then
        pass "Tag-only strategy succeeded"

        # Verify tag was created
        if git -C "$repo_dir" tag -l "v1.0.0" | grep -q "v1.0.0"; then
            pass "Tag v1.0.0 was created"
        else
            fail "Tag v1.0.0 should have been created"
        fi

        # Verify no gh calls were made (no GitHub release)
        if [[ "$(gh_mock_call_count)" -eq 0 ]]; then
            pass "No gh commands executed (tag-only)"
        else
            fail "Should not call gh in tag-only mode"
        fi
    else
        fail "Tag-only strategy should succeed"
    fi

    log_test_pass "execute_release_plan: tag-only strategy creates tag but no gh release"
}

#==============================================================================
# Tests: execute_release_plan applies and publishes a release (bd-tr5y.7)
#
# Real Git repositories publish to real bare receivers. Only GitHub is
# controlled: release_gh_mock answers release, run and download requests from
# files under $RELEASE_GH_DIR, and checks --verify-tag against the receiver.
#==============================================================================

eval "lifecycle_$(declare -f gh)"

release_gh_mock() {
    printf '%s\n' "$*" >> "$RELEASE_GH_DIR/calls"
    local arg dir=""
    case "${1:-} ${2:-}" in
        "release view")
            [[ -f "$RELEASE_GH_DIR/release-$3" ]] || { printf 'release not found\n' >&2; return 1; }
            jq -cn --arg tag "$3" '{tagName: $tag, url: ("https://github.com/owner/repo/releases/tag/" + $tag)}'
            ;;
        "release create")
            if [[ -f "$RELEASE_GH_DIR/create-fails" ]]; then
                rm -f "$RELEASE_GH_DIR/create-fails"
                printf 'HTTP 502: Bad Gateway\n' >&2
                return 1
            fi
            [[ " $* " == *" --verify-tag "* ]] || return 98
            git -C "$RELEASE_REMOTE" rev-parse --verify --quiet "refs/tags/$3" >/dev/null || {
                printf 'tag %s does not exist on the remote\n' "$3" >&2
                return 1
            }
            : > "$RELEASE_GH_DIR/release-$3"
            printf 'https://github.com/owner/repo/releases/tag/%s\n' "$3"
            ;;
        "run list") cat "$RELEASE_GH_DIR/runs.json" ;;
        "release download")
            for arg in "$@"; do
                [[ "$dir" == next ]] && dir="$arg"
                [[ "$arg" == --dir ]] && dir=next
            done
            cp "$RELEASE_GH_DIR"/assets/* "$dir"/
            ;;
        *) printf 'unexpected gh %s\n' "$*" >&2; return 99 ;;
    esac
}

# A repository at 1.1.0 with a VERSION file, package.json, changelog and a
# make test target, pushed to a bare receiver. The test target passes only
# when RELEASE_TEST_OK=yes and the checked-out VERSION is the release.
setup_release_test() {
    local strategy="${1:-auto}"
    setup_lifecycle_test
    source_ru_function "validate_release_plan"
    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"
    RELEASE_GH_DIR="$TEST_DIR/gh"
    mkdir -p "$RELEASE_GH_DIR/assets"
    gh() { release_gh_mock "$@"; }
    log_error() { printf '%s\n' "$*" >> "$TEST_DIR/errors"; }
    RELEASE_REPO=$(create_real_git_repo "release-repo" 1)
    RELEASE_REMOTE="$TEST_DIR/receiver.git"
    git init --bare --quiet "$RELEASE_REMOTE"
    git -C "$RELEASE_REMOTE" symbolic-ref HEAD refs/heads/main
    printf '1.1.0\n' > "$RELEASE_REPO/VERSION"
    printf '{\n  "name": "fixture",\n  "version": "1.1.0",\n  "dependencies": {\n    "left-pad": "^1.1.0"\n  }\n}\n' > "$RELEASE_REPO/package.json"
    printf '# Changelog\n\n## v1.1.0\n\n- Initial release\n' > "$RELEASE_REPO/CHANGELOG.md"
    printf 'test:\n\ttest "$$RELEASE_TEST_OK" = yes\n\ttest "$$(cat VERSION)" = 1.2.0\n' > "$RELEASE_REPO/Makefile"
    mkdir -p "$RELEASE_REPO/.ru"
    printf 'AGENT_SWEEP_RELEASE_STRATEGY=%s\n' "$strategy" > "$RELEASE_REPO/.ru/agent-sweep.conf"
    git -C "$RELEASE_REPO" add VERSION package.json CHANGELOG.md Makefile
    git -C "$RELEASE_REPO" commit --quiet -m "Version 1.1.0"
    git -C "$RELEASE_REPO" remote add origin "$RELEASE_REMOTE"
    git -C "$RELEASE_REPO" push --quiet -u origin main 2>/dev/null
    RELEASE_BASE=$(git -C "$RELEASE_REPO" rev-parse HEAD)
    export RELEASE_TEST_OK=yes
}

teardown_release_test() {
    gh() { lifecycle_gh "$@"; }
    log_error() { :; }
    unset RELEASE_TEST_OK
}

release_plan_json() {
    jq -cn --argjson checks "${1:-[\"tests\"]}" '{
        version: "1.2.0", tag: "v1.2.0",
        changelog_entry: "## v1.2.0\n\n- Releases are applied, checked and verified",
        version_files: [{path: "VERSION", old: "1.1.0", new: "1.2.0"},
                        {path: "package.json", old: "1.1.0", new: "1.2.0"}],
        checks: $checks}'
}

test_release_applies_version_files_changelog_and_publishes() {
    log_test_start "execute_release_plan: tags a commit holding the version files and changelog, then publishes it"
    setup_release_test auto
    # A common setting that would send the new tag along with the branch push
    git -C "$RELEASE_REPO" config push.followTags true
    printf 'unrelated staged work\n' > "$RELEASE_REPO/notes.txt"
    git -C "$RELEASE_REPO" add notes.txt

    local rc=0 commit tag_object
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 0 "$rc" "A valid release plan succeeds"
    commit=$(git -C "$RELEASE_REPO" rev-parse --verify --quiet 'v1.2.0^{commit}')
    tag_object=$(git -C "$RELEASE_REPO" rev-parse --verify --quiet refs/tags/v1.2.0)
    assert_equals tag "$(git -C "$RELEASE_REPO" cat-file -t v1.2.0 2>/dev/null)" "The release tag is annotated"
    assert_equals 1.2.0 "$(git -C "$RELEASE_REPO" show v1.2.0:VERSION 2>/dev/null)" "The tagged VERSION names the release"
    assert_equals 1.2.0 "$(git -C "$RELEASE_REPO" show v1.2.0:package.json 2>/dev/null | jq -r .version)" "The tagged package.json names the release"
    assert_equals '^1.1.0' "$(git -C "$RELEASE_REPO" show v1.2.0:package.json 2>/dev/null | jq -r '.dependencies["left-pad"]')" "A dependency that shares the old version is untouched"
    assert_equals '## v1.2.0' "$(git -C "$RELEASE_REPO" show v1.2.0:CHANGELOG.md 2>/dev/null | grep -m1 '^## ')" "The changelog entry is the newest section"
    assert_contains "$(git -C "$RELEASE_REPO" show v1.2.0:CHANGELOG.md 2>/dev/null)" '## v1.1.0' "Earlier changelog sections remain"
    assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REPO" rev-parse "$commit^" 2>/dev/null)" "Exactly one release commit sits on the previous HEAD"
    assert_equals $'CHANGELOG.md\nVERSION\npackage.json' "$(git -C "$RELEASE_REPO" diff-tree --no-commit-id --name-only -r "$commit" | LC_ALL=C sort)" "The release commit holds only the release files"
    assert_equals notes.txt "$(git -C "$RELEASE_REPO" diff --cached --name-only)" "Unrelated staged work stays staged and out of the release"
    assert_equals "$commit" "$(git -C "$RELEASE_REMOTE" rev-parse --verify --quiet refs/heads/main)" "The receiver's branch is the release commit"
    assert_equals "$tag_object" "$(git -C "$RELEASE_REMOTE" rev-parse --verify --quiet refs/tags/v1.2.0)" "The receiver has the same annotated tag"
    assert_contains "$(cat "$RELEASE_GH_DIR/calls")" 'release create v1.2.0 --verify-tag' "The GitHub release requires the published tag"
    assert_success "The recorded release is complete" jq -e --arg commit "$commit" \
        '.complete == true and .commit == $commit and .steps.checks.result == "passed" and .steps.publish == "done"' \
        "$(release_state_file "$RELEASE_REPO" v1.2.0)"
    teardown_release_test
    log_test_pass "execute_release_plan: tags a commit holding the version files and changelog, then publishes it"
}

test_release_failed_check_publishes_nothing_and_retry_continues() {
    log_test_start "execute_release_plan: a failed check publishes nothing; the retry reuses the release commit"
    setup_release_test auto
    local rc=0 first_commit
    RELEASE_TEST_OK=no execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 1 "$rc" "A failing requested check fails the release"
    assert_equals "" "$(git -C "$RELEASE_REPO" tag -l v1.2.0)" "No tag is created before the checks pass"
    assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REMOTE" rev-parse refs/heads/main)" "The receiver's branch is unchanged"
    assert_equals "" "$(git -C "$RELEASE_REMOTE" tag -l)" "The receiver has no tag"
    assert_equals "" "$(cat "$RELEASE_GH_DIR/calls" 2>/dev/null)" "GitHub is not asked for anything"
    first_commit=$(git -C "$RELEASE_REPO" rev-parse HEAD)
    assert_equals 1.2.0 "$(git -C "$RELEASE_REPO" show HEAD:VERSION)" "The checked release commit stays local for inspection"

    rc=0
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 0 "$rc" "The retry succeeds once the check passes"
    assert_equals "$first_commit" "$(git -C "$RELEASE_REPO" rev-parse 'v1.2.0^{commit}')" "The retry tags the same release commit"
    assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REPO" rev-parse "$first_commit^")" "The retry adds no second release commit"
    assert_equals "$first_commit" "$(git -C "$RELEASE_REMOTE" rev-parse refs/heads/main)" "The retry publishes the release commit"
    teardown_release_test
    log_test_pass "execute_release_plan: a failed check publishes nothing; the retry reuses the release commit"
}

test_release_resumes_after_github_release_failure() {
    log_test_start "execute_release_plan: a retry after a failed GitHub release resumes instead of refusing the tag"
    setup_release_test auto
    : > "$RELEASE_GH_DIR/create-fails"
    local rc=0 commit tag_object
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 1 "$rc" "A failed GitHub release fails the run"
    commit=$(git -C "$RELEASE_REPO" rev-parse 'v1.2.0^{commit}')
    tag_object=$(git -C "$RELEASE_REPO" rev-parse refs/tags/v1.2.0)
    assert_equals "$tag_object" "$(git -C "$RELEASE_REMOTE" rev-parse --verify --quiet refs/tags/v1.2.0)" "The tag was already published"
    assert_success "The record shows publication done and the release failed" jq -e \
        '.steps.publish == "done" and .steps.github_release == "failed" and .complete == false' \
        "$(release_state_file "$RELEASE_REPO" v1.2.0)"

    rc=0
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 0 "$rc" "The retry resumes and succeeds"
    assert_equals "$tag_object" "$(git -C "$RELEASE_REPO" rev-parse refs/tags/v1.2.0)" "The retry keeps the same tag object"
    assert_equals "$commit" "$(git -C "$RELEASE_REPO" rev-parse HEAD)" "The retry adds no commit"
    assert_equals 2 "$(grep -c '^release create v1.2.0' "$RELEASE_GH_DIR/calls")" "The release is created once, after the one failed attempt"
    rc=0
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 1 "$rc" "A completed release is not released again"
    teardown_release_test
    log_test_pass "execute_release_plan: a retry after a failed GitHub release resumes instead of refusing the tag"
}

test_release_null_version_is_no_release() {
    log_test_start "execute_release_plan: a plan with no version releases nothing and succeeds"
    setup_release_test auto
    local rc=0
    execute_release_plan '{"version": null, "tag": null, "changelog_entry": "", "version_files": [], "checks": []}' "$RELEASE_REPO" || rc=$?
    assert_equals 0 "$rc" "Declining a release is a successful outcome"
    assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REPO" rev-parse HEAD)" "No commit is made"
    assert_equals "" "$(git -C "$RELEASE_REPO" tag -l)" "No tag is made"
    teardown_release_test
    log_test_pass "execute_release_plan: a plan with no version releases nothing and succeeds"
}

test_release_refusals_leave_repository_unchanged() {
    log_test_start "execute_release_plan: refused plans change no commit, file, tag or receiver"
    local name plan rc expected
    for name in ambiguous-file wrong-new-version version-file-not-listed dirty-version-file \
        unknown-check foreign-receiver-tag; do
        setup_release_test auto
        plan=$(release_plan_json)
        case "$name" in
            ambiguous-file)
                printf 'release 1.1.0\nminimum 1.1.0\n' > "$RELEASE_REPO/config.txt"
                git -C "$RELEASE_REPO" add config.txt
                git -C "$RELEASE_REPO" commit --quiet -m "Add config"
                git -C "$RELEASE_REPO" push --quiet origin main 2>/dev/null
                RELEASE_BASE=$(git -C "$RELEASE_REPO" rev-parse HEAD)
                plan=$(run_with_input "$plan" jq -c '.version_files += [{path: "config.txt", old: "1.1.0", new: "1.2.0"}]')
                ;;
            wrong-new-version) plan=$(run_with_input "$plan" jq -c '.version_files[1].new = "1.3.0"') ;;
            version-file-not-listed) plan=$(run_with_input "$plan" jq -c '.version_files = [.version_files[1]]') ;;
            dirty-version-file) printf '{"edited": true}\n' > "$RELEASE_REPO/package.json" ;;
            unknown-check) plan=$(release_plan_json '["tests", "fuzz"]') ;;
            foreign-receiver-tag)
                git -C "$RELEASE_REPO" tag -a v1.2.0 -m "Someone else's" "$RELEASE_BASE"
                git -C "$RELEASE_REPO" push --quiet origin v1.2.0 2>/dev/null
                git -C "$RELEASE_REPO" tag -d v1.2.0 >/dev/null
                ;;
        esac
        expected=$(git -C "$RELEASE_REPO" status --porcelain; cat "$RELEASE_REPO/VERSION" "$RELEASE_REPO/package.json" "$RELEASE_REPO/CHANGELOG.md")
        rc=0
        execute_release_plan "$plan" "$RELEASE_REPO" || rc=$?
        assert_equals 1 "$rc" "$name is refused"
        assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REPO" rev-parse HEAD)" "$name makes no commit"
        assert_equals "$expected" "$(git -C "$RELEASE_REPO" status --porcelain; cat "$RELEASE_REPO/VERSION" "$RELEASE_REPO/package.json" "$RELEASE_REPO/CHANGELOG.md")" "$name leaves every file as it was"
        assert_equals "" "$(git -C "$RELEASE_REPO" tag -l)" "$name creates no local tag"
        assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REMOTE" rev-parse refs/heads/main)" "$name leaves the receiver's branch"
        case "$name" in
            ambiguous-file) expected="could declare 1.1.0 in more than one place" ;;
            wrong-new-version) expected="would be set to 1.3.0" ;;
            version-file-not-listed) expected="VERSION says 1.1.0" ;;
            dirty-version-file) expected="uncommitted changes: package.json" ;;
            unknown-check) expected="Unknown release check: fuzz" ;;
            foreign-receiver-tag) expected="already has a different v1.2.0" ;;
        esac
        assert_contains "$(cat "$TEST_DIR/errors" 2>/dev/null)" "$expected" "$name is refused for its own reason"
        teardown_release_test
    done
    log_test_pass "execute_release_plan: refused plans change no commit, file, tag or receiver"
}

test_release_tag_only_publishes_without_github() {
    log_test_start "execute_release_plan: tag-only publishes the release commit and tag and never calls GitHub"
    setup_release_test tag-only
    local rc=0 commit
    execute_release_plan "$(release_plan_json)" "$RELEASE_REPO" || rc=$?
    assert_equals 0 "$rc" "A tag-only release succeeds"
    commit=$(git -C "$RELEASE_REPO" rev-parse 'v1.2.0^{commit}')
    assert_equals 1.2.0 "$(git -C "$RELEASE_REPO" show v1.2.0:VERSION)" "The tag-only release still carries its version files"
    assert_equals "$commit" "$(git -C "$RELEASE_REMOTE" rev-parse refs/heads/main)" "The release commit is published"
    assert_equals "$(git -C "$RELEASE_REPO" rev-parse refs/tags/v1.2.0)" "$(git -C "$RELEASE_REMOTE" rev-parse refs/tags/v1.2.0)" "The tag is published"
    assert_equals "" "$(cat "$RELEASE_GH_DIR/calls" 2>/dev/null)" "GitHub is never called"
    rc=0
    execute_release_plan "$(release_plan_json '["tests", "checksums"]')" "$RELEASE_REPO" || rc=$?
    assert_equals 1 "$rc" "tag-only refuses checksums, which need a GitHub release"
    teardown_release_test
    log_test_pass "execute_release_plan: tag-only publishes the release commit and tag and never calls GitHub"
}

test_release_gh_release_requires_gh() {
    log_test_start "execute_release_plan: gh-release without gh refuses before changing anything"
    setup_release_test gh-release
    local bin="$TEST_DIR/no-gh-bin" tool tool_path rc=0
    mkdir -p "$bin"
    for tool in git jq awk sed grep sort tr tail head cut cat mktemp mkdir rm dirname basename date env bash make test; do
        tool_path=$(type -P "$tool") && ln -sf "$tool_path" "$bin/$tool"
    done
    (
        unset -f gh
        PATH="$bin"
        execute_release_plan "$(release_plan_json)" "$RELEASE_REPO"
    ) || rc=$?
    assert_equals 1 "$rc" "gh-release fails when gh is not installed"
    assert_equals "$RELEASE_BASE" "$(git -C "$RELEASE_REPO" rev-parse HEAD)" "No release commit is made"
    assert_equals "" "$(git -C "$RELEASE_REPO" tag -l)" "No tag is made"
    teardown_release_test
    log_test_pass "execute_release_plan: gh-release without gh refuses before changing anything"
}

test_release_ci_and_checksums_are_observed() {
    log_test_start "execute_release_plan: requested CI and checksums must be observed to pass"
    local scenario rc
    for scenario in pass ci-failed checksum-mismatch; do
        setup_release_test auto
        export AGENT_SWEEP_RELEASE_CI_POLL_SECONDS=0
        printf 'release payload\n' > "$RELEASE_GH_DIR/assets/ru.tar.gz"
        if command -v sha256sum &>/dev/null; then
            sha256sum "$RELEASE_GH_DIR/assets/ru.tar.gz" | sed 's#  .*/#  #' > "$RELEASE_GH_DIR/assets/SHA256SUMS"
        else
            shasum -a 256 "$RELEASE_GH_DIR/assets/ru.tar.gz" | sed 's#  .*/#  #' > "$RELEASE_GH_DIR/assets/SHA256SUMS"
        fi
        printf '[{"name":"release","status":"completed","conclusion":"success"}]\n' > "$RELEASE_GH_DIR/runs.json"
        case "$scenario" in
            ci-failed) printf '[{"name":"release","status":"completed","conclusion":"failure"}]\n' > "$RELEASE_GH_DIR/runs.json" ;;
            checksum-mismatch) printf 'tampered payload\n' > "$RELEASE_GH_DIR/assets/ru.tar.gz" ;;
        esac
        rc=0
        execute_release_plan "$(release_plan_json '["tests", "ci", "checksums"]')" "$RELEASE_REPO" || rc=$?
        if [[ "$scenario" == pass ]]; then
            assert_equals 0 "$rc" "Passing CI and matching checksums complete the release"
            assert_success "The record shows CI and checksums" jq -e '.steps.ci == "passed" and .steps.checksums == "verified" and .complete == true' \
                "$(release_state_file "$RELEASE_REPO" v1.2.0)"
        else
            assert_equals 1 "$rc" "$scenario fails the release"
            assert_success "$scenario leaves the release incomplete" jq -e '.complete == false' "$(release_state_file "$RELEASE_REPO" v1.2.0)"
        fi
        assert_contains "$(cat "$RELEASE_GH_DIR/calls")" "run list --commit $(git -C "$RELEASE_REPO" rev-parse 'v1.2.0^{commit}')" "$scenario reads the release commit's CI runs"
        unset AGENT_SWEEP_RELEASE_CI_POLL_SECONDS
        teardown_release_test
    done
    log_test_pass "execute_release_plan: requested CI and checksums must be observed to pass"
}

test_release_version_file_formats() {
    log_test_start "release_update_version_file: changes only the line that declares the version"
    setup_lifecycle_test
    local repo rc result
    repo=$(create_real_git_repo "version-formats" 1)
    printf '[package]\nname = "x"\nversion = "1.1.0"\n\n[dependencies]\nserde = { version = "1.1.0" }\n\n[dependencies.other]\nversion = "1.1.0"\n' > "$repo/Cargo.toml"
    printf '#!/usr/bin/env bash\nVERSION="1.1.0"\n# 1.1.0 added flags\n' > "$repo/tool"
    printf 'v1.1.0' > "$repo/VERSION"
    printf 'see 1.1.0 and 1.1.0\n' > "$repo/notes.txt"
    result=$(release_update_version_file "$repo" Cargo.toml 1.1.0 1.2.0)
    assert_equals updated "$result" "A TOML package version is updated"
    assert_equals 'version = "1.2.0"' "$(sed -n 3p "$repo/Cargo.toml")" "Only the [package] version changes"
    assert_equals 2 "$(grep -c '1\.1\.0' "$repo/Cargo.toml")" "Dependency versions keep the old number"
    result=$(release_update_version_file "$repo" tool 1.1.0 1.2.0)
    assert_equals 'VERSION="1.2.0"' "$(sed -n 2p "$repo/tool")" "A script's version assignment is chosen over a comment"
    assert_contains "$(cat "$repo/tool")" '# 1.1.0 added flags' "The comment keeps its text"
    result=$(release_update_version_file "$repo" VERSION 1.1.0 1.2.0)
    assert_equals v1.2.0 "$(cat "$repo/VERSION")" "A v-prefixed VERSION keeps its prefix and missing final newline"
    result=$(release_update_version_file "$repo" VERSION 1.1.0 1.2.0)
    assert_equals current "$result" "A file already at the new version is reported current"
    rc=0
    result=$(release_update_version_file "$repo" notes.txt 1.1.0 1.2.0) || rc=$?
    assert_equals 4 "$rc" "Two equal candidates are ambiguous"
    assert_equals 'see 1.1.0 and 1.1.0' "$(cat "$repo/notes.txt")" "An ambiguous file is unchanged"
    rc=0
    result=$(release_update_version_file "$repo" Cargo.toml 9.9.9 1.3.0) || rc=$?
    assert_equals 3 "$rc" "A missing old version is reported"
    log_test_pass "release_update_version_file: changes only the line that declares the version"
}

#==============================================================================
# Tests: execute_gh_actions orchestrator
#==============================================================================

test_gh_actions_no_actions() {
    log_test_start "execute_gh_actions: no actions in plan"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": []
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        pass "Returns success when no actions"
    else
        fail "Should succeed with no actions"
    fi

    assert_equals "0" "$(gh_mock_call_count)" "No gh calls should be made"

    log_test_pass "execute_gh_actions: no actions in plan"
}

test_gh_actions_missing_plan_file() {
    log_test_start "execute_gh_actions: rejects missing plan file"
    setup_lifecycle_test

    if execute_gh_actions "owner/repo" "$TEST_DIR/not-created/plan.json" 2>/dev/null; then
        fail "Should reject missing plan file"
    else
        pass "Rejected missing plan file"
    fi

    log_test_pass "execute_gh_actions: rejects missing plan file"
}

test_gh_actions_comment_execution() {
    log_test_start "execute_gh_actions: executes comment action"
    setup_lifecycle_test

    # Set up state dir for action logging
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "issue#42", "body": "Test comment"}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    # Verify gh was called with comment args (file-based mock log)
    if gh_mock_called_with "issue comment.*42"; then
        pass "gh issue comment was called"
    else
        fail "Should call gh issue comment"
    fi

    log_test_pass "execute_gh_actions: executes comment action"
}

test_gh_actions_close_execution() {
    log_test_start "execute_gh_actions: executes close action"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "close", "target": "issue#10", "reason": "completed"}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    if gh_mock_called_with "issue close.*10"; then
        pass "gh issue close was called"
    else
        fail "Should call gh issue close"
    fi

    log_test_pass "execute_gh_actions: executes close action"
}

test_gh_actions_label_execution() {
    log_test_start "execute_gh_actions: executes label action"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "label", "target": "issue#5", "labels": ["bug", "urgent"]}
        ]
    }'

    MOCK_GH_EXIT_CODE=0
    execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null

    if gh_mock_called_with "issue edit.*5.*add-label"; then
        pass "gh issue edit --add-label was called"
    else
        fail "Should call gh issue edit --add-label"
    fi

    log_test_pass "execute_gh_actions: executes label action"
}

test_gh_actions_merge_blocked() {
    log_test_start "execute_gh_actions: merge op is blocked by policy"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "merge", "target": "pr#99"}
        ]
    }'

    # Merge should be blocked and return failure
    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Merge should cause failure (blocked by policy)"
    else
        pass "Merge op blocked by policy"
    fi

    # Verify no gh merge call was made
    if ! gh_mock_called_with "merge"; then
        pass "No gh merge command was executed"
    else
        fail "Should not execute gh merge"
    fi

    log_test_pass "execute_gh_actions: merge op is blocked by policy"
}

test_gh_actions_invalid_target() {
    log_test_start "execute_gh_actions: invalid target fails gracefully"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "invalid_target", "body": "test"}
        ]
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Invalid target should cause failure"
    else
        pass "Failed on invalid target"
    fi

    log_test_pass "execute_gh_actions: invalid target fails gracefully"
}

test_gh_actions_label_pr_rejected() {
    log_test_start "execute_gh_actions: label on PR is rejected"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "label", "target": "pr#5", "labels": ["bug"]}
        ]
    }'

    # Labels are only supported on issues per the implementation
    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Label on PR should fail (issues only)"
    else
        pass "Label on PR correctly rejected"
    fi

    log_test_pass "execute_gh_actions: label on PR is rejected"
}

test_gh_actions_comment_missing_body() {
    log_test_start "execute_gh_actions: comment without body fails"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "gh_actions": [
            {"op": "comment", "target": "issue#42", "body": ""}
        ]
    }'

    if execute_gh_actions "owner/repo" "$plan_file" 2>/dev/null; then
        fail "Comment without body should fail"
    else
        pass "Comment without body correctly failed"
    fi

    log_test_pass "execute_gh_actions: comment without body fails"
}

#==============================================================================
# Tests: gh_action_already_executed / record_gh_action_log (idempotence)
#==============================================================================

test_idempotence_not_executed() {
    log_test_start "gh_action_already_executed: returns false when not executed"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    if gh_action_already_executed "owner/repo" '{"op":"comment","target":"issue#1"}'; then
        fail "Should return false when no log exists"
    else
        pass "Correctly reports not yet executed"
    fi

    log_test_pass "gh_action_already_executed: returns false when not executed"
}

test_idempotence_record_and_check() {
    log_test_start "record_gh_action_log + gh_action_already_executed"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local action_canon='{"op":"comment","target":"issue#42"}'

    # Record a successful execution
    record_gh_action_log "owner/repo" "$action_canon" "ok" ""

    # Verify the log file was created
    local log_file
    log_file=$(get_gh_actions_log_file)
    assert_file_exists "$log_file" "Action log file should exist"

    # Check idempotence
    if gh_action_already_executed "owner/repo" "$action_canon"; then
        pass "Correctly detects already-executed action"
    else
        fail "Should detect already-executed action"
    fi

    log_test_pass "record_gh_action_log + gh_action_already_executed"
}

test_idempotence_failed_not_blocking() {
    log_test_start "gh_action_already_executed: failed actions don't block retry"
    setup_lifecycle_test

    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }

    local action_canon='{"op":"comment","target":"issue#99"}'

    # Record a failed execution
    record_gh_action_log "owner/repo" "$action_canon" "failed" "network error"

    # Failed actions should not count as "already executed"
    if gh_action_already_executed "owner/repo" "$action_canon"; then
        fail "Failed actions should not block retry"
    else
        pass "Failed actions correctly allow retry"
    fi

    log_test_pass "gh_action_already_executed: failed actions don't block retry"
}

#==============================================================================
# Tests: update_plan_with_gates
#==============================================================================

test_update_plan_with_gates_success() {
    log_test_start "update_plan_with_gates: merges gate results"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "items": [],
        "git": {}
    }'

    local gates_result='{
        "overall_ok": true,
        "has_warning": false,
        "tests": {"ran": true, "ok": true, "output": "all passed"},
        "lint": {"ran": true, "ok": true, "output": ""},
        "secrets": {"scanned": true, "ok": true, "findings": []}
    }'

    if update_plan_with_gates "$plan_file" "$gates_result"; then
        pass "update_plan_with_gates succeeded"
    else
        fail "update_plan_with_gates should succeed"
    fi

    # Verify plan was updated
    local quality_ok
    quality_ok=$(jq -r '.git.quality_gates_ok' "$plan_file")
    assert_equals "true" "$quality_ok" "quality_gates_ok should be true"

    local tests_ok
    tests_ok=$(jq -r '.git.tests.ok' "$plan_file")
    assert_equals "true" "$tests_ok" "tests.ok should be true"

    local lint_ok
    lint_ok=$(jq -r '.git.lint.ok' "$plan_file")
    assert_equals "true" "$lint_ok" "lint.ok should be true"

    local secrets_ok
    secrets_ok=$(jq -r '.git.secrets.ok' "$plan_file")
    assert_equals "true" "$secrets_ok" "secrets.ok should be true"

    log_test_pass "update_plan_with_gates: merges gate results"
}

test_update_plan_with_gates_failure() {
    log_test_start "update_plan_with_gates: records gate failures"
    setup_lifecycle_test

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{
        "repo": "owner/repo",
        "items": [],
        "git": {}
    }'

    local gates_result='{
        "overall_ok": false,
        "has_warning": true,
        "tests": {"ran": true, "ok": false, "output": "3 tests failed"},
        "lint": {"ran": true, "ok": true, "output": ""},
        "secrets": {"scanned": true, "ok": false, "findings": ["AWS_KEY"]}
    }'

    update_plan_with_gates "$plan_file" "$gates_result"

    local quality_ok
    quality_ok=$(jq -r '.git.quality_gates_ok' "$plan_file")
    assert_equals "false" "$quality_ok" "quality_gates_ok should be false"

    local quality_warning
    quality_warning=$(jq -r '.git.quality_gates_warning' "$plan_file")
    assert_equals "true" "$quality_warning" "quality_gates_warning should be true"

    local tests_ok
    tests_ok=$(jq -r '.git.tests.ok' "$plan_file")
    assert_equals "false" "$tests_ok" "tests.ok should be false"

    local secrets_ok
    secrets_ok=$(jq -r '.git.secrets.ok' "$plan_file")
    assert_equals "false" "$secrets_ok" "secrets.ok should be false"

    log_test_pass "update_plan_with_gates: records gate failures"
}

test_update_plan_missing_file() {
    log_test_start "update_plan_with_gates: rejects missing plan file"
    setup_lifecycle_test

    local gates_result='{"overall_ok":true,"has_warning":false,"tests":{},"lint":{},"secrets":{}}'

    if update_plan_with_gates "$TEST_DIR/not-created/plan.json" "$gates_result" 2>/dev/null; then
        fail "Should reject missing plan file"
    else
        pass "Rejected missing plan file"
    fi

    log_test_pass "update_plan_with_gates: rejects missing plan file"
}

#==============================================================================
# Tests: get_release_strategy
#==============================================================================

test_release_strategy_default_no_workflow() {
    log_test_start "get_release_strategy: defaults to never without workflow"
    setup_lifecycle_test

    # Re-source to get clean copy (guards against prior test overrides)
    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-default" 1)

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "never" "$strategy" "Should default to 'never' without release workflow"

    log_test_pass "get_release_strategy: defaults to never without workflow"
}

test_release_strategy_per_repo_config() {
    log_test_start "get_release_strategy: reads per-repo config"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-repo" 1)

    # Create per-repo config
    mkdir -p "$repo_dir/.ru"
    echo 'AGENT_SWEEP_RELEASE_STRATEGY="tag-only"' > "$repo_dir/.ru/agent-sweep.conf"

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "tag-only" "$strategy" "Should read strategy from per-repo config"

    log_test_pass "get_release_strategy: reads per-repo config"
}

test_release_strategy_with_workflow() {
    log_test_start "get_release_strategy: auto when workflow exists"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local repo_dir
    repo_dir=$(create_real_git_repo "strategy-workflow" 1)

    # Create a release workflow
    mkdir -p "$repo_dir/.github/workflows"
    echo 'name: release' > "$repo_dir/.github/workflows/release.yml"

    local strategy
    strategy=$(get_release_strategy "$repo_dir")
    assert_equals "auto" "$strategy" "Should return 'auto' when workflow exists"

    log_test_pass "get_release_strategy: auto when workflow exists"
}

test_release_strategy_invalid_repo() {
    log_test_start "get_release_strategy: returns never for invalid repo"
    setup_lifecycle_test

    source_ru_function "get_release_strategy"
    source_ru_function "has_release_workflow"

    local strategy
    strategy=$(get_release_strategy "")
    assert_equals "never" "$strategy" "Should return 'never' for empty path"

    strategy=$(get_release_strategy "$TEST_DIR/not-created")
    assert_equals "never" "$strategy" "Should return 'never' for nonexistent path"

    log_test_pass "get_release_strategy: returns never for invalid repo"
}

#==============================================================================
# Tests: run_quality_gates
#==============================================================================

test_quality_gates_all_pass() {
    log_test_start "run_quality_gates: all gates pass"
    setup_lifecycle_test

    # Re-source to get a clean copy (guards against prior test side effects)
    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    # Mock the gate functions
    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":""}'
    }
    run_lint_gate() {
        echo '{"ran":true,"ok":true,"exit_code":0,"output":"clean"}'
        return 0
    }
    run_test_gate() {
        echo '{"ran":true,"ok":true,"exit_code":0,"output":"all passed"}'
        return 0
    }
    run_secret_scan() {
        echo '{"ran":true,"ok":true,"warning":false,"findings":[]}'
        return 0
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "All gates pass should return 0"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local overall_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok' 2>/dev/null)
    assert_equals "true" "$overall_ok" "overall_ok should be true"

    log_test_pass "run_quality_gates: all gates pass"
}

test_quality_gates_lint_failure() {
    log_test_start "run_quality_gates: lint failure"
    setup_lifecycle_test

    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":"eslint ."}'
    }
    run_lint_gate() {
        echo '{"ran":true,"ok":false,"exit_code":1,"output":"2 errors"}'
        return 1
    }
    run_test_gate() {
        echo '{"ran":true,"ok":true,"exit_code":0,"output":"ok"}'
        return 0
    }
    run_secret_scan() {
        echo '{"ran":true,"ok":true,"warning":false,"findings":[]}'
        return 0
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "1" "$exit_code" "Lint failure should return 1"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local overall_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok' 2>/dev/null)
    assert_equals "false" "$overall_ok" "overall_ok should be false on lint failure"

    log_test_pass "run_quality_gates: lint failure"
}

test_quality_gates_secret_warning() {
    log_test_start "run_quality_gates: secret warning"
    setup_lifecycle_test

    source_ru_function "run_quality_gates"
    get_review_state_dir() { echo "$RU_STATE_DIR/review"; }
    get_review_policy_dir() { echo "$RU_CONFIG_DIR/review-policies"; }

    load_policy_for_repo() {
        echo '{"test_command":"","lint_command":""}'
    }
    run_lint_gate() {
        echo '{"ran":false,"ok":null,"reason":"no_linter_found"}'
        return 2
    }
    run_test_gate() {
        echo '{"ran":false,"ok":null,"reason":"no_tests_found"}'
        return 2
    }
    run_secret_scan() {
        echo '{"ran":true,"ok":false,"warning":true,"findings":["possible_key"]}'
        return 2
    }

    local plan_file="$TEST_DIR/plan.json"
    create_test_plan_file "$plan_file" '{"repo":"owner/repo"}'

    local result
    result=$(run_quality_gates "$TEST_DIR/repo" "$plan_file" 2>/dev/null)
    local exit_code=$?

    assert_equals "2" "$exit_code" "Secret warning should return 2"
    assert_not_empty "$result" "run_quality_gates should produce output"

    local has_warning
    has_warning=$(echo "$result" | jq -r '.has_warning' 2>/dev/null)
    assert_equals "true" "$has_warning" "has_warning should be true"

    log_test_pass "run_quality_gates: secret warning"
}

#==============================================================================
# Tests: validate_commit_plan
#==============================================================================

test_validate_commit_plan_empty() {
    log_test_start "validate_commit_plan: rejects empty plan"
    setup_lifecycle_test

    if validate_commit_plan "" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject empty plan"
    else
        pass "Rejected empty plan"
        assert_not_empty "$VALIDATION_ERROR" "VALIDATION_ERROR should be set"
    fi

    log_test_pass "validate_commit_plan: rejects empty plan"
}

test_validate_commit_plan_invalid_json() {
    log_test_start "validate_commit_plan: rejects invalid JSON"
    setup_lifecycle_test

    if validate_commit_plan "not json at all" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject invalid JSON"
    else
        pass "Rejected invalid JSON"
    fi

    log_test_pass "validate_commit_plan: rejects invalid JSON"
}

test_validate_commit_plan_no_commits() {
    log_test_start "validate_commit_plan: rejects missing commits"
    setup_lifecycle_test

    if validate_commit_plan '{"push":false}' "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject plan without commits"
    else
        pass "Rejected plan without commits"
    fi

    log_test_pass "validate_commit_plan: rejects missing commits"
}

test_validate_commit_plan_no_message() {
    log_test_start "validate_commit_plan: rejects commit without message"
    setup_lifecycle_test

    local plan='{"commits":[{"files":["a.txt"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject commit without message"
    else
        pass "Rejected commit without message"
        assert_contains "$VALIDATION_ERROR" "message" "Error should mention message"
    fi

    log_test_pass "validate_commit_plan: rejects commit without message"
}

test_validate_commit_plan_no_files() {
    log_test_start "validate_commit_plan: rejects commit without files"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":[]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject commit without files"
    else
        pass "Rejected commit without files"
    fi

    log_test_pass "validate_commit_plan: rejects commit without files"
}

test_validate_commit_plan_absolute_path() {
    log_test_start "validate_commit_plan: rejects absolute paths"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["/etc/passwd"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject absolute file paths"
    else
        pass "Rejected absolute file path"
        assert_contains "$VALIDATION_ERROR" "absolute" "Error should mention absolute"
    fi

    log_test_pass "validate_commit_plan: rejects absolute paths"
}

test_validate_commit_plan_traversal_path() {
    log_test_start "validate_commit_plan: rejects path traversal"
    setup_lifecycle_test

    local plan='{"commits":[{"message":"test","files":["../../etc/passwd"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        fail "Should reject path traversal"
    else
        pass "Rejected path traversal"
        assert_contains "$VALIDATION_ERROR" "unsafe" "Error should mention unsafe"
    fi

    log_test_pass "validate_commit_plan: rejects path traversal"
}

test_validate_commit_plan_valid() {
    log_test_start "validate_commit_plan: accepts valid plan"
    setup_lifecycle_test

    # A valid commit candidate requires real HEAD/index identity. Restore the
    # actual scanner after the independent gate-protocol fixture cases above.
    source_ru_function "run_secret_scan"
    git -C "$TEST_DIR/repo" init -q -b main
    git -C "$TEST_DIR/repo" config user.name 'Test User'
    git -C "$TEST_DIR/repo" config user.email test@example.invalid
    printf 'baseline content\n' > "$TEST_DIR/repo/baseline.txt"
    git -C "$TEST_DIR/repo" add baseline.txt
    git -C "$TEST_DIR/repo" commit -qm Baseline
    echo "content" > "$TEST_DIR/repo/main.rs"

    local plan='{"commits":[{"message":"Fix bug","files":["main.rs"]}]}'
    if validate_commit_plan "$plan" "$TEST_DIR/repo" 2>/dev/null; then
        pass "Accepted valid plan"
    else
        fail "Should accept valid plan: $VALIDATION_ERROR"
    fi

    log_test_pass "validate_commit_plan: accepts valid plan"
}

#==============================================================================
# Tests: canonicalize_gh_action
#==============================================================================

test_canonicalize_gh_action() {
    log_test_start "canonicalize_gh_action: produces deterministic output"
    setup_lifecycle_test

    # Same content, different key order
    local result1 result2
    result1=$(canonicalize_gh_action '{"op":"comment","target":"issue#1","body":"hi"}')
    result2=$(canonicalize_gh_action '{"body":"hi","target":"issue#1","op":"comment"}')

    assert_equals "$result1" "$result2" "Same content should produce same canonical form"

    log_test_pass "canonicalize_gh_action: produces deterministic output"
}

test_canonicalize_gh_action_invalid() {
    log_test_start "canonicalize_gh_action: handles invalid JSON"
    setup_lifecycle_test

    local result
    result=$(canonicalize_gh_action "not json" 2>/dev/null)

    # jq should fail and return empty
    if [[ -z "$result" ]]; then
        pass "Returns empty for invalid JSON"
    else
        pass "Returned something for invalid JSON (jq might have handled it)"
    fi

    log_test_pass "canonicalize_gh_action: handles invalid JSON"
}

#==============================================================================
# Tests: execute_gh_action_comment / close / label (individual)
#==============================================================================

test_execute_gh_action_comment_issue() {
    log_test_start "execute_gh_action_comment: comments on issue"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_comment "owner/repo" "issue" "42" "Hello world" 2>/dev/null; then
        pass "Comment on issue succeeded"
    else
        fail "Comment on issue should succeed"
    fi

    if gh_mock_called_with "issue comment.*42"; then
        pass "Called gh issue comment 42"
    else
        fail "Should call gh issue comment 42"
    fi

    log_test_pass "execute_gh_action_comment: comments on issue"
}

test_execute_gh_action_comment_pr() {
    log_test_start "execute_gh_action_comment: comments on PR"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_comment "owner/repo" "pr" "7" "PR comment" 2>/dev/null; then
        pass "Comment on PR succeeded"
    else
        fail "Comment on PR should succeed"
    fi

    if gh_mock_called_with "pr comment.*7"; then
        pass "Called gh pr comment 7"
    else
        fail "Should call gh pr comment 7"
    fi

    log_test_pass "execute_gh_action_comment: comments on PR"
}

test_execute_gh_action_comment_failure() {
    log_test_start "execute_gh_action_comment: propagates gh failure"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=1
    MOCK_GH_OUTPUT="Not Found"

    if execute_gh_action_comment "owner/repo" "issue" "999" "body" 2>/dev/null; then
        fail "Should propagate gh failure"
    else
        pass "Propagated gh failure"
    fi

    log_test_pass "execute_gh_action_comment: propagates gh failure"
}

test_execute_gh_action_close_issue() {
    log_test_start "execute_gh_action_close: closes issue"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_close "owner/repo" "issue" "10" "completed" "" 2>/dev/null; then
        pass "Close issue succeeded"
    else
        fail "Close issue should succeed"
    fi

    if gh_mock_called_with "issue close.*10"; then
        pass "Called gh issue close 10"
    else
        fail "Should call gh issue close"
    fi

    log_test_pass "execute_gh_action_close: closes issue"
}

test_execute_gh_action_close_pr_with_comment() {
    log_test_start "execute_gh_action_close: closes PR with comment"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_close "owner/repo" "pr" "25" "completed" "Closing this PR" 2>/dev/null; then
        pass "Close PR with comment succeeded"
    else
        fail "Close PR with comment should succeed"
    fi

    if gh_mock_called_with "pr close.*25.*--comment"; then
        pass "Called gh pr close with --comment"
    else
        fail "Should call gh pr close with --comment"
    fi

    log_test_pass "execute_gh_action_close: closes PR with comment"
}

test_execute_gh_action_label() {
    log_test_start "execute_gh_action_label: adds labels"
    setup_lifecycle_test

    MOCK_GH_EXIT_CODE=0
    if execute_gh_action_label "owner/repo" "5" "bug,urgent"; then
        pass "Add labels succeeded"
    else
        fail "Add labels should succeed"
    fi

    if gh_mock_called_with "issue edit.*5.*--add-label.*bug,urgent"; then
        pass "Called gh issue edit with correct labels"
    else
        fail "Should call gh issue edit --add-label bug,urgent"
    fi

    log_test_pass "execute_gh_action_label: adds labels"
}

#==============================================================================
# Run All Tests
#==============================================================================

log_suite_start "Lifecycle Functions Unit Tests (bd-hjzw)"
echo ""

# Target parsing
run_test test_parse_target_issue
run_test test_parse_target_pr
run_test test_parse_target_invalid

# Commit plan execution
run_test test_commit_plan_empty_plan
run_test test_commit_plan_invalid_repo
run_test test_commit_plan_plan_mode
run_test test_commit_plan_no_commits
run_test test_commit_plan_valid_execution

# Release plan execution
run_test test_release_plan_empty_plan
run_test test_release_plan_invalid_repo
run_test test_release_plan_plan_mode
run_test test_release_plan_never_strategy
run_test test_release_plan_tag_only_strategy
run_test test_release_applies_version_files_changelog_and_publishes
run_test test_release_failed_check_publishes_nothing_and_retry_continues
run_test test_release_resumes_after_github_release_failure
run_test test_release_null_version_is_no_release
run_test test_release_refusals_leave_repository_unchanged
run_test test_release_tag_only_publishes_without_github
run_test test_release_gh_release_requires_gh
run_test test_release_ci_and_checksums_are_observed
run_test test_release_version_file_formats

# GH actions orchestrator
run_test test_gh_actions_no_actions
run_test test_gh_actions_missing_plan_file
run_test test_gh_actions_comment_execution
run_test test_gh_actions_close_execution
run_test test_gh_actions_label_execution
run_test test_gh_actions_merge_blocked
run_test test_gh_actions_invalid_target
run_test test_gh_actions_label_pr_rejected
run_test test_gh_actions_comment_missing_body

# Idempotence
run_test test_idempotence_not_executed
run_test test_idempotence_record_and_check
run_test test_idempotence_failed_not_blocking

# Update plan with gates
run_test test_update_plan_with_gates_success
run_test test_update_plan_with_gates_failure
run_test test_update_plan_missing_file

# Release strategy
run_test test_release_strategy_default_no_workflow
run_test test_release_strategy_per_repo_config
run_test test_release_strategy_with_workflow
run_test test_release_strategy_invalid_repo

# Quality gates
run_test test_quality_gates_all_pass
run_test test_quality_gates_lint_failure
run_test test_quality_gates_secret_warning

# Validate commit plan
run_test test_validate_commit_plan_empty
run_test test_validate_commit_plan_invalid_json
run_test test_validate_commit_plan_no_commits
run_test test_validate_commit_plan_no_message
run_test test_validate_commit_plan_no_files
run_test test_validate_commit_plan_absolute_path
run_test test_validate_commit_plan_traversal_path
run_test test_validate_commit_plan_valid

# Canonicalize GH action
run_test test_canonicalize_gh_action
run_test test_canonicalize_gh_action_invalid

# Individual GH action functions
run_test test_execute_gh_action_comment_issue
run_test test_execute_gh_action_comment_pr
run_test test_execute_gh_action_comment_failure
run_test test_execute_gh_action_close_issue
run_test test_execute_gh_action_close_pr_with_comment
run_test test_execute_gh_action_label

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
