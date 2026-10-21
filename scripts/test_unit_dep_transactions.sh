#!/usr/bin/env bash
# Real local Git and npm resolution around controlled AI responses. These tests
# prove transaction boundaries; they do not qualify a live AI provider.
# shellcheck disable=SC1091,SC2034,SC2317
set -uo pipefail

TX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TX_PROJECT_DIR="$(cd "$TX_SCRIPT_DIR/.." && pwd)"
source "$TX_SCRIPT_DIR/test_framework.sh"
source "$TX_PROJECT_DIR/ru"
TX_ORIGINAL_PATH="$PATH"
TX_REAL_NPM="$(command -v npm || true)"

tx_json_assert() {
    local json="$1" filter="$2" message="$3"
    assert_success "$message" jq -e "$filter" <<< "$json"
}

tx_plan() {
    jq -cn --argjson names "$1" '{status:"ok",failed_managers:0,total_outdated:($names|length),results:[{manager:"npm",status:"ok",outdated:[$names[]|{name:.,current:"1.0.0",wanted:"1.1.0",latest:"1.1.0",type:"dependencies"}]}]}'
}

tx_create_fixture() {
    local mode="$1" names="${2:-}" root repo
    [[ -n "$names" ]] || names='["alpha","beta","gamma"]'
    root=$(mktemp -d /tmp/ru-dep-transaction.XXXXXX) || return 1
    repo="$root/project"
    mkdir -p "$repo" "$root/bin" || return 1
    printf '0\n' > "$root/agent.count"
    printf '%s\n' "$mode" > "$root/scenario"
    printf 'owned baseline source\n' > "$repo/base.txt"
    printf 'node_modules/\n' > "$repo/.gitignore"
    jq -cn --argjson names "$names" '{name:"ru-transaction-fixture",version:"1.0.0",private:true,dependencies:(reduce $names[] as $name ({}; .[$name]="1.0.0"))}' > "$repo/package.json" || return 1
    if [[ "$mode" == lock-only ]]; then
        jq '.dependencies.alpha="^1.0.0"' "$repo/package.json" > "$root/manifest" || return 1
        cp "$root/manifest" "$repo/package.json" || return 1
    fi
    if [[ "$mode" == already-current || "$mode" == stale-plan ]]; then
        local version=1.1.0
        [[ "$mode" != stale-plan ]] || version=1.0.5
        jq --arg version "$version" '.dependencies.alpha=$version' "$repo/package.json" > "$root/manifest" || return 1
        cp "$root/manifest" "$repo/package.json" || return 1
    fi
    jq '{name:.name,version:.version,lockfileVersion:3,requires:true,packages:({"":{name:.name,version:.version,dependencies:.dependencies}} + (.dependencies|to_entries|map({key:("node_modules/"+.key),value:{version:(.value|ltrimstr("^"))}})|from_entries))}' "$repo/package.json" > "$repo/package-lock.json" || return 1
    git -C "$repo" init -q -b main || return 1
    git -C "$repo" config user.name 'RU transaction fixture' || return 1
    git -C "$repo" config user.email fixture@example.invalid || return 1
    git -C "$repo" add . || return 1
    git -C "$repo" commit -qm 'Transaction baseline' || return 1
    git clone -q --bare -- "$repo" "$root/receiver.git" || return 1
    git clone -q --bare -- "$repo" "$root/other.git" || return 1
    git -C "$repo" remote add origin "$root/receiver.git" || return 1
    cat > "$root/receiver.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail
while read -r old new ref; do
    printf '%s %s %s\n' "$old" "$new" "$ref" >> "$TX_ROOT/received-updates"
    [[ "$TX_MODE" != push-rejected ]] || exit 17
    for commit in $(git rev-list "$old..$new"); do
        tree=$(git show -s --format=%T "$commit") || exit 2
        awk -v head="$commit" -v tree="$tree" '$1==head && $2==tree {found=1} END {exit !found}' "$TX_ROOT/tested" || exit 18
    done
done
HOOK
    cat > "$root/bin/ntm" <<'NTM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$TX_ROOT/ntm.args"
case "${1:-}" in
    spawn)
        repo="$NTM_PROJECTS_BASE/$2"
        session="$2"
        for arg in "$@"; do [[ "$arg" != --label=* ]] || session+="--${arg#*=}"; done
        printf '%s\n' "$repo" > "$TX_ROOT/ntm.repo"
        printf '%s\n' "$session" > "$TX_ROOT/ntm.state"
        count=$(cat "$TX_ROOT/agent.count") || exit 2
        printf '%s\n' "$((count+1))" > "$TX_ROOT/agent.count"
        jq -r --argjson n "$count" '[.results[].outdated[]][$n].name' "$TX_ROOT/plan.json" > "$TX_ROOT/target"
        printf 'controlled provider spawn output\n'
        printf '{"success":true,"session":"%s"}\n' "$session" ;;
    --robot-status) printf '{"success":true,"sessions":{}}\n' ;;
    --robot-send=*)
        for arg in "$@"; do [[ "$arg" != --msg=* ]] || printf '%s\n' "${arg#*=}" > "$TX_ROOT/last-prompt"; done
        printf '{"success":true,"delivered":true}\n' ;;
    --robot-wait=*)
        if [[ " $* " == *' --transition '* ]]; then
            bash "$TX_ROOT/agent.sh" > "$TX_ROOT/agent.stdout" 2> "$TX_ROOT/agent.stderr" || exit "$?"
        fi
        printf '{"success":true,"condition":"idle"}\n' ;;
    --robot-tail=*) printf '{"success":true,"content":"controlled transaction"}\n' ;;
    kill)
        [[ "${2:-}" == "$(cat "$TX_ROOT/ntm.state")" ]] || exit 2
        printf '%s\n' "$2" > "$TX_ROOT/ntm.stopped"
        printf '{"success":true}\n' ;;
    *) exit 2 ;;
esac
NTM
    cat > "$root/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == has-session && "${2:-}" == -t ]] || exit 2
[[ -f "$TX_ROOT/ntm.state" ]] || exit 1
session=$(cat "$TX_ROOT/ntm.state") || exit 2
[[ "${3#=}" == "$session" ]] || exit 1
if [[ -f "$TX_ROOT/ntm.stopped" && "$(cat "$TX_ROOT/ntm.stopped")" == "$session" ]]; then exit 1; fi
exit 0
TMUX
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/codex"
    cat > "$root/bin/npm" <<'NPM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s | %s\n' "$PWD" "$*" >> "$TX_ROOT/npm.calls"
if [[ "${TX_NATIVE_NPM:-false}" == true || "${1:-}" != ci ]]; then
    exec "$TX_REAL_NPM" "$@"
fi
[[ "$TX_MODE" != install-failure ]] || exit 13
while IFS=$'\t' read -r name version; do
    [[ "$TX_MODE" != install-stale || "$name" != alpha ]] || version=1.0.0
    mkdir -p "node_modules/$name" || exit 2
    jq -cn --arg name "$name" --arg version "$version" '{name:$name,version:$version,main:"index.js"}' > "node_modules/$name/package.json" || exit 2
    printf 'module.exports = require("./package.json").version;\n' > "node_modules/$name/index.js"
done < <(jq -r '.packages|to_entries[]|select(.key|startswith("node_modules/"))|[.key|ltrimstr("node_modules/")] + [.value.version]|@tsv' package-lock.json)
printf 'Materialized locked fixture packages\n'
NPM
    cat > "$root/agent.sh" <<'AGENT'
#!/usr/bin/env bash
set -uo pipefail
repo=$(cat "$TX_ROOT/ntm.repo") || exit 2
name=$(cat "$TX_ROOT/target") || exit 2
before=$(git -C "$repo" rev-parse HEAD) || exit 2
printf '%s\n' "$before" > "$TX_ROOT/agent.before"
if [[ "$TX_MODE" == agent-timeout ]]; then
    sleep 20 & child=$!
    printf '%s\n' "$child" > "$TX_ROOT/timeout.child"
    wait "$child"
fi
[[ "$TX_MODE" != no-op ]] || exit 0
[[ "$TX_MODE" != agent-branch ]] || git -C "$repo" switch -qc provider-branch || exit 2
if [[ "$TX_MODE" == squash-history ]]; then
    printf 'failed private intermediate source\n' > "$repo/base.txt"
    git -C "$repo" add base.txt || exit 2
    git -C "$repo" commit -qm 'Private invalid intermediate' || exit 2
    git -C "$repo" show "$before:base.txt" > "$repo/base.txt" || exit 2
fi
version=1.1.0
[[ "$TX_MODE" != wrong-dependency ]] || name=beta
[[ "$TX_MODE" != wrong-version ]] || version=1.2.0
if [[ "$TX_MODE" == native-success ]]; then
    (cd "$repo" && npm install "alpha@$version" --save-exact --package-lock-only --ignore-scripts --no-audit --no-fund --registry="$TX_REGISTRY" --cache="$TX_ROOT/agent-cache") || exit 2
else
    if [[ "$TX_MODE" != lock-only ]]; then
        jq --arg name "$name" --arg version "$version" '.dependencies[$name]=$version' "$repo/package.json" > "$TX_ROOT/manifest.candidate" || exit 2
        cp "$TX_ROOT/manifest.candidate" "$repo/package.json" || exit 2
    fi
    if [[ "$TX_MODE" != manifest-only ]]; then
        jq --arg name "$name" --arg version "$version" --arg mode "$TX_MODE" '
          (if $mode=="lock-only" then . else .packages[""].dependencies[$name]=$version end) |
          .packages["node_modules/"+$name].version=$version' "$repo/package-lock.json" > "$TX_ROOT/lock.candidate" || exit 2
        cp "$TX_ROOT/lock.candidate" "$repo/package-lock.json" || exit 2
    fi
fi
case "$TX_MODE" in
    unexpected) printf 'unrequested source change\n' > "$repo/base.txt" ;;
    changed-script)
        jq '.scripts.test="true"' "$repo/package.json" > "$TX_ROOT/manifest.candidate" || exit 2
        cp "$TX_ROOT/manifest.candidate" "$repo/package.json" || exit 2 ;;
    manifest-mode) chmod +x "$repo/package.json" ;;
    original-concurrent) printf 'concurrent original user work\n' >> "$TX_ROOT/project/base.txt" ;;
    original-branch) git -C "$TX_ROOT/project" switch -qc user-branch || exit 2 ;;
    original-remote) git -C "$TX_ROOT/project" remote set-url origin "$TX_ROOT/other.git" || exit 2 ;;
esac
git -C "$repo" add --all || exit 2
git -C "$repo" commit -qm "Provider updates $name to $version" || exit 2
if [[ "$TX_MODE" == agent-revert ]]; then
    git -C "$repo" show "$before:package.json" > "$repo/package.json" || exit 2
    git -C "$repo" show "$before:package-lock.json" > "$repo/package-lock.json" || exit 2
    git -C "$repo" add package.json package-lock.json || exit 2
    git -C "$repo" commit -qm 'Provider reverts its attempt' || exit 2
fi
AGENT
    cat > "$root/project-test.sh" <<'TEST'
#!/usr/bin/env bash
set -uo pipefail
[[ -f "$TX_ROOT/ntm.stopped" ]] || exit 21
[[ "$(cat "$TX_ROOT/ntm.stopped")" == "$(cat "$TX_ROOT/ntm.state")" ]] || exit 22
target=$(cat "$TX_ROOT/target") || exit 2
head=$(git rev-parse HEAD) || exit 2
tree=$(git rev-parse 'HEAD^{tree}') || exit 2
actual=$(jq -r '.version' "node_modules/$target/package.json") || exit 2
printf '%s %s %s %s\n' "$head" "$tree" "$target" "$actual" >> "$TX_ROOT/tests.trace"
printf 'Actual installed %s %s at %s\n' "$target" "$actual" "$head"
printf 'Raw test stderr for %s\n' "$target" >&2
[[ "$actual" == 1.1.0 ]] || exit 23
if [[ "$TX_MODE" == test-timeout ]]; then
    sleep 20 & child=$!
    printf '%s\n' "$child" > "$TX_ROOT/timeout.child"
    wait "$child"
fi
case "$TX_MODE" in
    test-failure) exit 17 ;;
    second-test-failure|middle-test-failure) [[ "$target" != beta ]] || exit 17 ;;
    test-dirty) printf 'test changed candidate\n' >> base.txt ;;
    test-branch) git switch -qc tests-branch || exit 2 ;;
    test-swap)
        jq '.version="1.0.0"' node_modules/alpha/package.json > "$TX_ROOT/swapped-package" || exit 2
        cp "$TX_ROOT/swapped-package" node_modules/alpha/package.json || exit 2 ;;
esac
if [[ "${TX_NATIVE_NPM:-false}" == true ]]; then
    node -e 'if(require("alpha") !== "1.1.0")process.exit(24)' || exit 24
fi
printf '%s %s\n' "$head" "$tree" >> "$TX_ROOT/tested"
TEST
    chmod +x "$root/bin/ntm" "$root/bin/tmux" "$root/bin/npm" "$root/bin/codex" "$root/receiver.git/hooks/pre-receive" || return 1
    printf '%s\n' "$root"
}

tx_assert_scenario() {
    local mode="$1" publication="$2" root repo before after plan command result rc=0 count=0 expected='[]' evidence
    local failures_before=$TF_ASSERTIONS_FAILED names='["alpha"]' no_push=true timeout=45
    local TX_ROOT TX_MODE="$mode" TX_NATIVE_NPM=false NPM_CONFIG_CACHE PATH="$TX_ORIGINAL_PATH"
    root=$(tx_create_fixture "$mode") || return 1
    TX_ROOT="$root"; repo="$root/project"; PATH="$root/bin:$TX_ORIGINAL_PATH"; NPM_CONFIG_CACHE="$root/npm-cache"
    export TX_ROOT TX_MODE TX_NATIVE_NPM TX_REAL_NPM NPM_CONFIG_CACHE PATH
    export CI=true RU_CHECK_UPDATES=false AGENT_SWEEP_SECRET_SCAN=block
    printf 'Retained transaction fixture %s/%s: %s\n' "$mode" "$publication" "$root" >&2
    case "$mode" in
        two-success|second-test-failure) names='["alpha","beta"]' ;;
        middle-test-failure) names='["alpha","beta","gamma"]' ;;
    esac
    plan=$(tx_plan "$names") || return 1
    printf '%s\n' "$plan" > "$root/plan.json"
    before=$(git -C "$repo" rev-parse HEAD) || return 1
    case "$mode" in
        original-dirty) printf 'uncommitted original work\n' >> "$repo/base.txt" ;;
        already-owned) mkdir "$repo/.git/ru-dep-update.lock" || return 1 ;;
        index-mismatch)
            printf 'staged original content\n' > "$repo/base.txt"
            git -C "$repo" add base.txt || return 1
            git -C "$repo" show HEAD:base.txt > "$repo/base.txt" || return 1 ;;
    esac
    sha256sum "$repo/.git/index" > "$root/index.before"
    [[ "$publication" != push ]] || no_push=false
    case "$mode" in agent-timeout|test-timeout) timeout=4 ;; esac
    printf -v command 'bash %q' "$root/project-test.sh"
    result=$(run_dep_update_transactions "$repo" "$plan" "$command" "$timeout" codex "$no_push" 1) 2> "$root/transaction.stderr" || rc=$?
    printf '%s\n' "$result" > "$root/result.json"
    printf '%s\n' "$rc" > "$root/result.exit"
    tx_json_assert "$result" 'type=="object" and (.dependencies|type=="array") and (.deps_updated|type=="number")' "$mode/$publication returns one typed transaction"
    tx_json_assert "$result" '.deps_updated==([.dependencies[]|select(.status=="updated")]|length)' "$mode/$publication counts only promoted dependency receipts"
    after=$(git -C "$repo" rev-parse HEAD) || return 1
    assert_equals "$after" "$(jq -r '.after_head' <<< "$result")" "$mode/$publication reports the actually observed original HEAD"
    case "$mode" in
        success|lock-only|squash-history|push-rejected) count=1; expected='["alpha"]' ;;
        two-success) count=2; expected='["alpha","beta"]' ;;
        second-test-failure) count=1; expected='["alpha"]' ;;
        middle-test-failure) count=2; expected='["alpha","gamma"]' ;;
    esac
    assert_equals "$count" "$(jq -r '.deps_updated' <<< "$result")" "$mode/$publication has the independently expected successful count"
    assert_equals "$expected" "$(jq -c '[.dependencies[]|select(.status=="updated")|.name]' <<< "$result")" "$mode/$publication retains exactly the valid dependency requests"
    case "$mode" in success|two-success|lock-only|squash-history|already-current) assert_equals 0 "$rc" "$mode/$publication exits successfully" ;;
        *) assert_not_equals 0 "$rc" "$mode/$publication propagates the unsuccessful request" ;; esac
    if [[ "$count" -gt 0 ]]; then
        assert_equals "$count" "$(git -C "$repo" rev-list --count "$before..$after")" "$mode/$publication retains one host commit per accepted dependency"
        tx_json_assert "$result" 'all(.dependencies[]|select(.status=="updated"); .before_version=="1.0.0" and .actual_version=="1.1.0" and .commit==.verified_head and .tests.verified_head==.commit and .tests.ran==true and .tests.ok==true and .installed.actual_version=="1.1.0")' "$mode/$publication versions and tests bind to actual retained commits"
        while IFS= read -r dependency; do
            local name commit tree
            name=$(jq -r '.name' <<< "$dependency"); commit=$(jq -r '.commit' <<< "$dependency")
            tree=$(git -C "$repo" show -s --format=%T "$commit") || return 1
            assert_success "$mode/$publication exact accepted commit and tree were tested" awk -v head="$commit" -v tree="$tree" '$1==head && $2==tree {found=1} END {exit !found}' "$root/tested"
            assert_equals 1.1.0 "$(git -C "$repo" show "HEAD:package-lock.json" | jq -r --arg name "$name" '.packages["node_modules/"+$name].version')" "$mode/$publication actually retains the requested locked version"
        done < <(jq -c '.dependencies[]|select(.status=="updated")' <<< "$result")
    else
        assert_equals "$before" "$after" "$mode/$publication preserves the original commit on refusal"
    fi
    if [[ "$publication" == push && "$count" -gt 0 && "$mode" != push-rejected ]]; then
        assert_equals "$after" "$(git -C "$root/receiver.git" rev-parse refs/heads/main)" "$mode publishes the tested accepted HEAD to the real receiver"
        assert_equals success "$(jq -r '.publication.status' <<< "$result")" "$mode confirms publication separately"
    else
        assert_equals "$before" "$(git -C "$root/receiver.git" rev-parse refs/heads/main)" "$mode/$publication leaves the real receiver unchanged"
        [[ "$mode" == push-rejected ]] || assert_file_not_exists "$root/received-updates" "$mode/$publication invokes no receiver push"
    fi
    case "$mode" in
        second-test-failure|middle-test-failure)
            assert_equals 1.0.0 "$(git -C "$repo" show HEAD:package-lock.json | jq -r '.packages["node_modules/beta"].version')" "$mode never retains the failed middle dependency"
            assert_equals partial "$(jq -r '.status' <<< "$result")" "$mode explicitly reports partial success" ;;
        already-current)
            assert_equals skipped "$(jq -r '.dependencies[0].status' <<< "$result")" 'Already-current dependency has an explicit skipped receipt'
            assert_equals 0 "$(cat "$root/agent.count")" 'Already-current dependency starts no agent'
            assert_file_not_exists "$root/tests.trace" 'Already-current result claims no new test execution' ;;
        squash-history)
            assert_not_contains "$(git -C "$repo" log --format=%s "$before..$after")" 'Private invalid intermediate' 'Invalid intermediate history cannot be published'
            assert_equals 'owned baseline source' "$(git -C "$repo" show HEAD:base.txt)" 'Squashing retains only the verified final dependency tree' ;;
        install-stale) assert_file_not_exists "$root/tests.trace" 'Stale installed payload is refused before tests' ;;
        already-owned) assert_dir_exists "$repo/.git/ru-dep-update.lock" 'An existing ownership lock is preserved' ;;
        index-mismatch)
            assert_equals "$(cat "$root/index.before")" "$(sha256sum "$repo/.git/index")" 'Refused staged/worktree mismatch preserves exact user index bytes' ;;
        original-concurrent) assert_file_contains "$repo/base.txt" 'concurrent original user work' 'Concurrent original work is never reset' ;;
        agent-timeout|test-timeout)
            assert_equals timeout "$(jq -r '.status' <<< "$result")" "$mode records the expired total deadline"
            if [[ -f "$root/timeout.child" ]]; then
                local child child_state
                child=$(cat "$root/timeout.child")
                child_state=$(ps -o stat= -p "$child" 2>/dev/null || true)
                assert_true "[[ -z '$child_state' || '$child_state' == Z* ]]" "$mode stops its actual owned child process"
            fi ;;
    esac
    evidence=$(jq -er '.evidence_dir' <<< "$result") || return 1
    assert_file_exists "$evidence/requests.json" "$mode/$publication retains its requested inventory"
    assert_file_exists "$evidence/result.json" "$mode/$publication retains its final receipt"
    [[ "$TF_ASSERTIONS_FAILED" -eq "$failures_before" ]]
}

test_dep_transaction_success_and_partial() {
    local mode publication failures=0
    for publication in no-push push; do
        for mode in success two-success lock-only squash-history second-test-failure middle-test-failure already-current; do
            tx_assert_scenario "$mode" "$publication" || ((failures+=1))
        done
    done
    [[ "$failures" -eq 0 ]]
}

test_dep_transaction_refusals() {
    local mode failures=0
    for mode in no-op wrong-dependency wrong-version manifest-only unexpected changed-script install-failure install-stale test-failure test-dirty test-branch test-swap agent-branch agent-revert original-dirty original-concurrent original-branch original-remote already-owned index-mismatch manifest-mode stale-plan; do
        tx_assert_scenario "$mode" push || ((failures+=1))
    done
    [[ "$failures" -eq 0 ]]
}

test_dep_transaction_deadlines_and_rejected_publication() {
    local mode failures=0
    for mode in agent-timeout test-timeout push-rejected; do
        tx_assert_scenario "$mode" push || ((failures+=1))
    done
    [[ "$failures" -eq 0 ]]
}

test_dep_transaction_git_environment() {
    local root repo twin before plan command result rc=0 variable evidence repository
    local failures_before=$TF_ASSERTIONS_FAILED TX_ROOT TX_MODE=success PATH="$TX_ORIGINAL_PATH"
    root=$(tx_create_fixture success) || return 1
    TX_ROOT="$root"; repo="$root/project"; twin="$root/twin"; PATH="$root/bin:$TX_ORIGINAL_PATH"
    export TX_ROOT TX_MODE PATH TX_REAL_NPM
    git clone -q --no-hardlinks -- "$repo" "$twin" || return 1
    before=$(git -C "$repo" rev-parse HEAD) || return 1
    assert_equals "$before" "$(git -C "$twin" rev-parse HEAD)" 'Distinct Git ownership fixtures share exactly the same HEAD'
    for repository in project twin; do
        sha256sum "$root/$repository/.git/config" "$root/$repository/.git/index" "$root/$repository/.git/HEAD" > "$root/$repository.before" || return 1
        git -C "$root/$repository" for-each-ref --format='%(refname) %(objectname)' > "$root/$repository.refs" || return 1
    done
    plan=$(tx_plan '["alpha"]') || return 1
    printf -v command 'bash %q' "$root/project-test.sh"
    result=$(export GIT_DIR="$twin/.git"; run_dep_update_transactions "$repo" "$plan" "$command" 30 codex false 1) 2> "$root/environment.stderr" || rc=$?
    printf '%s\n' "$result" > "$root/environment.json"
    assert_not_equals 0 "$rc" 'Git routing override cannot report successful work'
    tx_json_assert "$result" '.deps_updated==0 and .dependencies[0].status=="unverified" and .dependencies[0].error_code=="unsafe_git_environment"' 'Git routing override has a typed unverified receipt'
    assert_equals 0 "$(cat "$root/agent.count")" 'Git routing override starts no provider'
    evidence=$(jq -er '.evidence_dir' <<< "$result") || return 1
    assert_dir_not_exists "$evidence/1" 'Git routing override is refused before cloning'
    tx_with_git_environment() (
        export "$1=$2"
        shift 2
        "$@"
    )
    for variable in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE; do
        assert_exit_code 1 "$variable is refused before inspecting Git" tx_with_git_environment "$variable" "$twin/.git" dep_update_git_environment_safe
        assert_exit_code 1 "$variable cannot redirect repository ownership" tx_with_git_environment "$variable" "$twin/.git" dep_update_repo_matches "$repo" "$before" refs/heads/main
        assert_exit_code 1 "$variable cannot redirect clone configuration" tx_with_git_environment "$variable" "$twin/.git" dep_update_clone_attempt "$repo" "$before" refs/heads/main "$root/attempt-$variable"
        assert_dir_not_exists "$root/attempt-$variable" "$variable fails before a clone is created"
    done
    for repository in project twin; do
        assert_equals "$(cat "$root/$repository.before")" "$(sha256sum "$root/$repository/.git/config" "$root/$repository/.git/index" "$root/$repository/.git/HEAD")" "$repository config, index and symbolic HEAD remain byte-identical"
        assert_equals "$(cat "$root/$repository.refs")" "$(git -C "$root/$repository" for-each-ref --format='%(refname) %(objectname)')" "$repository refs are unchanged"
    done
    assert_file_not_exists "$root/received-updates" 'Refused Git environments never invoke publication'
    assert_equals "$before" "$(git -C "$root/receiver.git" rev-parse refs/heads/main)" 'Git routing refusal preserves the actual receiver'
    [[ "$TF_ASSERTIONS_FAILED" -eq "$failures_before" ]]
}

tx_native_npm_case() (
    local mode="$1" root repo version package server_pid before after plan command result rc=0 attempt registry_port
    local failures_before=$TF_ASSERTIONS_FAILED
    root=$(tx_create_fixture "$mode" '["alpha"]') || return 1
    repo="$root/project"
    export TX_ROOT="$root" TX_MODE="$mode" TX_NATIVE_NPM=true TX_REAL_NPM
    export PATH="$root/bin:$TX_ORIGINAL_PATH" CI=true RU_CHECK_UPDATES=false AGENT_SWEEP_SECRET_SCAN=block
    export NPM_CONFIG_CACHE="$root/install-cache"
    printf 'Retained native npm fixture %s: %s\n' "$mode" "$root" >&2
    mkdir "$root/registry" || return 1
    for version in 1.0.0 1.1.0; do
        package="$root/package-$version"
        mkdir "$package" || return 1
        jq -cn --arg version "$version" '{name:"alpha",version:$version,main:"index.js"}' > "$package/package.json" || return 1
        printf 'module.exports = "%s";\n' "$version" > "$package/index.js"
        (cd "$package" && "$TX_REAL_NPM" pack --json --pack-destination "$root/registry" --ignore-scripts --cache="$root/pack-cache") > "$root/pack-$version.json" 2> "$root/pack-$version.stderr" || return 1
    done
    cat > "$root/registry.py" <<'REGISTRY'
import http.server
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
packs = {v: json.loads((root / ("pack-" + v + ".json")).read_text())[0] for v in ("1.0.0", "1.1.0")}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def do_GET(self):
        with (root / "registry.requests").open("a") as log:
            log.write(self.path + "\n")
        if self.path.rstrip("/") == "/alpha":
            base = "http://127.0.0.1:" + str(self.server.server_port)
            versions = {}
            for version, pack in packs.items():
                versions[version] = {"name": "alpha", "version": version, "dist": {
                    "tarball": base + "/alpha/-/" + pack["filename"],
                    "integrity": pack["integrity"], "shasum": pack["shasum"]}}
            payload = json.dumps({"name": "alpha", "dist-tags": {"latest": "1.1.0"}, "versions": versions}).encode()
            mime = "application/json"
        elif self.path.startswith("/alpha/-/") and self.path.rsplit("/", 1)[-1] in {p["filename"] for p in packs.values()}:
            payload = (root / "registry" / self.path.rsplit("/", 1)[-1]).read_bytes()
            mime = "application/octet-stream"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "registry.port").write_text(str(server.server_port))
server.serve_forever()
REGISTRY
    python3 "$root/registry.py" "$root" > "$root/registry.stdout" 2> "$root/registry.stderr" &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT
    for _ in {1..100}; do
        [[ ! -s "$root/registry.port" ]] || break
        kill -0 "$server_pid" 2>/dev/null || { cat "$root/registry.stderr" >&2; return 1; }
        sleep 0.05
    done
    registry_port=$(cat "$root/registry.port") || return 1
    export TX_REGISTRY="http://127.0.0.1:$registry_port" NPM_CONFIG_REGISTRY="http://127.0.0.1:$registry_port"
    # Replace the synthetic initial lock with one resolved by native npm.
    # Retain the original fixture file rather than discarding evidence.
    mv "$repo/package-lock.json" "$root/synthetic-initial-lock.json" || return 1
    (cd "$repo" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund --cache="$root/baseline-cache") > "$root/baseline.stdout" 2> "$root/baseline.stderr" || return 1
    git -C "$repo" add package-lock.json || return 1
    git -C "$repo" commit -qm 'Native npm baseline lock' || return 1
    git -C "$root/receiver.git" fetch -q "$repo" refs/heads/main:refs/heads/main || return 1
    before=$(git -C "$repo" rev-parse HEAD) || return 1
    plan=$(tx_plan '["alpha"]') || return 1
    printf '%s\n' "$plan" > "$root/plan.json"
    printf -v command 'bash %q' "$root/project-test.sh"
    result=$(run_dep_update_transactions "$repo" "$plan" "$command" 60 codex false 1) 2> "$root/transaction.stderr" || rc=$?
    printf '%s\n' "$result" > "$root/result.json"
    printf '%s\n' "$rc" > "$root/result.exit"
    after=$(git -C "$repo" rev-parse HEAD) || return 1
    tx_json_assert "$result" '.deps_outdated_before==1 and (.dependencies|length)==1' "$mode accounts for the native requested dependency"
    attempt="$(jq -er '.evidence_dir' <<< "$result")/1/repository"
    if [[ "$mode" == native-success ]]; then
        assert_equals 0 "$rc" 'Native npm resolution, install, host test and real publication succeed'
        tx_json_assert "$result" '.deps_updated==1 and .dependencies[0].before_version=="1.0.0" and .dependencies[0].actual_version=="1.1.0" and .dependencies[0].installed.actual_version=="1.1.0" and .publication.status=="success"' 'Native npm receipt records actual resolved and installed versions'
        assert_equals "$after" "$(git -C "$root/receiver.git" rev-parse refs/heads/main)" 'Native npm publishes the tested commit to the actual local receiver'
        assert_file_contains "$root/registry.requests" '/alpha/-/alpha-1.1.0.tgz' 'Native host installation really downloads the new packed payload'
        assert_file_contains "$root/tested" "$after" 'Native npm loaded-package test binds the actual accepted commit'
        assert_equals 1.1.0 "$(jq -r '.version' "$attempt/node_modules/alpha/package.json")" 'Native installed package bytes contain the requested version'
    else
        assert_not_equals 0 "$rc" 'Native forged-lock installation cannot report success'
        tx_json_assert "$result" '.deps_updated==0 and .dependencies[0].status=="unverified" and .dependencies[0].error_code=="installed_version_unverified"' 'Forged native package receives an explicit installed-version refusal'
        assert_equals "$before" "$after" 'Native forged-lock failure preserves the original branch'
        assert_equals "$before" "$(git -C "$root/receiver.git" rev-parse refs/heads/main)" 'Native forged-lock failure preserves the actual receiver'
        assert_file_not_exists "$root/tests.trace" 'Forged installed payload is rejected before any project test claim'
        assert_equals 1.0.0 "$(jq -r '.version' "$attempt/node_modules/alpha/package.json")" 'Native npm really materialized the stale tarball identified by its forged lock'
        assert_file_contains "$root/registry.requests" '/alpha/-/alpha-1.0.0.tgz' 'Forged-lock regression uses an actual tarball download'
    fi
    [[ "$TF_ASSERTIONS_FAILED" -eq "$failures_before" ]]
)

test_dep_transaction_native_npm() {
    local failures=0 mode
    for mode in native-success native-forged; do
        tx_native_npm_case "$mode" || ((failures+=1))
    done
    [[ "$failures" -eq 0 ]]
}

if [[ -z "$TX_REAL_NPM" ]] || ! command -v node >/dev/null 2>&1; then
    printf 'npm and node are required for dependency transaction tests\n' >&2
    exit 1
fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -gt 0 ]]; then
        for tx_test in "$@"; do run_test "$tx_test"; done
    else
        run_test test_dep_transaction_success_and_partial
        run_test test_dep_transaction_refusals
        run_test test_dep_transaction_deadlines_and_rejected_publication
        run_test test_dep_transaction_git_environment
        run_test test_dep_transaction_native_npm
    fi
    print_results
fi
