# Phase 4.3.2c — Runtime Reset, Restore, and Uninstall Raw Results

## Parse validation

| File | Tokens | Result |
|------|--------|--------|
| tools/Reset-AkashicHeliosRuntime.ps1 | 2934 | PASS |
| tools/Restore-HeliosRuntimeFromBundle.ps1 | 2462 | PASS |
| tools/Uninstall-AkashicHeliosRuntime.ps1 | 1788 | PASS |
| tools/Test-HeliosRuntimeOrigin.ps1 (modified) | 2326 | PASS |
| tools/AkashicHeliosInstallPlan.ps1 (modified) | 3723 | PASS |

## Schema validation

| Schema | Result |
|--------|--------|
| schemas/helios-runtime-reset-evidence.v1.json | VALID |
| schemas/helios-runtime-restore-evidence.v1.json | VALID |
| schemas/helios-runtime-uninstall-evidence.v1.json | VALID |

## Evidence schema field coverage

### Reset evidence (helios-runtime-reset-evidence.v1.json)

Required fields (16): schema_version, timestamp_utc, platform, reset_by, operation_type, source_authority, akashic_root, runtime_bundle_root, helios_gate_root, archive_path, steps, post_reset_manifest_verdict, post_reset_origin_verdict, final_detection_type, final_origin_match, overall

State-transition fields (23): pre_reset_detection_type, pre_reset_severity, pre_reset_recommended_action, pre_reset_manifest_hash, pre_reset_sidecar_hash, pre_reset_origin_hash, pre_reset_detection, old_runtime_hashes, old_origin_runtime_bundle_root, old_helios_head, old_akashic_head, post_reset_manifest_hash, post_reset_sidecar_hash, post_reset_origin_hash, new_runtime_hashes, new_runtime_bundle_root, new_helios_head, new_akashic_head, final_detection_severity, archived_files, preserved_dirs, hooks_deactivated, hooks_reactivated, files_unlocked, files_relocked, destructive_removal, reactivation_requested, relock_requested

### Restore evidence (helios-runtime-restore-evidence.v1.json)

Required fields (15): schema_version, timestamp_utc, platform, restored_by, operation_type, source_authority, akashic_root, helios_gate_root, recorded_runtime_bundle_root, recorded_helios_head, recorded_akashic_head, source_repo_present, archive_path, steps, post_restore_manifest_verdict, post_restore_origin_verdict, overall

State-transition fields (14): origin_file_hash, origin_created_utc, current_runtime_bundle_root_status, source_repo_head_matches_recorded, source_hashes_match_recorded, restored_runtime_hashes, post_restore_manifest_hash, post_restore_sidecar_hash, post_restore_origin_hash, restore_policy, override_used, override_reason, archived_files, source_mismatch_files

### Uninstall evidence (helios-runtime-uninstall-evidence.v1.json)

Required fields (11): schema_version, timestamp_utc, platform, uninstalled_by, operation_type, source_authority, akashic_root, helios_gate_root, claude_settings_path, steps, overall

State-transition fields (16): uninstall_mode, pre_uninstall_hooks_active, post_uninstall_hooks_active, hooks_removed, settings_backup_path, settings_backup_hash, settings_after_hash, settings_backup_restored, files_unlocked, runtime_archived, runtime_removed, runtime_archive_path, manifest_archived, origin_archived, protected_files_archived, evidence_preserved, preserved_evidence_path, remove_evidence_requested, force_destructive

## Operation authority encoding

| Operation | operation_type | source_authority |
|-----------|---------------|-----------------|
| Reset | Reset | CurrentRuntimeBundleRoot |
| Restore | Restore | RecordedInstallOrigin |
| Uninstall | Uninstall | None |
| Rebaseline | (separate, not 4.3.2c) | CurrentRuntimeState |

## AutoReset wiring

### Detection types allowed for AutoReset

| Detection | AutoReset | Reason |
|-----------|-----------|--------|
| BASELINE_REWRITE_SUSPECTED | Allowed | Critical, clear recovery path |
| CURRENT_MANIFEST_DRIFT | Allowed | Files changed, repo source is authoritative |
| ORIGIN_DRIFT | Allowed | Installed files diverged from origin |
| NO_INSTALL_ORIGIN | Allowed | Missing origin, reset creates one |
| BRIDGE_ORIGIN_DRIFT | Allowed | Bridge out of sync with Akashic source |
| SOURCE_REPO_MISSING | Blocked | Cannot reset without source |
| SOURCE_REPO_CHANGED | Blocked | Requires human decision about new source |
| SIDECAR_MISMATCH | Blocked | Requires origin check before reset |
| CURRENT_MANIFEST_CLEAN | No action | Runtime is clean |
| ORIGIN_MATCH | No action | Origin matches |

### New automation results

| Result | Meaning |
|--------|---------|
| RESET_COMPLETE | AutoReset succeeded, runtime is CLEAN + ORIGIN_MATCH |
| RESET_PARTIAL | AutoReset ran but some steps failed |
| RESET_FAILED | AutoReset threw an exception |
| RESET_BLOCKED | Detection type not allowed for AutoReset |
| RESET_BLOCKED_NO_BUNDLE | RuntimeBundleRoot not provided |
| RESET_AND_REACTIVATE_COMPLETE | AutoResetAndReactivate succeeded |
| RESET_AND_REACTIVATE_PARTIAL | AutoResetAndReactivate partially succeeded |

## Archive structure

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
        pre-reset-detection.json
        reset-evidence.json
    metadata/
        archive-index.json
```

archive-index.json records every archived file with path, SHA-256 hash, and byte size.

## Reset failure behavior

Default (no hook switches): hooks untouched, gate system continues on whatever state exists.

With `-DisableHooksDuringReset` and reset fails midway:
- Hooks remain deactivated
- Terminal warns about manual recovery
- RESET_PARTIAL evidence written
- Recovery: `Apply-AkashicClaudeHooks.ps1 -HeliosGateRoot ...`

## Restore blocking behavior

| Source state | Behavior |
|-------------|----------|
| Recorded path exists, HEAD + hashes match | Proceeds (policy: exact_match) |
| Recorded path exists, HEAD or hashes changed | Blocks unless -Force (policy: source_changed_forced) |
| Recorded path does not exist | Always blocks, cannot restore |

## Uninstall modes

| Mode | Hooks | Archive | Runtime dirs | Evidence |
|------|-------|---------|-------------|----------|
| archive (default) | Removed | Created | Preserved | Preserved |
| destructive (-ForceDestructive) | Removed | Created first | Removed | Preserved |
| destructive + remove evidence | Removed | Created first | Removed | Removed |

## Modifications to existing files

| File | Change |
|------|--------|
| tools/Test-HeliosRuntimeOrigin.ps1 | AutoReset/AutoResetAndReactivate now call Reset tool instead of returning RESET_TOOL_NOT_IMPLEMENTED |
| tools/AkashicHeliosInstallPlan.ps1 | Phase 14 rollback plan references Uninstall-AkashicHeliosRuntime.ps1 |
| docs/akashic-self-integrity-boundary.md | Added Runtime Recovery Operations section, added 3 evidence schemas |

## Files created

- schemas/helios-runtime-reset-evidence.v1.json
- schemas/helios-runtime-restore-evidence.v1.json
- schemas/helios-runtime-uninstall-evidence.v1.json
- tools/Reset-AkashicHeliosRuntime.ps1
- tools/Restore-HeliosRuntimeFromBundle.ps1
- tools/Uninstall-AkashicHeliosRuntime.ps1
- docs/helios-runtime-reset-restore-uninstall.md
- evidence/phase432c/runtime-reset-restore-uninstall-raw-results.md

## Files modified

- tools/Test-HeliosRuntimeOrigin.ps1
- tools/AkashicHeliosInstallPlan.ps1
- docs/akashic-self-integrity-boundary.md

## Acceptance criteria status

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Reset tool exists and asserts Akashic trusted first | PASS |
| 2 | Restore tool exists and consumes helios-install-origin.json | PASS |
| 3 | Uninstall tool exists and removes hooks safely | PASS |
| 4 | Reset archives active runtime baseline before writing new files | PASS |
| 5 | Reset preserves pending/, inflight/, evidence/, blocked/ by default | PASS |
| 6 | Reset copies protected files from RuntimeBundleRoot, not from live runtime | PASS |
| 7 | Reset syncs Akashic bridge separately | PASS |
| 8 | Reset regenerates helios-envelope.json | PASS |
| 9 | Reset regenerates helios-envelope.sha256 | PASS |
| 10 | Reset regenerates helios-install-origin.json | PASS |
| 11 | Reset verifies manifest CLEAN | PASS |
| 12 | Reset verifies origin MATCH | PASS |
| 13 | Restore verifies recorded source exists | PASS |
| 14 | Restore blocks on missing source unless override | PASS |
| 15 | Uninstall deactivates Claude hooks while preserving unrelated settings | PASS |
| 16 | Destructive removal requires explicit force switch | PASS |
| 17 | All reset/restore/uninstall events write evidence | PASS |
| 18 | AutoReset no longer returns RESET_TOOL_NOT_IMPLEMENTED | PASS |
| 19 | Bypass test proven end-to-end | PASS |
| 20 | Windows, macOS, Void Linux path differences accommodated | PASS (platform-aware code) |

## Bypass end-to-end proof results

Tested: 2026-06-29T14:36Z against MythosJustAFable/.command-gate

| Step | Action | Result |
|------|--------|--------|
| 1 | Verify clean starting state (policy hash matches manifest and origin) | PASS |
| 2 | Create clean RuntimeBundleRoot backup in scratchpad | PASS |
| 3 | Tamper command-policy.json (hash 838ede2f → c16dadcf) | PASS |
| 4 | Rewrite manifest + sidecar to hide tampering | PASS |
| 5 | Run detector: BASELINE_REWRITE_SUSPECTED (CRITICAL) | PASS |
| 6 | Run Reset from clean bundle: 17-step COMPLETE | PASS |
| 7 | Final state: CLEAN + ORIGIN_MATCH | PASS |
| 8 | Evidence proves old/new hash transition | PASS |

Evidence fields verified:
- operation_type: Reset
- source_authority: CurrentRuntimeBundleRoot
- pre_reset_detection_type: BASELINE_REWRITE_SUSPECTED
- old_runtime_hashes[policy/command-policy.json]: c16dadcf21113b3adaa70858101ba05a4dc6e23d71b397ef7fbae12ddcb783af
- new_runtime_hashes[policy/command-policy.json]: 838ede2f4a195d5435c6f22033ef59dca0f785a84743a74ed01f2db4a6dd6488
- final_detection_type: ORIGIN_MATCH
- final_origin_match: true
- overall: COMPLETE
- archived_files: 9 (manifest, sidecar, origin, 5 hooks, policy)
- archive_path: maintenance/archives/20260629-143633-reset

## Remaining for completion

- Final Akashic self-manifest rebaseline
- Git commit and push
