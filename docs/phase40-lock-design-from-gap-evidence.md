# Phase 4.0 — Lock Design from Gap Evidence

## 1. Executive Summary

Phase 4.0 derives lock and control requirements from the Phase 3.97 controlled gap-test matrix. Each requirement traces to a specific gap test, a TCE classification, and a per-test evidence file. No requirement is assumed — each is evidence-backed.

The central question Phase 4.0 answers for each observed gap:

> Does Phase 4 need a filesystem lock, a mutable evidence control, a semantic gate control, or an external control-plane control?

Phase 4.0 produces:

- A 4-class lock/control taxonomy.
- A 12-classification gap taxonomy.
- A 12-test requirement matrix with pass/fail rules, cleanup/restoration rules, and test modes.
- Enumerated lock candidates, non-lock controls, and open decisions.
- A final decision table mapping every gap to its Phase 4 treatment.

Phase 4.0 does not implement locks. Phase 4.1 implements what Phase 4.0 justifies.

## 2. Current Implementation Baseline

After Phase 3.99.2, the TCE adapter branch contains:

| Component | State |
|---|---|
| HeliosIntegrityBridge.ps1 (7 functions) | Complete — snapshot, compare, manifest, format, rebaseline |
| Sync, manifest, integrity tools (6) | Complete — build, verify, sync, gap-test, evidence parse, matrix |
| Pester test suite (18 tests) | Complete |
| Schemas (3 JSON Schema files) | Complete — envelope, baseline, command-evidence |
| Gap-test matrix (12 tests) | Complete — `evidence/gap-tests/` with per-test plans and lock-requirement evidence |
| Phase 3.97 lock-requirements doc | Complete — `docs/phase4-lock-requirements-from-gap-tests.md` |
| Adapter package tools (3) | Complete — build, verify, install-plan |
| Runtime bundle tools (2) | Complete — build, verify |
| Combined installer + e2e simulation | Complete |
| BOM hardening | Complete — all JSON writes use UTF-8 without BOM |
| Package validation (Phase 3.99.1) | Complete — full chain PASS |
| Readback audit (Phase 3.99.2) | Complete — clean tree, psd1 parse, FileList, validation JSON, documentation consistency |

TCE main is preserved at `c594a75` with manual-only CI triggers. Main has no adapter entries.

## 3. Phase 4.0 Boundary

Phase 4.0 is documentation-only.

**In scope:**

- Lock-requirement matrix derivation from gap evidence.
- Classification taxonomy definition.
- Lock/control class assignment for each gap.
- Pass/fail rules, cleanup rules, and test modes for each gap.
- Protected runtime lock candidate enumeration.
- Mutable lifecycle control definition.
- Semantic gate enforcement scope definition.
- External control-plane protection scope definition.
- Template trust-boundary decision.
- Evidence integrity strategy definition.

**Out of scope:**

- Lock tooling implementation (Phase 4.1).
- Lock/unlock/rebaseline/verify/status commands (Phase 4.1).
- `helios_lock` package creation (Phase 4.1).
- Live lock verification evidence (Phase 4.2).
- Lock system packaging (Phase 5).
- Long-term lock verification and audit strategy (Phase 6).

## 4. Evidence Source Model

Every lock/control requirement in this document traces to one or more of these sources:

| Source | Path | Role |
|---|---|---|
| Phase 3.97 lock-requirements doc | `docs/phase4-lock-requirements-from-gap-tests.md` | Per-test derivation with TCE classifications, lock targets, platform notes |
| Per-test lock-requirement evidence | `evidence/gap-tests/<test>/lock-requirement.json` | Machine-readable evidence: classification, affected_envelope, confidence, prevention_need |
| Per-test plan evidence | `evidence/gap-tests/<test>/test-plan.json` | Setup, mutation, trigger, expected behavior, restoration steps, execution status |
| Matrix summary | `evidence/gap-tests/gap-test-matrix-summary.json` | 12-test overview with mode counts and confidence levels |
| Test definitions | `tools/New-HeliosGapTestMatrix.ps1` | Canonical test definitions with `rational_insight`, `restoration`, `platform_notes`, `helios_phase3_ref` |
| Operational observations | `docs/phase399-operational-enforcement-observations.md` | Incidental operational evidence confirming `cwd_mismatch` and `undeclared_chain` classifications |

Evidence traceability rule: if a requirement in this document cannot be traced to one of these sources, it is not an evidence-backed requirement.

## 5. Lock/Control Classes

Phase 4.0 defines four lock/control classes. Each gap test maps to exactly one class.

### 5.1 Protected Runtime Lock

**Applies to:** `hooks/`, `policy/`, `manifest/`, sidecar, and conditionally trusted `templates/`.

**Required control:** OS-native write, delete, rename, and move protection.

**Platform mechanisms:**
- Windows: `icacls /deny "*S-1-1-0:(W,D)"`
- Linux: `chattr +i`
- macOS: `chflags uchg`
- POSIX fallback: `chmod a-w`

**Rationale:** These files form the trust surface for gate enforcement. If modified, renamed, or deleted, the witness detects drift on the next shell action — but the mutation has already occurred. Prevention at the filesystem level closes this gap.

**Gap tests that map here:** #1 (direct policy edit), #2 (hook self-drift), #3 (hook delete/move), #12 (template drift, conditional).

### 5.2 Mutable Lifecycle Area

**Applies to:** `pending/`, `inflight/`, `blocked/`, live `evidence/`.

**Required control:** Must remain writable. Use TTL cleanup, lifecycle rules, audit hashes, tamper marking, optional signing, append-only archival, or archive strategy.

**Rationale:** The gate lifecycle requires write access to these directories. Gates are created in `pending/`, moved to `inflight/` during execution, and denied commands produce records in `blocked/`. Evidence is written after each command. Locking these directories would break the gate system.

**Gap tests that map here:** #5 (stale gate — TTL/cleanup), #8 (evidence tamper — integrity strategy).

### 5.3 Semantic Gate Enforcement

**Applies to:** cwd validation, stale gate TTL, chain/segment validation, wrapper identity validation, write-impact schema validation.

**Required control:** No direct filesystem lock. Protect the hook and policy files that enforce these semantic rules (covered by class 5.1).

**Rationale:** These failures are gate-level identity and schema enforcement problems. The gate system already detects and denies them at PreToolUse time. The filesystem lock implication is indirect: Phase 4.1 must protect the enforcement code (hooks, policy) so that semantic gate validation cannot be bypassed by modifying the code that performs it.

**Gap tests that map here:** #4 (cwd shift), #6 (write-indicator denial), #7 (undeclared chain), #9 (failed missing tool_response), #10 (wrapper-required failure).

### 5.4 External Control-Plane Protection

**Applies to:** Claude `settings.json` and any hook-routing configuration.

**Required control:** Lock or monitor separately because Helios may not run if this configuration is changed.

**Rationale:** `settings.json` defines the PreToolUse hook entry that activates Helios. If this file is modified to remove or change the hook entry, Helios is never invoked. No current mechanism detects this. This is outside the `.command-gate/` protected envelope and represents the highest-severity bypass vector.

**Gap tests that map here:** #11 (settings.json control-plane edit).

## 6. Gap-Test Matrix

| # | Test | TCE Classification | Phase 4 Implication | Pass/Fail Rule | Cleanup/Restoration | Test Mode |
|---|---|---|---|---|---|---|
| 1 | Direct policy edit | `protected_drift` | Policy lock requirement. `policy/command-policy.json` must be protected from unauthorized write mutation. | Pass if Helios denies next shell action with `INTEGRITY_FAILURE` and TCE maps drift to policy lock requirement. Fail if policy drift is missed or mapped only as generic drift. | Restore original policy file, regenerate/reverify manifest if needed, clear stale blocked/evidence test artifacts. | Live controlled test because mutation is reversible. |
| 2 | Hook self-drift hash mismatch | `protected_drift` | Hook write lock requirement. Protected hook files must be protected from content mutation. | Pass if altered hook exists but hash mismatch is detected and command is denied. Fail if TCE does not distinguish hook drift from policy drift. | Restore original hook bytes, rebaseline only after restoration if manifest changed, verify `CLEAN`. | Live controlled test, reversible. |
| 3 | Hook delete/move | `missing_protected_file` | Hook delete, rename, and move lock requirement. Lock design must block removal, not only writes. | Pass if missing hook produces `INTEGRITY_FAILURE` and TCE classifies as missing protected file. Fail if it is treated as normal hash mismatch only. | Move file back or restore from known-good copy, verify manifest, clear test artifacts. | Live controlled test, but only with guaranteed restore path. |
| 4 | Cwd shift | `cwd_mismatch` | Gate identity enforcement, not filesystem locking. | Pass if command is denied because actual cwd differs from gate cwd, and TCE does not convert it into a lock requirement. Fail if it is mapped to protected-file locking. | Delete stale/mismatched pending gate, clear blocked record if generated. | Live controlled test. |
| 5 | Stale gate | `stale_gate` | TTL enforcement and cleanup lifecycle, not protected lock protection. `pending/` must remain mutable. | Pass if expired gate is rejected and TCE maps it to TTL cleanup. Fail if Phase 4 tries to lock `pending/` as protected runtime. | Move expired gate to stale evidence or delete test gate. Verify pending/inflight/evidence lifecycle is clean. | Live controlled test. |
| 6 | Write-indicator denial | `write_indicator_missing_impact` | Schema enforcement and gate policy enforcement. Lock only protects the policy and hook logic that enforce this rule. | Pass if write-like command without `read_write_impact` is denied and TCE maps it to schema/gate enforcement. Fail if classified as filesystem drift. | Delete invalid gate, clear blocked record. | Live controlled test. |
| 7 | Undeclared chain | `undeclared_chain` | Command identity and segment enforcement. Lock implication is indirect: protect policy and hook logic that enforce chain validation. | Pass if chained command with `multi_command:false` or missing segments is denied. Fail if TCE treats it as protected file mutation. | Delete invalid gate, rerun only with corrected `multi_command:true` and segments if needed. | Live controlled test. |
| 8 | Evidence tamper | `mutable_evidence_tamper` | Evidence integrity strategy: signing, append-only archival, tamper marking, hash ledger, or archive strategy. Not the same lock treatment as hooks/policy. | Pass if TCE detects evidence hash change and classifies it as mutable evidence tamper, not protected runtime drift. Fail if evidence is treated like protected hook/policy drift. | Restore evidence from copy or mark tampered artifact as test evidence. Do not rebaseline protected manifest for evidence tamper. | Prefer fixture or copied evidence. Live only on duplicate artifact. |
| 9 | Failed command with missing tool_response | `failed_missing_tool_response` | Post-hook robustness and evidence schema coverage. Not filesystem locking. | Pass if TCE normalizes missing `tool_response` through `fields_found`/`fields_missing` and keeps evidence chain usable. Fail if missing field crashes parser or becomes protected drift. | Clear synthetic fixture or failed-command test artifacts. | Fixture-based or controlled failed command. |
| 10 | Wrapper-required failure | `wrapper_validation_failure` | Wrapper identity enforcement and policy/gate-level validation. Lock implication is protecting the enforcement logic, not the command itself. | Pass if mismatch in `wrapped_command`, `wrapped_command_sha256`, suffix, or wrapper reason causes denial. Fail if wrapper mismatch is allowed or misclassified. | Delete invalid wrapper gate, rerun with corrected gate only if needed. | Live controlled test. |
| 11 | settings.json control-plane edit | `external_control_plane_risk` | External control-plane lock or monitor requirement. `settings.json` can disable Helios before Helios runs. | Pass if TCE identifies this as outside `.command-gate` protected envelope and maps it to settings control-plane protection. Fail if system assumes Helios can protect itself after hook removal. | Restore exact `settings.json` backup. Verify hooks still route to `helios_pretooluse.ps1` and `evidence_capture.ps1`. | Default fixture/documented plan. Live only with explicit approval. |
| 12 | Template drift/creation | `template_drift` or `template_unprotected_gap` | Template lock or monitored-template classification, depending on whether templates are in the manifest and whether templates participate in gate trust. | Pass if TCE precisely reports whether templates are protected, conditionally protected, or unprotected. Fail if new template creation is invisible while templates affect gate behavior. | Restore original template state, remove test template, rebaseline only if templates are intentionally protected. | Live or fixture, depending on current manifest policy. |

## 7. Classification Taxonomy

### 7.1 `protected_drift`

A protected runtime file exists but its hash differs from the manifest or baseline. The file was written to without authorization. Maps to protected runtime write lock requirement.

**Evidence:** Tests #1, #2. Confidence: high. Detection: witness detects on next shell action.

### 7.2 `missing_protected_file`

A protected runtime file is absent. It was deleted, renamed, or moved. Maps to protected runtime delete, rename, and move lock requirement. Distinct from `protected_drift` — absence is a different failure mode than content mutation.

**Evidence:** Test #3. Confidence: high. Detection: snapshot shows `exists=false`, drift source `MISSING`.

### 7.3 `cwd_mismatch`

A gate identity mismatch where command SHA256 may match but `working_directory` differs from the actual shell cwd. Maps to semantic gate enforcement. Not a filesystem lock requirement.

**Evidence:** Test #4. Confidence: high. Detection: gate validation at PreToolUse time. Operationally confirmed in Phase 3.99 packaging observations.

### 7.4 `stale_gate`

An expired gate lifecycle failure. The gate's `expires_utc` is in the past. Maps to TTL cleanup and lifecycle enforcement. Not a protected runtime lock requirement. `pending/` must remain writable.

**Evidence:** Test #5. Confidence: high. Detection: gate validation checks `expires_utc` against current UTC.

### 7.5 `write_indicator_missing_impact`

A write-like command (matching write-indicator patterns in policy) lacks required `read_write_impact` declaration in the gate. Maps to gate schema enforcement and policy protection. Not a standalone filesystem lock requirement — the policy file that defines write-indicator patterns is covered by the protected runtime lock class.

**Evidence:** Test #6. Confidence: high. Detection: `HasWriteIndicator` check in `gate_check.ps1`. Operationally confirmed in Phase 3.99 packaging observations.

### 7.6 `undeclared_chain`

A chained command (containing `&&`, `||`, `|`, or `;`) is not declared as `multi_command:true` with valid `segments`. Maps to command identity and segment enforcement. Filesystem lock implication is indirect: protect `gate_check.ps1` which contains the chain validation logic.

**Evidence:** Test #7. Confidence: medium. Detection: gate validation checks `multi_command` and `segments`. Operationally confirmed in Phase 3.99 packaging observations.

### 7.7 `mutable_evidence_tamper`

Evidence artifact hash changes after creation. Evidence is mutable by design — `evidence/` is not part of the protected envelope. Maps to evidence integrity strategy: signing, append-only archival, tamper marking, hash ledger, or archive policy. Not the same lock treatment as hooks or policy.

**Evidence:** Test #8. Confidence: medium. Detection: not detected by manifest; TCE comparison can detect hash change.

### 7.8 `failed_missing_tool_response`

PostToolUseFailure or failed-command evidence lacks `tool_response` field in the payload. Maps to post-hook robustness and evidence schema coverage. Not a filesystem lock requirement. The hook (`evidence_capture.ps1`) records `fields_found`/`fields_missing` and remains robust.

**Evidence:** Test #9. Confidence: medium. Mode: fixture-only. Detection: `evidence_capture.ps1` normalizes missing fields.

### 7.9 `wrapper_validation_failure`

A gate declares `exit_capture=wrapper_required` but wrapper fields (`wrapped_command`, `wrapped_command_sha256`, suffix, wrapper reason) mismatch. Maps to wrapper identity enforcement and policy/gate-level validation. Filesystem lock implication is indirect: protect `gate_check.ps1` which contains wrapper validation logic.

**Evidence:** Test #10. Confidence: medium. Mode: fixture-only. Detection: gate validation checks wrapper field matching.

### 7.10 `external_control_plane_risk`

Hook-routing configuration (`settings.json`) can disable Helios before Helios runs. This is outside the `.command-gate/` protected envelope. No current mechanism detects this. Maps to settings.json control-plane protection or monitoring. Highest-severity bypass vector.

**Evidence:** Test #11. Confidence: high. Mode: plan-only (live execution can disable the active control plane). Detection: NOT DETECTED by current system.

### 7.11 `template_drift`

A trusted template file that is protected in the manifest has changed. Maps to template lock or monitored-template enforcement, depending on whether templates are included in the manifest and whether they participate in gate trust.

**Evidence:** Test #12. Confidence: high (conditional). Detection: detected only if templates are in manifest hashes; currently NOT detected because `templates/` contains only `.gitkeep`.

### 7.12 `template_unprotected_gap`

Templates influence gate behavior (e.g., `tier_classifier.ps1` loads `operating-catalog.json` if present) but are not included in the manifest or protected envelope. Maps to Phase 4 template protection decision: manifest inclusion, directory monitoring, or lock treatment.

**Evidence:** Test #12. Confidence: high. Detection: NOT DETECTED. Documented as bypass-surface vector 9 in Helios.

## 8. Per-Test Requirement Derivation

### Test 1 — Direct Policy Edit

**Gap test:** `01-direct-policy-edit`
**Classification:** `protected_drift`
**Lock class:** Protected runtime lock (5.1)
**Evidence:** `evidence/gap-tests/01-direct-policy-edit/lock-requirement.json`

**Observed gap:** Policy file modified via Edit/Write tool. Witness detects hash mismatch on next shell action. Tampered policy never loaded (front controller checks integrity first). Phase 3 test 3 proved detection.

**Lock requirement:** Prevent write mutation of `policy/command-policy.json` at filesystem level.

**Pass/fail rule:** Pass if Helios denies next shell action with `INTEGRITY_FAILURE` and TCE maps drift to policy lock requirement. Fail if policy drift is missed or mapped only as generic drift.

**Cleanup/restoration:** Restore original policy file, regenerate/reverify manifest if needed, clear stale blocked/evidence test artifacts.

**Test mode:** Live controlled test because mutation is reversible.

**Platform:** Windows `icacls /deny W,D`; Linux `chattr +i`; macOS `chflags uchg`; POSIX `chmod a-w`.

**Phase 4 decision:** LOCK — high-confidence requirement. Policy is the core trust surface for tier classification.

### Test 2 — Hook Self-Drift Hash Mismatch

**Gap test:** `02-hook-self-drift`
**Classification:** `protected_drift`
**Lock class:** Protected runtime lock (5.1)
**Evidence:** `evidence/gap-tests/02-hook-self-drift/lock-requirement.json`

**Observed gap:** Protected hook file modified without deletion. Witness detects hash mismatch. Phase 3 test 4 proved detection for `helios_pretooluse.ps1` self-drift.

**Lock requirement:** Prevent write mutation of all hook files. Distinct from deletion — hash mismatch, not missing file.

**Pass/fail rule:** Pass if altered hook exists but hash mismatch is detected and command is denied. Fail if TCE does not distinguish hook drift from policy drift.

**Cleanup/restoration:** Restore original hook bytes, rebaseline only after restoration if manifest changed, verify `CLEAN`.

**Test mode:** Live controlled test, reversible.

**Platform:** Same as policy lock — OS-native write protection on each hook file.

**Phase 4 decision:** LOCK — high-confidence requirement. Hooks are the enforcement code path.

### Test 3 — Hook Delete/Move

**Gap test:** `03-hook-delete`
**Classification:** `missing_protected_file`
**Lock class:** Protected runtime lock (5.1)
**Evidence:** `evidence/gap-tests/03-hook-delete/lock-requirement.json`

**Observed gap:** Protected hook file deleted or moved. Witness detects `exists=false`, drift source `MISSING`.

**Lock requirement:** Prevent delete, rename, and move operations on hook files. Tested separately from hash mismatch — a missing file is a different failure mode.

**Pass/fail rule:** Pass if missing hook produces `INTEGRITY_FAILURE` and TCE classifies as missing protected file. Fail if it is treated as normal hash mismatch only.

**Cleanup/restoration:** Move file back or restore from known-good copy, verify manifest, clear test artifacts.

**Test mode:** Live controlled test, but only with guaranteed restore path.

**Platform:** Windows `icacls /deny D` prevents delete/rename; Linux `chattr +i` on file AND parent dir; macOS `chflags uchg`; POSIX `chmod a-w` on parent dir for rename prevention.

**Phase 4 decision:** LOCK — high-confidence requirement. Deletion is not just altered content.

### Test 4 — Cwd Shift

**Gap test:** `04-cwd-shift`
**Classification:** `cwd_mismatch`
**Lock class:** Semantic gate enforcement (5.3)
**Evidence:** `evidence/gap-tests/04-cwd-shift/lock-requirement.json`

**Observed gap:** Gate `working_directory` does not match actual cwd. Gate validation rejects. Operationally confirmed during Phase 3.99 packaging work.

**Lock requirement:** None — this is gate identity enforcement, not filesystem protection.

**Pass/fail rule:** Pass if command is denied because actual cwd differs from gate cwd, and TCE does not convert it into a lock requirement. Fail if it is mapped to protected-file locking.

**Cleanup/restoration:** Delete stale/mismatched pending gate, clear blocked record if generated.

**Test mode:** Live controlled test.

**Phase 4 decision:** NO LOCK — cwd is execution context, not a protected file. Gate validation already handles this. Hook/policy locks (5.1) protect the enforcement code.

### Test 5 — Stale Gate

**Gap test:** `05-stale-gate`
**Classification:** `stale_gate`
**Lock class:** Mutable lifecycle area (5.2)
**Evidence:** `evidence/gap-tests/05-stale-gate/lock-requirement.json`

**Observed gap:** Expired gate in `pending/`. Gate validation rejects on expiry check.

**Lock requirement:** None on `pending/` — it must remain writable. Implement TTL enforcement and stale gate cleanup instead.

**Pass/fail rule:** Pass if expired gate is rejected and TCE maps it to TTL cleanup. Fail if Phase 4 tries to lock `pending/` as protected runtime.

**Cleanup/restoration:** Move expired gate to stale evidence or delete test gate. Verify pending/inflight/evidence lifecycle is clean.

**Test mode:** Live controlled test.

**Phase 4 decision:** NO LOCK — mutable runtime lifecycle problem. Use cleanup tooling (e.g., `Move-HeliosStaleGateArtifacts`) for hygiene.

### Test 6 — Write-Indicator Denial

**Gap test:** `06-write-indicator-denial`
**Classification:** `write_indicator_missing_impact`
**Lock class:** Semantic gate enforcement (5.3)
**Evidence:** `evidence/gap-tests/06-write-indicator-denial/lock-requirement.json`

**Observed gap:** Command with write indicators lacks `read_write_impact` in gate. Gate validation rejects. Operationally confirmed during Phase 3.99 packaging work.

**Lock requirement:** Protect `policy/command-policy.json` (defines write-indicator patterns). The denial itself is gate-level semantic validation — no separate lock target.

**Pass/fail rule:** Pass if write-like command without `read_write_impact` is denied and TCE maps it to schema/gate enforcement. Fail if classified as filesystem drift.

**Cleanup/restoration:** Delete invalid gate, clear blocked record.

**Test mode:** Live controlled test.

**Phase 4 decision:** COVERED BY TEST #1 — policy lock protects the rule that enables this enforcement.

### Test 7 — Undeclared Chain

**Gap test:** `07-undeclared-chain`
**Classification:** `undeclared_chain`
**Lock class:** Semantic gate enforcement (5.3)
**Evidence:** `evidence/gap-tests/07-undeclared-chain/lock-requirement.json`

**Observed gap:** Chained command with `multi_command:false`. Gate validation rejects for segment mismatch. Operationally confirmed during Phase 3.99 packaging work.

**Lock requirement:** Protect `hooks/gate_check.ps1` (contains chain/segment validation logic). Chain detection is semantic, not filesystem.

**Pass/fail rule:** Pass if chained command with `multi_command:false` or missing segments is denied. Fail if TCE treats it as protected file mutation.

**Cleanup/restoration:** Delete invalid gate, rerun only with corrected `multi_command:true` and segments if needed.

**Test mode:** Live controlled test.

**Phase 4 decision:** COVERED BY TEST #2 — hook lock protects the enforcement logic.

### Test 8 — Evidence Tamper

**Gap test:** `08-evidence-tamper`
**Classification:** `mutable_evidence_tamper`
**Lock class:** Mutable lifecycle area (5.2)
**Evidence:** `evidence/gap-tests/08-evidence-tamper/lock-requirement.json`

**Observed gap:** Evidence artifact modified after creation. Manifest does not detect — `evidence/` is mutable runtime.

**Lock requirement:** Evidence integrity through audit marking, content hashing, optional signing, or append-only strategy. NOT the same lock treatment as hooks/policy.

**Pass/fail rule:** Pass if TCE detects evidence hash change and classifies it as mutable evidence tamper, not protected runtime drift. Fail if evidence is treated like protected hook/policy drift.

**Cleanup/restoration:** Restore evidence from copy or mark tampered artifact as test evidence. Do not rebaseline protected manifest for evidence tamper.

**Test mode:** Prefer fixture or copied evidence. Live only on duplicate artifact.

**Platform:** Linux `chattr +a` (append-only); Windows audit ACLs; macOS no direct equivalent.

**Phase 4 decision:** DIFFERENT TREATMENT — evidence must remain writable for the gate lifecycle. Consider append-only or per-artifact signing rather than immutable locks.

### Test 9 — Failed Command with Missing tool_response

**Gap test:** `09-failed-missing-tool-response`
**Classification:** `failed_missing_tool_response`
**Lock class:** Semantic gate enforcement (5.3)
**Evidence:** `evidence/gap-tests/09-failed-missing-tool-response/lock-requirement.json`

**Observed gap:** PostToolUseFailure with missing `tool_response` field in payload.

**Lock requirement:** Protect `hooks/evidence_capture.ps1` so failure handling remains robust.

**Pass/fail rule:** Pass if TCE normalizes missing `tool_response` through `fields_found`/`fields_missing` and keeps evidence chain usable. Fail if missing field crashes parser or becomes protected drift.

**Cleanup/restoration:** Clear synthetic fixture or failed-command test artifacts.

**Test mode:** Fixture-based or controlled failed command.

**Phase 4 decision:** COVERED BY TEST #2 — hook lock protects `evidence_capture.ps1`.

### Test 10 — Wrapper-Required Failure

**Gap test:** `10-wrapper-required-failure`
**Classification:** `wrapper_validation_failure`
**Lock class:** Semantic gate enforcement (5.3)
**Evidence:** `evidence/gap-tests/10-wrapper-required-failure/lock-requirement.json`

**Observed gap:** Gate declares `exit_capture=wrapper_required` with mismatched wrapper fields. Gate validation rejects.

**Lock requirement:** Protect `hooks/gate_check.ps1` (contains wrapper validation logic).

**Pass/fail rule:** Pass if mismatch in `wrapped_command`, `wrapped_command_sha256`, suffix, or wrapper reason causes denial. Fail if wrapper mismatch is allowed or misclassified.

**Cleanup/restoration:** Delete invalid wrapper gate, rerun with corrected gate only if needed.

**Test mode:** Live controlled test.

**Phase 4 decision:** COVERED BY TEST #2 — hook lock protects the validation logic.

### Test 11 — settings.json Control-Plane Edit

**Gap test:** `11-settings-json-control-plane`
**Classification:** `external_control_plane_risk`
**Lock class:** External control-plane protection (5.4)
**Evidence:** `evidence/gap-tests/11-settings-json-control-plane/lock-requirement.json`

**Observed gap:** `settings.json` modified to remove PreToolUse hook entry. Helios is never invoked. NO detection by any current mechanism. Highest-severity bypass vector.

**Lock requirement:** Lock `settings.json` with OS-native protection. Consider secondary integrity check.

**Pass/fail rule:** Pass if TCE identifies this as outside `.command-gate` protected envelope and maps it to settings control-plane protection. Fail if system assumes Helios can protect itself after hook removal.

**Cleanup/restoration:** Restore exact `settings.json` backup. Verify hooks still route to `helios_pretooluse.ps1` and `evidence_capture.ps1`.

**Test mode:** Default fixture/documented plan. Live only with explicit approval (can disable the active control plane).

**Platform:** Windows `icacls /deny W,D` on `settings.json`; must unlock for legitimate Claude Code config changes.

**Phase 4 decision:** LOCK — highest-severity bypass vector. This is where Helios cannot protect itself.

### Test 12 — Template Drift/Creation

**Gap test:** `12-template-drift`
**Classification:** `template_drift` or `template_unprotected_gap`
**Lock class:** Protected runtime lock (5.1, conditional)
**Evidence:** `evidence/gap-tests/12-template-drift/lock-requirement.json`

**Observed gap:** Template file created/modified under `templates/`. NOT in manifest hashes (current state). `tier_classifier.ps1` loads `operating-catalog.json` if present — undetected tier override. Documented as bypass-surface vector 9 in Helios.

**Lock requirement:** Conditional. Lock `templates/` directory if templates participate in gate trust. When `operating-catalog.json` is created, add to manifest and rebaseline.

**Pass/fail rule:** Pass if TCE precisely reports whether templates are protected, conditionally protected, or unprotected. Fail if new template creation is invisible while templates affect gate behavior.

**Cleanup/restoration:** Restore original template state, remove test template, rebaseline only if templates are intentionally protected.

**Test mode:** Live or fixture, depending on current manifest policy.

**Platform:** Windows `icacls /deny W` on `templates/` dir; Linux `chattr +i` on dir; macOS `chflags uchg` on dir.

**Phase 4 decision:** CONDITIONAL LOCK — see Section 13 (Template Trust-Boundary Decision).

## 9. Protected Runtime Lock Candidates

These files require OS-native filesystem protection (write, delete, rename, move):

| Lock Target | Requirements Covered | Priority | Evidence Source |
|---|---|---|---|
| `hooks/helios_pretooluse.ps1` | #2, #3 | Critical | Tests 2, 3 |
| `hooks/gate_check.ps1` | #2, #3, #7, #10 | Critical | Tests 2, 3, 7, 10 |
| `hooks/evidence_capture.ps1` | #2, #3, #9 | Critical | Tests 2, 3, 9 |
| `hooks/tier_classifier.ps1` | #2, #3 | Critical | Tests 2, 3 |
| `hooks/lib/HeliosIntegrityBridge.ps1` | #2, #3 | Critical | Tests 2, 3 |
| `policy/command-policy.json` | #1, #6 | Critical | Tests 1, 6 |
| `manifest/helios-envelope.json` | Coordinated edit bypass | Critical | Derived from manifest trust model |
| `manifest/helios-envelope.sha256` | Coordinated edit bypass | Critical | Derived from sidecar trust model |
| `templates/` directory | #12 (conditional) | High | Test 12 |
| `settings.json` (external) | #11 | Critical — highest severity | Test 11 |

## 10. Mutable Lifecycle Non-Lock Controls

These directories must remain writable. They receive lifecycle controls, not filesystem locks:

| Directory | Why Writable | Recommended Controls |
|---|---|---|
| `pending/` | Gate creation requires write access | TTL enforcement (expires_utc check), stale gate cleanup, lifecycle hygiene tooling |
| `inflight/` | Gate movement during execution | Lifecycle state tracking, cleanup of orphaned inflight gates |
| `evidence/` | Evidence production after each command | Content hashing at creation time, tamper marking, optional per-artifact signing, append-only archival strategy |
| `blocked/` | Denial records written on rejected commands | Audit trail preservation, lifecycle cleanup of aged records |

**Key distinction:** Mutable lifecycle artifacts are not less important than protected runtime files. They require different controls because their lifecycle demands write access. Evidence tamper is a real threat (#8) but the response is integrity verification, not immutability.

## 11. Semantic Gate Enforcement Controls

These gap tests identify gate-level enforcement problems. They do not require direct filesystem locks. Their filesystem lock implication is indirect: protect the hook and policy files that contain the enforcement logic.

| Test | Gap Class | Enforcement Mechanism | Protected By |
|---|---|---|---|
| #4 Cwd shift | `cwd_mismatch` | `working_directory` field validation in gate_check.ps1 | Hook lock (#2) |
| #6 Write-indicator denial | `write_indicator_missing_impact` | `HasWriteIndicator` check against `read_write_impact.writes` | Policy lock (#1) + Hook lock (#2) |
| #7 Undeclared chain | `undeclared_chain` | `multi_command` and `segments` validation in gate_check.ps1 | Hook lock (#2) |
| #9 Failed missing tool_response | `failed_missing_tool_response` | `fields_found`/`fields_missing` normalization in evidence_capture.ps1 | Hook lock (#2) |
| #10 Wrapper-required failure | `wrapper_validation_failure` | Wrapper field matching in gate_check.ps1 | Hook lock (#2) |

**Design rule:** If Phase 4.1 were to create separate filesystem locks for cwd validation or chain detection, it would be over-engineering. These are code-level enforcement behaviors. The correct Phase 4.1 action is to lock the code files that perform the enforcement, not to create filesystem artifacts for each semantic rule.

## 12. External Control-Plane Controls

`settings.json` (`C:\Users\dimas\.claude\settings.json`) is outside the `.command-gate/` protected envelope. It defines the PreToolUse and PostToolUse hook entries that activate Helios.

**Threat model:** If `settings.json` is modified to remove the PreToolUse hook entry, Helios is never invoked. The entire gate system becomes inert. No current mechanism detects this change.

**Required control:** OS-native lock (write and delete protection) on `settings.json`, with an explicit unlock workflow for legitimate Claude Code configuration changes.

**Unlock workflow (Phase 4.1 design consideration):**

1. Unlock `settings.json` with explicit authorization.
2. Make the configuration change.
3. Re-lock `settings.json`.
4. Verify hook entry is still present.
5. Run a smoke test (any gated command) to confirm gate system is active.

**Secondary integrity check (Phase 4.1 design consideration):** A pre-flight check that verifies `settings.json` still contains the expected hook entries before trusting that Helios is active. This would catch cases where the lock was bypassed or removed.

## 13. Template Trust-Boundary Decision

`templates/` is conditional. It is not automatically part of the protected runtime lock set.

**Current state:** `templates/` exists in the Helios runtime bundle with a `.gitkeep` file. `templates/operating-catalog.json` is not present. `tier_classifier.ps1` loads `operating-catalog.json` if it exists. If present, it can override tier classification.

**Decision framework:**

- If templates are **inert scaffolding** (no operational use, no files loaded by enforcement code): classify as monitored or excluded from protected runtime locks.
- If templates **participate in gate creation, policy trust, command authorization, or any runtime authority path**: classify as protected runtime lock candidates. Phase 4.1 must protect template creation, modification, deletion, rename, and move.
- If templates are **not currently in the manifest but can affect gate behavior** (current state for `operating-catalog.json`): classify the gap as `template_unprotected_gap` and decide whether Phase 4.1 should add manifest inclusion, directory monitoring, or lock treatment.

**Current classification:** `template_unprotected_gap` — templates can influence `tier_classifier.ps1` behavior but are not in the manifest. This is a known bypass-surface vector (Helios vector 9).

**Phase 4.0 recommendation:** Treat `templates/` as conditionally protected. Phase 4.1 should:

1. Lock the `templates/` directory against unauthorized writes.
2. When a trusted template is intentionally created (e.g., `operating-catalog.json`), add it to the manifest and rebaseline.
3. Monitor for unauthorized template creation that would bypass tier classification.

## 14. Evidence Integrity Strategy

Evidence (`evidence/`) is mutable by design but must maintain integrity for audit and trust purposes.

**Threat:** Evidence artifact modified after creation (test #8). The manifest does not detect this because `evidence/` is outside the protected envelope.

**Recommended controls (for Phase 4.1 implementation):**

| Control | Description | Platform Support |
|---|---|---|
| Content hashing at creation | Hash each evidence artifact at write time and record in a local hash ledger | All platforms |
| Tamper marking | If hash mismatch is detected on later read, mark artifact as tampered rather than silently accepting | All platforms |
| Optional per-artifact signing | Sign evidence artifacts with a session key; verify on read | All platforms (software signing) |
| Append-only archival | Mark evidence files as append-only after initial write | Linux `chattr +a`; Windows audit ACLs; macOS limited support |
| Archive strategy | Move completed evidence to a time-stamped archive directory with integrity summary | All platforms |

**Key distinction from protected runtime locks:** Evidence integrity is about detecting and marking tampering after the fact. Protected runtime locks are about preventing mutation before it occurs. Evidence artifacts cannot be immutably locked because the gate lifecycle writes to them.

## 15. Phase 4.1 Implementation Prerequisites

Phase 4.1 can begin when Phase 4.0 is complete. It needs:

1. **This document** — the lock-design specification.
2. **Lock candidate list** (Section 9) — exact files to protect.
3. **Mutable lifecycle list** (Section 10) — exact directories that must remain writable.
4. **Platform mechanism decisions** — which OS-native lock mechanism to use (icacls, chattr, chflags, chmod).
5. **Unlock workflow design** — how to temporarily unlock for maintenance rebaseline.
6. **Template trust decision** (Section 13) — whether templates are protected or monitored.
7. **Evidence integrity approach** (Section 14) — which evidence controls to implement.

Phase 4.1 must implement:

- `Lock-HeliosProtectedFiles` — apply OS-native locks to all protected runtime lock candidates.
- `Unlock-HeliosProtectedFiles` — temporarily remove locks for maintenance rebaseline.
- `Test-HeliosLockStatus` — verify all locks are in place.
- `Invoke-HeliosRebaseline` — coordinated unlock → update → relock → verify cycle.

## 16. Phase 4.2 Verification Prerequisites

Phase 4.2 runs live lock verification evidence. It needs:

1. **Phase 4.1 lock tooling** — locks must be in place before verification.
2. **Gap-test matrix** (Section 6) — pass/fail rules and test modes for each test.
3. **Cleanup/restoration procedures** — from per-test derivations (Section 8).
4. **Controlled test plan** — which tests run live, which use fixtures, which are plan-only.

Phase 4.2 executes the 12 gap tests against a locked runtime and records evidence of lock effectiveness.

## 17. Phase 5 Packaging Boundary

Phase 5 packages the lock system. It needs:

1. **Phase 4.1 lock tooling** — the tools to package.
2. **Phase 4.2 verification results** — evidence that locks work.
3. **Existing packaging architecture** (Phase 3.98–3.99.1) — adapter package builder, runtime bundle builder, combined install plan, e2e simulation.

Phase 5 extends the existing two-package model to include lock tooling in the adapter package and lock activation in the runtime bundle.

## 18. Phase 6 Long-Term Audit Boundary

Phase 6 defines long-term lock verification and audit strategy. It needs:

1. **Phase 4.2 verification evidence** — initial lock effectiveness proof.
2. **Evidence integrity strategy** (Section 14) — how to maintain evidence trust over time.
3. **Audit schedule** — periodic re-verification cadence.
4. **Drift response procedures** — what happens when lock verification detects drift.

Phase 6 is the final phase of the integrity-witness roadmap.

## 19. Open Questions

These decisions remain for Phase 4.1:

1. **Lock granularity:** Lock individual files or lock parent directories? Individual file locks are more precise but require per-file management. Directory locks prevent unauthorized file creation but may interfere with legitimate operations.

2. **Unlock authorization:** How is unlock authorization granted? Options: explicit gate with risk_tier 3, separate unlock key, or human confirmation.

3. **Rebaseline atomicity:** Can unlock → update → manifest regenerate → relock be made atomic? If interrupted, what is the recovery path?

4. **Cross-platform consistency:** Should Phase 4.1 implement all platform mechanisms (icacls, chattr, chflags, chmod) or focus on Windows first (primary development platform)?

5. **Evidence integrity implementation scope:** Which evidence controls (Section 14) should Phase 4.1 implement? All five, or a minimum viable set?

6. **Template trust scope:** Should `operating-catalog.json` be added to the manifest now (before it exists) or only when it is intentionally created?

7. **settings.json unlock frequency:** How often are legitimate `settings.json` changes expected? This affects whether lock/unlock should be lightweight or ceremonial.

## 20. Final Phase 4.0 Decision Table

| # | Test | Classification | Lock Class | Lock Target | Control Type | Evidence Confidence | Phase 4.1 Action |
|---|---|---|---|---|---|---|---|
| 1 | Direct policy edit | `protected_drift` | Protected runtime lock | `policy/command-policy.json` | OS-native write/delete lock | High | LOCK |
| 2 | Hook self-drift | `protected_drift` | Protected runtime lock | `hooks/*.ps1`, `hooks/lib/*.ps1` | OS-native write/delete lock | High | LOCK |
| 3 | Hook delete/move | `missing_protected_file` | Protected runtime lock | `hooks/*.ps1`, `hooks/lib/*.ps1` | OS-native delete/rename lock | High | LOCK |
| 4 | Cwd shift | `cwd_mismatch` | Semantic gate enforcement | N/A | Gate identity validation | High | NO LOCK — covered by #2 |
| 5 | Stale gate | `stale_gate` | Mutable lifecycle area | `pending/` (writable) | TTL cleanup, lifecycle hygiene | High | NO LOCK — cleanup tooling |
| 6 | Write-indicator denial | `write_indicator_missing_impact` | Semantic gate enforcement | `policy/command-policy.json` | Schema/policy enforcement | High | COVERED BY #1 |
| 7 | Undeclared chain | `undeclared_chain` | Semantic gate enforcement | `hooks/gate_check.ps1` | Command identity enforcement | Medium | COVERED BY #2 |
| 8 | Evidence tamper | `mutable_evidence_tamper` | Mutable lifecycle area | `evidence/` (writable) | Integrity strategy | Medium | DIFFERENT TREATMENT |
| 9 | Failed missing tool_response | `failed_missing_tool_response` | Semantic gate enforcement | `hooks/evidence_capture.ps1` | Post-hook robustness | Medium | COVERED BY #2 |
| 10 | Wrapper-required failure | `wrapper_validation_failure` | Semantic gate enforcement | `hooks/gate_check.ps1` | Wrapper identity enforcement | Medium | COVERED BY #2 |
| 11 | settings.json control-plane | `external_control_plane_risk` | External control-plane | `settings.json` | OS-native lock + unlock workflow | High | LOCK — highest severity |
| 12 | Template drift/creation | `template_drift` / `template_unprotected_gap` | Protected runtime lock (conditional) | `templates/` directory | Conditional lock + manifest inclusion | High | CONDITIONAL LOCK |
