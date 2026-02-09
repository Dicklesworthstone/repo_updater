#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_get_field"
source_ru_function "run_quality_gates"

log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

load_policy_for_repo() { echo '{"test_command":"","lint_command":""}'; }
run_lint_gate() { echo '{"ran":true,"ok":true,"output":"clean"}'; return 0; }
run_test_gate() { echo '{"ran":true,"ok":true,"output":"ok"}'; return 0; }
run_secret_scan() { echo '{"scanned":true,"ok":true,"findings":[]}'; return 0; }

tmpdir=$(mktemp -d)
plan_file="$tmpdir/plan.json"
echo '{"repo":"test/repo"}' > "$plan_file"
mkdir -p "$tmpdir/repo"

echo "=== Calling run_quality_gates ==="
result=$(run_quality_gates "$tmpdir/repo" "$plan_file" 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "RESULT_RAW=>>>$result<<<"
echo "OVERALL=$(echo "$result" | jq -r '.overall_ok' 2>/dev/null)"
