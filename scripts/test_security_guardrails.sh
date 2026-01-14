#!/usr/bin/env bash
#
# Unit Tests: Security Guardrails (bd-6p3o)
#
# Test coverage:
#   - File denylist: exact matches, glob patterns, allowed files, extra patterns
#   - Secret scanning: gitleaks, detect-secrets, heuristic fallback
#   - File size limits: small/large files, custom limits, disabled check
#   - Binary detection: text files, JSON, null bytes, ELF binaries, empty files
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Source required functions from ru
#==============================================================================

# Source the denylist array and functions
# shellcheck disable=SC1090
eval "$(sed -n '/^declare -a AGENT_SWEEP_DENYLIST_PATTERNS=/,/^)/p' "$PROJECT_DIR/ru")"
# Initialize AGENT_SWEEP_DENYLIST_EXTRA_LOCAL (used by is_file_denied, normally loaded from config)
declare -ga AGENT_SWEEP_DENYLIST_EXTRA_LOCAL=()
source_ru_function "is_file_denied"
source_ru_function "filter_files_denylist"
source_ru_function "get_denylist_patterns"

# Source secret scanning function
source_ru_function "run_secret_scan"
source_ru_function "json_escape"
source_ru_function "json_get_field"

# Source file size and binary detection functions
source_ru_function "is_file_too_large"
source_ru_function "is_binary_file"
source_ru_function "agent_sweep_is_positive_int"

# Mock logging to avoid noisy output on error paths
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

#==============================================================================
# FILE DENYLIST TESTS
#==============================================================================

test_denylist_exact_env_files() {
    log_test_start "Denylist: exact .env matches"

    # Test exact .env patterns
    assert_true "is_file_denied '.env'" ".env should be denied"
    assert_true "is_file_denied '.env.local'" ".env.local should be denied"
    assert_true "is_file_denied '.env.production'" ".env.production should be denied"
    assert_true "is_file_denied 'config/.env'" "Nested .env should be denied"
    assert_true "is_file_denied 'app/config/.env.test'" "Deeply nested .env should be denied"
}

test_denylist_key_files() {
    log_test_start "Denylist: private key files"

    # Test key file patterns
    assert_true "is_file_denied 'id_rsa'" "id_rsa should be denied"
    assert_true "is_file_denied 'id_rsa.pub'" "id_rsa.pub should be denied"
    assert_true "is_file_denied 'server.pem'" "*.pem should be denied"
    assert_true "is_file_denied 'certs/client.pem'" "Nested .pem should be denied"
    assert_true "is_file_denied 'ssl.key'" "*.key should be denied"
    assert_true "is_file_denied 'certificate.p12'" "*.p12 should be denied"
    assert_true "is_file_denied 'keystore.pfx'" "*.pfx should be denied"
}

test_denylist_credential_files() {
    log_test_start "Denylist: credential files"

    assert_true "is_file_denied 'credentials.json'" "credentials.json should be denied"
    assert_true "is_file_denied 'secrets.json'" "secrets.json should be denied"
    assert_true "is_file_denied 'api.secret'" "*.secret should be denied"
    assert_true "is_file_denied 'auth.secrets'" "*.secrets should be denied"
    assert_true "is_file_denied '.netrc'" ".netrc should be denied"
    assert_true "is_file_denied '.npmrc'" ".npmrc should be denied"
    assert_true "is_file_denied '.pypirc'" ".pypirc should be denied"
}

test_denylist_build_artifacts() {
    log_test_start "Denylist: build artifacts and dependencies"

    # node_modules
    assert_true "is_file_denied 'node_modules'" "node_modules should be denied"
    assert_true "is_file_denied 'node_modules/package/index.js'" "Files in node_modules should be denied"
    # Note: Nested directory detection (e.g., frontend/node_modules/*) is not currently
    # supported. The denylist matches patterns at path start or basename only.
    # See is_file_denied() for implementation details. This is a known limitation.
    # Future enhancement: Add */pattern/* support for nested directory matching

    # Python
    assert_true "is_file_denied '__pycache__'" "__pycache__ should be denied"
    assert_true "is_file_denied '__pycache__/module.pyc'" "Files in __pycache__ should be denied"
    assert_true "is_file_denied 'module.pyc'" "*.pyc should be denied"
    assert_true "is_file_denied 'optimized.pyo'" "*.pyo should be denied"

    # Build directories
    assert_true "is_file_denied 'dist'" "dist should be denied"
    assert_true "is_file_denied 'dist/bundle.js'" "Files in dist should be denied"
    assert_true "is_file_denied 'build'" "build should be denied"
    assert_true "is_file_denied 'build/output.css'" "Files in build should be denied"
    assert_true "is_file_denied '.next'" ".next should be denied"
    assert_true "is_file_denied 'target'" "target (Rust/Maven) should be denied"
    assert_true "is_file_denied 'vendor'" "vendor (Go/PHP) should be denied"
}

test_denylist_temp_files() {
    log_test_start "Denylist: temporary and log files"

    assert_true "is_file_denied 'debug.log'" "*.log should be denied"
    assert_true "is_file_denied 'server.tmp'" "*.tmp should be denied"
    assert_true "is_file_denied 'cache.temp'" "*.temp should be denied"
    assert_true "is_file_denied 'file.swp'" "*.swp should be denied"
    assert_true "is_file_denied 'file.swo'" "*.swo should be denied"
    assert_true "is_file_denied 'backup~'" "*~ should be denied"
    assert_true "is_file_denied '.DS_Store'" ".DS_Store should be denied"
    assert_true "is_file_denied 'Thumbs.db'" "Thumbs.db should be denied"
}

test_denylist_ide_files() {
    log_test_start "Denylist: IDE and editor files"

    assert_true "is_file_denied '.idea'" ".idea should be denied"
    assert_true "is_file_denied '.idea/workspace.xml'" "Files in .idea should be denied"
    assert_true "is_file_denied '.vscode'" ".vscode should be denied"
    assert_true "is_file_denied '.vscode/settings.json'" "Files in .vscode should be denied"
    assert_true "is_file_denied 'project.iml'" "*.iml should be denied"
}

test_denylist_allowed_files() {
    log_test_start "Denylist: allowed files verification"

    # Common source files should be allowed
    assert_false "is_file_denied 'src/main.py'" "Python source should be allowed"
    assert_false "is_file_denied 'app/index.js'" "JavaScript source should be allowed"
    assert_false "is_file_denied 'lib/module.ts'" "TypeScript source should be allowed"
    assert_false "is_file_denied 'README.md'" "README.md should be allowed"
    assert_false "is_file_denied 'package.json'" "package.json should be allowed"
    assert_false "is_file_denied 'config/settings.yaml'" "YAML config (not secrets.yaml) should be allowed"
    assert_false "is_file_denied '.gitignore'" ".gitignore should be allowed"
    assert_false "is_file_denied 'Makefile'" "Makefile should be allowed"
    assert_false "is_file_denied 'go.mod'" "go.mod should be allowed"
    assert_false "is_file_denied 'Cargo.toml'" "Cargo.toml should be allowed"
}

test_denylist_path_normalization() {
    log_test_start "Denylist: path normalization"

    # Test leading ./ removal
    assert_true "is_file_denied './.env'" "./.env should be denied (normalized)"
    assert_true "is_file_denied './node_modules/pkg'" "./node_modules/pkg should be denied (leading ./ stripped)"

    # Test trailing / removal
    assert_true "is_file_denied 'node_modules/'" "node_modules/ should be denied"
}

test_denylist_extra_patterns() {
    log_test_start "Denylist: extra patterns from environment"

    # Set extra patterns
    local old_extra="${AGENT_SWEEP_DENYLIST_EXTRA:-}"
    export AGENT_SWEEP_DENYLIST_EXTRA="*.backup internal/*"

    assert_true "is_file_denied 'data.backup'" "*.backup from extra should be denied"
    assert_true "is_file_denied 'internal/secret.txt'" "internal/* from extra should be denied"
    assert_false "is_file_denied 'external/public.txt'" "Non-matching should still be allowed"

    # Restore
    if [[ -n "$old_extra" ]]; then
        export AGENT_SWEEP_DENYLIST_EXTRA="$old_extra"
    else
        unset AGENT_SWEEP_DENYLIST_EXTRA
    fi
}

test_denylist_nested_directories() {
    log_test_start "Denylist: nested directory pattern matching"

    # Files in node_modules at any nesting depth should be denied (bd-omo4)
    assert_true "is_file_denied 'node_modules/pkg/a.js'" "node_modules/pkg/a.js should be denied"
    assert_true "is_file_denied 'frontend/node_modules/pkg/a.js'" "frontend/node_modules/pkg/a.js should be denied"
    assert_true "is_file_denied 'deep/nested/path/node_modules/pkg/a.js'" "deeply nested node_modules should be denied"

    # Same for __pycache__
    assert_true "is_file_denied '__pycache__/module.pyc'" "__pycache__/module.pyc should be denied"
    assert_true "is_file_denied 'src/__pycache__/module.pyc'" "nested __pycache__ should be denied"

    # Same for dist (build artifacts)
    assert_true "is_file_denied 'dist/bundle.js'" "dist/bundle.js should be denied"
    assert_true "is_file_denied 'frontend/dist/bundle.js'" "nested dist should be denied"

    # Same for build directory
    assert_true "is_file_denied 'build/output.js'" "build/output.js should be denied"
    assert_true "is_file_denied 'packages/core/build/index.js'" "nested build should be denied"

    # Regular files should still be allowed
    assert_false "is_file_denied 'src/components/Button.tsx'" "Regular source file should be allowed"
}

test_filter_files_denylist() {
    log_test_start "filter_files_denylist function"

    local input="src/main.py
.env
lib/module.js
id_rsa
README.md
node_modules/pkg/index.js"

    local output
    output=$(echo "$input" | filter_files_denylist 2>/dev/null)

    assert_contains "$output" "src/main.py" "Should include main.py"
    assert_contains "$output" "lib/module.js" "Should include module.js"
    assert_contains "$output" "README.md" "Should include README.md"
    assert_not_contains "$output" ".env" "Should exclude .env"
    assert_not_contains "$output" "id_rsa" "Should exclude id_rsa"
    assert_not_contains "$output" "node_modules" "Should exclude node_modules"
}

test_get_denylist_patterns() {
    log_test_start "get_denylist_patterns function"

    local patterns
    patterns=$(get_denylist_patterns)

    assert_contains "$patterns" ".env" "Should include .env pattern"
    assert_contains "$patterns" "*.pem" "Should include *.pem pattern"
    assert_contains "$patterns" "node_modules" "Should include node_modules pattern"
}

#==============================================================================
# SECRET SCANNING TESTS
#==============================================================================

test_secret_scan_returns_json() {
    log_test_start "Secret scan returns valid JSON structure"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    # Initialize git repo
    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "clean content" > "$test_repo/clean.txt"
    git -C "$test_repo" add clean.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    local result
    result=$(run_secret_scan "$test_repo")

    # Should be valid JSON with expected fields
    local ok
    ok=$(echo "$result" | jq -r '.ok // empty' 2>/dev/null)
    assert_not_empty "$ok" "Result should have 'ok' field"

    local tool
    tool=$(echo "$result" | jq -r '.tool // empty' 2>/dev/null)
    assert_not_empty "$tool" "Result should have 'tool' field"
}

test_secret_scan_detects_private_keys() {
    log_test_start "Secret scan detects private keys"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with private key pattern
    cat > "$test_repo/secret.txt" << 'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAq8HzQmQ0N3E8Hn6EXAMPLE
-----END RSA PRIVATE KEY-----
EOF
    git -C "$test_repo" add secret.txt

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "false" "$ok" "Should detect private key and return ok:false"
}

test_secret_scan_detects_aws_keys() {
    log_test_start "Secret scan detects AWS access keys"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with AWS key pattern
    echo "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" > "$test_repo/config.sh"
    git -C "$test_repo" add config.sh

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "false" "$ok" "Should detect AWS key and return ok:false"
}

test_secret_scan_detects_github_tokens() {
    log_test_start "Secret scan detects GitHub tokens"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with GitHub token pattern
    echo "GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwxyz" > "$test_repo/config.sh"
    git -C "$test_repo" add config.sh

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "false" "$ok" "Should detect GitHub token and return ok:false"
}

test_secret_scan_detects_slack_tokens() {
    log_test_start "Secret scan detects Slack tokens"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with Slack token pattern
    echo "SLACK_TOKEN=xoxb-1234567890123-1234567890123-abcdefghij" > "$test_repo/config.sh"
    git -C "$test_repo" add config.sh

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "false" "$ok" "Should detect Slack token and return ok:false"
}

test_secret_scan_detects_password_assignments() {
    log_test_start "Secret scan detects password assignments"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with password assignment
    echo 'password=supersecret123' > "$test_repo/config.ini"
    git -C "$test_repo" add config.ini

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "false" "$ok" "Should detect password assignment and return ok:false"
}

test_secret_scan_clean_file_passes() {
    log_test_start "Secret scan passes on clean files"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add clean file
    echo 'console.log("Hello, world!");' > "$test_repo/app.js"
    git -C "$test_repo" add app.js

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "true" "$ok" "Clean file should return ok:true"
}

test_secret_scan_test_key_format_not_matched() {
    log_test_start "Secret scan: test key format doesn't match production patterns"

    require_jq_or_skip || return 0

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_repo="$temp_dir/test_repo"
    mkdir -p "$test_repo"

    git -C "$test_repo" init --quiet
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"
    echo "initial" > "$test_repo/initial.txt"
    git -C "$test_repo" add initial.txt
    git -C "$test_repo" commit -m "Initial" --quiet

    # Add file with Stripe test key prefix (sk_test_ format differs from sk_live_ pattern)
    # Scanner patterns only match production key formats, not test key formats
    echo "STRIPE_KEY=sk_test_XXXXXXXXXXXXXXXXXXXX" > "$test_repo/config.sh"
    git -C "$test_repo" add config.sh

    local result
    result=$(run_secret_scan "$test_repo")

    local ok
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    assert_equals "true" "$ok" "Test key format (sk_test_) should not match production patterns"
}

#==============================================================================
# FILE SIZE LIMIT TESTS
#==============================================================================

test_file_size_small_file_allowed() {
    log_test_start "File size: small file allowed"

    # Check if is_file_too_large function exists
    if ! type is_file_too_large &>/dev/null; then
        skip_test "is_file_too_large not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/small.txt"

    # Create a small file (100 bytes)
    dd if=/dev/zero of="$test_file" bs=100 count=1 2>/dev/null

    # With 1MB limit, small file should not be too large
    assert_false "is_file_too_large '$test_file' 1" "100-byte file should be allowed with 1MB limit"
}

test_file_size_large_file_denied() {
    log_test_start "File size: large file denied"

    if ! type is_file_too_large &>/dev/null; then
        skip_test "is_file_too_large not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/large.bin"

    # Create a 2MB file
    dd if=/dev/zero of="$test_file" bs=1M count=2 2>/dev/null

    # With 1MB limit, 2MB file should be too large
    assert_true "is_file_too_large '$test_file' 1" "2MB file should be denied with 1MB limit"
}

test_file_size_custom_limit() {
    log_test_start "File size: custom limit via argument"

    if ! type is_file_too_large &>/dev/null; then
        skip_test "is_file_too_large not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/medium.bin"

    # Create a 5MB file
    dd if=/dev/zero of="$test_file" bs=1M count=5 2>/dev/null

    # With 10MB limit, 5MB file should be allowed
    assert_false "is_file_too_large '$test_file' 10" "5MB file should be allowed with 10MB limit"

    # With 3MB limit, 5MB file should be denied
    assert_true "is_file_too_large '$test_file' 3" "5MB file should be denied with 3MB limit"
}

test_file_size_zero_limit_disabled() {
    log_test_start "File size: zero limit disables check"

    if ! type is_file_too_large &>/dev/null; then
        skip_test "is_file_too_large not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/any.bin"

    # Create a 1MB file
    dd if=/dev/zero of="$test_file" bs=1M count=1 2>/dev/null

    # With 0 limit (disabled), any file should be allowed
    assert_false "is_file_too_large '$test_file' 0" "Any file should be allowed when limit is 0"
}

#==============================================================================
# BINARY DETECTION TESTS
#==============================================================================

test_binary_text_file_allowed() {
    log_test_start "Binary detection: text file allowed"

    # Check if is_binary_file function exists
    if ! type is_binary_file &>/dev/null; then
        skip_test "is_binary_file not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/code.py"

    # Create a text file
    echo 'def hello(): print("Hello, world!")' > "$test_file"

    # Text file should not be detected as binary
    assert_false "is_binary_file '$test_file'" "Python source file should not be binary"
}

test_binary_json_file_allowed() {
    log_test_start "Binary detection: JSON file allowed"

    if ! type is_binary_file &>/dev/null; then
        skip_test "is_binary_file not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/config.json"

    # Create a JSON file
    echo '{"name": "test", "version": "1.0.0"}' > "$test_file"

    # JSON file should not be detected as binary
    assert_false "is_binary_file '$test_file'" "JSON file should not be binary"
}

test_binary_null_bytes_detected() {
    log_test_start "Binary detection: file with null bytes"

    if ! type is_binary_file &>/dev/null; then
        skip_test "is_binary_file not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/binary.dat"

    # Create a file with null bytes
    printf 'Hello\x00World\x00Binary' > "$test_file"

    # File with null bytes should be detected as binary
    assert_true "is_binary_file '$test_file'" "File with null bytes should be binary"
}

test_binary_elf_detected() {
    log_test_start "Binary detection: ELF binary"

    if ! type is_binary_file &>/dev/null; then
        skip_test "is_binary_file not implemented yet"
        return 0
    fi

    # Use /bin/ls as a known ELF binary
    if [[ -f /bin/ls ]]; then
        assert_true "is_binary_file '/bin/ls'" "ELF binary (/bin/ls) should be detected as binary"
    else
        skip_test "/bin/ls not available for testing"
    fi
}

test_binary_empty_file() {
    log_test_start "Binary detection: empty file"

    if ! type is_binary_file &>/dev/null; then
        skip_test "is_binary_file not implemented yet"
        return 0
    fi

    local temp_dir
    temp_dir=$(create_temp_dir)
    local test_file="$temp_dir/empty.txt"

    # Create empty file
    touch "$test_file"

    # Empty file should not be detected as binary (or should be allowed)
    assert_false "is_binary_file '$test_file'" "Empty file should not be binary"
}

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

#==============================================================================
# Main
#==============================================================================

main() {
    echo "============================================"
    echo "Security Guardrails Tests (bd-6p3o)"
    echo "============================================"
    echo ""

    # File Denylist Tests
    echo "--- File Denylist Tests ---"
    run_test test_denylist_exact_env_files
    run_test test_denylist_key_files
    run_test test_denylist_credential_files
    run_test test_denylist_build_artifacts
    run_test test_denylist_temp_files
    run_test test_denylist_ide_files
    run_test test_denylist_allowed_files
    run_test test_denylist_path_normalization
    run_test test_denylist_extra_patterns
    run_test test_denylist_nested_directories
    run_test test_filter_files_denylist
    run_test test_get_denylist_patterns

    # Secret Scanning Tests
    echo ""
    echo "--- Secret Scanning Tests ---"
    run_test test_secret_scan_returns_json
    run_test test_secret_scan_detects_private_keys
    run_test test_secret_scan_detects_aws_keys
    run_test test_secret_scan_detects_github_tokens
    run_test test_secret_scan_detects_slack_tokens
    run_test test_secret_scan_detects_password_assignments
    run_test test_secret_scan_clean_file_passes
    run_test test_secret_scan_test_key_format_not_matched

    # File Size Tests
    echo ""
    echo "--- File Size Tests ---"
    run_test test_file_size_small_file_allowed
    run_test test_file_size_large_file_denied
    run_test test_file_size_custom_limit
    run_test test_file_size_zero_limit_disabled

    # Binary Detection Tests
    echo ""
    echo "--- Binary Detection Tests ---"
    run_test test_binary_text_file_allowed
    run_test test_binary_json_file_allowed
    run_test test_binary_null_bytes_detected
    run_test test_binary_elf_detected
    run_test test_binary_empty_file

    # Print results
    print_results
    return "$(get_exit_code)"
}

main "$@"
