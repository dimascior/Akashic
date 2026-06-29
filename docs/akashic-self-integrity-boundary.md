# Akashic Self-Integrity Boundary

## Purpose

Akashic verifies, prepares, activates, locks, unlocks, and rolls back a Helios runtime. Before Phase 4.3, Akashic verified Helios but was not itself independently verified. This phase makes Akashic a protected subject: Akashic must verify its own files before it is allowed to verify or modify Helios.

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
- Verification fails closed: if the manifest is missing, the sidecar is wrong, or any file has drifted, high-impact tools refuse to run.

**What Akashic self-integrity does not claim:**
- It does not prevent an actor with the same write authority over both protected files and the manifest from rewriting both.
- It does not provide cryptographic authority separation. Signature verification is SIGNATURE_NOT_IMPLEMENTED.
- It does not prevent the manifest generator from being run by an untrusted actor.

**Mitigation options (future phases):**
- GPG or minisign detached signatures over akashic-envelope.json
- External baseline authority (CI-anchored manifest, remote attestation)
- OS-level lock on manifest files (already supported via Lock-AkashicRoot.ps1)
- Append-only audit log of rebaseline events

## Protected Files

Protected patterns (discovered by tools at manifest generation time):

| Pattern | Role |
|---------|------|
| `AkashicIntegrityBridge.ps1` | bridge |
| `tools/*.ps1` | tool |
| `tools/lib/*.ps1` | library |
| `schemas/*.json` | schema |
| `docs/*.md` | contract-doc |
| `Tests/*.ps1` | test |

The manifest also lists itself and its sidecar as protected paths, but does not hash them (avoids self-referential hashing).

## Mutable Paths

| Path | Purpose |
|------|---------|
| `evidence/` | Validation output, phase evidence, gap test results |
| `manifest/akashic-envelope.sig` | Placeholder for detached signature |
| `manifest/akashic-public-key.asc` | Placeholder for verification key |

## Tools

| Tool | Purpose |
|------|---------|
| `New-AkashicSelfManifest.ps1` | Generate akashic-envelope.json and .sha256 sidecar |
| `Test-AkashicSelfIntegrity.ps1` | Verify all protected files against the manifest |
| `Assert-AkashicTrusted.ps1` | Fail-closed guard callable by other tools |
| `Lock-AkashicRoot.ps1` | Apply OS locks to protected Akashic files |
| `Unlock-AkashicRoot.ps1` | Remove OS locks from protected Akashic files |
| `Invoke-AkashicSelfRebaseline.ps1` | Unlock, regenerate manifest, verify, optionally re-lock |

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

## Signature Status

Manifest signature verification is SIGNATURE_NOT_IMPLEMENTED in this phase. The placeholder files `manifest/akashic-envelope.sig` and `manifest/akashic-public-key.asc` exist to define the future interface. No cryptographic authority separation exists until signature verification is implemented and tested.

## Schemas

- `schemas/akashic-self-envelope.v1.json` defines the manifest format.
- `schemas/akashic-self-integrity-evidence.v1.json` defines the verification evidence format.
