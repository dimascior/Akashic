# Phase 4.3.2b — Runtime Origin Detection Raw Results

## Test results

### 1. Parse validation

| File | Result |
|------|--------|
| Test-HeliosRuntimeOrigin.ps1 | PASS |
| Write-HeliosRuntimeDetection.ps1 | PASS |

### 2. Live detection: SOURCE_REPO_CHANGED

Ran against live MythosJustAFable gate root with RuntimeBundleRoot = HeliosGateRoot.

| Axis | Verdict |
|------|---------|
| Manifest | CLEAN |
| Sidecar | MATCH |
| Origin | MATCH |
| Source repo | SOURCE_REPO_CHANGED |
| Bridge | BRIDGE_ORIGIN_DRIFT |

- **Detection type:** SOURCE_REPO_CHANGED
- **Severity:** MEDIUM
- **Recommended action:** PLAN_RESET_FROM_NEW_REPO_STATE
- **Why SOURCE_REPO_CHANGED:** Akashic HEAD advanced from 06d271d (recorded in origin) to d2a51c0 (Phase 4.3.2a commit).
- **Why BRIDGE_ORIGIN_DRIFT:** AkashicIntegrityBridge.ps1 differs from HeliosIntegrityBridge.ps1. Bridge comes from Akashic, not RuntimeBundleRoot.
- **Evidence written to:** HeliosGateRoot/evidence/detections/ and AkashicRoot/evidence/phase432b/

### 3. Live detection: SOURCE_REPO_MISSING

Ran with RuntimeBundleRoot pointing to non-existent path.

| Axis | Verdict |
|------|---------|
| Manifest | CLEAN |
| Sidecar | MATCH |
| Origin | MATCH |
| Source repo | SOURCE_REPO_MISSING |
| Bridge | BRIDGE_ORIGIN_DRIFT |

- **Detection type:** SOURCE_REPO_MISSING
- **Severity:** HIGH
- **Recommended action:** BLOCK_RESET_UNTIL_SOURCE_RESOLVED

### 4. Detection priority verification

The priority chain selects the most critical finding:

| Priority | Detection type | Severity | Condition |
|----------|---------------|----------|-----------|
| 1 | BASELINE_REWRITE_SUSPECTED | CRITICAL | manifest CLEAN + origin DRIFT |
| 2 | SIDECAR_MISMATCH | HIGH | sidecar != manifest hash |
| 3 | CURRENT_MANIFEST_DRIFT | HIGH | files != manifest hashes |
| 4 | NO_INSTALL_ORIGIN | HIGH | origin file missing |
| 5 | ORIGIN_DRIFT | HIGH | files != origin hashes |
| 6 | SOURCE_REPO_MISSING | HIGH | RuntimeBundleRoot not found |
| 7 | SOURCE_REPO_CHANGED | MEDIUM | source files or HEADs changed |
| 8 | BRIDGE_ORIGIN_DRIFT | MEDIUM | bridge source != installed |
| 9 | ORIGIN_MATCH | INFO | all origin hashes match |
| 10 | CURRENT_MANIFEST_CLEAN | INFO | all manifest hashes match |

### 5. Bridge classification

Bridge drift is classified separately from runtime file drift:

| Status | Meaning |
|--------|---------|
| BRIDGE_MATCH | AkashicIntegrityBridge.ps1 == HeliosIntegrityBridge.ps1 |
| BRIDGE_ORIGIN_DRIFT | Bridge source != installed |
| BRIDGE_SOURCE_MISSING | AkashicIntegrityBridge.ps1 not found |
| BRIDGE_INSTALLED_MISSING | HeliosIntegrityBridge.ps1 not found |

### 6. Automation mode contract

| Mode | 4.3.2b behavior |
|------|-----------------|
| DetectOnly | Returns DETECTED |
| LogOnly | Returns LOGGED |
| PlanReset | Returns PLAN_GENERATED (or DETECTED if clean) |
| AutoReset | Returns RESET_TOOL_NOT_IMPLEMENTED |
| AutoResetAndReactivate | Returns RESET_TOOL_NOT_IMPLEMENTED |

### 7. No-reset guarantee

4.3.2b detects and logs only. It does not modify runtime files, manifests, hooks, locks, or Claude settings. Reset, restore, and uninstall are reserved for 4.3.2c.

### 8. Path normalization

All relative protected paths use forward-slash normalization:
- `hooks/gate_check.ps1` (not `hooks\gate_check.ps1`)
- `policy/command-policy.json`
- `hooks/lib/HeliosIntegrityBridge.ps1`

Absolute paths are kept as-is in metadata fields.

## Six comparison axes

| Axis | Comparison | Detects |
|------|-----------|---------|
| Live files → manifest | current hashes vs helios-envelope.json | runtime drift |
| Live files → origin | current hashes vs helios-install-origin.json | manifest rewrite |
| Source files → origin | current RuntimeBundleRoot vs recorded source hashes | source repo update |
| Bridge source → installed | AkashicIntegrityBridge vs HeliosIntegrityBridge | bridge drift |
| Akashic HEAD → recorded | current git HEAD vs origin akashic_head | repo advance |
| Helios HEAD → recorded | current git HEAD vs origin helios_head | repo advance |

## Files created

- `schemas/helios-runtime-detection.v1.json`
- `tools/Test-HeliosRuntimeOrigin.ps1`
- `tools/Write-HeliosRuntimeDetection.ps1`
- `evidence/phase432b/runtime-origin-detection-raw-results.md`
- `evidence/phase432b/20260629-081841-SOURCE_REPO_CHANGED.json`
