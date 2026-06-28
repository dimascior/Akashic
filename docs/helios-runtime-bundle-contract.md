# Helios Runtime Bundle — Package Contract

## Purpose

The Helios runtime bundle is a distributable snapshot of the `.command-gate/` directory that provides the gate enforcement system. It pairs with the TCE adapter package to form a complete installation. The runtime bundle contains hooks, policy, schemas, tools, docs, and empty mutable directories — but excludes live session artifacts, pending gates, and machine-local evidence.

## Source

| Field | Value |
|---|---|
| Repository | MythosJustAFable (Helios) |
| Branch | `phase3.75-helios-integrity-boundary` or active runtime branch |
| Root path | `.command-gate/` |

## Included Files

### Protected runtime envelope (hooks + policy)

| Path | Role |
|---|---|
| `hooks/helios_pretooluse.ps1` | Front controller entry point |
| `hooks/gate_check.ps1` | Gate validation logic |
| `hooks/evidence_capture.ps1` | Post-command evidence capture |
| `hooks/tier_classifier.ps1` | Tier classification |
| `hooks/lib/` | Directory for vendored bridge (populated during install) |
| `policy/command-policy.json` | Gate policy and tier patterns |

### Support assets

| Path | Role |
|---|---|
| `schemas/` | JSON Schema definitions for validation |
| `tools/` | Offline rebaseline, verification, cleanup tools |
| `docs/` | Architecture documentation |
| `templates/` | Tier override catalog directory (contains `.gitkeep`) |
| `maintenance/` | Maintenance rebaseline corridor directory |

### Mutable runtime directories (empty scaffolds)

| Path | Contents in bundle |
|---|---|
| `pending/` | `.gitkeep` only |
| `inflight/` | `.gitkeep` only |
| `evidence/` | `.gitkeep` only |
| `blocked/` | `.gitkeep` only |

### Trust anchors (generated during install, not bundled)

| Path | Generation |
|---|---|
| `manifest/helios-envelope.json` | Generated locally by `New-HeliosEnvelopeManifest.ps1` |
| `manifest/helios-envelope.sha256` | Generated locally alongside manifest |

The manifest and sidecar are NOT included in the runtime bundle. They are generated on the target machine after the bridge is installed and byte-identity is verified. This ensures hashes reflect actual installed bytes.

## Excluded Files

| Path pattern | Reason |
|---|---|
| `pending/*.gate.json` | Machine-local pending gates |
| `inflight/*.gate.json` | Machine-local inflight gates |
| `evidence/integrity/sessions/` | Machine-local session baselines and per-command evidence |
| `evidence/*.result.json` | Machine-local gate results |
| `evidence/*.tool_response.json` | Machine-local tool responses |
| `evidence/stale/` | Machine-local archived artifacts |
| `evidence/maintenance/` | Machine-local maintenance records |
| `evidence/install-evidence.json` | Machine-local install record |
| `blocked/*.json` | Machine-local denial records |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Installed from TCE adapter package, not bundled |
| `manifest/helios-envelope.json` | Generated locally during install |
| `manifest/helios-envelope.sha256` | Generated locally during install |

## Manifest Generation Rule

After the runtime bundle is unpacked and the TCE bridge is synced into `hooks/lib/`:

1. Run `New-HeliosEnvelopeManifest.ps1 -HeliosGateRoot <target> -RebaselinedBy installer`.
2. The tool hashes all 6 protected files and writes `helios-envelope.json`.
3. The tool computes the manifest hash and writes `helios-envelope.sha256`.
4. Both files are written as UTF-8 without BOM using `[System.IO.File]::WriteAllText()`.

## Sidecar Generation Rule

The sidecar is the SHA-256 hash of `helios-envelope.json`, written to `helios-envelope.sha256`. It is generated in the same call as the manifest. The sidecar prevents self-hash circularity and is verified before the manifest is parsed during PreToolUse.

## settings.json Activation Boundary

The runtime bundle does NOT modify `settings.json`. Hook activation is a separate step that requires explicit human approval. The combined install plan generates the settings changes needed but does not apply them.

## Install Evidence Boundary

Install evidence (`evidence/install-evidence.json`) is written by the installer on the target machine. It records:
- Installer version
- Package sources and hashes
- Manifest hash at install time
- Envelope verdict
- Smoke test results
- Settings activation status

## Runtime Bundle Verification Requirements

Before a runtime bundle is used for installation:

1. `runtime-manifest.json` exists with source branch and commit.
2. `runtime-checksums.sha256` matches all bundled files.
3. All hook files exist and are valid PowerShell.
4. Policy file exists and is valid JSON.
5. Mutable directories contain only `.gitkeep`.
6. No live evidence, pending gates, or blocked records are included.
7. No manifest or sidecar is included (they are generated locally).
8. All JSON files in the bundle are BOM-free.

## Relationship to TCE Adapter Package

| Responsibility | TCE Adapter Package | Helios Runtime Bundle |
|---|---|---|
| Bridge source-of-truth | Owns `HeliosIntegrityBridge.ps1` | Receives vendor copy |
| Hook scripts | Does not include | Includes all 4 hooks |
| Policy | Does not include | Includes `command-policy.json` |
| Schemas | Adapter schemas | Runtime schemas |
| Manifest | Adapter package manifest | Generated locally |
| Install tools | Package builder, verifier, install plan | None (consumed by installer) |
| Gap-test evidence | Includes 12 test directories | Not included |
| Lock requirements | Includes derivation doc | Referenced via handoff doc |

The TCE adapter package and Helios runtime bundle are complementary. Neither is sufficient alone. The combined install plan orchestrates both into a working `.command-gate/` installation.
