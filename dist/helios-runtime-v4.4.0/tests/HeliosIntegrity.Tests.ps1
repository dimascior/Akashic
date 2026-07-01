#requires -Module Pester

Describe "Helios Integrity Bridge" {

    BeforeAll {
        $script:GateRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $BridgePath = Join-Path $script:GateRoot '.command-gate\hooks\lib\HeliosIntegrityBridge.ps1'

        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

        foreach ($dir in @('hooks', 'hooks\lib', 'policy', 'manifest', 'pending', 'inflight', 'evidence', 'blocked')) {
            New-Item -ItemType Directory -Path (Join-Path $script:TestRoot $dir) -Force | Out-Null
        }

        . $BridgePath

        $script:ProtectedFiles = @{
            'hooks/gate_check.ps1'      = 'gate_check content'
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
}

Describe "Helios Maintenance Corridor" {

    BeforeAll {
        $script:GateRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:HookPath = Join-Path $script:GateRoot '.command-gate\hooks\helios_pretooluse.ps1'

        $script:MaintRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-maint-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        foreach ($dir in @('hooks', 'hooks\lib', 'policy', 'manifest', 'pending', 'inflight', 'evidence', 'evidence\maintenance', 'evidence\integrity', 'blocked', 'maintenance', 'templates')) {
            New-Item -ItemType Directory -Path (Join-Path $script:MaintRoot $dir) -Force | Out-Null
        }

        $script:TestFiles = @{
            'hooks/gate_check.ps1'                = 'gc content for maint test'
            'hooks/tier_classifier.ps1'           = 'tc content for maint test'
            'hooks/helios_pretooluse.ps1'         = 'hp content for maint test'
            'hooks/evidence_capture.ps1'          = 'ec content for maint test'
            'hooks/lib/HeliosIntegrityBridge.ps1' = 'bridge content for maint test'
            'policy/command-policy.json'           = '{"schema_version":"command-policy.v1"}'
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $script:FileHashes = @{}
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        foreach ($relPath in $script:TestFiles.Keys) {
            $fullPath = Join-Path $script:MaintRoot ($relPath -replace '/', '\')
            [System.IO.File]::WriteAllText($fullPath, $script:TestFiles[$relPath], $Utf8NoBom)
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $script:FileHashes[$relPath] = $hash
        }

        $manifest = [ordered]@{
            schema_version = 'helios-envelope.v1'
            created_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            rebaselined_by = 'test'
            protected      = [ordered]@{
                description = 'Must not change during gated execution'
                paths       = @('hooks/gate_check.ps1','hooks/evidence_capture.ps1','hooks/tier_classifier.ps1','hooks/helios_pretooluse.ps1','hooks/lib/HeliosIntegrityBridge.ps1','policy/command-policy.json','manifest/helios-envelope.json','manifest/helios-envelope.sha256')
                hashes      = [ordered]@{}
            }
            mutable        = [ordered]@{
                description = 'Must change as part of gate lifecycle'
                dirs        = @('pending/','inflight/','evidence/','blocked/')
            }
        }
        foreach ($relPath in ($script:FileHashes.Keys | Sort-Object)) {
            $manifest.protected.hashes[$relPath] = $script:FileHashes[$relPath]
        }
        $mPath = Join-Path $script:MaintRoot 'manifest\helios-envelope.json'
        $mJson = $manifest | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($mPath, $mJson, $Utf8NoBom)
        $mBytes = [System.IO.File]::ReadAllBytes($mPath)
        $script:ManifestHash = ($sha.ComputeHash($mBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $sPath = Join-Path $script:MaintRoot 'manifest\helios-envelope.sha256'
        [System.IO.File]::WriteAllText($sPath, $script:ManifestHash, $Utf8NoBom)

        $HeliosDotSourceFunctionsOnly = $true
        . (Join-Path $script:GateRoot '.command-gate\hooks\helios_pretooluse.ps1')
    }

    AfterAll {
        if ($script:MaintRoot -and (Test-Path $script:MaintRoot)) {
            Remove-Item -Recurse -Force $script:MaintRoot -ErrorAction SilentlyContinue
        }
    }

    Context "Read-MaintenanceRebaselineRequest" {
        It "returns null when no request exists" {
            $result = Read-MaintenanceRebaselineRequest -Root $script:MaintRoot
            $result | Should -BeNullOrEmpty
        }

        It "reads valid request file" {
            $reqPath = Join-Path $script:MaintRoot 'maintenance\rebaseline-request.json'
            $req = @{
                schema_version       = 'helios-maintenance-rebaseline.v1'
                request_id           = 'test-req-001'
                created_utc          = (Get-Date).ToUniversalTime().ToString('o')
                expires_utc          = (Get-Date).AddHours(2).ToUniversalTime().ToString('o')
                requested_by         = 'test'
                base_manifest_hash   = $script:ManifestHash
                expected_drift_paths = @('hooks/helios_pretooluse.ps1')
                reason               = 'test reason'
                write_mode           = 'front_controller_internal_rebaseline'
            }
            $req | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $reqPath -Encoding UTF8
            try {
                $result = Read-MaintenanceRebaselineRequest -Root $script:MaintRoot
                $result | Should -Not -BeNullOrEmpty
                $result.request.schema_version | Should -Be 'helios-maintenance-rebaseline.v1'
                $result.path | Should -Be $reqPath
            } finally {
                Remove-Item $reqPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Test-MaintenanceRebaselineRequest" {
        It "rejects expired request" {
            $req = @{
                request = @{
                    schema_version       = 'helios-maintenance-rebaseline.v1'
                    write_mode           = 'front_controller_internal_rebaseline'
                    expires_utc          = '2020-01-01T00:00:00Z'
                    base_manifest_hash   = $script:ManifestHash
                    expected_drift_paths = @('hooks/helios_pretooluse.ps1')
                }
            }
            $result = Test-MaintenanceRebaselineRequest -Request $req -SidecarHash $script:ManifestHash `
                -ActualDriftPaths @('hooks/helios_pretooluse.ps1') -MHashes $script:FileHashes
            $result.valid | Should -Be $false
            $result.reason | Should -Match 'expired'
        }

        It "rejects wrong schema_version" {
            $req = @{
                request = @{
                    schema_version       = 'wrong-version'
                    write_mode           = 'front_controller_internal_rebaseline'
                    expires_utc          = (Get-Date).AddHours(2).ToUniversalTime().ToString('o')
                    base_manifest_hash   = $script:ManifestHash
                    expected_drift_paths = @('hooks/helios_pretooluse.ps1')
                }
            }
            $result = Test-MaintenanceRebaselineRequest -Request $req -SidecarHash $script:ManifestHash `
                -ActualDriftPaths @('hooks/helios_pretooluse.ps1') -MHashes $script:FileHashes
            $result.valid | Should -Be $false
            $result.reason | Should -Match 'schema_version'
        }

        It "rejects base_manifest_hash mismatch" {
            $req = @{
                request = @{
                    schema_version       = 'helios-maintenance-rebaseline.v1'
                    write_mode           = 'front_controller_internal_rebaseline'
                    expires_utc          = (Get-Date).AddHours(2).ToUniversalTime().ToString('o')
                    base_manifest_hash   = '0' * 64
                    expected_drift_paths = @('hooks/helios_pretooluse.ps1')
                }
            }
            $result = Test-MaintenanceRebaselineRequest -Request $req -SidecarHash $script:ManifestHash `
                -ActualDriftPaths @('hooks/helios_pretooluse.ps1') -MHashes $script:FileHashes
            $result.valid | Should -Be $false
            $result.reason | Should -Match 'base_manifest_hash mismatch'
        }

        It "rejects drift path mismatch" {
            $req = @{
                request = @{
                    schema_version       = 'helios-maintenance-rebaseline.v1'
                    write_mode           = 'front_controller_internal_rebaseline'
                    expires_utc          = (Get-Date).AddHours(2).ToUniversalTime().ToString('o')
                    base_manifest_hash   = $script:ManifestHash
                    expected_drift_paths = @('hooks/gate_check.ps1')
                }
            }
            $result = Test-MaintenanceRebaselineRequest -Request $req -SidecarHash $script:ManifestHash `
                -ActualDriftPaths @('hooks/helios_pretooluse.ps1') -MHashes $script:FileHashes
            $result.valid | Should -Be $false
            $result.reason | Should -Match 'mismatch'
        }

        It "accepts valid request with matching drift" {
            $req = @{
                request = @{
                    schema_version       = 'helios-maintenance-rebaseline.v1'
                    write_mode           = 'front_controller_internal_rebaseline'
                    expires_utc          = (Get-Date).AddHours(2).ToUniversalTime().ToString('o')
                    base_manifest_hash   = $script:ManifestHash
                    expected_drift_paths = @('hooks/helios_pretooluse.ps1')
                }
            }
            $result = Test-MaintenanceRebaselineRequest -Request $req -SidecarHash $script:ManifestHash `
                -ActualDriftPaths @('hooks/helios_pretooluse.ps1') -MHashes $script:FileHashes
            $result.valid | Should -Be $true
        }
    }

    Context "Invoke-InternalRebaseline" {
        It "recomputes hashes and writes BOM-free manifest" {
            $targetPath = Join-Path $script:MaintRoot 'hooks\helios_pretooluse.ps1'
            [System.IO.File]::WriteAllText($targetPath, 'modified content', (New-Object System.Text.UTF8Encoding($false)))

            $req = @{
                request = @{
                    requested_by = 'test-rebaseline'
                    reason       = 'test rebaseline'
                }
            }
            $result = Invoke-InternalRebaseline -Root $script:MaintRoot -Request $req -MHashes $script:FileHashes

            $result.new_manifest_hash | Should -Match '^[0-9a-f]{64}$'
            $result.updated_hashes.Count | Should -Be $script:FileHashes.Count

            $mBytes = [System.IO.File]::ReadAllBytes((Join-Path $script:MaintRoot 'manifest\helios-envelope.json'))
            $mBytes[0] | Should -Not -Be 239
            $mBytes[1] | Should -Not -Be 187

            $sContent = [System.IO.File]::ReadAllText((Join-Path $script:MaintRoot 'manifest\helios-envelope.sha256'))
            $sContent | Should -Be $result.new_manifest_hash

            [System.IO.File]::WriteAllText($targetPath, $script:TestFiles['hooks/helios_pretooluse.ps1'], (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    Context "BOM-safe manifest parsing" {
        It "Get-Content -Raw strips BOM from manifest JSON" {
            $testManifest = Join-Path ([System.IO.Path]::GetTempPath()) "bom-test-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            try {
                $bomBytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{"test":"value"}')
                [System.IO.File]::WriteAllBytes($testManifest, $bomBytes)

                $parsed = Get-Content $testManifest -Raw | ConvertFrom-Json
                $parsed.test | Should -Be 'value'
            } finally {
                Remove-Item $testManifest -Force -ErrorAction SilentlyContinue
            }
        }

        It "UTF8.GetString preserves BOM and breaks ConvertFrom-Json" {
            $bomBytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{"test":"value"}')
            $rawString = [System.Text.Encoding]::UTF8.GetString($bomBytes)

            { $rawString | ConvertFrom-Json } | Should -Throw
        }
    }
}

Describe "Helios Tools" {

    BeforeAll {
        $script:GateRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:ToolsDir = Join-Path $script:GateRoot '.command-gate\tools'

        $script:ToolTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-tool-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"

        foreach ($dir in @('hooks', 'hooks\lib', 'policy', 'manifest', 'pending', 'inflight', 'evidence', 'blocked')) {
            New-Item -ItemType Directory -Path (Join-Path $script:ToolTestRoot $dir) -Force | Out-Null
        }

        $testFiles = @{
            'hooks\gate_check.ps1'                = 'gc content'
            'hooks\tier_classifier.ps1'           = 'tc content'
            'hooks\helios_pretooluse.ps1'         = 'hp content'
            'hooks\evidence_capture.ps1'          = 'ec content'
            'hooks\lib\HeliosIntegrityBridge.ps1' = 'bridge content'
            'policy\command-policy.json'           = '{}'
        }
        foreach ($rel in $testFiles.Keys) {
            $p = Join-Path $script:ToolTestRoot $rel
            [System.IO.File]::WriteAllBytes($p, [System.Text.Encoding]::UTF8.GetBytes($testFiles[$rel]))
        }
    }

    AfterAll {
        if ($script:ToolTestRoot -and (Test-Path $script:ToolTestRoot)) {
            Remove-Item -Recurse -Force $script:ToolTestRoot -ErrorAction SilentlyContinue
        }
    }

    Context "New-HeliosEnvelopeManifest" {
        It "writes manifest and sidecar with matching hash" {
            $rebaselineScript = Join-Path $script:ToolsDir 'New-HeliosEnvelopeManifest.ps1'
            $result = & $rebaselineScript -GateRoot $script:ToolTestRoot -RebaselinedBy 'test'

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

    Context "Test-HeliosEnvelopeIntegrity" {
        It "reports CLEAN after fresh rebaseline" {
            & (Join-Path $script:ToolsDir 'New-HeliosEnvelopeManifest.ps1') -GateRoot $script:ToolTestRoot -RebaselinedBy 'test' | Out-Null

            $verifyScript = Join-Path $script:ToolsDir 'Test-HeliosEnvelopeIntegrity.ps1'
            $result = & $verifyScript -GateRoot $script:ToolTestRoot

            $result.verdict | Should -Be 'CLEAN'
            $result.sidecar_valid | Should -Be $true
        }

        It "reports DRIFT after protected file modification" {
            & (Join-Path $script:ToolsDir 'New-HeliosEnvelopeManifest.ps1') -GateRoot $script:ToolTestRoot -RebaselinedBy 'test' | Out-Null

            $targetPath = Join-Path $script:ToolTestRoot 'hooks\gate_check.ps1'
            $original = [System.IO.File]::ReadAllBytes($targetPath)
            try {
                [System.IO.File]::WriteAllBytes($targetPath, [System.Text.Encoding]::UTF8.GetBytes('tampered'))

                $verifyScript = Join-Path $script:ToolsDir 'Test-HeliosEnvelopeIntegrity.ps1'
                $result = & $verifyScript -GateRoot $script:ToolTestRoot

                $result.verdict | Should -Be 'DRIFT'
                $drifted = $result.file_details | Where-Object { $_.status -ne 'CLEAN' }
                $drifted.Count | Should -BeGreaterThan 0
                $drifted[0].path | Should -Be 'hooks/gate_check.ps1'
            } finally {
                [System.IO.File]::WriteAllBytes($targetPath, $original)
            }
        }
    }

    Context "Move-HeliosStaleGateArtifacts" {
        It "dry-run reports stale files without moving" {
            $staleTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-stale-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($dir in @('pending', 'inflight', 'evidence')) {
                New-Item -ItemType Directory -Path (Join-Path $staleTestRoot $dir) -Force | Out-Null
            }
            New-Item -ItemType File -Path (Join-Path $staleTestRoot 'pending\old.gate.json') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $staleTestRoot 'inflight\stuck.gate.json') -Force | Out-Null

            try {
                $moveScript = Join-Path $script:ToolsDir 'Move-HeliosStaleGateArtifacts.ps1'
                $result = & $moveScript -GateRoot $staleTestRoot -DryRun

                $result.dry_run | Should -Be $true
                $result.artifacts.Count | Should -Be 2
                Test-Path (Join-Path $staleTestRoot 'pending\old.gate.json') | Should -Be $true
                Test-Path (Join-Path $staleTestRoot 'inflight\stuck.gate.json') | Should -Be $true
            } finally {
                Remove-Item -Recurse -Force $staleTestRoot -ErrorAction SilentlyContinue
            }
        }

        It "moves stale files to evidence/stale/" {
            $staleTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-stale-test2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($dir in @('pending', 'inflight', 'evidence')) {
                New-Item -ItemType Directory -Path (Join-Path $staleTestRoot $dir) -Force | Out-Null
            }
            New-Item -ItemType File -Path (Join-Path $staleTestRoot 'pending\old.gate.json') -Force | Out-Null

            try {
                $moveScript = Join-Path $script:ToolsDir 'Move-HeliosStaleGateArtifacts.ps1'
                $result = & $moveScript -GateRoot $staleTestRoot

                $result.dry_run | Should -Be $false
                Test-Path (Join-Path $staleTestRoot 'pending\old.gate.json') | Should -Be $false
                Test-Path (Join-Path $staleTestRoot 'evidence\stale\pending-old.gate.json') | Should -Be $true
                Test-Path (Join-Path $staleTestRoot 'evidence\stale\cleanup-summary.json') | Should -Be $true
            } finally {
                Remove-Item -Recurse -Force $staleTestRoot -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Test-HeliosEvidenceChain" {
        It "reports COMPLETE for a full evidence chain" {
            $chainTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-chain-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $sessionDir = Join-Path $chainTestRoot 'evidence\integrity\sessions\chain-test\commands'
            New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

            $toolId = 'tool-chain-001'
            @{ type = 'before' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.before.json") -Encoding UTF8
            @{ verdict = 'ALLOW' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.decision.json") -Encoding UTF8
            @{ type = 'after' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.after.json") -Encoding UTF8
            @{ type = 'compare' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.compare.json") -Encoding UTF8

            try {
                $chainScript = Join-Path $script:ToolsDir 'Test-HeliosEvidenceChain.ps1'
                $result = & $chainScript -GateRoot $chainTestRoot -SessionId 'chain-test'

                $result.verdict | Should -Be 'COMPLETE'
                $result.command_count | Should -Be 1
                $result.commands[0].tool_use_id | Should -Be $toolId
            } finally {
                Remove-Item -Recurse -Force $chainTestRoot -ErrorAction SilentlyContinue
            }
        }

        It "reports INCOMPLETE when after is missing for ALLOW verdict" {
            $chainTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-chain-test2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $sessionDir = Join-Path $chainTestRoot 'evidence\integrity\sessions\chain-test2\commands'
            New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

            $toolId = 'tool-chain-002'
            @{ type = 'before' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.before.json") -Encoding UTF8
            @{ verdict = 'ALLOW' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$toolId.decision.json") -Encoding UTF8

            try {
                $chainScript = Join-Path $script:ToolsDir 'Test-HeliosEvidenceChain.ps1'
                $result = & $chainScript -GateRoot $chainTestRoot -SessionId 'chain-test2'

                $result.verdict | Should -Be 'INCOMPLETE'
                $result.commands[0].missing | Should -Contain 'after'
                $result.commands[0].missing | Should -Contain 'compare'
            } finally {
                Remove-Item -Recurse -Force $chainTestRoot -ErrorAction SilentlyContinue
            }
        }

        It "reports COMPLETE_WITH_ORPHANS for orphan after-only files" {
            $chainTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-chain-test4-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $sessionDir = Join-Path $chainTestRoot 'evidence\integrity\sessions\chain-test4\commands'
            New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

            $gatedId = 'tool-gated-001'
            @{ type = 'before' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$gatedId.before.json") -Encoding UTF8
            @{ verdict = 'DENY' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$gatedId.decision.json") -Encoding UTF8

            $orphanId = 'tool-orphan-001'
            @{ type = 'after' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$orphanId.after.json") -Encoding UTF8

            try {
                $chainScript = Join-Path $script:ToolsDir 'Test-HeliosEvidenceChain.ps1'
                $result = & $chainScript -GateRoot $chainTestRoot -SessionId 'chain-test4'

                $result.verdict | Should -Be 'COMPLETE_WITH_ORPHANS'
                $result.complete_count | Should -Be 1
                $result.orphan_count | Should -Be 1
                $result.incomplete_count | Should -Be 0

                $orphanCmd = $result.commands | Where-Object { $_.tool_use_id -eq $orphanId }
                $orphanCmd.verdict | Should -Be 'ORPHAN'
                $orphanCmd.classification | Should -Be 'cross_session_posttool'
            } finally {
                Remove-Item -Recurse -Force $chainTestRoot -ErrorAction SilentlyContinue
            }
        }

        It "reports INCOMPLETE only for genuinely missing evidence" {
            $chainTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-chain-test5-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $sessionDir = Join-Path $chainTestRoot 'evidence\integrity\sessions\chain-test5\commands'
            New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

            $allowedId = 'tool-missing-after'
            @{ type = 'before' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$allowedId.before.json") -Encoding UTF8
            @{ verdict = 'ALLOW' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$allowedId.decision.json") -Encoding UTF8

            $orphanId = 'tool-orphan-002'
            @{ type = 'after' } | ConvertTo-Json | Set-Content (Join-Path $sessionDir "$orphanId.after.json") -Encoding UTF8

            try {
                $chainScript = Join-Path $script:ToolsDir 'Test-HeliosEvidenceChain.ps1'
                $result = & $chainScript -GateRoot $chainTestRoot -SessionId 'chain-test5'

                $result.verdict | Should -Be 'INCOMPLETE'
                $result.incomplete_count | Should -Be 1
                $result.orphan_count | Should -Be 1

                $incompleteCmd = $result.commands | Where-Object { $_.tool_use_id -eq $allowedId }
                $incompleteCmd.verdict | Should -Be 'INCOMPLETE'
                $incompleteCmd.classification | Should -Be 'allow'
                $incompleteCmd.missing | Should -Contain 'after'
            } finally {
                Remove-Item -Recurse -Force $chainTestRoot -ErrorAction SilentlyContinue
            }
        }

        It "reports NO_SESSION for missing session" {
            $chainTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-chain-test3-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $chainTestRoot -Force | Out-Null

            try {
                $chainScript = Join-Path $script:ToolsDir 'Test-HeliosEvidenceChain.ps1'
                $result = & $chainScript -GateRoot $chainTestRoot -SessionId 'nonexistent'

                $result.verdict | Should -Be 'NO_SESSION'
            } finally {
                Remove-Item -Recurse -Force $chainTestRoot -ErrorAction SilentlyContinue
            }
        }
    }
}
