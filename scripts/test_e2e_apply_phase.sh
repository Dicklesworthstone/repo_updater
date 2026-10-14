#!/usr/bin/env bash
#
# E2E Test: Apply Phase (bd-5hx7)
#
# Tests apply mode end-to-end functionality:
#   1. Full apply cycle - plan validation through gh_actions execution
#   2. Quality gate failure blocking apply
#   3. Dry-run mode with no mutations
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions called indirectly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Stubs and helpers
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_debug() { :; }
log_step() { :; }

# Source required functions
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "json_escape"
source_ru_function "validate_review_plan"
source_ru_function "canonicalize_gh_action"
source_ru_function "parse_gh_action_target"
source_ru_function "record_gh_action_log"
source_ru_function "gh_action_already_executed"
source_ru_function "load_policy_for_repo"
source_ru_function "get_review_policy_dir"
source_ru_function "detect_test_command"
source_ru_function "detect_lint_command"
source_ru_function "run_lint_gate"
source_ru_function "run_test_gate"
source_ru_function "run_secret_scan"
source_ru_function "run_quality_gates"
source_ru_function "update_plan_with_gates"
source_ru_function "execute_gh_action_comment"
source_ru_function "execute_gh_action_close"
source_ru_function "execute_gh_action_label"
source_ru_function "execute_gh_actions"
source_ru_function "get_gh_actions_log_file"
source_ru_function "get_review_state_dir"
source_ru_function "review_plan_digest"
source_ru_function "get_worktrees_dir"
source_ru_function "record_worktree_mapping"

# Real review worktree and original preparation mapping. External GitHub calls
# remain controlled; local Git identity and candidate preservation are real.
setup_real_review_candidate() {
    local base_ref="${1:-main}" base_full="${2:-refs/heads/main}" tag_kind="${3:-lightweight}"
    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    export REVIEW_RUN_ID="gate-test"
    APPLY_MAIN="$RU_PROJECTS_DIR/test-repo"
    APPLY_WT="$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID/owner_test-repo"
    APPLY_PLAN="$APPLY_WT/.ru/review-plan.json"
    mkdir -p "$APPLY_MAIN" "$E2E_TEMP_DIR/remote.git" "$RU_CONFIG_DIR/repos.d" "$RU_CONFIG_DIR/review-policies.d"
    git -C "$E2E_TEMP_DIR/remote.git" init --bare -q
    git -C "$APPLY_MAIN" init -q
    git -C "$APPLY_MAIN" checkout -q -b main
    git -C "$APPLY_MAIN" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m Initial
    git -C "$APPLY_MAIN" remote add origin "$E2E_TEMP_DIR/remote.git"
    git -C "$APPLY_MAIN" push -q -u origin main
    APPLY_BASE=$(git -C "$APPLY_MAIN" rev-parse HEAD)
    APPLY_BASE_REF="$base_ref"
    if [[ "$base_full" == commit ]]; then
        base_ref="$APPLY_BASE"
        base_full="$APPLY_BASE"
        APPLY_BASE_REF="$base_ref"
    fi
    if [[ "$base_full" == refs/tags/* ]]; then
        if [[ "$tag_kind" == annotated ]]; then
            git -C "$APPLY_MAIN" -c user.name=Apply -c user.email=apply@example.invalid tag -a "$base_ref" -m 'Reviewed tag' "$APPLY_BASE"
        else
            git -C "$APPLY_MAIN" tag "$base_ref" "$APPLY_BASE"
        fi
    fi
    mkdir -p "${APPLY_WT%/*}"
    git -C "$APPLY_MAIN" worktree add -q -b review-candidate "$APPLY_WT" "$base_full"
    mkdir -p "$APPLY_WT/.ru"
    if [[ "$base_full" != refs/heads/* ]]; then
        printf 'owner/test-repo@%s\n' "$base_ref" > "$RU_CONFIG_DIR/repos.d/public.txt"
    else
        printf 'owner/test-repo\n' > "$RU_CONFIG_DIR/repos.d/public.txt"
    fi
    record_worktree_mapping owner/test-repo "$APPLY_WT" review-candidate "$base_ref" "$APPLY_MAIN" "$APPLY_BASE" "$base_full"
}

write_real_review_plan() {
    local actions="${1:-[]}"
    local commits
    commits=$(git -C "$APPLY_WT" rev-list --reverse --topo-order "$APPLY_BASE..HEAD" | jq -Rsc 'split("\n") | map(select(length > 0) | {sha:.,subject:"Candidate fix"})')
    jq -n --arg path "$APPLY_WT" --arg base "$APPLY_BASE" --arg ref "$APPLY_BASE_REF" --argjson commits "$commits" --argjson actions "$actions" '
        {schema_version:1,repo:"owner/test-repo",run_id:"gate-test",worktree_path:$path,items:[],
         metadata:{started_at:"2026-10-13T10:00:00Z",completed_at:"2026-10-13T10:01:00Z",model:"controlled",driver:"local"},
         git:{branch:"review-candidate",base_ref:$ref,base_sha:$base,commits:$commits},gh_actions:$actions}
    ' > "$APPLY_PLAN"
}

approve_real_review_plan() {
    jq -n --arg digest "$(review_plan_digest "$APPLY_PLAN")" --arg head "$(git -C "$APPLY_WT" rev-parse HEAD)" \
        '{schema_version:1,approved:true,repo:"owner/test-repo",run_id:"gate-test",plan_digest:$digest,candidate_head:$head,approved_at:"2026-10-13T10:02:00Z"}' \
        > "$APPLY_WT/.ru/review-approval.json"
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_apply_cycle() {
    log_test_start "e2e: full apply cycle - plan to gh_actions"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR"

    local repo_id="owner/test-repo"
    local wt_path="$E2E_TEMP_DIR/worktree"
    local plan_file="$wt_path/.ru/review-plan.json"

    mkdir -p "$wt_path/.ru"
    mkdir -p "$RU_STATE_DIR/gh_action_logs"

    # Create valid review plan with gh_actions
    cat > "$plan_file" <<'PLAN_JSON'
{
    "schema_version": 1,
    "repo": "owner/test-repo",
    "run_id": "gate-test",
    "worktree_path": "/tmp/controlled-review",
    "metadata": {"started_at":"2026-10-13T10:00:00Z","completed_at":"2026-10-13T10:01:00Z","model":"controlled","driver":"local"},
    "items": [
        {"type": "issue", "number": 42, "decision": "fix", "title": "Test issue", "priority":"normal"}
    ],
    "gh_actions": [
        {"op": "comment", "target": "issue#42", "body": "Fixed in this batch"}
    ],
    "git": {
        "commits": [{"sha": "abc123", "message": "Fix issue #42"}],
        "tests": {"ran": false}
    }
}
PLAN_JSON

    # Validate plan
    local validation
    validation=$(validate_review_plan "$plan_file")
    assert_equals "Valid" "$validation" "Plan should be valid"

    # Create mock gh that logs calls
    e2e_create_mock_gh_custom '
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
    echo "Created comment" >&2
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
    echo "Created comment" >&2
    exit 0
fi
echo "mock gh: $*" >&2
exit 0
'

    # Execute gh_actions
    local exit_code=0
    execute_gh_actions "$repo_id" "$plan_file" || exit_code=$?

    assert_file_exists "$E2E_LOG_DIR/gh_calls.log" "Controlled endpoint retains actual calls"
    assert_contains "$(cat "$E2E_LOG_DIR/gh_calls.log")" "issue comment" "Comment execution is observed"

    assert_equals "0" "$exit_code" "execute_gh_actions should succeed"

    e2e_cleanup
    log_test_pass "e2e: full apply cycle - plan to gh_actions"
}

test_apply_with_quality_failure() {
    log_test_start "e2e: quality gate failure blocks apply"
    e2e_setup

    export RU_STATE_DIR="$E2E_TEMP_DIR/state"
    mkdir -p "$RU_STATE_DIR"

    local wt_path="$E2E_TEMP_DIR/worktree"
    local plan_file="$wt_path/.ru/review-plan.json"

    mkdir -p "$wt_path/.ru"

    # Create plan
    cat > "$plan_file" <<'PLAN_JSON'
{
    "schema_version": 1,
    "repo": "owner/test-repo",
    "run_id": "gate-test",
    "worktree_path": "/tmp/controlled-review",
    "metadata": {"started_at":"2026-10-13T10:00:00Z","completed_at":"2026-10-13T10:01:00Z","model":"controlled","driver":"local"},
    "items": [],
    "gh_actions": [],
    "git": {"commits": [], "tests": {"ran": false}}
}
PLAN_JSON

    # Execute a real test command with a nonstandard failure code.
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"
    printf 'TEST_COMMAND=exit 42\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/owner_test-repo"

    local exit_code=0
    local gates_result
    gates_result=$(run_quality_gates "$wt_path" "$plan_file") || exit_code=$?
    assert_equals 1 "$exit_code" "Failed executed test blocks the combined gate"
    assert_equals false "$(jq -r '.overall_ok' <<< "$gates_result")" "Failure cannot claim overall success"
    assert_equals 42 "$(jq -r '.tests.exit_code' <<< "$gates_result")" "Real execution exit is retained"

    e2e_cleanup
    log_test_pass "e2e: quality gate failure blocks apply"
}

test_cli_apply_failed_gates_prevent_mutations() {
    e2e_setup
    setup_real_review_candidate
    local wt_path="$APPLY_WT"
    local plan_file="$APPLY_PLAN"
    local gh_calls="$E2E_TEMP_DIR/gh-calls"
    local gate code rc before after
    before=$(git -C "$wt_path" rev-parse HEAD)
    e2e_create_mock_gh_custom "
case \"\$*\" in
    *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;;
esac
exit 0
"
    for gate in TEST LINT; do
        for code in 1 2 42 124 127; do
            write_real_review_plan '[{"op":"comment","target":"issue#42","body":"must not publish"}]'
            approve_real_review_plan
            printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n%s_COMMAND=exit %s\n' "$gate" "$code" > "$RU_CONFIG_DIR/review-policies.d/owner_test-repo"
            rc=0
            "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/apply-$gate-$code.stdout" 2> "$E2E_LOG_DIR/apply-$gate-$code.stderr" || rc=$?
            e2e_log_command "ru review --apply --push --non-interactive ($gate exit $code)" "$rc" "$E2E_LOG_DIR/apply-$gate-$code.stdout" "$E2E_LOG_DIR/apply-$gate-$code.stderr"
            assert_equals 2 "$rc" "Full CLI $gate exit $code blocks apply"
            assert_equals false "$(jq -r '.git.quality_gates_ok' "$plan_file")" "Failure persisted in plan"
            assert_file_not_exists "$gh_calls" "No GitHub mutation is attempted"
            after=$(git -C "$wt_path" rev-parse HEAD)
            assert_equals "$before" "$after" "Candidate HEAD is unchanged"
        done
    done
    # A passing command reaches the existing action executor, proving reachability.
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/owner_test-repo"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"passing action"}]'
    approve_real_review_plan
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/apply-pass.stdout" 2> "$E2E_LOG_DIR/apply-pass.stderr" || rc=$?
    assert_equals 0 "$rc" "Passing gates allow application"
    assert_file_exists "$gh_calls" "Passing gates reach the controlled GitHub endpoint"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_fully_loaded_runtime_detects_ruby_and_shell() {
    e2e_setup
    local ruby="$E2E_TEMP_DIR/ruby" shell="$E2E_TEMP_DIR/shell"
    mkdir -p "$ruby" "$shell/scripts"
    printf "gem 'rspec'\n" > "$ruby/Gemfile"
    printf '#!/usr/bin/env bash\nprintf "real shell test executed\\n"\n' > "$shell/scripts/run_all_tests.sh"
    chmod +x "$shell/scripts/run_all_tests.sh"
    local result rc=0
    # Source the complete entry point, including its normal robot-docs dispatch,
    # then inspect the effective definitions left loaded by that invocation.
    result=$(bash -c 'source "$1" robot-docs exit-codes > "$2"; detect_test_command "$3"' bash "$E2E_RU_SCRIPT" "$E2E_LOG_DIR/runtime-docs.json" "$ruby") || rc=$?
    assert_equals 0 "$rc" "Full entry point loads successfully"
    assert_equals 'bundle exec rspec' "$result" "Effective runtime retains Ruby detection"
    result=$(bash -c 'source "$1" robot-docs exit-codes > "$2"; run_test_gate "$3" "" 10' bash "$E2E_RU_SCRIPT" "$E2E_LOG_DIR/runtime-docs.json" "$shell")
    assert_equals true "$(jq -r '.ok' <<< "$result")" "Effective runtime executes detected shell tests"
    assert_contains "$(jq -r '.output_summary' <<< "$result")" 'real shell test executed' "Execution output proves the shell runner ran"
    e2e_cleanup
}

test_apply_dry_run() {
    log_test_start "e2e: dry-run mode prevents mutations"
    e2e_setup

    setup_real_review_candidate
    write_real_review_plan '[{"op":"close","target":"issue#99","reason":"completed"},{"op":"comment","target":"issue#99","body":"Closing this issue"}]'

    # Create mock gh that tracks if called
    local gh_was_called="$E2E_TEMP_DIR/gh_was_called"
    e2e_create_mock_gh_custom "
case \"\$*\" in
    *'api '*|*'issue '*|*'pr '*) echo 'gh called' >> '$gh_was_called' ;;
esac
exit 0
"
    local gate_marker="$E2E_TEMP_DIR/gate-ran" rc=0 before
    before=$(git -C "$APPLY_MAIN" rev-parse HEAD)
    printf 'TEST_COMMAND=touch %s\n' "$gate_marker" > "$RU_CONFIG_DIR/review-policies.d/_default"
    "$E2E_RU_SCRIPT" review --apply --dry-run --push --non-interactive > "$E2E_LOG_DIR/dry.stdout" 2> "$E2E_LOG_DIR/dry.stderr" || rc=$?
    assert_equals 0 "$rc" "Full CLI dry-run validates the real candidate"
    assert_file_not_exists "$gh_was_called" "No GitHub mutation in dry-run"
    assert_file_not_exists "$gate_marker" "Dry-run executes no test command"
    assert_file_not_exists "$APPLY_WT/.ru/review-approval.json" "Dry-run grants no approval"
    assert_equals "$before" "$(git -C "$APPLY_MAIN" rev-parse HEAD)" "Dry-run preserves main"
    assert_equals null "$(jq -r '.git.tests' "$APPLY_PLAN")" "Dry-run does not alter the plan"
    e2e_preserve_on_failure
    e2e_cleanup
    log_test_pass "e2e: dry-run mode prevents mutations"
}

test_cli_identity_and_approval_refusals() {
    e2e_setup
    setup_real_review_candidate
    local gh_calls="$E2E_TEMP_DIR/gh-mutations" gate_marker="$E2E_TEMP_DIR/gates-ran"
    local before rc mutation expected case_number=0
    before=$(git -C "$APPLY_MAIN" rev-parse HEAD)
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;; esac
exit 0
"
    printf 'TEST_COMMAND=touch %s\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' "$gate_marker" > "$RU_CONFIG_DIR/review-policies.d/_default"
    # Each refusal begins from a valid, already approved plan. The altered
    # field must be what stops execution, not an unrelated fixture defect.
    while IFS='|' read -r expected mutation; do
        [[ -n "$mutation" ]] || continue
        case_number=$((case_number + 1))
        write_real_review_plan '[{"op":"comment","target":"issue#42","body":"approved action"}]'
        approve_real_review_plan
        jq "$mutation" "$APPLY_PLAN" > "$APPLY_PLAN.changed"
        mv "$APPLY_PLAN.changed" "$APPLY_PLAN"
        rc=0
        "$E2E_RU_SCRIPT" review --apply --push --non-interactive --json > "$E2E_LOG_DIR/identity-$case_number.stdout" 2> "$E2E_LOG_DIR/identity-$case_number.stderr" || rc=$?
        assert_equals "$expected" "$rc" "Reject changed plan case $case_number: $mutation"
        assert_equals "$expected" "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/identity-$case_number.stdout")" "Structured refusal matches actual process exit"
        assert_equals "$expected" "$(jq -r '.data.results[0].exit_code' "$E2E_LOG_DIR/identity-$case_number.stdout")" "Structured refusal identifies the repository outcome"
        assert_file_not_exists "$gate_marker" "Refused identity/approval executes no gates"
        assert_file_not_exists "$gh_calls" "Refused identity/approval performs no GitHub mutation"
        assert_equals "$before" "$(git -C "$APPLY_MAIN" rev-parse main)" "Refused plan preserves main"
        assert_equals "$before" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Refused plan preserves origin"
    done <<'CASES'
4|.repo="foreign/repo"
4|.run_id="other-run"
4|.worktree_path="/tmp/foreign-worktree"
4|.git.branch="foreign-branch"
4|.git.base_ref="foreign-base"
4|.git.base_sha="0000000000000000000000000000000000000000"
4|.git.commits=[{sha:.git.base_sha,subject:"unreported candidate"}]
4|del(.metadata)
4|.items=[{type:"issue",number:0,title:"invalid",priority:"normal",decision:"fix"}]
4|.questions=[{id:"q",prompt:"question",answered:"yes"}]
4|.questions=[{id:"q",prompt:"question",answered:false,answer:{bad:"object"}}]
4|.gh_actions=[{op:"comment",target:"issue#42"}]
4|.gh_actions += [{op:"close",target:"issue#42",reason:"invented_reason"}]
2|.gh_actions[0].body="changed after approval"
CASES
    # --push cannot grant the missing default approval.
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"fresh unapproved action"}]'
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/unapproved.stdout" 2> "$E2E_LOG_DIR/unapproved.stderr" || rc=$?
    assert_equals 2 "$rc" "Default approval remains required with --push"
    assert_file_not_exists "$gate_marker" "Missing approval blocks before gates"
    # Invalid safety booleans must not quietly turn approval off.
    printf 'REVIEW_REQUIRE_APPROVAL=garbage\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/bad-policy.stdout" 2> "$E2E_LOG_DIR/bad-policy.stderr" || rc=$?
    assert_equals 2 "$rc" "Malformed approval policy fails closed"
    assert_file_not_exists "$gh_calls" "No refused case mutates GitHub"
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"candidate identity"}]'
    approve_real_review_plan
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m Candidate
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"candidate identity"}]'
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/changed-head.stdout" 2> "$E2E_LOG_DIR/changed-head.stderr" || rc=$?
    assert_equals 2 "$rc" "Matching current plan requires approval of the new candidate HEAD"
    assert_file_not_exists "$gh_calls" "Old approval cannot authorize a new candidate"
    # A mapped path that points at the main checkout is never an isolated
    # review worktree, even with matching plan metadata and valid approval.
    jq --arg path "$APPLY_MAIN" '."owner/test-repo".worktree_path=$path' "${APPLY_WT%/*}/mapping.json" > "${APPLY_WT%/*}/foreign-mapping.json"
    mv "${APPLY_WT%/*}/foreign-mapping.json" "${APPLY_WT%/*}/mapping.json"
    mkdir -p "$APPLY_MAIN/.ru"
    jq --arg path "$APPLY_MAIN" '.worktree_path=$path' "$APPLY_PLAN" > "$APPLY_MAIN/.ru/review-plan.json"
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/physical-main.stdout" 2> "$E2E_LOG_DIR/physical-main.stderr" || rc=$?
    assert_equals 4 "$rc" "Physical main checkout cannot stand in for a review worktree"
    assert_file_not_exists "$gh_calls" "Foreign physical mapping performs no action"
    jq --arg path "$APPLY_WT" '."owner/test-repo".worktree_path=$path' "${APPLY_WT%/*}/mapping.json" > "${APPLY_WT%/*}/restored-mapping.json"
    mv "${APPLY_WT%/*}/restored-mapping.json" "${APPLY_WT%/*}/mapping.json"
    mv "$APPLY_MAIN/.ru" "$E2E_TEMP_DIR/foreign-plan-artifact"
    # The documented policy deliberately allows unattended application.
    printf 'REVIEW_REQUIRE_APPROVAL=false\nREVIEW_ALLOW_PUSH=true\nTEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/policy-pass.stdout" 2> "$E2E_LOG_DIR/policy-pass.stderr" || rc=$?
    assert_equals 0 "$rc" "Documented explicit policy has observable effect"
    assert_file_exists "$gh_calls" "Permitted paired plan executes the actual controlled action"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_interactive_approval_receipt() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "Interactive PTY receipt proof requires Python's standard pty module"
        return 0
    fi
    e2e_setup
    setup_real_review_candidate
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"human approved action"}]'
    local gh_calls="$E2E_TEMP_DIR/gh-mutations" rc=0
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;; esac
exit 0
"
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    # Use real terminal stdin/stderr and redirected structured stdout. Answer
    # after the prompt appears: Gum may discard input queued before startup.
    env PATH="$E2E_MOCK_BIN:/usr/bin:/bin" TERM=dumb \
        python3 - "$E2E_RU_SCRIPT" "$E2E_LOG_DIR/interactive-result.json" "$E2E_LOG_DIR/interactive.typescript" <<'PY' \
        > "$E2E_LOG_DIR/interactive.stdout" 2> "$E2E_LOG_DIR/interactive.stderr" || rc=$?
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

runtime, result_path, transcript_path = sys.argv[1:]
with open(result_path, "wb") as structured, open(transcript_path, "wb") as transcript:
    child, terminal = pty.fork()
    if child == 0:
        os.dup2(structured.fileno(), 1)
        os.execv(runtime, [runtime, "review", "--apply", "--json"])
    # A fresh PTY otherwise reports 0x0; Gum cannot render its prompt there.
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
    deadline = time.monotonic() + 75
    observed = b""
    approved = False
    child_status = None
    while time.monotonic() < deadline:
        ready, _, _ = select.select([terminal], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(terminal, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if chunk:
                transcript.write(chunk)
                transcript.flush()
                observed += chunk
                # Respond to a real terminal cursor-position query.
                if b"\x1b[6n" in chunk:
                    os.write(terminal, b"\x1b[1;1R")
                plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", observed)
                if not approved and b"Approve this plan for " in plain:
                    os.write(terminal, b"y\n")
                    approved = True
        waited, status = os.waitpid(child, os.WNOHANG)
        if waited == child:
            child_status = status
            break
    if child_status is None:
        os.killpg(child, signal.SIGTERM)
        _, child_status = os.waitpid(child, 0)
        print("Interactive approval did not complete within 75 seconds", file=sys.stderr)
        sys.exit(124)
    os.close(terminal)
    if not approved:
        print("Runtime never displayed the required approval prompt", file=sys.stderr)
        sys.exit(1)
    sys.exit(os.waitstatus_to_exitcode(child_status))
PY
    assert_equals 0 "$rc" "Explicit terminal approval permits application"
    assert_file_exists "$APPLY_WT/.ru/review-approval.json" "Runtime writes the durable approval receipt"
    assert_equals "$(review_plan_digest "$APPLY_PLAN")" "$(jq -r '.plan_digest' "$APPLY_WT/.ru/review-approval.json")" "Receipt binds exact reviewed content"
    assert_equals "$(git -C "$APPLY_WT" rev-parse HEAD)" "$(jq -r '.candidate_head' "$APPLY_WT/.ru/review-approval.json")" "Receipt binds actual candidate HEAD"
    assert_file_exists "$gh_calls" "Approved interactive plan reaches the controlled endpoint"
    assert_equals 0 "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/interactive-result.json")" "Interactive JSON remains parseable with human output on terminal stderr"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_original_mapping_cannot_be_repointed() {
    e2e_setup
    setup_real_review_candidate
    local gh_calls="$E2E_TEMP_DIR/gh-mutations" gate_marker="$E2E_TEMP_DIR/gates-ran" rc=0
    git -C "$APPLY_MAIN" branch alternate "$APPLY_BASE"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"original base"}]'
    jq '."owner/test-repo".base_ref="alternate"' "${APPLY_WT%/*}/mapping.json" > "${APPLY_WT%/*}/changed-mapping.json"
    mv "${APPLY_WT%/*}/changed-mapping.json" "${APPLY_WT%/*}/mapping.json"
    jq '.git.base_ref="alternate"' "$APPLY_PLAN" > "$APPLY_PLAN.changed"
    mv "$APPLY_PLAN.changed" "$APPLY_PLAN"
    printf 'REVIEW_REQUIRE_APPROVAL=false\nTEST_COMMAND=touch %s\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' "$gate_marker" > "$RU_CONFIG_DIR/review-policies.d/_default"
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;; esac
exit 0
"
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/repointed.stdout" 2> "$E2E_LOG_DIR/repointed.stderr" || rc=$?
    assert_equals 4 "$rc" "Editing plan and mapping together cannot redirect original preparation"
    assert_file_not_exists "$gate_marker" "Repointed mapping stops before gates"
    assert_file_not_exists "$gh_calls" "Repointed mapping performs no GitHub mutation"
    assert_equals "$APPLY_BASE" "$(git -C "$APPLY_MAIN" rev-parse main)" "Original base is preserved"
    assert_equals "$APPLY_BASE" "$(git -C "$APPLY_MAIN" rev-parse alternate)" "Alternate branch is preserved"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Remote is preserved"
    # Restoring only the two edited fields recovers the actual prepared identity.
    jq '."owner/test-repo".base_ref="main"' "${APPLY_WT%/*}/mapping.json" > "${APPLY_WT%/*}/restored-mapping.json"
    mv "${APPLY_WT%/*}/restored-mapping.json" "${APPLY_WT%/*}/mapping.json"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"original base"}]'
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/restored.stdout" 2> "$E2E_LOG_DIR/restored.stderr" || rc=$?
    assert_equals 0 "$rc" "Original prepared identity remains usable"
    assert_file_exists "$gh_calls" "Restored positive plan reaches its intended endpoint"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_plan_change_during_actions_stops_remaining_actions() {
    e2e_setup
    setup_real_review_candidate
    local gh_calls="$E2E_TEMP_DIR/gh-mutations" rc=0
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"approved comment"},{"op":"close","target":"issue#42","reason":"completed"},{"op":"label","target":"issue#42","labels":["fixed"]}]'
    approve_real_review_plan
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    e2e_create_mock_gh_custom "
case \"\$*\" in
    *'issue comment'*)
        printf '%s\\n' \"\$*\" >> '$gh_calls'
        jq '.gh_actions[1].reason=\"not_planned\"' '$APPLY_PLAN' > '$APPLY_PLAN.changed'
        mv '$APPLY_PLAN.changed' '$APPLY_PLAN'
        ;;
    *'issue close'*|*'issue edit'*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;;
esac
exit 0
"
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/mid-action.stdout" 2> "$E2E_LOG_DIR/mid-action.stderr" || rc=$?
    assert_not_equals 0 "$rc" "Mid-application plan change is a partial failure"
    assert_file_exists "$gh_calls" "First approved operation actually executed"
    assert_equals 1 "$(wc -l < "$gh_calls" | tr -d ' ')" "Changed plan stops the later close and label"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Changed plan publishes no Git commits"
    assert_equals not_planned "$(jq -r '.gh_actions[1].reason' "$APPLY_PLAN")" "Counterexample really changed the reviewed content"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_approved_publication_and_idempotence() {
    e2e_setup
    setup_real_review_candidate
    local unrelated_sha
    git -C "$APPLY_MAIN" branch unrelated "$APPLY_BASE"
    git -C "$APPLY_MAIN" push -q origin refs/heads/unrelated:refs/heads/unrelated
    unrelated_sha=$(printf 'Unrelated local work\n' | git -C "$APPLY_MAIN" commit-tree "$APPLY_BASE^{tree}" -p "$APPLY_BASE")
    git -C "$APPLY_MAIN" update-ref refs/heads/unrelated "$unrelated_sha" "$APPLY_BASE"
    git -C "$APPLY_MAIN" config push.default matching
    git -C "$APPLY_MAIN" config remote.origin.push refs/heads/unrelated:refs/heads/unrelated
    local gh_calls="$E2E_TEMP_DIR/gh-mutations" rc=0 head_sha count
    printf 'real fix\n' > "$APPLY_WT/fix.txt"
    git -C "$APPLY_WT" add fix.txt
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q -m Fix
    head_sha=$(git -C "$APPLY_WT" rev-parse HEAD)
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"Verified fix"},{"op":"close","target":"issue#42","reason":"completed"},{"op":"label","target":"issue#42","labels":["fixed"]}]'
    approve_real_review_plan
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$gh_calls' ;; esac
exit 0
"
    printf 'REVIEW_ALLOW_PUSH=true\nTEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive --json > "$E2E_LOG_DIR/approved.stdout" 2> "$E2E_LOG_DIR/approved.stderr" || rc=$?
    assert_equals 0 "$rc" "Valid approved plan applies through real Git publication"
    assert_equals review "$(jq -r '.command' "$E2E_LOG_DIR/approved.stdout")" "Successful publication emits the common command envelope"
    assert_equals 0 "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/approved.stdout")" "Structured success matches actual process exit"
    assert_equals applied "$(jq -r '.data.results[0].status' "$E2E_LOG_DIR/approved.stdout")" "Structured result reports actual application"
    assert_equals "$head_sha" "$(git -C "$APPLY_MAIN" rev-parse main)" "Main reaches exact approved candidate"
    assert_equals "$head_sha" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Local bare origin receives exact candidate"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse unrelated)" "Only the approved base is pushed despite matching/custom push configuration"
    assert_equals "$unrelated_sha" "$(git -C "$APPLY_MAIN" rev-parse unrelated)" "Unrelated local work remains untouched"
    assert_contains "$(cat "$APPLY_MAIN/fix.txt")" 'real fix' "Published candidate includes the actual fix"
    count=$(wc -l < "$gh_calls" | tr -d ' ')
    assert_equals 3 "$count" "All three approved GitHub operations execute"
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/replay.stdout" 2> "$E2E_LOG_DIR/replay.stderr" || rc=$?
    assert_equals 0 "$rc" "Recomputed gates retain exact approval on replay"
    assert_equals 3 "$(wc -l < "$gh_calls" | tr -d ' ')" "Replay preserves action idempotence"
    # A later candidate commit revokes approval even if the plan is updated.
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m Later
    write_real_review_plan '[{"op":"comment","target":"issue#43","body":"new candidate"}]'
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/new-head.stdout" 2> "$E2E_LOG_DIR/new-head.stderr" || rc=$?
    assert_equals 4 "$rc" "Moved base/candidate requires a newly prepared review"
    assert_equals "$head_sha" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Revoked approval publishes nothing further"
    assert_equals 3 "$(wc -l < "$gh_calls" | tr -d ' ')" "Revoked approval executes no new action"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_comment_only_optional_git_contract() {
    e2e_setup
    setup_real_review_candidate
    local calls="$E2E_TEMP_DIR/mutations" gate_log="$E2E_TEMP_DIR/gates" rc=0
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$calls' ;; esac
exit 0
"
    printf 'TEST_COMMAND=printf gate >> %s\nLINT_COMMAND=exit 0\n' "$gate_log" > "$RU_CONFIG_DIR/review-policies.d/_default"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"optional git comment"}]'
    jq 'del(.git)' "$APPLY_PLAN" > "$APPLY_PLAN.changed"
    mv "$APPLY_PLAN.changed" "$APPLY_PLAN"
    approve_real_review_plan
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/no-git.stdout" 2> "$E2E_LOG_DIR/no-git.stderr" || rc=$?
    assert_equals 0 "$rc" "Original no-commit plan may omit optional git fields"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Optional-git positive executes the actual action"
    assert_equals "$(review_plan_digest "$APPLY_PLAN")" "$(jq -r '.plan_digest' "$APPLY_WT/.ru/review-approval.json")" "New gate-only git section retains approval"
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/no-git-replay.stdout" 2> "$E2E_LOG_DIR/no-git-replay.stderr" || rc=$?
    assert_equals 0 "$rc" "Optional-git positive replays successfully"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Optional-git replay preserves idempotence"
    local gate_bytes
    gate_bytes=$(wc -c < "$gate_log")
    jq '.git.branch="foreign-branch"' "$APPLY_PLAN" > "$APPLY_PLAN.changed"
    mv "$APPLY_PLAN.changed" "$APPLY_PLAN"
    approve_real_review_plan
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/partial-wrong.stdout" 2> "$E2E_LOG_DIR/partial-wrong.stderr" || rc=$?
    assert_equals 4 "$rc" "Explicit wrong partial identity is refused even without code"
    assert_equals "$gate_bytes" "$(wc -c < "$gate_log")" "Wrong partial identity executes no gates"
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m 'Unreported candidate'
    jq 'del(.git)' "$APPLY_PLAN" > "$APPLY_PLAN.changed"
    mv "$APPLY_PLAN.changed" "$APPLY_PLAN"
    approve_real_review_plan
    rc=0
    "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/unreported.stdout" 2> "$E2E_LOG_DIR/unreported.stderr" || rc=$?
    assert_equals 4 "$rc" "Actual code commits require complete reported git identity"
    assert_equals "$gate_bytes" "$(wc -c < "$gate_log")" "Unreported candidate executes no gates"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Invalid controls perform no further action"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "All optional-git cases preserve the remote"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_commit_pin_review() {
    e2e_setup
    setup_real_review_candidate main commit
    local calls="$E2E_TEMP_DIR/commit-pin-calls" rc=0
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$calls' ;; esac
exit 0
"
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"review pinned commit"}]'
    approve_real_review_plan
    "$E2E_RU_SCRIPT" review --apply --json --non-interactive > "$E2E_LOG_DIR/commit-pin.stdout" 2> "$E2E_LOG_DIR/commit-pin.stderr" || rc=$?
    assert_equals 0 "$rc" "Approved commit-pinned comment executes"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Commit pin positive reaches its endpoint"
    assert_equals "$APPLY_BASE" "$(jq -r '."owner/test-repo".base_ref_full' "${APPLY_WT%/*}/mapping.json")" "Mapping retains the full commit object"
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m 'Commit-pinned code candidate'
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"no unrequested publication branch"}]'
    approve_real_review_plan
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/commit-pin-push.stdout" 2> "$E2E_LOG_DIR/commit-pin-push.stderr" || rc=$?
    assert_equals 2 "$rc" "Immutable commit pin needs an explicit branch-based review to publish code"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Commit-pinned review preserves the remote"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Blocked publication executes no further action"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_changed_publication_target_refuses() {
    e2e_setup
    setup_real_review_candidate
    local calls="$E2E_TEMP_DIR/target-calls" gate="$E2E_TEMP_DIR/target-gates" rc=0
    local foreign="$E2E_TEMP_DIR/foreign.git"
    git -C "$E2E_TEMP_DIR" clone --bare -q "$E2E_TEMP_DIR/remote.git" "$foreign"
    git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m Candidate
    e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$calls' ;; esac
exit 0
"
    printf 'TEST_COMMAND=printf gate >> %s\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' "$gate" > "$RU_CONFIG_DIR/review-policies.d/_default"
    write_real_review_plan '[{"op":"comment","target":"issue#42","body":"publish only reviewed repository"}]'
    approve_real_review_plan
    local candidate
    candidate=$(git -C "$APPLY_WT" rev-parse HEAD)
    git -C "$APPLY_MAIN" config remote.origin.pushurl "$foreign"
    "$E2E_RU_SCRIPT" review --apply --push --json --non-interactive > "$E2E_LOG_DIR/changed-target.stdout" 2> "$E2E_LOG_DIR/changed-target.stderr" || rc=$?
    assert_equals 4 "$rc" "Changed effective push target revokes the prepared review identity"
    assert_file_not_exists "$gate" "Wrong target refuses before gates"
    assert_file_not_exists "$calls" "Wrong target performs no GitHub mutation"
    assert_equals "$APPLY_BASE" "$(git -C "$APPLY_MAIN" rev-parse HEAD)" "Wrong target preserves main"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Wrong target preserves intended remote"
    assert_equals "$APPLY_BASE" "$(git -C "$foreign" rev-parse main)" "Wrong target preserves foreign remote"
    git -C "$APPLY_MAIN" config --unset remote.origin.pushurl
    rc=0
    "$E2E_RU_SCRIPT" review --apply --push --json --non-interactive > "$E2E_LOG_DIR/restored-target.stdout" 2> "$E2E_LOG_DIR/restored-target.stderr" || rc=$?
    assert_equals 0 "$rc" "Restored approved target remains usable"
    assert_equals "$candidate" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Permitted control publishes the exact approved candidate"
    assert_equals "$APPLY_BASE" "$(git -C "$foreign" rev-parse main)" "Permitted control still preserves foreign remote"
    assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Permitted control performs the intended action"
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_publication_freezes_receiver_at_push() {
    local scenario
    for scenario in stable late-config; do
        e2e_setup
        setup_real_review_candidate
        local calls="$E2E_TEMP_DIR/late-calls" foreign="$E2E_TEMP_DIR/foreign.git"
        local real_git candidate rc=0 old_path="$PATH"
        real_git=$(command -v git)
        git -C "$E2E_TEMP_DIR" clone --bare -q "$E2E_TEMP_DIR/remote.git" "$foreign"
        printf 'Approved real content\n' > "$APPLY_WT/approved.txt"
        git -C "$APPLY_WT" add approved.txt
        git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q -m Candidate
        candidate=$(git -C "$APPLY_WT" rev-parse HEAD)
        e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$calls' ;; esac
exit 0
"
        printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
        write_real_review_plan '[{"op":"comment","target":"issue#42","body":"publish to the approved receiver"}]'
        approve_real_review_plan
        mkdir -p "$E2E_TEMP_DIR/late-bin"
        export RU_LATE_REAL_GIT="$real_git" RU_LATE_MAIN="$APPLY_MAIN" RU_LATE_FOREIGN="$foreign"
        export RU_LATE_SCENARIO="$scenario" RU_LATE_MARKER="$E2E_TEMP_DIR/actual-push.json"
        cat > "$E2E_TEMP_DIR/late-bin/git" <<'GIT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == -C && "${2:-}" == "$RU_LATE_MAIN" ]]; then
    for argument in "$@"; do
        if [[ "$argument" == push ]]; then
            jq -nc --args '$ARGS.positional' -- "$@" > "$RU_LATE_MARKER" || exit 3
            if [[ "$RU_LATE_SCENARIO" == late-config ]]; then
                "$RU_LATE_REAL_GIT" -C "$RU_LATE_MAIN" config remote.origin.pushurl "$RU_LATE_FOREIGN" || exit 3
            fi
            break
        fi
    done
fi
exec "$RU_LATE_REAL_GIT" "$@"
GIT
        chmod +x "$E2E_TEMP_DIR/late-bin/git"
        export PATH="$E2E_TEMP_DIR/late-bin:$PATH"
        "$E2E_RU_SCRIPT" review --apply --push --non-interactive --json > "$E2E_LOG_DIR/late-$scenario.stdout" 2> "$E2E_LOG_DIR/late-$scenario.stderr" || rc=$?
        export PATH="$old_path"
        assert_file_exists "$RU_LATE_MARKER" "Paired $scenario fixture reaches the actual Git push invocation"
        assert_equals "$candidate" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "$scenario publishes only to the prepared receiver"
        assert_equals "$APPLY_BASE" "$(git -C "$foreign" rev-parse main)" "$scenario preserves the foreign receiver"
        assert_equals "$candidate" "$(git -C "$APPLY_WT" rev-parse HEAD)" "$scenario preserves the approved worktree commit"
        if [[ "$scenario" == stable ]]; then
            assert_equals 0 "$rc" "Stable publication succeeds"
            assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Stable publication runs its approved action"
        else
            assert_equals "$foreign" "$(git -C "$APPLY_MAIN" config remote.origin.pushurl)" "Late fixture really changed remote configuration"
            assert_equals 2 "$rc" "Changed identity stops later actions after the safe frozen push"
            assert_file_not_exists "$calls" "Late configuration change executes no GitHub action"
        fi
        assert_equals "$rc" "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/late-$scenario.stdout")" "Publication metadata matches actual $scenario exit"
        e2e_preserve_on_failure
        e2e_cleanup
    done
}

test_cli_documented_close_reason() {
    e2e_setup
    setup_real_review_candidate
    local calls="$E2E_TEMP_DIR/close-arguments.jsonl" rc=0
    e2e_create_mock_gh_custom "
if [[ \"\${1:-}\" == issue || \"\${1:-}\" == pr ]]; then jq -nc --args '\$ARGS.positional' -- \"\$@\" >> '$calls' || exit 3; fi
exit 0
"
    printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
    write_real_review_plan '[{"op":"close","target":"issue#42","reason":"not_planned"},{"op":"close","target":"pr#15","reason":"Outside contribution declined: adds an unwanted dependency"}]'
    approve_real_review_plan
    "$E2E_RU_SCRIPT" review --apply --non-interactive --json > "$E2E_LOG_DIR/close.stdout" 2> "$E2E_LOG_DIR/close.stderr" || rc=$?
    assert_equals 0 "$rc" "Approved documented close reason succeeds through the public CLI"
    assert_equals '["issue","close","42","-R","owner/test-repo","--reason","not planned"]' "$(jq -sc '.[0]' "$calls")" "Actual controlled CLI receives one native reason argument"
    assert_equals '["pr","close","15","-R","owner/test-repo","--comment","Closing: Outside contribution declined: adds an unwanted dependency"]' "$(jq -sc '.[1]' "$calls")" "Descriptive PR close reason reaches the actual controlled endpoint"
    assert_equals 2 "$(jq -s 'length' "$calls")" "Both supported approved actions execute once"
    assert_equals 0 "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/close.stdout")" "Close result reflects successful execution"
    assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Comment-only action preserves the actual receiver"
    local gate="$E2E_TEMP_DIR/unsupported-gate"
    printf 'TEST_COMMAND=touch %s\nLINT_COMMAND=exit 0\n' "$gate" > "$RU_CONFIG_DIR/review-policies.d/_default"
    local unsupported
    for unsupported in '[{"op":"comment","target":"issue#42","body":"must not precede forbidden labels"},{"op":"label","target":"pr#15","labels":["reviewed"]}]' '[{"op":"comment","target":"issue#42","body":"must not precede forbidden merge"},{"op":"merge","target":"pr#15"}]'; do
        write_real_review_plan "$unsupported"
        approve_real_review_plan
        rc=0
        "$E2E_RU_SCRIPT" review --apply --non-interactive --json > "$E2E_LOG_DIR/unsupported.stdout" 2> "$E2E_LOG_DIR/unsupported.stderr" || rc=$?
        assert_equals 2 "$rc" "Supported schema cannot grant a forbidden application capability"
        assert_equals 2 "$(jq -r '._meta.exit_code' "$E2E_LOG_DIR/unsupported.stdout")" "Policy refusal metadata agrees with actual exit"
        assert_file_not_exists "$gate" "Forbidden action refuses before running gates"
        assert_equals 2 "$(jq -s 'length' "$calls")" "Forbidden plan cannot execute even its preceding valid comment"
        assert_equals "$APPLY_BASE" "$(git -C "$APPLY_MAIN" rev-parse HEAD)" "Policy refusal preserves actual main HEAD"
    done
    e2e_preserve_on_failure
    e2e_cleanup
}

test_cli_tag_review_preserves_ref_namespace() {
    local kind
    for kind in lightweight annotated; do
        e2e_setup
        setup_real_review_candidate reviewed-tag refs/tags/reviewed-tag "$kind"
        local calls="$E2E_TEMP_DIR/mutations" rc=0 tag_object
        tag_object=$(git -C "$APPLY_MAIN" rev-parse refs/tags/reviewed-tag)
        git -C "$APPLY_MAIN" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m 'Unrelated main advance'
        git -C "$APPLY_MAIN" branch reviewed-tag HEAD
        e2e_create_mock_gh_custom "
case \"\$*\" in *'api '*|*'issue '*|*'pr '*) printf '%s\\n' \"\$*\" >> '$calls' ;; esac
exit 0
"
        printf 'TEST_COMMAND=exit 0\nLINT_COMMAND=exit 0\nREVIEW_ALLOW_PUSH=true\n' > "$RU_CONFIG_DIR/review-policies.d/_default"
        write_real_review_plan '[{"op":"comment","target":"issue#42","body":"review pinned tag"}]'
        approve_real_review_plan
        "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/tag.stdout" 2> "$E2E_LOG_DIR/tag.stderr" || rc=$?
        assert_equals 0 "$rc" "Approved $kind tag review survives a branch/tag name collision"
        assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Tag positive executes its actual comment"
        assert_equals refs/tags/reviewed-tag "$(jq -r '."owner/test-repo".base_ref_full' "${APPLY_WT%/*}/mapping.json")" "Mapping retains the original tag namespace"
        git -C "$APPLY_MAIN" update-ref refs/tags/reviewed-tag HEAD "$tag_object"
        rc=0
        "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/moved-tag.stdout" 2> "$E2E_LOG_DIR/moved-tag.stderr" || rc=$?
        assert_equals 4 "$rc" "Moved original tag cannot reuse approval"
        git -C "$APPLY_MAIN" update-ref refs/tags/reviewed-tag "$tag_object"
        git -C "$APPLY_MAIN" update-ref -d refs/tags/reviewed-tag "$tag_object"
        rc=0
        "$E2E_RU_SCRIPT" review --apply --non-interactive > "$E2E_LOG_DIR/missing-tag.stdout" 2> "$E2E_LOG_DIR/missing-tag.stderr" || rc=$?
        assert_equals 4 "$rc" "Missing original tag cannot fall back to its same-named branch"
        git -C "$APPLY_MAIN" update-ref refs/tags/reviewed-tag "$tag_object"
        git -C "$APPLY_WT" -c user.name=Apply -c user.email=apply@example.invalid commit -q --allow-empty -m 'Tag-based code candidate'
        write_real_review_plan '[{"op":"comment","target":"issue#42","body":"do not publish tag candidate"}]'
        approve_real_review_plan
        rc=0
        "$E2E_RU_SCRIPT" review --apply --push --non-interactive > "$E2E_LOG_DIR/tag-push.stdout" 2> "$E2E_LOG_DIR/tag-push.stderr" || rc=$?
        assert_equals 2 "$rc" "Tag-based code publication is explicitly refused"
        assert_contains "$(cat "$E2E_LOG_DIR/tag-push.stderr")" 'requires a branch base' "Refusal identifies the immutable tag publication boundary"
        assert_equals "$tag_object" "$(git -C "$APPLY_MAIN" rev-parse refs/tags/reviewed-tag)" "Tag object remains unchanged"
        assert_equals "$APPLY_BASE" "$(git -C "$E2E_TEMP_DIR/remote.git" rev-parse main)" "Tag review never publishes an unrequested branch"
        assert_equals 1 "$(wc -l < "$calls" | tr -d ' ')" "Invalid tag cases perform no further action"
        e2e_preserve_on_failure
        e2e_cleanup
    done
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: apply phase"

run_test test_full_apply_cycle
run_test test_apply_with_quality_failure
run_test test_cli_apply_failed_gates_prevent_mutations
run_test test_fully_loaded_runtime_detects_ruby_and_shell
run_test test_apply_dry_run
run_test test_cli_identity_and_approval_refusals
run_test test_cli_approved_publication_and_idempotence
run_test test_cli_interactive_approval_receipt
run_test test_cli_original_mapping_cannot_be_repointed
run_test test_cli_plan_change_during_actions_stops_remaining_actions
run_test test_cli_comment_only_optional_git_contract
run_test test_cli_commit_pin_review
run_test test_cli_changed_publication_target_refuses
run_test test_cli_publication_freezes_receiver_at_push
run_test test_cli_documented_close_reason
run_test test_cli_tag_review_preserves_ref_namespace

print_results
exit "$(get_exit_code)"
