#!/usr/bin/env bash

set -euo pipefail

# Cursor flake updater: IDE (AppImage) and Agent CLI (lab tarball).
#
# Default: check upstream and refresh whichever pins are stale. CI runs this
# with no arguments; behavior is identical to a local no-arg invocation.
#
# Exit codes are part of the CLI contract:
#   0  no changes required (pins already current) or dry run with no pending update
#   1  hard error (network, parsing, sed, flake check, missing dependency)
#   2  user cancelled at the confirmation prompt (non-CI only)
#   3  dry run found at least one pending update (so CI can branch on it)
#
# Usage: ./update-cursor.sh [options] [IDE-VERSION]
# See --help.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_FILE="$SCRIPT_DIR/flake.nix"
AGENT_VERSIONS_FILE="$SCRIPT_DIR/cursor-agent-versions.nix"

# Exit codes (see header)
readonly EX_OK=0
readonly EX_ERR=1
readonly EX_CANCEL=2
readonly EX_DRY_PENDING=3

# Shared curl hardening: bounded time, retries with backoff, fail on HTTP >= 400.
# -sS keeps progress silent but surfaces errors.
CURL_OPTS=(--silent --show-error --fail --location --max-time 30 --retry 3 --retry-delay 2)
CURL_HEAD_OPTS=(--silent --show-error --location --max-time 30 --retry 3 --retry-delay 2)

print_help() {
    cat <<'EOF'
Usage: update-cursor.sh [options] [IDE-VERSION]

Checks upstream for newer Cursor IDE and Cursor Agent CLI builds and edits the
flake pins in place (flake.nix, cursor-agent-versions.nix), then runs
`nix flake check`.

By default, both pins are considered. The positional IDE-VERSION argument
constrains the IDE target only (the agent is still refreshed unless you pass
--ide-only).

Options:
  --ide-only            Only consider the IDE pin; leave the agent alone.
  --agent-only          Only consider the agent pin; leave the IDE alone.
  --dry-run             Report pending updates without editing files.
                        Exits 0 when nothing is pending, 3 when at least one
                        pin would change.
  -h, --help            Show this help and exit.

Arguments:
  IDE-VERSION           Optional IDE version to pin. Accepts either a full
                        "X.Y.Z" version or a minor "X.Y" (resolved to the
                        latest patch for that line via the Cursor API).
                        Ignored together with --agent-only.

Exit codes:
  0  no changes required
  1  hard error
  2  user cancelled at the prompt
  3  dry-run found at least one pending update

Environment:
  CI, GITHUB_ACTIONS    When set (non-empty), the confirmation prompt is
                        auto-answered "y".
  GITHUB_OUTPUT         When set, the script appends
                            cursor_updates=none|ide|agent|both
                        after a run. Use this from the CI workflow.
EOF
}

log() { echo "$@"; }
err() { echo "$@" >&2; }

# ---- Upstream lookups --------------------------------------------------------

# Extract semver from a resolved download URL like
# https://downloads.cursor.com/.../Cursor-2.6.22-x86_64.AppImage
extract_version_from_url() {
    local url="$1"
    local version
    version=$(echo "$url" | grep -oP 'Cursor-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    err "Error: Could not extract version from URL: $url"
    return 1
}

# Map Nix system → Cursor API arch segment.
api_arch_for() {
    case "$1" in
        x86_64-linux)  echo "linux-x64" ;;
        aarch64-linux) echo "linux-arm64" ;;
        *) err "Error: unsupported system '$1'"; return 1 ;;
    esac
}

# Return the resolved download URL for a given IDE version ("latest" or "X.Y" or "X.Y.Z") + arch.
get_download_info() {
    local version="$1"
    local arch="$2"
    local api_arch
    api_arch=$(api_arch_for "$arch") || return 1

    local api_url="https://api2.cursor.sh/updates/download/golden/$api_arch/cursor/$version"
    local actual_url
    actual_url=$(curl "${CURL_HEAD_OPTS[@]}" -I "$api_url" | grep -i '^location:' | cut -d' ' -f2- | tr -d '\r\n') || true

    if [[ -z "$actual_url" ]]; then
        err "Error: Could not resolve download URL for $arch (version=$version)"
        return 1
    fi
    echo "$actual_url"
}

get_version_from_url() {
    local version="$1"
    local arch="$2"
    local actual_url
    actual_url=$(get_download_info "$version" "$arch") || return 1
    extract_version_from_url "$actual_url"
}

# Single-source-of-truth "latest IDE version" via the Cursor update API.
# This is the same endpoint the installer uses, so it avoids scraping the
# marketing HTML at cursor.com/download.
get_latest_ide_version() {
    get_version_from_url "latest" "x86_64-linux"
}

# Parse the agent lab build id from the official installer script.
get_latest_agent_lab_version() {
    local install_script
    install_script=$(curl "${CURL_OPTS[@]}" "https://cursor.com/install") || {
        err "Error: failed to download https://cursor.com/install"
        return 1
    }
    local lab
    lab=$(echo "$install_script" | grep -oE 'downloads\.cursor\.com/lab/[^/[:space:]"]+' | head -1 | cut -d/ -f3)
    if [[ -z "$lab" ]]; then
        err "Error: could not parse agent lab version from install script"
        return 1
    fi
    echo "$lab"
}

# ---- Current pins ------------------------------------------------------------

get_current_ide_version() {
    grep -o 'version = "[^"]*"' "$FLAKE_FILE" | head -1 | cut -d'"' -f2
}

get_current_agent_lab_version() {
    if [[ ! -f "$AGENT_VERSIONS_FILE" ]]; then
        err "Error: $AGENT_VERSIONS_FILE not found"
        return 1
    fi
    grep -o 'labVersion = "[^"]*"' "$AGENT_VERSIONS_FILE" | head -1 | cut -d'"' -f2
}

normalize_version() {
    echo "$1" | grep -oP '^\K[0-9]+\.[0-9]+'
}

versions_equal() {
    [[ "$1" == "$2" ]]
}

# ---- Backup / restore --------------------------------------------------------

snapshot_flake_files() {
    cp "$FLAKE_FILE" "$FLAKE_FILE.backup"
    cp "$AGENT_VERSIONS_FILE" "$AGENT_VERSIONS_FILE.backup"
}

restore_flake_files() {
    [[ -f "$FLAKE_FILE.backup"          ]] && cp "$FLAKE_FILE.backup"          "$FLAKE_FILE"
    [[ -f "$AGENT_VERSIONS_FILE.backup" ]] && cp "$AGENT_VERSIONS_FILE.backup" "$AGENT_VERSIONS_FILE"
    return 0
}

clear_flake_backups() {
    rm -f "$FLAKE_FILE.backup" "$AGENT_VERSIONS_FILE.backup"
}

# Fail loudly if a sed range anchor matches more than once in the target file:
# our structural assumptions are that `flake.nix` has exactly one IDE sources
# block and `cursor-agent-versions.nix` has exactly one agent sources block.
assert_single_match() {
    local file="$1"
    local pattern="$2"
    local expected_count="${3:-1}"
    local n
    n=$(grep -cE "$pattern" "$file" || true)
    if [[ "$n" -ne "$expected_count" ]]; then
        err "Error: expected $expected_count match(es) for /$pattern/ in $file, found $n"
        return 1
    fi
}

escape_sed() {
    printf '%s\n' "$1" | sed -e 's/[\/&]/\\&/g'
}

# ---- Edits -------------------------------------------------------------------

update_agent_versions() {
    local lab="$1"
    local x64_url arm64_url x64_sha256 arm64_sha256
    x64_url="https://downloads.cursor.com/lab/${lab}/linux/x64/agent-cli-package.tar.gz"
    arm64_url="https://downloads.cursor.com/lab/${lab}/linux/arm64/agent-cli-package.tar.gz"

    log "Fetching SHA256 for agent CLI (x86_64)..."
    x64_sha256=$(nix-prefetch-url --type sha256 "$x64_url") || {
        err "Error: nix-prefetch-url failed for agent x86_64 tarball"
        return 1
    }
    log "Fetching SHA256 for agent CLI (aarch64)..."
    arm64_sha256=$(nix-prefetch-url --type sha256 "$arm64_url") || {
        err "Error: nix-prefetch-url failed for agent aarch64 tarball"
        return 1
    }

    # Structural guards: each arch attrset appears exactly once in the file.
    assert_single_match "$AGENT_VERSIONS_FILE" '^[[:space:]]*x86_64-linux = \{'  || return 1
    assert_single_match "$AGENT_VERSIONS_FILE" '^[[:space:]]*aarch64-linux = \{' || return 1

    local x64_url_escaped arm64_url_escaped
    x64_url_escaped=$(escape_sed "$x64_url")
    arm64_url_escaped=$(escape_sed "$arm64_url")

    if ! sed -i "s/^\([[:space:]]*labVersion = \)\"[^\"]*\";/\1\"$lab\";/" "$AGENT_VERSIONS_FILE"; then
        err "Error: Failed to update agent labVersion"; return 1
    fi
    if ! sed -i "/^[[:space:]]*x86_64-linux = {/,/^[[:space:]]*};/s|url = \"[^\"]*\";|url = \"$x64_url_escaped\";|" "$AGENT_VERSIONS_FILE"; then
        err "Error: Failed to update agent x86_64 URL"; return 1
    fi
    if ! sed -i "/^[[:space:]]*x86_64-linux = {/,/^[[:space:]]*};/s/sha256 = \"[^\"]*\";/sha256 = \"$x64_sha256\";/" "$AGENT_VERSIONS_FILE"; then
        err "Error: Failed to update agent x86_64 sha256"; return 1
    fi
    if ! sed -i "/^[[:space:]]*aarch64-linux = {/,/^[[:space:]]*};/s|url = \"[^\"]*\";|url = \"$arm64_url_escaped\";|" "$AGENT_VERSIONS_FILE"; then
        err "Error: Failed to update agent aarch64 URL"; return 1
    fi
    if ! sed -i "/^[[:space:]]*aarch64-linux = {/,/^[[:space:]]*};/s/sha256 = \"[^\"]*\";/sha256 = \"$arm64_sha256\";/" "$AGENT_VERSIONS_FILE"; then
        err "Error: Failed to update agent aarch64 sha256"; return 1
    fi

    grep -q "labVersion = \"$lab\"" "$AGENT_VERSIONS_FILE" || { err "Error: agent labVersion verification failed"; return 1; }
    grep -q "$x64_sha256"            "$AGENT_VERSIONS_FILE" || { err "Error: agent x86_64 sha256 verification failed"; return 1; }
    grep -q "$arm64_sha256"          "$AGENT_VERSIONS_FILE" || { err "Error: agent aarch64 sha256 verification failed"; return 1; }

    log "Updated $AGENT_VERSIONS_FILE with agent lab version $lab"
}

# Update IDE fields in flake.nix. The caller has already snapshotted for rollback.
update_flake_ide() {
    local version="$1"

    log "Fetching download URLs for IDE version $version..."

    # Resolve per-arch URLs and versions in a single pass.
    local x64_url arm64_url resolved_x64 resolved_arm64 actual_version
    x64_url=$(get_download_info   "$version" "x86_64-linux")  || { err "Failed to get x86_64 URL";   return 1; }
    arm64_url=$(get_download_info "$version" "aarch64-linux") || { err "Failed to get aarch64 URL"; return 1; }
    resolved_x64=$(extract_version_from_url "$x64_url")       || return 1
    resolved_arm64=$(extract_version_from_url "$arm64_url")   || return 1

    if [[ "$resolved_x64" != "$resolved_arm64" ]]; then
        err "Warning: IDE version mismatch between arches (x86_64=$resolved_x64, aarch64=$resolved_arm64); using x86_64"
    fi
    actual_version="$resolved_x64"

    log "Resolved IDE version: $actual_version"
    log "x86_64 URL: $x64_url"
    log "aarch64 URL: $arm64_url"

    if ! command -v nix-prefetch-url >/dev/null 2>&1; then
        err "Error: nix-prefetch-url not found"; return 1
    fi
    local x64_sha256 arm64_sha256
    log "Fetching SHA256 for x86_64 AppImage..."
    x64_sha256=$(nix-prefetch-url --type sha256 "$x64_url")   || { err "Failed to fetch x86_64 hash"; return 1; }
    log "Fetching SHA256 for aarch64 AppImage..."
    arm64_sha256=$(nix-prefetch-url --type sha256 "$arm64_url") || { err "Failed to fetch aarch64 hash"; return 1; }

    log "x86_64 SHA256: $x64_sha256"
    log "aarch64 SHA256: $arm64_sha256"

    # Structural guards: each arch attrset appears exactly once in flake.nix
    # (the only current matches are inside the `sources` block).
    assert_single_match "$FLAKE_FILE" '^[[:space:]]*x86_64-linux = \{'  || return 1
    assert_single_match "$FLAKE_FILE" '^[[:space:]]*aarch64-linux = \{' || return 1

    local x64_url_escaped arm64_url_escaped
    x64_url_escaped=$(escape_sed "$x64_url")
    arm64_url_escaped=$(escape_sed "$arm64_url")

    # Update version (first occurrence only, in the let block) using resolved version
    if ! sed -i "0,/^\([[:space:]]*version = \)\"[^\"]*\";/{s//\1\"$actual_version\";/}" "$FLAKE_FILE"; then
        err "Error: Failed to update IDE version"; return 1
    fi
    # Update x86_64-linux URL (IDE sources block in flake.nix)
    if ! sed -i "/^[[:space:]]*x86_64-linux = {/,/^[[:space:]]*};/s|url = \"[^\"]*\";|url = \"$x64_url_escaped\";|" "$FLAKE_FILE"; then
        err "Error: Failed to update IDE x86_64 URL"; return 1
    fi
    # Update x86_64-linux SHA256
    if ! sed -i "/^[[:space:]]*x86_64-linux = {/,/^[[:space:]]*};/s/sha256 = \"[^\"]*\";/sha256 = \"$x64_sha256\";/" "$FLAKE_FILE"; then
        err "Error: Failed to update IDE x86_64 sha256"; return 1
    fi
    # Update aarch64-linux URL
    if ! sed -i "/^[[:space:]]*aarch64-linux = {/,/^[[:space:]]*};/s|url = \"[^\"]*\";|url = \"$arm64_url_escaped\";|" "$FLAKE_FILE"; then
        err "Error: Failed to update IDE aarch64 URL"; return 1
    fi
    # Update aarch64-linux SHA256
    if ! sed -i "/^[[:space:]]*aarch64-linux = {/,/^[[:space:]]*};/s/sha256 = \"[^\"]*\";/sha256 = \"$arm64_sha256\";/" "$FLAKE_FILE"; then
        err "Error: Failed to update IDE aarch64 sha256"; return 1
    fi

    # Verify the updates were applied
    grep -q "version = \"$actual_version\"" "$FLAKE_FILE" || { err "Error: IDE version update verification failed";         return 1; }
    grep -q "$x64_sha256"                     "$FLAKE_FILE" || { err "Error: IDE x86_64 sha256 update verification failed";   return 1; }
    grep -q "$arm64_sha256"                   "$FLAKE_FILE" || { err "Error: IDE aarch64 sha256 update verification failed"; return 1; }

    log "Updated flake.nix with IDE version $actual_version"
}

test_flake() {
    log "Testing flake..."
    if ! command -v nix >/dev/null 2>&1; then
        log "Warning: nix command not found. Skipping flake check."
        return 0
    fi
    if ! nix flake check; then
        err "Error: Flake check failed"
        return 1
    fi
    log "Flake check passed!"
}

write_github_output() {
    local kind="$1"
    [[ -z "${GITHUB_OUTPUT:-}" ]] && return 0
    echo "cursor_updates=$kind" >> "$GITHUB_OUTPUT"
}

# ---- Main --------------------------------------------------------------------

usage_error() {
    err "$@"
    err "See --help."
    exit "$EX_ERR"
}

main() {
    local ide_only=0
    local agent_only=0
    local dry_run=0
    local ide_target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ide-only)   ide_only=1;   shift ;;
            --agent-only) agent_only=1; shift ;;
            --dry-run)    dry_run=1;    shift ;;
            -h|--help)    print_help;   exit "$EX_OK" ;;
            --)           shift; break ;;
            -*)           usage_error "Unknown option: $1" ;;
            *)
                if [[ -n "$ide_target" ]]; then
                    usage_error "Unexpected extra argument: $1"
                fi
                ide_target="$1"; shift
                ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        if [[ -n "$ide_target" ]]; then
            usage_error "Unexpected extra argument: $1"
        fi
        ide_target="$1"
    fi

    if (( ide_only && agent_only )); then
        usage_error "--ide-only and --agent-only are mutually exclusive"
    fi
    if (( agent_only )) && [[ -n "$ide_target" ]]; then
        usage_error "IDE-VERSION is not allowed with --agent-only"
    fi
    if [[ -n "$ide_target" ]] && [[ ! "$ide_target" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        usage_error "IDE-VERSION must match 'X.Y' or 'X.Y.Z' (got: $ide_target)"
    fi

    log "Cursor flake updater (IDE + Agent)"
    log "===================================="
    if (( dry_run ));    then log "Mode: dry run (no files will be modified)"; fi
    if (( ide_only ));   then log "Scope: IDE only";   fi
    if (( agent_only )); then log "Scope: agent only"; fi

    # --- IDE pin resolution ---------------------------------------------------
    local current_ide resolved_ide=""
    current_ide=$(get_current_ide_version)
    log "Current IDE version: $current_ide"

    if (( ! agent_only )); then
        if [[ -n "$ide_target" ]]; then
            log "IDE target argument: $ide_target"
            if [[ "$ide_target" =~ ^[0-9]+\.[0-9]+$ ]]; then
                log "Minor IDE version specified, resolving to latest patch via the Cursor API..."
                resolved_ide=$(get_version_from_url "$ide_target" "x86_64-linux") \
                    || { err "Failed to resolve IDE version"; exit "$EX_ERR"; }
                log "Resolved IDE version: $resolved_ide"
            else
                resolved_ide="$ide_target"
            fi
        else
            log "Fetching latest IDE version..."
            resolved_ide=$(get_latest_ide_version) \
                || { err "Failed to get latest IDE version"; exit "$EX_ERR"; }
            log "Latest IDE version: $resolved_ide"
        fi
    fi

    # --- Agent pin resolution -------------------------------------------------
    local current_agent="" latest_agent=""
    current_agent=$(get_current_agent_lab_version) || exit "$EX_ERR"
    log "Current agent lab version: $current_agent"
    if (( ! ide_only )); then
        latest_agent=$(get_latest_agent_lab_version) || exit "$EX_ERR"
        log "Latest agent lab version:  $latest_agent"
    fi

    # --- Decide what changes --------------------------------------------------
    local ide_changed=0 agent_changed=0
    if (( ! agent_only )) && ! versions_equal "$resolved_ide" "$current_ide"; then
        ide_changed=1
    fi
    if (( ! ide_only )) && ! versions_equal "$latest_agent" "$current_agent"; then
        agent_changed=1
    fi

    local ci_kind="none"
    if   (( ide_changed && agent_changed )); then ci_kind="both"
    elif (( ide_changed ));                  then ci_kind="ide"
    elif (( agent_changed ));                then ci_kind="agent"
    fi

    if (( ide_changed == 0 && agent_changed == 0 )); then
        log "No updates needed."
        write_github_output "none"
        exit "$EX_OK"
    fi

    log "Pending updates — IDE: $([[ $ide_changed -eq 1 ]] && echo yes || echo no), agent: $([[ $agent_changed -eq 1 ]] && echo yes || echo no)"

    if (( dry_run )); then
        # Do NOT write cursor_updates= in dry-run: CI branches on exit code, not output.
        exit "$EX_DRY_PENDING"
    fi

    # Confirmation (non-CI only). If stdin is not a TTY we treat it as a cancel
    # rather than hanging or dying under `set -e` on a failed `read`.
    if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log "Running in CI mode, auto-confirming update..."
    else
        if [[ ! -t 0 ]]; then
            err "Error: no TTY available for confirmation (use CI=1 to auto-confirm, or --dry-run to inspect)"
            exit "$EX_CANCEL"
        fi
        local answer=""
        read -r -p "Proceed with the update? (y/N): " -n 1 answer || answer=""
        echo
        if [[ ! $answer =~ ^[Yy]$ ]]; then
            log "Update cancelled."
            exit "$EX_CANCEL"
        fi
    fi

    snapshot_flake_files

    # --- Apply edits ----------------------------------------------------------
    if (( ide_changed )); then
        # Pass the original target shape to update_flake_ide: a major.minor pin
        # is cheaper (resolves once) than a full X.Y.Z that bypasses the `latest`
        # redirect.
        local ide_update_version="$resolved_ide"
        if [[ -z "$ide_target" ]]; then
            ide_update_version=$(normalize_version "$resolved_ide")
        elif [[ "$ide_target" =~ ^[0-9]+\.[0-9]+$ ]]; then
            ide_update_version="$ide_target"
        fi
        if ! update_flake_ide "$ide_update_version"; then
            err "Error: IDE update failed"
            restore_flake_files
            exit "$EX_ERR"
        fi
    fi

    if (( agent_changed )); then
        if ! update_agent_versions "$latest_agent"; then
            err "Error: agent update failed"
            restore_flake_files
            exit "$EX_ERR"
        fi
    fi

    if ! test_flake; then
        err "Error: post-update validation failed"
        restore_flake_files
        exit "$EX_ERR"
    fi

    clear_flake_backups
    write_github_output "$ci_kind"

    log "Update completed successfully!"
    log "You can now commit the changes:"
    log "  git add flake.nix cursor-agent-versions.nix"
    log "  git commit -m \"Update Cursor (scope: $ci_kind)\""
}

check_dependencies() {
    local missing_deps=()
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v sed  >/dev/null 2>&1 || missing_deps+=("sed")
    command -v grep >/dev/null 2>&1 || missing_deps+=("grep")
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        err "Error: Missing required dependencies: ${missing_deps[*]}"
        exit "$EX_ERR"
    fi
}

check_dependencies
main "$@"
