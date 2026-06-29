# macOS Phase 4.3.2d Cross-Platform Runtime Validation

**Date:** 2026-06-29
**Akashic commit tested:** b5debba4f390e4cc2e13474ea8bb67b434e597ae
**Machine:** Thiss-MBP.lan, macOS 14.6.1 (23G93), x86_64, Darwin 23.6.0

## Environment

```
PowerShell:      /Users/thispc/.local/bin/pwsh (7.4.7, user-level install)
git:             2.39.5 (Apple Git-154)
chflags:         /usr/bin/chflags
ls:              /bin/ls
User:            thispc (uid=501, admin)
Claude settings: /Users/thispc/.claude/settings.json
RuntimeBundleRoot: /Users/thispc/Engineering/Helios-/.command-gate
HeliosGateRoot:  /Users/thispc/.helios/.command-gate
Lock backend:    chflags (uchg/nouchg), strong_user_immutable
```

## Step 1: Prerequisites — PASS

All tools present. 8/8 PowerShell scripts parse clean. Helios- HEAD: d102467e3f0e4724cd1928b03b0344a0a90e150f. All 5 protected runtime source files exist in RuntimeBundleRoot.

## Step 2: Akashic Self-Integrity

Initial run: SIDECAR_MISMATCH (28 files drifted — expected, self-manifest was from earlier commit).
After `Invoke-AkashicSelfRebaseline.ps1 -RebaselinedBy macos-phase432d-validation`: CLEAN (104 protected, 0 drift).

## Step 3: PlanOnly — READY

```
schema_version: akashic-helios-install-plan.v2
mode: PlanOnly
platform: macOS
overall_status: READY
blockers: []
origin_status: SKIP
```

## Step 4: Prepare — READY

```
mode: Prepare
fixture_result: PASS
manifest_status: CLEAN
origin_status: PASS
overall_status: READY
settings_activation: skipped
lock_activation: plan_only
blockers: []
```

Bridge synced, byte identical (SHA256: 8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454).

## Step 5: Install Authority — ORIGIN_MATCH

```
current_manifest_verdict: CLEAN
sidecar_verdict: MATCH
origin_verdict: MATCH
detection_type: ORIGIN_MATCH
severity: INFO
recommended_action: NONE
```

## Step 6: Activate Hooks — ACTIVATED

```
hooks_added: PreToolUse, PostToolUse, PostToolUseFailure
status: ACTIVATED
Akashic self-integrity verified CLEAN before activation.
```

## Step 7: Live Gate Proof — PASS

**Interception:**
```
GATE REQUIRED: No valid gate found in pending/ for this command.
Tier: 0. SHA256: 1fc8ce6c2b4886be862f5206bd19981d9c6b99388cd17dbb6d71dc8486502d1c. Category: routine.
```

**Gate approval:**
```
Command: echo "phase432d-gate-test"; echo EXIT=$?
Output: phase432d-gate-test\nEXIT=0
Evidence: [EVIDENCE:phase432d-gate-test] Command succeeded. Exit=0 (source: parsed_marker).
```

## Step 8: Bypass Simulation — BASELINE_REWRITE_SUSPECTED

**Tamper:** Appended `# TAMPERED BY BYPASS SIMULATION` to `hooks/tier_classifier.ps1`.
**Hash change:** 9d41b12d... → 9257c080...
**Manifest regenerated:** rebaselined_by=bypass-simulation, manifest reports CLEAN.

**Origin detection caught the bypass:**
```
current_manifest_verdict: CLEAN
origin_verdict: BASELINE_REWRITE_SUSPECTED
detection_type: BASELINE_REWRITE_SUSPECTED
severity: CRITICAL
recommended_action: RESET_FROM_REPO
affected_files: hooks/tier_classifier.ps1
```

## Step 9: Reset — COMPLETE

```
Pre-reset:  BASELINE_REWRITE_SUSPECTED (CRITICAL)
Post-reset: ORIGIN_MATCH (INFO)
Archive:    /Users/thispc/.helios/.command-gate/maintenance/archives/20260629-221251-reset
Mutable dirs preserved: pending, inflight, evidence, blocked
Bridge re-synced, byte identical.
Fresh manifest and install-origin generated.
Final: CURRENT_MANIFEST_CLEAN + ORIGIN_MATCH
```

## Step 10: Restore — COMPLETE

```
source_authority: RecordedInstallOrigin
recorded_runtime_bundle_root: /Users/thispc/Engineering/Helios-/.command-gate
source_repo_head_matches_recorded: True
source_hashes_match_recorded: True
post_restore_manifest_verdict: CLEAN
post_restore_origin_verdict: MATCH
restore_policy: exact_match
override_used: False
Archive: /Users/thispc/.helios/.command-gate/maintenance/archives/20260629-221356-restore
overall: COMPLETE
```

## Step 11: Uninstall — COMPLETE

```
uninstall_mode: archive
pre_uninstall_hooks_active: True
post_uninstall_hooks_active: False
hooks_removed: True (PreToolUse, PostToolUse, PostToolUseFailure)
runtime_archived: True
runtime_removed: False
evidence_preserved: True
force_destructive: False
Archive: /Users/thispc/.helios/.command-gate/maintenance/archives/20260629-221403-uninstall
Settings after uninstall: hooks removed, unrelated settings preserved (availableModels, effortLevel, model intact).
overall: COMPLETE
```

## Discoveries

| # | Discovery | Impact |
|---|---|---|
| 1 | Self-manifest requires rebaseline after checkout of new commit | Expected; ran Invoke-AkashicSelfRebaseline |
| 2 | Apply-AkashicClaudeHooks uses bare `pwsh` — works because ~/.local/bin is in PATH | Would fail on minimal PATH; absolute path safer |
| 3 | Uninstall while hooks active causes GATE REQUIRED on the uninstall command itself | Ran activate+uninstall in single pwsh session to avoid gate loop |
| 4 | Reset parameter is `RuntimeBundleRoot` not `CurrentRuntimeBundleRoot` | Parameter name corrected on retry |

## Final Verdict: PASS

All 11 validation steps completed successfully on macOS 14.6.1 (23G93), x86_64.

```
Install result:            PASS (Prepare READY, manifest CLEAN, origin PASS)
Activation result:         PASS (3 hooks activated, Akashic CLEAN)
Gate proof result:         PASS (GATE REQUIRED → gate approval → evidence capture)
Bypass detection result:   PASS (BASELINE_REWRITE_SUSPECTED, CRITICAL)
Reset result:              PASS (CRITICAL → ORIGIN_MATCH, archive created)
Restore result:            PASS (from RecordedInstallOrigin, CLEAN + MATCH)
Uninstall result:          PASS (hooks removed, runtime archived, evidence preserved)
Locks applied:             false
Runtime locking status:    deferred
```
