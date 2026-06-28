# Akashic — Install Sequence

## Prerequisites

- PowerShell 5.1 or later.
- Target machine has a Helios gate root (`.command-gate/` directory) or will create one.
- Akashic adapter package (from git clone or release artifact).
- Claude Code installed (for hook activation).

## Install Sequence

### Step 1: Pull Akashic Adapter Package

**From git clone:**
```powershell
git clone https://github.com/dimascior/Akashic.git
$PackageRoot = "Akashic"
```

**From release artifact:**
```powershell
gh release download v<version> --repo dimascior/Akashic --dir akashic-adapter
$PackageRoot = "akashic-adapter"
```

### Step 2: Pull or Unpack Helios Runtime Bundle

The Helios runtime bundle is the `.command-gate/` directory structure. If the target repo already has a `.command-gate/`, this step is a verification. If not, the bundle provides the scaffold.

```powershell
$HeliosTargetRoot = "C:\path\to\target-repo\.command-gate"
```

### Step 3: Verify Akashic Adapter Package Checksum

```powershell
& "$PackageRoot\tools\Test-HeliosAdapterPackage.ps1" -PackageRoot $PackageRoot
```

Expected output: all files present, checksums match, bridge exists, schemas valid.

If checksum verification fails: **STOP**. Do not proceed with a tampered or corrupted package.

### Step 4: Verify Helios Runtime Bundle

If the Helios runtime bundle is a fresh download, verify its checksums. If it is an existing `.command-gate/` directory, verify envelope integrity:

```powershell
& "$PackageRoot\tools\Test-HeliosEnvelopeIntegrity.ps1" -HeliosGateRoot $HeliosTargetRoot
```

Expected: CLEAN verdict (existing installation) or directory-not-found (fresh installation).

### Step 5: Copy Akashic Bridge into Helios

```powershell
& "$PackageRoot\tools\Sync-HeliosBridge.ps1" `
    -AdapterRoot $PackageRoot `
    -HeliosGateRoot $HeliosTargetRoot
```

Expected output: `byte_identical = True`, matching SHA-256 hashes.

### Step 6: Verify Byte Identity

The sync tool reports byte identity. Confirm:

```powershell
$SourceHash = (Get-FileHash "$PackageRoot\HeliosIntegrityBridge.ps1" -Algorithm SHA256).Hash
$VendorHash = (Get-FileHash "$HeliosTargetRoot\hooks\lib\HeliosIntegrityBridge.ps1" -Algorithm SHA256).Hash
if ($SourceHash -ne $VendorHash) { throw "Bridge byte identity verification FAILED" }
```

### Step 7: Create Mutable Runtime Directories

```powershell
$MutableDirs = @('pending', 'inflight', 'evidence', 'blocked', 'maintenance',
                 'evidence\integrity', 'evidence\integrity\sessions',
                 'evidence\stale', 'evidence\maintenance', 'templates')
foreach ($dir in $MutableDirs) {
    $path = Join-Path $HeliosTargetRoot $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}
```

### Step 8: Generate Local Manifest

```powershell
& "$PackageRoot\tools\New-HeliosEnvelopeManifest.ps1" `
    -HeliosGateRoot $HeliosTargetRoot `
    -RebaselinedBy "installer" `
    -Note "Initial installation rebaseline"
```

The manifest is generated from the actual file hashes on the target machine. BOM-free UTF-8.

### Step 9: Generate Sidecar

The `New-HeliosEnvelopeManifest.ps1` tool generates both the manifest and sidecar in a single call. Verify the sidecar exists:

```powershell
if (-not (Test-Path (Join-Path $HeliosTargetRoot 'manifest\helios-envelope.sha256'))) {
    throw "Sidecar not generated"
}
```

### Step 10: Verify Envelope Integrity

```powershell
$IntegrityResult = & "$PackageRoot\tools\Test-HeliosEnvelopeIntegrity.ps1" -HeliosGateRoot $HeliosTargetRoot
```

Expected: `verdict = "CLEAN"`, `sidecar_valid = True`, all files CLEAN.

If verdict is DRIFT: **STOP**. Investigate the drifted files before proceeding.

### Step 11: Prepare Claude Settings Activation Plan

```powershell
$Plan = & "$PackageRoot\tools\New-HeliosInstallPlan.ps1" `
    -PackageRoot $PackageRoot `
    -HeliosTargetRoot $HeliosTargetRoot `
    -ClaudeSettingsPath "$env:USERPROFILE\.claude\settings.json" `
    -Mode PlanOnly
```

The plan generates a `install-plan.json` with the settings.json changes needed. Review the plan before proceeding.

### Step 12: Backup settings.json

```powershell
$SettingsPath = "$env:USERPROFILE\.claude\settings.json"
$BackupPath = "$env:USERPROFILE\.claude\settings.json.pre-helios-backup"
if (Test-Path $SettingsPath) {
    Copy-Item $SettingsPath $BackupPath
}
```

### Step 13: Activate Hooks (REQUIRES EXPLICIT APPROVAL)

**This step modifies `settings.json` to enable Helios hooks. Do not proceed without explicit human approval.**

The install plan from Step 11 shows exactly what will be added to `settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"<HeliosTargetRoot>\\hooks\\helios_pretooluse.ps1\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"<HeliosTargetRoot>\\hooks\\evidence_capture.ps1\""
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"<HeliosTargetRoot>\\hooks\\evidence_capture.ps1\""
          }
        ]
      }
    ]
  }
}
```

The human applies these changes to `settings.json` manually or confirms the installer should apply them.

### Step 14: Run No-Gate Deny Smoke Test

After activation, run a shell command without a matching gate. Expected: DENY.

```powershell
# Run any command through Claude Code
# Helios should deny with "no valid gate found"
```

### Step 15: Run Valid-Gate Allow Smoke Test

Create a valid gate file in `pending/` and run the matching command. Expected: ALLOW with full evidence chain.

Verify evidence files exist:
```
evidence/integrity/sessions/<session_id>/
  baseline.json
  commands/
    <tool_use_id>.before.json
    <tool_use_id>.decision.json
    <tool_use_id>.after.json
    <tool_use_id>.compare.json
```

### Step 16: Write Install Evidence

```powershell
$InstallEvidence = @{
    timestamp_utc       = (Get-Date).ToUniversalTime().ToString('o')
    installer_version   = '0.3.98'
    package_source      = $PackageRoot
    helios_target       = $HeliosTargetRoot
    bridge_hash         = $SourceHash
    manifest_hash       = (Get-Content (Join-Path $HeliosTargetRoot 'manifest\helios-envelope.sha256') -Raw).Trim()
    envelope_verdict    = 'CLEAN'
    smoke_test_deny     = $true
    smoke_test_allow    = $true
    settings_activated  = $true
    settings_backup     = $BackupPath
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Json = $InstallEvidence | ConvertTo-Json -Depth 5
$EvidencePath = Join-Path $HeliosTargetRoot 'evidence\install-evidence.json'
[System.IO.File]::WriteAllText($EvidencePath, $Json, $Utf8NoBom)
```

## Rollback Procedure

If installation fails or the user wants to remove Helios:

1. Restore `settings.json` from backup: `Copy-Item $BackupPath $SettingsPath`.
2. Remove `.command-gate/` directory (or the specific installed files).
3. Verify no hooks are active: run a shell command and confirm no gate prompt.

## Post-Install Verification Checklist

- [ ] `Test-HeliosAdapterPackage` passes on the package.
- [ ] `Test-HeliosRuntimeBundle` passes on the runtime bundle.
- [ ] `Test-HeliosEnvelopeIntegrity` returns CLEAN on the target.
- [ ] Bridge byte identity confirmed.
- [ ] Mutable directories exist.
- [ ] Manifest and sidecar present, valid, and BOM-free.
- [ ] settings.json backup exists.
- [ ] No-gate deny smoke test passes.
- [ ] Valid-gate allow smoke test passes with full evidence chain.
- [ ] Install evidence written.

## Two-Package Combined Install (Phase 3.99)

For a complete fresh installation using both packages:

```powershell
# 1. Build or pull both packages
$AdapterPkg = "akashic-v0.4.1"
$RuntimePkg = "helios-runtime-v0.4.1"

# 2. Verify both packages
& "$AdapterPkg\tools\Test-HeliosAdapterPackage.ps1" -PackageRoot $AdapterPkg
& "$AdapterPkg\tools\Test-HeliosRuntimeBundle.ps1" -BundleRoot $RuntimePkg

# 3. Generate combined install plan
& "$AdapterPkg\tools\New-HeliosCombinedInstallPlan.ps1" `
    -AdapterPackageRoot $AdapterPkg `
    -RuntimeBundleRoot $RuntimePkg `
    -TargetGateRoot "C:\path\to\repo\.command-gate" `
    -Mode PlanOnly

# 4. Review plan, then execute with Prepare mode
# 5. Generate local manifest (BOM-free)
# 6. Verify envelope CLEAN
# 7. Human approves settings.json activation
# 8. Run smoke tests
```

### End-to-End Simulation

Before a real install, run the simulation to verify both packages work together:

```powershell
& "$AdapterPkg\tools\Test-HeliosEndToEndInstallPlan.ps1" `
    -AdapterPackageRoot $AdapterPkg `
    -RuntimeBundleRoot $RuntimePkg
```

This creates a temporary directory, runs the full install flow, verifies BOM-free manifest/sidecar, checks envelope integrity, and cleans up.
