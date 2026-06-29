# Lock-AkashicRoot.ps1 - Apply OS-native filesystem locks to protected Akashic files
# Reuses the existing platform lock backend: Windows icacls, Linux chattr, macOS chflags.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$libDir = Join-Path $ScriptDir 'lib'
. (Join-Path $libDir 'AkashicLockBackend.ps1')

$Strategy = & (Join-Path $ScriptDir 'Get-AkashicLockStrategy.ps1') `
    -PrivilegeMode $PrivilegeMode `
    -RequireStrongLock:$RequireStrongLock `
    -AllowWeakFallback:$AllowWeakFallback

Write-Host "Lock backend: $($Strategy.backend) ($($Strategy.strength)) on $($Strategy.platform)"

if (-not $Strategy.implemented) {
    Write-Error "No lock backend available. Blockers: $($Strategy.blockers -join ', ')"
    return @()
}

$manifestPath = Join-Path $AkashicRoot 'manifest\akashic-envelope.json'
if (-not (Test-Path $manifestPath)) {
    throw 'Cannot lock: akashic-envelope.json not found. Run New-AkashicSelfManifest.ps1 first.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$results = @()

function Lock-SingleFile {
    param([string]$FilePath, [string]$Label)
    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }
    if ($PSCmdlet.ShouldProcess($FilePath, "Apply $($Strategy.backend) lock")) {
        $r = Invoke-AkashicLockPath -Strategy $Strategy -Path $FilePath
        if ($r.ExitCode -eq 0) {
            Write-Host "LOCKED: $Label"
            return @{ Path = $FilePath; Label = $Label; Status = 'LOCKED'; Backend = $Strategy.backend }
        } else {
            Write-Warning "FAILED to lock $Label : $($r.Output)"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
        }
    } else {
        Write-Host "WOULD LOCK: $Label"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF'; Backend = $Strategy.backend }
    }
}

$sep = [System.IO.Path]::DirectorySeparatorChar
foreach ($entry in $manifest.protected.files) {
    $fullPath = Join-Path $AkashicRoot ($entry.path -replace '/', $sep)
    $results += Lock-SingleFile -FilePath $fullPath -Label $entry.path
}

$manifestFile = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.json"
$sidecarFile  = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.sha256"
$results += Lock-SingleFile -FilePath $manifestFile -Label 'manifest/akashic-envelope.json'
$results += Lock-SingleFile -FilePath $sidecarFile -Label 'manifest/akashic-envelope.sha256'

$locked   = @($results | Where-Object { $_.Status -eq 'LOCKED' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = @($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf   = @($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host ''
Write-Host "--- Akashic Root Lock Summary ---"
Write-Host "Backend:   $($Strategy.backend) ($($Strategy.strength))"
Write-Host "Locked:    $locked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Lock operation completed with $failed failure(s)."
}

$results
