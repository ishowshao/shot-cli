# Pure CLI Migration Plan

## 1. Decision and Goal

### 1.1 Final Direction

- Product direction: **CLI-first and pure CLI**.
- `shot` should run without depending on GUI/XPC runtime path.
- Screen Recording permission guidance should target **Terminal/iTerm** (the actual TCC subject in TUI workflows).

### 1.2 Why This Direction

- Coding agent workflows are TUI-centric.
- On macOS, Screen Recording permission requires human grant anyway (unless managed by enterprise MDM/PPPC).
- Granting permission to terminal host benefits all CLI screenshot tools in that host.

## 2. Constraints (must accept)

- No silent grant for Screen Recording on consumer macOS.
- TCC decision is tied to calling chain/subject and code requirement.
- Different terminal apps need separate grants (e.g. Terminal vs iTerm).

## 3. Target Architecture

- Keep one primary executable path: `shot`.
- `doctor/displays/windows/capture` execute in-process (no XPC relay).
- Remove product messaging that implies "grant ShotCli GUI permission to make CLI work".

## 4. Implementation Plan

### Phase A: CLI behavior normalization

1. Update `doctor` output semantics:
   - No `endpoint = xpc`.
   - Explicitly state permission check is for current terminal context.
2. Update permission error hints:
   - Point to granting Screen Recording for terminal host app.
3. Add helper command(s):
   - `shot open-permissions` (open Privacy > Screen Recording).
   - Optional: `shot request-permission` to trigger system prompt path.

### Phase B: Remove XPC dependencies

1. Remove CLI forwarding path in app target (`ShotIPC` usage).
2. Remove `ShotCliXPCService` target and protocol coupling.
3. Keep/introduce single CLI entrypoint for `shot` execution.

### Phase C: Delivery and install

1. Keep install flow simple and scriptable:
   - `~/.local/bin/shot` preferred in dev.
   - Optional `/usr/local/bin/shot` with elevation.
2. Ensure no GUI prerequisite for standard CLI use.

### Phase D: Docs and verification scripts

1. Replace XPC-centric docs with pure CLI docs.
2. Update verification script to validate:
   - terminal permission state
   - capture success/failure expectations

## 5. Verification Matrix

1. `shot doctor --pretty`
   - no Screen Recording: exit `11`
   - with Screen Recording: exit `0`
2. `shot displays --pretty`
   - should work even when Screen Recording missing (if design keeps this behavior)
3. `shot windows --pretty`
   - missing permission: exit `11`
4. `shot capture --display <id> --out ~/Downloads/<file>.png`
   - missing permission: exit `11`
   - granted permission: exit `0` and output file exists

## 6. Manual Step Before Continuing (Your Action)

You plan to grant iTerm Screen Recording and restart iTerm.  
This is the exact minimal procedure:

1. Open `System Settings` -> `Privacy & Security` -> `Screen Recording`.
2. Enable permission for `iTerm` (or your target terminal app).
3. Quit and reopen iTerm.

## 7. Resume Checklist After Restart (No Context Loss)

After restart, run:

```bash
cd /Users/cyberoldman/htdocs/ShotCli
git checkout feat/pure-cli
git status --short
shot doctor --pretty
```

Then send me:

1. `shot doctor --pretty` output
2. your current terminal app name (iTerm/Terminal)

I will continue from this document and execute Phase A -> D sequentially.

## 8. Risks and Notes

- If `shot doctor` still reports missing after grant, verify:
  - you are in the same terminal app that was granted
  - app restart has completed
  - binary/signature path did not unexpectedly change
- For full unattended fleet rollout, only MDM/PPPC can remove the manual permission step.
