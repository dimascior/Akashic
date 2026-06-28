#requires -Module Pester

Describe "Helios Integrity Bridge" {

    BeforeAll {
        $AdapterRoot = Split-Path $PSScriptRoot -Parent
        $BridgePath  = Join-Path $AdapterRoot 'AkashicIntegrityBridge.ps1'
        . $BridgePath

        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

        foreach ($dir in @('hooks', 'hooks\lib', 'policy', 'manifest', 'pending', 'inflight', 'evidence', 'blocked')) {
            New-Item -ItemType Directory -Path (Join-Path $script:TestRoot $dir) -Force | Out-Null
        }

        $script:ProtectedFiles = @{
            'hooks/gate_check.ps1'     = 'gate_check content'
            'hooks/tier_classifier.ps1' = 'tier_classifier content'
            'policy/command-policy.json' = '{"schema_version":"command-policy.v1"}'
        }

        $sha = [System.Security.Cryptography.SHA256]::Create()
        $script:ExpectedHashes = @{}
        foreach ($relPath in $script:ProtectedFiles.Keys) {
            $fullPath = Join-Path $script:TestRoot ($relPath -replace '/', '\')
            $content = $script:ProtectedFiles[$relPath]
            [System.IO.File]::WriteAllBytes($fullPath, [System.Text.Encoding]::UTF8.GetBytes($content))
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $script:ExpectedHashes[$relPath] = $hash
        }

        New-Item -ItemType File -Path (Join-Path $script:TestRoot 'pending\test.gate.json') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:TestRoot 'evidence\test.result.json') -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Recurse -Force $script:TestRoot -ErrorAction SilentlyContinue
        }
    }

    Context "Get-HeliosEnvelopeSnapshot" {
        It "returns protected file hashes and mutable directory state" {
            $snapshot = Get-HeliosEnvelopeSnapshot -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes `
                -SessionId 'test-session' -ToolUseId 'test-tool' -CommandSha256 'abc123'

            $snapshot.protected.Count | Should -Be $script:ExpectedHashes.Count
            $snapshot.mutable.Keys | Should -Contain 'pending'
            $snapshot.mutable.Keys | Should -Contain 'evidence'
            $snapshot.mutable.Keys | Should -Contain 'inflight'
            $snapshot.mutable.Keys | Should -Contain 'blocked'
            $snapshot.mutable.pending.count | Should -BeGreaterThan 0
            $snapshot.session_id | Should -Be 'test-session'
            $snapshot.tool_use_id | Should -Be 'test-tool'
        }
    }

    Context "Compare-HeliosProtectedEnvelope" {
        It "returns CLEAN when all hashes match" {
            $snapshot = Get-HeliosEnvelopeSnapshot -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes

            $result = Compare-HeliosProtectedEnvelope -CurrentSnapshot $snapshot -ManifestHashes $script:ExpectedHashes

            $result.verdict | Should -Be 'CLEAN'
            $result.checked_against_manifest | Should -Be $true
            $result.details.Count | Should -Be $script:ExpectedHashes.Count
            foreach ($d in $result.details) {
                $d.drift_source.Count | Should -Be 0
            }
        }

        It "returns DRIFT when one hash differs" {
            $snapshot = Get-HeliosEnvelopeSnapshot -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes

            $tamperedHashes = @{}
            foreach ($k in $script:ExpectedHashes.Keys) { $tamperedHashes[$k] = $script:ExpectedHashes[$k] }
            $tamperedHashes['hooks/gate_check.ps1'] = 'aaaa' + $tamperedHashes['hooks/gate_check.ps1'].Substring(4)

            $result = Compare-HeliosProtectedEnvelope -CurrentSnapshot $snapshot -ManifestHashes $tamperedHashes

            $result.verdict | Should -Be 'DRIFT'
            $drifted = $result.details | Where-Object { $_.drift_source.Count -gt 0 }
            $drifted.Count | Should -Be 1
            $drifted[0].path | Should -Be 'hooks/gate_check.ps1'
            $drifted[0].drift_source | Should -Contain 'MANIFEST'
        }

        It "checks baseline when provided" {
            $snapshot = Get-HeliosEnvelopeSnapshot -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes

            $baselineHashes = @{}
            foreach ($k in $script:ExpectedHashes.Keys) { $baselineHashes[$k] = $script:ExpectedHashes[$k] }
            $baselineHashes['policy/command-policy.json'] = '0000000000000000000000000000000000000000000000000000000000000000'

            $result = Compare-HeliosProtectedEnvelope -CurrentSnapshot $snapshot -ManifestHashes $script:ExpectedHashes -BaselineHashes $baselineHashes

            $result.verdict | Should -Be 'DRIFT'
            $result.checked_against_baseline | Should -Be $true
            $drifted = $result.details | Where-Object { 'BASELINE' -in $_.drift_source }
            $drifted.Count | Should -Be 1
            $drifted[0].path | Should -Be 'policy/command-policy.json'
        }
    }

    Context "Compare-HeliosRuntimeTransition" {
        It "returns EXPECTED for valid ALLOW_POSTTOOL movement" {
            $before = @{
                pending  = @{ count = 2; files = @('test.gate.json', 'other.gate.json') }
                inflight = @{ count = 1; files = @('running.gate.json') }
                evidence = @{ count = 5; files = @('a.json','b.json','c.json','d.json','e.json') }
                blocked  = @{ count = 0; files = @() }
            }
            $after = @{
                pending  = @{ count = 2; files = @('test.gate.json', 'other.gate.json') }
                inflight = @{ count = 0; files = @() }
                evidence = @{ count = 7; files = @('a.json','b.json','c.json','d.json','e.json','running.gate.json','running.result.json') }
                blocked  = @{ count = 0; files = @() }
            }

            $result = Compare-HeliosRuntimeTransition -BeforeMutable $before -AfterMutable $after -ExpectedMutationProfile 'ALLOW_POSTTOOL'

            $result.verdict | Should -Be 'EXPECTED'
            $result.profile | Should -Be 'ALLOW_POSTTOOL'
        }

        It "returns UNEXPECTED when evidence loses files during ALLOW_POSTTOOL" {
            $before = @{
                pending  = @{ count = 1; files = @('a.json') }
                inflight = @{ count = 0; files = @() }
                evidence = @{ count = 5; files = @('a.json','b.json','c.json','d.json','e.json') }
                blocked  = @{ count = 0; files = @() }
            }
            $after = @{
                pending  = @{ count = 1; files = @('a.json') }
                inflight = @{ count = 0; files = @() }
                evidence = @{ count = 3; files = @('a.json','b.json','c.json') }
                blocked  = @{ count = 0; files = @() }
            }

            $result = Compare-HeliosRuntimeTransition -BeforeMutable $before -AfterMutable $after -ExpectedMutationProfile 'ALLOW_POSTTOOL'

            $result.verdict | Should -Be 'UNEXPECTED'
        }
    }

    Context "New-HeliosSessionBaseline" {
        It "creates baseline only when manifest is clean" {
            $result = New-HeliosSessionBaseline -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes `
                -SessionId 'baseline-test' -ToolUseId 'tool-001' -CommandSha256 'deadbeef'

            $result.created | Should -Be $true
            $result.path | Should -Not -BeNullOrEmpty
            Test-Path $result.path | Should -Be $true

            $baseline = Get-Content $result.path -Raw | ConvertFrom-Json
            $baseline.schema_version | Should -Be 'helios-baseline.v1'
            $baseline.session_id | Should -Be 'baseline-test'
            $baseline.protected_hashes.PSObject.Properties.Count | Should -Be $script:ExpectedHashes.Count
        }

        It "refuses baseline when manifest has drift" {
            $wrongHashes = @{}
            foreach ($k in $script:ExpectedHashes.Keys) { $wrongHashes[$k] = '0' * 64 }

            $result = New-HeliosSessionBaseline -GateRoot $script:TestRoot -ManifestHashes $wrongHashes `
                -SessionId 'fail-test' -ToolUseId 'tool-002'

            $result.created | Should -Be $false
            $result.reason | Should -Match 'does not match'
        }
    }

    Context "Write-HeliosIntegrityEvidence" {
        It "writes before, decision, after, and compare files" {
            $sessionId = 'evidence-test'
            $toolUseId = 'tool-ev-001'

            foreach ($type in @('before', 'decision', 'after', 'compare')) {
                $data = @{ type = $type; tool_use_id = $toolUseId; timestamp = (Get-Date).ToString('o') }
                $path = Write-HeliosIntegrityEvidence -GateRoot $script:TestRoot -SessionId $sessionId `
                    -ToolUseId $toolUseId -EvidenceType $type -Data $data

                $path | Should -Not -BeNullOrEmpty
                Test-Path $path | Should -Be $true
                $content = Get-Content $path -Raw | ConvertFrom-Json
                $content.type | Should -Be $type
            }
        }
    }

    Context "Test-HeliosIntegrity" {
        It "returns true when all files match" {
            $result = Test-HeliosIntegrity -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes
            $result | Should -Be $true
        }

        It "returns false when a file has been modified" {
            $targetPath = Join-Path $script:TestRoot 'hooks\gate_check.ps1'
            $original = [System.IO.File]::ReadAllBytes($targetPath)
            try {
                [System.IO.File]::WriteAllBytes($targetPath, [System.Text.Encoding]::UTF8.GetBytes('tampered content'))
                $result = Test-HeliosIntegrity -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes
                $result | Should -Be $false
            } finally {
                [System.IO.File]::WriteAllBytes($targetPath, $original)
            }
        }

        It "returns false when a file is missing" {
            $targetPath = Join-Path $script:TestRoot 'hooks\gate_check.ps1'
            $original = [System.IO.File]::ReadAllBytes($targetPath)
            try {
                Remove-Item $targetPath -Force
                $result = Test-HeliosIntegrity -GateRoot $script:TestRoot -ManifestHashes $script:ExpectedHashes
                $result | Should -Be $false
            } finally {
                [System.IO.File]::WriteAllBytes($targetPath, $original)
            }
        }
    }

    Context "Get-FileSha256" {
        It "produces lowercase 64-char hex hash" {
            $testFile = Join-Path $script:TestRoot 'hooks\gate_check.ps1'
            $hash = Get-FileSha256 -Path $testFile
            $hash | Should -Match '^[0-9a-f]{64}$'
        }

        It "produces consistent hashes for same content" {
            $testFile = Join-Path $script:TestRoot 'hooks\gate_check.ps1'
            $hash1 = Get-FileSha256 -Path $testFile
            $hash2 = Get-FileSha256 -Path $testFile
            $hash1 | Should -Be $hash2
        }
    }
}

Describe "Helios Adapter Tools" {

    BeforeAll {
        $script:AdapterRoot = Split-Path $PSScriptRoot -Parent
        $script:ToolsRoot   = Join-Path $script:AdapterRoot 'tools'

        $script:SimAdapterRoot = Join-Path ([System.IO.Path]::GetTempPath()) "akashic-tool-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:GateRoot = Join-Path ([System.IO.Path]::GetTempPath()) "gate-tool-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"

        New-Item -ItemType Directory -Path $script:SimAdapterRoot -Force | Out-Null
        foreach ($dir in @('hooks', 'hooks\lib', 'policy', 'manifest', 'pending', 'inflight', 'evidence', 'blocked')) {
            New-Item -ItemType Directory -Path (Join-Path $script:GateRoot $dir) -Force | Out-Null
        }

        $bridgeContent = '# test bridge content'
        $bridgeSrc = Join-Path $script:SimAdapterRoot 'AkashicIntegrityBridge.ps1'
        [System.IO.File]::WriteAllBytes($bridgeSrc, [System.Text.Encoding]::UTF8.GetBytes($bridgeContent))

        $testFiles = @{
            'hooks\gate_check.ps1'       = 'gc content'
            'hooks\tier_classifier.ps1'  = 'tc content'
            'hooks\helios_pretooluse.ps1' = 'hp content'
            'hooks\evidence_capture.ps1'  = 'ec content'
            'hooks\lib\HeliosIntegrityBridge.ps1' = $bridgeContent
            'policy\command-policy.json'  = '{}'
        }
        foreach ($rel in $testFiles.Keys) {
            $p = Join-Path $script:GateRoot $rel
            [System.IO.File]::WriteAllBytes($p, [System.Text.Encoding]::UTF8.GetBytes($testFiles[$rel]))
        }
    }

    AfterAll {
        if ($script:SimAdapterRoot -and (Test-Path $script:SimAdapterRoot)) {
            Remove-Item -Recurse -Force $script:SimAdapterRoot -ErrorAction SilentlyContinue
        }
        if ($script:GateRoot -and (Test-Path $script:GateRoot)) {
            Remove-Item -Recurse -Force $script:GateRoot -ErrorAction SilentlyContinue
        }
    }

    Context "Sync-AkashicBridge" {
        It "copies bridge file and reports byte-identical" {
            $syncScript = Join-Path $script:ToolsRoot 'Sync-AkashicBridge.ps1'
            $result = & $syncScript -AdapterRoot $script:SimAdapterRoot -HeliosGateRoot $script:GateRoot

            $result.byte_identical | Should -Be $true
            $result.source_hash | Should -Be $result.dest_hash
            $result.source_hash | Should -Match '^[0-9a-f]{64}$'
        }
    }

    Context "AkashicEnvelopeManifest" {
        It "writes manifest and sidecar with matching hash" {
            $rebaselineScript = Join-Path $script:ToolsRoot 'AkashicEnvelopeManifest.ps1'
            $result = & $rebaselineScript -HeliosGateRoot $script:GateRoot -RebaselinedBy 'test'

            $result.manifest_path | Should -Not -BeNullOrEmpty
            $result.sidecar_path | Should -Not -BeNullOrEmpty
            Test-Path $result.manifest_path | Should -Be $true
            Test-Path $result.sidecar_path | Should -Be $true

            $sha = [System.Security.Cryptography.SHA256]::Create()
            $manifestBytes = [System.IO.File]::ReadAllBytes($result.manifest_path)
            $computedHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $sidecarHash = (Get-Content $result.sidecar_path -Raw).Trim()

            $computedHash | Should -Be $sidecarHash
            $result.manifest_hash | Should -Be $computedHash
        }
    }

    Context "AkashicEnvelopeIntegrityValidation" {
        It "reports CLEAN after fresh rebaseline" {
            & (Join-Path $script:ToolsRoot 'AkashicEnvelopeManifest.ps1') -HeliosGateRoot $script:GateRoot -RebaselinedBy 'test' | Out-Null

            $verifyScript = Join-Path $script:ToolsRoot 'AkashicEnvelopeIntegrityValidation.ps1'
            $result = & $verifyScript -HeliosGateRoot $script:GateRoot

            $result.verdict | Should -Be 'CLEAN'
            $result.sidecar_valid | Should -Be $true
        }

        It "reports DRIFT after protected file modification" {
            & (Join-Path $script:ToolsRoot 'AkashicEnvelopeManifest.ps1') -HeliosGateRoot $script:GateRoot -RebaselinedBy 'test' | Out-Null

            $targetPath = Join-Path $script:GateRoot 'hooks\gate_check.ps1'
            [System.IO.File]::WriteAllBytes($targetPath, [System.Text.Encoding]::UTF8.GetBytes('tampered'))

            $verifyScript = Join-Path $script:ToolsRoot 'AkashicEnvelopeIntegrityValidation.ps1'
            $result = & $verifyScript -HeliosGateRoot $script:GateRoot

            $result.verdict | Should -Be 'DRIFT'
            $drifted = $result.file_details | Where-Object { $_.status -ne 'CLEAN' }
            $drifted.Count | Should -BeGreaterThan 0
            $drifted[0].path | Should -Be 'hooks/gate_check.ps1'
        }
    }
}
