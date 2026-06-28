# Phase 3.98 — Packaging Decision Record

## Decision

Package the TCE Helios adapter from the `helios-integrity-adapter` fork branch. Preserve TCE main. Distribute source packages with checksums. Install creates local manifest on target machine.

## Context

Phase 3.97 completed gap-test matrix, lock-requirement derivation, and adapter specification on the `helios-integrity-adapter` branch. The adapter is ready for distribution but must not merge into TCE main. Users need a clear way to pull, verify, install, and activate the adapter on their own machines.

## Decisions Made

### 1. Package from TCE fork branch

The `helios-integrity-adapter` branch is the package source. Release artifacts are built from this branch. The branch name and commit hash are recorded in every package manifest.

### 2. Preserve TCE main

TCE main remains the clean public-facing MyExporter module. No adapter files, no adapter entries in `FunctionsToExport` or `FileList`. Main stays at `c594a75` (or its non-adapter successor).

### 3. Distribute source package first

PowerShell scripts ship as source. No compiled binaries. Source distribution preserves:
- Auditability — users can read every line in the hook path.
- Hash transparency — SHA-256 of source files is deterministic.
- Direct inspection — no decompilation needed to verify behavior.

### 4. Create release zip with checksums

Primary distribution: GitHub release artifact (zip) from the adapter branch. Each release includes:
- `package-manifest.json` — contents, provenance, compatibility.
- `checksums.sha256` — SHA-256 hash for every file.
- Release notes tied to the specific commit.

### 5. Compile later only if needed

Compiled executables are deferred. No current operational need justifies compilation. If a need arises (performance, distribution simplification, proprietary logic), it can be reconsidered. The decision to compile is separate from the decision to package.

### 6. Install creates local manifest on target machine

The `helios-envelope.json` manifest and `helios-envelope.sha256` sidecar are generated locally during installation. This ensures:
- Hashes reflect actual installed bytes (no transport corruption trust).
- The sidecar is computed from the local manifest.
- The rebaseline is recorded with local timestamp and operator identity.

### 7. Helios remains runtime consumer

Helios owns the command-gate runtime. It consumes a byte-identical vendor copy of the TCE bridge. Helios does not package or distribute the bridge — TCE does.

### 8. TCE remains adapter source-of-truth

TCE owns the bridge source, adapter specification, gap-test evidence, and lock-requirement derivations. The package is a TCE product distributed from a TCE branch.

### 9. Phase 4 code begins after packaging is stable

Phase 4 (filesystem prevention / helios-lock) implementation does not start until:
- The package architecture document is complete.
- The install sequence is documented and tooled.
- At least one package has been built and verified.
- The two-package model is validated.

## Decisions Deferred

### Registry publishing

No PSGallery or npm or pip publishing decision in this phase. Registry publishing is a future decision after the install flow is proven stable with manual distribution.

### Dedicated adapter repo

The adapter stays in TCE's `Adapters/Helios/` directory on the fork branch. A dedicated repo is a future option if the adapter scope grows beyond TCE's directory structure.

### helios-lock packaging

Phase 4 helios-lock is a separate package with its own packaging decision. It is not bundled with the TCE adapter package. The packaging decision for helios-lock is blocked on Phase 4 implementation.

### TCE main merge

No timeline for merging adapter work into TCE main. The merge decision depends on adapter stability, user adoption, and a deliberate release choice.

## Success Criteria

Users have a clear way to:
1. Pull a Helios adapter package from the TCE fork branch.
2. Verify the package against checksums.
3. Install the adapter into a Helios runtime bundle.
4. Generate a local manifest on their target machine.
5. Verify envelope integrity before activation.
6. Review and approve hook activation in settings.json.
7. Run smoke tests confirming gate enforcement.
8. Record install evidence for audit trail.

All of this without merging anything into TCE main.

## Artifacts Created in Phase 3.98

| Artifact | Type | Path |
|---|---|---|
| Package architecture | doc | `docs/package-architecture.md` |
| Package options | doc | `docs/package-options.md` |
| Install sequence | doc | `docs/install-sequence.md` |
| Package manifest schema | doc | `docs/package-manifest-schema.md` |
| This decision record | doc | `docs/phase398-packaging-decision.md` |
| Package builder | tool | `tools/New-HeliosAdapterPackage.ps1` |
| Package verifier | tool | `tools/Test-HeliosAdapterPackage.ps1` |
| Install-plan generator | tool | `tools/New-HeliosInstallPlan.ps1` |

## Phase 3.99 Continuation

Phase 3.98 designed the TCE adapter packaging. Phase 3.99 completes the two-package story:

- **BOM hardening**: `New-HeliosEnvelopeManifest.ps1` fixed to use `$Utf8NoBom` for manifest and sidecar writes. `Test-HeliosEnvelopeIntegrity.ps1` now checks for BOM presence.
- **Runtime bundle packaging**: `New-HeliosRuntimeBundle.ps1` builds a distributable Helios runtime bundle. `Test-HeliosRuntimeBundle.ps1` verifies contents, checksums, and BOM safety.
- **Combined installer**: `New-HeliosCombinedInstallPlan.ps1` generates a full install plan consuming both the TCE adapter package and Helios runtime bundle.
- **End-to-end simulation**: `Test-HeliosEndToEndInstallPlan.ps1` simulates a complete install in a temp directory without touching the active runtime.
- **Operational enforcement observations**: Gate identity enforcement (undeclared chaining, cwd mismatch) observed operationally during Phase 3.98, confirming Phase 3.97 gap-test classifications.
- **Runtime bundle contract**: `helios-runtime-bundle-contract.md` defines what the runtime bundle includes, excludes, and how it relates to the adapter package.
