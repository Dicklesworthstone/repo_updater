#!/usr/bin/env bash
#
# ru installer
# Downloads and installs ru (Repo Updater) to your system
#
# DEFAULT: Downloads from GitHub Release with checksum verification
#
# Usage:
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh?ru_cb=$(date +%s)" | bash
#
# Options (via environment variables):
#   DEST=/path/to/dir      Install directory (default: ~/.local/bin)
#   RU_SYSTEM=1            Install to /usr/local/bin (requires sudo)
#   RU_VERSION=x.y.z       Install specific version (default: latest release)
#   RU_UNSAFE_MAIN=1       Install from main branch (NOT RECOMMENDED)
#   RU_CACHE_BUST=1        Append cache-busting query params to GitHub downloads (default: 1)
#   RU_CACHE_BUST_TOKEN=... Cache-bust token override (default: current epoch seconds)
#
# Examples:
#   # Standard installation (recommended)
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh?ru_cb=$(date +%s)" | bash
#
#   # Install specific version
#   RU_VERSION=1.0.0 curl -fsSL .../install.sh | bash
#
#   # System-wide installation
#   RU_SYSTEM=1 curl -fsSL .../install.sh | bash
#
#   # Custom directory
#   DEST=/opt/bin curl -fsSL .../install.sh | bash
#
# Security:
#   - Default: Downloads from GitHub Release with SHA256 checksum verification
#   - RU_UNSAFE_MAIN=1 required to install from main branch (for development only)
#
# Repository: https://github.com/Dicklesworthstone/repo_updater
# License: MIT
#
#==============================================================================

set -uo pipefail

#==============================================================================
# CONSTANTS
#==============================================================================

REPO_OWNER="Dicklesworthstone"
REPO_NAME="repo_updater"
SCRIPT_NAME="ru"
GITHUB_API="https://api.github.com"
GITHUB_RAW="https://raw.githubusercontent.com"
GITHUB_RELEASE_HOST="https://github.com"

# Cache-bust token used for GitHub downloads (reduces stale CDN caching)
RU_CACHE_BUST_TOKEN="${RU_CACHE_BUST_TOKEN:-$(date +%s)}"

# Temp dir path for cleanup trap (kept global to avoid set -u issues with local vars)
RU_INSTALLER_TEMP_DIR=""

#==============================================================================
# COLORS (disabled if stderr is not a terminal or NO_COLOR is set)
# We check -t 2 (stderr) because all log functions output to stderr
#==============================================================================

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

#==============================================================================
# LOGGING FUNCTIONS
#==============================================================================

log_info() {
    printf '%b\n' "${BLUE}ℹ${RESET} $*" >&2
}

log_success() {
    printf '%b\n' "${GREEN}✓${RESET} $*" >&2
}

log_warn() {
    printf '%b\n' "${YELLOW}⚠${RESET} $*" >&2
}

log_error() {
    printf '%b\n' "${RED}✗${RESET} $*" >&2
}

log_step() {
    printf '%b\n' "${BLUE}→${RESET} $*" >&2
}

#==============================================================================
# UTILITY FUNCTIONS
#==============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

cleanup_temp_dir() {
    local dir="$RU_INSTALLER_TEMP_DIR"
    if [[ -z "$dir" ]] || [[ "$dir" == "/" ]]; then
        return 0
    fi
    if [[ -d "$dir" ]]; then
        rm -rf "$dir" 2>/dev/null || true
    fi
}

mktemp_dir() {
    local dir=""

    # GNU coreutils mktemp
    if dir=$(mktemp -d 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi

    # BSD mktemp (macOS) typically requires -t (template)
    if dir=$(mktemp -d -t ru 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi
    if dir=$(mktemp -d -t ru.XXXXXXXXXX 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi

    return 1
}

append_query_param() {
    local url="$1"
    local key="$2"
    local value="$3"

    local sep='?'
    [[ "$url" == *\?* ]] && sep='&'
    printf '%s%s%s=%s' "$url" "$sep" "$key" "$value"
}

maybe_cache_bust_url() {
    local url="$1"

    if [[ "${RU_CACHE_BUST:-1}" != "1" ]]; then
        printf '%s' "$url"
        return 0
    fi

    case "$url" in
        "$GITHUB_RAW"/*|"$GITHUB_RELEASE_HOST"/*)
            append_query_param "$url" "ru_cb" "$RU_CACHE_BUST_TOKEN"
            ;;
        *)
            printf '%s' "$url"
            ;;
    esac
}

github_api_get() {
    local url="$1"
    local body=""

    if command_exists curl; then
        local response status
        if ! response=$(curl -sS \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Cache-Control: no-cache" \
            -H "Pragma: no-cache" \
            -H "User-Agent: ru-installer" \
            -w $'\n%{http_code}' \
            "$url" 2>/dev/null); then
            log_error "Failed to fetch GitHub API: $url"
            return 1
        fi
        status="${response##*$'\n'}"
        body="${response%$'\n'*}"

        case "$status" in
            200|201|202|204)
                printf '%s' "$body"
                return 0
                ;;
            404)
                printf '%s' "$body"
                return 2
                ;;
            *)
                printf '%s' "$body"
                return 1
                ;;
        esac
    fi

    if command_exists wget; then
        if ! body=$(wget -qO- "$url" 2>/dev/null); then
            log_error "Failed to fetch GitHub API: $url"
            return 1
        fi

        # Best-effort status detection from JSON body
        if printf '%s\n' "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"404"'; then
            printf '%s' "$body"
            return 2
        fi

        printf '%s' "$body"
        return 0
    fi

    log_error "Neither curl nor wget found. Please install one of them."
    return 1
}

# Attempt to detect the latest release tag without GitHub's API (avoids rate limits/proxies).
# Returns:
#   0 with version on stdout - success
#   1 - no releases exist (redirect resolves to /releases)
#   2 - request failed
get_latest_release_from_redirect() {
    local latest_url="$GITHUB_RELEASE_HOST/$REPO_OWNER/$REPO_NAME/releases/latest"
    local effective_url=""

    if command_exists curl; then
        if ! effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null); then
            return 2
        fi
    elif command_exists wget; then
        # wget doesn't expose a direct "effective URL" format, so read the Location header.
        # We intentionally avoid following redirects here so we can capture the tag URL.
        effective_url=$(
            wget -qS --spider --max-redirect=0 "$latest_url" 2>&1 \
                | awk '/^  Location: /{print $2}' \
                | tail -1 \
                | tr -d '\r'
        )
        if [[ -z "$effective_url" ]]; then
            return 2
        fi
    else
        return 2
    fi

    if [[ "$effective_url" != *"/tag/"* ]]; then
        return 1
    fi

    local tag="${effective_url##*/tag/}"
    tag="${tag%%\?*}"
    printf '%s\n' "${tag#v}"
}

extract_json_string_field() {
    local json="$1"
    local key="$2"

    if command_exists jq; then
        printf '%s\n' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null | head -1
        return 0
    fi

    printf '%s\n' "$json" \
        | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | cut -d'"' -f4
}

# Get the default shell config file
get_shell_config() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")

    case "$shell_name" in
        zsh)
            if [[ -f "$HOME/.zshrc" ]]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.zprofile"
            fi
            ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# Determine install directory
get_install_dir() {
    if [[ -n "${DEST:-}" ]]; then
        echo "$DEST"
    elif [[ -n "${RU_SYSTEM:-}" ]] && [[ "$RU_SYSTEM" == "1" ]]; then
        echo "/usr/local/bin"
    else
        echo "$HOME/.local/bin"
    fi
}

# Check if directory is in PATH
in_path() {
    local dir="$1"
    [[ ":$PATH:" == *":$dir:"* ]]
}

# Get latest release version from GitHub
# Returns:
#   0 with version on stdout - success
#   1 - no releases exist (caller should fall back to main)
#   2 - API error (rate limit, network, etc.)
get_latest_release() {
    local url="$GITHUB_API/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    local response api_rc

    response=$(github_api_get "$url")
    api_rc=$?
    if [[ "$api_rc" -eq 2 ]]; then
        # No releases exist - caller should fall back to main.
        return 1
    fi
    if [[ "$api_rc" -ne 0 ]]; then
        # Try a non-API method before failing (avoids API rate limits / weird proxies).
        local redirect_version=""
        if redirect_version=$(get_latest_release_from_redirect); then
            log_warn "GitHub API unavailable; detected latest release via redirect."
            printf '%s\n' "$redirect_version"
            return 0
        else
            local redirect_rc=$?
            if [[ "$redirect_rc" -eq 1 ]]; then
                return 1
            fi

            local msg
            msg=$(extract_json_string_field "$response" "message")
            if [[ -n "$msg" ]]; then
                log_error "GitHub API error while fetching latest release: $msg"
            elif printf '%s\n' "$response" | grep -qi "rate limit"; then
                log_error "GitHub API rate limit exceeded while fetching latest release."
            else
                log_error "Failed to fetch latest release from GitHub."
            fi
            log_info "Tip: If you suspect caching, run: curl -fsSL \"$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/install.sh?ru_cb=$RU_CACHE_BUST_TOKEN\" | bash"
            return 2
        fi
    fi

    # Extract tag_name from JSON (simple approach for portability)
    local version=""
    if command_exists jq; then
        version=$(printf '%s\n' "$response" | jq -r '.tag_name // empty' 2>/dev/null | head -1)
    else
        version=$(printf '%s\n' "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    if [[ -z "$version" ]]; then
        # Unexpected response shape; try redirect method as a fallback.
        local redirect_version=""
        if redirect_version=$(get_latest_release_from_redirect); then
            log_warn "GitHub API returned unexpected payload; detected latest release via redirect."
            printf '%s\n' "$redirect_version"
            return 0
        fi

        local redirect_rc=$?
        if [[ "$redirect_rc" -eq 1 ]]; then
            return 1
        fi

        local msg
        msg=$(extract_json_string_field "$response" "message")
        if [[ -n "$msg" ]]; then
            log_error "Could not determine latest release version (GitHub API message: $msg)"
        else
            log_error "Could not parse version from GitHub API response"
        fi
        log_info "Tip: If you suspect caching, run: curl -fsSL \"$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/install.sh?ru_cb=$RU_CACHE_BUST_TOKEN\" | bash"
        return 2
    fi

    # Remove 'v' prefix if present
    printf '%s\n' "${version#v}"
}

# Download a file with cache-busting
# Adds a timestamp query parameter to bypass CDN/proxy caches
download_file() {
    local url="$1"
    local dest="$2"
    local final_url
    final_url=$(maybe_cache_bust_url "$url")

    if command_exists curl; then
        curl -fsSL "$final_url" -o "$dest"
    elif command_exists wget; then
        wget -q "$final_url" -O "$dest"
    else
        log_error "Neither curl nor wget found"
        return 1
    fi
}

# Verify SHA256 checksum
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual

    if command_exists sha256sum; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command_exists shasum; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        log_warn "No checksum tool found (sha256sum or shasum). Skipping verification."
        return 0
    fi

    if [[ "$actual" != "$expected" ]]; then
        log_error "Checksum verification failed!"
        log_error "Expected: $expected"
        log_error "Got:      $actual"
        return 1
    fi

    return 0
}

#==============================================================================
# INSTALLATION FUNCTIONS
#==============================================================================

# Install from GitHub Release (with checksum verification)
install_from_release() {
    local version="$1"
    local install_dir="$2"
    local temp_dir

    if ! temp_dir=$(mktemp_dir); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    RU_INSTALLER_TEMP_DIR="$temp_dir"
    trap cleanup_temp_dir EXIT

    local release_base="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v$version"
    local script_url="$release_base/$SCRIPT_NAME"
    local checksum_url="$release_base/checksums.txt"

    log_step "Downloading ru v$version from release..."
    if ! download_file "$script_url" "$temp_dir/$SCRIPT_NAME"; then
        log_error "Failed to download ru from release"
        return 1
    fi

    log_step "Downloading checksums..."
    if download_file "$checksum_url" "$temp_dir/checksums.txt"; then
        # Extract expected checksum for ru
        local expected_checksum
        expected_checksum=$(grep -E "^[a-f0-9]{64}[[:space:]]+\*?$SCRIPT_NAME$" "$temp_dir/checksums.txt" | cut -d' ' -f1)

        if [[ -n "$expected_checksum" ]]; then
            log_step "Verifying checksum..."
            if ! verify_checksum "$temp_dir/$SCRIPT_NAME" "$expected_checksum"; then
                return 1
            fi
            log_success "Checksum verified"
        else
            log_warn "No checksum found for $SCRIPT_NAME in checksums.txt"
        fi
    else
        log_warn "Could not download checksums.txt. Proceeding without verification."
    fi

    # Install
    install_script "$temp_dir/$SCRIPT_NAME" "$install_dir"
}

# Install from main branch (development only)
install_from_main() {
    local install_dir="$1"
    local temp_dir

    if ! temp_dir=$(mktemp_dir); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    RU_INSTALLER_TEMP_DIR="$temp_dir"
    trap cleanup_temp_dir EXIT

    log_warn "Installing from main branch. This is NOT RECOMMENDED for production use."
    log_warn "The main branch may contain untested or breaking changes."
    echo "" >&2

    local script_url="$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/$SCRIPT_NAME"

    log_step "Downloading ru from main branch..."
    if ! download_file "$script_url" "$temp_dir/$SCRIPT_NAME"; then
        log_error "Failed to download ru from main branch"
        return 1
    fi

    # No checksum verification for main branch
    install_script "$temp_dir/$SCRIPT_NAME" "$install_dir"
}

# Install the script to destination
install_script() {
    local source="$1"
    local install_dir="$2"
    local dest="$install_dir/$SCRIPT_NAME"

    # Create directory if needed
    if [[ ! -d "$install_dir" ]]; then
        log_step "Creating directory: $install_dir"
        if [[ "$install_dir" == "/usr/local/bin" ]]; then
            if ! command_exists sudo; then
                log_error "sudo is required to create $install_dir"
                return 1
            fi
            if ! sudo mkdir -p "$install_dir"; then
                log_error "Failed to create directory: $install_dir"
                return 1
            fi
        else
            if ! mkdir -p "$install_dir"; then
                log_error "Failed to create directory: $install_dir"
                return 1
            fi
        fi
    fi

    # Install with proper permissions
    log_step "Installing to $dest"
    if [[ "$install_dir" == "/usr/local/bin" ]]; then
        if ! command_exists sudo; then
            log_error "sudo is required to install to $install_dir"
            return 1
        fi
        if ! sudo cp "$source" "$dest"; then
            log_error "Failed to install: $dest"
            return 1
        fi
        if ! sudo chmod +x "$dest"; then
            log_error "Failed to make executable: $dest"
            return 1
        fi
    else
        if ! cp "$source" "$dest"; then
            log_error "Failed to install: $dest"
            return 1
        fi
        if ! chmod +x "$dest"; then
            log_error "Failed to make executable: $dest"
            return 1
        fi
    fi

    log_success "Installed ru to $dest"
}

# Add directory to PATH in shell config
add_to_path() {
    local dir="$1"
    local shell_config
    shell_config=$(get_shell_config)
    local shell_config_dir
    shell_config_dir=$(dirname "$shell_config")
    if [[ -n "$shell_config_dir" && ! -d "$shell_config_dir" ]]; then
        mkdir -p "$shell_config_dir" 2>/dev/null || true
    fi

    # Check if already configured
    if grep -q "export PATH=.*$dir" "$shell_config" 2>/dev/null; then
        log_info "$dir already in $shell_config"
        return 0
    fi

    log_step "Adding $dir to PATH in $shell_config"

    # Add to shell config
    {
        printf '\n'
        printf '%s\n' "# Added by ru installer"
        printf '%s\n' "export PATH=\"$dir:\$PATH\""
    } >> "$shell_config"

    log_success "Added to $shell_config"
    log_info "Run 'source $shell_config' or start a new shell to update PATH"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    printf '\n' >&2
    printf '%b\n' "${BOLD}ru Installer${RESET}" >&2
    printf '%s\n' "────────────────────" >&2
    printf '\n' >&2

    # Determine install directory
    local install_dir
    install_dir=$(get_install_dir)

    # Check for required tools
    if ! command_exists curl && ! command_exists wget; then
        log_error "Either curl or wget is required. Please install one and try again."
        exit 1
    fi

    # Determine version and installation source
    if [[ -n "${RU_UNSAFE_MAIN:-}" ]] && [[ "$RU_UNSAFE_MAIN" == "1" ]]; then
        # Install from main branch (explicit request)
        log_info "Installing from main branch (RU_UNSAFE_MAIN=1)"
        install_from_main "$install_dir" || exit 1
    else
        # Install from release
        local version
        local get_release_exit=0
        if [[ -n "${RU_VERSION:-}" ]]; then
            version="$RU_VERSION"
            log_info "Installing version: $version"
            install_from_release "$version" "$install_dir" || exit 1
        else
            log_step "Fetching latest release version..."
            version=$(get_latest_release) || get_release_exit=$?

            case $get_release_exit in
                0)
                    log_info "Latest version: $version"
                    ;;
                1)
                    # No releases exist - fall back to main branch with warning
                    log_warn "No releases found for this repository."
                    log_warn "Falling back to installation from main branch."
                    log_warn "This is equivalent to RU_UNSAFE_MAIN=1."
                    log_info "Tip: If you suspect caching, run: curl -fsSL \"$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/install.sh?ru_cb=$RU_CACHE_BUST_TOKEN\" | bash"
                    printf '\n' >&2
                    install_from_main "$install_dir" || exit 1
                    version=""  # Skip release installation below
                    ;;
                *)
                    # API error - already logged by get_latest_release
                    exit 1
                    ;;
            esac
        fi

        # Install from release (if we have a version)
        if [[ -n "$version" ]]; then
            install_from_release "$version" "$install_dir" || exit 1
        fi
    fi

    # Check PATH and offer to add if needed
    if ! in_path "$install_dir"; then
        log_warn "$install_dir is not in your PATH"

        # Check if we can prompt
        if [[ -t 0 ]]; then
            printf '\n' >&2
            read -rp "Add $install_dir to PATH? [y/N] " response
            case "$response" in
                [yY]|[yY][eE][sS])
                    add_to_path "$install_dir"
                    ;;
                *)
                    log_info "Skipped adding to PATH"
                    log_info "You can manually add it with:"
                    log_info "  export PATH=\"$install_dir:\$PATH\""
                    ;;
            esac
        else
            log_info "Add it to your PATH with:"
            log_info "  export PATH=\"$install_dir:\$PATH\""
        fi
    fi

    # Verify installation
    printf '\n' >&2
    local installed_path="$install_dir/$SCRIPT_NAME"
    if [[ -x "$installed_path" ]]; then
        log_success "Installation complete!"
        printf '\n' >&2

        if in_path "$install_dir" || [[ -n "${RU_UNSAFE_MAIN:-}" ]]; then
            log_info "Get started with:"
            log_info "  ru --help        Show all commands"
            log_info "  ru init          Initialize configuration"
            log_info "  ru add owner/repo  Add a repository"
            log_info "  ru sync          Sync all repositories"
        else
            log_info "Get started with:"
            log_info "  $installed_path --help"
        fi

        printf '\n' >&2
        log_info "Documentation: https://github.com/$REPO_OWNER/$REPO_NAME"
    else
        log_error "Installation may have failed. Check the output above."
        exit 1
    fi
}

main "$@"
