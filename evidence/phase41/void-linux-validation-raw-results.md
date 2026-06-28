# Void Linux Validation Raw Results

**Date:** 2026-06-28
**Machine:** MYPC.tail8bc78d.ts.net (MacBook Air 11" Haswell)
**Validated by:** Claude Opus 4.5 + human operator

## 1. Preflight Environment

```
ldd --version 2>&1 | head -n 1
ldd (GNU libc) 2.41
```

```
uname -a
Linux MYPC 6.12.65_1 #1 SMP PREEMPT_DYNAMIC Wed Jun 18 07:40:01 UTC 2025 x86_64 GNU/Linux
```

```
User: void (uid=1000)
Groups: wheel
sudo: passwordless (configured via /etc/sudoers.d/zz-void-nopasswd)
```

```
chattr: /usr/sbin/chattr (exists)
lsattr: /usr/sbin/lsattr (exists)
pwsh: MISSING (installed during validation)
```

## 2. PowerShell Installation

PowerShell was not present. Installed via user-level tar.gz extraction.

```
Download: https://github.com/PowerShell/PowerShell/releases/download/v7.6.3/powershell-7.6.3-linux-x64.tar.gz
Install path: /home/void/.local/opt/microsoft/powershell/7/pwsh
Symlink: /home/void/.local/bin/pwsh
```

Command:
```
pwsh -NoProfile -Command '$PSVersionTable'
```

Raw output:
```
Name                           Value
----                           -----
PSVersion                      7.6.3
PSEdition                      Core
GitCommitId                    7.6.3
OS                             Void Linux
Platform                       Unix
PSCompatibleVersions           {1.0, 2.0, 3.0, 4.0...}
PSRemotingProtocolVersion      2.4
SerializationVersion           1.1.0.1
WSManStackVersion              3.0
```

## 3. Akashic Repository Clone

```
cd /root/Engineering
git clone https://github.com/dimascior/Akashic.git
cd Akashic
git pull -> Already up to date.
git rev-parse HEAD -> 6c9c2b80758deaa327d57a3f54f11e5bbc6ef0c7
```

## 4. Parser Validation

Command:
```
pwsh -NoProfile -Command '...' (8-file parser check)
```

Raw output:
```
PARSE_OK ./tools/Get-AkashicLockStrategy.ps1
PARSE_OK ./tools/lib/AkashicLockTargets.ps1
PARSE_OK ./tools/lib/AkashicLockBackend.ps1
PARSE_OK ./tools/Lock-AkashicProtectedFiles.ps1
PARSE_OK ./tools/Unlock-AkashicProtectedFiles.ps1
PARSE_OK ./tools/AkashicLockStatus.ps1
PARSE_OK ./tools/Test-AkashicOsLockFixture.ps1
PARSE_OK ./tools/AkashicHeliosInstallPlan.ps1
```

All 8 files: PARSE_OK. Zero errors.

## 5. Void Linux Lock Strategy Detection

Command:
```
pwsh -NoProfile -File ./tools/Get-AkashicLockStrategy.ps1 -RequireStrongLock
```

Raw output:
```
Name                           Value
----                           -----
platform                       Linux
backend                        chattr
implemented                    True
strength                       strong_if_supported
requires_elevation             False
privilege_mode                 None
lock_command                   /usr/sbin/chattr
unlock_command                 /usr/sbin/chattr
status_command                 /usr/sbin/lsattr
blockers                       {}
notes                          {Linux immutable attribute (chattr +i), chattr:...}
```

No blockers. Backend fully resolved.

## 6. Akashic Void Linux OS Lock Fixture

Command:
```
pwsh -NoProfile -File ./tools/Test-AkashicOsLockFixture.ps1 \
  -FixtureRoot /tmp/akashic-lock-fixture \
  -PrivilegeMode Auto \
  -RequireStrongLock \
  -KeepFixture
```

Raw output:
```
=== Akashic OS Lock Fixture Test ===
Platform: Linux
Backend:  chattr (strong_if_supported)

Fixture root: /tmp/akashic-lock-fixture
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

Evidence written: /root/Engineering/Akashic/evidence/phase41/os-lock-validation/void-linux.json

=== Result: PASS ===
```

Fixture result summary (from void-linux.json):
```json
{
  "schema_version": "akashic-os-lock-evidence.v1",
  "timestamp_utc": "2026-06-28T14:15:08.5791520Z",
  "os_name": "Linux",
  "kernel_version": "6.12.65_1",
  "powershell_version": "7.6.3",
  "filesystem_type": "tmpfs",
  "backend_selected": "chattr",
  "strength": "strong_if_supported",
  "privilege_mode": "None",
  "lock_command_used": "/usr/sbin/chattr +i",
  "unlock_command_used": "/usr/sbin/chattr -i",
  "status_command_used": "/usr/sbin/lsattr",
  "overall_result": "PASS"
}
```

## 7. Helios- Runtime Bundle Verification

```
cd /root/Engineering
git clone https://github.com/dimascior/Helios-.git
cd Helios-
git pull -> Already up to date.
git rev-parse HEAD -> 20b88f4a3a90e56c7642c3c790587f91c1deb40c
```

Runtime bundle file check:
```
test -f .command-gate/hooks/helios_pretooluse.ps1 && echo PRETOOLUSE_OK
test -f .command-gate/hooks/gate_check.ps1 && echo GATE_CHECK_OK
test -f .command-gate/hooks/evidence_capture.ps1 && echo EVIDENCE_CAPTURE_OK
test -f .command-gate/hooks/tier_classifier.ps1 && echo TIER_CLASSIFIER_OK
test -f .command-gate/policy/command-policy.json && echo POLICY_OK
```

Raw output:
```
PRETOOLUSE_OK
GATE_CHECK_OK
EVIDENCE_CAPTURE_OK
TIER_CLASSIFIER_OK
POLICY_OK
```

All 5 protected runtime files present.

## 8. Installer PlanOnly Validation

Command:
```
pwsh -NoProfile -File ./tools/AkashicHeliosInstallPlan.ps1 \
  -AkashicRoot /root/Engineering/Akashic \
  -RuntimeBundleRoot /root/Engineering/Helios-/.command-gate \
  -HeliosGateRoot /tmp/akashic-void-prepare-target/.command-gate \
  -Platform Linux \
  -Mode PlanOnly \
  -EvidenceOutputDir /tmp/akashic-void-prepare-evidence
```

Raw output (key fields):
```json
{
  "schema_version": "akashic-helios-install-plan.v2",
  "mode": "PlanOnly",
  "platform": "Linux",
  "runtime_bundle_root": "/root/Engineering/Helios-/.command-gate",
  "phases": [
    {"phase": 1, "name": "Verify Akashic package/root", "status": "PASS"},
    {"phase": 2, "name": "Verify RuntimeBundleRoot", "status": "PASS", "detail": "RuntimeBundleRoot verified: /root/Engineering/Helios-/.command-gate (5 protected, 0 support files)"},
    {"phase": 3, "name": "Create runtime directories", "status": "PLAN"},
    {"phase": 4, "name": "Copy runtime protected files", "status": "PLAN", "detail": "5 protected files to copy from RuntimeBundleRoot"},
    {"phase": 5, "name": "Copy runtime support files", "status": "SKIP"},
    {"phase": 6, "name": "Sync Akashic bridge", "status": "PLAN"},
    {"phase": 7, "name": "Verify bridge byte identity", "status": "SKIP"},
    {"phase": 8, "name": "Generate manifest", "status": "SKIP"},
    {"phase": 9, "name": "Verify envelope integrity", "status": "SKIP"},
    {"phase": 10, "name": "Detect lock strategy + run fixture", "status": "PASS", "detail": "Backend: chattr, Strength: strong_if_supported, Privilege: None"},
    {"phase": 11, "name": "Prepare settings activation plan", "status": "SKIP"},
    {"phase": 12, "name": "Prepare lock activation plan", "status": "PLAN"},
    {"phase": 13, "name": "Prepare rollback plan", "status": "PASS"},
    {"phase": 14, "name": "Write install evidence", "status": "SKIP"}
  ],
  "blockers": [],
  "overall_status": "READY"
}
```

14 phases. No blockers. Side effects: none (PlanOnly is fully dry).

## 9. Installer Prepare Validation

Command:
```
pwsh -NoProfile -File ./tools/AkashicHeliosInstallPlan.ps1 \
  -AkashicRoot /root/Engineering/Akashic \
  -RuntimeBundleRoot /root/Engineering/Helios-/.command-gate \
  -HeliosGateRoot /tmp/akashic-void-prepare-target/.command-gate \
  -Platform Linux \
  -Mode Prepare \
  -EvidenceOutputDir /tmp/akashic-void-prepare-evidence
```

Bridge sync verification output:
```json
{
  "dest_path": "/tmp/akashic-void-prepare-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1",
  "dest_size": 10542,
  "dest_hash": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
  "source_hash": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
  "byte_identical": true,
  "source_size": 10542,
  "source_path": "/root/Engineering/Akashic/AkashicIntegrityBridge.ps1",
  "timestamp_utc": "2026-06-28T16:22:33.6985808Z"
}
```

Manifest generation output:
```json
{
  "timestamp_utc": "2026-06-28T16:22:33.7930351Z",
  "rebaselined_by": "installer",
  "protected_hashes": {
    "hooks/gate_check.ps1": "9cd34197bbc9ac5ba1c63b77c640143afabf6fe6306a8cabfe9a24d0c0ed5246",
    "hooks/tier_classifier.ps1": "9d41b12d982c0a50c706ba9ee1c17f5ebcd8ade959b7226b31019fbdbf024757",
    "policy/command-policy.json": "5e4fc670a3e03947d8ab0c5d64a1c59faf5c92dd887ee25474d147425359639f",
    "hooks/evidence_capture.ps1": "beab97ea548f0edf0826fdc7365f23adef54cba9b21257d2ed0a8902fa832e0b",
    "hooks/lib/HeliosIntegrityBridge.ps1": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
    "hooks/helios_pretooluse.ps1": "31e6e82253aa1567367b92985973f799510b3ae17b89ac4379bc6e7092cac7b3"
  },
  "manifest_hash": "5ab26b6b044d40581fbb1c3ce528b0d7365ac9ffc23ced4953bd97da56617079"
}
```

Final Prepare result (key fields):
```json
{
  "schema_version": "akashic-helios-install-plan.v2",
  "mode": "Prepare",
  "platform": "Linux",
  "manifest_status": "CLEAN",
  "phases": [
    {"phase": 1, "name": "Verify Akashic package/root", "status": "PASS"},
    {"phase": 2, "name": "Verify RuntimeBundleRoot", "status": "PASS"},
    {"phase": 3, "name": "Create runtime directories", "status": "PASS", "detail": "Target + 15 directories created"},
    {"phase": 4, "name": "Copy runtime protected files", "status": "PASS", "detail": "5 protected runtime files copied"},
    {"phase": 5, "name": "Copy runtime support files", "status": "SKIP"},
    {"phase": 6, "name": "Sync Akashic bridge", "status": "PASS"},
    {"phase": 7, "name": "Verify bridge byte identity", "status": "PASS", "detail": "Byte identical: 8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454"},
    {"phase": 8, "name": "Generate manifest", "status": "PASS"},
    {"phase": 9, "name": "Verify envelope integrity", "status": "PASS", "detail": "Envelope integrity: CLEAN"},
    {"phase": 10, "name": "Detect lock strategy + run fixture", "status": "PASS"},
    {"phase": 11, "name": "Prepare settings activation plan", "status": "SKIP"},
    {"phase": 12, "name": "Prepare lock activation plan", "status": "PLAN"},
    {"phase": 13, "name": "Prepare rollback plan", "status": "PASS"},
    {"phase": 14, "name": "Write install evidence", "status": "PASS"}
  ],
  "blockers": [],
  "overall_status": "READY"
}
```

Raw install evidence JSON (written by tool to /tmp/akashic-void-prepare-evidence/install-evidence.json):
```json
{
  "schema_version": "akashic-install-evidence.v1",
  "timestamp_utc": "2026-06-28T16:22:33.9440812Z",
  "mode": "Prepare",
  "platform": "Linux",
  "akashic_root": "/root/Engineering/Akashic",
  "runtime_bundle_root": "/root/Engineering/Helios-/.command-gate",
  "helios_gate_root": "/tmp/akashic-void-prepare-target/.command-gate",
  "lock_strategy": {
    "backend": "chattr",
    "strength": "strong_if_supported",
    "privilege": "None"
  },
  "fixture_result": "NOT_RUN",
  "manifest_status": "CLEAN",
  "settings_activation": "skipped",
  "lock_activation": "plan_only",
  "blockers": []
}
```

## 10. Guardrail Compliance

- settings.json modified: false
- Active Helios runtime touched: false
- Active .command-gate files locked: false
- Hooks activated: false
- Passwords/tokens in evidence files: none
- All fixture paths were disposable /tmp/ directories
- Disposable fixtures cleaned after evidence captured

## 11. Commit Record

Akashic commit at start: `6c9c2b80758deaa327d57a3f54f11e5bbc6ef0c7`
Helios- commit: `20b88f4a3a90e56c7642c3c790587f91c1deb40c`

## 12. Note on Evidence File

The file `evidence/phase41/installer-prepare-validation-void-linux.json` committed in `b83a525` used a fabricated schema (`akashic-installer-prepare-validation.v1`) that did not match the actual tool output. The tool outputs `akashic-install-evidence.v1` with a simpler structure. This raw results file documents the actual command outputs.
