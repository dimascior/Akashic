# AkashicLockBackend.ps1 - Backend dispatch: privilege wrapping, lock/unlock/status, evidence format
# Dot-source from lock/unlock/status/fixture tools alongside AkashicLockTargets.ps1.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-AkashicPath {
    param([string]$Base, [string]$Relative)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $normalized = $Relative.Replace('/', $sep).Replace('\', $sep)
    return Join-Path $Base $normalized
}

function Invoke-AkashicNativeCommand {
    param(
        [Parameter(Mandatory)] [string]$CommandPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [string]$PrivilegeMode = 'None'
    )
    if ($PrivilegeMode -eq 'Sudo') {
        return & sudo -n $CommandPath @Arguments 2>&1
    }
    if ($PrivilegeMode -eq 'Doas') {
        return & doas $CommandPath @Arguments 2>&1
    }
    return & $CommandPath @Arguments 2>&1
}

function Invoke-AkashicLockPath {
    param(
        [Parameter(Mandatory)] $Strategy,
        [Parameter(Mandatory)] [string]$Path
    )
    $lockArgs = switch ($Strategy.backend) {
        'icacls'  { @($Path, '/deny', '*S-1-1-0:(W,D)') }
        'chattr'  { @('+i', $Path) }
        'chflags' { @('uchg', $Path) }
        'chmod'   { @('a-w', $Path) }
        default   { throw "Unsupported Akashic lock backend: $($Strategy.backend)" }
    }
    $output = Invoke-AkashicNativeCommand -CommandPath $Strategy.lock_command -Arguments $lockArgs -PrivilegeMode $Strategy.privilege_mode
    @{ ExitCode = $LASTEXITCODE; Output = "$output" }
}

function Invoke-AkashicUnlockPath {
    param(
        [Parameter(Mandatory)] $Strategy,
        [Parameter(Mandatory)] [string]$Path
    )
    $unlockArgs = switch ($Strategy.backend) {
        'icacls'  { @($Path, '/remove:d', '*S-1-1-0') }
        'chattr'  { @('-i', $Path) }
        'chflags' { @('nouchg', $Path) }
        'chmod'   { @('u+w', $Path) }
        default   { throw "Unsupported Akashic unlock backend: $($Strategy.backend)" }
    }
    $output = Invoke-AkashicNativeCommand -CommandPath $Strategy.unlock_command -Arguments $unlockArgs -PrivilegeMode $Strategy.privilege_mode
    @{ ExitCode = $LASTEXITCODE; Output = "$output" }
}

function Test-AkashicLockState {
    param(
        [Parameter(Mandatory)] $Strategy,
        [Parameter(Mandatory)] [string]$Path
    )
    $statusArgs = switch ($Strategy.backend) {
        'icacls'  { @($Path) }
        'chattr'  { @($Path) }
        'chflags' { @('-lO', $Path) }
        'chmod'   { @('-l', $Path) }
        default   { return $false }
    }
    $output = $null
    try {
        $rawOutput = Invoke-AkashicNativeCommand -CommandPath $Strategy.status_command -Arguments $statusArgs -PrivilegeMode 'None'
        $exitCode = $LASTEXITCODE
        $output = ($rawOutput | Out-String)
    } catch {
        return $false
    }
    if ($exitCode -ne 0 -and $Strategy.backend -eq 'chattr') {
        return $false
    }
    switch ($Strategy.backend) {
        'icacls' {
            $lines = $output -split "`n"
            foreach ($line in $lines) {
                if ($line -match '(?i)(\*S-1-1-0|Everyone)' -and
                    $line -match '\(DENY\)' -and
                    $line -match '\([^)]*[WD][^)]*\)') {
                    return $true
                }
            }
            return $false
        }
        'chattr' {
            foreach ($line in ($output -split "`n")) {
                $trimmed = $line.Trim()
                if ($trimmed -and $trimmed -match '^([^\s]+)') {
                    $attrs = $Matches[1]
                    if ($attrs -match 'i') { return $true }
                }
            }
            return $false
        }
        'chflags' {
            return ($output -match 'uchg')
        }
        'chmod' {
            foreach ($line in ($output -split "`n")) {
                $trimmed = $line.Trim()
                if ($trimmed -match '^([drwxsStT\-]{10})') {
                    return ($Matches[1] -notmatch 'w')
                }
            }
            return $false
        }
        default { return $false }
    }
}

function New-AkashicLockEvidence {
    param(
        [Parameter(Mandatory)] $Strategy,
        [Parameter(Mandatory)] [string]$TestPath,
        [Parameter(Mandatory)] [string[]]$ProtectedFilesTested,
        [Parameter(Mandatory)] [string[]]$MutableDirsTested,
        [hashtable]$NegativeResults,
        [hashtable]$UnlockRecoveryResults,
        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'BLOCKED')]
        [string]$OverallResult,
        [string]$RemainingLimitation
    )

    $osName = $Strategy.platform
    $kernelVersion = ''
    $fsType = ''

    if ($Strategy.platform -eq 'Windows') {
        $kernelVersion = [System.Environment]::OSVersion.VersionString
        try {
            $vol = Get-Volume -DriveLetter ($TestPath.Substring(0, 1)) -ErrorAction SilentlyContinue
            if ($vol) { $fsType = $vol.FileSystemType }
        } catch { $fsType = 'unknown' }
    } elseif ($Strategy.platform -in @('Linux', 'macOS')) {
        try { $kernelVersion = (& uname -r 2>$null).Trim() } catch {}
        try {
            $dfOut = & df -T $TestPath 2>$null | Select-Object -Last 1
            if ($dfOut -match '^\S+\s+(\S+)') { $fsType = $Matches[1] }
        } catch { $fsType = 'unknown' }
    }

    $lockUsed = switch ($Strategy.backend) {
        'icacls'  { "$($Strategy.lock_command) /deny" }
        'chattr'  { "$($Strategy.lock_command) +i" }
        'chflags' { "$($Strategy.lock_command) uchg" }
        'chmod'   { "$($Strategy.lock_command) a-w" }
        default   { $Strategy.lock_command }
    }
    $unlockUsed = switch ($Strategy.backend) {
        'icacls'  { "$($Strategy.unlock_command) /remove:d" }
        'chattr'  { "$($Strategy.unlock_command) -i" }
        'chflags' { "$($Strategy.unlock_command) nouchg" }
        'chmod'   { "$($Strategy.unlock_command) u+w" }
        default   { $Strategy.unlock_command }
    }
    $statusUsed = switch ($Strategy.backend) {
        'icacls'  { $Strategy.status_command }
        'chattr'  { $Strategy.status_command }
        'chflags' { "$($Strategy.status_command) -lO" }
        'chmod'   { "$($Strategy.status_command) -l" }
        default   { $Strategy.status_command }
    }

    [ordered]@{
        schema_version                       = 'akashic-os-lock-evidence.v1'
        timestamp_utc                        = (Get-Date).ToUniversalTime().ToString('o')
        os_name                              = $osName
        kernel_version                       = $kernelVersion
        powershell_version                   = "$($PSVersionTable.PSVersion)"
        filesystem_type                      = $fsType
        backend_selected                     = $Strategy.backend
        strength                             = $Strategy.strength
        privilege_mode                       = $Strategy.privilege_mode
        lock_command_used                    = $lockUsed
        unlock_command_used                  = $unlockUsed
        status_command_used                  = $statusUsed
        test_path                            = $TestPath
        protected_files_tested               = $ProtectedFilesTested
        mutable_dirs_tested                  = $MutableDirsTested
        negative_write_delete_rename_results = $NegativeResults
        unlock_recovery_results              = $UnlockRecoveryResults
        overall_result                       = $OverallResult
        remaining_limitation                 = $RemainingLimitation
        blockers                             = $Strategy.blockers
        notes                                = $Strategy.notes
    }
}
