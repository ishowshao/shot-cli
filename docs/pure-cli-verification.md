# Pure CLI Verification Guide

This document verifies the current architecture is pure CLI (`shot` runs in-process and does not depend on XPC).

## 0. Prerequisites

- `ShotCli.app` installed (recommended: `/Applications/ShotCli.app`) or local Debug build.
- `shot` command installed in your PATH.
- If not installed yet:
  - open `ShotCli.app`
  - click `Install to ~/.local/bin` in the `CLI Command (shot)` card
  - reopen terminal and run `shot version`

## 1. Quick Automated Check

Run:

```bash
scripts/verify-cli-flow.sh
```

Optional:

```bash
scripts/verify-cli-flow.sh --display-id 4 --out ~/Downloads/lg-test.png
scripts/verify-cli-flow.sh --display-name "LG ULTRAFINE"
```

Expected:

- `doctor_exit=11` when Screen Recording is missing.
- `doctor_exit=0` when Screen Recording is granted.
- `displays_exit=0`.
- `capture_exit=11` when permission is missing.
- `capture_exit=0` and output file exists when permission is granted.

## 2. Manual Validation

```bash
shot doctor --pretty
shot displays --pretty
shot windows --pretty
shot capture --display <displayId> --out ~/Downloads/test.png --pretty
```

Expected:

- `doctor`:
  - missing permission -> exit `11`
  - granted permission -> exit `0`
- `windows`:
  - missing permission -> exit `11`
- `capture`:
  - missing permission -> exit `11`
  - granted permission -> exit `0`

## 3. Permission Checks

The permission subject in CLI flows is the terminal app (`Terminal`/`iTerm`), not a separate XPC service.

To open settings quickly:

```bash
shot open-permissions
```

To trigger the request path:

```bash
shot request-permission --pretty
```

Then enable your terminal app in:

- `System Settings > Privacy & Security > Screen Recording`

After granting, restart the terminal app and rerun:

```bash
shot doctor --pretty
```

Expected: `permissions.screenRecording` becomes `granted`.
