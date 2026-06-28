# Phase 3.99 — Operational Enforcement Observations

## Context

During Phase 3.98 packaging work, the Helios gate system produced real enforcement evidence as a side effect of normal adapter development. These were not controlled gap tests — they were incidental operational validations that confirm gate identity enforcement is active during packaging work.

## Observed Enforcements

### 1. Undeclared chaining on piped branch-list command

**Command:** `git -C /c/Users/dimas/Desktop/TerminalContextExporter branch -a --format='%(refname:short) %(objectname:short)' 2>&1 | head -20`

**Gate error:** `UNDECLARED CHAINING: command contains chained operators (;, &&, ||, |) but the gate does not declare multi_command:true with segments.`

**Root cause:** The gate declared `multi_command: false` but the command contained a pipe (`|`). The gate system detected the undeclared chain and rejected the command.

**Resolution:** Updated gate to `multi_command: true` with `segments: ["git branch listing", "head filter"]`.

**Phase 3.97 alignment:** This matches gap-test class `undeclared_chain` (test 07). The same enforcement behavior documented as a controlled test plan was observed operationally.

### 2. Working-directory mismatch on git -C command

**Command:** `git -C /c/Users/dimas/Desktop/MythosJustAFable log --oneline -3 phase3.75-helios-integrity-boundary 2>&1`

**Gate error:** `working_directory mismatch gate: C:\Users\dimas\Desktop\MythosJustAFable actual: C:\Users\dimas\Desktop\CODEAPI`

**Root cause:** The gate declared `working_directory` as the Helios repo path, but the Bash tool runs from CODEAPI. The `git -C` flag changes where git operates but does not change the shell's working directory.

**Resolution:** Updated gate `working_directory` to `C:\\Users\\dimas\\Desktop\\CODEAPI` (the actual shell cwd).

**Phase 3.97 alignment:** This matches gap-test class `cwd_mismatch` (test 04). Gate identity enforcement correctly rejected the command because the declared and actual working directories did not match.

## Significance

These observations confirm:

1. **Gate enforcement is active during packaging work.** The system is not theoretical — it enforces gate identity rules on every shell command, including development and packaging operations.

2. **Phase 3.97 gap-test classifications are accurate.** The `undeclared_chain` and `cwd_mismatch` failure classes were defined through controlled test planning. Observing the same failure modes operationally validates the taxonomy.

3. **Gate identity enforcement is distinct from filesystem locking.** Neither of these enforcements involves protected-file drift or manifest hash comparison. They are semantic gate-level validations — the same distinction documented in the Phase 4 lock requirements where tests 4 and 5 are explicitly excluded from filesystem lock targets.

## Future Normalization

These operational observations should be normalized into TCE evidence examples using `ConvertFrom-HeliosEvidence.ps1`. The gate rejection messages contain the failure classification and resolution path. A future phase could ingest these as operational evidence that supplements the controlled gap-test matrix.
