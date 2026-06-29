# Akashic Self-Integrity Boundary

## Purpose

Akashic verifies, prepares, activates, locks, unlocks, and rolls back a Helios runtime. Akashic must verify its own files before it is allowed to verify or modify Helios.

## Architecture

- **Helios** is the runtime gate system. It controls Claude's Bash/PowerShell execution through gate enforcement.
- **Akashic** is the installer, integrity adapter, activation helper, lock/unlock framework, and verifier. It is the tooling that gets Helios deployed and maintains it.
- **Self-integrity** means Akashic's tools, libraries, schemas, and contract documents are hashed, manifested, and verified before any high-impact operation proceeds.

## Trust Boundary

Hash-only self-integrity detects drift but does not prevent an agent with write access to both files and manifests from rewriting them. Signed or external authority is required for that guarantee.

**What Akashic self-integrity claims:**
- Every protected Akashic file is hashed at manifest creation time.
- Before any high-impact tool runs, all protected files are verified against the manifest.
- File additions matching protected patterns that are not in the manifest are flagged.
- Sidecar hash mismatches are detected and fail the integrity check.
- Every repo file is classified as protected, mutable, ignored, or unknown.
- Unclassified files fail the integrity check by default.
- Verification fails closed: if the manifest is missing, the sidecar is wrong, any file has drifted, or unclassified files exist, high-impact tools refuse to run.

**What Akashic self-integrity does not claim:**
- It does not prevent an actor with the same write authority over both protected files and the manifest from rewriting both.
- It does not provide cryptographic authority separation. Signature verification is SIGNATURE_NOT_IMPLEMENTED.
- It does not prevent the manifest generator from being run by an untrusted actor.

**Mitigation options (future phases):**
- GPG or minisign detached signatures over akashic-envelope.json
- External baseline authority (CI-anchored manifest, remote attestation)
- OS-level lock on manifest files (already supported via Lock-AkashicRoot.ps1)
- Append-only audit log of rebaseline events

## Coverage Policy

Every repo file must be classified. Silent noncoverage is the bug.

### Protected

Files that can alter Akashic behavior, trust, installation, verification, CI, schema interpretation, or documentation contracts.

| Pattern | Scope | Role |
|---------|-------|------|
| `AkashicIntegrityBridge.ps1` | root | bridge |
| `*.ps1` | root | tool |
| `*.md` | root | contract-doc |
| `*.json` | root | config |
| `tools/**/*.ps1` | recursive | tool / compatibility-wrapper |
| `tools/lib/**/*.ps1` | recursive | library |
| `Tests/**/*.ps1` | recursive | test |
| `schemas/**/*.json` | recursive | schema |
| `docs/**/*.md` | recursive | contract-doc |
| `.github/workflows/*.yml` | directory | ci-workflow |
| `.github/workflows/*.yaml` | directory | ci-workflow |
| `*.psd1` | anywhere | module |
| `*.psm1` | anywhere | module |
| `*.ps1xml` | anywhere | module |
| `*.sh`, `*.bash`, `*.zsh` | anywhere | script |
| `*.bat`, `*.cmd` | anywhere | script |
| `*.py` | anywhere | script |
| `*.yml`, `*.yaml` | anywhere | config |
| `*.toml`, `*.xml` | anywhere | config |

The manifest also lists itself and its sidecar as protected paths, but does not hash them (avoids self-referential hashing).

### Mutable

Paths expected to change during normal Akashic operation.

| Pattern | Purpose |
|---------|---------|
| `evidence/*` | Validation output, phase evidence, gap test results |
| `manifest/akashic-envelope.sig` | Placeholder for detached signature |
| `manifest/akashic-public-key.asc` | Placeholder for verification key |
| `install-plan.json` | Generated install plan output |
| `*.tmp` | Temporary files |
| `*.log` | Log files |

### Ignored

Paths intentionally outside the trust boundary.

| Pattern | Purpose |
|---------|---------|
| `.git/*` | Git internals |
| `.vscode/*` | Editor metadata |
| `.idea/*` | Editor metadata |
| `node_modules/*` | Dependency cache |
| `__pycache__/*` | Python bytecode cache |
| `.DS_Store` | macOS Finder metadata |

### Unknown / Unclassified

Files that do not match any protected, mutable, or ignored pattern. The verifier reports `UNCLASSIFIED_FILES_FOUND` and fails the integrity check by default. Pass `-AllowUnclassified` for discovery mode.

## Classification Audit

The verifier walks every file in the repo and reports:

| Category | Meaning |
|----------|---------|
| `protected_manifested` | In the manifest and hashes match |
| `protected_unmanifested` | Matches a protected pattern but absent from manifest |
| `mutable_present` | In a mutable path, allowed to change |
| `ignored_present` | In an ignored path, outside trust boundary |
| `unknown_unclassified` | Not matched by any category |

## Tools

| Tool | Purpose |
|------|---------|
| `New-AkashicSelfManifest.ps1` | Generate akashic-envelope.json and .sha256 sidecar |
| `Test-AkashicSelfIntegrity.ps1` | Verify all protected files and classify every repo file |
| `Assert-AkashicTrusted.ps1` | Fail-closed guard callable by other tools |
| `Lock-AkashicRoot.ps1` | Apply OS locks to protected Akashic files |
| `Unlock-AkashicRoot.ps1` | Remove OS locks from protected Akashic files |
| `Invoke-AkashicSelfRebaseline.ps1` | Unlock, regenerate manifest, verify, optionally re-lock |
| `lib/AkashicCoveragePolicy.ps1` | Shared coverage policy (protected, mutable, ignored patterns) |

## Assert-AkashicTrusted Integration

The following high-impact tools call `Assert-AkashicTrusted.ps1` before any modification:

- `Apply-AkashicClaudeHooks.ps1` (modifies Claude settings)
- `Remove-AkashicClaudeHooks.ps1` (modifies Claude settings)
- `Install-AkashicHeliosRuntime.ps1` (installs/activates Helios)
- `Lock-AkashicProtectedFiles.ps1` (locks Helios files)
- `Unlock-AkashicProtectedFiles.ps1` (unlocks Helios files)
- `AkashicEnvelopeManifest.ps1` (creates Helios manifest)
- `Invoke-AkashicRebaseline.ps1` (rebaselines Helios)
- `Sync-AkashicBridge.ps1` (syncs bridge to Helios)
- `Lock-HeliosRuntime.ps1` (runtime lock wrapper)
- `Unlock-HeliosRuntime.ps1` (runtime unlock wrapper)
- `Invoke-HeliosRuntimeRebaseline.ps1` (runtime rebaseline wrapper)
- `Rollback-AkashicHeliosRuntime.ps1` (rollback)

If `Assert-AkashicTrusted` fails, these tools throw `AKASHIC_UNTRUSTED` and refuse to proceed.

## Rebaseline Workflow

When Akashic files change intentionally (new tools, updated scripts, schema changes):

1. A human runs `Invoke-AkashicSelfRebaseline.ps1 -AkashicRoot <path> -RebaselinedBy human`
2. The tool unlocks files if locked, regenerates the manifest, verifies the new baseline, and optionally re-locks.
3. The manifest records `rebaselined_by: human` and `signature_status: SIGNATURE_NOT_IMPLEMENTED`.

If the verifier finds unclassified files after rebaseline, update the coverage policy in `tools/lib/AkashicCoveragePolicy.ps1` and rebaseline again.

## Signature Status

Manifest signature verification is SIGNATURE_NOT_IMPLEMENTED in this phase. The placeholder files `manifest/akashic-envelope.sig` and `manifest/akashic-public-key.asc` exist to define the future interface. No cryptographic authority separation exists until signature verification is implemented and tested.

## Install Origin Authority

`helios-install-origin.json` records the repo/source state used to create a Helios runtime installation. While `helios-envelope.json` proves current consistency (files match manifest), `helios-install-origin.json` proves source lineage (files match the repo state that created them).

This catches the bypass case where an actor rewrites both protected runtime files and the runtime manifest together. The origin file records:

- Git HEAD commits of both Akashic and Helios repos at install time
- SHA-256 hashes of every source file in RuntimeBundleRoot
- SHA-256 hashes of every installed file in HeliosGateRoot
- SHA-256 of the manifest and sidecar at install time
- SHA-256 of the Akashic installer tools that performed the install
- Bridge source and installed hashes

Origin is generated during Prepare (Phase 10) after manifest verification confirms CLEAN.

| Tool | Purpose |
|------|---------|
| `New-HeliosInstallOrigin.ps1` | Generate install origin during Prepare/Reset/Restore |
| `Test-HeliosRuntimeOrigin.ps1` | Detect disagreements across manifest, origin, source repo, and bridge |
| `Write-HeliosRuntimeDetection.ps1` | Write detection events to evidence directories with terminal summary |

## Runtime Origin Detection

The detector classifies disagreements between manifest consistency, install-origin lineage, current source repo state, and bridge source state. It compares six axes:

1. Live runtime files vs `helios-envelope.json` (manifest consistency)
2. Live runtime files vs `helios-install-origin.json` (origin lineage)
3. Current RuntimeBundleRoot files vs recorded source hashes (source repo state)
4. Current Akashic bridge vs installed HeliosIntegrityBridge (bridge state)
5. Current Akashic HEAD vs recorded Akashic HEAD (repo advance)
6. Current Helios HEAD vs recorded Helios HEAD (repo advance)

Detection types by severity:

| Detection | Severity | Recommended Action |
|-----------|----------|-------------------|
| BASELINE_REWRITE_SUSPECTED | CRITICAL | RESET_FROM_REPO |
| SIDECAR_MISMATCH | HIGH | VERIFY_ORIGIN_THEN_REGENERATE_OR_RESET |
| CURRENT_MANIFEST_DRIFT | HIGH | RESET_FROM_REPO |
| NO_INSTALL_ORIGIN | HIGH | RESET_FROM_REPO_TO_CREATE_ORIGIN |
| ORIGIN_DRIFT | HIGH | RESET_FROM_REPO |
| SOURCE_REPO_MISSING | HIGH | BLOCK_RESET_UNTIL_SOURCE_RESOLVED |
| SOURCE_REPO_CHANGED | MEDIUM | PLAN_RESET_FROM_NEW_REPO_STATE |
| BRIDGE_ORIGIN_DRIFT | MEDIUM | RESET_FROM_REPO |
| ORIGIN_MATCH | INFO | NONE |
| CURRENT_MANIFEST_CLEAN | INFO | NONE |

Bridge drift is classified separately from runtime file drift because the bridge comes from Akashic, while runtime files come from Helios RuntimeBundleRoot.

Automation modes: `DetectOnly`, `LogOnly`, `PlanReset`, `AutoReset`, `AutoResetAndReactivate`. `AutoReset` and `AutoResetAndReactivate` return `RESET_TOOL_NOT_IMPLEMENTED` until Phase 4.3.2c.

The detector logs only. It does not modify runtime files, manifests, hooks, locks, or Claude settings. Reset, restore, and uninstall are separate operations defined in Phase 4.3.2c.

## Schemas

- `schemas/akashic-self-envelope.v1.json` defines the manifest format.
- `schemas/akashic-self-integrity-evidence.v1.json` defines the verification evidence format.
- `schemas/helios-install-origin.v1.json` defines the install origin format.
- `schemas/helios-runtime-detection.v1.json` defines the detection event format.
