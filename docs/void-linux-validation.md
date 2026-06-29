# Akashic Void Linux Validation Report

**Date:** 2026-06-29  
**Platform:** Void Linux (glibc), Kernel 6.12.65_1  
**PowerShell:** 7.6.3 (Linux-x64)

## Summary

Akashic integrity verification system successfully validated on Void Linux. The `HeliosIntegrityBridge.ps1` correctly validates manifest hashes and detects tampering of protected files.

## Architecture on Linux

```
HeliosIntegrityBridge.ps1
    ↓
helios-envelope.json (manifest)
    ↓
helios-envelope.sha256 (sidecar)
    ↓
Protected files (hooks/*.ps1, policy/*.json)
```

## Validation Results

### Manifest Integrity Check: PASS
- Sidecar hash correctly validates `helios-envelope.json`
- Protected file hashes match manifest entries
- Session baselines snapshot hashes at session start

### Tampering Detection: PASS
When `gate_check.ps1` was modified locally, the integrity check correctly blocked commands with:
```
INTEGRITY VIOLATION: hash mismatch for hooks/gate_check.ps1
```

### Hash Algorithm
- SHA256 (UTF-8 bytes)
- Computed via `[System.Security.Cryptography.SHA256]::Create()`

## Security Finding: Same-Trust-Boundary Bypass

**Observation:** An agent that can Write files can bypass integrity checks by updating both:
1. The protected file
2. The manifest hash in `helios-envelope.json`
3. The sidecar hash in `helios-envelope.sha256`

**This is by design** — Akashic protects against external tampering, not against authorized writers. The integrity system answers "has this file changed since the manifest was created?" not "is this agent authorized to change files?"

**Mitigation Recommendations:**
1. **Signed manifests** — Require GPG/age signature on sidecar that agent cannot forge
2. **External baseline authority** — Session baselines set by a trusted external process
3. **Immutable audit log** — All manifest updates logged to append-only store

## Linux-Specific Notes

### PowerShell Stdin Handling
Linux PowerShell `[Console]::In.ReadToEnd()` fully consumes stdin. Multiple reads return empty. This caused issues in `gate_check.ps1` when dot-sourced from `helios_pretooluse.ps1` (parent already consumed stdin).

### File Permissions
Installer creates root-owned files when run via sudo. Fix with:
```bash
sudo chown -R $USER:$USER ~/.helios
```

## Test Evidence

### Phase 4.1 Lock Fixture: PASS
- PlanOnly mode shows installation plan without writing
- Prepare mode writes files without activating hooks
- Activate mode enables hooks in Claude settings

### Phase 4.2 Live Operational: PASS
- PreToolUse hook intercepts Bash/PowerShell commands
- Ungated commands blocked with GATE REQUIRED message
- Gated commands execute, gate moves pending→inflight
- PostToolUse captures evidence with correlation_id

## Conclusion

Akashic integrity system is **OPERATIONAL** on Void Linux. The manifest chain correctly validates protected files at runtime. The same-trust-boundary bypass is a known limitation, not a bug — Akashic provides tamper-detection, not access control.
