# AGENTS.md

## Project Overview

This is a Nix flake that packages the Cursor IDE (AppImage) and the Cursor Agent CLI (official lab tarball, FHS-wrapped) for NixOS. It supports both `x86_64-linux` and `aarch64-linux` architectures.

## File Structure

- `flake.nix` - Main Nix flake definition with Cursor IDE and agent packages
- `cursor-agent-versions.nix` - Pinned lab version, URLs, and hashes for the agent CLI (updated by the script / CI)
- `cursor-agent.nix` - Build of the agent tarball using `buildFHSEnv`
- `update-cursor.sh` - Script to update the IDE and/or agent to new upstream versions (used in CI)

## Key Conventions

- **Default updater behavior:** `./update-cursor.sh` with no arguments (including in GitHub Actions) checks **both** the IDE AppImage pins and the agent lab tarball pins, and edits whichever are behind upstream.
- **Never delete comments** in any file
- When editing `flake.nix`, use sed/awk to modify specific lines - never rewrite the entire file
- The update script runs in CI pipelines, so all errors must exit early with non-zero codes

## Flake Structure

The `flake.nix` has these editable fields for **IDE** version updates:
- `version = "X.Y.Z";` - The Cursor IDE version string
- `sources.x86_64-linux.url` - Download URL for x86_64 AppImage
- `sources.x86_64-linux.sha256` - Hash for x86_64 AppImage
- `sources.aarch64-linux.url` - Download URL for aarch64 AppImage
- `sources.aarch64-linux.sha256` - Hash for aarch64 AppImage

The `cursor-agent-versions.nix` file pins the **agent CLI** (lab build id, not the same as IDE semver):
- `labVersion = "YYYY.MM.DD-…";` - Lab build string from `https://cursor.com/install`
- `sources.<system>.url` / `sha256` - Per-arch tarball at `downloads.cursor.com/lab/.../agent-cli-package.tar.gz`

## Cursor Download URL Pattern

The Cursor API uses this pattern:
```
https://api2.cursor.sh/updates/download/golden/{arch}/cursor/{version}
```

Where:
- `{arch}` is `linux-x64` or `linux-arm64`
- `{version}` is the version number or `latest`

This redirects to the actual download URL at `downloads.cursor.com`.

## Cursor Agent CLI URL Pattern

The official install script (`https://cursor.com/install`) downloads:
```
https://downloads.cursor.com/lab/{labVersion}/linux/{x64|arm64}/agent-cli-package.tar.gz
```

The script parses `{labVersion}` from that installer to discover the latest agent build.

## Commands

| Task | Command |
|------|---------|
| Check flake validity | `nix flake check` |
| Build Cursor IDE | `nix build .#cursor` |
| Build Cursor Agent CLI | `nix build .#cursor-agent` |
| Run IDE | `nix run .#cursor` |
| Run agent | `nix run .#cursor-agent` |
| Update IDE and agent to latest (default; same as CI) | `./update-cursor.sh` |
| Pin IDE only (agent still bumped) | `./update-cursor.sh 2.3.21` |
| Only touch the IDE pin | `./update-cursor.sh --ide-only` |
| Only touch the agent pin | `./update-cursor.sh --agent-only` |
| Check what would change without editing files | `./update-cursor.sh --dry-run` |
| Show script help | `./update-cursor.sh --help` |
| Get SHA256 hash | `nix-prefetch-url --type sha256 <url>` |

## Updater CLI contract

Exit codes (stable across releases):

| Code | Meaning |
|------|---------|
| `0`  | No updates required (or `--dry-run` with nothing pending) |
| `1`  | Hard error (network, parsing, sed, `nix flake check`, missing dep) |
| `2`  | User answered `N` at the confirmation prompt (non-CI only) |
| `3`  | `--dry-run` found at least one pending update |

Flags: `--ide-only`, `--agent-only`, `--dry-run`, `-h`/`--help`. `--ide-only` and `--agent-only` are mutually exclusive; `--agent-only` forbids a positional IDE version. A positional IDE version must be `X.Y` or `X.Y.Z` and is validated up front.

## Update Process

1. **IDE:** Get the actual AppImage download URL by following the API redirect; prefetch hashes for x86_64 and aarch64.
2. **Agent:** Read the lab version from `https://cursor.com/install`; prefetch hashes for both architectures’ `agent-cli-package.tar.gz` URLs.
3. Edit `flake.nix` (IDE) and `cursor-agent-versions.nix` (agent) using **sed** as implemented in `update-cursor.sh`.
4. Run `nix flake check` to verify.
5. If any step fails, restore from backup (`.backup` files next to the edited files) and exit with error.

## CI Environment Variables

The update script respects:
- `CI` or `GITHUB_ACTIONS` - Auto-confirms updates when set
- `GITHUB_OUTPUT` - Appends `cursor_updates=none|ide|agent|both`. The GitHub Actions workflow reads this value directly (via `steps.update.outputs.cursor_updates`) to decide whether to run `nix flake update`, `nix flake check`, and to build the commit message.

