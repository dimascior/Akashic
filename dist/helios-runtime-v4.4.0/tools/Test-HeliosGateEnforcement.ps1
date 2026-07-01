# Standalone gate enforcement verification.
# Pipes synthetic PreToolUse payloads to the hook and checks results.
# Run directly: powershell -NoProfile -File Test-HeliosGateEnforcement.ps1 -GateRoot <path>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GateRoot
)

$ErrorActionPreference = 'Stop'
$HookPath = Join-Path $GateRoot 'hooks\helios_pretooluse.ps1'

if (-not (Test-Path $HookPath)) {
    Write-Error "Hook not found: $HookPath"
    return
}

$Passed = 0
$Failed = 0
$Results = @()

function Invoke-HookTest {
    param([string]$Name, [hashtable]$Payload, [string]$ExpectContains, [string]$ExpectNotContains)

    $json = $Payload | ConvertTo-Json -Depth 5 -Compress
    $result = $json | powershell -NoProfile -ExecutionPolicy Bypass -File $HookPath 2>&1
    $output = ($result | Out-String).Trim()

    $pass = $true
    $reason = ''

    if ($ExpectContains -and -not $output.Contains($ExpectContains)) {
        $pass = $false
        $reason = "Expected output to contain '$ExpectContains'"
    }
    if ($ExpectNotContains -and $output.Contains($ExpectNotContains)) {
        $pass = $false
        $reason = "Expected output NOT to contain '$ExpectNotContains'"
    }

    return @{
        name   = $Name
        pass   = $pass
        reason = $reason
        output = $output.Substring(0, [Math]::Min($output.Length, 500))
    }
}

Write-Host "`n=== Helios Gate Enforcement Tests ===" -ForegroundColor Cyan
Write-Host "Gate root: $GateRoot`n"

# Test 1: Non-shell tool passthrough
$test = Invoke-HookTest -Name 'Non-shell passthrough' -Payload @{
    tool_name  = 'Read'
    session_id = 'test-session'
    tool_use_id = 'test-001'
    cwd        = $GateRoot
} -ExpectContains '{}'
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Test 2: No-gate denial
$test = Invoke-HookTest -Name 'No-gate denial' -Payload @{
    tool_name   = 'PowerShell'
    session_id  = 'test-session'
    tool_use_id = 'test-002'
    cwd         = $GateRoot
    tool_input  = @{ command = 'Write-Output "enforcement-test"' }
} -ExpectContains 'permissionDecision'
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Test 3: Empty stdin denial
$emptyResult = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $HookPath 2>&1
$emptyOutput = ($emptyResult | Out-String).Trim()
$test = @{
    name   = 'Empty stdin denial'
    pass   = $emptyOutput.Contains('deny')
    reason = if ($emptyOutput.Contains('deny')) { '' } else { 'Expected deny for empty stdin' }
    output = $emptyOutput.Substring(0, [Math]::Min($emptyOutput.Length, 500))
}
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Test 4: Integrity status in decision evidence
$sessionDir = Join-Path $GateRoot 'evidence\integrity\sessions\test-session\commands'
if (Test-Path $sessionDir) {
    $decisions = Get-ChildItem $sessionDir -Filter '*.decision.json' -ErrorAction SilentlyContinue
    $hasIntegrity = $false
    foreach ($d in $decisions) {
        $content = Get-Content $d.FullName -Raw | ConvertFrom-Json
        if ($content.integrity_status) {
            $hasIntegrity = $true
            break
        }
    }
    $test = @{
        name   = 'Decision evidence includes integrity_status'
        pass   = $hasIntegrity
        reason = if ($hasIntegrity) { '' } else { 'No integrity_status found in decision evidence' }
        output = ''
    }
} else {
    $test = @{
        name   = 'Decision evidence includes integrity_status'
        pass   = $false
        reason = 'No session evidence directory found'
        output = ''
    }
}
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Test 5: Sidecar verification
$manifestPath = Join-Path $GateRoot 'manifest\helios-envelope.json'
$sidecarPath = Join-Path $GateRoot 'manifest\helios-envelope.sha256'
$sha = [System.Security.Cryptography.SHA256]::Create()
$mBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$computed = ($sha.ComputeHash($mBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$sidecar = (Get-Content $sidecarPath -Raw).Trim()
$test = @{
    name   = 'Sidecar matches computed manifest hash'
    pass   = ($computed -eq $sidecar)
    reason = if ($computed -eq $sidecar) { '' } else { "computed=$computed sidecar=$sidecar" }
    output = ''
}
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Test 6: Manifest has no BOM
$firstBytes = [System.IO.File]::ReadAllBytes($manifestPath)[0..2]
$hasBom = ($firstBytes[0] -eq 239 -and $firstBytes[1] -eq 187 -and $firstBytes[2] -eq 191)
$test = @{
    name   = 'Manifest has no UTF-8 BOM'
    pass   = (-not $hasBom)
    reason = if (-not $hasBom) { '' } else { 'Manifest starts with BOM bytes (239,187,191)' }
    output = ''
}
$Results += $test
if ($test.pass) { $Passed++ } else { $Failed++ }
Write-Host "$(if($test.pass){'PASS'}else{'FAIL'}) $($test.name)" -ForegroundColor $(if($test.pass){'Green'}else{'Red'})

# Summary
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "Passed: $Passed  Failed: $Failed  Total: $($Passed + $Failed)"

@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    passed        = $Passed
    failed        = $Failed
    total         = $Passed + $Failed
    results       = $Results
}
