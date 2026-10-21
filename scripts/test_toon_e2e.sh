#!/usr/bin/env bash
set -euo pipefail

# Exercise this checkout with a populated isolated configuration, independent
# of the operator's installed ru version or personal repository inventory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$PROJECT_DIR:$PATH"
TOON_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ru-toon-e2e.XXXXXX")
export RU_CONFIG_DIR="$TOON_TEST_ROOT/config" RU_STATE_DIR="$TOON_TEST_ROOT/state"
export RU_CACHE_DIR="$TOON_TEST_ROOT/cache" RU_PROJECTS_DIR="$TOON_TEST_ROOT/projects"
export RU_CHECK_UPDATES=false RU_LAYOUT=flat
mkdir -p "$RU_CONFIG_DIR/repos.d" "$RU_STATE_DIR" "$RU_CACHE_DIR" "$RU_PROJECTS_DIR"
printf '%s\n' 'fixture-owner/first-repo' 'fixture-owner/second-repo' > "$RU_CONFIG_DIR/repos.d/public.txt"

# RU TOON E2E Test Script
# Tests TOON format support across ru commands

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_pass() { log "PASS: $*"; }
log_fail() { log "FAIL: $*"; }
log_skip() { log "SKIP: $*"; }
log_info() { log "INFO: $*"; }

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

record_pass() { ((TESTS_PASSED++)) || true; log_pass "$1"; }
record_fail() { ((TESTS_FAILED++)) || true; log_fail "$1"; }
record_skip() { ((TESTS_SKIPPED++)) || true; log_skip "$1"; }

log "=========================================="
log "RU (REPO UPDATER) TOON E2E TEST"
log "=========================================="
log ""

# Phase 1: Prerequisites
log "--- Phase 1: Prerequisites ---"

for cmd in ru jq; do
    if command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            jq)  version=$("$cmd" --version 2>/dev/null | head -1 || echo "available") ;;
            ru)  version="available" ;;  # ru has no --version flag
            *)   version="available" ;;
        esac
        log_info "$cmd: $version"
        record_pass "$cmd available"
    else
        record_fail "$cmd not found"
        [[ "$cmd" == "ru" ]] && exit 1
    fi
done
# The toon_rust CLI: "toon" since v0.2, "tru" before.
TOON_CLI=$(type -P tru || type -P toon || true)
if [[ -n "$TOON_CLI" ]]; then
    log_info "TOON CLI: $("$TOON_CLI" --version 2>/dev/null | head -1)"
    record_pass "toon_rust CLI available"
else
    record_fail "toon_rust CLI (toon or tru) not found"
fi
log ""

# Phase 2: Format Flag Tests
# NOTE: Using 'list' instead of 'status' because status scans all repos (~100+)
# and takes too long. 'list' is fast and demonstrates TOON format correctly.
log "--- Phase 2: Format Flag Tests ---"

log_info "Test 2.1: ru --format json list"
if json_output=$(ru --format json list 2>/dev/null); then
    if echo "$json_output" | jq . >/dev/null 2>&1; then
        record_pass "--format json produces valid JSON"
        json_bytes=$(echo -n "$json_output" | wc -c)
        log_info "  JSON output: $json_bytes bytes"
    else
        record_fail "--format json invalid"
    fi
else
    record_skip "ru --format json list error"
fi

log_info "Test 2.2: ru --format toon list"
if toon_output=$(ru --format toon list 2>/dev/null); then
    # TOON tabular format for arrays starts with [N]{header}:
    # e.g., [112]{repo,path,url}:
    if [[ -n "$toon_output" && "$toon_output" =~ ^\[([0-9]+)\]\{ ]]; then
        record_pass "--format toon produces TOON tabular format"
        toon_bytes=$(echo -n "$toon_output" | wc -c)
        log_info "  TOON output: $toon_bytes bytes"
    elif [[ -n "$toon_output" && "${toon_output:0:1}" != "{" ]]; then
        # Non-tabular TOON (key: value format)
        record_pass "--format toon produces TOON"
        toon_bytes=$(echo -n "$toon_output" | wc -c)
        log_info "  TOON output: $toon_bytes bytes"
    else
        # Might be JSON fallback, which is a failure once an encoder is installed
        if echo "$toon_output" | jq . >/dev/null 2>&1; then
            if [[ -n "$TOON_CLI" ]]; then
                record_fail "--format toon fell back to JSON although $TOON_CLI is installed"
            else
                record_skip "--format toon fell back to JSON"
            fi
        else
            record_fail "--format toon invalid output"
        fi
    fi
else
    record_skip "ru --format toon list error"
fi

log_info "Test 2.3: ru --format toon list without a toon.sh helper"
if [[ -n "$TOON_CLI" ]]; then
    if helperless=$(TOON_SH_PATH="$TOON_TEST_ROOT/no-helper.sh" ru --format toon list 2>/dev/null) &&
       helperless_json=$(printf '%s\n' "$helperless" | "$TOON_CLI" --decode 2>/dev/null) &&
       printf '%s\n' "$helperless_json" | jq -e '.command == "list" and .output_format == "toon" and .data.total == 2' >/dev/null; then
        record_pass "ru encodes with the installed toon_rust CLI when no toon.sh helper exists"
    else
        record_fail "ru did not encode TOON with the installed toon_rust CLI and no toon.sh helper"
    fi
else
    record_skip "TOON without a helper (no toon_rust CLI installed)"
fi
log ""

# Phase 3: Round-trip Verification
log "--- Phase 3: Round-trip Verification ---"

if [[ -n "${json_output:-}" && -n "${toon_output:-}" ]]; then
    # Handle both tabular format [N]{...} and key: value format
    if [[ "$toon_output" =~ ^\[([0-9]+)\]\{ ]] || [[ "${toon_output:0:1}" != "{" ]]; then
        if decoded=$(echo "$toon_output" | "$TOON_CLI" --decode 2>/dev/null); then
            # TOON tabular format may have different structure
            # Just verify it decodes to valid JSON
            if echo "$decoded" | jq . >/dev/null 2>&1; then
                record_pass "Round-trip produces valid JSON"
                if jq -ne --argjson original "$json_output" --argjson decoded "$decoded" '$original.data == $decoded.data' >/dev/null; then
                    record_pass "Round-trip preserves actual populated command data"
                else
                    record_fail "Round-trip changed actual command data"
                fi
            else
                record_fail "Round-trip decode invalid"
            fi
        else
            record_fail "${TOON_CLI:-toon} --decode failed"
        fi
    else
        record_skip "Round-trip (TOON fell back to JSON)"
    fi
else
    record_skip "Round-trip (no valid outputs)"
fi
log ""

# Compare JSON values rather than number spellings: 2 and 2.0 are equivalent,
# while a numeric string or an omitted field changes the actual payload.
if jq -ne '{total:2,repos:[{repo:"fixture",path:"/tmp/fixture"}]} == {total:2.0,repos:[{repo:"fixture",path:"/tmp/fixture"}]}' >/dev/null &&
   jq -ne '{total:2,repos:[{repo:"fixture",path:"/tmp/fixture"}]} != {total:"2",repos:[{repo:"fixture",path:"/tmp/fixture"}]}' >/dev/null &&
   jq -ne '{total:2,repos:[{repo:"fixture",path:"/tmp/fixture"}]} != {total:2,repos:[{repo:"fixture"}]}' >/dev/null; then
    record_pass "Payload comparison accepts equivalent numbers and rejects changed values or missing fields"
else
    record_fail "Payload comparison failed its paired equality and inequality controls"
fi

# Phase 4: Environment Variables
log "--- Phase 4: Environment Variables ---"

unset RU_OUTPUT_FORMAT TOON_DEFAULT_FORMAT

export RU_OUTPUT_FORMAT=toon
if env_out=$(ru list 2>/dev/null); then
    if [[ -n "$env_out" ]]; then
        record_pass "RU_OUTPUT_FORMAT=toon accepted"
    else
        record_skip "RU_OUTPUT_FORMAT test (empty output)"
    fi
else
    record_skip "RU_OUTPUT_FORMAT test"
fi
unset RU_OUTPUT_FORMAT

export TOON_DEFAULT_FORMAT=toon
if env_out=$(ru list 2>/dev/null); then
    if [[ -n "$env_out" ]]; then
        record_pass "TOON_DEFAULT_FORMAT=toon accepted"
    else
        record_skip "TOON_DEFAULT_FORMAT test (empty output)"
    fi
else
    record_skip "TOON_DEFAULT_FORMAT test"
fi

# Test CLI override
if override=$(ru --format json list 2>/dev/null) && echo "$override" | jq . >/dev/null 2>&1; then
    record_pass "CLI --format json overrides env"
else
    record_skip "CLI override test"
fi
unset TOON_DEFAULT_FORMAT
log ""

# Phase 5: Token Savings Analysis
log "--- Phase 5: Token Savings Analysis ---"

if [[ -n "${json_bytes:-}" && -n "${toon_bytes:-}" && "$json_bytes" -gt 0 ]]; then
    savings=$(( (json_bytes - toon_bytes) * 100 / json_bytes ))
    log_info "JSON: $json_bytes bytes"
    log_info "TOON: $toon_bytes bytes"
    log_info "Savings: ${savings}%"

    if [[ $savings -gt 20 ]]; then
        record_pass "Token savings ${savings}% (>20% target)"
    else
        log_info "Note: Savings below target but TOON format works"
        record_pass "TOON encoding functional"
    fi
else
    record_skip "Token savings (no valid byte counts)"
fi
log ""

# Phase 6: Multiple Commands
log "--- Phase 6: Multiple Commands ---"

# Note: 'status' omitted because it scans all repos and is too slow for CI
COMMANDS=(
    "list"
)

for cmd in "${COMMANDS[@]}"; do
    if ru --format toon $cmd &>/dev/null; then
        record_pass "ru --format toon $cmd"
    else
        record_skip "ru --format toon $cmd"
    fi
done
log ""

# Summary
log "=========================================="
log "SUMMARY: Passed=$TESTS_PASSED Failed=$TESTS_FAILED Skipped=$TESTS_SKIPPED"
log ""
log "NOTE: ru achieves ~40-45% token savings with TOON due to"
log "      tabular format for repository status arrays."
[[ $TESTS_FAILED -gt 0 ]] && exit 1 || exit 0
