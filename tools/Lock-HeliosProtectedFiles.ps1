<#
.SYNOPSIS
    Apply OS-native filesystem locks to Helios protected runtime files.
.DESCRIPTION
    Implements Phase 4.1 protected runtime locks derived from Phase 4.0 gap evidence.
    Windows: icacls deny write/delete to Everyone (*S-1-1-0).
    Lock targets from Phase 4.0 Section 9 decision table.
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory (e.g., C:\Users\dimas\Desktop\MythosJustAFable\.command-gate).
.PARAMETER IncludeSettingsJson
    Also lock the Claude settings.json (external control-plane, Phase 4.0 test #11).
.PARAMETER SettingsJsonPath
    Path to Claude settings.json. Defaults to $env:USERPROFILE\.claude\settings.json.
.PARAMETER IncludeTemplates
    Also lock the templates/ directory (conditional, Phase 4.0 test #12).
.PARAMETER WhatIf
    Show what would be locked without applying changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$IncludeSettingsJson,

    [string]$SettingsJsonPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

    [switch]$IncludeTemplates
)

$ErrorActionPreference = 'Stop'

$ProtectedFiles = @(
    'hooks\helios_pretooluse.ps1',
    'hooks\gate_check.ps1',
    'hooks\evidence_capture.ps1',
    'hooks\tier_classifier.ps1',
    'hooks\lib\HeliosIntegrityBridge.ps1',
    'policy\command-policy.json',
    'manifest\helios-envelope.json',
    'manifest\helios-envelope.sha256'
)

function Lock-SingleFile {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }

    if ($PSCmdlet.ShouldProcess($FilePath, 'Apply deny write/delete ACL')) {
        $result = & icacls $FilePath /deny "*S-1-1-0:(W,D)" 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "LOCKED: $Label -> $FilePath"
            return @{ Path = $FilePath; Label = $Label; Status = 'LOCKED' }
        } else {
            Write-Warning "FAILED to lock $Label : $result"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = "$result" }
        }
    } else {
        Write-Host "WOULD LOCK: $Label -> $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF' }
    }
}

$results = @()

foreach ($relPath in $ProtectedFiles) {
    $fullPath = Join-Path $HeliosGateRoot $relPath
    $results += Lock-SingleFile -FilePath $fullPath -Label $relPath
}

if ($IncludeTemplates) {
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    if (Test-Path $templatesDir) {
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates\$($tf.Name)"
            $results += Lock-SingleFile -FilePath $tf.FullName -Label $relLabel
        }
        if ($PSCmdlet.ShouldProcess($templatesDir, 'Apply deny write/delete ACL on templates directory')) {
            $dirResult = & icacls $templatesDir /deny "*S-1-1-0:(W,D)" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "LOCKED: templates/ directory -> $templatesDir"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'LOCKED' }
            } else {
                Write-Warning "FAILED to lock templates/ directory: $dirResult"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'FAILED'; Detail = "$dirResult" }
            }
        }
    } else {
        Write-Warning "SKIP: templates/ directory not found at $templatesDir"
        $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'NOT_FOUND' }
    }
}

if ($IncludeSettingsJson) {
    $results += Lock-SingleFile -FilePath $SettingsJsonPath -Label 'settings.json (external control-plane)'
}

$locked = ($results | Where-Object { $_.Status -eq 'LOCKED' }).Count
$failed = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf = ($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host "`n--- Lock Summary ---"
Write-Host "Locked:    $locked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Lock operation completed with $failed failure(s)."
}

$results
