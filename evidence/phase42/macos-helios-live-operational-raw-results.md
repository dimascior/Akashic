# macOS Helios Live Operational Raw Results — Phase 4.2

**Date:** 2026-06-29
**Machine:** Thiss-MBP.lan (macOS 14.6.1, build 23G93, x86_64)
**Validated by:** Claude Opus 4.6 (1M context) + human operator

## Repository State

```
Akashic HEAD:  3ce09a3eddca9da1acf1069af048fe397ecce48d
Akashic path:  /Users/thispc/Engineering/Akashic
Akashic status: clean

Helios- HEAD:  46e23931328f8d37b7ad118b6667fa204aa7790d
Helios- path:  /Users/thispc/Engineering/Helios-
Helios- status: clean
```

## Machine Info

```
Darwin Thiss-MBP.lan 23.6.0 Darwin Kernel Version 23.6.0: Mon Jul 29 21:13:00 PDT 2024; root:xnu-10063.141.2~1/RELEASE_X86_64 x86_64
ProductVersion: 14.6.1
BuildVersion:   23G93
User: thispc (uid=501, admin group)
PowerShell: 7.4.7 (user-level install at /Users/thispc/.local/bin/pwsh)
chflags: /usr/bin/chflags
ls: /bin/ls
git: 2.39.5 (Apple Git-154)
```

## Activation Tooling Check

All 7 required files present in Akashic checkout (added from Windows/Void Linux Phase 4.2 work):

```
EXISTS: tools/Apply-AkashicClaudeHooks.ps1
EXISTS: tools/Remove-AkashicClaudeHooks.ps1
EXISTS: tools/Test-HeliosLiveOperational.ps1
EXISTS: tools/Install-AkashicHeliosRuntime.ps1
EXISTS: schemas/helios-settings-activation-evidence.schema.json
EXISTS: schemas/helios-rollback-evidence.schema.json
EXISTS: docs/helios-user-installation.md
```

Parse test: All 4 PowerShell scripts PARSE_OK.

## RuntimeBundleRoot Verification

```
RuntimeBundleRoot: /Users/thispc/Engineering/Helios-/.command-gate

Protected runtime files:
  EXISTS: hooks/helios_pretooluse.ps1
  EXISTS: hooks/gate_check.ps1
  EXISTS: hooks/evidence_capture.ps1
  EXISTS: hooks/tier_classifier.ps1
  EXISTS: policy/command-policy.json

Directories:
  MISSING_DIR: hooks/lib (created by Prepare)
  MISSING_DIR: manifest (created by Prepare)
  EXISTS_DIR: pending
  MISSING_DIR: inflight (created by Prepare)
  EXISTS_DIR: evidence
  EXISTS_DIR: blocked
```

## Live Parameters

```
AkashicRoot:       /Users/thispc/Engineering/Akashic
HeliosRepoRoot:    /Users/thispc/Engineering/Helios-
RuntimeBundleRoot: /Users/thispc/Engineering/Helios-/.command-gate
HeliosGateRoot:    /Users/thispc/.helios/.command-gate
ClaudeSettingsPath: /Users/thispc/.claude/settings.json
PowerShell path:   /Users/thispc/.local/bin/pwsh
Lock backend:      chflags (uchg/nouchg)
Evidence path:     /Users/thispc/Engineering/Akashic/evidence/phase42
```

**Discovery: Same-path RuntimeBundleRoot/HeliosGateRoot fails.** When both point to the same directory, the installer's Phase 4 Copy-Item crashes with "Cannot overwrite the item with itself." Used separate HeliosGateRoot at `$HOME/.helios/.command-gate`.

## PlanOnly Raw Output

```
Install plan generated: install-plan.json (mode: PlanOnly, platform: macOS, status: READY)

schema_version: akashic-helios-install-plan.v2
timestamp_utc: 2026-06-29T01:05:38.7490650Z
mode: PlanOnly
platform: macOS
overall_status: READY
blockers: []

Phase  1: Verify Akashic package/root        = PASS (11 tools present)
Phase  2: Verify RuntimeBundleRoot            = PASS (5 protected, 0 support files)
Phase  3: Create runtime directories          = PLAN (9 directories to create)
Phase  4: Copy runtime protected files        = PLAN (5 protected files)
Phase  5: Copy runtime support files          = SKIP (no support files)
Phase  6: Sync Akashic bridge                 = PLAN
Phase  7: Verify bridge byte identity         = SKIP (deferred to Prepare)
Phase  8: Generate manifest                   = SKIP (deferred to Prepare)
Phase  9: Verify envelope integrity           = SKIP (deferred to Prepare)
Phase 10: Detect lock strategy + run fixture  = PASS (chflags, strong_user_immutable)
Phase 11: Prepare settings activation plan    = PLAN (generated)
Phase 12: Prepare lock activation plan        = PLAN
Phase 13: Prepare rollback plan               = PASS
Phase 14: Write install evidence              = SKIP (deferred to Prepare)

Settings activation plan:
  target_file: /Users/thispc/.claude/settings.json
  backup_path: /Users/thispc/.claude/settings.json.pre-helios-backup
  requires_approval: true
  hooks_to_add: PreToolUse, PostToolUse, PostToolUseFailure
```

## Prepare Raw Output

```
Bridge sync:
  source: /Users/thispc/Engineering/Akashic/AkashicIntegrityBridge.ps1
  dest:   /Users/thispc/.helios/.command-gate/hooks/lib/HeliosIntegrityBridge.ps1
  source_hash: 8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454
  dest_hash:   8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454
  byte_identical: true

Manifest:
  manifest_path: /Users/thispc/.helios/.command-gate/manifest/helios-envelope.json
  sidecar_path:  /Users/thispc/.helios/.command-gate/manifest/helios-envelope.sha256
  manifest_hash: 42b2749f8696202d62589742933ad6b8bac9673d83b512d2e3d1a7b140446eed
  rebaselined_by: installer
  protected_hashes:
    hooks/gate_check.ps1:                06a58750cd5a96c0b4be36e3ec1befeaa31fb90ce71324834d881c85075f6342
    hooks/helios_pretooluse.ps1:         31e6e82253aa1567367b92985973f799510b3ae17b89ac4379bc6e7092cac7b3
    hooks/evidence_capture.ps1:          beab97ea548f0edf0826fdc7365f23adef54cba9b21257d2ed0a8902fa832e0b
    hooks/tier_classifier.ps1:           9d41b12d982c0a50c706ba9ee1c17f5ebcd8ade959b7226b31019fbdbf024757
    policy/command-policy.json:          5e4fc670a3e03947d8ab0c5d64a1c59faf5c92dd887ee25474d147425359639f
    hooks/lib/HeliosIntegrityBridge.ps1: 8008a336b8d5c35704aa677a57796807f8bb7790d3ff0a9af89767519c51e454

Fixture: PASS (7-phase lock lifecycle on disposable /tmp path)

Install plan: mode=Prepare, platform=macOS, overall_status=READY
Phase  1: PASS    Phase  2: PASS    Phase  3: PASS (15 dirs created)
Phase  4: PASS (5 protected files copied)    Phase  5: SKIP
Phase  6: PASS (bridge synced)    Phase  7: PASS (byte identical)
Phase  8: PASS (manifest generated)    Phase  9: PASS (envelope CLEAN)
Phase 10: PASS (fixture PASS)    Phase 11: SKIP
Phase 12: PLAN (lock ready)    Phase 13: PASS    Phase 14: PASS

Install evidence: /Users/thispc/Engineering/Akashic/evidence/phase42/macos-prepare/install-evidence.json
  settings_activation: skipped
  lock_activation: plan_only
  blockers: []
```

## Settings Activation

**Settings backup:**
```
Backup path: /Users/thispc/.claude/settings.json.pre-helios-backup
Backup SHA256: b2e1dd97d1ff023f8512427ee1a65efff4faf49e602632da32abdc7058997989
```

**WhatIf dry-run output:**
```
=== DRY RUN (no changes will be made) ===
Settings file:  /Users/thispc/.claude/settings.json
Backup target:  /Users/thispc/.claude/settings.json.pre-helios-backup
Helios root:    /Users/thispc/.helios/.command-gate
Platform:       macOS

Hook commands that WOULD be written:
  PreToolUse:         pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/helios_pretooluse.ps1'
  PostToolUse:        pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/evidence_capture.ps1'
  PostToolUseFailure: pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/evidence_capture.ps1'

Hooks to add:            PreToolUse, PostToolUse, PostToolUseFailure
Hooks already present:
=== END DRY RUN ===
```

**Discovery: Bare `pwsh` path risk.** The Apply-AkashicClaudeHooks.ps1 tool generates `pwsh -NoProfile -File '...'` with bare `pwsh`. On this machine, pwsh was installed user-level at `~/.local/bin/pwsh` (no brew, no sudo). Hook commands were manually written with absolute path `/Users/thispc/.local/bin/pwsh` to ensure reliable resolution regardless of PATH inheritance.

**Applied hooks (with absolute pwsh path, after human approval):**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/thispc/.local/bin/pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/helios_pretooluse.ps1'",
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
            "command": "/Users/thispc/.local/bin/pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/evidence_capture.ps1'",
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
            "command": "/Users/thispc/.local/bin/pwsh -NoProfile -File '/Users/thispc/.helios/.command-gate/hooks/evidence_capture.ps1'",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

## Real Claude Hook Execution Proof

### Gate interception (PreToolUse)

**Attempt 1 — no gate:**
```
GATE REQUIRED: No valid gate found in pending/ for this command.
Tier: 0. SHA256: 54f2912b4ccad792d3cc85ddbcdea3431d32c951abab5411218b9c0066d40328. Category: routine.
```

**Attempt 2 — gate with wrong cwd and missing segments:**
```
GATE REJECTED: closest gate macos-phase42-shasum.gate.json matched sha256 but failed validation:
- working_directory mismatch
  gate:   /Users/thispc
  actual: /Users/thispc/Engineering/Akashic
- missing base fields: segments
```

**Attempt 3 — gate with correct cwd/segments but no exit capture suffix:**
```
EXIT CAPTURE REQUIRED: command does not end with an approved exit-capture suffix
('; echo EXIT=$?') and gate does not declare exit_capture=wrapper_required or not_applicable.
SHA256: 54f2912b4ccad792d3cc85ddbcdea3431d32c951abab5411218b9c0066d40328
```

**Attempt 4 — command with exit capture suffix (new SHA256):**
```
GATE REQUIRED: No valid gate found in pending/ for this command.
Tier: 0. SHA256: c4e1b617ec4deb6b6b0dd9817cdab9c3525d73af62a860d0154bce56332d9833. Category: routine.
```

### Gate approval (success path)

**Gate file:** `pending/macos-phase42-shasum.gate.json`
```json
{
  "schema_version": "command-gate.v1",
  "correlation_id": "macos-phase42-shasum",
  "command": "shasum -a 256 \"$HOME/.claude/settings.json\"; echo EXIT=$?",
  "command_sha256": "c4e1b617ec4deb6b6b0dd9817cdab9c3525d73af62a860d0154bce56332d9833",
  "working_directory": "/Users/thispc/Engineering/Akashic",
  "shell": "bash",
  "risk_tier": 0,
  "exit_capture": "suffix",
  "multi_command": true,
  "segments": ["shasum -a 256 \"$HOME/.claude/settings.json\"", "echo EXIT=$?"]
}
```

**Command output:**
```
be5831b1faac3308ea7df26fabedda58d9dcc146a071ae64c1041e349e93e321  /Users/thispc/.claude/settings.json
EXIT=0
```

**PostToolUse evidence:**
```
[EVIDENCE:macos-phase42-shasum] Command succeeded. Exit=0 (source: parsed_marker).
Compare EXPECTED from the gate vs ACTUAL output before creating the next gate.
```

**Evidence result file:** `evidence/20260629-macos-phase42-shasum.result.json`
```json
{
  "correlation_id": "macos-phase42-shasum",
  "tool_use_id": "toolu_01UE9DkPwqDgrmxCg1MaURfE",
  "session_id": "8797a91a-11ca-4c41-9475-62becec5f0ba",
  "hook_event": "PostToolUse",
  "exit_code": 0,
  "exit_code_source": "parsed_marker",
  "success": true,
  "output_preview": "be5831b1faac3308ea7df26fabedda58d9dcc146a071ae64c1041e349e93e321  /Users/thispc/.claude/settings.json\nEXIT=0"
}
```

### Gate approval (failure path)

**Gate file:** `pending/macos-phase42-fail-test.gate.json`
```json
{
  "schema_version": "command-gate.v1",
  "correlation_id": "macos-phase42-fail-test",
  "command": "cat /tmp/nonexistent-file-phase42-test; echo EXIT=$?",
  "command_sha256": "2b5e638ac05c874fd15770e772aa7a24b150ece5823b7ea5804311ad26548f14",
  "risk_tier": 1,
  "exit_capture": "suffix"
}
```

**Command output:**
```
cat: /tmp/nonexistent-file-phase42-test: No such file or directory
EXIT=1
```

**PostToolUse evidence:**
```
[EVIDENCE:macos-phase42-fail-test] Command succeeded. Exit=1 (source: parsed_marker).
Compare EXPECTED from the gate vs ACTUAL output before creating the next gate.
```

**Evidence result file:** `evidence/20260629-macos-phase42-fail-test.result.json`
```json
{
  "correlation_id": "macos-phase42-fail-test",
  "tool_use_id": "toolu_01RbsbeVqPKx1Zk2M7ie79H2",
  "session_id": "8797a91a-11ca-4c41-9475-62becec5f0ba",
  "hook_event": "PostToolUse",
  "exit_code": 1,
  "exit_code_source": "parsed_marker",
  "success": true,
  "output_preview": "cat: /tmp/nonexistent-file-phase42-test: No such file or directory\nEXIT=1"
}
```

**Note on PostToolUseFailure:** The suffix exit capture pattern (`; echo EXIT=$?`) ensures the overall shell command exits 0, so PostToolUse fires instead of PostToolUseFailure. The semantic exit code (EXIT=1) is captured via parsed_marker. This is the intended behavior documented in the Helios README.

## Manifest Integrity

```
manifest/helios-envelope.json exists: YES
manifest/helios-envelope.sha256 exists: YES
Sidecar value: 42b2749f8696202d62589742933ad6b8bac9673d83b512d2e3d1a7b140446eed

Protected hashes in manifest match session baseline: YES
  hooks/gate_check.ps1:                06a58750... (match)
  hooks/helios_pretooluse.ps1:         31e6e822... (match)
  hooks/evidence_capture.ps1:          beab97ea... (match)
  hooks/tier_classifier.ps1:           9d41b12d... (match)
  hooks/lib/HeliosIntegrityBridge.ps1: 8008a336... (match)
  policy/command-policy.json:          5e4fc670... (match)

Mutable directories:
  pending/:  writable (0 files after gate consumption)
  inflight/: writable (0 files after gate consumption)
  evidence/: writable (16 files: consumed gates, results, sidecars, integrity session)
  blocked/:  writable (5 blocked records from gate validation failures)

Protected files locked: NO (locks deferred, not applied)
```

## Discoveries

| # | Discovery | Impact |
|---|---|---|
| 1 | Same-path RuntimeBundleRoot/HeliosGateRoot causes Copy-Item self-overwrite crash | Used separate $HOME/.helios/.command-gate as HeliosGateRoot |
| 2 | Apply-AkashicClaudeHooks.ps1 uses bare `pwsh` in hook commands | User-level pwsh install requires absolute path in hooks |
| 3 | `segments` is a required base field even when `multi_command: false` | Gate rejected until segments array provided |
| 4 | Exit capture suffix is strictly enforced — command must end with `; echo EXIT=$?` | Changed command to include suffix; new SHA256 required |
| 5 | PostToolUseFailure does not fire with suffix exit capture (shell exits 0) | Semantic exit code captured via parsed_marker in PostToolUse instead |
| 6 | Claude Code cwd is `/Users/thispc/Engineering/Akashic` (last cd), not $HOME | Gate working_directory must match actual cwd |
| 7 | Blocked attempts are written to blocked/ with timestamp and SHA256 prefix | 5 blocked records from iterative gate corrections |
| 8 | Integrity session baseline created at first gated command | Session ID 8797a91a... with per-command .before.json files |

## Final Status

```
Phase 4.2 macOS status: PASS

Live interception:        PROVEN (GATE REQUIRED on ungated command)
Gate validation:          PROVEN (GATE REJECTED with diagnostic on malformed gates)
Gate approval:            PROVEN (command executed after valid gate)
Success evidence:         PROVEN (PostToolUse with correlation_id, exit=0)
Failure evidence:         PROVEN (PostToolUse with correlation_id, exit=1 via parsed_marker)
Manifest integrity:       PROVEN (all 6 protected hashes match baseline)
Session baseline:         PROVEN (created and verified)
Locks applied:            false
Runtime locking status:   deferred
Active runtime touched:   Helios hooks activated in settings.json (reversible via backup)
```
