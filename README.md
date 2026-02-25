# ShotCli

ShotCli is a non-interactive screenshot tool for macOS. It is now **CLI-first and pure CLI**: `shot` commands run in-process with no XPC forwarding.

## Key Features

- Non-interactive capture (no mouse selection UI required)
- Display/window enumeration before capture
- Structured JSON output with stable exit codes
- Pure CLI execution path (`shot` runs in-process)

## Architecture

- `ShotCli.app`: optional GUI for command installation and permission onboarding
- `shot`: CLI entrypoint (`ShotCli.app/Contents/MacOS/shot`)
- `ShotCliCore`: shared CLI engine

## Requirements

- macOS 14+
- Xcode 26+

## Quick Start

### 1. Build

```bash
xcodebuild -project ShotCli.xcodeproj -scheme ShotCli -configuration Debug -destination 'platform=macOS' build
```

### 2. Install / Launch the App

Install `ShotCli.app` (recommended: `/Applications`) and open it once.

### 3. Install `shot` Command

Recommended via GUI:

- Open `ShotCli.app`
- In the `CLI Command (shot)` card, click:
  - `Install to ~/.local/bin` (recommended, no admin privileges required)
  - or `Install to /usr/local/bin` (prompts for admin authentication)

Script-based option:

```bash
scripts/install-shot-link.sh --app /Applications/ShotCli.app
```

### 4. Verify

```bash
shot version
shot doctor --pretty
```

## Command Examples

```bash
shot displays --pretty
shot windows --pretty
shot capture --display 4 --out ~/Downloads/lg-ultrafine.png --pretty
```

## Permissions

Screen Recording permission is required for `shot windows` and `shot capture`.

- Grant Screen Recording to your **terminal host app** (`Terminal`/`iTerm`) in:
  - `System Settings > Privacy & Security > Screen Recording`
- You can use:
  - `shot open-permissions`
  - `shot request-permission`
- If missing, related commands return exit code `11`.

## Common Exit Codes

- `0`: success
- `10`: unavailable helper action (for example, failed to open System Settings)
- `11`: missing Screen Recording permission
- `14`: capture/enumeration failure
- `15`: output write failure

## Verification & Troubleshooting

See:

- `docs/pure-cli-verification.md`

Quick validation script:

```bash
scripts/verify-cli-flow.sh --display-name "LG ULTRAFINE"
```

## Repository Layout

- `ShotCli/`: main app (SwiftUI UI + CLI entrypoint)
- `ShotCliCore/`: shared CLI engine
- `scripts/`: helper scripts
- `docs/`: design and verification docs

## License

No license file is currently declared in this repository. All rights reserved by default.
