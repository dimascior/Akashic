# Phase 4.1 — Lock/Unlock/Rebaseline Tooling

**Status: Implementation draft. All verification checklist items are pending.**

## Scope

Phase 4.1 implements the lock/control tooling justified by Phase 4.0 gap evidence. Every tool traces to a Phase 4.0 decision table entry. No tool has been validated against a live Helios runtime yet.

## Platform Strategy

**Cross-platform.** `Get-AkashicLockStrategy.ps1` resolves the OS-native lock backend at runtime. Consumer tools dot-source `tools/lib/AkashicLockTargets.ps1` (inventory) and `tools/lib/AkashicLockBackend.ps1` (dispatch). No platform-specific `if` blocks in consumer tools.

| Platform | Backend | Lock | Unlock | Status | Strength |
|---|---|---|---|---|---|
| Windows | icacls | `/deny "*S-1-1-0:(W,D)"` | `/remove:d "*S-1-1-0"` | Parse DENY ACE | strong |
| Linux | chattr | `+i` | `-i` | lsattr for `i` flag | strong_if_supported |
| macOS | chflags | `uchg` | `nouchg` | `ls -lO` for `uchg` | strong_user_immutable |
| POSIX | chmod | `a-w` | `u+w` | mode bits | weak_fallback (opt-in) |

Backend dispatch uses `& $CommandPath @Arguments` (never Invoke-Expression, bash -c, or shell strings). Privilege wrapping (sudo -n, doas) is handled in `Invoke-AkashicNativeCommand`.

## Tools Implemented

### Protected Runtime Lock Tools (Phase 4.0 Section 9)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `Lock-AkashicProtectedFiles.ps1` | Apply deny ACLs to all protected files | Tests #1, #2, #3, #11, #12 |
| `Unlock-AkashicProtectedFiles.ps1` | Remove deny ACLs for maintenance | Inverse of lock |
| `AkashicLockStatus.ps1` | Verify lock state of all targets | Verification for all lock tests |
| `Invoke-AkashicRebaseline.ps1` | Coordinated unlock→update→relock→verify | Phase 4.0 Section 15, open question #3 |

### Mutable Lifecycle Tools (Phase 4.0 Section 10)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `Move-AkashicStaleGateArtifacts.ps1` | Clean expired pending/ and orphaned inflight/ | Test #5 (stale gate) |

### External Control-Plane Tools (Phase 4.0 Section 12)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `AkashicSettingsIntegrity.ps1` | Verify settings.json hook entries | Test #11 (highest severity) |

### Schema

| Schema | Purpose |
|---|---|
| `helios-rebaseline.schema.json` | Rebaseline record format for audit trail |

## Lock Target Registry

From Phase 4.0 Section 9 decision table:

### Direct Lock Targets (LOCK decision)

| File | Gap Tests | Priority |
|---|---|---|
| `hooks/helios_pretooluse.ps1` | #2, #3 | Critical |
| `hooks/gate_check.ps1` | #2, #3, #7, #10 | Critical |
| `hooks/evidence_capture.ps1` | #2, #3, #9 | Critical |
| `hooks/tier_classifier.ps1` | #2, #3 | Critical |
| `hooks/lib/HeliosIntegrityBridge.ps1` | #2, #3 | Critical |
| `policy/command-policy.json` | #1, #6 | Critical |
| `manifest/helios-envelope.json` | Manifest trust | Critical |
| `manifest/helios-envelope.sha256` | Sidecar trust | Critical |

### External Lock Target (LOCK — highest severity)

| File | Gap Test | Priority |
|---|---|---|
| `settings.json` | #11 | Critical — highest severity bypass vector |

### Conditional Lock Target

| File | Gap Test | Condition |
|---|---|---|
| `templates/` directory | #12 | Lock only if templates participate in gate trust |

## Rebaseline Workflow

The `Invoke-AkashicRebaseline` tool implements a 7-step atomic cycle:

```
1. Pre-flight lock check    → verify locks are in place
2. Unlock                   → remove deny ACLs
3. Update action            → execute the user-supplied change
4. Regenerate manifest      → New-HeliosEnvelopeManifest
5. Relock                   → reapply deny ACLs
6. Post-flight lock check   → verify locks restored
7. Envelope integrity       → Test-HeliosEnvelopeIntegrity
```

**Failure recovery:** If steps 3 or 4 fail, emergency relock is attempted immediately. The rebaseline record captures every step with timestamp and status.

**Atomicity answer (Phase 4.0 open question #3):** The cycle is not truly atomic — there is a window between unlock and relock where files are writable. The mitigation is:
- The unlock window is minimized (only as long as the update action takes).
- Emergency relock on any failure.
- The rebaseline record provides audit evidence of the unlock window duration.

## Mutable Lifecycle Strategy

From Phase 4.0 Section 10:

| Directory | Control | Tool |
|---|---|---|
| `pending/` | TTL enforcement, stale gate cleanup | `Move-AkashicStaleGateArtifacts.ps1` |
| `inflight/` | Orphan detection, age-based cleanup | `Move-AkashicStaleGateArtifacts.ps1` |
| `evidence/` | Content hashing at creation (existing via bridge) | `Write-HeliosIntegrityEvidence` in bridge |
| `blocked/` | Audit trail preservation | Lifecycle cleanup via stale artifact tool |

**Key decision:** These directories are NOT locked. Phase 4.0 test #5 explicitly requires `pending/` to remain writable.

## Settings.json Control-Plane Strategy

From Phase 4.0 Section 12:

1. **Lock** `settings.json` with `Lock-AkashicProtectedFiles -IncludeSettingsJson`.
2. **Verify** hook entries with `AkashicSettingsIntegrity.ps1` as a pre-flight check.
3. **Unlock** for legitimate config changes via `Invoke-AkashicRebaseline -IncludeSettingsJson`.
4. **Re-verify** after unlock/relock that hook entries still point to Helios scripts.

## Template Trust Decision

From Phase 4.0 Section 13:

**Decision: Conditional lock.** `templates/` is locked with `-IncludeTemplates` flag, not by default.

- When `operating-catalog.json` is intentionally created, it should be added to the manifest and the directory locked.
- The `AkashicLockStatus -IncludeTemplates` check reports template lock state separately.

## Evidence Integrity Strategy

From Phase 4.0 Section 14:

Phase 4.1 relies on pre-existing bridge capabilities. No new evidence-integrity tooling was added in this phase:
- **Content hashing at creation:** Pre-existing in `Write-HeliosIntegrityEvidence` (bridge function). Not newly implemented or verified by Phase 4.1.
- **Tamper marking:** Pre-existing detection via `Compare-HeliosProtectedEnvelope` against baseline. Not newly implemented or verified by Phase 4.1.

Neither capability has been tested against evidence tamper scenarios (Phase 4.0 test #8). Verification belongs in Phase 4.2.

Deferred to Phase 4.2+:
- Per-artifact signing
- Append-only archival (platform-dependent: Linux `chattr +a`)
- Archive strategy with time-stamped directories
- Verification that existing bridge capabilities actually detect evidence tamper

## Phase 4.0 Open Questions — Resolved

| # | Question | Phase 4.1 Answer |
|---|---|---|
| 1 | Lock granularity | Individual file locks. More precise, avoids interfering with mutable directories. |
| 2 | Unlock authorization | Human-initiated via `Invoke-HeliosRebaseline -RebaselinedBy human`. No automated unlock. |
| 3 | Rebaseline atomicity | 7-step cycle with emergency relock on failure. Not truly atomic but minimized window. |
| 4 | Cross-platform | Resolved: strategy-driven dispatch. Windows PASS, Linux/macOS pending physical machine test. |
| 5 | Evidence integrity scope | Minimum viable: content hashing + tamper marking. Signing/archival deferred. |
| 6 | Template trust scope | Conditional. Lock with `-IncludeTemplates` when templates are trusted. |
| 7 | settings.json unlock frequency | Expected to be rare. Lock by default, unlock only for config changes. |

## Semantic Gate Controls

From Phase 4.0 Section 11:

**No new tools needed.** Semantic gate enforcement (tests #4, #6, #7, #9, #10) is protected indirectly by locking the hook and policy files that contain the enforcement logic. The existing gate system already detects and denies these violations at PreToolUse time.

## Verification Checklist

Evidence files are in `evidence/phase41/`.

- [x] All 8 protected files exist in live Helios runtime — `lock-target-inventory.json`
- [x] All 8 protected files lockable via `Lock-AkashicProtectedFiles` — live fixture execution (`fixture-lock-unlock-validation.json`, step 1)
- [x] All 8 protected files unlockable via `Unlock-AkashicProtectedFiles` — live fixture execution (`fixture-lock-unlock-validation.json`, step 3)
- [x] `AkashicLockStatus` detection logic handles SID and English Everyone, checks W/D rights — `lock-status-baseline.json`
- [x] `AkashicLockStatus` reports LOCKED after live lock — live fixture execution (`fixture-lock-unlock-validation.json`, step 2)
- [x] `AkashicSettingsIntegrity` validates hook entries — verified against live `settings.json` (`settings-integrity-result.json`)
- [x] `Invoke-AkashicRebaseline` schema compliance — all terminal paths emit `schema_version` and `completed_utc` (`schema-validation-result.json`)
- [x] Emergency relock path analysis — all 8 terminal paths documented, emergency relock triggers on update/manifest failure (`rebaseline-failure-path-fixture.json`)
- [ ] `Invoke-AkashicRebaseline` completes 7-step cycle — live execution pending
- [x] `Move-AkashicStaleGateArtifacts` logic for expired pending gates — code review pass (`stale-gate-cleanup-fixture.json`)
- [x] `Move-AkashicStaleGateArtifacts` logic for orphaned inflight gates — code review pass (`stale-gate-cleanup-fixture.json`)
- [x] Mutable directories remain writable after lock operation — live fixture execution (`fixture-lock-unlock-validation.json`, step 2)
- [x] `helios-rebaseline.schema.json` validates fixture rebaseline records — fixture validates (`schema-validation-result.json`)
- [x] Phase 4.1 tools included in adapter package file list — 6 tools + 1 schema + 2 docs added (`package-tool-coverage.json`)
- [ ] Package builder, runtime bundle, and e2e install test execution — deferred (package builder path dependency, see `package-tool-coverage.json`)

### Cross-Platform Fixture Validation

`Test-AkashicOsLockFixture.ps1` creates a disposable fixture directory and runs a 7-phase lifecycle test identical on all platforms. Evidence written to `evidence/phase41/os-lock-validation/`.

| Platform | Result | Evidence |
|---|---|---|
| Windows (NTFS, icacls) | PASS | `windows.json` |
| Void Linux (chattr) | NOT_TESTED | Requires physical machine |
| macOS (chflags) | NOT_TESTED | Requires physical machine |

### Remaining gaps before Phase 4.1 complete

1. ~~**Live lock/unlock execution**~~ — Resolved: fixture validation proves icacls lock/unlock (`fixture-lock-unlock-validation.json`).
2. ~~**Live lock-status verification**~~ — Resolved: Test-HeliosLockStatus detects LOCKED and UNLOCKED states against live ACLs.
3. **Live rebaseline cycle** — Full 7-step cycle has not been executed end-to-end.
4. ~~**Mutable directory writability after lock**~~ — Resolved: all 4 mutable dirs writable while protected files locked.
5. **Package builder path dependency** — `AkashicPackage.ps1` standalone packaging deferred to Phase 5.
6. **Linux fixture test** — Requires physical Void Linux machine with chattr/lsattr and privilege path validated.
7. **macOS fixture test** — Requires physical macOS machine with chflags uchg validated.
