# tier_classifier.ps1 — Dot-sourced by gate_check.ps1 and evidence_capture.ps1
# Exports: Get-CommandTier, Test-ChainViolation, Test-WriteIndicator,
#          Get-CommandCapabilities, Test-ControlPlanePath

$script:GateRoot = Split-Path $PSScriptRoot -Parent
$script:PolicyLoaded = $false
$script:Tier4Patterns = @()
$script:Tier3Patterns = @()
$script:Tier2Patterns = @()
$script:Tier1Patterns = @()
$script:WriteIndicators = @()
$script:CapabilityPatterns = @{}
$script:ControlPlanePaths = @()

function Load-Policy {
    if ($script:PolicyLoaded) { return }
    $PolicyPath = Join-Path $script:GateRoot 'policy\command-policy.json'
    if (-not (Test-Path $PolicyPath)) {
        $script:PolicyLoaded = $true
        return
    }
    try {
        $Policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json

        if ($Policy.tier_4_forbidden) {
            $script:Tier4Patterns = @($Policy.tier_4_forbidden)
        }
        if ($Policy.tier_3_modifying) {
            $script:Tier3Patterns = @($Policy.tier_3_modifying)
        }
        if ($Policy.tier_2_remote_admin) {
            $script:Tier2Patterns = @($Policy.tier_2_remote_admin)
        }
        if ($Policy.tier_1_diagnostic) {
            $script:Tier1Patterns = @($Policy.tier_1_diagnostic)
        }
        if ($Policy.write_indicators) {
            $script:WriteIndicators = @($Policy.write_indicators)
        }
        if ($Policy.capability_patterns) {
            $script:CapabilityPatterns = $Policy.capability_patterns
        }
        if ($Policy.control_plane_paths) {
            $script:ControlPlanePaths = @($Policy.control_plane_paths)
        }
    } catch {}
    $script:PolicyLoaded = $true
}

function Test-ChainViolation {
    param([string]$Command)
    Load-Policy

    $InSingleQuote = $false
    $HasChain = $false
    for ($i = 0; $i -lt $Command.Length; $i++) {
        $c = $Command[$i]
        if ($c -eq "'" -and ($i -eq 0 -or $Command[$i-1] -ne '\')) {
            $InSingleQuote = -not $InSingleQuote
            continue
        }
        if ($InSingleQuote) { continue }

        if ($c -eq ';') { $HasChain = $true; break }
        if ($c -eq '|' -and $i+1 -lt $Command.Length -and $Command[$i+1] -eq '|') { $HasChain = $true; break }
        if ($c -eq '&' -and $i+1 -lt $Command.Length -and $Command[$i+1] -eq '&') { $HasChain = $true; break }
        if ($c -eq '|' -and ($i+1 -ge $Command.Length -or $Command[$i+1] -ne '|')) { $HasChain = $true; break }
    }

    return $HasChain
}

function Test-WriteIndicator {
    param([string]$Command)
    Load-Policy

    foreach ($p in $script:WriteIndicators) {
        if ($Command -match $p) {
            return $true
        }
    }
    return $false
}

function Get-CommandCapabilities {
    param([string]$Command)
    Load-Policy

    $Flags = @{}
    $ReasonCodes = @()
    $HighestCapabilityTier = 0
    $RequiresReadWriteImpact = $false
    $RequiresStopConditions = $false
    $MatchedCategories = @()

    $CategoryNames = @()
    if ($script:CapabilityPatterns -is [PSCustomObject]) {
        $CategoryNames = @($script:CapabilityPatterns.PSObject.Properties.Name)
    } elseif ($script:CapabilityPatterns -is [hashtable]) {
        $CategoryNames = @($script:CapabilityPatterns.Keys)
    }

    foreach ($categoryName in $CategoryNames) {
        $category = $script:CapabilityPatterns.$categoryName
        $patterns = @()
        if ($category.patterns) { $patterns = @($category.patterns) }

        $matched = $false
        foreach ($p in $patterns) {
            if ($Command -match $p) {
                $matched = $true
                break
            }
        }

        if ($matched) {
            $Flags[$categoryName] = $true
            $ReasonCodes += $categoryName.ToUpper()
            $MatchedCategories += $categoryName

            $catTier = 0
            if ($category.tier) { $catTier = [int]$category.tier }
            if ($catTier -gt $HighestCapabilityTier) { $HighestCapabilityTier = $catTier }

            if ($category.requires_read_write_impact -eq $true) { $RequiresReadWriteImpact = $true }
            if ($category.requires_stop_conditions -eq $true) { $RequiresStopConditions = $true }
        } else {
            $Flags[$categoryName] = $false
        }
    }

    return @{
        Flags                   = $Flags
        ReasonCodes             = $ReasonCodes
        HighestCapabilityTier   = $HighestCapabilityTier
        RequiresReadWriteImpact = $RequiresReadWriteImpact
        RequiresStopConditions  = $RequiresStopConditions
        MatchedCategories       = $MatchedCategories
        HasCapability           = ($MatchedCategories.Count -gt 0)
    }
}

function Test-ControlPlanePath {
    param([string]$Command)
    Load-Policy

    $MatchedPaths = @()
    foreach ($p in $script:ControlPlanePaths) {
        if ($Command -match $p) {
            $MatchedPaths += $p
        }
    }

    return @{
        HasControlPlaneRef = ($MatchedPaths.Count -gt 0)
        MatchedPaths       = $MatchedPaths
    }
}

function Get-CommandTier {
    param([string]$Command)
    Load-Policy

    $CapabilityResult = Get-CommandCapabilities $Command
    $ControlPlaneResult = Test-ControlPlanePath $Command

    $ReasonCodes = [System.Collections.ArrayList]@($CapabilityResult.ReasonCodes)
    if ($ControlPlaneResult.HasControlPlaneRef) {
        [void]$ReasonCodes.Add('CONTROL_PLANE_PATH_REFERENCED')
    }

    foreach ($p in $script:Tier4Patterns) {
        if ($Command -match $p) {
            return @{
                Tier               = 4
                Name               = 'forbidden'
                MatchedPattern     = $p
                MatchedTemplate    = $null
                CapabilityFlags    = $CapabilityResult.Flags
                ReasonCodes        = @($ReasonCodes)
                CapabilityEscalated = $false
                ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
            }
        }
    }

    $CatalogPath = Join-Path $script:GateRoot 'templates\operating-catalog.json'
    if (Test-Path $CatalogPath) {
        try {
            $Catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json
            foreach ($entry in $Catalog) {
                $Pattern = $entry.pattern
                if (-not $Pattern) { $Pattern = $entry.pattern_regex }
                if (-not $Pattern) { continue }

                $TemplateId = $entry.template_id
                if (-not $TemplateId) { $TemplateId = $entry.id }

                $EntryName = $entry.name
                if (-not $EntryName) { $EntryName = $entry.family }

                if ($Command -match $Pattern) {
                    $CatalogTier = [int]$entry.tier
                    $Escalated = $false
                    $FinalTier = $CatalogTier

                    if ($CapabilityResult.HighestCapabilityTier -gt $CatalogTier) {
                        $FinalTier = $CapabilityResult.HighestCapabilityTier
                        $Escalated = $true
                        [void]$ReasonCodes.Add("CAPABILITY_ESCALATION_FROM_$($CatalogTier)_TO_$($FinalTier)")
                    }

                    return @{
                        Tier               = $FinalTier
                        Name               = $EntryName
                        MatchedPattern     = $Pattern
                        MatchedTemplate    = $TemplateId
                        CapabilityFlags    = $CapabilityResult.Flags
                        ReasonCodes        = @($ReasonCodes)
                        CapabilityEscalated = $Escalated
                        ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
                    }
                }
            }
        } catch {}
    }

    foreach ($p in $script:Tier3Patterns) {
        if ($Command -match $p) {
            return @{
                Tier               = 3
                Name               = 'modifying'
                MatchedPattern     = $p
                MatchedTemplate    = $null
                CapabilityFlags    = $CapabilityResult.Flags
                ReasonCodes        = @($ReasonCodes)
                CapabilityEscalated = $false
                ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
            }
        }
    }

    foreach ($p in $script:Tier2Patterns) {
        if ($Command -match $p) {
            return @{
                Tier               = 2
                Name               = 'remote_admin'
                MatchedPattern     = $p
                MatchedTemplate    = $null
                CapabilityFlags    = $CapabilityResult.Flags
                ReasonCodes        = @($ReasonCodes)
                CapabilityEscalated = $false
                ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
            }
        }
    }

    foreach ($p in $script:Tier1Patterns) {
        if ($Command -match $p) {
            $Escalated = $false
            $FinalTier = 1

            if ($CapabilityResult.HighestCapabilityTier -gt 1) {
                $FinalTier = $CapabilityResult.HighestCapabilityTier
                $Escalated = $true
                [void]$ReasonCodes.Add("CAPABILITY_ESCALATION_FROM_1_TO_$FinalTier")
            }

            return @{
                Tier               = $FinalTier
                Name               = if ($Escalated) { 'capability_escalated' } else { 'diagnostic' }
                MatchedPattern     = $p
                MatchedTemplate    = $null
                CapabilityFlags    = $CapabilityResult.Flags
                ReasonCodes        = @($ReasonCodes)
                CapabilityEscalated = $Escalated
                ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
            }
        }
    }

    # Tier 0 default — but capability patterns can escalate
    $Escalated = $false
    $FinalTier = 0
    $FinalName = 'routine'

    if ($CapabilityResult.HighestCapabilityTier -gt 0) {
        $FinalTier = $CapabilityResult.HighestCapabilityTier
        $Escalated = $true
        $FinalName = 'capability_escalated'
        [void]$ReasonCodes.Add("CAPABILITY_ESCALATION_FROM_0_TO_$FinalTier")
    }

    return @{
        Tier               = $FinalTier
        Name               = $FinalName
        MatchedPattern     = $null
        MatchedTemplate    = $null
        CapabilityFlags    = $CapabilityResult.Flags
        ReasonCodes        = @($ReasonCodes)
        CapabilityEscalated = $Escalated
        ControlPlanePaths  = $ControlPlaneResult.MatchedPaths
    }
}
