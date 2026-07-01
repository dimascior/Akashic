# Phase 4 — helios-lock (Filesystem Prevention)

## Purpose

The integrity witness provides detection-on-next-shell-action. helios-lock provides prevention: OS-native filesystem locks that block modification of protected files at the filesystem level, closing the gap between mutation and detection.

## Lock Targets

### Must be locked (runtime protected envelope)

| Path | Reason |
|---|---|
| `hooks/helios_pretooluse.ps1` | Front controller entry point |
| `hooks/gate_check.ps1` | Gate validation logic |
| `hooks/evidence_capture.ps1` | Post-command evidence capture |
| `hooks/tier_classifier.ps1` | Tier classification |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Vendored witness bridge |
| `policy/command-policy.json` | Tier patterns and gate policy |
| `templates/` | Tier override catalog directory (including any future operating-catalog.json) |
| `manifest/helios-envelope.json` | Durable manifest (hash registry) |
| `manifest/helios-envelope.sha256` | Sidecar integrity anchor |
| `C:\Users\dimas\.claude\settings.json` | Hook activation (external control-plane) |

### Must remain writable (mutable runtime envelope)

| Path | Reason |
|---|---|
| `pending/` | Gates created here before execution |
| `inflight/` | Gates moved here during execution |
| `evidence/` | Gate results, integrity evidence, session baselines |
| `blocked/` | Denied command records |

### Not locked (repo-controlled support assets)

`docs/`, `schemas/`, `tools/`, `tests/` — not in the active hook path.

## Lock Strategy by Platform

### Windows
```powershell
icacls "hooks\gate_check.ps1" /deny "*S-1-1-0:(W,D)"
# Unlock for rebaseline:
icacls "hooks\gate_check.ps1" /remove:d "*S-1-1-0"
```

### Linux
```bash
sudo chattr +i hooks/gate_check.ps1
# Unlock for rebaseline:
sudo chattr -i hooks/gate_check.ps1
```

### macOS
```bash
chflags uchg hooks/gate_check.ps1
# Unlock for rebaseline:
chflags nouchg hooks/gate_check.ps1
```

### POSIX Fallback
```bash
chmod a-w hooks/gate_check.ps1
# Unlock for rebaseline:
chmod u+w hooks/gate_check.ps1
```

## Lock Workflow

1. **Unlock** all protected files (human action).
2. Make approved changes (code update, bridge sync, policy edit).
3. **Rebaseline**: `tools/New-HeliosEnvelopeManifest.ps1 -GateRoot <path> -RebaselinedBy human`.
4. **Verify**: `tools/Test-HeliosEnvelopeIntegrity.ps1 -GateRoot <path>` — expect CLEAN.
5. **Refresh session baseline**: next clean gated command creates a new baseline automatically.
6. **Relock** all protected files (human action).
7. **Lock verification probes**: run `Test-HeliosEnvelopeIntegrity.ps1` again to confirm locked state does not affect readability. Attempt a write to a locked file to confirm it fails.

## Lock Verification Evidence

Phase 4 should add lock state to the integrity evidence:
- Record lock status (locked/unlocked) for each protected file in before/after snapshots.
- Detect and report unlocked protected files as a warning (distinct from hash drift).
- Lock status check uses platform-appropriate commands.

## Non-Shell Tool Interception

Claude Code hooks currently only gate Bash and PowerShell tool uses. Edit, Write, and NotebookEdit bypass the gate entirely. Options:
- Request Claude Code hook expansion for non-shell tools (Edit, Write, NotebookEdit matchers in PreToolUse).
- Filesystem locks make this less critical — the tools will fail to write locked files regardless of hook coverage.
- Detect post-hoc via PostToolUse evidence that a protected file was modified by a non-shell tool (requires PostToolUse hooks for Edit/Write).

## settings.json Protection

`C:\Users\dimas\.claude\settings.json` is the most critical lock target. If modified to remove the PreToolUse hook entry, the entire gate system is silently disabled. This file is outside `.command-gate/` and requires special handling:
- Lock with OS-native protection (same platform strategy as above).
- Consider a secondary integrity check that verifies settings.json content matches expected hook configuration.

## Prerequisites (Met)

- Integrity witness implementation complete (Phases 0-3).
- Durable manifest and sidecar in place.
- Session baseline system operational.
- Evidence chain writing verified.
- Tools for rebaseline and verification created.
- Pester test suite covering bridge and tools.
- Bypass surface documented.
