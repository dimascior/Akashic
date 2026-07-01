# Human Rebaseline Boundary

## Principle

The durable manifest (`helios-envelope.json` + `helios-envelope.sha256`) is the root of trust. Its integrity depends on a human-approved rebaseline process. A model can propose changes to protected files and propose a rebaseline, but a human must approve it.

## Boundary Rules

1. **A model can propose a rebaseline.** The model may modify protected files as part of approved implementation work and suggest that the manifest be updated.

2. **A human approves the rebaseline.** The rebaseline tool writes `helios-envelope.json` and `helios-envelope.sha256`. The human runs the tool or confirms the model's invocation.

3. **The front controller trusts the new manifest only after that approved rebaseline.** Until the manifest is updated, any modification to protected files causes INTEGRITY_FAILURE on the next shell command.

4. **The session baseline refreshes automatically.** After a successful rebaseline, the next clean gated command creates a new session baseline. No human action is required for this step.

## Rebaseline Steps

```
1. Human approves the change to protected file(s).
2. Change is made (by model or human).
3. Human runs (or approves model running):
   tools/New-HeliosEnvelopeManifest.ps1 -GateRoot .command-gate -RebaselinedBy human
4. Human verifies:
   tools/Test-HeliosEnvelopeIntegrity.ps1 -GateRoot .command-gate
   → expect CLEAN
5. Next gated command creates session baseline automatically.
6. If using helios-lock (Phase 4): human relocks all protected files.
```

## What "RebaselinedBy" Means

The `-RebaselinedBy` parameter in `New-HeliosEnvelopeManifest.ps1` records who approved the rebaseline. The value `human` means a human reviewed and approved the current state of all protected files before the manifest was regenerated. Other values (e.g., `automated`, `ci`) are possible but carry lower trust.

## Trust Chain

```
Human approves file state
  → New-HeliosEnvelopeManifest.ps1 writes manifest + sidecar
    → helios_pretooluse.ps1 verifies sidecar, then manifest hashes
      → If CLEAN: dot-source bridge, create/verify baseline, proceed to gate validation
      → If DRIFT: deny with INTEGRITY_FAILURE before any policy code loads
```

## Compromise Scenarios

| Scenario | Detection |
|---|---|
| Model modifies protected file without rebaseline | INTEGRITY_FAILURE on next shell command |
| Model modifies manifest to match tampered file | Sidecar mismatch (sidecar still has old hash) |
| Model modifies both manifest and sidecar | Detection only if helios-lock prevents the write. Without locks, this is the bootstrap trust gap. |
| Model modifies settings.json to remove hooks | No detection. This is why settings.json is a Phase 4 lock target. |

The bootstrap trust caveat: before helios-lock exists, a fully local attacker can modify manifest, sidecar, and protected files in a coordinated way. The integrity witness detects individual drift but cannot prevent coordinated replacement. This is exactly why Phase 4 locks matter.
