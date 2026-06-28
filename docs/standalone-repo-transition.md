# Standalone Repo Transition

This document records the provenance and extraction plan for the Helios integrity adapter.

## Origin

The adapter was developed on the `helios-integrity-adapter` branch of [TerminalContextExporter](https://github.com/dimascior/TerminalContextExporter) between Phases 3.97 and 4.0. TCE main (`c594a75`) was preserved without adapter entries throughout development.

### Branch history

| Commit | Phase | Description |
|---|---|---|
| `783193e` | 3.97 | Gap-test completion and lock-requirement derivation |
| `1bcf1e9` | 3.98 | Packaging architecture and install tooling |
| `c81eab9` | 3.99 | Runtime bundle packaging and BOM hardening |
| `c4df19c` | 3.99.1 | Package validation and manifest hardening |
| `9d6bd88` | 4.0 | Lock design from gap evidence |
| `efc090b` | branch hygiene | Remove legacy root docs from helios-integrity-adapter |
| `2916e3a` | transition | Add standalone repo transition note |

## Repository roles after transition

| Repository | Role |
|---|---|
| **TerminalContextExporter** (main) | Original TCE module. No adapter entries. Preserved as the clean public baseline. |
| **TerminalContextExporter** (helios-integrity-adapter) | Extraction seed branch. Archived after standalone repo creation. |
| **Standalone adapter repo** | Long-term home for the adapter package, Phase 4.1 lock tooling, and future phases. |
| **Helios-** (main, after PR #2 merge) | Active runtime target. Consumes adapter and runtime bundle packages downstream. |

## TCE main preservation

TCE main must remain unchanged:

- HEAD: `c594a75`
- FileList: no `Adapters\Helios` entries
- No adapter code, evidence, schemas, tools, or docs
- The `helios-integrity-adapter` branch is NOT merged into TCE main

## Extraction approach

### Recommended: clean export with provenance

1. Create a new repository (e.g., `helios-integrity-adapter` or `tce-helios-adapter`).
2. Copy the current tree from `MyExporter/Adapters/Helios/` into the repo root.
3. Adjust the README to note standalone context (remove TCE-nested path references).
4. Add a provenance section recording the TCE origin and branch history (this document).
5. Create a single initial commit referencing the source branch and final extraction seed commit (the HEAD of `helios-integrity-adapter` at time of extraction).
6. Continue Phase 4.1 implementation in the standalone repo.

### Alternative: subtree split with history

```
git subtree split --prefix=MyExporter/Adapters/Helios -b adapter-standalone
```

This preserves per-file commit history but:
- Loses commits that touched files outside the subtree (e.g., `MyExporter.psd1` updates).
- Produces a partial history that may confuse readers.
- The 7-commit history is short enough that provenance notes in README are sufficient.

**Recommendation: clean export.** The commit history is compact (7 commits). Provenance is better served by an explicit record than by a partial git history.

## What the standalone repo contains

From `MyExporter/Adapters/Helios/` on `helios-integrity-adapter` at the final extraction seed commit:

- `AkashicIntegrityBridge.ps1` — 7-function integrity witness bridge
- `README.md` — adapter documentation with packaging, install, and phase roadmap
- `schemas/` — 3 JSON Schema definitions (envelope, baseline, command-evidence)
- `tools/` — 13 tools (sync, manifest, integrity, gap-test, packaging, install)
- `docs/` — 12 documents (spec, lock requirements, packaging, Phase 4.0 design, transition note)
- `evidence/` — gap-test evidence and package validation results
- `Tests/` — Pester test suite

## What stays in TCE

TCE main retains only the original MyExporter module. The `helios-integrity-adapter` branch can be archived or deleted after the standalone repo is created and verified.

## Phase 4.1 implementation target

Phase 4.1 (lock/unlock/rebaseline tooling) begins in the standalone adapter repo, not in TCE main or the TCE adapter branch. The standalone repo is the long-term home for:

- Phase 4.1: Lock/unlock/rebaseline tooling
- Phase 4.2: Live lock verification evidence
- Phase 5: Lock system packaging
- Phase 6: Long-term lock verification and audit strategy

## Helios consumption model

After PR #2 merges into Helios main, Helios owns the runtime `.command-gate/` tree. The adapter repo produces two distribution packages:

1. **TCE adapter package** — bridge source, schemas, tools, docs
2. **Helios runtime bundle** — vendored bridge, hooks, policy, manifest

Helios installs the runtime bundle via `AkashicCombinedInstallPlan.ps1`. The adapter repo remains the source-of-truth for the bridge implementation.
