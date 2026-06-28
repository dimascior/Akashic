# Phase 4.1 Evidence Index

## Evidence Classification

Evidence files fall into three categories:

1. **Tool-produced** — written directly by Akashic tools using their native schemas. These are the canonical machine-generated records.
2. **Raw logs** — unabridged command output from physical machine validation sessions. These are the canonical human-auditable records.
3. **Wrapper summaries** — assembled outside the tools by validation scripts or session context. These use schemas not defined in any tool (`akashic-installer-prepare-validation.v1`, `akashic-installer-contract-readiness.v1`). They are project-level summaries, not tool output.

## Tool Schemas

| Schema | Produced By | Purpose |
|---|---|---|
| `akashic-os-lock-evidence.v1` | `New-AkashicLockEvidence` in `tools/lib/AkashicLockBackend.ps1` | Lock fixture test results |
| `akashic-install-evidence.v1` | `AkashicHeliosInstallPlan.ps1` (Phase 14) | Installer Prepare/Activate evidence |
| `akashic-helios-install-plan.v2` | `AkashicHeliosInstallPlan.ps1` | Full install plan output |
| `helios-envelope.v1` | `AkashicEnvelopeManifest.ps1` | Manifest written to target runtime |

## Tool-Produced Evidence (canonical)

| File | Schema | Platform |
|---|---|---|
| `os-lock-validation/windows.json` | `akashic-os-lock-evidence.v1` | Windows |
| `os-lock-validation/void-linux.json` | `akashic-os-lock-evidence.v1` | Void Linux |
| `os-lock-validation/macos.json` | `akashic-os-lock-evidence.v1` | macOS |

## Raw Validation Logs (canonical)

| File | Platform | Contents |
|---|---|---|
| `void-linux-validation-raw-results.md` | Void Linux | Unabridged pwsh session: preflight, install, fixture, PlanOnly, Prepare |
| `macos-validation-raw-results.md` | macOS | Unabridged pwsh session: preflight, install, fixture, PlanOnly, Prepare |

No Windows raw validation log exists. The Windows Prepare validation was run via a disposable script in a Claude Code session; the raw command output was not captured as a standalone document.

## Wrapper Summaries (noncanonical)

These files use schemas invented outside the tools. They summarize results but are not tool output.

| File | Schema | Notes |
|---|---|---|
| `installer-prepare-validation.json` | `akashic-installer-prepare-validation.v1` | Windows. Wrapper assembled by validation script. Not produced by installer tool. |
| `installer-prepare-validation-macos.json` | `akashic-installer-prepare-validation.v1` | macOS. Wrapper assembled by validation script. Superseded by `macos-validation-raw-results.md`. |
| `installer-contract-readiness.json` | `akashic-installer-contract-readiness.v1` | Project status summary. Not a tool schema. |
| `os-lock-validation/summary.json` | `akashic-os-lock-summary.v1` | Cross-platform lock summary. Not a tool schema. |

## Other Phase 4.1 Evidence

Pre-existing evidence from gap tests, fixture dry runs, and tool coverage checks. These predate the installer contract work.

| File | Purpose |
|---|---|
| `akashic-rename-alignment.json` | Naming convention alignment check |
| `fixture-lock-unlock-validation.json` | Early lock/unlock fixture results |
| `lock-dryrun-result.json` | Lock dry run output |
| `lock-status-baseline.json` | Lock status baseline snapshot |
| `lock-target-inventory.json` | Protected file and mutable dir inventory |
| `package-tool-coverage.json` | Tool coverage assessment |
| `rebaseline-failure-path-fixture.json` | Rebaseline failure path test |
| `schema-validation-result.json` | Schema validation check |
| `settings-integrity-result.json` | Settings integrity check |
| `stale-gate-cleanup-fixture.json` | Stale gate cleanup test |
| `unlock-dryrun-result.json` | Unlock dry run output |
