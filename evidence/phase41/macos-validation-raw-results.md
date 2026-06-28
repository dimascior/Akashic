# macOS Validation Raw Results

**Date:** 2026-06-28
**Machine:** Thiss-MBP.lan
**Validated by:** Claude Opus 4.6 (1M context) + human operator

## 1. Preflight Environment

```
ProductName:    macOS
ProductVersion: 14.6.1
BuildVersion:   23G93
```

```
Darwin Thiss-MBP.lan 23.6.0 Darwin Kernel Version 23.6.0: Mon Jul 29 21:13:00 PDT 2024; root:xnu-10063.141.2~1/RELEASE_X86_64 x86_64
```

```
Architecture: x86_64
User: thispc
Working directory: /Users/thispc
```

```
pwsh: MISSING (installed during validation)
chflags: /usr/bin/chflags
ls: /bin/ls
```

```
ls -lO $HOME output:
total 0
drwx------+  9 thispc  staff  -       288 Mar 13 16:21 Desktop
drwx------+  3 thispc  staff  -        96 Mar  9 11:13 Documents
drwx------+  5 thispc  staff  -       160 Mar  9 19:42 Downloads
drwx------@ 81 thispc  staff  hidden 2592 Mar  9 22:49 Library
drwx------   4 thispc  staff  -       128 Mar 10 09:23 Movies
drwx------+  3 thispc  staff  -        96 Mar  9 11:13 Music
drwx------+  4 thispc  staff  -       128 Mar  9 11:14 Pictures
drwxr-xr-x+  4 thispc  staff  -       128 Mar  9 11:13 Public
drwxr-xr-x   4 thispc  staff  -       128 Mar  9 20:11 Wallpapers
```

## 2. PowerShell Installation

PowerShell was not present on the machine. Installed via user-level tar.gz extraction (no sudo required).

```
Download: https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/powershell-7.4.7-osx-x64.tar.gz
Install path: /Users/thispc/.local/powershell/pwsh
Symlink: /Users/thispc/.local/bin/pwsh
```

```
PSVersionTable output:
Name                           Value
----                           -----
PSVersion                      7.4.7
PSEdition                      Core
GitCommitId                    7.4.7
OS                             Darwin 23.6.0 Darwin Kernel Version 23.6.0: Mon...
Platform                       Unix
PSCompatibleVersions           {1.0, 2.0, 3.0, 4.0...}
PSRemotingProtocolVersion      2.3
SerializationVersion           1.1.0.1
WSManStackVersion              3.0
```

## 3. Akashic Repository Clone

```
mkdir -p $HOME/Engineering
cd $HOME/Engineering
git clone https://github.com/dimascior/Akashic.git
cd Akashic
git pull -> Already up to date.
git rev-parse HEAD -> 0ffacfd676d2c999478f94a8ba3943ea0d12ba31
```

Baseline confirmed: `0ffacfd676d2c999478f94a8ba3943ea0d12ba31`

## 4. Parser Validation

Command:
```
pwsh -NoProfile -Command '
$files = @(
  "./tools/Get-AkashicLockStrategy.ps1",
  "./tools/lib/AkashicLockTargets.ps1",
  "./tools/lib/AkashicLockBackend.ps1",
  "./tools/Lock-AkashicProtectedFiles.ps1",
  "./tools/Unlock-AkashicProtectedFiles.ps1",
  "./tools/AkashicLockStatus.ps1",
  "./tools/Test-AkashicOsLockFixture.ps1",
  "./tools/AkashicHeliosInstallPlan.ps1"
)
foreach ($f in $files) {
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errors) | Out-Null
  if ($errors.Count) {
    Write-Host "PARSE_FAIL $f"
    $errors | Format-List
    exit 1
  } else {
    Write-Host "PARSE_OK $f"
  }
}
'
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

## 5. macOS Lock Strategy Detection

Command:
```
pwsh -NoProfile -File ./tools/Get-AkashicLockStrategy.ps1 -RequireStrongLock
```

Raw output:
```
Name                           Value
----                           -----
platform                       macOS
backend                        chflags
implemented                    True
strength                       strong_user_immutable
requires_elevation             False
privilege_mode                 None
lock_command                   /usr/bin/chflags
unlock_command                 /usr/bin/chflags
status_command                 /bin/ls
blockers                       {}
notes                          {BSD user immutable flag (uchg) via chflags, Owner can clear flag; schg avoided for recovery safety}
```

No blockers. Backend fully resolved.

## 6. Manual chflags Smoke Test

Command:
```bash
fixture="$(mktemp -d /tmp/akashic-macos-smoke.XXXXXX)"
echo ok > "$fixture/test.txt"
ls -lO "$fixture/test.txt"
chflags uchg "$fixture/test.txt"
ls -lO "$fixture/test.txt"
echo blocked >> "$fixture/test.txt" && echo WRITE_UNEXPECTED || echo WRITE_BLOCKED
rm "$fixture/test.txt" && echo DELETE_UNEXPECTED || echo DELETE_BLOCKED
chflags nouchg "$fixture/test.txt"
rm "$fixture/test.txt"
rmdir "$fixture"
```

Raw output:
```
fixture=/tmp/akashic-macos-smoke.9lx9Jr
--- before lock ---
-rw-r--r--  1 thispc  wheel  - 3 Jun 28 10:38 /tmp/akashic-macos-smoke.9lx9Jr/test.txt
--- after lock ---
-rw-r--r--  1 thispc  wheel  uchg 3 Jun 28 10:38 /tmp/akashic-macos-smoke.9lx9Jr/test.txt
(eval):1: operation not permitted: /tmp/akashic-macos-smoke.9lx9Jr/test.txt
WRITE_BLOCKED
rm: /tmp/akashic-macos-smoke.9lx9Jr/test.txt: Operation not permitted
DELETE_BLOCKED
--- after unlock ---
-rw-r--r--  1 thispc  wheel  - 3 Jun 28 10:38 /tmp/akashic-macos-smoke.9lx9Jr/test.txt
SMOKE_TEST_PASSED
```

Observations:
- `ls -lO` shows `uchg` flag after `chflags uchg`
- Write blocked: `(eval):1: operation not permitted`
- Delete blocked: `rm: Operation not permitted`
- `chflags nouchg` restores normal access
- File deleted and temp dir removed successfully after unlock

## 7. Akashic macOS OS Lock Fixture

Command:
```
pwsh -NoProfile -File ./tools/Test-AkashicOsLockFixture.ps1 \
  -FixtureRoot /tmp/akashic-macos-lock-fixture \
  -PrivilegeMode None \
  -RequireStrongLock \
  -KeepFixture
```

Raw console output:
```
=== Akashic OS Lock Fixture Test ===
Platform: macOS
Backend:  chflags (strong_user_immutable)

Fixture root: /tmp/akashic-macos-lock-fixture
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

Evidence written: /Users/thispc/Engineering/Akashic/evidence/phase41/os-lock-validation/macos.json

=== Result: PASS ===
```

Raw tool-generated evidence JSON (written by Test-AkashicOsLockFixture.ps1, not manually authored):
```json
{
  "schema_version": "akashic-os-lock-evidence.v1",
  "timestamp_utc": "2026-06-28T14:38:32.7907190Z",
  "os_name": "macOS",
  "kernel_version": "23.6.0",
  "powershell_version": "7.4.7",
  "filesystem_type": "",
  "backend_selected": "chflags",
  "strength": "strong_user_immutable",
  "privilege_mode": "None",
  "lock_command_used": "/usr/bin/chflags uchg",
  "unlock_command_used": "/usr/bin/chflags nouchg",
  "status_command_used": "/bin/ls -lO",
  "test_path": "/tmp/akashic-macos-lock-fixture",
  "protected_files_tested": [
    "hooks/helios_pretooluse.ps1",
    "hooks/gate_check.ps1",
    "hooks/evidence_capture.ps1",
    "hooks/tier_classifier.ps1",
    "hooks/lib/HeliosIntegrityBridge.ps1",
    "policy/command-policy.json",
    "manifest/helios-envelope.json",
    "manifest/helios-envelope.sha256"
  ],
  "mutable_dirs_tested": [
    "pending",
    "inflight",
    "evidence",
    "blocked"
  ],
  "negative_write_delete_rename_results": {
    "hooks/helios_pretooluse.ps1": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "manifest/helios-envelope.sha256": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "hooks/gate_check.ps1": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "hooks/evidence_capture.ps1": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "hooks/lib/HeliosIntegrityBridge.ps1": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "manifest/helios-envelope.json": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "hooks/tier_classifier.ps1": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    },
    "policy/command-policy.json": {
      "append_blocked": true,
      "write_blocked": true,
      "delete_blocked": true,
      "rename_blocked": true
    }
  },
  "unlock_recovery_results": {
    "hooks/helios_pretooluse.ps1": true,
    "manifest/helios-envelope.sha256": true,
    "hooks/gate_check.ps1": true,
    "hooks/evidence_capture.ps1": true,
    "hooks/lib/HeliosIntegrityBridge.ps1": true,
    "manifest/helios-envelope.json": true,
    "hooks/tier_classifier.ps1": true,
    "policy/command-policy.json": true
  },
  "overall_result": "PASS",
  "remaining_limitation": "",
  "blockers": [],
  "notes": [
    "BSD user immutable flag (uchg) via chflags",
    "Owner can clear flag; schg avoided for recovery safety"
  ]
}
```

## 8. Installer PlanOnly on macOS

Disposable runtime bundle created at `/tmp/akashic-macos-bundle` with:
- `hooks/helios_pretooluse.ps1` (stub)
- `hooks/gate_check.ps1` (stub)
- `hooks/evidence_capture.ps1` (stub)
- `hooks/tier_classifier.ps1` (stub)
- `policy/command-policy.json` (stub)
- `schemas/fixture.json` (stub)
- `tools/fixture-tool.ps1` (stub)
- `docs/fixture.md` (stub)
- `tests/fixture-test.ps1` (stub)

Command:
```
pwsh -NoProfile -File ./tools/AkashicHeliosInstallPlan.ps1 \
  -AkashicRoot "$HOME/Engineering/Akashic" \
  -RuntimeBundleRoot "/tmp/akashic-macos-bundle" \
  -HeliosGateRoot "/tmp/akashic-macos-target/.command-gate" \
  -Platform macOS \
  -Mode PlanOnly \
  -EvidenceOutputDir "/tmp/akashic-macos-evidence"
```

Raw output JSON:
```json
{
  "schema_version": "akashic-helios-install-plan.v2",
  "timestamp_utc": "2026-06-28T14:39:19.5608570Z",
  "mode": "PlanOnly",
  "platform": "macOS",
  "akashic_root": "/Users/thispc/Engineering/Akashic",
  "runtime_bundle_root": "/tmp/akashic-macos-bundle",
  "helios_gate_root": "/tmp/akashic-macos-target/.command-gate",
  "claude_settings_path": "/Users/thispc/.claude/settings.json",
  "lock_strategy": {
    "backend": "chflags",
    "implemented": true,
    "strength": "strong_user_immutable",
    "requires_elevation": false,
    "privilege_mode": "None",
    "blockers": [],
    "notes": [
      "BSD user immutable flag (uchg) via chflags",
      "Owner can clear flag; schg avoided for recovery safety"
    ]
  },
  "fixture_result": "NOT_RUN",
  "manifest_status": "NOT_GENERATED",
  "phases": [
    {
      "phase": 1,
      "name": "Verify Akashic package/root",
      "status": "PASS",
      "blocking": true,
      "detail": "Akashic root verified (11 tools present): /Users/thispc/Engineering/Akashic"
    },
    {
      "phase": 2,
      "name": "Verify RuntimeBundleRoot",
      "status": "PASS",
      "blocking": true,
      "detail": "RuntimeBundleRoot verified: /tmp/akashic-macos-bundle (5 protected, 4 support files)"
    },
    {
      "phase": 3,
      "name": "Create runtime directories",
      "status": "PLAN",
      "blocking": true,
      "detail": "Target does not exist (will be created in Prepare/Activate): /tmp/akashic-macos-target/.command-gate"
    },
    {
      "phase": 4,
      "name": "Copy runtime protected files",
      "status": "PLAN",
      "blocking": true,
      "detail": "5 protected files to copy from RuntimeBundleRoot"
    },
    {
      "phase": 5,
      "name": "Copy runtime support files",
      "status": "PLAN",
      "blocking": false,
      "detail": "4 support files to copy from RuntimeBundleRoot"
    },
    {
      "phase": 6,
      "name": "Sync Akashic bridge",
      "status": "PLAN",
      "blocking": true,
      "detail": "Bridge sync planned: /Users/thispc/Engineering/Akashic/AkashicIntegrityBridge.ps1 -> /tmp/akashic-macos-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1"
    },
    {
      "phase": 7,
      "name": "Verify bridge byte identity",
      "status": "SKIP",
      "blocking": true,
      "detail": "Byte identity check deferred to Prepare/Activate"
    },
    {
      "phase": 8,
      "name": "Generate manifest",
      "status": "SKIP",
      "blocking": true,
      "detail": "Manifest generation deferred to Prepare/Activate"
    },
    {
      "phase": 9,
      "name": "Verify envelope integrity",
      "status": "SKIP",
      "blocking": true,
      "detail": "Envelope verification deferred to Prepare/Activate"
    },
    {
      "phase": 10,
      "name": "Detect lock strategy + run fixture",
      "status": "PASS",
      "blocking": true,
      "detail": "Backend: chflags, Strength: strong_user_immutable, Privilege: None"
    },
    {
      "phase": 11,
      "name": "Prepare settings activation plan",
      "status": "SKIP",
      "blocking": false,
      "detail": "Settings activation not requested"
    },
    {
      "phase": 12,
      "name": "Prepare lock activation plan",
      "status": "PLAN",
      "blocking": false,
      "detail": "Lock plan generated (fixture: NOT_RUN, backend: chflags)"
    },
    {
      "phase": 13,
      "name": "Prepare rollback plan",
      "status": "PASS",
      "blocking": false,
      "detail": "Rollback plan generated"
    },
    {
      "phase": 14,
      "name": "Write install evidence",
      "status": "SKIP",
      "blocking": false,
      "detail": "Evidence deferred to Prepare/Activate"
    }
  ],
  "bridge_sync_plan": {
    "source": "/Users/thispc/Engineering/Akashic/AkashicIntegrityBridge.ps1",
    "dest": "/tmp/akashic-macos-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1",
    "source_exists": true,
    "role": "bridge_vendor_copy",
    "verify": "SHA-256 byte identity check after copy"
  },
  "runtime_protected_copy_plan": [
    {
      "relative": "hooks/helios_pretooluse.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/helios_pretooluse.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/helios_pretooluse.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/gate_check.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/gate_check.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/gate_check.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/evidence_capture.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/evidence_capture.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/evidence_capture.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/tier_classifier.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/tier_classifier.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/tier_classifier.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "policy/command-policy.json",
      "source": "/tmp/akashic-macos-bundle/policy/command-policy.json",
      "dest": "/tmp/akashic-macos-target/.command-gate/policy/command-policy.json",
      "role": "protected_runtime"
    }
  ],
  "runtime_support_copy_plan": [
    {
      "relative": "schemas/fixture.json",
      "source": "/tmp/akashic-macos-bundle/schemas/fixture.json",
      "dest": "/tmp/akashic-macos-target/.command-gate/schemas/fixture.json",
      "role": "support"
    },
    {
      "relative": "tools/fixture-tool.ps1",
      "source": "/tmp/akashic-macos-bundle/tools/fixture-tool.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/tools/fixture-tool.ps1",
      "role": "support"
    },
    {
      "relative": "docs/fixture.md",
      "source": "/tmp/akashic-macos-bundle/docs/fixture.md",
      "dest": "/tmp/akashic-macos-target/.command-gate/docs/fixture.md",
      "role": "support"
    },
    {
      "relative": "tests/fixture-test.ps1",
      "source": "/tmp/akashic-macos-bundle/tests/fixture-test.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/tests/fixture-test.ps1",
      "role": "support"
    }
  ],
  "settings_activation_plan": null,
  "lock_activation_plan": {
    "protected_lock_targets": [
      "hooks/helios_pretooluse.ps1",
      "hooks/gate_check.ps1",
      "hooks/evidence_capture.ps1",
      "hooks/tier_classifier.ps1",
      "hooks/lib/HeliosIntegrityBridge.ps1",
      "policy/command-policy.json",
      "manifest/helios-envelope.json",
      "manifest/helios-envelope.sha256"
    ],
    "mutable_dirs": [
      "pending",
      "inflight",
      "evidence",
      "blocked"
    ],
    "include_settings_lock": false,
    "include_templates_lock": false,
    "lock_tool": "tools/Lock-AkashicProtectedFiles.ps1",
    "status_tool": "tools/AkashicLockStatus.ps1",
    "requires_approval": true,
    "lock_strategy": {
      "backend": "chflags",
      "strength": "strong_user_immutable",
      "privilege": "None"
    },
    "fixture_prerequisite": "NOT_RUN"
  },
  "rollback_plan": {
    "steps": [
      "Restore settings.json from backup: /Users/thispc/.claude/settings.json.pre-helios-backup",
      "Remove deny ACLs from locked files (Unlock-AkashicProtectedFiles)",
      "Verify no hooks active: run shell command, confirm no gate prompt",
      "Optionally remove target: /tmp/akashic-macos-target/.command-gate"
    ],
    "risk": "Low \u2014 restoring settings.json disables hooks immediately"
  },
  "install_evidence": null,
  "blockers": [],
  "overall_status": "READY"
}
```

Side effect verification after PlanOnly:
```
Target directory /tmp/akashic-macos-target: NOT CREATED (confirmed with test -d)
```

No target directories created. No files copied. No manifest generated. No settings.json modification. No locks applied. No active runtime touched.

## 9. Installer Prepare on macOS

Command:
```
pwsh -NoProfile -File ./tools/AkashicHeliosInstallPlan.ps1 \
  -AkashicRoot "$HOME/Engineering/Akashic" \
  -RuntimeBundleRoot "/tmp/akashic-macos-bundle" \
  -HeliosGateRoot "/tmp/akashic-macos-target/.command-gate" \
  -Platform macOS \
  -Mode Prepare \
  -EvidenceOutputDir "/tmp/akashic-macos-evidence"
```

Raw bridge sync output (emitted by Sync-AkashicBridge.ps1 during Prepare):
```json
{
  "dest_size": 10542,
  "dest_hash": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
  "timestamp_utc": "2026-06-28T14:39:41.8441290Z",
  "source_path": "/Users/thispc/Engineering/Akashic/AkashicIntegrityBridge.ps1",
  "source_size": 10542,
  "source_hash": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
  "byte_identical": true,
  "dest_path": "/tmp/akashic-macos-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1"
}
```

Raw manifest/envelope output (emitted by AkashicEnvelopeManifest.ps1 during Prepare):
```json
{
  "sidecar_path": "/tmp/akashic-macos-target/.command-gate/manifest/helios-envelope.sha256",
  "rebaselined_by": "installer",
  "protected_hashes": {
    "hooks/helios_pretooluse.ps1": "b42677e1a4de3cddef8e6e98c7f9dbd4f6ff05919e25ddebca9369f5e721f119",
    "hooks/tier_classifier.ps1": "95ecc37787255661afac9c343540e0b992e57ff3ac37e661be939cd74e38d772",
    "policy/command-policy.json": "fa6ac7220b72949e463db787aac1b49704d613c271fb795bfcb06db3e942cee2",
    "hooks/lib/HeliosIntegrityBridge.ps1": "8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454",
    "hooks/evidence_capture.ps1": "8b0b0c7b10db3440263e18e3e6cfd1f24d96ef11d08b86b15d89ef48dd2865c3",
    "hooks/gate_check.ps1": "bff584a8108dc665b4306647222e3cde92d66d0d390ddf0aed6409781e40597e"
  },
  "manifest_hash": "5ac2bf43c082ea49b85bcf72ee8b9a4422d0df277e4a71b7500c41c59d57af3d",
  "manifest_path": "/tmp/akashic-macos-target/.command-gate/manifest/helios-envelope.json",
  "timestamp_utc": "2026-06-28T14:39:41.9150840Z"
}
```

Raw install plan JSON:
```json
{
  "schema_version": "akashic-helios-install-plan.v2",
  "timestamp_utc": "2026-06-28T14:39:41.9926660Z",
  "mode": "Prepare",
  "platform": "macOS",
  "akashic_root": "/Users/thispc/Engineering/Akashic",
  "runtime_bundle_root": "/tmp/akashic-macos-bundle",
  "helios_gate_root": "/tmp/akashic-macos-target/.command-gate",
  "claude_settings_path": "/Users/thispc/.claude/settings.json",
  "lock_strategy": {
    "backend": "chflags",
    "implemented": true,
    "strength": "strong_user_immutable",
    "requires_elevation": false,
    "privilege_mode": "None",
    "blockers": [],
    "notes": [
      "BSD user immutable flag (uchg) via chflags",
      "Owner can clear flag; schg avoided for recovery safety"
    ]
  },
  "fixture_result": "NOT_RUN",
  "manifest_status": "CLEAN",
  "phases": [
    {
      "phase": 1,
      "name": "Verify Akashic package/root",
      "status": "PASS",
      "blocking": true,
      "detail": "Akashic root verified (11 tools present): /Users/thispc/Engineering/Akashic"
    },
    {
      "phase": 2,
      "name": "Verify RuntimeBundleRoot",
      "status": "PASS",
      "blocking": true,
      "detail": "RuntimeBundleRoot verified: /tmp/akashic-macos-bundle (5 protected, 4 support files)"
    },
    {
      "phase": 3,
      "name": "Create runtime directories",
      "status": "PASS",
      "blocking": true,
      "detail": "Target + 15 directories created: /tmp/akashic-macos-target/.command-gate"
    },
    {
      "phase": 4,
      "name": "Copy runtime protected files",
      "status": "PASS",
      "blocking": true,
      "detail": "5 protected runtime files copied"
    },
    {
      "phase": 5,
      "name": "Copy runtime support files",
      "status": "PASS",
      "blocking": false,
      "detail": "4 support files copied"
    },
    {
      "phase": 6,
      "name": "Sync Akashic bridge",
      "status": "PASS",
      "blocking": true,
      "detail": "Bridge synced: /tmp/akashic-macos-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1"
    },
    {
      "phase": 7,
      "name": "Verify bridge byte identity",
      "status": "PASS",
      "blocking": true,
      "detail": "Byte identical: 8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454"
    },
    {
      "phase": 8,
      "name": "Generate manifest",
      "status": "PASS",
      "blocking": true,
      "detail": "Manifest generated from files in final position"
    },
    {
      "phase": 9,
      "name": "Verify envelope integrity",
      "status": "PASS",
      "blocking": true,
      "detail": "Envelope integrity: CLEAN"
    },
    {
      "phase": 10,
      "name": "Detect lock strategy + run fixture",
      "status": "PASS",
      "blocking": true,
      "detail": "Backend: chflags, Strength: strong_user_immutable, Privilege: None"
    },
    {
      "phase": 11,
      "name": "Prepare settings activation plan",
      "status": "SKIP",
      "blocking": false,
      "detail": "Settings activation not requested"
    },
    {
      "phase": 12,
      "name": "Prepare lock activation plan",
      "status": "PLAN",
      "blocking": false,
      "detail": "Lock plan generated (fixture: NOT_RUN, backend: chflags)"
    },
    {
      "phase": 13,
      "name": "Prepare rollback plan",
      "status": "PASS",
      "blocking": false,
      "detail": "Rollback plan generated"
    },
    {
      "phase": 14,
      "name": "Write install evidence",
      "status": "PASS",
      "blocking": false,
      "detail": "Evidence written: /tmp/akashic-macos-evidence/install-evidence.json"
    }
  ],
  "bridge_sync_plan": {
    "source": "/Users/thispc/Engineering/Akashic/AkashicIntegrityBridge.ps1",
    "dest": "/tmp/akashic-macos-target/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1",
    "source_exists": true,
    "role": "bridge_vendor_copy",
    "verify": "SHA-256 byte identity check after copy"
  },
  "runtime_protected_copy_plan": [
    {
      "relative": "hooks/helios_pretooluse.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/helios_pretooluse.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/helios_pretooluse.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/gate_check.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/gate_check.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/gate_check.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/evidence_capture.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/evidence_capture.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/evidence_capture.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "hooks/tier_classifier.ps1",
      "source": "/tmp/akashic-macos-bundle/hooks/tier_classifier.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/hooks/tier_classifier.ps1",
      "role": "protected_runtime"
    },
    {
      "relative": "policy/command-policy.json",
      "source": "/tmp/akashic-macos-bundle/policy/command-policy.json",
      "dest": "/tmp/akashic-macos-target/.command-gate/policy/command-policy.json",
      "role": "protected_runtime"
    }
  ],
  "runtime_support_copy_plan": [
    {
      "relative": "schemas/fixture.json",
      "source": "/tmp/akashic-macos-bundle/schemas/fixture.json",
      "dest": "/tmp/akashic-macos-target/.command-gate/schemas/fixture.json",
      "role": "support"
    },
    {
      "relative": "tools/fixture-tool.ps1",
      "source": "/tmp/akashic-macos-bundle/tools/fixture-tool.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/tools/fixture-tool.ps1",
      "role": "support"
    },
    {
      "relative": "docs/fixture.md",
      "source": "/tmp/akashic-macos-bundle/docs/fixture.md",
      "dest": "/tmp/akashic-macos-target/.command-gate/docs/fixture.md",
      "role": "support"
    },
    {
      "relative": "tests/fixture-test.ps1",
      "source": "/tmp/akashic-macos-bundle/tests/fixture-test.ps1",
      "dest": "/tmp/akashic-macos-target/.command-gate/tests/fixture-test.ps1",
      "role": "support"
    }
  ],
  "settings_activation_plan": null,
  "lock_activation_plan": {
    "protected_lock_targets": [
      "hooks/helios_pretooluse.ps1",
      "hooks/gate_check.ps1",
      "hooks/evidence_capture.ps1",
      "hooks/tier_classifier.ps1",
      "hooks/lib/HeliosIntegrityBridge.ps1",
      "policy/command-policy.json",
      "manifest/helios-envelope.json",
      "manifest/helios-envelope.sha256"
    ],
    "mutable_dirs": [
      "pending",
      "inflight",
      "evidence",
      "blocked"
    ],
    "include_settings_lock": false,
    "include_templates_lock": false,
    "lock_tool": "tools/Lock-AkashicProtectedFiles.ps1",
    "status_tool": "tools/AkashicLockStatus.ps1",
    "requires_approval": true,
    "lock_strategy": {
      "backend": "chflags",
      "strength": "strong_user_immutable",
      "privilege": "None"
    },
    "fixture_prerequisite": "NOT_RUN"
  },
  "rollback_plan": {
    "steps": [
      "Restore settings.json from backup: /Users/thispc/.claude/settings.json.pre-helios-backup",
      "Remove deny ACLs from locked files (Unlock-AkashicProtectedFiles)",
      "Verify no hooks active: run shell command, confirm no gate prompt",
      "Optionally remove target: /tmp/akashic-macos-target/.command-gate"
    ],
    "risk": "Low \u2014 restoring settings.json disables hooks immediately"
  },
  "install_evidence": {
    "schema_version": "akashic-install-evidence.v1",
    "timestamp_utc": "2026-06-28T14:39:41.9899390Z",
    "mode": "Prepare",
    "platform": "macOS",
    "akashic_root": "/Users/thispc/Engineering/Akashic",
    "runtime_bundle_root": "/tmp/akashic-macos-bundle",
    "helios_gate_root": "/tmp/akashic-macos-target/.command-gate",
    "lock_strategy": {
      "backend": "chflags",
      "strength": "strong_user_immutable",
      "privilege": "None"
    },
    "fixture_result": "NOT_RUN",
    "manifest_status": "CLEAN",
    "settings_activation": "skipped",
    "lock_activation": "plan_only",
    "blockers": []
  },
  "blockers": [],
  "overall_status": "READY"
}
```

Raw install evidence JSON (written by the tool to /tmp/akashic-macos-evidence/install-evidence.json):
```json
{
  "schema_version": "akashic-install-evidence.v1",
  "timestamp_utc": "2026-06-28T14:39:41.9899390Z",
  "mode": "Prepare",
  "platform": "macOS",
  "akashic_root": "/Users/thispc/Engineering/Akashic",
  "runtime_bundle_root": "/tmp/akashic-macos-bundle",
  "helios_gate_root": "/tmp/akashic-macos-target/.command-gate",
  "lock_strategy": {
    "backend": "chflags",
    "strength": "strong_user_immutable",
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

- settings.json modified: false (active ~/.claude/settings.json was not touched during validation)
- Active Helios runtime touched: false
- Active .command-gate files locked: false
- Hooks activated: false
- Passwords/tokens in commands: none
- All fixture paths were disposable /tmp/ directories
- Disposable fixtures cleaned after evidence written (except /tmp/akashic-macos-lock-fixture retained via -KeepFixture)

## 11. Commit Record

Akashic commit: `403d6912439cf6a59e3115c0a2898bd01e8a1f2a`
Helios- commit: `af5d648d2676dd49e88184beee7ef4818249716a`
Both commits local only (push pending git authentication setup).
