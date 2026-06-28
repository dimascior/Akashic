# Akashic Naming and Runtime Boundary

## Purpose

This document defines which names belong to Akashic (the adapter repo) and which belong to Helios (the runtime target). It prevents blind find-and-replace confusion and ensures future contributors understand the ownership boundary.

## Akashic Identity (this repo)

The following are Akashic-owned and carry the Akashic name:

| Category | Examples |
|---|---|
| Repository | `dimascior/Akashic` |
| Source bridge | `AkashicIntegrityBridge.ps1` |
| Package artifact | `akashic-v<version>` |
| Package name field | `"package_name": "akashic"` |
| Adapter tools | `AkashicPackage.ps1`, `AkashicPackageValidation.ps1`, `Sync-AkashicBridge.ps1`, etc. |
| Lock/control tools | `Lock-AkashicProtectedFiles.ps1`, `Invoke-AkashicRebaseline.ps1`, etc. |
| Lock strategy | `Get-AkashicLockStrategy.ps1` (OS backend detection) |
| Lock lib (shared) | `tools/lib/AkashicLockTargets.ps1`, `tools/lib/AkashicLockBackend.ps1` |
| Lock fixture test | `Test-AkashicOsLockFixture.ps1` (disposable validation) |
| Install planner | `AkashicInstallPlan.ps1`, `AkashicCombinedInstallPlan.ps1` |
| Evidence tools | `ConvertFrom-AkashicEvidence.ps1`, `Invoke-AkashicGapTest.ps1` |
| Test suite | `Tests/AkashicIntegrityBridge.Tests.ps1` |
| Evidence directory | `evidence/` |
| Release artifacts | `akashic-v<version>.zip` |

## Helios Identity (runtime target)

The following are Helios-owned and retain the Helios name:

| Category | Examples |
|---|---|
| Runtime directory | `.command-gate/` |
| Vendor bridge copy | `hooks/lib/HeliosIntegrityBridge.ps1` |
| Hook scripts | `hooks/helios_pretooluse.ps1`, `hooks/gate_check.ps1`, etc. |
| Policy file | `policy/command-policy.json` |
| Manifest files | `manifest/helios-envelope.json`, `manifest/helios-envelope.sha256` |
| Schema names | `helios-envelope.schema.json`, `helios-baseline.schema.json`, etc. |
| Schema versions | `helios-adapter-package.v2`, `helios-baseline.v1`, etc. |
| Function names | `Get-HeliosEnvelopeSnapshot`, `Compare-HeliosProtectedEnvelope`, etc. |
| Mutable dirs | `pending/`, `inflight/`, `evidence/`, `blocked/` (within `.command-gate/`) |

## TCE Identity (historical provenance only)

| Category | Context |
|---|---|
| Origin repo | `TerminalContextExporter` — extraction seed, archived branch |
| TCE branch | `helios-integrity-adapter` at `d0ab1ff` |
| TCE main | Preserved at `c594a75` — no adapter entries |

TCE references appear only in provenance fields (`tce_origin` in package manifest, `docs/standalone-repo-transition.md`). TCE does not own any active code path.

## Decision Rules

1. **Repo, package, and tooling identity** → Akashic.
2. **Runtime enforcement environment** (hooks, policy, manifest, gate lifecycle, function names) → Helios.
3. **Schema names** → Helios (they describe the runtime envelope format).
4. **Vendor copy path** (`hooks/lib/HeliosIntegrityBridge.ps1`) → Helios. This path is controlled by the Helios runtime, not the adapter.
5. **Historical provenance** → TCE. Never used as an active identity.

## Compatibility Wrappers

Old Helios-prefixed tool names exist as 2-line forwarding wrappers under `tools/`. They call the Akashic-named tool with `@args`. These wrappers exist for backward compatibility with scripts that reference the old names. The canonical tool names are the Akashic versions.
