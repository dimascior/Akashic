# Phase 3.99.1 — Package Validation Results

## Summary

Phase 3.99.1 proves the two-package installer architecture by executing the full package build and verification chain. All tools produce PASS results after targeted fixes to manifest completeness, BOM hardening, and file list coverage.

## Validation Chain

| Step | Tool | Result | Detail |
|---|---|---|---|
| 1 | `New-HeliosAdapterPackage.ps1` | SUCCESS | 53 files, 0 skipped |
| 2 | `Test-HeliosAdapterPackage.ps1` | PASS 13/13 | All BOM checks clean |
| 3 | `New-HeliosRuntimeBundle.ps1` | SUCCESS | 19 files, .gitkeep hashed |
| 4 | `Test-HeliosRuntimeBundle.ps1` | PASS 17/17 | files[]/file_hashes/checksums cross-validated |
| 5 | `New-HeliosCombinedInstallPlan.ps1` | SUCCESS | 15-step plan, settings requires approval |
| 6 | `Test-HeliosEndToEndInstallPlan.ps1` | PASS 16/16 | Full simulation in temp directory |

## End-to-End Simulation Checks

- Adapter package verifies: PASS
- Runtime bundle verifies: PASS
- Install plan generated: PASS
- Prepare mode executed: PASS
- Target scaffold created: PASS
- .gitkeep files created (5 dirs): PASS
- Protected runtime files copied (5 files): PASS
- Bridge copied: PASS
- Bridge byte identity: PASS
- Manifest generated: PASS
- Sidecar generated: PASS
- Manifest BOM-free: PASS
- Sidecar BOM-free: PASS
- Envelope integrity: CLEAN
- Settings plan requires approval: PASS
- Rollback plan exists: PASS

## Fixes Applied

### A. Adapter package builder file list incomplete

`New-HeliosAdapterPackage.ps1` did not include Phase 3.99 tools or docs. Added 6 entries:

- `tools\New-HeliosRuntimeBundle.ps1`
- `tools\Test-HeliosRuntimeBundle.ps1`
- `tools\New-HeliosCombinedInstallPlan.ps1`
- `tools\Test-HeliosEndToEndInstallPlan.ps1`
- `docs\helios-runtime-bundle-contract.md`
- `docs\phase399-operational-enforcement-observations.md`

Also added the 4 new tools to `Test-HeliosAdapterPackage.ps1` required files list.

### B. Adapter package verifier lacked BOM checks

`Test-HeliosAdapterPackage.ps1` had no BOM detection. Added checks for:

- `package-manifest.json` BOM status
- `checksums.sha256` BOM status
- All JSON files in the package

Results are returned in a `bom_check` object with `package_manifest_bom_free`, `checksums_bom_free`, and `json_bom_free` fields.

### C. Runtime bundle .gitkeep files not tracked

`New-HeliosRuntimeBundle.ps1` created `.gitkeep` files in mutable directories and added them to `files[]`, but did not compute their hashes or add them to `file_hashes` or `runtime-checksums.sha256`. Added `Add-TrackedFile` helper function and applied it to all file creation/copy paths. Also tracked `templates/.gitkeep`.

### D. Runtime bundle verifier lacked cross-checks

`Test-HeliosRuntimeBundle.ps1` verified checksums but did not cross-check `files[]` against `file_hashes` against checksums. Added:

- `files_exist_on_disk` — every files[] entry exists
- `files_have_hashes` — every files[] entry has a matching file_hashes entry
- `hashes_in_checksums` — every file_hashes entry appears in checksums
- `manifest_bom_free` — runtime-manifest.json BOM check
- `checksums_bom_free` — runtime-checksums.sha256 BOM check
- `mutable_gitkeep_present` — all 4 mutable dirs have .gitkeep

### E. Combined install Prepare mode missing .gitkeep creation

`New-HeliosCombinedInstallPlan.ps1` Prepare mode created directories but not `.gitkeep` files. Added creation of `.gitkeep` in pending, inflight, evidence, blocked, and templates. Added `manifest_status: pending_rebaseline` marker.

### F. End-to-end simulation missing checks

`Test-HeliosEndToEndInstallPlan.ps1` did not verify `.gitkeep` files or protected file copies. Added:

- `gitkeep_files_created` — 5 .gitkeep files in mutable + templates dirs
- `protected_files_copied` — 5 protected runtime files present

## First-Run Failure

The initial e2e simulation failed because `Test-HeliosRuntimeBundle.ps1` was not in the adapter package. The adapter package builder's file list (from Phase 3.98) predated the Phase 3.99 tools. Fix A resolved this.

## Conclusion

The two-package installer architecture is validated. Phase 4 can proceed with confidence that the packaging, verification, and installation toolchain produces correct results.
