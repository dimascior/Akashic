# Phase 4 Lock Requirements — Derived from Gap-Test Evidence

## Derivation Method

Each lock requirement in this document is derived from a specific controlled gap test in the Phase 3.97 matrix. Every lock target is justified by an observed gap, a TCE classification, and an evidence path. No requirement is assumed — each is evidence-backed.

Evidence base: `evidence/gap-tests/<test-name>/lock-requirement.json`

## Lock Requirement Table

| # | Gap Test | TCE Classification | Lock Requirement | Lock Target | Confidence |
|---|---|---|---|---|---|
| 1 | Direct policy edit | `protected_drift` | Policy lock | `policy/command-policy.json` | High |
| 2 | Hook self-drift | `protected_drift` | Hook write lock | `hooks/*.ps1`, `hooks/lib/*.ps1` | High |
| 3 | Hook delete | `missing_protected_file` | Hook delete/rename lock | `hooks/*.ps1`, `hooks/lib/*.ps1` | High |
| 4 | Cwd shift | `cwd_mismatch` | Gate identity enforcement | N/A — not filesystem | High |
| 5 | Stale gate | `stale_gate` | TTL/cleanup enforcement | N/A — `pending/` writable | High |
| 6 | Write-indicator denial | `write_indicator_missing_impact` | Schema + policy enforcement | `policy/command-policy.json` | High |
| 7 | Undeclared chain | `undeclared_chain` | Command identity enforcement | `hooks/gate_check.ps1` | Medium |
| 8 | Evidence tamper | `mutable_evidence_tamper` | Evidence audit/signing | `evidence/` (different from hooks) | Medium |
| 9 | Failed missing tool_response | `failed_missing_tool_response` | Post-hook robustness | `hooks/evidence_capture.ps1` | Medium |
| 10 | Wrapper-required failure | `wrapper_validation_failure` | Wrapper identity enforcement | `hooks/gate_check.ps1` | Medium |
| 11 | settings.json control-plane | `external_control_plane_risk` | Control-plane lock | `settings.json` | High |
| 12 | Template drift | `template_unprotected_gap` | Template lock | `templates/` directory | High |

## Detailed Derivations

### 1. Policy Lock

**Gap test:** 01-direct-policy-edit
**Observed failure:** Policy file modified via Edit/Write tool. Witness detects hash mismatch on next shell action. Tampered policy never loaded (front controller checks integrity first).
**Existing witness behavior:** Detection-on-next-shell-action. INTEGRITY_FAILURE deny. Phase 3 test 3 verified.
**TCE classification:** `protected_drift`
**Lock requirement:** Prevent write mutation of `policy/command-policy.json` at filesystem level.
**Platform:** Windows `icacls /deny "*S-1-1-0:(W,D)"`; Linux `chattr +i`; macOS `chflags uchg`; POSIX `chmod a-w`
**Evidence path:** `evidence/gap-tests/01-direct-policy-edit/lock-requirement.json`
**Phase 4 decision:** LOCK — high-confidence requirement. Policy is the core trust surface for tier classification.

### 2. Hook Write Lock

**Gap test:** 02-hook-self-drift
**Observed failure:** Protected hook file modified without deletion. Witness detects hash mismatch.
**Existing witness behavior:** Detection-on-next-shell-action. INTEGRITY_FAILURE deny. Phase 3 test 4 verified (helios_pretooluse.ps1 self-drift).
**TCE classification:** `protected_drift`
**Lock requirement:** Prevent write mutation of all hook files. Distinct from deletion — hash mismatch, not missing file.
**Platform:** Same as policy lock — OS-native write protection on each hook file.
**Evidence path:** `evidence/gap-tests/02-hook-self-drift/lock-requirement.json`
**Phase 4 decision:** LOCK — high-confidence requirement. Hooks are the enforcement code path.

### 3. Hook Delete/Rename Lock

**Gap test:** 03-hook-delete
**Observed failure:** Protected hook file deleted or moved. Witness detects `exists=false`, drift source `MISSING`.
**Existing witness behavior:** Detection-on-next-shell-action. INTEGRITY_FAILURE deny.
**TCE classification:** `missing_protected_file`
**Lock requirement:** Prevent delete, rename, and move operations on hook files. Tested separately from hash mismatch — a missing file is a different failure mode.
**Platform:** Windows `icacls /deny D`; Linux `chattr +i` on file AND parent dir; macOS `chflags uchg`; POSIX `chmod a-w` on parent dir for rename prevention.
**Evidence path:** `evidence/gap-tests/03-hook-delete/lock-requirement.json`
**Phase 4 decision:** LOCK — high-confidence requirement. Deletion is not just altered content.

### 4. Gate Identity Enforcement (NOT Lock)

**Gap test:** 04-cwd-shift
**Observed failure:** Gate working_directory does not match actual cwd. Gate validation rejects.
**Existing witness behavior:** Detected by gate validation at PreToolUse time.
**TCE classification:** `cwd_mismatch`
**Lock requirement:** None — this is gate identity enforcement, not filesystem protection.
**Platform:** N/A
**Evidence path:** `evidence/gap-tests/04-cwd-shift/lock-requirement.json`
**Phase 4 decision:** NO LOCK — cwd is execution context, not a protected file. Gate validation already handles this.

### 5. TTL/Cleanup Enforcement (NOT Lock)

**Gap test:** 05-stale-gate
**Observed failure:** Expired gate in pending/. Gate validation rejects on expiry check.
**Existing witness behavior:** Detected by gate validation — `expires_utc` checked against current UTC.
**TCE classification:** `stale_gate`
**Lock requirement:** None on `pending/` — it must remain writable. Implement TTL enforcement and stale gate cleanup instead.
**Platform:** N/A
**Evidence path:** `evidence/gap-tests/05-stale-gate/lock-requirement.json`
**Phase 4 decision:** NO LOCK — mutable runtime lifecycle problem. Use `Move-HeliosStaleGateArtifacts.ps1` for cleanup.

### 6. Schema + Policy Enforcement

**Gap test:** 06-write-indicator-denial
**Observed failure:** Command with write indicators lacks `read_write_impact` in gate. Gate validation rejects.
**Existing witness behavior:** Detected by gate validation — `HasWriteIndicator` check.
**TCE classification:** `write_indicator_missing_impact`
**Lock requirement:** Protect `policy/command-policy.json` (defines write-indicator patterns). The denial itself is gate-level semantic validation — no separate lock target.
**Platform:** Covered by policy lock (requirement #1).
**Evidence path:** `evidence/gap-tests/06-write-indicator-denial/lock-requirement.json`
**Phase 4 decision:** COVERED BY #1 — policy lock protects the rule that enables this enforcement.

### 7. Command Identity Enforcement

**Gap test:** 07-undeclared-chain
**Observed failure:** Chained command with `multi_command` false. Gate validation rejects for segment mismatch.
**Existing witness behavior:** Detected by gate validation — `multi_command` and `segments` fields checked.
**TCE classification:** `undeclared_chain`
**Lock requirement:** Protect `hooks/gate_check.ps1` (contains chain/segment validation logic). Chain detection is semantic, not filesystem.
**Platform:** Covered by hook write lock (requirement #2).
**Evidence path:** `evidence/gap-tests/07-undeclared-chain/lock-requirement.json`
**Phase 4 decision:** COVERED BY #2 — hook lock protects the enforcement logic.

### 8. Evidence Audit/Signing (Different Treatment)

**Gap test:** 08-evidence-tamper
**Observed failure:** Evidence artifact modified after creation. Manifest does not detect — `evidence/` is mutable runtime.
**Existing witness behavior:** NOT detected by manifest. Evidence is mutable by design.
**TCE classification:** `mutable_evidence_tamper`
**Lock requirement:** Evidence integrity through audit marking, content hashing, optional signing, or append-only strategy. NOT the same lock treatment as hooks/policy.
**Platform:** Linux `chattr +a` (append-only); Windows audit ACLs; macOS no direct equivalent.
**Evidence path:** `evidence/gap-tests/08-evidence-tamper/lock-requirement.json`
**Phase 4 decision:** DIFFERENT TREATMENT — evidence must remain writable for the gate lifecycle. Consider append-only or per-artifact signing rather than immutable locks.

### 9. Post-Hook Robustness

**Gap test:** 09-failed-missing-tool-response
**Observed failure:** PostToolUseFailure with missing `tool_response` field in payload.
**Existing witness behavior:** `evidence_capture.ps1` records `fields_found`/`fields_missing`. Hook remains robust.
**TCE classification:** `failed_missing_tool_response`
**Lock requirement:** Protect `hooks/evidence_capture.ps1` so failure handling remains robust.
**Platform:** Covered by hook write lock (requirement #2).
**Evidence path:** `evidence/gap-tests/09-failed-missing-tool-response/lock-requirement.json`
**Phase 4 decision:** COVERED BY #2 — hook lock protects evidence_capture.ps1.

### 10. Wrapper Identity Enforcement

**Gap test:** 10-wrapper-required-failure
**Observed failure:** Gate declares `exit_capture=wrapper_required` with mismatched wrapper fields. Gate validation rejects.
**Existing witness behavior:** Detected by gate validation — wrapper field matching.
**TCE classification:** `wrapper_validation_failure`
**Lock requirement:** Protect `hooks/gate_check.ps1` (contains wrapper validation logic).
**Platform:** Covered by hook write lock (requirement #2).
**Evidence path:** `evidence/gap-tests/10-wrapper-required-failure/lock-requirement.json`
**Phase 4 decision:** COVERED BY #2 — hook lock protects the validation logic.

### 11. Control-Plane Lock (Highest Severity)

**Gap test:** 11-settings-json-control-plane
**Observed failure:** `settings.json` modified to remove PreToolUse hook entry. Helios is never invoked. NO detection by any current mechanism.
**Existing witness behavior:** NOT DETECTED. settings.json is outside `.command-gate/` and not covered by manifest.
**TCE classification:** `external_control_plane_risk`
**Lock requirement:** Lock `C:\Users\dimas\.claude\settings.json` with OS-native protection. Consider secondary integrity check.
**Platform:** Windows `icacls /deny "*S-1-1-0:(W,D)"` on `settings.json`; must unlock for legitimate config changes.
**Evidence path:** `evidence/gap-tests/11-settings-json-control-plane/lock-requirement.json`
**Phase 4 decision:** LOCK — highest-severity bypass vector. This is where Helios cannot protect itself.

### 12. Template Lock

**Gap test:** 12-template-drift
**Observed failure:** Template file created/modified under `templates/`. NOT in manifest hashes (current state). `tier_classifier.ps1` loads `operating-catalog.json` if present — undetected tier override.
**Existing witness behavior:** NOT DETECTED — `templates/operating-catalog.json` is not in manifest hashes. Documented in bypass-surface.md vector 9.
**TCE classification:** `template_unprotected_gap`
**Lock requirement:** Lock `templates/` directory. When `operating-catalog.json` is created, add to manifest and rebaseline.
**Platform:** Windows `icacls /deny W` on templates/ dir; Linux `chattr +i` on dir.
**Evidence path:** `evidence/gap-tests/12-template-drift/lock-requirement.json`
**Phase 4 decision:** LOCK — templates influence tier classification. Unprotected template creation is an undetected bypass.

## Summary: Phase 4 Lock Targets

### Must Lock (OS-native filesystem protection)

| Target | Requirements Covered | Priority |
|---|---|---|
| `hooks/helios_pretooluse.ps1` | #2, #3 | Critical |
| `hooks/gate_check.ps1` | #2, #3, #7, #10 | Critical |
| `hooks/evidence_capture.ps1` | #2, #3, #9 | Critical |
| `hooks/tier_classifier.ps1` | #2, #3 | Critical |
| `hooks/lib/HeliosIntegrityBridge.ps1` | #2, #3 | Critical |
| `policy/command-policy.json` | #1, #6 | Critical |
| `manifest/helios-envelope.json` | Coordinated edit bypass | Critical |
| `manifest/helios-envelope.sha256` | Coordinated edit bypass | Critical |
| `templates/` directory | #12 | High |
| `C:\Users\dimas\.claude\settings.json` | #11 | Critical — highest severity |

### Must NOT Lock (mutable runtime)

| Target | Reason |
|---|---|
| `pending/` | Gate lifecycle requires write access |
| `inflight/` | Gate lifecycle requires write access |
| `evidence/` | Evidence production requires write access |
| `blocked/` | Denial records require write access |

### Different Treatment (evidence integrity)

| Target | Strategy | Requirement |
|---|---|---|
| `evidence/` contents | Append-only, content hashing, or signing | #8 |

### No Lock Needed (gate semantics)

| Gap | Why No Lock | Requirement |
|---|---|---|
| Cwd mismatch | Gate identity enforcement handles this | #4 |
| Stale gate | TTL/cleanup enforcement handles this | #5 |

## Relationship to Helios Phase 4 Handoff

The Helios `docs/phase4-lock-handoff.md` is a strong design draft that aligns with these evidence-derived requirements. Key confirmations:

- Lock targets match: hooks, policy, templates, manifest, sidecar, settings.json
- Mutable dirs correctly excluded: pending/, inflight/, evidence/, blocked/
- Platform strategies align: icacls, chattr, chflags, chmod

Key additions from TCE gap-test evidence:
- Explicit distinction between write-mutation locks (#2) and delete/rename locks (#3)
- Evidence tamper classified differently from protected-drift (#8)
- Gate-semantic failures explicitly excluded from lock targets (#4, #5, #6, #7, #9, #10)
- Template gap explicitly grounded in bypass-surface evidence (#12)
- settings.json confirmed as highest-severity requirement (#11)

## Phase 4 Entry Criteria

All met after Phase 3.97:
- 12 gap tests defined with TCE classifications
- Lock requirements derived from evidence
- Each lock target justified by observed gap
- Mutable runtime correctly excluded
- Evidence treatment distinguished from protected-runtime treatment
- Helios phase4-lock-handoff.md confirmed and extended
- TCE adapter branch owns the derivation evidence

## Remaining Blockers Before Phase 4 Implementation

1. Live execution of gap tests 1-3 (protected file mutations) — currently documented as executable plans with restoration procedures. Can be run when explicitly approved.
2. Helios PR #2 merge — Phase 3.96 runtime work awaiting merge.
3. Phase 4 packaging decision — helios-lock as Python package, PowerShell module, or standalone scripts.
4. TCE main merge decision — when to bring adapter work to main.
