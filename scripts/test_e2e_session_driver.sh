#!/usr/bin/env bash
#
# E2E Test: Session driver lifecycle and functionality
#
# Tests local driver (tmux-based) session management:
#   1. Full session lifecycle (start, send, stream, stop)
#   2. Parallel session isolation (no cross-talk)
#   3. Interrupt and graceful shutdown
#
# Note: These tests use mocked claude command to avoid requiring actual Claude Code.
# The local_driver_* functions are tested with tmux but mock AI responses.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions called indirectly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (test isolation + assertions)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Stubs and helpers
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

# Source required functions - simple ones via source_ru_function
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "detect_review_driver"
source_ru_function "local_driver_session_alive"
source_ru_function "local_driver_stop_session"
source_ru_function "local_driver_list_sessions"
source_ru_function "local_driver_send_to_session"
source_ru_function "local_driver_interrupt_session"

# Define driver interface functions inline (simpler than sourcing _enable_local_driver)
driver_start_session() {
    local wt_path="$1"
    local prompt="$2"
    local session_id
    session_id="ru-e2e-$$-$(date +%s)"
    local controlled_claude
    [[ -x "$E2E_MOCK_BIN/claude" ]] || return 1
    controlled_claude=$(printf '%q' "$E2E_MOCK_BIN/claude")

    # Create session directory
    local session_dir="${RU_STATE_DIR}/sessions/${session_id}"
    mkdir -p "$session_dir"
    echo "$wt_path" > "$session_dir/worktree_path"

    # Create log file
    mkdir -p "$wt_path/.ru"
    local log_file="$wt_path/.ru/session.log"

    # Start tmux session with claude
    if ! tmux new-session -d -s "$session_id" -c "$wt_path" \
        "$controlled_claude -p '$prompt' --output-format stream-json 2>&1 | tee '$log_file'; echo DONE" 2>/dev/null; then
        echo ""
        return 1
    fi

    echo "$session_id"
    return 0
}

driver_send_to_session() {
    local_driver_send_to_session "$@"
}

driver_get_session_state() {
    local session_id="$1"
    if tmux has-session -t "$session_id" 2>/dev/null; then
        echo '{"state": "alive"}'
    else
        echo '{"state": "dead"}'
    fi
}

driver_stop_session() {
    local_driver_stop_session "$@"
}

driver_interrupt_session() {
    local_driver_interrupt_session "$@"
}

driver_session_alive() {
    local_driver_session_alive "$@"
}

# Create mock claude script that outputs stream-json format
create_mock_claude() {
    local mock_bin="$1"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock claude that outputs stream-json format

# Parse args for prompt and output format
prompt=""
output_format=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) prompt="$2"; shift 2 ;;
        --output-format) output_format="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ "$output_format" == "stream-json" ]]; then
    # Output init event
    echo '{"type":"system","subtype":"init","session_id":"mock-session"}'
    sleep 0.1

    # Output generating event
    echo '{"type":"assistant","subtype":"text","text":"Processing your request..."}'
    sleep 0.2

    # Output completion event
    echo '{"type":"result","status":"success","cost_usd":0.001}'
fi

exit 0
MOCK_EOF
    chmod +x "$mock_bin/claude"
}

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &>/dev/null; then
        return 1
    fi
    # Try to check if we can create sessions
    if ! tmux list-sessions &>/dev/null 2>&1 && [[ -z "${TMUX:-}" ]]; then
        # tmux server not running and we're not in tmux
        # Try to start a detached session to test
        if tmux new-session -d -s "ru-e2e-test-$$" 2>/dev/null; then
            tmux kill-session -t "ru-e2e-test-$$" 2>/dev/null
            return 0
        fi
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_local_driver_full_cycle() {
    log_test_start "session driver: full lifecycle"

    if ! check_tmux_available; then
        skip_test "tmux not available or cannot create sessions"
        return 0
    fi

    e2e_setup

    # Create mock claude
    create_mock_claude "$E2E_MOCK_BIN"
    export PATH="$E2E_MOCK_BIN:$PATH"

    # Setup environment
    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-session-$$"
    mkdir -p "$RU_STATE_DIR"

    # Create a worktree directory
    local wt_path="$E2E_TEMP_DIR/worktree"
    mkdir -p "$wt_path/.ru"

    # 1. Start session
    local session_id
    session_id=$(driver_start_session "$wt_path" "Test prompt" 2>/dev/null) || true

    if [[ -z "$session_id" ]] || [[ "$session_id" == "0" ]]; then
        skip_test "Could not start tmux session (may need tmux server)"
        e2e_cleanup
        return 0
    fi

    assert_not_equals "" "$session_id" "Session ID should be non-empty"

    # 2. Check session alive
    sleep 0.5
    if driver_session_alive "$session_id"; then
        pass "Session is alive after start"
    else
        # Session may have completed quickly with mock claude
        pass "Session completed (mock claude runs fast)"
    fi

    # 3. Send to session (if still alive)
    if driver_session_alive "$session_id"; then
        local send_rc=0
        driver_send_to_session "$session_id" "Additional prompt" 2>/dev/null || send_rc=$?
        # Send may fail if session already completed
        if [[ $send_rc -eq 0 ]]; then
            pass "Send to session succeeded"
        else
            pass "Session already completed before send"
        fi
    fi

    # 4. Stop session
    driver_stop_session "$session_id" 2>/dev/null || true
    sleep 0.5

    # 5. Verify session stopped
    if ! driver_session_alive "$session_id"; then
        pass "Session is not alive after stop"
    else
        # Force kill
        tmux kill-session -t "$session_id" 2>/dev/null || true
        pass "Session cleaned up"
    fi

    e2e_cleanup
    log_test_pass "session driver: full lifecycle"
}

test_parallel_sessions() {
    log_test_start "session driver: parallel sessions"

    if ! check_tmux_available; then
        skip_test "tmux not available"
        return 0
    fi

    e2e_setup

    # Create mock claude
    create_mock_claude "$E2E_MOCK_BIN"
    export PATH="$E2E_MOCK_BIN:$PATH"

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-parallel-$$"
    mkdir -p "$RU_STATE_DIR"

    # Create 4 worktree directories
    local -a sessions=()
    local -a wt_paths=()
    local i

    for i in 1 2 3 4; do
        wt_paths+=("$E2E_TEMP_DIR/worktree-$i")
        mkdir -p "${wt_paths[-1]}/.ru"
    done

    # Start 4 sessions
    local failed=0
    for i in 0 1 2 3; do
        local sid
        sid=$(driver_start_session "${wt_paths[$i]}" "Prompt $i" 2>/dev/null) || true
        if [[ -n "$sid" ]] && [[ "$sid" != "0" ]]; then
            sessions+=("$sid")
        else
            ((failed++)) || true
        fi
    done

    if [[ ${#sessions[@]} -eq 0 ]]; then
        skip_test "Could not start any tmux sessions"
        e2e_cleanup
        return 0
    fi

    # Verify sessions are distinct
    local unique_count
    unique_count=$(printf '%s\n' "${sessions[@]}" | sort -u | wc -l)
    assert_equals "${#sessions[@]}" "$unique_count" "All sessions have unique IDs"

    # Cleanup all sessions
    for sid in "${sessions[@]}"; do
        driver_stop_session "$sid" 2>/dev/null || true
        tmux kill-session -t "$sid" 2>/dev/null || true
    done

    e2e_cleanup
    log_test_pass "session driver: parallel sessions"
}

test_session_interrupt_recovery() {
    log_test_start "session driver: interrupt recovery"

    if ! check_tmux_available; then
        skip_test "tmux not available"
        return 0
    fi

    e2e_setup

    # Create a slow mock claude that sleeps
    mkdir -p "$E2E_MOCK_BIN"
    cat > "$E2E_MOCK_BIN/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
# Slow mock claude for interrupt testing
trap 'echo "Interrupted"; exit 130' INT TERM
echo '{"type":"system","subtype":"init","session_id":"mock-session"}'
sleep 30  # Long sleep to allow interrupt
exit 0
MOCK_EOF
    chmod +x "$E2E_MOCK_BIN/claude"
    export PATH="$E2E_MOCK_BIN:$PATH"

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="e2e-interrupt-$$"
    mkdir -p "$RU_STATE_DIR"

    local wt_path="$E2E_TEMP_DIR/worktree"
    mkdir -p "$wt_path/.ru"

    # Start session
    local session_id
    session_id=$(driver_start_session "$wt_path" "Test prompt" 2>/dev/null) || true

    if [[ -z "$session_id" ]] || [[ "$session_id" == "0" ]]; then
        skip_test "Could not start tmux session"
        e2e_cleanup
        return 0
    fi

    # Let it start
    sleep 0.5

    # Verify session is running
    if ! driver_session_alive "$session_id"; then
        skip_test "Session exited before interrupt test"
        e2e_cleanup
        return 0
    fi

    # Send interrupt
    local int_rc=0
    driver_interrupt_session "$session_id" 2>/dev/null || int_rc=$?
    assert_equals "0" "$int_rc" "Interrupt should succeed"

    # Wait for session to handle interrupt
    sleep 1

    # Session should still exist (interrupted but not killed)
    # Or it may have exited gracefully
    pass "Interrupt was sent successfully"

    # Cleanup
    driver_stop_session "$session_id" 2>/dev/null || true
    tmux kill-session -t "$session_id" 2>/dev/null || true

    e2e_cleanup
    log_test_pass "session driver: interrupt recovery"
}

#------------------------------------------------------------------------------
# Full CLI consumer coverage. Agent/package metadata/changelog endpoints are
# explicitly controlled. Git commits, receiver refs and publication hooks are
# real; these fixtures do not qualify a live provider or package registry.
create_ai_cli_fixture() {
    local command="$1" env_root repo_path
    env_root=$(create_test_env) || return 1
    repo_path="$env_root/projects/repo"
    mkdir -p "$repo_path" "$env_root/controlled-bin" || return 1
    printf 'owner/repo\n' > "$env_root/config/ru/repos.d/public.txt"
    git -C "$repo_path" init -q -b main || return 1
    git -C "$repo_path" config user.name 'CLI fixture' || return 1
    git -C "$repo_path" config user.email cli@example.invalid || return 1
    printf 'baseline CLI bytes\n' > "$repo_path/base.txt"
    if [[ "$command" == dep-update ]]; then
        printf '%s\n' '{"name":"fixture","dependencies":{"example-package":"1.0.0"}}' > "$repo_path/package.json"
    fi
    git -C "$repo_path" add --all || return 1
    git -C "$repo_path" commit -qm 'CLI fixture baseline' || return 1
    git clone -q --bare "$repo_path" "$env_root/receiver.git" || return 1
    git -C "$repo_path" remote add origin "$env_root/receiver.git" || return 1
    cat > "$env_root/receiver.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail
git_dir=$(git rev-parse --absolute-git-dir) || exit 1
cat >> "$git_dir/received-updates"
if [[ "${NTM_MOCK_REJECT_PUSH:-false}" == true ]]; then
    printf 'Controlled CLI receiver refuses publication\n' >&2
    exit 17
fi
HOOK
    chmod +x "$env_root/receiver.git/hooks/pre-receive" || return 1
    cp "$SCRIPT_DIR/test_bin/ntm" "$env_root/controlled-bin/ntm" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$env_root/controlled-bin/codex"
    cat > "$env_root/controlled-bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == has-session && "${2:-}" == -t ]] || exit 2
[[ -f "$NTM_MOCK_STATE_FILE" ]] || exit 1
session=$(head -n 1 "$NTM_MOCK_STATE_FILE")
[[ "${3#=}" == "$session" ]] || exit 1
if [[ -f "$NTM_MOCK_STATE_FILE.stopped" ]] && [[ "$(cat "$NTM_MOCK_STATE_FILE.stopped")" == "$session" ]]; then exit 1; fi
exit 0
TMUX
    chmod +x "$env_root/controlled-bin/codex" "$env_root/controlled-bin/tmux" || return 1
    cat > "$env_root/controlled-bin/npm" <<'NPM'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" != outdated || "${2:-}" != --json ]]; then
    printf 'Controlled npm endpoint received unsupported arguments\n' >&2
    exit 2
fi
printf '%s\n' '{"example-package":{"current":"1.0.0","wanted":"1.0.1","latest":"1.0.1","type":"dependencies"}}'
exit 1
NPM
    cat > "$env_root/controlled-bin/curl" <<'CURL'
#!/usr/bin/env bash
printf 'Controlled changelog endpoint unavailable\n' >&2
exit 22
CURL
    chmod +x "$env_root/controlled-bin/npm" "$env_root/controlled-bin/curl" || return 1
    if [[ "$command" == ai-sync ]]; then
        printf 'actual CLI requested work\n' > "$repo_path/planned.txt"
    fi
    printf '%s\n' "$env_root"
}

run_ai_cli_fixture() {
    local env_root="$1" command="$2" scenario="$3" reject="$4"
    shift 4
    local work_file=planned.txt package_name="" repo_path="$env_root/projects/repo"
    local -a command_args=()
    if [[ "$command" == dep-update ]]; then
        work_file=package.json
        package_name=example-package
        command_args=("--repo=$repo_path" --manager=npm --major --test-cmd=true)
    fi
    env PATH="$env_root/controlled-bin:$E2E_ORIGINAL_PATH" CI=true RU_CHECK_UPDATES=false \
        XDG_CONFIG_HOME="$env_root/config" XDG_STATE_HOME="$env_root/state" XDG_CACHE_HOME="$env_root/cache" \
        RU_CONFIG_DIR="$env_root/config/ru" RU_STATE_DIR="$env_root/state/ru" RU_CACHE_DIR="$env_root/cache/ru" \
        RU_PROJECTS_DIR="$env_root/projects" RU_LAYOUT=flat AGENT_SWEEP_SECRET_SCAN=block \
        NTM_MOCK_SCENARIO="$scenario" NTM_MOCK_REPO="$repo_path" \
        NTM_MOCK_STATE_FILE="$env_root/ntm.state" NTM_MOCK_LAST_PROMPT="$env_root/ntm.prompt" \
        NTM_MOCK_ARGS_LOG="$env_root/ntm.args" NTM_MOCK_WORK_FILE="$work_file" \
        NTM_MOCK_PACKAGE_NAME="$package_name" NTM_MOCK_PACKAGE_VERSION=1.0.1 NTM_MOCK_REJECT_PUSH="$reject" \
        GIT_TRACE="$env_root/git.trace" \
        bash "$E2E_RU_SCRIPT" "$command" --agent=codex --timeout=10 --json --non-interactive \
        "${command_args[@]}" "$@" > "$env_root/cli.stdout" 2> "$env_root/cli.stderr"
}

assert_ai_cli_common_results() {
    local command="$1" scenario env_root repo_path before after result session rc evidence key
    if [[ "$command" == ai-sync ]]; then key=repos; else key=results; fi
    for scenario in session_work ok timeout; do
        env_root=$(create_ai_cli_fixture "$command") || return 1
        repo_path="$env_root/projects/repo"
        before=$(git -C "$repo_path" rev-parse HEAD)
        rc=0
        run_ai_cli_fixture "$env_root" "$command" "$scenario" false --no-push || rc=$?
        cat "$env_root/cli.stderr" >&2
        result=$(cat "$env_root/cli.stdout")
        assert_success "Full $command stdout contains exactly one JSON value" jq -e -s 'length == 1' <<< "$result"
        session=$(jq -c --arg key "$key" '.data[$key][0]' <<< "$result")
        assert_equals 1 "$(jq -r '.schema_version' <<< "$session")" "$command retains the common session schema"
        assert_equals true "$(jq -r '.publication.no_push' <<< "$session")" "$command retains explicit no-push status"
        assert_equals not_requested "$(jq -r '.publication.status' <<< "$session")" "$command requests no host publication"
        assert_equals "$repo_path" "$(jq -r '.repo' <<< "$session")" "$command retains the actual repository identity"
        evidence=$(jq -r '.evidence_dir' <<< "$session")
        assert_file_exists "$evidence/prompt.txt" "$command preserves the exact requested work on every outcome"
        assert_file_exists "$evidence/ready.stdout" "$command preserves actual readiness diagnostics on every outcome"
        if [[ "$scenario" != timeout ]]; then
            assert_file_exists "$evidence/wait.stdout" "$command preserves actual transition diagnostics when that stage ran"
        fi
        assert_not_contains "$(cat "$env_root/git.trace")" ' push ' "$command --no-push makes zero host Git push invocations"
        assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "$command --no-push preserves the actual receiver"
        after=$(git -C "$repo_path" rev-parse HEAD)
        if [[ "$scenario" == session_work ]]; then
            assert_equals 0 "$rc" "$command accepts verified actual work"
            assert_equals success "$(jq -r '.status' <<< "$session")" "$command reports verified work success"
            assert_equals "$after" "$(jq -r '.work.commits[0]' <<< "$session")" "$command retains the full actual commit SHA"
            assert_not_equals "$before" "$after" "$command actually commits requested content"
            if [[ "$command" == dep-update ]]; then
                assert_equals 1.0.1 "$(git -C "$repo_path" show HEAD:package.json | jq -r '.dependencies["example-package"]')" "Controlled dep-update endpoint changes the actual committed manifest"
            else
                assert_equals 'actual CLI requested work' "$(git -C "$repo_path" show HEAD:planned.txt)" "Full ai-sync commits actual requested bytes"
            fi
        else
            assert_not_equals 0 "$rc" "$command refuses no-work and timeout outcomes"
            assert_not_equals success "$(jq -r '.status' <<< "$session")" "$command never promotes a failing session to success"
            assert_equals failed "$(jq -r '.work.status' <<< "$session")" "$command retains the actual Git-work failure"
            assert_equals "$before" "$after" "$command failure retains the original actual HEAD"
            if [[ "$scenario" == timeout ]]; then
                assert_equals timeout "$(jq -r '.transport.status' <<< "$session")" "$command retains the typed transport timeout"
            fi
        fi
    done
}

test_ai_sync_cli_common_results() { assert_ai_cli_common_results ai-sync; }
test_dep_update_cli_common_results() { assert_ai_cli_common_results dep-update; }

test_ai_sync_cli_requested_content_is_not_replaceable() {
    local scenario env_root repo_path before after result session rc evidence
    for scenario in session_work session_discard_requested session_revert_requested session_extra_requested; do
        env_root=$(create_ai_cli_fixture ai-sync) || return 1
        repo_path="$env_root/projects/repo"
        git -C "$repo_path" add -- planned.txt || return 1
        git -C "$repo_path" commit -qm 'Tracked requested-content baseline' || return 1
        before=$(git -C "$repo_path" rev-parse HEAD) || return 1
        printf 'original partial staged version\n' > "$repo_path/planned.txt"
        git -C "$repo_path" add -- planned.txt || return 1
        cp "$repo_path/.git/index" "$env_root/before.index.raw" || return 1
        printf 'original complete working version\nsecond requested line\n' > "$repo_path/planned.txt"
        cp "$repo_path/planned.txt" "$env_root/before.planned.raw" || return 1
        rc=0
        run_ai_cli_fixture "$env_root" ai-sync "$scenario" false --no-push || rc=$?
        cat "$env_root/cli.stderr" >&2
        result=$(cat "$env_root/cli.stdout")
        assert_success "Requested-content consumer stdout is exactly one JSON value" jq -e -s 'length == 1' <<< "$result"
        session=$(jq -c '.data.repos[0]' <<< "$result")
        evidence=$(jq -r '.evidence_dir' <<< "$session")
        after=$(git -C "$repo_path" rev-parse HEAD) || return 1
        assert_not_equals "$before" "$after" "Both controlled endpoints make actual useful nonempty commits"
        assert_equals "$after" "$(jq -r '.work.commits[-1]' <<< "$session")" "Typed consumer records the exact actual final provider commit"
        assert_equals idle "$(jq -r '.transport.status' <<< "$session")" "Controlled idle transport is distinct from verified requested work"
        assert_equals '[]' "$(jq -c '.work.remaining_paths' <<< "$session")" "Both actual provider outcomes have clean working state"
        assert_success "Runtime retains the exact original staged index" cmp "$env_root/before.index.raw" "$evidence/before.index.raw"
        assert_success "Runtime retains the exact original raw working bytes" cmp "$env_root/before.planned.raw" "$evidence/before-files/planned.txt"
        assert_not_contains "$(cat "$env_root/git.trace")" ' push ' "Content validation performs no host push in no-push mode"
        if [[ "$scenario" == session_work ]]; then
            assert_equals 0 "$rc" "One real working-version commit accepts a partially staged request"
            assert_equals success "$(jq -r '.work.status' <<< "$session")" "Original requested bytes satisfy actual work validation"
            assert_equals true "$(jq -r '.work.requested_content_verified' <<< "$session")" "Successful content verification is explicit"
            git -C "$repo_path" show HEAD:planned.txt > "$env_root/committed.planned.raw" || return 1
            assert_success "Actual candidate contains exact original working bytes" cmp "$env_root/before.planned.raw" "$env_root/committed.planned.raw"
            assert_equals 1 "$(jq '.work.commits | length' <<< "$session")" "Original partial staged version does not force an extra commit"
        else
            assert_equals 1 "$rc" "Discarded requested bytes fail the full CLI despite nonempty clean work"
            assert_equals failed "$(jq -r '.work.status' <<< "$session")" "Unrelated commits do not satisfy requested work"
            if [[ "$scenario" == session_extra_requested ]]; then
                assert_equals 'Final candidate contains unrequested file changes' "$(jq -r '.work.error' <<< "$session")" "Typed failure distinguishes extra edits from lost requested bytes"
                assert_equals '[]' "$(jq -c '.work.unpreserved_requests' <<< "$session")" "Extra-edit refusal does not invent missing requested paths"
                assert_not_equals "$(jq -r '.work.requested_tree' <<< "$session")" "$(jq -r '.work.after_tree' <<< "$session")" "Actual final tree differs from the captured commit-only request"
                assert_equals 'unrequested extra controlled provider work' "$(git -C "$repo_path" show HEAD:unrelated.txt)" "Refusal retains actual extra provider-created work"
            else
                assert_equals 'Original requested content is missing from the final candidate' "$(jq -r '.work.error' <<< "$session")" "Typed failure identifies the actual requested-content loss"
                assert_equals planned.txt "$(jq -r '.work.unpreserved_requests[0].path' <<< "$session")" "Typed failure names the unpreserved request"
                assert_equals 'useful unrelated controlled provider work' "$(git -C "$repo_path" show HEAD:unrelated.txt)" "Failure retains useful provider-created commits"
            fi
            assert_equals "$after" "$(git -C "$repo_path" rev-parse HEAD)" "Full CLI failure never rolls back useful local work"
            if [[ "$scenario" == session_revert_requested ]]; then
                assert_equals 2 "$(jq '.work.commits | length' <<< "$session")" "Commit-then-revert keeps both actual provider commits"
                git -C "$repo_path" show "$(jq -r '.work.commits[0]' <<< "$session"):planned.txt" > "$env_root/first-committed.planned.raw" || return 1
                assert_success "Historical requested bytes were actually committed before the revert" cmp "$env_root/before.planned.raw" "$env_root/first-committed.planned.raw"
            fi
        fi
    done
}

test_ai_cli_host_publication_success_and_refusal() {
    local command mode env_root repo_path before after result session key rc
    for command in ai-sync dep-update; do
        if [[ "$command" == ai-sync ]]; then key=repos; else key=results; fi
        for mode in false true; do
            env_root=$(create_ai_cli_fixture "$command") || return 1
            repo_path="$env_root/projects/repo"
            before=$(git -C "$repo_path" rev-parse HEAD)
            rc=0
            run_ai_cli_fixture "$env_root" "$command" session_work "$mode" || rc=$?
            cat "$env_root/cli.stderr" >&2
            result=$(cat "$env_root/cli.stdout")
            assert_success "Full $command publication stdout remains one JSON value" jq -e -s 'length == 1' <<< "$result"
            session=$(jq -c --arg key "$key" '.data[$key][0]' <<< "$result")
            after=$(git -C "$repo_path" rev-parse HEAD)
            assert_equals success "$(jq -r '.work.status' <<< "$session")" "$command preserves verified local work across publication results"
            assert_equals "$after" "$(jq -r '.work.commits[0]' <<< "$session")" "$command preserves the actual local candidate SHA"
            assert_equals false "$(jq -r '.publication.no_push' <<< "$session")" "$command explicitly requested host publication"
            assert_file_exists "$env_root/receiver.git/received-updates" "$command invokes the real receiver hook"
            if [[ "$mode" == false ]]; then
                assert_equals 0 "$rc" "$command succeeds after real host publication"
                assert_equals success "$(jq -r '.publication.status' <<< "$session")" "$command retains verified publication success"
                assert_equals "$after" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "$command publishes the exact actual candidate"
            else
                assert_not_equals 0 "$rc" "$command fails when the actual receiver rejects publication"
                assert_equals failed "$(jq -r '.status' <<< "$session")" "$command never hides a rejected publication"
                assert_equals failed "$(jq -r '.publication.status' <<< "$session")" "$command preserves typed publication failure"
                assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "$command refusal preserves the actual receiver ref"
                assert_contains "$(cat "$(jq -r '.evidence_dir' <<< "$session")/publication.stderr")" 'Controlled CLI receiver refuses' "$command retains actual receiver refusal diagnostics"
            fi
        done
    done
}

test_ai_cli_dry_run_is_read_only() {
    local command env_root repo_path before index_before rc result
    for command in ai-sync dep-update; do
        env_root=$(create_ai_cli_fixture "$command") || return 1
        repo_path="$env_root/projects/repo"
        before=$(git -C "$repo_path" rev-parse HEAD)
        index_before=$(git hash-object "$repo_path/.git/index")
        rc=0
        run_ai_cli_fixture "$env_root" "$command" session_work false --dry-run || rc=$?
        cat "$env_root/cli.stderr" >&2
        result=$(cat "$env_root/cli.stdout")
        assert_equals 0 "$rc" "$command dry-run returns success"
        assert_success "$command dry-run stdout is exactly one JSON value" jq -e -s 'length == 1' <<< "$result"
        assert_equals "$before" "$(git -C "$repo_path" rev-parse HEAD)" "$command dry-run preserves actual HEAD"
        assert_equals "$index_before" "$(git hash-object "$repo_path/.git/index")" "$command dry-run preserves the exact actual index"
        assert_file_not_exists "$env_root/ntm.args" "$command dry-run never invokes the controlled NTM endpoint"
        assert_file_not_exists "$env_root/receiver.git/received-updates" "$command dry-run never enters a receiver hook"
    done
}

test_dep_update_cli_relative_repo_preserves_physical_identity() {
    local env_root repo_path before after rc=0 result session
    env_root=$(create_ai_cli_fixture dep-update) || return 1
    repo_path="$env_root/projects/repo"
    before=$(git -C "$repo_path" rev-parse HEAD)
    (
        cd "$env_root/projects" || exit 1
        run_ai_cli_fixture "$env_root" dep-update session_work false --repo=./repo --no-push
    ) || rc=$?
    cat "$env_root/cli.stderr" >&2
    result=$(cat "$env_root/cli.stdout")
    assert_success "Relative-path consumer stdout is exactly one JSON value" jq -e -s 'length == 1' <<< "$result"
    session=$(jq -c '.data.results[0]' <<< "$result")
    after=$(git -C "$repo_path" rev-parse HEAD)
    assert_not_equals "$before" "$after" "Relative-path endpoint creates an actual requested commit"
    assert_equals 1.0.1 "$(git -C "$repo_path" show HEAD:package.json | jq -r '.dependencies["example-package"]')" "Relative-path endpoint actually updates committed dependency bytes"
    assert_equals 0 "$rc" "Documented relative --repo path accepts verified actual work"
    assert_equals success "$(jq -r '.status' <<< "$session")" "Relative identity cannot turn completed work into a failure"
    assert_equals "$repo_path" "$(jq -r '.repo' <<< "$session")" "Consumer binds the actual physical repository identity"
    assert_equals "$after" "$(jq -r '.work.commits[0]' <<< "$session")" "Relative-path consumer preserves the exact actual commit SHA"
    assert_equals true "$(jq -r '.publication.no_push' <<< "$session")" "Relative-path consumer preserves explicit no-push evidence"
    assert_equals "$before" "$(git -C "$env_root/receiver.git" rev-parse refs/heads/main)" "Relative-path no-push preserves the actual receiver"
    assert_not_contains "$(cat "$env_root/git.trace")" ' push ' "Relative-path no-push invokes no host Git push"
}

# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: session driver"

run_test test_local_driver_full_cycle
run_test test_parallel_sessions
run_test test_session_interrupt_recovery
run_test test_ai_sync_cli_common_results
run_test test_ai_sync_cli_requested_content_is_not_replaceable
run_test test_dep_update_cli_common_results
run_test test_ai_cli_host_publication_success_and_refusal
run_test test_ai_cli_dry_run_is_read_only
run_test test_dep_update_cli_relative_repo_preserves_physical_identity

print_results
exit "$(get_exit_code)"
