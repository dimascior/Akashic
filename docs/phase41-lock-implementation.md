# Phase 4.1 — Lock/Unlock/Rebaseline Tooling

**Status: Implementation draft. All verification checklist items are pending.**

## Scope

Phase 4.1 implements the lock/control tooling justified by Phase 4.0 gap evidence. Every tool traces to a Phase 4.0 decision table entry. No tool has been validated against a live Helios runtime yet.

## Platform Strategy

**Primary target: Windows.** All lock tools use `icacls` ACL operations.

| Operation | icacls Command |
|---|---|
| Lock (deny write+delete) | `icacls <file> /deny "*S-1-1-0:(W,D)"` |
| Unlock (remove deny) | `icacls <file> /remove:d "*S-1-1-0"` |
| Verify (check deny ACE) | `icacls <file>` → parse for `*S-1-1-0` DENY |

Future platform support (Phase 4.1+):
- Linux: `chattr +i` / `chattr -i`
- macOS: `chflags uchg` / `chflags nouchg`
- POSIX fallback: `chmod a-w` / `chmod u+w`

## Tools Implemented

### Protected Runtime Lock Tools (Phase 4.0 Section 9)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `Lock-HeliosProtectedFiles.ps1` | Apply deny ACLs to all protected files | Tests #1, #2, #3, #11, #12 |
| `Unlock-HeliosProtectedFiles.ps1` | Remove deny ACLs for maintenance | Inverse of lock |
| `Test-HeliosLockStatus.ps1` | Verify lock state of all targets | Verification for all lock tests |
| `Invoke-HeliosRebaseline.ps1` | Coordinated unlock→update→relock→verify | Phase 4.0 Section 15, open question #3 |

### Mutable Lifecycle Tools (Phase 4.0 Section 10)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `Move-HeliosStaleGateArtifacts.ps1` | Clean expired pending/ and orphaned inflight/ | Test #5 (stale gate) |

### External Control-Plane Tools (Phase 4.0 Section 12)

| Tool | Purpose | Phase 4.0 Evidence |
|---|---|---|
| `Test-HeliosSettingsIntegrity.ps1` | Verify settings.json hook entries | Test #11 (highest severity) |

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

The `Invoke-HeliosRebaseline` tool implements a 7-step atomic cycle:

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
| `pending/` | TTL enforcement, stale gate cleanup | `Move-HeliosStaleGateArtifacts.ps1` |
| `inflight/` | Orphan detection, age-based cleanup | `Move-HeliosStaleGateArtifacts.ps1` |
| `evidence/` | Content hashing at creation (existing via bridge) | `Write-HeliosIntegrityEvidence` in bridge |
| `blocked/` | Audit trail preservation | Lifecycle cleanup via stale artifact tool |

**Key decision:** These directories are NOT locked. Phase 4.0 test #5 explicitly requires `pending/` to remain writable.

## Settings.json Control-Plane Strategy

From Phase 4.0 Section 12:

1. **Lock** `settings.json` with `Lock-HeliosProtectedFiles -IncludeSettingsJson`.
2. **Verify** hook entries with `Test-HeliosSettingsIntegrity.ps1` as a pre-flight check.
3. **Unlock** for legitimate config changes via `Invoke-HeliosRebaseline -IncludeSettingsJson`.
4. **Re-verify** after unlock/relock that hook entries still point to Helios scripts.

## Template Trust Decision

From Phase 4.0 Section 13:

**Decision: Conditional lock.** `templates/` is locked with `-IncludeTemplates` flag, not by default.

- When `operating-catalog.json` is intentionally created, it should be added to the manifest and the directory locked.
- The `Test-HeliosLockStatus -IncludeTemplates` check reports template lock state separately.

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
| 4 | Cross-platform | Windows first (icacls). Other platforms deferred. |
| 5 | Evidence integrity scope | Minimum viable: content hashing + tamper marking. Signing/archival deferred. |
| 6 | Template trust scope | Conditional. Lock with `-IncludeTemplates` when templates are trusted. |
| 7 | settings.json unlock frequency | Expected to be rare. Lock by default, unlock only for config changes. |

## Semantic Gate Controls

From Phase 4.0 Section 11:

**No new tools needed.** Semantic gate enforcement (tests #4, #6, #7, #9, #10) is protected indirectly by locking the hook and policy files that contain the enforcement logic. The existing gate system already detects and denies these violations at PreToolUse time.

## Verification Checklist

Evidence files are in `evidence/phase41/`.

- [x] All 8 protected files exist in live Helios runtime — `lock-target-inventory.json`
- [ ] All 8 protected files lockable via `Lock-HeliosProtectedFiles` — code review pass (`lock-dryrun-result.json`), live execution pending
- [ ] All 8 protected files unlockable via `Unlock-HeliosProtectedFiles` — code review pass (`unlock-dryrun-result.json`), live execution pending
- [x] `Test-HeliosLockStatus` detection logic handles SID and localized name, checks W/D rights — `lock-status-baseline.json`
- [ ] `Test-HeliosLockStatus` reports LOCKED after live lock — live execution pending
- [x] `Test-HeliosSettingsIntegrity` validates hook entries — verified against live `settings.json` (`settings-integrity-result.json`)
- [x] `Invoke-HeliosRebaseline` schema compliance — all terminal paths emit `schema_version` and `completed_utc` (`schema-validation-result.json`)
- [x] Emergency relock path analysis — all 8 terminal paths documented, emergency relock triggers on update/manifest failure (`rebaseline-failure-path-fixture.json`)
- [ ] `Invoke-HeliosRebaseline` completes 7-step cycle — live execution pending
- [x] `Move-HeliosStaleGateArtifacts` logic for expired pending gates — code review pass (`stale-gate-cleanup-fixture.json`)
- [x] `Move-HeliosStaleGateArtifacts` logic for orphaned inflight gates — code review pass (`stale-gate-cleanup-fixture.json`)
- [ ] Mutable directories remain writable after lock operation — live execution pending
- [x] `helios-rebaseline.schema.json` validates fixture rebaseline records — fixture validates (`schema-validation-result.json`)
- [x] Phase 4.1 tools included in adapter package file list — 6 tools + 1 schema + 2 docs added (`package-tool-coverage.json`)
- [ ] Package builder, runtime bundle, and e2e install test execution — deferred (package builder path dependency, see `package-tool-coverage.json`)

### Remaining gaps before Phase 4.1 complete

1. **Live lock/unlock execution** — Lock and unlock tools have not been run against the Helios runtime. Code review passes but icacls execution is unproven.
2. **Live lock-status verification** — Test-HeliosLockStatus has not been run against locked files. Detection logic is correct by code review.
3. **Live rebaseline cycle** — Full 7-step cycle has not been executed end-to-end.
4. **Mutable directory writability after lock** — Not proven that locking protected files leaves pending/inflight/evidence/blocked writable.
5. **Package builder path dependency** — `New-HeliosAdapterPackage.ps1` still requires TCE nested path. Standalone repo packaging deferred to Phase 5.
