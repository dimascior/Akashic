param([Parameter(Mandatory)][string]$Path)
$e = [ref]$null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, $e)
if ($e.Value.Count -gt 0) { $e.Value | ForEach-Object { $_.ToString() } }
else { Write-Host "NO PARSE ERRORS in $Path" }
