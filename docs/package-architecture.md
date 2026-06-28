# Akashic — Package Architecture

## Package Goals

1. Users can pull the TCE Helios adapter from the fork branch without merging into TCE main.
2. The package is source-visible, checksum-verifiable, and locally rebaselined on the target machine.
3. Installation and activation are separate steps with explicit approval gates.
4. The trust model is auditable: every file is hashed, every step produces evidence, and no binary blobs are required.

## Two-Package Model

### Package 1: Akashic Adapter Package

**Source:** `Akashic` standalone repo (originally extracted from `TerminalContextExporter`, `helios-integrity-adapter` branch).
**Purpose:** Source-of-truth adapter package. Contains the bridge implementation, schemas, tools, documentation, and gap-test evidence that prove the adapter contract.

**Contents:**

| Directory | Files | Role |
|---|---|---|
| `/` | `AkashicIntegrityBridge.ps1` | Source-of-truth bridge implementation |
| `/` | `README.md` | Adapter documentation |
| `docs/` | `tce-helios-integrity-adapter-spec.md` | Adapter specification |
| `docs/` | `phase4-lock-requirements-from-gap-tests.md` | Lock requirement derivations |
| `docs/` | `package-architecture.md` | This document |
| `docs/` | `package-options.md` | Distribution option comparison |
| `docs/` | `install-sequence.md` | Installation procedure |
| `docs/` | `package-manifest-schema.md` | Package metadata schema |
| `docs/` | `phase398-packaging-decision.md` | Phase 3.98 decision record |
| `schemas/` | `helios-envelope.schema.json` | Envelope manifest schema |
| `schemas/` | `helios-baseline.schema.json` | Session baseline schema |
| `schemas/` | `helios-command-evidence.schema.json` | Per-command evidence schema |
| `tools/` | `Sync-AkashicBridge.ps1` | Bridge sync (source → vendor copy) |
| `tools/` | `AkashicEnvelopeManifest.ps1` | Manifest rebaseline |
| `tools/` | `AkashicEnvelopeIntegrityValidation.ps1` | Envelope integrity verification |
| `tools/` | `Invoke-AkashicGapTest.ps1` | Gap-test orchestration |
| `tools/` | `ConvertFrom-AkashicEvidence.ps1` | Evidence parser/normalizer |
| `tools/` | `AkashicGapTestMatrix.ps1` | Gap-test matrix generator |
| `tools/` | `AkashicPackage.ps1` | Package builder |
| `tools/` | `AkashicPackageValidation.ps1` | Package verification |
| `tools/` | `AkashicInstallPlan.ps1` | Install-plan generator |
| `Tests/` | `AkashicIntegrityBridge.Tests.ps1` | Pester test suite |
| `evidence/gap-tests/` | 12 subdirectories | Gap-test evidence artifacts |

### Package 2: Helios Runtime Bundle

**Source:** `MythosJustAFable` repo, Helios runtime branch.
**Purpose:** Runtime gate enforcement bundle. The operational command-gate system that the adapter integrates with.

**Contents:**

| Directory | Files | Role |
|---|---|---|
| `hooks/` | `helios_pretooluse.ps1`, `gate_check.ps1`, `evidence_capture.ps1`, `tier_classifier.ps1` | Active hook scripts |
| `hooks/lib/` | `HeliosIntegrityBridge.ps1` | Vendored bridge (byte-identical to TCE source) |
| `policy/` | `command-policy.json` | Gate policy and tier patterns |
| `templates/` | `.gitkeep` | Tier override catalog directory |
| `schemas/` | JSON Schema definitions | Runtime validation schemas |
| `tools/` | Rebaseline, verification, cleanup | Offline maintenance tools |
| `docs/` | Architecture, bypass surface, lock handoff | Runtime documentation |
| `maintenance/` | (empty) | Maintenance rebaseline corridor |
| `manifest/` | `helios-envelope.json`, `helios-envelope.sha256` | Durable trust anchors |
| `pending/` | `.gitkeep` | Gate lifecycle directory |
| `inflight/` | `.gitkeep` | Gate lifecycle directory |
| `evidence/` | `.gitkeep` | Evidence and integrity sessions |
| `blocked/` | `.gitkeep` | Denied command records |

## Installer Layer

The installer connects the two packages. It is a set of PowerShell tools that ship with the TCE adapter package.

### Installer Responsibilities

The unified installer (`AkashicHeliosInstallPlan.ps1`) runs a 16-phase plan. See `docs/akashic-helios-installer-contract.md` for the full contract.

1. **Verify Akashic identity and tool availability** — confirm package root and required tools exist.
2. **Verify Helios target** — find or initialize `.command-gate/` at the target path.
3. **Verify runtime directories** — create required directories in Prepare/Activate mode.
4. **Verify protected file and mutable directory inventory** — canonical lists from `AkashicLockTargets.ps1`.
5. **Detect OS lock strategy** — `Get-AkashicLockStrategy.ps1` resolves platform backend.
6. **Run lock fixture** — disposable test must PASS before any active runtime locking.
7. **Copy Akashic bridge** — `AkashicIntegrityBridge.ps1` → `hooks/lib/HeliosIntegrityBridge.ps1`.
8. **Verify byte identity** — SHA-256 match between source and vendored copy.
9. **Generate target-machine manifest** — BOM-free UTF-8, generated from actual file hashes.
10. **Verify envelope integrity** — `AkashicEnvelopeIntegrityValidation.ps1` on the target.
11. **Prepare settings activation plan** — platform-aware hook commands (powershell.exe vs pwsh).
12. **Prepare lock activation plan** — requires fixture PASS + human approval.
13. **Prepare rollback plan** — settings restore, unlock, verification.
14. **Write install evidence** — mode, platform, strategy, fixture result, blockers.
15. **Keep install separate from activation** — settings.json is NOT modified without explicit approval.
16. **Active runtime locking deferred** — not permitted until fixture + installer pass per platform.

### Install vs Activation Boundary

| Step | Installer Does | Requires Approval |
|---|---|---|
| Copy files | Yes | No |
| Verify hashes | Yes | No |
| Create directories | Yes | No |
| Generate manifest | Yes | No |
| Write install evidence | Yes | No |
| Run smoke tests | Yes | No |
| Modify settings.json | **No — generates plan only** | **Yes — explicit human approval** |
| Enable hooks | **No** | **Yes — human activates** |

## Branch Boundaries

| Branch | Package Role | Merge Target |
|---|---|---|
| `helios-integrity-adapter` | TCE adapter package source | Not merged to main |
| TCE `main` | Preserved clean MyExporter | No adapter entries |
| Helios runtime branch | Runtime bundle source | Helios repo only |

## Target-Machine Rebaseline

The manifest and sidecar are generated locally on the target machine after installation. This ensures:

1. Hashes reflect the actual installed file bytes (no transport corruption).
2. The sidecar is computed from the local manifest (no pre-computed trust).
3. The rebaseline is recorded with the local machine timestamp and operator identity.

## Verification Flow

```
1. AkashicPackageValidation -PackageRoot <path>
   → Confirms package contents, checksums, and required files.

2. AkashicInstallPlan -PackageRoot <path> -HeliosTargetRoot <path>
   → Generates install-plan.json with copy list, verification steps, and activation plan.

3. [Execute install plan]
   → Copies files, generates manifest, verifies envelope.

4. AkashicEnvelopeIntegrityValidation -HeliosGateRoot <path>
   → Confirms CLEAN verdict on target machine.

5. [Smoke tests]
   → No-gate deny: command without gate → DENY.
   → Valid-gate allow: command with valid gate → ALLOW with evidence chain.
```

## Smoke-Test Flow

| Test | Input | Expected | Proves |
|---|---|---|---|
| No-gate deny | Shell command with no pending gate | DENY (no valid gate) | Gate enforcement active |
| Valid-gate allow | Shell command with valid matching gate | ALLOW + 4 evidence files | Full evidence chain operational |
| Integrity failure | Shell command after controlled policy edit | INTEGRITY_FAILURE DENY | Witness detects drift |

## Package Trust Model

| Trust Property | How Achieved |
|---|---|
| Source transparency | Source distribution (PowerShell scripts, no compiled binaries) |
| Content integrity | SHA-256 checksums per file in `checksums.sha256` |
| Package integrity | Package manifest with file list and hashes |
| Transport verification | Checksum comparison after download or clone |
| Local trust generation | Manifest and sidecar generated on target machine |
| Audit trail | Install evidence written with timestamps and operator identity |
| Bridge identity | Byte-identical verification between source and vendored copy |

## Compilation Decision

PowerShell scripts ship as source for this phase:

- Source distribution preserves auditability, hash transparency, and direct inspection.
- Users can read every line that runs in their hook path.
- Checksums and optional signatures provide integrity without compilation.
- Compiled executables may be considered later for a specific operational need (performance, distribution simplification, or obfuscation of proprietary logic). No such need exists today.

## Runtime Bundle Tooling (Phase 3.99)

Phase 3.99 adds the Helios runtime bundle as the second installable package:

| Tool | Purpose |
|---|---|
| `AkashicRuntimeBundle.ps1` | Build a distributable runtime bundle from a Helios repo checkout |
| `AkashicRuntimeBundleValidation.ps1` | Verify runtime bundle contents, checksums, and BOM safety |
| `AkashicCombinedInstallPlan.ps1` | Generate a full install plan consuming both packages |
| `AkashicEndToEndInstallPlanValidation.ps1` | Simulate a full install in a temp directory |

### BOM Hardening

All JSON writers in the install trust path use `[System.IO.File]::WriteAllText()` with `$Utf8NoBom`. The `AkashicEnvelopeIntegrityValidation.ps1` tool includes a BOM safety check on manifest and sidecar. Runtime bundle and adapter package verifiers check all JSON files for BOM presence.

### End-to-End Install Simulation

`AkashicEndToEndInstallPlanValidation.ps1` creates a temporary directory, runs both package verifiers, executes the combined install plan in Prepare mode, generates a local manifest and sidecar, verifies BOM absence, checks envelope integrity, and validates settings activation and rollback plans.

## Future Packaging Options

| Option | Phase | Status |
|---|---|---|
| Git clone from adapter branch | 3.98 | Recommended for development |
| GitHub release artifact (zip) | 3.98 | Recommended for distribution |
| Helios runtime bundle | 3.99 | Complete — runtime packaging tooled |
| End-to-end install simulation | 3.99 | Complete — simulation verified |
| Unified installer contract | 4.1 | Defined — `docs/akashic-helios-installer-contract.md` |
| Unified install planner | 4.1 | Created — `tools/AkashicHeliosInstallPlan.ps1` |
| PowerShell module (PSGallery) | Future | After install flow stabilizes |
| Dedicated adapter repo | Future | If adapter grows beyond TCE scope |
| Helios monorepo bundle | Future | If unified distribution preferred |
