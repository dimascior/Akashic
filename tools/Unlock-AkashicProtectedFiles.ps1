<#
.SYNOPSIS
    Remove OS-native filesystem locks from Helios protected runtime files.
.DESCRIPTION
    Reverses the deny ACLs applied by Lock-AkashicProtectedFiles.
    Windows: icacls /remove:d to strip deny ACEs for Everyone (*S-1-1-0).
    Intended for maintenance rebaseline only — relock immediately after changes.
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER IncludeSettingsJson
    Also unlock the Claude settings.json (external control-plane).
.PARAMETER SettingsJsonPath
    Path to Claude settings.json. Defaults to $env:USERPROFILE\.claude\settings.json.
.PARAMETER IncludeTemplates
    Also unlock the templates/ directory.
.PARAMETER WhatIf
    Show what would be unlocked without applying changes.
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

function Unlock-SingleFile {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }

    if ($PSCmdlet.ShouldProcess($FilePath, 'Remove deny write/delete ACL')) {
        $result = & icacls $FilePath /remove:d "*S-1-1-0" 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "UNLOCKED: $Label -> $FilePath"
            return @{ Path = $FilePath; Label = $Label; Status = 'UNLOCKED' }
        } else {
            Write-Warning "FAILED to unlock $Label : $result"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = "$result" }
        }
    } else {
        Write-Host "WOULD UNLOCK: $Label -> $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF' }
    }
}

$results = @()

foreach ($relPath in $ProtectedFiles) {
    $fullPath = Join-Path $HeliosGateRoot $relPath
    $results += Unlock-SingleFile -FilePath $fullPath -Label $relPath
}

if ($IncludeTemplates) {
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    if (Test-Path $templatesDir) {
        if ($PSCmdlet.ShouldProcess($templatesDir, 'Remove deny write/delete ACL on templates directory')) {
            $dirResult = & icacls $templatesDir /remove:d "*S-1-1-0" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "UNLOCKED: templates/ directory -> $templatesDir"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'UNLOCKED' }
            } else {
                Write-Warning "FAILED to unlock templates/ directory: $dirResult"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'FAILED'; Detail = "$dirResult" }
            }
        }
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates\$($tf.Name)"
            $results += Unlock-SingleFile -FilePath $tf.FullName -Label $relLabel
        }
    } else {
        Write-Warning "SKIP: templates/ directory not found at $templatesDir"
        $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'NOT_FOUND' }
    }
}

if ($IncludeSettingsJson) {
    $results += Unlock-SingleFile -FilePath $SettingsJsonPath -Label 'settings.json (external control-plane)'
}

$unlocked = ($results | Where-Object { $_.Status -eq 'UNLOCKED' }).Count
$failed = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf = ($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host "`n--- Unlock Summary ---"
Write-Host "Unlocked:  $unlocked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Unlock operation completed with $failed failure(s)."
}

$results
