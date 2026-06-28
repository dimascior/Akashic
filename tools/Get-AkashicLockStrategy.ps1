<#
.SYNOPSIS
    Resolve OS-native lock backend for Akashic protected files.
.DESCRIPTION
    Detects the current platform and returns a strategy object describing
    which lock backend to use and whether privilege escalation is available.

    Backends:
      Windows  - icacls deny write/delete for *S-1-1-0
      Linux    - chattr +i immutable attribute
      macOS    - chflags uchg user immutable flag
      Fallback - chmod a-w (weak, opt-in only)

    Returns resolved executable paths (lock_command, unlock_command,
    status_command) and the resolved privilege_mode. Verb construction
    and status parsing belong in AkashicLockBackend.ps1, not here.

    Never prompts for passwords. Returns PRIVILEGE_UNAVAILABLE blocker
    when non-interactive elevation is not possible.
.PARAMETER PrivilegeMode
    How to escalate privilege on Linux when chattr requires root.
      Auto     - try root, then sudo -n, then doas (default)
      Sudo     - require sudo -n
      Doas     - require doas
      RootOnly - only succeed if already root
      None     - disable elevation entirely
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available. Overrides AllowWeakFallback.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod a-w when the strong backend is unavailable.
    Ignored when RequireStrongLock is set.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback
)

$ErrorActionPreference = 'Stop'

# --- Platform detection ---
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $platform = 'Windows'
} elseif ($IsWindows) {
    $platform = 'Windows'
} elseif ($IsMacOS) {
    $platform = 'macOS'
} elseif ($IsLinux) {
    $platform = 'Linux'
} else {
    $platform = 'Unknown'
}

$backend            = $null
$implemented        = $false
$strength           = $null
$requiresElevation  = $false
$privMode           = 'None'
$lockCmd            = $null
$unlockCmd          = $null
$statusCmd          = $null
$notes              = [System.Collections.Generic.List[string]]::new()
$blockers           = [System.Collections.Generic.List[string]]::new()

switch ($platform) {

    'Windows' {
        $backend    = 'icacls'
        $implemented = $true
        $strength   = 'strong'
        $lockCmd    = 'icacls'
        $unlockCmd  = 'icacls'
        $statusCmd  = 'icacls'
        $notes.Add('Deny write/delete ACL via Everyone SID (*S-1-1-0)')
    }

    'macOS' {
        $chflagsAvail = Get-Command 'chflags' -ErrorAction SilentlyContinue
        if ($chflagsAvail) {
            $backend     = 'chflags'
            $implemented = $true
            $strength    = 'strong_user_immutable'
            $lockCmd     = $chflagsAvail.Source
            $unlockCmd   = $chflagsAvail.Source
            $lsCmd = Get-Command 'ls' -ErrorAction SilentlyContinue
            $statusCmd   = if ($lsCmd) { $lsCmd.Source } else { 'ls' }
            $notes.Add('BSD user immutable flag (uchg) via chflags')
            $notes.Add('Owner can clear flag; schg avoided for recovery safety')
        } else {
            $blockers.Add('BACKEND_UNAVAILABLE')
            $notes.Add('chflags not found on this macOS system')
        }
    }

    'Linux' {
        $chattrResolved = $null
        $lsattrResolved = $null

        $cmd = Get-Command 'chattr' -ErrorAction SilentlyContinue
        if ($cmd) { $chattrResolved = $cmd.Source }
        else {
            foreach ($p in @('/usr/bin/chattr', '/sbin/chattr', '/usr/sbin/chattr')) {
                if (Test-Path $p) { $chattrResolved = $p; break }
            }
        }

        $cmd = Get-Command 'lsattr' -ErrorAction SilentlyContinue
        if ($cmd) { $lsattrResolved = $cmd.Source }
        else {
            foreach ($p in @('/usr/bin/lsattr', '/sbin/lsattr', '/usr/sbin/lsattr')) {
                if (Test-Path $p) { $lsattrResolved = $p; break }
            }
        }

        if (-not $chattrResolved -or -not $lsattrResolved) {
            $blockers.Add('BACKEND_UNAVAILABLE')
            if (-not $chattrResolved) { $notes.Add('chattr not found') }
            if (-not $lsattrResolved) { $notes.Add('lsattr not found') }
        } else {
            $backend            = 'chattr'
            $strength           = 'strong_if_supported'
            $requiresElevation  = $true
            $lockCmd            = $chattrResolved
            $unlockCmd          = $chattrResolved
            $statusCmd          = $lsattrResolved
            $notes.Add('Linux immutable attribute (chattr +i)')
            $notes.Add("chattr: $chattrResolved")
            $notes.Add("lsattr: $lsattrResolved")

            # --- Privilege resolution ---
            $currentUid = $null
            try { $currentUid = (& id -u 2>$null).Trim() } catch {}

            if ($currentUid -eq '0') {
                $requiresElevation = $false
                $implemented = $true
                $privMode = 'None'
                $notes.Add('Running as root')
            } elseif ($PrivilegeMode -eq 'None') {
                $blockers.Add('PRIVILEGE_UNAVAILABLE')
                $notes.Add('PrivilegeMode=None: elevation disabled')
            } elseif ($PrivilegeMode -eq 'RootOnly') {
                $blockers.Add('PRIVILEGE_UNAVAILABLE')
                $notes.Add('RootOnly: current user is not root')
            } else {
                $resolved = $false

                if ($PrivilegeMode -in @('Auto', 'Sudo')) {
                    $sudoCmd = Get-Command 'sudo' -ErrorAction SilentlyContinue
                    if ($sudoCmd) {
                        try {
                            & sudo -n true 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                $privMode = 'Sudo'
                                $implemented = $true
                                $resolved = $true
                                $notes.Add('Elevation: sudo (non-interactive confirmed)')
                            }
                        } catch {}
                    }
                    if (-not $resolved -and $PrivilegeMode -eq 'Sudo') {
                        $blockers.Add('PRIVILEGE_UNAVAILABLE')
                        $notes.Add('Sudo requested but sudo -n failed or sudo not found')
                    }
                }

                if (-not $resolved -and $PrivilegeMode -in @('Auto', 'Doas')) {
                    $doasCmd = Get-Command 'doas' -ErrorAction SilentlyContinue
                    if ($doasCmd) {
                        try {
                            $psi = [System.Diagnostics.ProcessStartInfo]::new()
                            $psi.FileName = 'doas'
                            $psi.Arguments = 'true'
                            $psi.RedirectStandardInput = $true
                            $psi.RedirectStandardOutput = $true
                            $psi.RedirectStandardError = $true
                            $psi.UseShellExecute = $false
                            $psi.CreateNoWindow = $true
                            $p = [System.Diagnostics.Process]::Start($psi)
                            $p.StandardInput.Close()
                            if ($p.WaitForExit(5000) -and $p.ExitCode -eq 0) {
                                $privMode = 'Doas'
                                $implemented = $true
                                $resolved = $true
                                $notes.Add('Elevation: doas (confirmed)')
                            }
                            if (-not $p.HasExited) { try { $p.Kill() } catch {} }
                        } catch {}
                    }
                    if (-not $resolved -and $PrivilegeMode -eq 'Doas') {
                        $blockers.Add('PRIVILEGE_UNAVAILABLE')
                        $notes.Add('Doas requested but doas failed or not found')
                    }
                }

                if (-not $resolved -and $PrivilegeMode -eq 'Auto') {
                    $blockers.Add('PRIVILEGE_UNAVAILABLE')
                    $notes.Add('Auto: neither sudo -n nor doas succeeded')
                }
            }
        }
    }

    default {
        $blockers.Add('BACKEND_UNAVAILABLE')
        $notes.Add('Unknown platform')
    }
}

# --- Weak fallback resolution ---
if (-not $implemented -and $blockers.Count -gt 0) {
    if ($RequireStrongLock) {
        $notes.Add('RequireStrongLock: refusing weak fallback')
    } elseif ($AllowWeakFallback) {
        $chmodCmd = Get-Command 'chmod' -ErrorAction SilentlyContinue
        $lsCmd    = Get-Command 'ls' -ErrorAction SilentlyContinue
        if ($chmodCmd) {
            $backend            = 'chmod'
            $implemented        = $true
            $strength           = 'weak_fallback'
            $requiresElevation  = $false
            $privMode           = 'None'
            $lockCmd            = $chmodCmd.Source
            $unlockCmd          = $chmodCmd.Source
            $statusCmd          = if ($lsCmd) { $lsCmd.Source } else { 'ls' }
            $blockers.Clear()
            $notes.Add('Degraded to chmod a-w (weak: owner can restore write)')
        } else {
            $notes.Add('chmod not found; no fallback available')
        }
    } else {
        $notes.Add('Weak fallback not allowed (pass -AllowWeakFallback to permit chmod)')
    }
}

[ordered]@{
    platform           = $platform
    backend            = $backend
    implemented        = $implemented
    strength           = $strength
    requires_elevation = $requiresElevation
    privilege_mode     = $privMode
    lock_command       = $lockCmd
    unlock_command     = $unlockCmd
    status_command     = $statusCmd
    blockers           = [string[]]$blockers
    notes              = [string[]]$notes
}
