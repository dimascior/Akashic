$msg = @"
docs: update README to reflect Phase 4.4 awareness and installer role

Add installer role section (PlanOnly/Prepare/Activate). Add settings integrity,
session continuity audit, and maintenance transition sections. Add capability
status table with truthful claims: hashes implemented, signatures not
implemented, file lock tooling exists but active runtime locking deferred.
Update schemas list to 15 files. Update component status table. Update phase
roadmap to include Phase 4.4 completion.
"@
git -C "C:\Users\dimas\Desktop\helios-integrity-adapter" commit -m $msg
