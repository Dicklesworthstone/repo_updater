#!/usr/bin/env bash
#
# Unit Tests: Parsing Coverage Expansion (bd-6387)
# Tests for previously untested parsing/resolution functions:
#   - resolve_abs_or_tilde_path_or_default (path resolution)
#   - resolve_output_format (output format negotiation)
#   - sanitize_session_name (tmux session name sanitization)
#   - strip_ansi (ANSI escape code removal)
#   - load_all_repos (config file loading)
#   - detect_main_pollution (fork pollution detection)
#   - get_fork_status (fork sync status)
#   - has_upstream_remote (upstream remote detection)
#   - get_upstream_default_branch (default branch detection)
#   - create_rescue_branch (rescue branch creation)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""
CURRENT_SECTION=""

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' YELLOW='' RESET=''
fi

ORIG_HOME="$HOME"

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
}

restore_home() {
    export HOME="$ORIG_HOME"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# NOTE: This trap is replaced later when fork tests set up FORK_TEMP.
# cleanup_test_env is called explicitly before that point (line ~560).
trap cleanup_test_env EXIT

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got:      $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

section() {
    CURRENT_SECTION="$1"
    echo ""
    echo -e "${BLUE}--- $1 ---${RESET}"
}

#==============================================================================
# Stub functions
#==============================================================================

log_warn() { :; }
log_error() { :; }
log_verbose() { :; }
log_info() { :; }
log_debug() { :; }

#==============================================================================
# Source functions from ru
#==============================================================================

source_function() {
    local func_name="$1"
    local tmp_file
    tmp_file=$(mktemp)
    sed -n "/^${func_name}()/,/^}/p" "$RU_SCRIPT" > "$tmp_file"
    if [[ -s "$tmp_file" ]]; then
        # shellcheck disable=SC1090
        source "$tmp_file"
    else
        echo "Warning: Function $func_name not found in ru" >&2
    fi
    rm -f "$tmp_file"
}

# Source all functions under test
source_function "resolve_abs_or_tilde_path_or_default"
source_function "sanitize_session_name"
source_function "strip_ansi"
source_function "is_git_repo"
source_function "repo_is_dirty"
source_function "load_all_repos"
source_function "has_upstream_remote"
source_function "get_upstream_default_branch"
source_function "get_fork_status"
source_function "detect_main_pollution"
source_function "create_rescue_branch"

# resolve_output_format needs globals
OUTPUT_FORMAT=""
JSON_OUTPUT="false"
SHOW_STATS="false"
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
source_function "resolve_output_format"

#==============================================================================
# Tests: resolve_abs_or_tilde_path_or_default
#==============================================================================

section "resolve_abs_or_tilde_path_or_default"

# Test: absolute path passes through
result=$(resolve_abs_or_tilde_path_or_default "/usr/local/bin" "/default")
if [[ "$result" == "/usr/local/bin" ]]; then
    pass "absolute path passes through unchanged"
else
    fail "absolute path passes through unchanged" "/usr/local/bin" "$result"
fi

# Test: tilde-only resolves to HOME
result=$(resolve_abs_or_tilde_path_or_default "~" "/default")
if [[ "$result" == "$HOME/" ]]; then
    pass "tilde-only resolves to HOME"
else
    fail "tilde-only resolves to HOME" "$HOME/" "$result"
fi

# Test: tilde with path resolves correctly
result=$(resolve_abs_or_tilde_path_or_default "~/Documents/stuff" "/default")
if [[ "$result" == "$HOME/Documents/stuff" ]]; then
    pass "tilde with path resolves correctly"
else
    fail "tilde with path resolves correctly" "$HOME/Documents/stuff" "$result"
fi

# Test: relative path falls back to default
result=$(resolve_abs_or_tilde_path_or_default "relative/path" "/fallback/dir")
if [[ "$result" == "/fallback/dir" ]]; then
    pass "relative path falls back to default"
else
    fail "relative path falls back to default" "/fallback/dir" "$result"
fi

# Test: empty string falls back to default
result=$(resolve_abs_or_tilde_path_or_default "" "/fallback/dir")
if [[ "$result" == "/fallback/dir" ]]; then
    pass "empty string falls back to default"
else
    fail "empty string falls back to default" "/fallback/dir" "$result"
fi

# Test: just dot falls back to default
result=$(resolve_abs_or_tilde_path_or_default "." "/fallback/dir")
if [[ "$result" == "/fallback/dir" ]]; then
    pass "dot falls back to default"
else
    fail "dot falls back to default" "/fallback/dir" "$result"
fi

# Test: root path works
result=$(resolve_abs_or_tilde_path_or_default "/" "/default")
if [[ "$result" == "/" ]]; then
    pass "root path passes through"
else
    fail "root path passes through" "/" "$result"
fi

# Test: absolute path with spaces
result=$(resolve_abs_or_tilde_path_or_default "/path/with spaces/here" "/default")
if [[ "$result" == "/path/with spaces/here" ]]; then
    pass "absolute path with spaces preserved"
else
    fail "absolute path with spaces preserved" "/path/with spaces/here" "$result"
fi

# Test: tilde not at start (e.g., "foo~bar") falls back to default
result=$(resolve_abs_or_tilde_path_or_default "foo~bar" "/default")
if [[ "$result" == "/default" ]]; then
    pass "tilde not at start falls back to default"
else
    fail "tilde not at start falls back to default" "/default" "$result"
fi

# Test: ~user form (not ~/path) falls back to default
result=$(resolve_abs_or_tilde_path_or_default "~user/path" "/default")
if [[ "$result" == "/default" ]]; then
    pass "~user form falls back to default (not supported)"
else
    fail "~user form falls back to default (not supported)" "/default" "$result"
fi

#==============================================================================
# Tests: resolve_output_format
#==============================================================================

section "resolve_output_format"

# Test: default (no env vars) resolves to text
OUTPUT_FORMAT=""
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
SHOW_STATS="false"
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "text" && "$JSON_OUTPUT" == "false" ]]; then
    pass "default resolves to text with JSON_OUTPUT=false"
else
    fail "default resolves to text" "text/false" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: OUTPUT_FORMAT=json sets JSON_OUTPUT=true
OUTPUT_FORMAT="json"
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "json" && "$JSON_OUTPUT" == "true" ]]; then
    pass "json format sets JSON_OUTPUT=true"
else
    fail "json format sets JSON_OUTPUT=true" "json/true" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: OUTPUT_FORMAT=toon sets JSON_OUTPUT=true
OUTPUT_FORMAT="toon"
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "toon" && "$JSON_OUTPUT" == "true" ]]; then
    pass "toon format sets JSON_OUTPUT=true"
else
    fail "toon format sets JSON_OUTPUT=true" "toon/true" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: RU_OUTPUT_FORMAT env var used when OUTPUT_FORMAT empty
OUTPUT_FORMAT=""
RU_OUTPUT_FORMAT="json"
TOON_DEFAULT_FORMAT=""
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "json" && "$JSON_OUTPUT" == "true" ]]; then
    pass "RU_OUTPUT_FORMAT env var used as fallback"
else
    fail "RU_OUTPUT_FORMAT env var used as fallback" "json/true" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: TOON_DEFAULT_FORMAT used when both empty
OUTPUT_FORMAT=""
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT="toon"
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "toon" && "$JSON_OUTPUT" == "true" ]]; then
    pass "TOON_DEFAULT_FORMAT used as second fallback"
else
    fail "TOON_DEFAULT_FORMAT used as second fallback" "toon/true" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: OUTPUT_FORMAT takes precedence over env vars
OUTPUT_FORMAT="text"
RU_OUTPUT_FORMAT="json"
TOON_DEFAULT_FORMAT="toon"
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "text" && "$JSON_OUTPUT" == "false" ]]; then
    pass "CLI format takes precedence over env vars"
else
    fail "CLI format takes precedence over env vars" "text/false" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: case insensitive format
OUTPUT_FORMAT="JSON"
resolve_output_format
if [[ "$OUTPUT_FORMAT" == "json" && "$JSON_OUTPUT" == "true" ]]; then
    pass "case insensitive format (JSON -> json)"
else
    fail "case insensitive format" "json/true" "$OUTPUT_FORMAT/$JSON_OUTPUT"
fi

# Test: SHOW_STATS=true exports TOON_STATS
OUTPUT_FORMAT=""
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
SHOW_STATS="true"
resolve_output_format
if [[ "${TOON_STATS:-}" == "1" ]]; then
    pass "SHOW_STATS=true exports TOON_STATS=1"
else
    fail "SHOW_STATS=true exports TOON_STATS=1" "1" "${TOON_STATS:-unset}"
fi
unset TOON_STATS
SHOW_STATS="false"

# Test: invalid format exits with code 4
OUTPUT_FORMAT="yaml"
RU_OUTPUT_FORMAT=""
TOON_DEFAULT_FORMAT=""
if result=$(resolve_output_format 2>&1); then
    fail "invalid format should exit non-zero" "exit 4" "exit 0"
else
    pass "invalid format exits non-zero"
fi
# Reset
OUTPUT_FORMAT=""

#==============================================================================
# Tests: sanitize_session_name
#==============================================================================

section "sanitize_session_name"

# Test: alphanumeric passes through
result=$(sanitize_session_name "mySession123")
if [[ "$result" == "mySession123" ]]; then
    pass "alphanumeric passes through"
else
    fail "alphanumeric passes through" "mySession123" "$result"
fi

# Test: spaces replaced with underscores
result=$(sanitize_session_name "my session name")
if [[ "$result" == "my_session_name" ]]; then
    pass "spaces replaced with underscores"
else
    fail "spaces replaced with underscores" "my_session_name" "$result"
fi

# Test: special characters replaced
result=$(sanitize_session_name "my-repo.name@v2!")
if [[ "$result" == "my_repo_name_v2" ]]; then
    pass "special characters replaced with underscores"
else
    fail "special characters replaced with underscores" "my_repo_name_v2" "$result"
fi

# Test: multiple consecutive non-alphanumeric collapsed
result=$(sanitize_session_name "foo---bar___baz")
if [[ "$result" == "foo_bar_baz" ]]; then
    pass "consecutive non-alphanumeric collapsed to single underscore"
else
    fail "consecutive non-alphanumeric collapsed to single underscore" "foo_bar_baz" "$result"
fi

# Test: leading/trailing non-alphanumeric stripped
result=$(sanitize_session_name "---hello---")
if [[ "$result" == "hello" ]]; then
    pass "leading/trailing underscores stripped"
else
    fail "leading/trailing underscores stripped" "hello" "$result"
fi

# Test: empty string
result=$(sanitize_session_name "")
if [[ "$result" == "" ]]; then
    pass "empty string returns empty"
else
    fail "empty string returns empty" "" "$result"
fi

# Test: path-like input
result=$(sanitize_session_name "/data/projects/my_repo")
if [[ "$result" == "data_projects_my_repo" ]]; then
    pass "path-like input sanitized correctly"
else
    fail "path-like input sanitized correctly" "data_projects_my_repo" "$result"
fi

# Test: unicode characters replaced
result=$(sanitize_session_name "café_résumé")
if [[ "$result" == "caf_r_sum" ]]; then
    pass "unicode characters replaced with underscores"
else
    fail "unicode characters replaced with underscores" "caf_r_sum" "$result"
fi

#==============================================================================
# Tests: strip_ansi
#==============================================================================

section "strip_ansi"

# Test: removes color codes
result=$(echo -e '\033[0;31mred text\033[0m' | strip_ansi)
if [[ "$result" == "red text" ]]; then
    pass "removes ANSI color codes"
else
    fail "removes ANSI color codes" "red text" "$result"
fi

# Test: removes bold/dim/etc.
result=$(echo -e '\033[1mbold\033[0m \033[2mdim\033[0m' | strip_ansi)
if [[ "$result" == "bold dim" ]]; then
    pass "removes bold/dim formatting codes"
else
    fail "removes bold/dim formatting codes" "bold dim" "$result"
fi

# Test: plain text passes through
result=$(echo "no escape codes here" | strip_ansi)
if [[ "$result" == "no escape codes here" ]]; then
    pass "plain text passes through unchanged"
else
    fail "plain text passes through unchanged" "no escape codes here" "$result"
fi

# Test: empty input
result=$(echo "" | strip_ansi)
if [[ "$result" == "" ]]; then
    pass "empty input returns empty"
else
    fail "empty input returns empty" "" "$result"
fi

# Test: multiple color codes in sequence
result=$(echo -e '\033[0;32mgreen\033[0m \033[0;34mblue\033[0m \033[0;31mred\033[0m' | strip_ansi)
if [[ "$result" == "green blue red" ]]; then
    pass "multiple color codes stripped correctly"
else
    fail "multiple color codes stripped correctly" "green blue red" "$result"
fi

#==============================================================================
# Tests: load_all_repos
#==============================================================================

section "load_all_repos"

setup_test_env

# Prepare config directory with repos.d
RU_CONFIG_DIR="$TEMP_DIR/config/ru"
repos_d="$RU_CONFIG_DIR/repos.d"
mkdir -p "$repos_d"

# Test: loads repos from single file
cat > "$repos_d/main.txt" << 'EOF'
https://github.com/user/repo1.git
https://github.com/user/repo2.git
EOF

load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 2 ]]; then
    pass "loads 2 repos from single file"
else
    fail "loads 2 repos from single file" "2" "${#my_repos[@]}"
fi

# Test: first repo correct
if [[ "${my_repos[0]}" == "https://github.com/user/repo1.git" ]]; then
    pass "first repo URL correct"
else
    fail "first repo URL correct" "https://github.com/user/repo1.git" "${my_repos[0]}"
fi

# Test: skips comments and blank lines
cat > "$repos_d/main.txt" << 'EOF'
# This is a comment
https://github.com/user/repo1.git

  # Indented comment
https://github.com/user/repo2.git

EOF

load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 2 ]]; then
    pass "skips comments and blank lines"
else
    fail "skips comments and blank lines" "2" "${#my_repos[@]}"
fi

# Test: loads from multiple files
cat > "$repos_d/main.txt" << 'EOF'
https://github.com/user/repo1.git
EOF
cat > "$repos_d/extra.txt" << 'EOF'
https://github.com/user/repo2.git
https://github.com/user/repo3.git
EOF

load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 3 ]]; then
    pass "loads repos from multiple .txt files"
else
    fail "loads repos from multiple .txt files" "3" "${#my_repos[@]}"
fi

# Test: empty repos.d directory returns empty array
rm -f "$repos_d"/*.txt
load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 0 ]]; then
    pass "empty repos.d returns empty array"
else
    fail "empty repos.d returns empty array" "0" "${#my_repos[@]}"
fi

# Test: non-existent repos.d returns empty array
rm -rf "$repos_d"
load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 0 ]]; then
    pass "non-existent repos.d returns empty array"
else
    fail "non-existent repos.d returns empty array" "0" "${#my_repos[@]}"
fi

# Test: skips non-.txt files
mkdir -p "$repos_d"
cat > "$repos_d/main.txt" << 'EOF'
https://github.com/user/repo1.git
EOF
cat > "$repos_d/notes.md" << 'EOF'
https://github.com/user/should-not-load.git
EOF

load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 1 ]]; then
    pass "ignores non-.txt files"
else
    fail "ignores non-.txt files" "1" "${#my_repos[@]}"
fi

# Test: whitespace-only lines skipped
cat > "$repos_d/main.txt" << 'EOF'

https://github.com/user/repo1.git

EOF

load_all_repos my_repos
if [[ "${#my_repos[@]}" -eq 1 ]]; then
    pass "whitespace-only lines skipped"
else
    fail "whitespace-only lines skipped" "1" "${#my_repos[@]}"
fi

cleanup_test_env
restore_home

#==============================================================================
# Tests: Fork helper functions (require git repos)
#==============================================================================

section "has_upstream_remote"

# Create a temporary git repo setup for fork tests
FORK_TEMP=$(mktemp -d)
trap 'rm -rf "$FORK_TEMP"; cleanup_test_env' EXIT

# Step 1: Create "upstream" as a normal repo with a commit on main
git init "$FORK_TEMP/upstream" >/dev/null 2>&1
(
    cd "$FORK_TEMP/upstream" || exit
    git checkout -b main 2>/dev/null
    echo "upstream content" > file.txt
    git add file.txt
    git commit -m "Upstream initial commit" >/dev/null 2>&1
)

# Step 2: Create "origin" as a clone of upstream (simulates GitHub fork)
git clone "$FORK_TEMP/upstream" "$FORK_TEMP/origin" --bare >/dev/null 2>&1

# Step 3: Create the working copy (local fork checkout)
git clone "$FORK_TEMP/origin" "$FORK_TEMP/fork" >/dev/null 2>&1
(
    cd "$FORK_TEMP/fork" || exit
    git checkout main 2>/dev/null || git checkout -b main origin/main 2>/dev/null
    # Add upstream remote pointing to the "upstream" repo
    git remote add upstream "$FORK_TEMP/upstream"
    git fetch upstream >/dev/null 2>&1
)

# Test: has_upstream_remote returns 0 when upstream exists
if has_upstream_remote "$FORK_TEMP/fork" "upstream"; then
    pass "has_upstream_remote: returns 0 when upstream exists"
else
    fail "has_upstream_remote: returns 0 when upstream exists"
fi

# Test: has_upstream_remote returns 1 for non-existent remote
if has_upstream_remote "$FORK_TEMP/fork" "nonexistent"; then
    fail "has_upstream_remote: returns 1 for non-existent remote"
else
    pass "has_upstream_remote: returns 1 for non-existent remote"
fi

# Test: default remote name is "upstream"
if has_upstream_remote "$FORK_TEMP/fork"; then
    pass "has_upstream_remote: defaults to 'upstream' remote name"
else
    fail "has_upstream_remote: defaults to 'upstream' remote name"
fi

section "get_upstream_default_branch"

# Test: detects main branch via upstream remote
result=$(get_upstream_default_branch "$FORK_TEMP/fork" "upstream")
if [[ "$result" == "main" ]]; then
    pass "get_upstream_default_branch: detects 'main' branch"
else
    fail "get_upstream_default_branch: detects 'main' branch" "main" "$result"
fi

# Test: also works with origin remote
result=$(get_upstream_default_branch "$FORK_TEMP/fork" "origin")
if [[ "$result" == "main" ]]; then
    pass "get_upstream_default_branch: detects 'main' from origin"
else
    fail "get_upstream_default_branch: detects 'main' from origin" "main" "$result"
fi

# Test: returns failure for non-existent remote
if get_upstream_default_branch "$FORK_TEMP/fork" "nonexistent" >/dev/null 2>&1; then
    fail "get_upstream_default_branch: returns failure for non-existent remote"
else
    pass "get_upstream_default_branch: returns failure for non-existent remote"
fi

section "get_fork_status"

# Ensure fork is synced with upstream (upstream already has the same commit)
(
    cd "$FORK_TEMP/fork" || exit
    git fetch upstream >/dev/null 2>&1
)

# Test: synced state
result=$(get_fork_status "$FORK_TEMP/fork" "upstream" "main")
IFS=$'\t' read -r ahead behind status has_changes <<< "$result"
if [[ "$status" == "synced" && "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
    pass "get_fork_status: detects synced state"
else
    fail "get_fork_status: detects synced state" "0/0/synced" "$ahead/$behind/$status"
fi

# Test: ahead state (local commits not in upstream)
(
    cd "$FORK_TEMP/fork" || exit
    echo "local change" >> file.txt
    git add file.txt
    git commit -m "Local commit" >/dev/null 2>&1
)

result=$(get_fork_status "$FORK_TEMP/fork" "upstream" "main")
IFS=$'\t' read -r ahead behind status has_changes <<< "$result"
if [[ "$status" == "ahead" && "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
    pass "get_fork_status: detects ahead state"
else
    fail "get_fork_status: detects ahead state" ">0/0/ahead" "$ahead/$behind/$status"
fi

# Test: dirty working tree detected
echo "uncommitted change" >> "$FORK_TEMP/fork/file.txt"

result=$(get_fork_status "$FORK_TEMP/fork" "upstream" "main")
IFS=$'\t' read -r ahead behind status has_changes <<< "$result"
if [[ "$has_changes" == "true" ]]; then
    pass "get_fork_status: detects dirty working tree"
else
    fail "get_fork_status: detects dirty working tree" "true" "$has_changes"
fi

# Clean up dirty state
git -C "$FORK_TEMP/fork" checkout -- file.txt 2>/dev/null

# Test: unknown ref returns unknown
result=$(get_fork_status "$FORK_TEMP/fork" "upstream" "nonexistent_branch")
IFS=$'\t' read -r ahead behind status has_changes <<< "$result"
if [[ "$status" == "unknown" ]]; then
    pass "get_fork_status: returns unknown for missing branch"
else
    fail "get_fork_status: returns unknown for missing branch" "unknown" "$status"
fi

section "detect_main_pollution"

# Test: polluted (local has commits upstream doesn't)
if detect_main_pollution "$FORK_TEMP/fork" "upstream" "main"; then
    pass "detect_main_pollution: detects local commits ahead of upstream"
else
    fail "detect_main_pollution: detects local commits ahead of upstream"
fi

# Test: clean (reset fork to match upstream)
(
    cd "$FORK_TEMP/fork" || exit
    git reset --hard upstream/main >/dev/null 2>&1
    git fetch upstream >/dev/null 2>&1
)

if detect_main_pollution "$FORK_TEMP/fork" "upstream" "main"; then
    fail "detect_main_pollution: returns 1 when synced (clean)"
else
    pass "detect_main_pollution: returns 1 when synced (clean)"
fi

section "create_rescue_branch"

# Add a local commit to create something worth rescuing
echo "work to rescue" >> "$FORK_TEMP/fork/file.txt"
git -C "$FORK_TEMP/fork" add file.txt >/dev/null 2>&1
git -C "$FORK_TEMP/fork" commit -m "Work to rescue" >/dev/null 2>&1

# Test: creates rescue branch with expected name pattern
rescue_name=$(create_rescue_branch "$FORK_TEMP/fork" "main")
if [[ "$rescue_name" == rescue/main_* ]]; then
    pass "create_rescue_branch: creates branch with rescue/main_TIMESTAMP pattern"
else
    fail "create_rescue_branch: creates branch with rescue/main_TIMESTAMP pattern" "rescue/main_*" "$rescue_name"
fi

# Test: rescue branch exists in the repo
if git -C "$FORK_TEMP/fork" rev-parse --verify "$rescue_name" >/dev/null 2>&1; then
    pass "create_rescue_branch: branch exists in repo"
else
    fail "create_rescue_branch: branch exists in repo"
fi

# Test: rescue branch points to same commit as main
main_sha=$(git -C "$FORK_TEMP/fork" rev-parse main)
rescue_sha=$(git -C "$FORK_TEMP/fork" rev-parse "$rescue_name")
if [[ "$main_sha" == "$rescue_sha" ]]; then
    pass "create_rescue_branch: rescue branch matches main HEAD"
else
    fail "create_rescue_branch: rescue branch matches main HEAD" "$main_sha" "$rescue_sha"
fi

#==============================================================================
# Results (FORK_TEMP cleaned by EXIT trap)
#==============================================================================

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
