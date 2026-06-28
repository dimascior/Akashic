# Windows Validation Raw Results

**Date:** 2026-06-28
**Machine:** DESKTOP-T3NJDBQ
**Validated by:** Claude Opus 4.6 + human operator

## 1. Preflight Environment

Command:
```
$PSVersionTable
[System.Environment]::OSVersion
```

Raw output:
```
Name                           Value
----                           -----
BuildVersion                   10.0.19041.6456
CLRVersion                     4.0.30319.42000
PSCompatibleVersions           1.0, 2.0, 3.0, 4.0, 5.0, 5.1.19041.6456
PSEdition                      Desktop
PSRemotingProtocolVersion      2.3
PSVersion                      5.1.19041.6456
SerializationVersion           1.1.0.1
WSManStackVersion              3.0

Platform:       Win32NT
Version:        10.0.19045.0
VersionString:  Microsoft Windows NT 10.0.19045.0
```

```
icacls: C:\WINDOWS\system32\icacls.exe
Filesystem (C:): NTFS
User: Admin
```

## 2. Repository Baselines

Command:
```
git -C C:\Users\dimas\Desktop\helios-integrity-adapter rev-parse HEAD
git -C C:\Users\dimas\Desktop\Helios- rev-parse HEAD
```

Raw output:
```
Akashic HEAD: 67eb2e4f2977e0ccc45a7089cee8f18ab852f808
Helios- HEAD: 20b88f4a3a90e56c7642c3c790587f91c1deb40c
```

## 3. Helios- Runtime Bundle Verification

Command:
```
Test-Path C:\Users\dimas\Desktop\Helios-\.command-gate\hooks\helios_pretooluse.ps1
Test-Path C:\Users\dimas\Desktop\Helios-\.command-gate\hooks\gate_check.ps1
Test-Path C:\Users\dimas\Desktop\Helios-\.command-gate\hooks\evidence_capture.ps1
Test-Path C:\Users\dimas\Desktop\Helios-\.command-gate\hooks\tier_classifier.ps1
Test-Path C:\Users\dimas\Desktop\Helios-\.command-gate\policy\command-policy.json
```

Raw output:
```
hooks\helios_pretooluse.ps1 : True
hooks\gate_check.ps1 : True
hooks\evidence_capture.ps1 : True
hooks\tier_classifier.ps1 : True
policy\command-policy.json : True

All 5 protected runtime files present: True
```

## 4. Parser Validation (8 Akashic scripts)

Raw output:
```
PARSE_OK  Get-AkashicLockStrategy.ps1
PARSE_OK  AkashicLockTargets.ps1
PARSE_OK  AkashicLockBackend.ps1
PARSE_OK  Lock-AkashicProtectedFiles.ps1
PARSE_OK  Unlock-AkashicProtectedFiles.ps1
PARSE_OK  AkashicLockStatus.ps1
PARSE_OK  Test-AkashicOsLockFixture.ps1
PARSE_OK  AkashicHeliosInstallPlan.ps1

Parsed: 8 / 8
```

## 5. Windows Lock Strategy Detection

Command:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Get-AkashicLockStrategy.ps1 -RequireStrongLock
```

Raw output:
```json
{
    "platform":  "Windows",
    "backend":  "icacls",
    "implemented":  true,
    "strength":  "strong",
    "requires_elevation":  false,
    "privilege_mode":  "None",
    "lock_command":  "icacls",
    "unlock_command":  "icacls",
    "status_command":  "icacls",
    "blockers":  [

                 ],
    "notes":  [
                  "Deny write/delete ACL via Everyone SID (*S-1-1-0)"
              ]
}
```

## 6. Windows OS Lock Fixture

Command:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-AkashicOsLockFixture.ps1 -FixtureRoot C:\Users\dimas\AppData\Local\Temp\akashic-windows-fixture-71921611 -RequireStrongLock -KeepFixture
```

Raw output:
```
=== Akashic OS Lock Fixture Test ===
Platform: Windows
Backend:  icacls (strong)

Fixture root: C:\Users\dimas\AppData\Local\Temp\akashic-windows-fixture-71921611
Fixture created with 8 protected files and 4 mutable dirs

--- Phase 1: Lock protected files ---
  LOCKED: hooks/helios_pretooluse.ps1
  LOCKED: hooks/gate_check.ps1
  LOCKED: hooks/evidence_capture.ps1
  LOCKED: hooks/tier_classifier.ps1
  LOCKED: hooks/lib/HeliosIntegrityBridge.ps1
  LOCKED: policy/command-policy.json
  LOCKED: manifest/helios-envelope.json
  LOCKED: manifest/helios-envelope.sha256

--- Phase 2: Verify status = LOCKED ---
  [LOCKED] hooks/helios_pretooluse.ps1
  [LOCKED] hooks/gate_check.ps1
  [LOCKED] hooks/evidence_capture.ps1
  [LOCKED] hooks/tier_classifier.ps1
  [LOCKED] hooks/lib/HeliosIntegrityBridge.ps1
  [LOCKED] policy/command-policy.json
  [LOCKED] manifest/helios-envelope.json
  [LOCKED] manifest/helios-envelope.sha256

--- Phase 3: Negative write/delete/rename tests ---
  [PASS] hooks/helios_pretooluse.ps1 - append=True write=True delete=True rename=True
  [PASS] hooks/gate_check.ps1 - append=True write=True delete=True rename=True
  [PASS] hooks/evidence_capture.ps1 - append=True write=True delete=True rename=True
  [PASS] hooks/tier_classifier.ps1 - append=True write=True delete=True rename=True
  [PASS] hooks/lib/HeliosIntegrityBridge.ps1 - append=True write=True delete=True rename=True
  [PASS] policy/command-policy.json - append=True write=True delete=True rename=True
  [PASS] manifest/helios-envelope.json - append=True write=True delete=True rename=True
  [PASS] manifest/helios-envelope.sha256 - append=True write=True delete=True rename=True

--- Phase 4: Mutable directories remain writable ---
  [WRITABLE] pending/
  [WRITABLE] inflight/
  [WRITABLE] evidence/
  [WRITABLE] blocked/

--- Phase 5: Unlock protected files ---
  UNLOCKED: hooks/helios_pretooluse.ps1
  UNLOCKED: hooks/gate_check.ps1
  UNLOCKED: hooks/evidence_capture.ps1
  UNLOCKED: hooks/tier_classifier.ps1
  UNLOCKED: hooks/lib/HeliosIntegrityBridge.ps1
  UNLOCKED: policy/command-policy.json
  UNLOCKED: manifest/helios-envelope.json
  UNLOCKED: manifest/helios-envelope.sha256

--- Phase 6: Verify status = UNLOCKED ---
  [UNLOCKED] hooks/helios_pretooluse.ps1
  [UNLOCKED] hooks/gate_check.ps1
  [UNLOCKED] hooks/evidence_capture.ps1
  [UNLOCKED] hooks/tier_classifier.ps1
  [UNLOCKED] hooks/lib/HeliosIntegrityBridge.ps1
  [UNLOCKED] policy/command-policy.json
  [UNLOCKED] manifest/helios-envelope.json
  [UNLOCKED] manifest/helios-envelope.sha256

--- Phase 7: Protected files writable after unlock ---
  [WRITABLE] hooks/helios_pretooluse.ps1
  [WRITABLE] hooks/gate_check.ps1
  [WRITABLE] hooks/evidence_capture.ps1
  [WRITABLE] hooks/tier_classifier.ps1
  [WRITABLE] hooks/lib/HeliosIntegrityBridge.ps1
  [WRITABLE] policy/command-policy.json
  [WRITABLE] manifest/helios-envelope.json
  [WRITABLE] manifest/helios-envelope.sha256

Evidence written: C:\Users\dimas\Desktop\helios-integrity-adapter\evidence\phase41\os-lock-validation\windows.json

=== Result: PASS ===
```

Tool-produced evidence: `evidence/phase41/os-lock-validation/windows.json` (schema `akashic-os-lock-evidence.v1`)

Fixture directory cleaned up.

## 7. Installer PlanOnly Validation

Command:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\AkashicHeliosInstallPlan.ps1 `
  -AkashicRoot "C:\Users\dimas\Desktop\helios-integrity-adapter" `
  -RuntimeBundleRoot "C:\Users\dimas\Desktop\Helios-\.command-gate" `
  -HeliosGateRoot "C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-target\.command-gate" `
  -Platform Windows `
  -Mode PlanOnly `
  -EvidenceOutputDir "C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-evidence"
```

Raw output (key fields):
```json
{
    "schema_version":  "akashic-helios-install-plan.v2",
    "mode":  "PlanOnly",
    "platform":  "Windows",
    "runtime_bundle_root":  "C:\\Users\\dimas\\Desktop\\Helios-\\.command-gate",
    "overall_status":  "READY",
    "blockers":  null,
    "phases":  [
                   {
                       "phase":  1,
                       "name":  "Verify Akashic package/root",
                       "status":  "PASS",
                       "detail":  "Akashic root verified (11 tools present): C:\\Users\\dimas\\Desktop\\helios-integrity-adapter"
                   },
                   {
                       "phase":  2,
                       "name":  "Verify RuntimeBundleRoot",
                       "status":  "PASS",
                       "detail":  "RuntimeBundleRoot verified: C:\\Users\\dimas\\Desktop\\Helios-\\.command-gate (5 protected, 0 support files)"
                   },
                   {
                       "phase":  3,
                       "name":  "Create runtime directories",
                       "status":  "PLAN",
                       "detail":  "Target does not exist (will be created in Prepare/Activate): C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate"
                   },
                   {
                       "phase":  4,
                       "name":  "Copy runtime protected files",
                       "status":  "PLAN",
                       "detail":  "5 protected files to copy from RuntimeBundleRoot"
                   },
                   {
                       "phase":  5,
                       "name":  "Copy runtime support files",
                       "status":  "SKIP",
                       "detail":  "No support files found in RuntimeBundleRoot"
                   },
                   {
                       "phase":  6,
                       "name":  "Sync Akashic bridge",
                       "status":  "PLAN",
                       "detail":  "Bridge sync planned: C:\\Users\\dimas\\Desktop\\helios-integrity-adapter\\AkashicIntegrityBridge.ps1 -\u003e C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate\\hooks\\lib\\HeliosIntegrityBridge.ps1"
                   },
                   {
                       "phase":  7,
                       "name":  "Verify bridge byte identity",
                       "status":  "SKIP",
                       "detail":  "Byte identity check deferred to Prepare/Activate"
                   },
                   {
                       "phase":  8,
                       "name":  "Generate manifest",
                       "status":  "SKIP",
                       "detail":  "Manifest generation deferred to Prepare/Activate"
                   },
                   {
                       "phase":  9,
                       "name":  "Verify envelope integrity",
                       "status":  "SKIP",
                       "detail":  "Envelope verification deferred to Prepare/Activate"
                   },
                   {
                       "phase":  10,
                       "name":  "Detect lock strategy + run fixture",
                       "status":  "PASS",
                       "detail":  "Backend: icacls, Strength: strong, Privilege: None"
                   },
                   {
                       "phase":  11,
                       "name":  "Prepare settings activation plan",
                       "status":  "SKIP",
                       "detail":  "Settings activation not requested"
                   },
                   {
                       "phase":  12,
                       "name":  "Prepare lock activation plan",
                       "status":  "PLAN",
                       "detail":  "Lock plan generated (fixture: NOT_RUN, backend: icacls)"
                   },
                   {
                       "phase":  13,
                       "name":  "Prepare rollback plan",
                       "status":  "PASS",
                       "detail":  "Rollback plan generated"
                   },
                   {
                       "phase":  14,
                       "name":  "Write install evidence",
                       "status":  "SKIP",
                       "detail":  "Evidence deferred to Prepare/Activate"
                   }
               ]
}
```

Side effects: target_dir_created=False evidence_dir_created=False (both should be False for PlanOnly)

## 8. Installer Prepare Validation

Command:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\AkashicHeliosInstallPlan.ps1 `
  -AkashicRoot "C:\Users\dimas\Desktop\helios-integrity-adapter" `
  -RuntimeBundleRoot "C:\Users\dimas\Desktop\Helios-\.command-gate" `
  -HeliosGateRoot "C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-target\.command-gate" `
  -Platform Windows `
  -Mode Prepare `
  -EvidenceOutputDir "C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-evidence"
```

Bridge sync verification:
```json
{
    "source_path":  "C:\\Users\\dimas\\Desktop\\helios-integrity-adapter\\AkashicIntegrityBridge.ps1",
    "dest_path":  "C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate\\hooks\\lib\\HeliosIntegrityBridge.ps1",
    "source_hash":  "ba6c9576cee58c561d379565e533fdef6bbc6fbf709179a33299d51d859757c7",
    "dest_hash":  "ba6c9576cee58c561d379565e533fdef6bbc6fbf709179a33299d51d859757c7",
    "byte_identical":  true,
    "source_size":  10838,
    "dest_size":  10838
}
```

## 9. Install Evidence (tool-produced)

Command:
```
Get-Content "C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-evidence\install-evidence.json" -Raw
```

Raw output:
```json
{
    "schema_version":  "akashic-install-evidence.v1",
    "timestamp_utc":  "2026-06-28T17:27:48.2404960Z",
    "mode":  "Prepare",
    "platform":  "Windows",
    "akashic_root":  "C:\\Users\\dimas\\Desktop\\helios-integrity-adapter",
    "runtime_bundle_root":  "C:\\Users\\dimas\\Desktop\\Helios-\\.command-gate",
    "helios_gate_root":  "C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate",
    "lock_strategy":  {
                          "backend":  "icacls",
                          "strength":  "strong",
                          "privilege":  "None"
                      },
    "fixture_result":  "NOT_RUN",
    "manifest_status":  "CLEAN",
    "settings_activation":  "skipped",
    "lock_activation":  "plan_only",
    "blockers":  [

                 ]
}
```

## 10. Final Prepare Result

```json
{
    "schema_version":  "akashic-helios-install-plan.v2",
    "mode":  "Prepare",
    "platform":  "Windows",
    "manifest_status":  "CLEAN",
    "overall_status":  "READY",
    "blockers":  null,
    "phases":  [
                   {
                       "phase":  1,
                       "name":  "Verify Akashic package/root",
                       "status":  "PASS",
                       "detail":  "Akashic root verified (11 tools present): C:\\Users\\dimas\\Desktop\\helios-integrity-adapter"
                   },
                   {
                       "phase":  2,
                       "name":  "Verify RuntimeBundleRoot",
                       "status":  "PASS",
                       "detail":  "RuntimeBundleRoot verified: C:\\Users\\dimas\\Desktop\\Helios-\\.command-gate (5 protected, 0 support files)"
                   },
                   {
                       "phase":  3,
                       "name":  "Create runtime directories",
                       "status":  "PASS",
                       "detail":  "Target + 15 directories created: C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate"
                   },
                   {
                       "phase":  4,
                       "name":  "Copy runtime protected files",
                       "status":  "PASS",
                       "detail":  "5 protected runtime files copied"
                   },
                   {
                       "phase":  5,
                       "name":  "Copy runtime support files",
                       "status":  "SKIP",
                       "detail":  "No support files found in RuntimeBundleRoot"
                   },
                   {
                       "phase":  6,
                       "name":  "Sync Akashic bridge",
                       "status":  "PASS",
                       "detail":  "Bridge synced: C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-target\\.command-gate\\hooks\\lib\\HeliosIntegrityBridge.ps1"
                   },
                   {
                       "phase":  7,
                       "name":  "Verify bridge byte identity",
                       "status":  "PASS",
                       "detail":  "Byte identical: ba6c9576cee58c561d379565e533fdef6bbc6fbf709179a33299d51d859757c7"
                   },
                   {
                       "phase":  8,
                       "name":  "Generate manifest",
                       "status":  "PASS",
                       "detail":  "Manifest generated from files in final position"
                   },
                   {
                       "phase":  9,
                       "name":  "Verify envelope integrity",
                       "status":  "PASS",
                       "detail":  "Envelope integrity: CLEAN"
                   },
                   {
                       "phase":  10,
                       "name":  "Detect lock strategy + run fixture",
                       "status":  "PASS",
                       "detail":  "Backend: icacls, Strength: strong, Privilege: None"
                   },
                   {
                       "phase":  11,
                       "name":  "Prepare settings activation plan",
                       "status":  "SKIP",
                       "detail":  "Settings activation not requested"
                   },
                   {
                       "phase":  12,
                       "name":  "Prepare lock activation plan",
                       "status":  "PLAN",
                       "detail":  "Lock plan generated (fixture: NOT_RUN, backend: icacls)"
                   },
                   {
                       "phase":  13,
                       "name":  "Prepare rollback plan",
                       "status":  "PASS",
                       "detail":  "Rollback plan generated"
                   },
                   {
                       "phase":  14,
                       "name":  "Write install evidence",
                       "status":  "PASS",
                       "detail":  "Evidence written: C:\\Users\\dimas\\AppData\\Local\\Temp\\akashic-windows-prepare-evidence\\install-evidence.json"
                   }
               ]
}
```

## 11. Guardrail Compliance

```
settings.json modified: false
active runtime touched: false
active .command-gate files locked: false
hooks activated: false
all target paths disposable: true
```

TargetRoot: C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-target\.command-gate
EvidenceRoot: C:\Users\dimas\AppData\Local\Temp\akashic-windows-prepare-evidence

Disposable target and evidence directories cleaned up.
