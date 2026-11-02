#!/usr/bin/env bash
#
# Unit tests: commit publication transport binding (run_commit_publication_transport)
#
# Covers, with real local Git repositories as receivers and whatever git is installed:
# - binding the named remote's push to the one scanned destination on any Git version (Git 2.34 and 2.43 read an
#   empty `-c remote.X.url=` as one more URL, so a bind that relied on it refused every publication)
# - inspect, fetch and push reach only the scanned receiver when the named remote lists two push URLs
# - the named remote's tracking ref still follows a publication push
# - the repository's own pre-push hook still sees the named remote and the scanned URL
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
# shellcheck disable=SC2034  # Globals consumed by sourced ru functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

transport_script_dir="$SCRIPT_DIR"
transport_project_dir="$PROJECT_DIR"
# shellcheck source=../ru
source "$PROJECT_DIR/ru"
SCRIPT_DIR="$transport_script_dir"
PROJECT_DIR="$transport_project_dir"

log_step() { :; }
log_info() { :; }
log_warn() { :; }
log_success() { :; }
log_verbose() { :; }

_transport_bare() {
    git init --bare --quiet "$1" && git -C "$1" symbolic-ref HEAD refs/heads/main
}

_transport_commit() { # <repo> <file content>
    printf '%s\n' "$2" > "$1/file.txt"
    git -C "$1" add file.txt && git -C "$1" commit --quiet -m "$2" && git -C "$1" rev-parse HEAD
}

# A working repo whose origin fetches from receiver A and lists push URLs A and B (two receivers), with a pre-push hook
# that records its arguments. Prints nothing; sets the globals below.
_transport_setup() {
    local root="$1"
    T_A="$root/receiver-a.git"; T_B="$root/receiver-b.git"; T_REPO="$root/work"; T_HOOKLOG="$root/hook.log"
    _transport_bare "$T_A" && _transport_bare "$T_B" || return 1
    git init --quiet "$T_REPO" && git -C "$T_REPO" symbolic-ref HEAD refs/heads/main || return 1
    git -C "$T_REPO" config user.email "test@test.com" && git -C "$T_REPO" config user.name "Test User" || return 1
    T_BASE=$(_transport_commit "$T_REPO" base) || return 1
    git -C "$T_REPO" push --quiet "$T_A" main && git -C "$T_REPO" push --quiet "$T_B" main || return 1
    git -C "$T_REPO" remote add origin "$T_A" || return 1
    git -C "$T_REPO" config --add remote.origin.pushurl "$T_A" && git -C "$T_REPO" config --add remote.origin.pushurl "$T_B" || return 1
    git -C "$T_REPO" fetch --quiet origin || return 1
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s %s\n' \"\$1\" \"\$2\" >> '$T_HOOKLOG'" 'cat > /dev/null' > "$T_REPO/.git/hooks/pre-push"
    chmod +x "$T_REPO/.git/hooks/pre-push"
}

test_transport_binds_the_scanned_destination_on_any_git() {
    local test_name git_version
    git_version=$(git --version)
    test_name="run_commit_publication_transport: binds only the scanned destination ($git_version)"
    log_test_start "$test_name"
    local root out rc
    root=$(create_temp_dir)
    assert_exit_code 0 "real receivers and a two-URL origin are set up" _transport_setup "$root"

    out=$(run_commit_publication_transport "$T_REPO" origin "$T_A" inspect refs/heads/main 2>&1); rc=$?
    assert_equals 0 "$rc" "inspect binds origin to the scanned receiver: $out"
    assert_contains "$out" "$T_BASE" "inspect reads the scanned receiver's main"
    log_test_pass "$test_name"
}

test_transport_publishes_only_to_the_scanned_receiver() {
    local test_name="run_commit_publication_transport: fetch and push reach only the scanned receiver"
    log_test_start "$test_name"
    local root out rc other theirs candidate
    root=$(create_temp_dir)
    assert_exit_code 0 "real receivers and a two-URL origin are set up" _transport_setup "$root"

    # A commit that only receiver A has; fetch must bring it from A.
    other="$root/other"
    git clone --quiet "$T_A" "$other" && git -C "$other" config user.email "o@test.com" && git -C "$other" config user.name "Other"
    theirs=$(_transport_commit "$other" theirs)
    git -C "$other" push --quiet origin main
    out=$(run_commit_publication_transport "$T_REPO" origin "$T_A" fetch refs/heads/main 2>&1); rc=$?
    assert_equals 0 "$rc" "fetch from the scanned receiver succeeds: $out"
    assert_exit_code 0 "the receiver's commit is now local" git -C "$T_REPO" cat-file -e "$theirs^{commit}"

    git -C "$T_REPO" merge --quiet --ff-only "$theirs"
    candidate=$(_transport_commit "$T_REPO" candidate)
    out=$(run_commit_publication_transport "$T_REPO" origin "$T_A" push refs/heads/main "$candidate" "$theirs" 2>&1); rc=$?
    assert_equals 0 "$rc" "push to the scanned receiver succeeds: $out"
    assert_equals "$candidate" "$(git -C "$T_A" rev-parse refs/heads/main)" "the scanned receiver has the candidate"
    assert_equals "$T_BASE" "$(git -C "$T_B" rev-parse refs/heads/main)" "the other push URL's receiver is unchanged"
    assert_equals "$candidate" "$(git -C "$T_REPO" rev-parse refs/remotes/origin/main)" "origin's tracking ref follows the push"
    assert_equals "origin $T_A" "$(cat "$T_HOOKLOG" 2>/dev/null)" "the repository's pre-push hook saw origin and the scanned URL once"
    log_test_pass "$test_name"
}

run_test test_transport_binds_the_scanned_destination_on_any_git
run_test test_transport_publishes_only_to_the_scanned_receiver

print_results
exit "$(get_exit_code)"
