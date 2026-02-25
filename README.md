# ShotCli

ShotCli is a non-interactive screenshot tool for macOS. It provides a GUI for permission onboarding and command setup, and a `shot` CLI for automation, scripting, and CI workflows.

## Key Features

- Non-interactive capture (no mouse selection UI required)
- Display/window enumeration before capture
- Structured JSON output with stable exit codes
- Local XPC architecture (`shot` -> `ShotCliXPCService`)

## Architecture

- `ShotCli.app`: main app for permission onboarding and CLI command installation
- `shot`: CLI entrypoint (`ShotCli.app/Contents/MacOS/shot`)
- `ShotCliXPCService.xpc`: embedded XPC service for `doctor/displays/windows/capture`
- `ShotCliCore`: shared CLI engine and XPC protocol

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

Screen Recording permission is required for capture and window enumeration.

- Click `Request Permission` in `ShotCli.app`
- Enable access for ShotCli in System Settings
- If missing, related commands return exit code `11`

## Common Exit Codes

- `0`: success
- `10`: service unavailable
- `11`: missing Screen Recording permission
- `14`: capture/enumeration failure
- `15`: output write failure

## Verification & Troubleshooting

See:

- `docs/xpc-verification.md`

Quick validation script:

```bash
scripts/verify-xpc-flow.sh --display-name "LG ULTRAFINE"
```

## Repository Layout

- `ShotCli/`: main app (SwiftUI UI, IPC client)
- `ShotCliCore/`: shared CLI engine and protocol
- `ShotCliXPCService/`: XPC service entrypoint
- `scripts/`: helper scripts
- `docs/`: design and verification docs

## License

No license file is currently declared in this repository. All rights reserved by default.
