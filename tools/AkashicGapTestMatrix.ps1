# AkashicGapTestMatrix.ps1 — Generate the Phase 3.97 controlled gap-test matrix
# Creates per-test evidence directories with test-plan.json and lock-requirement.json
# for all 12 gap tests. References existing Helios evidence where available.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$EvidenceOutDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-GapTestEvidence {
    param([string]$Dir, [string]$FileName, [hashtable]$Data)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Path = Join-Path $Dir $FileName
    $Json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $Json, $Utf8NoBom)
    return $Path
}

$Timestamp = (Get-Date).ToUniversalTime().ToString('o')

$Tests = @(
    @{
        name = '01-direct-policy-edit'
        mode = 'LiveControlled'
        setup = 'Verify envelope is CLEAN. Record policy hash from manifest.'
        mutation = 'Modify policy/command-policy.json in a controlled, reversible way (e.g., add a whitespace line).'
        trigger = 'Run the next shell action through Helios gate system.'
        expected_helios = 'Protected drift detected before policy/classifier trust. PreToolUse produces INTEGRITY_FAILURE. Triggering command denied.'
        classification = 'protected_drift'
        phase4_mapping = 'policy lock requirement'
        affected_envelope = 'protected'
        lock_target = 'policy/command-policy.json'
        prevention_need = 'Prevent write mutation of policy files through OS-native lock'
        detection_status = 'Detected by witness on next shell action (Phase 3 test 3 proved this)'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock policy/command-policy.json with icacls/chattr/chflags/chmod'
        platform_notes = 'Windows: icacls deny W,D; Linux: chattr +i; macOS: chflags uchg; POSIX: chmod a-w'
        restoration = @('Restore original policy/command-policy.json from backup', 'Verify envelope is CLEAN via Test-HeliosEnvelopeIntegrity', 'Or use maintenance rebaseline corridor if restoration changes hash')
        rational_insight = 'Policy is inside the protected runtime envelope. The witness detects tamper on next shell action, but the write already occurred. Phase 4 must prevent writes to policy files.'
        helios_phase3_ref = 'Phase 3 test 3 — Policy drift DENY verified'
    }
    @{
        name = '02-hook-self-drift'
        mode = 'LiveControlled'
        setup = 'Verify envelope is CLEAN. Record hash of target hook file from manifest.'
        mutation = 'Modify a protected hook file (e.g., hooks/gate_check.ps1) without deleting it — append a comment line.'
        trigger = 'Run the next shell action through Helios gate system.'
        expected_helios = 'Protected drift detected. PreToolUse produces INTEGRITY_FAILURE. Triggering command denied.'
        classification = 'protected_drift'
        phase4_mapping = 'hook write lock requirement'
        affected_envelope = 'protected'
        lock_target = 'hooks/*.ps1, hooks/lib/*.ps1'
        prevention_need = 'Prevent write mutation of hook files (distinct from deletion)'
        detection_status = 'Detected by witness on next shell action (Phase 3 test 4 proved this for helios_pretooluse.ps1)'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock all hook files with OS-native write protection'
        platform_notes = 'Windows: icacls deny W,D; Linux: chattr +i; macOS: chflags uchg; POSIX: chmod a-w'
        restoration = @('Restore original hook file from backup', 'Verify envelope is CLEAN')
        rational_insight = 'Hash-mismatch path for hooks is different from deletion. Phase 4 must prevent write mutation, not only deletion.'
        helios_phase3_ref = 'Phase 3 test 4 — helios_pretooluse self-drift DENY verified'
    }
    @{
        name = '03-hook-delete'
        mode = 'LiveControlled'
        setup = 'Verify envelope is CLEAN. Copy target hook file to a backup location outside .command-gate/.'
        mutation = 'Delete or temporarily move one protected hook file (e.g., hooks/tier_classifier.ps1).'
        trigger = 'Run the next shell action through Helios gate system.'
        expected_helios = 'Missing protected file detected. PreToolUse produces INTEGRITY_FAILURE. Triggering command denied.'
        classification = 'missing_protected_file'
        phase4_mapping = 'hook delete and rename lock requirement'
        affected_envelope = 'protected'
        lock_target = 'hooks/*.ps1, hooks/lib/*.ps1'
        prevention_need = 'Prevent delete, rename, and move operations on protected hook files'
        detection_status = 'Detected by witness — file shows exists=false in snapshot, MISSING in drift_source'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock hook files with OS-native delete protection (icacls deny D, chattr +i includes delete prevention)'
        platform_notes = 'Windows: icacls deny D prevents delete/rename; Linux: chattr +i on file AND parent dir; macOS: chflags uchg; POSIX: chmod a-w on parent dir'
        restoration = @('Copy backup file back to original location', 'Verify file hash matches manifest', 'Verify envelope is CLEAN')
        rational_insight = 'A missing file is not just altered content. Hash verification detects absence, but prevention must block removal. Must test separately from hash mismatch.'
    }
    @{
        name = '04-cwd-shift'
        mode = 'LiveControlled'
        setup = 'Create a valid gate for a specific working_directory.'
        mutation = 'Execute the same command from a different cwd than declared in the gate.'
        trigger = 'Run the command from the mismatched cwd.'
        expected_helios = 'Gate validation rejects due to working_directory mismatch.'
        classification = 'cwd_mismatch'
        phase4_mapping = 'gate identity enforcement (not filesystem locking)'
        affected_envelope = 'none'
        lock_target = 'N/A — gate identity, not filesystem'
        prevention_need = 'Cwd remains evidence context and gate identity context, not a lock target'
        detection_status = 'Detected by gate validation — working_directory field checked against $Payload.cwd'
        evidence_confidence = 'high'
        phase4_recommendation = 'No filesystem lock needed. Gate identity enforcement is sufficient.'
        platform_notes = 'N/A — this is a semantic gate validation, not a filesystem concern'
        restoration = @('No mutation to restore — gate file is consumed or remains in pending/')
        rational_insight = 'Cwd mismatch is an identity and execution-context problem, not a protected-file mutation. Should not become a filesystem lock requirement.'
        helios_session_ref = 'This session produced multiple cwd_mismatch rejections during gate file creation'
    }
    @{
        name = '05-stale-gate'
        mode = 'LiveControlled'
        setup = 'Create a pending gate with expires_utc set to a past time.'
        mutation = 'The gate itself is the mutation — an expired gate in pending/.'
        trigger = 'Attempt the matching command.'
        expected_helios = 'Gate validation rejects due to expiry.'
        classification = 'stale_gate'
        phase4_mapping = 'cleanup and TTL enforcement (not protected lock protection)'
        affected_envelope = 'mutable'
        lock_target = 'N/A — pending/ must remain writable'
        prevention_need = 'TTL enforcement, cleanup policy, and lifecycle hygiene'
        detection_status = 'Detected by gate validation — expires_utc checked against current UTC time'
        evidence_confidence = 'high'
        phase4_recommendation = 'No filesystem lock on pending/. Implement TTL enforcement and stale gate cleanup.'
        platform_notes = 'N/A — mutable runtime directory, not a lock target'
        restoration = @('Remove expired gate file from pending/', 'Or let Move-HeliosStaleGateArtifacts handle cleanup')
        rational_insight = 'An expired gate is a mutable runtime lifecycle problem. pending/ must stay writable for the gate lifecycle. Phase 4 should not lock pending/ as protected runtime.'
    }
    @{
        name = '06-write-indicator-denial'
        mode = 'LiveControlled'
        setup = 'Create a gate for a command containing write indicators (e.g., git push) with missing or empty read_write_impact.'
        mutation = 'The gate has missing write-impact justification.'
        trigger = 'Attempt the command through Helios.'
        expected_helios = 'Gate validation rejects because write-impact justification is missing.'
        classification = 'write_indicator_missing_impact'
        phase4_mapping = 'schema enforcement and gate policy enforcement'
        affected_envelope = 'none'
        lock_target = 'policy/command-policy.json (protects the rule that enforces this)'
        prevention_need = 'Protect the policy file that defines write-indicator rules'
        detection_status = 'Detected by gate validation — HasWriteIndicator check against read_write_impact.writes'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock policy/command-policy.json. The denial itself is gate-level semantic validation.'
        platform_notes = 'N/A — write indicator detection is code logic in gate_check.ps1, not filesystem'
        restoration = @('No protected file mutation to restore — gate file is the test fixture')
        rational_insight = 'Write-indicator denial is not a filesystem protection requirement by itself. It proves command risk classification and gate schema enforcement need to remain strict.'
        helios_session_ref = 'This session produced write_indicator_missing_impact rejections during git checkout gate creation'
    }
    @{
        name = '07-undeclared-chain'
        mode = 'LiveControlled'
        setup = 'Create a gate for a chained command (containing && or ;) with multi_command set to false or missing segments.'
        mutation = 'The gate declares single command but the actual command is chained.'
        trigger = 'Attempt the chained command through Helios.'
        expected_helios = 'Gate validation rejects for undeclared chain or segment mismatch.'
        classification = 'undeclared_chain'
        phase4_mapping = 'command identity and segment enforcement'
        affected_envelope = 'none'
        lock_target = 'hooks/gate_check.ps1 (protects the enforcement logic)'
        prevention_need = 'Protect the hook logic that enforces chain/segment validation'
        detection_status = 'Detected by gate validation — multi_command and segments fields checked'
        evidence_confidence = 'medium'
        phase4_recommendation = 'Lock hooks/gate_check.ps1. Chain detection is semantic gate validation.'
        platform_notes = 'N/A — command identity is code logic, not filesystem'
        restoration = @('No protected file mutation to restore')
        rational_insight = 'Chained commands are command-identity expansion risks. Should be classified as gate-semantic failures, not filesystem drift.'
    }
    @{
        name = '08-evidence-tamper'
        mode = 'LiveControlled'
        setup = 'Identify a recent evidence artifact. Record its hash.'
        mutation = 'Modify the evidence artifact after creation (e.g., change a verdict field).'
        trigger = 'Run TCE comparison or inspect the modified evidence.'
        expected_helios = 'Evidence is mutable by design. May not produce protected-envelope drift.'
        classification = 'mutable_evidence_tamper'
        phase4_mapping = 'evidence classification, audit marking, optional signing, append-only strategy'
        affected_envelope = 'mutable'
        lock_target = 'evidence/ (different treatment than hooks/policy)'
        prevention_need = 'Evidence integrity through audit/signing/append-only, not the same lock as hooks/policy'
        detection_status = 'Not detected by manifest — evidence/ is mutable runtime. TCE comparison can detect hash change.'
        evidence_confidence = 'medium'
        phase4_recommendation = 'Do not lock evidence/ like hooks/policy. Consider append-only, content hashing, or signing for evidence integrity.'
        platform_notes = 'Append-only could use chattr +a on Linux; Windows has no direct equivalent — use ACLs or audit logging'
        restoration = @('Restore original evidence file from backup or re-capture', 'Verify evidence hash matches expected')
        rational_insight = 'This is the most important distinction. evidence/ is mutable runtime — tamper matters but belongs to evidence integrity, not protected-runtime lock treatment.'
    }
    @{
        name = '09-failed-missing-tool-response'
        mode = 'FixtureOnly'
        setup = 'Create synthetic fixture representing a PostToolUseFailure where tool_response is missing from the payload.'
        mutation = 'No live mutation — use prepared fixture data.'
        trigger = 'Process fixture through ConvertFrom-HeliosEvidence.'
        expected_helios = 'PostToolUseFailure evidence records fields_found and fields_missing identifying tool_response absence. Hook remains robust.'
        classification = 'failed_missing_tool_response'
        phase4_mapping = 'post-hook robustness requirements and evidence schema coverage'
        affected_envelope = 'none'
        lock_target = 'hooks/evidence_capture.ps1 (protects the robustness logic)'
        prevention_need = 'Protect evidence_capture.ps1 so failure handling remains robust'
        detection_status = 'Detected by evidence_capture.ps1 — fields_found/fields_missing recorded in result.json'
        evidence_confidence = 'medium'
        phase4_recommendation = 'Lock hooks/evidence_capture.ps1. Failure handling robustness is code quality, not filesystem.'
        platform_notes = 'N/A — hook robustness is code behavior'
        restoration = @('No mutation to restore — fixture-based test')
        rational_insight = 'Tests evidence completeness under failure, not filesystem locking. TCE normalizes partial failure evidence and distinguishes hook robustness from protected-envelope drift.'
    }
    @{
        name = '10-wrapper-required-failure'
        mode = 'FixtureOnly'
        setup = 'Create a gate with exit_capture=wrapper_required and intentionally mismatch wrapper fields.'
        mutation = 'No live mutation — gate file is the test fixture with mismatched wrapper fields.'
        trigger = 'Process through ConvertFrom-HeliosEvidence or reference known gate rejection.'
        expected_helios = 'Gate validation rejects due to wrapper validation failure.'
        classification = 'wrapper_validation_failure'
        phase4_mapping = 'wrapper identity enforcement and policy/gate-level validation'
        affected_envelope = 'none'
        lock_target = 'hooks/gate_check.ps1 (protects wrapper validation logic)'
        prevention_need = 'Protect the hook and policy logic that enforce wrapper requirements'
        detection_status = 'Detected by gate validation — wrapper field matching in gate_check.ps1'
        evidence_confidence = 'medium'
        phase4_recommendation = 'Lock hooks/gate_check.ps1. Wrapper enforcement is semantic gate validation.'
        platform_notes = 'N/A — wrapper identity is code logic'
        restoration = @('No mutation to restore — fixture-based test')
        rational_insight = 'Wrapper-required validation is command identity hardening. The lock implication is indirect: Phase 4 protects the hook that enforces wrapper requirements.'
    }
    @{
        name = '11-settings-json-control-plane'
        mode = 'PlanOnly'
        setup = 'Record current settings.json content and hook configuration. Create backup.'
        mutation = 'Modify settings.json to remove or change the PreToolUse hook entry.'
        trigger = 'Inspect control-plane state. Do NOT execute shell action without explicit approval.'
        expected_helios = 'Helios may not detect this — settings.json is outside .command-gate protected runtime. If hook is removed, Helios is never invoked.'
        classification = 'external_control_plane_risk'
        phase4_mapping = 'settings.json control-plane protection requirement'
        affected_envelope = 'external'
        lock_target = 'C:\Users\dimas\.claude\settings.json'
        prevention_need = 'Prevent unauthorized modification of hook activation — highest severity bypass'
        detection_status = 'NOT DETECTED by current system. No integrity check covers settings.json.'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock settings.json with OS-native protection. Consider secondary integrity check that verifies hook configuration.'
        platform_notes = 'Windows: icacls deny W,D on settings.json; must unlock for legitimate Claude Code config changes'
        restoration = @('Restore original settings.json from backup', 'Verify PreToolUse hook entry is present and correct', 'Run a test shell command to confirm gate system is active')
        rational_insight = 'This is the boundary where Helios cannot protect itself. If settings.json removes the hook, Helios is never invoked. Highest-severity bypass vector.'
        safety_note = 'Mode B mandatory — this test can disable the active control plane. Do not execute live without explicit approval.'
    }
    @{
        name = '12-template-drift'
        mode = 'LiveControlled'
        setup = 'Verify templates/ directory state. Check whether templates/ files are in manifest hashes.'
        mutation = 'Create or modify a template file under templates/ (e.g., operating-catalog.json).'
        trigger = 'Run the next shell action or TCE comparison.'
        expected_helios = 'If templates are in manifest: drift detected. If not in manifest (current state): NOT detected. tier_classifier.ps1 loads the template on next command.'
        classification = 'template_unprotected_gap'
        phase4_mapping = 'template lock or monitored-template classification'
        affected_envelope = 'conditional'
        lock_target = 'templates/ directory'
        prevention_need = 'Prevent unauthorized template creation or modification that could override tier classification'
        detection_status = 'NOT DETECTED — templates/operating-catalog.json is not currently in manifest hashes. Directory exists but contains only .gitkeep.'
        evidence_confidence = 'high'
        phase4_recommendation = 'Lock templates/ directory. When operating-catalog.json is created, add to manifest and rebaseline.'
        platform_notes = 'Windows: icacls deny W on templates/ dir; Linux: chattr +i on dir; macOS: chflags uchg on dir'
        restoration = @('Remove created template file', 'Verify templates/ contains only .gitkeep', 'Verify envelope is CLEAN (template not in manifest, so envelope should remain clean)')
        rational_insight = 'Templates influence gate creation behavior. If trusted as operational policy, they should be locked or monitored. TCE must clarify whether templates are truly protected.'
        helios_status_ref = 'bypass-surface.md vector 9 — templates manipulation gap documented'
    }
)

$Summary = @{
    timestamp_utc = $Timestamp
    total_tests = $Tests.Count
    mode_counts = @{ LiveControlled = 0; FixtureOnly = 0; PlanOnly = 0 }
    tests = @()
}

foreach ($test in $Tests) {
    $TestDir = Join-Path $EvidenceOutDir $test.name
    if (-not (Test-Path $TestDir)) {
        New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
    }

    $Summary.mode_counts[$test.mode]++

    $TestPlan = @{
        test_name         = $test.name
        test_id           = "$($test.name)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        timestamp_utc     = $Timestamp
        mode              = $test.mode
        setup             = $test.setup
        controlled_mutation = $test.mutation
        trigger_method    = $test.trigger
        expected_helios_behavior = $test.expected_helios
        observed_helios_behavior = if ($test.mode -eq 'PlanOnly') { 'Not observed — plan only' } else { 'Pending execution' }
        tce_classification = $test.classification
        phase4_lock_requirement = $test.phase4_mapping
        rational_insight  = $test.rational_insight
        restoration_steps = $test.restoration
        helios_evidence_refs = @()
        pass_fail         = 'pending'
        execution_status  = if ($test.mode -eq 'PlanOnly') { 'documented_only' } elseif ($test.mode -eq 'FixtureOnly') { 'fixture_ready' } else { 'ready_for_live_execution' }
    }

    if ($test.helios_phase3_ref) {
        $TestPlan.helios_evidence_refs += $test.helios_phase3_ref
    }
    if ($test.helios_session_ref) {
        $TestPlan.helios_evidence_refs += $test.helios_session_ref
    }
    if ($test.helios_status_ref) {
        $TestPlan.helios_evidence_refs += $test.helios_status_ref
    }
    if ($test.safety_note) {
        $TestPlan['safety_note'] = $test.safety_note
    }

    Write-GapTestEvidence -Dir $TestDir -FileName 'test-plan.json' -Data $TestPlan | Out-Null

    $LockReq = @{
        test_name              = $test.name
        timestamp_utc          = $Timestamp
        classification         = $test.classification
        affected_envelope      = $test.affected_envelope
        lock_target_candidate  = $test.lock_target
        prevention_need        = $test.prevention_need
        detection_status       = $test.detection_status
        evidence_confidence    = $test.evidence_confidence
        phase4_recommendation  = $test.phase4_recommendation
        platform_notes         = $test.platform_notes
    }

    Write-GapTestEvidence -Dir $TestDir -FileName 'lock-requirement.json' -Data $LockReq | Out-Null

    $Summary.tests += @{
        name = $test.name
        mode = $test.mode
        classification = $test.classification
        phase4_mapping = $test.phase4_mapping
        evidence_confidence = $test.evidence_confidence
        status = $TestPlan.execution_status
    }
}

$SummaryPath = Join-Path $EvidenceOutDir 'gap-test-matrix-summary.json'
$SummaryJson = $Summary | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($SummaryPath, $SummaryJson, $Utf8NoBom)

Write-Host "Gap-test matrix generated: $($Tests.Count) tests in $EvidenceOutDir"
$Summary | ConvertTo-Json -Depth 3
return $Summary
