#!/usr/bin/env bash
#
# E2E Test: ru robot-docs command
# Tests machine-readable CLI documentation output
#
# Test coverage:
#   - ru robot-docs outputs valid JSON for all topics
#   - ru robot-docs all includes all topic sections
#   - ru robot-docs with invalid topic exits 4
#   - ru robot-docs includes version and schema_version metadata
#   - ru robot-docs commands lists all known commands
#   - ru robot-docs exit-codes covers all exit codes
#   - ru robot-docs works without --json flag (always JSON)
#   - ru robot-docs schemas includes command schemas
#   - ru --schema shortcut works
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

# Actual output conformance requires python3 + jsonschema (Draft 2020-12)
# and rfc3339_validator so date-time assertions are active.
# This is a test dependency, not a ru runtime dependency; CI must install it.
# Missing jsonschema fails the named conformance proof rather than skipping it.
STRUCTURED_TOON_SH="${TOON_SH_PATH:-${HOME}/.local/lib/toon.sh}"

assert_cli_schema() {
    local label="$1" expected_code="$2" command_name="$3"
    shift 3
    local actual_code=0
    "$E2E_RU_SCRIPT" "$@" > "$E2E_LOG_DIR/$label.stdout" 2> "$E2E_LOG_DIR/$label.stderr" || actual_code=$?
    assert_equals "$expected_code" "$actual_code" "$label preserves the actual exit code"
    if python3 - "$E2E_LOG_DIR/schema.stdout" "$E2E_LOG_DIR/$label.stdout" "$command_name" "$actual_code" <<'PY'
import json, sys
from jsonschema import Draft202012Validator, FormatChecker
assert "date-time" in FormatChecker.checkers, "rfc3339_validator is required for date-time validation"
with open(sys.argv[1]) as stream:
    schema = json.load(stream)["data"]["content"]
with open(sys.argv[2]) as stream:
    result = json.load(stream)
Draft202012Validator.check_schema(schema)
Draft202012Validator(schema, format_checker=FormatChecker()).validate(result)
assert result["command"] == sys.argv[3], result
assert result["_meta"]["exit_code"] == int(sys.argv[4]), result
assert result["output_format"] == "json", result
print("validated", sys.argv[2], "exit", sys.argv[4])
PY
    then
        pass "$label validates against the actual advertised command schema"
    else
        fail "$label does not validate against the actual advertised command schema"
        cat "$E2E_LOG_DIR/$label.stderr" >&2
    fi
}

setup_structured_conformance() {
    e2e_setup
    export RU_STATE_DIR="$XDG_STATE_HOME/ru" RU_CACHE_DIR="$XDG_CACHE_HOME/ru"
    export RU_CHECK_UPDATES=false RU_LAYOUT=flat
    e2e_create_mock_ntm
    e2e_create_mock_gh 0 '{}'
    # A controlled provider executable satisfies dry-run prerequisites only.
    # Any attempted real agent launch in this suite is an error.
    cat > "$E2E_MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    --version) printf 'controlled-provider-version\n' ;;
    --help) printf 'controlled-provider --output-format stream-json\n' ;;
    *) printf 'Unexpected provider invocation\n' >&2; exit 90 ;;
esac
MOCK
    chmod +x "$E2E_MOCK_BIN/claude"
    "$E2E_RU_SCRIPT" robot-docs schemas > "$E2E_LOG_DIR/schema.stdout" 2> "$E2E_LOG_DIR/schema.stderr"
}

create_structured_local_repo() {
    local repo="$RU_PROJECTS_DIR/$1"
    mkdir -p "$repo"
    git -C "$repo" init -b main > "$E2E_LOG_DIR/git-init.stdout" 2> "$E2E_LOG_DIR/git-init.stderr" || return 1
    printf 'original bytes\n' > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt || return 1
    git -C "$repo" commit -m 'structured output control' > "$E2E_LOG_DIR/git-commit.stdout" 2> "$E2E_LOG_DIR/git-commit.stderr" || return 1
}

cleanup_structured_conformance() {
    if [[ -n "${STRUCTURED_ARTIFACT_DIR:-}" ]]; then
        mkdir -p "$STRUCTURED_ARTIFACT_DIR"
        cp -a "$E2E_TEMP_DIR" "$STRUCTURED_ARTIFACT_DIR/"
    fi
    unset RU_STATE_DIR RU_CACHE_DIR RU_CHECK_UPDATES RU_LAYOUT
    e2e_cleanup
}

#==============================================================================
# Tests
#==============================================================================

test_valid_json_all_topics() {
    e2e_setup

    local topics=("quickstart" "commands" "examples" "exit-codes" "formats" "schemas" "all")
    for topic in "${topics[@]}"; do
        local output
        output=$("$E2E_RU_SCRIPT" robot-docs "$topic" 2>/dev/null)
        if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
            pass "robot-docs $topic produces valid JSON"
        else
            fail "robot-docs $topic does NOT produce valid JSON"
        fi
    done

    e2e_cleanup
}

test_envelope_structure() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null)

    for key in generated_at version output_format command data; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
            pass "Envelope has key: $key"
        else
            fail "Envelope missing key: $key"
        fi
    done

    local cmd
    cmd=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['command'])" 2>/dev/null)
    assert_equals "robot-docs" "$cmd" "Envelope command = robot-docs"

    local fmt
    fmt=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_format'])" 2>/dev/null)
    assert_equals "json" "$fmt" "Envelope output_format = json"

    e2e_cleanup
}

test_schema_version() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null)
    local sv
    sv=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['schema_version'])" 2>/dev/null)
    assert_equals "1.0.0" "$sv" "schema_version = 1.0.0"

    e2e_cleanup
}

test_all_topic_includes_sections() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs all 2>/dev/null)

    for section in quickstart commands examples exit_codes formats schemas; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; assert '$section' in d" 2>/dev/null; then
            pass "'all' topic includes section: $section"
        else
            fail "'all' topic missing section: $section"
        fi
    done

    e2e_cleanup
}

test_commands_topic_coverage() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs commands 2>/dev/null)

    local expected_commands=("sync" "status" "init" "add" "remove" "list" "doctor" "self-update" "config" "prune" "import" "review" "robot-docs")
    for cmd in "${expected_commands[@]}"; do
        if echo "$output" | python3 -c "
import sys,json
cmds = json.load(sys.stdin)['data']['content']['commands']
names = [c['name'] for c in cmds]
assert '$cmd' in names
" 2>/dev/null; then
            pass "Commands topic includes: $cmd"
        else
            fail "Commands topic missing: $cmd"
        fi
    done

    e2e_cleanup
}

test_exit_codes_coverage() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs exit-codes 2>/dev/null)

    for code in 0 1 2 3 4 5; do
        if echo "$output" | python3 -c "
import sys,json
codes = json.load(sys.stdin)['data']['content']['exit_codes']
found = [c for c in codes if c['code'] == $code]
assert len(found) == 1
" 2>/dev/null; then
            pass "Exit codes includes code $code"
        else
            fail "Exit codes missing code $code"
        fi
    done

    e2e_cleanup
}

test_invalid_topic() {
    e2e_setup

    assert_exit_code 4 "Invalid topic exits with code 4" \
        "$E2E_RU_SCRIPT" robot-docs nonexistent_topic

    e2e_cleanup
}

test_default_topic_is_all() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs 2>/dev/null)
    local topic
    topic=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['topic'])" 2>/dev/null)
    assert_equals "all" "$topic" "Default topic = all"

    e2e_cleanup
}

test_schemas_has_command_schemas() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs schemas 2>/dev/null)

    for cmd in status list sync doctor config prune review agent-sweep ai-sync dep-update robot-docs error; do
        if echo "$output" | python3 -c "
import sys,json
cmds = json.load(sys.stdin)['data']['content']['commands']
assert '$cmd' in cmds
assert 'data_schema' in cmds['$cmd']
" 2>/dev/null; then
            pass "Schemas includes $cmd with data_schema"
        else
            fail "Schemas missing $cmd or data_schema"
        fi
    done

    if echo "$output" | python3 -c "
import sys,json
d = json.load(sys.stdin)['data']['content']
assert 'envelope' in d
assert '\$schema' in d['envelope']
" 2>/dev/null; then
        pass "Schemas has envelope with \$schema"
    else
        fail "Schemas missing envelope or \$schema"
    fi

    e2e_cleanup
}

test_schema_shortcut() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" --schema 2>/dev/null)
    if echo "$output" | python3 -c "
import sys,json
d = json.load(sys.stdin)
assert d['data']['topic'] == 'schemas'
assert 'commands' in d['data']['content']
" 2>/dev/null; then
        pass "--schema shortcut returns schemas topic"
    else
        fail "--schema shortcut does not return schemas topic"
    fi

    e2e_cleanup
}

test_version_matches() {
    e2e_setup

    local ru_version
    ru_version=$("$E2E_RU_SCRIPT" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    local doc_version
    doc_version=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)

    assert_equals "$ru_version" "$doc_version" "Envelope version matches ru --version"

    e2e_cleanup
}

test_actual_empty_and_failure_schemas() {
    setup_structured_conformance
    assert_success "The schema proof has its declared validator dependency" python3 -c 'import jsonschema, rfc3339_validator; assert "date-time" in jsonschema.FormatChecker.checkers'
    assert_cli_schema empty-list 0 list list --json
    assert_cli_schema empty-status 0 status status --no-fetch --json
    assert_cli_schema empty-sync 0 sync sync --dry-run --json
    assert_cli_schema empty-prune 0 prune prune --json
    assert_cli_schema empty-ai-sync 0 ai-sync ai-sync --dry-run --json
    assert_cli_schema empty-dep-update 0 dep-update dep-update --dry-run --json
    assert_cli_schema empty-analytics 0 review review --analytics --json
    assert_cli_schema empty-review-status 0 review review --status --format json
    assert_cli_schema empty-config 0 config config --json
    assert_cli_schema empty-doctor 0 doctor doctor --json
    assert_cli_schema empty-agent-sweep 4 agent-sweep agent-sweep --dry-run --json
    assert_cli_schema failed-ai-option 4 ai-sync ai-sync '--unknown="quoted"' --json
    assert_cli_schema failed-dep-option 4 dep-update dep-update --unknown --format json
    assert_cli_schema failed-dep-agent 4 dep-update dep-update --agent=unknown --json
    assert_cli_schema failed-dep-path 4 dep-update dep-update '--repo=/tmp/missing "repo"' --json
    assert_cli_schema failed-review-option 4 review review --mode=unknown --json
    assert_cli_schema failed-sweep-mode 4 agent-sweep agent-sweep --execution-mode=unknown --json
    assert_cli_schema failed-sweep-parallel 4 agent-sweep agent-sweep --parallel=0 --json
    assert_cli_schema failed-sweep-option 4 agent-sweep agent-sweep --unknown --json
    assert_cli_schema failed-config-assignment 4 config config --set=invalid --json
    assert_cli_schema failed-prune-options 4 prune prune --archive --delete --json
    assert_cli_schema failed-docs-topic 4 robot-docs robot-docs 'unknown "topic"'
    assert_cli_schema valid-docs-startup 0 robot-docs robot-docs schemas
    TMPDIR="$E2E_TEMP_DIR/missing-temp-directory" assert_cli_schema failed-docs-startup 3 robot-docs robot-docs schemas
    assert_file_contains "$E2E_LOG_DIR/failed-docs-startup.stderr" 'Failed to create temp file' "Always-structured docs retain the real startup diagnostic"
    assert_cli_schema structured-help 0 review --json review --help
    assert_file_contains "$E2E_LOG_DIR/failed-ai-option.stderr" 'Unknown option' "Argument diagnostics remain on stderr"
    assert_success "Failed option has one typed refusal document" jq -se 'length == 1 and .[0].data.error.code == 4' "$E2E_LOG_DIR/failed-ai-option.stdout"
    cleanup_structured_conformance
}

test_actual_populated_and_dry_schemas() {
    setup_structured_conformance
    create_structured_local_repo repo0 || { fail "Could not create real Git control"; cleanup_structured_conformance; return; }
    printf 'owner/repo0\n' > "$RU_CONFIG_DIR/repos.d/public.txt"
    local repo="$RU_PROJECTS_DIR/repo0" before_head before_index
    before_head=$(git -C "$repo" rev-parse HEAD)
    before_index=$(git -C "$repo" ls-files --stage -z | git hash-object --stdin)
    printf '%s\n' "$before_head" > "$E2E_LOG_DIR/head.before"
    git -C "$repo" ls-files --stage -z > "$E2E_LOG_DIR/index.before"
    assert_cli_schema populated-list 0 list list --paths --format json
    assert_cli_schema populated-status 0 status status --no-fetch --json
    assert_cli_schema clean-sweep 0 agent-sweep agent-sweep --dry-run --format json
    printf 'peer staged bytes\n' > "$repo/peer staged.txt"
    git -C "$repo" add 'peer staged.txt' || { fail "Could not stage real peer control"; cleanup_structured_conformance; return; }
    before_index=$(git -C "$repo" ls-files --stage -z | git hash-object --stdin)
    git -C "$repo" ls-files --stage -z > "$E2E_LOG_DIR/index.before"
    printf 'uncommitted bytes\n' >> "$repo/tracked.txt"
    assert_cli_schema dry-sweep 0 agent-sweep agent-sweep --dry-run --format json
    assert_cli_schema json-last-sweep 0 agent-sweep agent-sweep --dry-run --format text --json
    local text_code=0
    "$E2E_RU_SCRIPT" agent-sweep --dry-run --json --format text > "$E2E_LOG_DIR/text-last.stdout" 2> "$E2E_LOG_DIR/text-last.stderr" || text_code=$?
    assert_equals 0 "$text_code" "Last explicit text flag preserves success exit"
    assert_equals '' "$(cat "$E2E_LOG_DIR/text-last.stdout")" "Last explicit text flag keeps human prose off stdout"
    assert_file_contains "$E2E_LOG_DIR/text-last.stderr" 'repo0' "Last explicit text flag retains the human preview"
    assert_cli_schema dry-ai-sync 0 ai-sync ai-sync --dry-run --json
    assert_cli_schema filtered-ai-sync 0 ai-sync ai-sync --dry-run --include=missing --json
    assert_success "AI preview preserves the real dirty path" jq -e --arg path "$repo" '.data.total == 1 and .data.repos == [{path:$path,status:"pending"}]' "$E2E_LOG_DIR/dry-ai-sync.stdout"
    assert_success "Sweep format flag preserves dirty repository selection" jq -e '.data.mode == "dry-run" and .data.repos == ["owner/repo0"]' "$E2E_LOG_DIR/dry-sweep.stdout"

    printf '{"name":"fixture","dependencies":{"fixture":"1.0.0"}}\n' > "$repo/package.json"
    cat > "$E2E_MOCK_BIN/npm" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == outdated && "${2:-}" == --json ]] || { printf 'Unexpected npm invocation\n' >&2; exit 91; }
printf '{"fixture":{"current":"1.0.0","wanted":"1.0.1","latest":"1.0.1","type":"dependencies"}}\n'
exit 1
MOCK
    chmod +x "$E2E_MOCK_BIN/npm"
    assert_cli_schema dry-dep-update 0 dep-update dep-update --dry-run --repo="$repo" --format json
    assert_success "Dependency preview preserves actual controlled outdated result" jq -e '.data.processed == 1 and .data.updated == 0 and .data.results[0].status == "pending" and .data.results[0].outdated.results[0].outdated[0].name == "fixture"' "$E2E_LOG_DIR/dry-dep-update.stdout"
    assert_file_contains "$E2E_LOG_DIR/dry-dep-update.stderr" 'Would update 1 deps' "Dependency dry-run prose remains on stderr"
    assert_cli_schema dry-ad-hoc 0 sync sync owner/new-repo --dry-run --json
    assert_cli_schema invalid-ad-hoc 2 sync sync 'bad "repository"' --dry-run --json

    create_structured_local_repo orphan || { fail "Could not create orphan control"; cleanup_structured_conformance; return; }
    assert_cli_schema populated-prune 0 prune prune --json
    assert_cli_schema dry-prune 0 prune prune --archive --dry-run --json
    assert_success "Prune preview retains the actual orphan path" jq -e --arg path "$RU_PROJECTS_DIR/orphan" '.data.orphans | any(.path == $path)' "$E2E_LOG_DIR/dry-prune.stdout"
    assert_dir_exists "$RU_PROJECTS_DIR/orphan" "Prune dry-run preserves the real orphan"
    assert_success "Archive preview records no mutation" jq -e '.data.dry_run == true and .data.completed == 0 and .data.operations == []' "$E2E_LOG_DIR/dry-prune.stdout"
    assert_cli_schema dry-delete-prune 0 prune prune --delete --force --dry-run --json
    assert_dir_exists "$RU_PROJECTS_DIR/orphan" "Delete preview preserves the same real orphan"
    assert_success "Delete preview records no mutation" jq -e '.data.mode == "delete" and .data.dry_run == true and .data.completed == 0 and .data.operations == []' "$E2E_LOG_DIR/dry-delete-prune.stdout"
    assert_cli_schema assigned-config 0 config config '--set=UPDATE_STRATEGY=ff-only' --json
    assert_cli_schema populated-config 0 config config --print --format json
    assert_cli_schema populated-doctor 0 doctor doctor --json

    e2e_create_mock_gh 0 "$(e2e_graphql_response_with_items 1)"
    assert_cli_schema populated-review-discovery 0 review review --dry-run --mode=local --json
    assert_success "Controlled discovery retains both actual issue and PR payloads" jq -e '.data.summary.items_found == 2 and (.data.items | length) == 2' "$E2E_LOG_DIR/populated-review-discovery.stdout"
    e2e_create_mock_gh 0 "$(e2e_graphql_response_empty 1)"
    assert_cli_schema empty-review-discovery 0 review review --dry-run --mode=local --json
    e2e_create_mock_gh 1 '{}'
    assert_cli_schema failed-review-auth 3 review review --dry-run --json
    assert_file_contains "$E2E_LOG_DIR/failed-review-auth.stderr" 'auth' "Controlled auth failure retains stderr diagnostics"
    e2e_create_mock_gh 0 '{}'
    mkdir -p "$RU_STATE_DIR/worktrees/schema-run"
    printf '{}\n' > "$RU_STATE_DIR/worktrees/schema-run/mapping.json"
    assert_cli_schema failed-review-apply 4 review review --apply --dry-run --json
    assert_success "Existing apply envelope keeps its payload without double nesting" jq -e '.data.mode == "apply" and .data.error == "invalid_mapping" and (.data | has("generated_at") | not)' "$E2E_LOG_DIR/failed-review-apply.stdout"
    mkdir -p "$RU_STATE_DIR/metrics"
    printf '{"reviews":{"total":2},"timing":{"total_duration_minutes":3}}\n' > "$RU_STATE_DIR/metrics/$(date -u +%Y-%m).json"
    assert_cli_schema populated-analytics 0 review review --analytics --json
    assert_success "Analytics retains recorded metrics" jq -e '.data.metrics.reviews.total == 2' "$E2E_LOG_DIR/populated-analytics.stdout"
    assert_equals "$before_head" "$(git -C "$repo" rev-parse HEAD)" "Structured dry/error flows preserve real HEAD"
    assert_equals "$before_index" "$(git -C "$repo" ls-files --stage -z | git hash-object --stdin)" "Structured dry/error flows preserve exact real staged entries"
    assert_file_contains "$repo/tracked.txt" 'uncommitted bytes' "Structured dry/error flows preserve unstaged bytes"
    git -C "$repo" rev-parse HEAD > "$E2E_LOG_DIR/head.after"
    git -C "$repo" ls-files --stage -z > "$E2E_LOG_DIR/index.after"
    assert_success "Structured dry/error flows preserve every byte of retained NUL staged entries" cmp "$E2E_LOG_DIR/index.before" "$E2E_LOG_DIR/index.after"

    if python3 - "$E2E_LOG_DIR/schema.stdout" "$E2E_LOG_DIR/populated-list.stdout" "$E2E_LOG_DIR/dry-ai-sync.stdout" <<'PY'
import copy, json, sys
from jsonschema import Draft202012Validator, FormatChecker, ValidationError
schema = json.load(open(sys.argv[1]))["data"]["content"]
assert "date-time" in FormatChecker.checkers
validator = Draft202012Validator(schema, format_checker=FormatChecker())
listing = json.load(open(sys.argv[2]))
preview = json.load(open(sys.argv[3]))
mutants = [copy.deepcopy(listing), copy.deepcopy(listing), copy.deepcopy(preview), copy.deepcopy(listing)]
mutants[0]["data"]["total"] = "1"
del mutants[1]["data"]["repos"]
mutants[2]["data"]["repos"][0]["status"] = False
mutants[3]["generated_at"] = "invalid timestamp"
for original in (listing, preview):
    validator.validate(original)
for mutant in mutants:
    try:
        validator.validate(mutant)
    except ValidationError:
        continue
    raise AssertionError("Advertised schema accepted altered actual payload: " + repr(mutant))
PY
    then
        pass "Advertised schemas reject changed payload types and missing required fields beside valid actual outputs"
    else
        fail "Advertised schemas did not discriminate altered actual outputs"
    fi
    cleanup_structured_conformance
}

test_structured_workflow_source_api() {
    e2e_setup
    local output="$E2E_LOG_DIR/source-api.stdout"
    if bash -c '
        source "$1"
        JSON_OUTPUT=true OUTPUT_FORMAT=json
        already_wrapped() {
            emit_structured "$(build_json_envelope review '\''{"mode":"status","useful":"quoted \\\"value\\\""}'\'' '\''{"duration_seconds":13,"summary":{"n":2},"exit_code":0}'\'')"
            return 7
        }
        rc=0
        run_structured_workflow review already_wrapped || rc=$?
        [[ "$rc" == 7 && "$OUTPUT_FORMAT" == json ]]
    ' _ "$E2E_RU_SCRIPT" > "$output" 2> "$E2E_LOG_DIR/source-api.stderr"; then
        pass "Source API retains actual workflow exit and caller format"
    else
        fail "Source API changed exit or caller format"
        cat "$E2E_LOG_DIR/source-api.stderr" >&2
    fi
    assert_success "Already-enveloped metadata and quoted payload survive once" jq -se 'length == 1 and .[0]._meta.exit_code == 7 and .[0]._meta.duration_seconds == 13 and .[0]._meta.summary.n == 2 and (.[0].data | has("generated_at") | not) and (. [0].data.useful | contains("value"))' "$output"
    if bash -c '
        source "$1"
        JSON_OUTPUT=true OUTPUT_FORMAT=json
        bad_stream() { printf "{}\n{}\n"; }
        rc=0
        run_structured_workflow review bad_stream || rc=$?
        [[ "$rc" == 3 ]]
    ' _ "$E2E_RU_SCRIPT" > "$E2E_LOG_DIR/bad-stream.stdout" 2> "$E2E_LOG_DIR/bad-stream.stderr"; then
        pass "Two JSON objects refuse as one structured result"
    else
        fail "Multiple JSON values were accepted as one result"
    fi
    assert_success "Malformed stream reports a single typed error" jq -se 'length == 1 and .[0]._meta.exit_code == 3 and .[0].data.error.reason == "invalid_structured_output"' "$E2E_LOG_DIR/bad-stream.stdout"
    local bin="$E2E_TEMP_DIR/no-jq-bin" tool
    mkdir -p "$bin"
    for tool in bash date mktemp cat rm dirname python3; do
        ln -s "$(type -P "$tool")" "$bin/$tool"
    done
    if PATH="$bin" "$bin/bash" -c '
        source "$1"
        command -v jq && exit 93
        JSON_OUTPUT=true OUTPUT_FORMAT=json
        already_wrapped() {
            emit_structured "$(build_json_envelope review '\''{"mode":"status","useful":"Python control"}'\'' '\''{"duration_seconds":13,"summary":{"n":2},"exit_code":0}'\'')"
            return 7
        }
        rc=0
        run_structured_workflow review already_wrapped || rc=$?
        [[ "$rc" == 7 && "$OUTPUT_FORMAT" == json ]]
    ' _ "$E2E_RU_SCRIPT" > "$E2E_LOG_DIR/no-jq.stdout" 2> "$E2E_LOG_DIR/no-jq.stderr"; then
        pass "Actual jq-free PATH retains the Python workflow result and exit"
    else
        fail "Actual jq-free workflow did not preserve its result"
        cat "$E2E_LOG_DIR/no-jq.stderr" >&2
    fi
    assert_success "Python branch retains the same already-enveloped metadata" jq -se 'length == 1 and .[0]._meta.exit_code == 7 and .[0]._meta.duration_seconds == 13 and .[0]._meta.summary.n == 2 and .[0].data.useful == "Python control"' "$E2E_LOG_DIR/no-jq.stdout"
    cleanup_structured_conformance
}

# Actual PTY stdin/stderr and captured stdout exercise the source API dispatcher.
# The negative control reproduces only its original asynchronous worker statement
# without explicit stdin forwarding; no provider or GitHub service is invoked.
test_structured_dispatcher_preserves_actual_tty_approval() {
    e2e_setup
    if TOON_SH_PATH="$STRUCTURED_TOON_SH" python3 - "$E2E_RU_SCRIPT" "$E2E_LOG_DIR" <<'PY'
import json, os, pty, select, subprocess, sys, time

script = r'''
source "$1"
JSON_OUTPUT=true OUTPUT_FORMAT="$4"
[[ -t 0 && -t 2 && ! -t 1 ]] || { printf 'Caller is not the required actual TTY/captured-stdout fixture\n' >&2; exit 83; }
printf 'CALLER_TTY_STDIN_STDERR\n' >&2
approval_workflow() {
    [[ -t 0 && -t 2 && ! -t 1 ]] || { printf 'NO_TTY_APPROVAL_STDIN\n' >&2; return 84; }
    printf 'ACTUAL_TTY_APPROVAL_REQUEST\n' >&2
    local approval
    IFS= read -r approval || return 85
    [[ "$approval" == yes ]] || return 86
    printf '{"mode":"status","approval":"yes","useful":"retained caller payload"}\n'
}
if [[ "$3" == baseline ]]; then
    # Original faulty worker launch, intentionally missing <&0.
    ( OUTPUT_FORMAT=json approval_workflow ) > "$2" &
    worker_pid="${!:-}"
    rc=0
    wait "$worker_pid" || rc=$?
    cat "$2"
    exit "$rc"
fi
run_structured_workflow review approval_workflow
'''

def run_case(mode, output_format):
    master, slave = pty.openpty()
    label = "pty-" + mode + "-" + output_format
    output_path = os.path.join(sys.argv[2], label + ".stdout")
    proc = subprocess.Popen(["bash", "-c", script, "_", sys.argv[1], output_path + ".worker", mode, output_format],
                            stdin=slave, stderr=slave, stdout=subprocess.PIPE)
    os.close(slave)
    diagnostics = bytearray()
    approval_sent = False
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                diagnostics.extend(chunk)
                if b"ACTUAL_TTY_APPROVAL_REQUEST" in diagnostics:
                    os.write(master, b"yes\n")
                    approval_sent = True
                    break
            if proc.poll() is not None:
                break
        output, _ = proc.communicate(timeout=max(0.1, deadline - time.monotonic()))
        while select.select([master], [], [], 0.05)[0]:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            diagnostics.extend(chunk)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2)
        os.close(master)
    with open(output_path, "wb") as stream:
        stream.write(output)
    with open(os.path.join(sys.argv[2], label + ".stderr"), "wb") as stream:
        stream.write(diagnostics)
    assert b"CALLER_TTY_STDIN_STDERR" in diagnostics, diagnostics
    if mode == "baseline":
        assert proc.returncode == 84, (proc.returncode, output, diagnostics)
        assert not approval_sent and b"NO_TTY_APPROVAL_STDIN" in diagnostics, diagnostics
        assert output == b"", output
        return None
    assert approval_sent and proc.returncode == 0, (proc.returncode, output, diagnostics)
    if output_format == "toon":
        decoded = subprocess.run(["tru", "--decode"], input=output, capture_output=True, check=True)
        output = decoded.stdout
    result = json.loads(output)
    assert result["command"] == "review" and result["output_format"] == output_format, result
    assert result["_meta"]["exit_code"] == 0, result
    assert result["data"] == {"mode":"status", "approval":"yes", "useful":"retained caller payload"}, result
    return result

run_case("baseline", "json")
json_result = run_case("actual", "json")
toon_result = run_case("actual", "toon")
assert json_result["data"] == toon_result["data"] and json_result["_meta"] == toon_result["_meta"]
print("Actual TTY approval preserved through JSON capture and actual TOON conversion; missing-stdin baseline refused")
PY
    then
        pass "Actual dispatcher retains TTY approval and useful JSON/TOON payload beside the failing missing-stdin baseline"
    else
        fail "Actual dispatcher did not preserve TTY approval or conversion"
    fi
    cleanup_structured_conformance
}

test_actual_workflow_toon_and_fallback() {
    setup_structured_conformance
    create_structured_local_repo repo0 || { fail "Could not create TOON Git control"; cleanup_structured_conformance; return; }
    printf 'owner/repo0\n' > "$RU_CONFIG_DIR/repos.d/public.txt"
    printf 'dirty bytes\n' >> "$RU_PROJECTS_DIR/repo0/tracked.txt"
    assert_cli_schema json-sweep-control 0 agent-sweep agent-sweep --dry-run --json
    local code=0
    TOON_SH_PATH="$STRUCTURED_TOON_SH" "$E2E_RU_SCRIPT" agent-sweep --dry-run --format toon > "$E2E_LOG_DIR/actual.toon" 2> "$E2E_LOG_DIR/actual-toon.stderr" || code=$?
    assert_equals 0 "$code" "Actual encoder workflow preserves success exit"
    if tru --decode < "$E2E_LOG_DIR/actual.toon" > "$E2E_LOG_DIR/decoded.json" 2> "$E2E_LOG_DIR/decode.stderr" &&
       jq -e '.output_format == "toon" and .command == "agent-sweep"' "$E2E_LOG_DIR/decoded.json" >/dev/null &&
       jq -ne --argjson original "$(cat "$E2E_LOG_DIR/json-sweep-control.stdout")" --argjson decoded "$(cat "$E2E_LOG_DIR/decoded.json")" '$original.data == $decoded.data and $original._meta == $decoded._meta' >/dev/null; then
        pass "Actual TOON decode preserves the JSON command payload and metadata"
    else
        fail "Actual TOON round trip did not preserve the command result"
        cat "$E2E_LOG_DIR/actual-toon.stderr" "$E2E_LOG_DIR/decode.stderr" >&2
    fi
    export TOON_SH_PATH="$E2E_TEMP_DIR/missing-toon.sh"
    assert_cli_schema missing-encoder-fallback 0 agent-sweep agent-sweep --dry-run --format toon
    assert_file_contains "$E2E_LOG_DIR/missing-encoder-fallback.stderr" 'falling back to JSON' "Missing encoder fallback is explicit on stderr"
    assert_success "Fallback preserves the same actual dirty-repository payload" jq -ne --argjson original "$(cat "$E2E_LOG_DIR/json-sweep-control.stdout")" --argjson fallback "$(cat "$E2E_LOG_DIR/missing-encoder-fallback.stdout")" '$original.data == $fallback.data'
    unset TOON_SH_PATH
    cleanup_structured_conformance
}

test_actual_review_interrupt_envelope() {
    setup_structured_conformance
    printf 'owner/repo0\n' > "$RU_CONFIG_DIR/repos.d/public.txt"
    export STRUCTURED_READY_FILE="$E2E_TEMP_DIR/control-ready"
    cat > "$E2E_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then exit 0; fi
if [[ "${1:-}" == api && "${2:-}" == graphql ]]; then
    : > "$STRUCTURED_READY_FILE"
    sleep 1
    printf '{"data":{}}\n'
    exit 0
fi
printf 'Unexpected controlled gh invocation\n' >&2
exit 92
MOCK
    chmod +x "$E2E_MOCK_BIN/gh"
    assert_cli_schema stable-delayed-review 0 review review --dry-run --json
    export STRUCTURED_READY_FILE="$E2E_TEMP_DIR/graphql-ready"
    "$E2E_RU_SCRIPT" review --dry-run --json > "$E2E_LOG_DIR/interrupted.stdout" 2> "$E2E_LOG_DIR/interrupted.stderr" &
    local cli_pid=$! i code=0
    for ((i=0; i<100; i++)); do
        [[ ! -f "$STRUCTURED_READY_FILE" ]] || break
        sleep 0.02
    done
    assert_file_exists "$STRUCTURED_READY_FILE" "Actual review reached the controlled discovery endpoint"
    assert_dir_exists "$RU_STATE_DIR/review.lock.d" "Actual interrupted review holds the physical lock before the signal"
    kill -TERM "$cli_pid" || fail "Could not interrupt this test's owned CLI process"
    wait "$cli_pid" || code=$?
    assert_equals 5 "$code" "Structured actual review interruption retains exit 5"
    assert_success "Interrupted result is one envelope with actual interruption status" jq -se 'length == 1 and .[0].command == "review" and .[0]._meta.exit_code == 5' "$E2E_LOG_DIR/interrupted.stdout"
    assert_file_contains "$E2E_LOG_DIR/interrupted.stderr" 'Review interrupted' "Original review interrupt diagnostic survives"
    assert_false "[[ -d \"$RU_STATE_DIR/review.lock.d\" ]]" "Interrupted child releases its actual review lock"
    unset STRUCTURED_READY_FILE
    cleanup_structured_conformance
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_valid_json_all_topics
run_test test_envelope_structure
run_test test_schema_version
run_test test_all_topic_includes_sections
run_test test_commands_topic_coverage
run_test test_exit_codes_coverage
run_test test_invalid_topic
run_test test_default_topic_is_all
run_test test_schemas_has_command_schemas
run_test test_schema_shortcut
run_test test_version_matches
run_test test_actual_empty_and_failure_schemas
run_test test_actual_populated_and_dry_schemas
run_test test_structured_workflow_source_api
run_test test_structured_dispatcher_preserves_actual_tty_approval
run_test test_actual_workflow_toon_and_fallback
run_test test_actual_review_interrupt_envelope

print_results
exit "$(get_exit_code)"
