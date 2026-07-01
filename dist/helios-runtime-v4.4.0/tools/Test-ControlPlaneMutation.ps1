param(
    [Parameter(Mandatory)][string]$GateRoot,
    [ValidateSet('mutate','restore')][string]$Action = 'mutate'
)
$originPath = Join-Path $GateRoot 'manifest\helios-install-origin.json'
if (-not (Test-Path $originPath)) { Write-Host "SKIP: $originPath not found"; exit 0 }

$json = Get-Content $originPath -Raw | ConvertFrom-Json
if ($Action -eq 'mutate') {
    $json | Add-Member -NotePropertyName 'cp_test_utc' -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    $json | ConvertTo-Json -Depth 5 | Set-Content $originPath -Encoding UTF8
    Write-Host "MUTATED: added cp_test_utc to $originPath"
} else {
    $props = @($json.PSObject.Properties | Where-Object { $_.Name -eq 'cp_test_utc' })
    if ($props.Count -gt 0) {
        $json.PSObject.Properties.Remove('cp_test_utc')
        $json | ConvertTo-Json -Depth 5 | Set-Content $originPath -Encoding UTF8
        Write-Host "RESTORED: removed cp_test_utc from $originPath"
    } else {
        Write-Host "NOOP: cp_test_utc not present"
    }
}
