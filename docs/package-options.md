# Helios TCE Adapter — Package Distribution Options

## Option 1: Git Clone from helios-integrity-adapter

**How users pull it:**
```bash
git clone -b helios-integrity-adapter https://github.com/<owner>/TerminalContextExporter.git
```

**Pros:**
- Full git history and blame available.
- Users can track upstream changes with `git pull`.
- No build step required.
- Source transparency — every file inspectable.

**Cons:**
- Pulls entire repo (including non-adapter files on the branch).
- Requires git.
- Users must know the branch name.
- No versioned release — always tracking HEAD.

**Trust properties:**
- Git commit signatures (if configured) verify author.
- File integrity verified by git object hashes.
- No package-level checksum (must verify after clone).

**Branch impact:** None — reads from adapter branch, no merge required.

**Recommended phase:** 3.98 (development distribution).

---

## Option 2: Branch Zip from Fork

**How users pull it:**
```
Download: https://github.com/<owner>/TerminalContextExporter/archive/refs/heads/helios-integrity-adapter.zip
```

**Pros:**
- No git required.
- Single download.
- Contains only the branch snapshot.

**Cons:**
- No git history.
- GitHub-generated zip may differ from local builds (line endings, metadata).
- No built-in versioning.
- Must verify checksums manually.

**Trust properties:**
- GitHub serves the zip over HTTPS.
- No content signature beyond transport security.
- Users should verify `checksums.sha256` after extraction.

**Branch impact:** None — reads from adapter branch.

**Recommended phase:** 3.98 (quick distribution).

---

## Option 3: GitHub Release Artifact

**How users pull it:**
```bash
gh release download v0.3.98 --repo <owner>/TerminalContextExporter
```
Or download from the Releases page.

**Pros:**
- Versioned releases with changelogs.
- Deterministic content (built from specific commit).
- Can include `checksums.sha256` as a release asset.
- Users see release notes and version history.
- Works with `gh` CLI or browser download.

**Cons:**
- Requires a release workflow (manual or automated).
- Release must be cut from the adapter branch, not main.
- GitHub release UI defaults to main — adapter-branch releases need clear labeling.

**Trust properties:**
- Release tied to specific commit hash.
- `checksums.sha256` included as asset.
- Release author visible in GitHub UI.
- Optional: GPG-sign the release tag.

**Branch impact:** None — release built from adapter branch commit.

**Recommended phase:** 3.98 (recommended distribution method).

---

## Option 4: PowerShell Module Package

**How users pull it:**
```powershell
Install-Module -Name HeliosTceAdapter -Repository PSGallery
```

**Pros:**
- Standard PowerShell distribution mechanism.
- Version management built in.
- Dependency resolution (if needed).
- `Update-Module` for upgrades.

**Cons:**
- Requires PSGallery account and publishing workflow.
- Module manifest must be separate from MyExporter.psd1.
- PSGallery review process adds latency.
- The adapter is not a standalone module — it depends on Helios runtime context.

**Trust properties:**
- PSGallery signs packages.
- Version pinning available.
- Module manifest declares dependencies.

**Branch impact:** None — published from adapter branch, not main.

**Recommended phase:** Future (after install flow stabilizes and adapter is proven stable).

---

## Option 5: Dedicated Adapter Repo

**How users pull it:**
```bash
git clone https://github.com/<owner>/helios-tce-adapter.git
```

**Pros:**
- Clean separation — adapter has its own repo, issues, releases.
- No confusion with MyExporter main module.
- Independent release cycle.

**Cons:**
- Requires repo creation and maintenance.
- Sync between TCE source and dedicated repo adds overhead.
- Bridge source-of-truth must still live in TCE (or ownership transfers).
- More repos to manage.

**Trust properties:**
- Standard git/GitHub trust model.
- Independent release and tagging.

**Branch impact:** TCE adapter branch content would be mirrored. Source-of-truth ownership must be documented.

**Recommended phase:** Future (if adapter scope grows beyond TCE's Adapters/ directory).

---

## Option 6: Helios Monorepo Bundle

**How users pull it:**
Clone the Helios (MythosJustAFable) repo with the adapter included.

**Pros:**
- Single repo contains both runtime and adapter.
- No cross-repo sync needed.

**Cons:**
- Violates TCE ownership boundary — TCE owns the bridge source-of-truth.
- Helios repo is currently private.
- Mixes runtime consumer (Helios) with source-of-truth producer (TCE).
- Makes bridge updates harder to track.

**Trust properties:**
- Single repo simplifies trust but obscures ownership.
- Bridge provenance becomes unclear.

**Branch impact:** Would require merging adapter into Helios repo. Breaks TCE ownership model.

**Recommended phase:** Not recommended — violates established ownership boundaries.

---

## Option 7: Git Submodule or Subtree

**How users pull it:**
```bash
# Submodule
git submodule add -b helios-integrity-adapter https://github.com/<owner>/TerminalContextExporter.git .tce-adapter

# Subtree
git subtree add --prefix=.tce-adapter https://github.com/<owner>/TerminalContextExporter.git helios-integrity-adapter --squash
```

**Pros:**
- Helios repo references TCE adapter at a specific commit.
- Updates are explicit (`git submodule update` or `git subtree pull`).
- Preserves ownership boundary.

**Cons:**
- Submodules are notoriously confusing for users.
- Subtree merges create noisy git history.
- Both add operational complexity.
- CI/CD must handle the cross-repo reference.

**Trust properties:**
- Submodule pins to exact commit hash.
- Subtree squash loses individual commit history.

**Branch impact:** References adapter branch commit. No merge into TCE main.

**Recommended phase:** Future (if Helios repo needs to pin a specific adapter version).

---

## Option 8: Future helios-lock Package

**How users pull it:**
```powershell
Install-Module -Name HeliosLock
# or
pip install helios-lock
```

**Pros:**
- Dedicated package for Phase 4+ filesystem prevention.
- Clear separation: adapter (detection) vs lock (prevention).
- Independent versioning.

**Cons:**
- Phase 4 implementation not started.
- Packaging decision (Python vs PowerShell) not made.
- Depends on adapter being stable first.

**Trust properties:**
- Package-manager signing and versioning.
- Depends on adapter package for integrity verification.

**Branch impact:** Separate package, not in TCE adapter or main.

**Recommended phase:** Phase 5 (after Phase 4 implementation).

---

## Recommendation Summary

| Phase | Distribution Method | Audience |
|---|---|---|
| 3.98 (now) | GitHub release artifact from adapter branch | Primary distribution |
| 3.98 (now) | Git clone of adapter branch | Development and contribution |
| Future | PowerShell module | Stable release distribution |
| Future | Dedicated repo | If adapter scope grows |
| Not recommended | Helios monorepo | Violates ownership boundary |
| Phase 5 | helios-lock package | After Phase 4 implementation |
