# Windows Helios Live Operational Raw Results

**Date:** 2026-06-28
**Machine:** DESKTOP-T3NJDBQ
**OS:** Windows 10 (10.0.19045), NTFS
**PowerShell:** 5.1.19041.6456 (Desktop)
**Validated by:** Claude Opus 4.6 + human operator

## 1. Settings Activation Proof

The active Claude settings point to the MythosJustAFable `.command-gate` hooks:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\dimas\\Desktop\\MythosJustAFable\\.command-gate\\hooks\\helios_pretooluse.ps1\"",
            "timeout": 15
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\dimas\\Desktop\\MythosJustAFable\\.command-gate\\hooks\\evidence_capture.ps1\"",
            "timeout": 15
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\dimas\\Desktop\\MythosJustAFable\\.command-gate\\hooks\\evidence_capture.ps1\"",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

Source: `C:\Users\dimas\.claude\settings.json`

All three hook points active:
- **PreToolUse** → `helios_pretooluse.ps1` (front controller: integrity check, gate validation)
- **PostToolUse** → `evidence_capture.ps1` (success evidence)
- **PostToolUseFailure** → `evidence_capture.ps1` (failure evidence)

## 2. Live Interception Proof

Command (no gate in pending/):
```
Write-Output "helios-live-interception-test"
```

Raw output:
```
GATE REQUIRED: No valid gate found in pending/ for this command.
Tier: 0. SHA256: 54dfa3f7fa403c1d7a34c8cbc5c05670145d1df6a6c557f82c2901b07d4c1906.
Category: routine.
```

The command was blocked by `helios_pretooluse.ps1`. No gate file existed in `pending/` matching the command SHA256. The hook computed the SHA256 of the command text, searched for a matching `.gate.json`, found none, and rejected execution.

## 3. Gate Approval Proof

Gate file created in `pending/`:
```json
{
  "schema_version": "command-gate.v1",
  "correlation_id": "live-test-approve-001",
  "created_utc": "2026-06-28T21:10:00Z",
  "expires_utc": "2026-06-29T02:00:00Z",
  "command": "Write-Output \"helios-live-interception-test\"",
  "command_sha256": "54dfa3f7fa403c1d7a34c8cbc5c05670145d1df6a6c557f82c2901b07d4c1906",
  "working_directory": "C:\\Users\\dimas\\Desktop\\CODEAPI",
  "shell": "powershell",
  "risk_tier": 0,
  "exit_capture": "not_applicable",
  "exit_capture_reason": "pure_output",
  "multi_command": false,
  "segments": [],
  "need": "Phase 4.2 live operational test: prove gate approval flow works",
  "expected": "Output: helios-live-interception-test",
  "actual_means": "Write-Output echoes a string to stdout",
  "next_logic": "Verify PostToolUse evidence_capture.ps1 fires after success",
  "approval_boundary": "This gate makes the command eligible for permission flow only; it does not auto-approve execution."
}
```

Same command retried:
```
Write-Output "helios-live-interception-test"
```

Raw output:
```
helios-live-interception-test
```

The gate was consumed from `pending/`, the command executed, and the output matched the gate's `expected` field.

## 4. PostToolUse Evidence Capture Proof

After the successful command in step 3, the `PostToolUse` hook fired:

```
[EVIDENCE:live-test-approve-001] Command succeeded.
Compare EXPECTED from the gate vs ACTUAL output before creating the next gate.
```

The `evidence_capture.ps1` hook:
- Identified the consumed gate by correlation_id `live-test-approve-001`
- Recorded the command as succeeded
- Moved the gate file to `evidence/` with execution metadata

## 5. PostToolUseFailure Evidence Capture Proof

Command (with gate `live-test-failure-001` in pending/):
```
Get-Content "C:\nonexistent-helios-test-file-12345.txt"
```

Gate created with:
```json
{
  "correlation_id": "live-test-failure-001",
  "command_sha256": "dd6d3e1d6cd1aef3506bb00acf04353e687142d149cb9a7a83731167e5292304",
  "risk_tier": 1,
  "expected": "Error: file not found. PostToolUseFailure hook should fire and capture evidence."
}
```

Raw output:
```
Exit code 1
Get-Content : Cannot find path 'C:\nonexistent-helios-test-file-12345.txt' because it does not exist.
At line:1 char:1
+ Get-Content "C:\nonexistent-helios-test-file-12345.txt"
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ObjectNotFound: (C:\nonexistent-...-file-12345.txt:String)
      [Get-Content], ItemNotFoundException
    + FullyQualifiedErrorId : PathNotFound,Microsoft.PowerShell.Commands.GetContentCommand
```

PostToolUseFailure hook output:
```
[EVIDENCE:live-test-failure-001] Command failed.
Compare EXPECTED from the gate vs ACTUAL output before creating the next gate.
```

The failure path works: gate consumed, command attempted, error occurred, `PostToolUseFailure` hook fired, evidence captured with the gate's correlation_id.

## 6. Manifest Integrity Verification

Command:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File integrity-check.ps1
```

### Manifest Sidecar Integrity

```
Manifest path:  C:\Users\dimas\Desktop\MythosJustAFable\.command-gate\manifest\helios-envelope.json
Computed SHA256: 3f9deb3c3ac7ceed6e1dc55e86b782bb1583b00d97f4a63313aff8c592638e37
Sidecar SHA256:  3f9deb3c3ac7ceed6e1dc55e86b782bb1583b00d97f4a63313aff8c592638e37
Match: True
```

### Protected File Hash Verification

```
hooks/evidence_capture.ps1
  expected: b7c80f66b44de5ed749d963bc1c65108af5f44cb5c5296751520db3f05f88b10
  actual:   b7c80f66b44de5ed749d963bc1c65108af5f44cb5c5296751520db3f05f88b10
  match:    True
hooks/gate_check.ps1
  expected: 004aaae86bd5ff666b191576c1a4eef12b549b214c5c6a26e83553bb1f53114c
  actual:   004aaae86bd5ff666b191576c1a4eef12b549b214c5c6a26e83553bb1f53114c
  match:    True
hooks/helios_pretooluse.ps1
  expected: 31e6e82253aa1567367b92985973f799510b3ae17b89ac4379bc6e7092cac7b3
  actual:   31e6e82253aa1567367b92985973f799510b3ae17b89ac4379bc6e7092cac7b3
  match:    True
hooks/lib/HeliosIntegrityBridge.ps1
  expected: c26f927dbe1e52fbc9da2db473fd7c69b0d21a0e1b9b915a8d4b5710b8bc8b0a
  actual:   c26f927dbe1e52fbc9da2db473fd7c69b0d21a0e1b9b915a8d4b5710b8bc8b0a
  match:    True
hooks/tier_classifier.ps1
  expected: b1bc9475898e473a829ea6c4b3f39f2e7578fe2864326cf39a18716db14bf2aa
  actual:   b1bc9475898e473a829ea6c4b3f39f2e7578fe2864326cf39a18716db14bf2aa
  match:    True
policy/command-policy.json
  expected: 838ede2f4a195d5435c6f22033ef59dca0f785a84743a74ed01f2db4a6dd6488
  actual:   838ede2f4a195d5435c6f22033ef59dca0f785a84743a74ed01f2db4a6dd6488
  match:    True

All protected hashes match: True
```

### Integrity Status

```
INTEGRITY STATUS: CLEAN
```

Manifest schema: `helios-envelope.v1`, created `2026-06-27T13:38:04Z`, rebaselined by: human.

## 7. Active Runtime Structure

```
hooks/          : True
hooks/lib/      : True
policy/         : True
manifest/       : True
pending/        : True
inflight/       : True
evidence/       : True
blocked/        : True
maintenance/    : True
templates/      : True
schemas/        : True
```

All 11 runtime directories present.

## 8. Gate Lifecycle Statistics

```
Pending gates:  34
Evidence gates: 352
```

352 consumed gate evidence files prove sustained operational use over multiple sessions, not a one-time test.

## 9. Active Runtime File Inventory

Protected files (6 with hashes in manifest):
```
hooks/helios_pretooluse.ps1          31e6e825...  (front controller)
hooks/gate_check.ps1                 004aaae8...  (command validation)
hooks/evidence_capture.ps1           b7c80f66...  (PostToolUse/PostToolUseFailure)
hooks/tier_classifier.ps1            b1bc9475...  (risk tier classification)
hooks/lib/HeliosIntegrityBridge.ps1  c26f927d...  (vendored bridge)
policy/command-policy.json           838ede2f...  (gate policy)
```

Protected files also listed in manifest paths (self-referential, no hash):
```
manifest/helios-envelope.json
manifest/helios-envelope.sha256
```

## 10. Guardrail Compliance

```
settings.json modified:              false (read-only inspection)
active runtime files modified:       false
active .command-gate files locked:    false (locking deferred to Phase 4.2 step 10)
hooks activated:                     already active (pre-existing)
live runtime path:                   C:\Users\dimas\Desktop\MythosJustAFable\.command-gate
```

## 11. Verification Summary

| Step | Description | Result |
|---|---|---|
| 1 | Settings activation (PreToolUse, PostToolUse, PostToolUseFailure) | ACTIVE |
| 2 | Live interception (command blocked without gate) | PASS |
| 3 | Gate approval (command allowed with valid gate) | PASS |
| 4 | PostToolUse evidence capture | PASS |
| 5 | PostToolUseFailure evidence capture | PASS |
| 6 | Manifest sidecar integrity | CLEAN |
| 6 | Protected file hash verification (6/6 match) | CLEAN |
| 7 | Active runtime structure (11/11 directories) | PRESENT |
| 8 | Gate lifecycle (352 evidence gates) | OPERATIONAL |
| 9 | Runtime locking | DEFERRED |

**Windows Helios live operational status: PASS**

Note: The active runtime is the pre-existing MythosJustAFable `.command-gate`, not a fresh Akashic-installer-driven install. The live verification proves the gate system is operational, not that the Akashic installer created it. Phase 4.1 separately proved the installer can prepare a valid runtime from scratch.
