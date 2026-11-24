#!/usr/bin/env bash
#
# E2E Verification Suite: Review Failures, Checkpoints, Dashboard Wiring,
# Local Driver Direct Logging, and Portable Stat/Date Capabilities (bd-tr5y.9 / bd-tr5y.10)
#
# shellcheck disable=SC2034  # Variables used by sourced framework/functions
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/test_e2e_framework.sh"

require_review_tools() {
    if ! command -v git &>/dev/null || ! command -v jq &>/dev/null || ! command -v python3 &>/dev/null; then
        skip_test "git, jq, and python3 are required"
        return 1
    fi
    return 0
}

create_local_git_repo_with_origin() {
    local repo_name="$1"
    local repo_path="$RU_PROJECTS_DIR/$repo_name"
    local bare_path="$E2E_TEMP_DIR/remotes/${repo_name}.git"

    mkdir -p "$bare_path" "$repo_path"
    git init --bare "$bare_path" >/dev/null 2>&1
    git -C "$repo_path" init >/dev/null 2>&1
    git -C "$repo_path" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || true
    git -C "$repo_path" config user.email "test@example.com"
    git -C "$repo_path" config user.name "Test Author"

    printf "hello %s\n" "$repo_name" > "$repo_path/README.md"
    git -C "$repo_path" add README.md >/dev/null 2>&1
    git -C "$repo_path" commit -m "initial commit" >/dev/null 2>&1
    git -C "$repo_path" remote add origin "$bare_path" >/dev/null 2>&1
    git -C "$repo_path" push -u origin main >/dev/null 2>&1
}

create_tracking_mock_tmux() {
    local spawn_log="$1"
    local mock_bin="$E2E_TEMP_DIR/mock_bin"
    mkdir -p "$mock_bin"
    local shb="#""!/usr/bin/env bash"
    printf "%s\n" \
        "$shb" \
        "cmd=\"\${1:-}\"; shift || true" \
        "case \"\$cmd\" in" \
        "  new-session)" \
        "    sid=\"\"" \
        "    while [[ \$# -gt 0 ]]; do" \
        "      if [[ \"\$1\" == \"-s\" ]]; then sid=\"\${2:-}\"; shift 2; continue; fi" \
        "      shift" \
        "    done" \
        "    printf \"%s\\n\" \"\$sid\" >> \"$spawn_log\"" \
        "    exit 0 ;;" \
        "  has-session) exit 0 ;;" \
        "  list-panes) echo \"1\"; exit 0 ;;" \
        "  list-sessions) exit 0 ;;" \
        "  send-keys|kill-session) exit 0 ;;" \
        "  -V) echo \"tmux 3.4\"; exit 0 ;;" \
        "  *) exit 0 ;;" \
        "esac" > "$mock_bin/tmux"
    chmod +x "$mock_bin/tmux"
    export PATH="$mock_bin:$PATH"
}

setup_review_env() {
    local count="$1"
    e2e_setup
    export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export RU_REVIEW_POLL_INTERVAL=1

    e2e_init_ru
    mkdir -p "$RU_CONFIG_DIR/repos.d"
    local list_file="$RU_CONFIG_DIR/repos.d/public.txt"
    local idx=0
    while (( idx < count )); do
        create_local_git_repo_with_origin "repo${idx}"
        printf "owner/repo%d\n" "$idx" >> "$list_file"
        idx=$((idx + 1))
    done

    local gql=""
    gql=$(e2e_graphql_response_with_items "$count")
    e2e_create_mock_gh 0 "$gql"
    e2e_create_mock_ntm "ok"
}

wait_for_path() {
    local path="$1" timeout="${2:-15}" start now
    start=$(date +%s)
    while [[ ! -f "$path" ]]; do
        now=$(date +%s)
        if [[ $((now - start)) -ge "$timeout" ]]; then
            return 1
        fi
        sleep 0.2
    done
    return 0
}

wait_for_mapping_repos() {
    local file="$1" count="${2:-1}" timeout="${3:-15}" start now
    start=$(date +%s)
    local jq_check="type == \"object\" and length >= \$count and all(.[]; (.worktree_path | type == \"string\" and length > 0))"
    while ! jq -e --argjson count "$count" "$jq_check" "$file" >/dev/null 2>&1; do
        now=$(date +%s)
        if [[ $((now - start)) -ge "$timeout" ]]; then
            return 1
        fi
        sleep 0.2
    done
    return 0
}

write_valid_plan_for_repo() {
    local run_id="$1" repo_id="$2"
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    local wt_path=""
    wt_path=$(jq -r --arg repo "$repo_id" ".[\$repo].worktree_path // empty" "$mapping_file" 2>/dev/null)
    [[ -n "$wt_path" ]] || return 1
    mkdir -p "$wt_path/.ru"
    local mapping_obj=""
    mapping_obj=$(jq --arg repo "$repo_id" ".[\$repo]" "$mapping_file")
    jq -n --arg run "$run_id" --arg repo "$repo_id" --arg path "$wt_path" --argjson mapping "$mapping_obj" \
        "{schema_version:1,run_id:\$run,repo:\$repo,worktree_path:\$path,items:[{type:\"issue\",number:1,title:\"Issue 1\",priority:\"high\",decision:\"fix\",risk_level:\"low\"}],git:{branch:\$mapping.branch,base_ref:\$mapping.base_ref,base_sha:\$mapping.base_sha,commits:[]},metadata:{started_at:\"2026-10-13T10:00:00Z\",completed_at:\"2026-10-13T10:01:00Z\",model:\"controlled\",driver:\"local\"}}" \
        > "$wt_path/.ru/review-plan.json"
}

write_pipe_event() {
    local run_id="$1" repo_id="$2" payload="$3"
    local sid="ru-review-${run_id}-${repo_id//\//-}"
    mkdir -p "$RU_STATE_DIR/pipes"
    printf "%s\n" "$payload" > "$RU_STATE_DIR/pipes/${sid}.pipe.log"
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    if [[ -f "$mapping_file" ]]; then
        local wt_path=""
        wt_path=$(jq -r --arg repo "$repo_id" ".[\$repo].worktree_path // empty" "$mapping_file" 2>/dev/null || echo "")
        if [[ -n "$wt_path" && -d "$wt_path" ]]; then
            mkdir -p "$wt_path/.ru"
            printf "%s\n" "$payload" | tee "$wt_path/.ru/session.log" >/dev/null
        fi
    fi
}

wait_pid() {
    local pid="$1" timeout="${2:-25}" start now
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        if [[ $((now - start)) -ge "$timeout" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"
    return $?
}

#------------------------------------------------------------------------------
# Test 1: Session error preserves non-zero exit, checkpoint, and digest isolation
#------------------------------------------------------------------------------
test_session_failure_preserves_nonzero_exit_checkpoint_and_digest_isolation() {
    local test_name="e2e: session failure preserves exit code, checkpoint, and digest isolation"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 2
    local spawn_log="$E2E_TEMP_DIR/spawns.log"
    create_tracking_mock_tmux "$spawn_log"

    local out_file="$E2E_LOG_DIR/fail_run.stdout"
    local err_file="$E2E_LOG_DIR/fail_run.stderr"
    "$E2E_RU_SCRIPT" review --mode=local --parallel=1 --plan --json --non-interactive >"$out_file" 2>"$err_file" &
    local pid=$!

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_path "$info_file" 15 || true
    local run_id=""
    run_id=$(jq -r ".run_id // empty" "$info_file" 2>/dev/null)
    assert_not_empty "$run_id" "captured run_id"

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_mapping_repos "$mapping_file" 2 15 || true

    write_valid_plan_for_repo "$run_id" "owner/repo0"
    local wt0="" wt1=""
    wt0=$(jq -r ".[\"owner/repo0\"].worktree_path" "$mapping_file")
    wt1=$(jq -r ".[\"owner/repo1\"].worktree_path" "$mapping_file")
    mkdir -p "$wt0/.ru" "$wt1/.ru"
    printf "# Digest for repo0\n" > "$wt0/.ru/repo-digest.md"
    printf "# Untrusted digest for failed repo1\n" > "$wt1/.ru/repo-digest.md"

    write_pipe_event "$run_id" "owner/repo0" "{\"type\":\"result\",\"status\":\"success\"}"
    write_pipe_event "$run_id" "owner/repo1" "{\"type\":\"result\",\"status\":\"error\",\"is_error\":true}"

    local rc=0
    wait_pid "$pid" 25 || rc=$?
    assert_equals "1" "$rc" "partial session failure exits 1 (not 0)"

    local st="" d_rc="" m_rc="" r0_st="" r1_st=""
    st=$(jq -r ".data.status" "$out_file" 2>/dev/null)
    d_rc=$(jq -r ".data.exit_code" "$out_file" 2>/dev/null)
    m_rc=$(jq -r "._meta.exit_code" "$out_file" 2>/dev/null)
    r0_st=$(jq -r ".data.repos[\"owner/repo0\"].status" "$out_file" 2>/dev/null)
    r1_st=$(jq -r ".data.repos[\"owner/repo1\"].status" "$out_file" 2>/dev/null)

    assert_equals "failed" "$st" "completion JSON status is failed"
    assert_equals "1" "$d_rc" "completion JSON exit_code is 1"
    assert_equals "1" "$m_rc" "envelope metadata exit_code is 1"
    assert_equals "completed" "$r0_st" "repo0 recorded completed"
    assert_equals "error" "$r1_st" "repo1 recorded error"

    local ckpt="$RU_STATE_DIR/review/review-checkpoint.json"
    assert_file_exists "$ckpt" "checkpoint preserved after failure"
    local c_done="" c_pend=""
    c_done=$(jq -r ".completed_repos | join(\",\")" "$ckpt" 2>/dev/null)
    c_pend=$(jq -r ".pending_repos | join(\",\")" "$ckpt" 2>/dev/null)
    assert_equals "owner/repo0" "$c_done" "checkpoint records completed repo0"
    assert_equals "owner/repo1" "$c_pend" "checkpoint keeps failed repo1 pending"

    assert_file_exists "$RU_STATE_DIR/repo-digests/owner_repo0.md" "digest updated for completed repo0"
    assert_file_not_exists "$RU_STATE_DIR/repo-digests/owner_repo1.md" "digest NOT updated for failed repo1"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 2: Missing plan fails and --resume skips completed repo and retries failed repo
#------------------------------------------------------------------------------
test_no_plan_fails_and_resume_skips_completed_repo() {
    local test_name="e2e: no_plan fails cleanly and --resume skips completed repo"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 2
    local spawn_log1="$E2E_TEMP_DIR/spawns_pass1.log"
    create_tracking_mock_tmux "$spawn_log1"

    "$E2E_RU_SCRIPT" review --mode=local --parallel=1 --plan --json --non-interactive >"$E2E_LOG_DIR/p1.stdout" 2>"$E2E_LOG_DIR/p1.stderr" &
    local pid1=$!
    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_path "$info_file" 15 || true
    local run_id=""
    run_id=$(jq -r ".run_id // empty" "$info_file" 2>/dev/null)
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_mapping_repos "$mapping_file" 2 15 || true

    write_valid_plan_for_repo "$run_id" "owner/repo0"
    write_pipe_event "$run_id" "owner/repo0" "{\"type\":\"result\",\"status\":\"success\"}"
    write_pipe_event "$run_id" "owner/repo1" "{\"type\":\"result\",\"status\":\"success\"}"

    local rc1=0
    wait_pid "$pid1" 25 || rc1=$?
    assert_equals "1" "$rc1" "missing review-plan.json causes exit 1"

    local state_file="$RU_STATE_DIR/review/review-state.json"
    local r1_out="" r1_st=""
    r1_out=$(jq -r ".repos[\"owner/repo1\"].outcome" "$state_file" 2>/dev/null)
    r1_st=$(jq -r ".repos[\"owner/repo1\"].status" "$state_file" 2>/dev/null)
    assert_equals "no_plan" "$r1_out" "repo1 outcome recorded as no_plan"
    assert_equals "error" "$r1_st" "repo1 status recorded as error"

    local ckpt="$RU_STATE_DIR/review/review-checkpoint.json"
    assert_file_exists "$ckpt" "checkpoint retained after no_plan failure"
    local c_done="" c_pend=""
    c_done=$(jq -r ".completed_repos | join(\",\")" "$ckpt" 2>/dev/null)
    c_pend=$(jq -r ".pending_repos | join(\",\")" "$ckpt" 2>/dev/null)
    assert_equals "owner/repo0" "$c_done" "checkpoint retains completed repo0"
    assert_equals "owner/repo1" "$c_pend" "checkpoint retains failed repo1 in pending"

    local repo1_gql="" resume_gql=""
    repo1_gql=$(e2e_graphql_repo_with_items "owner/repo1")
    resume_gql="{\"data\":{\"repo0\":${repo1_gql}}}"
    e2e_create_mock_gh 0 "$resume_gql"
    local spawn_log2="$E2E_TEMP_DIR/spawns_pass2.log"
    create_tracking_mock_tmux "$spawn_log2"
    "$E2E_RU_SCRIPT" review --mode=local --parallel=1 --plan --resume --json --non-interactive >"$E2E_LOG_DIR/p2.stdout" 2>"$E2E_LOG_DIR/p2.stderr" &
    local pid2=$!
    wait_for_path "$info_file" 15 || true
    wait_for_mapping_repos "$mapping_file" 1 15 || true

    write_valid_plan_for_repo "$run_id" "owner/repo1"
    write_pipe_event "$run_id" "owner/repo1" "{\"type\":\"result\",\"status\":\"success\"}"

    local rc2=0
    wait_pid "$pid2" 25 || rc2=$?
    assert_equals "0" "$rc2" "resumed run completes cleanly with exit 0"
    local st2=""
    st2=$(jq -r ".data.status" "$E2E_LOG_DIR/p2.stdout" 2>/dev/null)
    assert_equals "complete" "$st2" "resumed completion status is complete"
    assert_file_not_exists "$ckpt" "checkpoint cleared ONLY after resumed run succeeds"

    local repo0_spawns=0 repo1_spawns=0
    repo0_spawns=$(grep -c "owner-repo0" "$spawn_log2" 2>/dev/null || true)
    repo1_spawns=$(grep -c "owner-repo1" "$spawn_log2" 2>/dev/null || true)
    assert_equals "0" "$repo0_spawns" "resume skipped already-completed owner/repo0"
    assert_equals "1" "$repo1_spawns" "resume retried failed owner/repo1 exactly once"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 3: Local driver direct logging (no FIFO deadlock) + non-zero exit tracking
#------------------------------------------------------------------------------
test_local_driver_direct_log_no_fifo_deadlock_and_nonzero_exit() {
    local test_name="e2e: local driver avoids FIFO deadlock and tracks non-zero exit"
    log_test_start "$test_name"
    if ! command -v tmux &>/dev/null || ! command -v jq &>/dev/null; then
        skip_test "tmux and jq required"
        log_test_pass "$test_name"
        return 0
    fi

    e2e_setup
    local wt_ok="$E2E_TEMP_DIR/wt_ok"
    local wt_fail="$E2E_TEMP_DIR/wt_fail"
    local fake_bin="$E2E_TEMP_DIR/fake_claude_bin"
    mkdir -p "$wt_ok" "$wt_fail" "$fake_bin"

    local shb="#""!/usr/bin/env bash"
    printf "%s\n" \
        "$shb" \
        "if [[ \"\$*\" == *\"FAIL_17\"* ]]; then" \
        "  echo \"provider fatal error\"" \
        "  exit 17" \
        "fi" \
        "python3 -c \"print(\\\"x\\\" * 131072)\"" \
        "printf \"{\\\"type\\\":\\\"result\\\",\\\"status\\\":\\\"success\\\"}\\n\"" \
        "exit 0" > "$fake_bin/claude"
    chmod +x "$fake_bin/claude"

    local sid_ok="ru-local-ok-$$"
    local sid_fail="ru-local-fail-$$"

    local driver_out="" sub_rc=0
    driver_out=$(
        export PATH="$fake_bin:$PATH"
        source_ru_function "ensure_dir"
        source_ru_function "json_escape"
        source_ru_function "local_driver_start_session"
        source_ru_function "local_driver_get_session_state"
        source_ru_function "local_driver_stop_session"
        log_error() { echo "ERR: $*" >&2; }
        get_worktree_for_session() {
            case "$1" in
                "$sid_ok") echo "$wt_ok" ;;
                "$sid_fail") echo "$wt_fail" ;;
            esac
        }

        local_driver_start_session "$wt_ok" "$sid_ok" "BIG_OK" >/dev/null || exit 11
        local_driver_start_session "$wt_fail" "$sid_fail" "FAIL_17" >/dev/null || exit 12

        local start_t now_t
        start_t=$(date +%s)
        while [[ ! -f "$wt_ok/.ru/session.exit" || ! -f "$wt_fail/.ru/session.exit" ]]; do
            now_t=$(date +%s)
            if [[ $((now_t - start_t)) -ge 12 ]]; then
                local_driver_stop_session "$sid_ok"
                local_driver_stop_session "$sid_fail"
                exit 13
            fi
            sleep 0.2
        done

        local st_ok="" st_fail="" s1="" s2="" e2=""
        st_ok=$(local_driver_get_session_state "$sid_ok")
        st_fail=$(local_driver_get_session_state "$sid_fail")
        local_driver_stop_session "$sid_ok"
        local_driver_stop_session "$sid_fail"
        s1=$(echo "$st_ok" | jq -r ".state")
        s2=$(echo "$st_fail" | jq -r ".state")
        e2=$(echo "$st_fail" | jq -r ".exit_code")
        printf "%s|%s|%s\n" "$s1" "$s2" "$e2"
    ) || sub_rc=$?

    assert_equals "0" "$sub_rc" "local driver sessions completed without FIFO deadlock"
    assert_equals "complete|error|17" "$driver_out" "local driver distinguishes exit 0 (complete) vs exit 17 (error)"
    assert_file_not_exists "$wt_ok/.ru/events.pipe" "no unread events.pipe FIFO created"
    assert_file_exists "$wt_ok/.ru/session.log" "session.log captured >128KB output directly"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 4: Non-interactive --auto-answer=fail fails closed with exit 3 + checkpoint
#------------------------------------------------------------------------------
test_non_interactive_auto_answer_fail_blocks_cleanly() {
    local test_name="e2e: non-interactive --auto-answer=fail exits 3 and retains checkpoint"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 1
    local spawn_log="$E2E_TEMP_DIR/spawns.log"
    create_tracking_mock_tmux "$spawn_log"

    local out_file="$E2E_LOG_DIR/ni_fail.stdout"
    local err_file="$E2E_LOG_DIR/ni_fail.stderr"
    "$E2E_RU_SCRIPT" review --mode=local --parallel=1 --plan --non-interactive --auto-answer=fail --json >"$out_file" 2>"$err_file" &
    local pid=$!

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_path "$info_file" 15 || true
    local run_id=""
    run_id=$(jq -r ".run_id // empty" "$info_file" 2>/dev/null)
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_mapping_repos "$mapping_file" 1 15 || true

    local q_line=""
    q_line=$(printf "%b" "{\"type\":\"tool_use\",\"id\":\"toolu_ni_1\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Proceed with refactor?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}}\nclaude>")
    write_pipe_event "$run_id" "owner/repo0" "$q_line"

    local rc=0
    wait_pid "$pid" 25 || rc=$?
    assert_equals "3" "$rc" "non-interactive --auto-answer=fail exits 3 (blocking failure)"
    local st=""
    st=$(jq -r ".data.status" "$out_file" 2>/dev/null)
    assert_equals "failed" "$st" "completion status is failed"
    assert_file_exists "$RU_STATE_DIR/review/review-checkpoint.json" "checkpoint preserved when non-interactive fails"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 5: Dashboard refuses non-TTY, --non-interactive, and --dry-run fast
#------------------------------------------------------------------------------
test_dashboard_non_tty_and_conflicting_flag_refusals() {
    local test_name="e2e: dashboard refuses non-TTY, --non-interactive, and --dry-run"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 1

    local rc=0 out="" reason="" meta_rc=""
    out=$(timeout 10 "$E2E_RU_SCRIPT" --json review --dashboard < /dev/null 2>/dev/null) || rc=$?
    assert_equals "3" "$rc" "ru review --dashboard without TTY exits 3 immediately"
    reason=$(printf "%s\n" "$out" | jq -r ".data.error.reason" 2>/dev/null)
    meta_rc=$(printf "%s\n" "$out" | jq -r "._meta.exit_code" 2>/dev/null)
    assert_equals "tty_required" "$reason" "non-TTY refusal reason is tty_required"
    assert_equals "3" "$meta_rc" "non-TTY refusal envelope exit_code is 3"

    rc=0
    local human_err=""
    human_err=$(timeout 10 "$E2E_RU_SCRIPT" review --dashboard < /dev/null 2>&1) || rc=$?
    assert_equals "3" "$rc" "human ru review --dashboard without TTY exits 3"
    assert_contains "$human_err" "interactive terminal" "human non-TTY refusal prints diagnostic to stderr"

    rc=0
    out=$(timeout 10 "$E2E_RU_SCRIPT" --json review --dashboard --non-interactive < /dev/null 2>/dev/null) || rc=$?
    assert_equals "4" "$rc" "ru review --dashboard --non-interactive exits 4"
    reason=$(printf "%s\n" "$out" | jq -r ".data.error.reason" 2>/dev/null)
    assert_equals "conflicting_options" "$reason" "--dashboard --non-interactive emits conflicting_options"

    rc=0
    out=$(timeout 10 "$E2E_RU_SCRIPT" --json review --dashboard --dry-run < /dev/null 2>/dev/null) || rc=$?
    assert_equals "4" "$rc" "ru review --dashboard --dry-run exits 4"
    reason=$(printf "%s\n" "$out" | jq -r ".data.error.reason" 2>/dev/null)
    assert_equals "conflicting_options" "$reason" "--dashboard --dry-run emits conflicting_options"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 6a: Live dashboard in real PTY wires pause/resume to real scheduler
#------------------------------------------------------------------------------
test_dashboard_pty_pause_resume_controls_scheduler() {
    local test_name="e2e: dashboard PTY p/r genuinely pauses and resumes scheduler admission"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 2
    local spawn_log="$E2E_TEMP_DIR/dash_spawns.log"
    create_tracking_mock_tmux "$spawn_log"

    local pty_driver="$E2E_TEMP_DIR/pty_pause_resume.py"
    cat << 'PYEND' > "$pty_driver"
import json, os, pty, select, subprocess, sys, time

ru_script, state_dir, spawn_log, transcript_path = sys.argv[1:5]
master_fd, slave_fd = pty.openpty()
env = os.environ.copy()
env["TERM"] = "xterm-256color"
env["RU_REVIEW_POLL_INTERVAL"] = "1"
env["RU_STATE_DIR"] = state_dir

proc = subprocess.Popen(
    [ru_script, "review", "--dashboard", "--mode=local", "--parallel=1", "--plan"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, env=env, close_fds=True,
)
os.close(slave_fd)

buf = bytearray()
def drain(seconds=0.3):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([master_fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    break
                buf.extend(chunk)
            except OSError:
                break

def wait_file(path, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        drain(0.1)
        if os.path.exists(path):
            return True
    return False

def wait_cond(fn, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        drain(0.15)
        if fn():
            return True
    return False

def write_plan_and_complete(run_id, mapping_path, repo_id):
    with open(mapping_path) as f:
        mapping = json.load(f)[repo_id]
    wt = mapping["worktree_path"]
    os.makedirs(os.path.join(wt, ".ru"), exist_ok=True)
    plan = {
        "schema_version": 1,
        "run_id": run_id,
        "repo": repo_id,
        "worktree_path": wt,
        "items": [{"type": "issue", "number": 1, "title": "Fix", "priority": "high", "decision": "fix", "risk_level": "low"}],
        "git": {"branch": mapping["branch"], "base_ref": mapping["base_ref"], "base_sha": mapping["base_sha"], "commits": []},
        "metadata": {"started_at": "2026-10-13T10:00:00Z", "completed_at": "2026-10-13T10:01:00Z", "model": "controlled", "driver": "local"},
    }
    with open(os.path.join(wt, ".ru", "review-plan.json"), "w") as f:
        json.dump(plan, f)
    pipes_dir = os.path.join(state_dir, "pipes")
    os.makedirs(pipes_dir, exist_ok=True)
    sid = f"ru-review-{run_id}-{repo_id.replace('/', '-')}"
    with open(os.path.join(pipes_dir, f"{sid}.pipe.log"), "w") as f:
        f.write('{"type":"result","status":"success"}\n')
    with open(os.path.join(wt, ".ru", "session.log"), "w") as f:
        f.write('{"type":"result","status":"success"}\n')

def spawn_count(substr):
    if not os.path.exists(spawn_log):
        return 0
    with open(spawn_log) as f:
        return sum(1 for line in f if substr in line)

def repo_status(repo_id):
    sf = os.path.join(state_dir, "review", "review-state.json")
    if not os.path.exists(sf):
        return ""
    try:
        with open(sf) as f:
            return json.load(f).get("repos", {}).get(repo_id, {}).get("status", "")
    except Exception:
        return ""

try:
  info_file = os.path.join(state_dir, "review.lock.info")
  assert wait_file(info_file, 15), "lock info not created"
  with open(info_file) as f:
      run_id = json.load(f)["run_id"]
  mapping_path = os.path.join(state_dir, "worktrees", run_id, "mapping.json")
  assert wait_file(mapping_path, 15), "mapping.json not created"
  assert wait_cond(lambda: spawn_count("owner-repo0") >= 1, 15), "repo0 never started"

  # Pause scheduler via PTY 'p'
  os.write(master_fd, b"p")
  pause_file = os.path.join(state_dir, "review", "review.paused")
  assert wait_cond(lambda: os.path.exists(pause_file) and b"[PAUSED]" in buf, 10), "dashboard pause did not activate"

  # Complete repo0 while paused; repo1 MUST NOT be admitted
  write_plan_and_complete(run_id, mapping_path, "owner/repo0")
  assert wait_cond(lambda: repo_status("owner/repo0") == "completed", 15), "repo0 did not complete"
  drain(2.2)
  spawns_while_paused = spawn_count("owner-repo1")
  assert spawns_while_paused == 0, f"repo1 admitted while paused (spawns={spawns_while_paused})"

  # Resume scheduler via PTY 'r'; repo1 MUST now be admitted
  os.write(master_fd, b"r")
  assert wait_cond(lambda: (not os.path.exists(pause_file)) and spawn_count("owner-repo1") == 1, 15), "resume did not admit repo1"

  # Complete repo1 and quit via PTY 'q'
  write_plan_and_complete(run_id, mapping_path, "owner/repo1")
  assert wait_cond(lambda: repo_status("owner/repo1") == "completed", 15), "repo1 did not complete"
  os.write(master_fd, b"q")
  drain(0.5)
  rc = proc.wait(timeout=15)
  print(f"PTY_EXIT={rc}")
  sys.exit(rc)
finally:
  if proc.poll() is None:
      proc.terminate()
      try:
          proc.wait(timeout=5)
      except subprocess.TimeoutExpired:
          proc.kill()
  try:
      os.close(master_fd)
  except OSError:
      pass
  with open(transcript_path, "wb") as f:
      f.write(buf)
PYEND

    local pty_transcript="$E2E_LOG_DIR/pty_pause_resume.txt"
    local pty_rc=0
    python3 "$pty_driver" "$E2E_RU_SCRIPT" "$RU_STATE_DIR" "$spawn_log" "$pty_transcript" >"$E2E_LOG_DIR/pty_pr.stdout" 2>"$E2E_LOG_DIR/pty_pr.stderr" || pty_rc=$?
    if [[ "$pty_rc" -ne 0 ]]; then cat "$E2E_LOG_DIR/pty_pr.stderr" >&2 || true; fi
    assert_equals "0" "$pty_rc" "live dashboard PTY pause/resume/complete/quit exits 0"
    assert_file_not_exists "$RU_STATE_DIR/review/review-checkpoint.json" "checkpoint cleared after all repos completed in dashboard"
    assert_file_not_exists "$RU_STATE_DIR/review/review.paused" "pause state cleaned up on dashboard exit"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 6b: Dashboard apply ('a') and bulk apply ('b') route through shared engine
#------------------------------------------------------------------------------
test_dashboard_pty_apply_and_bulk_apply_use_shared_engine() {
    local test_name="e2e: dashboard a/b actions route through shared apply_review_plan_for_repo"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    setup_review_env 1
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"
    printf 'REVIEW_ALLOW_PUSH="true"\nREVIEW_REQUIRE_APPROVAL="true"\n' | tee "$RU_CONFIG_DIR/review-policies.d/_default" >/dev/null
    local repo_path="$RU_PROJECTS_DIR/repo0"
    local bare_path="$E2E_TEMP_DIR/remotes/repo0.git"
    local spawn_log="$E2E_TEMP_DIR/apply_spawns.log"
    create_tracking_mock_tmux "$spawn_log"

    # Add an executable shell test suite that initially FAILS (planted negative gate)
    mkdir -p "$repo_path/scripts"
    local shb="#""!/usr/bin/env bash"
    printf "%s\nexit 1\n" "$shb" > "$repo_path/scripts/run_all_tests.sh"
    chmod +x "$repo_path/scripts/run_all_tests.sh"
    git -C "$repo_path" add scripts/run_all_tests.sh >/dev/null 2>&1
    git -C "$repo_path" commit -m "add test suite" >/dev/null 2>&1
    git -C "$repo_path" push origin main >/dev/null 2>&1
    local base_head=""
    base_head=$(git -C "$repo_path" rev-parse HEAD)

    # Run a real plan pass to create anchored worktree and mapping.json
    "$E2E_RU_SCRIPT" review --mode=local --parallel=1 --plan --non-interactive >"$E2E_LOG_DIR/prep.stdout" 2>"$E2E_LOG_DIR/prep.stderr" &
    local prep_pid=$!
    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_path "$info_file" 15 || true
    local run_id=""
    run_id=$(jq -r ".run_id // empty" "$info_file" 2>/dev/null)
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_mapping_repos "$mapping_file" 1 15 || true
    local wt_path=""
    wt_path=$(jq -r ".[\"owner/repo0\"].worktree_path" "$mapping_file")

    # Create a real commit in the worktree (still failing tests!) and bind plan to it
    printf "candidate fix\n" > "$wt_path/fix.txt"
    git -C "$wt_path" add fix.txt >/dev/null 2>&1
    git -C "$wt_path" commit -m "candidate fix" >/dev/null 2>&1
    local cand_sha1=""
    cand_sha1=$(git -C "$wt_path" rev-parse HEAD)
    local mapping_obj=""
    mapping_obj=$(jq ".[\"owner/repo0\"]" "$mapping_file")
    mkdir -p "$wt_path/.ru"
    jq -n --arg run "$run_id" --arg path "$wt_path" --arg sha "$cand_sha1" --argjson mapping "$mapping_obj" \
        "{schema_version:1,run_id:\$run,repo:\"owner/repo0\",worktree_path:\$path,items:[{type:\"issue\",number:1,title:\"Issue 1\",priority:\"high\",decision:\"fix\",risk_level:\"low\"}],git:{branch:\$mapping.branch,base_ref:\$mapping.base_ref,base_sha:\$mapping.base_sha,commits:[{sha:\$sha,message:\"candidate fix\",files:[\"fix.txt\"]}]},metadata:{started_at:\"2026-10-13T10:00:00Z\",completed_at:\"2026-10-13T10:01:00Z\",model:\"controlled\",driver:\"local\"}}" \
        > "$wt_path/.ru/review-plan.json"
    write_pipe_event "$run_id" "owner/repo0" "{\"type\":\"result\",\"status\":\"success\"}"
    local prep_rc=0
    wait_pid "$prep_pid" 25 || prep_rc=$?
    assert_equals "0" "$prep_rc" "preparation plan run succeeded"

    # Helper PTY driver for --apply --dashboard --push
    local pty_apply="$E2E_TEMP_DIR/pty_apply.py"
    cat << 'PYEND' > "$pty_apply"
import os, pty, select, subprocess, sys, time

ru_script, state_dir, action_key, approval_reply, expected_status, out_log = sys.argv[1:7]
master_fd, slave_fd = pty.openpty()
env = os.environ.copy()
env["TERM"] = "xterm-256color"
env["RU_STATE_DIR"] = state_dir
# Exclude gum from PATH so gum_confirm uses its built-in ANSI [y/N] TTY prompt
no_gum_bin = os.path.join(os.path.dirname(out_log), "no_gum_bin")
os.makedirs(no_gum_bin, exist_ok=True)
for d in env.get("PATH", "").split(":"):
    if not d or not os.path.isdir(d):
        continue
    for entry in os.listdir(d):
        if entry == "gum":
            continue
        dst = os.path.join(no_gum_bin, entry)
        if not os.path.lexists(dst):
            try:
                os.symlink(os.path.join(d, entry), dst)
            except OSError:
                pass
env["PATH"] = no_gum_bin

proc = subprocess.Popen(
    [ru_script, "review", "--apply", "--dashboard", "--push"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, env=env, close_fds=True,
)
os.close(slave_fd)

buf = bytearray()
def wait_for(needle, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([master_fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    break
                buf.extend(chunk)
            except OSError:
                break
        if needle.encode() in buf:
            return True
    return False

try:
  assert wait_for("SUMMARY", 15), "dashboard did not render SUMMARY"
  os.write(master_fd, action_key.encode())
  assert wait_for("Approve this plan", 15), "shared ensure_review_approval prompt did not appear"
  os.write(master_fd, (approval_reply + "\n").encode())
  assert wait_for(expected_status, 20), f"expected status {expected_status!r} did not appear"
  os.write(master_fd, b"q")
  rc = proc.wait(timeout=15)
  sys.exit(rc)
finally:
  if proc.poll() is None:
      proc.terminate()
      try:
          proc.wait(timeout=5)
      except subprocess.TimeoutExpired:
          proc.kill()
  try:
      os.close(master_fd)
  except OSError:
      pass
  with open(out_log, "wb") as f:
      f.write(buf)
PYEND

    # Case 1 (Planted Negative): 'a' + default-No approval -> exit 2, zero mutation
    local rc_no=0
    python3 "$pty_apply" "$E2E_RU_SCRIPT" "$RU_STATE_DIR" "a" "" "Apply failed" "$E2E_LOG_DIR/apply_no.txt" 2>"$E2E_LOG_DIR/apply_no.err" || rc_no=$?
    if [[ "$rc_no" -ne 2 ]]; then cat "$E2E_LOG_DIR/apply_no.err" >&2 || true; fi
    assert_equals "2" "$rc_no" "dashboard 'a' with default-No approval exits 2"
    assert_equals "$base_head" "$(git -C "$repo_path" rev-parse HEAD)" "declined approval preserves local main"
    assert_equals "$base_head" "$(git -C "$bare_path" rev-parse refs/heads/main)" "declined approval preserves origin main"

    # Case 2 (Planted Negative): 'a' + 'y' approval with failing quality gate -> exit 2, zero mutation
    local rc_gate=0
    python3 "$pty_apply" "$E2E_RU_SCRIPT" "$RU_STATE_DIR" "a" "y" "Apply failed" "$E2E_LOG_DIR/apply_gate.txt" 2>"$E2E_LOG_DIR/apply_gate.err" || rc_gate=$?
    if [[ "$rc_gate" -ne 2 ]]; then cat "$E2E_LOG_DIR/apply_gate.err" >&2 || true; fi
    assert_equals "2" "$rc_gate" "dashboard 'a' with failing quality gate exits 2"
    assert_equals "$base_head" "$(git -C "$repo_path" rev-parse HEAD)" "failing quality gate preserves local main"
    assert_equals "$base_head" "$(git -C "$bare_path" rev-parse refs/heads/main)" "failing quality gate preserves origin main"

    # Case 3 (Positive): Fix test suite in worktree commit, re-bind plan, run 'b' (bulk apply safe) + 'y' -> exit 0 + pushed!
    printf "%s\nexit 0\n" "$shb" > "$wt_path/scripts/run_all_tests.sh"
    chmod +x "$wt_path/scripts/run_all_tests.sh"
    git -C "$wt_path" add scripts/run_all_tests.sh >/dev/null 2>&1
    git -C "$wt_path" commit -m "fix tests" >/dev/null 2>&1
    local cand_sha2=""
    cand_sha2=$(git -C "$wt_path" rev-parse HEAD)
    jq -n --arg run "$run_id" --arg path "$wt_path" --arg sha1 "$cand_sha1" --arg sha2 "$cand_sha2" --argjson mapping "$mapping_obj" \
        "{schema_version:1,run_id:\$run,repo:\"owner/repo0\",worktree_path:\$path,items:[{type:\"issue\",number:1,title:\"Issue 1\",priority:\"high\",decision:\"fix\",risk_level:\"low\"}],git:{branch:\$mapping.branch,base_ref:\$mapping.base_ref,base_sha:\$mapping.base_sha,commits:[{sha:\$sha1,message:\"candidate fix\",files:[\"fix.txt\"]},{sha:\$sha2,message:\"fix tests\",files:[\"scripts/run_all_tests.sh\"]}]},metadata:{started_at:\"2026-10-13T10:00:00Z\",completed_at:\"2026-10-13T10:01:00Z\",model:\"controlled\",driver:\"local\"}}" \
        > "$wt_path/.ru/review-plan.json"

    local rc_ok=0
    python3 "$pty_apply" "$E2E_RU_SCRIPT" "$RU_STATE_DIR" "b" "y" "Bulk apply safe: 1 applied, 0 failed" "$E2E_LOG_DIR/apply_ok.txt" 2>"$E2E_LOG_DIR/apply_ok.err" || rc_ok=$?
    if [[ "$rc_ok" -ne 0 ]]; then cat "$E2E_LOG_DIR/apply_ok.err" >&2 || true; fi
    assert_equals "0" "$rc_ok" "dashboard 'b' bulk apply safe with passing gate and approval exits 0"
    assert_equals "$cand_sha2" "$(git -C "$repo_path" rev-parse HEAD)" "approved passing bulk apply fast-forwards local main"
    assert_equals "$cand_sha2" "$(git -C "$bare_path" rev-parse refs/heads/main)" "approved passing bulk apply pushes to bare origin"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test 7: Capability-based stat & date across uutils, BSD, and GNU shims
#------------------------------------------------------------------------------
test_portable_stat_and_date_capability_detection() {
    local test_name="e2e: portable stat/date capability checks across uutils, BSD, and GNU"
    log_test_start "$test_name"
    require_review_tools || { log_test_pass "$test_name"; return 0; }

    e2e_setup
    local wt_root="$E2E_TEMP_DIR/state/ru/worktrees"
    mkdir -p "$wt_root/run-2026-01" "$wt_root/run-2026-02" "$wt_root/run-2026-03-unmapped"
    printf "{}\n" > "$wt_root/run-2026-01/mapping.json"
    printf "{}\n" > "$wt_root/run-2026-02/mapping.json"
    local sample_file="$E2E_TEMP_DIR/sample.bin"
    printf "1234567890" > "$sample_file"

    local shb="#""!/usr/bin/env bash"

    # 7a: uutils shim (NO 'GNU' in --version, supports -c and -d)
    local uutils_bin="$E2E_TEMP_DIR/uutils_bin"
    mkdir -p "$uutils_bin"
    printf "%s\n" \
        "$shb" \
        "if [[ \"\${1:-}\" == \"--version\" ]]; then echo \"stat (uutils coreutils) 0.0.27\"; exit 0; fi" \
        "if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%s\" ]]; then echo \"10\"; exit 0; fi" \
        "if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%Y\" ]]; then" \
        "  case \"\${3:-}\" in" \
        "    *run-2026-01*) echo \"1700000100\" ;;" \
        "    *run-2026-02*) echo \"1700000200\" ;;" \
        "    *run-2026-03-unmapped*) echo \"1799999999\" ;;" \
        "    *) echo \"1700000050\" ;;" \
        "  esac; exit 0; fi" \
        "exit 1" > "$uutils_bin/stat"
    printf "%s\n" \
        "$shb" \
        "if [[ \"\${1:-}\" == \"--version\" ]]; then echo \"date (uutils coreutils) 0.0.27\"; exit 0; fi" \
        "if [[ \"\$*\" == *\"-d\"* ]]; then echo \"2026-12-01T00:00:00Z\"; exit 0; fi" \
        "exit 1" > "$uutils_bin/date"
    chmod +x "$uutils_bin/stat" "$uutils_bin/date"

    # 7b: BSD shim (-c and -d fail, -f and -v succeed, equal mtimes to verify tie-breaking)
    local bsd_bin="$E2E_TEMP_DIR/bsd_bin"
    mkdir -p "$bsd_bin"
    printf "%s\n" \
        "$shb" \
        "if [[ \"\${1:-}\" == \"-c\" ]]; then echo \"stat: illegal option -- c\" >&2; exit 1; fi" \
        "if [[ \"\${1:-}\" == \"-f\" && \"\${2:-}\" == \"%z\" ]]; then echo \"10\"; exit 0; fi" \
        "if [[ \"\${1:-}\" == \"-f\" && \"\${2:-}\" == \"%m\" ]]; then" \
        "  case \"\${3:-}\" in" \
        "    *run-2026-01*) echo \"1700000500\" ;;" \
        "    *run-2026-02*) echo \"1700000500\" ;;" \
        "    *run-2026-03-unmapped*) echo \"1799999999\" ;;" \
        "    *) echo \"1700000050\" ;;" \
        "  esac; exit 0; fi" \
        "exit 1" > "$bsd_bin/stat"
    printf "%s\n" \
        "$shb" \
        "if [[ \"\$*\" == *\"-d\"* ]]; then echo \"date: illegal option -- d\" >&2; exit 1; fi" \
        "if [[ \"\$*\" == *\"-v\"* ]]; then echo \"2026-12-02T00:00:00Z\"; exit 0; fi" \
        "exit 1" > "$bsd_bin/date"
    chmod +x "$bsd_bin/stat" "$bsd_bin/date"

    local u_res="" b_res=""
    u_res=$(
        export PATH="$uutils_bin:$PATH"
        export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
        export REVIEW_RESUME="false"
        source_ru_function "get_file_size_bytes"
        source_ru_function "get_file_mtime_epoch"
        source_ru_function "date_add_days"
        source_ru_function "resolve_review_apply_run_id"
        log_error() { :; }
        local sz="" mt="" dt="" rid=""
        sz=$(get_file_size_bytes "$sample_file")
        mt=$(get_file_mtime_epoch "$sample_file")
        dt=$(date_add_days 7)
        rid=$(resolve_review_apply_run_id)
        printf "%s|%s|%s|%s\n" "$sz" "$mt" "$dt" "$rid"
    )
    assert_equals "10|1700000050|2026-12-01T00:00:00Z|run-2026-02" "$u_res" \
        "uutils coreutils capability detection works without GNU version string and prefers mapped run"

    b_res=$(
        export PATH="$bsd_bin:$PATH"
        export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
        export REVIEW_RESUME="false"
        source_ru_function "get_file_size_bytes"
        source_ru_function "get_file_mtime_epoch"
        source_ru_function "date_add_days"
        source_ru_function "resolve_review_apply_run_id"
        log_error() { :; }
        local sz="" mt="" dt="" rid=""
        sz=$(get_file_size_bytes "$sample_file")
        mt=$(get_file_mtime_epoch "$sample_file")
        dt=$(date_add_days 7)
        rid=$(resolve_review_apply_run_id)
        printf "%s|%s|%s|%s\n" "$sz" "$mt" "$dt" "$rid"
    )
    assert_equals "10|1700000050|2026-12-02T00:00:00Z|run-2026-02" "$b_res" \
        "BSD stat/date fallback works, ignores newer unmapped dir, and breaks exact mtime ties deterministically"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Run Tests
#------------------------------------------------------------------------------
log_suite_start "E2E Tests: Review Dashboard, Failure Preservation, Local Driver, Portable Stat/Date"

run_test test_session_failure_preserves_nonzero_exit_checkpoint_and_digest_isolation
run_test test_no_plan_fails_and_resume_skips_completed_repo
run_test test_local_driver_direct_log_no_fifo_deadlock_and_nonzero_exit
run_test test_non_interactive_auto_answer_fail_blocks_cleanly
run_test test_dashboard_non_tty_and_conflicting_flag_refusals
run_test test_dashboard_pty_pause_resume_controls_scheduler
run_test test_dashboard_pty_apply_and_bulk_apply_use_shared_engine
run_test test_portable_stat_and_date_capability_detection

print_results
exit "$(get_exit_code)"
