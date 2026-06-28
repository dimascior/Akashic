# HeliosIntegrityBridge.ps1 — TCE adapter for Helios envelope integrity
# Source-of-truth implementation. Vendored copy lives at .command-gate/hooks/lib/
# PowerShell 5.1+ compatible. No module imports — self-contained for hook use.

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($bytes)
    return ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-HeliosEnvelopeSnapshot {
    param(
        [Parameter(Mandatory)][string]$GateRoot,
        [Parameter(Mandatory)][hashtable]$ManifestHashes,
        [string]$SessionId,
        [string]$ToolUseId,
        [string]$CommandSha256,
        [string]$CorrelationId,
        [string]$Cwd,
        [string]$Shell
    )

    $snapshot = @{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        session_id    = $SessionId
        tool_use_id   = $ToolUseId
        command_sha256 = $CommandSha256
        correlation_id = $CorrelationId
        context = @{
            cwd      = $Cwd
            shell    = $Shell
            user     = $env:USERNAME
            platform = if ($env:OS -eq 'Windows_NT') { 'Windows' } elseif ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'Unknown' }
            hostname = $env:COMPUTERNAME
        }
        protected = @{}
        mutable   = @{}
    }

    foreach ($relPath in $ManifestHashes.Keys) {
        $fullPath = Join-Path $GateRoot $relPath
        $fileExists = Test-Path $fullPath
        $hash = $null
        if ($fileExists) {
            $hash = Get-FileSha256 -Path $fullPath
        }
        $snapshot.protected[$relPath] = @{
            path   = $relPath
            exists = $fileExists
            hash   = $hash
        }
    }

    foreach ($dir in @('pending', 'inflight', 'evidence', 'blocked')) {
        $dirPath = Join-Path $GateRoot $dir
        $files = @()
        if (Test-Path $dirPath) {
            $files = @(Get-ChildItem -Path $dirPath -File | Select-Object -ExpandProperty Name)
        }
        $snapshot.mutable[$dir] = @{
            count = $files.Count
            files = $files
        }
    }

    return $snapshot
}

function Compare-HeliosProtectedEnvelope {
    param(
        [Parameter(Mandatory)][hashtable]$CurrentSnapshot,
        [Parameter(Mandatory)][hashtable]$ManifestHashes,
        [hashtable]$BaselineHashes
    )

    $verdict = 'CLEAN'
    $details = @()

    foreach ($relPath in $ManifestHashes.Keys) {
        $current = $CurrentSnapshot.protected[$relPath]
        $manifestExpected = $ManifestHashes[$relPath]

        $detail = @{
            path              = $relPath
            expected_manifest = $manifestExpected
            expected_baseline = $null
            actual            = $current.hash
            exists            = $current.exists
            drift_source      = @()
        }

        if ($BaselineHashes -and $BaselineHashes.ContainsKey($relPath)) {
            $detail.expected_baseline = $BaselineHashes[$relPath]
        }

        if (-not $current.exists) {
            $verdict = 'DRIFT'
            $detail.drift_source += 'MISSING'
        }
        elseif ($current.hash -ne $manifestExpected) {
            $verdict = 'DRIFT'
            $detail.drift_source += 'MANIFEST'
        }

        if ($detail.expected_baseline -and $current.exists -and $current.hash -ne $detail.expected_baseline) {
            $verdict = 'DRIFT'
            if ('BASELINE' -notin $detail.drift_source) {
                $detail.drift_source += 'BASELINE'
            }
        }

        $details += $detail
    }

    return @{
        verdict                  = $verdict
        details                  = $details
        checked_against_manifest = $true
        checked_against_baseline = ($null -ne $BaselineHashes)
    }
}

function Compare-HeliosRuntimeTransition {
    param(
        [Parameter(Mandatory)][hashtable]$BeforeMutable,
        [Parameter(Mandatory)][hashtable]$AfterMutable,
        [Parameter(Mandatory)][string]$ExpectedMutationProfile
    )

    $verdict = 'EXPECTED'
    $details = @()

    foreach ($dir in @('pending', 'inflight', 'evidence', 'blocked')) {
        $before = $BeforeMutable[$dir]
        $after  = $AfterMutable[$dir]

        $added   = @($after.files | Where-Object { $_ -notin $before.files })
        $removed = @($before.files | Where-Object { $_ -notin $after.files })
        $netChange = $after.count - $before.count

        $detail = @{
            directory    = $dir
            before_count = $before.count
            after_count  = $after.count
            added        = $added
            removed      = $removed
            net_change   = $netChange
            note         = $null
        }

        switch ($ExpectedMutationProfile) {
            'ALLOW_PRETOOL' {
                if ($dir -eq 'pending' -and $netChange -gt 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'pending should not gain files during ALLOW_PRETOOL'
                }
                if ($dir -eq 'inflight' -and $netChange -lt 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'inflight should not lose files during ALLOW_PRETOOL'
                }
                if ($dir -eq 'evidence' -and $netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'evidence should remain stable during ALLOW_PRETOOL'
                }
                if ($dir -eq 'blocked' -and $netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'blocked should remain stable during ALLOW_PRETOOL'
                }
            }
            'ALLOW_POSTTOOL' {
                if ($dir -eq 'inflight' -and $netChange -gt 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'inflight should not gain files during ALLOW_POSTTOOL'
                }
                if ($dir -eq 'evidence' -and $netChange -lt 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'evidence should not lose files during ALLOW_POSTTOOL'
                }
            }
            'DENY_PRETOOL' {
                if ($dir -eq 'pending' -and $netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'pending should remain stable during DENY_PRETOOL'
                }
                if ($dir -eq 'inflight' -and $netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'inflight should remain stable during DENY_PRETOOL'
                }
                if ($dir -eq 'evidence' -and $netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = 'evidence should remain stable during DENY_PRETOOL'
                }
            }
            'INTEGRITY_FAILURE' {
                if ($netChange -ne 0) {
                    $verdict = 'UNEXPECTED'; $detail.note = "$dir should remain stable during INTEGRITY_FAILURE"
                }
            }
        }

        $details += $detail
    }

    return @{
        verdict = $verdict
        profile = $ExpectedMutationProfile
        details = $details
    }
}

function New-HeliosSessionBaseline {
    param(
        [Parameter(Mandatory)][string]$GateRoot,
        [Parameter(Mandatory)][hashtable]$ManifestHashes,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$ToolUseId,
        [string]$CommandSha256,
        [string]$Cwd,
        [string]$Shell
    )

    $snapshot = Get-HeliosEnvelopeSnapshot -GateRoot $GateRoot -ManifestHashes $ManifestHashes `
        -SessionId $SessionId -ToolUseId $ToolUseId -CommandSha256 $CommandSha256 `
        -Cwd $Cwd -Shell $Shell

    $integrityResult = Compare-HeliosProtectedEnvelope -CurrentSnapshot $snapshot -ManifestHashes $ManifestHashes

    if ($integrityResult.verdict -ne 'CLEAN') {
        return @{
            created       = $false
            reason        = 'Protected envelope does not match durable manifest'
            drift_details = $integrityResult.details
        }
    }

    $baseline = @{
        schema_version       = 'helios-baseline.v1'
        session_id           = $SessionId
        created_utc          = (Get-Date).ToUniversalTime().ToString('o')
        anchor_tool_use_id   = $ToolUseId
        anchor_command_sha256 = $CommandSha256
        protected_hashes     = @{}
        mutable_state        = $snapshot.mutable
        context              = $snapshot.context
    }

    foreach ($relPath in $snapshot.protected.Keys) {
        $baseline.protected_hashes[$relPath] = $snapshot.protected[$relPath].hash
    }

    $sessionDir = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId"
    if (-not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }
    $commandsDir = Join-Path $sessionDir 'commands'
    if (-not (Test-Path $commandsDir)) {
        New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null
    }

    $baselinePath = Join-Path $sessionDir 'baseline.json'
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $baselinePath -Encoding UTF8

    return @{
        created  = $true
        path     = $baselinePath
        baseline = $baseline
    }
}

function Test-HeliosIntegrity {
    param(
        [Parameter(Mandatory)][string]$GateRoot,
        [Parameter(Mandatory)][hashtable]$ManifestHashes
    )

    foreach ($relPath in $ManifestHashes.Keys) {
        $fullPath = Join-Path $GateRoot $relPath
        if (-not (Test-Path $fullPath)) { return $false }
        $actual = Get-FileSha256 -Path $fullPath
        if ($actual -ne $ManifestHashes[$relPath]) { return $false }
    }
    return $true
}

function Write-HeliosIntegrityEvidence {
    param(
        [Parameter(Mandatory)][string]$GateRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$ToolUseId,
        [Parameter(Mandatory)][ValidateSet('before','decision','after','compare')][string]$EvidenceType,
        [Parameter(Mandatory)][hashtable]$Data
    )

    $commandsDir = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\commands"
    if (-not (Test-Path $commandsDir)) {
        New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null
    }

    $filePath = Join-Path $commandsDir "$ToolUseId.$EvidenceType.json"
    $Data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $filePath -Encoding UTF8

    return $filePath
}
