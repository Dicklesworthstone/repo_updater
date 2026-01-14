#!/usr/bin/env bash
#
# Unit tests: Config management
# (get_config_value, set_config_value, resolve_config, ensure_config_exists)
#
# Tests configuration priority (CLI > env > file > default), file operations,
# and directory structure creation.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source the specific functions we need to test
source_ru_function "ensure_dir"
source_ru_function "get_config_value"
source_ru_function "set_config_value"
source_ru_function "ensure_config_exists"
source_ru_function "log_verbose"
source_ru_function "is_valid_config_key"
source_ru_function "expand_tilde"
source_ru_function "resolve_config"

# Set XDG defaults for sourcing (we override in tests anyway)
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/ru-test-config}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/tmp/ru-test-state}"

# Source defaults from ru (we need DEFAULT_* variables)
eval "$(grep -E '^DEFAULT_' "$PROJECT_DIR/ru" | head -20)"

# These will be overridden in each test
RU_CONFIG_DIR="$XDG_CONFIG_HOME/ru"
RU_STATE_DIR="$XDG_STATE_HOME/ru"
RU_LOG_DIR="$RU_STATE_DIR/logs"

# Initialize other global variables that functions depend on
VERBOSE="false"
GUM_AVAILABLE="false"
LOG_LEVEL=0

#==============================================================================
# Tests: get_config_value
#==============================================================================

test_get_config_value_cli_priority() {
    local test_name="get_config_value: CLI argument takes priority"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    # Set up environment for this test
    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config file with a value
    echo "TESTKEY=file_value" > "$RU_CONFIG_DIR/config"

    # Set environment variable
    export RU_TESTKEY="env_value"

    # CLI value should take priority
    local result
    result=$(get_config_value "TESTKEY" "default_value" "cli_value")

    assert_equals "cli_value" "$result" "CLI argument should take priority"

    unset RU_TESTKEY
    log_test_pass "$test_name"
}

test_get_config_value_env_priority() {
    local test_name="get_config_value: Environment variable takes second priority"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config file with a value
    echo "TESTKEY=file_value" > "$RU_CONFIG_DIR/config"

    # Set environment variable
    export RU_TESTKEY="env_value"

    # No CLI value - env should take priority over file
    local result
    result=$(get_config_value "TESTKEY" "default_value" "")

    assert_equals "env_value" "$result" "Environment variable should take priority over config file"

    unset RU_TESTKEY
    log_test_pass "$test_name"
}

test_get_config_value_file_priority() {
    local test_name="get_config_value: Config file takes third priority"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config file with a value
    echo "TESTKEY=file_value" > "$RU_CONFIG_DIR/config"

    # No CLI, no env - file should be used
    unset RU_TESTKEY 2>/dev/null || true

    local result
    result=$(get_config_value "TESTKEY" "default_value" "")

    assert_equals "file_value" "$result" "Config file value should be used when no CLI or env"

    log_test_pass "$test_name"
}

test_get_config_value_default_fallback() {
    local test_name="get_config_value: Default is used when nothing else set"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Empty config file - no TESTKEY
    echo "# empty" > "$RU_CONFIG_DIR/config"

    # No CLI, no env, no file value - default should be used
    unset RU_TESTKEY 2>/dev/null || true

    local result
    result=$(get_config_value "TESTKEY" "default_value" "")

    assert_equals "default_value" "$result" "Default value should be used as fallback"

    log_test_pass "$test_name"
}

test_get_config_value_handles_quoted_values() {
    local test_name="get_config_value: Strips quotes from file values"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Config with quoted value
    echo 'QUOTED_KEY="quoted value"' > "$RU_CONFIG_DIR/config"

    unset RU_QUOTED_KEY 2>/dev/null || true

    local result
    result=$(get_config_value "QUOTED_KEY" "" "")

    assert_equals "quoted value" "$result" "Quotes should be stripped from file values"

    log_test_pass "$test_name"
}

test_get_config_value_preserves_internal_quotes() {
    local test_name="get_config_value: Preserves internal quote characters"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    cat > "$RU_CONFIG_DIR/config" <<'EOF'
INTERNAL_QUOTES=foo"bar'baz
EOF

    unset RU_INTERNAL_QUOTES 2>/dev/null || true

    local result
    result=$(get_config_value "INTERNAL_QUOTES" "" "")

    assert_equals "foo\"bar'baz" "$result" "Internal quotes should be preserved"

    log_test_pass "$test_name"
}

test_get_config_value_strips_only_matching_outer_quotes() {
    local test_name="get_config_value: Strips only matching surrounding quotes"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    cat > "$RU_CONFIG_DIR/config" <<'EOF'
SINGLE_QUOTED='quoted "value"'
MISMATCHED_START="foo
MISMATCHED_END=bar"
EOF

    unset RU_SINGLE_QUOTED RU_MISMATCHED_START RU_MISMATCHED_END 2>/dev/null || true

    local result
    result=$(get_config_value "SINGLE_QUOTED" "" "")
    assert_equals 'quoted "value"' "$result" "Matching surrounding single quotes should be stripped"

    result=$(get_config_value "MISMATCHED_START" "" "")
    assert_equals '"foo' "$result" "Mismatched starting quote should not be stripped"

    result=$(get_config_value "MISMATCHED_END" "" "")
    assert_equals 'bar"' "$result" "Mismatched trailing quote should not be stripped"

    log_test_pass "$test_name"
}

test_get_config_value_handles_paths_with_slashes() {
    local test_name="get_config_value: Handles paths with slashes"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Config with path value
    echo "PROJECTS_DIR=/home/user/my projects/repos" > "$RU_CONFIG_DIR/config"

    unset RU_PROJECTS_DIR 2>/dev/null || true

    local result
    result=$(get_config_value "PROJECTS_DIR" "/default" "")

    assert_equals "/home/user/my projects/repos" "$result" "Paths with slashes should work"

    log_test_pass "$test_name"
}

test_get_config_value_no_config_file() {
    local test_name="get_config_value: Works when no config file exists"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    # Don't create the config file

    unset RU_NOFILE_KEY 2>/dev/null || true

    local result
    result=$(get_config_value "NOFILE_KEY" "fallback_default" "")

    assert_equals "fallback_default" "$result" "Should return default when no config file exists"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: set_config_value
#==============================================================================

test_set_config_value_creates_new_key() {
    local test_name="set_config_value: Creates new key in config file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create empty config
    echo "# config" > "$RU_CONFIG_DIR/config"

    # Set a new value
    set_config_value "NEWKEY" "newvalue"

    # Check it was added
    assert_file_contains "$RU_CONFIG_DIR/config" "NEWKEY=newvalue" "New key should be appended"

    log_test_pass "$test_name"
}

test_set_config_value_updates_existing_key() {
    local test_name="set_config_value: Updates existing key in config file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config with existing key
    cat > "$RU_CONFIG_DIR/config" << 'EOF'
# config
EXISTING_KEY=old_value
OTHER_KEY=other
EOF

    # Update the existing key
    set_config_value "EXISTING_KEY" "new_value"

    # Check it was updated
    local content
    content=$(cat "$RU_CONFIG_DIR/config")

    assert_contains "$content" "EXISTING_KEY=new_value" "Key should be updated to new value"
    assert_not_contains "$content" "old_value" "Old value should be gone"
    assert_contains "$content" "OTHER_KEY=other" "Other keys should be preserved"

    log_test_pass "$test_name"
}

test_set_config_value_creates_config_file() {
    local test_name="set_config_value: Creates config file if it doesn't exist"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Don't create config file
    assert_file_not_exists "$RU_CONFIG_DIR/config" "Config file should not exist initially"

    # Set a value - should create the file
    set_config_value "CREATED_KEY" "created_value"

    assert_file_exists "$RU_CONFIG_DIR/config" "Config file should be created"
    assert_file_contains "$RU_CONFIG_DIR/config" "CREATED_KEY=created_value" "Key should be in new file"

    log_test_pass "$test_name"
}

test_set_config_value_handles_paths() {
    local test_name="set_config_value: Handles paths with special characters"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    echo "# config" > "$RU_CONFIG_DIR/config"

    # Set a path value with slashes
    set_config_value "PROJECTS_DIR" "/home/user/my-repos/github"

    assert_file_contains "$RU_CONFIG_DIR/config" "PROJECTS_DIR=/home/user/my-repos/github" "Path should be stored correctly"

    log_test_pass "$test_name"
}

test_set_config_value_escapes_sed_special_chars() {
    local test_name="set_config_value: Escapes sed special characters"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Start with a key that we'll update
    echo "TESTKEY=original" > "$RU_CONFIG_DIR/config"

    # Test ampersand (& means "matched text" in sed replacement)
    set_config_value "TESTKEY" "foo&bar"
    local result
    result=$(grep "^TESTKEY=" "$RU_CONFIG_DIR/config" | cut -d= -f2-)
    assert_equals "foo&bar" "$result" "Ampersand should be escaped properly"

    # Test backslash
    set_config_value "TESTKEY" 'path\with\backslashes'
    result=$(grep "^TESTKEY=" "$RU_CONFIG_DIR/config" | cut -d= -f2-)
    assert_equals 'path\with\backslashes' "$result" "Backslash should be escaped properly"

    # Test pipe (our sed delimiter)
    set_config_value "TESTKEY" "value|with|pipes"
    result=$(grep "^TESTKEY=" "$RU_CONFIG_DIR/config" | cut -d= -f2-)
    assert_equals "value|with|pipes" "$result" "Pipe should be escaped properly"

    # Test combined special characters
    set_config_value "TESTKEY" 'mixed&special\chars|here'
    result=$(grep "^TESTKEY=" "$RU_CONFIG_DIR/config" | cut -d= -f2-)
    assert_equals 'mixed&special\chars|here' "$result" "Combined special chars should be escaped"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: ensure_config_exists
#==============================================================================

test_ensure_config_exists_creates_directories() {
    local test_name="ensure_config_exists: Creates config and repos.d directories"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_temp_dir)

    # Use a fresh directory that create_test_env hasn't touched
    export RU_CONFIG_DIR="$test_env/fresh_config/ru"
    export RU_STATE_DIR="$test_env/fresh_state/ru"
    export RU_LOG_DIR="$RU_STATE_DIR/logs"
    export DEFAULT_PROJECTS_DIR="$test_env/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Nothing should exist
    assert_dir_not_exists "$RU_CONFIG_DIR" "Config dir should not exist initially"

    # Run ensure_config_exists
    ensure_config_exists >/dev/null 2>&1

    # Directories should now exist
    assert_dir_exists "$RU_CONFIG_DIR" "Config directory should be created"
    assert_dir_exists "$RU_CONFIG_DIR/repos.d" "repos.d directory should be created"

    log_test_pass "$test_name"
}

test_ensure_config_exists_creates_config_file() {
    local test_name="ensure_config_exists: Creates config file with defaults"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_temp_dir)

    export RU_CONFIG_DIR="$test_env/fresh_config/ru"
    export RU_STATE_DIR="$test_env/fresh_state/ru"
    export RU_LOG_DIR="$RU_STATE_DIR/logs"
    export DEFAULT_PROJECTS_DIR="$test_env/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    ensure_config_exists >/dev/null 2>&1

    # Config file should exist
    local config_file="$RU_CONFIG_DIR/config"
    assert_file_exists "$config_file" "Config file should be created"

    # Should contain expected keys
    assert_file_contains "$config_file" "PROJECTS_DIR=" "Should have PROJECTS_DIR"
    assert_file_contains "$config_file" "LAYOUT=" "Should have LAYOUT"
    assert_file_contains "$config_file" "UPDATE_STRATEGY=" "Should have UPDATE_STRATEGY"
    assert_file_contains "$config_file" "AUTOSTASH=" "Should have AUTOSTASH"

    log_test_pass "$test_name"
}

test_ensure_config_exists_creates_repos_file() {
    local test_name="ensure_config_exists: Creates public.txt template"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_temp_dir)

    export RU_CONFIG_DIR="$test_env/fresh_config/ru"
    export RU_STATE_DIR="$test_env/fresh_state/ru"
    export RU_LOG_DIR="$RU_STATE_DIR/logs"
    export DEFAULT_PROJECTS_DIR="$test_env/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    ensure_config_exists >/dev/null 2>&1

    # public.txt should exist
    local repos_file="$RU_CONFIG_DIR/repos.d/public.txt"
    assert_file_exists "$repos_file" "public.txt should be created"

    # Should contain format examples
    assert_file_contains "$repos_file" "owner/repo" "Should have format examples"
    assert_file_contains "$repos_file" "@branch" "Should document branch pinning"

    log_test_pass "$test_name"
}

test_ensure_config_exists_idempotent() {
    local test_name="ensure_config_exists: Is idempotent (doesn't overwrite)"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_temp_dir)

    export RU_CONFIG_DIR="$test_env/fresh_config/ru"
    export RU_STATE_DIR="$test_env/fresh_state/ru"
    export RU_LOG_DIR="$RU_STATE_DIR/logs"
    export DEFAULT_PROJECTS_DIR="$test_env/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # First call creates everything
    ensure_config_exists >/dev/null 2>&1

    # Add a marker to config
    echo "# MARKER: Custom content" >> "$RU_CONFIG_DIR/config"

    # Second call should not overwrite
    ensure_config_exists >/dev/null 2>&1

    # Marker should still be there
    assert_file_contains "$RU_CONFIG_DIR/config" "MARKER: Custom content" "Config should not be overwritten"

    log_test_pass "$test_name"
}

test_ensure_config_exists_creates_state_dirs() {
    local test_name="ensure_config_exists: Creates state directories"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_temp_dir)

    export RU_CONFIG_DIR="$test_env/fresh_config/ru"
    export RU_STATE_DIR="$test_env/fresh_state/ru"
    export RU_LOG_DIR="$RU_STATE_DIR/logs"
    export DEFAULT_PROJECTS_DIR="$test_env/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    assert_dir_not_exists "$RU_STATE_DIR" "State dir should not exist initially"

    ensure_config_exists >/dev/null 2>&1

    assert_dir_exists "$RU_STATE_DIR" "State directory should be created"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: is_valid_config_key
#==============================================================================

test_is_valid_config_key_valid_simple() {
    local test_name="is_valid_config_key: Valid simple key"
    log_test_start "$test_name"

    if is_valid_config_key "PROJECTS_DIR"; then
        log_test_pass "$test_name"
    else
        fail_test "PROJECTS_DIR should be a valid config key"
    fi
}

test_is_valid_config_key_valid_with_numbers() {
    local test_name="is_valid_config_key: Valid key with numbers"
    log_test_start "$test_name"

    if is_valid_config_key "LOG_LEVEL_2"; then
        log_test_pass "$test_name"
    else
        fail_test "LOG_LEVEL_2 should be a valid config key"
    fi
}

test_is_valid_config_key_valid_with_underscores() {
    local test_name="is_valid_config_key: Valid key with underscores"
    log_test_start "$test_name"

    if is_valid_config_key "UPDATE_STRATEGY"; then
        log_test_pass "$test_name"
    else
        fail_test "UPDATE_STRATEGY should be a valid config key"
    fi
}

test_is_valid_config_key_single_letter() {
    local test_name="is_valid_config_key: Valid single letter key"
    log_test_start "$test_name"

    if is_valid_config_key "X"; then
        log_test_pass "$test_name"
    else
        fail_test "X should be a valid config key"
    fi
}

test_is_valid_config_key_invalid_lowercase() {
    local test_name="is_valid_config_key: Invalid lowercase key"
    log_test_start "$test_name"

    if is_valid_config_key "projects_dir"; then
        fail_test "Lowercase projects_dir should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_mixed_case() {
    local test_name="is_valid_config_key: Invalid mixed case key"
    log_test_start "$test_name"

    if is_valid_config_key "ProjectsDir"; then
        fail_test "Mixed case ProjectsDir should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_starts_with_number() {
    local test_name="is_valid_config_key: Invalid key starting with number"
    log_test_start "$test_name"

    if is_valid_config_key "2PROJECTS"; then
        fail_test "Key starting with number should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_starts_with_underscore() {
    local test_name="is_valid_config_key: Invalid key starting with underscore"
    log_test_start "$test_name"

    if is_valid_config_key "_PRIVATE"; then
        fail_test "Key starting with underscore should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_with_hyphen() {
    local test_name="is_valid_config_key: Invalid key with hyphen"
    log_test_start "$test_name"

    if is_valid_config_key "PROJECTS-DIR"; then
        fail_test "Key with hyphen should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_empty() {
    local test_name="is_valid_config_key: Invalid empty key"
    log_test_start "$test_name"

    if is_valid_config_key ""; then
        fail_test "Empty string should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

test_is_valid_config_key_invalid_with_space() {
    local test_name="is_valid_config_key: Invalid key with space"
    log_test_start "$test_name"

    if is_valid_config_key "PROJECTS DIR"; then
        fail_test "Key with space should be invalid"
    else
        log_test_pass "$test_name"
    fi
}

#==============================================================================
# Tests: resolve_config
#==============================================================================

test_resolve_config_uses_defaults() {
    local test_name="resolve_config: Uses defaults when nothing set"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create empty config (no settings)
    echo "# empty config" > "$RU_CONFIG_DIR/config"

    # Set defaults
    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Clear any existing values
    unset RU_PROJECTS_DIR RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL 2>/dev/null || true
    PROJECTS_DIR=""
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    # Run resolve_config
    resolve_config

    assert_equals "/default/projects" "$PROJECTS_DIR" "PROJECTS_DIR should use default"
    assert_equals "flat" "$LAYOUT" "LAYOUT should use default"
    assert_equals "ff-only" "$UPDATE_STRATEGY" "UPDATE_STRATEGY should use default"
    assert_equals "true" "$AUTOSTASH" "AUTOSTASH should use default"
    assert_equals "4" "$PARALLEL" "PARALLEL should use default"

    log_test_pass "$test_name"
}

test_resolve_config_uses_config_file() {
    local test_name="resolve_config: Uses config file values"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config with custom values
    cat > "$RU_CONFIG_DIR/config" << 'EOF'
PROJECTS_DIR=/custom/projects
LAYOUT=owner-repo
UPDATE_STRATEGY=rebase
AUTOSTASH=false
PARALLEL=8
EOF

    # Set defaults (should be overridden)
    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Clear env vars and current values
    unset RU_PROJECTS_DIR RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL 2>/dev/null || true
    PROJECTS_DIR=""
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    resolve_config

    assert_equals "/custom/projects" "$PROJECTS_DIR" "PROJECTS_DIR should use config file"
    assert_equals "owner-repo" "$LAYOUT" "LAYOUT should use config file"
    assert_equals "rebase" "$UPDATE_STRATEGY" "UPDATE_STRATEGY should use config file"
    assert_equals "false" "$AUTOSTASH" "AUTOSTASH should use config file"
    assert_equals "8" "$PARALLEL" "PARALLEL should use config file"

    log_test_pass "$test_name"
}

test_resolve_config_expands_tilde() {
    local test_name="resolve_config: Expands tilde in PROJECTS_DIR"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    local old_home="$HOME"
    HOME="$test_env/home"
    mkdir -p "$HOME"

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    cat > "$RU_CONFIG_DIR/config" << 'EOF'
PROJECTS_DIR=~/repos
EOF

    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    unset RU_PROJECTS_DIR RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL 2>/dev/null || true
    PROJECTS_DIR=""
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    resolve_config

    assert_equals "$HOME/repos" "$PROJECTS_DIR" "PROJECTS_DIR should expand tilde"

    HOME="$old_home"
    log_test_pass "$test_name"
}

test_resolve_config_uses_env_vars() {
    local test_name="resolve_config: Environment variables override config file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config with values
    cat > "$RU_CONFIG_DIR/config" << 'EOF'
PROJECTS_DIR=/file/projects
LAYOUT=flat
EOF

    # Set defaults
    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Set env vars (should override file)
    export RU_PROJECTS_DIR="/env/projects"
    export RU_LAYOUT="full"

    # Clear current values
    PROJECTS_DIR=""
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    resolve_config

    assert_equals "/env/projects" "$PROJECTS_DIR" "PROJECTS_DIR should use env var"
    assert_equals "full" "$LAYOUT" "LAYOUT should use env var"

    unset RU_PROJECTS_DIR RU_LAYOUT
    log_test_pass "$test_name"
}

test_resolve_config_uses_cli_args() {
    local test_name="resolve_config: CLI args take highest priority"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config with values
    cat > "$RU_CONFIG_DIR/config" << 'EOF'
PROJECTS_DIR=/file/projects
LAYOUT=flat
EOF

    # Set defaults
    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Set env vars
    export RU_PROJECTS_DIR="/env/projects"

    # Set CLI args (these are passed as current values before resolve_config)
    PROJECTS_DIR="/cli/projects"
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    resolve_config

    assert_equals "/cli/projects" "$PROJECTS_DIR" "PROJECTS_DIR should use CLI arg"

    unset RU_PROJECTS_DIR
    log_test_pass "$test_name"
}

test_resolve_config_partial_config() {
    local test_name="resolve_config: Handles partial config gracefully"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    export RU_CONFIG_DIR="$test_env/config/ru"
    mkdir -p "$RU_CONFIG_DIR"

    # Create config with only some values
    cat > "$RU_CONFIG_DIR/config" << 'EOF'
PROJECTS_DIR=/partial/projects
EOF

    # Set defaults
    export DEFAULT_PROJECTS_DIR="/default/projects"
    export DEFAULT_LAYOUT="flat"
    export DEFAULT_UPDATE_STRATEGY="ff-only"
    export DEFAULT_AUTOSTASH="true"
    export DEFAULT_PARALLEL="4"

    # Clear everything
    unset RU_PROJECTS_DIR RU_LAYOUT RU_UPDATE_STRATEGY RU_AUTOSTASH RU_PARALLEL 2>/dev/null || true
    PROJECTS_DIR=""
    LAYOUT=""
    UPDATE_STRATEGY=""
    AUTOSTASH=""
    PARALLEL=""

    resolve_config

    assert_equals "/partial/projects" "$PROJECTS_DIR" "PROJECTS_DIR should use config file"
    assert_equals "flat" "$LAYOUT" "LAYOUT should use default"
    assert_equals "ff-only" "$UPDATE_STRATEGY" "UPDATE_STRATEGY should use default"
    assert_equals "true" "$AUTOSTASH" "AUTOSTASH should use default"
    assert_equals "4" "$PARALLEL" "PARALLEL should use default"

    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

# get_config_value tests
run_test test_get_config_value_cli_priority
run_test test_get_config_value_env_priority
run_test test_get_config_value_file_priority
run_test test_get_config_value_default_fallback
run_test test_get_config_value_handles_quoted_values
run_test test_get_config_value_preserves_internal_quotes
run_test test_get_config_value_strips_only_matching_outer_quotes
run_test test_get_config_value_handles_paths_with_slashes
run_test test_get_config_value_no_config_file

# set_config_value tests
run_test test_set_config_value_creates_new_key
run_test test_set_config_value_updates_existing_key
run_test test_set_config_value_creates_config_file
run_test test_set_config_value_handles_paths
run_test test_set_config_value_escapes_sed_special_chars

# ensure_config_exists tests
run_test test_ensure_config_exists_creates_directories
run_test test_ensure_config_exists_creates_config_file
run_test test_ensure_config_exists_creates_repos_file
run_test test_ensure_config_exists_idempotent
run_test test_ensure_config_exists_creates_state_dirs

# is_valid_config_key tests
run_test test_is_valid_config_key_valid_simple
run_test test_is_valid_config_key_valid_with_numbers
run_test test_is_valid_config_key_valid_with_underscores
run_test test_is_valid_config_key_single_letter
run_test test_is_valid_config_key_invalid_lowercase
run_test test_is_valid_config_key_invalid_mixed_case
run_test test_is_valid_config_key_invalid_starts_with_number
run_test test_is_valid_config_key_invalid_starts_with_underscore
run_test test_is_valid_config_key_invalid_with_hyphen
run_test test_is_valid_config_key_invalid_empty
run_test test_is_valid_config_key_invalid_with_space

# resolve_config tests
run_test test_resolve_config_uses_defaults
run_test test_resolve_config_uses_config_file
run_test test_resolve_config_expands_tilde
run_test test_resolve_config_uses_env_vars
run_test test_resolve_config_uses_cli_args
run_test test_resolve_config_partial_config

print_results
exit "$(get_exit_code)"
