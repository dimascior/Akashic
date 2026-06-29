# Helios Runtime Reset, Restore, and Uninstall

## Purpose

Phase 4.3.2c turns the integrity system from "I can prove something drifted" into "I can safely recover from that drift." It provides three controlled recovery operations and keeps them separate from Rebaseline.

## Operations

| Operation | Tool | Source Authority | Purpose |
|-----------|------|-----------------|---------|
| Reset | `Reset-AkashicHeliosRuntime.ps1` | CurrentRuntimeBundleRoot | Discard active baseline, regenerate from current repo source |
| Restore | `Restore-HeliosRuntimeFromBundle.ps1` | RecordedInstallOrigin | Return to the exact source state recorded at install time |
| Uninstall | `Uninstall-AkashicHeliosRuntime.ps1` | None | Remove hooks and runtime state safely |
| Rebaseline | `Invoke-AkashicRebaseline.ps1` | CurrentRuntimeState | Accept current files after human review (separate, not 4.3.2c) |

These MUST remain separate. Mixing them recreates the trust ambiguity the integrity system exists to eliminate.

## Reset

Archives the active baseline and creates a fresh repo-derived baseline from the current `RuntimeBundleRoot`. If the runtime file and manifest were both rewritten together, Reset does not bless the rewritten state.

### Flow (17 steps)

1. Assert Akashic trusted
2. Run `Test-HeliosRuntimeOrigin.ps1` (pre-reset detection)
3. Write detection event if noteworthy
4. Deactivate Claude hooks (if `-DisableHooksDuringReset`)
5. Unlock runtime files if locked
6. Archive active baseline (manifest, sidecar, origin, protected files)
7. Verify mutable lifecycle dirs preserved (pending/, inflight/, evidence/, blocked/)
8. Copy protected files from RuntimeBundleRoot
9. Sync Akashic bridge (separate step, bridge comes from Akashic)
10. Generate fresh `helios-envelope.json` + `.sha256`
11. Verify manifest CLEAN
12. Generate fresh `helios-install-origin.json`
13. Verify origin MATCH (post-reset detection)
14. Reactivate hooks (if `-ReactivateHooksAfterReset`)
15. Relock files (if `-RelockAfterReset`)
16. Collect post-reset hashes
17. Write reset evidence

### Parameters

| Parameter | Required | Default | Purpose |
|-----------|----------|---------|---------|
| `-AkashicRoot` | Yes | | Path to Akashic adapter |
| `-RuntimeBundleRoot` | Yes | | Path to Helios source files (current repo state) |
| `-HeliosGateRoot` | Yes | | Path to active gate runtime |
| `-Platform` | No | Auto | Windows, macOS, or Linux |
| `-DisableHooksDuringReset` | No | false | Deactivate Claude hooks before replacing files |
| `-ReactivateHooksAfterReset` | No | false | Reactivate Claude hooks after reset completes |
| `-RelockAfterReset` | No | false | Re-lock protected files after reset |
| `-ResetBy` | No | reset-tool | Identity recorded in evidence |
| `-ClaudeSettingsPath` | No | platform default | Override Claude settings path |
| `-EvidenceOutputDir` | No | evidence/phase432c | Override evidence directory |

### Failure behavior

If `-DisableHooksDuringReset` is used and reset fails midway:
- Hooks remain deactivated
- Claude commands run without Helios gating until manually reactivated
- RESET_PARTIAL evidence is written
- Terminal warns about manual recovery: `Apply-AkashicClaudeHooks.ps1`

Default (no hook switches): hooks are not touched. If reset fails, the gate system continues operating on whatever state exists.

## Restore

Returns the runtime to the recorded `helios-install-origin.json` source state. Unlike Reset which uses the current repo source, Restore uses the source that created the original installation.

### Flow (14 steps)

1. Assert Akashic trusted
2. Read `helios-install-origin.json`
3. Resolve recorded RuntimeBundleRoot and source repo state
4. Confirm source still exists (block on missing)
5. Compare current runtime to recorded origin
6. Archive current runtime baseline
7. Restore protected files from recorded source
8. Sync bridge from current Akashic source
9. Regenerate `helios-envelope.json` + `.sha256`
10. Handle origin per restore policy (preserve if exact match, regenerate if source changed)
11. Verify manifest CLEAN
12. Verify origin MATCH
13. Collect post-restore hashes
14. Write restore evidence

### Parameters

| Parameter | Required | Default | Purpose |
|-----------|----------|---------|---------|
| `-AkashicRoot` | Yes | | Path to Akashic adapter |
| `-HeliosGateRoot` | Yes | | Path to active gate runtime |
| `-Platform` | No | Auto | Windows, macOS, or Linux |
| `-Force` | No | false | Proceed when source has changed since install |
| `-ForceReason` | No | | Reason for override (recorded in evidence) |
| `-RestoredBy` | No | restore-tool | Identity recorded in evidence |

### Blocking behavior

- Recorded RuntimeBundleRoot does not exist: **always blocks**, cannot restore without source
- Recorded RuntimeBundleRoot exists but source has changed (different HEAD or file hashes): **blocks unless `-Force` is provided**
- With `-Force`: proceeds and records `override_used: true` and `override_reason` in evidence

### Restore policy

| Policy | Condition | Origin handling |
|--------|-----------|----------------|
| `exact_match` | Source matches recorded state | Preserve original origin file |
| `source_changed_forced` | Source changed, `-Force` used | Regenerate origin from current source |

## Uninstall

Removes Helios hooks and runtime state in a controlled way. Archives by default. Only destroys with explicit switch.

### Flow (8 steps)

1. Assert Akashic trusted
2. Remove Helios hooks from Claude settings (or restore backup with `-RestoreSettingsBackup`)
3. Unlock runtime protected files if locked
4. Archive HeliosGateRoot contents
5. Preserve evidence directory by default
6. Remove active runtime directories (only with `-ForceDestructive`)
7. Determine overall result
8. Write uninstall evidence (to AkashicRoot evidence dir, survives gate root removal)

### Parameters

| Parameter | Required | Default | Purpose |
|-----------|----------|---------|---------|
| `-AkashicRoot` | Yes | | Path to Akashic adapter |
| `-HeliosGateRoot` | Yes | | Path to active gate runtime |
| `-Platform` | No | Auto | Windows, macOS, or Linux |
| `-RestoreSettingsBackup` | No | false | Restore pre-Helios settings backup instead of selective removal |
| `-ForceDestructive` | No | false | Remove runtime directories after archiving |
| `-RemoveEvidence` | No | false | Also remove evidence directory (requires `-ForceDestructive`) |
| `-UninstalledBy` | No | uninstall-tool | Identity recorded in evidence |

### Destructive behavior

| Switches | Behavior |
|----------|----------|
| (none) | Archive only. Runtime directories preserved. Hooks removed from settings. |
| `-ForceDestructive` | Archive then remove hooks/, policy/, manifest/, templates/, schemas/, pending/, inflight/, blocked/ |
| `-ForceDestructive -RemoveEvidence` | Same as above plus remove evidence/ |

## Archive Structure

All operations create a timestamped archive under `maintenance/archives/`:

```
maintenance/archives/<YYYYMMDD-HHmmss>-<operation>/
    manifest/
        helios-envelope.json
        helios-envelope.sha256
        helios-install-origin.json
    protected/
        hooks/helios_pretooluse.ps1
        hooks/gate_check.ps1
        hooks/evidence_capture.ps1
        hooks/tier_classifier.ps1
        hooks/lib/HeliosIntegrityBridge.ps1
        policy/command-policy.json
    evidence/
        pre-reset-detection.json     (reset only)
        reset-evidence.json          (reset only)
    metadata/
        archive-index.json
        restore-evidence.json        (restore only)
        uninstall-evidence.json      (uninstall only)
```

`archive-index.json` records every archived path with its SHA-256 hash and size.

## Automation Mode Wiring

The detector (`Test-HeliosRuntimeOrigin.ps1`) now calls Reset for `AutoReset` and `AutoResetAndReactivate` modes.

### AutoReset allowed detection types

| Detection | AutoReset behavior |
|-----------|-------------------|
| BASELINE_REWRITE_SUSPECTED | Allowed |
| CURRENT_MANIFEST_DRIFT | Allowed |
| ORIGIN_DRIFT | Allowed |
| NO_INSTALL_ORIGIN | Allowed |
| BRIDGE_ORIGIN_DRIFT | Allowed |
| SOURCE_REPO_MISSING | Blocked |
| SOURCE_REPO_CHANGED | Blocked |
| SIDECAR_MISMATCH | Blocked |
| CURRENT_MANIFEST_CLEAN | No action needed |
| ORIGIN_MATCH | No action needed |

### Automation results

| Mode | Result |
|------|--------|
| DetectOnly | `DETECTED` |
| LogOnly | `LOGGED` |
| PlanReset | `PLAN_GENERATED` or `DETECTED` |
| AutoReset | `RESET_COMPLETE`, `RESET_PARTIAL`, `RESET_FAILED`, `RESET_BLOCKED`, `RESET_BLOCKED_NO_BUNDLE`, or `DETECTED` |
| AutoResetAndReactivate | `RESET_AND_REACTIVATE_COMPLETE`, `RESET_AND_REACTIVATE_PARTIAL`, `RESET_FAILED`, `RESET_BLOCKED`, `RESET_BLOCKED_NO_BUNDLE`, or `DETECTED` |

## Evidence Schemas

| Schema | Proves |
|--------|--------|
| `helios-runtime-reset-evidence.v1.json` | Old authority archived, new authority generated from correct source, final CLEAN + ORIGIN_MATCH |
| `helios-runtime-restore-evidence.v1.json` | Recorded source resolved, archived, restored, final CLEAN + ORIGIN_MATCH |
| `helios-runtime-uninstall-evidence.v1.json` | Settings changed, backup used, runtime archived or destroyed |

Each evidence schema includes `operation_type` and `source_authority` fields to encode the distinction directly.

## Platform Accommodations

| Concern | Windows | macOS | Linux |
|---------|---------|-------|-------|
| PowerShell path | `powershell.exe` or `pwsh` | Absolute `pwsh` | Absolute `pwsh` |
| Claude settings | `USERPROFILE\.claude\settings.json` | `HOME/.claude/settings.json` | `HOME/.claude/settings.json` |
| Lock mechanism | NTFS ACL deny | `chflags` | `chattr` (if available) |
| Path normalization | Forward slashes for relative protected paths | Same | Same |
| Ownership check | N/A | Standard | Required (BLOCKED_OWNERSHIP_MISMATCH) |

## Trust Boundary

Reset/Restore/Uninstall inherit the same trust boundary as the rest of Akashic:
- Hash-only integrity detects drift but cannot prevent a privileged actor from rewriting both files and evidence
- Signature verification remains SIGNATURE_NOT_IMPLEMENTED
- The archive proves what existed before the operation, but an actor with write access could forge the archive
- External authority (signed manifests, CI-anchored baselines) is required for full tamper-proof guarantees
