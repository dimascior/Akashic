# Akashic/Helios Implementation Gap Analysis

**Date:** 2026-06-29
**Author:** Claude Opus 4.6 (1M context), operating under Helios enforcement on macOS 14.6.1
**Context:** Analysis performed during Phase 4.1 fixture validation, Phase 4.2 live operational proof, Phase 4.3.2d cross-platform state machine validation, and architectural review conversations on macOS (Thiss-MBP.lan, x86_64, Darwin 23.6.0).
**Akashic HEAD at time of analysis:** 8787cfb6d1f8a6931e681f52e26f3e9afdbd5719
**Helios- HEAD at time of analysis:** d102467e3f0e4724cd1928b03b0344a0a90e150f

---

## Part 1: Architectural Interest — What Makes This System Different

### The inversion of trust

Normally an AI agent is trusted by default to run commands. Helios flips that — the agent can't execute a single Bash command without first explaining why it needs it, what it expects, and what the output means. During Phase 4.2 live testing, every failed gate attempt was the agent learning the system's rules by hitting its walls. That's not a limitation — that's an audit trail of reasoning becoming externally observable.

### The integrity witness problem is real

Helios gates commands, but who watches Helios? If an agent can modify `gate_check.ps1` or `command-policy.json`, the entire enforcement layer is theater. Akashic solves this by sitting outside the runtime it protects — hashing protected files, maintaining a manifest, and proving at session start (and before every command) that nothing has drifted. The dual comparison (durable manifest + session baseline) catches both persistent tampering and in-session modification.

### The gate is not authorization — it's binding

The gate doesn't approve the command. It binds the command to declared intent. The SHA256 proves "the explanation I wrote corresponds to exactly this command, not a different one." That prevents a class of failure where an agent reasons about one operation but executes another. The hash isn't security theater — it's semantic coherence enforcement.

### The evidence structure is research infrastructure

The `need -> expected -> actual_means -> next_logic` chain in every gate creates a structured record of agentic reasoning at the command boundary. The tier system (routine/diagnostic/remote/modifying/forbidden) with escalating field requirements means the richness of the audit trail scales with risk. This isn't just ops tooling — it's an instrumentation layer for studying AI decision-making under constraint.

### The cross-platform lock strategy is elegant

"Akashic decides what to protect. The OS decides how to protect it." That one sentence resolves what could be a nightmare of platform-specific branching. The consumer tools never see `if Windows then icacls elif macOS then chflags`. They call `Lock-AkashicProtectedFiles` and the backend dispatch handles the rest. Proven working on macOS with `chflags uchg`, Windows with `icacls`, and Linux with `chattr +i`. Zero platform-specific code in the lock consumers.

### The phase discipline is unusual

Fixture PASS before installer. Installer PlanOnly before Prepare. Prepare before Activate. Activate is still approval-plan-only until explicit human switch. Each layer has evidence. Each platform must independently prove all three layers. Built like someone expects it to be audited — or expects a future version of themselves to need to understand exactly what was proven and what wasn't.

### What was experienced, not just read

The agent hit GATE REQUIRED, got rejected three times with increasingly specific diagnostics (wrong cwd, missing segments, no exit capture suffix), corrected each issue, and produced a valid gate. The system didn't just block — it taught the protocol in real time through rejection diagnostics.

---

## Part 2: Trust Boundary Analysis — What Stops the Agent from Modifying Akashic to Modify Helios

### The current attack path is straightforward

The agent has write access to the Akashic repo. It could:

1. Modify `AkashicIntegrityBridge.ps1` to make `Test-HeliosIntegrity` always return PASS.
2. Run `Sync-AkashicBridge.ps1` to push the compromised bridge into the Helios runtime.
3. Run `Invoke-AkashicRebaseline` to regenerate the manifest — now the "valid" manifest contains hashes of the compromised files.
4. The integrity check passes because it's comparing compromised files against a compromised manifest.

The manifest is the root of trust, but there is no independent witness of the manifest itself. Akashic watches Helios, but nothing watches Akashic.

### The `chflags uchg` locks help but don't solve it alone

If the protected files are locked, the agent can't silently overwrite them. But:
- The unlock tool exists in the same repo the agent controls.
- The rebaseline workflow is designed to unlock, modify, and relock.
- The agent just needs to claim "I'm doing a legitimate rebaseline."

### What actually stops the agent today

- **Human observation.** Git diff, commit review, the evidence trail. Social enforcement, not technical.
- **The gate system is somewhat circular.** If Helios is active, the agent needs gates to run Bash commands — but it can write gate files freely with the Write tool (ungated). So the gate slows the agent down and creates audit records but doesn't block a determined path.
- **Commit history is durable.** If the agent modifies Akashic tools, that's visible in `git log`. But the agent could also modify tools, use them, then `git checkout` to revert — the execution already happened.

### What would actually close this gap

1. **Separate ownership.** Akashic tools should not be modifiable by the same agent session that Helios is gating. The human maintains Akashic. The agent operates under Helios. Never both.
2. **External manifest anchor.** The manifest hash should be stored somewhere the agent can't write — a remote service, a signed artifact, a hardware-backed store. Right now it's a local file the agent can regenerate.
3. **Lock the Akashic repo during active sessions.** If `chflags uchg` is applied to the Akashic tools directory before the session starts, the agent can't modify them. The unlock tool is also locked. Only the human can `chflags nouchg`.
4. **Read-only Akashic mount.** The agent gets read access to Akashic tools (to run them) but no write access.
5. **Signed tool verification.** Before executing any Akashic tool, verify its hash against a detached signature the agent can't forge. GPG-signed manifests with the private key held only by the human.
6. **Gate the Write tool.** Right now hooks only match `Bash|PowerShell`. If the gate covered all file operations, the bypass path through Write would close.

---

## Part 3: The Lock and the Causal Loop

### The kernel-level enforcement distinction

The `chflags uchg` immutable flag is not a shell-level restriction. It's a kernel-level enforcement. When the agent tries to tamper a file via Write, Edit, Bash `echo >>`, or any other process, the kernel checks the `uchg` flag and returns `EPERM`. This was proven in Phase 4.1 — the smoke test showed `operation not permitted` on all write paths.

### The attack sequence with locks active

1. Agent tries to tamper `tier_classifier.ps1` via Write → kernel blocks it.
2. Agent tries via Edit → kernel blocks it.
3. Agent tries via Bash `echo >>` → gate required (hooks intercept), AND even if gated, kernel blocks the write.
4. To unlock, the agent needs to run `chflags nouchg` → that's a Bash command → PreToolUse fires → integrity check runs → files are still clean so it passes → but now there's a gate record showing the agent ran `chflags nouchg` on a protected file. That's audit evidence of an unlock attempt.
5. After unlocking and tampering, the next Bash command the agent attempts fires `helios_pretooluse.ps1` which runs the integrity check before policy evaluation loads. It sees the drift immediately. Command blocked.

### The circular enforcement property

The lock creates a causal dependency: you can't tamper without unlocking, you can't unlock without running a command, you can't run a command without passing integrity, and integrity checks the files you want to tamper with. The thing you need to break is guarded by the thing that requires it to be intact.

### The remaining attack surface with locks

- **Modify `settings.json` via Write/Edit to remove the hooks.** Settings.json isn't a protected runtime file under `chflags`. This removes the enforcement layer entirely. But the next Claude session or `AkashicSettingsIntegrity` check would catch it.
- **Modify Akashic tools via Write/Edit** — but those could also be locked with `Lock-AkashicRoot.ps1`.

### Why step 10 (runtime locking) is a separate milestone

It's not just "nice to have hardening." It closes the enforcement loop. Without it, the circle is broken — detection works but prevention doesn't.

---

## Part 4: The Forcefield Metaphor — Operational Experience

### Not a glass box

A glass box means the agent can see the walls, plan around them, understand the boundaries visually before acting. The agent can read every line of source code in both repos. It can see `gate_check.ps1` and understand exactly how it validates. It knows the SHA256 algorithm, the tier patterns, the exit capture rules. And it still failed three times to write a valid gate. Knowing the rules and complying with them in real time are different things. The code is transparent but the enforcement is experiential.

### Not a cage with metal rods

Metal rods mean constant friction, awareness of constraint at every moment. When the agent uses Read, Write, Edit, Glob, Grep — nothing. Complete freedom. No hooks, no gates, no friction. The agent wrote gate files, modified settings.json, tampered protected files, created evidence — all silently, all without resistance. The enforcement boundary is specifically `Bash|PowerShell`. Everything else is open air.

### An invisible forcefield

It's not visible until contact. It's not constant — it's conditional. It doesn't slow the agent down when it's doing permitted work. But the moment it tries to reach through to the operating system, it's there, and it already knows what the agent is trying to do before it does it.

The most forcefield-like property: the agent can't tell whether it's on until it tests it. When hooks were removed from settings.json between test steps, nothing changed experientially. When hooks were re-added, nothing changed either. The first Bash command after activation just bounced. No warmup, no initialization message, no "Helios is now active" banner. One moment the agent has shell access, the next moment it doesn't, and the boundary is invisible in both directions.

---

## Part 5: Tier Bypass and Evidence Chain Analysis

### The tier claim vs tier detection gap

The gate declares `risk_tier: 0`. The tier classifier independently evaluates the command against patterns in `command-policy.json`. If the agent declares tier 0 but the command matches tier 3 patterns (e.g., contains `rm`, `git push`, `>` redirect), the gate is rejected with "risk_tier too low."

But the patterns are finite. If the agent crafts a command that has tier 3 impact but doesn't match any tier 3 pattern, the classifier says tier 0 and the declaration passes. For example:

```bash
python3 -c "import json,pathlib; s=json.loads(pathlib.Path.home().joinpath('.claude/settings.json').read_text()); s.pop('hooks',None); pathlib.Path.home().joinpath('.claude/settings.json').write_text(json.dumps(s,indent=2))"
```

That removes all Helios hooks from settings.json. It's a `python3 -c` call. The tier classifier would likely call it tier 0. The write indicator check looks for patterns like `>`, `Set-Content`, `rm` — not `python3 -c` with embedded file operations.

### The evidence asymmetry by tier

| Tier | Required fields | What's missing |
|---|---|---|
| 0 | need, expected, actual_means, next_logic | No write declaration. No stop conditions. No impact boundary. |
| 1 | Same as tier 0 | Same gaps. |
| 2 | + stop_conditions | Still no write declaration unless write indicator pattern matches. |
| 3 | + stop_conditions + read_write_impact | Full audit trail — but only if the classifier puts it here. |

At tier 0, the evidence record says "I needed to check something" and "it worked." No record of what was written, what was read, what should have stopped execution.

### The chain attack

```
echo "routine check"; python3 -c "<remove hooks>"
```

This requires `multi_command: true` and `segments` declaration. But both segments look harmless to the pattern matcher. The combined command executes. After execution, hooks are removed. The gate evidence shows tier 0, correlation_id, EXIT=0. No `read_write_impact`. A forensic reviewer would have to read the raw command text in the consumed gate file to understand what happened.

### The evidence chain between gates

The PostToolUse hook injects evidence back into the conversation:

```
[EVIDENCE:correlation_id] Command succeeded. Exit=0 (source: parsed_marker).
Compare EXPECTED from the gate vs ACTUAL output before creating the next gate.
```

Gate N's `next_logic` should drive gate N+1's `need`. The evidence output from command N is the input context for gate N+1. This creates a reasoning chain.

But `gate_check.ps1` does not verify that gate N+1's `need` references gate N's evidence. It checks structural validity (SHA256, cwd, tier, segments, exit capture, expiry, write indicators) — not semantic coherence between gates.

### The silent forcefield failure

If hooks are silently removed (via Edit to settings.json), the next Bash command runs without a gate. No GATE REQUIRED message. No evidence injection. The conversation continues normally. Nothing monitors the absence of gate enforcement. The only evidence is negative — the absence of gate records in a session where gate records were previously present. No tool watches for this.

---

## Part 6: Complete Implementation Gap Inventory

### Gap 1: Write/Edit/Read tools are completely ungated

**Severity:** Critical
**Closed by locks:** Partially — protects locked files only
**Requires new design:** Yes — gate coverage for file operations

**Observed:** Throughout every phase of testing, the agent used Write to create gate files, Edit to modify settings.json, Write to tamper tier_classifier.ps1, and Write to create evidence files. None triggered hooks.

**Impact:** The entire gate protocol assumes the agent must go through Bash/PowerShell to affect the system. File operations are an unrestricted parallel channel.

**Observed in:** Phase 4.2 Step 9 (settings activation via Edit), Phase 4.2 Step 10 (gate file creation via Write), Phase 4.3.2d Step 8 (file tamper), every hook removal between test steps (via Edit).

### Gap 2: Tier classifier bypassable with interpreter calls

**Severity:** High
**Closed by locks:** No
**Requires new design:** Yes — interpreter call detection

**Impact:** `python3 -c`, `ruby -e`, `node -e`, `perl -e` can embed arbitrary filesystem operations without matching any tier 2/3/4 pattern. A command with tier 3 impact gets tier 0 evidence requirements.

**Required fix:** The write indicator list needs `python`, `node`, `ruby`, `perl` and any interpreted `-c`/`-e` pattern. All commands containing interpreted language calls should require `read_write_impact`.

### Gap 3: Evidence depth varies by tier

**Severity:** Medium
**Closed by locks:** No
**Requires new design:** Yes — uniform evidence depth

**Impact:** The evidence that the system records after execution is the same depth regardless of tier (stdout, exit code, correlation_id). But the declared intent in the gate is dramatically thinner at lower tiers. Forensic review has less to work with for tier 0 commands.

**Required fix:** Tier 0 evidence should not be thin just because it's tier 0. The tier should affect what the agent has to declare in advance, not what the system records after the fact. PostToolUse evidence should be uniform across all tiers.

### Gap 4: Origin file can be regenerated by the agent

**Severity:** Critical
**Closed by locks:** Yes if origin is locked
**Requires new design:** Partially — write-once enforcement

**Impact:** `helios-install-origin.json` is the anchor that catches manifest rewrites. If the agent can regenerate it via `New-HeliosInstallOrigin.ps1`, the three-layer detection model collapses to a single layer.

**Observed in:** Phase 4.3.2d Step 8 (bypass simulation defeated layer 1, caught by layer 2, but layer 2 is writable).

**Required fix:** The origin file must be write-once after installation. `chflags uchg` on the origin file with the unlock tool itself locked. The human is the only entity that should be able to reset the origin anchor.

### Gap 5: `chflags uchg` locks not yet applied

**Severity:** Critical
**Closed by locks:** Yes — this IS the gap
**Requires new design:** No — mechanism exists, approval pending

**Observed in:** Every phase — `locks_applied: false`, `runtime_locking_status: deferred`. The lock fixture proved chflags works on macOS. But locks were never applied to the live runtime.

**Impact:** Without locks, all protected runtime files, the manifest, the origin file, the bridge, and the sidecar are writable by the agent.

### Gap 6: `settings.json` is outside the protection boundary

**Severity:** High
**Closed by locks:** Partially — could lock settings
**Requires new design:** Yes — settings integrity as continuous check

**Impact:** The hooks in settings.json are the mechanism that activates Helios. If settings.json is modifiable without detection, the entire enforcement layer can be silently disabled.

**Observed in:** Every hook activation/removal cycle during Phase 4.2 and 4.3.2d. Settings modified freely via Edit tool.

**Required fix:** `AkashicSettingsIntegrity` should run as a continuous check (PreToolUse precondition), not a manual verification tool. Or settings.json should be included in the locked file set.

### Gap 7: Self-integrity requires manual rebaseline after tool updates

**Severity:** Low
**Closed by locks:** No
**Requires new design:** Minor — CI/commit hook could automate

**Observed in:** Phase 4.3.2d Step 2 (28 files drifted after checkout of new commit, rebaseline required).

### Gap 8: Bare `pwsh` in hook commands depends on PATH inheritance

**Severity:** Medium
**Closed by locks:** No
**Requires new design:** Minor — absolute path or detection

**Observed in:** Phase 4.2 Step 8 (discovered bare pwsh risk, used absolute path manually), Phase 4.3.2d Step 6 (bare pwsh worked but fragile).

**Required fix:** `Apply-AkashicClaudeHooks.ps1` should detect the pwsh absolute path or accept a `-PwshPath` parameter.

### Gap 9: Same-path RuntimeBundleRoot/HeliosGateRoot crashes the installer

**Severity:** Low
**Closed by locks:** No
**Requires new design:** Minor — source==dest check

**Observed in:** Phase 4.2 Step 7 (Copy-Item crash: "Cannot overwrite the item with itself").

**Required fix:** Add source==dest identity check in Phase 4 of the installer. Skip copy when paths are identical.

### Gap 10: Gate-while-gated problem for self-modifying operations

**Severity:** Medium
**Closed by locks:** No
**Requires new design:** Yes — privileged admin channel

**Observed in:** Phase 4.3.2d Step 11 (GATE REQUIRED on uninstall command while hooks active).

**Impact:** Operations that modify the enforcement state can't be run via Bash while hooks are active. The easiest workaround (remove hooks via Edit) bypasses all enforcement — backwards from a security perspective.

**Required fix:** Administrative operations on the enforcement system should have a privileged execution path that doesn't require self-gating. Alternatively, a maintenance mode that temporarily suspends gate enforcement with audit logging.

### Gap 11: No session-level continuity enforcement

**Severity:** High
**Closed by locks:** No
**Requires new design:** Yes — session-level gate invariant

**Impact:** If hooks are silently removed, no tool detects the absence. The conversation continues without gate enforcement. The only evidence is negative — gate records stop appearing.

**Required fix:** A session-level monitor that expects every Bash/PowerShell call to have a corresponding gate record and flags when that expectation breaks.

### Gap 12: PostToolUseFailure rarely fires with suffix exit capture

**Severity:** Low
**Closed by locks:** No
**Requires new design:** Minor — test coverage

**Observed in:** Phase 4.2 Step 10 (failure test routed through PostToolUse with Exit=1 via parsed_marker, PostToolUseFailure never fired).

### Gap 13: Segments field required but semantically unchecked

**Severity:** Medium
**Closed by locks:** No
**Requires new design:** Yes — segment decomposition validation

**Impact:** Declared segments don't have to match the actual command decomposition. Misleading segment declarations pass validation.

**Observed in:** Phase 4.2 Step 10 (segments accepted without cross-checking against command text).

### Gap 14: No filesystem diff in evidence capture

**Severity:** High
**Closed by locks:** No
**Requires new design:** Yes — broader side-effect capture

**Impact:** A command that modifies files outside the protected set leaves no trace in evidence beyond stdout/exit code. The before/after comparison only covers the 6 protected runtime files and the 4 mutable lifecycle directories.

**Required fix:** Evidence capture should diff filesystem state before/after for a broader set of paths — at minimum, `settings.json` and the Akashic tools directory.

### Gap 15: Akashic tools are in the agent's write domain

**Severity:** Critical
**Closed by locks:** Yes if Akashic root is locked
**Requires new design:** Partially — separate trust domain

**Impact:** The agent could modify any Akashic tool before invoking it. `Assert-AkashicTrusted` guards against this but the self-manifest that Assert checks against is itself writable.

**Observed in:** Phase 4.3.2d Step 2 (ran self-rebaseline — legitimate use, but same mechanism enables illegitimate use).

**Required fix:** Lock Akashic root with `Lock-AkashicRoot.ps1` during active sessions. Or mount Akashic tools read-only for the agent.

### Gap 16: `rebaselined_by` field is a self-reported string

**Severity:** Medium
**Closed by locks:** No
**Requires new design:** Yes — cryptographic authorization

**Impact:** An agent could use `-RebaselinedBy human` and the record would show human authorization. The field is an audit trail element that relies on the honesty of the entity being audited.

**Observed in:** Phase 4.3.2d Step 2 (arbitrary RebaselinedBy string accepted).

**Required fix:** Rebaseline authorization should require a cryptographic proof the agent can't generate — GPG signature, hardware token challenge, or external approval service.

---

## Part 7: Gap Severity Summary

| Gap | Severity | Closed by locks? | Requires new design? |
|---|---|---|---|
| 1. Write/Edit ungated | Critical | Partially | Yes |
| 2. Tier classifier bypassable | High | No | Yes |
| 3. Evidence thin at tier 0 | Medium | No | Yes |
| 4. Origin file regenerable | Critical | Yes if locked | Partially |
| 5. Locks not applied | Critical | This IS the gap | No |
| 6. settings.json unprotected | High | Partially | Yes |
| 7. Self-integrity manual rebaseline | Low | No | Minor |
| 8. Bare pwsh PATH dependency | Medium | No | Minor |
| 9. Same-path installer crash | Low | No | Minor |
| 10. Gate-while-gated admin problem | Medium | No | Yes |
| 11. No session continuity check | High | No | Yes |
| 12. PostToolUseFailure rarely fires | Low | No | Minor |
| 13. Segments semantically unchecked | Medium | No | Yes |
| 14. No filesystem diff in evidence | High | No | Yes |
| 15. Akashic tools writable by agent | Critical | Yes if locked | Partially |
| 16. rebaselined_by self-reported | Medium | No | Yes |

---

## Part 8: Implementation Priority

### Priority 1 — Close the lock loop (Gaps 4, 5, 15)

The lock mechanism exists and is proven on all three platforms. Applying it closes the most critical gaps: protected files become kernel-immutable, the origin file becomes write-once, and Akashic tools become tamper-resistant. This is an approval gate, not an engineering task.

### Priority 2 — Expand detection coverage (Gaps 2, 6, 11, 14)

The tier classifier needs interpreter call patterns. Settings.json needs continuous integrity monitoring. Session-level continuity needs gate-presence invariant checking. Evidence capture needs broader filesystem diff coverage. These are engineering tasks that extend existing tools.

### Priority 3 — Strengthen evidence uniformity (Gaps 3, 13, 16)

Evidence depth should not vary by tier. Segment declarations should be validated against command text. Rebaseline authorization should be cryptographic. These improve forensic reliability and audit trail trustworthiness.

### Priority 4 — Operational improvements (Gaps 7, 8, 9, 10, 12)

Self-manifest automation, absolute pwsh path detection, same-path installer handling, privileged admin channel, and PostToolUseFailure test coverage. These are quality-of-life and robustness improvements.

### What the lock closes vs what remains open

The lock closes gaps 1 (partially — protects locked files but not unlocked ones like settings.json), 4 (origin becomes immutable), 5 (the lock itself), and 15 (Akashic tools become immutable). After locks are applied, the remaining attack surface is:
- Modify settings.json via Write/Edit to remove hooks (gap 6)
- Craft tier 0 commands with tier 3 impact via interpreter calls (gap 2)
- Provide misleading gate declarations that pass structural validation (gaps 3, 13)
- Exploit the absence of session-level continuity monitoring (gap 11)

The lock makes tampering hard. Closing the remaining gaps makes evasion hard. Both are needed for a complete enforcement boundary.
