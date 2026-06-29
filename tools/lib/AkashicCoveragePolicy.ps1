# AkashicCoveragePolicy.ps1 - Shared coverage policy for Akashic self-integrity.
# Defines protected, mutable, and ignored classification patterns.
# Dot-source from New-AkashicSelfManifest.ps1 and Test-AkashicSelfIntegrity.ps1.
#
# Every repo file must be classified as protected, mutable, or ignored.
# Unclassified files are a coverage gap that the verifier reports.

# Discovery patterns for building the manifest.
# Dir: relative directory to scan (empty = repo root).
# Pattern: file filter for Get-ChildItem.
# Recurse: search subdirectories.
$script:AkashicProtectedDiscovery = @(
    # Root-level by extension (non-recursive)
    @{ Dir = ''; Pattern = '*.ps1'; Recurse = $false },
    @{ Dir = ''; Pattern = '*.md'; Recurse = $false },
    @{ Dir = ''; Pattern = '*.json'; Recurse = $false },
    # Recursive under specific directories
    @{ Dir = 'tools'; Pattern = '*.ps1'; Recurse = $true },
    @{ Dir = 'Tests'; Pattern = '*.ps1'; Recurse = $true },
    @{ Dir = 'schemas'; Pattern = '*.json'; Recurse = $true },
    @{ Dir = 'docs'; Pattern = '*.md'; Recurse = $true },
    @{ Dir = '.github/workflows'; Pattern = '*.yml'; Recurse = $false },
    @{ Dir = '.github/workflows'; Pattern = '*.yaml'; Recurse = $false },
    # Protected anywhere in repo (recursive from root)
    @{ Dir = ''; Pattern = '*.psd1'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.psm1'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.ps1xml'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.sh'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.bash'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.zsh'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.bat'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.cmd'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.py'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.yml'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.yaml'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.toml'; Recurse = $true },
    @{ Dir = ''; Pattern = '*.xml'; Recurse = $true }
)

# Mutable patterns: paths expected to change during operation.
$script:AkashicMutablePatterns = @(
    'evidence/*',
    'manifest/akashic-envelope.sig',
    'manifest/akashic-public-key.asc',
    'install-plan.json',
    '*.tmp',
    '*.log'
)

# Ignored patterns: intentionally outside the trust boundary.
$script:AkashicIgnoredPatterns = @(
    '.git/*',
    '.vscode/*',
    '.idea/*',
    'node_modules/*',
    '__pycache__/*'
)

# Classify a relative path as protected, mutable, ignored, or unknown.
# Caller must normalize path to forward slashes before calling.
function Get-AkashicFileClassification {
    param([string]$RelPath)

    $fileName = [System.IO.Path]::GetFileName($RelPath)
    if ($fileName -eq '.DS_Store') { return 'ignored' }

    foreach ($pattern in $script:AkashicIgnoredPatterns) {
        if ($RelPath -like $pattern) { return 'ignored' }
    }

    foreach ($pattern in $script:AkashicMutablePatterns) {
        if ($RelPath -like $pattern) { return 'mutable' }
    }

    # Manifest files: protected path, not hashed (self-referential avoidance)
    if ($RelPath -eq 'manifest/akashic-envelope.json' -or
        $RelPath -eq 'manifest/akashic-envelope.sha256') {
        return 'protected'
    }

    # Directory-scoped protected patterns
    if ($RelPath -like 'tools/*.ps1') { return 'protected' }
    if ($RelPath -like 'Tests/*.ps1') { return 'protected' }
    if ($RelPath -like 'schemas/*.json') { return 'protected' }
    if ($RelPath -like 'docs/*.md') { return 'protected' }
    if ($RelPath -like '.github/workflows/*.yml') { return 'protected' }
    if ($RelPath -like '.github/workflows/*.yaml') { return 'protected' }

    $ext = [System.IO.Path]::GetExtension($RelPath).ToLower()

    # Protected anywhere in repo
    if ($ext -in @('.psd1', '.psm1', '.ps1xml', '.sh', '.bash', '.zsh',
                   '.bat', '.cmd', '.py', '.yml', '.yaml', '.toml', '.xml')) {
        return 'protected'
    }

    # Protected at root only (no directory separator)
    if ($RelPath -notlike '*/*' -and $ext -in @('.ps1', '.md', '.json')) {
        return 'protected'
    }

    return 'unknown'
}
