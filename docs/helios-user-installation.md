# Helios User Installation Guide

## Prerequisites

| Platform | Requirements |
|---|---|
| Windows | PowerShell 5.1+, icacls (built-in), NTFS filesystem |
| Linux | pwsh 7+, chattr/lsattr, ext4/btrfs/xfs with immutable support |
| macOS | pwsh 7+, chflags (built-in) |

You need two repositories:
- **Akashic** — the installer, integrity adapter, and activation helper (this repo)
- **Helios-** — the runtime bundle source (`dimascior/Helios-`)

Akashic installs, prepares, verifies, activates, locks, unlocks, and rolls back a Helios runtime. Helios is the runtime that actually controls Claude's Bash/PowerShell execution through gate enforcement.

## Quick Start

### 1. Prepare + Activate

```powershell
# Windows
.\tools\Install-AkashicHeliosRuntime.ps1 `
  -AkashicRoot "C:\path\to\Akashic" `
  -RuntimeBundleRoot "C:\path\to\Helios-\.command-gate" `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate" `
  -ActivateClaudeHooks `
  -Verify
```

```bash
# Linux / macOS
pwsh -NoProfile -File ./tools/Install-AkashicHeliosRuntime.ps1 \
  -AkashicRoot "$HOME/Akashic" \
  -RuntimeBundleRoot "$HOME/Helios-/.command-gate" \
  -HeliosGateRoot "$HOME/your-project/.command-gate" \
  -ActivateClaudeHooks \
  -Verify
```

This will:
1. Copy Helios hooks, policy, and support files from RuntimeBundleRoot to HeliosGateRoot
2. Sync the Akashic integrity bridge to the Helios vendor location
3. Generate the manifest and sidecar for the Helios runtime
4. Back up your current Claude settings
5. Add Helios hooks (PreToolUse, PostToolUse, PostToolUseFailure) to Claude settings
6. Verify the Helios runtime (hooks, manifest, hashes, structure)

### Dry Run First

Before modifying settings, preview what would happen:

```powershell
.\tools\Install-AkashicHeliosRuntime.ps1 `
  -AkashicRoot "C:\path\to\Akashic" `
  -RuntimeBundleRoot "C:\path\to\Helios-\.command-gate" `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate" `
  -ActivateClaudeHooks `
  -WhatIf
```

This shows exactly which hook commands would be written, where the backup would go, and whether existing hooks point to a different runtime root — without touching any files.

### 2. What Happens After Activation

Every Bash or PowerShell command Claude runs will be intercepted by the Helios front controller. Commands require a valid `.gate.json` in `pending/` to execute. Without one, the command is blocked with a `GATE REQUIRED` message.

### 3. Creating Your First Gate

After activation, your first command will be blocked. The rejection tells you the SHA256 of the command. Create a gate file:

```json
{
  "schema_version": "command-gate.v1",
  "correlation_id": "my-first-gate",
  "created_utc": "2026-06-28T12:00:00Z",
  "expires_utc": "2026-06-29T12:00:00Z",
  "command": "the exact command text",
  "command_sha256": "the sha256 from the rejection",
  "working_directory": "C:\\path\\to\\project",
  "shell": "powershell",
  "risk_tier": 0,
  "exit_capture": "not_applicable",
  "exit_capture_reason": "pure_output",
  "multi_command": false,
  "segments": [],
  "need": "Why this command is needed",
  "expected": "What output you expect",
  "actual_means": "What the command actually does",
  "next_logic": "What happens next",
  "approval_boundary": "This gate makes the command eligible for permission flow only; it does not auto-approve execution."
}
```

Save it as `<your-project>/.command-gate/pending/<name>.gate.json` and retry the command.

### Using the Gate Creation Tool

Instead of writing JSON by hand, use the gate creation tool:

```powershell
.\tools\New-HeliosGate.ps1 `
  -Command 'git status' `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate" `
  -Need "Check repo state" `
  -Expected "Clean working tree" `
  -ActualMeans "Shows git status output" `
  -NextLogic "Proceed with next task"
```

The tool computes the SHA256 automatically, detects chained commands, sets expiry (default 60 minutes), and writes a valid gate file.

For higher-risk commands:

```powershell
.\tools\New-HeliosGate.ps1 `
  -Command 'Remove-Item ./temp -Recurse -Force' `
  -HeliosGateRoot "C:\path\to\.command-gate" `
  -Shell powershell `
  -RiskTier 3 `
  -Writes @(".\temp") `
  -Deletes @(".\temp") `
  -StopConditions @("abort if temp contains uncommitted work") `
  -ExpiresInMinutes 15
```

## Gate Management

```powershell
# List active pending gates
.\tools\Get-HeliosPendingGates.ps1 -HeliosGateRoot "C:\path\to\.command-gate"

# Include expired gates
.\tools\Get-HeliosPendingGates.ps1 -HeliosGateRoot "C:\path\to\.command-gate" -IncludeExpired

# View recent evidence records
.\tools\Get-HeliosEvidence.ps1 -HeliosGateRoot "C:\path\to\.command-gate" -Summary

# Look up a specific gate's evidence
.\tools\Get-HeliosEvidence.ps1 -HeliosGateRoot "C:\path\to\.command-gate" -CorrelationId "my-gate-id"

# Clean up expired gates (moves to evidence/stale/)
.\tools\Clear-HeliosStaleGates.ps1 -HeliosGateRoot "C:\path\to\.command-gate"

# Preview what would be cleaned
.\tools\Clear-HeliosStaleGates.ps1 -HeliosGateRoot "C:\path\to\.command-gate" -WhatIf
```

## Prepare Only (No Settings Changes)

```powershell
.\tools\Install-AkashicHeliosRuntime.ps1 `
  -AkashicRoot "C:\path\to\Akashic" `
  -RuntimeBundleRoot "C:\path\to\Helios-\.command-gate" `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate"
```

This copies files and generates the manifest but does not modify Claude settings.

## Deactivation / Rollback

### Remove hooks only (keep runtime files)

```powershell
.\tools\Remove-AkashicClaudeHooks.ps1
```

### Restore from backup

```powershell
.\tools\Remove-AkashicClaudeHooks.ps1 -RestoreFromBackup
```

### Custom settings path

```powershell
.\tools\Remove-AkashicClaudeHooks.ps1 -ClaudeSettingsPath "C:\path\to\settings.json"
```

### Full rollback (hooks + unlock + remove runtime)

```powershell
.\tools\Rollback-AkashicHeliosRuntime.ps1 `
  -HeliosGateRoot "C:\path\to\.command-gate" `
  -RestoreFromBackup `
  -UnlockRuntime `
  -RemoveRuntime
```

## Maintenance Rebaseline

After modifying protected runtime files (hooks, policy, bridge), rebaseline the manifest:

```powershell
.\tools\Invoke-HeliosRuntimeRebaseline.ps1 `
  -HeliosGateRoot "C:\path\to\.command-gate" `
  -AkashicRoot "C:\path\to\Akashic" `
  -RelockAfter
```

This unlocks, regenerates the manifest, verifies integrity, and optionally re-locks.

## Verification

Run the live operational verifier at any time:

```powershell
.\tools\Test-HeliosLiveOperational.ps1 `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate"
```

This checks:
- Runtime target exists
- All hooks present (4 scripts)
- Bridge present
- Policy present
- Manifest and sidecar exist
- Manifest hash matches sidecar
- Protected file hashes match manifest (6 files)
- Mutable directories exist and are writable
- Claude settings point to the correct hooks
- Gate lifecycle stats

## Runtime Locking (Advanced)

After live verification passes, you can lock the protected runtime files:

```powershell
.\tools\Install-AkashicHeliosRuntime.ps1 `
  -AkashicRoot "C:\path\to\Akashic" `
  -RuntimeBundleRoot "C:\path\to\Helios-\.command-gate" `
  -HeliosGateRoot "C:\path\to\your-project\.command-gate" `
  -ActivateClaudeHooks `
  -Verify `
  -LockRuntime `
  -RequireStrongLock
```

Locking applies OS-native protections (icacls on Windows, chattr on Linux, chflags on macOS) to prevent modification of hook scripts, policy, bridge, and manifest during gated execution.

To unlock for maintenance:

```powershell
.\tools\Unlock-AkashicProtectedFiles.ps1 -HeliosGateRoot "C:\path\to\.command-gate"
```

## Evidence

All operations write evidence to `evidence/phase42/` (or a custom `-EvidenceOutputDir`):

| File | Schema | When |
|---|---|---|
| `settings-activation-evidence.json` | `helios-settings-activation-evidence.v1` | After hook activation |
| `settings-rollback-evidence.json` | `helios-rollback-evidence.v1` | After hook removal |
| `live-operational-check.json` | `helios-live-operational-check.v1` | After verification |
| `install-summary.json` | (install summary) | After unified install |
| `install-evidence.json` | `akashic-install-evidence.v1` | After Prepare/Activate |

## Settings Path Resolution

| Platform | Default Path |
|---|---|
| Windows | `%USERPROFILE%\.claude\settings.json` |
| Linux | `$HOME/.claude/settings.json` |
| macOS | `$HOME/.claude/settings.json` |

Override with `-ClaudeSettingsPath` on any tool.
