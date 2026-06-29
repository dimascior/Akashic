# Unlock-AkashicRoot.ps1 - Remove OS-native filesystem locks from protected Akashic files
# Reuses the existing platform lock backend: Windows icacls, Linux chattr, macOS chflags.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$AllowWeakFallback
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$libDir = Join-Path $ScriptDir 'lib'
. (Join-Path $libDir 'AkashicLockBackend.ps1')

$Strategy = & (Join-Path $ScriptDir 'Get-AkashicLockStrategy.ps1') `
    -PrivilegeMode $PrivilegeMode `
    -AllowWeakFallback:$AllowWeakFallback

Write-Host "Unlock backend: $($Strategy.backend) ($($Strategy.strength)) on $($Strategy.platform)"

if (-not $Strategy.implemented) {
    Write-Error "No unlock backend available. Blockers: $($Strategy.blockers -join ', ')"
    return @()
}

$manifestPath = Join-Path $AkashicRoot 'manifest\akashic-envelope.json'
if (-not (Test-Path $manifestPath)) {
    throw 'Cannot unlock: akashic-envelope.json not found. Run New-AkashicSelfManifest.ps1 first.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$results = @()

function Unlock-SingleFile {
    param([string]$FilePath, [string]$Label)
    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }
    if ($PSCmdlet.ShouldProcess($FilePath, "Remove $($Strategy.backend) lock")) {
        $r = Invoke-AkashicUnlockPath -Strategy $Strategy -Path $FilePath
        if ($r.ExitCode -eq 0) {
            Write-Host "UNLOCKED: $Label"
            return @{ Path = $FilePath; Label = $Label; Status = 'UNLOCKED'; Backend = $Strategy.backend }
        } else {
            Write-Warning "FAILED to unlock $Label : $($r.Output)"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
        }
    } else {
        Write-Host "WOULD UNLOCK: $Label"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF'; Backend = $Strategy.backend }
    }
}

$sep = [System.IO.Path]::DirectorySeparatorChar
foreach ($entry in $manifest.protected.files) {
    $fullPath = Join-Path $AkashicRoot ($entry.path -replace '/', $sep)
    $results += Unlock-SingleFile -FilePath $fullPath -Label $entry.path
}

$manifestFile = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.json"
$sidecarFile  = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.sha256"
$results += Unlock-SingleFile -FilePath $manifestFile -Label 'manifest/akashic-envelope.json'
$results += Unlock-SingleFile -FilePath $sidecarFile -Label 'manifest/akashic-envelope.sha256'

$unlocked = @($results | Where-Object { $_.Status -eq 'UNLOCKED' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = @($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf   = @($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host ''
Write-Host "--- Akashic Root Unlock Summary ---"
Write-Host "Backend:   $($Strategy.backend) ($($Strategy.strength))"
Write-Host "Unlocked:  $unlocked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Unlock operation completed with $failed failure(s)."
}

$results
