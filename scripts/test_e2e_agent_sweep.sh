#!/usr/bin/env bash
#
# E2E Test: ru agent-sweep workflow
#
# Coverage:
# - dry-run listing of dirty repos
# - json dry-run output
# - single repo success with ntm/tmux mocks
# - preflight rebase detection
# - --repos glob vs plain-text selection, -j forms, --show-denylist, --debug/-d
# - ai-sync: a leading --dry-run stays a dry run; --include/--exclude globs
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test framework (test_e2e_framework.sh sources test_framework.sh internally)
source "$SCRIPT_DIR/test_e2e_framework.sh"

create_dirty_repo() {
    local name="$1"
    local repo_dir="$RU_PROJECTS_DIR/$name"
    local remote_dir="$E2E_TEMP_DIR/remotes/$name.git"

    # Create bare remote first
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare >/dev/null 2>&1

    # Create the working repo
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    echo "initial" > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md >/dev/null 2>&1
    git -C "$repo_dir" commit -m "init" >/dev/null 2>&1

    # Set up remote and push
    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1 || \
        git -C "$repo_dir" push -u origin master >/dev/null 2>&1

    # Create dirty file (must match mock tmux plan output: modified.txt)
    echo "dirty" > "$repo_dir/modified.txt"

    echo "$repo_dir"
}

test_agent_sweep_dry_run_lists_repo() {
    local test_name="agent-sweep: dry-run lists dirty repo"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_exit 0 "agent-sweep --dry-run" "dry-run exits 0"
    e2e_assert_ru_stderr_contains "agent-sweep --dry-run" "testrepo" "dry-run lists repo"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_json_dry_run() {
    local test_name="agent-sweep: json dry-run output"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_json "agent-sweep --dry-run --json" ".data.mode" "dry-run" "json mode is dry-run"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_single_repo_success() {
    local test_name="agent-sweep: single repo succeeds with mocks"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_exit 0 "agent-sweep" "agent-sweep exits 0 with mock ntm"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_preflight_rebase_in_progress() {
    local test_name="agent-sweep: preflight detects rebase in progress"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    mkdir -p "$repo_dir/.git/rebase-apply"

    e2e_assert_ru_exit 2 "agent-sweep --json" "preflight failure returns exit 2"

    local preflight_file="$XDG_STATE_HOME/ru/agent-sweep/preflight_results.ndjson"
    assert_true "[[ -f \"$preflight_file\" ]]" "preflight results file exists"
    assert_true "grep -q 'rebase_in_progress' \"$preflight_file\"" "rebase_in_progress recorded"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_json_run_is_one_object() {
    local test_name="agent-sweep: a real --json run prints exactly one JSON result"
    log_test_start "$test_name"

    # ntm prints "Killed session ..." on stdout when ru removes a finished
    # session (the mock prints "killed"); that used to corrupt the result,
    # so a successful sweep reported invalid_structured_output and exit 3.
    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    local out exit_code=0
    out=$("$E2E_RU_SCRIPT" agent-sweep --json 2>/dev/null) || exit_code=$?
    assert_equals "0" "$exit_code" "real --json sweep exits 0"
    if printf '%s\n' "$out" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
        pass "stdout is exactly one JSON object"
    else
        fail "stdout is exactly one JSON object" "Got: $(printf '%s' "$out" | head -c 300)"
    fi
    assert_equals "1" "$(printf '%s\n' "$out" | jq -r '.data.summary.succeeded // empty' 2>/dev/null)" "the summary reports the successful repo"

    e2e_cleanup
    log_test_pass "$test_name"
}

# The README's documented agent-sweep flags, run through the full CLI. Globs
# are passed as quoted arguments, never word-split by this shell.
test_agent_sweep_repos_glob_selects_matching() {
    local test_name="agent-sweep: --repos glob selects only matching repos"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "demo-app" >/dev/null
    create_dirty_repo "other" >/dev/null
    e2e_add_repo "example/demo-app"
    e2e_add_repo "example/other"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" agent-sweep --dry-run '--repos=demo*' 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "glob dry-run exits 0"
    assert_contains "$output" "demo-app" "glob demo* selects demo-app"
    assert_not_contains "$output" "- other" "glob demo* leaves other out"

    exit_code=0
    output=$("$E2E_RU_SCRIPT" agent-sweep --dry-run --repos=other 2>&1) || exit_code=$?
    assert_contains "$output" "other" "plain text still selects by substring"
    assert_not_contains "$output" "demo-app" "plain text other leaves demo-app out"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_parallel_flags_reach_sweep() {
    local test_name="agent-sweep: -j4 and -j 3 set the sweep's parallelism"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_stderr_contains "agent-sweep --dry-run -j4" "up to 4 agents in parallel" "-j4 reaches agent-sweep"
    e2e_assert_ru_stderr_contains "agent-sweep --dry-run -j 3" "up to 3 agents in parallel" "-j 3 reaches agent-sweep"
    e2e_assert_ru_stderr_contains "-j2 agent-sweep --dry-run" "up to 2 agents in parallel" "-j2 before the command reaches agent-sweep"
    e2e_assert_ru_stderr_contains "agent-sweep --dry-run" "up to 1 agents in parallel" "default is one agent"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_show_denylist() {
    local test_name="agent-sweep: --show-denylist lists patterns without expanding them"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    # A file that the extra pattern would expand to if it were globbed
    touch "$E2E_TEMP_DIR/leak.custom"

    local output exit_code=0
    output=$(cd "$E2E_TEMP_DIR" && AGENT_SWEEP_DENYLIST_EXTRA='*.custom internal_docs/*' \
        "$E2E_RU_SCRIPT" agent-sweep --show-denylist 2>/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "--show-denylist exits 0"
    assert_contains "$output" ".env" "default patterns are listed"
    assert_contains "$output" "*.pem" "default glob patterns are listed verbatim"
    assert_contains "$output" "*.custom" "extra pattern is listed verbatim"
    assert_contains "$output" "internal_docs/*" "second extra pattern is listed"
    assert_not_contains "$output" "leak.custom" "extra pattern is not expanded against files"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_agent_sweep_debug_flag() {
    local test_name="agent-sweep: --debug and -d enable debug output"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_ntm
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    e2e_assert_ru_exit 0 "agent-sweep --debug --dry-run" "--debug is accepted"
    e2e_assert_ru_stderr_contains "agent-sweep --debug --dry-run" "[DEBUG]" "--debug prints debug lines"
    e2e_assert_ru_stderr_contains "agent-sweep -d --dry-run" "[DEBUG]" "-d prints debug lines"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ai-sync uses the same dirty-repo selection. Agent and multiplexer tools are
# replaced by stubs that record any call, so a regression that ignores
# --dry-run cannot start a real AI session from this test.
stub_agent_tools() {
    local tool
    for tool in claude codex gemini ntm tmux; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/agent_calls.log"\nexit 1\n' \
            "$tool" "$E2E_TEMP_DIR" > "$E2E_MOCK_BIN/$tool"
        chmod +x "$E2E_MOCK_BIN/$tool"
    done
}

test_ai_sync_leading_dry_run_is_a_dry_run() {
    local test_name="ai-sync: --dry-run before the command is still a dry run"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru
    stub_agent_tools

    local repo_dir head_before
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"
    head_before=$(git -C "$repo_dir" rev-parse HEAD)

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" --dry-run ai-sync 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru --dry-run ai-sync exits 0"
    assert_contains "$output" "Dry run - would process" "ru --dry-run ai-sync only previews"
    assert_not_contains "$output" "Processing:" "no repository is processed"
    assert_equals "$head_before" "$(git -C "$repo_dir" rev-parse HEAD)" "repository HEAD is unchanged"
    assert_true "[[ ! -s \"$E2E_TEMP_DIR/agent_calls.log\" ]]" "no agent or tmux tool was called"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_ai_sync_include_exclude_globs() {
    local test_name="ai-sync: --include/--exclude globs match repo names"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru
    stub_agent_tools

    create_dirty_repo "demo-app" >/dev/null
    create_dirty_repo "other" >/dev/null
    e2e_add_repo "example/demo-app"
    e2e_add_repo "example/other"

    local output
    output=$("$E2E_RU_SCRIPT" ai-sync --dry-run '--exclude=demo*' 2>&1)
    assert_contains "$output" "other" "--exclude=demo* keeps other"
    assert_not_contains "$output" "demo-app" "--exclude=demo* drops demo-app"

    output=$("$E2E_RU_SCRIPT" ai-sync --dry-run '--include=demo*' 2>&1)
    assert_contains "$output" "demo-app" "--include=demo* keeps demo-app"
    assert_not_contains "$output" "  other" "--include=demo* drops other"

    output=$("$E2E_RU_SCRIPT" ai-sync --dry-run --include=other 2>&1)
    assert_contains "$output" "other" "plain --include still matches by substring"
    assert_not_contains "$output" "demo-app" "plain --include=other drops demo-app"

    e2e_cleanup
    log_test_pass "$test_name"
}

# Run tests
setup_cleanup_trap
run_test test_agent_sweep_dry_run_lists_repo
run_test test_agent_sweep_json_dry_run
run_test test_agent_sweep_single_repo_success
run_test test_preflight_rebase_in_progress
run_test test_agent_sweep_json_run_is_one_object
run_test test_agent_sweep_repos_glob_selects_matching
run_test test_agent_sweep_parallel_flags_reach_sweep
run_test test_agent_sweep_show_denylist
run_test test_agent_sweep_debug_flag
run_test test_ai_sync_leading_dry_run_is_a_dry_run
run_test test_ai_sync_include_exclude_globs
print_results
exit "$(get_exit_code)"
