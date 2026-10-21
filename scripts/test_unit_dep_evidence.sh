#!/usr/bin/env bash
# Native dependency evidence, with deterministic adapters for unavailable tools.
# Fixtures are retained for inspection. No external registry is contacted.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_DIR/ru"

evidence_json_assert() {
    local value="$1" predicate="$2" message="$3"
    if printf '%s\n' "$value" | jq -e "$predicate" >/dev/null; then
        _tf_pass "$message"
    else
        _tf_fail "$message" "$value"
    fi
}

evidence_git_init() {
    git -C "$1" init -q -b main &&
        git -C "$1" config user.name 'RU evidence fixture' &&
        git -C "$1" config user.email 'evidence@example.invalid' &&
        git -C "$1" add . && git -C "$1" commit -qm fixture
}

evidence_npm_files() {
    local repo="$1" alpha="$2" beta="${3:-1.0.0}"
    printf '%s\n' '{"name":"fixture","version":"1.0.0","scripts":{"test":"node test.js"},"dependencies":{"alpha":"^1.0.0","beta":"^1.0.0"}}' > "$repo/package.json"
    jq -cn --arg alpha "$alpha" --arg beta "$beta" '{name:"fixture",version:"1.0.0",lockfileVersion:3,requires:true,packages:{
        "":{name:"fixture",version:"1.0.0",dependencies:{alpha:"^1.0.0",beta:"^1.0.0"}},
        "node_modules/alpha":{version:$alpha,resolved:("https://registry.invalid/alpha/-/alpha-"+$alpha+".tgz")},
        "node_modules/beta":{version:$beta,resolved:("https://registry.invalid/beta/-/beta-"+$beta+".tgz")}}}' > "$repo/package-lock.json"
}

test_dep_evidence_npm() {
    local root repo request before after result rc
    root=$(mktemp -d /tmp/ru-dep-evidence-npm.XXXXXX) || return 1
    repo="$root/project"
    mkdir "$repo" || return 1
    printf 'Retained native npm evidence fixture: %s\n' "$root" >&2
    evidence_npm_files "$repo" 1.0.0
    evidence_git_init "$repo" || return 1
    request='{"manager":"npm","name":"alpha","current":"1.0.0","latest":"1.1.0"}'
    rc=0; before=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Native npm reads a consistent tracked baseline'
    evidence_json_assert "$before" '.actual_version == "1.0.0" and .file_hashes["package-lock.json"] != null' 'Baseline contains actual locked version and file hashes'
    evidence_npm_files "$repo" 1.1.0
    rc=0; after=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Native npm reads the updated lock resolution'
    rc=0; result=$(dep_update_verify "$before" "$after" "$request") || rc=$?
    assert_equals 0 "$rc" 'A compatible lock-only update is accepted'
    evidence_json_assert "$result" '.status == "success" and .before_version == "1.0.0" and .actual_version == "1.1.0" and .manifest_changed == false and .lockfile_changed == true' 'Receipt separates actual versions and changed file classes'
    rc=0; result=$(dep_update_verify "$after" "$after" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Already-current is not an update success'
    evidence_json_assert "$result" '.status == "skipped" and .error_code == "already_current"' 'Already-current outcome is explicit'
    evidence_npm_files "$repo" 1.1.0 1.1.0
    result=$(dep_update_snapshot "$repo" "$request") || return 1
    rc=0; result=$(dep_update_verify "$before" "$result" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Another direct dependency cannot accompany the target update'
    evidence_json_assert "$result" '.error_code == "unexpected_dependency_change"' 'Wrong-dependency update carries the specific refusal'
    evidence_npm_files "$repo" 1.2.0
    result=$(dep_update_snapshot "$repo" "$request") || return 1
    rc=0; result=$(dep_update_verify "$before" "$result" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Wrong target version is not accepted'
    evidence_json_assert "$result" '.error_code == "requested_version_not_reached"' 'Requested version must actually be reached'
    evidence_npm_files "$repo" 1.1.0
    jq '.scripts.test="true"' "$repo/package.json" > "$root/changed.json"
    cp "$root/changed.json" "$repo/package.json"
    result=$(dep_update_snapshot "$repo" "$request") || return 1
    rc=0; result=$(dep_update_verify "$before" "$result" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Changing the test command cannot validate an update'
    evidence_json_assert "$result" '.error_code == "unexpected_dependency_change"' 'Manifest settings are held fixed'
    evidence_npm_files "$repo" 1.1.0
    mkdir -p "$repo/node_modules/alpha" "$repo/node_modules/beta"
    printf '%s\n' '{"name":"alpha","version":"1.0.0"}' > "$repo/node_modules/alpha/package.json"
    printf '%s\n' '{"name":"beta","version":"1.0.0"}' > "$repo/node_modules/beta/package.json"
    rc=0; result=$(dep_update_verify_installed "$repo" "$request" "$after") || rc=$?
    assert_not_equals 0 "$rc" 'A stale installed package cannot pass locked-version validation'
    evidence_json_assert "$result" '.error_code == "installed_version_mismatch"' 'Physical installed package mismatch is explicit'
    printf '%s\n' '{"name":"alpha","version":"1.1.0"}' > "$repo/node_modules/alpha/package.json"
    rc=0; result=$(dep_update_verify_installed "$repo" "$request" "$after") || rc=$?
    assert_equals 0 "$rc" 'Matching physical package and native installed tree are accepted'
    evidence_json_assert "$result" '.installed == true and .actual_version == "1.1.0"' 'Installed evidence records the materialized version'
    rc=0; result=$(dep_update_verify '{}' "$after" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Missing snapshot facts cannot be promoted to success'
    evidence_json_assert "$result" '.status == "unverified"' 'Malformed evidence stays unverified'
    rc=0; result=$(dep_update_snapshot "$repo" '{"manager":"yarn","name":"alpha","latest":"1.1.0"}') || rc=$?
    assert_not_equals 0 "$rc" 'Unsupported manager is not silently successful'
    evidence_json_assert "$result" '.error_code == "unsupported_update"' 'Unsupported manager has a typed result'
    assert_exit_code 1 'Literal path validation rejects traversal' _dep_update_evidence_file "$repo" '../project/package.json'
    ln -s "$repo/package.json" "$repo/manifest-link.json" || return 1
    assert_exit_code 1 'Manifest symlink is refused' _dep_update_evidence_file "$repo" manifest-link.json false
    printf '%s\n' "$before" > "$root/before.json"
    printf '%s\n' "$after" > "$root/after.json"
}

test_dep_evidence_reader_mutation() {
    local root repo request result rc
    root=$(mktemp -d /tmp/ru-dep-evidence-mutation.XXXXXX) || return 1
    repo="$root/project"; mkdir "$repo" || return 1
    evidence_npm_files "$repo" 1.0.0
    evidence_git_init "$repo" || return 1
    request='{"manager":"npm","name":"alpha","latest":"1.1.0"}'
    npm() { printf '\n' >> package.json; command npm "$@"; }
    rc=0; result=$(dep_update_snapshot "$repo" "$request") || rc=$?
    unset -f npm
    assert_not_equals 0 "$rc" 'A native reader cannot mutate files during snapshot inspection'
    evidence_json_assert "$result" '.status == "unverified" and .error_code == "validation_mutated_files"' 'Reader mutation is detected by pre/post hashes'
    printf 'Retained reader-mutation fixture: %s\n' "$root" >&2
}

test_dep_evidence_native_cargo() {
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
        skip_test 'cargo and rustc are required for optional native Cargo verification'
        return 0
    fi
    local root repo request before after result rc version
    root=$(mktemp -d /tmp/ru-dep-evidence-cargo.XXXXXX) || return 1
    repo="$root/project"
    mkdir -p "$repo/src" "$repo/secondary/src" "$repo/.cargo" "$repo/vendor/alpha-1.0.0/src"
    printf 'Retained offline native Cargo fixture: %s\n' "$root" >&2
    printf '%s\n' '[package]' 'name = "fixture"' 'version = "0.1.0"' 'edition = "2021"' \
        '[dependencies]' 'alpha = "^1.0"' '[workspace]' 'members = ["secondary"]' 'default-members = ["."]' > "$repo/Cargo.toml"
    printf '%s\n' '#[test] fn target_is_updated() { assert_eq!(alpha::version(), "1.1.0"); }' > "$repo/src/lib.rs"
    printf '%s\n' '[package]' 'name = "secondary"' 'version = "0.1.0"' 'edition = "2021"' > "$repo/secondary/Cargo.toml"
    printf '%s\n' '#[test] fn non_default_member_runs() { assert_eq!(2 + 2, 4); }' > "$repo/secondary/src/lib.rs"
    printf '%s\n' '[source.crates-io]' 'replace-with = "vendored-sources"' '[source.vendored-sources]' 'directory = "vendor"' > "$repo/.cargo/config.toml"
    printf '%s\n' '/target/' > "$repo/.gitignore"
    version=1.0.0
    printf '%s\n' '[package]' 'name = "alpha"' "version = \"$version\"" 'edition = "2021"' > "$repo/vendor/alpha-$version/Cargo.toml"
    printf 'pub fn version() -> &\x27static str { "%s" }\n' "$version" > "$repo/vendor/alpha-$version/src/lib.rs"
    printf '%s\n' '{"files":{},"package":null}' > "$repo/vendor/alpha-$version/.cargo-checksum.json"
    (cd "$repo" && cargo generate-lockfile --offline) > "$root/initial.stdout" 2> "$root/initial.stderr" || return 1
    version=1.1.0
    mkdir -p "$repo/vendor/alpha-$version/src"
    printf '%s\n' '[package]' 'name = "alpha"' "version = \"$version\"" 'edition = "2021"' > "$repo/vendor/alpha-$version/Cargo.toml"
    printf 'pub fn version() -> &\x27static str { "%s" }\n' "$version" > "$repo/vendor/alpha-$version/src/lib.rs"
    printf '%s\n' '{"files":{},"package":null}' > "$repo/vendor/alpha-$version/.cargo-checksum.json"
    evidence_git_init "$repo" || return 1
    request='{"manager":"cargo","name":"alpha","crate_name":"fixture","kind":"Normal","platform":null,"current":"1.0.0","latest":"1.1.0"}'
    rc=0; before=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Native Cargo reads the old locked registry edge'
    evidence_json_assert "$before" '.actual_version == "1.0.0" and .files == ["Cargo.lock"]' 'Cargo baseline is old and only permits a lockfile change'
    rc=0; (cd "$repo" && cargo update -p alpha --precise 1.1.0 --offline) > "$root/update.stdout" 2> "$root/update.stderr" || rc=$?
    assert_equals 0 "$rc" 'Real Cargo updates the vendored dependency'
    rc=0; after=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Native Cargo reads the new locked registry edge'
    rc=0; result=$(dep_update_verify "$before" "$after" "$request") || rc=$?
    assert_equals 0 "$rc" 'Cargo manifest hashes and unchanged unrelated edges validate'
    evidence_json_assert "$result" '.actual_version == "1.1.0" and .lockfile_changed == true and .manifest_changed == false' 'Cargo receipt records the actual lock-only version change'
    rc=0; (cd "$repo" && cargo fetch --locked --offline) > "$root/fetch.stdout" 2> "$root/fetch.stderr" || rc=$?
    assert_equals 0 "$rc" 'Real Cargo fetch materializes the locked graph'
    rc=0; result=$(dep_update_verify_installed "$repo" "$request" "$after") || rc=$?
    assert_equals 0 "$rc" 'Native installed Cargo graph matches its snapshot'
    rc=0; (cd "$repo" && cargo test --workspace --locked --offline) > "$root/tests.stdout" 2> "$root/tests.stderr" || rc=$?
    assert_equals 0 "$rc" 'Compiled tests pass in root and non-default workspace member'
    assert_equals Cargo.lock "$(git -C "$repo" diff --name-only)" 'Only Cargo.lock changed through native update, installation and tests'
    printf '%s\n' "$before" > "$root/before.json"
    printf '%s\n' "$after" > "$root/after.json"
}

test_dep_evidence_controlled_composer_go() {
    local root repo request before after result rc sum version
    local EVIDENCE_COMPOSER_FAIL=false EVIDENCE_GO_MANIFEST EVIDENCE_GO_GRAPH
    root=$(mktemp -d /tmp/ru-dep-evidence-controls.XXXXXX) || return 1
    printf 'Retained controlled Composer/Go adapter fixtures: %s\n' "$root" >&2
    repo="$root/composer"; mkdir "$repo" || return 1
    composer() { [[ "$EVIDENCE_COMPOSER_FAIL" == false && "$*" == *validate* ]]; }
    printf '%s\n' '{"name":"fixture/project","require":{"acme/lib":"^1.0"},"scripts":{"test":"php test.php"}}' > "$repo/composer.json"
    printf '%s\n' '{"content-hash":"old","packages":[{"name":"acme/lib","version":"1.0.0","type":"library"}],"packages-dev":[]}' > "$repo/composer.lock"
    evidence_git_init "$repo" || return 1
    request='{"manager":"composer","name":"acme/lib","current":"1.0.0","latest":"1.1.0"}'
    rc=0; before=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Controlled Composer validator permits a consistent baseline'
    printf '%s\n' '{"content-hash":"new","packages":[{"name":"acme/lib","version":"1.1.0","type":"library"}],"packages-dev":[]}' > "$repo/composer.lock"
    rc=0; after=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Controlled Composer snapshot reads the changed locked version'
    rc=0; result=$(dep_update_verify "$before" "$after" "$request") || rc=$?
    assert_equals 0 "$rc" 'Composer evidence accepts the requested direct package update'
    mkdir -p "$repo/vendor/composer" "$repo/vendor/acme/lib"
    printf '%s\n' '{"packages":[{"name":"acme/lib","version":"1.1.0"}]}' > "$repo/vendor/composer/installed.json"
    printf '%s\n' '{"name":"acme/lib"}' > "$repo/vendor/acme/lib/composer.json"
    rc=0; result=$(dep_update_verify_installed "$repo" "$request" "$after") || rc=$?
    assert_equals 0 "$rc" 'Composer installed metadata and physical manifest identify the target'
    printf '%s\n' '{"name":"wrong/package"}' > "$repo/vendor/acme/lib/composer.json"
    rc=0; result=$(dep_update_verify_installed "$repo" "$request" "$after") || rc=$?
    assert_not_equals 0 "$rc" 'Wrong physical Composer package cannot masquerade as the locked target'
    EVIDENCE_COMPOSER_FAIL=true
    rc=0; result=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Composer native validator refusal is not ignored'
    evidence_json_assert "$result" '.error_code == "manager_validation_failed"' 'Composer command failure remains typed unverified'
    unset -f composer

    repo="$root/go"; mkdir "$repo" || return 1
    EVIDENCE_GO_MANIFEST="$root/go-manifest.json"
    EVIDENCE_GO_GRAPH="$root/go-graph.json"
    go() {
        case "$1:${2:-}" in
            env:GOWORK) printf '%s\n' "${GOWORK:-}" ;;
            mod:edit) cat "$EVIDENCE_GO_MANIFEST" ;;
            list:-mod=readonly) cat "$EVIDENCE_GO_GRAPH" ;;
            *) return 1 ;;
        esac
    }
    sum=$(printf '%043d' 0 | tr 0 A)
    version=v1.0.0
    printf 'module example.test/root\n\ngo 1.20\n\nrequire example.test/lib %s\n' "$version" > "$repo/go.mod"
    printf 'example.test/lib %s h1:%s=\nexample.test/lib %s/go.mod h1:%s=\n' "$version" "$sum" "$version" "$sum" > "$repo/go.sum"
    jq -cn --arg version "$version" '{Module:{Path:"example.test/root"},Go:"1.20",Require:[{Path:"example.test/lib",Version:$version,Indirect:false}]}' > "$EVIDENCE_GO_MANIFEST"
    jq -cn --arg version "$version" '{Path:"example.test/root",Main:true},{Path:"example.test/lib",Version:$version}' > "$EVIDENCE_GO_GRAPH"
    evidence_git_init "$repo" || return 1
    request='{"manager":"go","name":"example.test/lib","current":"v1.0.0","latest":"v1.1.0"}'
    rc=0; before=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Controlled Go graph and checksums establish the old direct version'
    version=v1.1.0
    printf 'module example.test/root\n\ngo 1.20\n\nrequire example.test/lib %s\n' "$version" > "$repo/go.mod"
    printf 'example.test/lib %s h1:%s=\nexample.test/lib %s/go.mod h1:%s=\n' "$version" "$sum" "$version" "$sum" > "$repo/go.sum"
    jq -cn --arg version "$version" '{Module:{Path:"example.test/root"},Go:"1.20",Require:[{Path:"example.test/lib",Version:$version,Indirect:false}]}' > "$EVIDENCE_GO_MANIFEST"
    jq -cn --arg version "$version" '{Path:"example.test/root",Main:true},{Path:"example.test/lib",Version:$version}' > "$EVIDENCE_GO_GRAPH"
    rc=0; after=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_equals 0 "$rc" 'Controlled Go graph and checksums establish the new direct version'
    rc=0; result=$(dep_update_verify "$before" "$after" "$request") || rc=$?
    assert_equals 0 "$rc" 'Go evidence verifies actual manifest and lock changes'
    evidence_json_assert "$result" '.actual_version == "v1.1.0" and .manifest_changed == true and .lockfile_changed == true' 'Go receipt records actual updated version and both file changes'
    printf 'example.test/lib %s h1:%s=\n' "$version" "$sum" > "$repo/go.sum"
    rc=0; result=$(dep_update_snapshot "$repo" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'Missing target go.mod checksum is not accepted'
    printf 'example.test/lib %s h1:%s=\nexample.test/lib %s/go.mod h1:%s=\n' "$version" "$sum" "$version" "$sum" > "$repo/go.sum"
    printf 'go 1.20\nuse .\n' > "$repo/go.work"
    rc=0; result=$(GOWORK=off dep_update_snapshot "$repo" "$request") || rc=$?
    assert_not_equals 0 "$rc" 'GOWORK=off cannot hide a physical Go workspace'
    evidence_json_assert "$result" '.status == "unverified" and .error_code == "unsupported_update"' 'Unsupported Go workspace remains an explicit refusal'
    unset -f go
}

main() {
    log_suite_start 'Dependency update evidence'
    run_test test_dep_evidence_npm
    run_test test_dep_evidence_reader_mutation
    run_test test_dep_evidence_native_cargo
    run_test test_dep_evidence_controlled_composer_go
    print_results
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
